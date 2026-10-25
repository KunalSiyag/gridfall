extends SceneTree
## Environmental attacks (the brawl feature's slam, flag slams; docs/fp/ARCHITECTURE.md, Brawl):
## R with someone held and open street beyond them throws them; with a wall just beyond them it
## slams them into it (the actions feature's "slam"): they go down off the wall to the side, never
## through it, with a heavy hit-stop and hero_slammed on the bus; with the flag off it throws. A
## bin, cone, wheelie bin or carton just beyond them goes over with them and they go down over
## it. Third person on a grown city; time runs through traffic's step, the features' tick(1/60)
## and the player's simulate and update_view.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const BRAWL := preload("res://scripts/fp/brawl/brawl_feature.gd")
const ACTIONS := preload("res://scripts/fp/actions/actions_feature.gd")
const DT := 1.0 / 60.0
## The props that go over when someone is slammed into them.
const LIGHT := ["bin", "cone", "wheelie", "carton"]
## The hero stands this far (m) from a prop's place to slam someone into it.
const PROP_BACK := 1.4

var fails: Array[String] = []
var ctx: FpContext
var tr: FpFeature
var act: FpFeature
var hp: FpFeature
var pr: FpFeature
var feel: FpFeature
var f: FpFeature
var react: RefCounted
## [at, what, over] of every hero_slammed.
var slammed: Array = []


func _init() -> void:
	await process_frame
	ctx = K.make_ctx(get_root(), {"view": true, "grow": true, "camera_mode": "third"})
	ctx.player.set_process(false)
	ctx.view.set_fp_mode(true)
	if ctx.view.has_method("flush_rebuild_queue"):
		ctx.view.call("flush_rebuild_queue")
	ctx.collision.rebuild_all()
	tr = K.make_feature(ctx, "traffic")
	act = K.make_feature(ctx, "actions")
	hp = K.make_feature(ctx, "health")
	pr = K.make_feature(ctx, "props")
	feel = K.make_feature(ctx, "hit_feel")
	f = K.make_feature(ctx, "brawl")
	if [tr, act, hp, pr, feel, f].has(null):
		K.check(fails, false, "the traffic, actions, health, props, hit_feel, brawl features exist")
		K.finish(self, "FP_SLAMS_TEST", fails)
		return
	tr.set("auto_step", false)
	tr.set("ambient_enabled", false)
	for n: Node in [act, hp, pr, feel, f]:
		n.set_process(false)
	react = tr.get("reactions")
	ctx.bus.hero_slammed.connect(
		func(at: Vector3, what: String, over: bool) -> void: slammed.append([at, what, over])
	)
	var walk := K.sidewalk(ctx, 3.0 * WS.M)
	K.check(fails, not walk.is_empty(), "fixture: a clear run of sidewalk")
	if not walk.is_empty():
		_check_open(walk)
		_check_wall(walk)
		_check_flag_off(walk)
	_check_prop()
	Engine.time_scale = 1.0
	K.finish(self, "FP_SLAMS_TEST", fails)


# ------------------------------------------------------------------ helpers


## Runs the street for secs: traffic, the actions, health, props, brawl, then the player.
func _step(secs: float) -> void:
	for _k in range(ceili(secs / DT - 1e-6)):
		tr.call("step", DT)
		act.call("tick", DT)
		hp.call("tick", DT)
		pr.call("_process", DT)
		f.call("tick", DT)
		ctx.player.simulate(Vector2.ZERO, false, DT)
		ctx.player.update_view(DT)
	feel.call("tick", 1.0)


## A fresh scene: nobody about, nothing held, every prop up, the hero at feet facing the level
## unit dir with someone grabbed 0.6 m ahead of them (null when the grab failed).
func _held_at(feet: Vector3, dir: Vector3) -> WK.Walker:
	f.call("release")
	act.call("cancel")
	K.quiet_walkers(tr)
	pr.call("stand_all")
	hp.call("from_dict", {"hp": 100.0})
	slammed.clear()
	var p := ctx.player
	p.input_enabled = true
	p.teleport(feet, rad_to_deg(atan2(-dir.x, -dir.z)))
	p.update_view(DT)
	var w := K.person_ahead(ctx, tr, 0.9)
	if not bool(f.call("grab")):
		return null
	_step(0.4)
	return w


func _feet(w: WK.Walker) -> Vector3:
	return w.pos + w.vis_off


## A wall across the run, its face metres ahead of feet.
func _wall(feet: Vector3, run: Vector3, metres: float) -> AABB:
	var across := Vector3(absf(run.z), 0.0, absf(run.x))
	var c := feet + run * ((metres + 0.1) * WS.M) + Vector3.UP * (1.5 * WS.M)
	var size := across * (3.0 * WS.M) + Vector3(absf(run.x), 0.0, absf(run.z)) * (0.2 * WS.M)
	size.y = 3.0 * WS.M
	return AABB(c - size * 0.5, size)


## R, then the swing played out and the body down: the swing R started.
func _shove() -> String:
	K.check(fails, bool(act.call("strike", "shove")), "fixture: R starts a swing")
	var kind := str(act.get("swing"))
	_step(1.5)
	return kind


# ------------------------------------------------------------------ checks


func _check_open(walk: Dictionary) -> void:
	var run: Vector3 = walk["run"]
	var w := _held_at(walk["pos"], run)
	K.check(fails, w != null, "fixture: someone held on the sidewalk")
	if w == null:
		return
	K.check(fails, (f.call("slam_spot", run) as Dictionary).is_empty(), "open street: no slam")
	K.check(fails, _shove() == "throw", "R throws them")
	K.check(fails, slammed.is_empty() and int(f.get("slams")) == 0, "and nobody is slammed")


