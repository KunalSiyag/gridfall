extends Node3D
## One crew at work on its site (feature "crews"): a foreman beside the gate keeping an eye on
## things, two builders at the spots nearest the middle and a hauler carrying crates from a pile
## inside the gate to a drop point by the builders, under a board that names the crew, the order,
## the stage and the time left. What the builders do follows the stage. A crew that takes an
## order while you play walks in through the gate. Every place and every way comes from the site's
## CrewGrid (CrewSpots), so nobody stands or walks in the hoarding, a machine or the frame, and a
## worker climbs onto a slab or over a berm instead of through it; place() runs again when the
## site is redrawn for a new stage, and a worker whose spot moved walks over when it can.

const WS := preload("res://scripts/fp/world_scale.gd")
const S := preload("res://scripts/fp/ui/hud_style.gd")
const BODIES := preload("res://scripts/fp/crews/crew_bodies.gd")
const SPOTS := preload("res://scripts/fp/crews/crew_spots.gd")
## A crew, in order: the foreman takes the gate, the builders the work spots, the hauler the pile.
const ROLES: Array[String] = ["foreman", "builder", "builder", "hauler"]
## What the builders do in each stage; a looping clip is held HOLD seconds, a one-shot plays out.
const STAGE_CLIPS := {
	"clearing": [&"push", &"pickup", &"crouch_idle"],
	"excavation": [&"push", &"crouch_idle"],
	"grading": [&"push", &"crouch_idle"],
	"demolition": [&"push", &"interact"],
	"hauling": [&"pickup", &"push"],
	"foundation": [&"crouch_idle", &"interact"],
	"paving": [&"crouch_idle", &"push"],
	"piling": [&"interact", &"push"],
	"landscaping": [&"crouch_idle", &"pickup", &"interact"],
}
const BUILD_CLIPS: Array[StringName] = [&"interact", &"crouch_idle", &"interact", &"push"]
const FOREMAN_CLIPS: Array[StringName] = [&"idle_look", &"fold_arms", &"phone", &"idle_look"]
## A hauler with no clear way from the pile to the work sorts the pile instead.
const SORT_CLIPS: Array[StringName] = [&"crouch_idle", &"pickup", &"idle_look"]
const HOLD := Vector2(3.0, 6.0)
## One-shot lengths for a worker whose body has not loaded yet.
const ONE_SHOT_S := {&"pickup": 0.83, &"interact": 2.0}
## A worker is at a waypoint within this distance (world units).
const ARRIVE := 0.1 * WS.M
## Seconds between workers stepping off as a crew arrives.
const STAGGER := 0.8
## How quickly a worker turns toward where it goes or what it works on (1/s).
const TURN := 5.0
const BOARD_UP := 3.4 * WS.M
const BOARD_COLOR := Color(1.0, 0.84, 0.32)
const DUST_COLOR := Color(0.8, 0.74, 0.64, 0.38)
## The crew, its board and its dust show within this distance of the player (bodies end at
## VIS_PERSON anyway).
const NEAR := WS.VIS_PERSON + 0.5
## The interaction ray has to pass within PICK_R of a worker, up to PICK_H above its feet.
const PICK_R := 0.4 * WS.M
const PICK_H := 1.8 * WS.M
const CHEST := 1.3 * WS.M
## How long a worker stops to talk after E.
const TALK_S := 3.5

static var _dust_mat: StandardMaterial3D


## One worker: where it is and what it does. Its body (CrewBodies) appears once it has loaded.
class Worker:
	extends RefCounted
	var role: String = "builder"
	var body: BODIES.Body = null
	var kind: int = 0
	var jitter: float = 0.5
	var pos: Vector3 = Vector3(NAN, NAN, NAN)
	var yaw: float = 0.0
	## Where it works and what it faces there.
	var spot: Vector3 = Vector3(NAN, NAN, NAN)
	var face: Vector3 = Vector3(NAN, NAN, NAN)
	## Who it talks to after E.
	var look: Vector3 = Vector3(NAN, NAN, NAN)
	var path: Array[Vector3] = []
	## Where the walk to path[0] set off from (its height eases to path[0]'s on the way).
	var from: Vector3 = Vector3(NAN, NAN, NAN)
	## off (no room on the site), wait (to walk in), walk, work, take / put (a crate), talk.
	var state: String = "work"
	## The state a talk goes back to.
	var after: String = "work"
	## Seconds left in the current clip, and its whole length.
	var t: float = 0.0
	var span: float = 0.0
	var step: int = 0
	var carrying: bool = false
	var clip: StringName = &"idle"


