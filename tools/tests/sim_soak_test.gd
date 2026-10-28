extends SceneTree
## The long-run soak: two seeds x 50 days of city growth with residents, minds and mayors, offline.
## Asserts the run stays on the calendar (every day lands), every bounded array stays inside its
## cap (no runaway growth), and the stats stay finite; prints one report-only line per seed with
## the end-state shape and a fingerprint hash for eyeball comparison across gate runs. Script
## errors during the soak fail the gate step itself. Every ten days the world is saved mid-day
## and reloaded (sim_save_kit's document/load_into_new), asserting the re-saved bytes are
## identical — the no-drift check over every saved field — and the soak continues in the loaded
## world, so a field that only drifts after many days is caught. Registered in tools/gate.sh full
## (not quick; it costs about a minute and a half). Prints SIM_SOAK_TEST: PASS|FAIL.

const SK := preload("res://tools/tests/sim_save_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")

const SEEDS := [7, 11]
const DAYS := 50
## Save/reload cadence in days; day 50 is skipped (nothing follows it, and the end-of-soak
## fingerprint already covers the final state).
const ROUNDTRIP_EVERY := 10

## Generous but leak-catching caps (the peaks a seed-7 soak reaches: sites 109, events 2; the rest
## are the code's own trims: history 120, log 200, messages 300, departed 40, people 100).
const MAX_SITES := 200
const MAX_EVENTS := 16
const MAX_HISTORY := 120
const MAX_LOG := 210
const MAX_MESSAGES := 320
const MAX_DEPARTED := 50

var fails: Array = []


func _init() -> void:
	await process_frame
	for seed_v: int in SEEDS:
		await _soak(seed_v)
		await process_frame
	print("SIM_SOAK_TEST: " + ("PASS" if fails.is_empty() else "FAIL " + str(fails)))
	quit(0 if fails.is_empty() else 1)


func check(ok: bool, what: String) -> void:
	if not ok:
		fails.append(what)
	print(("SIM_SOAK_TEST:   ok   " if ok else "SIM_SOAK_TEST:   FAIL ") + what)


