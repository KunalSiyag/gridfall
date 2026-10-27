extends RefCounted
## The bench the windowed proofs run on (tools/backhoe_proof.gd, tools/vehicles_proof.gd): the
## output directory from the command line, the feature context (view, render, grow, a third-person
## camera) with the world's own clocks paused, the traffic and drive features stopped on the bench,
## the stepping loop with a live shot-camera hook, and the shot, fail and finish helpers. What
## each proof stages and frames is its own.

const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const OBB := preload("res://scripts/fp/obb2d.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const LG := preload("res://scripts/fp/traffic/lane_graph.gd")
const DT := 1.0 / 60.0

## The proof's own name in its prints.
var tag: String = "PROOF"
var tree: SceneTree
var ctx: FpContext
var traffic: FpFeature
var drive: FpFeature
var output: String = ""
var failed: bool = false
## The bench's per-frame hook, called after the view update (the proofs put their shot camera
## there); unset leaves the player's own camera alone.
var per_frame: Callable = Callable()
## The lanes of the longest plain straight road `road()` last staged, for the proofs that ride
## and drive along it; [] until then.
var lanes: Array = []


## Builds the bench: the output directory (--output= on the command line, else the fallback), the
## context with the world's own clocks paused, and the traffic and drive features stopped on it.
## Returns the output directory in use.
func bench(p_tree: SceneTree, fallback: String) -> String:
	var out := fallback
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--output="):
			out = arg.trim_prefix("--output=")
	tree = p_tree
	output = out
	# The proofs stage driven lane cars, and claiming one with carjack on drags its driver out
	# and knocks them down beside it, in every shot that follows.
	FeatureFlags.set_override("carjack", false)
	DirAccess.make_dir_recursive_absolute(out)
	ctx = K.make_ctx(
		tree.get_root(), {"view": true, "render": true, "grow": true, "camera_mode": "third"}
	)
	# The game enters street view this way (main.gd); without it the orbit-only layers (mayor
	# bots, territory borders, labels) stay up and float over the street at tile scale.
	ctx.view.set_fp_mode(true)
	if ctx.view.has_method("flush_rebuild_queue"):
		ctx.view.call("flush_rebuild_queue")
	ctx.collision.rebuild_all()
	ctx.player.set_process(false)
	ctx.player.input_enabled = false
	ctx.sim.set_process(false)
	ctx.sky.set_process(false)
	traffic = K.make_feature(ctx, "traffic")
	drive = K.make_feature(ctx, "drive")
	for f: FpFeature in [traffic, drive]:
		f.set_process(false)
	return out


## Steps the real clocks for the given frames with nothing held: the drive feature's own process
## (held input actions ride and drive through it), the traffic feature's step and visuals, the
## player's view; then the per-frame hook puts the shot camera where the proof wants it.
func settle(frames: int) -> void:
	for _k in frames:
		drive.call("_process", DT)
		traffic.call("step", DT)
		traffic.call("sync_visuals", DT)
		ctx.player.update_view(DT)
		if per_frame.is_valid():
			per_frame.call()
		await tree.process_frame


## Holds an input action for the given frames, then lets it go.
func hold(action: String, frames: int) -> void:
	Input.action_press(action)
	await settle(frames)
	Input.action_release(action)
	await settle(4)


## Puts the hero at the vehicle's driver's side, close enough to claim it.
func beside(c: VH.Car) -> void:
	var u := OBB.side_axis(c.yaw)
	var q := Vector2(c.pos.x + c.vis_off.x, c.pos.z + c.vis_off.z)
	var p := q + u * (c.half_w + WS.PLAYER_RADIUS - 0.6 * WS.M)
	ctx.player.teleport(Vector3(p.x, ctx.collision.walk_height(Vector3(p.x, 0.0, p.y)), p.y), 0.0)


## Stages the lanes of the longest stretch of plain straight road on `lanes` (the run of straight
## tiles counted out from every straight tile first, then the longest one rebuilt), for the proofs
## that ride and drive along it. False when the town has no road of 3+ plain straight tiles, or
## its longest run carries no lanes.
func road() -> bool:
	var lg: LG = traffic.get("lanes")
	var best_len := 0
	var best_i := -1
	var best_e := 0
	for i: int in lg.tiles.keys():
		var here: LG.TileInfo = lg.tiles[i]
		if here.piece != "straight" or here.bridge:
			continue
		for e: int in [0, 1]:
			if not (here.mask & (1 << e)):
				continue
			var n := _straight_run(lg, i, e)
			if n > best_len:
				best_len = n
				best_i = i
				best_e = e
	if best_len < 3:
		fail("a straight road of 3+ tiles (%d)" % best_len)
		return false
	var run: Array[int] = [best_i]
	var at := best_i
	for _k in best_len - 1:
		at = lg.across(at, best_e)
		run.append(at)
	lanes = lg.lanes_along(run, LG.OPP[best_e], best_e)
	if lanes.is_empty():
		fail("the road carries lanes")
		return false
	return true


## How many plain straight tiles run on from tile i along edge e, tile i itself counted.
func _straight_run(lg: LG, i: int, e: int) -> int:
	var n := 1
	var at := lg.across(i, e)
	while at >= 0:
		var info: LG.TileInfo = lg.info(at)
		if info == null or info.piece != "straight" or info.bridge:
			break
		n += 1
		at = lg.across(at, e)
	return n


## Lets the driven vehicle pull up, then gets the hero out and waits for the exit to finish: off
## a bicycle that is at once, while the cars go the long way round (car_doors), braking to a stop,
## the door opening and the hero climbing out over the frames that follow. The proof should let
## its own shot camera go first (the player's camera takes the pull-up over).
func stop_and_leave() -> void:
	Input.action_release("drive_throttle")
	Input.action_press("drive_brake")
	await settle(120)
	Input.action_release("drive_brake")
	if not bool(drive.call("leave")):
		fail("leave gets the hero out")
		return
	for _k in 300:
		if not bool(drive.get("active")):
			return
		await settle(1)
	fail("the hero ends up out of the car")


## The car the hero is at the wheel of.
func car() -> VH.Car:
	return _vh().by_id.get(int(drive.get("car_id")))


## Every car in town.
func cars() -> Array:
	return _vh().cars


## Every car in town goes, the player's own included, and the dynamic kerb boxes with them — a
## clean road, the hero on foot.
func clear_cars() -> void:
	for c: VH.Car in cars().duplicate():
		_vh().remove(c)
	ctx.collision.dynamic_boxes = []


## Every walker goes, so a vehicle staged where people are not the subject clips no bystander.
func quiet_walkers() -> void:
	K.quiet_walkers(traffic)


## The vehicles the traffic feature runs.
func _vh() -> VH:
	return traffic.get("vehicles")


## Waits for the driven car's full model to load in the background.
func load_model() -> Node3D:
	for _k in 240:
		traffic.call("sync_visuals", DT)
		ctx.player.update_view(DT)
		var node: Node3D = car().node
		if node != null:
			return node
		await tree.process_frame
	return null


## Saves the viewport as name.png in the output directory.
func shot(p_name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := tree.get_root().get_texture().get_image()
	var result := image.save_png(output.path_join(p_name + ".png"))
	if result != OK:
		fail("saving %s" % p_name)
	print("%s: %s %s" % [tag, p_name, error_string(result)])


## Records a failure.
func fail(what: String) -> void:
	failed = true
	print("%s: FAIL %s" % [tag, what])


## Ends the proof: PASS or FAIL, then an exit code to match.
func finish() -> void:
	print("%s: %s (%s)" % [tag, "FAIL" if failed else "PASS", output])
	tree.quit(1 if failed else 0)
