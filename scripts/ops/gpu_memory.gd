class_name GpuMemory
extends RefCounted
## Low-GPU-memory mode. decide() reads the graphics card once per process (the RenderingServer's
## adapter name, vendor and type, then its memory from nvidia-smi on NVIDIA or from the amdgpu
## sysfs files on Linux) and turns the mode on for an integrated or software GPU, a card with 4 GB
## or less, or one with less than LOW_FREE_MIB free (another program, such as a local LLM server,
## holding the rest). apply_to() then shrinks what the renderer allocates before the city is
## built, and FpMode defaults the quality preset to Low. GRIDFALL_LOW_VRAM=1 or 0 forces the mode
## on or off; with the "low_vram_auto" flag off only that switch turns it on.

## A "4 GB" card reports 4096 MiB (some a little less); the next common size is 6 GB.
const LOW_TOTAL_MIB := 4608
const LOW_FREE_MIB := 1536
const SUN_ATLAS := 4096
const LAMP_ATLAS := 2048
## Project values set for this process, so first person's render_opt restores to them on exit.
const SETTINGS := {
	"rendering/lights_and_shadows/directional_shadow/size": SUN_ATLAS,
	"rendering/lights_and_shadows/directional_shadow/soft_shadow_filter_quality":
	RenderingServer.SHADOW_QUALITY_SOFT_VERY_LOW,
	"rendering/environment/ssao/quality": RenderingServer.ENV_SSAO_QUALITY_LOW,
	"rendering/anti_aliasing/quality/msaa_3d": Viewport.MSAA_DISABLED,
}
const TRUE_WORDS := ["1", "true", "on", "yes"]
const FALSE_WORDS := ["0", "false", "off", "no"]

## decide()'s cached answer: probe() plus "low" and "reason" ({} until the first call).
static var _info: Dictionary = {}


## The card: {"adapter", "vendor", "type" (RenderingDevice.DeviceType), "total_mib", "free_mib",
## "source"}; memory is -1 when unknown (headless, or no tool reports it).
static func probe() -> Dictionary:
	var info := {
		"adapter": RenderingServer.get_video_adapter_name(),
		"vendor": RenderingServer.get_video_adapter_vendor(),
		"type": int(RenderingServer.get_video_adapter_type()),
		"total_mib": -1,
		"free_mib": -1,
		"source": "",
	}
	if DisplayServer.get_name() == "headless":
		return info
	if "nvidia" in (str(info["vendor"]) + " " + str(info["adapter"])).to_lower():
		_read_nvidia(info)
	elif OS.get_name() == "Linux":
		_read_sysfs(info)
	return info


## Why the mode is on for this card, or "" when it is off. env is GRIDFALL_LOW_VRAM; auto is the
## "low_vram_auto" flag; web is the browser build, which always starts lean (WebGL 2 on whatever
## laptop opens the page, and it cannot read the card's memory), so it starts on Low too.
static func reason(info: Dictionary, env: String, auto: bool, web: bool = false) -> String:
	var e := env.strip_edges().to_lower()
	if e in TRUE_WORDS:
		return "GRIDFALL_LOW_VRAM=1"
	if e in FALSE_WORDS:
		return ""
	if web:
		return "web browser"
	if not auto:
		return ""
	var t := int(info.get("type", -1))
	var total := int(info.get("total_mib", -1))
	var free := int(info.get("free_mib", -1))
	var why := ""
	if t == RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU:
		why = "integrated GPU"
	elif t == RenderingDevice.DEVICE_TYPE_CPU:
		why = "software renderer"
	elif total > 0 and total <= LOW_TOTAL_MIB:
		why = "%d MiB of GPU memory" % total
	elif free >= 0 and free < LOW_FREE_MIB:
		why = "%d MiB of GPU memory free" % free
	return why


## probe() with "low" and "reason", decided on the first call and cached for the process.
static func decide() -> Dictionary:
	if _info.is_empty():
		var info := probe()
		info["reason"] = reason(
			info,
			OS.get_environment("GRIDFALL_LOW_VRAM"),
			FeatureFlags.enabled("low_vram_auto"),
			OS.has_feature("web")
		)
		info["low"] = not str(info["reason"]).is_empty()
		_info = info
	return _info


## Whether the low-GPU-memory mode is on.
static func low() -> bool:
	return bool(decide()["low"])


## Sets the decision for this process (tests); clear() forgets it.
static func set_override(on: bool, why: String = "test") -> void:
	_info = {"low": on, "reason": why if on else "", "total_mib": -1, "free_mib": -1}


static func clear() -> void:
	_info = {}


