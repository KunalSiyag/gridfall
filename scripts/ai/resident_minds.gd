class_name ResidentMinds
extends Node
## Gives every resident a GMI brain. Once a day residents are planned in batches of ten, each
## batch on a different fast model. When something breaks, the people near it and the people with
## the right trade are asked how they react. Every answer is cached per resident so offline runs
## replay what the real models decided; the heuristic below only covers residents nobody has met yet.

signal plans_done(day: int)
signal reacted(ev: Dictionary, responses: Array)
signal busy_changed(n: int)

const D := preload("res://scripts/sim/sim_defs.gd")
const MODELS := [
	"deepseek-ai/DeepSeek-V4.1-Flash", "google/gemini-3.5-flash-lite", "MiniMaxAI/MiniMax-M3",
	"deepseek-ai/DeepSeek-V4-Flash-0731", "Qwen/Qwen3.8-Flash", "zai-org/GLM-5.3-Flash",
]
const BATCH := 10
const MAX_REACTORS := 10
const EFFECTS := {
	"fire": "a building is burning and the fire can spread to its neighbours",
	"blackout": "a power plant is down; homes and workplaces nearby have no electricity",
	"sewage_burst": "a sewage main burst; raw sewage is in the streets",
	"gridlock": "traffic is jammed solid",
	"smog": "toxic smog; people with asthma and the elderly struggle to breathe",
	"earthquake": "buildings collapsed, people may be trapped, fires may start",
	"flood": "the river overflowed; streets and ground floors are under water",
	"tornado": "a tornado tore a path of destroyed buildings",
	"water_main": "a water main broke at the pump; taps nearby are dry",
	"power_line": "a live power line is down across a road; the road is closed and power is cut",
	"car_crash": "a crash is blocking the road and people may be hurt",
}
const PLAN_SYSTEM := """You are the inner minds of real people living in GridFall, a city run by five AI mayors. Each resident below is a distinct person with their own personality, job, household, money and memories. Think as each of them, independently and in character, and decide what they actually do today given their real situation: power, water, pollution, crime, the commute, rent against savings, taxes, incidents near them, and what their mayor said.
Nothing is scripted. People can skip work, change how they commute, cut spending when money is tight, go help neighbours when something breaks, complain or protest at city hall, recommend the city to friends or warn them off, and move out when life is bad. Be realistic: most people keep their routines, few move on a whim, but people do leave after repeated problems or when they cannot afford rent. Mood is 0 (miserable) to 10 (thriving).
Reply with ONLY JSON, one entry per resident with the same ids:
{"residents":[{"id":"r1","go_to_work":true,"commute":"car|bus|bike|walk|stay_home","spend":0-300,"spend_where":"local|downtown|online|none","evening":"home|shopping|park|stadium|visit_friend|help_neighbors|protest|work_overtime","mood":0-10,"mood_reason":"<=12 words","intent":"stay|considering_leaving|leaving","recommend":0-10,"approve_mayor":0-10,"complaint":"none|power|water|sewage|trash|pollution|crime|traffic|taxes|rent|jobs|health|incident|noise","message_to_mayor":"<=20 words or empty","thought":"<=25 words, first person","say":"<=10 words said out loud"}]}"""
const REACT_SYSTEM := """Something just went wrong in GridFall, a city run by five AI mayors. You are the minds of the residents listed. Decide how EACH person reacts, in character, given who they are, their skills, how far away they are, what they are doing right now and their personality.
Nothing fixes itself: the problem stays until people put in work. People whose trade matches what is needed are far more useful; others can still lend a hand, call it in, get to safety, or ignore it. "help" means physically going there now to work on it. "report" means calling it in to the mayor's office. Most people do not drop everything for something far away, but professionals on duty usually respond.
Reply with ONLY JSON: {"responses":[{"id":"r1","action":"help|report|avoid|evacuate|ignore","mood":0-10,"thought":"<=20 words, first person, about THIS incident","say":"<=10 words said out loud right now","message_to_mayor":"<=20 words or empty"}]}
Every field is required for every resident."""

