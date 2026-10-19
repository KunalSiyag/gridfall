class_name Analytics
extends RefCounted
## Local, opt-in product analytics: track(event, props) appends {event, props, session, seq, ts,
## build} to user://ops/analytics.jsonl (scrubbed, rotated). On only with GRIDFALL_ANALYTICS=1 or
## the "analytics" flag; otherwise track() costs one breadcrumb check and one bool test. Nothing
## leaves the machine; tools/ops/analytics_report.py summarises the file. Props must not carry
## player text (send lengths, ids and counts instead).

const FILE := "analytics.jsonl"

## -1 until first use, then 0 / 1.
static var _on: int = -1
static var _seq: int = 0
static var _started_ms: int = Time.get_ticks_msec()


## GRIDFALL_ANALYTICS=1 or the "analytics" flag (resolved once; configure() overrides).
static func enabled() -> bool:
	if _on < 0:
		_on = 1 if (OS.get_environment("GRIDFALL_ANALYTICS") == "1" or FeatureFlags.enabled("analytics", false)) else 0
	return _on == 1


## Forces analytics on or off for this process (tests).
static func configure(on: bool) -> void:
	_on = 1 if on else 0


## Records one product event. Also leaves an error-tracker breadcrumb.
static func track(event: String, props: Dictionary = {}) -> void:
	ErrorTracker.breadcrumb(event)
	if not enabled():
		return
	_seq += 1
	OpsSink.append(FILE, {
		"event": event,
		"props": props,
		"session": Trace.session_id(),
		"seq": _seq,
		"ts": Time.get_unix_time_from_system(),
		"uptime_s": snappedf(float(Time.get_ticks_msec() - _started_ms) / 1000.0, 0.1),
	})


## Seconds since the process started.
static func uptime_s() -> float:
	return float(Time.get_ticks_msec() - _started_ms) / 1000.0
