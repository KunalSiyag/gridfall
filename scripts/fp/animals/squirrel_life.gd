extends RefCounted
## The squirrels' behaviour; the squirrels node (squirrels.gd) decides where each keeps (a lawn and
## its tree), feeds the world before every step() and draws them (squirrel_body.gd's mesh, one
## MultiMesh). A squirrel forages round its spot: it bounds from place to place in the gait's hops,
## stops, sits up on its haunches and nibbles with its paws at its mouth, its tail swaying behind
## it. A fright — the hero walking up to it or sprinting near, a dog close by or running, a person
## stepping on it — and it chatters once, dashes for its tree and runs up the trunk, clinging there
## head-up until the trouble has gone, then comes back down to its lawn. Two squirrels whose
## lawns touch now and then chase one another instead: one runs a spiral round its trunk, the
## other cuts straight after it, both chattering, and a catch swaps who chases whom — a game,
## and it yields to any real fright.

const WS := preload("res://scripts/fp/world_scale.gd")

## A bound: BOUND_MPS (m/s) eating ground in HOP_S (s) hops that lift the body HOP_UP (m).
const BOUND_MPS := 3.2 * WS.M
const HOP_S := 0.19
const HOP_UP := 0.05 * WS.M
## An amble between close spots (m/s), turning (rad/s).
const AMBLE := 0.9 * WS.M
const TURN := 7.0
## Sitting up to nibble lasts NIBBLE_S (s); now and then a pause without it.
const NIBBLE_S := Vector2(0.7, 1.6)
const PAUSE_S := Vector2(0.2, 0.6)
## Fleeing: a dash of DASH_MPS (m/s) to the tree, a climb of CLIMB_MPS (m/s) up it to CLING_H (m),
## and holding there until CALM_S (s) after the last fright; then down again.
const DASH_MPS := 4.6 * WS.M
const CLIMB_MPS := 1.4 * WS.M
const CLING_H := 2.2 * WS.M
const CALM_S := 3.0
## The frights: the hero on foot within WARY (m) or sprinting within SPRINT (m) of it, a dog
## within DOG_NEAR (m) or running (faster than DOG_RUN_MPS) within DOG_FAR (m), and anyone
## stepping within TRAMPLE (m). A cat counts only within CAT_NEAR (one stalking low and slow gets
## that close) or running (a pounce).
const WARY := 2.6 * WS.M
const SPRINT := 5.5 * WS.M
const SPRINT_MPS := 2.8 * WS.M
const DOG_NEAR := 3.5 * WS.M
const DOG_FAR := 7.0 * WS.M
const DOG_RUN_MPS := 2.5 * WS.M
const TRAMPLE := 0.9 * WS.M
const CAT_NEAR := 0.8 * WS.M
## Once it is up, nothing but the calm clock brings it down.
const UP_KEEP := 6.0
## The chatters it gives while it flees (animal_called), each at most every CHATTER_S (s).
const CHATTER_S := 1.5

## The chase (play): homes within PLAY_NEAR (m) are playmates; a calm foraging pair starts a
## chase at PLAY_ODDS a second, each round PLAY_ROUND_S (s) long. The one chased runs its spiral
## at PLAY_MPS (m/s), its circle breathing between SPIRAL_R (m) round the trunk; the chaser cuts
## after it a touch faster (PLAY_CHASE_MPS, m/s — the chase must end in a catch), counting one
## within PLAY_CATCH (m).
const PLAY_NEAR := 2.5 * WS.M
const PLAY_ODDS := 0.02
const PLAY_ROUND_S := Vector2(4.0, 7.0)
const PLAY_CATCH := 0.35 * WS.M
const PLAY_MPS := 2.4 * WS.M
const PLAY_CHASE_MPS := 2.9 * WS.M
const SPIRAL_R := Vector2(0.5, 1.1)

const NO_POINT := Vector3(NAN, NAN, NAN)
const LOD := preload("res://scripts/fp/animals/settle_lod.gd")
## The states the slow cadence may coarse (settle_lod.gd); any escape state, or the hero coming
## close, returns the squirrel to full rate.
const QUIET_STATES := ["forage", "nibble", "hold"]


