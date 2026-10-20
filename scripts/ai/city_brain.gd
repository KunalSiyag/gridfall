class_name CityBrain
extends Node
## Puts GMI model inference on every layer of the city. Each in-game day it batches:
##   - 5 AI mayors (different models) that read their district map and issue build/zone/tax actions
##   - Citizen Voices: sampled residents describe their lives; complaints feed back to mayors
##   - GridFall Gazette: a news editor writes the day's headline from real events
##   - Chaos Director: picks disasters that probe the city's weaknesses
##   - Grid Operator: sets load-shedding priority when power or water runs short
##   - Council Speaker: rules on ordinance proposals using the mayors' votes
## plus an on-demand Street Inspector that role-plays whatever tile the player clicks.
## Live calls fall back to the recorded replay cache, then to local heuristics.

signal mayor_thinking(mi: int)
signal mayor_decided(mi: int, decision: Dictionary)
signal citizens_spoke(voices: Array)
signal news_published(paper: Dictionary)
signal council_ruled(ruling: Dictionary)
signal chaos_decided(decision: Dictionary)
signal operator_decided(decision: Dictionary)
signal inspector_answered(report: Dictionary)
signal busy_changed(pending: int)

const D := preload("res://scripts/sim/sim_defs.gd")
const MayorTurns := preload("res://scripts/ai/mayor_turns.gd")
const BrainText := preload("res://scripts/ai/brain_text.gd")
const MAX_WAIT_MS := 75000

var sim: CitySim
var client: GmiClient
var wait_for_ai: bool = true
var mayor_state: Array[Dictionary] = []
var proposals: Dictionary = {}
var decree: String = ""
var decree_day: int = -1
var last_paper: Dictionary = {}
var last_voices: Array = []
var last_council: Dictionary = {}
var last_chaos: Dictionary = {}
var last_operator: Dictionary = {}
var chaos_last_day: int = -10
var day_feed: Array[String] = []
var complaints: Array[Dictionary] = []
var minds: ResidentMinds = null

var _mayor_in_flight: Array[bool] = [false, false, false, false, false]
var _support_in_flight: Dictionary = {}
var _wait_started_ms: int = 0
## Street mode sets this: the mayors take the day's turns one by one through the day (turns), so
## a player on foot sees decisions land every few minutes. Off (orbit, tests): all at dawn.
var stagger_mayors: bool = false
var turns: MayorTurns = MayorTurns.new()
## The day round's pieces still waiting for a frame, and the round's trace id and label.
var _queue: Array[Callable] = []
var _queue_trace: String = ""
var _queue_label: String = ""


func setup(p_sim: CitySim, p_client: GmiClient) -> void:
	sim = p_sim
	client = p_client
	mayor_state.clear()
	complaints.clear()
	for i in range(D.MAYORS.size()):
		mayor_state.append({"thoughts": [], "results": [], "post": "", "mood": "ready", "log": [], "source": "", "latency_ms": 0, "day": 0})
		complaints.append({})
	sim.day_gate = _day_gate
	proposals.clear()
	decree = ""
	last_paper = {}
	last_voices = []
	last_council = {}
	last_chaos = {}
	last_operator = {}
	chaos_last_day = -10
	day_feed.clear()
	_queue.clear()
	turns.clear()
	if sim.has_method("add_spread_source"):
		sim.add_spread_source(spread_pending, _finish_queue)
	if sim.day_started.is_connected(_on_day_started):
		return
	sim.day_started.connect(_on_day_started)
	sim.day_ended.connect(_on_day_ended)
	sim.event_started.connect(func(ev: Dictionary) -> void:
		day_feed.append("EVENT: %s at (%d,%d) %s" % [ev["label"], int(ev["x"]), int(ev["y"]), str(ev.get("reason", ""))])
	)
	sim.city_log.connect(func(line: String, category: String) -> void:
		if category in ["council", "deal", "player", "response", "disaster"]:
			day_feed.append(line)
	)


func pending_calls() -> int:
	var n := 0
	for b in _mayor_in_flight:
		if b:
			n += 1
	return n + _support_in_flight.size()


func mayors_pending() -> int:
	var n := 0
	for b in _mayor_in_flight:
		if b:
			n += 1
	return n


func _day_gate() -> bool:
	# A staggered mayor who was still deciding when the day ended takes the turn once free.
	for mi: int in turns.take_all(_mayor_in_flight):
		_run_turn(mi)
	var busy := mayors_pending() + (minds.pending() if minds != null else 0)
	if not wait_for_ai or busy == 0:
		_wait_started_ms = 0
		return true
	if _wait_started_ms == 0:
		_wait_started_ms = Time.get_ticks_msec()
	return Time.get_ticks_msec() - _wait_started_ms > MAX_WAIT_MS


func send_decree(text: String) -> void:
	decree = text.strip_edges().left(300)
	decree_day = sim.day
	sim.city_log.emit("Day %d: Player decree to all mayors: \"%s\"" % [sim.day, decree], "player")


## Starts the day round: the five mayors, then the support roles in order, each judging whether it
## is due when its turn comes. Inside the sim's sliced day job (sim.day_start_deferred()) the first
## mayor runs in the emission and the rest one per frame through sim.run_in_phase while
## spread_pending() holds the job, so the round lands where the synchronous path (step_tick,
## orbit, tests) runs it inline. Every piece runs under the round's trace id.
func _on_day_started(day: int) -> void:
	var pieces: Array[Callable] = []
	if not turns.start(day, stagger_mayors):
		for mi in range(D.MAYORS.size()):
			pieces.append(_mayor_piece.bind(mi, day))
	for role: String in ["citizens", "news", "chaos", "operator", "council"]:
		pieces.append(_support_piece.bind(role, day))
	var prev := [Trace.current(), Trace.current_label()]
	_queue_trace = Trace.begin("day %d" % day)
	_queue_label = Trace.current_label()
	(pieces.pop_front() as Callable).call()
	if sim.has_method("day_start_deferred") and sim.day_start_deferred():
		_queue.append_array(pieces)
	else:
		for p in pieces:
			p.call()
	Trace.set_current(prev[0], prev[1])
	busy_changed.emit(pending_calls())


## True while the day round still has pieces waiting for a frame (the sim's spread gate).
func spread_pending() -> bool:
	return not _queue.is_empty()


## Runs the round's waiting pieces now (the sim drains its spread sources before a save or skip).
func _finish_queue() -> void:
	while not _queue.is_empty():
		_run_piece(_queue.pop_front())


func _process(_delta: float) -> void:
	if not _queue.is_empty():
		_run_piece(_queue.pop_front())
		if _queue.is_empty():
			busy_changed.emit(pending_calls())
	if not turns.due.is_empty() and MayorTurns.sim_idle(sim):
		_run_turn(turns.take_due(sim.day_progress(), stagger_mayors, _mayor_in_flight))


