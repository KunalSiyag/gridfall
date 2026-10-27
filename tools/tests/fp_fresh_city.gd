extends RefCounted
## The fresh-city fixture shared by the animals tests (fp_animals_test, fp_cats_test,
## fp_pigeons_test, fp_perches_test): a city with no growth (only the founding roads and City
## Hall, nobody built anywhere), wired like the grown fixture but stepped by hand, at noon. Each
## test turns the parts it needs on (the cats' blocking bodies, the walkers about for the dogs).
## wire() and quiet() are the grown tests' shared setup too.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const AF := preload("res://scripts/fp/animals/animals_feature.gd")
const PG := preload("res://scripts/fp/animals/pigeons.gd")
const CATS := preload("res://scripts/fp/animals/cats.gd")

const DT := 1.0 / 60.0


## A fresh-city context with the traffic and animals features set up headless: no ambient agents,
## no automatic stepping, noon. nodes() plus {"ctx", "traffic", "animals", "ok"} with ok false
## when a feature was missing.
static func make(root: Node) -> Dictionary:
	var ctx := K.make_ctx(root, {"view": true, "grow": false, "ticks": 0, "camera_mode": "third"})
	ctx.sim.start()
	var tr := K.make_feature(ctx, "traffic")
	var f := K.make_feature(ctx, "animals")
	var ok := tr != null and f != null
	if ok:
		wire(ctx, tr, f, Callable())
	var out := nodes(f)
	out.merge({"ctx": ctx, "traffic": tr, "animals": f, "ok": ok})
	return out


## The animals tests' grown city: make()'s fixture grown instead, the cats off (a stalking cat
## would send the flocks up; fp_cats_test has that), wired and quieted, every animal_called
## collected by on_call. nodes() plus {"ctx", "traffic", "animals", "ok"} with ok false when a
## feature was missing.
static func make_grown(root: Node, on_call: Callable) -> Dictionary:
	FeatureFlags.set_override("cats", false)
	var ctx := K.make_ctx(root, {"view": true, "grow": true, "camera_mode": "third"})
	ctx.player.set_process(false)
	var tr := K.make_feature(ctx, "traffic")
	var f := K.make_feature(ctx, "animals")
	var ok := tr != null and f != null
	if ok:
		wire(ctx, tr, f, on_call)
		quiet(ctx, tr)
	var out := nodes(f)
	out.merge({"ctx": ctx, "traffic": tr, "animals": f, "ok": ok})
	return out


## The animals tests' shared opening: make_grown() with every animal_called collected into calls
## and the common fixture check made. When a feature was missing the test is finished (tree,
## token, fails) and {} returned; else the fixture ({"ctx", "traffic", "animals", "ok"} plus
## nodes()).
static func open_grown(tree: SceneTree, token: String, fails: Array, calls: Array) -> Dictionary:
	var fx := make_grown(
		tree.get_root(), func(_at: Vector3, c: String, _s: float) -> void: calls.append(c)
	)
	K.check(fails, bool(fx["ok"]), "fixture: traffic and animals registered")
	if not bool(fx["ok"]):
		K.finish(tree, token, fails)
		return {}
	return fx


## Nobody in the city lives with a dog but the caller's own owners (the dogs tests' and the
## wildlife proof's shared fixture).
static func no_dogs_at_home(ctx: FpContext) -> void:
	for r: Dictionary in ctx.residents.people:
		if str(r.get("household", "")) == AF.DOG_HOUSEHOLD:
			r["household"] = "lives alone"


## The k-th resident with a home, made to live with a dog and to be out (state).
static func dog_owner(ctx: FpContext, k: int, state: String) -> Dictionary:
	var n := 0
	for r: Dictionary in ctx.residents.people:
		if int(r.get("home", -1)) < 0:
			continue
		if n == k:
			r["household"] = AF.DOG_HOUSEHOLD
			r["state"] = state
			return r
		n += 1
	return {}


