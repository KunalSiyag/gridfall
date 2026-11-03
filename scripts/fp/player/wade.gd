extends RefCounted
## The hero in water (flag hero_wade): the numbers FpPlayer reads while wading, written once and
## const-only so tests can pin them. Depths are world units over the riverbed (CollisionWorld.
## water_depth); the hero wades to WS.WADE_MAX, slower the deeper it gets, and cannot swim (the
## clip set has no swim or tread). Preload as WADE.

const WS := preload("res://scripts/fp/world_scale.gd")

## Deeper than this a jump loses its spring: the water holds the legs.
const JUMP_FROM := 0.2 * WS.M
const JUMP_FACTOR := 0.6
## The hero looks this far ahead (m) for water past WADE_MAX before the "too deep" notice.
const LOOK_AHEAD := 0.7 * WS.M
## Seconds between two "too deep" notices.
const TOO_DEEP_EVERY := 20.0
const TOO_DEEP_TEXT := "Too deep to wade."
## The first-person eye never sinks closer than this to the water surface (a hero knocked down
## while wading would otherwise look up from under the plane, which is drawn from above only).
const EYE_CLEAR := 0.1 * WS.M


## Top-speed factor in water of this depth: 1 up to WADE_SLOW_FROM, WADE_SLOW at WADE_MAX, an
## eased fall in between.
static func speed_factor(depth: float) -> float:
	return lerpf(1.0, WS.WADE_SLOW, smoothstep(WS.WADE_SLOW_FROM, WS.WADE_MAX, depth))


## The lowest eye height (relative to the feet at world height feet_y) of a hero standing in water:
## EYE_CLEAR above the surface. A hero on dry ground has no floor (-INF).
static func eye_floor(feet_y: float, depth: float) -> float:
	return WS.WATER_Y + EYE_CLEAR - feet_y if depth > 0.0 else -INF


## The jump speed factor: 1 in the shallows, JUMP_FACTOR from JUMP_FROM on.
static func jump_factor(depth: float) -> float:
	return JUMP_FACTOR if depth > JUMP_FROM else 1.0


## True while a sprint cannot build: past the ankles the pace tops out at a run.
static func caps_sprint(depth: float) -> bool:
	return depth > WS.WADE_NO_SPRINT


## True when the hero standing in `depth` of water, heading `dir` (unit xz), is about to meet a bed
## deeper than WADE_MAX: the notice's trigger. Deep ahead and already past half of WADE_MAX.
static func too_deep_ahead(col: CollisionWorld, pos: Vector3, dir: Vector2, depth: float) -> bool:
	if depth < WS.WADE_MAX * 0.5 or dir == Vector2.ZERO:
		return false
	var ahead := pos + Vector3(dir.x, 0.0, dir.y) * LOOK_AHEAD
	return col.water_depth(ahead) > WS.WADE_MAX + 1e-6
