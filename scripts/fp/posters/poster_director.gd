extends RefCounted
## Decides what each poster carrier shows (slice D): mayors' campaigns on billboards in their own
## districts, the GridFall Gazette at bus shelters, shop ads named after the real businesses,
## "Coming soon" hoardings on construction sites, ordinance and incident notices on homes and
## workshops, protest flyers after a district protest, and lease boards. Every image prompt comes
## from assets/posters/prompts.json plus SimDefs and directory data (never raw LLM text except the
## de-branded slogan or headline); every overlay string goes through SimDefs.debrand().
##
## An assignment is {"key", "kind" (pool), "family", "prompt", "size", "priority", "overlay"}.

const D := preload("res://scripts/sim/sim_defs.gd")
const PROMPTS_PATH := "res://assets/posters/prompts.json"
const WIDE := "1536x640"
const TALL := "768x1152"
const SLOGAN_MAX := 60
const CAMPAIGN_REFRESH_DAYS := 3
const CAMPAIGN_MOOD_SHIFT := 1.0
## Walls within this many tiles of an active incident show its warning.
const INCIDENT_RADIUS := 6.0
## business_kind() (lower case) -> pre-baked ad pool; anything else is ad_default.
const AD_POOL := {
	"cafe": "ad_cafe", "diner": "ad_cafe", "deli": "ad_cafe", "noodle bar": "ad_cafe", "bistro": "ad_cafe",
	"bakery": "ad_bakery",
	"market": "ad_market", "corner store": "ad_market", "pharmacy": "ad_market", "laundromat": "ad_market",
	"barbershop": "ad_market", "dental clinic": "ad_market",
	"bookshop": "ad_bookshop", "florist": "ad_bookshop", "design studio": "ad_bookshop", "electronics": "ad_bookshop",
	"tailors": "ad_bookshop",
	"fitness club": "ad_fitness",
	"cinema": "ad_cinema", "hotel": "ad_cinema",
	"savings bank": "ad_bank", "exchange": "ad_bank",
	"hardware": "ad_hardware", "workshop": "ad_hardware", "garage": "ad_hardware", "auto repair": "ad_hardware",
	"joinery": "ad_hardware", "print works": "ad_hardware",
}
## Shop copy by business kind (falls back to the pool line).
const TAGLINES := {
	"cafe": "Fresh coffee from 7 am", "diner": "Breakfast all day", "deli": "Sandwiches made to order",
	"noodle bar": "Hand-pulled noodles, hot and fast", "bistro": "Dinner for two tonight", "bakery": "Baked fresh every morning",
	"market": "Fresh produce daily", "corner store": "Open late, every day", "pharmacy": "Your neighbourhood pharmacy",
	"laundromat": "Wash, dry, fold. Same day.", "barbershop": "Walk-ins welcome", "dental clinic": "Smile. New patients welcome.",
	"bookshop": "Browse, linger, discover", "florist": "Flowers for every day", "design studio": "Ideas, made real",
	"electronics": "Repairs while you wait", "tailors": "Made to measure", "fitness club": "Your first week is free",
	"cinema": "Now showing", "hotel": "Stay in the heart of the city", "savings bank": "Your home starts here",
	"exchange": "Invest in GridFall", "hardware": "Everything for the job", "workshop": "Built to last",
	"garage": "Service while you wait", "auto repair": "Back on the road today", "joinery": "Handmade in GridFall",
	"print works": "Printed by tomorrow",
}
const POOL_TAGLINES := {
	"ad_cafe": "Good food, good company", "ad_bakery": "Baked fresh every morning", "ad_market": "Everything for the neighbourhood",
	"ad_bookshop": "Browse, linger, discover", "ad_fitness": "Your first week is free", "ad_cinema": "Tonight in GridFall",
	"ad_bank": "Your home starts here", "ad_hardware": "Built to last", "ad_default": "Now open",
}
## Slogans a mayor runs on before their first public post.
const DEFAULT_SLOGANS := {
	"argon": "Power, water and parks that just work.",
	"deepseek": "Smarter roads. Faster commutes.",
	"kimi": "A city that works for everyone.",
	"qwen": "Clean energy. Balanced books.",
	"grok": "Build big. Build now.",
}
## Plain-language effect lines for ordinance notices.
const ORDINANCE_LINES := {
	"public_transit": "New bus and tram routes for every district. Expect up to 30% less traffic.",
	"recycling": "Sort your waste for collection. Pollution down 15% citywide.",
	"neighborhood_watch": "Neighbours on patrol after dark. Crime down 20%.",
	"clean_air_act": "Factories must cut emissions by 40%.",
	"tourism_campaign": "Visitors welcome. More customers for local shops.",
	"green_energy_subsidy": "Solar and wind output up 50% with city support.",
	"water_conservation": "Use water wisely. Citywide use down 25%.",
	"free_clinics": "Free check-ups at every clinic in the city.",
	"curfew": "Under-18s must be home by 10 pm.",
	"trade_expo": "Industry welcome: new orders for local factories.",
}
## Protest complaint -> placard line.
const COMPLAINT_LINES := {
	"power": "Keep the lights on!", "water": "Clean water now!", "sewage": "Fix the sewers!", "trash": "Pick up the trash!",
	"pollution": "Clear the air!", "crime": "Safe streets now!", "traffic": "Fix our roads!", "taxes": "Cut the taxes!",
	"rent": "Homes we can afford!", "jobs": "Jobs for GridFall!", "health": "Clinics for every block!",
	"incident": "Safety first, now!", "noise": "Let us sleep!",
}
const POWER_EVENTS := ["blackout", "power_line"]
const WATER_EVENTS := ["water_main", "flood", "sewage_burst"]

