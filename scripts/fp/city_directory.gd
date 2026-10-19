class_name CityDirectory
extends RefCounted
## Human place names for the city: streets for road runs, addresses for lots, business and
## landmark names, district names. Deterministic from sim.city_seed; never uses sim.rng.

const D := preload("res://scripts/sim/sim_defs.gd")
const STREET_NAMES := [
	"Maple", "Oak", "Cedar", "Birch", "Willow", "Elm", "Pine", "Aspen", "Chestnut", "Laurel", "Juniper",
	"Hawthorn", "Magnolia", "Sycamore", "Poplar", "Alder", "Linden", "Spruce", "Hazel", "Rowan", "Cypress",
	"Acacia", "Beech", "Holly", "Ivy", "Mulberry", "Hickory", "Walnut", "Orchard", "Meadow", "Harbor",
	"River", "Canal", "Mill", "Market", "Station", "Union", "Liberty", "Garden", "Lake", "Bridge", "Church",
	"School", "Park", "Spring", "Summit", "Valley", "Granite", "Copper", "Foundry", "Quarry", "Ferry",
	"Lantern", "Beacon", "Harvest", "Prospect", "Highland", "Clover", "Fern", "Heather", "Sparrow", "Wren",
	"Lark", "Kestrel",
]
const AVENUE_NAMES := [
	"Addison", "Barrett", "Calloway", "Delgado", "Easton", "Fairview", "Grafton", "Halsey", "Irving",
	"Jefferson", "Kensington", "Lindgren", "Monroe", "Newton", "Prescott", "Quincy", "Ramsey", "Sterling",
	"Thornton", "Underwood", "Vance", "Whitman", "Yardley", "Abbott", "Bellamy", "Carver", "Dalton",
	"Ellison", "Fletcher", "Garrison", "Holloway", "Ingram", "Kingsley", "Lowell", "Mercer", "Nash",
	"Osborne", "Pemberton", "Radcliffe", "Sinclair", "Tolliver", "Upton", "Vickers", "Wexford", "York",
	"Ashby", "Brennan", "Colby", "Dorsey", "Emerson", "Finch", "Gideon", "Harlow", "Ives", "Jarvis",
	"Keller", "Langley", "Merritt", "Norwood", "Oakley", "Porter", "Rutherford", "Sheridan", "Talbot",
]
const SURNAMES := [
	"Alvarez", "Brooks", "Chen", "Dubois", "Edwards", "Fischer", "Garcia", "Haddad", "Ito", "Jensen",
	"Kowalski", "Lopez", "Moreau", "Nakamura", "O'Brien", "Patel", "Quinn", "Rossi", "Silva", "Tanaka",
	"Usman", "Varga", "Weber", "Xu", "Yilmaz", "Zhou", "Bianchi", "Costa", "Dimitrov", "Eriksen",
	"Ferreira", "Grant", "Hughes", "Ivanova", "Jovanovic", "Kim", "Larsen", "Mensah", "Novak", "Ortega",
	"Popescu", "Reyes", "Sato", "Torres", "Ueda", "Volkov", "Walsh", "Young",
]
const ADJECTIVES := ["Golden", "Blue", "Corner", "Little", "Lucky", "Green", "Daily", "Bright", "Copper", "Silver", "Red Door", "Old Town"]
const KINDS := {
	D.ZONE_C: {
		1: ["Cafe", "Bakery", "Bookshop", "Florist", "Diner", "Barbershop", "Deli", "Pharmacy", "Hardware", "Laundromat", "Noodle Bar", "Corner Store"],
		2: ["Market", "Bistro", "Fitness Club", "Dental Clinic", "Savings Bank", "Cinema", "Design Studio", "Electronics", "Hotel", "Tailors"],
		3: ["Tower", "Plaza", "Center", "Exchange", "Building"],
	},
	D.ZONE_I: {
		1: ["Workshop", "Garage", "Print Works", "Joinery", "Auto Repair"],
		2: ["Warehouse", "Foundry", "Logistics", "Bottling Plant", "Textiles"],
		3: ["Works", "Manufacturing", "Steel", "Chemicals", "Assembly Plant"],
	},
}
const LANDMARK_SUFFIX := {
	D.POLICE: "Police Station", D.HOSPITAL: "General Hospital", D.SCHOOL: "Elementary School",
	D.COAL: "Power Station", D.SOLAR: "Solar Farm", D.PUMP: "Water Works", D.SEWAGE: "Treatment Plant",
	D.WIND: "Wind Farm", D.TRAIN: "Station", D.LANDFILL: "Recycling Yard",
}
## Contiguous road tiles counted in each direction when measuring a run.
const RUN_CAP := 32
const _N4 := [Vector2i(0, 1), Vector2i(1, 0), Vector2i(0, -1), Vector2i(-1, 0)]   # S, E, N, W: frontage tie order

