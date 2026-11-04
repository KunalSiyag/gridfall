extends RefCounted
## One fixed seed-7 city and brain state for the mayor-prompt tests: a grown city, every mayor with
## a post, thoughts and results, two proposals on the floor with votes, a decree and a Gazette
## headline (everything the user prompt already shows), plus the state only mayor context v2 reads
## (a council ruling, a Grid Operator order, a Chaos Director strike, a note and a request). With
## the flag off that second group must not reach a prompt.

const D := preload("res://scripts/sim/sim_defs.gd")
const K := preload("res://tools/tests/fp_kit.gd")

## The day the fixture's prompts are built for (its records are from the days before).
const PROMPT_DAY := 7


## Builds the city and brain under root: {"sim", "people", "client", "brain"}. A client given is
## used as it is (a fake with its own transport); else an offline one.
static func build(root: Node, client: GmiClient = null) -> Dictionary:
	var w := K.make_sim(root, 7, false, client)
	var sim: CitySim = w["sim"]
	sim.set_process(false)
	sim.set_speed(0)
	K.grow(sim, w["people"], 40)
	var brain: CityBrain = (load("res://scripts/ai/city_brain.gd") as GDScript).new()
	brain.name = "CityBrain"
	root.add_child(brain)
	brain.setup(sim, w["client"])
	w["brain"] = brain
	fill_state(brain)
	return w


## The same city on a scripted live transport (support/scripted_net.gd, answers set per model):
## {"sim", "people", "client", "brain", "net"}.
static func build_live(root: Node) -> Dictionary:
	var net := (load("res://tools/tests/support/scripted_net.gd") as GDScript).new()
	net.name = "ScriptedNet"
	net.live_enabled = true
	var w := build(root, net)
	w["net"] = net
	return w


## Writes the fixture's state into a brain that was just set up.
static func fill_state(brain: CityBrain) -> void:
	for mi in range(D.MAYORS.size()):
		var ms: Dictionary = brain.mayor_state[mi]
		ms["post"] = "Update %d from district %d: roads first, then homes." % [mi, mi]
		ms["thoughts"] = [
			"Day 5: power is tight",
			"Day 6: save for a %s" % ["park", "school", "pump", "plant", "clinic"][mi]
		]
		ms["results"] = [
			"OK road: built", "REJECTED zone: not enough room at (%d,%d)" % [mi + 2, mi + 3]
		]
		ms["day"] = 6
	brain.complaints[0] = {"power": 2}
	brain.complaints[3] = {"traffic": 1, "taxes": 1}
	brain.proposals = {
		"recycling":
		{"by": "Ada Okafor", "day": 6, "votes": {"argon": "yes", "grok": "no", "kimi": "yes"}},
		"curfew": {"by": "Duke Granger", "day": 6, "votes": {"grok": "yes"}},
	}
	brain.decree = "Build more parks."
	brain.decree_day = brain.sim.day
	brain.last_paper = {
		"day": 6,
		"headline": "Five mayors fight over one power grid",
		"editorial": "Share.",
		"source": "cache"
	}
	brain.sim.ordinances["public_transit"] = 4
	# State only mayor context v2 reads (the golden was made before notes existed: left out).
	brain.last_council = {
		"day": 6,
		"enacted": ["public_transit"],
		"repealed": [],
		"rejected": [],
		"statement": "Public Transit passed; Recycling waits for more votes.",
		"source": "live",
	}
	brain.last_operator = {
		"day": 5,
		"priority": [2, 0, 1, 3, 4],
		"note": "Central Plaza keeps power first; Duke Granger's district sheds first.",
		"advice": "Build wind before zoning more.",
		"source": "live",
	}
	brain.last_chaos = {
		"day": 6,
		"trigger": true,
		"type": "sewage_burst",
		"x": 18,
		"y": 18,
		"reason": "Grok-4.5's industrial quarter overloads the sewer.",
		"narration": "A main bursts!",
		"source": "live",
	}
	brain.notes = {
		"argon":
		[
			{
				"from": "kimi",
				"day": 6,
				"kind": "note",
				"text": "Share your solar surplus with me.",
				"amount": 0,
				"seen": false
			}
		],
		"kimi":
		[
			{
				"from": "deepseek",
				"day": 6,
				"kind": "request",
				"text": "Sewage plant is bankrupting me.",
				"amount": 600,
				"seen": false
			}
		],
	}
