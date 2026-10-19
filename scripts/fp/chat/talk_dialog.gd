extends Control
## Face-to-face conversation with a resident (slice C §4), and the "Ask someone here" answer.
## A 600x220 card at bottom-centre over a soft bottom gradient (the upper 60 % of the screen stays
## clear for A's two-shot): avatar, name, job, mood face, where they are, their line, quick replies
## and a free-text line. Each player line makes one ChatterMinds.talk call (20 per conversation);
## replies fall back to the offline voice after 8 s of feed time. C is the only emitter of
## bus.conversation_changed: (id, true) in the frame &"talk" is pushed, before the card shows, and
## exactly one (id, false) on every close path. Only the resident's id is stored; every turn looks
## them up again with residents.find(id).

const S := preload("res://scripts/fp/ui/chat_panel_style.gd")
const W := preload("res://scripts/fp/ui/chat_panel_widgets.gd")
const T := preload("res://scripts/fp/chat/chat_text.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")

const CARD_W := 600.0
const CARD_H := 220.0
const BOTTOM_GAP := 26.0
const FADE_SECONDS := 0.22
const MAX_LINES := 20
const FALLBACK_MS := 8000
const GOODBYE_HOLD_MS := 1300
const INPUT_MAX := 140
const PUBLIC_LINE_CHANCE := 0.2
const EMOTE_TEXT := {"wave": "waves", "shrug": "shrugs", "angry": "frowns", "laugh": "laughs"}
const STATE_TEXT := {"home": "at home", "work": "at work", "working": "at work", "shopping": "out shopping", "park": "at the park", "stadium": "at the stadium", "visit_friend": "visiting a friend", "help_neighbors": "helping out", "protest": "at a protest", "commuting": "on the way", "helping": "helping out"}

## The conversation ended (resident id; "" for an "Ask someone here" answer).
signal ended(resident_id: String)

var ctx: FpContext
var feed: ChatFeed
var minds: ChatterMinds
## Posts a resident's public line: func(r: Dictionary, text: String) (the chat feature).
var post_line: Callable = Callable()
## "" (closed), "talk" (a resident) or "ask" (an "Ask someone here" answer).
var mode: String = ""
var active_id: String = ""
## The player's feet when the conversation opened (the distance rule).
var anchor: Vector3 = Vector3.ZERO
## Player lines in this conversation (each made one talk call).
var lines: int = 0
var waiting: bool = false
## The free-text line (tests focus it).
var input: LineEdit

var _name: String = ""
var _turns: Array = []
var _last_said: String = ""
var _wait_since: int = 0
var _token: int = 0
var _closing_ms: int = -1
var _mood_total: float = 0.0
var _subjects: Array[Dictionary] = []
var _tween: Tween
var _card: PanelContainer
var _shade: TextureRect
var _avatar: Control
var _avatar_slot: Control
var _name_l: Label
var _sub_l: Label
var _mood_face: Control
var _mood_l: Label
var _mood_box: Control
var _you_l: Label
var _emote_l: Label
var _text_l: Label
var _dots: Control
var _quick: HFlowContainer
var _input_row: HBoxContainer


## Builds the (hidden) card in the overlay slot.
func setup(p_ctx: FpContext, p_feed: ChatFeed, p_minds: ChatterMinds) -> void:
	ctx = p_ctx
	feed = p_feed
	minds = p_minds
	name = "TalkDialog"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	_build()


## Opens a conversation with resident id: pushes &"talk", emits conversation_changed(id, true)
## (before the card is visible), records the anchor and shows their opening line. A conversation
## already open with someone else is closed first. Returns false when the resident is gone.
func open(id: String) -> bool:
	if ctx == null or ctx.residents == null:
		return false
	var r := ctx.residents.find(id)
	if r.is_empty():
		return false
	if mode != "":
		end()
	mode = "talk"
	active_id = id
	_name = str(r["name"])
	_hide_now()
	ctx.push_modal(&"talk")
	if ctx.bus != null:
		ctx.bus.conversation_changed.emit(id, true)
	anchor = ctx.player_position()
	_reset_turns()
	_fill_header_resident(r)
	var hello := minds.greeting(r) if minds != null else "Hi."
	_turns.append({"who": "them", "text": hello})
	_show_line(hello, minds.greeting_emote(r) if minds != null else "none", "")
	_build_quick(r)
	_input_row.visible = true
	_appear()
	return true


