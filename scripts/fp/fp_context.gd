class_name FpContext
extends RefCounted
## Service locator for first-person slices. FpMode fills it once in setup(); fields never change
## identity until FpMode.teardown() (CityView keeps its identity across view.setup()).

const WS := preload("res://scripts/fp/world_scale.gd")
const D := preload("res://scripts/sim/sim_defs.gd")

var main: Node3D                  # main.gd; call main.save_game(), main.focus(), main.notify(), main.exit_fp()
var mode: FpMode
var sim: CitySim
var residents: Residents          # may be inactive (GRIDFALL_RESIDENTS=0): check residents.is_active()
var minds: ResidentMinds
var brain: CityBrain
var client: GmiClient
var view: CityView
var sky: SkyDirector
var audio: GridFallAudioDirector
var sun: DirectionalLight3D
var env: Environment              # the shared Environment (Main.camera.environment), mutated by SkyDirector
var bus: GameBus
var player: FpPlayer
var hud: FpHud
var collision: CollisionWorld
var directory: CityDirectory
var world_root: Node3D            # FpMode/World: put in-world FP nodes here, never under CityView
var features: Dictionary = {}     # feature_id -> FpFeature
var settings: Dictionary = {}     # see FpMode.DEFAULT_SETTINGS; change only via mode.apply_settings()
var ws: GDScript = WS             # convenience; prefer your own `const WS := preload(...)` for typing
var _modal: Dictionary = {}       # owner StringName -> true


## The registered feature with this id, or null.
func feature(id: String) -> FpFeature:
	return features.get(id, null)


## A UI that needs the mouse and keyboard (chat input, pause menu, map, dialogue) pushes itself;
## while any owner is pushed, the player ignores movement and look, and the mouse is visible.
## Emits bus.modal_changed(true) on 0 -> 1.
func push_modal(owner: StringName) -> void:
	if _modal.has(owner):
		return
	_modal[owner] = true
	if _modal.size() == 1 and bus != null:
		bus.modal_changed.emit(true)


## Removes owner; emits bus.modal_changed(false) on 1 -> 0.
func pop_modal(owner: StringName) -> void:
	if not _modal.has(owner):
		return
	_modal.erase(owner)
	if _modal.is_empty() and bus != null:
		bus.modal_changed.emit(false)


## True while any modal owner is pushed.
func is_modal() -> bool:
	return not _modal.is_empty()


## True while owner is pushed.
func has_modal(owner: StringName) -> bool:
	return _modal.has(owner)


## Number of pushed modal owners.
func modal_count() -> int:
	return _modal.size()


## Feet position of the player (world units). Without a player (some unit tests): mode.spawn_point().pos
## when mode is set up, else Vector3.ZERO.
func player_position() -> Vector3:
	if player != null and is_instance_valid(player):
		return player.position
	if mode != null and is_instance_valid(mode) and mode.ctx == self and sim != null:
		return mode.spawn_point()["pos"]
	return Vector3.ZERO


## Tile index under the player (D.idx), or -1 outside the world.
func player_tile() -> int:
	var p := player_position()
	var x := roundi(p.x)
	var y := roundi(p.z)
	return D.idx(x, y) if D.in_bounds(x, y) else -1
