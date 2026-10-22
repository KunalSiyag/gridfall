extends FpFeature
## Street props that the player's car, the hero on foot, people and traffic knock about
## (integration feature "props"). Bins, benches, planters, mailboxes, bike racks, parking meters,
## traffic cones, wheelie bins and cardboard cartons hit hard enough for their kind fall: CityView
## knocks the batched prop down (not drawn, its collider out of CollisionWorld) and a copy of its
## meshes tumbles off (tumble.gd) over the walker's ground and off its walls, rolls over its edges
## and comes to rest on a face, where it can be hit again. Hit slower, a prop holds and blocks like
## a wall; lamps, trees, bollards, hydrants, utility boxes and signs always hold. A fallen prop
## stands in its place again once it has lain RESPAWN seconds out of sight and away from the
## player, and at once when its tile is drawn again. The car's body (drive/car_body.gd) asks
## knockables_near() and knock(); prop_knocked on the bus reports every fall and every hard kick.
##
## On foot (flag prop_bumps): the hero running into a light prop (a bin, cone, wheelie bin or
## carton) fast enough for its kind knocks it over, and a blow with nobody in reach lands on the
## one in front (strike(), from the actions feature); the hero, people walking and traffic kick
## fallen props along; and a fallen prop sliding fast knocks into the props in its way.

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const TUMBLE := preload("res://scripts/fp/props/tumble.gd")
const OBB := preload("res://scripts/fp/obb2d.gd")

## Knockable StreetDressing kinds: [mass (a sedan is 1), the slowest a hit may send the prop
## flying (m/s) for it to give way, the slowest (m/s) someone on foot must come at it for it to go
## over (0: it holds against people and their blows)].
const KINDS := {
	"bin": [0.02, 0.8, 3.0],
	"mailbox": [0.06, 2.5, 0.0],
	"bench": [0.06, 2.0, 0.0],
	"bench_park": [0.06, 2.0, 0.0],
	"rack": [0.04, 2.5, 0.0],
	"meter": [0.03, 3.0, 0.0],
	"planter": [0.3, 3.5, 0.0],
	"cone": [0.003, 0.3, 0.6],
	"wheelie": [0.012, 0.6, 2.5],
	"carton": [0.004, 0.3, 0.9],
}
## At most this many props lie fallen at once; past it the oldest stands up again.
const MAX_DOWN := 24
## A fallen prop stands up again after lying this long (s) out of sight, with the player at least
## RESPAWN_CLEAR (u) from its place and no car on it.
const RESPAWN := 20.0
const RESPAWN_CLEAR := 1.0
## Tumbles move in steps of STEP (s), at most MAX_STEPS a frame.
const STEP := 1.0 / 60.0
const MAX_STEPS := 4
## Hits on a fallen prop slower than this (u/s) are not reported on the bus.
const KICK_REPORT := 1.0 * WS.M
## The photo shot: the camera stands PHOTO_BACK (u) in front of the prop, which a hit sends along
## its sidewalk at PHOTO_FLY (u/s).
const PHOTO_BACK := 0.16
const PHOTO_FLY := 4.0 * WS.M
## Someone on foot: their mass (a sedan is 1) and reach round their feet (u). A bump hands a prop
## (1 + BUMP_BOUNCE) times its share of the closing speed; one that hands on less than BUMP_MIN
## (u/s) is none, and a fallen prop takes a bump from people and traffic at most every BUMP_GAP
## (s).
const PERSON_MASS := 0.05
const PERSON_R := WS.PLAYER_RADIUS
const BUMP_BOUNCE := 0.2
const BUMP_MIN := 0.3 * WS.M
const BUMP_GAP := 0.25
## The hero touches a standing prop within CONTACT (u) of its side plus what they close on it in a
## frame (a blocked body stops up to a frame's move short: CollisionWorld.move_body); feet further
## than STEP_OFF (u) above or below a fallen prop's underside pass it by. Moved more than TELEPORT
## (u) since the last frame, the hero was put somewhere: the speed before brings no bump.
const CONTACT := 0.05 * WS.M
const STEP_OFF := 0.5 * WS.M
const TELEPORT := 1.0 * WS.M
## A blow of full strength (actions' 0..1) hands a prop the momentum of someone on foot at BLOW
## (u/s); it flies off at most BLOW_FLY.
const BLOW := 3.0 * WS.M
const BLOW_FLY := 6.0 * WS.M
## People and traffic kick the fallen props within TRAFFIC_R (u) of the player.
const TRAFFIC_R := 2.0
## A fallen prop sliding at least CHAIN_SPEED (u/s) knocks into the props in its way.
const CHAIN_SPEED := 1.0 * WS.M

