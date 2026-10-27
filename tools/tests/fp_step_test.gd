extends SceneTree
## The hero's combat step (player.combat_step) and the step-in (the actions feature's strike_step
## flag): how far a grounded step may go, that the world holds it (a wall, a prop and a person
## are never overlapped), that a punch at someone near the edge of its reach steps the hero in
## through the wind-up and stops short of them, and that kicks, empty swings, close targets and
## the flag off keep the hero's feet. Third person on a grown city; time runs through the
## feature's tick(1/60), traffic's step and the player's update_view.

const K := preload("res://tools/tests/fp_kit.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const DT := 1.0 / 60.0

var fails: Array[String] = []
var ctx: FpContext
var tr: FpFeature
var f: FpFeature


func _init() -> void:
	await process_frame
	ctx = K.make_ctx(get_root(), {"view": true, "grow": true, "camera_mode": "third"})
	ctx.player.set_process(false)
	tr = K.make_feature(ctx, "traffic")
	f = K.make_feature(ctx, "actions")
	if tr == null or f == null:
		K.check(fails, false, "fixture: the traffic and actions features are registered")
		K.finish(self, "FP_STEP_TEST", fails)
		return
	tr.set("auto_step", false)
	tr.set("ambient_enabled", false)
	f.set_process(false)
	_check_step_in()
	_check_combat_step()
	K.finish(self, "FP_STEP_TEST", fails)


## The step-in (strike_step): a punch at someone just inside reach steps the hero in through the
## wind-up and stops short of them; a kick, an empty swing, a target already close and the flag
## off all keep the hero's feet, and the blow lands either way.
func _check_step_in() -> void:
	_settle()
	if _spot() == Vector3.ZERO:
		return
	FeatureFlags.set_override("strike_step", true)
	# Someone a step inside the punch's reach.
	var w := _ahead(1.15)
	var at0: Vector3 = ctx.player.position
	var hits0 := int(f.get("hits"))
	K.check(fails, bool(f.call("strike")), "step-in fixture starts a jab")
	_step(0.25)
	var moved := _feet_moved(at0)
	K.check(
		fails,
		moved > 0.1 * WS.M and moved <= 0.18 * WS.M + 1e-9,
		"a jab at reach's edge steps in at most 18 cm (%.3f m)" % (moved / WS.M)
	)
	K.check(
		fails, _gap(w) >= 0.9 * WS.M, "and stops short of them (%.2f m apart)" % (_gap(w) / WS.M)
	)
	K.check(fails, int(f.get("hits")) == hits0 + 1, "and still lands")
	_gone(w)
	# A kick never steps, even well inside its reach.
	_settle()
	var kick := _ahead(1.2)
	at0 = ctx.player.position
	hits0 = int(f.get("hits"))
	K.check(fails, bool(f.call("strike", "kick")), "step-in fixture starts a kick")
	_step(0.25)
	K.check(
		fails,
		_feet_moved(at0) < 1e-9 and int(f.get("hits")) == hits0 + 1,
		"a kick keeps its feet and still lands"
	)
	_gone(kick)
	# Nobody there: an empty swing keeps its feet.
	_settle()
	at0 = ctx.player.position
	K.check(fails, bool(f.call("strike")), "step-in fixture swings at nobody")
	_step(0.25)
	K.check(fails, _feet_moved(at0) < 1e-9, "an empty swing keeps its feet")
	# A target inside the stop line needs no step.
	_settle()
	var close_by := _ahead(0.9)
	at0 = ctx.player.position
	hits0 = int(f.get("hits"))
	K.check(fails, bool(f.call("strike")), "step-in fixture starts a jab up close")
	_step(0.25)
	K.check(
		fails,
		_feet_moved(at0) < 1e-9 and int(f.get("hits")) == hits0 + 1,
		"a jab up close keeps the hero's feet and lands"
	)
	_gone(close_by)
	# The flag off: reach's edge throws from where the hero stands.
	_settle()
	FeatureFlags.set_override("strike_step", false)
	var far_off := _ahead(1.15)
	at0 = ctx.player.position
	hits0 = int(f.get("hits"))
	K.check(fails, bool(f.call("strike")), "step-in fixture starts a jab with the flag off")
	_step(0.25)
	K.check(
		fails,
		_feet_moved(at0) < 1e-9 and int(f.get("hits")) == hits0 + 1,
		"strike_step off throws the jab from where the hero stands"
	)
	_gone(far_off)
	FeatureFlags.set_override("strike_step", true)
	_settle()


## combat_step itself: the ask caps at 18 cm on clear ground, and a wall, a prop and a person
## all hold it (the hero never ends up inside any of them).
func _check_combat_step() -> void:
	var p := ctx.player
	var col := ctx.collision
	_clear()
	var run := _spot()
	if run == Vector3.ZERO:
		return
	var side := Vector3(-run.z, 0.0, run.x)
	var y0 := p.position.y
	# Clear ground: the whole ask comes back, capped at 18 cm.
	var moved := p.combat_step(run * 5.0)
	K.check(
		fails,
		is_equal_approx(moved.length(), 0.18 * WS.M) and moved.dot(run) > 0.0,
		"a step on clear ground comes back capped at 18 cm (%.3f m)" % (moved.length() / WS.M)
	)
	# A person 60 cm ahead: the destination is inside their circle, so no step at all.
	var close_by := _ahead(0.6)
	var at0: Vector3 = p.position
	K.check(
		fails,
		p.combat_step(run * 0.18 * WS.M) == Vector3.ZERO and p.position == at0,
		"a person close ahead holds the step"
	)
	_gone(close_by)
	# A person 80 cm ahead: the step goes and lands outside their circle.
	var far_off := _ahead(0.8)
	moved = p.combat_step(run * 0.18 * WS.M)
	K.check(
		fails,
		is_equal_approx(moved.length(), 0.18 * WS.M) and _gap(far_off) >= 0.52 * WS.M - 1e-9,
		(
			"a step toward someone further off stays outside their circle (%.2f m)"
			% (_gap(far_off) / WS.M)
		)
	)
	_gone(far_off)
	# Airborne: no step.
	p.grounded = false
	K.check(
		fails, p.combat_step(run * 0.18 * WS.M) == Vector3.ZERO, "an airborne hero does not step"
	)
	p.grounded = true
	# A wall to the side: the step stops at its face, the hero never inside.
	var c1 := p.position + side * (0.4 * WS.M) - run * (0.6 * WS.M)
	var c2 := p.position + side * (1.2 * WS.M) + run * (0.6 * WS.M)
	var lo := Vector3(minf(c1.x, c2.x), y0, minf(c1.z, c2.z))
	var hi := Vector3(maxf(c1.x, c2.x), y0 + 2.5 * WS.M, maxf(c1.z, c2.z))
	col.add_test_box(AABB(lo, hi - lo))
	moved = p.combat_step(side * 0.18 * WS.M)
	K.check(
		fails,
		moved.dot(side) <= 0.1 * WS.M + 1e-9 and not _in_box(p.position, lo, hi),
		"a wall holds the step and the hero stays out of it (%.3f m in)" % (moved.dot(side) / WS.M)
	)
	# A prop cylinder ahead: the same, sliding round it at most.
	var prop := p.position + run * (0.45 * WS.M)
	col.add_test_cylinder(prop.x, prop.z, 0.1 * WS.M, y0 + 2.0 * WS.M)
	moved = p.combat_step(run * 0.18 * WS.M)
	var off := Vector2(p.position.x - prop.x, p.position.z - prop.z).length()
	K.check(
		fails,
		moved.dot(run) <= 0.05 * WS.M + 1e-9 and off >= 0.4 * WS.M - 1e-9,
		(
			"a prop holds the step (%.2f m off its axis, %.3f m in)"
			% [off / WS.M, moved.dot(run) / WS.M]
		)
	)


## Cancels any swing under way, clears the street and lets the combo window pass, so the next
## punch starts from the jab.
func _settle() -> void:
	f.call("cancel")
	_clear()
	_step(1.1)


## Steps the actions feature (unless feature is false), traffic and the player for secs.
func _step(secs: float, feature: bool = true) -> void:
	for _k in ceili(secs / DT - 1e-6):
		if feature:
			f.call("tick", DT)
		tr.call("step", DT)
		ctx.player.simulate(Vector2.ZERO, false, DT)
		ctx.player.update_view(DT)


## Clears the street, so only the test's own people are about.
func _clear() -> void:
	K.quiet_walkers(tr)


## Someone standing dist_m metres ahead of the hero, facing them.
func _ahead(dist_m: float) -> WK.Walker:
	return K.person_ahead(ctx, tr, dist_m)


## Takes w off the street again.
func _gone(w: WK.Walker) -> void:
	var walkers: WK = tr.get("walkers")
	walkers.remove(w)


## Puts the hero on a clear stretch of sidewalk facing along it, so a step has ground under it:
## the run's unit direction, or Vector3.ZERO when the city has none.
func _spot() -> Vector3:
	var s: Dictionary = K.sidewalk(ctx, 0.3)
	if s.is_empty():
		K.check(fails, false, "fixture: a clear sidewalk stretch")
		return Vector3.ZERO
	var run: Vector3 = s["run"]
	ctx.player.teleport(s["pos"], rad_to_deg(atan2(-run.x, -run.z)))
	return run


## The horizontal gap from the hero's feet to where w is drawn (u).
func _gap(w: WK.Walker) -> float:
	var q: Vector3 = w.pos + w.vis_off
	return Vector2(q.x - ctx.player.position.x, q.z - ctx.player.position.z).length()


## How far the hero's feet have moved horizontally from at (u).
func _feet_moved(at: Vector3) -> float:
	var p := ctx.player
	return Vector2(p.position.x - at.x, p.position.z - at.z).length()


## The hero's standing circle overlaps the box.
func _in_box(at: Vector3, lo: Vector3, hi: Vector3) -> bool:
	if at.y + WS.PLAYER_HEIGHT <= lo.y or at.y >= hi.y:
		return false
	var q := Vector2(clampf(at.x, lo.x, hi.x), clampf(at.z, lo.z, hi.z))
	return Vector2(at.x - q.x, at.z - q.y).length() < WS.PLAYER_RADIUS
