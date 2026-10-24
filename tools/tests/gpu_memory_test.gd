extends SceneTree
## Low-GPU-memory mode (scripts/ops/gpu_memory.gd): the decision table, nvidia-smi parsing, the
## renderer knobs apply_to() lowers, render_opt restoring to them, and FpMode starting a card short
## of memory on the Low preset.

const K := preload("res://tools/tests/fp_kit.gd")
const RO := preload("res://scripts/fp/render/render_opt_feature.gd")
const INTEGRATED := RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU
const DISCRETE := RenderingDevice.DEVICE_TYPE_DISCRETE_GPU

var fails: Array[String] = []


func _init() -> void:
	await process_frame
	_check_reason()
	_check_nvidia_parse()
	_check_decide()
	_check_apply()
	_check_fp_default()
	GpuMemory.clear()
	K.finish(self, "GPU_MEMORY_TEST", fails)


func _card(type: int, total: int, free: int) -> Dictionary:
	return {"adapter": "Test GPU", "type": type, "total_mib": total, "free_mib": free}


func _check_reason() -> void:
	var r := func(info: Dictionary, env: String = "", auto: bool = true) -> String:
		return GpuMemory.reason(info, env, auto)
	K.check(
		fails, r.call(_card(DISCRETE, 4096, 3000)) == "4096 MiB of GPU memory", "a 4 GB card is low"
	)
	K.check(
		fails,
		r.call(_card(DISCRETE, 3962, 3000)) != "",
		"a card reporting a little under 4 GB is low"
	)
	K.check(fails, r.call(_card(DISCRETE, 8192, 6000)) == "", "an 8 GB card with room is not low")
	K.check(fails, r.call(_card(DISCRETE, 6144, 5000)) == "", "a 6 GB card with room is not low")
	K.check(
		fails,
		r.call(_card(DISCRETE, 8192, 700)) == "700 MiB of GPU memory free",
		"an 8 GB card another program fills is low"
	)
	K.check(
		fails, r.call(_card(INTEGRATED, -1, -1)) == "integrated GPU", "an integrated GPU is low"
	)
	K.check(
		fails,
		r.call(_card(RenderingDevice.DEVICE_TYPE_CPU, -1, -1)) == "software renderer",
		"a software renderer is low"
	)
	K.check(
		fails, r.call(_card(DISCRETE, -1, -1)) == "", "a discrete card of unknown memory is not low"
	)
	K.check(
		fails,
		r.call(_card(DISCRETE, 8192, 6000), "1") == "GRIDFALL_LOW_VRAM=1",
		"GRIDFALL_LOW_VRAM=1 forces the mode on"
	)
	K.check(
		fails,
		r.call(_card(DISCRETE, 4096, 300), "off") == "",
		"GRIDFALL_LOW_VRAM=off forces it off"
	)
	K.check(
		fails,
		r.call(_card(DISCRETE, 4096, 300), "", false) == "",
		"the low_vram_auto flag off leaves the card alone"
	)
	K.check(
		fails,
		r.call(_card(DISCRETE, 8192, 6000), "yes", false) == "GRIDFALL_LOW_VRAM=1",
		"the switch works with the flag off"
	)


func _check_nvidia_parse() -> void:
	var out := "NVIDIA GeForce RTX 3050 Laptop GPU, 4096, 3067\n"
	out += "NVIDIA RTX A6000, 49140, 48000\nbad line\n"
	var rows := GpuMemory.parse_nvidia(out)
	K.check(
		fails, rows.size() == 2, "nvidia-smi: two rows, the bad line skipped (%d)" % rows.size()
	)
	if rows.size() < 2:
		return
	K.check(
		fails,
		(
			rows[0]["name"] == "NVIDIA GeForce RTX 3050 Laptop GPU"
			and rows[0]["total_mib"] == 4096
			and rows[0]["free_mib"] == 3067
		),
		"nvidia-smi: name, total and free read"
	)
	K.check(
		fails,
		GpuMemory.pick_row(rows, "NVIDIA RTX A6000")["total_mib"] == 49140,
		"the row of the adapter Godot renders on is picked"
	)
	K.check(
		fails,
		GpuMemory.pick_row(rows, "Unknown")["total_mib"] == 4096,
		"an unmatched adapter falls back to the first row"
	)
	K.check(fails, GpuMemory.pick_row([] as Array[Dictionary], "x").is_empty(), "no rows, no card")
	K.check(
		fails,
		GpuMemory.parse_nvidia("Card, with comma, 2048, 100")[0]["name"] == "Card, with comma",
		"a name with a comma survives"
	)


