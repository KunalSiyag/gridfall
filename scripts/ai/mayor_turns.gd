extends RefCounted
## Staggered mayor turns (CityBrain.stagger_mayors, on in street mode). Instead of all five mayors
## deciding at dawn, they take the day's turns one by one, spread over the first SPAN of the day in
## an order that rotates daily, so a player on foot sees decisions land every few minutes. A turn
## still waiting when the day ends runs then (CityBrain._on_day_ended). No nodes.

const D := preload("res://scripts/sim/sim_defs.gd")
## Share of the day the turns are spread over.
const SPAN := 0.9

## Mayors still to take the day's turn, in turn order.
var due: Array[int] = []
## The day the waiting turns belong to.
var day: int = -1


## Starts p_day: queues every mayor's turn when staggered. Returns staggered; false leaves the
## queue empty for the brain to run the mayors at dawn.
func start(p_day: int, staggered: bool) -> bool:
	due.clear()
	day = p_day
	if staggered:
		due.assign(order(p_day))
	return staggered


## The mayor whose turn has come at progress (0..1 through the day), taken off the queue, or -1.
## Not staggered (street mode left mid-day), the next waiting mayor goes at once. A mayor still
## deciding (busy[mi], e.g. a live call from the day before) keeps the turn and holds the queue.
func take_due(progress: float, staggered: bool, busy: Array = []) -> int:
	if due.is_empty() or (staggered and progress < at(D.MAYORS.size() - due.size())):
		return -1
	if _busy(busy, due[0]):
		return -1
	return due.pop_front()


## Every waiting turn whose mayor is free, taken off the queue (the day is ending). A mayor still
## deciding (busy[mi]) keeps the turn.
func take_all(busy: Array = []) -> Array[int]:
	var out: Array[int] = []
	for mi: int in due:
		if not _busy(busy, mi):
			out.append(mi)
	for mi: int in out:
		due.erase(mi)
	return out


## The next turn: {"mi": mayor index, "at": the day fraction it starts}, or {} when nobody waits.
func next_turn() -> Dictionary:
	if due.is_empty():
		return {}
	return {"mi": due[0], "at": at(D.MAYORS.size() - due.size())}


func clear() -> void:
	due.clear()
	day = -1


func to_dict() -> Dictionary:
	return {"due": due.duplicate(), "day": day}


## Restores a saved queue; unknown or repeated mayor indices are dropped.
func from_dict(d: Variant) -> void:
	clear()
	if typeof(d) != TYPE_DICTIONARY:
		return
	var saved: Variant = (d as Dictionary).get("due", [])
	if typeof(saved) == TYPE_ARRAY:
		for v: Variant in saved:
			var mi := int(v) if typeof(v) in [TYPE_INT, TYPE_FLOAT] else -1
			if mi >= 0 and mi < D.MAYORS.size() and not due.has(mi):
				due.append(mi)
	var saved_day: Variant = (d as Dictionary).get("day", -1)
	day = int(saved_day) if typeof(saved_day) in [TYPE_INT, TYPE_FLOAT] else -1


## The order of p_day's turns, rotated daily so nobody always goes first.
static func order(p_day: int) -> Array[int]:
	var out: Array[int] = []
	for k in range(D.MAYORS.size()):
		out.append(posmod(p_day + k, D.MAYORS.size()))
	return out


## The day fraction at which the k-th turn starts.
static func at(k: int) -> float:
	return SPAN * (float(k) + 0.5) / float(D.MAYORS.size())


## True while sim has no sliced job or spread work in flight (always for a synchronous sim). A
## staggered turn starts only then: its actions come from outside any job, and a mutator from
## outside finishes the job in flight, and the spread work it waits for, in that one frame.
static func sim_idle(sim: Object) -> bool:
	for pending: String in ["job_pending", "spread_pending"]:
		if sim.has_method(pending) and bool(sim.call(pending)):
			return false
	return true


static func _busy(busy: Array, mi: int) -> bool:
	return mi < busy.size() and bool(busy[mi])
