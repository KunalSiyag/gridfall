extends RefCounted
## First-person asset paths. Slice H owns this list and produces the files; every consumer loads
## them with load_scene() and falls back to the legacy asset or a procedural stand-in on null.

const PEOPLE_LEGACY_DIR := "res://models/real/people/"
const PEOPLE_RIGGED_DIR := "res://models/real/people_rigged/"
const VEHICLES_LEGACY_DIR := "res://models/real/vehicles/"
const VEHICLES_V2_DIR := "res://models/real/vehicles_v2/"
const STREET_DIR := "res://models/real/street/"
const TRAFFIC_LIGHT := STREET_DIR + "traffic_light.glb"
const PED_SIGNAL := STREET_DIR + "ped_signal.glb"
const STREET_SIGN := STREET_DIR + "street_sign.glb"
const STOP_SIGN := STREET_DIR + "stop_sign.glb"
const YIELD_SIGN := STREET_DIR + "yield_sign.glb"
const BUS_SHELTER := STREET_DIR + "bus_shelter.glb"
const BILLBOARD_POSTER := STREET_DIR + "billboard.glb"
const POSTER_FRAME := STREET_DIR + "poster_frame.glb"
const HOARDING := STREET_DIR + "hoarding.glb"
const CROSSWALK_RAMP := STREET_DIR + "curb_ramp.glb"
const BIKE_RACK := STREET_DIR + "bike_rack.glb"
const PARKING_METER := STREET_DIR + "parking_meter.glb"
const LEASE_SIGN := STREET_DIR + "lease_sign.glb"
const BOLLARD := "res://models/real/props/bollard.glb"
const BICYCLE := VEHICLES_V2_DIR + "bicycle.glb"
## Animation names every rigged person provides, as Godot lists them after import. H names the
## Blender actions "<name>-loop" (and "sit") so the importer sets LOOP_LINEAR; H's test confirms
## the suffix is stripped on 4.7.2. If it is not, H changes this list to the suffixed names.
const PERSON_ANIMS := ["idle", "walk", "run", "talk", "sit"]
const PERSON_LOOPING := ["idle", "walk", "run", "talk"]
## Separate wheel nodes on vehicles_v2 road vehicles (origin at the hub, spin about local X).
const WHEEL_NODES := ["Wheel_FL", "Wheel_FR", "Wheel_RL", "Wheel_RR"]
const BIKE_WHEEL_NODES := ["Wheel_F", "Wheel_R"]
## Node-name contracts inside H's GLBs (all optional; consumers fall back when absent).
## Poster_<n>: MeshInstance3D, one surface, material "Poster", UV 0..1, normal +Z in node space.
const POSTER_NODE_PREFIX := "Poster_"
## PosterSpot_<n>: empty on a blank wall, +Z out of the wall, scale = poster size in units.
const POSTER_SPOT_PREFIX := "PosterSpot_"
## Door_<n>: empty at the bottom centre of a doorway, +Z out, scale.y = leaf height.
const DOOR_SPOT_PREFIX := "Door_"
## ColBox_<n>: empty, position = box centre, scale = half extents (collision proxy, no mesh).
const COLBOX_PREFIX := "ColBox_"

## path -> PackedScene, or null when the path could not be loaded as a scene.
static var _scene_cache: Dictionary = {}


## First path in the list that load_scene() can load, or "".
static func first_existing(paths: Array) -> String:
	for p: Variant in paths:
		if load_scene(str(p)) != null:
			return str(p)
	return ""


## The PackedScene at path, or null. Returns non-null only when ResourceLoader.exists(path) is
## true, load(path) is non-null and the result is a PackedScene. Cached per path.
static func load_scene(path: String) -> PackedScene:
	if _scene_cache.has(path):
		return _scene_cache[path]
	var ps: PackedScene = null
	if not path.is_empty() and ResourceLoader.exists(path):
		var res: Resource = load(path)
		if res is PackedScene:
			ps = res as PackedScene
	_scene_cache[path] = ps
	return ps
