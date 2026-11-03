extends RefCounted
## The first-day opening (flag first_day_opening): what a fresh street city does differently on its
## day 1, so the first minute shows a bright morning, a view down the avenue and a mayor turn soon.
## Main calls arm() before sim.start() and begin() after it, for a fresh interactive city only (not
## a loaded save, tools or tests); each undoes itself when the flag is off.
##   - the sky is clear all day (Weather.daily_state, via FpContext.first_day_opening);
##   - the clock opens at 07:30 (CitySim.start_at_progress; tools keep 06:00);
##   - the five founding mayor turns land within about 3.5 minutes at 1x (MayorTurns.opening);
##   - the hero faces down the avenue with City Hall at 45 degrees (FpMode.spawn_point).
## Nothing here is saved: a save carries the clock through the tick phase, and a loaded city
## (FpMode.from_dict) runs every day as before.

const D := preload("res://scripts/sim/sim_defs.gd")
## How far along a road the avenue is measured for the side with more of it (tiles).
const SCAN := 12


## Whether the opening is on (the flag).
static func enabled() -> bool:
	return FeatureFlags.enabled("first_day_opening")


## Before sim.start() of a fresh street city: day 1's mayor turns follow the compressed founding
## schedule when on, the ordinary one when not (always set, so a New city after a played one is
## right too).
static func arm(brain: CityBrain, on: bool) -> void:
	if brain != null:
		brain.turns.opening = on


## After sim.start(): opens the clock at FIRST_DAY_START and turns the hero to face down the
## avenue. mode must be set up (FpMode); returns false (and changes nothing) when it is not.
static func begin(mode: FpMode) -> bool:
	if mode == null or mode.ctx == null or mode.ctx.sim == null or mode.player == null:
		return false
	mode.ctx.first_day_opening = true
	mode.ctx.sim.start_at_progress(D.FIRST_DAY_START)
	var sp := mode.spawn_point()
	mode.player.teleport(sp["pos"], float(sp["yaw"]))
	_resync_sky(mode)
	return true


## Back from the Planner view (Main.enter_fp builds a new FpMode, whose from_dict cleared the
## opening): while it is still day 1 the sky is the opening's clear one again. The clock, the
## mayors and the hero's place are the city's own and carry on as they were.
static func resume(mode: FpMode) -> void:
	if mode == null or mode.ctx == null or mode.ctx.sim == null or mode.ctx.sim.day != 1:
		return
	mode.ctx.first_day_opening = true
	_resync_sky(mode)


## The street weather takes the sky the day now calls for at once.
static func _resync_sky(mode: FpMode) -> void:
	var street := mode.ctx.feature("streetscape")
	var weather: Variant = street.get("weather") if street != null else null
	if weather != null and weather.has_method("resync"):
		weather.resync()


## The hero's yaw (deg) on the sidewalk in front of City Hall: along the avenue (the road the hall
## fronts), towards the side with more road, with the hall 45 degrees off to one side. road is the
## frontage road tile and dir the unit vector from it to the hall (as FpMode.spawn_point has them).
static func avenue_yaw(sim: CitySim, road: int, dir: Vector3) -> float:
	var along := Vector3(-dir.z, 0.0, dir.x)
	if _run_length(sim, road, -along) > _run_length(sim, road, along):
		along = -along
	var f := (dir + along).normalized()
	return rad_to_deg(atan2(-f.x, -f.z))


## Road tiles in a row from road along step (a unit vector in tile axes), up to SCAN.
static func _run_length(sim: CitySim, road: int, step: Vector3) -> int:
	var x := D.tx(road)
	var y := D.ty(road)
	var n := 0
	while n < SCAN:
		x += roundi(step.x)
		y += roundi(step.z)
		if not D.in_bounds(x, y) or sim.kind[D.idx(x, y)] != D.ROAD:
			break
		n += 1
	return n