## A staggered mayor turn under its own trace id; -1 (none due) or a mayor still deciding: nothing.
func _run_turn(mi: int) -> void:
	if mi < 0 or _mayor_in_flight[mi]:
		return
	var prev := [Trace.current(), Trace.current_label()]
	Trace.begin("day %d turn %s" % [turns.day, str(D.MAYORS[mi]["id"])])
	_run_mayor(mi, turns.day)
	Trace.set_current(prev[0], prev[1])


## One deferred piece under the round's trace id, as part of the sim's job phase.
func _run_piece(piece: Callable) -> void:
	var prev := [Trace.current(), Trace.current_label()]
	Trace.set_current(_queue_trace, _queue_label)
	if sim.has_method("run_in_phase"):
		sim.run_in_phase(piece)
	else:
		piece.call()
	Trace.set_current(prev[0], prev[1])


static func _three_votes(p: Dictionary) -> bool:
	return (p["votes"] as Dictionary).size() >= 3


func _mayor_piece(mi: int, day: int) -> void:
	if not _mayor_in_flight[mi]:
		_run_mayor(mi, day)


func _support_piece(role: String, day: int) -> void:
	if _support_due(role, day):
		var run := {
			"citizens": _run_citizens, "news": _run_news, "chaos": _run_chaos,
			"operator": _run_operator, "council": _run_council,
		}
		_run_support(role, day, run[role])


func _support_due(role: String, day: int) -> bool:
	var st := sim.stats
	match role:
		"citizens":
			return not sim.work_based()
		"news":
			return day >= 2
		"chaos":
			return day >= 4 and day - chaos_last_day >= 2
		"operator":
			var pcap := float(st.get("power_cap", 0.0))
			var wcap := float(st.get("water_cap", 0.0))
			var low_p := pcap > 0.0 and float(st.get("power_need", 0.0)) > pcap * 0.9
			var low_w := wcap > 0.0 and float(st.get("water_need", 0.0)) > wcap * 0.9
			return low_p or low_w or day % 5 == 0
		"council":
			var hot := proposals.values().any(_three_votes)
			return not proposals.is_empty() and (day % 3 == 0 or hot)
	return false


func _on_day_ended(_day: int) -> void:
	# Staggered turns still waiting run now, on their own day and before its calls are flushed.
	for mi: int in turns.take_all(_mayor_in_flight):
		_run_turn(mi)
	client.flush_cache()


func _run_support(role: String, day: int, fn: Callable) -> void:
	if _support_in_flight.has(role):
		return
	_support_in_flight[role] = true
	busy_changed.emit(pending_calls())
	await fn.call(day)
	_support_in_flight.erase(role)
	busy_changed.emit(pending_calls())


# ------------------------------------------------------------------ mayors

func _mayor_system_prompt(mi: int) -> String:
	var m: Dictionary = D.MAYORS[mi]
	var ord_keys := ", ".join(PackedStringArray(D.ORDINANCES.keys()))
	return "%s\n" % m["persona"] + """You are one of the five elected mayors of GridFall, a SimCity-style city. Each mayor controls ONLY their own district. Once per in-game day you return ONE JSON object of decisions.
RULES
- Zoned land grows buildings only when: a road is within 2 tiles, the tile is connected to power, and demand for that zone type is positive. Power flows from plants through roads and touching buildings. Water (pumps) is required for density 2+. High land value (parks, schools, low pollution, near the river) allows density 3.
- Power plants, water pumps and sewage plants serve the WHOLE connected city. coal_plant: 140 MW, $3000, heavy pollution. solar_farm: 45 MW, $1600, clean. water_pump: $900, 90 units (x1.5 within 2 tiles of the river), needs power. sewage_plant: $1300, 120 units, needs power; if city sewage capacity is short, pollution and unhappiness rise everywhere.
- Services cover a radius: police $750 (crime), fire_station $750 (fires spread less), hospital $1200 (health), school $950 (land value, commercial density), park $120 (land value, cuts pollution).
- Big projects: wind_farm $2200 (70 MW, clean, +25% near the river or map edge), landfill $1000 (160 waste capacity for the WHOLE city; without enough landfill, trash raises pollution and unhappiness once the city grows; it pollutes nearby), train_station $1800 (cuts traffic and raises land value within 8 tiles), university $3200 (strong education radius 11, +R and +C demand), stadium $4000 (happiness and land value radius 10, +C demand), airport $6000 (+0.15 C and I demand citywide, 30 jobs, noisy pollution, needs 8 MW).
- The people are AI residents with their own minds. They choose whether to go to work, how to commute, where to spend, whether to help fix what breaks, whether to protest, and whether to move away. Unhappy residents leave, which empties homes and shrinks your tax base. Incidents (fires, broken water mains, downed power lines, crashes...) stay broken until residents and paid crews put in enough repair work.
- Daily income = income tax on what your residents earned plus sales tax on what they spent in your shops, plus industry. Upkeep = buildings + roads + share of ordinances. Taxes above ~9% slow growth and anger residents. You cannot go below -$2000.
- Costs: road $10/tile ($50 on water), zone $5/tile, bulldoze $5/tile, emergency crews $300.
- Construction takes time. A build order opens a construction site (+ on the map, listed under under_construction) that your paid contractors work through in stages: clearing, excavation, foundation, frame, finishing. A building does nothing until it is finished: a park takes about 1 day, a police station about 3, a hospital about 4, a coal plant about 9, a stadium about 12, an airport about 15. Roads open after about a day, bridges after about 2.5 days. Private developers build zoned lots up the same way (houses about 2 days, towers about 6) and only run about 10 sites per district at once. Residents who are construction workers, electricians or engineers join nearby sites and finish them faster, but never more than about 1.6x. Plan ahead: order power and water before you need them. Bulldozing sends a demolition crew. Never order a building again while its site is still open.
- The city can grow: the founding city covers x,y 0..31 inside a wide frontier (x,y """ + "%d..%d" % [D.X0, D.X0 + D.W - 1] + """) of unclaimed woods, lakes and the river. You may annex an unclaimed 16x16 plot that borders your district (LAND YOU CAN ANNEX lists them with prices); the price rises with each plot you add. Land is cheap, so keep claiming plots ahead of demand: surveyors map the frontier further out as the city grows. New land is empty: it needs roads connected to the city, power and zoning before anyone lives there.
ACTIONS (max 7 per day). Coordinates are absolute world coordinates x,y and must be inside your district (except annex).
 {"type":"road","x":X,"y":Y,"x2":X2,"y2":Y2}  straight or L-shaped (horizontal leg first), max 16 tiles
 {"type":"zone","zone":"R|C|I","x":X,"y":Y,"w":W,"h":H}  rectangle up to 6x6 on empty or forest land, top-left corner at x,y
 {"type":"build","building":"coal_plant|solar_farm|wind_farm|water_pump|sewage_plant|landfill|police|fire_station|hospital|school|park|train_station|university|stadium|airport","x":X,"y":Y}
 {"type":"bulldoze","x":X,"y":Y,"w":1,"h":1}
 {"type":"set_tax","r":0-20,"c":0-20,"i":0-20}
 {"type":"emergency","x":X,"y":Y}  pay $300 for city crews who work on incidents within 4 tiles for a few hours (adds repair work, does not end them instantly)
 {"type":"grant","to":"argon|deepseek|kimi|qwen|grok","amount":N}
 {"type":"annex","x":X,"y":Y}  buy the unclaimed 16x16 plot containing x,y (it must border your district)
Ordinance keys: """ + ord_keys + """
Reply with ONLY this JSON object, no markdown:
{"thought":"your private reasoning, <=220 chars","public_post":"what you announce to citizens and other mayors, <=160 chars","mood":"one word","actions":[...],"propose_ordinance":"ordinance key or empty string","votes":{"ordinance_key":"yes or no"}}"""


