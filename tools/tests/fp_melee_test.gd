extends SceneTree
## Melee weapons (integration feature "melee"; docs/fp/ARCHITECTURE.md, Melee weapons): bats,
## pipes and bottles lying about a grown city (drawn near the hero, gone far off, a taken one back
## once the hero has been away); the interact feature picking one out and E taking it; the weapon
## in the right fist; the strike button swinging it (further than a fist, as hard as the weapon,
## the clips alternating), weapon_hit on the bus, a bat's third blow, a pipe's first knocking
## people down, a bottle breaking in a spray of glass; Z dropping it, a swap, the car and a
## knock-down dropping it; save state; the flag off; teardown.
## Third person; time runs through the features' tick(1/60), traffic's step and the player's
## update_view.

const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const DT := 1.0 / 60.0

var fails: Array[String] = []
var ctx: FpContext
var tr: FpFeature
var act: FpFeature
var m: FpFeature
var rig: RefCounted
## [at, cause, info] of every person_hit; [at, kind, what, broke] of every weapon_hit; every
## hero_action's action.
var hits: Array = []
var blows: Array = []
var acts: Array[String] = []


func _init() -> void:
	K.watchdog(self, "FP_MELEE_TEST")
	await process_frame
	ctx = K.make_ctx(get_root(), {"view": true, "grow": true, "camera_mode": "third"})
	ctx.player.set_process(false)
	tr = K.make_feature(ctx, "traffic")
	act = K.make_feature(ctx, "actions")
	m = K.make_feature(ctx, "melee")
	if tr == null or act == null or m == null:
		K.check(fails, false, "the traffic, actions and melee features are registered")
		K.finish(self, "FP_MELEE_TEST", fails)
		return
	tr.set("auto_step", false)
	tr.set("ambient_enabled", false)
	act.set_process(false)
	m.set_process(false)
	K.quiet_walkers(tr)
	ctx.bus.person_hit.connect(
		func(at: Vector3, cause: String, info: Dictionary) -> void: hits.append([at, cause, info])
	)
	ctx.bus.weapon_hit.connect(
		func(at: Vector3, kind: String, what: String, broke: bool) -> void:
			blows.append([at, kind, what, broke])
	)
	ctx.bus.hero_action.connect(func(a: String, _at: Vector3) -> void: acts.append(a))
	var p := ctx.player
	p.teleport(p.position, rad_to_deg(p.yaw))
	rig = p.avatar.get("rig")
	K.check(fails, rig != null, "fixture: the hero is HC's animated rig")
	var home := p.position
	_check_spots()
	_check_pick()
	_check_respawn()
	p.teleport(home, rad_to_deg(p.yaw))
	_check_hand()
	_check_bat()
	_check_pipe()
	_check_bottle()
	_check_drop()
	_check_save()
	_check_flag()
	_check_teardown()
	K.finish(self, "FP_MELEE_TEST", fails)


# ------------------------------------------------------------------ helpers


func _step(secs: float) -> void:
	for _k in range(ceili(secs / DT - 1e-6)):
		act.call("tick", DT)
		m.call("tick", DT)
		tr.call("step", DT)
		ctx.player.simulate(Vector2.ZERO, false, DT)
		ctx.player.update_view(DT)


## The first spot of kind, {} when the city has none.
func _spot(kind: String) -> Dictionary:
	for s: Dictionary in m.get("spots"):
		if str(s["kind"]) == kind:
			return s
	return {}


## The weapon lying at pos ({} when none): the melee feature's Item.
func _item_at(pos: Vector3) -> Object:
	for it: Object in (m.get("items") as Dictionary).values():
		if (it.get("pos") as Vector3).distance_to(pos) < 1e-4:
			return it
	return null


## Stands the hero dist_m metres from pos, facing it, and draws the weapons around.
func _stand_by(pos: Vector3, dist_m: float) -> void:
	var p := ctx.player
	var away := Vector3(1.0, 0.0, 0.3).normalized()
	var at := pos + away * dist_m * WS.M
	at.y = pos.y
	p.teleport(at, rad_to_deg(atan2(away.x, away.z)))
	m.call("refresh")


