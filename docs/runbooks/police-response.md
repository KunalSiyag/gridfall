# Police response: a stuck fade, stuck officers or a chase that goes nowhere

The police answer the hero's offences in first person (`scripts/fp/traffic/police_response.gd` and `police_bust.gd`, the `police_response` flag, on by default). A called police car posts "Police arrived on <street>" and puts two officers out; a hero held within 3 m of one for 2 s after the shout, or in a stopped car beside the police car, is busted (fade to black, out of any car, put outside the nearest station); a hero who runs or drives off is chased for 30 s (up to 60 s against one who has stopped while the car closes in, or while it is within 40 m of them), or is "No sign of the suspect" when over 500 m away. A car that gets as near as the roads go, or stands 5 s in the traffic, within 60 m of the hero puts its officers out again from there.

**Symptoms**

- The screen stays black or the hero cannot move after "Busted: fined ...".
- Officers stand beside a parked police car for minutes, or a police car keeps "pursuing".
- "The police do nothing": no officers, only a parked car with its siren.
- Officers stay at the car's flank and never walk up to a hero 10 to 30 m off.

**Confirm**

1. Run with the flag off: `GRIDFALL_FLAGS=police_response=0` (or `{"police_response": false}` in `user://feature_flags.json`). If the symptom goes away it is this feature. A parked car that sits 40 s with its siren and leaves is the flag-off behaviour.
2. A parked car and no officers is normal when the hero is more than 50 m away when it arrives (the car hunts a hero within 500 m, and only says "No sign of the suspect" beyond that), when its stay has under 8 s left, and for the crews the sim's disasters send (they have no stay and no officers) and for ambulances.
3. Run the four tests (headless, offline): `tools/tests/fp_police_response_test.gd` (the scene, the warning, the arrest, no station), `fp_police_chase_test.gd` (the chase and its give-up, the flag off, a load or teardown mid-response, the cool-down), `fp_police_edges_test.gd` (the officers' walk, the input hold, the pace at 1x/4x/8x, a teleport's warm-up, a second car on its way, only called police are a response, the nearest station) and `fp_police_catch_test.gd` (when a car has caught a hero up, the flee radius, the chase's words).

**Fix**

- Black screen or no input: the fade ticks from the traffic feature's `_process` (`police.bust.tick`); a world rebuild (F9) or leaving first person drops it and gives the input back. The fade takes the input again whenever another feature hands it back mid-fade (the health feature's stagger does) and gives back only what the arrest took. If it can still happen, the bug is in `police_bust.gd` (`begin`, `tick`, `_hold_input`, `_finish`).
- Officers stuck "out" or at the door: a walk ends within `ARRIVE_EPS` of its stop radius (float32 positions cannot make the last hair of a step); a walk that stops short of its target would be a regression of `_walk_to`.
- Officers or car stuck: `police.clear(true)` frees every officer and sends a car mid-chase home; a response also ends when its car is removed, leaves or the flag goes off. A call is sent home by `fleets.gd` 240 s after it was dispatched. The officers keep the stay up while they are after a hero for at most 45 s in all.
- The hero is not caught: the car drives its own lanes at its own pace and never teleports, so a hero who keeps moving fast and far outruns it, and the first leg of a chase is often a slow U-turn of the lane graph (hence "Police are after you" is said once the car is up to 5 m/s).

**Verify**

The four tests print `FP_POLICE_RESPONSE_TEST: PASS`, `FP_POLICE_CHASE_TEST: PASS`, `FP_POLICE_EDGES_TEST: PASS` and `FP_POLICE_CATCH_TEST: PASS`; then play: call the police (punch someone down, or carjack), stand still and watch the officers, the shout and the fade.