func _mayor_user_prompt(mi: int, day: int) -> String:
	var m: Dictionary = D.MAYORS[mi]
	var b := sim.district_rect(mi)
	var ms: Dictionary = mayor_state[mi]
	var lines: Array[String] = []
	lines.append("DAY %d. You are %s, mayor of %s (district %d, x %d..%d, y %d..%d)." % [day, m["display"], m["district"], mi, b.position.x, b.end.x - 1, b.position.y, b.end.y - 1])
	lines.append("YOUR DISTRICT: " + JSON.stringify(sim.district_summary(mi)))
	lines.append("CITY: " + JSON.stringify(sim.city_summary()))
	lines.append("MAP OF YOUR DISTRICT (legend: %s):\n%s" % [D.MAP_LEGEND, sim.district_ascii(mi)])
	lines.append("OPEN LOTS NEXT TO ROADS [x,y]: " + JSON.stringify(sim.open_lots(mi, 14)))
	var plots: Array = sim.annexable_plots(mi)
	if not plots.is_empty():
		lines.append("LAND YOU CAN ANNEX (top-left x,y of each 16x16 plot, price, open/forest/water tiles): " + JSON.stringify(plots.slice(0, 5).map(func(p: Dictionary) -> String: return "(%d,%d) $%d %d/%d/%d" % [p["x"], p["y"], p["cost"], p["open_land"], p["forest"], p["water"]])))
	var res: Array = ms.get("results", [])
	if not res.is_empty():
		lines.append("YESTERDAY'S ACTION RESULTS: " + "; ".join(PackedStringArray(res)))
	var th: Array = ms.get("thoughts", [])
	if not th.is_empty():
		lines.append("YOUR RECENT THOUGHTS: " + " | ".join(PackedStringArray(th.slice(-2))))
	var others: Array[String] = []
	for oi in range(D.MAYORS.size()):
		if oi != mi and not str(mayor_state[oi].get("post", "")).is_empty():
			others.append("%s: %s" % [D.MAYORS[oi]["display"], mayor_state[oi]["post"]])
	if not others.is_empty():
		lines.append("OTHER MAYORS SAID: " + " || ".join(PackedStringArray(others)))
	var comp: Dictionary = complaints[mi]
	if not comp.is_empty():
		lines.append("CITIZEN COMPLAINTS IN YOUR DISTRICT (count): " + JSON.stringify(comp))
	if sim.work_based():
		lines.append("YOUR RESIDENTS (each named resident speaks for about %d people): %s" % [int(sim.people.share), JSON.stringify(sim.people.district_mood(mi))])
		for msg: Variant in sim.people.messages_for(mi, 6):
			var md: Dictionary = msg
			lines.append("RESIDENT %s (%s, mood %d/10) WRITES TO YOU: \"%s\"" % [md["name"], md["job"], int(md["mood"]), D.debrand(str(md["text"]))])
	else:
		for v: Variant in last_voices:
			var vd: Dictionary = v
			if int(vd.get("district", -1)) == mi:
				lines.append("A RESIDENT SAYS: \"%s\"" % D.debrand(str(vd.get("thought", ""))))
	if not last_paper.is_empty():
		lines.append("TODAY'S GAZETTE HEADLINE: " + str(last_paper.get("headline", "")))
	if not proposals.is_empty():
		var pl: Array[String] = []
		for key: String in proposals.keys():
			pl.append("%s (proposed by %s, votes %s)" % [key, proposals[key]["by"], JSON.stringify(_votes_by_name(proposals[key]["votes"]))])
		lines.append("PENDING ORDINANCE PROPOSALS (vote yes/no): " + "; ".join(PackedStringArray(pl)))
	lines.append("ACTIVE ORDINANCES: " + JSON.stringify(sim.ordinances.keys()))
	if not decree.is_empty() and sim.day - decree_day <= 1:
		lines.append("MESSAGE FROM THE CITY OVERSEER (the human player) - take it seriously: \"%s\"" % decree)
	lines.append("Decide today's actions now. Valid coordinates matter: rejected actions are wasted.")
	return "\n".join(lines)


func _run_mayor(mi: int, day: int) -> void:
	_mayor_in_flight[mi] = true
	mayor_thinking.emit(mi)
	busy_changed.emit(pending_calls())
	var m: Dictionary = D.MAYORS[mi]
	var res: Dictionary = await client.chat_json("mayor", str(m["id"]), str(m["model"]), _mayor_system_prompt(mi), _mayor_user_prompt(mi, day), day, 1500, 70.0, _heuristic_mayor.bind(mi))
	var data: Dictionary = res["data"]
	var results: Array[String] = []
	var applied: Array[Dictionary] = []
	var focus := D.NO_TILE
	var acts: Array = data.get("actions", []) if typeof(data.get("actions")) == TYPE_ARRAY else []
	acts = acts.slice(0, D.MAX_ACTIONS_PER_DAY)
	var topped_up: bool = str(res["source"]) != "cache"
	var k := -1
	while true:
		k += 1
		if k >= acts.size():
			if topped_up:
				break
			# Top up only after the replayed actions have spent their share of the treasury.
			topped_up = true
			acts.append_array(_replay_top_up(mi, acts))
			if k >= acts.size():
				break
		if typeof(acts[k]) != TYPE_DICTIONARY:
			continue
		var a: Dictionary = acts[k]
		var r: Dictionary = sim.apply_action(mi, a)
		var ok := bool(r.get("ok", false))
		results.append("%s %s: %s" % ["OK" if ok else "REJECTED", str(a.get("type", "?")), r.get("reason", "")])
		applied.append({"action": a, "ok": ok, "reason": r.get("reason", "")})
		if ok and focus == D.NO_TILE and a.has("x"):
			focus = Vector2i(int(r.get("x", a.get("x", -1))), int(r.get("y", a.get("y", -1))))
	var prop := str(data.get("propose_ordinance", "")).strip_edges().to_lower()
	var proposed := ""
	if D.ORDINANCES.has(prop) and not sim.ordinances.has(prop) and not proposals.has(prop):
		proposals[prop] = {"by": m["display"], "day": day, "votes": {str(m["id"]): "yes"}}
		proposed = prop
		day_feed.append("%s proposed the %s ordinance." % [m["display"], D.ORDINANCES[prop]["label"]])
	var cast := {}
	var votes: Variant = data.get("votes", {})
	if typeof(votes) == TYPE_DICTIONARY:
		for key: Variant in (votes as Dictionary).keys():
			var ks := str(key).to_lower()
			if proposals.has(ks):
				cast[ks] = str((votes as Dictionary)[key]).to_lower()
				(proposals[ks]["votes"] as Dictionary)[str(m["id"])] = cast[ks]
	var ms: Dictionary = mayor_state[mi]
	var thought := D.debrand(str(data.get("thought", ""))).left(260)
	var post := D.debrand(str(data.get("public_post", ""))).left(200)
	(ms["thoughts"] as Array).append("Day %d: %s" % [day, thought])
	if (ms["thoughts"] as Array).size() > 6:
		(ms["thoughts"] as Array).pop_front()
	ms["results"] = results
	ms["post"] = post
	ms["mood"] = str(data.get("mood", "focused")).left(20)
	ms["source"] = res["source"]
	ms["latency_ms"] = res["latency_ms"]
	ms["day"] = day
	var entry := {"day": day, "thought": thought, "post": post, "mood": ms["mood"], "actions": applied, "source": res["source"], "latency_ms": res["latency_ms"], "error": res.get("error", ""), "model": m["model"], "focus": focus, "proposal": proposed, "votes": cast}
	(ms["log"] as Array).append(entry)
	if (ms["log"] as Array).size() > 12:
		(ms["log"] as Array).pop_front()
	if not post.is_empty():
		day_feed.append("%s posted: %s" % [m["display"], post])
	_mayor_in_flight[mi] = false
	mayor_decided.emit(mi, entry)
	busy_changed.emit(pending_calls())


