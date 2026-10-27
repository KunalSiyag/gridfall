extends RefCounted
## The web tier's animals density cap (quality.gd WEB_DENSITY "animals", flag web_quality) split
## over the animals feature's groups, and its application to the feature. Pulled out of
## animals_feature.gd for the 1000-line cap; split() is static and pure so the tests read it
## without a city.

const Q := preload("res://scripts/fp/render/quality.gd")
const CATS := preload("res://scripts/fp/animals/cats.gd")
const SQUIRRELS := preload("res://scripts/fp/animals/squirrels.gd")
const PIGEONS := preload("res://scripts/fp/animals/pigeons.gd")
const WATERFOWL := preload("res://scripts/fp/animals/waterfowl.gd")

## The dogs' desktop budget lives here so DESKTOP can read it without preloading the feature
## (which preloads this); animals_feature.gd aliases it.
const MAX_DOGS := 10
## The desktop budgets the web tier's animals cap splits between (split()). A flock counts as
## one group; its birds stay the flock's own budget.
const DESKTOP := {
	"dogs": MAX_DOGS,
	"cats": CATS.MAX_CATS,
	"squirrels": SQUIRRELS.MAX_SQUIRRELS,
	"pigeons": PIGEONS.MAX_FLOCKS,
	"ducks": WATERFOWL.MAX_FLOCKS,
}


## The web tier's animals cap split over the groups in proportion to their desktop budgets,
## largest remainder, so the small groups thin out first as the cap tightens; none ever gets
## more than its desktop budget, and cap 0 or less leaves nobody.
static func split(cap: int) -> Dictionary:
	var out := {}
	var total := 0
	for k in DESKTOP:
		total += DESKTOP[k]
		out[k] = 0
	if cap <= 0:
		return out
	var rem: Array = []
	var left := cap
	for k in DESKTOP:
		var e: float = float(cap) * int(DESKTOP[k]) / total
		out[k] = mini(int(e), DESKTOP[k])
		left -= out[k]
		rem.append([e - int(e), k])
	rem.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) > float(b[0]))
	for r in rem:
		if left <= 0:
			break
		if out[r[1]] < DESKTOP[r[1]]:
			out[r[1]] += 1
			left -= 1
	return out


## The split for the running build: the "animals" cap split over the groups on the web tier, {}
## off it (the feature then keeps every MAX_*).
static func capped() -> Dictionary:
	var caps := Q.density_caps()
	return split(int(caps["animals"])) if caps.has("animals") else {}


## The feature's ceilings from capped()'s split (a {} split is a no-op): the dogs', the cats'
## and the flock counts'. The squirrels' ceiling the feature sets itself before the squirrels'
## setup() — their MultiMesh sizes from it.
static func apply(f: Node, caps: Dictionary) -> void:
	if caps.is_empty():
		return
	f.set("max_dogs", int(caps["dogs"]))
	(f.get("cats") as Node).set("max_cats", int(caps["cats"]))
	(f.get("pigeons") as Node).set("max_flocks", int(caps["pigeons"]))
	(f.get("waterfowl") as Node).set("max_flocks", int(caps["ducks"]))