var sim: CitySim
var _perm_h := PackedInt32Array()
var _perm_v := PackedInt32Array()


## Binds the sim and builds the seed permutations.
func setup(p_sim: CitySim) -> void:
	sim = p_sim
	rebuild()


## Recomputes the seed-dependent permutations (call after load / New City; cheap).
func rebuild() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = sim.city_seed * 7907 + 11
	_perm_h = _shuffle(rng, STREET_NAMES.size())
	_perm_v = _shuffle(rng, AVENUE_NAMES.size())


## Name of the street a road tile belongs to ("Maple Street", "Delgado Avenue"); for a junction the
## name of its longer run. "" for non-road tiles.
func street_name(i: int) -> String:
	if not _is_road_idx(i):
		return ""
	var x := D.tx(i)
	var y := D.ty(i)
	var m := RoadTopology.mask(sim, x, y)
	var ew := (m & RoadTopology.EW) != 0 or m == 0
	var ns := (m & RoadTopology.NS) != 0
	if ew and ns:
		ew = _run_len(x, y, true) >= _run_len(x, y, false)
	return _ew_name(y) if ew else _ns_name(x)


## "Maple Street & Delgado Avenue" for junction tiles (3+ arms), else street_name(i).
func intersection_name(i: int) -> String:
	if not _is_road_idx(i):
		return ""
	var m := RoadTopology.mask(sim, D.tx(i), D.ty(i))
	if RoadTopology.arms(m).size() < 3:
		return street_name(i)
	var first := street_name(i)
	var ew := _ew_name(D.ty(i))
	var ns := _ns_name(D.tx(i))
	return "%s & %s" % [first, ns if first == ew else ew]


## The road tile lot i fronts (4-neighbour ROAD with the longest run; ties S, E, N, W), or -1.
func frontage(i: int) -> int:
	if i < 0 or i >= sim.kind.size():
		return -1
	var x := D.tx(i)
	var y := D.ty(i)
	var best := -1
	var best_len := 0
	for dv: Vector2i in _N4:
		var nx := x + dv.x
		var ny := y + dv.y
		if not D.in_bounds(nx, ny) or sim.kind[D.idx(nx, ny)] != D.ROAD:
			continue
		# A lot north or south of the road faces its E-W run; east or west faces its N-S run.
		var n := _run_len(nx, ny, dv.y != 0)
		if n > best_len:
			best_len = n
			best = D.idx(nx, ny)
	return best


## Yaw in degrees that turns a model's +Z face toward frontage(i) (S=0, E=90, N=180, W=-90); NAN if none.
func frontage_yaw(i: int) -> float:
	var f := frontage(i)
	if f < 0:
		return NAN
	var dx := D.tx(f) - D.tx(i)
	var dy := D.ty(f) - D.ty(i)
	if dy > 0:
		return 0.0
	if dx > 0:
		return 90.0
	if dy < 0:
		return 180.0
	return -90.0


## "214 Maple Street" for a lot with frontage; "" otherwise.
func address(i: int) -> String:
	var f := frontage(i)
	if f < 0 or _is_road_idx(i):
		return ""
	var faces_ew := D.ty(f) != D.ty(i)
	var along := D.tx(i) - D.X0 if faces_ew else D.ty(i) - D.Y0
	# side 1: the lot is north or west of the street.
	var side := 1 if (D.ty(f) > D.ty(i) or D.tx(f) > D.tx(i)) else 2
	return "%d %s" % [along * 4 + side, _faced_street(i, f)]


## Business name for a ZONE_C / ZONE_I tile at level > 0 ("Alvarez's Bakery"), else "".
func business_name(i: int) -> String:
	if not _valid(i):
		return ""
	return _business(i, sim.kind[i], sim.level[i])


