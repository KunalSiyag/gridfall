extends Control
## The Ask-the-five panel (feature "arena_ask"): the overseer's question and five side-by-side
## columns, one per mayor, filling as their models answer (ArenaColumn): who finished first,
## what each thought, said and would do, and where each answer came from. Nothing shown here is
## applied to the city. The panel only needs the CityBrain: it asks through brain.arena_asker(),
## so the first-person modal (ArenaFeature) and the orbit overlay (CityHud) share the budget and
## the answers. Esc closes it (close_requested); even a focused question box lets Esc through.
##
## Naming models is this page's purpose, so its widgets are re-tagged to the "arena" owner and
## the street's no-branding scan leaves them out (see ArenaColumn.reown, gmi_key_panel.gd).

## Esc, or the Close button.
signal close_requested
## A question was submitted (the ask result: {"ok": bool, ...}).
signal asked(result: Dictionary)

const D := preload("res://scripts/sim/sim_defs.gd")
const S := preload("res://scripts/fp/ui/hud_style.gd")
const COLUMN := preload("res://scripts/fp/arena/arena_column.gd")

const SIDE := 28.0
const HINT := "Nothing here changes the city: it is a what-if."

var brain: Node
## Neutral persona: every mayor gets the same one-line persona, so differences are the models.
var neutral: bool = false
var columns: Array[PanelContainer] = []
var input: LineEdit
var ask_button: Button
var toggle: CheckButton
var status: Label
var heading: Label
var _asker: ArenaAsk = null
var _last_question: String = ""


func setup(p_brain: Node) -> void:
	brain = p_brain
	name = "ArenaPanel"
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.color = Color(0, 0, 0, 0.5)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var panel := S.panel(Color(0.03, 0.04, 0.07, 0.95), S.RADIUS_PANEL, 18, 14)
	panel.name = "Panel"
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.offset_left = SIDE
	panel.offset_right = -SIDE
	panel.offset_top = 36.0
	panel.offset_bottom = -36.0
	add_child(panel)
	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_theme_constant_override("separation", 8)
	panel.add_child(col)
	heading = S.plain("Ask the five", 26, S.WHITE, S.title())
	col.add_child(heading)
	status = S.plain("", 14, S.TEXT_DIM, S.font())
	status.name = "Status"
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(status)
	col.add_child(_controls())
	var row := HBoxContainer.new()
	row.name = "Columns"
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 8)
	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(row)
	col.add_child(scroll)
	for mi in range(D.MAYORS.size()):
		var c: PanelContainer = COLUMN.new()
		c.setup(mi)
		row.add_child(c)
		columns.append(c)
	col.add_child(_footer())
	COLUMN.reown(self)
	set_process(false)
	_say("Ask all five mayors what they would do. Type a question below, or /ask in the chat.")


## Asks all five (the box's text when question is empty) and shows the race. Returns ArenaAsk's
## result; a refusal shows its reason in the status line and leaves the columns as they were.
func submit(question: String = "") -> Dictionary:
	var q := question.strip_edges()
	if q.is_empty():
		q = _last_question
	var res := {"ok": false, "code": "no_city", "reason": "There is no city to ask about yet."}
	if brain != null and brain.has_method("arena_asker"):
		_bind()
		res = _asker.ask(q, "neutral" if neutral else "own")
	if bool(res.get("ok", false)):
		_last_question = q
		input.text = q
	else:
		_say(str(res.get("reason", "")), true)
	asked.emit(res)
	return res


## Shows the newest run again (the state it is in now), or the prompt to ask when there is none.
func show_last() -> void:
	_bind()
	_refresh_toggle()
	var r: Dictionary = _asker.run if _asker != null else {}
	if r.is_empty():
		for c: PanelContainer in columns:
			c.clear("Waiting for a question.")
		_say("Ask all five mayors what they would do. Type a question below, or /ask in the chat.")
		return
	_last_question = str(r["question"])
	input.text = _last_question
	_on_started(r)
	for mi in range(columns.size()):
		var got: Dictionary = (r["results"] as Array)[mi]
		if not got.is_empty():
			(columns[mi] as PanelContainer).show_result(got)
	_refresh_status()


## The city was replaced (New City, Load): forget the old answers.
func reset() -> void:
	if _asker != null:
		_unbind()
	_last_question = ""
	if input != null:
		input.text = ""
	for c: PanelContainer in columns:
		c.clear("Waiting for a question.")
	_say("Ask all five mayors what they would do. Type a question below, or /ask in the chat.")


## Shows or hides the panel; the bar only ticks while it is visible.
func set_open(on: bool) -> void:
	visible = on
	set_process(on)
	if on:
		show_last()


## All the texts on the page, for a test or a smoke: heading, status, every column's labels.
func texts() -> PackedStringArray:
	var out := PackedStringArray()
	COLUMN._collect(self, out)
	return out