## The first perch spot of the grown city (a street's lamp or a built lot's roof edge), with where
## the player stands by it (the road before the lot), else {}.
static func perch_spot(ctx: FpContext, pr: Node) -> Dictionary:
	for i in range(ctx.sim.kind.size()):
		var s: Dictionary = pr.call("_spot_of", i)
		if s.is_empty():
			continue
		var stand := Vector3(D.tx(i), 0.0, D.ty(i))
		if str(s["key"]).begins_with("roof:"):
			var fr: int = ctx.directory.frontage(i)
			if fr < 0:
				continue
			stand = Vector3(D.tx(fr), 0.0, D.ty(fr))
		var g := ctx.collision.walk_height(stand)
		stand.y = g if not is_nan(g) else 0.0
		s["stand"] = stand
		return s
	return {}


## The animals feature's nodes, collected: {"pigeons" (its node), "flock", "perches" (its node),
## "waterfowl" (its node), "cats" (its node), "life", "squirrels" (its node), "sq_life", "pack",
## "bodies" (the dogs')}.
static func nodes(f: FpFeature) -> Dictionary:
	var pigeons: PG = f.get("pigeons") if f != null else null
	var cats: CATS = f.get("cats") if f != null else null
	var sq: Node = f.get("squirrels") if f != null else null
	return {
		"pigeons": pigeons,
		"flock": pigeons.flock if pigeons != null else null,
		"perches": f.get("perches") if f != null else null,
		"waterfowl": f.get("waterfowl") if f != null else null,
		"cats": cats,
		"life": cats.life if cats != null else null,
		"squirrels": sq,
		"sq_life": sq.get("life") if sq != null else null,
		"pack": f.get("pack") if f != null else null,
		"bodies": f.get("bodies") if f != null else null,
	}


## Steps the traffic and the animals feature secs (in 1/60 s steps).
static func step(tr: FpFeature, f: FpFeature, secs: float) -> void:
	for _k in range(ceili(secs / DT - 1e-6)):
		tr.call("step", DT)
		f.call("tick", DT)


## The animals tests' wiring once their features are made: no ambient traffic, no automatic
## stepping, the animals feature and the player frozen, noon, and every animal_called collected by
## on_call (an invalid Callable skips the listening).
static func wire(ctx: FpContext, tr: FpFeature, f: FpFeature, on_call: Callable) -> void:
	tr.set("auto_step", false)
	tr.set("ambient_enabled", false)
	f.set_process(false)
	ctx.player.set_process(false)
	ctx.sky.fixed_hour = 12.0
	ctx.sky.hour = 12.0
	ctx.sky.night = 0.0
	if on_call.is_valid():
		ctx.bus.animal_called.connect(on_call)


## Nobody walks about and nobody lives with a dog, so only a test's own frights are about.
static func quiet(ctx: FpContext, tr: FpFeature) -> void:
	var wk: WK = tr.get("walkers")
	for w: WK.Walker in wk.walkers.duplicate():
		wk.remove(w)
	for r: Dictionary in ctx.residents.people:
		if str(r.get("household", "")) == AF.DOG_HOUSEHOLD:
			r["household"] = "lives alone"


## Turns the weather on ("rain") or off ("clear") for the animals feature: the fixture has no
## streetscape, so one is made on first use (the feature the animals read the rain from). Returns
## the streetscape feature, or null when there is none registered.
static func force_weather(ctx: FpContext, state: String) -> FpFeature:
	var st := ctx.feature("streetscape")
	if st == null:
		st = K.make_feature(ctx, "streetscape")
	if st == null:
		return null
	st.call("force_weather", state)
	return st


## The rain gate every diurnal-animal test shares: in the rain none of them comes out (they
## shelter); once it clears they come back. what names the animal, count returns how many are out
## now. Records the checks on fails.
static func rain_gate(
	ctx: FpContext, tr: FpFeature, f: FpFeature, fails: Array, what: String, count: Callable
) -> void:
	var st := force_weather(ctx, "rain")
	K.check(fails, st != null, "rain: the streetscape the animals read the weather from")
	if st == null:
		return
	step(tr, f, AF.SCAN_S + 0.2)
	var raining := int(count.call())
	force_weather(ctx, "clear")
	step(tr, f, AF.SCAN_S + 0.2)
	K.check(fails, raining == 0, "rain: no %s in the rain" % what)
	K.check(fails, int(count.call()) > 0, "rain: once it clears they come back")