## Puts the hero dist_m metres from where w is drawn, facing them (a blow slides them back).
func _face(w: WK.Walker, dist_m: float) -> void:
	var p := ctx.player
	var q := w.pos + w.vis_off
	var to := Vector3(q.x - p.position.x, 0.0, q.z - p.position.z).normalized()
	p.position = Vector3(q.x, p.position.y, q.z) - to * dist_m * WS.M
	p.yaw = atan2(-to.x, -to.z)
	p.cam_yaw = p.yaw


## Swings (or punches) once at whoever is in front and lets the swing play out.
func _swing() -> void:
	act.call("strike")
	_step(0.75)


func _remove(w: WK.Walker) -> void:
	(tr.get("walkers") as WK).remove(w)


# ------------------------------------------------------------------ checks


func _check_spots() -> void:
	var st := m.self_test()
	K.check(fails, bool(st.get("ok", false)), "self_test (%s)" % st.get("detail", ""))
	var keys: Array[int] = []
	for e: InputEvent in InputMap.action_get_events("act_drop"):
		if e is InputEventKey:
			keys.append(int((e as InputEventKey).physical_keycode))
	K.check(fails, keys == [KEY_Z], "Z drops the weapon in hand (%s)" % str(keys))
	var kinds := {}
	var ground := true
	var by_lot := true
	var spots: Dictionary = m.get("SPOTS")
	for s: Dictionary in m.get("spots"):
		kinds[s["kind"]] = true
		var g := ctx.collision.walk_height(s["pos"])
		ground = ground and absf(g - (s["pos"] as Vector3).y) < 1e-4
		ground = ground and ctx.collision.surface_at(s["pos"]) not in ["asphalt", "water"]
		by_lot = by_lot and (spots[s["kind"]] as Dictionary).has(ctx.sim.kind[int(s["lot"])])
	var some := kinds.has("pipe") and kinds.has("bat")
	K.check(fails, some, "weapons lie about the city (%s)" % str(kinds.keys()))
	K.check(fails, by_lot, "each by a lot of its kind (bats by homes, pipes by industry)")
	K.check(fails, ground, "on the ground, off the road")
	var a: Array = m.call("_find_spots")
	K.check(fails, a == m.get("spots"), "the same spots every time for a city")


## The interact feature picks out the weapon at the hero's feet; E takes it.
func _check_pick() -> void:
	var s := _spot("pipe")
	if s.is_empty():
		return
	_stand_by(s["pos"], 1.0)
	var it := _item_at(s["pos"])
	K.check(fails, it != null, "a weapon near the hero is drawn")
	if it == null:
		return
	var node: Node3D = it.get("node")
	var lying := node != null and node.is_inside_tree() and node.position.y > float(s["pos"].y)
	K.check(fails, lying, "lying on the ground")
	var p := ctx.player
	var eye := p.eye_position()
	var dir := ((s["pos"] as Vector3) - eye).normalized()
	var ia := K.make_feature(ctx, "interact")
	var t: Dictionary = ia.call("targets_along", eye, dir) if ia != null else {}
	var named := str(t.get("label", "")) == "Pick up the steel pipe"
	K.check(fails, str(t.get("kind")) == "weapon" and named, "E aims at it (%s)" % t.get("label"))
	if ia != null:
		ia.teardown()
		ctx.features.erase("interact")
		ia.free()
	var up := Vector3.UP
	K.check(fails, (m.call("pick", eye, up, 10.0) as Dictionary).is_empty(), "not looking away")
	ctx.bus.interact_requested.emit(t)
	var ok := str(m.get("held_kind")) == "pipe" and int(m.get("taken")) == 1
	K.check(fails, ok, "E picks it up (holding '%s')" % m.get("held_kind"))
	K.check(fails, _item_at(s["pos"]) == null, "and it is gone from the ground")
	m.call("refresh")
	K.check(fails, _item_at(s["pos"]) == null, "nor drawn there again with the hero about")


