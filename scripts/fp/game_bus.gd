class_name GameBus
extends Node
## Signals that cross first-person slices. Emitters and listeners are listed in docs/fp/S0-foundation.md §9.

## A world point that deserves attention (y = 0). reason: "event:<type>", "resident:<id>", "tile",
## "district:<mi>", "ai:<mi or support role>" (an AI decision landed there) or "player" (a
## waypoint set on the map).
signal ping(world_pos: Vector3, reason: String)
## A player-facing notice. kind: "info", "alert", "success" or "system".
signal toast(text: String, kind: String)
## The interaction target under the crosshair changed; {} when nothing is targeted.
signal interact_target_changed(target: Dictionary)
## The player pressed interact on target.
signal interact_requested(target: Dictionary)
## The player asked to talk to a named resident.
signal talk_requested(resident_id: String)
## A face-to-face conversation started or ended.
signal conversation_changed(resident_id: String, active: bool)
## A message was posted to the global chat (chat message dict, §9).
signal chat_posted(msg: Dictionary)
## A poster texture is ready: {"key", "kind", "texture", "meta"}.
signal poster_ready(poster: Dictionary)
## The player entered tile (x, y).
signal player_tile_changed(x: int, y: int)
## The first-person time scale changed (1, 2, 4 or 8).
signal time_scale_changed(scale: int)
## The settings changed; settings is the full dict.
signal settings_changed(settings: Dictionary)
## The game was paused or resumed.
signal pause_changed(paused: bool)
## The quality preset changed: "low", "medium" or "high".
signal quality_changed(preset: String)
## Some modal UI opened (true) or the last one closed (false).
signal modal_changed(active: bool)
## The world was rebuilt and every feature ran on_world_rebuilt().
signal world_ready
## A button on a place card: action "ask_here" (C answers through brain.inspect_tile). Emitted by B.
signal card_action(action: String, tile: int)
## The hero got into a car (true) or out of it (false). Emitted by the drive feature.
signal drive_changed(active: bool)
## The player's car hit something hard: the contact point, the closing speed (u/s) and what was
## hit, "wall" (anything fixed) or "car". Emitted by the drive feature.
signal car_impact(at: Vector3, speed: float, what: String)
## The driver's door of the player's car opened (true) or slammed shut (false), at its handle.
## Emitted by the drive feature.
signal car_door(at: Vector3, open: bool)
## A street prop was knocked over, or a fallen one kicked hard, at a point (its StreetDressing
## kind: "bin", "cone" ...) and flies off at speed (u/s): by the player's car, the hero, people
## walking, traffic or another prop. Emitted by the props feature.
signal prop_knocked(at: Vector3, kind: String, speed: float)
## Someone on foot was hit at a point (their feet): cause "shove" or "punch" (the hero's fists
## and kicks), "car" (the car the player drives) or "carjack" (dragged out of the car the player
## takes); info is traffic_feature.gd hit_walker()'s {"walker", "resident_id", "name", "down",
## "street", "strength", "by" (-1 the hero, else the attacker walker's id), "witnesses",
## "crew"}, a throw that meets a wall or a solid prop mid-flight adding "impact" {"at", "in"}
## (throw_impact — marked on this one emission, never a second person_hit). Emitted by traffic.
signal person_hit(at: Vector3, cause: String, info: Dictionary)
## The hero swung, gestured or got over something: action "jab", "cross", "hook", "shove",
## "kick", "swing" (a weapon in hand), "counter" (a hook countering a punch), "throw" or "slam"
## (someone held), "grapple" (taking hold of someone), an emote ("wave", "yes", "no", "shout",
## "dance") or a parkour move ("vault", "hop", "climb", "roll" off a hard landing, "grab" taking
## hold of a wall, or free running's "run_up" up a ledge, "catch" of a ledge in the air and "leap"
## across a gap), or "hijack" (leaping from the car the hero drove onto one to take), as it starts,
## at their feet. Emitted by the actions, brawl, parkour and drive features.
signal hero_action(action: String, at: Vector3)
## The hero's car horn sounded at at (street plane, xz): radius is how far it carries in world
## units, long true when the hero leans on it (a tap first, the held press turning long). Emitted
## by the drive feature (the horn_street flag); the street's answer to it -- people startled,
## birds up -- lives with the agents that draw them.
signal horn_sounded(at: Vector2, radius: float, long: bool)
## A weapon in the hero's hand landed a blow at a point on what ("person" or "prop"): kind "bat",
## "pipe" or "bottle", broke true when it broke (a bottle does on its first). Emitted by the melee
## feature.
signal weapon_hit(at: Vector3, kind: String, what: String, broke: bool)
## A blow of the hero's (a kick or a weapon) landed on an animal at at: kind "dog", "cat" or
## "pigeon", strength 0..1. Emitted by the animals feature.
signal animal_hit(at: Vector3, kind: String, strength: float)
## Someone answered the hero: a resident face to face (their id and name), or whoever answered
## "Ask someone here" (resident_id "" and their role, "Shopkeeper"). reply is filtered for
## display. Emitted by chat.
signal talk_replied(resident_id: String, speaker: String, reply: String)
## The player filed a story for the Gazette: reporter_feature.gd file_story()'s {"agent",
## "headline", "place", "quote", "by", "tile", "district", "day", "scoop", "local", "sharp",
## "points", "text"}. Emitted by the reporter feature; chat runs "text" as a Gazette line.
signal story_filed(story: Dictionary)
## Something struck the hero on foot: at is where the blow came from (a fist, a car's front, a
## dog's jaws), cause "punch" (someone fighting back), "car" (a car that could not stop for them)
## or "bite" (a dog defending its owner), strength 0..1 and push the xz velocity (u/s) it throws
## the hero along. Emitted by traffic and the animals feature; the health feature takes the damage.
signal hero_hit(at: Vector3, cause: String, strength: float, push: Vector3)
## Someone fighting the hero (wid, the walkers_near id) started a punch from their fist at that
## lands in secs, unless the guard goes up in time to counter it (the actions feature's parry).
## Emitted by traffic.
signal hero_threatened(at: Vector3, secs: float, wid: int)
## The hero slammed the person they held into something (the brawl feature's slam): at is the
## contact at chest height, what "wall" (a wall, a post or a parked car) or the street prop's kind,
## over true when the prop went over with them. Emitted by the brawl feature.
signal hero_slammed(at: Vector3, what: String, over: bool)
## The hero lost amount of health to cause: "punch", "car" or "bite" (hero_hit), "crash" (in the
## car they drive) or "fall" (a hard landing); health is what is left (0..100, 0 knocked out) and
## down is true when it put them on the ground. Emitted by the health feature.
signal hero_hurt(amount: float, cause: String, health: float, down: bool)
## An animal called out at a point (its head): a dog's "bark", "growl" or "whine", a pigeon's
## "coo", a lone pigeon's "flap" or a flock's "takeoff", a cat's "meow", "purr", "hiss" or
## "chatter" (at a bird it stalks); size is its height at the shoulder (m), so a small dog yaps
## higher. Emitted by the animals feature.
signal animal_called(at: Vector3, call: String, size: float)
