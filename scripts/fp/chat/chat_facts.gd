extends RefCounted
## What is really going on in the city, for chat answers (slice C): what the district's mayor did
## on their last turn in spoken words, their latest post, the Gazette headline, the council's last
## ruling, incidents and sites being built, and the district's numbers. Names only, never
## coordinates. The live player-reply and talk prompts carry it as "city_facts"; the offline
## voices quote it. No nodes.

const D := preload("res://scripts/sim/sim_defs.gd")
const T := preload("res://scripts/fp/chat/chat_text.gd")
const LINE_CHARS := 140
const MAX_DID := 2
const MAX_LIST := 3
const ZONE_NOUNS := {
	"R": ["home", "homes"], "C": ["shop lot", "shop lots"], "I": ["factory lot", "factory lots"]
}
## How each mayor (by D.MAYORS index) signs off an offline reply.
const SIGN_OFF := [
	"Power and water come first.",
	"I'm watching the numbers.",
	"Come by City Hall and tell me more.",
	"Every dollar has to earn its keep.",
	"Bigger and faster, that's the plan.",
]
## A mayor's answer about one of the district's numbers, by intent: [numbers key, the value from
## which it is bad news, the line while it is fine, the line once it is not]. {where} is the
## district, {n} the value.
const NUMBER_ANSWERS := {
	"power":
	[
		"buildings_without_power",
		1.0,
		"Power is holding across {where}.",
		"{n} buildings are dark in {where}, and fixing that is my job.",
	],
	"water":
	[
		"buildings_without_water",
		1.0,
		"Water is running everywhere in {where}.",
		"{n} buildings have dry taps, and the crews know.",
	],
	"jobs":
	[
		"out_of_work",
		1.0,
		"Pretty much everyone in {where} has a job.",
		"{n} people here are looking for work. More jobs are coming.",
	],
	"traffic":
	[
		"traffic_out_of_10",
		5.0,
		"Traffic is moving in {where} today.",
		"Traffic is bad, I know. Better roads are on my list.",
	],
	"crime":
	[
		"crime_out_of_10",
		3.0,
		"The streets of {where} are safe.",
		"Crime is up, and I'm asking for more patrols.",
	],
}
## A resident's complaint key as people say it.
const COMPLAINT_NOUNS := {
	"power": "the power cuts",
	"water": "the water",
	"sewage": "the drains",
	"trash": "the trash",
	"pollution": "the air",
	"crime": "the break-ins",
	"traffic": "the traffic",
	"taxes": "taxes",
	"rent": "rent",
	"jobs": "jobs",
	"health": "the clinic waits",
	"noise": "the building noise",
	"incident": "the mess nobody cleans up",
}


## The facts for district d (-1: the city as a whole): district, mayor, mayor_did ("zoned 6
## homes near Elm Street and ordered a fire station"), mayor_when ("today", "yesterday",
## "recently" or ""), mayor_post, gazette, council ("passed the Youth Curfew"), incidents and
## building (up to 3 each, "building fire at Elm Street"), numbers ({} outside the districts) and
## complaints (the top 2 complaint keys).
static func build(
	sim: CitySim, brain: CityBrain, people: Residents, dir: CityDirectory, d: int
) -> Dictionary:
	var has_d := sim != null and d >= 0 and d < D.MAYORS.size() and d < sim.mayors.size()
	var out := {
		"district": str(D.MAYORS[d]["district"]) if has_d else "the city",
		"mayor": D.mayor_display(d) if has_d else "",
		"mayor_did": "",
		"mayor_when": "",
		"mayor_post": "",
		"gazette": "",
		"council": "",
		"incidents": [],
		"building": [],
		"numbers": {},
		"complaints": [],
	}
	if sim == null or dir == null:
		return out
	if brain != null:
		if has_d and d < brain.mayor_state.size():
			var ms: Dictionary = brain.mayor_state[d]
			out["mayor_post"] = T.display(str(ms.get("post", "")), dir)
			var turns: Array = ms.get("log", []) if typeof(ms.get("log")) == TYPE_ARRAY else []
			if not turns.is_empty() and typeof(turns[-1]) == TYPE_DICTIONARY:
				var e: Dictionary = turns[-1]
				out["mayor_did"] = did_words(e.get("actions", []), dir)
				out["mayor_when"] = _when(sim.day, int(e.get("day", sim.day)))
		out["gazette"] = T.display(str(brain.last_paper.get("headline", "")), dir)
		out["council"] = council_words(brain.last_council)
	out["incidents"] = _incidents(sim, dir, d)
	out["building"] = _sites(sim, dir, d)
	if has_d:
		out["numbers"] = _numbers(sim, people, d)
		if people != null:
			out["complaints"] = _top_complaints(people.district_mood(d))
	return out