## Fallen props, oldest first: {"tile", "slot", "kind", "t": TUMBLE, "node": Node3D, "age": s,
## "bump": s before people or traffic may bump it again}.
var down: Array[Dictionary] = []
var _acc: float = 0.0
## The photo shot's prop: {"tile", "slot", "kind", "xf", "fly", "rest"}, {} without one.
var _photo: Dictionary = {}
## The hero's level velocity and feet when the feature last looked: running into a prop stops the
## body, so a bump takes the faster of that velocity and the one now.
var _hero_vel := Vector2.ZERO
var _hero_at := Vector3.ZERO
var _driving: bool = false


func feature_id() -> String:
	return "props"


func setup(p_ctx: FpContext) -> void:
	super.setup(p_ctx)
	if ctx.view != null:
		link_signal(ctx.view.tile_built, _on_tile_built)
		link_signal(ctx.view.tile_cleared, _on_tile_cleared)
	if ctx.bus != null:
		link_signal(ctx.bus.drive_changed, _on_drive_changed)


## Boot, load or New City: every holder is new and every prop stands.
func on_world_rebuilt() -> void:
	_clear(-1)


func teardown() -> void:
	unlink_signals()
	stand_all()


func self_test() -> Dictionary:
	if ctx.view == null:
		return {"ok": true, "detail": "no city view"}
	var bad: Array[String] = []
	for kind: String in KINDS:
		var kit := ctx.view.street_kit(kind)
		if kit.is_empty() or (kit["parts"] as Array).is_empty():
			bad.append("no %s kit" % kind)
	var p := ctx.player_position()
	var n := 0
	for k: Dictionary in knockables_near(p, 3.0):
		var placed := ctx.view.street_placements(int(k["tile"]))
		var slot := int(k["slot"])
		if slot >= placed.size() or not KINDS.has(str(placed[slot][0])):
			bad.append("tile %d slot %d is no knockable prop" % [int(k["tile"]), slot])
		n += 1
	var detail := "%d knockable props within 60 m, %d down" % [n, down.size()]
	return {
		"ok": bad.is_empty(), "detail": detail + ("" if bad.is_empty() else ": " + ", ".join(bad))
	}


func _process(delta: float) -> void:
	if ctx == null or ctx.collision == null:
		return
	var bumps := FeatureFlags.enabled("prop_bumps")
	if bumps:
		_bump_hero(minf(delta, STEP * MAX_STEPS))
	if down.is_empty():
		return
	if bumps:
		_bump_traffic()
	_acc = minf(_acc + delta, STEP * MAX_STEPS)
	while _acc >= STEP:
		_acc -= STEP
		_step_all(bumps)
	for e: Dictionary in down:
		e["age"] = float(e["age"]) + delta
		e["bump"] = maxf(float(e["bump"]) - delta, 0.0)
		(e["node"] as Node3D).transform = (e["t"] as TUMBLE).xform()
	_respawn()


# ------------------------------------------------------------------ the car's body


## The props within r of p (feet) that can be knocked about, standing or fallen: {"c": Vector2
## (xz), "r": reach round c, "box": AABB (world; standing boxes), "mass", "kind", "tile", "slot",
## "down": true (fallen ones)}.
func knockables_near(p: Vector3, r: float) -> Array:
	var out: Array = []
	if ctx == null or ctx.view == null:
		return out
	var c := Vector2(p.x, p.z)
	for ty in range(floori(p.z - r - 0.5), ceili(p.z + r + 0.5) + 1):
		for tx in range(floori(p.x - r - 0.5), ceili(p.x + r + 0.5) + 1):
			if D.in_bounds(tx, ty):
				_standing(D.idx(tx, ty), c, r, out)
	for e: Dictionary in down:
		var t: TUMBLE = e["t"]
		var q := Vector2(t.pos.x, t.pos.z)
		var qr := _lying_radius(t)
		if q.distance_to(c) < r + qr:
			var k := {"c": q, "r": qr, "mass": float(KINDS[e["kind"]][0]), "kind": e["kind"]}
			k.merge({"tile": e["tile"], "slot": e["slot"], "down": true})
			out.append(k)
	return out


