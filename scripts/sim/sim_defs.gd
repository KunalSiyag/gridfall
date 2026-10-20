class_name SimDefs
extends RefCounted
## Static rules, costs, and catalogs for the GridFall city simulation.

## Founding city size; the world around it is six times wider in each direction.
const CORE := 32
const W := 192
const H := 192
const X0 := -80
const Y0 := -80
const PLOT := 16
## "No tile" marker: -1 is a real coordinate in the wider world.
const NO_TILE := Vector2i(-99999, -99999)
const ANNEX_BASE_COST := 1500
const ANNEX_STEP_COST := 400
## Plots within this many plots of claimed land are surveyed: mapped and shown clearly. The
## frontier beyond stays in haze until the city grows towards it.
const SURVEY_RANGE := 2
## Layout of saves written before the world grew to 192x192.
const LEGACY_WORLD := {"w": 96, "h": 96, "x0": -32, "y0": -32}
const GROWTH_TICKS_PER_DAY := 4
const BASE_DAY_SECONDS := 12.0
const START_FUNDS := 12000

# Tile kinds
const EMPTY := 0
const ROAD := 1
const ZONE_R := 2
const ZONE_C := 3
const ZONE_I := 4
const COAL := 5
const SOLAR := 6
const PUMP := 7
const SEWAGE := 8
const POLICE := 9
const FIRE := 10
const HOSPITAL := 11
const SCHOOL := 12
const PARK := 13
const HALL := 14
const RUBBLE := 15
const FOREST := 16
const WIND := 17
const STADIUM := 18
const TRAIN := 19
const UNIVERSITY := 20
const LANDFILL := 21
const AIRPORT := 22
## A tile being built or torn down; CitySim.sites holds what it will become.
const SITE := 23

# Terrain
const LAND := 0
const WATER := 1

const KIND_NAMES := {
	EMPTY: "empty", ROAD: "road", ZONE_R: "residential", ZONE_C: "commercial", ZONE_I: "industrial",
	COAL: "coal_plant", SOLAR: "solar_farm", PUMP: "water_pump", SEWAGE: "sewage_plant",
	POLICE: "police", FIRE: "fire_station", HOSPITAL: "hospital", SCHOOL: "school", PARK: "park",
	HALL: "city_hall", RUBBLE: "rubble", FOREST: "forest",
	WIND: "wind_farm", STADIUM: "stadium", TRAIN: "train_station", UNIVERSITY: "university",
	LANDFILL: "landfill", AIRPORT: "airport", SITE: "construction_site",
}

## Buildable service structures. power/water/sewage are capacities supplied; radius is coverage.
const BUILDINGS := {
	"coal_plant": {"kind": COAL, "cost": 3000, "upkeep": 45, "power": 140, "pollution": 1.0, "label": "Coal Power Plant"},
	"solar_farm": {"kind": SOLAR, "cost": 1600, "upkeep": 14, "power": 45, "pollution": 0.0, "label": "Solar Farm"},
	"water_pump": {"kind": PUMP, "cost": 900, "upkeep": 12, "water": 90, "label": "Water Tower & Pump"},
	"sewage_plant": {"kind": SEWAGE, "cost": 1300, "upkeep": 18, "sewage": 120, "label": "Sewage Treatment Plant"},
	"police": {"kind": POLICE, "cost": 750, "upkeep": 22, "radius": 7, "label": "Police Station"},
	"fire_station": {"kind": FIRE, "cost": 750, "upkeep": 22, "radius": 7, "label": "Fire Station"},
	"hospital": {"kind": HOSPITAL, "cost": 1200, "upkeep": 30, "radius": 8, "label": "Hospital"},
	"school": {"kind": SCHOOL, "cost": 950, "upkeep": 25, "radius": 8, "label": "School"},
	"park": {"kind": PARK, "cost": 120, "upkeep": 2, "radius": 3, "label": "Park"},
	"wind_farm": {"kind": WIND, "cost": 2200, "upkeep": 16, "power": 70, "pollution": 0.0, "label": "Wind Farm"},
	"stadium": {"kind": STADIUM, "cost": 4000, "upkeep": 40, "radius": 10, "label": "Stadium"},
	"train_station": {"kind": TRAIN, "cost": 1800, "upkeep": 25, "radius": 8, "label": "Train Station"},
	"university": {"kind": UNIVERSITY, "cost": 3200, "upkeep": 45, "radius": 11, "label": "University"},
	"landfill": {"kind": LANDFILL, "cost": 1000, "upkeep": 12, "waste": 160, "label": "Landfill"},
	"airport": {"kind": AIRPORT, "cost": 6000, "upkeep": 60, "label": "Airport"},
}