var sim: CitySim
var people: Residents
var client: GmiClient
var brain: Node
var stats: Dictionary = {"live": 0, "cache": 0, "heuristic": 0, "batches_ok": 0, "batches_failed": 0, "reactions": 0}
var model_stats: Dictionary = {}
var last_plan_day: int = 0
var _plans_pending: int = 0
var _reacts_pending: int = 0
var _rot: int = 0
var _asked: Dictionary = {}
var _bad_models: Dictionary = {}
var _rng := RandomNumberGenerator.new()
## Sliced mode (sim.sliced): the day's plan batches and the follow-up reactions wait here and run
## one per frame, in the order the synchronous path runs them.
var _spread: Array[Callable] = []
var _spread_running: bool = false


func setup(p_sim: CitySim, p_people: Residents, p_client: GmiClient, p_brain: Node) -> void:
	sim = p_sim
	people = p_people
	client = p_client
	brain = p_brain
	_rng.seed = sim.city_seed + 99
	_asked.clear()
	_plans_pending = 0
	_reacts_pending = 0
	_spread.clear()
	sim.spread_gate = spreading
	sim.spread_finish = finish_spread
	if not people.day_ready.is_connected(plan_day):
		people.day_ready.connect(plan_day)
		sim.event_started.connect(_on_event_started)


func pending() -> int:
	return _plans_pending + _reacts_pending


func _model(k: int) -> String:
	for step in range(MODELS.size()):
		var m: String = MODELS[(k + step) % MODELS.size()]
		if int(_bad_models.get(m, 0)) < 3:
			return m
	return MODELS[k % MODELS.size()]


func _note_model(model: String, res: Dictionary) -> void:
	if not model_stats.has(model):
		model_stats[model] = {"ok": 0, "fail": 0, "ms": 0}
	var ms: Dictionary = model_stats[model]
	if bool(res.get("ok", false)):
		ms["ok"] = int(ms["ok"]) + 1
		ms["ms"] = int(ms["ms"]) + int(res.get("latency_ms", 0))
		_bad_models[model] = 0
	elif str(res.get("error", "")) != "offline":
		ms["fail"] = int(ms["fail"]) + 1
		_bad_models[model] = int(_bad_models.get(model, 0)) + 1


# ---------------------------------------------------------------- daily plans

func plan_day(day: int) -> void:
	if _spread_ok():
		_plan_day_spread(day)
		return
	last_plan_day = day
	var everyone: Array = people.people.duplicate()
	if everyone.is_empty():
		plans_done.emit(day)
		return
	var batches: Array = []
	for i in range(0, everyone.size(), BATCH):
		batches.append(everyone.slice(i, i + BATCH))
	_plans_pending += batches.size()
	busy_changed.emit(pending())
	var ctx := _city_context()
	for b in range(batches.size()):
		_plan_batch(batches[b], day, _model(_rot + b), ctx)
	_rot += 1
	for ev in sim.events.duplicate():
		var resident_helpers := 0
		for h: String in (ev["helpers"] as Dictionary).keys():
			if h.contains("("):
				resident_helpers += 1
		if resident_helpers < 2:
			_react(ev, true)


## Sliced sim work outside a forced synchronous tick: plan batches and reactions run one per frame.
func _spread_ok() -> bool:
	return sim != null and sim.spread_allowed() and is_inside_tree()


## True while spread plan batches or reactions are still waiting for their frame (sliced mode).
func spreading() -> bool:
	return not _spread.is_empty()


## Runs every waiting spread item now (a save, skip or mode switch needs the whole day planned).
func finish_spread() -> void:
	while not _spread.is_empty():
		var c: Callable = _spread.pop_front()
		c.call()


