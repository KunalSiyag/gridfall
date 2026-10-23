extends FpFeature
## Melee weapons (integration feature "melee"; docs/fp/ARCHITECTURE.md, Melee weapons): a baseball
## bat, a steel pipe or a bottle lying about the city for the hero to pick up and swing. Bats lie
## in the parks and by some homes, pipes on the sidewalk by the industrial lots and bottles by the
## shops (a share of each, the same ones every time for a city); those within SHOW_R of the hero
## are drawn, and one taken lies there again once the hero has been away beyond HIDE_R. E by one
## picks it up (pick() and interact_requested; with one in hand the two swap), Z drops it, and
## getting into a car or being knocked down drops it too. In hand it follows the right fist, and
## the actions feature swings it instead of punching (held(), landed()): weapon_hit on the bus
## reports every blow it lands, and a bottle breaks on the first one, in a spray of glass.

const WS := preload("res://scripts/fp/world_scale.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const KIT := preload("res://scripts/fp/melee/weapon_kit.gd")
## Which lots keep a weapon in front of them (kind -> {lot kind: share}).
const SPOTS := {
	"bat": {D.PARK: 0.5, D.ZONE_R: 0.15}, "pipe": {D.ZONE_I: 0.35}, "bottle": {D.ZONE_C: 0.25}
}
## Where on a lot a weapon is tried: along the street from the middle of its front (u), and round
## a park's middle; it needs ROOM (m) clear of props.
const STREET_TRIES: Array[float] = [0.08, -0.08, 0.2, -0.2]
const PARK_TRIES: Array[Vector2] = [Vector2(0.1, 0.1), Vector2(-0.12, 0.05), Vector2(0.0, -0.15)]
const ROOM := 0.5
## Weapons within SHOW_R (m) of the hero are drawn; past HIDE_R they go (and a taken one returns).
const SHOW_R := 45.0
const HIDE_R := 60.0
const REFRESH_S := 0.5
## E reaches a weapon within PICK_R (m) of the feet, the look passing within PICK_BALL (m) of it.
const PICK_R := 1.8
const PICK_BALL := 0.35
## A dropped weapon lands DROP_AHEAD (m) in front of the feet.
const DROP_AHEAD := 0.45
## Where the grip sits in the right hand's bone frame (metres, scaled to the world): the weapon's
## +Y comes out of the fist on the thumb side.
const HOLD := Transform3D(Basis(Vector3(0.0, 0.0, 1.0), -PI * 0.5), Vector3(0.0, 0.085, 0.03))
const GLASS := 18


## A weapon lying in the world.
class Item:
	extends RefCounted
	var id: int = 0
	var kind: String = ""
	var pos := Vector3.ZERO
	var yaw: float = 0.0
	var spot: int = -1  # its index in spots, -1 for one the hero dropped
	var node: MeshInstance3D = null


## Every place a weapon lies when nobody has taken it: {"kind", "pos", "yaw", "lot"}.
var spots: Array[Dictionary] = []
## The weapons lying in the world now, by id.
var items: Dictionary = {}
## The kind in the hero's hand ("" for none).
var held_kind: String = ""
## Weapons picked up, dropped and broken so far (tests).
var taken: int = 0
var dropped: int = 0
var broken: int = 0
var _held_node: MeshInstance3D = null
var _taken_spots: Dictionary = {}  # spot index -> true while taken
var _next_id: int = 1
var _refresh_t: float = 0.0
var _meshes: Dictionary = {}


func feature_id() -> String:
	return "melee"


func setup(p_ctx: FpContext) -> void:
	super.setup(p_ctx)
	if ctx.bus != null:
		link_signal(ctx.bus.interact_requested, _on_interact)
		link_signal(ctx.bus.drive_changed, _on_drive_changed)
		link_signal(ctx.bus.hero_hurt, _on_hero_hurt)


func on_world_rebuilt() -> void:
	_clear_items()
	_taken_spots.clear()
	spots = _find_spots()
	refresh()


func teardown() -> void:
	unlink_signals()
	_clear_items()
	_set_held("")


func to_dict() -> Dictionary:
	return {"held": held_kind} if not held_kind.is_empty() else {}


func from_dict(d: Dictionary) -> void:
	var k := str(d.get("held", ""))
	_set_held(k if KIT.KINDS.has(k) else "")


func _process(delta: float) -> void:
	tick(delta)


## Moves the weapon in hand with the fist and, every REFRESH_S, draws the weapons near the hero.
func tick(dt: float) -> void:
	_follow_hand()
	_refresh_t -= dt
	if _refresh_t <= 0.0:
		_refresh_t = REFRESH_S
		refresh()


## What the hero swings: {} for bare fists, else {"kind", "strength", "reach" (m past a fist's),
## "breaks"}.
func held() -> Dictionary:
	if held_kind.is_empty():
		return {}
	var k: Dictionary = KIT.KINDS[held_kind]
	return {
		"kind": held_kind, "strength": k["strength"], "reach": k["reach"], "breaks": k["breaks"]
	}


## A swing of the weapon in hand landed at a point on what ("person" or "prop"): weapon_hit, and a
## bottle breaks. Returns true when it broke.
func landed(what: String, at: Vector3) -> bool:
	if held_kind.is_empty():
		return false
	var kind := held_kind
	var broke := bool(KIT.KINDS[kind]["breaks"])
	if broke:
		_shatter(_held_node.global_position if _held_node != null else at)
		_set_held("")
		broken += 1
	if ctx.bus != null:
		ctx.bus.weapon_hit.emit(at, kind, what, broke)
	return broke


## Picks up the weapon with this id (one in hand is put down where it lay). False when there is
## no such weapon.
func take(id: int) -> bool:
	var it: Item = items.get(id)
	if it == null:
		return false
	if not held_kind.is_empty():
		_lay(held_kind, it.pos, it.yaw + PI * 0.5, -1)
	_remove(it)
	if it.spot >= 0:
		_taken_spots[it.spot] = true
	_set_held(it.kind)
	taken += 1
	if ctx.bus != null:
		var lbl := str(KIT.KINDS[it.kind]["label"])
		ctx.bus.toast.emit("Picked up a %s. Z drops it." % lbl, "system")
	return true


## Puts the weapon in hand down in front of the hero's feet; false with nothing in hand.
func drop() -> bool:
	if held_kind.is_empty() or ctx.player == null:
		return false
	var p := ctx.player
	var at := p.position + p.body_forward() * DROP_AHEAD * WS.M
	if ctx.collision != null:
		var y := ctx.collision.walk_height(at)
		at.y = p.position.y if is_nan(y) or absf(y - p.position.y) > 0.5 * WS.M else y
	_lay(held_kind, at, p.yaw + PI * 0.5, -1)
	_set_held("")
	dropped += 1
	return true


## Draws the weapons at the spots within SHOW_R of the hero and lets those beyond HIDE_R go (a
## taken spot's weapon comes back once the hero is that far away).
func refresh() -> void:
	if ctx == null or ctx.player == null or not FeatureFlags.enabled("melee"):
		return
	var me := ctx.player.position
	for it: Item in items.values():
		if _flat(it.pos, me) > HIDE_R * WS.M:
			_remove(it)
	var shown := {}
	for it: Item in items.values():
		shown[it.spot] = true
	for k in range(spots.size()):
		var s: Dictionary = spots[k]
		var d := _flat(s["pos"], me)
		if d > HIDE_R * WS.M:
			_taken_spots.erase(k)
		elif d < SHOW_R * WS.M and not shown.has(k) and not _taken_spots.has(k):
			_lay(str(s["kind"]), s["pos"], float(s["yaw"]), k)


## The weapon on the ground nearest along the ray, within PICK_R of the feet: {"kind": "weapon",
## "id", "tile", "pos", "dist", "label", "data": {"weapon"}}, or {}.
func pick(origin: Vector3, dir: Vector3, max_dist: float) -> Dictionary:
	if ctx.player == null or items.is_empty():
		return {}
	var d := dir.normalized()
	var best: Item = null
	var bt := max_dist
	for it: Item in items.values():
		if _flat(it.pos, ctx.player.position) > PICK_R * WS.M:
			continue
		var c := it.pos + Vector3.UP * 0.03 * WS.M
		var t := (c - origin).dot(d)
		if t < 0.0 or t >= bt:
			continue
		if (origin + d * t).distance_to(c) <= PICK_BALL * WS.M:
			bt = t
			best = it
	if best == null:
		return {}
	var lbl := str(KIT.KINDS[best.kind]["label"])
	var verb := "Swap for" if not held_kind.is_empty() else "Pick up"
	return {
		"kind": "weapon",
		"id": str(best.id),
		"tile": ctx.collision.tile_at(best.pos) if ctx.collision != null else -1,
		"pos": best.pos,
		"dist": bt,
		"label": "%s the %s" % [verb, lbl],
		"data": {"weapon": best.kind},
	}


func self_test() -> Dictionary:
	var kinds := {}
	for s: Dictionary in spots:
		kinds[s["kind"]] = int(kinds.get(s["kind"], 0)) + 1
	var detail := "spots %s, %d lying near, holding '%s'" % [str(kinds), items.size(), held_kind]
	return {"ok": true, "detail": detail}


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("act_drop") and not event.is_echo() and drop():
		get_viewport().set_input_as_handled()


func _on_interact(t: Dictionary) -> void:
	if str(t.get("kind", "")) == "weapon":
		take(int(str(t.get("id", "0"))))


func _on_drive_changed(active: bool) -> void:
	if active:
		drop()


func _on_hero_hurt(_amount: float, _cause: String, _health: float, down: bool) -> void:
	if down:
		drop()


# ------------------------------------------------------------------ in hand


func _set_held(kind: String) -> void:
	if _held_node != null:
		_held_node.queue_free()
		_held_node = null
	held_kind = kind
	if kind.is_empty():
		return
	_held_node = MeshInstance3D.new()
	_held_node.name = "Held_" + kind
	_held_node.mesh = _mesh(kind)
	_held_node.top_level = true
	add_child(_held_node)
	_follow_hand()


## Puts the weapon in hand in the right fist (at the right hip without an animated body).
func _follow_hand() -> void:
	if _held_node == null or ctx.player == null:
		return
	var p := ctx.player
	var sk := _skeleton()
	var i := sk.find_bone("RightHand") if sk != null else -1
	if i < 0 or not sk.is_inside_tree():
		var side := p.body_forward().cross(Vector3.UP).normalized()
		var at := p.position + side * 0.25 * WS.M + Vector3.UP * 0.9 * WS.M
		_held_node.global_transform = Transform3D(Basis(side, PI * 0.5), at)
		return
	var bx := sk.global_transform * sk.get_bone_global_pose(i)
	var hand := Transform3D(bx.basis.orthonormalized(), bx.origin)
	var off := Transform3D(HOLD.basis, HOLD.origin * WS.M)
	_held_node.global_transform = hand * off
	_held_node.visible = p.avatar == null or p.avatar.visible


func _skeleton() -> Skeleton3D:
	var av := ctx.player.avatar
	if av == null:
		return null
	var rig: Variant = av.get("rig")
	if rig == null:
		return null
	return (rig as Object).get("skeleton") as Skeleton3D


## A spray of glass where a bottle broke.
func _shatter(at: Vector3) -> void:
	if not is_inside_tree():
		return
	var fx := CPUParticles3D.new()
	fx.name = "Glass"
	fx.top_level = true
	fx.one_shot = true
	fx.amount = GLASS
	fx.lifetime = 0.9
	fx.explosiveness = 1.0
	fx.direction = Vector3.UP
	fx.spread = 70.0
	fx.initial_velocity_min = 1.0 * WS.M
	fx.initial_velocity_max = 2.6 * WS.M
	fx.gravity = Vector3.DOWN * 9.8 * WS.M
	fx.scale_amount_min = 0.5
	fx.scale_amount_max = 1.2
	var shard := BoxMesh.new()
	shard.size = Vector3(0.02, 0.004, 0.015) * WS.M
	shard.material = KIT.material("bottle")
	fx.mesh = shard
	add_child(fx)
	fx.global_position = at
	fx.emitting = true
	get_tree().create_timer(fx.lifetime + 0.5).timeout.connect(fx.queue_free)


# ------------------------------------------------------------------ in the world


func _lay(kind: String, at: Vector3, yaw: float, spot: int) -> void:
	var it := Item.new()
	it.id = _next_id
	_next_id += 1
	it.kind = kind
	it.pos = at
	it.yaw = yaw
	it.spot = spot
	it.node = MeshInstance3D.new()
	it.node.name = "Weapon_%d" % it.id
	it.node.mesh = _mesh(kind)
	# Lying flat, along yaw, its widest part resting on the ground.
	var lie := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, -PI * 0.5)
	var r := _rest_r(kind) * WS.M
	it.node.transform = Transform3D(lie, at + Vector3.UP * r)
	add_child(it.node)
	items[it.id] = it


