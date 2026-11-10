extends RefCounted
## A city and a CityBrain for the council tests (fp_council_log_test, fp_council_replay_test): the
## council runs offline (the offline planner and the recorded replay) or against a scripted Speaker
## (support/scripted_net.gd) with proposals the test puts on the floor.

const D := preload("res://scripts/sim/sim_defs.gd")
const K := preload("res://tools/tests/fp_kit.gd")


## A city and a brain on client under root: {"sim", "brain", "client", "people"}.
static func world(root: Node, client: GmiClient = null) -> Dictionary:
	var w := K.make_sim(root, 7, false, client)
	var sim: CitySim = w["sim"]
	sim.set_process(false)
	sim.set_speed(0)
	var brain: CityBrain = (load("res://scripts/ai/city_brain.gd") as GDScript).new()
	brain.name = "CityBrain"
	root.add_child(brain)
	brain.setup(sim, w["client"])
	w["brain"] = brain
	return w


static func free_world(w: Dictionary) -> void:
	for k: String in ["brain", "people", "client", "sim"]:
		if w.has(k) and is_instance_valid(w[k]):
			(w[k] as Node).queue_free()


## A proposal by mayor index by with the votes cast.
static func prop(by: int, votes: Dictionary, day: int = 6) -> Dictionary:
	return {"by": D.mayor_display(by), "day": day, "votes": votes}


## Votes of the first yes mayors saying yes and the next no mayors saying no, in seat order.
static func votes_of(yes: int, no: int) -> Dictionary:
	var out := {}
	for k in range(yes + no):
		out[str(D.MAYORS[k]["id"])] = "yes" if k < yes else "no"
	return out
