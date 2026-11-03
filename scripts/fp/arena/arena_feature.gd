extends FpFeature
## Ask the five (integration feature "arena_ask"; docs/fp/ARCHITECTURE.md, Arena). The chat command
## "/ask <question>" (chat_ask.gd -> bus.ask_requested) sends one question to all five mayors'
## models at once, each from the same city state it plans a normal turn from, and opens a modal
## with five columns that fill as the models answer: who finished first, what each thought, said
## and would do, and where each answer came from. Nothing is applied to the city (ArenaAsk). A bare
## "/ask" shows the last answers again. Esc closes it and the mouse goes back to the game like any
## other modal (FpMode listens to bus.modal_changed). The page names models on purpose: its widgets
## are tagged to their own owner, so the street's no-branding scan leaves them out.

const PANEL := preload("res://scripts/fp/arena/arena_panel.gd")
const MODAL := &"arena"

var panel: PANEL
var panel_open: bool = false


func feature_id() -> String:
	return "arena_ask"


func setup(p_ctx: FpContext) -> void:
	super.setup(p_ctx)
	if ctx.hud != null:
		panel = PANEL.new()
		ctx.hud.slot("overlay").add_child(panel)
		panel.setup(ctx.brain)
		panel.visible = false
		panel.close_requested.connect(close_panel)
	if ctx.bus != null:
		link_signal(ctx.bus.ask_requested, _on_ask)
		link_signal(ctx.bus.pause_changed, _on_pause)


## Boot, load or New City: the old city's answers are gone.
func on_world_rebuilt() -> void:
	close_panel()
	if panel != null:
		panel.brain = ctx.brain
		panel.reset()


func teardown() -> void:
	close_panel()
	unlink_signals()
	if panel != null and is_instance_valid(panel):
		panel.queue_free()
	panel = null


func self_test() -> Dictionary:
	if ctx.hud != null and panel == null:
		return {"ok": false, "detail": "arena panel missing"}
	return {"ok": true, "detail": "%d columns" % (panel.columns.size() if panel != null else 0)}


## Opens the panel. False when it may not open now: no HUD or city, a modal open, paused, in photo
## mode or talking.
func open_panel() -> bool:
	if panel_open:
		return true
	if panel == null or ctx.brain == null or ctx.player == null or ctx.is_modal():
		return false
	if (ctx.mode != null and ctx.mode.paused) or ctx.player.photo_mode:
		return false
	if ctx.player.in_conversation():
		return false
	panel_open = true
	ctx.push_modal(MODAL)
	panel.brain = ctx.brain
	panel.set_open(true)
	Analytics.track("arena_open", {})
	return true


func close_panel() -> void:
	if not panel_open:
		return
	panel_open = false
	if ctx != null:
		ctx.pop_modal(MODAL)
	if panel != null:
		panel.set_open(false)


## Asks all five (a bare "/ask" just shows the last answers). A refusal (the budget, the flag) is
## a toast and shows in the panel's status line.
func ask(question: String) -> Dictionary:
	if not open_panel():
		_toast("Ask the five once you are on your feet and nothing else is open.")
		return {"ok": false, "code": "closed", "reason": "the panel cannot open now"}
	if question.strip_edges().is_empty():
		return {"ok": true, "code": "shown"}
	var res: Dictionary = panel.submit(question)
	if bool(res.get("ok", false)):
		Analytics.track("arena_ask", {"chars": question.length(), "neutral": panel.neutral})
	else:
		_toast(str(res.get("reason", "")))
	return res


func _on_ask(question: String) -> void:
	ask(question)


func _on_pause(p: bool) -> void:
	if p:
		close_panel()


func _toast(t: String) -> void:
	if ctx.bus != null:
		ctx.bus.toast.emit(t, "info")
