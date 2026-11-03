extends "res://tools/tests/support/gated_client.gd"
## A GatedClient whose live_json answers like a live model instead of "offline": with each = true
## every call parks until released (release(i), i in the order sent), then answers the canned
## mayor turn in data_for[agent id], or the failure text in fail[agent id]. Keeps what it was sent
## in `seen`. Shared by ai_ask_all_test.gd and fp_arena_test.gd.

## One dict per call: {role, agent, model, system, user}.
var seen: Array[Dictionary] = []
## agent id -> the reply data.
var data_for: Dictionary = {}
## agent id -> the error text of a failed call.
var fail: Dictionary = {}


func live_json(
	role: String,
	agent_id: String,
	model: String,
	system_prompt: String,
	user_prompt: String,
	day: int,
	_max_tokens: int,
	_timeout_s: float
) -> Dictionary:
	sent.append(role)
	(
		seen
		. append(
			{
				"role": role,
				"agent": agent_id,
				"model": model,
				"system": system_prompt,
				"user": user_prompt,
			}
		)
	)
	if hold or each:
		await _park()
	var result := _new_result(role, agent_id, model, day)
	if fail.has(agent_id):
		result["error"] = str(fail[agent_id])
		result["source"] = "failed"
		return result
	result["ok"] = true
	result["source"] = "live"
	result["data"] = data_for.get(agent_id, {})
	return result