## One squirrel.
class Squirrel:
	extends RefCounted
	## Its tile's spot ("sq:<tile>"), so the node can find it again.
	var key := ""
	var pos := Vector3.ZERO
	var yaw: float = 0.0
	## Its state: foraging on the lawn ("forage", "nibble"), fleeing ("flee"), up its tree
	## ("climb", "hold", "down").
	var state := "forage"
	## The lawn it keeps to, the tree it flees to ([x, z, r]) and where on the trunk it clings.
	var home := Vector3.ZERO
	var tree: Array = []
	var goal := Vector3.ZERO
	## How long the state lasts, how far through the bound or climb it is, and since when calm.
	var state_t: float = 0.0
	var hop_t: float = 0.0
	var climb_y: float = 0.0
	var calm_t: float = 0.0
	var chatter_t: float = 0.0
	## The chase: the playmate's key while a chase is on, who chases whom, a grace before a fresh
	## chaser may count a catch (so a catch parts them before the next), and whether the parts
	## have swapped already (the game runs two rounds at most).
	var play_with := ""
	var play_chaser := false
	var play_cd: float = 0.0
	var play_swapped := false
	## The pose the shader takes from INSTANCE_CUSTOM.
	var stride: float = 0.0
	var sit: float = 0.0
	var tail: float = 0.0
	var lean: float = 0.0
	## Slow-cadence accumulator while far from the hero, and whether the draw must refresh it.
	var hz_t: float = 0.0
	var dirty: bool = true


var squirrels: Array = []
var col: CollisionWorld = null
## Called with (at, "chatter") when one flees.
var on_call: Callable
## The world this step, set by the squirrels node: the hero's feet and velocity and whether they
## are on foot; dogs as [feet, velocity] (and cats as [feet, velocity, CAT_NEAR]); the feet of the
## people on foot around.
var hero := Vector3(INF, INF, INF)
var hero_vel := Vector3.ZERO
var hero_on_foot: bool = false
var dogs: Array = []
var passers: Array = []
var _rng := RandomNumberGenerator.new()


func _init() -> void:
	_rng.seed = 4211


## A squirrel for the lawn at home with its tree ([x, z, r] of the trunk), keyed by its spot.
func add(home: Vector3, tree: Array, key := "") -> Squirrel:
	var s := Squirrel.new()
	s.key = key
	s.home = home
	s.tree = tree
	s.pos = home
	s.yaw = _rng.randf() * TAU
	s.state = "nibble"
	s.state_t = _rng.randf_range(NIBBLE_S.x, NIBBLE_S.y)
	s.tail = _rng.randf_range(-0.3, 0.3)
	squirrels.append(s)
	return s


## The squirrel with this key, or null.
func squirrel(key: String) -> Squirrel:
	for s: Squirrel in squirrels:
		if s.key == key:
			return s
	return null


func remove(s: Squirrel) -> void:
	_stop_play(s)
	squirrels.erase(s)


## One step of dt game seconds for every squirrel.
func step(dt: float) -> void:
	if dt <= 0.0:
		return
	for s: Squirrel in squirrels:
		var sdt := LOD.step_dt(s, s.pos, hero, dt, s.state in QUIET_STATES)
		if sdt <= 0.0:
			continue
		s.dirty = true
		_threat(s, sdt)
		match s.state:
			"forage":
				_forage(s, sdt)
			"nibble":
				_nibble(s, sdt)
			"flee":
				_flee(s, sdt)
			"climb":
				_climb(s, sdt)
			"hold":
				_hold(s, sdt)
			"play":
				_play(s, sdt)
			_:
				_down(s, sdt)


## A fright at at within r_m metres sends the squirrels on the ground fleeing for their trees.
func startle(at: Vector3, r_m: float) -> void:
	if r_m <= 0.0:
		return
	for s: Squirrel in squirrels:
		if _flat(s.pos, at) < r_m * WS.M and not s.state in ["flee", "climb", "hold"]:
			_flee_tree(s)