var job_id: int = 0
var crew: int = 0
var tile: int = -1
## CrewSpots.layout of the site ({} before place()).
var spots: Dictionary = {}
var workers: Array[Worker] = []
var board: Label3D
var dust: CPUParticles3D
## The site's stage (a SITE_STAGES name), which picks what the builders do.
var stage: String = ""
var near: bool = true
var _bodies: BODIES
var _rng := RandomNumberGenerator.new()


## A crew of ROLES for job (a CitySim.crew_jobs entry) on tile i, its bodies from bodies.
func setup(bodies: BODIES, job: Dictionary, i: int) -> void:
	_bodies = bodies
	job_id = int(job["id"])
	crew = int(job["crew"])
	tile = i
	name = "Crew%d_%d" % [crew + 1, job_id]
	_rng.seed = hash([job_id, i])
	for k in range(ROLES.size()):
		var w := Worker.new()
		w.role = ROLES[k]
		w.kind = k + crew
		w.jitter = _rng.randf()
		w.step = _rng.randi_range(0, 3)
		workers.append(w)
	board = _make_board()
	add_child(board)
	dust = _make_dust()
	add_child(dust)


## Lays the crew out on the site as it is drawn now. With arrive the crew walks in from outside
## the gate; otherwise a worker walks to its new spot when it can get there, or is put there.
func place(ctx: FpContext, arrive: bool) -> void:
	spots = SPOTS.layout(ctx, tile, ROLES.count("builder"))
	var work: Array = spots["work"]
	var builders := 0
	for k in range(workers.size()):
		var w := workers[k]
		_assign(w, _spot_for(w.role, work, builders), k if arrive else -1)
		if w.role == "builder":
			builders += 1
	var gate: Vector3 = spots["gate"]
	board.position = (gate if SPOTS.found(gate) else spots["middle"]) + Vector3.UP * BOARD_UP
	dust.position = work[0] if not work.is_empty() else spots["middle"]


## Moves the crew on by dt seconds; it shows only near player_pos.
func step(dt: float, player_pos: Vector3) -> void:
	var middle: Vector3 = spots.get("middle", SPOTS.NONE)
	_set_near(SPOTS.found(middle) and _flat(player_pos, middle) < NEAR)
	var busy := false
	for w: Worker in workers:
		if w.state == "off":
			continue
		match w.state:
			"wait":
				w.t -= dt
				if w.t <= 0.0:
					w.state = "walk"
			"walk":
				_walk(w, dt)
			"work":
				_work(w, dt)
				busy = busy or w.role == "builder"
			"take", "put":
				_haul(w, dt)
			"talk":
				_talk(w, dt)
		if near:
			_show(w)
	dust.emitting = near and busy


## The board's two lines: the crew and the order, then the stage and the time left.
func set_board(title: String, line: String) -> void:
	board.text = "%s\n%s" % [title, line]


## Worker k stops what it is doing to talk to the player at `at` for TALK_S. False while it walks.
func greet(k: int, at: Vector3) -> bool:
	if k < 0 or k >= workers.size():
		return false
	var w := workers[k]
	if not w.state in ["work", "take", "put", "talk"]:
		return false
	if w.state != "talk":
		w.after = w.state
	w.state = "talk"
	w.look = at
	w.clip = &"talk"
	BODIES.play(w.body, &"talk")
	w.t = TALK_S
	return true


## The worker the ray from origin along dir passes within PICK_R of, nearest first, up to
## max_dist: {"k" (index in workers), "t" (distance along the ray), "pos" (its chest)}, or {}.
func pick(origin: Vector3, dir: Vector3, max_dist: float) -> Dictionary:
	var best := {}
	if not near:
		return best
	var end := origin + dir * max_dist
	for k in range(workers.size()):
		var w := workers[k]
		if w.body == null or w.state == "off" or w.state == "wait":
			continue
		var top := w.pos + Vector3.UP * PICK_H
		var seg := Geometry3D.get_closest_points_between_segments(origin, end, w.pos, top)
		if seg[0].distance_to(seg[1]) > PICK_R:
			continue
		var t := origin.distance_to(seg[0])
		if best.is_empty() or t < float(best["t"]):
			best = {"k": k, "t": t, "pos": w.pos + Vector3.UP * CHEST}
	return best


## How many workers are at work on the site with a body (tests and the self test).
func working() -> int:
	var n := 0
	for w: Worker in workers:
		n += 1 if w.body != null and w.state != "off" and w.state != "wait" else 0
	return n


## Gives every body back to the pool (before the rig is freed).
func release() -> void:
	for w: Worker in workers:
		if w.body != null:
			_bodies.release(w.body)
			w.body = null


# ------------------------------------------------------------------ layout


func _spot_for(role: String, work: Array, builders: int) -> Vector3:
	match role:
		"foreman":
			return spots["gate"]
		"hauler":
			return spots["pile"]
	return work[builders] if builders < work.size() else SPOTS.NONE


