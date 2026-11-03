extends FpFeature
## The coach card (integration feature "coach_card", flag coach_card): the first minute's guidance.
## A fresh city's welcome (Main asks over bus.coach_requested) is a key-cap card at the bottom
## centre, in the overview key bar's style: WASD walk, Shift run, Tab city overview, J AI feed,
## E talk, Enter chat, Esc menu. It stays 15 real seconds or until the player presses J, Tab or
## E (or does anything else first: chat, the menu, a hero action), and never shows again once
## settings coach_seen is set. A "Click to look around" pill shows while the pointer is free on a
## build that has one. A small ladder of one-line hints follows, each shown at most once (kept in
## settings coach_hints): the first AI decision (J reads it), the first resident within 3 m (E to
## talk), a minute without input at 1x (] speeds time up) and the first Tab (the Planner
## view button opens the full city builder). All text is de-branded street text: no model names.

const S := preload("res://scripts/fp/ui/hud_style.gd")
const L := preload("res://scripts/fp/coach/coach_logic.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const FADE_PER_S := 5.0
## Bottom of the stack above the screen edge in the 1600x900 base: clear of the overview's key bar.
const BOTTOM := 72.0

var _box: VBoxContainer
var _card: PanelContainer
var _hint: PanelContainer
var _hint_row: HBoxContainer
var _pill: PanelContainer
var _card_on: bool = false
var _card_t: float = 0.0
var _hint_id: String = ""
var _hint_t: float = 0.0
var _pending: Array[String] = []
var _idle: float = 0.0
var _pill_on: bool = false


func feature_id() -> String:
	return "coach_card"


func setup(p_ctx: FpContext) -> void:
	super.setup(p_ctx)
	_build()
	if ctx.bus != null:
		var b := ctx.bus
		link_signal(b.coach_requested, _on_requested)
		link_signal(b.ai_decision_shown, _on_ai_decision)
		link_signal(b.interact_target_changed, _on_target)
		link_signal(b.modal_changed, _on_modal)
		for sig: Signal in [b.hero_action, b.interact_requested, b.talk_requested]:
			link_signal(sig, _on_acted)


func teardown() -> void:
	unlink_signals()
	if _box != null and is_instance_valid(_box):
		if _box.get_parent() != null:
			_box.get_parent().remove_child(_box)
		_box.queue_free()
	_box = null


# ------------------------------------------------------------------ state


## True while the welcome card is up.
func card_visible() -> bool:
	return _card_on


## The ladder hint on show ("J reads it"), or "".
func hint_shown() -> String:
	return L.hint_text(_hint_id) if not _hint_id.is_empty() else ""


## True while the "Click to look around" pill is up.
func capture_pill_visible() -> bool:
	return _pill_on


## Whether ladder hint id was shown before (this run or an earlier one).
func hint_seen(id: String) -> bool:
	return L.shown_hints(str(ctx.settings.get(L.HINTS_KEY, ""))).has(id)


## Shows the welcome card unless it was seen for good. True when it showed.
func show_welcome() -> bool:
	if bool(ctx.settings.get(L.SEEN_KEY, false)) or _card_on:
		return false
	_card_on = true
	_card_t = L.CARD_SECONDS
	_card.visible = true
	return true


## Ends the welcome card (a key, an action or the timer) and keeps it from coming back.
func dismiss_welcome() -> void:
	if not _card_on:
		return
	_card_on = false
	_save({L.SEEN_KEY: true})


## Queues ladder hint id: shown at once if nothing else is up (never twice, ever).
func offer_hint(id: String) -> void:
	if not L.HINTS.has(id) or hint_seen(id) or _pending.has(id) or id == _hint_id or L.tool_run():
		return
	_pending.append(id)
	_next_hint()


func _next_hint() -> void:
	if _card_on or not _hint_id.is_empty() or _pending.is_empty():
		return
	_hint_id = _pending.pop_front()
	_hint_t = L.HINT_SECONDS
	_save({L.HINTS_KEY: L.with_hint(str(ctx.settings.get(L.HINTS_KEY, "")), _hint_id)})
	for c in _hint_row.get_children():
		_hint_row.remove_child(c)
		c.queue_free()
	for p: Array in L.HINTS[_hint_id]:
		_hint_row.add_child(
			S.key_cap(str(p[1])) if p[0] == "key" else S.label(str(p[1]), 15, S.TEXT)
		)
	_hint.visible = true
	_hint.reset_size()


func _save(patch: Dictionary) -> void:
	if ctx.mode != null and is_instance_valid(ctx.mode):
		ctx.mode.apply_settings(patch)
	else:
		ctx.settings.merge(patch, true)


# ------------------------------------------------------------------ input and signals


func _input(event: InputEvent) -> void:
	if ctx == null or event.is_echo():
		return
	if L.is_player_input(event):
		_idle = 0.0
	if not _card_on:
		return
	for a: String in L.DISMISS_ACTIONS:
		if event.is_action_pressed(a):
			dismiss_welcome()
			return


func _on_requested(topic: String) -> void:
	if topic == "welcome":
		show_welcome()


func _on_ai_decision(_agent: String) -> void:
	offer_hint("feed")


func _on_target(t: Dictionary) -> void:
	if str(t.get("kind", "")) == "resident" and float(t.get("dist", 1e9)) <= L.TALK_METRES * WS.M:
		offer_hint("talk")


func _on_modal(_active: bool) -> void:
	if ctx.has_modal(&"overview"):
		offer_hint("tab")


func _on_acted(_a: Variant = null, _b: Variant = null) -> void:
	dismiss_welcome()


# ------------------------------------------------------------------ frame


func _process(delta: float) -> void:
	if ctx == null or _box == null:
		return
	if _card_on:
		_card_t -= delta
		if _card_t <= 0.0:
			dismiss_welcome()
	if not _hint_id.is_empty():
		_hint_t -= delta
		if _hint_t <= 0.0:
			_hint_id = ""
	if _hint_id.is_empty():
		_next_hint()
	var at_1x := ctx.sim != null and ctx.sim.speed == 1
	if at_1x and not ctx.is_modal():
		_idle += delta
		if _idle >= L.IDLE_SECONDS:
			offer_hint("speed")
	else:
		_idle = 0.0
	_pill_on = _wants_pill()
	_fade(_card, _card_on, delta)
	_fade(_hint, not _hint_id.is_empty(), delta)
	_fade(_pill, _pill_on, delta)


func _wants_pill() -> bool:
	var paused := ctx.mode != null and ctx.mode.paused
	var pointer := ctx.mode == null or ctx.mode.capture_mouse
	var headless := DisplayServer.get_name() == "headless"
	var shows := L.should_show_capture_hint(Input.mouse_mode, paused, ctx.is_modal(), headless)
	return pointer and shows and not L.tool_run()


func _fade(c: Control, on: bool, delta: float) -> void:
	var a := move_toward(c.modulate.a, 1.0 if on else 0.0, delta * FADE_PER_S)
	c.modulate.a = a
	c.visible = a > 0.01 or on


# ------------------------------------------------------------------ view


func _build() -> void:
	_box = VBoxContainer.new()
	_box.name = "Coach"
	_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_box.anchor_left = 0.5
	_box.anchor_right = 0.5
	_box.anchor_top = 1.0
	_box.anchor_bottom = 1.0
	_box.offset_left = -520.0
	_box.offset_right = 520.0
	_box.offset_top = -BOTTOM - 10.0
	_box.offset_bottom = -BOTTOM
	_box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_box.alignment = BoxContainer.ALIGNMENT_END
	_box.add_theme_constant_override("separation", 8)
	_pill = _pill_panel(L.CAPTURE_TEXT)
	_hint = S.panel(Color(0.04, 0.05, 0.08, 0.72), S.RADIUS, 12, 6)
	_hint.name = "Hint"
	_hint_row = HBoxContainer.new()
	_hint_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint_row.add_theme_constant_override("separation", 7)
	_hint.add_child(_hint_row)
	_card = _card_panel()
	for c: Control in [_pill, _hint, _card]:
		c.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		c.visible = false
		c.modulate.a = 0.0
		_box.add_child(c)
	if ctx.hud != null:
		ctx.hud.slot("center").add_child(_box)
	else:
		add_child(_box)


func _card_panel() -> PanelContainer:
	var p := S.panel(S.PANEL_BG, S.RADIUS, 16, 9)
	p.name = "Card"
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 16)
	p.add_child(row)
	for e: Array in L.KEYS:
		var h := HBoxContainer.new()
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		h.add_theme_constant_override("separation", 6)
		h.add_child(S.key_cap(str(e[0])))
		h.add_child(S.label(str(e[1]), 15, S.TEXT))
		row.add_child(h)
	return p


func _pill_panel(t: String) -> PanelContainer:
	var p := S.panel(Color(0.04, 0.05, 0.08, 0.72), 12, 14, 6, Color(1, 1, 1, 0.18))
	p.name = "CapturePill"
	p.add_child(S.label(t, 15, S.TEXT))
	return p