var ctx: FpContext
var prompts: Dictionary = {}
## Per mayor: {} until a campaign exists, else {"key", "kind", "family", "prompt", "size", "priority",
## "overlay", "day", "mood", "word", "variant", "from_post"}.
var campaigns: Array[Dictionary] = [{}, {}, {}, {}, {}]
## The current Gazette assignment ({} before the first paper).
var gazette: Dictionary = {}


func setup(p_ctx: FpContext) -> void:
	ctx = p_ctx
	if FileAccess.file_exists(PROMPTS_PATH):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PROMPTS_PATH))
		if typeof(parsed) == TYPE_DICTIONARY:
			prompts = parsed


## The full image prompt for a body: body + " " + the style lock (same string the generator uses).
func prompt(body: String) -> String:
	return body + " " + str(prompts.get("style_lock", ""))


# ------------------------------------------------------------------ campaigns and news

## Seeds the Gazette from brain.last_paper and every mayor's campaign (their latest post, else a
## default slogan), so posters do not wait a game day for the next signal. Existing state is kept.
func seed_from_brain() -> void:
	var brain := ctx.brain
	if gazette.is_empty() and brain != null and not brain.last_paper.is_empty():
		on_news(brain.last_paper)
	for mi in range(D.MAYORS.size()):
		if not campaigns[mi].is_empty():
			continue
		var post := ""
		if brain != null and mi < brain.mayor_state.size():
			post = str(brain.mayor_state[mi].get("post", ""))
		_make_campaign(mi, post, 0)


## A mayor decided (CityBrain.mayor_decided). Refreshes that mayor's campaign at most every
## CAMPAIGN_REFRESH_DAYS game days, when the district's mood moved by CAMPAIGN_MOOD_SHIFT or the
## mayor's mood word changed; the first real post always replaces the default slogan. Returns true
## when the campaign changed.
func on_mayor_decided(mi: int, entry: Dictionary) -> bool:
	if mi < 0 or mi >= D.MAYORS.size():
		return false
	var post := D.debrand(str(entry.get("post", ""))).strip_edges()
	var cur := campaigns[mi]
	if cur.is_empty():
		_make_campaign(mi, post, 0)
		return true
	if post.is_empty():
		return false
	if not bool(cur.get("from_post", false)):
		_make_campaign(mi, post, int(cur.get("variant", 0)))
		return true
	if _day() - int(cur.get("day", 0)) < CAMPAIGN_REFRESH_DAYS:
		return false
	if absf(_district_mood(mi) - float(cur.get("mood", 5.0))) < CAMPAIGN_MOOD_SHIFT and _mood_word(mi) == str(cur.get("word", "")):
		return false
	_make_campaign(mi, post, (int(cur.get("variant", 0)) + 1) % _scenes(mi).size())
	return true


