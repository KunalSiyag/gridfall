extends RefCounted
## First-person world scale. One unit is one tile is 20 m; physical quantities are written as
## metres * M. Preload as WS: `const WS := preload("res://scripts/fp/world_scale.gd")`.
## Values are frozen (docs/fp/S0-foundation.md §4.3): a slice adds constants only inside its own
## section at the end of this file.

const M := 0.05                          # units per metre (core.py:19 M = 1/20)
const TILE_M := 20.0                     # metres per tile

# --- Player
const EYE := 1.65 * M                    # 1.65 m standing eye height (ARCH §2)
const CROUCH_EYE := 1.0 * M              # 1.0 m crouched eye height (ARCH §2)
const PLAYER_RADIUS := 0.3 * M           # 0.3 m capsule radius (ARCH §2)
const PLAYER_HEIGHT := 1.8 * M           # 1.8 m standing height
const CROUCH_HEIGHT := 1.2 * M           # 1.2 m crouched height
const WALK := 1.45 * M                   # 1.45 m/s (ARCH §2)
const RUN := 4.5 * M                     # 4.5 m/s (ARCH §2)
const CROUCH_WALK := 0.8 * M             # 0.8 m/s
const ACCEL := 10.0 * M                  # 10 m/s², ground acceleration
const GRAVITY := 9.81 * M                # 9.81 m/s² (crit §d)
const JUMP_SPEED := 3.4 * M              # 3.4 m/s, apex about 0.59 m
const STEP_HEIGHT := 0.25 * M            # 25 cm max auto step; clears the 12 cm curb
const MOUSE_SENSITIVITY := 0.0022        # radians per pixel (default setting)
const PITCH_LIMIT_DEG := 85.0
const PHOTO_FLY_SPEED := 8.0 * M         # 8 m/s photo-mode free-fly

# --- Camera
const CAMERA_NEAR := 0.004               # 8 cm (probe-verified: Godot keeps 0.004)
const CAMERA_FAR := 60.0                 # 1.2 km
const FOV := 72.0                        # degrees, vertical

# --- Roads (authoring values, tools/blender/realcity/roads.py)
const ROAD_HALF := 0.3                   # 6 m carriageway half-width (roads.py:27 HW)
const LANE_OFFSET := 0.15                # 3 m right-hand lane centre (dashes at 0, carriageway ±0.3)
const ASPHALT_TOP := 0.003               # 6 cm (roads.py:24 ZA)
const SIDEWALK_TOP := 0.009              # 18 cm above the tile datum (roads.py:25 ZS)
const CURB_RISE := SIDEWALK_TOP - ASPHALT_TOP  # 12 cm curb face (roads.py:45)
const MARKING_TOP := 0.0033              # roads.py:26 ZM = ZA + 0.0003
const SIDEWALK_INNER := 0.3              # 6 m: sidewalk band starts at the curb (_straight_sides)
const SIDEWALK_OUTER := 0.5              # 10 m: tile edge
const SIDEWALK_CENTER := 0.4             # 8 m: sidewalk band centre (spawn point, sidewalk_point)
const CURB_FURNITURE := [0.305, 0.345]   # lamps, signs, bins, bollards (baked lamps at ±0.34, roads.py:166-167)
const PED_BAND := [0.355, 0.405]         # pedestrian centrelines (E), review DEH-20
const FRONT_FURNITURE := [0.415, 0.49]   # shelters, racks, meters against the lot edge, review DEH-20
const STOP_LINE := 0.35                  # stop-line inner edge from the junction centre (roads.py:109-115)
const ZEBRA_NEAR := 0.375                # roads.py:92-106
const ZEBRA_FAR := 0.47                  # roads.py:92-106
const CORNER_INNER_R := 0.2              # corner carriageway inner radius about the tile corner (roads.py:173-181)
const CORNER_OUTER_R := 0.8              # roads.py:173-181
const CORNER_LANE_R_IN := 0.35           # inner lane arc, 0.5 - 0.15
const CORNER_LANE_R_OUT := 0.65          # outer lane arc, 0.5 + 0.15
const CORNER_FILLET_R := 0.09            # junction curb fillet (roads.py:188)
const END_CIRCLE_R := 0.38               # cul-de-sac turning circle (roads.py:244)
const END_CIRCLE_OFFSET := 0.04          # circle centre offset toward the closed end (roads.py:245; Blender +Y is Godot -Z)
const END_ISLAND_R := 0.11               # raised grass island at SIDEWALK_TOP with a tree (roads.py:263-266)
const BRIDGE_SIDEWALK_OUT := 0.428       # walkable bridge sidewalk ends; parapet beyond (roads.py:270-281)
const LAMP_HEIGHT := 0.42                # 8.4 m (roads.py:127)