## Recorded replay answers predate wind farms, landfills, the big projects and annexation, so a
## replayed day borrows at most one of those builds and one annexation from the heuristic planner.
func _replay_top_up(mi: int, acts: Array) -> Array:
	const NEWER := ["wind_farm", "landfill", "train_station", "university", "stadium", "airport"]
	var has_newer := false
	var has_annex := false
	for a: Variant in acts:
		if typeof(a) == TYPE_DICTIONARY:
			has_newer = has_newer or str((a as Dictionary).get("building", "")) in NEWER
			has_annex = has_annex or str((a as Dictionary).get("type", "")) == "annex"
	# The replayed actions also spend money, so only borrow a build the district can comfortably afford.
	var treasury := int(sim.mayors[mi]["treasury"])
	var out: Array = []
	for a: Variant in _heuristic_mayor(mi).get("actions", []):
		var ad: Dictionary = a
		var key := str(ad.get("building", ""))
		if not has_newer and key in NEWER and treasury > int(D.BUILDINGS[key]["cost"]) + 3000:
			out.append(ad)
			has_newer = true
		elif not has_annex and str(ad.get("type", "")) == "annex":
			out.append(ad)
			has_annex = true
	return out


func _heuristic_mayor(mi: int) -> Dictionary:
	var m: Dictionary = sim.mayors[mi]
	var mid := str(m["id"])
	var b := sim.district_rect(mi)
	var funds := int(m["treasury"])
	var actions: Array = []
	var notes: Array[String] = []
	var have := {}
	var burning_tile := D.NO_TILE
	for y in range(b.position.y, b.end.y):
		for x in range(b.position.x, b.end.x):
			var i := D.idx(x, y)
			if sim.district[i] != mi:
				continue
			have[sim.kind[i]] = int(have.get(sim.kind[i], 0)) + 1
			if sim.burning[i] > 0:
				burning_tile = Vector2i(x, y)
	for s: Dictionary in sim.sites.values():
		if int(s["owner"]) == mi and str(s["type"]) == "build":
			have[int(s["target_kind"])] = int(have.get(int(s["target_kind"]), 0)) + 1
	if burning_tile != D.NO_TILE and funds > D.EMERGENCY_COST:
		actions.append({"type": "emergency", "x": burning_tile.x, "y": burning_tile.y})
		funds -= D.EMERGENCY_COST
		notes.append("fire crews first")
	var lots: Array = sim.open_lots(mi, 30)
	var lot_i := 0
	var pcap := float(sim.stats.get("power_cap", 0.0))
	var pneed := float(sim.stats.get("power_need", 0.0))
	var clean := mid in ["argon", "qwen", "kimi"]
	if pneed > pcap * 0.85 and not have.has(D.COAL) and not have.has(D.SOLAR) and not have.has(D.WIND) and lot_i < lots.size():
		var key := "coal_plant"
		if clean:
			key = "wind_farm" if funds >= int(D.BUILDINGS["wind_farm"]["cost"]) + 400 else "solar_farm"
		if funds >= int(D.BUILDINGS[key]["cost"]) + 400:
			actions.append({"type": "build", "building": key, "x": int(lots[lot_i][0]), "y": int(lots[lot_i][1])})
			funds -= int(D.BUILDINGS[key]["cost"])
			lot_i += 1
			notes.append("power is short, adding a %s" % key.replace("_", " "))
	var wcap := float(sim.stats.get("water_cap", 0.0))
	var wneed := float(sim.stats.get("water_need", 0.0))
	if (wcap <= 0.0 or wneed > wcap * 0.85) and not have.has(D.PUMP) and funds > 1300 and lot_i < lots.size():
		actions.append({"type": "build", "building": "water_pump", "x": int(lots[lot_i][0]), "y": int(lots[lot_i][1])})
		funds -= 900
		lot_i += 1
		notes.append("need water for density")
	var sneed := float(sim.stats.get("sewage_need", 0.0))
	var scap := float(sim.stats.get("sewage_cap", 0.0))
	if sneed > scap * 0.9 and int(m["pop"]) > 150 and not have.has(D.SEWAGE) and funds > 1700 and lot_i < lots.size():
		actions.append({"type": "build", "building": "sewage_plant", "x": int(lots[lot_i][0]), "y": int(lots[lot_i][1])})
		funds -= 1300
		lot_i += 1
		notes.append("sewage overflowing")
	var pop := int(m["pop"])
	if float(sim.stats.get("waste_ratio", 1.0)) < 0.9 and pop > 250 and not have.has(D.LANDFILL) and funds > 1600 and lot_i < lots.size():
		actions.append({"type": "build", "building": "landfill", "x": int(lots[lot_i][0]), "y": int(lots[lot_i][1])})
		funds -= int(D.BUILDINGS["landfill"]["cost"])
		lot_i += 1
		notes.append("trash is piling up, opening a landfill")
	var big := {"argon": ["university", "train_station"], "deepseek": ["train_station", "university"], "kimi": ["stadium", "train_station"], "qwen": ["train_station", "university"], "grok": ["airport", "stadium"]}
	if pop > 900 and lot_i < lots.size():
		for bk: String in big.get(mid, []):
			var bkind := int(D.BUILDINGS[bk]["kind"])
			if not have.has(bkind) and funds > int(D.BUILDINGS[bk]["cost"]) + 1500:
				actions.append({"type": "build", "building": bk, "x": int(lots[lot_i][0]), "y": int(lots[lot_i][1])})
				funds -= int(D.BUILDINGS[bk]["cost"])
				lot_i += 1
				notes.append("investing in a %s" % bk.replace("_", " "))
				break
	var services := [["police", 300], ["fire_station", 260], ["school", 450], ["hospital", 650]]
	for s: Array in services:
		var sk := str(s[0])
		if pop > int(s[1]) and not have.has(int(D.BUILDINGS[sk]["kind"])) and funds > int(D.BUILDINGS[sk]["cost"]) + 600 and lot_i < lots.size():
			actions.append({"type": "build", "building": sk, "x": int(lots[lot_i][0]), "y": int(lots[lot_i][1])})
			funds -= int(D.BUILDINGS[sk]["cost"])
			lot_i += 1
			notes.append("adding %s" % sk.replace("_", " "))
			break
	var dem := {"R": float(sim.demand["r"]), "C": float(sim.demand["c"]), "I": float(sim.demand["i"])}
	match mid:
		"grok":
			dem["I"] = float(dem["I"]) + 0.2
		"kimi":
			dem["C"] = float(dem["C"]) + 0.25
		"argon", "qwen":
			dem["R"] = float(dem["R"]) + 0.15
	var order: Array = dem.keys()
	order.sort_custom(func(a: String, c: String) -> bool: return float(dem[a]) > float(dem[c]))
	var zoned := 0
	while zoned < 3 and lot_i < lots.size() and funds > 200:
		var z := str(order[zoned % 2])
		actions.append({"type": "zone", "zone": z, "x": int(lots[lot_i][0]), "y": int(lots[lot_i][1]), "w": 2, "h": 2})
		lot_i += 2
		zoned += 1
		funds -= 20
	if zoned > 0:
		notes.append("zoning %s where demand is strongest" % str(order[0]))
	if lots.size() < 16:
		var plot := _best_annex(mi)
		if not plot.is_empty() and funds > int(plot["cost"]) + 2000:
			actions.append({"type": "annex", "x": int(plot["x"]), "y": int(plot["y"])})
			funds -= int(plot["cost"])
			notes.append("annexing new land to the %s" % _direction_of(mi, plot))
	if lots.size() - lot_i < 6 and funds > 300:
		var road := _plan_road(mi)
		if not road.is_empty():
			actions.append(road)
			notes.append("extending roads to open land")
	if pop > 120 and float(m["happiness"]) < 0.45 and funds > 400 and lot_i < lots.size():
		actions.append({"type": "build", "building": "park", "x": int(lots[lot_i][0]), "y": int(lots[lot_i][1])})
		notes.append("a park for unhappy residents")
	if int(m["treasury"]) < 1500:
		actions.append({"type": "set_tax", "r": mini(int(m["tax_r"]) + 1, 12), "c": mini(int(m["tax_c"]) + 1, 12), "i": mini(int(m["tax_i"]) + 1, 12)})
		notes.append("raising taxes to stay solvent")
	elif int(m["treasury"]) > 16000 and int(m["tax_r"]) > 7:
		actions.append({"type": "set_tax", "r": 7, "c": 8, "i": 8})
		notes.append("cutting taxes to boost growth")
	var flavor := {
		"argon": "Utilities before towers.", "deepseek": "Optimize the network graph.",
		"kimi": "Happy citizens build a strong center.", "qwen": "Spend only what pays back.",
		"grok": "Growth now, paperwork later.",
	}
	var proposal := ""
	if day_of_sim() % 6 == 0:
		var pick := {"argon": "recycling", "deepseek": "public_transit", "kimi": "free_clinics", "qwen": "water_conservation", "grok": "trade_expo"}
		proposal = str(pick.get(mid, ""))
	var votes := {}
	for key: String in proposals.keys():
		votes[key] = "no" if (mid == "grok" and key in ["clean_air_act", "curfew"]) else "yes"
	return {
		"thought": "%s %s." % [flavor.get(mid, ""), ", ".join(PackedStringArray(notes)) if not notes.is_empty() else "holding steady and saving funds"],
		"public_post": "District update: %s." % (notes[0] if not notes.is_empty() else "steady growth, budget balanced"),
		"mood": "steady", "actions": actions, "propose_ordinance": proposal, "votes": votes,
	}