## The Gazette published a paper (CityBrain.news_published). Returns true when it changed.
func on_news(paper: Dictionary) -> bool:
	var headline := D.debrand(str(paper.get("headline", ""))).strip_edges()
	if headline.is_empty():
		return false
	var day := int(paper.get("day", _day()))
	if not gazette.is_empty() and str(gazette["overlay"].get("headline", "")) == headline and int(gazette["overlay"].get("day", -1)) == day:
		return false
	var topic := gazette_topic(paper)
	var live := str(prompts.get("gazette_live", "")).replace("{headline}", headline)
	var story := ""
	var stories: Variant = paper.get("stories", [])
	if typeof(stories) == TYPE_ARRAY and not (stories as Array).is_empty() and typeof(stories[0]) == TYPE_DICTIONARY:
		story = D.debrand(str((stories[0] as Dictionary).get("title", "")))
	gazette = _assignment("gazette_" + topic, prompt(live if not live.is_empty() else _gazette_body(topic)), TALL, 2,
		{"headline": headline, "day": day, "story": story, "masthead": "GRIDFALL GAZETTE"})
	return true


## Topic of a paper for the offline photo: crews, construction, park or skyline.
static func gazette_topic(paper: Dictionary) -> String:
	var text := str(paper.get("headline", ""))
	var stories: Variant = paper.get("stories", [])
	if typeof(stories) == TYPE_ARRAY:
		for s: Variant in stories:
			if typeof(s) == TYPE_DICTIONARY:
				text += " " + str((s as Dictionary).get("title", ""))
	text = text.to_lower()
	for w in ["fire", "blaze", "crew", "rescue", "flood", "quake", "tornado", "smog", "blackout", "outage", "crash", "burst", "emergency", "storm"]:
		if text.contains(w):
			return "crews"
	for w in ["build", "construct", "tower", "site", "crane", "road", "bridge", "zon", "develop", "housing", "homes", "expan"]:
		if text.contains(w):
			return "construction"
	for w in ["park", "green", "tree", "garden", "solar", "wind", "clean", "recycl"]:
		if text.contains(w):
			return "park"
	return "skyline"


func _make_campaign(mi: int, post: String, variant: int) -> void:
	var m: Dictionary = D.MAYORS[mi]
	var id := str(m["id"])
	var from_post := not post.strip_edges().is_empty()
	var slogan := slogan_of(post) if from_post else str(DEFAULT_SLOGANS.get(id, ""))
	var scenes := _scenes(mi)
	var v := clampi(variant, 0, maxi(scenes.size() - 1, 0))
	var body: String = scenes[v] if not scenes.is_empty() else "A calm modern city street at golden hour."
	var a := _assignment("campaign_" + id, prompt(body), WIDE, 1, {
		"name": str(m["display"]), "district": str(m["district"]), "slogan": slogan, "mayor": mi,
		"color": str(m["color"]), "call": "RE-ELECT",
	})
	a["day"] = _day()
	a["mood"] = _district_mood(mi)
	a["word"] = _mood_word(mi)
	a["variant"] = v
	a["from_post"] = from_post
	campaigns[mi] = a


## The first <= 60 characters of a post, cut at a word boundary, de-branded.
static func slogan_of(post: String) -> String:
	var s := D.debrand(post).strip_edges().replace("\n", " ")
	if s.length() <= SLOGAN_MAX:
		return s
	var cut := s.left(SLOGAN_MAX)
	var sp := cut.rfind(" ")
	if sp > 20:
		cut = cut.left(sp)
	return cut.rstrip(",;:-") + "…"


func _scenes(mi: int) -> Array:
	var c: Variant = prompts.get("campaign", {})
	if typeof(c) != TYPE_DICTIONARY:
		return []
	return (c as Dictionary).get(str(D.MAYORS[mi]["id"]), [])


func _gazette_body(topic: String) -> String:
	return str((prompts.get("gazette", {}) as Dictionary).get(topic, ""))


# ------------------------------------------------------------------ carriers

## The assignment for a slot ({"id", "tile", "carrier", ...}); {} when it should show nothing.
func assign(slot: Dictionary) -> Dictionary:
	var i := int(slot["tile"])
	match str(slot["carrier"]):
		"billboard":
			return _billboard(slot, i)
		"shelter":
			return gazette_or_default()
		"wall":
			return _wall(slot, i)
		"hoarding":
			return hoarding(i)
		"lease":
			return _lease(i)
	return {}


