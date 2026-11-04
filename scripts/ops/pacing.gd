class_name Pacing
extends RefCounted
## Step lengths for the per-frame catch-up loops (traffic, birds, animals): a long frame, or a
## high game speed, hands them a big delta that they work off in steps of at most MAX_STEP.
## Bounded to MAX_STEPS_PER_FRAME steps a frame, the loops cannot spiral on a slow browser frame.

## Most steps one frame may run in a catch-up loop.
const MAX_STEPS_PER_FRAME := 12
## Longest frame, in real seconds, the world integrates (see frame_dt).
const MAX_FRAME_DT := 1.0


## The step length for working off dt in steps: max_step, or longer when dt would need more than
## MAX_STEPS_PER_FRAME of them. dt up to MAX_STEPS_PER_FRAME * max_step (1x speed at any frame
## rate above 3 fps) keeps the plain max_step.
static func step_for(dt: float, max_step: float) -> float:
	return maxf(max_step, dt / float(MAX_STEPS_PER_FRAME))


## The frame delta the world integrates: delta, but at most MAX_FRAME_DT seconds (flag
## frame_dt_clamp). A browser tab hidden for minutes hands the first frame after it the whole gap
## as its delta: unclamped, the traffic works off minutes of driving (at 8x, ten times that) in the
## 12 steps step_for allows; measured (tools/tests/fp_resume_test.gd), a 600 s frame at 8x replaces
## the whole moving traffic of the street: every car of the fixture was gone and new ones spawned.
## A clamped frame loses the time instead, as a paused game does. The sim clock needs no clamp of
## its own (its backlog clamp drops what it cannot run), so this is for the code that integrates
## delta itself.
static func frame_dt(delta: float) -> float:
	if not FeatureFlags.enabled("frame_dt_clamp", true):
		return delta
	return clampf(delta, 0.0, MAX_FRAME_DT)
