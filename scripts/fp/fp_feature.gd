class_name FpFeature
extends Node3D
## A first-person feature module owned by one slice. FpMode instantiates it from the registry,
## adds it under FpMode/Features (Node3D at identity, so children are in world space) and drives
## the lifecycle: setup -> on_world_rebuilt (after every view.setup) -> to_dict/from_dict -> teardown.

var ctx: FpContext


## Stable id; also the key in ctx.features and in save["fp"]. Override.
func feature_id() -> String:
	return ""


## Store ctx, connect signals, build nodes that do not depend on the city geometry.
func setup(p_ctx: FpContext) -> void:
	ctx = p_ctx


## The city view was rebuilt (boot, load, New City). Re-attach anything tied to tiles.
func on_world_rebuilt() -> void:
	pass


## Feature state for save["fp"][feature_id()]. Return {} for nothing.
func to_dict() -> Dictionary:
	return {}


## Restore state; d is {} for a fresh city or an old save.
func from_dict(_d: Dictionary) -> void:
	pass


## Disconnect from long-lived objects (sim, view, residents, brain, bus); FpMode frees the node after.
func teardown() -> void:
	pass


## Interaction pick along a ray (A's interact queries every feature). Return a target dict
## (§9) or {} when this feature owns nothing on the ray within max_dist.
func pick(_origin: Vector3, _dir: Vector3, _max_dist: float) -> Dictionary:
	return {}


## Called by the FP smoke after the world is up. {"ok": bool, "detail": String}.
func self_test() -> Dictionary:
	return {"ok": true, "detail": "stub"}


## Extra named eye-level shots for the FP photo tour:
## [{"name": String, "pos": Vector3 (feet), "yaw": float deg, "pitch": float deg, "hour": float,
##   "prepare": String (optional), "restore": String (optional)}].
## "prepare" / "restore" name methods on this feature that the tour calls (no arguments) before
## the shot is placed and after it is saved, for example forcing rain and clearing it again.
func photo_shots() -> Array:
	return []