## Opens the card for an "Ask someone here" answer that is still coming (typing dots).
func open_ask(place: String) -> void:
	if mode == "talk":
		end()
	if mode == "":
		ctx.push_modal(&"talk")
	mode = "ask"
	active_id = ""
	anchor = ctx.player_position()
	_reset_turns()
	_set_avatar(Color("#5A6B82"), "", "person")
	_name_l.text = "Someone nearby"
	_sub_l.text = place
	_mood_box.visible = false
	_show_typing()
	_set_quick([["Thanks", "Thanks"]])
	_input_row.visible = false
	_appear()


## Fills an open "Ask someone here" card with the answer (already filtered).
func set_ask_answer(speaker: String, place: String, says: String) -> void:
	if mode != "ask":
		return
	_name_l.text = speaker
	_sub_l.text = place
	_show_line(says, "none", "")


## Ends the conversation (or closes the ask card): emits exactly one conversation_changed(id,
## false) for a resident, pops &"talk" and fades out. notice (optional) becomes a toast.
func end(notice: String = "") -> void:
	if mode == "":
		return
	var was := mode
	var id := active_id
	mode = ""
	active_id = ""
	_token += 1
	waiting = false
	_closing_ms = -1
	if input.has_focus():
		input.unedit()
		input.release_focus()
	if was == "talk":
		_finish_effects(id)
		if ctx.bus != null:
			ctx.bus.conversation_changed.emit(id, false)
	ctx.pop_modal(&"talk")
	_disappear()
	if not notice.is_empty() and ctx.bus != null:
		ctx.bus.toast.emit(notice, "info")
	ended.emit(id)


## True while the free-text line has focus (the player is typing a line).
func is_typing() -> bool:
	return input != null and input.has_focus()


## The line the card shows now (the resident's reply or the ask answer; "" while typing).
func shown_text() -> String:
	return _text_l.text if _text_l.visible else ""


## The player says text (a quick reply or the free-text line). One talk call per line; ignored
## while a reply is pending.
func say(text: String) -> void:
	if mode == "ask":
		end()
		return
	if mode != "talk" or waiting or _closing_ms >= 0:
		return
	var t := text.strip_edges().left(INPUT_MAX)
	if t.is_empty():
		return
	var r := ctx.residents.find(active_id)
	if r.is_empty():
		end("%s has left." % _name)
		return
	_last_said = t
	if ChatterMinds.intent_of(t) == "bye":
		var bye := minds.talk_heuristic(r, _turns, t)
		_turns.append({"who": "you", "text": t})
		_show_line(str(bye["reply"]), "wave", t)
		_closing_ms = feed.now_ms + GOODBYE_HOLD_MS
		return
	if lines >= MAX_LINES:
		_show_line("Sorry, I really have to get going. Nice talking to you!", "wave", t)
		_closing_ms = feed.now_ms + GOODBYE_HOLD_MS
		return
	lines += 1
	Analytics.track("talk_message", {"chars": t.length(), "line": lines})
	var before := _turns.duplicate()
	_turns.append({"who": "you", "text": t})
	waiting = true
	_wait_since = feed.now_ms
	_token += 1
	var tok := _token
	_you_l.text = "You: " + t
	_you_l.visible = true
	_show_typing()
	var res: Dictionary = await minds.talk(r, before, t)
	if tok != _token or mode != "talk":
		return
	_receive(res)


## Timed rules, driven by the feed clock: the distance rule (player feet vs anchor), the resident
## leaving, the 8 s fallback and the goodbye hold.
func on_pump(now_ms: int) -> void:
	if mode == "":
		return
	var p := ctx.player_position()
	if Vector2(p.x - anchor.x, p.z - anchor.z).length() > 2.0 * WS.TALK_RANGE:
		end()
		return
	if mode == "talk":
		var r := ctx.residents.find(active_id) if ctx.residents != null else {}
		if r.is_empty():
			end("%s has left." % _name)
			return
		if waiting and now_ms - _wait_since >= FALLBACK_MS:
			_token += 1
			var before := _turns.slice(0, _turns.size() - 1)
			_receive(minds.talk_heuristic(r, before, _last_said))
	if _closing_ms >= 0 and now_ms >= _closing_ms:
		end()


func _input(event: InputEvent) -> void:
	if mode == "":
		return
	if not event.is_echo() and event.is_action_pressed("pause_menu"):
		end()
		get_viewport().set_input_as_handled()
	elif input.has_focus() and (event.is_action_pressed("ui_focus_next") or event.is_action_pressed("ui_focus_prev")):
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if mode == "" or event.is_echo() or not event.is_pressed():
		return
	if event.is_action_pressed("chat_open") and _input_row.visible:
		input.grab_focus()
		input.edit()
		get_viewport().set_input_as_handled()
		return
	var key := event as InputEventKey
	if key != null and not input.has_focus():
		var k := int(key.physical_keycode) - KEY_1
		if k >= 0 and k < _quick.get_child_count():
			(_quick.get_child(k) as Button).pressed.emit()
			get_viewport().set_input_as_handled()


