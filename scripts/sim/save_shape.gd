extends RefCounted
## The shape a save must have before a load replaces the live city with it. A save is JSON that
## somebody wrote, so any field can be the wrong kind of value (a writer bug, a hand edit, a build
## with another layout), and the loaders cast and iterate what they read: a cast that fails ends
## the loader half way, after the live city is already gone. These checks only read the save, so
## CitySim.from_dict and Main._restore run them first and refuse the whole save instead.
##
## They check kinds, not meanings: a tax rate of 1e9 is still a number. A key the save leaves out
## is fine (the loader has a default for it); a key that is there must be the right kind, and an
## explicit null is the wrong kind. Numbers are ints or floats (JSON has only floats).
## Static only. Pure data in, bool out, headless.

const NUM := "number"
const DICT := "dict"
const ARR := "array"
## An array whose entries are dictionaries (and whose fields FIELDS names are the right kind).
const REC := "records"
## A dictionary whose values are all numbers.
const NUMS := "numbers"
## A switch: a bool, or a number (what bool() converts).
const FLAG := "flag"
## A dictionary that has the shape of one of the SECTIONS, named after the sign: "@client" is a
## dictionary shaped like SECTIONS["client"]. The brain keeps a copy of the client's state and
## loads it with the client's own from_dict, so it needs the client's own check.
const SECTION_SIGN := "@"

## What CitySim.from_dict reads from its section, by key. The tile arrays and the world block have
## their own checks (they need the world's size).
const SIM := {
	"seed": NUM,
	"day": NUM,
	"tick_in_day": NUM,
	"event_seq": NUM,
	"site_seq": NUM,
	"crew_seq": NUM,
	"ordinances": DICT,
	"disabled_until": NUMS,
	"broken_roads": NUMS,
	"grid_priority": ARR,
	"log": ARR,
	"mayors": REC,
	"events": REC,
	"history": REC,
	"sites": REC,
	"crew_jobs": REC,
}

## What Main._restore hands each system after the sim: the sections of a save by name. The sim's
## own section is CitySim's to check (SIM above), so it is only a dictionary here.
const SECTIONS := {
	"sim": {},
	"brain":
	{
		"mayor_state": REC,
		"proposals": DICT,
		"decree_day": NUM,
		"last_paper": DICT,
		"last_voices": ARR,
		"last_council": DICT,
		"last_chaos": DICT,
		"last_operator": DICT,
		"chaos_last_day": NUM,
		"complaints": REC,
		"client": "@client",
	},
	"client": {"session_cache": DICT, "stats": DICT},
	"residents": {"people": REC, "departed": REC, "messages": REC, "seq": NUM, "enabled": FLAG},
	"minds": {"stats": DICT, "model_stats": DICT, "rot": NUM},
}

## What a record of each REC section must have, by key: "numbers" are fields the loader converts
## with int() or float() (or the recompute right after the load calculates with), and must be
## numbers where the record has them; "lists" must be arrays of numbers; "arrays" arrays of
## anything; "need" must be there at all (the recompute indexes them). Anything else in a record
## is not read by the load.
const FIELDS := {
	"mayor_state": {"arrays": ["thoughts", "results", "log"]},
	"events":
	{
		"need": ["type", "x", "y"],
		"numbers": ["id", "x", "y", "radius", "start_day", "until_day", "progress", "work"],
		"lists": ["tiles"],
	},
	"sites":
	{
		"numbers":
		[
			"id",
			"i",
			"x",
			"y",
			"owner",
			"from_kind",
			"from_level",
			"target_kind",
			"target_level",
			"stage",
			"start_tick",
			"progress",
			"stage_work",
			"rate",
			"tick_work",
			"job",
		]
	},
	"crew_jobs": {"numbers": ["id", "owner", "x", "y", "crew", "work", "total", "done"]},
	"people":
	{
		"numbers":
		[
			"home",
			"work",
			"at",
			"age",
			"helping",
			"help_eta",
			"help_ticks",
			"broke_days",
			"arrived",
			"spent",
			"plan_day",
			"wage",
			"site",
			"last_site",
		]
	},
}


