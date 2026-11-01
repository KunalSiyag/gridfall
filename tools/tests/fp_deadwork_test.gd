extends SceneTree
## Dead work at boot. Nobody on foot sees the data-view columns or the power and water icons, and
## the browser export compiles occlusion culling out, so:
## - CityView builds the column MultiMesh (one instance per tile) and the two icon MultiMeshes on
##   first use, not in setup(): none exists after a first-person boot, a Load or a New City; orbit
##   builds the icons when it is entered and the first data view builds the columns, as the very
##   buffer the old per-tile loop wrote; a planner round trip reuses what it built; on foot the
##   icons are left alone every frame; and a layer built late is drawn right away: the icons show
##   what the sim asks for (the tiles without power, the powered zones without water) on entering
##   orbit, on coming back from foot, after setup(), Load and New City, not after the next timer;
## - render_opt on the web (forced on here) builds no OccluderInstance3D and never turns the
##   viewport's occlusion culling on, through the boot pass, the chunk rebuilds, a Load and its self
##   test, while the impostor chunks stay what the desktop builds; the desktop path still builds
##   the occluders and the flag; the production default of that switch is the platform tag.
## Runs headless: the dummy renderer keeps a MultiMesh's bulk buffer but not its per-instance
## writes, so the columns are compared through that buffer and the definition _column() gives.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const Q := preload("res://scripts/fp/render/quality.gd")
const RENDER_OPT := "res://scripts/fp/render/render_opt_feature.gd"
const TILES := D.W * D.H
const SAVE := "user://deadwork_save.json"
## Every data view the HUD offers.
const MODES := [
	"power",
	"water",
	"pollution",
	"crime",
	"land_value",
	"traffic",
	"happiness",
	"services",
	"districts"
]

var fails: Array[String] = []
## The bare view of the first part: a sim, a camera and a CityView booted the way main.gd does.
var made: Dictionary
var sim: CitySim
var cam: Camera3D
var view: CityView
## The layers seen so far, to tell a reuse from a rebuild.
var icon_ids: Array = []
var col_id := 0


func _init() -> void:
	K.watchdog(self, "FP_DEADWORK_TEST", 250.0)
	await process_frame
	await _view_boot()
	_view_orbit()
	_view_pulse()
	_view_data()
	await _view_setup_again()
	await _view_foot_again()
	_view_free()
	await _check_occluders()
	await _check_main()
	K.finish(self, "FP_DEADWORK_TEST", fails)


## The live MultiMeshInstance3D children of v with one instance per tile: the column layer (it has
## colours) and the two icon layers (it has none).
func _layers(v: CityView, colours: bool) -> Array[MultiMeshInstance3D]:
	var out: Array[MultiMeshInstance3D] = []
	for c: Node in v.get_children():
		var m := c as MultiMeshInstance3D
		if m == null or m.is_queued_for_deletion() or m.multimesh == null:
			continue
		if m.multimesh.instance_count == TILES and m.multimesh.use_colors == colours:
			out.append(m)
	return out


func _ids(layers: Array[MultiMeshInstance3D]) -> Array:
	return layers.map(func(m: MultiMeshInstance3D) -> int: return m.get_instance_id())


## The albedo of an icon layer's sphere.
func _icon_colour(m: MultiMeshInstance3D) -> Color:
	return ((m.multimesh.mesh as PrimitiveMesh).material as StandardMaterial3D).albedo_color


## Neither layer exists: no node, and the view holds no reference.
func _bare(v: CityView, what: String) -> void:
	var none: bool = _layers(v, true).is_empty() and _layers(v, false).is_empty()
	for key: String in ["_overlay_mm", "_power_icons", "_water_icons"]:
		none = none and v.get(key) == null
	K.check(fails, none, "%s: no column layer and no icon layer exists" % what)


## True when the status icons mark tile i when it has no power or no water: a zone with a building,
## or a service that is no park and no power plant (CityView._refresh_status reads the same sim).
func _needs_status(s: CitySim, i: int) -> bool:
	var k := s.kind[i]
	if D.is_zone(k):
		return s.level[i] > 0
	return D.is_service(k) and k != D.PARK and not D.is_power_plant(k)


## The icon counts the sim asks for: x red icons (needs power, has none), y blue ones (powered, a
## zone, has no water).
func _icon_want(s: CitySim) -> Vector2i:
	var want := Vector2i.ZERO
	for i in s.active:
		if not _needs_status(s, i):
			continue
		if s.powered[i] == 0:
			want.x += 1
		elif s.watered[i] == 0 and D.is_zone(s.kind[i]):
			want.y += 1
	return want


