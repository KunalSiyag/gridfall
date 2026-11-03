extends RefCounted
## The chat command "/ask <question>" (feature "arena_ask"): the question goes to all five
## mayors' models at once and the answers are only shown, never applied (ArenaAsk). The chat
## feature calls take() first on every line the player sends; a bare "/ask" asks the panel to show
## its last answers again. Nothing here posts to the feed, so no resident answers an /ask.

const COMMAND := "/ask"


## True when text is the /ask command ("/ask", or "/ask" and a space then anything).
static func is_ask(text: String) -> bool:
	var t := text.strip_edges().to_lower()
	return t == COMMAND or t.begins_with(COMMAND + " ")


## The question after the command, "" for a bare "/ask".
static func question_of(text: String) -> String:
	return text.strip_edges().substr(COMMAND.length()).strip_edges()


## Handles an /ask line: closes the chat drawer (the panel is a modal of its own) and sends the
## question over the bus. False when text is not an /ask line or the feature is switched off.
static func take(text: String, ctx: FpContext, drawer: Object) -> bool:
	if not is_ask(text) or ctx == null or ctx.bus == null:
		return false
	if not FeatureFlags.enabled("arena_ask"):
		return false
	if drawer != null and bool(drawer.get("is_open")):
		drawer.call("close")
	ctx.bus.ask_requested.emit(question_of(text))
	return true
