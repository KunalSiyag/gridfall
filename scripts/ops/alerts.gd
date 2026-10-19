class_name OpsAlerts
extends Node
## Local alerting. Every interval_s it evaluates res://data/alert_rules.json against live inputs:
## frame time p95, the GMI circuit breaker, the GMI live failure ratio, errors per minute (from
## ErrorTracker's in-memory counters) and sim tick stalls. A rule that fires (at most once per its
## cooldown_s) prints "OPS_ALERT {json}", is appended to user://ops/alerts.jsonl when error
## tracking or analytics records to disk, and becomes a player toast only when the "ops_alerts"
## flag is on and GRIDFALL_OPS_ALERTS_UI=1. The "ops_alerts" flag off disables evaluation.
## Also installs ErrorTracker and keeps its game context current.

signal alert_fired(alert: Dictionary)

const RULES_PATH := "res://data/alert_rules.json"
const FILE := "alerts.jsonl"
const FRAME_SAMPLES := 240
const MAX_FIRED := 50

## The Main node (main.gd); sim, client and view_mode are read from it. May be null.
var main: Node = null
var rules: Array = []
var interval_s: float = 5.0
var warmup_s: float = 20.0
## The most recent fired alerts (newest last).
var fired: Array[Dictionary] = []
var _frame_ms: PackedFloat32Array = PackedFloat32Array()
var _frame_i: int = 0
var _since: float = 0.0
var _age: float = 0.0
var _last_fired: Dictionary = {}
var _progress: int = -1
var _progress_ms: int = 0
var _ui: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	ErrorTracker.install()
	var cfg := load_rules(RULES_PATH)
	rules = cfg.get("rules", [])
	interval_s = float(cfg.get("interval_s", interval_s))
	warmup_s = float(cfg.get("warmup_s", warmup_s))
	var on := FeatureFlags.enabled("ops_alerts")
	_ui = on and OS.get_environment("GRIDFALL_OPS_ALERTS_UI") == "1"
	set_process(on)


func _exit_tree() -> void:
	ErrorTracker.uninstall()


func _process(delta: float) -> void:
	if _frame_ms.size() < FRAME_SAMPLES:
		_frame_ms.append(delta * 1000.0)
	else:
		_frame_ms[_frame_i] = delta * 1000.0
		_frame_i = (_frame_i + 1) % FRAME_SAMPLES
	_age += delta
	_since += delta
	if _since >= interval_s:
		_since = 0.0
		tick()


## One evaluation round: refreshes the error context, gathers inputs, fires due rules.
func tick(now_ms: int = -1) -> Array[Dictionary]:
	var now := now_ms if now_ms >= 0 else Time.get_ticks_msec()
	var inputs := gather_inputs(now)
	var out: Array[Dictionary] = []
	for hit: Dictionary in evaluate(rules, inputs):
		var rule := _rule(str(hit["id"]))
		if not due(rule, _last_fired, now):
			continue
		_last_fired[str(hit["id"])] = now
		out.append(fire(hit))
	return out


## Live inputs for evaluate().
func gather_inputs(now_ms: int) -> Dictionary:
	var sim: CitySim = main.get("sim") if main != null else null
	var client: GmiClient = main.get("client") if main != null else null
	var ctx := {"view_mode": str(main.get("view_mode")) if main != null else ""}
	var stall := 0.0
	if sim != null and is_instance_valid(sim):
		ctx["day"] = sim.day
		ctx["tick"] = sim.tick_in_day
		ctx["speed"] = sim.speed
		var marker := sim.day * 1000 + sim.tick_in_day
		var paused := is_inside_tree() and get_tree().paused
		if marker != _progress or sim.speed <= 0 or paused:
			_progress = marker
			_progress_ms = now_ms
		else:
			var expected_s := maxf(1.0, sim.tick_seconds() / float(sim.speed))
			stall = float(now_ms - _progress_ms) / 1000.0 / expected_s
	var inputs := {
		"frame_ms": Array(_frame_ms) if _age >= warmup_s else [],
		"errors_last_minute": ErrorTracker.errors_in_last(60000, now_ms),
		"sim_stall_ratio": stall,
		"breaker_state": "",
		"live_outcomes": [],
	}
	if client != null and is_instance_valid(client):
		inputs["breaker_state"] = client.breaker_state()
		inputs["live_outcomes"] = client.live_outcomes.duplicate()
		ctx["gmi_breaker"] = inputs["breaker_state"]
		ctx["gmi_live"] = client.live_enabled
	ErrorTracker.set_context(ctx)
	return inputs