## What the view's icon layers draw (their visible instance counts), as x red and y blue.
func _icons_drawn(v: CityView) -> Vector2i:
	var power: MultiMeshInstance3D = v.get("_power_icons")
	var water: MultiMeshInstance3D = v.get("_water_icons")
	if power == null or water == null:
		return Vector2i(-1, -1)
	return Vector2i(power.multimesh.visible_instance_count, water.multimesh.visible_instance_count)


## The icons draw what the sim asks for, at this very moment (the callers do not wait for a frame or
## for the 0.6 s status timer). Headless cannot read the per-instance transforms back, so the
## counts are the pin: a layer built but never filled shows 0, one never counted shows -1.
func _check_icons(v: CityView, s: CitySim, what: String) -> void:
	var want := _icon_want(s)
	var drawn := _icons_drawn(v)
	K.check(fails, drawn == want, "%s: icons drawn %s, the sim wants %s" % [what, drawn, want])


## Grows the sim, then pins a mix of status icons on it that tells a swapped pair or a stuck count
## from the right one: 3 tiles that need power and have none, 5 powered zones without water.
func _icon_fixture() -> void:
	K.grow(sim, made["people"], 40)
	sim.set_speed(0)
	var dark := 0
	var dry := 0
	for i in sim.active:
		if not _needs_status(sim, i):
			continue
		if dark < 3:
			sim.powered[i] = 0
			dark += 1
		elif dry < 5 and D.is_zone(sim.kind[i]):
			sim.powered[i] = 1
			sim.watered[i] = 0
			dry += 1
	var want := _icon_want(sim)
	var says := "fixture: the city asks for %s red and blue icons (at least 3 and 5, never equal)"
	K.check(fails, want.x >= 3 and want.y >= 5 and want.x != want.y, says % want)


## The sim moves on while nobody looks: one tile gets its power back and one its water.
func _icon_mend(s: CitySim) -> void:
	var healed := false
	var wet := false
	for i in s.active:
		if not _needs_status(s, i):
			continue
		if not healed and s.powered[i] == 0:
			s.powered[i] = 1
			s.watered[i] = 1
			healed = true
		elif not wet and s.powered[i] == 1 and s.watered[i] == 0 and D.is_zone(s.kind[i]):
			s.watered[i] = 1
			wet = true
	K.check(fails, healed and wet, "fixture: a dark tile and a dry tile were mended")


# ------------------------------------------------------------------ the view


func _view_boot() -> void:
	made = K.make_sim(get_root(), 7, false)
	sim = made["sim"]
	sim.start()
	sim.set_speed(0)
	_icon_fixture()
	cam = Camera3D.new()
	cam.name = "DeadworkCam"
	get_root().add_child(cam)
	view = (load("res://scripts/world/city_view.gd") as GDScript).new()
	view.name = "DeadworkView"
	get_root().add_child(view)
	# The boot order of main.gd: the flag first, then the first setup().
	view.fp_mode = true
	view.setup(sim, cam)
	await process_frame
	await process_frame
	_bare(view, "first-person boot")
	view.set_overlay("power")
	K.check(fails, view.overlay_mode == "none", "a data view asked for on foot is refused")
	view.set_overlay("none")
	view._process(0.1)
	view._refresh_status()
	_bare(view, "first-person boot after a data view, a refresh and a frame")


## Orbit builds the icons when it is entered, and only them.
func _view_orbit() -> void:
	view.set_fp_mode(false)
	var icons := _layers(view, false)
	K.check(
		fails, icons.size() == 2, "entering orbit builds the two icon layers (%d)" % icons.size()
	)
	K.check(fails, _layers(view, true).is_empty(), "entering orbit builds no columns")
	_check_icons(view, sim, "entering orbit")
	K.check(
		fails,
		icons.all(func(m: MultiMeshInstance3D) -> bool: return m.visible),
		"orbit shows the icons"
	)
	var power: MultiMeshInstance3D = view.get("_power_icons")
	var water: MultiMeshInstance3D = view.get("_water_icons")
	var red := _icon_colour(power).is_equal_approx(Color(1.0, 0.25, 0.2))
	var blue := _icon_colour(water).is_equal_approx(Color(0.25, 0.6, 1.0))
	K.check(fails, red and blue, "the power icons are red and the water icons blue, as before")
	icon_ids = _ids(icons)


