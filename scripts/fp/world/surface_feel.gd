extends RefCounted
## What each ground surface feels like to the hero (flag surface_feel), written once: the footstep
## set and its level and pitch, how much slower the surface is to run on, and how much dust a
## sprint kicks up. const-only and static, so tests pin every class. Preload as SF.
##
## The classes are CollisionWorld.surface_at's names, plus "sand" (the lawn and the dry shelf of a
## river bank inside the shore band, shore.gd: sand the ground shader paints there). The recorded
## step sets are asphalt, sidewalk, lot, grass, dirt, bridge and the splash set for water
## (sounds/fp, 33 KB each, nothing new is shipped); a class without its own recordings borrows the
## nearest and is told apart by level and pitch:
##   sand   dirt, 3 dB soft and a fifth lower: a damp, dull scuff
##   gravel dirt, 1.5 dB louder and a sixth higher: the grit of a crunch
##   trail  grass, a little softer and lower: a worn path
## Speeds are factors of the top speed: pavement and slabs 1, a bridge 1, grass 0.98, a dirt track
## and gravel 0.97, trail 0.98, sand 0.93 (the softest). Dust, 0..1, is the share of the puff a
## sprinting step raises (0 on anything paved or wet).

const WS := preload("res://scripts/fp/world_scale.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const RB := preload("res://scripts/fp/world/riverbed.gd")
const SHORE := preload("res://scripts/world/shore.gd")

## class -> {"set": footstep surface, "gain": dB on the step, "pitch": factor, "speed": factor,
## "dust": 0..1}.
const TABLE := {
	"asphalt": {"set": "asphalt", "gain": 0.0, "pitch": 1.0, "speed": 1.0, "dust": 0.0},
	"sidewalk": {"set": "sidewalk", "gain": 0.5, "pitch": 1.0, "speed": 1.0, "dust": 0.0},
	"lot": {"set": "lot", "gain": 0.0, "pitch": 0.97, "speed": 1.0, "dust": 0.0},
	"grass": {"set": "grass", "gain": -2.5, "pitch": 0.96, "speed": 0.98, "dust": 0.0},
	"sand": {"set": "dirt", "gain": -3.0, "pitch": 0.82, "speed": 0.93, "dust": 1.0},
	"dirt": {"set": "dirt", "gain": 0.0, "pitch": 1.0, "speed": 0.97, "dust": 0.7},
	"gravel": {"set": "dirt", "gain": 1.5, "pitch": 1.16, "speed": 0.97, "dust": 0.45},
	"trail": {"set": "grass", "gain": -1.5, "pitch": 0.92, "speed": 0.98, "dust": 0.25},
	"bridge": {"set": "bridge", "gain": 0.5, "pitch": 0.96, "speed": 1.0, "dust": 0.0},
	"water": {"set": "water", "gain": 0.0, "pitch": 1.0, "speed": 1.0, "dust": 0.0},
}
## The class of a surface name the table does not know: it sounds and runs like the sidewalk.
const FALLBACK := "sidewalk"
## A step on the dry shelf or the wet edge of a river (water shallower than this, m) is sand.
const SHELF_M := 0.03
## The sand's band of the shore, as a share of the shore band's own (shore.gd, 0..1 of its sand
## weight): from here on land counts as sand.
const SAND_FROM := 0.5
## Top-speed factors ease toward their class with this halflife (s): no jolt at a surface edge.
const HL_SPEED := 0.2
## A puff of dust needs the hero at least this fast (m/s): a run (4.5) or a sprint, not a walk.
const DUST_MIN_MPS := 4.0


## The feel class of CollisionWorld surface name `surface` at world point p: grass inside the
## shore band of a river and the dry shelf of its bank are "sand"; any other name is itself (an
## unknown one the FALLBACK).
static func feel_at(col: CollisionWorld, surface: String, p: Vector3) -> String:
	if surface == "grass" and near_water(col.ctx.sim, p):
		return "sand"
	if surface == "water" and col.water_depth(p) < SHELF_M * WS.M:
		return "sand"
	return surface if TABLE.has(surface) else FALLBACK


## True when land point p lies in the sand of a shore: its tile touches water and its distance to
## the water is inside SAND_FROM of the band (shore.gd, which the ground shader paints).
static func near_water(sim: CitySim, p: Vector3) -> bool:
	var x := roundi(p.x)
	var y := roundi(p.z)
	if not D.in_bounds(x, y) or sim.terrain[D.idx(x, y)] == D.WATER:
		return false
	var flags := SHORE.water_flags(sim, x, y)
	if not flags.has(true):
		return false
	var dist := RB.land_distance(flags, p.x - float(x) + 0.5, p.z - float(y) + 0.5)
	return SHORE.band(dist).x >= SAND_FROM


## The row of class c (an unknown class gets FALLBACK's).
static func row(c: String) -> Dictionary:
	return TABLE[c] if TABLE.has(c) else TABLE[FALLBACK]


## The top-speed factor of class c.
static func speed(c: String) -> float:
	return float(row(c)["speed"])


## The dust share of class c.
static func dust(c: String) -> float:
	return float(row(c)["dust"])


## The footstep set (audio_bank.gd's SURFACES name) to play for class c.
static func step_set(c: String) -> String:
	return str(row(c)["set"])


## How wet the streets are, 0..1: the streetscape's weather, read by name (0 without it).
static func street_wet(ctx: FpContext) -> float:
	var street := ctx.feature("streetscape") if ctx != null else null
	if street == null:
		return 0.0
	var w: Variant = street.get("weather")
	if not (w is Object) or not is_instance_valid(w):
		return 0.0
	var v: Variant = (w as Object).get("wet")
	return clampf(float(v), 0.0, 1.0) if typeof(v) == TYPE_FLOAT else 0.0
