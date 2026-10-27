# Combat pose contracts

The actions and brawl features own the gameplay clocks. The hero's pose layer follows those
clocks; it never decides whether a blow lands.

## Grapple

The held person's feet sit 0.58 m ahead, with the existing struggle sway. A smaller gap can
block the hero's forward movement against the held person's collision circle. The hands
reach 0.18 skeleton metres short of the held feet, at upper-arm height, and the hips brace
forward 7 degrees. This shortens the arm reach without sacrificing the ability to drag.

`fp_brawl_test.gd` checks head clearance, hand contact, reachable bent-arm targets, sway and
forward dragging. Its throw test compares the actual animated body transform with
`Walker.body_xf` over 90 rendered frames, including the hip pivot used for the throw's tilt.
Raw `Walker.pos` is the pedestrian's network anchor, not its current reaction position.
Collision, targeting and rendering use `pos + vis_off`.

## Head

Neck and head look-at rotations can accumulate beyond either modifier's individual limit.
`hero_look.gd` bounds the completed head to 70 degrees of yaw and 20 degrees of pitch in the
body's frame. After the combat pose adds its spine turn and lean, the head is bounded again
to 45 degrees of yaw and 6 degrees of pitch. These are anatomical corrections, not gameplay
targeting changes.

## Directional reactions

Flag `directional_hits` keeps a lightly hit person's original facing and makes their torso
tip and roll along the blow. Stronger blows increase the lean and its duration. A heavy melee
blow first staggers them for 0.08–0.16 seconds, then starts the existing knockback and arc.
Throws and vehicle hits launch immediately. Disabling the flag restores the original
turn-toward-the-blow behavior.

`Walker.vis_tilt` and `vis_roll` rotate around the same hip pivot in `body_xf`; this contract
is shared by close animated bodies and distant people.

## The flinch of a blow taken

Flag `hero_flinch`. A blow that lands on the hero flinches the body the way it came from: one
in the face snaps the head back (`hit_head`), one in the back or the side folds the chest
(`hit_chest`). The camera rolls toward the side that was hit, and while `hit_feel` is on the
jolt grows with the blow's strength (0.7x to 1.5x of the fixed kick). A body a move carries
(a landing roll) only feels it in the view. Off: every flinch is the same fixed jolt, the two
flinch clips alternating as before.

## Kick

`hero_kick_pose.gd` defines a right-foot path in skeleton metres: chamber a bent knee, extend
at the actions feature's 0.24-second contact, recoil to the chamber, then plant and release.
The left foot stays planted while the spine counterbalances the kick. The authored clip
still supplies the remaining full-body movement.

## Strike recovery

Flag `strike_recovery`. The swing's own length never changes, but what follows a landing and
a miss differ: a blow that lands on a person, an animal or a prop resolves the torso back
into stance over 0.18 seconds (`resolve_contact`), while a swing at empty air follows through
further and adds the swing's whiff recovery (0.08–0.18 seconds by swing) before the next
attack may start. Throws, slams and counters keep the legacy timing.

## The step-in

Flag `strike_step`. A grounded punch or weapon swing at someone just inside its reach steps
the hero in through the wind-up: at most 0.18 m per swing at 1.2 m/s, never closer than
0.95 m feet to feet. All of it goes through the player's `combat_step`, which moves by the
walking collision rules, refuses ungrounded, crouched, carried and photo states, ground
discontinuities and any overlap with a person's circle, and leaves running strength alone.
The blow's own reach never grows; kicks, shoves, throws, slams, counters and swings at empty
air keep their feet.

## The counter window

Flag `counter_cues`. A punch thrown at the hero holds its clip at 0.5x through the first
half of the run to contact, then plays at 1.5x; the two rates average to one, so the clip
arrives with the blow's own clock and the counter window (the actions feature's 0.4 s
`COUNTER_LEAD`) keeps its length. The brawl feature's `!` rides right at the head (0.1 m above the head bone)
of the walker the threat's id names, re-read every frame so it follows them, and grows from 26 to 40 px through the wind-up, fading over
its 0.15 s tail once the blow has landed (`cue_look`). Off: the clip plays at one speed and
the mark stays 34 px until it goes.

## Tempers

Flag `fight_tempers`. A person who fights back fights their own way, fixed to who they
are: their walker and resident ids hash into the temper shares, so the same person always
fights the same way whatever happens around them first. A guard turns near half the hero's
blows aside behind their fists, and a blow turned aside counts for nothing: no reel, no
slide, nothing toward the knock-down. A dancer sidesteps their own way round the hero
while they wait to punch, keeping punching range. A caller shouts their call longer and up
to two of the people near enough to see square up and join in, each their own way. A bolt
squares up but thinks better of it inside a couple of seconds and runs. A bruiser leads
with the cross and answers a blow the moment it lands. Off: everyone fights the plain way,
jab and cross at one pace.

Flag `guard_chip`. Guards wear out, the hero's and a brawler's alike. A punch the hero's
guard catches drains its poise (a thin sliver inside the health arc), and the one that
empties it lands in full: the guard drops and the hero staggers a beat, the view dipped —
and until the poise knits back, a guard raised again catches nothing. A brawler's guard
chips the same way, 0.26 and a fifth of the blow's strength for every blow turned aside:
the one that takes it past its fill lands in full, and the guard stays beaten for the rest
of the scrap (a fresh scrap starts with a whole guard). Off: guards never tire.

## The street around a body

Flag `downed_awareness`. A blow that leaves someone down brings the nearest onlooker within
six metres over to look: they walk up beside the body (a hand's width past 0.8 m counts as
arrived), lean in with a slow head shake for a moment, then walk on — once for each
knock-down, and never one of the fight's own. And a fighter whose blows put the hero down
stands over them a beat — one last shout — before walking off. Off: nobody comes to look,
and a fighter who downs the hero walks off the same instant.

Flag `crowd_gasp`. A knock-down in view rocks the onlookers who stay back as one: no beat of
looking first, a sharp backward tip (0.12 rad over half a second) before they shout. Once
per crowd: another body falling within 6 s and 10 m of the last gets the plain reaction.
Visual only — there is no gasp clip in the sounds bank. Off: onlookers take their usual
moment, then shout or run as before.

The scrap itself lives in `fight_back.gd`, split out of `reactions.gd` (which keeps the
blow, the fall and the street watching): fighting back, the tempers, the counter window's
rates and the two beats above.

`fp_combat_pose_test.gd` checks head limits with accumulated neck rotations, the kick phases,
directional lean, strength scaling, stagger-before-fall ordering and flag-off behavior.
`fp_brawl_test.gd` checks the held-back and snap rates, the landing clock, the cue's growth
and fade, the anchor over the attacker's head and the flag-off mark; `fp_step_test.gd` checks
the step-in and `combat_step`'s walls, props and people. `fp_tempers_test.gd` checks each
temper, the identity hash, the test pin, the guard's chip and the flag-off plain fight.
`fp_health_test.gd` checks the flinch's direction, the view jolt's strength scaling and side
roll, the flag-off alternation, and the poise's drain, break (the full blow, the dropped
guard, the stagger), knit-back and flag off. `fp_downed_test.gd` checks the walk-up and
lean, once per knock-down,
the stand-over beat and the flag off; `fp_brawl_test.gd` also checks the gasp's rock-back,
the once-per-crowd cooldown and its flag off.