static func is_number(v: Variant) -> bool:
	return typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT


## True when v is an array of dictionaries that each follow spec (a FIELDS entry, or {}).
static func records_ok(v: Variant, spec: Dictionary) -> bool:
	if typeof(v) != TYPE_ARRAY:
		return false
	for rec: Variant in v:
		if typeof(rec) != TYPE_DICTIONARY or not record_ok(rec as Dictionary, spec):
			return false
	return true


## True when one record has every key of spec's "need", numbers in its "numbers" fields, and
## arrays of numbers in its "lists" fields (where it has them).
static func record_ok(rec: Dictionary, spec: Dictionary) -> bool:
	for key: Variant in spec.get("need", []):
		if not rec.has(key):
			return false
	for key: Variant in spec.get("numbers", []):
		if rec.has(key) and not is_number(rec[key]):
			return false
	for key: Variant in spec.get("lists", []):
		if rec.has(key) and not numbers_ok(rec[key]):
			return false
	for key: Variant in spec.get("arrays", []):
		if rec.has(key) and typeof(rec[key]) != TYPE_ARRAY:
			return false
	return true


## True when v is an array of numbers.
static func numbers_ok(v: Variant) -> bool:
	return (
		typeof(v) == TYPE_ARRAY and (v as Array).all(func(n: Variant) -> bool: return is_number(n))
	)


## True when v is a value of the given kind (NUM, FLAG, DICT, ARR, REC, NUMS or a "@section");
## spec is REC's.
static func kind_ok(v: Variant, kind: String, spec: Dictionary = {}) -> bool:
	if kind.begins_with(SECTION_SIGN):
		return (
			typeof(v) == TYPE_DICTIONARY
			and section_ok(v as Dictionary, SECTIONS[kind.trim_prefix(SECTION_SIGN)])
		)
	match kind:
		NUM:
			return is_number(v)
		FLAG:
			return typeof(v) == TYPE_BOOL or is_number(v)
		DICT:
			return typeof(v) == TYPE_DICTIONARY
		ARR:
			return typeof(v) == TYPE_ARRAY
		REC:
			return records_ok(v, spec)
		NUMS:
			return (
				typeof(v) == TYPE_DICTIONARY
				and (v as Dictionary).values().all(func(n: Variant) -> bool: return is_number(n))
			)
	return false


## True when every key of schema that data has is of the kind the schema says.
static func section_ok(data: Dictionary, schema: Dictionary) -> bool:
	for key: String in schema.keys():
		if not data.has(key):
			continue
		var spec: Dictionary = FIELDS.get(key, {})
		if not kind_ok(data[key], str(schema[key]), spec):
			return false
	return true


## True when sim, a save's sim section, has the shape CitySim.from_dict reads. founding_mayor is a
## new city's mayor record: the numbers it has (treasury, taxes, counters) must be numbers in the
## saved mayors too, since the recompute that ends the load calculates with them.
static func sim_ok(sim: Dictionary, founding_mayor: Dictionary) -> bool:
	var numbers: Array = []
	for key: String in founding_mayor.keys():
		if is_number(founding_mayor[key]):
			numbers.append(key)
	return section_ok(sim, SIM) and records_ok(sim.get("mayors", []), {"numbers": numbers})


## True when every section of doc, a whole save, is a dictionary, and the ones the systems after
## the sim load (brain, client, residents, minds) have the shape their loaders read.
static func document_ok(doc: Dictionary) -> bool:
	for name: String in SECTIONS.keys():
		if not doc.has(name):
			continue
		var section: Variant = doc[name]
		if typeof(section) != TYPE_DICTIONARY:
			return false
		if not section_ok(section, SECTIONS[name]):
			return false
	return true