func _soak(seed_v: int) -> void:
	var w := SK.make_world(get_root(), seed_v)
	var sim: CitySim = w["sim"]
	var people: Residents = w["people"]
	var day0 := sim.day
	var t0 := Time.get_ticks_msec()
	# The bounded arrays move during the day too (construction peaks mid-run), so the peaks are
	# tracked tick by tick, not just read off the end state.
	var peak := {"sites": 0, "events": 0, "messages": 0, "people": 0}
	for day_i in range(DAYS):
		for t in range(D.GROWTH_TICKS_PER_DAY):
			sim.step_tick()
			peak["sites"] = maxi(peak["sites"], sim.sites.size())
			peak["events"] = maxi(peak["events"], sim.events.size())
			peak["messages"] = maxi(peak["messages"], people.messages.size())
			peak["people"] = maxi(peak["people"], people.people.size())
			# Round-trip mid-day, when the world is quiescent: no day-end job in flight, no
			# day-gate hold. A boundary save would capture the gate-held world whose pending
			# day-start cascade runs on load instead (the designed resume path), so the loaded
			# world legitimately differs there; mid-day it must match byte for byte.
			if (
				t == D.GROWTH_TICKS_PER_DAY / 2
				and (day_i + 1) % ROUNDTRIP_EVERY == 0
				and day_i + 1 < DAYS
			):
				w = _roundtrip(w, seed_v, day_i + 1)
				sim = w["sim"]
				people = w["people"]
	var secs := (Time.get_ticks_msec() - t0) / 1000.0
	check(
		sim.day == day0 + DAYS,
		"seed %d: fifty days land on the calendar (day %d)" % [seed_v, sim.day]
	)

	# Bounded arrays, peaks included: a soak that grows without end is a leak, whatever the day
	# says.
	check(
		peak["sites"] <= MAX_SITES,
		"seed %d: open sites stay bounded (peak %d <= %d)" % [seed_v, peak["sites"], MAX_SITES]
	)
	check(
		peak["events"] <= MAX_EVENTS,
		"seed %d: events stay bounded (peak %d <= %d)" % [seed_v, peak["events"], MAX_EVENTS]
	)
	check(
		peak["messages"] <= MAX_MESSAGES,
		"seed %d: messages stay bounded (peak %d <= %d)" % [seed_v, peak["messages"], MAX_MESSAGES]
	)
	check(
		peak["people"] <= Residents.MAX_RESIDENTS,
		(
			"seed %d: residents stay at the cap (peak %d <= %d)"
			% [seed_v, peak["people"], Residents.MAX_RESIDENTS]
		)
	)
	check(
		sim.history.size() <= MAX_HISTORY,
		"seed %d: history stays at its cap (%d <= %d)" % [seed_v, sim.history.size(), MAX_HISTORY]
	)
	check(
		sim.log_lines.size() <= MAX_LOG,
		"seed %d: the log stays at its cap (%d <= %d)" % [seed_v, sim.log_lines.size(), MAX_LOG]
	)
	check(
		people.departed.size() <= MAX_DEPARTED,
		(
			"seed %d: the departed list stays bounded (%d <= %d)"
			% [seed_v, people.departed.size(), MAX_DEPARTED]
		)
	)

	# A living, finite city: no NaN may creep into the stats or a mayor's books.
	var stats: Dictionary = sim.stats
	check(
		(
			is_finite(float(stats.get("happiness", 0.0)))
			and is_finite(float(stats.get("population", 0.0)))
		),
		"seed %d: happiness and population stay finite" % seed_v
	)
	var books_ok := true
	for m: Dictionary in sim.mayors:
		if not is_finite(float(m.get("treasury", 0.0))):
			books_ok = false
	check(books_ok, "seed %d: every mayor's treasury stays finite" % seed_v)

	var counts := SK.counts(w)
	var fingerprint: int = JSON.stringify([sim.to_dict(), people.to_dict()]).hash()
	var head := (
		"SIM_SOAK seed=%d day=%d peak_sites=%d peak_events=%d zones=%d built=%d pop=%d"
		% [
			seed_v,
			sim.day,
			peak["sites"],
			peak["events"],
			counts[0],
			counts[1],
			int(stats.get("population", 0))
		]
	)
	var tail := (
		"people=%d departed=%d history=%d log=%d hash=%d static_kb=%d secs=%.0f"
		% [
			people.people.size(),
			people.departed.size(),
			sim.history.size(),
			sim.log_lines.size(),
			fingerprint,
			OS.get_static_memory_usage() / 1024,
			secs,
		]
	)
	print(head + " " + tail)
	SK.free_world(w)


## Saves the world mid-soak, reloads it into a fresh world, and returns the loaded world (the old
## one is freed). Asserts the reload is accepted, the re-saved bytes are identical, and the loaded
## state matches the pre-save state: a field that only misbehaves after many days (a counter that
## saturates, a relaxation that converges differently after a load) is caught here.
func _roundtrip(w: Dictionary, seed_v: int, day: int) -> Dictionary:
	var doc: Dictionary = JSON.parse_string(JSON.stringify(SK.document(w)))
	var w2: Dictionary = SK.load_into_new(get_root(), doc)
	check(bool(w2.get("ok", true)), "seed %d day %d: the mid-soak save reloads" % [seed_v, day])
	if not w2.get("ok", true):
		return w
	var doc2: Dictionary = JSON.parse_string(JSON.stringify(SK.document(w2)))
	check(
		JSON.stringify(doc2) == JSON.stringify(doc),
		"seed %d day %d: the re-saved bytes are identical" % [seed_v, day]
	)
	SK.free_world(w)
	return w2