## The icons breathe in orbit, and on foot (hidden) they are not rewritten every frame. Both layers:
## the water icons follow the power icons' scale and offset.
func _view_pulse() -> void:
	var power: Node3D = view.get("_power_icons")
	var water: Node3D = view.get("_water_icons")
	view.set("_time", 0.0)
	view._process(0.1)
	var s1 := power.scale
	var w1 := water.scale
	view._process(0.2)
	K.check(fails, not power.scale.is_equal_approx(s1), "orbit: the icons pulse every frame")
	var together := water.scale == power.scale and water.position == power.position
	var moved := power.position != Vector3.ZERO and not water.scale.is_equal_approx(w1)
	K.check(fails, together and moved, "orbit: the water icons breathe with the power icons")
	view.set_fp_mode(true)
	var held := [power.scale, power.position, water.scale, water.position]
	view._process(0.3)
	var untouched: bool = held == [power.scale, power.position, water.scale, water.position]
	K.check(fails, untouched, "on foot the hidden icons are not rewritten")
	K.check(fails, not power.visible and not water.visible, "on foot both icon layers are hidden")
	var before := _icon_want(sim)
	_icon_mend(sim)
	var after := _icon_want(sim)
	K.check(fails, after == before - Vector2i(1, 1), "fixture: the sim now asks for %s" % after)
	K.check(fails, _icons_drawn(view) == before, "on foot the icons keep what they drew")
	view.set_fp_mode(false)
	_check_icons(view, sim, "back in orbit after the sim moved on foot")
	view._process(0.3)
	var again: bool = power.scale != held[0] and water.scale == power.scale
	K.check(
		fails, again and power.visible and water.visible, "back in orbit both layers pulse again"
	)


## The first data view builds the column layer, once; the others reuse it.
func _view_data() -> void:
	K.check(fails, _layers(view, true).is_empty(), "orbit alone builds no columns")
	view.set_overlay("power")
	var cols := _layers(view, true)
	K.check(
		fails, cols.size() == 1, "the first data view builds one column layer (%d)" % cols.size()
	)
	if cols.size() != 1:
		return
	K.check(fails, cols[0].visible and view.overlay_mode == "power", "the data view shows it")
	_check_columns(cols[0])
	col_id = cols[0].get_instance_id()
	var tiles_root: Node3D = view.get("_tiles_root")
	K.check(fails, not tiles_root.visible, "a data view hides the buildings, as before")
	var reused := true
	for mode: String in MODES:
		view.set_overlay(mode)
		reused = reused and _ids(_layers(view, true)) == [col_id]
	K.check(fails, reused, "every data view reuses the one column layer")
	view.set_overlay("none")
	var kept := _layers(view, true)
	K.check(fails, _ids(kept) == [col_id] and not kept[0].visible, "closing it hides the columns")
	K.check(fails, tiles_root.visible, "closing it shows the buildings again")


## The column layer is what the per-tile loop built: a 3D transform and a colour per tile, a flat
## clear column everywhere.
func _check_columns(mmi: MultiMeshInstance3D) -> void:
	var mm := mmi.multimesh
	var box := mm.mesh as BoxMesh
	var shape := mm.transform_format == MultiMesh.TRANSFORM_3D and mm.use_colors
	shape = shape and not mm.use_custom_data and mm.instance_count == TILES
	shape = shape and box != null and box.size.is_equal_approx(Vector3(0.94, 1.0, 0.94))
	shape = shape and mmi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	K.check(
		fails, shape, "the column layer is a 3D, coloured, one-box-per-tile MultiMesh, no shadow"
	)
	# The first buffer a fresh build holds, against the definition the old loop wrote per tile:
	# _column(i, 0.0) for the transform, Color(0, 0, 0, 0).
	var fresh: MultiMeshInstance3D = view.call("_make_overlay_multimesh")
	var flat: PackedFloat32Array = view.call("_flat_columns")
	var held := fresh.multimesh.buffer
	K.check(
		fails, held == flat, "a fresh column layer holds the bulk buffer (%d floats)" % held.size()
	)
	K.check(fails, flat.size() == TILES * 16, "the buffer has a transform and a colour per tile")
	var t0: Transform3D = view._column(0, 0.0)
	var scale_only := Basis.from_scale(Vector3(t0.basis.x.x, t0.basis.y.y, t0.basis.z.z))
	K.check(
		fails,
		t0.basis.is_equal_approx(scale_only),
		"_column() is a pure scale (_flat_columns writes the diagonal and the origin only)"
	)
	_check_layout()
	var bad := 0
	var first := ""
	for i in range(TILES):
		var want := _mm_floats(view._column(i, 0.0))
		want.append_array([0.0, 0.0, 0.0, 0.0])
		for k in range(16):
			if flat[i * 16 + k] != want[k]:
				bad += 1
				first = first if not first.is_empty() else "tile %d float %d" % [i, k]
	var says := "all %d tiles: transform and colour equal _column(i, 0.0) and a clear colour %s"
	K.check(fails, bad == 0, says % [TILES, first])
	fresh.free()