## Knocks street prop `slot` of tile i over (fallen, hits it again): pushed at world point `at`, it
## flies off at the level velocity fly (u/s). False when it holds (not knockable, or standing and
## sent off slower than its kind gives way at) or, fallen, already moves away that fast.
func knock(i: int, slot: int, at: Vector3, fly: Vector3) -> bool:
	var speed := Vector2(fly.x, fly.z).length()
	var fallen := _entry(i, slot)
	if not fallen.is_empty():
		return _kick(fallen, at, fly, speed)
	if ctx.view == null:
		return false
	var placed := ctx.view.street_placements(i)
	if slot < 0 or slot >= placed.size():
		return false
	var kind := str(placed[slot][0])
	if not KINDS.has(kind) or speed < float(KINDS[kind][1]) * WS.M:
		return false
	var kit := ctx.view.street_kit(kind)
	if kit.is_empty() or (kit["parts"] as Array).is_empty():
		return false
	ctx.view.set_street_prop_down(i, slot, true)
	if ctx.collision != null:
		ctx.collision.invalidate(i)
	var t := TUMBLE.new()
	t.launch(placed[slot][1], kit["aabb"], at, fly)
	var node := _draw(kind, kit)
	node.transform = t.xform()
	var e := {"tile": i, "slot": slot, "kind": kind, "t": t, "node": node, "age": 0.0}
	# Whoever knocked it over is still touching it: no second bump from them at once.
	e["bump"] = BUMP_GAP
	down.append(e)
	if down.size() > MAX_DOWN:
		_stand(down.pop_front())
	if ctx.bus != null:
		ctx.bus.prop_knocked.emit(at, kind, speed)
	return true


## Stands every fallen prop up again.
func stand_all() -> void:
	for e: Dictionary in down:
		_stand(e)
	down.clear()


## A fallen prop hit again: it moves off at fly unless it already moves away about that fast.
func _kick(e: Dictionary, at: Vector3, fly: Vector3, speed: float) -> bool:
	var t: TUMBLE = e["t"]
	if speed < 1e-6:
		return false
	var dir := Vector3(fly.x, 0.0, fly.z) / speed
	var cur := Vector3(t.vel.x, 0.0, t.vel.z).dot(dir)
	if cur >= speed * 0.9:
		return false
	t.kick(at, fly - dir * maxf(cur, 0.0))
	e["age"] = 0.0
	if ctx.bus != null and speed >= KICK_REPORT:
		ctx.bus.prop_knocked.emit(at, str(e["kind"]), speed)
	return true


## Fallen prop `slot` of tile i (its entry in down), {} while it stands.
func _entry(i: int, slot: int) -> Dictionary:
	for e: Dictionary in down:
		if int(e["tile"]) == i and int(e["slot"]) == slot:
			return e
	return {}


## Appends the knockable props standing on tile i within r of c.
func _standing(i: int, c: Vector2, r: float, out: Array) -> void:
	var holder := ctx.view.tile_holder(i)
	if holder == null:
		return
	var hx := holder.transform
	for v: Variant in holder.get_meta("colliders", []):
		if not (v is Dictionary):
			continue
		var d: Dictionary = v
		var kind := str(d.get("kind", ""))
		if not d.has("slot") or bool(d.get("down", false)) or not KINDS.has(kind):
			continue
		var k := {"mass": float(KINDS[kind][0]), "kind": kind, "tile": i, "slot": int(d["slot"])}
		if str(d.get("shape", "box")) == "cyl":
			var q := hx * (d["pos"] as Vector3)
			k["c"] = Vector2(q.x, q.z)
			k["r"] = float(d["r"])
		else:
			var b := hx * ConstructionKit.collider_aabb(d)
			k["box"] = b
			k["c"] = Vector2(b.get_center().x, b.get_center().z)
			k["r"] = Vector2(b.size.x, b.size.z).length() * 0.5
		if (k["c"] as Vector2).distance_to(c) < r + float(k["r"]):
			out.append(k)