const ROAD_COST := 10
const ZONE_COST := 5
const BULLDOZE_COST := 5
const EMERGENCY_COST := 300
const MAX_ROAD_LEN := 16
const MAX_ZONE_SIDE := 6
const MAX_ACTIONS_PER_DAY := 7

## Staged construction. Every site gets CREW_RATE work points per growth tick from its paid
## contractor; residents with construction skills add more. A site needs (ticks * CREW_RATE)
## points in total, split evenly across its stages.
const CREW_RATE := 10.0
## Contractor-only build times in growth ticks (4 ticks = 1 day). Resident crews shorten them.
const ROAD_TICKS := 4
const BRIDGE_TICKS := 10
const ZONE_SITE_TICKS := {"zone_house": 8, "zone_new": 10, "zone_up": 14, "zone_tower": 24}
## Resident helpers can add at most this share of a contractor shift to one site per tick, so
## a keen neighbourhood speeds a job up without building a stadium in a weekend.
const HELPER_CAP := 0.6
## Private developers in one district only take on this many zone sites at a time.
const MAX_ZONE_SITES := 10
const SITE_STAGES := {
	"build": ["clearing", "excavation", "foundation", "frame", "finishing"],
	"light": ["clearing", "foundation", "frame", "finishing"],
	"park": ["clearing", "landscaping"],
	"zone_new": ["excavation", "foundation", "frame", "finishing"],
	"zone_house": ["foundation", "frame", "finishing"],
	"zone_up": ["frame", "finishing"],
	"zone_tower": ["foundation", "frame", "finishing"],
	"road": ["clearing", "grading", "paving"],
	"bridge": ["piling", "decking", "paving"],
	"demolish": ["demolition", "hauling"],
	"haul": ["hauling"],
	"clear": ["clearing"],
}
const STAGE_LABELS := {
	"clearing": "clearing the land", "excavation": "digging the foundations", "foundation": "pouring concrete",
	"frame": "raising the frame", "finishing": "finishing the facade", "landscaping": "landscaping",
	"grading": "grading the roadbed", "paving": "paving", "piling": "driving piles", "decking": "laying the deck",
	"demolition": "demolishing", "hauling": "hauling debris away",
}
## Light structures skip the excavation stage.
const LIGHT_BUILDS := ["solar_farm", "wind_farm", "landfill"]
## The player's own building crews, for orders placed from the phone. A crew takes one order at a
## time and works it in real seconds at game speed; later orders wait for the next free crew.
const CREWS := 2
## A park takes a crew CREW_MIN_S, the airport CREW_MAX_S, other buildings scale with their
## contractor time in between. Roads and clearing take CREW_TILE_S per tile. No order is quicker
## than CREW_JOB_MIN_S or slower than CREW_MAX_S.
const CREW_MIN_S := 120.0
const CREW_MAX_S := 300.0
const CREW_JOB_MIN_S := 45.0
const CREW_TILE_S := {"road": 10.0, "bridge": 24.0, "clear": 30.0, "haul": 45.0}

# Capacity per density level (index = level 0..3)
const R_POP := [0, 16, 48, 120]
const C_JOBS := [0, 10, 30, 72]
const I_JOBS := [0, 14, 40, 90]

const ORDINANCES := {
	"public_transit": {"label": "Public Transit Network", "cost": 60, "desc": "-30% traffic"},
	"recycling": {"label": "Recycling Program", "cost": 40, "desc": "-15% pollution"},
	"neighborhood_watch": {"label": "Neighborhood Watch", "cost": 30, "desc": "-20% crime"},
	"clean_air_act": {"label": "Clean Air Act", "cost": 20, "desc": "-40% industrial pollution, -0.1 I demand"},
	"tourism_campaign": {"label": "Tourism Campaign", "cost": 50, "desc": "+0.15 commercial demand"},
	"green_energy_subsidy": {"label": "Green Energy Subsidy", "cost": 50, "desc": "+50% solar and wind output"},
	"water_conservation": {"label": "Water Conservation", "cost": 25, "desc": "-25% water use"},
	"free_clinics": {"label": "Free Clinics", "cost": 60, "desc": "+5% happiness"},
	"curfew": {"label": "Youth Curfew", "cost": 10, "desc": "-30% crime, -5% happiness"},
	"trade_expo": {"label": "Industrial Trade Expo", "cost": 45, "desc": "+0.2 industrial demand"},
}

