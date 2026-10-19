extends RefCounted
## People on foot (docs/fp/slices/E-traffic.md §3 Pedestrians): they walk the sidewalk network at
## PED_WALK ±15 %, keep right when they meet, keep 0.6 m apart, follow slower walkers, sidestep
## the posts baked into lit straights and the player, and cross only on zebras: in their walk
## phase at lights, or at tees when no car is within 2 s. A walker either wanders (ambient), follows
## a plan of network edges and free legs (resident trips), or stands (waiting, chatting, outdoors).

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const LG := preload("res://scripts/fp/traffic/lane_graph.gd")
const SW := preload("res://scripts/fp/traffic/sidewalks.gd")
const JN := preload("res://scripts/fp/traffic/junctions.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
## Half width of the walking band around its centreline (PED_BAND).
const BAND := (WS.PED_BAND[1] - WS.PED_BAND[0]) * 0.5 - 0.002
const SEP := 0.6 * WS.M
const KEEP_RIGHT := 0.012
const CELL := 0.06
## Simulation LOD: walkers within LOD_FULL of the player step every step, out to LOD_NEAR (the
## drawing range) every LOD_MID_DT, beyond that every LOD_DT without crowd logic. Draws carry them
## on in between.
const LOD_FULL := 1.5
const LOD_MID_DT := 1.0 / 15.0
const LOD_NEAR := 4.6
const LOD_DT := 0.2
## Seconds a person spawned in view takes to fade in.
const FADE_IN := 1.6
## Ambient walkers who stop to chat when they meet (a pair of them stands out of the flow).
const CHATTY := 0.22
const CHAT_MEET := 1.3 * WS.M
const CHAT_MIN := 10.0
const CHAT_MAX := 40.0
## People waiting at a zebra spread along the curb (metres, by slot) and step back a row.
const WAIT_ALONG: Array[float] = [0.0, -0.6, 0.6]
const WAIT_ROW := 0.55
## Hip height of the legacy people (half their 1.83 m), the pivot of the leg swing.
const HIP_M := 0.91


## One person on foot.
class Walker extends RefCounted:
	var id: int = 0
	var role: String = "ambient"     # ambient | resident
	var resident_id: String = ""
	var model: int = -1
	var speed: float = WS.PED_WALK
	var edge: SW.PedEdge = null
	var t: float = 0.0               # distance walked along the edge (in walking direction)
	var t_end: float = -1.0          # stop here on this edge (-1: its end)
	var far: bool = false            # beyond the traffic radius: no crowd or crossing logic
	var dir: int = 1                 # +1 a -> b, -1 b -> a
	var lat: float = 0.0
	var lat_jit: float = 0.0
	var plan: Array = []             # steps: {"edge": id, "dir": d} or {"pt": Vector3}
	var pt_target := Vector3.ZERO    # current free-leg target
	var on_leg: bool = false
	var state: String = "walk"       # walk | wait | stand | hidden
	var wait_t: float = 0.0
	var stand_yaw: float = 0.0
	var crossing: SW.PedEdge = null  # zebra it is registered on
	var pos := Vector3.ZERO
	var yaw: float = 0.0
	var vel := Vector3.ZERO
	var v: float = 0.0
	var phase: float = 0.0
	var hold: bool = false           # conversation: stop and face the player
	var face_player: bool = false
	var done: bool = false           # plan finished (owner reacts)
	var dead: bool = false
	var node: Node3D = null
	var lod: int = -1
	var owner: Variant = null
	var last_node: int = -1
	var stalled_s: float = 0.0
	var acc_dt: float = 0.0
	var info: Dictionary = {}        # its agents_near entry (refreshed in place)
	var info_serial: int = -1
	var lod_far: bool = false
	var lod_dt: float = 0.0
	var gait: float = 0.0            # drawn stride amount 0..1 (eases toward the walking speed)
	var fade: float = 1.0            # drawn opacity 0..1 (people spawned in view fade in)
	var wait_slot: int = -1          # place in the little crowd waiting at a zebra
	var chatty: bool = false         # stops to chat when meeting another chatty walker
	var chat_t: float = 0.0
	var chat_cool: float = 0.0
	var chat_lat: float = 0.0
	var chat_with: Walker = null
	var vis_off := Vector3.ZERO      # drawn offset from pos (eases; spreads a waiting crowd)


var sw: SW
var lg: LG
var jn: JN
var vh: VH
var walkers: Array = []
var player_pos := Vector3(INF, 0, INF)
var player_on: bool = false
## Obstacles on sidewalks (the posts in lit straights): Array[Vector2].
var posts: Array[Vector2] = []
var _post_cells: Dictionary = {}
var _next_id: int = 1
var _rng := RandomNumberGenerator.new()
var _grid: Dictionary = {}
var on_done: Callable
## Called with (walker) when one is removed (the renderer frees its node).
var on_removed: Callable


func setup(p_sw: SW, p_lg: LG, p_jn: JN, p_vh: VH, seed: int) -> void:
	sw = p_sw
	lg = p_lg
	jn = p_jn
	vh = p_vh
	_rng.seed = seed * 7027 + 11
	walkers.clear()


func make(role: String) -> Walker:
	var w := Walker.new()
	w.id = _next_id
	_next_id += 1
	w.role = role
	w.speed = WS.PED_WALK * _rng.randf_range(0.85, 1.15)
	w.lat_jit = _rng.randf_range(-0.008, 0.008)
	w.lat = w.lat_jit
	w.phase = _rng.randf() * TAU
	w.chatty = role == "ambient" and _rng.randf() < CHATTY
	walkers.append(w)
	return w


func remove(w: Walker) -> void:
	if w.dead:
		return
	w.dead = true
	_leave_zebra(w)
	walkers.erase(w)
	if on_removed.is_valid():
		on_removed.call(w)


## Puts w on edge e at distance t (walking direction dir).
func place(w: Walker, e: SW.PedEdge, t: float, dir: int) -> void:
	_leave_zebra(w)
	w.edge = e
	w.t = clampf(t, 0.0, e.length)
	w.t_end = -1.0
	w.dir = dir
	w.state = "walk"
	w.on_leg = false
	_pose(w, 0.0)


## Stands w at p facing yaw (outdoors, waiting, chatting).
func stand(w: Walker, p: Vector3, yaw: float) -> void:
	_leave_zebra(w)
	w.edge = null
	w.state = "stand"
	w.pos = p
	w.yaw = yaw
	w.stand_yaw = yaw
	w.v = 0.0
	w.vel = Vector3.ZERO


## Rebuilds the post obstacles of lit straights (posts at model-local (±0.4, ∓0.2), roads.py).
func rebuild_posts(sim: CitySim) -> void:
	posts.clear()
	_post_cells.clear()
	for i: int in lg.tiles.keys():
		var t: LG.TileInfo = lg.tiles[i]
		if t.piece != "straight" or t.bridge:
			continue
		var x := D.tx(i)
		var y := D.ty(i)
		if (x + y) % 4 != 0:
			continue
		var yaw := float(RoadTopology.piece(t.mask)[1])
		var b := Basis(Vector3.UP, deg_to_rad(yaw))
		for lp: Vector3 in [Vector3(-0.4, 0, -0.2), Vector3(0.4, 0, 0.2)]:
			var q := b * lp
			var p := Vector2(x + q.x, y + q.z)
			posts.append(p)
			var key := Vector2i(floori(p.x / CELL), floori(p.y / CELL))
			if not _post_cells.has(key):
				_post_cells[key] = []
			(_post_cells[key] as Array).append(p)


# ------------------------------------------------------------------ stepping

func step(dt: float) -> void:
	var near2 := LOD_NEAR * LOD_NEAR
	var full2 := LOD_FULL * LOD_FULL
	for w: Walker in walkers:
		var dx := w.pos.x - player_pos.x
		var dz := w.pos.z - player_pos.z
		var d2 := dx * dx + dz * dz
		w.lod_far = player_on and d2 > near2
		w.lod_dt = 0.0 if not player_on or d2 <= full2 else (LOD_DT if w.lod_far else LOD_MID_DT)
	_build_grid()
	for w: Walker in walkers.duplicate():
		if w.dead or w.state == "hidden":
			continue
		w.acc_dt += dt
		if w.acc_dt < w.lod_dt:
			continue
		var h := w.acc_dt
		w.acc_dt = 0.0
		_step_one(w, h)


func _step_one(w: Walker, dt: float) -> void:
	if w.hold:
		w.v = 0.0
		w.vel = Vector3.ZERO
		if w.face_player and player_on:
			var d := player_pos - w.pos
			if d.length_squared() > 1e-8:
				w.yaw = lerp_angle(w.yaw, atan2(d.x, d.z), minf(1.0, dt * 6.0))
		return
	if w.state == "stand":
		w.v = 0.0
		return
	if w.state == "chat":
		_chat(w, dt)
		return
	w.chat_cool -= dt
	if w.on_leg:
		_walk_leg(w, dt)
	elif w.edge != null:
		_walk_edge(w, dt)


func _build_grid() -> void:
	_grid.clear()
	for w: Walker in walkers:
		if w.dead or w.state == "hidden" or w.lod_far:
			continue
		var key := Vector2i(floori(w.pos.x / CELL), floori(w.pos.z / CELL))
		if not _grid.has(key):
			_grid[key] = [w]
		else:
			(_grid[key] as Array).append(w)


func _walk_edge(w: Walker, dt: float) -> void:
	var e := w.edge
	if e == null or not e.alive:
		w.edge = null
		w.state = "walk"
		_next(w)
		return
	if w.state == "wait":
		w.wait_t += dt
		w.v = 0.0
		w.vel = Vector3.ZERO
		var z := _peek_zebra(w)
		if z == null or w.far or _can_cross(z):
			w.state = "walk"
			w.wait_t = 0.0
			_next(w)
		elif w.role == "ambient" and w.wait_t > 45.0:
			# Tired of waiting: wander off another way.
			w.plan.clear()
			w.state = "walk"
			w.wait_t = 0.0
			_next(w)
		else:
			# Face the road while waiting at the curb.
			var d := sw.dir_at(z, 0.0) * float(_zebra_dir(w, z))
			w.yaw = lerp_angle(w.yaw, atan2(d.x, d.y), minf(1.0, dt * 4.0))
		return
	var fwd := _fwd(w)
	var v := w.speed
	var lat_t := w.lat_jit
	var end := e.length if w.t_end < 0.0 else minf(w.t_end, e.length)
	if w.far or w.lod_far:
		w.v = v
		w.t += v * dt
		if w.t >= end:
			w.t = end
			_pose(w, dt)
			_next(w)
		else:
			_pose(w, dt)
		return
	# Others nearby: follow a slower walker ahead, keep right of oncoming ones, keep apart.
	var cx := floori(w.pos.x / CELL)
	var cz := floori(w.pos.z / CELL)
	for gx in range(cx - 1, cx + 2):
		for gz in range(cz - 1, cz + 2):
			for o: Walker in _grid.get(Vector2i(gx, gz), []):
				if o == w:
					continue
				var dp := o.pos - w.pos
				var dist := Vector2(dp.x, dp.z).length()
				if dist > SEP * 3.0:
					continue
				var ahead := dp.x * fwd.x + dp.z * fwd.y
				if ahead <= 0.0:
					continue
				var ofwd := Vector2(sin(o.yaw), cos(o.yaw))
				if o.state != "walk" or o.hold:
					# Someone standing (chatting, waiting): step around them on the road side.
					if dist < SEP * 2.5:
						var side := -dp.x * fwd.y + dp.z * fwd.x
						lat_t = -BAND * 0.8 if side > 0.0 else BAND * 0.8
						if dist < SEP * 0.9 and absf(side - w.lat) < SEP * 0.6:
							v *= 0.4
					continue
				if ofwd.dot(fwd) < -0.3 and dist < CHAT_MEET and _may_chat(w, e) and _may_chat(o, o.edge):
					_start_chat(w, o)
					return
				if ofwd.dot(fwd) > 0.3:
					if dist < SEP * 1.6 and o.v < v:
						v = maxf(o.v, 0.0) if dist < SEP else lerpf(o.v, v, (dist - SEP) / (SEP * 0.6))
				else:
					lat_t = KEEP_RIGHT
					if dist < SEP:
						v *= 0.5
	# The player: step aside, or stop right in front of them.
	if player_on:
		var dp := player_pos - w.pos
		var ahead := dp.x * fwd.x + dp.z * fwd.y
		var side := -dp.x * fwd.y + dp.z * fwd.x
		if ahead > -0.4 * WS.M and ahead < 2.2 * WS.M and absf(side) < 1.2 * WS.M:
			# Step around the player, leaving the band a little if that is what it takes.
			lat_t = -(BAND + 0.012) if side > 0.0 else (BAND + 0.012)
			if ahead > 0.0 and ahead < 0.7 * WS.M and absf(side - w.lat) < 0.5 * WS.M:
				v = 0.0
			elif ahead > 0.0:
				v *= 0.6
	# Posts on lit straights stand on the outer half of the band.
	if not e.zebra and not _post_cells.is_empty():
		for gx in range(cx - 1, cx + 2):
			for gz in range(cz - 1, cz + 2):
				for p: Vector2 in _post_cells.get(Vector2i(gx, gz), []):
					var dp := p - Vector2(w.pos.x, w.pos.z)
					if dp.length() < 1.2 * WS.M:
						var side := -dp.x * fwd.y + dp.y * fwd.x
						lat_t = -BAND * 0.8 if side > 0.0 else BAND * 0.8
	w.lat = move_toward(w.lat, clampf(lat_t, -BAND - 0.012, BAND + 0.012), dt * 0.6 * WS.M)
	w.v = v
	w.t += v * dt
	if v < 0.05 * WS.M:
		w.stalled_s += dt
	else:
		w.stalled_s = 0.0
	if w.t >= end:
		w.t = end
		_pose(w, dt)
		_next(w)
		return
	_pose(w, dt)


## Unit walking direction on the current edge.
func _fwd(w: Walker) -> Vector2:
	var u := w.t if w.dir > 0 else w.edge.length - w.t
	var d := sw.dir_at(w.edge, u)
	return d if w.dir > 0 else -d


func _pose(w: Walker, dt: float) -> void:
	var e := w.edge
	var u := w.t if w.dir > 0 else e.length - w.t
	var p := sw.pos_at(e, u)
	var f := _fwd(w)
	var right := Vector2(-f.y, f.x)
	var lat := w.lat if not e.zebra else w.lat * 0.5
	var np := Vector3(p.x + right.x * lat, p.y, p.z + right.y * lat)
	if dt > 0.0:
		w.vel = (np - w.pos) / dt
		w.vel.y = 0.0
	w.pos = np
	var ty := atan2(f.x, f.y)
	w.yaw = ty if dt <= 0.0 else lerp_angle(w.yaw, ty, minf(1.0, dt * 8.0))
	w.phase += dt * w.v / (0.75 * WS.M) * PI


## The zebra edge w would take next (null when the next step is not a zebra).
func _peek_zebra(w: Walker) -> SW.PedEdge:
	if not w.plan.is_empty():
		var st: Dictionary = w.plan[0]
		if st.has("edge"):
			var e := sw.edge(int(st["edge"]))
			return e if e != null and e.zebra else null
		return null
	return null


## At the end of the current edge: take the next plan step, or wander.
func _next(w: Walker) -> void:
	var n := -1
	if w.edge != null:
		n = w.edge.b if w.dir > 0 else w.edge.a
	_leave_zebra(w)
	if not w.plan.is_empty():
		var st: Dictionary = w.plan[0]
		if st.has("pt"):
			w.plan.pop_front()
			w.pt_target = st["pt"]
			w.on_leg = true
			return
		var e := sw.edge(int(st["edge"]))
		if e == null or not e.alive:
			w.plan.clear()
			w.done = true
			if on_done.is_valid():
				on_done.call(w)
			return
		if e.zebra and not w.far and not _can_cross(e):
			_begin_wait(w)
			return
		w.plan.pop_front()
		_enter(w, e, int(st["dir"]), float(st.get("t0", 0.0)), float(st.get("t1", -1.0)))
		return
	if w.role != "ambient":
		w.done = true
		w.v = 0.0
		if on_done.is_valid():
			on_done.call(w)
		return
	if n < 0:
		return
	# Wander: any edge but the one we came along; zebras now and then when allowed.
	var opts: Array = []
	for eid: int in sw.adj[n]:
		var e: SW.PedEdge = sw.edges[eid]
		if e == null or e == w.edge:
			continue
		opts.append(e)
	if opts.is_empty():
		if w.edge != null:
			_enter(w, w.edge, -w.dir)
		return
	var pick: SW.PedEdge = opts[_rng.randi() % opts.size()]
	if pick.zebra and _rng.randf() < 0.45:
		var walks: Array = []
		for e: SW.PedEdge in opts:
			if not e.zebra:
				walks.append(e)
		if not walks.is_empty():
			pick = walks[_rng.randi() % walks.size()]
	var dir := 1 if pick.a == n else -1
	if pick.zebra and not _can_cross(pick):
		w.plan = [{"edge": pick.id, "dir": dir}]
		w.role = "ambient"
		_begin_wait(w)
		return
	_enter(w, pick, dir)


## True when w could stop to chat here: an ambient walker in the mood, on a plain sidewalk.
func _may_chat(w: Walker, e: SW.PedEdge) -> bool:
	if w.role != "ambient" or not w.chatty or w.chat_cool > 0.0 or w.state != "walk" or w.on_leg or w.hold:
		return false
	if e == null or e.zebra or not w.plan.is_empty():
		return false
	var t: LG.TileInfo = lg.info(e.tile)
	return t != null and t.piece == "straight"


## Two walkers who meet stop for a chat: both step to the lot side of the walking band (out of
## the flow) and face each other for 10-40 s.
func _start_chat(a: Walker, b: Walker) -> void:
	var secs := _rng.randf_range(CHAT_MIN, CHAT_MAX)
	for pair: Array in [[a, b], [b, a]]:
		var w: Walker = pair[0]
		w.state = "chat"
		w.chat_t = secs
		w.chat_with = pair[1]
		w.v = 0.0
		w.vel = Vector3.ZERO
		var f := _fwd(w)
		var p := Vector2(w.pos.x, w.pos.z)
		var to_road := Vector2(D.tx(w.edge.tile), D.ty(w.edge.tile)) - p
		var right := Vector2(-f.y, f.x)
		w.chat_lat = -BAND if right.dot(to_road) > 0.0 else BAND


func _chat(w: Walker, dt: float) -> void:
	w.v = 0.0
	w.vel = Vector3.ZERO
	w.chat_t -= dt
	var o := w.chat_with
	if o == null or o.dead or o.state != "chat" or w.chat_t <= 0.0:
		w.state = "walk"
		w.chat_with = null
		w.chat_cool = _rng.randf_range(60.0, 150.0)
		return
	w.lat = move_toward(w.lat, w.chat_lat, dt * 0.5 * WS.M)
	var yaw := w.yaw
	_pose(w, 0.0)
	w.yaw = yaw
	var d := o.pos - w.pos
	if Vector2(d.x, d.z).length_squared() > 1e-10:
		w.yaw = lerp_angle(w.yaw, atan2(d.x, d.z), minf(1.0, dt * 3.0))


## w stops at the curb before a zebra, taking the next free place in the waiting crowd.
func _begin_wait(w: Walker) -> void:
	w.state = "wait"
	w.v = 0.0
	w.wait_t = 0.0
	var taken := {}
	for o: Walker in walkers:
		if o != w and o.state == "wait" and not o.dead and o.pos.distance_squared_to(w.pos) < 0.0004:
			taken[o.wait_slot] = true
	var k := 0
	while taken.has(k):
		k += 1
	w.wait_slot = k


## Drawn offset of a waiting walker's place in the crowd (zero once they walk).
func _wait_offset(w: Walker) -> Vector3:
	if w.state != "wait" or w.wait_slot <= 0:
		return Vector3.ZERO
	var z := _peek_zebra(w)
	if z == null:
		return Vector3.ZERO
	var d := sw.dir_at(z, 0.0) * float(_zebra_dir(w, z))
	var along := Vector2(-d.y, d.x)
	var k := w.wait_slot
	var o := along * (WAIT_ALONG[k % 3] * WS.M) - d * (WAIT_ROW * WS.M * float(k / 3))
	return Vector3(o.x, 0.0, o.y)


func _enter(w: Walker, e: SW.PedEdge, dir: int, t0: float = 0.0, t1: float = -1.0) -> void:
	w.edge = e
	w.dir = dir
	w.t = t0
	w.t_end = t1
	w.state = "walk"
	if e.zebra and not w.far:
		w.crossing = e
		e.walkers.append(w)


## +1 when w would walk zebra z from a to b (it stands at a), else -1.
func _zebra_dir(w: Walker, z: SW.PedEdge) -> int:
	if not w.plan.is_empty():
		return int((w.plan[0] as Dictionary).get("dir", 1))
	return 1


func _leave_zebra(w: Walker) -> void:
	if w.crossing != null:
		w.crossing.walkers.erase(w)
		w.crossing = null


## True when w may step onto zebra z now.
func _can_cross(z: SW.PedEdge) -> bool:
	var t: LG.TileInfo = lg.info(z.tile)
	if t == null:
		return true
	if t.lights:
		return jn.ped_walk(z.tile, z.arm) and not zebra_cars(z.tile, z.arm, 0.8)
	return not zebra_cars(z.tile, z.arm, 2.0)


## True when a vehicle is on, or within `secs` of, the zebra across `arm` of junction tile i.
func zebra_cars(i: int, arm: int, secs: float) -> bool:
	var t: LG.TileInfo = lg.info(i)
	if t == null or vh == null:
		return false
	# Inbound on that arm: the approach and the lanes feeding it.
	var a: LG.Lane = t.approach[arm]
	if a != null:
		if _lane_threat(a, a.zebra_s0, a.zebra_s1, secs, 0.0):
			return true
		for p: LG.Lane in lg.prev_lanes(a):
			if _lane_threat(p, a.zebra_s0 + p.length, a.zebra_s1 + p.length, secs, 0.0):
				return true
	# Outbound through that arm: moves exiting there, and approaches whose cars are headed there.
	for e in range(4):
		for mv: LG.Lane in t.moves[e]:
			if mv.to_e != arm:
				continue
			if _lane_threat(mv, mv.zebra_s0, mv.zebra_s1, secs, 0.0):
				return true
			var ap: LG.Lane = t.approach[e]
			if ap != null:
				for o: VH.Car in ap.cars:
					if (o.gate == ap.id or o.v > 1.0 * WS.M) and vh._next_move(o, ap) == mv:
						var dist := ap.length - o.s + mv.zebra_s0
						if dist / maxf(o.v, 0.5 * WS.M) < secs:
							return true
	return false


## True when a vehicle on l covers [s0, s1] now or reaches s0 within secs.
func _lane_threat(l: LG.Lane, s0: float, s1: float, secs: float, _x: float) -> bool:
	for o: VH.Car in l.cars:
		if o.s >= s0 - 0.01 and o.s - o.length <= s1 + 0.01:
			return true
		if o.s < s0:
			var d := s0 - o.s
			if o.v > 0.3 * WS.M and d / o.v < secs:
				return true
			if d < 0.3 * WS.M:
				return true
	for o: VH.Car in l.tails:
		var r := vh.rear_on(o, l)
		if r <= s1 + 0.01:
			return true
	return false


func _walk_leg(w: Walker, dt: float) -> void:
	var to := w.pt_target
	var d := Vector2(to.x - w.pos.x, to.z - w.pos.z)
	var dist := d.length()
	var v := w.speed
	if player_on:
		var dp := player_pos - w.pos
		if Vector2(dp.x, dp.z).length() < 0.5 * WS.M and Vector2(dp.x, dp.z).dot(d) > 0.0:
			v = 0.0
	var step := v * dt
	w.v = v
	if dist <= step or dist < 1e-5:
		w.pos = to
		w.on_leg = false
		_next(w)
		return
	var dir := d / dist
	var np := w.pos + Vector3(dir.x, 0, dir.y) * step
	np.y = lerpf(w.pos.y, to.y, clampf(step / maxf(dist, 1e-5), 0.0, 1.0))
	w.vel = (np - w.pos) / maxf(dt, 1e-5)
	w.pos = np
	w.yaw = lerp_angle(w.yaw, atan2(dir.x, dir.y), minf(1.0, dt * 8.0))
	w.phase += dt * v / (0.75 * WS.M) * PI


## Starts w on a plan from where it stands (first step a free leg to the network or an edge).
func start_plan(w: Walker, plan: Array) -> void:
	w.plan = plan
	w.done = false
	w.state = "walk"
	w.edge = null
	w.on_leg = false
	_next(w)


## Eases the drawn stride toward the walking speed and the fade-in toward 1 (real seconds, so a
## paused tour still settles).
func ease_visuals(w: Walker, delta: float) -> void:
	var want := clampf(w.v / (0.7 * WS.PED_WALK), 0.0, 1.0)
	var off := _wait_offset(w)
	if off != w.vis_off:
		var was := w.vis_off
		w.vis_off = w.vis_off.move_toward(off, delta * WS.PED_WALK)
		# Stepping into place in the crowd is walking too.
		want = maxf(want, clampf((w.vis_off - was).length() / maxf(delta, 1e-4) / (0.7 * WS.PED_WALK), 0.0, 1.0))
		w.phase += (w.vis_off - was).length() / (0.75 * WS.M) * PI
	w.gait = move_toward(w.gait, want, delta * 4.0)
	if w.fade < 1.0:
		w.fade = minf(1.0, w.fade + delta / FADE_IN)


## Draw transform of w: the legs and arms swing in the people shader (render.gd), and the body
## bobs with them, highest as the legs pass each other.
func draw_xform(w: Walker) -> Transform3D:
	# The hips drop as the legs spread, so the planted foot stays on the ground (render.LEG_SWING).
	var a := 0.38 * w.gait * sin(draw_phase(w))
	var drop := HIP_M * WS.M * (1.0 - cos(a))
	var p := w.pos + w.vis_off - Vector3(0, drop, 0)
	if _carried(w):
		p += w.vel * w.acc_dt
	return Transform3D(Basis(Vector3.UP, w.yaw), p)


## Stride phase as drawn (carried on over the time the simulation LOD has not stepped yet).
func draw_phase(w: Walker) -> float:
	if _carried(w):
		return w.phase + w.acc_dt * w.v / (0.75 * WS.M) * PI
	return w.phase


func _carried(w: Walker) -> bool:
	return w.acc_dt > 0.0 and w.v > 0.0 and w.state == "walk" and not w.hold
