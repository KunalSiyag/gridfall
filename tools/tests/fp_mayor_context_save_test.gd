extends SceneTree
## Mayor context v2 and a save (flag mayor_context_v2): the notes between mayors and the council
## history survive a save and load, bounded and sanitised (a save is a file anyone can edit), a
## hostile one is cut down to the newest records of the five mayors, and an old save has neither.
## A note kept past KEEP_DAYS days is dropped, and a note a mayor sent himself is never loaded.
## Headless, offline, fake transport only (support/scripted_net.gd): no key, no network.

const K := preload("res://tools/tests/fp_kit.gd")
const PF := preload("res://tools/tests/support/prompt_fixture.gd")
const NET := preload("res://tools/tests/support/scripted_net.gd")
const MC := preload("res://scripts/ai/mayor_context.gd")
const SAVE_SHAPE := preload("res://scripts/sim/save_shape.gd")
const TOKEN := "FP_MAYOR_CONTEXT_SAVE_TEST"

var fails: Array[String] = []


func check(ok: bool, what: String) -> void:
	K.check(fails, ok, what)


func _init() -> void:
	K.watchdog(self, TOKEN)
	await process_frame
	_check_save(PF.build_live(get_root()))
	_check_prune_and_self_notes()
	FeatureFlags.set_override(MC.FLAG, false)
	K.finish(self, TOKEN, fails)


func _check_save(w: Dictionary) -> void:
	var net: NET = w["net"]
	var brain: CityBrain = w["brain"]
	var sim: CitySim = w["sim"]
	FeatureFlags.set_override(MC.FLAG, true)
	brain.notes = {
		"kimi":
		[
			{
				"from": "argon",
				"day": 7,
				"kind": "note",
				"text": "Share please",
				"amount": 0,
				"seen": false
			}
		],
		"deepseek":
		[
			{
				"from": "argon",
				"day": 7,
				"kind": "request",
				"text": "Funds",
				"amount": 600,
				"seen": true
			}
		]
	}
	brain.council_history = [
		{
			"day": 6,
			"key": "curfew",
			"by": "Duke Granger",
			"by_id": "grok",
			"votes": {"grok": "yes", "argon": "no"},
			"notes": {"argon": "too costly"},
			"yes": 1,
			"no": 1,
			"outcome": "deferred",
			"against": false,
			"override": false,
			"statement": "Wait.",
			"source": "live"
		}
	]
	var doc := {
		"sim": sim.to_dict(),
		"brain": brain.to_dict(),
		"client": net.to_dict(),
		"residents": (w["people"] as Residents).to_dict()
	}
	var parsed: Dictionary = JSON.parse_string(JSON.stringify(doc))
	check(
		SAVE_SHAPE.document_ok(parsed),
		"a save with notes and a council history has the shape the loaders read"
	)
	check(
		(
			(parsed["brain"] as Dictionary).has("council_history")
			and (parsed["brain"] as Dictionary).has("notes")
		),
		"both are in the brain's section"
	)
	var before := JSON.stringify([brain.notes, brain.council_history])
	brain.notes = {}
	brain.council_history = []
	brain.from_dict(parsed["brain"])
	check(
		JSON.stringify([brain.notes, brain.council_history]) == before,
		"notes and the council history round-trip through a save"
	)
	var hostile := (parsed["brain"] as Dictionary).duplicate(true)
	var many: Array = []
	for k in range(30):
		many.append(
			{
				"day": k,
				"key": "curfew",
				"outcome": "enacted",
				"source": "live",
				"votes": {"argon": "yes", "grok": "yes", "nobody": "yes"},
				"statement": "Grok-4.5 rules " + "x".repeat(400)
			}
		)
	many.append("junk")
	many.append({"day": 1, "outcome": "bogus"})
	hostile["council_history"] = many
	var spam: Array = []
	for k in range(9):
		spam.append(
			{
				"from": "kimi",
				"day": k,
				"kind": "note",
				"text": "Kimi-K3 says " + "y".repeat(300),
				"amount": 12,
				"seen": false
			}
		)
	spam.append({"from": "nobody", "day": 1, "kind": "note", "text": "x"})
	spam.append(5)
	hostile["notes"] = {"argon": spam, "nobody": spam, "kimi": "oops"}
	brain.from_dict(hostile)
	check(
		brain.council_history.size() == 20 and int(brain.council_history[-1]["day"]) == 29,
		"a saved history is cut to the newest 20 (%d)" % brain.council_history.size()
	)
	var h: Dictionary = brain.council_history[-1]
	check(
		(
			h["votes"].size() == 2
			and int(h["yes"]) == 2
			and bool(h["override"])
			and str(h["statement"]).length() <= 240
			and not str(h["statement"]).contains("Grok")
		),
		"its records are rebuilt: five-seat votes, recomputed tally, de-branded and cut text"
	)
	check(
		(
			brain.notes.keys() == ["argon"]
			and (brain.notes["argon"] as Array).size() == MC.NOTES_PER_MAYOR
		),
		"saved notes keep known mayors and the newest %d each" % MC.NOTES_PER_MAYOR
	)
	var n: Dictionary = brain.notes["argon"][0]
	check(
		(
			str(n["text"]).length() <= MC.NOTE_CHARS
			and not str(n["text"]).contains("Kimi")
			and int(n["amount"]) == 0
		),
		"a note's text is de-branded and cut, and a plain note carries no amount"
	)
	check(
		(
			not SAVE_SHAPE.document_ok({"brain": {"notes": []}})
			and not SAVE_SHAPE.document_ok({"brain": {"council_history": {}}})
		),
		"a save with the wrong kind of notes or history is refused as a whole"
	)
	brain.from_dict({})
	check(brain.notes.is_empty() and brain.council_history.is_empty(), "an old save has neither")


## Notes older than KEEP_DAYS go at the next prune; a saved note from a mayor to himself is not
## loaded.
func _check_prune_and_self_notes() -> void:
	var day := 20
	var notes := {
		"kimi":
		[
			{"from": "argon", "day": day - MC.KEEP_DAYS, "kind": "note", "text": "edge"},
			{"from": "argon", "day": day - MC.KEEP_DAYS - 1, "kind": "note", "text": "old"},
		],
		"qwen": [{"from": "argon", "day": 1, "kind": "note", "text": "ancient"}],
	}
	MC.prune(notes, day)
	check(
		notes.keys() == ["kimi"] and (notes["kimi"] as Array).size() == 1,
		(
			"notes older than 8 days go, the 8-day-old one stays, an emptied list goes (%s)"
			% str(notes)
		)
	)
	check(MC.KEEP_DAYS == 8, "the keep window is the documented 8 days")
	var loaded := (
		MC
		. restore(
			{
				"argon":
				[
					{"from": "argon", "day": 5, "kind": "note", "text": "to myself"},
					{"from": "kimi", "day": 5, "kind": "note", "text": "to Ada"},
				]
			}
		)
	)
	check(
		(loaded["argon"] as Array).size() == 1 and str(loaded["argon"][0]["from"]) == "kimi",
		"a saved note from a mayor to himself is not loaded"
	)