## plan_day for sliced mode: the same batches, models, context and follow-up reactions, one batch
## per frame instead of all at once (each batch builds ten cards, at most about 10 ms).
func _plan_day_spread(day: int) -> void:
	last_plan_day = day
	var everyone: Array = people.people.duplicate()
	if everyone.is_empty():
		plans_done.emit(day)
		return
	var batches: Array = []
	for i in range(0, everyone.size(), BATCH):
		batches.append(everyone.slice(i, i + BATCH))
	_plans_pending += batches.size()
	busy_changed.emit(pending())
	var ctx := _city_context()
	for b in range(batches.size()):
		_spread.append(_plan_batch.bind(batches[b], day, _model(_rot + b), ctx))
	_rot += 1
	_spread.append(_spread_reacts)
	_run_spread()


## The tail of plan_day: incidents with fewer than two resident helpers get a wide call for help,
## one reaction per frame.
func _spread_reacts() -> void:
	var reacts: Array[Callable] = []
	for ev in sim.events.duplicate():
		var resident_helpers := 0
		for h: String in (ev["helpers"] as Dictionary).keys():
			if h.contains("("):
				resident_helpers += 1
		if resident_helpers < 2:
			reacts.append(_react.bind(ev, true))
	for k in range(reacts.size() - 1, -1, -1):
		_spread.push_front(reacts[k])


func _run_spread() -> void:
	if _spread_running:
		return
	_spread_running = true
	while not _spread.is_empty():
		await get_tree().process_frame
		if _spread.is_empty():
			break
		var c: Callable = _spread.pop_front()
		c.call()
	_spread_running = false


func _plan_batch(batch: Array, day: int, model: String, ctx: Dictionary) -> void:
	var cards: Array = []
	for r: Dictionary in batch:
		cards.append(people.card(r))
	var user := JSON.stringify({"day": day, "city": ctx, "residents": cards})
	var res: Dictionary = await client.live_json("residents", "plans", model, PLAN_SYSTEM, user, day, 3600, 55.0)
	_note_model(model, res)
	var got: Dictionary = {}
	if bool(res["ok"]):
		var arr: Variant = (res["data"] as Dictionary).get("residents", [])
		if typeof(arr) == TYPE_ARRAY:
			for v: Variant in arr:
				if typeof(v) == TYPE_DICTIONARY:
					got[str((v as Dictionary).get("id", ""))] = v
	if str(res.get("error", "")) != "offline":
		var bk := "batches_ok" if not got.is_empty() else "batches_failed"
		stats[bk] = int(stats[bk]) + 1
	for r: Dictionary in batch:
		if not people.people.has(r):
			continue
		var k := "resident|" + people.key(r)
		var data: Dictionary = got.get(str(r["id"]), {})
		var src := "live"
		if not data.is_empty():
			client.remember(k, day, data)
		else:
			data = client.lookup(k, day)
			src = "cache"
			if data.is_empty():
				data = _heuristic_plan(r)
				src = "heuristic"
		stats[src] = int(stats[src]) + 1
		if src != "live":
			client.count_source(src)
		people.apply_plan(r, data, src, model if src == "live" else "")
	_plans_pending -= 1
	busy_changed.emit(pending())
	if _plans_pending == 0:
		people.rebuild_maps()
		plans_done.emit(day)


func _city_context() -> Dictionary:
	var mayors: Array = []
	for mi in range(D.MAYORS.size()):
		var said := ""
		var states: Array = brain.get("mayor_state") if brain != null else []
		if mi < states.size():
			said = str((states[mi] as Dictionary).get("post", ""))
		mayors.append({"district": mi, "mayor": D.MAYORS[mi]["display"], "income_tax_pct": int(sim.mayors[mi]["tax_r"]), "said_yesterday": D.debrand(said)})
	var headline := ""
	if brain != null:
		headline = str((brain.get("last_paper") as Dictionary).get("headline", ""))
	var summary := sim.city_summary()
	return {
		"population": summary["population"], "unemployment": summary["unemployment"], "avg_traffic": summary["avg_traffic"],
		"power": summary["power"], "water": summary["water"], "sewage": summary["sewage"], "trash": summary["waste"],
		"incidents": summary["active_events"], "ordinances": summary["ordinances"], "mayors": mayors, "gazette_headline": headline,
	}