## The pose the shader takes from INSTANCE_CUSTOM.
static func pose(s: Squirrel) -> Color:
	return Color(s.stride, s.sit, s.tail, s.lean)


## The squirrel's transform: its yaw, the climb's pitch up the trunk, its bound's lift.
static func xform(s: Squirrel, up: float) -> Transform3D:
	var pitch := -1.25 if s.state in ["climb", "hold", "down"] else 0.0
	var basis := Basis(Vector3.UP, s.yaw) * Basis(Vector3.RIGHT, pitch)
	return Transform3D(basis.scaled(Vector3.ONE * WS.M), s.pos + Vector3.UP * up)


## How far off the ground its bound carries it (m) at this moment: the hop's arc while it forages
## or dashes, nothing while it sits up, climbs or clings.
static func lift(s: Squirrel) -> float:
	if not s.state in ["forage", "flee", "play"]:
		return 0.0
	return HOP_UP * sin(PI * fposmod(s.hop_t, 1.0))


# ------------------------------------------------------------------ the states


## Bounds about its lawn: a goal within FORAGE_R of home, hops of the gait, now and then a nibble.
func _forage(s: Squirrel, dt: float) -> void:
	if _maybe_play(s, dt):
		return
	s.lean = move_toward(s.lean, 0.12, dt * 4.0)
	s.sit = move_toward(s.sit, 0.0, dt * 5.0)
	s.tail = lerpf(s.tail, 0.3 * sin(TAU * fposmod(s.hop_t * 2.4, 1.0)), 1.0 - exp(-6.0 * dt))
	var to := s.goal - s.pos
	to.y = 0.0
	if to.length() < 0.06 * WS.M:
		s.state = "nibble" if _rng.randf() < 0.55 else "forage"
		s.state_t = (
			_rng.randf_range(NIBBLE_S.x, NIBBLE_S.y)
			if s.state == "nibble"
			else _rng.randf_range(PAUSE_S.x, PAUSE_S.y)
		)
		s.goal = _next_goal(s)
		return
	s.yaw = rotate_toward(s.yaw, atan2(to.x, to.z), TURN * dt)
	var fwd := Vector3(sin(s.yaw), 0.0, cos(s.yaw))
	var spd := (
		AMBLE if _flat(s.home, s.pos) < 0.4 * WS.M and to.length() < 0.5 * WS.M else BOUND_MPS
	)
	var dist := minf(spd * dt, to.length())
	s.stride = fposmod(s.stride + dist / (HOP_S * BOUND_MPS), 1.0)
	s.hop_t += dt / HOP_S
	s.pos += fwd * dist


## Sits up on its haunches nibbling, its tail swaying, until its bout is done.
func _nibble(s: Squirrel, dt: float) -> void:
	s.lean = move_toward(s.lean, 0.0, dt * 4.0)
	s.sit = move_toward(s.sit, 1.0, dt * 5.0)
	s.stride = move_toward(s.stride, 0.0, dt * 6.0)
	s.tail = lerpf(s.tail, 0.45 * sin(TAU * s.state_t * 0.5), 1.0 - exp(-5.0 * dt))
	s.state_t -= dt
	if s.state_t <= 0.0:
		s.state = "forage"
		s.goal = _next_goal(s)


