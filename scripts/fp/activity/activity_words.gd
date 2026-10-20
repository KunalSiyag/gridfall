extends RefCounted
## Plain words for the AI activity layer: what a mayor's turn did ("Zoned 6 homes · Ordered a
## Solar Farm"), council, chaos and grid rulings, a support agent's model badge, where an answer
## came from (live, replay or offline), "4 min" ages and compass directions. No nodes.

const D := preload("res://scripts/sim/sim_defs.gd")

const ZONE_WORDS := {
	"R": ["home", "homes"], "C": ["shop lot", "shop lots"], "I": ["factory lot", "factory lots"]
}
const DIRS := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
const SOURCE_TAGS := {"live": "LIVE", "cache": "REPLAY"}
## Most action phrases one summary lists before "+N more".
const MAX_PARTS := 2
const DETAIL_CHARS := 150


## The model a mayor runs on, as its badge reads ("DeepSeek-V4").
static func mayor_model(mi: int) -> String:
	return str(D.MAYORS[mi]["name"]) if mi >= 0 and mi < D.MAYORS.size() else ""


## A model id as a badge: the part after the vendor, without a trailing date stamp
## ("openai/gpt-6-luna" -> "gpt-6-luna",
## "deepseek-ai/DeepSeek-V4-Flash-0731" -> "DeepSeek-V4-Flash").
static func model_label(model_id: String) -> String:
	var s := model_id.get_slice("/", model_id.get_slice_count("/") - 1)
	return RegEx.create_from_string("-\\d{4}$").sub(s, "")


## Where an answer came from: "LIVE" (a model call), "REPLAY" (a recorded model answer),
## "OFFLINE" (the built-in planner, no model involved) or, when a live call was tried and failed
## (failed), "FALLBACK".
static func source_tag(source: String, failed: bool = false) -> String:
	if failed and source != "live":
		return "FALLBACK"
	return str(SOURCE_TAGS.get(source, "OFFLINE"))


## One line for what a mayor's turn did, from CityBrain's applied list
## ([{"action": Dictionary, "ok": bool, "reason": String}]).
static func summarize(applied: Array) -> String:
	var parts: Array[String] = []
	var refused := 0
	for v: Variant in applied:
		if typeof(v) != TYPE_DICTIONARY:
			continue
		var e: Dictionary = v
		if not bool(e.get("ok", false)):
			refused += 1
			continue
		var p := action_words(e.get("action", {}))
		if not p.is_empty() and not parts.has(p):
			parts.append(p)
	if parts.is_empty():
		return "Held off this turn" if refused == 0 else "Every order was refused"
	var out := " · ".join(PackedStringArray(parts.slice(0, MAX_PARTS)))
	if parts.size() > MAX_PARTS:
		out += " · +%d more" % (parts.size() - MAX_PARTS)
	if refused > 0:
		out += " (%d refused)" % refused
	return out


## The first refusal reason in an applied list ("cannot afford road ($120)"), or "".
static func first_refusal(applied: Array) -> String:
	for v: Variant in applied:
		if typeof(v) == TYPE_DICTIONARY and not bool((v as Dictionary).get("ok", false)):
			return str((v as Dictionary).get("reason", ""))
	return ""


## A short phrase for one mayor action ({"type": "zone", "zone": "R", "w": 3, "h": 2} ->
## "Zoned 6 homes"), or "" for an unknown one.
static func action_words(a: Variant) -> String:
	if typeof(a) != TYPE_DICTIONARY:
		return ""
	var d: Dictionary = a
	var out := ""
	match str(d.get("type", "")).to_lower():
		"road":
			var dx := absi(int(d.get("x2", d.get("x", 0))) - int(d.get("x", 0)))
			var dy := absi(int(d.get("y2", d.get("y", 0))) - int(d.get("y", 0)))
			var n := mini(dx + dy + 1, D.MAX_ROAD_LEN)
			out = "Laid %d road tile%s" % [n, "" if n == 1 else "s"]
		"zone":
			var z := str(d.get("zone", "R")).to_upper().left(1)
			var w: Array = ZONE_WORDS.get(z, ZONE_WORDS["R"])
			var side := D.MAX_ZONE_SIDE
			var n := clampi(int(d.get("w", 1)), 1, side) * clampi(int(d.get("h", 1)), 1, side)
			out = "Zoned %d %s" % [n, w[0] if n == 1 else w[1]]
		"build":
			var b: Dictionary = D.BUILDINGS.get(str(d.get("building", "")).to_lower(), {})
			out = "Ordered " + _a(str(b.get("label", "building")))
		"bulldoze":
			var n := clampi(int(d.get("w", 1)), 1, 3) * clampi(int(d.get("h", 1)), 1, 3)
			out = "Cleared %d lot%s" % [n, "" if n == 1 else "s"]
		"set_tax", "tax":
			var r := [int(d.get("r", 0)), int(d.get("c", 0)), int(d.get("i", 0))]
			out = "Set taxes to R%d/C%d/I%d" % r
		"emergency":
			out = "Sent emergency crews"
		"grant":
			var to := D.mayor_display(D.mayor_index(str(d.get("to", ""))))
			var amt := "$" + str(maxi(0, int(d.get("amount", 0))))
			out = "Granted %s to %s" % [amt, to] if not to.is_empty() else "Made a grant"
		"annex":
			out = "Annexed new land"
	return out


