extends FpFeature
## Time-sliced sim ticks for first person (slice F). Turns CitySim.sliced on, so growth ticks and
## day boundaries run a few milliseconds per frame instead of freezing the street for 0.3-1 s,
## with the per-frame budget taken from the quality preset.

## Sliced sim work per frame (ms) by quality preset.
const BUDGET_MS := {"low": 3.0, "medium": 4.0, "high": 5.0}
## D11: no frame may stall longer than this because of the sim, residents or minds.
const STALL_LIMIT_MS := 50.0

var _sim: CitySim


func feature_id() -> String:
	return "sim_perf"


func setup(p_ctx: FpContext) -> void:
	super.setup(p_ctx)
	_sim = ctx.sim
	if _sim == null:
		return
	_apply_quality(str(ctx.settings.get("quality", "medium")))
	_sim.sliced = true
	if ctx.bus != null and not ctx.bus.quality_changed.is_connected(_apply_quality):
		ctx.bus.quality_changed.connect(_apply_quality)


func teardown() -> void:
	if ctx != null and ctx.bus != null and ctx.bus.quality_changed.is_connected(_apply_quality):
		ctx.bus.quality_changed.disconnect(_apply_quality)
	if _sim != null and is_instance_valid(_sim):
		# The setter finishes a tick in flight, so the orbit view never inherits half a tick.
		_sim.sliced = false


## The sim's per-pump timings (CitySim.slice_stats()), for G2's bench and the HUD.
func slice_stats() -> Dictionary:
	if _sim == null or not is_instance_valid(_sim):
		return {}
	return _sim.slice_stats()


func self_test() -> Dictionary:
	if _sim == null or not is_instance_valid(_sim):
		return {"ok": false, "detail": "no sim"}
	var st := _sim.slice_stats()
	var ok := _sim.sliced and float(st["max_ms"]) < STALL_LIMIT_MS
	var detail := "sliced=%s budget=%.1fms pumps=%d ticks=%d max=%.2fms p95=%.2fms units<=%d/%d sync_max=%.1fms (%d forced) (brain %.1fms, view %.1fms excluded)" % [
		str(_sim.sliced).to_lower(), _sim.slice_budget_ms, int(st["pumps"]), int(st["ticks"]), float(st["max_ms"]),
		float(st["p95_ms"]), int(st["max_units"]), int(st["units_limit"]), float(st["sync_max_ms"]),
		int(st["sync_finishes"]), float(st["brain_ms"]), float(st["view_ms"]),
	]
	return {"ok": ok, "detail": detail}


func _apply_quality(preset: String) -> void:
	if _sim != null and is_instance_valid(_sim):
		_sim.slice_budget_ms = float(BUDGET_MS.get(preset, 4.0))
