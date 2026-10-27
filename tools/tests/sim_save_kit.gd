extends RefCounted
## Shared scaffolding for the sim save/load tests (sim_determinism_test, save_migration_test): a
## seed-N world with residents, minds and a brain wired as Main wires them, the restore path of
## Main._restore / Main.load_game, and the save document, state hash and teardown those tests share.
##
## Static only; no nodes of its own. Everything is headless and offline.

const D := preload("res://scripts/sim/sim_defs.gd")
const K := preload("res://tools/tests/fp_kit.gd")


## A CitySim(seed) + GmiClient(offline) + Residents + ResidentMinds + CityBrain under root, wired
## as Main does: the brain gets sim and client, the minds are the brain's, and the day round is
## connected. Returns {"sim", "client", "people", "minds", "brain"}.
static func make_world(root: Node, seed_v: int = 7) -> Dictionary:
	var w := K.make_sim(root, seed_v, true)
	var sim: CitySim = w["sim"]
	sim.set_process(false)
	sim.set_speed(0)
	var brain: CityBrain = (load("res://scripts/ai/city_brain.gd") as GDScript).new()
	brain.name = "CityBrain"
	root.add_child(brain)
	brain.setup(sim, w["client"])
	(w["minds"] as ResidentMinds).plans_done.connect(brain.residents_spoke)
	brain.minds = w["minds"]
	w["brain"] = brain
	return w


## The save document Main._write_save() writes for w.
static func document(w: Dictionary) -> Dictionary:
	return {
		"sim": (w["sim"] as CitySim).to_dict(),
		"brain": (w["brain"] as CityBrain).to_dict(),
		"client": (w["client"] as GmiClient).to_dict(),
		"residents": (w["people"] as Residents).to_dict(),
		"minds": (w["minds"] as ResidentMinds).to_dict(),
	}


## Applies d to w (a world from make_world). Returns true when the sim accepted the save.
static func apply(w: Dictionary, d: Dictionary) -> bool:
	var sim: CitySim = w["sim"]
	var brain: CityBrain = w["brain"]
	var client: GmiClient = w["client"]
	var people: Residents = w["people"]
	var minds: ResidentMinds = w["minds"]
	if not sim.from_dict(d.get("sim", {})):
		return false
	brain.from_dict(d.get("brain", {}))
	client.from_dict(d.get("client", {}))
	people.setup(sim)
	minds.setup(sim, people, client, brain)
	brain.minds = minds
	people.from_dict(d.get("residents", {}))
	minds.from_dict(d.get("minds", {}))
	sim._recompute_all()
	sim.waiting_for_ai = false
	if sim.tick_in_day == 0:
		sim.start()
	return true


## Loads d into a brand new world: {"ok": bool, ...world}. A rejected save frees the world and
## returns {"ok": false} with no nodes.
static func load_into_new(root: Node, d: Dictionary) -> Dictionary:
	var w := make_world(root, int((d.get("sim", {}) as Dictionary).get("seed", 7)))
	if not apply(w, d):
		free_world(w)
		return {"ok": false}
	return w


## A hash of every piece of state a save carries.
static func state_hash(w: Dictionary) -> int:
	return (
		JSON
		. stringify(
			[
				(w["sim"] as CitySim).to_dict(),
				(w["brain"] as CityBrain).to_dict(),
				(w["people"] as Residents).to_dict(),
				(w["minds"] as ResidentMinds).to_dict(),
			]
		)
		. hash()
	)


## Ticks days whole days; true when the day counter advanced exactly that far.
static func ticks_ok(w: Dictionary, days: int) -> bool:
	var sim: CitySim = w["sim"]
	var day := sim.day
	for _t in range(days * D.GROWTH_TICKS_PER_DAY):
		sim.step_tick()
	return sim.day == day + days


## [zones, built] counts over the active tiles.
static func counts(w: Dictionary) -> Array:
	var sim: CitySim = w["sim"]
	var zones := 0
	var built := 0
	for i in sim.active:
		if D.is_zone(sim.kind[i]):
			zones += 1
		elif sim.kind[i] >= D.COAL and sim.kind[i] != D.FOREST:
			built += 1
	return [zones, built]


## Frees every node of a world, or a rejected-load result ({ok: false}) that holds none.
static func free_world(w: Dictionary) -> void:
	for key in ["brain", "sim", "people", "minds", "client"]:
		if w.has(key):
			(w[key] as Node).queue_free()