## A taken weapon lies at its spot again once the hero has been beyond HIDE_R; ones that far off
## are not drawn.
func _check_respawn() -> void:
	var s := _spot("pipe")
	if s.is_empty():
		return
	var p := ctx.player
	var far := (s["pos"] as Vector3) + Vector3(70.0 * WS.M, 0.0, 0.0)
	p.position = far
	m.call("refresh")
	K.check(fails, _item_at(s["pos"]) == null, "a weapon 70 m off is not drawn")
	var shown := true
	for it: Object in (m.get("items") as Dictionary).values():
		var d := Vector2((it.get("pos") as Vector3).x - far.x, (it.get("pos") as Vector3).z - far.z)
		shown = shown and d.length() < 60.0 * WS.M
	K.check(fails, shown, "nor any beyond 60 m")
	_stand_by(s["pos"], 1.0)
	K.check(fails, _item_at(s["pos"]) != null, "back again, the taken pipe lies there anew")
	m.call("from_dict", {})


func _check_hand() -> void:
	m.call("from_dict", {"held": "bat"})
	_step(0.3)
	var node: Node3D = m.get("_held_node")
	K.check(fails, node != null and node.is_inside_tree(), "a weapon in hand is drawn")
	if node == null or rig == null:
		return
	var hand: Vector3 = rig.call("bone_world", "RightHand")
	var d := node.global_position.distance_to(hand) / WS.M
	K.check(fails, d < 0.15, "in the right fist (%.2f m off)" % d)
	var tip := node.global_transform * (Vector3.UP * 0.7 * WS.M)
	var len_m := tip.distance_to(node.global_position) / WS.M
	K.check(fails, absf(len_m - 0.7) < 0.02, "at its own size (%.2f m)" % len_m)


## A bat swings further than a fist, as hard as a bat; the clips alternate; the third blow puts
## them down.
func _check_bat() -> void:
	m.call("from_dict", {})
	var w := K.person_ahead(ctx, tr, 1.5)
	hits.clear()
	_swing()
	K.check(fails, hits.is_empty(), "a fist does not reach someone 1.5 m off")
	m.call("from_dict", {"held": "bat"})
	hits.clear()
	blows.clear()
	acts.clear()
	_face(w, 1.5)
	var started: bool = act.call("strike") == true and str(act.get("swing")) == "swing"
	K.check(fails, started and acts == ["swing"], "with a bat the strike button swings it")
	_step(DT)
	var c1 := str(rig.tree.get("parameters/action/current_state")) if rig != null else ""
	_step(0.75)
	K.check(fails, hits.size() == 1, "the bat reaches them (%d blows)" % hits.size())
	var info: Dictionary = hits[0][2] if not hits.is_empty() else {}
	var hard := absf(float(info.get("strength", 0.0)) - 0.62) < 0.01
	var reel := hard and not bool(info.get("down", true))
	K.check(fails, reel, "as hard as a bat, and they reel (%s)" % str(info))
	var b: Array = blows[0] if blows.size() == 1 else [null, "", "", true]
	var heard := str(b[1]) == "bat" and str(b[2]) == "person" and not bool(b[3])
	K.check(fails, heard, "weapon_hit hears a bat on a person (%s)" % str(blows))
	_face(w, 1.5)
	act.call("strike")
	_step(DT)
	var c2 := str(rig.tree.get("parameters/action/current_state")) if rig != null else ""
	_step(0.75)
	var alt := rig == null or (c1 == "swing_a" and c2 == "swing_b")
	K.check(fails, alt, "forehand, then backhand (%s, %s)" % [c1, c2])
	_face(w, 1.5)
	_swing()
	var downs: Array[bool] = []
	for h: Array in hits:
		downs.append(bool((h[2] as Dictionary).get("down", false)))
	K.check(fails, downs == [false, false, true], "the third blow knocks them down %s" % str(downs))
	K.check(fails, str(m.get("held_kind")) == "bat", "the bat is still in hand")
	_remove(w)
	_step(0.5)


func _check_pipe() -> void:
	m.call("from_dict", {"held": "pipe"})
	var w := K.person_ahead(ctx, tr, 1.4)
	hits.clear()
	_swing()
	var info: Dictionary = hits[0][2] if hits.size() == 1 else {}
	K.check(fails, bool(info.get("down", false)), "a pipe's first blow knocks them down")
	_remove(w)
	_step(0.5)


