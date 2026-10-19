extends RefCounted
## Intelligent Driver Model (Treiber 2000) in world units (docs/fp/slices/E-traffic.md §3).

const WS := preload("res://scripts/fp/world_scale.gd")
const T := 1.5                   # desired time headway, s
const A := 1.0 * WS.M            # max acceleration, 1 m/s²
const B := 2.0 * WS.M            # comfortable deceleration, 2 m/s²
const S0 := 2.0 * WS.M           # jam distance, 2 m
const DELTA := 4.0
const B_MAX := 8.0 * WS.M        # hardest braking the model may ask for


## Acceleration for speed v toward desired speed v0 with a leader gap (bumper to bumper) closing
## at dv = v - v_leader. gap = INF means a free road.
static func acc(v: float, v0: float, gap: float, dv: float) -> float:
	var free := 1.0 - pow(v / maxf(v0, 0.001), DELTA) if v0 > 0.001 else -1.0
	if gap == INF:
		return clampf(A * free, -B_MAX, A)
	if gap <= 0.0005:
		return -B_MAX
	var s_star := S0 + maxf(0.0, v * T + v * dv / (2.0 * sqrt(A * B)))
	var r := s_star / gap
	return clampf(A * (free - r * r), -B_MAX, A)


## Speed a car may hold at distance d before a point it must pass at v_end (comfortable braking).
static func approach_speed(v_end: float, d: float) -> float:
	return sqrt(maxf(0.0, v_end * v_end + 2.0 * B * maxf(d, 0.0)))
