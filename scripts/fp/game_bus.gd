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
signal world_ready()
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
## A street prop was knocked over at a point (its StreetDressing kind: "bin", "bench" ...) and
## flies off at speed (u/s). Emitted by the props feature.
signal prop_knocked(at: Vector3, kind: String, speed: float)
## Someone on foot was hit at a point (their feet): cause "shove" or "punch" (the hero), "car"
## (the car the player drives) or "carjack" (dragged out of the car the player takes); info is
## traffic_feature.gd hit_walker()'s {"walker", "resident_id", "name", "down", "street",
## "strength", "witnesses", "crew"}. Emitted by traffic.
signal person_hit(at: Vector3, cause: String, info: Dictionary)
## The hero swung or gestured: action "jab", "cross", "shove" or an emote ("wave", "yes", "no",
## "shout", "dance"), at their feet. Emitted by the actions feature.
signal hero_action(action: String, at: Vector3)
## Someone answered the hero: a resident face to face (their id and name), or whoever answered
## "Ask someone here" (resident_id "" and their role, "Shopkeeper"). reply is filtered for
## display. Emitted by chat.
signal talk_replied(resident_id: String, speaker: String, reply: String)
## The player filed a story for the Gazette: reporter_feature.gd file_story()'s {"agent",
## "headline", "place", "quote", "by", "tile", "district", "day", "scoop", "local", "sharp",
## "points", "text"}. Emitted by the reporter feature; chat runs "text" as a Gazette line.
signal story_filed(story: Dictionary)