func _receive(res: Dictionary) -> void:
	waiting = false
	_dots.visible = false
	var r := ctx.residents.find(active_id)
	if r.is_empty():
		end("%s has left." % _name)
		return
	var reply := str(res.get("reply", "")).strip_edges()
	if reply.is_empty():
		reply = "Hm."
	_turns.append({"who": "them", "text": reply})
	_show_line(reply, str(res.get("emote", "none")), _last_said)
	var delta := clampf(float(res.get("mood_delta", 0.0)), -1.0, 1.0)
	var allowed := clampf(_mood_total + delta, -1.0, 1.0) - _mood_total
	if absf(allowed) > 0.0:
		_mood_total += allowed
		_nudge_mood(r, allowed)
		_refresh_mood(r)
	var mem := str(res.get("memory", "")).strip_edges()
	if not mem.is_empty():
		_subjects.append({"text": mem, "live": str(res.get("source", "")) == "live"})


## One memory per conversation (and sometimes a public chat line), when it ends.
func _finish_effects(id: String) -> void:
	if lines == 0 or ctx.residents == null:
		return
	var r := ctx.residents.find(id)
	if r.is_empty():
		return
	var subject := "the city"
	var live := false
	for k in range(_subjects.size() - 1, -1, -1):
		var s: Dictionary = _subjects[k]
		var t := str(s["text"])
		if t not in ["saying hello", "saying goodbye"]:
			subject = t
			live = bool(s["live"])
			break
	var line := ("talked with a visitor: " + subject.trim_suffix(".").to_lower()) if live else ("talked with a visitor about " + subject)
	_remember(r, line)
	var rng := RandomNumberGenerator.new()
	rng.seed = T.h(id + str(ctx.sim.day) + str(lines))
	if rng.randf() < PUBLIC_LINE_CHANCE and post_line.is_valid():
		var about := subject if not live else "how things are going"
		post_line.call(r, "Just met someone asking about %s. Nice to see new faces around." % about)


func _remember(r: Dictionary, line: String) -> void:
	if ctx.residents.has_method("remember"):
		ctx.residents.call("remember", r, line)
		return
	var mem: Array = r.get("memory", [])
	mem.append("Day %d: %s" % [ctx.sim.day, line])
	while mem.size() > 8:
		mem.pop_front()
	r["memory"] = mem


func _nudge_mood(r: Dictionary, delta: float) -> void:
	if ctx.residents.has_method("nudge_mood"):
		ctx.residents.call("nudge_mood", r, delta)
		return
	r["mood"] = clampf(float(r.get("mood", 5.0)) + delta, 0.0, 10.0)


func _reset_turns() -> void:
	_turns = []
	_subjects.clear()
	lines = 0
	waiting = false
	_token += 1
	_closing_ms = -1
	_mood_total = 0.0
	_last_said = ""
	if input != null:
		input.clear()


# ---------------------------------------------------------------- presentation

func _fill_header_resident(r: Dictionary) -> void:
	var nm := str(r["name"])
	_set_avatar(S.avatar_color(str(r["id"]), "resident", -1), T.initials(nm), "")
	_name_l.text = nm
	var job := T.cap(str(r.get("job_title", "")))
	var at := int(r.get("at", r.get("home", -1)))
	var state := str(r.get("state", "home"))
	var where: String = STATE_TEXT.get(state, state.replace("_", " "))
	if where.length() > 28:
		where = "out and about"
	var place := ctx.directory.place_label(at) if ctx.directory != null and at >= 0 else ""
	_sub_l.text = "%s, %d  ·  %s%s" % [job, int(r.get("age", 30)), where, (", " + place) if not place.is_empty() and state != "home" else ""]
	if state == "home" and not place.is_empty():
		_sub_l.text = "%s, %d  ·  lives at %s" % [job, int(r.get("age", 30)), place]
	_mood_box.visible = true
	_refresh_mood(r)


func _refresh_mood(r: Dictionary) -> void:
	var m := float(r.get("mood", 5.0))
	(_mood_face as W.MoodFace).set_mood(m)
	_mood_l.text = S.mood_word(m)
	_mood_l.add_theme_color_override("font_color", S.mood_color(m))


func _set_avatar(fill: Color, initials: String, icon: String) -> void:
	if _avatar != null:
		_avatar.queue_free()
	_avatar = W.Avatar.new(fill, initials, 48.0, icon)
	_avatar_slot.add_child(_avatar)


