class_name Pacing
extends RefCounted
## Step lengths for the per-frame catch-up loops (traffic, birds, animals): a long frame, or a
## high game speed, hands them a big delta that they work off in steps of at most MAX_STEP.
## Bounded to MAX_STEPS_PER_FRAME steps a frame, the loops cannot spiral on a slow browser frame.

## Most steps one frame may run in a catch-up loop.
const MAX_STEPS_PER_FRAME := 12


## The step length for working off dt in steps: max_step, or longer when dt would need more than
## MAX_STEPS_PER_FRAME of them. dt up to MAX_STEPS_PER_FRAME * max_step (1x speed at any frame
## rate above 3 fps) keeps the plain max_step.
static func step_for(dt: float, max_step: float) -> float:
	return maxf(max_step, dt / float(MAX_STEPS_PER_FRAME))