## A transform as MultiMesh.buffer holds it (the layout contact_shadows.gd writes by hand): three
## rows of the 3x4 matrix, each the basis row (x.x, y.x, z.x) and then the origin's component. The
## basis axes are the matrix' columns, so this is not the order of one axis at a time; the two
## agree only for a pure scale, which is all _column() builds.
func _mm_floats(t: Transform3D) -> Array[float]:
	var b := t.basis
	var o := t.origin
	return [b.x.x, b.y.x, b.z.x, o.x, b.x.y, b.y.y, b.z.y, o.y, b.x.z, b.y.z, b.z.z, o.z]


## The oracle itself, on a rotated basis where the row order and the axis order differ: row 0 is
## (cos, 0, sin, 1) and row 2 is (-sin, 0, cos, 3) for a turn of 0.5 about up.
func _check_layout() -> void:
	var f := _mm_floats(Transform3D(Basis(Vector3.UP, 0.5), Vector3(1, 2, 3)))
	var c := cos(0.5)
	var s := sin(0.5)
	var row0 := is_equal_approx(f[0], c) and is_equal_approx(f[2], s) and f[3] == 1.0
	var row2 := is_equal_approx(f[8], -s) and is_equal_approx(f[10], c) and f[11] == 3.0
	K.check(fails, row0 and row2 and f[7] == 2.0, "the oracle packs a transform row by row")


## Load or New City in orbit with a data view up: setup() drops the old layers and builds no
## columns, and the HUD's set again builds one.
func _view_setup_again() -> void:
	view.set_overlay("traffic")
	var old_cols: Object = view.get("_overlay_mm")
	var old_icon: Object = view.get("_power_icons")
	view.setup(sim, cam)
	K.check(fails, view.get("_overlay_mm") == null, "setup() with a data view up builds no columns")
	K.check(fails, _layers(view, true).is_empty(), "...and leaves no column layer standing")
	K.check(fails, view.overlay_mode == "traffic", "setup() leaves the mode to the HUD")
	var icons := _layers(view, false)
	K.check(
		fails, icons.size() == 2, "setup() in orbit has the icons ready (cinematic.gd reads them)"
	)
	_check_icons(view, sim, "setup() in orbit")
	view._refresh_status()
	await process_frame
	await process_frame
	var gone := not is_instance_valid(old_cols) and not is_instance_valid(old_icon)
	K.check(fails, gone, "setup() frees the old column and icon layers")
	view.set_overlay("traffic")
	var back := _layers(view, true)
	K.check(fails, back.size() == 1 and back[0].visible, "the HUD's set again builds one layer")
	K.check(fails, _ids(back) != [col_id], "...a new one")
	var fresh := _ids(_layers(view, false))
	K.check(
		fails,
		fresh.size() == 2 and icon_ids.all(func(i: int) -> bool: return not fresh.has(i)),
		"the icon layers are new ones"
	)


## A Load or New City on foot, after an orbit session, leaves nothing of either layer.
func _view_foot_again() -> void:
	view.set_fp_mode(true)
	K.check(fails, view.overlay_mode == "none", "going back on foot closes the data view")
	view.setup(sim, cam)
	await process_frame
	await process_frame
	_bare(view, "a setup() on foot after an orbit session")


func _view_free() -> void:
	view.free()
	cam.free()
	for key: String in ["people", "client", "sim"]:
		(made[key] as Node).free()


# ------------------------------------------------------------------ the occluders


func _occluder_nodes() -> Array[Node]:
	return get_root().find_children("*", "OccluderInstance3D", true, false)