## Esc, even while the question box has focus (a focused LineEdit would swallow it otherwise).
func _input(event: InputEvent) -> void:
	if not visible or event.is_echo():
		return
	if event.is_action_pressed("pause_menu"):
		close_requested.emit()
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if _asker == null or not _asker.busy():
		return
	var e := _asker.elapsed_s()
	for c: PanelContainer in columns:
		c.tick(e, ArenaAsk.TIMEOUT_S)


func _bind() -> void:
	var a: ArenaAsk = (
		brain.arena_asker() if brain != null and brain.has_method("arena_asker") else null
	)
	if a == _asker:
		return
	_unbind()
	_asker = a
	if _asker != null:
		_asker.started.connect(_on_started)
		_asker.answered.connect(_on_answered)
		_asker.finished.connect(_on_finished)


func _unbind() -> void:
	if _asker != null:
		if _asker.started.is_connected(_on_started):
			_asker.started.disconnect(_on_started)
		if _asker.answered.is_connected(_on_answered):
			_asker.answered.disconnect(_on_answered)
		if _asker.finished.is_connected(_on_finished):
			_asker.finished.disconnect(_on_finished)
	_asker = null


func _on_started(r: Dictionary) -> void:
	for c: PanelContainer in columns:
		c.set_pending()
	_refresh_status(r)


func _on_answered(result: Dictionary) -> void:
	var mi := int(result.get("mi", -1))
	if mi >= 0 and mi < columns.size():
		(columns[mi] as PanelContainer).show_result(result)
	_refresh_status()


func _on_finished(_r: Dictionary) -> void:
	_refresh_status()


func _refresh_status(r: Dictionary = {}) -> void:
	var run: Dictionary = r if not r.is_empty() else (_asker.run if _asker != null else {})
	if run.is_empty():
		return
	_refresh_toggle()
	var total := D.MAYORS.size()
	var live := bool(run["live"])
	var line := ""
	if not live:
		# Nothing went out: no persona was applied and nobody heard the question.
		line = 'Your question was not sent: "%s"  ·  ' % str(run["question"])
		line += "recordings and the offline planner answered: the models were not asked."
	else:
		var mode := (
			"everyone given the same persona line"
			if str(run["persona_mode"]) == "neutral"
			else "each in their own persona"
		)
		line = '"%s"  ·  %s  ·  ' % [str(run["question"]), mode]
		var n_live := int(run["live_landed"])
		if not bool(run["done"]):
			line += "%d of %d answered." % [int(run["landed"]), total]
		elif n_live == total:
			line += "all five answered live."
		elif n_live == 0:
			line += "no live answer: all %d fell back (see the red notes)." % total
		else:
			line += (
				"%d of %d answered live, %d fell back (see the red notes)."
				% [n_live, total, total - n_live]
			)
	_say(line + "  " + HINT)


## The toggle's tooltip: what it changes, and that it changes nothing without a live key.
func _refresh_toggle() -> void:
	var can_live: bool = _asker != null and _asker.live_possible()
	toggle.tooltip_text = (
		"Same persona line for everyone; each mayor still sees its own district."
		if can_live
		else "No live key: answers are recordings, so this changes nothing."
	)


func _say(t: String, warn: bool = false) -> void:
	status.text = t
	status.add_theme_color_override("font_color", S.AMBER if warn else S.TEXT_DIM)


func _controls() -> HBoxContainer:
	var h := HBoxContainer.new()
	h.name = "Controls"
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_theme_constant_override("separation", 10)
	input = LineEdit.new()
	input.name = "Question"
	input.placeholder_text = "e.g. Your district lost power and the treasury is empty. What now?"
	input.max_length = ArenaAsk.MAX_QUESTION
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	input.custom_minimum_size = Vector2(300, 32)
	input.mouse_filter = Control.MOUSE_FILTER_STOP
	input.text_submitted.connect(func(t: String) -> void: submit(t))
	h.add_child(input)
	ask_button = S.pill_button("Ask", 14)
	ask_button.name = "Ask"
	ask_button.focus_mode = Control.FOCUS_NONE
	ask_button.pressed.connect(func() -> void: submit(input.text))
	h.add_child(ask_button)
	toggle = CheckButton.new()
	toggle.name = "Neutral"
	toggle.text = "Same persona for all five"
	toggle.tooltip_text = ""
	toggle.focus_mode = Control.FOCUS_NONE
	toggle.add_theme_font_size_override("font_size", 14)
	toggle.toggled.connect(func(on: bool) -> void: neutral = on)
	h.add_child(toggle)
	return h


func _footer() -> HBoxContainer:
	var bar := HBoxContainer.new()
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.alignment = BoxContainer.ALIGNMENT_END
	bar.add_theme_constant_override("separation", 6)
	bar.add_child(S.key_cap("Esc", 12))
	var close := S.pill_button("Close", 13)
	close.name = "Close"
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(func() -> void: close_requested.emit())
	bar.add_child(close)
	return bar
