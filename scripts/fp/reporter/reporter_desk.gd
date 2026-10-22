extends RefCounted
## The Gazette's desk (feature "reporter"): which AI decisions make a lead and how they read
## ("Viktor Han ordered a Police Station"), what a filed story says and earns, the press ranks,
## what a photo must frame, and the mayors' league (people, jobs, approval and funds, worth 25
## points each). No nodes.

const D := preload("res://scripts/sim/sim_defs.gd")

## Points for a filed story, and the bonuses on top: a scoop (filed fast), a local voice (the quote
## comes from someone who lives in the deciding mayor's district) and a sharp shot (a photo that
## frames the scene).
const FILED := 100
const SCOOP := 50
const LOCAL := 25
const SHARP := 25
## Press ranks, [points needed, name], lowest first.
const RANKS := [
	[0, "Stringer"], [300, "Reporter"], [1000, "Senior reporter"], [2500, "Star reporter"]
]
const ZONED := {"R": "zoned new homes", "C": "zoned new shops", "I": "zoned new industry"}
const VAGUE := "made a decision here"
## Longest quote kept, in characters.
const QUOTE_CHARS := 140
## A league category is worth this many points to the best mayor in it (approval: a 10 out of 10).
const CATEGORY := 25.0
## A shot frames its subject when the subject sits inside this central part of the view (a
## fraction of its width and of its height).
const FRAME := 0.65


## The lead in a mayor's turn: what they did at its focus tile, the first order carried out that
## has a place. {} when the turn has none. A lead is {"agent" ("0".."4", "council" or "chaos"),
## "headline", "tile": Vector2i, "district" (the deciding mayor; -1 for the others)}.
static func mayor_lead(mi: int, entry: Dictionary) -> Dictionary:
	var focus: Variant = entry.get("focus", D.NO_TILE)
	if mi < 0 or mi >= D.MAYORS.size() or typeof(focus) != TYPE_VECTOR2I:
		return {}
	var did := VAGUE
	var raw: Variant = entry.get("actions", [])
	var applied: Array = raw if typeof(raw) == TYPE_ARRAY else []
	for v: Variant in applied:
		if typeof(v) != TYPE_DICTIONARY or not bool((v as Dictionary).get("ok", false)):
			continue
		var a: Variant = (v as Dictionary).get("action", {})
		if typeof(a) == TYPE_DICTIONARY and (a as Dictionary).has("x"):
			did = deed(a)
			break
	return _lead(str(mi), "%s %s" % [D.mayor_display(mi), did], focus, mi)


## The lead in a council ruling that passed or repealed an ordinance, at City Hall (hall); {} when
## the council changed nothing.
static func council_lead(r: Dictionary, hall: Vector2i) -> Dictionary:
	for pair: Array in [["enacted", "passed"], ["repealed", "repealed"]]:
		var raw: Variant = r.get(pair[0], [])
		var keys: Array = raw if typeof(raw) == TYPE_ARRAY else []
		for k: Variant in keys:
			var o: Dictionary = D.ORDINANCES.get(str(k), {})
			if not o.is_empty():
				return _lead("council", "The council %s the %s" % [pair[1], o["label"]], hall, -1)
	return {}


## The lead in a Chaos Director pick that struck somewhere ("Building Fire reported"); {} for a
## calm day or a pick without a place.
static func chaos_lead(d: Dictionary) -> Dictionary:
	if not bool(d.get("trigger", false)) or not d.has("x"):
		return {}
	var ev: Dictionary = D.DISASTERS.get(str(d.get("type", "")), {})
	var at := Vector2i(int(d["x"]), int(d.get("y", 0)))
	return _lead("chaos", "%s reported" % str(ev.get("label", "An incident")), at, -1)


## What one order did, as the Gazette puts it ("ordered a Police Station", "zoned new homes").
static func deed(a: Dictionary) -> String:
	var out := VAGUE
	match str(a.get("type", "")).to_lower():
		"build":
			var b: Dictionary = D.BUILDINGS.get(str(a.get("building", "")).to_lower(), {})
			out = "ordered " + _article(str(b.get("label", "building")))
		"zone":
			out = str(ZONED.get(str(a.get("zone", "R")).to_upper().left(1), ZONED["R"]))
		"road":
			out = "laid a new road"
		"bulldoze":
			out = "cleared a block"
		"emergency":
			out = "sent in emergency crews"
		"annex":
			out = "annexed new land"
	return out


## The agent's colour (a mayor's or a support agent's).
static func color_of(agent: String) -> Color:
	var hex := "#FFD27F"
	if agent.is_valid_int() and int(agent) >= 0 and int(agent) < D.MAYORS.size():
		hex = str(D.MAYORS[int(agent)]["color"])
	elif D.SUPPORT_AGENTS.has(agent):
		hex = str(D.SUPPORT_AGENTS[agent]["color"])
	return Color(hex)


## A reply as a quote: de-branded, on one line, at most QUOTE_CHARS (cut at a word, with "…").
static func clip(t: String) -> String:
	var s := D.debrand(t.strip_edges()).replace("\n", " ")
	if s.length() <= QUOTE_CHARS:
		return s
	var cut := s.left(QUOTE_CHARS - 1)
	var space := cut.rfind(" ")
	if space > QUOTE_CHARS * 0.5:
		cut = cut.left(space)
	return cut.rstrip(" ,.;:") + "…"