func _check_occluders() -> void:
	var ctx := K.render_street_ctx(get_root(), fails)
	# The desktop path: occluders and the viewport flag, as before.
	var desk := K.make_feature(ctx, "render_opt")
	var desk_occ: RefCounted = desk.get("occluders")
	var desk_nodes := _occluder_nodes().size()
	var desk_chunks: int = (desk.get("hlod") as RefCounted).chunk_nodes.size()
	var on: bool = desk.get("web") == false and desk_nodes > 0 and desk_occ.box_count() > 0
	var says := "desktop: render_opt builds occluders (%d nodes, %d boxes) and the flag"
	K.check(
		fails, on and get_root().use_occlusion_culling, says % [desk_nodes, desk_occ.box_count()]
	)
	K.check(fails, bool(desk.self_test()["ok"]), "desktop: self_test ok")
	_check_web_default(desk)
	desk.teardown()
	ctx.features.erase("render_opt")
	desk.free()
	await process_frame
	await process_frame
	var clean := _occluder_nodes().is_empty() and not get_root().use_occlusion_culling
	K.check(fails, clean, "desktop: teardown removes the occluders and restores the flag")
	await _check_web(ctx, desk_chunks)


## The production default of the switch: web follows the platform. OS.has_feature("web") cannot be
## faked on the desktop, so every other check here forces the member; this one pins its declaration,
## which a literal false (nothing would change in a browser) or Q.web_mode() (the web_quality flag
## would bring the dead work back) would silently break. A browser run of tools/web_fps_probe.js
## with GF_FPS_NO_OCCLUSION=1 is the live check.
func _check_web_default(desk: FpFeature) -> void:
	var src := (load(RENDER_OPT) as GDScript).source_code
	var rx := RegEx.create_from_string("(?m)^var web\\s*:\\s*bool\\s*=\\s*Q\\.is_web\\(\\)\\s*$")
	var says := "render_opt: web is declared as Q.is_web(), not a literal or web_mode"
	K.check(fails, rx.search(src) != null, says)
	K.check(fails, desk.get("web") == Q.is_web(), "desktop: the default is the platform's answer")


## The web path, forced: the same city, no occluders and no flag.
func _check_web(ctx: FpContext, desk_chunks: int) -> void:
	var web: FpFeature = K.make_feature(ctx, "render_opt", {"web": true})
	var occ: RefCounted = web.get("occluders")
	var hlod: RefCounted = web.get("hlod")
	await process_frame
	var none: bool = _occluder_nodes().is_empty() and occ.chunk_nodes.is_empty()
	K.check(fails, none and occ.box_count() == 0, "web: the boot pass builds no OccluderInstance3D")
	K.check(fails, web.get("web") == true and web.get("active") == true, "web: render_opt is up")
	K.check(
		fails, not get_root().use_occlusion_culling, "web: occlusion culling is never turned on"
	)
	var same: bool = hlod.chunk_nodes.size() == desk_chunks and desk_chunks > 0
	K.check(
		fails, same, "web: the impostor chunks are the desktop's (%d)" % hlod.chunk_nodes.size()
	)
	# A growth burst: every chunk dirty, rebuilt one at a time.
	var dirty: Dictionary = web.get("_dirty")
	for c: Vector2i in hlod.chunk_tiles.keys():
		dirty[c] = true
	web.call("flush")
	await process_frame
	var burst: bool = _occluder_nodes().is_empty() and hlod.chunk_nodes.size() == desk_chunks
	K.check(fails, burst, "web: chunk rebuilds build impostors and no occluders")
	# The rebuild a Load runs.
	web.on_world_rebuilt()
	await process_frame
	var again := _occluder_nodes().is_empty() and not get_root().use_occlusion_culling
	K.check(fails, again, "web: a world rebuild builds no occluders either")
	var st: Dictionary = web.self_test()
	K.check(fails, bool(st["ok"]), "web: self_test ok without occluders (%s)" % st["detail"])
	web.teardown()
	ctx.features.erase("render_opt")
	web.free()
	await process_frame


# ------------------------------------------------------------------ the whole game