## A fallen prop's reach on the ground: the mean of its level half extents as it lies.
func _lying_radius(t: TUMBLE) -> float:
	var s := absf(sin(t.angle))
	var cs := absf(cos(t.angle))
	if absf(t.axis.x) > 0.5:
		return (t.half.x + t.half.z * cs + t.half.y * s) * 0.5
	return (t.half.z + t.half.x * cs + t.half.y * s) * 0.5


# ------------------------------------------------------------------ on foot and in traffic


## A blow of strength 0..1 (actions' swings) from someone with their feet at `from`, aimed along
## the level dir: it lands on the nearest prop that gives way to people, inside the cone ahead (the
## cosine), with its side within reach (feet to feet, as for a person) less a person's girth of the
## body's centre. Standing, it falls; fallen, it is knocked along. False when there is none, or
## bumps are off.
func strike(from: Vector3, dir: Vector3, reach: float, cone: float, strength: float) -> bool:
	if not FeatureFlags.enabled("prop_bumps"):
		return false
	var c := Vector2(from.x, from.z)
	var aim := Vector2(dir.x, dir.z).normalized()
	var best := {}
	var bd := INF
	var arm := reach - PERSON_R
	for k: Dictionary in knockables_near(from, arm):
		var g := _gap(k, c)
		var gap := float(g[0])
		var yields := k.has("down") or float(KINDS[k["kind"]][2]) > 0.0
		if yields and gap <= arm and gap < bd and (g[1] as Vector2).dot(aim) >= cone:
			bd = gap
			best = k
	if best.is_empty():
		return false
	var fly := aim * minf(BLOW * PERSON_MASS * strength / float(best["mass"]), BLOW_FLY)
	var at := from + Vector3(aim.x, 0.0, aim.y) * bd
	if best.has("down"):
		_push(_entry(int(best["tile"]), int(best["slot"])), at, fly)
		return true
	return knock(int(best["tile"]), int(best["slot"]), at, Vector3(fly.x, 0.0, fly.y))


## The hero on foot: running into a standing prop at least as fast as its kind gives way to people
## knocks it over; walking into a fallen one kicks it along. delta: the frame's time, capped like
## the tumbles' steps so a hitch does not reach props far ahead.
func _bump_hero(delta: float) -> void:
	var p := ctx.player
	if p == null or not is_instance_valid(p) or _driving or p.photo_mode:
		_hero_vel = Vector2.ZERO
		return
	var feet := p.position
	var v := Vector2(p.velocity.x, p.velocity.z)
	var put := Vector2(feet.x - _hero_at.x, feet.z - _hero_at.z).length() > TELEPORT
	var hit := v if put or v.length_squared() >= _hero_vel.length_squared() else _hero_vel
	_hero_vel = v
	_hero_at = feet
	if hit.length() < BUMP_MIN:
		return
	var c := Vector2(feet.x, feet.z)
	for k: Dictionary in knockables_near(feet, PERSON_R + CONTACT + hit.length() * delta):
		var g := _gap(k, c)
		var n: Vector2 = g[1]
		var close := hit.dot(n)
		var need := float(KINDS[k["kind"]][2]) * WS.M
		if k.has("down") or need <= 0.0 or close < need:
			continue
		if float(g[0]) > PERSON_R + CONTACT + close * delta:
			continue
		var fly := _bounce(Vector2.ZERO, float(k["mass"]), hit, PERSON_MASS, n)
		var at := feet + Vector3(n.x, 0.0, n.y) * PERSON_R
		knock(int(k["tile"]), int(k["slot"]), at, Vector3(fly.x, 0.0, fly.y))
	for e: Dictionary in down.duplicate():
		_bump_fallen(e, c, feet.y, hit)


## Someone on foot with their feet at (c, y), moving at the level velocity v, kicks fallen prop e
## along when they run into it.
func _bump_fallen(e: Dictionary, c: Vector2, y: float, v: Vector2) -> void:
	var t: TUMBLE = e["t"]
	var to := Vector2(t.pos.x, t.pos.z) - c
	var reach := PERSON_R + _lying_radius(t)
	if float(e["bump"]) > 0.0 or to.length_squared() >= reach * reach or to.is_zero_approx():
		return
	if absf(t.pos.y - t.drop() - y) > STEP_OFF:
		return
	var n := to.normalized()
	var dv := _bounce(_level_vel(e), float(KINDS[e["kind"]][0]), v, PERSON_MASS, n)
	if dv.length() >= BUMP_MIN:
		_push(e, Vector3(c.x, y, c.y) + Vector3(n.x, 0.0, n.y) * PERSON_R, dv)


