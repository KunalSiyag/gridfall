extends GmiClient
## A GmiClient whose transport is a script a test writes: one JSON reply per model id (by_model),
## as the live API would return it once parsed, and a record of every prompt sent. A model with no
## reply fails like an unreadable answer ("no JSON in reply", the service up), so its caller falls
## back to the replay cache and the offline planner. No network and no key: only _post is replaced,
## so source, latency, session cache and fallbacks are the real client's. Preload it as a constant:
##   const NET := preload("res://tools/tests/support/scripted_net.gd")
##   var net: NET = NET.new()
##   net.live_enabled = true   # before it joins a world: K.make_sim keeps live_enabled as given

## model id -> the reply's JSON object.
var by_model: Dictionary = {}
## Every call, in order: {"model", "system", "user"}.
var sent: Array[Dictionary] = []


func _post(
	model: String, system_prompt: String, user_prompt: String, _max_tokens: int, _timeout_s: float
) -> Dictionary:
	sent.append({"model": model, "system": system_prompt, "user": user_prompt})
	if not by_model.has(model):
		return {"ok": false, "error": "no JSON in reply", "service_fail": false, "http": 200}
	var reply: Dictionary = (by_model[model] as Dictionary).duplicate(true)
	return {"ok": true, "data": reply, "raw": JSON.stringify(reply), "http": 200}


## The user prompt of the newest call to model ("" when there was none).
func last_user(model: String) -> String:
	for k in range(sent.size() - 1, -1, -1):
		if str(sent[k]["model"]) == model:
			return str(sent[k]["user"])
	return ""
