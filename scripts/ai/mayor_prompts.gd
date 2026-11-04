extends RefCounted
## The mayors' turn prompts, moved out of CityBrain (which keeps thin wrappers). system() is the
## rules and the reply schema, user() the day's state for one mayor. With the mayor_context_v2
## flag off the text is exactly what CityBrain built before the move (a golden test pins it);
## with it on, MayorContext adds the council, operator, chaos and league lines, the notes between
## mayors and the extra reply fields. Pure reads: nothing here changes the brain or the sim.

const D := preload("res://scripts/sim/sim_defs.gd")
const MayorContext := preload("res://scripts/ai/mayor_context.gd")
const ANNEX_HEAD := (
	"LAND YOU CAN ANNEX (top-left x,y of each 16x16 plot, " + "price, open/forest/water tiles): "
)


# gdlint: disable=max-line-length
## The system prompt for mayor mi: persona, rules, actions and the reply schema.
static func system(mi: int) -> String:
	var m: Dictionary = D.MAYORS[mi]
	var ord_keys := ", ".join(PackedStringArray(D.ORDINANCES.keys()))
	var text := (
		"%s\n" % m["persona"]
		+ """You are one of the five elected mayors of GridFall, a SimCity-style city. Each mayor controls ONLY their own district. Once per in-game day you return ONE JSON object of decisions.
RULES
- Zoned land grows buildings only when: a road is within 2 tiles, the tile is connected to power, and demand for that zone type is positive. Power flows from plants through roads and touching buildings. Water (pumps) is required for density 2+. High land value (parks, schools, low pollution, near the river) allows density 3.
- Power plants, water pumps and sewage plants serve the WHOLE connected city. coal_plant: 140 MW, $3000, heavy pollution. solar_farm: 45 MW, $1600, clean. water_pump: $900, 90 units (x1.5 within 2 tiles of the river), needs power. sewage_plant: $1300, 120 units, needs power; if city sewage capacity is short, pollution and unhappiness rise everywhere.
- Services cover a radius: police $750 (crime), fire_station $750 (fires spread less), hospital $1200 (health), school $950 (land value, commercial density), park $120 (land value, cuts pollution).
- Big projects: wind_farm $2200 (70 MW, clean, +25% near the river or map edge), landfill $1000 (160 waste capacity for the WHOLE city; without enough landfill, trash raises pollution and unhappiness once the city grows; it pollutes nearby), train_station $1800 (cuts traffic and raises land value within 8 tiles), university $3200 (strong education radius 11, +R and +C demand), stadium $4000 (happiness and land value radius 10, +C demand), airport $6000 (+0.15 C and I demand citywide, 30 jobs, noisy pollution, needs 8 MW).
- The people are AI residents with their own minds. They choose whether to go to work, how to commute, where to spend, whether to help fix what breaks, whether to protest, and whether to move away. Unhappy residents leave, which empties homes and shrinks your tax base. Incidents (fires, broken water mains, downed power lines, crashes...) stay broken until residents and paid crews put in enough repair work.
- Daily income = income tax on what your residents earned plus sales tax on what they spent in your shops, plus industry. Upkeep = buildings + roads + share of ordinances. Taxes above ~9% slow growth and anger residents. You cannot go below -$2000.
- Costs: road $10/tile ($50 on water), zone $5/tile, bulldoze $5/tile, emergency crews $300.
- Road grades: a road order may set "grade". paved ($10/tile, upkeep 0.15) is the default; gravel ($6, upkeep 0.08, 70% speed) only lets nearby lots reach density 2; dirt ($3, upkeep 0.04, half speed) and trail ($1, upkeep 0.01, a third of the speed) only density 1. Bridges are always paved. A lot grows as dense as its best road within 2 tiles allows. Ordering a better grade over an existing rougher road resurfaces it (the road closes while crews work). Cheap tracks open new land quickly; pave them as the district densifies.
- Construction takes time. A build order opens a construction site (+ on the map, listed under under_construction) that your paid contractors work through in stages: clearing, excavation, foundation, frame, finishing. A building does nothing until it is finished: a park takes about 1 day, a police station about 3, a hospital about 4, a coal plant about 9, a stadium about 12, an airport about 15. Roads open after about a day, bridges after about 2.5 days. Private developers build zoned lots up the same way (houses about 2 days, towers about 6) and only run about 10 sites per district at once. Residents who are construction workers, electricians or engineers join nearby sites and finish them faster, but never more than about 1.6x. Plan ahead: order power and water before you need them. Bulldozing sends a demolition crew. Never order a building again while its site is still open.
- The city can grow: the founding city covers x,y 0..31 inside a wide frontier (x,y """
		+ "%d..%d" % [D.X0, D.X0 + D.W - 1]
		+ """) of unclaimed woods, lakes and the river. You may annex an unclaimed 16x16 plot that borders your district (LAND YOU CAN ANNEX lists them with prices); the price rises with each plot you add. Land is cheap, so keep claiming plots ahead of demand: surveyors map the frontier further out as the city grows. New land is empty: it needs roads connected to the city, power and zoning before anyone lives there.
ACTIONS (max 7 per day). Coordinates are absolute world coordinates x,y and must be inside your district (except annex).
 {"type":"road","x":X,"y":Y,"x2":X2,"y2":Y2,"grade":"paved|gravel|dirt|trail"}  straight or L-shaped (horizontal leg first), max 16 tiles; grade is optional (paved)
 {"type":"zone","zone":"R|C|I","x":X,"y":Y,"w":W,"h":H}  rectangle up to 6x6 on empty or forest land, top-left corner at x,y
 {"type":"build","building":"coal_plant|solar_farm|wind_farm|water_pump|sewage_plant|landfill|police|fire_station|hospital|school|park|train_station|university|stadium|airport","x":X,"y":Y}
 {"type":"bulldoze","x":X,"y":Y,"w":1,"h":1}
 {"type":"set_tax","r":0-20,"c":0-20,"i":0-20}
 {"type":"emergency","x":X,"y":Y}  pay $300 for city crews who work on incidents within 4 tiles for a few hours (adds repair work, does not end them instantly)
 {"type":"grant","to":"argon|deepseek|kimi|qwen|grok","amount":N}
 {"type":"annex","x":X,"y":Y}  buy the unclaimed 16x16 plot containing x,y (it must border your district)
Ordinance keys: """
		+ ord_keys
		+ """
Reply with ONLY this JSON object, no markdown:
{"thought":"your private reasoning, <=220 chars","public_post":"what you announce to citizens and other mayors, <=160 chars","mood":"one word","actions":[...],"propose_ordinance":"ordinance key or empty string","votes":{"ordinance_key":"yes or no"}}"""
	)
	return MayorContext.extend_system(text)