## People walking and traffic kick along the fallen props within TRAFFIC_R of the player that they
## run into.
func _bump_traffic() -> void:
	var traffic := ctx.feature("traffic")
	if traffic == null or not traffic.has_method("agents_packed"):
		return
	var me := ctx.player_position()
	var near: Array[Dictionary] = []
	for e: Dictionary in down:
		var q: Vector3 = (e["t"] as TUMBLE).pos
		if Vector2(q.x - me.x, q.z - me.z).length() < TRAFFIC_R:
			near.append(e)
	if near.is_empty():
		return
	var a: Dictionary = traffic.call("agents_packed", me, TRAFFIC_R + 0.1)
	var pos: PackedVector3Array = a["pos"]
	var vel: PackedVector3Array = a["vel"]
	var kinds: PackedStringArray = a["kind"]
	for k in range(pos.size()):
		if kinds[k] != "pedestrian":
			continue
		for e: Dictionary in near:
			_bump_fallen(e, Vector2(pos[k].x, pos[k].z), pos[k].y, Vector2(vel[k].x, vel[k].z))
	for b: Array in traffic.call("bodies_near", me, TRAFFIC_R):
		for e: Dictionary in near:
			_bump_car(e, b)


## Vehicle body b (traffic's bodies_near entry) kicks fallen prop e along when it runs into it.
func _bump_car(e: Dictionary, b: Array) -> void:
	var t: TUMBLE = e["t"]
	if float(e["bump"]) > 0.0:
		return
	var yb := float(b[2])
	var q := Vector2(t.pos.x, t.pos.z)
	var hit := OBB.box_circle(b[1], OBB.side_axis(yb), OBB.heading(yb), b[3], q, _lying_radius(t))
	if hit.is_empty():
		return
	var n := -(hit[0] as Vector2)
	var dv := _bounce(_level_vel(e), float(KINDS[e["kind"]][0]), b[4], float(b[5]), n)
	if dv.length() >= BUMP_MIN:
		var p: Vector2 = hit[2]
		_push(e, Vector3(p.x, t.pos.y, p.y), dv)


## Fallen prop e sliding at least CHAIN_SPEED knocks into the first prop in its way: a standing one
## falls when the hit is hard enough for its kind (else its wall turns e back), a fallen one is
## kicked on, and e keeps the momentum it does not hand on.
func _chain(e: Dictionary) -> void:
	var t: TUMBLE = e["t"]
	var v := _level_vel(e)
	if e.has("gone") or t.resting or v.length() < CHAIN_SPEED:
		return
	var c := Vector2(t.pos.x, t.pos.z)
	var r := _lying_radius(t)
	var m := float(KINDS[e["kind"]][0])
	for k: Dictionary in knockables_near(t.pos, r):
		var i := int(k["tile"])
		var slot := int(k["slot"])
		var g := _gap(k, c)
		if (i == int(e["tile"]) and slot == int(e["slot"])) or float(g[0]) > r:
			continue
		var n: Vector2 = g[1]
		var other := _entry(i, slot) if k.has("down") else {}
		var dv := _bounce(_level_vel(other), float(k["mass"]), v, m, n)
		var at := t.pos + Vector3(n.x, 0.0, n.y) * r
		if dv.length() < BUMP_MIN:
			continue
		if other.is_empty() and not knock(i, slot, at, Vector3(dv.x, 0.0, dv.y)):
			continue
		if not other.is_empty():
			_push(other, at, dv)
		var back := dv * (float(k["mass"]) / m)
		t.vel -= Vector3(back.x, 0.0, back.y)
		return


## Fallen prop e takes the level velocity change dv (u/s), pushed at world point `at`; reported on
## the bus from KICK_REPORT.
func _push(e: Dictionary, at: Vector3, dv: Vector2) -> void:
	(e["t"] as TUMBLE).kick(at, Vector3(dv.x, 0.0, dv.y))
	e["age"] = 0.0
	e["bump"] = BUMP_GAP
	if ctx.bus != null and dv.length() >= KICK_REPORT:
		ctx.bus.prop_knocked.emit(at, str(e["kind"]), dv.length())


