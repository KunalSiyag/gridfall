extends SceneTree
## people_pool.gd's lifecycle contract, pinned directly (the split moved the body pool and scene
## cache out of people.gd with only indirect coverage): the per-frame instancing budget, pooling
## reuse, seat/attach/detach bookkeeping, scene-cache ownership, clear(), and the weakref back.

const K := preload("res://tools/tests/fp_kit.gd")
const FIX := preload("res://tools/tests/support/props_fixture.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const POOL := preload("res://scripts/fp/traffic/people_pool.gd")


func _init() -> void:
	K.watchdog(self, "FP_PEOPLE_POOL_TEST")
	var fails: Array[String] = []
	var m: Dictionary = FIX.make(get_root())
	var tr: Variant = m.get("tr")
	if tr == null:
		K.check(fails, false, "fixture: the traffic feature")
		K.finish(self, "FP_PEOPLE_POOL_TEST", fails)
		return
	var pe: Variant = tr.get("people")
	var wk: WK = tr.get("walkers")
	var pool: Variant = pe.get("_pool")
	K.check(fails, pool != null, "fixture: people reaches its pool")
	if pool == null:
		K.finish(self, "FP_PEOPLE_POOL_TEST", fails)
		return
	pool.set("blocking", true)  # deterministic loads on the calling thread
	pool.call("clear")
	pool.call("begin_frame")

	# A dressed ambient walker picks the avatar the checks run against.
	var w: WK.Walker = wk.make("ambient")
	pe.call("dress", w, null)
	K.check(fails, w.av >= 0, "dress picks an ambient avatar")
	var ai: int = w.av
	# The pool pipeline never touches a body with an empty clip: _animate picks one first.
	w.anim_clip = w.idle_clip if w.idle_clip != &"" else &"talk"

	# The per-frame budget: a cold pool lends NEW_PER_FRAME new bodies, then no more until the
	# next frame.
	var lent: Array = []
	for _i in range(POOL.NEW_PER_FRAME):
		lent.append(pool.call("take", ai))
	K.check(
		fails, not lent.has(null), "a cold pool lends %d new bodies in a frame" % POOL.NEW_PER_FRAME
	)
	K.check(
		fails,
		pool.call("take", ai) == null,
		"the %dth take of the frame waits" % (POOL.NEW_PER_FRAME + 1)
	)
	pool.call("begin_frame")
	K.check(fails, pool.call("take", ai) != null, "the next frame's budget lends again")

	# Pooling: a released body is the next one lent, with no new load.
	for b: Variant in lent:
		if b != null:
			pool.call("release_body", b)
	pool.call("begin_frame")
	var loads: int = pool.get("scene_loads")
	var again: Variant = pool.call("take", ai)
	K.check(fails, again == lent[-1], "a released body is lent again (same instance)")
	K.check(fails, pool.get("scene_loads") == loads, "a pooled take initiates no load")

	# seat/detach bookkeeping: the body is lent out and visibly held until detached.
	K.check(fails, pool.call("seat", w), "seat lends a body")
	K.check(
		fails,
		w.body != null and (pool.get("_seated") as Array).has(w.body),
		"the seated body is held out of the pipeline"
	)
	K.check(fails, (w.body as RefCounted).get("root").visible, "the seated body is visible")
	pool.call("detach", w)
	K.check(
		fails,
		w.body == null and (pool.get("_seated") as Array).is_empty(),
		"detach returns the body and frees the walker"
	)

	# attach marks the body active for the frame; detach pulls it back out.
	K.check(fails, pool.call("attach", w, 1, 7), "attach lends within the budget")
	var b2: Variant = w.body
	K.check(
		fails,
		(pe.get("_active") as Array).has(b2) and b2.get("seen") == 7,
		"the attached body is active and stamped with the frame"
	)
	pool.call("detach", w)
	K.check(fails, not (pe.get("_active") as Array).has(b2), "detach deactivates the body")

	# The scene cache: one load per path, a missing path cached as null, nothing pending when
	# blocking.
	var path: String = (pe.get("avatars")[ai] as RefCounted).get("path")
	loads = pool.get("scene_loads")
	pool.call("scene", path)
	pool.call("scene", path)
	K.check(fails, pool.get("scene_loads") == loads, "a cached scene loads once")
	K.check(
		fails,
		(
			pool.call("scene", "res://models/characters/bodies/Nobody_00.glb") == null
			and pool.get("scene_loads") == loads
			and not pool.call("is_pending", path)
		),
		"a missing scene is cached as null without initiating a load"
	)

	# prewarm covers every ambient avatar, then idles over the warm cache.
	loads = pool.get("scene_loads")
	pool.call("prewarm_ambient", pe.get("_amb_groups"), pe.get("avatars"))
	K.check(
		fails, pool.get("scene_loads") > loads, "prewarm over a cold cache loads the ambient bodies"
	)
	loads = pool.get("scene_loads")
	pool.call("prewarm_ambient", pe.get("_amb_groups"), pe.get("avatars"))
	K.check(fails, pool.get("scene_loads") == loads, "prewarm over a warm cache loads nothing")

	# The back-ref is weak and live.
	K.check(fails, pool.call("_ppl") == pe, "the pool reaches its people through the weakref")

	# clear() frees pooled and lent bodies and resets the counters.
	pool.call("seat", w)
	pool.call("clear")
	K.check(
		fails,
		(
			pool.get("bodies_made") == 0
			and (pool.get("_seated") as Array).is_empty()
			and w.body == null
		),
		"clear frees the lent bodies and resets"
	)
	wk.remove(w)
	K.finish(self, "FP_PEOPLE_POOL_TEST", fails)
