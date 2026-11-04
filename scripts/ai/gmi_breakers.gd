class_name GmiBreakers
extends RefCounted
## The circuit breakers of GmiClient, one per group of roles. A single breaker for every call let a
## burst of failing background calls (ten parallel resident batches meeting a 429, a chatter
## round timing out) open the circuit for the mayors too, who then played their turn from the
## replay cache for 30 s. Each group now counts its own consecutive service failures and opens
## alone; the mayors, the support agents (Gazette, council, chaos, citizens, operator, inspector),
## the residents and the rest each have theirs.
##
## The group "chat" is the default: every role not named in GROUPS (the street chatter, the
## face-to-face talk, anything added later) lands in it, and its breaker is the one GmiClient
## keeps as `breaker`. state() is the aggregate the alerts and the street badge read: "open" when
## any group is open, else "half_open" when any is probing, else "closed".

## One group's breaker moved (group, from, to).
signal changed(group: String, from: String, to: String)

const DEFAULT_GROUP := "chat"
## The role -> group table. Roles missing here belong to DEFAULT_GROUP.
const GROUPS := {
	"mayor": "mayor",
	"news": "support",
	"council": "support",
	"chaos": "support",
	"citizens": "support",
	"operator": "support",
	"inspector": "support",
	"residents": "residents",
}

var _by_group: Dictionary = {}
var _threshold: int = 4
var _cooldown_ms: int = 30000


## default_breaker is the default group's (GmiClient.breaker); the others copy its threshold and
## cool-down when they are first needed.
func _init(default_breaker: CircuitBreaker = null) -> void:
	var b := default_breaker if default_breaker != null else CircuitBreaker.new()
	_threshold = b.failure_threshold
	_cooldown_ms = b.cooldown_ms
	_adopt(DEFAULT_GROUP, b)


## The group a role's calls are counted in.
static func group_of(role: String) -> String:
	return str(GROUPS.get(role, DEFAULT_GROUP))


## The breaker of the group role belongs to.
func breaker_for(role: String) -> CircuitBreaker:
	return group(group_of(role))


## The breaker of a group (made on first use).
func group(name: String) -> CircuitBreaker:
	if not _by_group.has(name):
		_adopt(name, CircuitBreaker.new(_threshold, _cooldown_ms))
	return _by_group[name]


## "open" when any group is open (peeked: an open breaker past its cool-down reads half_open),
## else "half_open" when any is, else "closed".
func state(now_ms: int = -1) -> String:
	var worst := CircuitBreaker.CLOSED
	for name: String in _by_group:
		var s: String = (_by_group[name] as CircuitBreaker).peek_state(now_ms)
		if s == CircuitBreaker.OPEN:
			return s
		if s == CircuitBreaker.HALF_OPEN:
			worst = s
	return worst


## The mayors' group alone (peeked): what says whether the city's own minds are reachable. The
## street badge and Ask the five read this, so a residents or chatter storm does not mark the mayors
## as down.
func mayor_state(now_ms: int = -1) -> String:
	return group("mayor").peek_state(now_ms)


## {group: state} for every group seen so far (peeked).
func states(now_ms: int = -1) -> Dictionary:
	var out := {}
	for name: String in _by_group:
		out[name] = (_by_group[name] as CircuitBreaker).peek_state(now_ms)
	return out


## The names of the groups that are not closed, sorted ("" when all are closed).
func tripped(now_ms: int = -1) -> PackedStringArray:
	var out := PackedStringArray()
	for name: String in _by_group:
		if (_by_group[name] as CircuitBreaker).peek_state(now_ms) != CircuitBreaker.CLOSED:
			out.append(name)
	out.sort()
	return out


## Closes every group's breaker.
func reset() -> void:
	for name: String in _by_group:
		(_by_group[name] as CircuitBreaker).reset()


func _adopt(name: String, b: CircuitBreaker) -> void:
	_by_group[name] = b
	b.state_changed.connect(_on_state_changed.bind(name))


func _on_state_changed(from: String, to: String, name: String) -> void:
	changed.emit(name, from, to)