func _best_annex(mi: int) -> Dictionary:
	var best: Dictionary = {}
	var best_score := -1
	for p: Dictionary in sim.annexable_plots(mi):
		var score := int(p["open_land"]) + int(p["forest"]) / 2
		if score > best_score:
			best_score = score
			best = p
	return best


func _direction_of(mi: int, plot: Dictionary) -> String:
	var b := sim.district_rect(mi)
	var c := Vector2(b.position) + Vector2(b.size) * 0.5
	var p := Vector2(int(plot["x"]) + 8, int(plot["y"]) + 8) - c
	if absf(p.x) > absf(p.y):
		return "east" if p.x > 0 else "west"
	return "south" if p.y > 0 else "north"


func day_of_sim() -> int:	return sim.day


func _plan_road(mi: int) -> Dictionary:
	var b := sim.district_rect(mi)
	for step in range(2, 16, 4):
		for horizontal in [true, false]:
			var line: Array[Vector2i] = []
			if horizontal:
				var y := b.position.y + step
				if y >= b.end.y:
					continue
				for x in range(b.position.x, b.end.x):
					line.append(Vector2i(x, y))
			else:
				var x2 := b.position.x + step
				if x2 >= b.end.x:
					continue
				for y2 in range(b.position.y, b.end.y):
					line.append(Vector2i(x2, y2))
			var seg: Array[Vector2i] = []
			for p in line:
				var i := D.idx(p.x, p.y)
				if sim.district[i] != mi:
					continue
				var k := sim.kind[i]
				if k == D.EMPTY or k == D.FOREST:
					seg.append(p)
				elif k != D.ROAD:
					break
			if seg.size() >= 3:
				var first: Vector2i = seg[0]
				var last: Vector2i = seg[mini(seg.size() - 1, 11)]
				if sim.road_dist[D.idx(first.x, first.y)] <= 1 or sim.road_dist[D.idx(last.x, last.y)] <= 1:
					return {"type": "road", "x": first.x, "y": first.y, "x2": last.x, "y2": last.y}
	return {}


# ------------------------------------------------------------------ citizens

