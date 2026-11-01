extends GmiClient
## A stand-in for a live GMI call that a test holds by hand, so the order of events is exact and
## no timer is involved. Preload it as a constant and use the constant as the type:
##   const GATED := preload("res://tools/tests/support/gated_client.gd")
##   var client: GATED = GATED.new()
## With hold = true every call parks until `gate` is emitted, and all of them leave together. With
## each = true every call parks on a gate of its own instead (`parked`, in the order the calls were
## sent) and release(i) lets one go, so an old call and a new one can be in flight at once.
## The answer to a chat_json call is the offline planner's: computed when the call is sent (the
## model answered about the city it was shown), or, with late = true, when the call is released (a
## live call that failed and fell back to the planner). A live_json call (the residents' plan
## batches and reactions) answers "offline", so its caller falls back to the cache and the planner.

signal gate


## One parked call's own gate.
class Holder:
	extends RefCounted
	signal go


var hold := false
var each := false
var late := false
## The role of every call received, in order.
var sent: Array[String] = []
## The gates of the calls parked under `each`, in the order they were sent.
var parked: Array[Holder] = []


## Lets the call at index i of `parked` go.
func release(i: int) -> void:
	parked[i].go.emit()


func chat_json(
	role: String,
	_agent_id: String,
	_model: String,
	_system_prompt: String,
	_user_prompt: String,
	_day: int,
	_max_tokens: int,
	_timeout_s: float,
	heuristic: Callable
) -> Dictionary:
	sent.append(role)
	var data: Dictionary = {} if late else heuristic.call()
	if hold or each:
		await _park()
		if late:
			data = heuristic.call()
	return {
		"ok": true, "data": data, "source": "heuristic", "latency_ms": 0, "error": "", "raw": ""
	}


func live_json(
	role: String,
	agent_id: String,
	model: String,
	_system_prompt: String,
	_user_prompt: String,
	day: int,
	_max_tokens: int,
	_timeout_s: float
) -> Dictionary:
	sent.append(role)
	if hold or each:
		await _park()
	var result := _new_result(role, agent_id, model, day)
	result["error"] = "offline"
	result["source"] = "failed"
	return result


func _park() -> void:
	if each:
		var h := Holder.new()
		parked.append(h)
		await h.go
	else:
		await gate
