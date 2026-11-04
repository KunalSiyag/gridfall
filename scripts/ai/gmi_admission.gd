class_name GmiAdmission
extends RefCounted
## How many live calls GmiClient has out at once, with the mayors first. A browser keeps few
## connections per host (six over HTTP/1.1) and a key's tier may rate-limit a burst, while at dawn
## ten resident batches, the chatter and five mayors all go out together. With the cap on, the
## background roles (the residents, the street chatter, the talk) wait for a free slot instead of
## all going out at once; the roles that are the city's own business (the mayors, the support
## agents and the "Ask the five" panel) never wait, and while one of them is in flight the
## background gets half the slots. A call still waiting when its own timeout is up gives up and
## the caller falls back as for any failed call.
##
## Off by default (flag gmi_inflight_cap): it paces the minds, and the right numbers depend on the
## key's tier, which no test can know. GmiClient asks can_enter() and brackets a call with
## enter() and leave().

## Roles that never wait for a slot.
const PRIORITY_ROLES := [
	"mayor", "news", "council", "chaos", "citizens", "operator", "inspector", "arena"
]
## Background calls allowed at once (halved, at least 1, while a priority call is out).
const BACKGROUND_MAX := 6

var background_max: int = BACKGROUND_MAX
var _background: int = 0
var _priority: int = 0


static func is_priority(role: String) -> bool:
	return role in PRIORITY_ROLES


## Background slots free right now: background_max, or half of it while a priority call is out.
func slots() -> int:
	if _priority > 0:
		return maxi(1, background_max >> 1)
	return background_max


## True when a call of this role may go out now. A priority call always may.
func can_enter(role: String) -> bool:
	return is_priority(role) or _background < slots()


func enter(role: String) -> void:
	if is_priority(role):
		_priority += 1
	else:
		_background += 1


func leave(role: String) -> void:
	if is_priority(role):
		_priority = maxi(0, _priority - 1)
	else:
		_background = maxi(0, _background - 1)


## Background calls out now (the tests read it).
func background() -> int:
	return _background


## Priority calls out now.
func priority() -> int:
	return _priority