func _run_citizens(day: int) -> void:
	var sample: Array = sim.sample_citizens(6)
	if sample.is_empty():
		return
	var agent: Dictionary = D.SUPPORT_AGENTS["citizens"]
	var sys := "You voice the ordinary residents of GridFall, a SimCity-style city run by five AI mayors. For each resident given, write what they are thinking today in first person, grounded ONLY in their actual conditions (power, water, pollution, crime, commute traffic, taxes, nearby services). Be specific, human, sometimes funny. Reply ONLY JSON: {\"voices\":[{\"id\":\"...\",\"thought\":\"<=110 chars\",\"mood\":\"happy|ok|upset|angry\",\"complaint\":\"power|water|pollution|crime|traffic|taxes|jobs|fire|health|none\"}]}"
	var user := "Day %d. City happiness %.2f, unemployment %.2f, demand %s.\nResidents: %s" % [day, float(sim.stats.get("happiness", 0)), float(sim.stats.get("unemployment", 0)), JSON.stringify(sim.city_summary()["demand"]), JSON.stringify(sample)]
	var res: Dictionary = await client.chat_json("citizens", "voices", str(agent["model"]), sys, user, day, 1200, 40.0, _heuristic_citizens.bind(sample))
	var voices_in: Array = res["data"].get("voices", []) if typeof(res["data"].get("voices")) == TYPE_ARRAY else []
	var by_id := {}
	for s: Variant in sample:
		by_id[str((s as Dictionary)["id"])] = s
	var out: Array = []
	for i in range(D.MAYORS.size()):
		complaints[i] = {}
	for v: Variant in voices_in:
		if typeof(v) != TYPE_DICTIONARY:
			continue
		var vd: Dictionary = v
		var src: Dictionary = by_id.get(str(vd.get("id", "")), {})
		if src.is_empty():
			continue
		var dist := sim.district[D.idx(int(src["x"]), int(src["y"]))]
		var entry := {"id": src["id"], "name": src["name"], "x": src["x"], "y": src["y"], "district": dist, "thought": str(vd.get("thought", "")).left(140), "mood": str(vd.get("mood", "ok")), "complaint": str(vd.get("complaint", "none")), "source": res["source"]}
		out.append(entry)
		var c := str(entry["complaint"])
		if c != "none":
			complaints[dist][c] = int(complaints[dist].get(c, 0)) + 1
	last_voices = out
	citizens_spoke.emit(out)


## With AI residents, the voices the mayors hear are the residents' own words from today's plans.
func residents_spoke(_day: int) -> void:
	var ppl: Residents = sim.people
	if ppl == null or not ppl.is_active():
		return
	for i in range(D.MAYORS.size()):
		complaints[i] = {}
	var ranked: Array = []
	for r in ppl.people:
		var d := sim.district[int(r["home"])]
		var c := str(r["complaint"])
		if c != "none":
			complaints[d][c] = int(complaints[d].get(c, 0)) + 1
		if not str(r["thought"]).is_empty():
			ranked.append([absf(float(r["mood"]) - 5.5) + (2.0 if not str(r["message"]).is_empty() else 0.0) + randf(), r])
	ranked.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) > float(b[0]))
	var out: Array = []
	for pair: Array in ranked.slice(0, 6):
		var r: Dictionary = pair[1]
		var h := int(r["home"])
		var m := float(r["mood"])
		out.append({
			"id": r["id"], "name": r["name"], "job": r["job_title"], "x": D.tx(h), "y": D.ty(h), "district": sim.district[h],
			"thought": str(r["thought"]).left(140), "mood": "happy" if m >= 7.0 else ("ok" if m >= 5.0 else ("upset" if m >= 3.0 else "angry")),
			"complaint": r["complaint"], "source": r["source"],
		})
	last_voices = out
	citizens_spoke.emit(out)

func _heuristic_citizens(sample: Array) -> Dictionary:
	var voices: Array = []
	for s: Variant in sample:
		var c: Dictionary = s
		var complaint := "none"
		var thought := "Honestly? Life in my block is pretty good right now."
		var mood := "happy"
		if not bool(c["has_power"]):
			complaint = "power"
			thought = "My lights have been out all day. Who do I even call?"
			mood = "angry"
		elif not bool(c["has_water"]):
			complaint = "water"
			thought = "No running water again. I'm brushing my teeth with soda."
			mood = "upset"
		elif float(c["pollution"]) > 0.5:
			complaint = "pollution"
			thought = "The air tastes like a factory. My kid keeps coughing."
			mood = "upset"
		elif float(c["crime"]) > 0.35:
			complaint = "crime"
			thought = "Third car break-in on my street this week. We need police."
			mood = "upset"
		elif float(c["commute_traffic"]) > 0.6:
			complaint = "traffic"
			thought = "Forty minutes to go six blocks. These roads can't keep up."
			mood = "ok"
		elif int(c["tax_rate"]) > 11:
			complaint = "taxes"
			thought = "Taxes went up again and the potholes stayed."
			mood = "ok"
		voices.append({"id": c["id"], "thought": thought, "mood": mood, "complaint": complaint})
	return {"voices": voices}


# ------------------------------------------------------------------ news

func _run_news(day: int) -> void:
	var agent: Dictionary = D.SUPPORT_AGENTS["news"]
	var feed := day_feed.slice(-14)
	day_feed.clear()
	var hist := sim.history.slice(-3)
	var mayors_line := ", ".join(PackedStringArray(D.MAYORS.map(func(mm: Dictionary) -> String: return "%s (%s)" % [mm["display"], mm["district"]])))
	var sys := "You are the editor of the GridFall Gazette, the newspaper of a SimCity-style city governed by five elected mayors: " + mayors_line + ". Write today's front page from the REAL events given. Be punchy, a little satirical, factual. Reply ONLY JSON: {\"headline\":\"<=90 chars\",\"stories\":[{\"title\":\"<=60 chars\",\"body\":\"<=200 chars\"}],\"editorial\":\"<=160 chars\"} with 2-3 stories."
	var user := "Day %d front page.\nRecent events and statements:\n%s\nCity trend (last days): %s\nCity now: %s" % [day, "\n".join(PackedStringArray(feed)) if not feed.is_empty() else "(quiet day)", JSON.stringify(hist), JSON.stringify(sim.city_summary())]
	var res: Dictionary = await client.chat_json("news", "gazette", str(agent["model"]), sys, user, day, 1000, 40.0, _heuristic_news.bind(feed))
	var paper: Dictionary = res["data"].duplicate(true)
	BrainText.debrand_paper(paper)
	paper["day"] = day
	paper["source"] = res["source"]
	last_paper = paper
	news_published.emit(paper)


func _heuristic_news(feed: Array) -> Dictionary:
	var pop := int(sim.stats.get("population", 0))
	var stories: Array = []
	for line: Variant in feed.slice(-3):
		stories.append({"title": "City Desk", "body": str(line).left(200)})
	return {
		"headline": "GridFall reaches %d residents as mayors jostle for growth" % pop,
		"stories": stories,
		"editorial": "Five mayors, one power grid. Somebody will have to share.",
	}


# ------------------------------------------------------------------ chaos director