## Mayor index named in text: the last name, "mayor" and the first name, or the first name alone
## when no resident shares it (Rosa does); a bare "mayor" or "mayors" means the mayor of district
## (when there is one). -1 when none.
static func mayor_named(text: String, district: int) -> int:
	var low := " " + T.normalise(text) + " "
	for k in range(D.MAYORS.size()):
		var display := str(D.MAYORS[k]["display"])
		var first := T.normalise(display.get_slice(" ", 0))
		var last := T.normalise(display.get_slice(" ", 1))
		var alone := not Residents.FIRST_NAMES.has(display.get_slice(" ", 0))
		if low.contains(" %s " % last) or low.contains(" mayor %s " % first):
			return k
		if alone and low.contains(" %s " % first):
			return k
	if low.contains(" mayor ") or low.contains(" mayors "):
		return district if district >= 0 and district < D.MAYORS.size() else -1
	return -1


## A mayor's turn in spoken words, lower case, from CityBrain's applied list ([{"action", "ok"}]):
## the first MAX_DID orders that went through, joined by "and". "" when none did.
static func did_words(applied: Variant, dir: CityDirectory) -> String:
	var parts: Array[String] = []
	if typeof(applied) != TYPE_ARRAY:
		return ""
	for v: Variant in applied:
		if typeof(v) != TYPE_DICTIONARY or not bool((v as Dictionary).get("ok", false)):
			continue
		var p := order_words((v as Dictionary).get("action", {}), dir)
		if not p.is_empty() and not parts.has(p):
			parts.append(p)
		if parts.size() >= MAX_DID:
			break
	return " and ".join(PackedStringArray(parts))


## One mayor order in spoken words ({"type": "build", "building": "fire_station", "x", "y"} ->
## "ordered a fire station near Elm Street"), or "" for an unknown one.
static func order_words(a: Variant, dir: CityDirectory) -> String:
	if typeof(a) != TYPE_DICTIONARY:
		return ""
	var o: Dictionary = a
	var x := int(o.get("x", -1))
	var y := int(o.get("y", -1))
	var place := dir.place_label(D.idx(x, y)) if dir != null and D.in_bounds(x, y) else ""
	var near := (" near " + place) if not place.is_empty() else ""
	var out := ""
	match str(o.get("type", "")).to_lower():
		"zone":
			var z := str(o.get("zone", "R")).to_upper().left(1)
			var nouns: Array = ZONE_NOUNS.get(z, ["lot", "lots"])
			var side := D.MAX_ZONE_SIDE
			var n := clampi(int(o.get("w", 1)), 1, side) * clampi(int(o.get("h", 1)), 1, side)
			out = "zoned %d %s%s" % [n, nouns[0] if n == 1 else nouns[1], near]
		"build":
			var key := str(o.get("building", "")).to_lower()
			var label := str((D.BUILDINGS.get(key, {}) as Dictionary).get("label", "new building"))
			out = "ordered %s%s" % [_a(label.to_lower()), near]
		"road":
			out = "laid a new road" + near
		"bulldoze":
			out = "cleared old lots" + near
		"set_tax", "tax":
			out = "set home taxes to %d percent" % int(o.get("r", 0))
		"emergency":
			out = "sent emergency crews" + ((" to " + place) if not place.is_empty() else "")
		"grant":
			var to := D.mayor_display(D.mayor_index(str(o.get("to", ""))))
			out = ("sent money to " + to) if not to.is_empty() else "made a grant"
		"annex":
			out = "annexed new land"
	return out


## What a council ruling changed, lower case ("passed the Youth Curfew"), or "".
static func council_words(r: Dictionary) -> String:
	for pair: Array in [["enacted", "passed"], ["repealed", "repealed"]]:
		var arr: Variant = r.get(pair[0], [])
		if typeof(arr) != TYPE_ARRAY or (arr as Array).is_empty():
			continue
		var o: Dictionary = D.ORDINANCES.get(str((arr as Array)[0]), {})
		if not o.is_empty():
			return "%s the %s" % [pair[1], str(o["label"])]
	return ""