## How far the level point c is from the side of knockables_near entry k (u; 0 inside it) and the
## level unit normal from c toward it: [gap, normal].
func _gap(k: Dictionary, c: Vector2) -> Array:
	var to: Vector2 = (k["c"] as Vector2) - c
	if k.has("box"):
		var b: AABB = k["box"]
		var lo := Vector2(b.position.x, b.position.z)
		var q := c.clamp(lo, lo + Vector2(b.size.x, b.size.z))
		if not q.is_equal_approx(c):
			return [q.distance_to(c), (q - c).normalized()]
		return [0.0, to.normalized()]
	return [maxf(to.length() - float(k["r"]), 0.0), to.normalized()]


## A fallen prop's level velocity (entry e of down; zero for {}, a standing prop).
func _level_vel(e: Dictionary) -> Vector2:
	if e.is_empty():
		return Vector2.ZERO
	var t: TUMBLE = e["t"]
	return Vector2(t.vel.x, t.vel.z)


## The level velocity change of a prop of mass m moving at v when a body of mass mb moving at vb
## runs into it along the unit normal n (from the body to the prop); zero when they part.
static func _bounce(v: Vector2, m: float, vb: Vector2, mb: float, n: Vector2) -> Vector2:
	var vn := (vb - v).dot(n)
	if vn <= 0.0:
		return Vector2.ZERO
	return n * ((1.0 + BUMP_BOUNCE) * vn / (1.0 + m / mb))


func _on_drive_changed(active: bool) -> void:
	_driving = active
	_hero_vel = Vector2.ZERO


# ------------------------------------------------------------------ fallen props


## Moves every fallen prop on by STEP; with chain, the fast ones then knock into what they reach.
func _step_all(chain: bool) -> void:
	var floor_at := ctx.collision.walk_height
	var blocked := ctx.collision.body_blocked
	for e: Dictionary in down:
		(e["t"] as TUMBLE).step(STEP, floor_at, blocked)
	if chain:
		for e: Dictionary in down.duplicate():
			_chain(e)


## A copy of kit's meshes for a fallen prop of `kind`, in the feature's world space.
func _draw(kind: String, kit: Dictionary) -> Node3D:
	var n := Node3D.new()
	n.name = "Fallen_" + kind
	var end := WS.VIS_PROP * _vis_mult()
	for part: Dictionary in kit["parts"]:
		var mi := MeshInstance3D.new()
		mi.mesh = part["mesh"]
		mi.transform = part["xform"]
		if part.get("mat") != null:
			mi.material_override = part["mat"]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visibility_range_end = end
		mi.visibility_range_end_margin = 0.5
		mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		n.add_child(mi)
	add_child(n)
	return n


## Stands up the fallen props that have lain RESPAWN seconds where nobody sees them go.
func _respawn() -> void:
	var keep: Array[Dictionary] = []
	for e: Dictionary in down:
		if float(e["age"]) >= RESPAWN and _may_stand(e["t"]):
			_stand(e)
		else:
			keep.append(e)
	down = keep


## True when the fallen prop t and its place are out of sight, the player is RESPAWN_CLEAR away
## and no car stands on its place.
func _may_stand(t: TUMBLE) -> bool:
	var spot := t.start.origin
	var me := ctx.player_position()
	if Vector2(spot.x - me.x, spot.z - me.z).length() < RESPAWN_CLEAR:
		return false
	if not (_unseen(spot) and _unseen(t.pos)):
		return false
	var traffic := ctx.feature("traffic")
	if traffic == null or not traffic.has_method("bodies_near"):
		return true
	var r := maxf(t.half.x, t.half.z)
	var q := Vector2(spot.x, spot.z)
	for b: Array in traffic.call("bodies_near", spot, r):
		var yb := float(b[2])
		if not OBB.box_circle(b[1], OBB.side_axis(yb), OBB.heading(yb), b[3], q, r).is_empty():
			return false
	return true


## Stands fallen prop e up in its place again.
func _stand(e: Dictionary) -> void:
	e["gone"] = true
	if is_instance_valid(e["node"]):
		(e["node"] as Node3D).queue_free()
	var i := int(e["tile"])
	if ctx.view != null:
		ctx.view.set_street_prop_down(i, int(e["slot"]), false)
	if ctx.collision != null and is_instance_valid(ctx.collision):
		ctx.collision.invalidate(i)