## Gives w its spot: it walks in from outside the gate (order: its place in the line, -1 for no
## walk-in), walks over from where it stands, or appears there.
func _assign(w: Worker, spot: Vector3, order: int) -> void:
	var drop: Vector3 = spots["drop"]
	w.spot = spot
	w.face = drop if w.role == "hauler" and SPOTS.found(drop) else spots["middle"]
	if not SPOTS.found(spot):
		_off(w)
		return
	var start: Vector3 = spots["out"]
	if order >= 0 and SPOTS.found(start):
		w.path = _arrival(start, spot)
		if not w.path.is_empty():
			w.pos = start
			w.from = start
			w.state = "wait"
			w.t = STAGGER * float(order)
			w.yaw = _heading(start, w.path[0], w.yaw)
			return
	if not SPOTS.found(w.pos) or w.state == "off":
		_put(w, spot)
		return
	var to := drop if w.role == "hauler" and w.carrying and SPOTS.found(drop) else spot
	if w.pos.distance_to(to) < ARRIVE and w.state != "walk" and w.state != "wait":
		return
	w.path = SPOTS.route(spots, w.pos, to)
	if w.path.is_empty():
		_put(w, spot)
	else:
		w.from = w.pos
		w.state = "walk"


## The way in from start outside the gate: through the gate to the door, then over the site to
## spot; [] when the door does not reach spot.
func _arrival(start: Vector3, spot: Vector3) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var door: Vector3 = spots.get("door", SPOTS.NONE)
	if not SPOTS.found(door) or start.distance_to(door) < ARRIVE:
		return out
	var rest := SPOTS.route(spots, door, spot)
	if rest.is_empty() and door.distance_to(spot) > ARRIVE:
		return out
	out.append(door)
	out.append_array(rest)
	return out


## No room for w on the site at this stage: it sits it out.
func _off(w: Worker) -> void:
	if w.body != null:
		_bodies.release(w.body)
		w.body = null
	w.state = "off"
	w.pos = SPOTS.NONE
	w.path.clear()
	w.carrying = false


func _put(w: Worker, p: Vector3) -> void:
	w.pos = p
	if SPOTS.found(w.face):
		w.yaw = _heading(p, w.face, w.yaw)
	_settle(w)


# ------------------------------------------------------------------ work


## w is where it was going: the hauler takes or sets down a crate, everyone else works.
func _settle(w: Worker) -> void:
	w.path.clear()
	if w.role == "hauler" and SPOTS.found(spots.get("drop", SPOTS.NONE)):
		_begin(w, "put" if w.carrying else "take")
	else:
		_begin(w, "work")


func _begin(w: Worker, st: String) -> void:
	w.state = st
	w.t = 0.0
	if st == "take" or st == "put":
		_play(w, &"pickup")


func _walk(w: Worker, dt: float) -> void:
	if w.path.is_empty():
		_settle(w)
		return
	var clip := &"carry" if w.carrying else &"walk"
	if w.clip != clip:
		w.clip = clip
		BODIES.play(w.body, clip)
	var to: Vector3 = w.path[0]
	var d := Vector3(to.x - w.pos.x, 0.0, to.z - w.pos.z)
	var dist := d.length()
	var move := _bodies.speed(w.body, clip) * dt
	if dist <= maxf(move, ARRIVE):
		w.pos = to
		w.from = to
		w.path.pop_front()
		if w.path.is_empty():
			_settle(w)
		return
	w.pos += d / dist * move
	w.pos.y = _ease_y(w, to, dist - move)
	w.yaw = lerp_angle(w.yaw, atan2(d.x, d.z), minf(1.0, dt * TURN))


## w's height on the way from w.from to `to` with `left` still to go: up or down a step, a slab
## or a berm as it goes.
static func _ease_y(w: Worker, to: Vector3, left: float) -> float:
	var span := _flat(w.from, to) if SPOTS.found(w.from) else 0.0
	if span < 1e-6:
		return to.y
	return lerpf(w.from.y, to.y, clampf(1.0 - left / span, 0.0, 1.0))


func _work(w: Worker, dt: float) -> void:
	_turn_to(w, w.face, dt)
	w.t -= dt
	if w.t > 0.0:
		return
	var list := _clips(w)
	_play(w, list[w.step % list.size()])
	w.step += 1


func _clips(w: Worker) -> Array:
	match w.role:
		"foreman":
			return FOREMAN_CLIPS
		"hauler":
			return SORT_CLIPS
	return STAGE_CLIPS.get(stage, BUILD_CLIPS)


