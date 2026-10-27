extends RefCounted
## Settled-state level of detail, shared by the animal life sims (pigeon_flock, squirrel_life,
## cat_life): an animal or flock with nothing going on, far from the hero, ticks at 4 Hz — the
## skipped time banks up and steps whole, so its timers keep pace. Anything happening (a
## fright, the hero coming close, a car bearing down, a hunt, an escape) takes it back to full
## rate on the next tick.

const WS := preload("res://scripts/fp/world_scale.gd")
## The slow-cadence period (s) and how far from the hero (u) it starts.
const SETTLE_S := 0.25
const NEAR := 25.0 * WS.M


## A flock's step budget this tick: dt, or nothing while a settled far flock banks time toward
## its next slow-cadence step. dodge_s is the flock sim's car-dodge horizon (DODGE_S).
static func flock_dt(f: Object, hero: Vector3, cars: Array, dodge_s: float, dt: float) -> float:
	return step_dt(f, f.home, hero, dt, flock_quiet(f, cars, dodge_s))


## True while nothing about a flock can change on its own: no fright running, no crumbs out,
## every bird down with none queued to take off, and (for a ground flock) no car that could
## reach it within the rest of a nap — a flutter-off must not start late. Parked and crawling
## cars never wake a flock; a perched one looks down on the street and cars cannot reach it.
static func flock_quiet(f: Object, cars: Array, dodge_s: float) -> bool:
	if f.alarm > 0.0 or not f.crumb_spots.is_empty():
		return false
	for b in f.birds:
		if b.air or b.delay > 0.0:
			return false
	if not f.perched:
		for c: Array in cars:
			var sp := Vector2((c[1] as Vector3).x, (c[1] as Vector3).z).length()
			var reach: float = float(c[2]) + sp * (dodge_s + SETTLE_S) + f.radius + 1.0 * WS.M
			if sp >= 1.0 * WS.M and _flat(c[0], f.home) < reach:
				return false
	return true


## An animal's step budget this tick: dt, or nothing while it banks. calm says its state is a
## quiet one (the caller knows its states: foraging, resting; never a hunt or an escape).
static func step_dt(a: Object, pos: Vector3, hero: Vector3, dt: float, calm: bool) -> float:
	if calm and _flat(pos, hero) > NEAR:
		a.hz_t += dt
		if a.hz_t < SETTLE_S:
			return 0.0
		var banked: float = a.hz_t
		a.hz_t = 0.0
		return banked
	a.hz_t = 0.0
	return dt


static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()