## "days" is only used when no residents are simulated. With residents, an incident stays broken
## until people or paid crews put in "work" points; "skills" say who is actually useful, and
## "weather" incidents also fade by that much per tick on their own.
const DISASTERS := {
	"fire": {"label": "Building Fire", "days": 2, "work": 60, "skills": ["fire", "rescue"]},
	"blackout": {"label": "Power Plant Failure", "days": 2, "work": 120, "skills": ["power"]},
	"sewage_burst": {"label": "Sewage Main Burst", "days": 2, "work": 100, "skills": ["sewage", "water"]},
	"gridlock": {"label": "Traffic Gridlock", "days": 1, "work": 50, "skills": ["traffic", "order"]},
	"smog": {"label": "Toxic Smog Event", "days": 2, "work": 90, "skills": ["medical", "industry"], "weather": 6.0},
	"earthquake": {"label": "Earthquake", "days": 1, "work": 160, "skills": ["rescue", "construction", "medical"]},
	"flood": {"label": "River Flood", "days": 1, "work": 130, "skills": ["rescue", "water"], "weather": 8.0},
	"tornado": {"label": "Tornado", "days": 1, "work": 140, "skills": ["rescue", "construction", "medical"]},
	"water_main": {"label": "Water Main Break", "days": 2, "work": 80, "skills": ["water"]},
	"power_line": {"label": "Downed Power Line", "days": 1, "work": 70, "skills": ["power"]},
	"car_crash": {"label": "Car Crash", "days": 1, "work": 40, "skills": ["medical", "order", "traffic"]},
}
const SKILL_LABELS := {
	"power": "electrical repair", "water": "water and pipes", "sewage": "sewage systems", "fire": "firefighting",
	"rescue": "search and rescue", "medical": "medical care", "order": "policing", "traffic": "traffic and driving",
	"construction": "construction", "industry": "industrial operations", "care": "caring for people",
}

## Five autonomous AI mayors, each powered by a different GMI Cloud model.
const MAYORS := [
	{
		"id": "argon", "name": "Argon-4", "display": "Ada Okafor", "model": "google/gemini-4-argon", "color": "#FFB800",
		"district": "Northwest Civic Campus", "style": "Utility-first planner",
		"persona": "You are Ada Okafor, mayor of the Northwest Civic Campus and a meticulous civic planner. You build reliable power, water, and sewage first, keep taxes moderate, and love parks and schools.",
	},
	{
		"id": "deepseek", "name": "DeepSeek-V4", "display": "Viktor Han", "model": "deepseek-ai/DeepSeek-V4-Flash-0731", "color": "#00F0FF",
		"district": "Northeast Tech Corridor", "style": "Systems engineer",
		"persona": "You are Viktor Han, mayor of the Northeast Tech Corridor and a first-principles systems engineer. You optimize road grids, industrial output, and traffic flow, and you quantify every trade-off.",
	},
	{
		"id": "kimi", "name": "Kimi-K3", "display": "Mei Kimura", "model": "moonshotai/kimi-k3", "color": "#B44CFF",
		"district": "Central Plaza", "style": "Coalition builder",
		"persona": "You are Mei Kimura, the coalition mayor of the Central Plaza. You prioritize citizen happiness, commerce, safety, and you broker deals between the other mayors.",
	},
	{
		"id": "qwen", "name": "Qwen-3.8", "display": "Rosa Quintero", "model": "Qwen/Qwen3.8-Max", "color": "#10E88A",
		"district": "Southwest Eco Quarter", "style": "Fiscal pragmatist",
		"persona": "You are Rosa Quintero, mayor of the Southwest Eco Quarter and a fiscally careful pragmatist. You balance budgets, grow steadily, prefer clean energy, and avoid debt.",
	},
	{
		"id": "grok", "name": "Grok-4.5", "display": "Duke Granger", "model": "x-ai/grok-4.5", "color": "#FF2E54",
		"district": "Southeast Boomtown", "style": "Growth maximalist",
		"persona": "You are Duke Granger, mayor of the Southeast Boomtown and a witty, aggressive growth maximalist. You chase population and tax revenue, tolerate pollution, mock red tape, and take bold bets.",
	},
]

