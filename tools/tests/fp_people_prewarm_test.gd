extends SceneTree
## people.gd's body-scene warming: a dressed ambient walker's scene is requested at dress time
## (threaded builds), the ambient set can pre-warm in one pass at world build (the no-threads
## web export loads synchronously -- a cold seat there would parse a glb mid-frame), and a seat
## after warming never initiates another load.

const K := preload("res://tools/tests/fp_kit.gd")
const FIX := preload("res://tools/tests/support/props_fixture.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")


func _init() -> void:
	K.watchdog(self, "FP_PEOPLE_PREWARM_TEST")
	var fails: Array[String] = []
	var m: Dictionary = FIX.make(get_root())
	var tr: Variant = m.get("tr")
	if tr == null:
		K.check(fails, false, "fixture: the traffic feature")
		K.finish(self, "FP_PEOPLE_PREWARM_TEST", fails)
		return
	var pe: Variant = tr.get("people")
	var wk: WK = tr.get("walkers")

	# The ambient pre-warm caches every ambient avatar's body scene, each loaded at most once.
	var before: int = pe.get("scene_loads")
	pe.call("_prewarm_ambient")
	var seen: Dictionary = {}
	var missing: int = 0
	for gw: Array in pe.get("_amb_groups"):
		for ai: int in gw[1]:
			var path: String = (pe.get("avatars")[ai] as RefCounted).get("path")
			if seen.has(path):
				continue
			seen[path] = true
			if not (pe.get("_scenes") as Dictionary).has(path):
				missing += 1
	K.check(fails, seen.size() > 0, "fixture: an ambient avatar set (%d scenes)" % seen.size())
	K.check(
		fails,
		missing == 0,
		"the pre-warm caches every ambient scene (missing %d of %d)" % [missing, seen.size()]
	)
	var warmed: int = pe.get("scene_loads") - before
	K.check(
		fails,
		warmed <= seen.size(),
		"the pre-warm loads each ambient scene at most once (%d for %d)" % [warmed, seen.size()]
	)

	# A dressed ambient walker's scene is already warm: dressing (which kicks the request) and
	# seating add no load initiations.
	var w: WK.Walker = wk.make("ambient")
	pe.call("dress", w, null)
	K.check(fails, w.av >= 0, "dress picks an ambient avatar")
	pe.call("finish_loads")
	var settled: int = pe.get("scene_loads")
	K.check(fails, pe.call("seat", w), "the warmed driver seats")
	K.check(
		fails,
		pe.get("scene_loads") == settled,
		"a seat after warming initiates no load (still %d)" % settled
	)

	# The body a seat lends runs its skeleton modifiers (the T0 head look) on the idle frame
	# with the hand-advanced mixers, not once per physics frame (web catch-up multiplies that).
	var seated: Array = (pe.get("_pool") as RefCounted).get("_seated")
	var sk := (seated[0].get("skel") if not seated.is_empty() else null) as Skeleton3D
	K.check(
		fails,
		(
			sk != null
			and sk.modifier_callback_mode_process == Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_IDLE
		),
		"a seated body's modifiers run on the idle frame, not once per physics frame"
	)
	K.finish(self, "FP_PEOPLE_PREWARM_TEST", fails)