## Prints, records and (debug only) toasts one alert. Returns the alert record.
func fire(hit: Dictionary) -> Dictionary:
	var rec := hit.duplicate()
	rec["ts"] = Time.get_unix_time_from_system()
	rec["session"] = Trace.session_id()
	print("OPS_ALERT " + Redact.scrub(JSON.stringify(rec)))
	if ErrorTracker.recording() or Analytics.enabled():
		OpsSink.append(FILE, rec)
	ErrorTracker.breadcrumb("alert " + str(rec.get("id", "")))
	fired.append(rec)
	while fired.size() > MAX_FIRED:
		fired.pop_front()
	alert_fired.emit(rec)
	if _ui and main != null and main.has_method("notify"):
		main.call("notify", "Ops alert: " + str(rec.get("message", rec.get("id", ""))), "alert")
	return rec


func _rule(id: String) -> Dictionary:
	for r: Variant in rules:
		if typeof(r) == TYPE_DICTIONARY and str((r as Dictionary).get("id", "")) == id:
			return r
	return {}


## {"interval_s", "warmup_s", "rules": [...]} from path ({} when missing or invalid).
static func load_rules(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


## Pure rule evaluation. inputs: {"frame_ms": Array[float], "breaker_state": String,
## "live_outcomes": Array[bool], "errors_last_minute": int, "sim_stall_ratio": float}. Returns one
## {"id", "kind", "severity", "value", "threshold", "message"} per rule whose condition holds
## (cooldowns are the caller's, see due()).
static func evaluate(rule_list: Array, inputs: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for rv: Variant in rule_list:
		if typeof(rv) != TYPE_DICTIONARY:
			continue
		var r: Dictionary = rv
		if not bool(r.get("enabled", true)):
			continue
		var kind := str(r.get("kind", ""))
		var th := float(r.get("threshold", 0.0))
		var value := 0.0
		var hit := false
		match kind:
			"frame_time_p95_ms":
				var frames: Array = inputs.get("frame_ms", [])
				if frames.size() >= int(r.get("min_samples", 60)):
					value = percentile(frames, 0.95)
					hit = value > th
			"gmi_breaker_open":
				hit = str(inputs.get("breaker_state", "")) == CircuitBreaker.OPEN
				value = 1.0 if hit else 0.0
			"gmi_live_failure_ratio":
				var outcomes: Array = inputs.get("live_outcomes", [])
				var window: Array = outcomes.slice(maxi(0, outcomes.size() - int(r.get("window", 20))))
				if window.size() >= int(r.get("min_calls", 5)):
					var bad := 0
					for o: Variant in window:
						if not bool(o):
							bad += 1
					value = float(bad) / float(window.size())
					hit = value > th
			"errors_per_minute":
				value = float(inputs.get("errors_last_minute", 0))
				hit = value >= th
			"sim_tick_stall":
				value = float(inputs.get("sim_stall_ratio", 0.0))
				hit = value >= th
			_:
				continue
		if hit:
			var msg := str(r.get("message", kind))
			out.append({"id": str(r.get("id", kind)), "kind": kind, "severity": str(r.get("severity", "warning")),
				"value": snappedf(value, 0.01), "threshold": th, "message": msg.replace("{value}", str(snappedf(value, 0.01))).replace("{threshold}", str(th))})
	return out


## True when rule may fire at now_ms given {id: last fired ms}.
static func due(rule: Dictionary, last_fired: Dictionary, now_ms: int) -> bool:
	var id := str(rule.get("id", ""))
	if not last_fired.has(id):
		return true
	return now_ms - int(last_fired[id]) >= int(float(rule.get("cooldown_s", 300.0)) * 1000.0)


## The q-quantile (0..1, nearest rank) of values.
static func percentile(values: Array, q: float) -> float:
	if values.is_empty():
		return 0.0
	var v := values.duplicate()
	v.sort()
	var k := clampi(ceili(q * v.size()) - 1, 0, v.size() - 1)
	return float(v[k])