## Supporting GMI agents that give the rest of the city a mind.
const SUPPORT_AGENTS := {
	"citizens": {"name": "Citizen Voices", "model": "MiniMaxAI/MiniMax-M3", "color": "#7FD1FF"},
	"news": {"name": "GridFall Gazette", "model": "XiaomiMiMo/MiMo-V2.6-Flash", "color": "#FFD27F"},
	"council": {"name": "Council Speaker", "model": "openai/gpt-6-luna", "color": "#C9B6FF"},
	"chaos": {"name": "Chaos Director", "model": "deepseek-ai/DeepSeek-V4-Pro", "color": "#FF7A59"},
	"operator": {"name": "Grid Operator", "model": "google/gemini-3.8-flash", "color": "#9CFF8F"},
	"inspector": {"name": "Street Inspector", "model": "MiniMaxAI/MiniMax-M3", "color": "#FFFFFF"},
}

const ZONE_CHAR := {ZONE_R: "r", ZONE_C: "c", ZONE_I: "i"}
const DEV_CHAR := {ZONE_R: "R", ZONE_C: "C", ZONE_I: "I"}
const MAP_CHAR := {
	EMPTY: ".", ROAD: "=", COAL: "E", SOLAR: "S", PUMP: "W", SEWAGE: "X", POLICE: "K",
	FIRE: "F", HOSPITAL: "H", SCHOOL: "U", PARK: "T", HALL: "M", RUBBLE: "#", FOREST: "^",
	WIND: "V", STADIUM: "O", TRAIN: "Q", UNIVERSITY: "N", LANDFILL: "L", AIRPORT: "P", SITE: "+",
}
const MAP_LEGEND := ". empty land, ^ forest (zoning clears it), ~ water, = road, r/c/i zoned empty lot, R/C/I developed (digit after = density not shown), E coal plant, S solar, V wind farm, W water pump, X sewage plant, L landfill, K police, F fire station, H hospital, U school, N university, T park, O stadium, Q train station, P airport, M city hall, # rubble, + construction site (being built or demolished), * on fire, space = outside your district"


## The founding city keeps coordinates 0..31 so recorded mayor actions and saves stay valid;
## the wider world runs from X0/Y0 (-80) to 111 and is opened up plot by plot through annexation.
static func idx(x: int, y: int) -> int:
	return (y - Y0) * W + (x - X0)


static func in_bounds(x: int, y: int) -> bool:
	return x >= X0 and y >= Y0 and x < X0 + W and y < Y0 + H


static func tx(i: int) -> int:
	return i % W + X0


static func ty(i: int) -> int:
	return i / W + Y0