# --- Ground datum (current CityView geometry)
const GROUND_Y := -0.012                 # base grass plane (city_view.gd:278)
const LOT_TOP := 0.004                   # real-model lot slab top (validate_real)
const PAD_TOP := 0.006                   # C/I pad and rubble plane (city_view.gd:934, 989)
const WATER_Y := 0.03                    # water surface (city_view.gd:290)
const RIVERBED_Y := -0.004               # city_view.gd:285
const LOT_FOOTPRINT := 0.94              # authored lot width before REAL_SCALE (validate_real)

# --- Asset multipliers (targets the slices apply)
const REAL_SCALE := 1.0                  # buildings (CityView uses 0.9 today)
const PEOPLE_SCALE := 1.0                # avatars use 1.5 today
const VEHICLE_SCALE := 1.0 / 1.2         # legacy real vehicles were authored at 1.2x (vehicles.py:22)
const VEHICLE_V2_SCALE := 1.0            # H's re-exported vehicles
const MACHINE_SCALE := 1.0 / 20.0        # construction machines (construction_kit.gd:9 uses 1/16)
const PERSON_H := 1.75 * M               # 1.75 m authored person height (people.py:1)

# --- Agent speeds (E)
const CAR_CITY := 13.9 * M               # 50 km/h
const CAR_RESIDENTIAL := 8.3 * M         # 30 km/h
const BUS_SPEED := 11.1 * M              # 40 km/h
const EMERGENCY_SPEED := 19.4 * M        # 70 km/h
const PED_WALK := 1.35 * M               # 1.35 m/s
const PARK_OFFSET := 0.245               # 4.9 m curb parking slot centre from the road centreline (DEH-11)
const PASS_OFFSET := 0.12                # 2.4 m moving lane beside occupied parking slots (DEH-11)

# --- Interaction (A)
const TALK_RANGE := 3.0 * M              # 3 m
const INTERACT_RANGE := 6.0 * M          # 6 m: buildings, posters, cars

# --- Audio (I)
const AUDIO_UNIT_SIZE := 0.5             # AudioStreamPlayer3D unit_size (10 m)

# --- Light profile targets (G1)
const SHADOW_MAX_DIST := 12.0            # 240 m (crit §d: 8-15)
const SSAO_RADIUS := 1.0 * M             # 1 m (crit §d)
const SSIL_RADIUS := 5.0 * M             # 5 m (crit §d)
const FOG_DEPTH_BEGIN := 20.0            # 400 m
const FOG_DEPTH_END := 58.0              # 1.16 km, just inside CAMERA_FAR

# --- Visibility targets (G2, E)
const VIS_BUILDING := 15.0               # 300 m: real buildings; merged impostors beyond (G2)
const VIS_PROP := 4.0                    # 80 m
const VIS_PERSON := 4.0                  # 80 m
const VIS_CAR := 10.0                    # 200 m
const VIS_SITE_PART := 8.0               # 160 m
const TRAFFIC_RADIUS := 15.0             # 300 m full traffic sim radius

# --- Time
const FP_DAY_SECONDS := 1200.0           # 20-minute game day (D4)
const TIME_SCALES := [1, 2, 4, 8]        # allowed first-person speeds (D4)


# --- A player (owned by A)
# end A


# --- B hud (owned by B)
# end B


# --- C chat (owned by C)
# end C


# --- D posters (owned by D)
# end D


# --- E traffic (owned by E)
# end E


# --- F sim performance (owned by F)
# end F


# --- G1 streetscape (owned by G1)
# end G1


# --- G2 render performance (owned by G2)
# end G2


# --- H assets (owned by H)
# end H


# --- I audio (owned by I)
# end I