func _check_wall(walk: Dictionary) -> void:
	var run: Vector3 = walk["run"]
	var feet: Vector3 = walk["pos"]
	ctx.collision.add_test_box(_wall(feet, run, 1.15))
	var w := _held_at(feet, run)
	if w == null:
		K.check(fails, false, "fixture: someone held in front of a wall")
		ctx.collision.clear_test_boxes()
		return
	var spot: Dictionary = f.call("slam_spot", run)
	var gap := float(spot.get("gap", INF)) / WS.M
	K.check(
		fails,
		str(spot.get("what", "")) == "wall" and absf(gap - 0.3) < 0.08,
		"a wall 0.3 m beyond them is a slam (%s, %.2f m)" % [spot.get("what", "none"), gap]
	)
	var stops := int(feel.get("stops"))
	var kind := _shove()
	K.check(fails, kind == "slam", "R slams them into it (%s)" % kind)
	var down := bool(react.call("is_down", w)) and int(f.get("held_id")) == -1
	K.check(fails, down and int(f.get("slams")) == 1, "they go down out of the hands")
	var heard := slammed.size() == 1 and str(slammed[0][1]) == "wall" and not bool(slammed[0][2])
	K.check(fails, heard, "hero_slammed(wall) on the bus (%s)" % [slammed])
	K.check(fails, int(feel.get("stops")) > stops, "with a hit-stop")
	var to := _feet(w) - ctx.player.position
	var ahead := to.dot(run) / WS.M
	var side := absf(to.dot(Vector3(-run.z, 0.0, run.x))) / WS.M
	K.check(
		fails,
		ahead < 1.15 - 0.2 and side > 0.15,
		"off the wall to the side, not through it (%.2f m ahead, %.2f to the side)" % [ahead, side]
	)
	ctx.collision.clear_test_boxes()


func _check_flag_off(walk: Dictionary) -> void:
	var run: Vector3 = walk["run"]
	var feet: Vector3 = walk["pos"]
	FeatureFlags.set_override("slams", false)
	ctx.collision.add_test_box(_wall(feet, run, 1.15))
	var w := _held_at(feet, run)
	if w != null:
		K.check(fails, (f.call("slam_spot", run) as Dictionary).is_empty(), "slams off: no slam")
		K.check(fails, _shove() == "throw" and slammed.is_empty(), "R throws them at the wall")
	ctx.collision.clear_test_boxes()
	FeatureFlags.set_override("slams", true)


func _check_prop() -> void:
	var fx := _prop_fixture()
	K.check(fails, not fx.is_empty(), "fixture: someone held in front of a bin, cone or carton")
	if fx.is_empty():
		return
	var w: WK.Walker = fx["w"]
	var dir: Vector3 = fx["dir"]
	var before := _feet(w)
	K.check(fails, _shove() == "slam", "R slams them into the %s" % fx["kind"])
	K.check(fails, _is_down(fx), "the %s goes over" % fx["kind"])
	var heard := slammed.size() == 1 and str(slammed[0][1]) == str(fx["kind"])
	K.check(
		fails, heard and bool(slammed[0][2]), "hero_slammed(%s, over) (%s)" % [fx["kind"], slammed]
	)
	var on := (_feet(w) - before).dot(dir) / WS.M
	var down := bool(react.call("is_down", w))
	K.check(fails, down and on > 0.5, "and they go down over it (%.2f m on)" % on)
	pr.call("stand_all")


## Someone held in front of a light standing prop on a road tile: {"w", "dir", "kind", "tile",
## "slot"}, {} when no prop has room round it.
func _prop_fixture() -> Dictionary:
	for i: int in ctx.sim.active:
		if ctx.sim.kind[i] != D.ROAD:
			continue
		var placed: Array = ctx.view.street_placements(i)
		for s in range(placed.size()):
			if str(placed[s][0]) not in LIGHT:
				continue
			var at := (placed[s][1] as Transform3D).origin
			for dir: Vector3 in [Vector3.RIGHT, Vector3.LEFT, Vector3.BACK, Vector3.FORWARD]:
				var fx := {"dir": dir, "kind": str(placed[s][0]), "tile": i, "slot": s}
				if _held_by(fx, at):
					return fx
	return {}


## True once someone is held with the prop of fx (at its place) right beyond them along fx.dir.
func _held_by(fx: Dictionary, at: Vector3) -> bool:
	var dir: Vector3 = fx["dir"]
	var feet := at - dir * (PROP_BACK * WS.M)
	var g := ctx.collision.walk_height(feet)
	if (
		is_nan(g)
		or ctx.collision.body_blocked(
			Vector3(feet.x, g, feet.z), WS.PLAYER_RADIUS, WS.PLAYER_HEIGHT
		)
	):
		return false
	var w := _held_at(Vector3(feet.x, g, feet.z), dir)
	var spot: Dictionary = f.call("slam_spot", dir) if w != null else {}
	if (
		int(spot.get("tile", -1)) == int(fx["tile"])
		and int(spot.get("slot", -1)) == int(fx["slot"])
	):
		fx["w"] = w
		return true
	return false


func _is_down(fx: Dictionary) -> bool:
	for e: Dictionary in pr.get("down"):
		if int(e["tile"]) == int(fx["tile"]) and int(e["slot"]) == int(fx["slot"]):
			return true
	return false