## "bakery", "warehouse", ... for C/I lots at level > 0, else "".
func business_kind(i: int) -> String:
	if not _valid(i):
		return ""
	var k := sim.kind[i]
	var l := sim.level[i]
	if (k != D.ZONE_C and k != D.ZONE_I) or l <= 0:
		return ""
	var list: Array = KINDS[k][clampi(l, 1, 3)]
	return str(list[_hash(i, k, l) % list.size()]).to_lower()


## Landmark name for a service tile ("GridFall City Hall", "Maple Street Fire Station"), else "".
func landmark_name(i: int) -> String:
	if not _valid(i):
		return ""
	return _landmark(i, sim.kind[i], sim.level[i])


## Best name for a tile: landmark, business, apartment name (R2/R3 "Maple Court"), else "".
func place_name(i: int) -> String:
	if not _valid(i):
		return ""
	return _name_for(i, sim.kind[i], sim.level[i])


## Best label for a tile: place_name, else address, else street_name, else district_name.
func place_label(i: int) -> String:
	if not _valid(i):
		return "the frontier"
	var s := place_name(i)
	if not s.is_empty():
		return s
	if _is_road_idx(i):
		s = street_name(i)
		return s + " Bridge" if RoadTopology.is_bridge(sim, i) else s
	s = address(i)
	if not s.is_empty():
		return s
	return district_name(i)


## District name: D.MAYORS[d]["district"] for claimed land, "the river" on water, else "the frontier".
func district_name(i: int) -> String:
	if not _valid(i):
		return "the frontier"
	var d := sim.district[i]
	if d >= 0 and d < D.MAYORS.size():
		return str(D.MAYORS[d]["district"])
	if sim.terrain[i] == D.WATER:
		return "the river"
	return "the frontier"


## Mayor display name for district d (D.MAYORS[d]["display"]), "" for d < 0.
func mayor_display(d: int) -> String:
	return D.mayor_display(d)


## Street label for a world point: road -> intersection_name; lot -> its frontage street; else the
## nearest road within 2 tiles; else district_name.
func street_at(p: Vector3) -> String:
	var x := roundi(p.x)
	var y := roundi(p.z)
	if not D.in_bounds(x, y):
		return "the frontier"
	var i := D.idx(x, y)
	if _is_road_idx(i):
		return intersection_name(i)
	var f := frontage(i)
	if f >= 0:
		return _faced_street(i, f)
	var best := -1
	var best_d := 1e9
	for dy in range(-2, 3):
		for dx in range(-2, 3):
			if not D.in_bounds(x + dx, y + dy):
				continue
			var j := D.idx(x + dx, y + dy)
			if sim.kind[j] != D.ROAD:
				continue
			var d := Vector2(x + dx - p.x, y + dy - p.z).length_squared()
			if d < best_d:
				best_d = d
				best = j
	if best >= 0:
		return street_name(best)
	return district_name(i)


## The name tile i will carry once a construction site finishes as (target_kind, target_level):
## the same rules as landmark_name / business_name / place_name, computed for the target instead
## of the current kind. "" when the target has no name (roads, R1 houses, demolition).
func planned_name(i: int, target_kind: int, target_level: int) -> String:
	if not _valid(i):
		return ""
	return _name_for(i, target_kind, target_level)


# ------------------------------------------------------------------ internals

func _name_for(i: int, k: int, l: int) -> String:
	var s := _landmark(i, k, l)
	if not s.is_empty():
		return s
	s = _business(i, k, l)
	if not s.is_empty():
		return s
	return _apartment(i, k, l)


func _landmark(i: int, k: int, l: int) -> String:
	match k:
		D.HALL:
			return "GridFall City Hall"
		D.STADIUM:
			return "GridFall Arena"
		D.UNIVERSITY:
			return "University of GridFall"
		D.AIRPORT:
			return "GridFall International Airport"
		D.PARK:
			return "%s Park" % _short_or_district(i)
		D.FIRE:
			return "Fire Station No. %d" % (1 + _hash(i, k, l) % 60)
	if LANDMARK_SUFFIX.has(k):
		return "%s %s" % [_short_or_district(i), LANDMARK_SUFFIX[k]]
	return ""