func _check_decide() -> void:
	GpuMemory.clear()
	var info := GpuMemory.decide()
	var forced := OS.get_environment("GRIDFALL_LOW_VRAM") in GpuMemory.TRUE_WORDS
	K.check(
		fails,
		info.has("low") and info.has("reason") and info.has("adapter"),
		"decide() reports the card and the decision"
	)
	K.check(
		fails,
		bool(info["low"]) == forced,
		"headless with no switch stays at full memory (low=%s)" % info["low"]
	)
	K.check(fails, GpuMemory.decide() == info, "the decision is cached")
	GpuMemory.set_override(true)
	K.check(
		fails,
		(
			GpuMemory.low()
			and GpuMemory.describe(GpuMemory.decide()).contains("low GPU memory mode (test)")
		),
		"set_override turns it on and describe says so"
	)
	GpuMemory.set_override(false)
	K.check(
		fails,
		not GpuMemory.low() and GpuMemory.describe(GpuMemory.decide()).contains("full GPU memory"),
		"and off"
	)


func _check_apply() -> void:
	var vp := get_root()
	var saved := {}
	for key: String in GpuMemory.SETTINGS:
		saved[key] = ProjectSettings.get_setting(key)
	var vp_saved := [vp.msaa_3d, vp.screen_space_aa, vp.positional_shadow_atlas_size]
	vp.msaa_3d = Viewport.MSAA_2X
	vp.positional_shadow_atlas_size = 4096
	GpuMemory.apply_to(vp)
	K.check(
		fails,
		(
			vp.msaa_3d == Viewport.MSAA_DISABLED
			and vp.screen_space_aa == Viewport.SCREEN_SPACE_AA_FXAA
		),
		"MSAA off, FXAA on"
	)
	K.check(
		fails,
		vp.positional_shadow_atlas_size == GpuMemory.LAMP_ATLAS,
		"lamp shadow atlas 4096 -> 2048"
	)
	K.check(
		fails,
		int(ProjectSettings.get_setting(RO.RS_SETTINGS["atlas"])) == GpuMemory.SUN_ATLAS,
		"sun shadow atlas 4096 as the project value"
	)
	K.check(
		fails,
		(
			int(ProjectSettings.get_setting(RO.RS_SETTINGS["ssao"]))
			== RenderingServer.ENV_SSAO_QUALITY_LOW
		),
		"SSAO low as the project value"
	)
	for key: String in GpuMemory.SETTINGS:
		if key.contains("shadow") or key.contains("ssao"):
			K.check(
				fails,
				key in RO.RS_SETTINGS.values(),
				"render_opt snapshots %s, so it restores the low value" % key
			)
	for key: String in saved:
		ProjectSettings.set_setting(key, saved[key])
	vp.msaa_3d = vp_saved[0]
	vp.screen_space_aa = vp_saved[1]
	vp.positional_shadow_atlas_size = vp_saved[2]


func _check_fp_default() -> void:
	var has_saved := false
	if FileAccess.file_exists(FpMode.SETTINGS_PATH):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(FpMode.SETTINGS_PATH))
		has_saved = typeof(parsed) == TYPE_DICTIONARY and (parsed as Dictionary).has("quality")
	GpuMemory.set_override(true)
	var m := FpMode.new()
	var s: Dictionary = m.call("_load_settings")
	if has_saved:
		K.check(fails, not m.auto_low_quality, "a saved quality wins over the low mode")
	else:
		K.check(
			fails,
			m.auto_low_quality and s["quality"] == "low",
			"a low card starts first person on Low (%s)" % s["quality"]
		)
	GpuMemory.set_override(false)
	var s2: Dictionary = m.call("_load_settings")
	K.check(
		fails,
		(
			not m.auto_low_quality
			and (has_saved or s2["quality"] == FpMode.DEFAULT_SETTINGS["quality"])
		),
		"a full card keeps the default preset"
	)
	m.free()
