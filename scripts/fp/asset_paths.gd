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
## Driver contact markers in vehicles_v2 road vehicles with a driver's seat (empties, like
## Seat_Driver): Pedal_L / Pedal_R at the ankle targets on the footwell floor (the driver's side
## is +X), Wheel_L / Wheel_R on the steering rim, Cab_Roof on the headliner above the seat. The
## drive feature seats the hero's feet and hands on them and sinks the hips until the head clears
## Cab_Roof, so the seated pose fits every cabin.
const DRIVER_MARKERS := ["Pedal_L", "Pedal_R", "Wheel_L", "Wheel_R", "Cab_Roof"]
## The bicycle's cranks and pedals (origin at the bottom bracket, spin about local X; the left
## pedal, on +X, straight up at rest).
const CRANK_NODE := "Crank"
## Far LOD next to each vehicles_v2 model (<name>_lod1.glb): one mesh, wheels merged, at most 1,500
## triangles, a few flat untextured materials (colour in the albedo); the lamp lenses are the
## emissive Light_Head / Light_Tail.
const VEHICLE_LOD_SUFFIX := "_lod1.glb"
## Traffic-signal lens nodes in TRAFFIC_LIGHT (<prefix><n>, one material each), and the pedestrian
## head nodes in TRAFFIC_LIGHT and PED_SIGNAL.
const SIGNAL_NODE_PREFIXES := ["Signal_Red_", "Signal_Amber_", "Signal_Green_"]
const WALK_NODE_PREFIX := "Walk_"
const DONT_WALK_NODE_PREFIX := "DontWalk_"
## Name-blade anchors in TRAFFIC_LIGHT and STREET_SIGN: A runs along X facing +Z, B along Z facing +X.
const SIGN_TEXT_NODES := ["SignText_A", "SignText_B"]
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


# --- HC characters ---
## Realistic characters (slice HC, docs/fp/slices/HC-characters.md). Bodies are Microsoft Rocketbox
## avatars on Godot's humanoid skeleton (`%GeneralSkeleton`, metric, feet at y = 0, facing +Z). Scale
## each one under a `CharacterRoot` node: `scale = WS.M * h_target_m / rest_height_m`, with
## rest_height_m (stature to the skull top; hair and hats add up to 4 %) from CHAR_ROSTER. Animate with the gender's library added as the default library ""
## (clip names stay bare: "walk") and `root_motion_track = CHAR_ROOT_MOTION_TRACK`; loops then play in
## place. Every clip carries the metas `speed_mps` (Root speed on a skeleton whose hips are
## `speed_ref_hip_m` high: a body with hip_m from the roster covers speed_mps * hip_m / speed_ref_hip_m
## metres per second before CharacterRoot scaling) and `loop`; turns also carry `root_turn_deg`.
const CHARACTERS_DIR := "res://models/characters/"
const CHAR_BODIES_DIR := CHARACTERS_DIR + "bodies/"
## roster.json: bodies (rest_height_m, hip_m, group, gender, lod1), job_pools, casual_pools,
## name_gender, height targets. Far LODs are CHAR_BODIES_DIR + "<Name>_lod1.glb".
const CHAR_ROSTER := CHARACTERS_DIR + "roster.json"
const CHAR_LIB_M := CHARACTERS_DIR + "anim/lib_m.tres"
const CHAR_LIB_F := CHARACTERS_DIR + "anim/lib_f.tres"
const HERO_M := CHAR_BODIES_DIR + "Male_Adult_06.glb"
const HERO_F := CHAR_BODIES_DIR + "Female_Adult_04.glb"
const CHAR_ROOT_MOTION_TRACK := "%GeneralSkeleton:Root"
## LookAtModifier3D.forward_axis for the Head and Neck bones of every character rig.
const CHAR_LOOK_AXIS := SkeletonModifier3D.BONE_AXIS_PLUS_Z
## Clips the player uses (both libraries hold them, plus AP.PERSON_ANIMS and the crowd extras).
const PERSON_TPS_ANIMS := [
	"idle", "walk", "walk_fast", "run", "run_fast", "crouch_idle", "crouch_walk", "jump_start", "fall",
	"land", "talk", "sit_down", "sit", "stand_up", "interact", "wave", "phone", "door_try",
	"walk_start", "walk_stop", "run_start", "run_stop", "turn_l90", "turn_r90", "turn_l180_walk",
	"turn_r180_walk",
]
# end HC


# --- animals (owned by the animals feature)
## Quaternius' rigged dogs (CC0, models/real/LICENSES/quaternius-dogs.txt): one skeleton, clips
## Walk, Gallop, Idle, Idle_2, Idle_2_HeadLow, Eating, Attack, Idle_HitReact_Left/Right and
## Jump_ToIdle.
const DOG_SHIBA := "res://models/real/animals/shiba_inu.glb"
const DOG_HUSKY := "res://models/real/animals/husky.glb"
## Quaternius' Cat (CC0, models/real/LICENSES/quaternius-cat.txt), rebuilt by
## tools/blender/make_cat.py: clips Idle, Walk, Trot, Run, Stalk, Crouch, Pounce, Sit, Loaf, Groom,
## Sleep, Hiss, Startle and Stretch, and the coat fields cat_coat.gdshader reads.
const CAT := "res://models/real/animals/cat.glb"
# end animals