func _check_bottle() -> void:
	m.call("from_dict", {"held": "bottle"})
	var w := K.person_ahead(ctx, tr, 1.0)
	hits.clear()
	blows.clear()
	var b0 := int(m.get("broken"))
	_swing()
	K.check(fails, hits.size() == 1, "a bottle lands (%d blows)" % hits.size())
	var b: Array = blows[0] if blows.size() == 1 else [null, "", "", false]
	var broke := str(b[1]) == "bottle" and bool(b[3]) and int(m.get("broken")) == b0 + 1
	K.check(fails, broke, "and breaks on it (%s)" % str(blows))
	var empty := str(m.get("held_kind")).is_empty() and m.get("_held_node") == null
	K.check(fails, empty, "leaving the hand empty")
	K.check(fails, m.get_node_or_null("Glass") is CPUParticles3D, "in a spray of glass")
	_remove(w)
	acts.clear()
	_swing()
	K.check(fails, acts == ["jab"], "then the hero punches again (%s)" % str(acts))
	_step(0.5)


## Z drops the weapon at the feet; one taken there swaps with the one in hand; getting into a car
## or being knocked down drops it.
func _check_drop() -> void:
	var p := ctx.player
	m.call("from_dict", {"held": "bat"})
	var n0 := (m.get("items") as Dictionary).size()
	m.call("_unhandled_input", K.action_event("act_drop"))
	var items: Dictionary = m.get("items")
	var ok := str(m.get("held_kind")).is_empty() and items.size() == n0 + 1
	K.check(fails, ok, "Z drops the bat (%d lying, %d before)" % [items.size(), n0])
	var it: Object = null
	for x: Object in items.values():
		if int(x.get("spot")) == -1:
			it = x
	var near := it != null and (it.get("pos") as Vector3).distance_to(p.position) < 0.8 * WS.M
	K.check(fails, near, "at the hero's feet")
	K.check(fails, m.call("drop") == false, "nothing more to drop")
	m.call("from_dict", {"held": "pipe"})
	var swapped: bool = it != null and m.call("take", int(it.get("id"))) == true
	var back: Object = _item_at(it.get("pos")) if it != null else null
	swapped = swapped and str(m.get("held_kind")) == "bat"
	swapped = swapped and back != null and str(back.get("kind")) == "pipe"
	K.check(fails, swapped, "taking the bat with a pipe in hand leaves the pipe there")
	ctx.bus.drive_changed.emit(true)
	K.check(fails, str(m.get("held_kind")).is_empty(), "getting into a car drops it")
	ctx.bus.drive_changed.emit(false)
	m.call("from_dict", {"held": "bat"})
	ctx.bus.hero_hurt.emit(10.0, "punch", 80.0, false)
	K.check(fails, str(m.get("held_kind")) == "bat", "a blow the hero shrugs off keeps it")
	ctx.bus.hero_hurt.emit(30.0, "car", 50.0, true)
	K.check(fails, str(m.get("held_kind")).is_empty(), "a knock-down drops it")
	_step(0.3)


func _check_save() -> void:
	m.call("from_dict", {"held": "pipe"})
	var d: Dictionary = m.to_dict()
	K.check(fails, d == {"held": "pipe"}, "to_dict keeps the weapon in hand (%s)" % str(d))
	m.call("from_dict", {"held": "sword"})
	var none := str(m.get("held_kind")).is_empty() and m.to_dict().is_empty()
	K.check(fails, none, "an unknown weapon in a save is ignored")


func _check_flag() -> void:
	FeatureFlags.set_override("melee", false)
	m.on_world_rebuilt()
	K.check(fails, (m.get("items") as Dictionary).is_empty(), "with the flag off none are drawn")
	FeatureFlags.set_override("melee", true)
	m.on_world_rebuilt()
	_stand_by(_spot("pipe").get("pos", Vector3.ZERO), 1.0)
	K.check(fails, not (m.get("items") as Dictionary).is_empty(), "on again they are")


func _check_teardown() -> void:
	m.call("from_dict", {"held": "bat"})
	m.teardown()
	var left := 0
	for c: Node in m.get_children():
		if not c.is_queued_for_deletion() and c is MeshInstance3D:
			left += 1
	var clean := left == 0 and (m.get("items") as Dictionary).is_empty()
	K.check(fails, clean and str(m.get("held_kind")).is_empty(), "teardown clears every weapon")