## Dashes for its tree, a clatter of chatter once, then up.
func _flee(s: Squirrel, dt: float) -> void:
	s.lean = move_toward(s.lean, 0.2, dt * 6.0)
	s.sit = move_toward(s.sit, 0.0, dt * 8.0)
	var at := Vector3(s.tree[0], s.pos.y, s.tree[1])
	var to := at - s.pos
	to.y = 0.0
	var left := to.length()
	# Arrived at the bark: the trunk's own width counts as reached.
	if left <= maxf(0.1 * WS.M, float(s.tree[2])):
		s.state = "climb"
		s.climb_y = s.pos.y - _ground(s.pos)
		s.yaw = atan2(s.pos.x - s.tree[0], s.pos.z - s.tree[1])
		s.pos = Vector3(s.tree[0], s.pos.y, s.tree[1]) + _out(s) * float(s.tree[2])
		return
	s.yaw = rotate_toward(s.yaw, atan2(to.x, to.z), TURN * 2.0 * dt)
	s.stride = fposmod(s.stride + dt / (HOP_S * 2.0), 1.0)
	s.hop_t += dt / (HOP_S * 0.9)
	# Straight for the trunk, whatever way it happens to be facing: a dash steered only by its
	# own heading turns a circle tighter than the tree stands near, so it would orbit the bark
	# for ever without ever reaching it.
	s.pos += to.normalized() * minf(DASH_MPS * dt, left)
	s.climb_y = s.pos.y - _ground(s.pos)


## Runs up its trunk, head up, to the height it keeps.
func _climb(s: Squirrel, dt: float) -> void:
	s.sit = move_toward(s.sit, 0.3, dt * 4.0)
	s.lean = move_toward(s.lean, 0.0, dt * 4.0)
	s.stride = fposmod(s.stride + dt * 2.4, 1.0)
	s.tail = lerpf(s.tail, 0.2, 1.0 - exp(-5.0 * dt))
	s.climb_y += CLIMB_MPS * dt
	if s.climb_y >= CLING_H:
		s.state = "hold"
		s.state_t = 0.0
	s.pos = _on_trunk(s)


## Clings to its trunk until the trouble has been gone CALM_S, then comes back down.
func _hold(s: Squirrel, dt: float) -> void:
	s.sit = move_toward(s.sit, 0.25, dt * 3.0)
	s.stride = move_toward(s.stride, 0.0, dt * 4.0)
	s.tail = lerpf(s.tail, 0.35 * sin(TAU * s.state_t * 0.4), 1.0 - exp(-4.0 * dt))
	s.state_t += dt
	if s.calm_t >= CALM_S:
		s.state = "down"
	s.pos = _on_trunk(s)


## Back down the trunk to the ground, then to its lawn.
func _down(s: Squirrel, dt: float) -> void:
	s.sit = move_toward(s.sit, 0.0, dt * 4.0)
	s.stride = fposmod(s.stride + dt * 2.0, 1.0)
	s.climb_y -= CLIMB_MPS * dt
	if s.climb_y <= 0.0:
		s.state = "forage"
		s.goal = _next_goal(s)
		s.calm_t = 0.0
	s.pos = _on_trunk(s)


# ------------------------------------------------------------------ the world


## The frights that send it up its tree, and the calm clock that brings it back down.
func _threat(s: Squirrel, dt: float) -> void:
	var up := s.state in ["flee", "climb", "hold", "down"]
	var trouble := false
	if hero_on_foot:
		var d := _flat(hero, s.pos)
		var fast := Vector2(hero_vel.x, hero_vel.z).length() > SPRINT_MPS
		trouble = d < (SPRINT if fast else WARY)
	for dg: Array in dogs:
		var at: Vector3 = dg[0]
		var d := _flat(at, s.pos)
		var running := Vector2((dg[1] as Vector3).x, (dg[1] as Vector3).z).length() > DOG_RUN_MPS
		# An entry with its own near radius (a cat, CAT_NEAR) only frightens it that close.
		var near := float(dg[2]) if dg.size() > 2 else DOG_NEAR
		trouble = trouble or d < near or (running and d < DOG_FAR)
	if not trouble:
		for p: Vector3 in passers:
			trouble = trouble or _flat(p, s.pos) < TRAMPLE
	if trouble:
		s.calm_t = 0.0
		if not up:
			_flee_tree(s)
		return
	s.calm_t += dt
	if up and s.calm_t > CALM_S + UP_KEEP:
		s.calm_t = 0.0


## Off for its tree, with one chatter as it goes.
func _flee_tree(s: Squirrel) -> void:
	_stop_play(s)
	if s.tree.is_empty():
		return
	s.state = "flee"
	s.calm_t = 0.0
	if s.chatter_t <= 0.0:
		s.chatter_t = CHATTER_S
		_call(s.pos + Vector3(0.0, 0.12 * WS.M, 0.0), "chatter")