func _heuristic_plan(r: Dictionary) -> Dictionary:
	var c := people.card(r)
	var home: Dictionary = c["home"]
	var money: Dictionary = c["money"]
	var traits: Array = r["traits"]
	var mood := 6.5
	var reasons: Array[String] = []
	var complaint := "none"
	if not bool(home["power"]):
		mood -= 2.5
		reasons.append("no power at home")
		complaint = "power"
	if not bool(home["water"]):
		mood -= 1.5
		reasons.append("dry taps")
		complaint = "water" if complaint == "none" else complaint
	if float(home["pollution"]) > 0.45:
		mood -= 1.5
		reasons.append("the air is filthy")
		complaint = "pollution" if complaint == "none" else complaint
	if float(home["crime"]) > 0.35:
		mood -= 1.0
		reasons.append("crime on my street")
		complaint = "crime" if complaint == "none" else complaint
	var work: Variant = c["work"]
	var jam := 0.0
	var dist := 0
	if typeof(work) == TYPE_DICTIONARY:
		jam = float((work as Dictionary)["avg_traffic_on_route"])
		dist = int((work as Dictionary)["tiles_away"])
		if jam > 0.6:
			mood -= 0.8
			reasons.append("the commute is a nightmare")
			complaint = "traffic" if complaint == "none" else complaint
	elif str(r["job_title"]) not in ["retiree", "student"]:
		mood -= 1.5
		reasons.append("still no job")
		complaint = "jobs" if complaint == "none" else complaint
	if float(money["savings"]) < float(money["daily_rent"]) * 3.0:
		mood -= 1.2
		reasons.append("rent is eating my savings")
		complaint = "rent" if complaint == "none" else complaint
	if int(money["income_tax_pct"]) > 11:
		mood -= 0.8
		complaint = "taxes" if complaint == "none" else complaint
	if not (c["incidents_nearby"] as Array).is_empty():
		mood -= 0.7
		reasons.append("trouble in the neighbourhood")
		complaint = "incident" if complaint == "none" else complaint
	mood += 0.4 * minf(2.0, float((home["nearby"] as Array).size()))
	if traits.has("optimistic"):
		mood += 0.7
	if traits.has("grumpy") or traits.has("cynical"):
		mood -= 0.7
	mood = clampf(mood + _rng.randf_range(-0.5, 0.5), 0.0, 10.0)
	var prev := float(r["mood"])
	var intent := "stay"
	if mood < 3.0 and prev < 3.5 and not traits.has("loyal to the city"):
		intent = "leaving" if _rng.randf() < 0.35 else "considering_leaving"
	elif mood < 4.5:
		intent = "considering_leaving"
	var commute := "car"
	if dist <= 3:
		commute = "walk"
	elif dist <= 6 and (traits.has("adventurous") or traits.has("thrifty")):
		commute = "bike"
	elif jam > 0.45 and sim.cov_transit[int(r["home"])] > 0.2:
		commute = "bus"
	var spend := _rng.randi_range(20, 60)
	if traits.has("frugal") or traits.has("thrifty"):
		spend = _rng.randi_range(5, 25)
	if float(money["savings"]) < 200.0:
		spend = mini(spend, 10)
	var where := "local"
	if jam > 0.7 and traits.has("impatient"):
		where = "online"
	elif traits.has("ambitious") or traits.has("sociable"):
		where = "downtown"
	var evening := "home"
	var skilled_nearby := false
	for line: Variant in c["incidents_nearby"]:
		for s: Variant in c["skills"]:
			if str(line).contains(str(s)):
				skilled_nearby = true
	if not (c["incidents_nearby"] as Array).is_empty() and (skilled_nearby or traits.has("caring") or traits.has("civic-minded") or traits.has("brave")):
		evening = "help_neighbors"
	elif mood < 4.0 and (traits.has("outspoken") or traits.has("community organizer")):
		evening = "protest"
	elif (home["nearby"] as Array).has("park") and _rng.randf() < 0.4:
		evening = "park"
	elif _rng.randf() < 0.35:
		evening = "shopping"
	elif traits.has("sociable"):
		evening = "visit_friend"
	var why := ", ".join(PackedStringArray(reasons.slice(0, 2))) if not reasons.is_empty() else "things are going fine"
	var thought := why.left(1).to_upper() + why.substr(1) + "."
	if reasons.is_empty():
		thought = ["Work, dinner, sleep. Honestly, not bad.", "GridFall is growing on me.", "Quiet day. I'll take it.", "Saving up a bit more this month."][_rng.randi_range(0, 3)]
	var msg := ""
	if complaint != "none" and (mood < 4.5 or traits.has("outspoken") or traits.has("civic-minded")):
		msg = {
			"power": "Our block has no power. Fix the grid.", "water": "No running water at home. Please send help.",
			"pollution": "The air here is making people sick.", "crime": "We need police on our streets.",
			"traffic": "My commute is gridlocked every day.", "jobs": "There are no jobs for people like me.",
			"rent": "Rent is too high for working people.", "taxes": "Taxes are too high for what we get.",
			"incident": "Something is broken near my home and nobody has fixed it.",
		}.get(complaint, "Please listen to your residents.")
	return {
		"go_to_work": not (mood < 2.0 and traits.has("lazy")), "commute": commute, "spend": spend, "spend_where": where,
		"evening": evening, "mood": snappedf(mood, 0.5), "mood_reason": why, "intent": intent,
		"recommend": clampi(int(round(mood)), 0, 10), "approve_mayor": clampi(int(round(mood - 0.5)), 0, 10),
		"complaint": complaint, "message_to_mayor": msg, "thought": thought, "say": "",
	}


