extends SceneTree
## Dogs (integration feature "animals"; docs/fp/ARCHITECTURE.md, Animals): a resident who lives
## with a dog comes out with it on its lead and walks it at heel (at their left, the Walk clip,
## the lead drawn from their hand to its collar); standing still they let it off to roam, walking
## on they call it back; E on a dog close by pets it (the pick, the hop, the wag, a toast) and
## one out of reach is not picked; the hero punching its owner sets it on them (a growl, the Attack
## clip, bites on hero_hit "bite" taking health, at most DogPack.BITES) and it will not be petted
## then; a shout makes it flinch and bark; a car about to run it down makes it leap aside,
## whining; pause freezes it; walking off beyond FAR takes the dogs away and coming back brings
## the same dog; the photo shot (a Shiba Inu and a husky in a front yard); a dog household keeps
## its dog in the front yard, the resident coming out takes it along and it goes back when they
## go in; a young city (only the founding roads and City Hall) has half as many again of the
## people passing through walking a dog, and grown the share settles back; self_test and teardown.
## Third person on a grown city; time runs through the feature's tick(1/60), traffic's step and
## the player's update_view.

const K := preload("res://tools/tests/fp_kit.gd")
const FRESH := preload("res://tools/tests/fp_fresh_city.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const AF := preload("res://scripts/fp/animals/animals_feature.gd")
const PACK := preload("res://scripts/fp/animals/dog_pack.gd")
const BODIES := preload("res://scripts/fp/animals/dog_bodies.gd")
const DT := 1.0 / 60.0
const WALK_MPS := 1.4

var fails: Array[String] = []
var ctx: FpContext
var tr: FpFeature
var health: FpFeature
var f: FpFeature
var pack: PACK
## The straight sidewalk the owner walks along (K.sidewalk).
var walk: Dictionary = {}
## Every animal_called [call, size], the strength of every bite (hero_hit "bite") and every toast.
var calls: Array = []
var bites: Array[float] = []
var toasts: Array[String] = []


func _init() -> void:
	await process_frame
	# The pigeons' and the cats' calls would mix with the dogs' (fp_pigeons_test and fp_cats_test
	# have them).
	FeatureFlags.set_override("pigeons", false)
	FeatureFlags.set_override("cats", false)
	ctx = K.make_ctx(get_root(), {"view": true, "grow": true, "camera_mode": "third"})
	ctx.player.set_process(false)
	tr = K.make_feature(ctx, "traffic")
	health = K.make_feature(ctx, "health")
	f = K.make_feature(ctx, "animals")
	walk = K.sidewalk(ctx, 0.6)
	if tr == null or health == null or f == null or walk.is_empty():
		K.check(
			fails, false, "fixture: traffic, health and animals registered, a straight sidewalk"
		)
		K.finish(self, "FP_ANIMALS_TEST", fails)
		return
	tr.set("auto_step", false)
	tr.set("ambient_enabled", false)
	health.set_process(false)
	f.set_process(false)
	pack = f.get("pack")
	(f.get("bodies") as BODIES).blocking = true
	_quiet()
	_no_dogs_at_home()
	ctx.bus.animal_called.connect(
		func(_at: Vector3, c: String, s: float) -> void: calls.append([c, s])
	)
	ctx.bus.hero_hit.connect(
		func(_at: Vector3, c: String, s: float, _p: Vector3) -> void:
			if c == "bite":
				bites.append(s)
	)
	ctx.bus.toast.connect(func(t: String, _k: String) -> void: toasts.append(t))
	ctx.sky.fixed_hour = 12.0
	ctx.sky.hour = 12.0
	ctx.sky.night = 0.0
	ctx.player.teleport(walk["pos"], float(walk["yaw"]))
	var w := _check_lead()
	var d := _dog_of(w)
	if d != null:
		_check_roam(w, d)
		_check_pet(d)
		_check_defend(w, d)
		_check_startle(d)
		_check_dodge(d)
		_check_pause(d)
		_check_far(w, d)
	_check_yard()
	_check_young_city()
	_check_teardown()
	K.finish(self, "FP_ANIMALS_TEST", fails)


# ------------------------------------------------------------------ helpers


## Steps traffic, the dogs and the player secs (in 1/60 s steps).
func _step(secs: float) -> void:
	for _k in range(ceili(secs / DT - 1e-6)):
		tr.call("step", DT)
		f.call("tick", DT)
		ctx.player.simulate(Vector2.ZERO, false, DT)
		ctx.player.update_view(DT)


## One step with w walking mps along the sidewalk (traffic leaves a standing walker be).
func _walk_on(w: WK.Walker, mps: float) -> void:
	var run: Vector3 = walk["run"]
	var p := w.pos + run * mps * WS.M * DT
	var y := ctx.collision.walk_height(p)
	p.y = y if not is_nan(y) else w.pos.y
	w.pos = p
	w.yaw = atan2(run.x, run.z)
	_step(DT)


## Removes every walker, so only the test's own people are about.
func _quiet() -> void:
	var wk: WK = tr.get("walkers")
	for w: WK.Walker in wk.walkers.duplicate():
		wk.remove(w)


## Nobody in the city lives with a dog but the test's own owners.
func _no_dogs_at_home() -> void:
	for r: Dictionary in ctx.residents.people:
		if str(r.get("household", "")) == AF.DOG_HOUSEHOLD:
			r["household"] = "lives alone"


## The k-th resident with a home, made to live with a dog and to be out (state).
func _owner(k: int, state: String) -> Dictionary:
	var n := 0
	for r: Dictionary in ctx.residents.people:
		if int(r.get("home", -1)) < 0:
			continue
		if n == k:
			r["household"] = AF.DOG_HOUSEHOLD
			r["state"] = state
			return r
		n += 1
	return {}


func _dog_of(w: WK.Walker) -> PACK.Dog:
	for d: PACK.Dog in pack.dogs:
		if d.walker == w.id:
			return d
	return null


func _dog_by_key(key: String) -> PACK.Dog:
	for d: PACK.Dog in pack.dogs:
		if d.key == key:
			return d
	return null


## The hero dist_m metres back along the sidewalk from the dog, facing it.
func _face(d: PACK.Dog, dist_m: float) -> void:
	var run: Vector3 = walk["run"]
	var at := d.pos - run * dist_m * WS.M
	var y := ctx.collision.walk_height(at)
	at.y = y if not is_nan(y) else d.pos.y
	var look := d.pos - at
	ctx.player.teleport(at, rad_to_deg(atan2(-look.x, -look.z)))


## The middle of the dog's back (what E aims at).
func _back(d: PACK.Dog) -> Vector3:
	return d.pos + Vector3(0.0, 0.75 * pack.shoulder_m(d) * WS.M, 0.0)


func _leads() -> int:
	return int((f.get("leads") as Node).get("count"))


func _called(c: String) -> bool:
	for e: Array in calls:
		if str(e[0]) == c:
			return true
	return false


# ------------------------------------------------------------------ checks


## A resident who lives with a dog stands ahead on the sidewalk: their dog comes out at their side
## on its lead; walking on 4 s, it heels at their left within the lead, at their pace on the Walk
## clip, the lead drawn.
func _check_lead() -> WK.Walker:
	var r := _owner(0, "park")
	var wk: WK = tr.get("walkers")
	var w := wk.make("resident")
	w.extra = 0
	w.resident_id = str(r["id"])
	var run: Vector3 = walk["run"]
	wk.stand(w, (walk["pos"] as Vector3) + run * 0.05, atan2(run.x, run.z))
	_step(0.1)
	var d := _dog_of(w)
	var first := str(r["name"]).get_slice(" ", 0)
	K.check(
		fails,
		d != null and d.key == "r:" + w.resident_id and d.owner_name == first and d.mode == "heel",
		(
			"lead: a resident who lives with a dog comes out with it (r:<id>, %s's, on the lead)"
			% first
		)
	)
	if d == null:
		return w
	var b := d.body
	var rigged := b.skel != null and b.ap != null and b.rig != null
	K.check(
		fails,
		rigged and b.ap.has_animation(&"Gallop") and b.ap.has_animation(&"Attack"),
		"lead: the dog is the rigged %s with its clips and a DogRig" % d.breed
	)
	var worst := 0.0
	var left := 0.0
	var n := 0
	for k in range(roundi(4.0 / DT)):
		_walk_on(w, WALK_MPS)
		if k * DT < 1.5:
			continue
		var off := d.pos - w.pos
		off.y = 0.0
		worst = maxf(worst, off.length())
		left += off.dot(Vector3(cos(w.yaw), 0.0, -sin(w.yaw)))
		n += 1
	left /= maxf(n, 1)
	K.check(
		fails,
		worst <= PACK.LEAD * 1.02 and left > 0.15 * WS.M,
		(
			"lead: it heels at the owner's left (%.2f m) within the lead (%.2f m at most)"
			% [left / WS.M, worst / WS.M]
		)
	)
	K.check(
		fails,
		b.clip == &"Walk" and absf(d.speed - WALK_MPS * WS.M) < 0.3 * WS.M,
		"lead: at the owner's pace on the Walk clip (%s, %.2f m/s)" % [b.clip, d.speed / WS.M]
	)
	K.check(fails, _leads() == 1 and d.clipped, "lead: the lead is drawn (%d)" % _leads())
	return w


## The owner stops: after UNCLIP_S the dog is off its lead (none drawn) and roams; walking on,
## they call it back to heel on the lead.
func _check_roam(w: WK.Walker, d: PACK.Dog) -> void:
	_step(PACK.UNCLIP_S + 1.0)
	K.check(
		fails,
		d.mode == "roam" and not d.clipped and _leads() == 0,
		"roam: the owner standing lets it off the lead (%s, %d leads)" % [d.mode, _leads()]
	)
	for _k in range(roundi(2.5 / DT)):
		_walk_on(w, WALK_MPS)
	var far := Vector2(d.pos.x - w.pos.x, d.pos.z - w.pos.z).length()
	K.check(
		fails,
		d.mode == "heel" and d.clipped and far <= PACK.LEAD * 1.02 and _leads() == 1,
		"roam: walking on calls it back to heel on the lead (%.2f m)" % (far / WS.M)
	)


## The hero steps up to the dog: E on it ("Pet <name>, <owner>'s <breed>") makes it hop and wag,
## with a toast; a dog 4 m off is out of reach.
func _check_pet(d: PACK.Dog) -> void:
	d.temper = "friendly"
	_face(d, 1.0)
	var eye := ctx.player.eye_position()
	var t := f.pick(eye, (_back(d) - eye).normalized(), 3.0)
	var label := "Pet %s, %s's %s" % [d.name, d.owner_name, AF.BREED_NAMES[d.breed]]
	K.check(
		fails,
		str(t.get("kind", "")) == "dog" and str(t.get("label", "")) == label,
		"pet: the dog in front is picked (%s)" % str(t.get("label", ""))
	)
	toasts.clear()
	ctx.bus.interact_requested.emit(t)
	var hop := int(f.get("pets")) == 1 and d.act == "hop" and d.happy >= 1.0
	K.check(
		fails,
		hop and toasts.size() == 1 and toasts[0].begins_with(d.name),
		"pet: E pets it, it hops (%s) with a toast (%s)" % [d.act, str(toasts)]
	)
	_step(1.5)
	K.check(fails, d.body.rig.wag > 0.5, "pet: its tail wags (%.2f)" % d.body.rig.wag)
	_face(d, 4.0)
	eye = ctx.player.eye_position()
	t = f.pick(eye, (_back(d) - eye).normalized(), 6.0)
	K.check(fails, t.is_empty(), "pet: a dog 4 m off is out of reach")


## The hero punches the owner: the dog growls and will not be petted, lunges (Attack) and bites
## (hero_hit "bite" at BITE, health lost) at most BITES times, then calms down.
func _check_defend(w: WK.Walker, d: PACK.Dog) -> void:
	var p := ctx.player
	p.input_enabled = true
	_face(d, 1.0)
	calls.clear()
	bites.clear()
	var hp0 := float(health.get("hp"))
	tr.call("hit_walker", w.id, p.position, Vector3.ZERO, 0.4, "punch")
	K.check(
		fails,
		d.angry > 0.0 and _called("growl"),
		"defend: punching the owner sets the dog on the hero, growling"
	)
	toasts.clear()
	ctx.bus.interact_requested.emit({"kind": "dog", "id": str(d.id)})
	K.check(
		fails,
		int(f.get("pets")) == 1 and toasts.size() == 1 and "growls" in toasts[0],
		"defend: it will not be petted now (%s)" % str(toasts)
	)
	var lunged := false
	for _k in range(roundi(4.0 / DT)):
		_step(DT)
		lunged = lunged or d.body.clip == &"Attack"
	var lost := hp0 - float(health.get("hp"))
	K.check(
		fails,
		lunged and bites.size() >= 1 and bites.size() <= PACK.BITES and lost > 0.0,
		"defend: it lunges and bites (%d bites, %.1f health)" % [bites.size(), lost]
	)
	var strong := bites.all(func(s: float) -> bool: return is_equal_approx(s, AF.BITE))
	K.check(fails, strong and _called("bark"), "defend: bites at BITE, barking between")
	p.input_enabled = false
	_step(4.0)
	K.check(fails, d.angry <= 0.0, "defend: it calms down after its bites (%.1f s)" % d.angry)


## A shout close by makes the dog flinch (an Idle_HitReact clip) and bark.
func _check_startle(d: PACK.Dog) -> void:
	d.temper = "friendly"
	d.bark_cool = 0.0
	d.barks = 0
	calls.clear()
	ctx.bus.hero_action.emit("shout", ctx.player.position)
	_step(0.2)
	var size := pack.shoulder_m(d)
	var heard := not calls.is_empty() and is_equal_approx(float(calls[0][1]), size)
	K.check(
		fails,
		d.act == "flinch" and str(d.body.clip).begins_with("Idle_HitReact") and _called("bark"),
		"startle: a shout makes it flinch (%s) and bark" % d.body.clip
	)
	K.check(
		fails, heard, "startle: animal_called carries its height at the shoulder (%.2f m)" % size
	)
	_step(1.0)


## A car about to run the dog down makes it leap aside, out of the car's path, whining.
func _check_dodge(d: PACK.Dog) -> void:
	calls.clear()
	var run: Vector3 = walk["run"]
	var left := Vector3(run.z, 0.0, -run.x)
	var car := [d.pos - run * 3.0 * WS.M + left * 0.3 * WS.M, run * 10.0 * WS.M, 2.3 * WS.M, WS.M]
	var p0 := d.pos
	var fled := false
	for _k in range(30):
		pack.cars = [car]
		pack.step(DT)
		fled = fled or d.act == "flee"
	pack.cars = []
	var aside := (d.pos - p0).dot(-left)
	K.check(
		fails,
		fled and aside > 0.4 * WS.M and _called("whine"),
		"dodge: a car coming at it makes it leap aside (%.2f m), whining" % (aside / WS.M)
	)
	_step(1.0)


## Paused (sim speed 0) it stands frozen: no motion, its clip and its tail stopped.
func _check_pause(d: PACK.Dog) -> void:
	d.happy = 1.0
	ctx.sim.speed = 0
	_step(DT)
	var p0 := d.pos
	var wag0: float = d.body.rig.get("_phase")
	_step(1.0)
	var still := d.pos == p0 and is_equal_approx(float(d.body.rig.get("_phase")), wag0)
	var stopped := d.body.ap.speed_scale == 0.0 and d.body.rig.pace == 0.0
	ctx.sim.speed = 1
	_step(0.2)
	K.check(
		fails,
		still and stopped and d.body.ap.speed_scale > 0.0,
		"pause: the dog freezes (clip and tail stopped) and comes back to life"
	)


## The hero going beyond FAR takes the dogs off the street; coming back brings the same dog.
func _check_far(w: WK.Walker, d: PACK.Dog) -> void:
	var p := ctx.player
	var home := p.position
	var made := (f.get("bodies") as BODIES).made
	p.teleport(home + Vector3(AF.FAR + 1.0, 0.0, 0.0), rad_to_deg(p.yaw))
	_step(AF.SCAN_S + 0.1)
	var gone := pack.dogs.is_empty() and (f.get("_root") as Node3D).get_child_count() == 0
	p.teleport(home, rad_to_deg(p.yaw))
	_step(AF.SCAN_S + 0.1)
	var again := _dog_of(w)
	var same := again != null and again.name == d.name and again.breed == d.breed
	same = same and (f.get("bodies") as BODIES).made == made
	K.check(fails, gone, "far: beyond FAR the dogs go")
	K.check(fails, same, "far: back again, the same dog comes out (a pooled body)")
	(tr.get("walkers") as WK).remove(w)


## The photo shot: a Shiba Inu and a husky in the front yard of the nearest house, gone after. A
## dog household with nobody out keeps its dog in that yard; the resident coming out takes it on
## the lead and it goes back to the yard LOST_S after they go in.
func _check_yard() -> void:
	f.on_world_rebuilt()
	var shots := f.photo_shots()
	K.check(fails, shots.size() == 1 and str(shots[0]["name"]) == "dogs", "photo: one dogs shot")
	if shots.is_empty():
		return
	ctx.player.teleport(shots[0]["pos"], float(shots[0]["yaw"]))
	f.call(str(shots[0]["prepare"]))
	var breeds := {}
	var lot := -1
	for d: PACK.Dog in pack.dogs:
		if d.key.begins_with("photo:") and d.mode == "yard":
			breeds[d.breed] = d.lot_box.has_point(Vector2(d.pos.x, d.pos.z))
			lot = d.lot
	K.check(
		fails,
		breeds.size() == 2 and not false in breeds.values(),
		"photo: a Shiba Inu and a husky in the front yard (%s)" % str(breeds)
	)
	f.call(str(shots[0]["restore"]))
	K.check(fails, pack.dogs.is_empty(), "photo: restore takes them away")
	var r := _owner(1, "home")
	r["home"] = lot
	ctx.sky.night = 1.0
	f.on_world_rebuilt()
	_step(0.1)
	K.check(fails, pack.dogs.is_empty(), "yard: at night the dogs stay in")
	ctx.sky.night = 0.0
	f.on_world_rebuilt()
	_step(0.1)
	var d := _dog_by_key("r:" + str(r["id"]))
	K.check(
		fails,
		d != null and d.mode == "yard" and d.lot == lot,
		"yard: the household's dog is out in its front yard by day"
	)
	if d == null:
		return
	var inside := true
	for _k in range(roundi(8.0 / DT)):
		_step(DT)
		inside = inside and d.lot_box.grow(0.01).has_point(Vector2(d.pos.x, d.pos.z))
	K.check(fails, inside, "yard: it keeps to the front of its lot for 8 s")
	var wk: WK = tr.get("walkers")
	var w := wk.make("resident")
	w.extra = 0
	w.resident_id = str(r["id"])
	wk.stand(w, d.anchor + Vector3(0.02, 0.0, 0.0), 0.0)
	_step(AF.SCAN_S + 0.1)
	K.check(
		fails, d.walker == w.id and d.mode == "heel", "yard: the resident coming out takes it along"
	)
	wk.remove(w)
	_step(AF.LOST_S + AF.SCAN_S + 0.2)
	K.check(
		fails,
		d.walker == -1 and d.mode == "yard" and d.lot == lot,
		"yard: back to its yard when they go in"
	)


## A young city (no growth: only the founding roads and City Hall): half as many again of the
## people passing through walk a dog (WALK_SHARE_EARLY), so with walkers about near the player a
## dog is out within the first minute; once the city has grown the share settles back
## (WALK_SHARE), and people passing still walk a dog now and then.
func _check_young_city() -> void:
	var fresh := FRESH.make(get_root())
	if not bool(fresh["ok"]):
		K.check(fails, false, "young: fixture: traffic and animals registered")
		return
	(fresh["bodies"] as BODIES).blocking = true
	var fpack: PACK = fresh["pack"]
	var fctx: FpContext = fresh["ctx"]
	var ftr: FpFeature = fresh["traffic"]
	var ff: FpFeature = fresh["animals"]
	var wks: WK = ftr.get("walkers")
	var me: Vector3 = fctx.player.position
	for k in range(20):
		var w := wks.make("ambient")
		w.extra = 0
		var at := me + Vector3((k - 10) * 0.12, 0.0, 0.0)
		var y := fctx.collision.walk_height(at)
		wks.stand(w, Vector3(at.x, y if not is_nan(y) else at.y, at.z), 0.0)
	FRESH.step(ftr, ff, AF.SCAN_S + 0.1)
	var dogs := 0
	for d: PACK.Dog in fpack.dogs:
		dogs += 1 if d.walker >= 0 else 0
	var share: float = ff.call("_walk_share")
	K.check(
		fails,
		dogs >= 1 and is_equal_approx(share, AF.WALK_SHARE_EARLY),
		"young: with people passing, a dog is out at once (%d dogs, share %.2f)" % [dogs, share]
	)
	K.grow(fctx.sim, fctx.residents)
	var tries := 0
	while ff.call("_built_lots") < AF.YOUNG_LOTS and tries < 6:
		K.ticks(fctx.sim, 40)
		tries += 1
	ff.call("_read_homes")
	var grown: float = ff.call("_walk_share")
	K.check(
		fails,
		is_equal_approx(grown, AF.WALK_SHARE),
		"young: grown, the share settles back (%.2f)" % grown
	)
	var ids := {}
	for k in range(30):
		var w := wks.make("ambient")
		w.extra = 0
		ids[w.id] = true
		var at := me + Vector3((k - 15) * 0.08, 0.0, 0.1)
		var y := fctx.collision.walk_height(at)
		wks.stand(w, Vector3(at.x, y if not is_nan(y) else at.y, at.z), 0.0)
	FRESH.step(ftr, ff, AF.SCAN_S + 0.1)
	var grown_dogs := 0
	for d: PACK.Dog in fpack.dogs:
		grown_dogs += 1 if ids.has(d.walker) else 0
	K.check(
		fails,
		grown_dogs >= 2,
		"young: grown, people passing still walk dogs (%d of 30)" % grown_dogs
	)


func _check_teardown() -> void:
	var st := f.self_test()
	K.check(fails, bool(st["ok"]), "self_test: %s" % st["detail"])
	var root: Node3D = f.get("_root")
	f.teardown()
	K.check(
		fails,
		pack.dogs.is_empty() and root.get_child_count() == 0 and _leads() == 0,
		"teardown: no dogs, bodies or leads left"
	)