static func in_core(x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < CORE and y < CORE


static func plot_of(x: int, y: int) -> Vector2i:
	return Vector2i(floori(float(x) / PLOT), floori(float(y) / PLOT))


static func plot_rect(p: Vector2i) -> Rect2i:
	return Rect2i(p.x * PLOT, p.y * PLOT, PLOT, PLOT)


static func is_zone(kind: int) -> bool:
	return kind == ZONE_R or kind == ZONE_C or kind == ZONE_I


static func is_service(kind: int) -> bool:
	return (kind >= COAL and kind <= HALL) or (kind >= WIND and kind <= AIRPORT)


## Contractor-only build time in growth ticks (4 per day) for a service building.
static func build_ticks(key: String) -> int:
	if key == "park":
		return 4
	# A police station takes ~3 days, a stadium ~12 and the airport ~15.
	return clampi(4 + int(BUILDINGS[key]["cost"]) / 90, 10, 60)


## Real seconds one of the player's crews needs for a site of plan that contractors alone would
## finish in ticks growth ticks.
static func crew_seconds(plan: String, ticks: int) -> float:
	match plan:
		"build", "light", "park":
			# build_ticks runs from 4 (park) to 60 (airport).
			return lerpf(CREW_MIN_S, CREW_MAX_S, clampf(float(ticks - 4) / 56.0, 0.0, 1.0))
		"demolish":
			return 40.0 + 6.0 * float(ticks)
	return float(CREW_TILE_S.get(plan, CREW_JOB_MIN_S))


## The site plan for building key: the park and the light builds go through fewer stages.
static func build_plan(key: String) -> String:
	if key == "park":
		return "park"
	return "light" if LIGHT_BUILDS.has(key) else "build"


## Crew seconds for one building of type key, from the order to the opening.
static func build_crew_seconds(key: String) -> float:
	var plan := build_plan(key)
	var ticks := maxi(build_ticks(key), (SITE_STAGES[plan] as Array).size())
	return clampf(crew_seconds(plan, ticks), CREW_JOB_MIN_S, CREW_MAX_S)


static func is_power_plant(kind: int) -> bool:
	return kind == COAL or kind == SOLAR or kind == WIND


static func building_key_for_kind(kind: int) -> String:
	for key: String in BUILDINGS.keys():
		if int(BUILDINGS[key]["kind"]) == kind:
			return key
	return ""


static func mayor_index(mayor_id: String) -> int:
	for i in range(MAYORS.size()):
		if str(MAYORS[i]["id"]) == mayor_id:
			return i
	return -1


## Human display name of mayor mi ("" when out of range).
static func mayor_display(mi: int) -> String:
	if mi < 0 or mi >= MAYORS.size():
		return ""
	return str(MAYORS[mi]["display"])


## Compiled once: per mayor [brand-with-suffix RegEx, bare-word RegEx].
static var _debrand_res: Array = []


## Replaces model branding in free text (LLM output, replay cache, old saves) with display names:
## model ids (D.MAYORS[*].model) and brand names (D.MAYORS[*].name, also with a trailing ".x" or
## "-Flash" style suffix) become the display name; a bare brand word (Argon|DeepSeek|Kimi|Qwen|Grok,
## case-sensitive, whole word) becomes "Mayor <Surname>".
static func debrand(text: String) -> String:
	if text.is_empty():
		return text
	if _debrand_res.is_empty():
		for m: Dictionary in MAYORS:
			var brand := str(m["name"])
			var word := brand.get_slice("-", 0)
			var full := RegEx.create_from_string("\\b%s(?:\\.\\d+)*(?:-(?:[A-Z][A-Za-z0-9]*|\\d[A-Za-z0-9.]*))*\\b" % _regex_escape(brand))
			var bare := RegEx.create_from_string("\\b%s\\b" % _regex_escape(word))
			_debrand_res.append([full, bare])
	# Fast path: every pattern below contains a model id or a bare brand word.
	var hit := false
	for m: Dictionary in MAYORS:
		if text.contains(str(m["model"])) or text.contains(str(m["name"]).get_slice("-", 0)):
			hit = true
			break
	if not hit:
		return text
	var out := text
	for m: Dictionary in MAYORS:
		out = out.replace(str(m["model"]), str(m["display"]))
	for k in range(MAYORS.size()):
		out = (_debrand_res[k][0] as RegEx).sub(out, str(MAYORS[k]["display"]), true)
	for k in range(MAYORS.size()):
		var display := str(MAYORS[k]["display"])
		out = (_debrand_res[k][1] as RegEx).sub(out, "Mayor " + display.get_slice(" ", display.get_slice_count(" ") - 1), true)
	return out


static func _regex_escape(s: String) -> String:
	var out := ""
	for c in s:
		out += ("\\" + c) if c in ".^$*+?()[]{}|\\-/" else c
	return out


## Founding district layout: center 10x10 block for Kimi; four corner quadrants for the rest.
## Land outside the founding city belongs to nobody (-1) until a mayor annexes it.
static func district_of(x: int, y: int) -> int:
	if not in_core(x, y):
		return -1
	if x >= 11 and x <= 20 and y >= 11 and y <= 20:
		return 2
	if y < 16:
		return 0 if x < 16 else 1
	return 3 if x < 16 else 4


static func district_bounds(d: int) -> Rect2i:
	match d:
		0:
			return Rect2i(0, 0, 16, 16)
		1:
			return Rect2i(16, 0, 16, 16)
		2:
			return Rect2i(11, 11, 10, 10)
		3:
			return Rect2i(0, 16, 16, 16)
		_:
			return Rect2i(16, 16, 16, 16)
