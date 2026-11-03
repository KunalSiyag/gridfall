extends RefCounted
## What a blow in the street means for the city (traffic_feature.gd hit_walker): a resident who
## was hit remembers it and their mood drops (a shove least, a car or a carjack most, more when
## knocked down), and residents who saw it remember it too. A punch that knocks someone down, the
## ASSAULT-th punch within ASSAULT_S or a carjack calls the police; someone a car knocks down, an
## ambulance (a crew from the nearest station that stays at the scene a while, fleets.gd), each
## kind at most once per CREW_COOL. A police car that gets there is the police_response flag's to
## run (police_response.gd); what the hero did sets the fine, and an arrest is the street's relief
## (arrested()).

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const MOOD := {"shove": -0.5, "punch": -1.0, "car": -2.0, "carjack": -2.0}
const DOWN_MOOD := 1.5
const SAW_MOOD := -0.3
## Those who see the hero arrested within ARREST_SEEN of them are a little easier.
const ARREST_MOOD := 0.3
const ARREST_SEEN := 25.0 * WS.M
const ASSAULT := 3
const ASSAULT_S := 60.0
const CREW_COOL := 90.0
const STAY := {"police": 40.0, "ambulance": 30.0}
## Memory lines (residents.gd remember): what happened to them and what they saw (%s is where).
const HIT_LINES := {
	"shove": "got shoved by a visitor %s",
	"punch": "was punched by a visitor %s",
	"down": "was knocked down by a visitor %s",
	"car": "was hit by a visitor's car %s",
	"carjack": "was carjacked by a visitor %s",
}
const SAW_LINES := {
	"shove": "saw a visitor shove someone %s",
	"punch": "saw a visitor punch someone %s",
	"car": "saw a visitor's car hit someone %s",
	"carjack": "saw a visitor carjack someone %s",
}

var f: Object
var _punches: Array[float] = []
var _called: Dictionary = {}  # crew kind -> traffic clock when last called


func setup(p_f: Object) -> void:
	f = p_f
	_punches.clear()
	_called.clear()


## The person_hit info for walker w hit by cause at world point at (res: reactions.gd hit()'s
## result, seen: the walkers who saw it, by: who struck — -1 the hero, else a walker's id):
## {"walker", "resident_id", "name", "down", "street", "strength", "by", "witnesses" (their
## resident ids), "crew" ("police", "ambulance" or "")}. A crew answers the hero's violence only:
## a blow by someone else never counts toward the assault streak nor dispatches one.
func report(
	w: WK.Walker,
	at: Vector3,
	strength: float,
	cause: String,
	res: Dictionary,
	seen: Array,
	by: int = -1
) -> Dictionary:
	var down := bool(res.get("down", false))
	var street := _street(at)
	var where := ("on " + street) if not street.is_empty() else "in the street"
	var info := {
		"walker": w.id,
		"resident_id": w.resident_id,
		"name": "",
		"down": down,
		"street": street,
		"strength": strength,
		"by": by,
		"witnesses": [],
		"crew": "",
	}
	var key := "down" if down and cause == "punch" else cause
	var r := _resident(w.resident_id)
	if not r.is_empty():
		info["name"] = str(r.get("name", ""))
		f.ctx.residents.remember(r, str(HIT_LINES.get(key, HIT_LINES["shove"])) % where)
		f.ctx.residents.nudge_mood(r, float(MOOD.get(cause, -0.5)) * (DOWN_MOOD if down else 1.0))
	for o: WK.Walker in seen:
		var s := _resident(o.resident_id)
		if s.is_empty():
			continue
		f.ctx.residents.remember(s, str(SAW_LINES.get(cause, SAW_LINES["shove"])) % where)
		f.ctx.residents.nudge_mood(s, SAW_MOOD)
		(info["witnesses"] as Array).append(o.resident_id)
	if by < 0:
		info["crew"] = _crew(cause, down, at)
		f.police.note_offence(cause)
	return info


func _resident(rid: String) -> Dictionary:
	var rs: Variant = f.ctx.residents
	if rid.is_empty() or rs == null or not rs.has_method("remember"):
		return {}
	return rs.find(rid)


func _street(at: Vector3) -> String:
	var x := roundi(at.x)
	var y := roundi(at.z)
	return f.street_label(D.idx(x, y)) if D.in_bounds(x, y) else ""


## Calls the police after an assault or a carjack and an ambulance for someone a car knocked
## down; the kind called, or "".
func _crew(cause: String, down: bool, at: Vector3) -> String:
	var now: float = f.clock
	var kind := ""
	if cause == "punch":
		_punches.append(now)
		while not _punches.is_empty() and now - _punches[0] > ASSAULT_S:
			_punches.pop_front()
		if down or _punches.size() >= ASSAULT:
			kind = "police"
	elif cause == "car" and down:
		kind = "ambulance"
	elif cause == "carjack":
		kind = "police"
	if kind.is_empty() or now - float(_called.get(kind, -INF)) < CREW_COOL:
		return ""
	if not f.call_crew(kind, at, float(STAY[kind]), cause):
		return ""
	_called[kind] = now
	if kind == "police":
		_punches.clear()
	return kind


## The police took the hero away at at (on street, "" in the open): residents on foot who saw it
## (within ARREST_SEEN) remember it and are a little easier. Returns how many did.
func arrested(at: Vector3, street: String) -> int:
	var where := ("on " + street) if not street.is_empty() else "in the street"
	var n := 0
	for w: WK.Walker in f.walkers.walkers:
		if w.dead or w.resident_id.is_empty():
			continue
		if Vector2(w.pos.x - at.x, w.pos.z - at.z).length() > ARREST_SEEN:
			continue
		var r := _resident(w.resident_id)
		if r.is_empty():
			continue
		f.ctx.residents.remember(r, "saw the police arrest a visitor %s" % where)
		f.ctx.residents.nudge_mood(r, ARREST_MOOD)
		n += 1
	return n