func _billboard(slot: Dictionary, i: int) -> Dictionary:
	var d := ctx.sim.district[i]
	if d >= 0 and d < D.MAYORS.size() and slot_hash(str(slot["id"])) % 2 == 0:
		if campaigns[d].is_empty():
			_make_campaign(d, "", 0)
		return campaigns[d]
	return ad_for(_ad_tile(i), WIDE)


## The current Gazette, or a front page built from the city's own numbers before the first paper.
func gazette_or_default() -> Dictionary:
	if not gazette.is_empty():
		return gazette
	var pop := int(ctx.sim.stats.get("population", 0))
	var headline := ("GridFall grows to %d residents as the mayors race to build" % pop) if pop > 0 else "A new city rises on the river"
	return _assignment("gazette_skyline", prompt(_gazette_body("skyline")), TALL, 0,
		{"headline": headline, "day": _day(), "story": "", "masthead": "GRIDFALL GAZETTE"})


## An ad for the business on tile i (or a district ad when it has none), as the pre-baked pool image.
func ad_for(i: int, size: String = WIDE) -> Dictionary:
	var dir := ctx.directory
	var name := dir.business_name(i) if i >= 0 else ""
	var kind := dir.business_kind(i) if i >= 0 else ""
	var pool := str(AD_POOL.get(kind, "ad_default"))
	var addr := dir.address(i) if i >= 0 else ""
	if name.is_empty():
		var d := ctx.sim.district[i] if i >= 0 else -1
		name = "Shop %s" % (dir.district_name(i) if i >= 0 and d >= 0 else "GridFall")
		kind = ""
	var body := str((prompts.get("ad", {}) as Dictionary).get(pool, ""))
	return _assignment(pool, prompt(body), size, 0, {
		"name": D.debrand(name), "address": D.debrand(addr), "kind": kind,
		"tagline": str(TAGLINES.get(kind, POOL_TAGLINES.get(pool, "Now open"))),
	})


## The C lot whose business a billboard on tile i advertises: i itself, else the nearest named shop
## within 4 tiles, else -1.
func _ad_tile(i: int) -> int:
	if not ctx.directory.business_name(i).is_empty():
		return i
	var x := D.tx(i)
	var y := D.ty(i)
	var best := -1
	var best_d := 1e9
	for dy in range(-4, 5):
		for dx in range(-4, 5):
			if not D.in_bounds(x + dx, y + dy):
				continue
			var j := D.idx(x + dx, y + dy)
			if ctx.sim.kind[j] != D.ZONE_C or ctx.sim.level[j] <= 0:
				continue
			var dd := float(dx * dx + dy * dy)
			if dd < best_d:
				best_d = dd
				best = j
	return best


func _wall(slot: Dictionary, i: int) -> Dictionary:
	var k := ctx.sim.kind[i]
	if k == D.ZONE_C:
		return ad_for(i, TALL)
	var inc := incident_near(i)
	if not inc.is_empty():
		return inc
	var ords: Array = ctx.sim.ordinances.keys()
	if not ords.is_empty():
		ords.sort()
		return ordinance_notice(str(ords[slot_hash(str(slot["id"])) % ords.size()]))
	var d := ctx.sim.district[i]
	if d >= 0 and d < D.MAYORS.size():
		var pl := placard(d)
		if not pl.is_empty():
			return pl
		if campaigns[d].is_empty():
			_make_campaign(d, "", 0)
		return campaigns[d]
	return ad_for(_ad_tile(i), TALL)


## A notice for an enacted ordinance.
func ordinance_notice(key: String) -> Dictionary:
	var o: Dictionary = D.ORDINANCES.get(key, {})
	var since := int(ctx.sim.ordinances.get(key, _day()))
	var body := str((prompts.get("notice", {}) as Dictionary).get("ordinance", ""))
	return _assignment("notice_ordinance", prompt(body), TALL, 0, {
		"header": "PUBLIC NOTICE", "title": D.debrand(str(o.get("label", key.capitalize()))),
		"body": str(ORDINANCE_LINES.get(key, str(o.get("desc", "")))), "footer": "By order of the City Council · Day %d" % since,
		"ordinance": key,
	})


