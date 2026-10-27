extends RefCounted
## A thrown or flung body meeting a wall or a solid prop mid-flight (the throw_impact flag;
## docs/fp/ARCHITECTURE.md, Integration: brawl). reactions.gd plans the flight: impact_ahead
## probes the airborne slide for what it strikes and the throw's one person_hit carries the
## prediction in its info ({"at", "in"}) — marked there, never a second emission, so incidents
## and the street's answers do not double-book. Then, frame by frame, rebound_if_blocked turns
## the flight's collision clamp (the step the geometry eats) into a short rebound off the face,
## once a throw, the body slumping where it comes to rest. Pure helpers over the Reaction record;
## reactions.gd calls both.

const WS := preload("res://scripts/fp/world_scale.gd")

## The rebound's length (m) and seconds.
const REBOUND_M := 0.35
const REBOUND_S := 0.3
## Metres between the flight line's probes when a throw's impact is predicted.
const IMPACT_STEP_M := 0.1


## The predicted strike of a throw's flight from p along flight (the airborne slide, u) on the
## first wall or solid prop in the way: {"at", "in" (seconds into the flight)}; {} on a clear
## arc, with the flag off, or with nothing to probe with.
static func impact_ahead(
	collision: CollisionWorld, p: Vector3, flight: Vector3, air: float, reach: float, height: float
) -> Dictionary:
	if collision == null or not FeatureFlags.enabled("throw_impact"):
		return {}
	var d := flight.length()
	if d < 1e-6:
		return {}
	var step := IMPACT_STEP_M * WS.M
	var covered := step
	while covered < d:
		var q: Vector3 = p + flight * (covered / d)
		if collision.body_blocked(q, reach, height):
			return {"at": q, "in": air * covered / d}
		covered += step
	return {}


## The flight's step from p by move landed at q instead: when the geometry ate enough of it,
## head-on and mid-air, the throw rebounds off the face (throw_impact, once a throw).
static func rebound_if_blocked(r, p: Vector3, move: Vector3, q: Vector3) -> void:
	if r.impacted or not FeatureFlags.enabled("throw_impact"):
		return
	if r.air <= 0.0 or r.slide_t >= r.air:
		return
	var eaten: Vector3 = p + move - q
	if eaten.length_squared() <= move.length_squared() * 0.25 or eaten.dot(r.slide) <= 0.0:
		return
	r.impacted = true
	# eaten points into the face (the step's part the wall took); the rebound comes back off it.
	var away := -Vector3(eaten.x, 0.0, eaten.z)
	if away.length_squared() < 1e-10:
		away = -r.slide
	r.slide = away.normalized() * (REBOUND_M * WS.M)
	r.slide_t = 0.0
	r.slide_s = REBOUND_S
	r.air = 0.0
	r.skid = 1.0