func _check_main() -> void:
	OS.set_environment("GRIDFALL_VIEW", "fp")
	var main: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	get_root().add_child(main)
	for _i in range(5):
		await process_frame
	var v: CityView = main.view
	K.check(fails, main.fp != null and v.fp_mode, "main boots in first person")
	_bare(v, "main's first-person boot")
	# Load and New City on foot, then Load with the web path forced on the live render_opt.
	K.check(fails, main.save_game(SAVE), "fixture: the city saves")
	main.new_game()
	await process_frame
	_bare(v, "New City on foot")
	K.check(fails, main.load_game(SAVE), "fixture: the save loads")
	await process_frame
	_bare(v, "Load on foot")
	var ro: FpFeature = main.fp.ctx.feature("render_opt")
	ro.set("web", true)
	K.check(fails, main.load_game(SAVE), "fixture: the save loads again")
	await process_frame
	await process_frame
	var boxes: int = (ro.get("occluders") as RefCounted).box_count()
	K.check(
		fails, _occluder_nodes().is_empty() and boxes == 0, "web: Load leaves no OccluderInstance3D"
	)
	await _main_planner(main, v)
	await _main_reload(main, v)
	K.check(fails, main.fp != null and v.fp_mode, "the round trips end on foot")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE))
	main.audio._exit_tree()


## The planner round trip: orbit, a data view from the HUD, back on foot, and again.
func _main_planner(main: Node, v: CityView) -> void:
	# The fresh city's one service has no power; pin it so the count is not 0 by luck.
	var s: CitySim = main.sim
	for i in s.active:
		if _needs_status(s, i):
			s.powered[i] = 0
			break
	K.check(fails, _icon_want(s).x > 0, "fixture: main's city has a tile without power")
	main.exit_fp()
	_check_icons(v, s, "the planner entered from foot")
	for _i in range(3):
		await process_frame
	K.check(fails, not v.fp_mode and main.view_mode == "orbit", "fixture: the planner is up")
	var icons := _layers(v, false)
	var shown := (
		icons.size() == 2 and icons.all(func(m: MultiMeshInstance3D) -> bool: return m.visible)
	)
	K.check(fails, shown, "the planner has its two icon layers, both shown")
	K.check(fails, _layers(v, true).is_empty(), "...and no columns yet")
	main.hud.set_overlay("power")
	var cols := _layers(v, true)
	K.check(
		fails, cols.size() == 1 and cols[0].visible, "a data view from the HUD builds the columns"
	)
	var col := _ids(cols)
	main.enter_fp()
	for _i in range(3):
		await process_frame
	var closed := (
		v.fp_mode and v.overlay_mode == "none" and (v.get("_tiles_root") as Node3D).visible
	)
	K.check(fails, closed, "back on foot the data view is closed and the buildings are shown")
	var held := _layers(v, true)
	var held_icons := _layers(v, false)
	K.check(
		fails, _ids(held) == col and not held[0].visible, "on foot the columns are kept, hidden"
	)
	var hid := (
		held_icons.size() == 2
		and not held_icons.any(func(m: MultiMeshInstance3D) -> bool: return m.visible)
	)
	K.check(fails, hid, "...and so are the icons, both of them")
	main.exit_fp()
	_check_icons(v, main.sim, "the second visit")
	for _i in range(3):
		await process_frame
	var again := _layers(v, false)
	var back := again.all(func(m: MultiMeshInstance3D) -> bool: return m.visible)
	K.check(fails, _ids(again) == _ids(icons) and back, "the second visit reuses the icons, shown")
	main.hud.set_overlay("power")
	var cols2 := _layers(v, true)
	K.check(
		fails, _ids(cols2) == col and cols2[0].visible, "the second data view reuses the columns"
	)
	col_id = col[0]


## Load and New City in the planner with a data view up: the HUD sets its mode again.
func _main_reload(main: Node, v: CityView) -> void:
	K.check(fails, main.load_game(SAVE), "fixture: the save loads in the planner")
	_check_icons(v, main.sim, "Load in the planner")
	for _i in range(3):
		await process_frame
	var loaded := _layers(v, true)
	var shown := v.overlay_mode == "power" and loaded.size() == 1 and loaded[0].visible
	K.check(fails, shown and _ids(loaded) != [col_id], "Load in the planner: one new column layer")
	K.check(
		fails,
		_layers(v, false).size() == 2 and v.get("_power_icons") != null,
		"...and the icons ready"
	)
	main.new_game()
	_check_icons(v, main.sim, "New City in the planner")
	for _i in range(3):
		await process_frame
	var started := _layers(v, true)
	var up := v.overlay_mode == "power" and started.size() == 1 and started[0].visible
	K.check(fails, up, "New City in the planner: one new column layer")
	K.check(fails, _layers(v, false).size() == 2, "...and the icons ready")
	main.hud.set_overlay("none")
	main.enter_fp()
	for _i in range(3):
		await process_frame