## Mayor mi's offline answer to the visitor: first person, at most 2 sentences and LINE_CHARS.
## It answers the line's intent (ChatterMinds.intent_of) from facts f (build() for the mayor's
## district) and says what the mayor did last; with nothing specific to answer it follows the
## turn with the mayor's latest one-sentence post or their sign-off.
static func mayor_reply(
	mi: int, intent: String, f: Dictionary, rng: RandomNumberGenerator
) -> String:
	var did := str(f.get("mayor_did", ""))
	var turn := "My next orders go out soon."
	if not did.is_empty():
		turn = "%s I %s." % [T.cap(str(f.get("mayor_when", "recently"))), did]
	var close: String = SIGN_OFF[mi] if mi >= 0 and mi < SIGN_OFF.size() else ""
	var post := str(f.get("mayor_post", ""))
	if not post.is_empty() and T.sentence_count(post) == 1 and rng.randf() < 0.5:
		close = T.clip(post, 90)
	var parts: Array[String] = []
	var answer := _mayor_answer(intent, f)
	if not answer.is_empty():
		parts.append(answer)
	parts.append(turn)
	parts.append(close)
	return _fit(parts, LINE_CHARS)


## A resident's line about one fact in f. about picks it: "incident", "mayor" (their last turn),
## "building", "gazette", "council" or "complaint", "" when f has none of that; an empty about
## picks the most pressing fact (in that order, half the time the first). "" when nothing stands
## out.
static func city_line(f: Dictionary, rng: RandomNumberGenerator, about: String = "") -> String:
	var opts := {}
	var inc: Array = f.get("incidents", [])
	if not inc.is_empty():
		opts["incident"] = "There's %s right now." % _a(str(inc[0]))
	var did := str(f.get("mayor_did", ""))
	var mayor := str(f.get("mayor", ""))
	if not did.is_empty() and not mayor.is_empty():
		var when := str(f.get("mayor_when", "recently"))
		opts["mayor"] = "Mayor %s %s %s." % [mayor.get_slice(" ", 1), did, when]
	var sites: Array = f.get("building", [])
	if not sites.is_empty():
		opts["building"] = "They're putting up %s." % str(sites[0])
	var hl := str(f.get("gazette", ""))
	if not hl.is_empty():
		opts["gazette"] = 'The Gazette says "%s".' % T.clip(hl, 60)
	var ruling := str(f.get("council", ""))
	if not ruling.is_empty():
		opts["council"] = "The council just %s." % ruling
	var cs: Array = f.get("complaints", [])
	if not cs.is_empty() and COMPLAINT_NOUNS.has(str(cs[0])):
		var noun := str(COMPLAINT_NOUNS[str(cs[0])])
		opts["complaint"] = "Everyone here keeps talking about %s." % noun
	if not about.is_empty() or opts.is_empty():
		return str(opts.get(about, ""))
	var keys: Array = opts.keys()
	var k: Variant = keys[0] if rng.randf() < 0.5 else keys[rng.randi_range(0, keys.size() - 1)]
	return str(opts[k])


## f without its empty fields (the "city_facts" block of a prompt).
static func compact(f: Dictionary) -> Dictionary:
	var out := {}
	for k: Variant in f.keys():
		var v: Variant = f[k]
		var empty := false
		match typeof(v):
			TYPE_STRING:
				empty = str(v).is_empty()
			TYPE_ARRAY:
				empty = (v as Array).is_empty()
			TYPE_DICTIONARY:
				empty = (v as Dictionary).is_empty()
		if not empty:
			out[k] = v
	return out


# ---------------------------------------------------------------- internals


