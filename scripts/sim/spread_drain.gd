class_name SpreadDrain
extends RefCounted
## Drain scheduler for the day-start work the sliced sim spreads over frames: the brain's day round
## (five mayors and the support roles) and the residents' plan batches each run ONE piece per frame
## (CityBrain._process, ResidentMinds._run_spread), about fifty frames, while the sliced job waits
## for them (CitySim.spread_pending) and the clock sits at dawn. At 4x and 8x that wait is most of
## the day: the pump is idle during it, so its budget goes unused. run() spends a small slice of
## that budget on extra pieces in the same frame. Pacing only: the pieces are the same, each
## source's own queue keeps its order, and the sources alternate in the order the frame runs them
## (ResidentMinds first, then the brain), one piece each per round, as the per-frame path does.
## Pure: callables in, a count out. No nodes, no randomness, no clock reads that reach the sim (the
## wall clock only decides how many pieces fit).

const FLAG := "day_drain_fast"
## The drain starts at this game speed (1x and 2x keep the one piece per frame).
const MIN_SPEED := 4
## Wall milliseconds of piece work one frame may hold at most, counting the pieces the per-frame
## paths run anyway (one for each waiting source: ResidentMinds and the brain each run one a frame
## whether the drain is on or not). The sim's own per-frame budget caps it too (CitySim). So the
## drain adds pieces only while the frame, forced ones included, stays inside this: a frame that
## is already full of pieces (a piece of 5 to 10 ms in the browser, two sources: 10 to 20 ms)
## gets none, and its length is what it was without the drain.
const BUDGET_MS := 8.0
## At most this many extra pieces in one frame, whatever the budget says.
const MAX_PIECES := 16
## Weight of the newest piece's cost in the running estimate used to predict the next one.
const COST_BLEND := 0.3
## What a skipped frame leaves of a too-heavy estimate: slowly, so that a machine where pieces cost
## too much to add any is probed again only now and then (every 30 to 50 frames).
const ESTIMATE_DECAY := 0.99


## Runs waiting pieces so that the frame's piece work, the per-frame ones included, stays within
## budget_ms. sources: [[gate: Callable, step: Callable], ...] in the order a frame runs them;
## gate() says whether the source has a piece waiting, step() runs exactly one. stats (kept by the
## caller between frames) carries "ema_ms" (the estimated cost of one piece) and counts "pieces" and
## "frames" for the report. Returns how many extra pieces ran.
static func run(sources: Array, budget_ms: float, stats: Dictionary = {}) -> int:
	if budget_ms <= 0.0 or sources.is_empty():
		return 0
	var t0 := Time.get_ticks_usec()
	var ema := float(stats.get("ema_ms", 0.0))
	# The per-frame paths run one piece for every source with one waiting, after this call.
	var waiting := 0
	for src: Array in sources:
		if bool((src[0] as Callable).call()):
			waiting += 1
	var limit := budget_ms - float(waiting) * ema
	var ran := 0
	var more := true
	while more and ran < MAX_PIECES:
		more = false
		for src: Array in sources:
			if not bool((src[0] as Callable).call()):
				continue
			var spent := float(Time.get_ticks_usec() - t0) / 1000.0
			# No estimate yet (ema 0): the first piece measures one. After that a piece runs only
			# while its predicted cost still fits.
			if spent + ema > limit:
				# A heavy estimate changes only when a piece runs: let it fall so one is retried.
				_note(stats, ema if ran > 0 else ema * ESTIMATE_DECAY, ran)
				return ran
			var s0 := Time.get_ticks_usec()
			(src[1] as Callable).call()
			var cost := float(Time.get_ticks_usec() - s0) / 1000.0
			ema = cost if ran == 0 and ema == 0.0 else lerpf(ema, cost, COST_BLEND)
			ran += 1
			more = true
	_note(stats, ema, ran)
	return ran


static func _note(stats: Dictionary, ema: float, ran: int) -> void:
	stats["ema_ms"] = ema
	if ran > 0:
		stats["pieces"] = int(stats.get("pieces", 0)) + ran
		stats["frames"] = int(stats.get("frames", 0)) + 1


## Whether a sim at spd (game speed) with the flag state on should drain: the speed gate alone.
static func active_at(spd: int, budget_ms: float) -> bool:
	return budget_ms > 0.0 and spd >= MIN_SPEED
