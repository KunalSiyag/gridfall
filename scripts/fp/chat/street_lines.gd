extends RefCounted
## What the chat hears when the visitor hits someone in the street (game bus person_hit; see
## docs/fp/ARCHITECTURE.md, Body actions): the one who was hit says so (a shove, a punch, being
## knocked down, a car) and one of the residents who saw it adds a line, and a crew called to
## the scene (incidents.gd: police after an assault, an ambulance for someone a car knocked down)
## posts a City Alert card. One victim-and-witness pair per GAP_MS on the feed clock, so a flurry
## of jabs reads as one scene; a harder blow inside the gap still posts, and so does every crew.

const D := preload("res://scripts/sim/sim_defs.gd")
const T := preload("res://scripts/fp/chat/chat_text.gd")
const GAP_MS := 8000
const SEVERITY := {"shove": 0, "punch": 1, "car": 2, "down": 3, "car_down": 3}
## What the one who was hit says ({street}: where).
const VICTIM := {
	"shove":
	[
		"Some visitor just shoved me on {street}. Who does that?",
		"Got pushed out of the way on {street}. Manners, people.",
		"Did that visitor just shove me? On {street}, in broad daylight.",
	],
	"punch":
	[
		"A visitor just punched me on {street}! What is wrong with people?",
		"Got hit in the face on {street}. By a visitor. Unbelievable.",
		"Someone on {street} just swung at me. I'm okay. I think.",
	],
	"down":
	[
		"Knocked flat on {street} by some visitor. Call the police!",
		"I'm on the ground on {street}. A visitor just floored me.",
		"Just got knocked down on {street}. My head's ringing.",
	],
	"car":
	[
		"A car just clipped me on {street}! Watch where you're driving!",
		"Nearly got run over on {street}. Still shaking.",
		"Some visitor drove right into me on {street}.",
	],
	"car_down":
	[
		"Hit by a car on {street} and knocked flat. Somebody call an ambulance.",
		"A visitor's car sent me flying on {street}.",
		"Got run down on {street}. Everything hurts.",
	],
}
## What a resident who saw it says ({who}: the one hit, by first name, or "someone").
const WITNESS := {
	"shove":
	[
		"Did a visitor just shove {who} on {street}?",
		"Some visitor's pushing people around on {street}.",
		"Saw a visitor shove {who} on {street}. Not cool.",
	],
	"punch":
	[
		"A visitor just punched {who} on {street}! Somebody stop them.",
		"Fight on {street}. Some visitor hit {who}.",
		"Stay away from {street}, there's a visitor throwing punches.",
	],
	"down":
	[
		"A visitor just knocked {who} flat on {street}. Call the police!",
		"Someone's down on {street}. That visitor floored them.",
		"Is {who} okay? A visitor knocked them down on {street}.",
	],
	"car":
	[
		"A car just hit {who} on {street}!",
		"Did you see that? A visitor drove into {who} on {street}.",
		"Slow down on {street}! A car just clipped someone.",
	],
	"car_down":
	[
		"A car just ran {who} down on {street}. Call an ambulance!",
		"Someone got hit by a car on {street}. They're on the ground.",
		"That visitor's car sent {who} flying on {street}!",
	],
}
const CREW := {
	"police": "Police called to {street} after a visitor attacked people",
	"ambulance": "Ambulance called to {street}: a car hit someone",
}

var ctx: FpContext
var feed: ChatFeed
var _last_ms: int = -GAP_MS
var _last_sev: int = -1
var _rng := RandomNumberGenerator.new()


func setup(p_ctx: FpContext, p_feed: ChatFeed) -> void:
	ctx = p_ctx
	feed = p_feed
	_last_ms = feed.now_ms - GAP_MS
	_last_sev = -1
	_rng.seed = (ctx.sim.city_seed if ctx.sim != null else 7) * 4813 + 17


## person_hit (game bus): queues the victim's line and a witness's, and a crew's City Alert card.
func on_person_hit(at: Vector3, cause: String, info: Dictionary) -> void:
	var down := bool(info.get("down", false))
	var key := ("car_down" if down else "car") if cause == "car" else ("down" if down else cause)
	if not VICTIM.has(key):
		return
	var street := str(info.get("street", ""))
	var where := street if not street.is_empty() else "the street"
	var sev := int(SEVERITY[key])
	if feed.now_ms - _last_ms >= GAP_MS or sev > _last_sev:
		_last_ms = feed.now_ms
		_last_sev = sev
		_say(info, key, where)
	var crew := str(info.get("crew", ""))
	if not CREW.has(crew):
		return
	var refs := {"type": "street", "crew": crew}
	var tile := _tile(at)
	if tile >= 0:
		refs["tile"] = tile
	var d := ctx.sim.district[tile] if tile >= 0 else -1
	var text := str(CREW[crew]).format({"street": where})
	feed.enqueue(feed.make("system", "City Alert", "system", d, text, "incident", -1, refs))


func _say(info: Dictionary, key: String, where: String) -> void:
	var r := _resident(str(info.get("resident_id", "")))
	var who := T.first_name(str(r["name"])) if not r.is_empty() else "someone"
	if not r.is_empty():
		var said := _pick(VICTIM[key]).format({"street": where})
		feed.enqueue(_msg(r, said), {"exempt": true})
	for rid: Variant in info.get("witnesses", []):
		var s := _resident(str(rid))
		if s.is_empty() or (not r.is_empty() and str(s["id"]) == str(r["id"])):
			continue
		var saw := _pick(WITNESS[key]).format({"street": where, "who": who})
		feed.enqueue(_msg(s, saw), {"exempt": true})
		return


func _msg(r: Dictionary, text: String) -> Dictionary:
	var d := ctx.sim.district[int(r["home"])]
	var refs := {"job": str(r.get("job_title", ""))}
	return feed.make(str(r["id"]), str(r["name"]), "resident", d, text, "react", -1, refs)


func _resident(rid: String) -> Dictionary:
	if rid.is_empty() or ctx.residents == null:
		return {}
	return ctx.residents.find(rid)


func _pick(lines: Array) -> String:
	return str(lines[_rng.randi_range(0, lines.size() - 1)])


static func _tile(at: Vector3) -> int:
	var x := roundi(at.x)
	var y := roundi(at.z)
	return D.idx(x, y) if D.in_bounds(x, y) else -1