func _show_line(text: String, emote: String, you: String) -> void:
	_dots.visible = false
	_text_l.visible = true
	_text_l.text = text
	var e: String = EMOTE_TEXT.get(emote, "")
	_emote_l.visible = not e.is_empty()
	_emote_l.text = "*%s*" % e
	_you_l.visible = not you.is_empty()
	_you_l.text = "You: " + you


func _show_typing() -> void:
	_text_l.visible = false
	_emote_l.visible = false
	_dots.visible = true


func _build_quick(r: Dictionary) -> void:
	var opts: Array = [["How's life?", "How's life?"], ["What's going on?", "What happened around here?"]]
	var d := ctx.sim.district[int(r["home"])] if ctx.sim != null else -1
	if d >= 0 and d < D.MAYORS.size():
		var disp := str(D.MAYORS[d]["display"])
		opts.append(["Mayor %s?" % disp.get_slice(" ", disp.get_slice_count(" ") - 1), "What do you think of Mayor %s?" % disp])
	opts.append(["Goodbye", "Goodbye"])
	_set_quick(opts)


## opts: [label, line said] pairs; "Thanks" closes the ask card.
func _set_quick(opts: Array) -> void:
	for c in _quick.get_children():
		_quick.remove_child(c)
		c.queue_free()
	for k in range(opts.size()):
		var label := str(opts[k][0])
		var line := str(opts[k][1])
		var leave := line in ["Goodbye", "Thanks"]
		var b := S.pill_button(label, Color(1, 1, 1, 0.08) if not leave else Color(0.9, 0.3, 0.28, 0.22), S.TEXT, 13)
		b.name = "Quick%d" % k
		b.tooltip_text = "%s  (key %d)" % [line, k + 1]
		b.pressed.connect(say.bind(line) if line != "Thanks" else end.bind(""))
		_quick.add_child(b)


func _appear() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	visible = true
	modulate.a = 0.0
	_card.offset_top = -CARD_H - BOTTOM_GAP + 14.0
	_card.offset_bottom = -BOTTOM_GAP + 14.0
	if not is_inside_tree():
		modulate.a = 1.0
		return
	_tween = create_tween().set_parallel(true)
	_tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	_tween.tween_property(self, "modulate:a", 1.0, FADE_SECONDS)
	_tween.tween_property(_card, "offset_top", -CARD_H - BOTTOM_GAP, FADE_SECONDS)
	_tween.tween_property(_card, "offset_bottom", -BOTTOM_GAP, FADE_SECONDS)


func _hide_now() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	visible = false


func _disappear() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	if not is_inside_tree():
		visible = false
		return
	_tween = create_tween()
	_tween.set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_CUBIC)
	_tween.tween_property(self, "modulate:a", 0.0, FADE_SECONDS * 0.8)
	_tween.tween_callback(func() -> void: visible = mode != "")