# ---------------------------------------------------------------- reacting to incidents

func _on_event_started(ev: Dictionary) -> void:
	if people != null and people.is_active():
		_react(ev, false)


func _react(ev: Dictionary, wide: bool) -> void:
	var picks := _pick_responders(ev, wide)
	if picks.is_empty():
		return
	var eid := int(ev["id"])
	if not _asked.has(eid):
		_asked[eid] = []
	var cards: Array = []
	for r: Dictionary in picks:
		(_asked[eid] as Array).append(str(r["id"]))
		cards.append(_react_card(r, ev))
	var skills: Array = (ev.get("skills", []) as Array).map(func(s: Variant) -> String: return str(D.SKILL_LABELS.get(str(s), s)))
	var helpers: Array = (ev["helpers"] as Dictionary).keys()
	var incident := {
		"what": ev["label"], "where": [int(ev["x"]), int(ev["y"])], "district_mayor": sim.mayors[sim.district[D.idx(int(ev["x"]), int(ev["y"]))]]["name"],
		"effects": EFFECTS.get(str(ev["type"]), ""), "cause": ev.get("reason", ""), "needs_skills": skills,
		"repaired_pct": int(100.0 * float(ev["progress"]) / maxf(1.0, float(ev["work"]))),
		"hours_unfixed": (sim.global_tick() - int(ev.get("start_tick", sim.global_tick()))) * 6, "already_helping": helpers.slice(0, 6),
	}
	var model := _model(_rot + eid)
	_reacts_pending += 1
	busy_changed.emit(pending())
	var user := JSON.stringify({"day": sim.day, "incident": incident, "residents": cards})
	var res: Dictionary = await client.live_json("residents", "reactions", model, REACT_SYSTEM, user, sim.day, 2200, 40.0)
	_note_model(model, res)
	var got: Dictionary = {}
	if bool(res["ok"]):
		var arr: Variant = (res["data"] as Dictionary).get("responses", [])
		if typeof(arr) == TYPE_ARRAY:
			for v: Variant in arr:
				if typeof(v) == TYPE_DICTIONARY:
					got[str((v as Dictionary).get("id", ""))] = v
	if _spread_ok():
		# One responder per frame, ahead of anything already waiting; the sliced tick waits for them.
		var st := {"out": [], "stop": false}
		var items: Array[Callable] = []
		for r: Dictionary in picks:
			items.append(_react_one.bind(r, ev, got, model, st))
		items.append(_react_done.bind(ev, st))
		for k in range(items.size() - 1, -1, -1):
			_spread.push_front(items[k])
		_run_spread()
		return
	var out: Array = []
	for r: Dictionary in picks:
		if not people.people.has(r):
			continue
		var k := "react|%s|%s" % [people.key(r), ev["type"]]
		var data: Dictionary = got.get(str(r["id"]), {})
		var src := "live"
		if not data.is_empty():
			client.remember(k, sim.day, data)
		else:
			data = client.lookup(k, sim.day)
			src = "cache"
			if data.is_empty():
				data = _heuristic_react(r, ev)
				src = "heuristic"
		if src != "live":
			client.count_source(src)
		stats["reactions"] = int(stats["reactions"]) + 1
		if not sim.events.has(ev):
			break
		var action := people.respond(r, ev, data, src, model if src == "live" else "")
		out.append({"id": r["id"], "name": r["name"], "job": r["job_title"], "action": action, "say": r["say"], "thought": r["thought"], "source": src})
	_reacts_pending -= 1
	busy_changed.emit(pending())
	if not out.is_empty():
		var helping := out.filter(func(o: Dictionary) -> bool: return str(o["action"]) == "help").map(func(o: Dictionary) -> String: return str(o["name"]))
		if not helping.is_empty():
			sim._log("%s: %s went to help." % [ev["label"], ", ".join(PackedStringArray(helping.slice(0, 5)))], "response")
		reacted.emit(ev, out)


