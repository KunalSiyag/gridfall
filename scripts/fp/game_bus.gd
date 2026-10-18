class_name GameBus
extends Node
## Signals that cross first-person slices. Emitters and listeners are listed in docs/fp/S0-foundation.md §9.

## A world point that deserves attention (y = 0). reason: "event:<type>", "resident:<id>", "tile",
## "district:<mi>" or "player" (a waypoint set on the map).
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