# gdlint: enable=max-line-length


## The user prompt for mayor mi on day: their district, the city, what the others said and decided.
static func user(brain: CityBrain, mi: int, day: int) -> String:
	var sim: CitySim = brain.sim
	var m: Dictionary = D.MAYORS[mi]
	var b := sim.district_rect(mi)
	var ms: Dictionary = brain.mayor_state[mi]
	var lines: Array[String] = []
	lines.append(
		(
			"DAY %d. You are %s, mayor of %s (district %d, x %d..%d, y %d..%d)."
			% [
				day,
				m["display"],
				m["district"],
				mi,
				b.position.x,
				b.end.x - 1,
				b.position.y,
				b.end.y - 1
			]
		)
	)
	lines.append("YOUR DISTRICT: " + JSON.stringify(sim.district_summary(mi)))
	lines.append("CITY: " + JSON.stringify(sim.city_summary()))
	lines.append("MAP OF YOUR DISTRICT (legend: %s):\n%s" % [D.MAP_LEGEND, sim.district_ascii(mi)])
	lines.append("OPEN LOTS NEXT TO ROADS [x,y]: " + JSON.stringify(sim.open_lots(mi, 14)))
	var plots: Array = sim.annexable_plots(mi)
	if not plots.is_empty():
		var shown: Array[String] = []
		for p: Dictionary in plots.slice(0, 5):
			var at := "(%d,%d) $%d %d/%d/%d"
			shown.append(at % [p["x"], p["y"], p["cost"], p["open_land"], p["forest"], p["water"]])
		lines.append(ANNEX_HEAD + JSON.stringify(shown))
	var res: Array = ms.get("results", [])
	if not res.is_empty():
		lines.append("YESTERDAY'S ACTION RESULTS: " + "; ".join(PackedStringArray(res)))
	var th: Array = ms.get("thoughts", [])
	if not th.is_empty():
		lines.append("YOUR RECENT THOUGHTS: " + " | ".join(PackedStringArray(th.slice(-2))))
	var others: Array[String] = []
	for oi in range(D.MAYORS.size()):
		if oi != mi and not str(brain.mayor_state[oi].get("post", "")).is_empty():
			others.append("%s: %s" % [D.MAYORS[oi]["display"], brain.mayor_state[oi]["post"]])
	if not others.is_empty():
		lines.append("OTHER MAYORS SAID: " + " || ".join(PackedStringArray(others)))
	var comp: Dictionary = brain.complaints[mi]
	if not comp.is_empty():
		lines.append("CITIZEN COMPLAINTS IN YOUR DISTRICT (count): " + JSON.stringify(comp))
	if sim.work_based():
		lines.append(
			(
				"YOUR RESIDENTS (each named resident speaks for about %d people): %s"
				% [int(sim.people.share), JSON.stringify(sim.people.district_mood(mi))]
			)
		)
		for msg: Variant in sim.people.messages_for(mi, 6):
			var md: Dictionary = msg
			lines.append(
				(
					'RESIDENT %s (%s, mood %d/10) WRITES TO YOU: "%s"'
					% [md["name"], md["job"], int(md["mood"]), D.debrand(str(md["text"]))]
				)
			)
	else:
		for v: Variant in brain.last_voices:
			var vd: Dictionary = v
			if int(vd.get("district", -1)) == mi:
				lines.append('A RESIDENT SAYS: "%s"' % D.debrand(str(vd.get("thought", ""))))
	if not brain.last_paper.is_empty():
		lines.append("TODAY'S GAZETTE HEADLINE: " + str(brain.last_paper.get("headline", "")))
	if not brain.proposals.is_empty():
		var pl: Array[String] = []
		for key: String in brain.proposals.keys():
			pl.append(
				(
					"%s (proposed by %s, votes %s)"
					% [
						key,
						brain.proposals[key]["by"],
						JSON.stringify(brain._votes_by_name(brain.proposals[key]["votes"]))
					]
				)
			)
		lines.append(
			"PENDING ORDINANCE PROPOSALS (vote yes/no): " + "; ".join(PackedStringArray(pl))
		)
	lines.append("ACTIVE ORDINANCES: " + JSON.stringify(sim.ordinances.keys()))
	if not brain.decree.is_empty() and sim.day - brain.decree_day <= 1:
		lines.append(
			(
				'MESSAGE FROM THE CITY OVERSEER (the human player) - take it seriously: "%s"'
				% brain.decree
			)
		)
	lines.append_array(MayorContext.user_lines(brain, mi, day))
	lines.append(
		"Decide today's actions now. Valid coordinates matter: rejected actions are wasted."
	)
	return "\n".join(lines)