func _remove(it: Item) -> void:
	items.erase(it.id)
	if it.node != null:
		it.node.queue_free()
		it.node = null


func _clear_items() -> void:
	for it: Item in items.values():
		_remove(it)
	items.clear()


func _mesh(kind: String) -> ArrayMesh:
	if not _meshes.has(kind):
		_meshes[kind] = KIT.mesh(kind)
	return _meshes[kind]


## The widest radius of kind's profile (m): it lies on that.
static func _rest_r(kind: String) -> float:
	var r := 0.0
	for pt: Array in KIT.PROFILES[kind]:
		r = maxf(r, float(pt[1]))
	return r


func _find_spots() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if ctx.sim == null or ctx.collision == null or ctx.directory == null:
		return out
	for i: int in ctx.sim.active:
		var lk := ctx.sim.kind[i]
		for kind: String in SPOTS:
			var shares: Dictionary = SPOTS[kind]
			if not shares.has(lk) or _roll("%s:%d" % [kind, i]) >= float(shares[lk]):
				continue
			var at := _park_spot(i) if lk == D.PARK else _front_spot(i)
			if not is_nan(at.x):
				var yaw := _roll("yaw:%d" % i) * TAU
				out.append({"kind": kind, "pos": at, "yaw": yaw, "lot": i})
	return out


