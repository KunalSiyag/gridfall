extends RefCounted
## The front kick's foot path in the body's frame (right, up, forward, metres). A bent-knee
## chamber precedes the extension; the foot returns to that chamber before it plants again.

const REST := Vector3(0.12, 0.08, 0.0)
const CHAMBER := Vector3(0.12, 0.62, 0.25)
const EXTENDED := Vector3(0.12, 0.85, 0.88)
const CHAMBER_AT := 0.5
const RECOIL_S := 0.14
const PLANT_S := 0.34
const RELEASE_S := 0.12
const TAKE_S := 0.035


static func foot(t: float, contact: float) -> Vector3:
	var chamber := contact * CHAMBER_AT
	if t < chamber:
		return REST.lerp(CHAMBER, smoothstep(0.0, chamber, t))
	if t < contact:
		return CHAMBER.lerp(EXTENDED, smoothstep(chamber, contact, t))
	if t < contact + RECOIL_S:
		return EXTENDED.lerp(CHAMBER, smoothstep(contact, contact + RECOIL_S, t))
	return CHAMBER.lerp(REST, smoothstep(contact + RECOIL_S, contact + PLANT_S, t))


static func weight(t: float, contact: float) -> float:
	return (
		smoothstep(0.0, TAKE_S, t)
		* (1.0 - smoothstep(contact + PLANT_S, contact + PLANT_S + RELEASE_S, t))
	)