## The byline of a passer-by who answered "Ask someone here": a role reads "a shopkeeper" or "an
## officer", a name ("Mara Ellis") stays as it is, and nobody reads "someone nearby".
static func passerby(speaker: String) -> String:
	var s := speaker.strip_edges()
	if s.is_empty():
		return "someone nearby"
	var words := s.split(" ", false)
	var named := words.size() > 1
	for w: String in words:
		var c := w.left(1)
		named = named and c != c.to_lower()
	return s if named else _article(s.to_lower())


## The story as the Gazette runs it in the chat: "From 214 Maple Street: Viktor Han ordered a
## Police Station. “About time,” says Ana Ruiz."
static func story_text(s: Dictionary) -> String:
	var out := "From %s: %s." % [s.get("place", "the city"), s.get("headline", "")]
	var q := str(s.get("quote", ""))
	if q.is_empty():
		return out
	var by := str(s.get("by", ""))
	by = "someone nearby" if by.is_empty() else by
	if q.right(1) in ["!", "?", "…"]:
		return out + " “%s” says %s." % [q, by]
	return out + " “%s,” says %s." % [q.trim_suffix("."), by]


## Points for a story: FILED, and SCOOP, LOCAL and SHARP for each bonus it earned.
static func points_for(scoop: bool, local: bool, sharp: bool) -> int:
	return FILED + (SCOOP if scoop else 0) + (LOCAL if local else 0) + (SHARP if sharp else 0)


## The bonuses a story earned, in words ("scoop, local voice"); "" for none.
static func bonus_words(s: Dictionary) -> String:
	var parts := PackedStringArray()
	for pair: Array in [["scoop", "scoop"], ["local", "local voice"], ["sharp", "sharp shot"]]:
		if bool(s.get(pair[0], false)):
			parts.append(pair[1])
	return ", ".join(parts)


## The press rank for points: {"name", "next" (the points the next rank needs, -1 at the top)}.
static func rank_of(points: int) -> Dictionary:
	var k := 0
	for n in range(RANKS.size()):
		if points >= int(RANKS[n][0]):
			k = n
	var next := int(RANKS[k + 1][0]) if k + 1 < RANKS.size() else -1
	return {"name": str(RANKS[k][1]), "next": next}


## Whether screen point p (a camera's unproject_position) lies in the central FRAME of a view of
## this size.
static func framed(p: Vector2, view: Vector2) -> bool:
	var m := view * (1.0 - FRAME) * 0.5
	return Rect2(m, view - m * 2.0).has_point(p)


## The league table, best first: a row per mayor {"mi", "who", "model", "style", "district",
## "color", "pop", "jobs", "approval" (0-10: what the district's residents think of their mayor,
## else its happiness), "funds", "orders" (carried out), "refused", "score" (0-100)}. People, jobs
## and funds score against the best mayor, approval out of 10. Ties go to the bigger district.
static func standings(sim: CitySim, people: Residents) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	if sim == null:
		return rows
	var best := {"pop": 1.0, "jobs": 1.0, "funds": 1.0}
	for mi in range(mini(D.MAYORS.size(), sim.mayors.size())):
		var m: Dictionary = sim.mayors[mi]
		var row := {"mi": mi, "who": D.mayor_display(mi), "model": str(D.MAYORS[mi]["name"])}
		row["style"] = str(D.MAYORS[mi]["style"])
		row["district"] = str(D.MAYORS[mi]["district"])
		row["color"] = color_of(str(mi))
		row["pop"] = int(m.get("pop", 0))
		row["jobs"] = int(m.get("jobs", 0))
		row["funds"] = int(m.get("treasury", 0))
		row["orders"] = int(m.get("actions_ok", 0))
		row["refused"] = int(m.get("actions_rejected", 0))
		row["approval"] = _approval(mi, m, people)
		for k: String in best.keys():
			best[k] = maxf(float(best[k]), float(row[k]))
		rows.append(row)
	for row: Dictionary in rows:
		var share := float(row["pop"]) / float(best["pop"]) + float(row["approval"]) / 10.0
		share += float(row["jobs"]) / float(best["jobs"])
		share += maxf(float(row["funds"]), 0.0) / float(best["funds"])
		row["score"] = roundi(CATEGORY * share)
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return _ahead(a, b))
	return rows


static func _approval(mi: int, m: Dictionary, people: Residents) -> float:
	if people != null and people.is_active():
		var mood := people.district_mood(mi)
		if int(mood.get("residents", 0)) > 0:
			return clampf(float(mood.get("approval", 0.0)), 0.0, 10.0)
	return snappedf(clampf(float(m.get("happiness", 0.5)), 0.0, 1.0) * 10.0, 0.1)


static func _ahead(a: Dictionary, b: Dictionary) -> bool:
	if int(a["score"]) != int(b["score"]):
		return int(a["score"]) > int(b["score"])
	if int(a["pop"]) != int(b["pop"]):
		return int(a["pop"]) > int(b["pop"])
	return int(a["mi"]) < int(b["mi"])


static func _lead(agent: String, headline: String, at: Vector2i, district: int) -> Dictionary:
	if not D.in_bounds(at.x, at.y):
		return {}
	return {"agent": agent, "headline": D.debrand(headline), "tile": at, "district": district}


static func _article(noun: String) -> String:
	return ("an " if noun.left(1).to_lower() in ["a", "e", "i", "o", "u"] else "a ") + noun
