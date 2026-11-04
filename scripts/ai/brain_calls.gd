extends Node
## The GMI calls a CityBrain has in flight, and which city each was sent for (CityBrain extends
## this). setup() and from_dict() replace the city: _forget_calls() starts a new generation and
## clears the flags, so an answer for the old city is dropped when it lands (_ask) instead of
## being applied to the new one, and the new city plans at once.

signal busy_changed(pending: int)

var client: GmiClient

var _mayor_in_flight: Array[bool] = [false, false, false, false, false]
var _support_in_flight: Dictionary = {}
## Counts the cities this brain has served. A call remembers the value it was sent under.
var _generation: int = 0
## What every model has done in this city (calls, answer times, repairs, accepted orders): the
## league, the Arena tab and the services page read it. Fed by the client and by mayor_decided.
var ledger := ModelLedger.new()
## The "Ask the five" engine (flag arena_ask), built on first use and dropped with the city.
var arena: ArenaAsk = null


## The Ask-the-five engine for this city: one per city, so the budget is shared by every view.
func arena_asker() -> ArenaAsk:
	if arena == null:
		arena = ArenaAsk.new(self)
	return arena


func pending_calls() -> int:
	return mayors_pending() + _support_in_flight.size()


func mayors_pending() -> int:
	return _mayor_in_flight.count(true)


## The city is being replaced (New City, Load): calls still in flight belong to the old one.
func _forget_calls() -> void:
	_generation += 1
	arena = null
	_mayor_in_flight.fill(false)
	_support_in_flight.clear()
	busy_changed.emit(pending_calls())


## One GMI call for the city as it is now: {} if the city was replaced while it was in flight.
## A planner fallback that runs late answers {} too: it would read, and draw RNG from, the new
## city.
func _ask(
	role: String,
	agent_id: String,
	model: String,
	system_prompt: String,
	user_prompt: String,
	day: int,
	max_tokens: int,
	timeout_s: float,
	heuristic: Callable
) -> Dictionary:
	var gen := _generation
	var fresh := func() -> Dictionary: return heuristic.call() if gen == _generation else {}
	var res: Dictionary = await client.chat_json(
		role, agent_id, model, system_prompt, user_prompt, day, max_tokens, timeout_s, fresh
	)
	return res if gen == _generation else {}