static func _mayor_answer(intent: String, f: Dictionary) -> String:
	var n: Dictionary = f.get("numbers", {})
	var where := str(f.get("district", "the district"))
	var out := ""
	if NUMBER_ANSWERS.has(intent):
		var spec: Array = NUMBER_ANSWERS[intent]
		var v := float(n.get(spec[0], 0.0))
		out = str(spec[3] if v >= float(spec[1]) else spec[2])
		return out.format({"where": where, "n": int(v)})
	match intent:
		"greet":
			out = "Hello, and welcome to %s!" % where
		"bye":
			out = "Take care out there."
		"how":
			out = "Busy, but people here seem happy."
			if float(n.get("approval_out_of_10", 5.0)) < 5.0:
				out = "People are angry, and I hear them."
		"money":
			var tax := int(n.get("home_tax_percent", 9))
			out = "Home taxes are %d percent here, and they pay for the crews." % tax
		"incident", "around":
			var inc: Array = f.get("incidents", [])
			out = "No incidents in %s right now." % where
			if not inc.is_empty():
				out = "Crews are on the %s." % str(inc[0])
		"news":
			var hl := str(f.get("gazette", ""))
			if not hl.is_empty():
				out = 'The Gazette says "%s". Read it with care.' % T.clip(hl, 60)
	return out


static func _numbers(sim: CitySim, people: Residents, d: int) -> Dictionary:
	var s := sim.district_summary(d)
	var c: Dictionary = s.get("counts", {})
	var out := {
		"people": int(s.get("pop", 0)),
		"jobs": int(s.get("jobs", 0)),
		"buildings_without_power": int(c.get("unpowered", 0)),
		"buildings_without_water": int(c.get("unwatered", 0)),
		"buildings_on_fire": int(c.get("burning", 0)),
		"home_tax_percent": int((s.get("tax", {}) as Dictionary).get("r", 9)),
		"traffic_out_of_10": snappedf(float(s.get("avg_traffic", 0.0)) * 10.0, 0.5),
		"crime_out_of_10": snappedf(float(s.get("avg_crime", 0.0)) * 10.0, 0.5),
	}
	if people != null:
		var dm := people.district_mood(d)
		out["out_of_work"] = int(dm.get("unemployed", 0))
		out["mood_out_of_10"] = float(dm.get("avg_mood", 5.0))
		out["approval_out_of_10"] = float(dm.get("approval", 5.0))
	return out


static func _incidents(sim: CitySim, dir: CityDirectory, d: int) -> Array:
	var out: Array = []
	for ev: Dictionary in sim.events:
		var x := int(ev.get("x", -1))
		var y := int(ev.get("y", -1))
		if not D.in_bounds(x, y) or (d >= 0 and sim.district[D.idx(x, y)] != d):
			continue
		var what := str(ev.get("label", "trouble")).to_lower()
		out.append("%s at %s" % [what, dir.place_label(D.idx(x, y))])
		if out.size() >= MAX_LIST:
			break
	return out


## Sites going up in district d: services first ("a new fire station at Oak Avenue"), then
## zone sites ("new houses at Elm Street"). Roads are left out.
static func _sites(sim: CitySim, dir: CityDirectory, d: int) -> Array:
	var out: Array = []
	for pass_type: String in ["build", "zone"]:
		for s: Dictionary in sim.sites.values():
			if str(s.get("type", "")) != pass_type or (d >= 0 and int(s.get("owner", -1)) != d):
				continue
			var label := "new " + str(s.get("label", "building")).to_lower()
			var what := label if label.ends_with("s") else _a(label)
			out.append("%s at %s" % [what, dir.place_label(int(s.get("i", -1)))])
			if out.size() >= MAX_LIST:
				return out
	return out


static func _top_complaints(dm: Dictionary) -> Array:
	var cs: Dictionary = dm.get("complaints", {})
	var keys: Array = cs.keys()
	keys.sort_custom(
		func(a: Variant, b: Variant) -> bool:
			return int(cs[a]) > int(cs[b]) or (int(cs[a]) == int(cs[b]) and str(a) < str(b))
	)
	return keys.slice(0, 2)


static func _when(today: int, day: int) -> String:
	if day >= today:
		return "today"
	return "yesterday" if day == today - 1 else "recently"


## The first sentences of parts (empty ones skipped) that fit in n characters, at most 2.
static func _fit(parts: Array[String], n: int) -> String:
	var out := ""
	var used := 0
	for p in parts:
		if p.is_empty():
			continue
		var joined := p if out.is_empty() else out + " " + p
		if joined.length() > n:
			if out.is_empty():
				out = T.clip(p, n)
			break
		out = joined
		used += 1
		if used >= 2:
			break
	return out


static func _a(noun: String) -> String:
	return ("an " if noun.left(1) in ["a", "e", "i", "o", "u"] else "a ") + noun