## Where it sits on the trunk: against the bark at its climb height, on the side it went up.
func _on_trunk(s: Squirrel) -> Vector3:
	var g := _ground(Vector3(s.tree[0], 0.0, s.tree[1]))
	var y := (g if not is_nan(g) else s.home.y) + s.climb_y
	return Vector3(s.tree[0], y, s.tree[1]) + _out(s) * (float(s.tree[2]) + 0.02 * WS.M)


## Facing out from the trunk, toward its lawn.
func _out(s: Squirrel) -> Vector3:
	var away := Vector3(s.home.x - s.tree[0], 0.0, s.home.z - s.tree[1])
	if away.length_squared() < 1e-12:
		return Vector3.BACK
	return away.normalized()


## A goal to bound to: a free lawn point within FORAGE_R of home.
func _next_goal(s: Squirrel) -> Vector3:
	for _k in range(4):
		var a := _rng.randf() * TAU
		var p := s.home + Vector3(cos(a), 0.0, sin(a)) * _rng.randf_range(0.1, 0.8) * WS.M
		if lawn_ok(p):
			p.y = _ground(p) if not is_nan(_ground(p)) else s.home.y
			return p
	return s.home


## Walkable lawn under the squirrel (not the road, not water), with room clear round it: where the
## node picks a squirrel's home, and where it bounds to.
func lawn_ok(p: Vector3) -> bool:
	if col == null:
		return true
	var g := col.walk_height(p)
	if is_nan(g) or col.surface_at(p) == "asphalt":
		return false
	return not col.is_blocked(Vector3(p.x, g, p.z), 0.06 * WS.M)


# ------------------------------------------------------------------ the chase


## Calm foraging with a playmate's lawn within reach, and the odds come up: a chase breaks out.
func _maybe_play(s: Squirrel, dt: float) -> bool:
	if s.play_with != "" or _rng.randf() > PLAY_ODDS * dt:
		return false
	for o: Squirrel in squirrels:
		if (
			o != s
			and o.play_with == ""
			and o.state in ["forage", "nibble"]
			and _flat(o.home, s.home) < PLAY_NEAR
		):
			_start_play(s, o)
			return true
	return false


## Off they go: a runs after b, who runs the spiral round its trunk, both chattering, for one
## round; a catch swaps who chases whom.
func _start_play(a: Squirrel, b: Squirrel) -> void:
	var round_s := _rng.randf_range(PLAY_ROUND_S.x, PLAY_ROUND_S.y)
	for pair: Array in [[a, b, true], [b, a, false]]:
		var one: Squirrel = pair[0]
		one.state = "play"
		one.play_with = (pair[1] as Squirrel).key
		one.play_chaser = pair[2]
		one.state_t = round_s
		one.play_cd = 0.0
		one.play_swapped = false
	_call(a.pos + Vector3(0.0, 0.12 * WS.M, 0.0), "chatter")