## One responder of a spread _react (the body of its loop; st carries the results and the break).
func _react_one(r: Dictionary, ev: Dictionary, got: Dictionary, model: String, st: Dictionary) -> void:
	if bool(st["stop"]) or not people.people.has(r):
		return
	var k := "react|%s|%s" % [people.key(r), ev["type"]]
	var data: Dictionary = got.get(str(r["id"]), {})
	var src := "live"
	if not data.is_empty():
		client.remember(k, sim.day, data)
	else:
		data = client.lookup(k, sim.day)
		src = "cache"
		if data.is_empty():
			data = _heuristic_react(r, ev)
			src = "heuristic"
	if src != "live":
		client.count_source(src)
	stats["reactions"] = int(stats["reactions"]) + 1
	if not sim.events.has(ev):
		st["stop"] = true
		return
	var action := people.respond(r, ev, data, src, model if src == "live" else "")
	(st["out"] as Array).append({"id": r["id"], "name": r["name"], "job": r["job_title"], "action": action, "say": r["say"], "thought": r["thought"], "source": src})


## The end of a spread _react, as after its loop.
func _react_done(ev: Dictionary, st: Dictionary) -> void:
	var out: Array = st["out"]
	_reacts_pending -= 1
	busy_changed.emit(pending())
	if not out.is_empty():
		var helping := out.filter(func(o: Dictionary) -> bool: return str(o["action"]) == "help").map(func(o: Dictionary) -> String: return str(o["name"]))
		if not helping.is_empty():
			sim._log("%s: %s went to help." % [ev["label"], ", ".join(PackedStringArray(helping.slice(0, 5)))], "response")
		reacted.emit(ev, out)