func _run_chaos(day: int) -> void:
	var agent: Dictionary = D.SUPPORT_AGENTS["chaos"]
	var districts: Array = []
	for mi in range(D.MAYORS.size()):
		var s := sim.district_summary(mi)
		var b := sim.district_rect(mi)
		districts.append({"district": mi, "mayor": D.MAYORS[mi]["display"], "x_range": [b.position.x, b.end.x - 1], "y_range": [b.position.y, b.end.y - 1], "pop": s["pop"], "services": s["services"], "avg_traffic": s["avg_traffic"], "avg_pollution": s["avg_pollution"], "industrial_dev": s["counts"]["i_dev"], "residential_dev": s["counts"]["r_dev"]})
	var sys := "You are the Chaos Director of GridFall, a SimCity-style city run by five AI mayors. Your job is to keep the game dramatic but fair by choosing at most ONE disaster today that tests a real weakness: fire where there is no fire station, gridlock where traffic is high, blackout when the power margin is thin, sewage_burst when sewage is overloaded, smog near heavy industry, flood near the river (x 26..29), tornado or earthquake rarely. Skip days when the city is fragile or small. Reply ONLY JSON: {\"trigger\":true|false,\"type\":\"fire|blackout|sewage_burst|gridlock|smog|earthquake|flood|tornado\",\"x\":X,\"y\":Y,\"reason\":\"<=140 chars, why this tests the city\",\"narration\":\"<=140 chars dramatic announcement\"}"
	var area := sim.owned_rect()
	sys += " X and Y must lie inside the claimed city: x %d..%d, y %d..%d." % [area.position.x, area.end.x - 1, area.position.y, area.end.y - 1]
	var user := "Day %d. Days since your last disaster: %d. City: %s\nDistricts: %s" % [day, day - chaos_last_day, JSON.stringify(sim.city_summary()), JSON.stringify(districts)]
	var res: Dictionary = await client.chat_json("chaos", "director", str(agent["model"]), sys, user, day, 1200, 45.0, _heuristic_chaos)
	var data: Dictionary = res["data"]
	var decision := {"day": day, "trigger": bool(data.get("trigger", false)), "type": str(data.get("type", "")), "reason": str(data.get("reason", "")).left(160), "narration": str(data.get("narration", "")).left(160), "source": res["source"]}
	if decision["trigger"] and D.DISASTERS.has(decision["type"]) and int(sim.stats.get("population", 0)) > 80:
		var ev := sim.trigger_disaster(str(decision["type"]), int(data.get("x", 16)), int(data.get("y", 16)), "Chaos Director", str(decision["reason"]))
		decision["x"] = ev.get("x", 0)
		decision["y"] = ev.get("y", 0)
		chaos_last_day = day
	else:
		decision["trigger"] = false
	last_chaos = decision
	chaos_decided.emit(decision)


func _heuristic_chaos() -> Dictionary:
	if sim.rng.randf() > 0.35:
		return {"trigger": false, "reason": "The city needs a breather.", "narration": "A calm day in GridFall."}
	var types := ["fire", "gridlock", "smog", "sewage_burst", "blackout"]
	var t: String = types[sim.rng.randi_range(0, types.size() - 1)]
	var spots: Array[int] = []
	for i in sim.active:
		if D.is_zone(sim.kind[i]) and sim.level[i] > 0:
			spots.append(i)
	if spots.is_empty():
		return {"trigger": false, "reason": "Nothing worth breaking yet.", "narration": ""}
	var s: int = spots[sim.rng.randi_range(0, spots.size() - 1)]
	return {"trigger": true, "type": t, "x": D.tx(s), "y": D.ty(s), "reason": "Random stress test.", "narration": "Trouble strikes GridFall!"}


# ------------------------------------------------------------------ grid operator

func _run_operator(day: int) -> void:
	var agent: Dictionary = D.SUPPORT_AGENTS["operator"]
	var per: Array = []
	for mi in range(D.MAYORS.size()):
		var s := sim.district_summary(mi)
		per.append({"district": mi, "mayor": D.MAYORS[mi]["display"], "pop": s["pop"], "jobs": s["jobs"], "unpowered": s["counts"]["unpowered"], "unwatered": s["counts"]["unwatered"], "services": s["services"]})
	var where := ["NW", "NE", "center", "SW", "SE"]
	var dl := ", ".join(PackedStringArray(range(D.MAYORS.size()).map(func(k: int) -> String: return "%d %s %s" % [k, D.MAYORS[k]["display"], where[k]])))
	var sys := "You are the GridFall Grid Operator, an AI that runs the shared power and water network of a SimCity-style city with five AI-run districts (" + dl + "). When supply is short, load is shed from the LAST district in your priority list first. Prioritize hospitals, fire coverage, dense housing and fairness. Reply ONLY JSON: {\"priority\":[5 distinct district indices],\"note\":\"<=160 chars explaining the order\",\"advice\":\"<=140 chars capacity advice to the mayors\"}"
	var user := "Day %d. Power %s. Water %s. Sewage %s. Current priority %s. Districts: %s" % [day, sim.city_summary()["power"], sim.city_summary()["water"], sim.city_summary()["sewage"], JSON.stringify(sim.grid_priority), JSON.stringify(per)]
	var res: Dictionary = await client.chat_json("operator", "grid", str(agent["model"]), sys, user, day, 800, 35.0, _heuristic_operator)
	var data: Dictionary = res["data"]
	var pr: Array = []
	if typeof(data.get("priority")) == TYPE_ARRAY:
		for v: Variant in data["priority"]:
			var d := int(v)
			if d >= 0 and d < 5 and not pr.has(d):
				pr.append(d)
	for d in range(5):
		if not pr.has(d):
			pr.append(d)
	sim.grid_priority = pr
	var decision := {"day": day, "priority": pr, "note": str(data.get("note", "")).left(180), "advice": str(data.get("advice", "")).left(160), "source": res["source"]}
	last_operator = decision
	day_feed.append("Grid Operator set priority %s: %s" % [JSON.stringify(pr), decision["note"]])
	operator_decided.emit(decision)


func _heuristic_operator() -> Dictionary:
	var order: Array = [0, 1, 2, 3, 4]
	order.sort_custom(func(a: int, b: int) -> bool: return int(sim.mayors[a]["pop"]) > int(sim.mayors[b]["pop"]))
	return {"priority": order, "note": "Most populated districts keep power first.", "advice": "Build more generation before zoning more."}


# ------------------------------------------------------------------ council

func _run_council(day: int) -> void:
	var agent: Dictionary = D.SUPPORT_AGENTS["council"]
	var plist: Array = []
	for key: String in proposals.keys():
		plist.append({"key": key, "label": D.ORDINANCES[key]["label"], "effect": D.ORDINANCES[key]["desc"], "daily_cost": D.ORDINANCES[key]["cost"], "proposed_by": proposals[key]["by"], "votes": _votes_by_name(proposals[key]["votes"])})
	var active: Array = []
	for key: String in sim.ordinances.keys():
		active.append({"key": key, "label": D.ORDINANCES[key]["label"], "since_day": sim.ordinances[key]})
	var sys := "You are the Speaker of the GridFall City Council. Five elected mayors vote on ordinances; you rule on each proposal. Majority (3+ yes of 5) normally passes; with only 2 yes you may pass it only if city data strongly supports it. You may also repeal one active ordinance that no longer pays off. Reply ONLY JSON: {\"enact\":[keys],\"repeal\":[keys],\"statement\":\"<=220 chars ruling explained to citizens\"}"
	var user := "Day %d. Proposals: %s\nActive: %s\nCity: %s" % [day, JSON.stringify(plist), JSON.stringify(active), JSON.stringify(sim.city_summary())]
	var res: Dictionary = await client.chat_json("council", "speaker", str(agent["model"]), sys, user, day, 900, 40.0, _heuristic_council)
	var data: Dictionary = res["data"]
	var enacted: Array = []
	var repealed: Array = []
	if typeof(data.get("enact")) == TYPE_ARRAY:
		for k: Variant in data["enact"]:
			var ks := str(k)
			if proposals.has(ks) and _yes_votes(ks) >= 2 and sim.enact_ordinance(ks):
				enacted.append(ks)
	if typeof(data.get("repeal")) == TYPE_ARRAY:
		for k: Variant in data["repeal"]:
			if sim.repeal_ordinance(str(k)):
				repealed.append(str(k))
	var rejected: Array = []
	for key: String in proposals.keys():
		if not enacted.has(key) and (proposals[key]["votes"] as Dictionary).size() >= 4:
			rejected.append(key)
	for key in enacted + rejected:
		proposals.erase(key)
	var ruling := {"day": day, "enacted": enacted, "repealed": repealed, "rejected": rejected, "statement": D.debrand(str(data.get("statement", ""))).left(240), "source": res["source"]}
	last_council = ruling
	council_ruled.emit(ruling)


