class_name Trace
extends RefCounted
## Request and trace ids. A trace groups the calls of one unit of work (the brain's day round):
## set it with begin() before the calls start and end() after; GmiClient stamps every request with
## its own request id plus the current trace id (X-Request-ID / X-Trace-ID headers, log records).

static var _current: String = ""
static var _label: String = ""
static var _session: String = new_id()


## 16 lowercase hex chars from the system CSPRNG.
static func new_id() -> String:
	return Crypto.new().generate_random_bytes(8).hex_encode()


## Starts a new current trace (label is for humans, e.g. "day 4") and returns its id.
static func begin(label: String = "") -> String:
	_current = new_id()
	_label = label
	return _current


## Clears the current trace.
static func end() -> void:
	_current = ""
	_label = ""


## Makes id the current trace (to resume one across an await); "" clears it.
static func set_current(id: String, label: String = "") -> void:
	_current = id
	_label = label


## The current trace id, "" when none.
static func current() -> String:
	return _current


static func current_label() -> String:
	return _label


## One id per game process, shared by analytics, error and alert records.
static func session_id() -> String:
	return _session


static func is_id(s: String) -> bool:
	return s.length() == 16 and s.is_valid_hex_number(false)