## Drops the fallen props of tile i (every tile when i < 0) without standing them up: their
## holder was drawn again, props standing.
func _clear(i: int) -> void:
	var keep: Array[Dictionary] = []
	for e: Dictionary in down:
		if i >= 0 and int(e["tile"]) != i:
			keep.append(e)
		else:
			e["gone"] = true
			if is_instance_valid(e["node"]):
				(e["node"] as Node3D).queue_free()
	down = keep


func _on_tile_built(i: int, _holder: Node3D) -> void:
	_clear(i)


func _on_tile_cleared(i: int) -> void:
	_clear(i)


## True when the camera cannot see p: behind it, off to a side or past the props' draw distance.
func _unseen(p: Vector3) -> bool:
	var cam: Camera3D = null
	if ctx.player != null and is_instance_valid(ctx.player):
		cam = ctx.player.camera
	if cam == null or not cam.is_inside_tree():
		return true
	var d := cam.global_position.distance_to(p)
	if d > WS.VIS_PROP * _vis_mult():
		return true
	if d < 0.08:
		return false
	return not (cam.is_position_in_frustum(p) or cam.is_position_in_frustum(p + Vector3.UP * 0.05))


func _vis_mult() -> float:
	return ctx.view.vis_mult if ctx.view != null else 1.0


# ------------------------------------------------------------------ photo tour


## The photo shot: the knockable prop nearest the spawn point knocked along its sidewalk, seen
## from the road in front of it where it comes to rest.
func photo_shots() -> Array:
	_photo = _photo_prop()
	if _photo.is_empty():
		return []
	var xf: Transform3D = _photo["xf"]
	var front := Vector3(xf.basis.z.x, 0.0, xf.basis.z.z).normalized()
	var pos := xf.origin + front * PHOTO_BACK
	pos.y = ctx.collision.walk_height(pos)
	var look: Vector3 = _photo["rest"] - (pos + Vector3(0, WS.EYE, 0))
	var pitch := rad_to_deg(atan2(look.y, Vector2(look.x, look.z).length()))
	var shot := {"name": "props", "pos": pos, "yaw": rad_to_deg(atan2(-look.x, -look.z))}
	shot.merge({"pitch": pitch, "hour": 11.0, "prepare": "photo_prepare", "restore": "stand_all"})
	return [shot]


## Photo tour: the shot's prop knocked over and already at rest.
func photo_prepare() -> void:
	if _photo.is_empty():
		return
	var xf: Transform3D = _photo["xf"]
	if not knock(int(_photo["tile"]), int(_photo["slot"]), xf.origin, _photo["fly"]):
		return
	var t: TUMBLE = down.back()["t"]
	var floor_at := ctx.collision.walk_height
	var blocked := ctx.collision.body_blocked
	while t.step(STEP, floor_at, blocked):
		pass
	(down.back()["node"] as Node3D).transform = t.xform()


## The standing knockable prop nearest the spawn point with walkable ground in front of it, and
## where a hit along its sidewalk lays it to rest: {"tile", "slot", "kind", "xf", "fly", "rest"}.
func _photo_prop() -> Dictionary:
	if ctx.view == null or ctx.collision == null:
		return {}
	var sp := (
		ctx.mode.spawn_point()["pos"] as Vector3 if ctx.mode != null else ctx.player_position()
	)
	var best := {}
	var bd := INF
	for k: Dictionary in knockables_near(sp, 3.0):
		var placed: Array = ctx.view.street_placements(int(k["tile"]))[int(k["slot"])]
		var xf: Transform3D = placed[1]
		var front := Vector3(xf.basis.z.x, 0.0, xf.basis.z.z).normalized()
		var d := xf.origin.distance_to(sp)
		if d < bd and not is_nan(ctx.collision.walk_height(xf.origin + front * PHOTO_BACK)):
			bd = d
			best = {"tile": k["tile"], "slot": k["slot"], "kind": placed[0], "xf": xf}
	if best.is_empty():
		return {}
	var xf: Transform3D = best["xf"]
	best["fly"] = Vector3(xf.basis.x.x, 0.0, xf.basis.x.z).normalized() * PHOTO_FLY
	var t := TUMBLE.new()
	t.launch(xf, ctx.view.street_kit(str(best["kind"]))["aabb"], xf.origin, best["fly"])
	while t.step(STEP, ctx.collision.walk_height, ctx.collision.body_blocked):
		pass
	best["rest"] = t.pos
	return best
