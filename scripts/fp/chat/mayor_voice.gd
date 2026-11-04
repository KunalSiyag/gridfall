extends RefCounted
## Who wrote a chat line credited to a mayor (finding F8 of the model audit). Chat lines come from
## one of three fast models that rotate (ChatterMinds), whoever the card names, so a line "by Mei
## Kimura" is really her press office's draft. Every such line carries `via`:
##   "press_office"  written by a fast chat model or the offline script in the mayor's name
##   "own_voice"     the mayor's own model said it (flag mayor_voice_calls, a live key only)
## and the chat row prints the matching chip. With the flag on, attribute() sends each mayor line
## (at most MAX_REWRITES a round, in parallel) to that mayor's own model as
## live_json("chatter", "mayor-voice", ...), which rewrites the draft in the mayor's voice; a
## failed, empty or unsuitable answer leaves the press office's line as it was.
##
## Why the flag is off by default: each rewrite is one more live call, 1 to 3 per chat round, to the
## mayors' (large, slower) models on the player's own key, and on the web build every extra
## parallel call counts against a visitor's rate limit. The label alone costs nothing.

const D := preload("res://scripts/sim/sim_defs.gd")
const T := preload("res://scripts/fp/chat/chat_text.gd")
const PRESS := "press_office"
const OWN := "own_voice"
const MAX_REWRITES := 3
const TOKENS := 160
const TIMEOUT := 20.0
const LINE_CHARS := 140
const SYSTEM := """%s
A member of your press office drafted the group-chat message below in your name.
Say it yourself: first person, your own voice, the same meaning and facts, at most 20 words
and 2 sentences. Add no new facts.
Never mention AI, models, games, prompts, tiles or coordinates.
Reply with ONLY JSON: {"say":"..."}"""


## True when the mayors' own models may write their chat lines: the flag is on and a live key is
## in use.
static func wants_own(client: GmiClient) -> bool:
	return (
		client != null
		and client.live_enabled
		and client.has_key()
		and FeatureFlags.enabled("mayor_voice_calls", false)
	)


## Marks every mayor line of lines as the press office's, then, when wants_own(client), has the
## mayors' own models rewrite them. Coroutine; returns lines. directory: the CityDirectory the
## chat text filter uses (or null).
static func attribute(client: GmiClient, day: int, lines: Array, directory: Variant) -> Array:
	for l: Variant in lines:
		if typeof(l) == TYPE_DICTIONARY and str((l as Dictionary).get("role", "")) == "mayor":
			(l as Dictionary)["via"] = PRESS
	if not wants_own(client) or not client.is_inside_tree():
		return lines
	var todo: Array[int] = []
	for i in range(lines.size()):
		if (
			typeof(lines[i]) == TYPE_DICTIONARY
			and str((lines[i] as Dictionary).get("role", "")) == "mayor"
		):
			todo.append(i)
	todo = todo.slice(0, MAX_REWRITES)
	if todo.is_empty():
		return lines
	var state := {"left": todo.size()}
	for i: int in todo:
		_rewrite_one(client, day, lines[i], directory, state)
	var deadline := Time.get_ticks_msec() + int((TIMEOUT + 8.0) * 1000.0)
	while int(state["left"]) > 0 and Time.get_ticks_msec() < deadline and client.is_inside_tree():
		await client.get_tree().process_frame
	return lines


## One mayor line through its mayor's own model; fills line["text"] and line["via"] on success.
static func _rewrite_one(
	client: GmiClient, day: int, line: Dictionary, directory: Variant, state: Dictionary
) -> void:
	var mi := int(line.get("district", -1))
	if mi < 0 or mi >= D.MAYORS.size():
		state["left"] = int(state["left"]) - 1
		return
	var m: Dictionary = D.MAYORS[mi]
	var user := JSON.stringify(
		{
			"day": day,
			"district": str(m["district"]),
			"style": str(m["style"]),
			"press_office_draft": str(line.get("text", ""))
		}
	)
	var res: Dictionary = await client.live_json(
		"chatter",
		"mayor-voice",
		str(m["model"]),
		SYSTEM % str(m["persona"]),
		user,
		day,
		TOKENS,
		TIMEOUT
	)
	var text := suitable(res, directory)
	if not text.is_empty():
		line["text"] = text
		line["via"] = OWN
	state["left"] = int(state["left"]) - 1


## The line a live answer holds ("say"), filtered like every chat line, or "" when there is none
## worth showing (failed call, empty, a link, a model's name, more than 2 sentences).
static func suitable(res: Dictionary, directory: Variant) -> String:
	if not bool(res.get("ok", false)) or typeof(res.get("data")) != TYPE_DICTIONARY:
		return ""
	var data: Dictionary = res["data"]
	var raw := str(data.get("say", data.get("text", ""))).strip_edges()
	if raw.is_empty() or T.has_url(raw) or T.has_model_name(raw):
		return ""
	var text := T.clip(T.display(raw, directory), LINE_CHARS)
	if text.is_empty() or T.sentence_count(text) > 2:
		return ""
	return text
