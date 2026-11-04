extends GmiClient
## The real GmiClient._post behind a scripted HTTPRequest round trip: the next replies in
## `steps` (each {"http": int, "result": int, "body": String} or {"message": Dictionary, "usage":
## Dictionary, "finish": String}), the last one repeating.
var steps: Array[Dictionary] = []
var trips: int = 0
## While true a round trip waits (a call that is "in flight"): set it false to let them finish.
var hold: bool = false


func _round_trip(_headers: PackedStringArray, _body: String, _timeout_s: float) -> Dictionary:
	while hold and is_inside_tree():
		await get_tree().process_frame
	var step: Dictionary = steps[mini(trips, steps.size() - 1)]
	trips += 1
	var text := str(step.get("body", ""))
	if step.has("message"):
		var choice := {"message": step["message"]}
		if step.has("finish"):
			choice["finish_reason"] = step["finish"]
		var reply := {"choices": [choice]}
		if step.has("usage"):
			reply["usage"] = step["usage"]
		text = JSON.stringify(reply)
	return {
		"result": int(step.get("result", HTTPRequest.RESULT_SUCCESS)),
		"http": int(step.get("http", 200)),
		"headers": PackedStringArray(),
		"body": text.to_utf8_buffer(),
	}