## A proposal's votes keyed by mayor display name instead of mayor id, for prompts: the ids are the
## lowercase brand words (argon, deepseek ...), which D.debrand does not catch.
func _votes_by_name(votes: Variant) -> Dictionary:
	var out := {}
	if typeof(votes) != TYPE_DICTIONARY:
		return out
	for key: Variant in (votes as Dictionary).keys():
		var who := str(key)
		for m: Dictionary in D.MAYORS:
			if str(m["id"]) == who:
				who = str(m["display"])
				break
		out[who] = (votes as Dictionary)[key]
	return out


func _yes_votes(key: String) -> int:
	var n := 0
	for v: Variant in (proposals[key]["votes"] as Dictionary).values():
		if str(v).begins_with("y"):
			n += 1
	return n


func _heuristic_council() -> Dictionary:
	var enact: Array = []
	for key: String in proposals.keys():
		if _yes_votes(key) >= 3:
			enact.append(key)
	return {"enact": enact, "repeal": [], "statement": "The council follows the majority of mayors." if not enact.is_empty() else "No proposal reached a majority today."}


# ------------------------------------------------------------------ inspector (on demand)

func inspect_tile(x: int, y: int) -> void:
	var rep := sim.tile_report(x, y)
	if rep.is_empty():
		return
	var agent: Dictionary = D.SUPPORT_AGENTS["inspector"]
	var who := "a city surveyor standing on this empty lot"
	var kname := str(rep["kind"])
	match kname:
		"residential":
			who = "a resident who lives in this building"
		"commercial":
			who = "the owner of a shop in this building"
		"industrial":
			who = "the foreman of the factory here"
		"road":
			who = "a driver currently stuck on this road"
		"river":
			who = "a fisherman on the river"
		"forest":
			who = "a park ranger in this patch of forest"
		"rubble":
			who = "a construction worker clearing this rubble"
		_:
			if kname != "empty":
				who = "a staff member working at this %s" % kname
	if not (rep.get("construction", {}) as Dictionary).is_empty():
		who = "the site foreman on this construction site (the %s being built)" % str(rep["construction"]["building"]).to_lower()
	var sys := "You are the GridFall Street Inspector. Role-play %s in a SimCity-style city run by five elected mayors. Speak in first person about your real situation using ONLY the data given, then give a short expert diagnosis and one concrete suggestion for the district mayor. Reply ONLY JSON: {\"speaker\":\"short role name\",\"says\":\"<=220 chars\",\"diagnosis\":\"<=160 chars\",\"suggestion\":\"<=120 chars\"}" % who
	var nearby_events: Array = []
	for ev in sim.events:
		if absi(int(ev["x"]) - x) + absi(int(ev["y"]) - y) <= 6:
			nearby_events.append(ev["label"])
	var user := "Day %d. Tile data: %s\nNearby events: %s\nDistrict mayor's latest post: %s" % [sim.day, JSON.stringify(rep), JSON.stringify(nearby_events), D.debrand(str(mayor_state[int(rep["district_index"])].get("post", "")))]
	inspector_answered.emit({"x": x, "y": y, "pending": true, "report": rep})
	var res: Dictionary = await client.chat_json("inspector", "street", str(agent["model"]), sys, user, sim.day, 700, 30.0, _heuristic_inspect.bind(rep))
	var out: Dictionary = res["data"].duplicate()
	out["x"] = x
	out["y"] = y
	out["report"] = rep
	out["source"] = res["source"]
	out["latency_ms"] = res["latency_ms"]
	out["pending"] = false
	inspector_answered.emit(out)


func _heuristic_inspect(rep: Dictionary) -> Dictionary:
	var issues: Array[String] = []
	if not bool(rep["powered"]):
		issues.append("no power")
	if not bool(rep["watered"]) and int(rep["density"]) > 0:
		issues.append("no water")
	if float(rep["pollution"]) > 0.4:
		issues.append("heavy pollution")
	if float(rep["crime"]) > 0.3:
		issues.append("crime")
	if not bool(rep["road_access"]):
		issues.append("no road access")
	var diag := "Conditions look healthy." if issues.is_empty() else "Problems: " + ", ".join(PackedStringArray(issues)) + "."
	return {"speaker": str(rep["kind"]).capitalize(), "says": "This is a %s at (%d,%d). %s" % [rep["kind"], int(rep["x"]), int(rep["y"]), diag], "diagnosis": diag, "suggestion": "Connect power and water, then add parks and services nearby."}


# ------------------------------------------------------------------ save / load

func to_dict() -> Dictionary:
	_finish_queue()
	return {
		"mayor_state": mayor_state.duplicate(true), "proposals": proposals.duplicate(true), "decree": decree,
		"decree_day": decree_day, "last_paper": last_paper, "last_voices": last_voices, "last_council": last_council,
		"last_chaos": last_chaos, "last_operator": last_operator, "chaos_last_day": chaos_last_day,
		"complaints": complaints.duplicate(true), "client": client.to_dict(),
		"turns": turns.to_dict(),
	}


func from_dict(d: Dictionary) -> void:
	_queue.clear()
	mayor_state.clear()
	for ms: Variant in d.get("mayor_state", []):
		mayor_state.append(ms as Dictionary)
	while mayor_state.size() < D.MAYORS.size():
		mayor_state.append({"thoughts": [], "results": [], "post": "", "mood": "ready", "log": [], "source": "", "latency_ms": 0, "day": 0})
	proposals = d.get("proposals", {})
	decree = str(d.get("decree", ""))
	decree_day = int(d.get("decree_day", -1))
	last_paper = d.get("last_paper", {})
	last_voices = d.get("last_voices", [])
	last_council = d.get("last_council", {})
	last_chaos = d.get("last_chaos", {})
	last_operator = d.get("last_operator", {})
	chaos_last_day = int(d.get("chaos_last_day", -10))
	complaints.clear()
	for c: Variant in d.get("complaints", []):
		complaints.append(c as Dictionary)
	while complaints.size() < D.MAYORS.size():
		complaints.append({})
	turns.from_dict(d.get("turns", {}))
	client.from_dict(d.get("client", {}))
	BrainText.debrand_state(proposals, mayor_state, last_paper, last_council)