func _front_spot(i: int) -> Vector3:
	var fr := ctx.directory.frontage(i)
	if fr < 0:
		return Vector3(NAN, 0.0, 0.0)
	var m := RoadTopology.mask(ctx.sim, D.tx(fr), D.ty(fr))
	if m != RoadTopology.NS and m != RoadTopology.EW:
		return Vector3(NAN, 0.0, 0.0)
	var road := Vector3(D.tx(fr), 0.0, D.ty(fr))
	var across := Vector3(D.tx(i), 0.0, D.ty(i)) - road
	var run := RoadTopology.run_dir(m)
	for along: float in STREET_TRIES:
		var p := road + across * (WS.SIDEWALK_CENTER + 0.06) + run * along
		if _room(p):
			p.y = ctx.collision.walk_height(p)
			return p
	return Vector3(NAN, 0.0, 0.0)


func _park_spot(i: int) -> Vector3:
	var c := Vector3(D.tx(i), 0.0, D.ty(i))
	for off: Vector2 in PARK_TRIES:
		var p := c + Vector3(off.x, 0.0, off.y)
		if _room(p):
			p.y = ctx.collision.walk_height(p)
			return p
	return Vector3(NAN, 0.0, 0.0)


func _room(p: Vector3) -> bool:
	var y := ctx.collision.walk_height(p)
	if is_nan(y) or ctx.collision.surface_at(p) in ["asphalt", "water"]:
		return false
	return not ctx.collision.is_blocked(Vector3(p.x, y, p.z), ROOM * WS.M)


func _roll(key: String) -> float:
	# String hashes of near-identical keys sit close together; the generator scatters them.
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("melee:" + key) ^ (ctx.sim.city_seed * 7919)
	return rng.randf()


static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()