## Shrinks what the renderer allocates: the sun's shadow atlas 8192 -> 4096 and its filter, SSAO
## quality, MSAA off (FXAA instead) and the lamp shadow atlas of vp. Also sets SETTINGS as project
## values for this process (never saved).
static func apply_to(vp: Viewport) -> void:
	for key: String in SETTINGS:
		ProjectSettings.set_setting(key, SETTINGS[key])
	RenderingServer.directional_shadow_atlas_set_size(SUN_ATLAS, true)
	RenderingServer.directional_soft_shadow_filter_set_quality(
		RenderingServer.SHADOW_QUALITY_SOFT_VERY_LOW
	)
	var ps := "rendering/environment/ssao/"
	RenderingServer.environment_set_ssao_quality(
		RenderingServer.ENV_SSAO_QUALITY_LOW,
		true,
		float(ProjectSettings.get_setting(ps + "adaptive_target", 0.5)),
		int(ProjectSettings.get_setting(ps + "blur_passes", 2)),
		float(ProjectSettings.get_setting(ps + "fadeout_from", 50.0)),
		float(ProjectSettings.get_setting(ps + "fadeout_to", 300.0))
	)
	if vp != null:
		vp.msaa_3d = Viewport.MSAA_DISABLED
		# Compatibility (the web build) has no screen-space AA at all; asking for FXAA only warns.
		if not compat(RenderingServer.get_current_rendering_method()):
			vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
		vp.positional_shadow_atlas_size = mini(vp.positional_shadow_atlas_size, LAMP_ATLAS)


## True for the Compatibility renderer's method name (gl_compatibility).
static func compat(method: String) -> bool:
	return method == "gl_compatibility"


## One line for the log: the card, its memory and the decision.
static func describe(info: Dictionary) -> String:
	var mem := "memory unknown"
	if int(info.get("total_mib", -1)) > 0:
		mem = "%d MiB, %d MiB free" % [int(info["total_mib"]), int(info.get("free_mib", -1))]
	var mode := (
		"low GPU memory mode (%s)" % info["reason"]
		if bool(info.get("low", false))
		else "full GPU memory"
	)
	return "GridFall GPU: %s, %s: %s" % [str(info.get("adapter", "?")), mem, mode]


## Rows of `nvidia-smi --query-gpu=name,memory.total,memory.free --format=csv,noheader,nounits`:
## [{"name", "total_mib", "free_mib"}]; malformed lines are skipped.
static func parse_nvidia(text: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for line: String in text.split("\n", false):
		var parts := line.split(",")
		if (
			parts.size() < 3
			or not parts[-2].strip_edges().is_valid_int()
			or not parts[-1].strip_edges().is_valid_int()
		):
			continue
		var gpu := ",".join(parts.slice(0, parts.size() - 2)).strip_edges()
		out.append(
			{
				"name": gpu,
				"total_mib": parts[-2].strip_edges().to_int(),
				"free_mib": parts[-1].strip_edges().to_int()
			}
		)
	return out


## The row whose name the adapter carries (several cards), else the first; {} when there is none.
static func pick_row(rows: Array[Dictionary], adapter: String) -> Dictionary:
	for r: Dictionary in rows:
		if not str(r["name"]).is_empty() and str(r["name"]).to_lower() in adapter.to_lower():
			return r
	return rows[0] if not rows.is_empty() else {}


static func _read_nvidia(info: Dictionary) -> void:
	var out: Array = []
	var args := ["--query-gpu=name,memory.total,memory.free", "--format=csv,noheader,nounits"]
	if OS.execute("nvidia-smi", args, out) != 0 or out.is_empty():
		return
	var row := pick_row(parse_nvidia(str(out[0])), str(info["adapter"]))
	if not row.is_empty():
		info["total_mib"] = row["total_mib"]
		info["free_mib"] = row["free_mib"]
		info["source"] = "nvidia-smi"


## amdgpu exposes mem_info_vram_total and mem_info_vram_used (bytes) per card; the biggest wins.
static func _read_sysfs(info: Dictionary) -> void:
	var root := "/sys/class/drm"
	if not DirAccess.dir_exists_absolute(root):
		return
	for card: String in DirAccess.get_directories_at(root):
		if not card.begins_with("card") or not card.substr(4).is_valid_int():
			continue
		var total := _sysfs_int("%s/%s/device/mem_info_vram_total" % [root, card])
		var used := _sysfs_int("%s/%s/device/mem_info_vram_used" % [root, card])
		if total > 0 and total >> 20 > int(info["total_mib"]):
			info["total_mib"] = total >> 20
			info["free_mib"] = (total - used) >> 20 if used >= 0 else -1
			info["source"] = "sysfs"


static func _sysfs_int(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return -1
	var s := f.get_line().strip_edges()
	return s.to_int() if s.is_valid_int() else -1