## Picking a crate up at the pile (take) or setting it down by the work (put): the crate comes or
## goes half way through, then the hauler sets off the other way.
func _haul(w: Worker, dt: float) -> void:
	_turn_to(w, w.face if w.state == "take" else spots["middle"], dt)
	w.t -= dt
	if w.t <= w.span * 0.5:
		w.carrying = w.state == "take"
	if w.t > 0.0:
		return
	w.path.assign(spots["haul"] if w.carrying else spots["back"])
	if w.path.is_empty():
		w.path.append(spots["drop"] if w.carrying else spots["pile"])
	w.from = w.pos
	w.state = "walk"


func _talk(w: Worker, dt: float) -> void:
	_turn_to(w, w.look, dt)
	w.t -= dt
	if w.t <= 0.0:
		_begin(w, w.after)


## Plays clip on w and sets how long w keeps at it: a one-shot to its end, a loop HOLD seconds.
func _play(w: Worker, clip: StringName) -> void:
	w.clip = clip
	BODIES.play(w.body, clip)
	var ap := w.body.ap if w.body != null else null
	var hold := _rng.randf_range(HOLD.x, HOLD.y)
	if ap != null and ap.has_animation(clip):
		var a := ap.get_animation(clip)
		w.t = a.length if a.loop_mode == Animation.LOOP_NONE else hold
	else:
		w.t = float(ONE_SHOT_S.get(clip, hold))
	w.span = w.t


func _turn_to(w: Worker, p: Vector3, dt: float) -> void:
	if not SPOTS.found(p) or _flat(w.pos, p) < ARRIVE:
		return
	w.yaw = lerp_angle(w.yaw, _heading(w.pos, p, w.yaw), minf(1.0, dt * TURN))


# ------------------------------------------------------------------ bodies


## Puts w's body where w is (making it once its scene has loaded), with the crate while carrying.
func _show(w: Worker) -> void:
	if w.body == null:
		w.body = _bodies.make(w.kind, w.jitter, self)
		if w.body == null:
			return
		if w.role == "hauler":
			_bodies.add_crate(w.body)
		BODIES.play(w.body, w.clip, 0.0)
	var r := w.body.root
	r.visible = w.state != "wait"
	r.position = w.pos
	r.rotation.y = w.yaw
	if w.body.crate != null:
		w.body.crate.visible = w.carrying


## Out of sight the crew stops drawing and animating (it keeps working).
func _set_near(on: bool) -> void:
	if on == near:
		return
	near = on
	visible = on
	for w: Worker in workers:
		if w.body != null and w.body.ap != null:
			w.body.ap.active = on


static func _heading(a: Vector3, b: Vector3, fallback: float) -> float:
	var d := Vector2(b.x - a.x, b.z - a.z)
	return fallback if d.length_squared() < 1e-12 else atan2(d.x, d.y)


static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


# ------------------------------------------------------------------ board and dust


func _make_board() -> Label3D:
	var l := Label3D.new()
	l.name = "Board"
	l.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	l.font = S.bold()
	l.font_size = 40
	l.pixel_size = 0.0003
	l.outline_size = 12
	l.outline_modulate = Color(0.02, 0.03, 0.05, 0.9)
	l.modulate = BOARD_COLOR
	l.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	l.visibility_range_end = NEAR
	l.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return l


## Soft puffs of dust drifting up from the work while the builders are at it.
func _make_dust() -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.name = "Dust"
	p.emitting = false
	p.amount = 10
	p.lifetime = 2.4
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 0.6 * WS.M
	p.direction = Vector3.UP
	p.spread = 70.0
	p.gravity = Vector3(0.0, 0.04 * WS.M, 0.0)
	p.initial_velocity_min = 0.1 * WS.M
	p.initial_velocity_max = 0.35 * WS.M
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.6
	var fade := Gradient.new()
	fade.set_color(0, Color(DUST_COLOR, 0.0))
	fade.set_color(1, Color(DUST_COLOR, 0.0))
	fade.add_point(0.3, DUST_COLOR)
	p.color_ramp = fade
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * (0.7 * WS.M)
	quad.material = _dust_material()
	p.mesh = quad
	p.visibility_range_end = NEAR
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return p


## A round, soft-edged billboard tinted by each particle's colour (shared by every crew).
static func _dust_material() -> StandardMaterial3D:
	if _dust_mat != null:
		return _dust_mat
	var soft := Gradient.new()
	soft.set_color(0, Color(1, 1, 1, 1))
	soft.set_color(1, Color(1, 1, 1, 0))
	var tex := GradientTexture2D.new()
	tex.gradient = soft
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(0.5, 0.0)
	tex.width = 64
	tex.height = 64
	_dust_mat = StandardMaterial3D.new()
	_dust_mat.albedo_texture = tex
	_dust_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_dust_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	_dust_mat.vertex_color_use_as_albedo = true
	_dust_mat.roughness = 1.0
	return _dust_mat