func _business(i: int, k: int, l: int) -> String:
	if (k != D.ZONE_C and k != D.ZONE_I) or l <= 0:
		return ""
	var lv := clampi(l, 1, 3)
	var h := _hash(i, k, l)
	var list: Array = KINDS[k][lv]
	var kind_word := str(list[h % list.size()])
	var tpl := (h >> 8) % 4
	var sur := str(SURNAMES[(h >> 12) % SURNAMES.size()])
	if lv >= 3:
		return "%s %s" % [sur if tpl % 2 == 0 else _short_or_district(i), kind_word]
	match tpl:
		0:
			return "%s's %s" % [sur, kind_word]
		1:
			return "%s %s" % [_short_or_district(i), kind_word]
		2:
			return "The %s %s" % [ADJECTIVES[(h >> 16) % ADJECTIVES.size()], kind_word]
	var k2 := (h >> 20) % SURNAMES.size()
	if str(SURNAMES[k2]) == sur:
		k2 = (k2 + 1) % SURNAMES.size()
	return "%s & %s %s" % [sur, SURNAMES[k2], kind_word]


func _apartment(i: int, k: int, l: int) -> String:
	if k != D.ZONE_R or l < 2:
		return ""
	var h := _hash(i, k, l)
	var tpl := (h >> 8) % 4
	if tpl == 2 and l < 3:
		tpl = 0
	match tpl:
		0:
			return "%s Court" % _short_or_district(i)
		1:
			return "%s House" % SURNAMES[(h >> 12) % SURNAMES.size()]
		2:
			return "%s Towers" % _short_or_district(i)
	return "The %s Apartments" % ADJECTIVES[(h >> 16) % ADJECTIVES.size()]


## The frontage street name without its suffix ("Maple", "North Maple"), else the district's first word.
func _short_or_district(i: int) -> String:
	var f := frontage(i)
	if f >= 0:
		var s := _faced_street(i, f)
		var cut := s.rfind(" ")
		return s.left(cut) if cut > 0 else s
	var dn := district_name(i)
	if dn.begins_with("the "):
		dn = dn.substr(4).capitalize()
	return dn.get_slice(" ", 0)


## The street of the run lot i faces at road tile f: the E-W run when f is north or south of the lot.
func _faced_street(i: int, f: int) -> String:
	return _ew_name(D.ty(f)) if D.ty(f) != D.ty(i) else _ns_name(D.tx(f))


func _ew_name(y: int) -> String:
	var r := y - D.Y0
	var band: String = ["North ", "", "South "][clampi(floori(r / 64.0), 0, 2)]
	return "%s%s Street" % [band, STREET_NAMES[_perm_h[posmod(r, 64)]]]


func _ns_name(x: int) -> String:
	var c := x - D.X0
	var band: String = ["West ", "", "East "][clampi(floori(c / 64.0), 0, 2)]
	return "%s%s Avenue" % [band, AVENUE_NAMES[_perm_v[posmod(c, 64)]]]


## Length of the contiguous road run through (x, y): horizontal = the E-W run, else N-S.
func _run_len(x: int, y: int, horizontal: bool) -> int:
	var n := 1
	var step := Vector2i(1, 0) if horizontal else Vector2i(0, 1)
	for s: int in [1, -1]:
		for k in range(1, RUN_CAP + 1):
			var nx := x + step.x * k * s
			var ny := y + step.y * k * s
			if not D.in_bounds(nx, ny) or sim.kind[D.idx(nx, ny)] != D.ROAD:
				break
			n += 1
	return n


func _hash(i: int, k: int, l: int) -> int:
	return _mix(sim.city_seed, i, k * 10 + l)


static func _mix(a: int, b: int, c: int) -> int:
	return absi((a * 73856093) ^ (b * 19349663) ^ (c * 83492791)) & 0x7fffffff


static func _shuffle(rng: RandomNumberGenerator, n: int) -> PackedInt32Array:
	var p := PackedInt32Array()
	p.resize(n)
	for k in range(n):
		p[k] = k
	for k in range(n - 1, 0, -1):
		var j := rng.randi_range(0, k)
		var t := p[k]
		p[k] = p[j]
		p[j] = t
	return p


func _valid(i: int) -> bool:
	return sim != null and i >= 0 and i < sim.kind.size()


func _is_road_idx(i: int) -> bool:
	return _valid(i) and sim.kind[i] == D.ROAD
