class_name CircuitBreaker
extends RefCounted
## Consecutive-failure circuit breaker. closed: calls pass; failure_threshold failures in a row
## open it. open: calls are refused for cooldown_ms. Then half_open: one probe call passes (the
## rest are refused until it reports); its success closes the breaker, its failure re-opens it.
## Every method takes an optional now_ms (Time.get_ticks_msec() when negative) so tests can drive
## the clock.

signal state_changed(from: String, to: String)

const CLOSED := "closed"
const OPEN := "open"
const HALF_OPEN := "half_open"

var failure_threshold: int = 4
var cooldown_ms: int = 30000
var state: String = CLOSED
var failures: int = 0
## How many times the breaker opened.
var open_count: int = 0
var opened_at_ms: int = 0
var _probe_out: bool = false


func _init(p_threshold: int = 4, p_cooldown_ms: int = 30000) -> void:
	failure_threshold = maxi(1, p_threshold)
	cooldown_ms = maxi(0, p_cooldown_ms)


## True when a call may go out now. In half_open only the first caller gets true (the probe).
func allow(now_ms: int = -1) -> bool:
	var now := _now(now_ms)
	match state:
		CLOSED:
			return true
		OPEN:
			if now - opened_at_ms < cooldown_ms:
				return false
			_set_state(HALF_OPEN)
			_probe_out = true
			return true
		_:
			if _probe_out:
				return false
			_probe_out = true
			return true


func record_success() -> void:
	failures = 0
	_probe_out = false
	if state != CLOSED:
		_set_state(CLOSED)


func record_failure(now_ms: int = -1) -> void:
	_probe_out = false
	failures += 1
	if state == HALF_OPEN or (state == CLOSED and failures >= failure_threshold):
		_open(_now(now_ms))


## The state as a caller would see it now: an open breaker past its cooldown reads half_open.
func peek_state(now_ms: int = -1) -> String:
	if state == OPEN and _now(now_ms) - opened_at_ms >= cooldown_ms:
		return HALF_OPEN
	return state


## Milliseconds until an open breaker lets a probe through (0 when not open).
func retry_in_ms(now_ms: int = -1) -> int:
	if state != OPEN:
		return 0
	return maxi(0, cooldown_ms - (_now(now_ms) - opened_at_ms))


func reset() -> void:
	failures = 0
	_probe_out = false
	if state != CLOSED:
		_set_state(CLOSED)


func _open(now: int) -> void:
	opened_at_ms = now
	open_count += 1
	_set_state(OPEN)


func _set_state(s: String) -> void:
	var old := state
	state = s
	state_changed.emit(old, s)


static func _now(now_ms: int) -> int:
	return now_ms if now_ms >= 0 else Time.get_ticks_msec()