func _build() -> void:
	_shade = TextureRect.new()
	_shade.name = "Shade"
	_shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shade.anchor_left = 0.0
	_shade.anchor_right = 1.0
	_shade.anchor_top = 1.0
	_shade.anchor_bottom = 1.0
	_shade.offset_top = -330
	_shade.stretch_mode = TextureRect.STRETCH_SCALE
	_shade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	var g := Gradient.new()
	g.set_color(0, Color(0, 0, 0, 0))
	g.set_color(1, Color(0.0, 0.01, 0.03, 0.62))
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill_from = Vector2(0, 0)
	gt.fill_to = Vector2(0, 1)
	gt.width = 4
	gt.height = 64
	_shade.texture = gt
	add_child(_shade)
	_card = PanelContainer.new()
	_card.name = "Card"
	_card.mouse_filter = Control.MOUSE_FILTER_STOP
	_card.anchor_left = 0.5
	_card.anchor_right = 0.5
	_card.anchor_top = 1.0
	_card.anchor_bottom = 1.0
	_card.offset_left = -CARD_W * 0.5
	_card.offset_right = CARD_W * 0.5
	_card.offset_top = -CARD_H - BOTTOM_GAP
	_card.offset_bottom = -BOTTOM_GAP
	_card.grow_vertical = Control.GROW_DIRECTION_BEGIN
	var sb := S.box(Color(0.04, 0.055, 0.08, 0.93), 20, Color(1, 1, 1, 0.09), 1, Vector4(18, 14, 18, 14))
	sb.shadow_color = Color(0, 0, 0, 0.45)
	sb.shadow_size = 22
	sb.shadow_offset = Vector2(0, 6)
	_card.add_theme_stylebox_override("panel", sb)
	add_child(_card)
	var v := VBoxContainer.new()
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_theme_constant_override("separation", 8)
	_card.add_child(v)
	var head := HBoxContainer.new()
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_theme_constant_override("separation", 12)
	v.add_child(head)
	_avatar_slot = CenterContainer.new()
	_avatar_slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_avatar_slot.custom_minimum_size = Vector2(48, 48)
	head.add_child(_avatar_slot)
	var who := VBoxContainer.new()
	who.mouse_filter = Control.MOUSE_FILTER_IGNORE
	who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	who.alignment = BoxContainer.ALIGNMENT_CENTER
	who.add_theme_constant_override("separation", 0)
	head.add_child(who)
	_name_l = S.label("", S.display_font(), 22, Color.WHITE)
	who.add_child(_name_l)
	_sub_l = S.label("", S.body_font(), 13, S.TEXT_DIM)
	_sub_l.clip_text = true
	_sub_l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_sub_l.custom_minimum_size.x = 10
	who.add_child(_sub_l)
	_mood_box = PanelContainer.new()
	_mood_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mood_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_mood_box.add_theme_stylebox_override("panel", S.box(Color(1, 1, 1, 0.06), 13, Color(1, 1, 1, 0.07), 1, Vector4(7, 4, 10, 4)))
	head.add_child(_mood_box)
	var mh := HBoxContainer.new()
	mh.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mh.add_theme_constant_override("separation", 6)
	_mood_box.add_child(mh)
	_mood_face = W.MoodFace.new(18.0)
	mh.add_child(_mood_face)
	_mood_l = S.label("", S.display_font(), 13, S.TEXT)
	mh.add_child(_mood_l)
	var close_b := Button.new()
	close_b.focus_mode = Control.FOCUS_NONE
	close_b.custom_minimum_size = Vector2(30, 30)
	close_b.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	close_b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	close_b.tooltip_text = "Leave (Esc)"
	for st in ["normal", "hover", "pressed", "hover_pressed"]:
		close_b.add_theme_stylebox_override(st, S.box(Color(1, 1, 1, 0.12 if st == "hover" else 0.05), 15))
	close_b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	var ci := W.Icon.new("close", S.TEXT_DIM, 14.0)
	ci.position = Vector2(8, 8)
	close_b.add_child(ci)
	close_b.pressed.connect(end.bind(""))
	head.add_child(close_b)
	var speech := VBoxContainer.new()
	speech.mouse_filter = Control.MOUSE_FILTER_IGNORE
	speech.size_flags_vertical = Control.SIZE_EXPAND_FILL
	speech.add_theme_constant_override("separation", 3)
	v.add_child(speech)
	_you_l = S.label("", S.italic_font(), 13, Color("#7FE8A8"))
	_you_l.clip_text = true
	_you_l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_you_l.custom_minimum_size.x = 10
	speech.add_child(_you_l)
	var line := HBoxContainer.new()
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_theme_constant_override("separation", 6)
	speech.add_child(line)
	_emote_l = S.label("", S.italic_font(), 15, S.GOLD)
	_emote_l.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	line.add_child(_emote_l)
	_text_l = S.wrap_label("", S.body_font(), 17, Color.WHITE)
	_text_l.max_lines_visible = 3
	_text_l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	line.add_child(_text_l)
	_dots = W.Dots.new(Color(1, 1, 1, 0.85))
	_dots.visible = false
	line.add_child(_dots)
	_quick = HFlowContainer.new()
	_quick.name = "Quick"
	_quick.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_quick.add_theme_constant_override("h_separation", 6)
	_quick.add_theme_constant_override("v_separation", 4)
	v.add_child(_quick)
	_input_row = HBoxContainer.new()
	_input_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_input_row.add_theme_constant_override("separation", 8)
	v.add_child(_input_row)
	input = LineEdit.new()
	input.name = "TalkInput"
	input.placeholder_text = "Say something…  (Enter)"
	input.max_length = INPUT_MAX
	input.keep_editing_on_text_submit = true
	input.context_menu_enabled = false
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	input.custom_minimum_size.y = 32
	S.style_line_edit(input, 13)
	input.text_submitted.connect(func(t: String) -> void:
		if t.strip_edges().is_empty():
			input.unedit()
			input.release_focus()
			return
		input.clear()
		say(t))
	input.editing_toggled.connect(func(on: bool) -> void:
		if not on and input.has_focus():
			input.release_focus())
	_input_row.add_child(input)
	var send := S.pill_button("Say", S.GOLD, Color(0.13, 0.09, 0.02), 14, S.display_font())
	send.pressed.connect(func() -> void:
		var t := input.text
		input.clear()
		say(t))
	_input_row.add_child(send)