func _pick_responders(ev: Dictionary, wide: bool) -> Array:
	var asked: Array = _asked.get(int(ev["id"]), [])
	var ex := int(ev["x"])
	var ey := int(ev["y"])
	var radius := int(ev.get("radius", 3))
	var skilled: Array = []
	var near: Array = []
	for r in people.people:
		if int(r["helping"]) >= 0 or (asked.has(str(r["id"])) and not wide):
			continue
		var at := int(r["at"])
		var h := int(r["home"])
		var d := mini(absi(D.tx(at) - ex) + absi(D.ty(at) - ey), absi(D.tx(h) - ex) + absi(D.ty(h) - ey))
		var has := false
		for s: Variant in r["skills"]:
			if (ev.get("skills", []) as Array).has(str(s)):
				has = true
		if has and d <= (32 if wide else 18):
			skilled.append([d, r])
		elif d <= radius + (5 if wide else 2):
			near.append([d, r])
	skilled.sort_custom(func(a: Array, b: Array) -> bool: return int(a[0]) < int(b[0]))
	near.sort_custom(func(a: Array, b: Array) -> bool: return int(a[0]) < int(b[0]))
	var out: Array = []
	for pair: Array in skilled.slice(0, 6):
		out.append(pair[1])
	for pair: Array in near:
		if out.size() >= MAX_REACTORS:
			break
		out.append(pair[1])
	return out


func _react_card(r: Dictionary, ev: Dictionary) -> Dictionary:
	var at := int(r["at"])
	var h := int(r["home"])
	var ex := int(ev["x"])
	var ey := int(ev["y"])
	var w := int(r["work"])
	var on_duty := w >= 0 and bool(r["worked"]) and absi(D.tx(w) - ex) + absi(D.ty(w) - ey) <= 12
	return {
		"id": r["id"], "name": r["name"], "age": r["age"], "job": r["job_title"], "traits": r["traits"], "household": r["household"],
		"skills": (r["skills"] as Array).map(func(s: Variant) -> String: return str(D.SKILL_LABELS.get(str(s), s))),
		"tiles_away_now": absi(D.tx(at) - ex) + absi(D.ty(at) - ey), "home_tiles_away": absi(D.tx(h) - ex) + absi(D.ty(h) - ey),
		"doing_now": r["state"], "on_duty_nearby": on_duty, "mood": int(round(float(r["mood"]))), "memory": (r["memory"] as Array).slice(-2),
	}


func _heuristic_react(r: Dictionary, ev: Dictionary) -> Dictionary:
	var traits: Array = r["traits"]
	var c := _react_card(r, ev)
	var d := int(c["tiles_away_now"])
	var has := false
	for s: Variant in r["skills"]:
		if (ev.get("skills", []) as Array).has(str(s)):
			has = true
	var action := "ignore"
	var say := ""
	if has and (d <= 14 or bool(c["on_duty_nearby"])):
		action = "help"
		say = "That's my line of work. On my way."
	elif int(c["home_tiles_away"]) <= int(ev.get("radius", 3)) + 2:
		if traits.has("brave") or traits.has("caring") or traits.has("civic-minded") or traits.has("hardworking") or traits.has("community organizer"):
			action = "help"
			say = "Come on, everyone grab a hand!"
		elif (traits.has("anxious") or traits.has("cautious") or traits.has("family-first")) and str(ev["type"]) in ["fire", "earthquake", "flood", "tornado", "smog", "power_line"]:
			action = "evacuate"
			say = "We're getting out of here."
		else:
			action = "report"
			say = "I'm calling the city about this."
	elif traits.has("outspoken"):
		action = "report"
	return {
		"action": action, "say": say, "mood": maxf(0.0, float(r["mood"]) - (1.0 if int(c["home_tiles_away"]) <= 6 else 0.3)),
		"thought": "The %s at (%d,%d)... %s" % [ev["label"], int(ev["x"]), int(ev["y"]), "I can actually fix this." if has else "I hope someone sorts it out fast."],
		"message_to_mayor": "Send crews to the %s at (%d,%d) now." % [ev["label"], int(ev["x"]), int(ev["y"])] if action == "report" else "",
	}


func to_dict() -> Dictionary:
	return {"stats": stats.duplicate(), "model_stats": model_stats.duplicate(true), "rot": _rot}


func from_dict(d: Dictionary) -> void:
	var s: Dictionary = d.get("stats", {})
	for k in s.keys():
		stats[k] = s[k]
	model_stats = d.get("model_stats", {})
	_rot = int(d.get("rot", 0))
	_plans_pending = 0
	_reacts_pending = 0
	_spread.clear()
