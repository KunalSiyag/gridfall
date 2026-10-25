extends RefCounted
## The fresh-city fixture shared by the animals tests (fp_animals_test, fp_cats_test,
## fp_pigeons_test): a city with no growth (only the founding roads and City Hall, nobody built
## anywhere), wired like the grown fixture but stepped by hand, at noon. Each test turns the parts
## it needs on (the cats' blocking bodies, the walkers about for the dogs).

const K := preload("res://tools/tests/fp_kit.gd")
const PG := preload("res://scripts/fp/animals/pigeons.gd")
const CATS := preload("res://scripts/fp/animals/cats.gd")

const DT := 1.0 / 60.0


## A fresh-city context with the traffic and animals features set up headless: no ambient agents,
## no automatic stepping, noon. {"ctx", "traffic", "animals", "pigeons" (its node), "flock", "cats"
## (its node), "life", "pack", "bodies" (the dogs'), "ok"} with ok false when a feature was
## missing.
static func make(root: Node) -> Dictionary:
	var ctx := K.make_ctx(root, {"view": true, "grow": false, "ticks": 0, "camera_mode": "third"})
	ctx.sim.start()
	var tr := K.make_feature(ctx, "traffic")
	var f := K.make_feature(ctx, "animals")
	var ok := tr != null and f != null
	if ok:
		tr.set("auto_step", false)
		tr.set("ambient_enabled", false)
		f.set_process(false)
		ctx.player.set_process(false)
		ctx.sky.fixed_hour = 12.0
		ctx.sky.hour = 12.0
		ctx.sky.night = 0.0
	var pigeons: PG = f.get("pigeons") if f != null else null
	var cats: CATS = f.get("cats") if f != null else null
	return {
		"ctx": ctx,
		"traffic": tr,
		"animals": f,
		"pigeons": pigeons,
		"flock": pigeons.flock if pigeons != null else null,
		"cats": cats,
		"life": cats.life if cats != null else null,
		"pack": f.get("pack") if f != null else null,
		"bodies": f.get("bodies") if f != null else null,
		"ok": ok,
	}


## Steps the traffic and the animals feature secs (in 1/60 s steps).
static func step(tr: FpFeature, f: FpFeature, secs: float) -> void:
	for _k in range(ceili(secs / DT - 1e-6)):
		tr.call("step", DT)
		f.call("tick", DT)
