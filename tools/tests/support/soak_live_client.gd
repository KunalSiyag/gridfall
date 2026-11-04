extends GmiClient
## A GmiClient whose network answers from a script, for the soak (tools/tests/fp_soak.gd): every
## call "succeeds" at once with a synthetic reply that fits what its prompt asks for, so the live
## paths of the whole game run (the mayors' and agents' chat_json, the residents' batches and
## reactions, the chatter) and the session cache fills as it does in a keyed session, without a key
## or a network. Main's own GmiClient node takes this script (Node.set_script) at boot, which
## keeps every reference to it. A reply is a function of the prompt (and of the city, for a
## mayor's plan): nothing random.

## Calls answered, by kind ("mayor", "residents", "reactions", "agent").
var served: Dictionary = {}
## The plan a mayor "decides": called with the mayor's index, returns the reply object. The soak
## hands in the scripted planner (CityBrain._heuristic_mayor), whose orders grow the city, so the
## residents the minds are asked about exist; without it every mayor sets taxes and builds nothing.
var mayor_plan := Callable()

const D := preload("res://scripts/sim/sim_defs.gd")

var _id_rx := RegEx.create_from_string('"id":"(r[0-9]+)"')


func _post(
	_model: String, system_prompt: String, user_prompt: String, _max_tokens: int, _timeout_s: float
) -> Dictionary:
	var data := _reply(system_prompt, user_prompt)
	var mi := _mayor_of(system_prompt)
	if mi >= 0 and mayor_plan.is_valid():
		data.merge(mayor_plan.call(mi) as Dictionary, true)
	return {"ok": true, "data": data, "raw": "{}", "http": 200}


## The index of the mayor whose persona opens the system prompt, -1 for any other call.
func _mayor_of(system_prompt: String) -> int:
	for mi in range(D.MAYORS.size()):
		if system_prompt.begins_with(str(D.MAYORS[mi]["persona"])):
			return mi
	return -1


## The synthetic reply for a prompt: a plan for every resident id it names (for the plan and the
## reaction prompts), else one object that carries every field the mayors and the support agents
## read, so any of their replies is satisfied by it.
func _reply(system_prompt: String, user_prompt: String) -> Dictionary:
	var kind := "agent"
	if system_prompt.contains("the inner minds of real people"):
		kind = "residents"
	elif system_prompt.contains("Something just went wrong in GridFall"):
		kind = "reactions"
	elif _mayor_of(system_prompt) >= 0:
		kind = "mayor"
	served[kind] = int(served.get(kind, 0)) + 1
	var ids: Array[String] = []
	for m in _id_rx.search_all(user_prompt):
		var id := m.get_string(1)
		if not ids.has(id):
			ids.append(id)
	var residents: Array = []
	var responses: Array = []
	for id: String in ids:
		(
			residents
			. append(
				{
					"id": id,
					"go_to_work": true,
					"commute": "car",
					"spend": 40,
					"spend_where": "local",
					"evening": "home",
					"mood": 6,
					"mood_reason": "an ordinary day",
					"intent": "stay",
					"recommend": 6,
					"approve_mayor": 6,
					"complaint": "none",
					"message_to_mayor": "",
					"thought": "Another day in GridFall.",
					"say": "Morning.",
				}
			)
		)
		(
			responses
			. append(
				{
					"id": id,
					"action": "report",
					"mood": 5,
					"thought": "I will call it in.",
					"say": "Call it in!",
					"message_to_mayor": "",
				}
			)
		)
	return {
		"thought": "Steady as she goes.",
		"public_post": "Another quiet day in the district.",
		"mood": "calm",
		"actions": [{"type": "set_tax", "r": 9, "c": 9, "i": 9}],
		"propose_ordinance": "",
		"votes": {},
		"headline": "GridFall carries on",
		"stories": [{"title": "Quiet day", "body": "Nothing much happened."}],
		"editorial": "Carry on.",
		"trigger": false,
		"reason": "A calm day.",
		"narration": "A calm day in GridFall.",
		"note": "Grid steady.",
		"advice": "No change.",
		"priority": "power",
		"statement": "No change today.",
		"enacted": [],
		"repealed": [],
		"voices": [],
		"residents": residents,
		"responses": responses,
	}
