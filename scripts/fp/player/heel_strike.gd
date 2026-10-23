extends RefCounted
## Where a heel comes down in one sampled gait cycle, for the hero rig's feet analysis
## (hero_rig.gd): the sample near the nominal strike where the heel gets within EPS of its lowest.

## How close (m) to its lowest point near the nominal strike a heel counts as down, and the
## window, in cycles around the nominal strike, that the search covers.
const EPS := 0.005
const BEFORE := 0.2
const AFTER := 0.15


## Where samples h (one cycle) come down to within EPS of their lowest value inside the window
## around nominal (the heel strike after the swing), interpolated between samples.
static func down_phase(h: PackedFloat32Array, nominal: float) -> float:
	var n := h.size()
	var i0 := roundi((nominal - BEFORE) * n)
	var i1 := roundi((nominal + AFTER) * n)
	var lo := INF
	for i in range(i0, i1 + 1):
		lo = minf(lo, h[posmod(i, n)])
	var thr := lo + EPS
	for i in range(i0 + 1, i1 + 1):
		var prev := h[posmod(i - 1, n)]
		var cur := h[posmod(i, n)]
		if prev > thr and cur <= thr:
			var f := clampf((prev - thr) / maxf(prev - cur, 1e-6), 0.0, 1.0)
			return fposmod((float(i) - 1.0 + f) / float(n), 1.0)
	return fposmod(nominal, 1.0)