## Proposals and votes from a decision entry ("Proposed the Curfew ordinance · Voted no on
## Clean Air Act"), or "".
static func politics(entry: Dictionary) -> String:
	var parts: Array[String] = []
	var prop := str(entry.get("proposal", ""))
	if D.ORDINANCES.has(prop):
		parts.append("Proposed the %s ordinance" % str(D.ORDINANCES[prop]["label"]))
	var votes: Variant = entry.get("votes", {})
	if typeof(votes) == TYPE_DICTIONARY:
		for key: Variant in (votes as Dictionary).keys():
			var o: Dictionary = D.ORDINANCES.get(str(key), {})
			if not o.is_empty() and str(key) != prop:
				parts.append("Voted %s on %s" % [str(votes[key]), str(o["label"])])
	return " · ".join(PackedStringArray(parts.slice(0, 2)))


## What a council ruling did ("Passed Curfew · Repealed Clean Air Act").
static func council_words(r: Dictionary) -> String:
	var parts: Array[String] = []
	for pair: Array in [["enacted", "Passed"], ["repealed", "Repealed"], ["rejected", "Rejected"]]:
		var arr: Variant = r.get(pair[0], [])
		if typeof(arr) != TYPE_ARRAY:
			continue
		for k: Variant in arr:
			var o: Dictionary = D.ORDINANCES.get(str(k), {})
			if not o.is_empty():
				parts.append("%s %s" % [pair[1], str(o["label"])])
	if parts.is_empty():
		return "No ordinance changed"
	return " · ".join(PackedStringArray(parts.slice(0, MAX_PARTS + 1)))


## What the Chaos Director chose ("Set off a building fire" or "Kept the city calm").
static func chaos_words(d: Dictionary) -> String:
	if not bool(d.get("trigger", false)):
		return "Kept the city calm"
	var ev: Dictionary = D.DISASTERS.get(str(d.get("type", "")), {})
	return "Set off " + _a(str(ev.get("label", "an incident")).to_lower())


## Which district the Grid Operator powers first ("Power goes first to Central Plaza").
static func operator_words(d: Dictionary) -> String:
	var pr: Variant = d.get("priority", [])
	if typeof(pr) != TYPE_ARRAY or (pr as Array).is_empty():
		return "Kept the power order"
	var first := int((pr as Array)[0])
	if first < 0 or first >= D.MAYORS.size():
		return "Kept the power order"
	return "Power goes first to " + str(D.MAYORS[first]["district"])


## Free text for a card: de-branded, one line, at most DETAIL_CHARS with an ellipsis.
static func detail(t: String) -> String:
	var s := D.debrand(t.strip_edges()).replace("\n", " ")
	if s.length() <= DETAIL_CHARS:
		return s
	return s.left(DETAIL_CHARS - 1).rstrip(" ,.;:") + "…"


## A saved focus tile back as a Vector2i: CityBrain keeps a Vector2i, a JSON save turns it into
## "(x, y)" or [x, y]. D.NO_TILE when there is none.
static func tile_of(v: Variant) -> Vector2i:
	if typeof(v) == TYPE_VECTOR2I:
		return v
	if typeof(v) == TYPE_ARRAY and (v as Array).size() >= 2:
		return Vector2i(int(v[0]), int(v[1]))
	if typeof(v) == TYPE_STRING:
		var m := RegEx.create_from_string("(-?\\d+)\\s*,\\s*(-?\\d+)").search(str(v))
		if m != null:
			return Vector2i(int(m.get_string(1)), int(m.get_string(2)))
	return D.NO_TILE


## Compass direction from a to b on the ground ("NE"), north being -Z.
static func direction(a: Vector3, b: Vector3) -> String:
	var bearing := atan2(b.x - a.x, -(b.z - a.z))
	return DIRS[posmod(roundi(bearing / (PI / 4.0)), 8)]


## A card's age: "now", "4 min", "2 h"; "Day 7" for one restored from a save (seconds < 0).
static func ago(seconds: float, day: int) -> String:
	if seconds < 0.0:
		return "Day %d" % day
	if seconds < 45.0:
		return "now"
	if seconds < 3600.0:
		return "%d min" % maxi(1, roundi(seconds / 60.0))
	return "%d h" % roundi(seconds / 3600.0)


static func _a(noun: String) -> String:
	var art := "an" if noun.left(1).to_lower() in ["a", "e", "i", "o", "u"] else "a"
	return "%s %s" % [art, noun]
