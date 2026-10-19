extends Node3D
## Real light pools under the street lamps near the player (slice G1): a fixed pool of shadowless
## OmniLight3Ds, re-assigned four times a second to the nearest Bulb_* nodes within REACH of the
## player and dimmed with the night. Bulbs are collected per tile on tile_built.

const WS := preload("res://scripts/fp/world_scale.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const REACH := 4.0
const RANGE := 12.0 * WS.M
const ENERGY := 1.6
const COLOR := Color(1.0, 0.8, 0.56)

var ctx: FpContext
var pool: Array[OmniLight3D] = []
## Tile -> Array of Bulb nodes on its holder.
var _bulbs: Dictionary = {}
var _t: float = 0.0


func setup(p_ctx: FpContext, count: int) -> void:
	ctx = p_ctx
	set_count(count)
	rescan()


## Resizes the pool to n lights (quality preset).
func set_count(n: int) -> void:
	while pool.size() > n:
		pool.pop_back().queue_free()
	while pool.size() < n:
		var l := OmniLight3D.new()
		l.name = "StreetLight%d" % pool.size()
		l.shadow_enabled = false
		l.omni_range = RANGE
		l.omni_attenuation = 1.2
		l.light_color = COLOR
		l.light_energy = 0.0
		l.light_specular = 0.4
		l.visible = false
		add_child(l)
		pool.append(l)


## Collects the bulbs of every tile holder (after view.setup).
func rescan() -> void:
	_bulbs.clear()
	if ctx == null or ctx.view == null:
		return
	for i: int in ctx.view._tile_nodes.keys():
		on_tile_built(i, ctx.view._tile_nodes[i])


func on_tile_built(i: int, holder: Node3D) -> void:
	var found: Array = holder.find_children("Bulb*", "MeshInstance3D", true, false)
	if found.is_empty():
		_bulbs.erase(i)
	else:
		_bulbs[i] = found


func on_tile_cleared(i: int) -> void:
	_bulbs.erase(i)


func _process(delta: float) -> void:
	if ctx == null or ctx.view == null:
		return
	var glow := smoothstep(0.25, 0.85, ctx.view.night)
	_t += delta
	if _t >= 0.25 or glow <= 0.0:
		_t = 0.0
		_assign(glow)
	for l in pool:
		l.light_energy = ENERGY * glow
		l.visible = l.visible and glow > 0.01


## Moves the pool onto the nearest bulbs within REACH of the player (all hidden by day).
func _assign(glow: float) -> void:
	var near: Array = []
	if glow > 0.01:
		var p := ctx.player_position()
		var cx := roundi(p.x)
		var cy := roundi(p.z)
		var r := ceili(REACH)
		for y in range(cy - r, cy + r + 1):
			for x in range(cx - r, cx + r + 1):
				if not D.in_bounds(x, y):
					continue
				for b: Variant in _bulbs.get(D.idx(x, y), []):
					if not is_instance_valid(b) or not (b as Node3D).is_inside_tree():
						continue
					var bp := (b as Node3D).global_position
					var d := Vector2(bp.x - p.x, bp.z - p.z).length()
					if d <= REACH:
						near.append([d, bp])
		near.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	for k in range(pool.size()):
		var l := pool[k]
		if k < near.size():
			l.global_position = (near[k][1] as Vector3) - Vector3(0, 0.3 * WS.M, 0)
			l.visible = true
		else:
			l.visible = false


## Lights currently lit (tests).
func lit_count() -> int:
	var n := 0
	for l in pool:
		if l.visible and l.light_energy > 0.0:
			n += 1
	return n