## The chase itself: the one chased runs a spiral round its trunk — its circle breathing out and
## in as it goes — and the chaser cuts straight after it, round the trunk rather than through it.
## A catch tumbles them together: the chaser sits the tumble out a beat (its grace) while the
## other bolts, then gives chase with the parts swapped; the next catch (or a round run out)
## ends the game and both go back to their lawns. A real fright breaks the game at once
## (_threat's _flee_tree clears it).
func _play(s: Squirrel, dt: float) -> void:
	s.lean = move_toward(s.lean, 0.18, dt * 5.0)
	s.sit = move_toward(s.sit, 0.0, dt * 8.0)
	s.tail = lerpf(s.tail, 0.5 * sin(TAU * fposmod(s.hop_t * 3.0, 1.0)), 1.0 - exp(-6.0 * dt))
	s.hop_t += dt / (HOP_S * 0.9)
	s.state_t -= dt
	s.play_cd = maxf(0.0, s.play_cd - dt)
	s.chatter_t -= dt
	if s.chatter_t <= 0.0:
		s.chatter_t = CHATTER_S
		_call(s.pos + Vector3(0.0, 0.12 * WS.M, 0.0), "chatter")
	var other := squirrel(s.play_with)
	if other == null or other.state != "play" or s.state_t <= 0.0:
		_stop_play(s)
		return
	var dir := Vector3.ZERO
	if s.play_chaser:
		if s.play_cd > 0.0:
			# The tumble's beat: caught it, sit up a moment while it bolts.
			s.sit = move_toward(s.sit, 0.6, dt * 6.0)
			s.stride = move_toward(s.stride, 0.0, dt * 6.0)
			return
		dir = other.pos - s.pos
		dir.y = 0.0
		if not s.tree.is_empty():
			# Round the trunk, not through it.
			var off := s.pos - Vector3(s.tree[0], s.pos.y, s.tree[1])
			off.y = 0.0
			var keep := float(s.tree[2]) + 0.12 * WS.M
			if off.length() < keep and off.length_squared() > 1e-10:
				dir += off.normalized() * (keep - off.length()) * 8.0
		if dir.length() < PLAY_CATCH:
			# Caught: the second catch ends the game; the first swaps who chases whom for a
			# shorter round back, with a grace to run apart before the next catch can count.
			if s.play_swapped:
				_stop_play(s)
				return
			var round_s := _rng.randf_range(PLAY_ROUND_S.x * 0.5, PLAY_ROUND_S.y * 0.5)
			for pair: Array in [[s, false], [other, true]]:
				var one: Squirrel = pair[0]
				one.play_chaser = pair[1]
				one.state_t = round_s
				one.play_cd = 1.0
				one.play_swapped = true
			return
	else:
		var trunk := s.home if s.tree.is_empty() else Vector3(s.tree[0], s.pos.y, s.tree[1])
		var away := s.pos - trunk
		away.y = 0.0
		if away.length_squared() < 1e-8:
			away = _out(s)
		var r_want := lerpf(SPIRAL_R.x, SPIRAL_R.y, 0.5 + 0.5 * sin(s.state_t * 2.1)) * WS.M
		var radial := away.normalized() * clampf(r_want - away.length(), -1.0, 1.0)
		dir = Vector3(-away.z, 0.0, away.x).normalized() + radial * 1.6
	if dir.length_squared() < 1e-10:
		return
	dir = dir.normalized()
	s.yaw = rotate_toward(s.yaw, atan2(dir.x, dir.z), TURN * 1.6 * dt)
	var dist := (PLAY_CHASE_MPS if s.play_chaser else PLAY_MPS) * dt
	s.stride = fposmod(s.stride + dist / (HOP_S * BOUND_MPS), 1.0)
	# Only over good lawn, as a forage hop: where the ground runs out (a wall, the kerb, the
	# road), the game breaks up.
	var nxt := s.pos + dir * dist
	if not lawn_ok(nxt):
		_stop_play(s)
		return
	s.pos = nxt
	var g := _ground(s.pos)
	if not is_nan(g):
		s.pos.y = g


## The game is over: both back to foraging on their lawns. When a real fright broke it, the
## frightened one is already off for its tree and only its playmate goes back to its lawn.
func _stop_play(s: Squirrel) -> void:
	if s.play_with == "":
		return
	var other := squirrel(s.play_with)
	if other != null and other.play_with == s.key:
		other.play_with = ""
		other.play_chaser = false
		other.play_swapped = false
		if other.state == "play":
			other.state = "forage"
			other.goal = _next_goal(other)
	s.play_with = ""
	s.play_chaser = false
	s.play_swapped = false
	if s.state == "play":
		s.state = "forage"
		s.goal = _next_goal(s)


func _ground(p: Vector3) -> float:
	var g := col.walk_height(p) if col != null else NAN
	return g


func _call(at: Vector3, sound: String) -> void:
	if on_call.is_valid():
		on_call.call(at, sound)


static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()