## A warning for the nearest active incident within INCIDENT_RADIUS of tile i, or {}.
func incident_near(i: int) -> Dictionary:
	var x := float(D.tx(i))
	var y := float(D.ty(i))
	var best: Dictionary = {}
	var best_d := INCIDENT_RADIUS * INCIDENT_RADIUS
	for ev: Dictionary in ctx.sim.events:
		var dd := Vector2(float(ev.get("x", 0)) - x, float(ev.get("y", 0)) - y).length_squared()
		if dd <= best_d:
			best_d = dd
			best = ev
	if best.is_empty():
		return {}
	return incident_notice(best)


## The warning poster for an incident event (procedural layout over the pre-baked notice photo).
func incident_notice(ev: Dictionary) -> Dictionary:
	var t := str(ev.get("type", ""))
	var pool := "notice_power" if t in POWER_EVENTS else ("notice_water" if t in WATER_EVENTS else "notice_incident")
	var label := str(ev.get("label", D.DISASTERS.get(t, {}).get("label", "Incident")))
	var place := ""
	var ex := int(ev.get("x", 0))
	var ey := int(ev.get("y", 0))
	if D.in_bounds(ex, ey):
		place = ctx.directory.place_label(D.idx(ex, ey))
		if place.is_empty():
			place = ctx.directory.street_at(Vector3(ex, 0, ey))
	var line := "%s near %s. Follow crews' directions." % [label, place] if not place.is_empty() else "%s nearby. Follow crews' directions." % label
	var body := str((prompts.get("notice", {}) as Dictionary).get(pool.trim_prefix("notice_"), ""))
	return _assignment(pool, prompt(body), TALL, 0, {
		"header": "WARNING", "title": D.debrand(label), "body": D.debrand(line), "footer": "GridFall Emergency Services",
		"incident": int(ev.get("id", 0)), "family_override": "incident",
	})


## A protest flyer when district d protested yesterday, else {}.
func placard(d: int) -> Dictionary:
	var people := ctx.residents
	if people == null or not people.is_active():
		return {}
	var dm := people.district_mood(d)
	if int(dm.get("protested_yesterday", 0)) <= 0:
		return {}
	var complaints: Dictionary = dm.get("complaints", {})
	var top := ""
	var top_n := 0
	var ks := complaints.keys()
	ks.sort()
	for c: Variant in ks:
		if int(complaints[c]) > top_n:
			top_n = int(complaints[c])
			top = str(c)
	var mayor := D.mayor_display(d)
	var body := str((prompts.get("placard", {}) as Dictionary).get("protest", ""))
	return _assignment("placard", prompt(body), TALL, 0, {
		"title": str(COMPLAINT_LINES.get(top, "Listen to us!")),
		"body": ("Mayor %s, are you listening?" % mayor.get_slice(" ", mayor.get_slice_count(" ") - 1)) if not mayor.is_empty() else "Are you listening?",
		"footer": "Rally at City Hall · Day %d" % _day(), "complaint": top,
	})


## "Coming soon" for the construction site on tile i ({} when there is none or it is a road job).
func hoarding(i: int) -> Dictionary:
	var s: Dictionary = ctx.sim.sites.get(i, {})
	if s.is_empty() or str(s.get("type", "")) == "road" or str(s.get("type", "")) == "demolish":
		return {}
	var tk := int(s.get("target_kind", -1))
	var tl := int(s.get("target_level", 0))
	var name := ctx.directory.planned_name(i, tk, tl)
	if name.is_empty():
		for key: String in D.BUILDINGS.keys():
			if int(D.BUILDINGS[key]["kind"]) == tk:
				name = str(D.BUILDINGS[key]["label"])
				break
	if name.is_empty():
		name = "New homes" if tk == D.ZONE_R else str(s.get("label", "New building"))
	var owner := int(s.get("owner", -1))
	var builder := "Built by %s's contractors" % D.mayor_display(owner) if owner >= 0 and owner < D.MAYORS.size() else "Built by GridFall contractors"
	var pool := "hoarding_park" if tk == D.PARK else ("hoarding_station" if D.is_service(tk) else "hoarding_tower")
	var body := str((prompts.get("hoarding", {}) as Dictionary).get(pool.trim_prefix("hoarding_"), ""))
	return _assignment(pool, prompt(body), WIDE, 0, {
		"title": "COMING SOON", "name": D.debrand(name), "builder": D.debrand(builder), "owner": owner,
		"color": str(D.MAYORS[owner]["color"]) if owner >= 0 and owner < D.MAYORS.size() else "#F2C230",
	})


func _lease(i: int) -> Dictionary:
	var addr := ctx.directory.address(i)
	return {"key": "lease|" + addr, "kind": "lease", "family": "lease", "prompt": "", "size": "", "priority": 0,
		"overlay": {"title": "For lease", "address": addr if not addr.is_empty() else ctx.directory.district_name(i), "phone": "555-01%02d" % (absi(i) % 100)}}


# ------------------------------------------------------------------ helpers

func _assignment(kind: String, p: String, size: String, priority: int, overlay: Dictionary) -> Dictionary:
	var fam := str(overlay.get("family_override", kind.get_slice("_", 0)))
	return {"key": GmiImageClient.key_for(p, size), "kind": kind, "family": fam, "prompt": p, "size": size,
		"priority": priority, "overlay": overlay}


## Deterministic per-slot hash seeded by the city.
func slot_hash(slot_id: String) -> int:
	return absi(("%s|%d" % [slot_id, ctx.sim.city_seed]).hash())


func _day() -> int:
	return ctx.sim.day if ctx != null and ctx.sim != null else 0


func _district_mood(mi: int) -> float:
	if ctx.residents == null or not ctx.residents.is_active():
		return 5.0
	return float(ctx.residents.district_mood(mi).get("avg_mood", 5.0))


func _mood_word(mi: int) -> String:
	if ctx.brain == null or mi >= ctx.brain.mayor_state.size():
		return ""
	return str(ctx.brain.mayor_state[mi].get("mood", ""))


## Campaign state for the save: campaign_day, campaign_mood and the assignments themselves.
func to_dict() -> Dictionary:
	var days: Array = []
	var moods: Array = []
	var words: Array = []
	var list: Array = []
	for c: Dictionary in campaigns:
		days.append(int(c.get("day", -1)))
		moods.append(float(c.get("mood", 5.0)))
		words.append(str(c.get("word", "")))
		list.append(_strip(c))
	return {"campaign_day": days, "campaign_mood": moods, "campaign_word": words, "campaigns": list, "gazette": _strip(gazette)}


func from_dict(d: Dictionary) -> void:
	var list: Variant = d.get("campaigns", [])
	var days: Variant = d.get("campaign_day", [])
	var moods: Variant = d.get("campaign_mood", [])
	var words: Variant = d.get("campaign_word", [])
	campaigns = [{}, {}, {}, {}, {}]
	if typeof(list) == TYPE_ARRAY:
		for mi in range(mini((list as Array).size(), campaigns.size())):
			var c: Variant = list[mi]
			if typeof(c) != TYPE_DICTIONARY or (c as Dictionary).is_empty():
				continue
			var a := _restore(c)
			a["day"] = int(days[mi]) if typeof(days) == TYPE_ARRAY and mi < (days as Array).size() else int(c.get("day", 0))
			a["mood"] = float(moods[mi]) if typeof(moods) == TYPE_ARRAY and mi < (moods as Array).size() else 5.0
			a["word"] = str(words[mi]) if typeof(words) == TYPE_ARRAY and mi < (words as Array).size() else ""
			a["variant"] = int(c.get("variant", 0))
			a["from_post"] = bool(c.get("from_post", false))
			campaigns[mi] = a
	var g: Variant = d.get("gazette", {})
	gazette = _restore(g) if typeof(g) == TYPE_DICTIONARY and not (g as Dictionary).is_empty() else {}


static func _strip(a: Dictionary) -> Dictionary:
	if a.is_empty():
		return {}
	var out := {}
	for k: String in ["key", "kind", "family", "prompt", "size", "priority", "overlay", "day", "variant", "from_post"]:
		if a.has(k):
			out[k] = a[k]
	return out


## An assignment from saved JSON (ints come back as floats).
static func _restore(c: Dictionary) -> Dictionary:
	var a := c.duplicate(true)
	a["priority"] = int(a.get("priority", 0))
	var ov: Dictionary = a.get("overlay", {})
	for k: String in ["day", "mayor", "owner", "incident"]:
		if ov.has(k):
			ov[k] = int(ov[k])
	a["overlay"] = ov
	return a
