extends Control
## Top-centre indicator chips (slice B): population, mood and treasury on the left of the clock
## chip (day, time, speed); power, water, alerts and the "City hall in session" dot on its right,
## so the clock stays centred while the alert chips come and go. Values refresh on stats_updated and
## time_scale_changed and at 4 Hz for the clock; a changed value pulses its chip for 0.3 s, and only
## a new incident blinks (the alerts chip, twice).

const D := preload("res://scripts/sim/sim_defs.gd")
const S := preload("res://scripts/fp/ui/hud_style.gd")
const HudIcon := preload("res://scripts/fp/ui/hud_icon.gd")

const REFRESH := 0.25
const PULSE := 0.3
const BLINK := 0.9
const ICON_PX := 17.0
const VALUE_PX := 17
## Ids of the chips, in screen order.
const IDS := ["pop", "mood", "money", "power", "water", "time", "alerts", "session"]
const STATE_COLORS := {"ok": S.TEXT, "good": S.GOOD, "warn": S.AMBER, "fail": S.RED}

var ctx: FpContext
## id -> {"panel": PanelContainer, "box": StyleBoxFlat, "icon": HudIcon, "value": Label,
## "state": String, "pulse": float, "line": Color}
var _chips: Dictionary = {}
var _day: Label
var _speed: Label
var _alert_text: Label
var _t: float = 0.0
var _blink: float = 0.0
var _last_event_id: int = -1
var _bound: bool = false


## Builds the chips and connects to the sim and bus (refreshes at once).
func setup(p_ctx: FpContext) -> void:
	ctx = p_ctx
	name = "Chips"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# The top_bar slot starts 12 px from the top; 12 more puts the chips on the 24 px safe margin.
	offset_top = 12
	offset_left = 8
	offset_right = -8
	var row := HBoxContainer.new()
	row.name = "Row"
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	row.add_theme_constant_override("separation", 8)
	add_child(row)
	var left := _group(row, BoxContainer.ALIGNMENT_END, true)
	var mid := _group(row, BoxContainer.ALIGNMENT_CENTER, false)
	var right := _group(row, BoxContainer.ALIGNMENT_BEGIN, true)
	_chip(left, "pop", "person")
	_chip(left, "mood", "face")
	_chip(left, "money", "coin")
	_time_chip(mid)
	_chip(right, "power", "bolt")
	_chip(right, "water", "drop")
	_chip(right, "alerts", "alert")
	_alert_text = S.chip_label("", 15, S.TEXT_DIM, S.font())
	_alert_text.name = "Latest"
	(_chips["alerts"]["panel"] as PanelContainer).get_child(0).add_child(_alert_text)
	_session_chip(right)
	if ctx.sim != null:
		ctx.sim.stats_updated.connect(refresh)
		_bound = true
	if ctx.bus != null:
		ctx.bus.time_scale_changed.connect(_on_time_scale)
	_last_event_id = _newest_event_id()
	refresh()


## Disconnects from the sim (the HUD outlives nothing, but a reload keeps the same sim).
func teardown() -> void:
	if _bound and ctx.sim != null and ctx.sim.stats_updated.is_connected(refresh):
		ctx.sim.stats_updated.disconnect(refresh)
	_bound = false


## Re-reads every value from the sim, residents, sky and mode. Sets a label only when its text
## changed, so a 4 Hz refresh relayouts nothing in the steady state.
func refresh() -> void:
	if ctx == null or ctx.sim == null:
		return
	var sim := ctx.sim
	var st := sim.stats
	_put("pop", S.fmt(int(st.get("population", 0))), "ok")
	var mood := mood_value()
	var mood_state := (
		"good" if mood >= 6.5 else ("ok" if mood >= 4.5 else ("warn" if mood >= 3.0 else "fail"))
	)
	_put("mood", "%.1f" % mood, mood_state)
	(_chips["mood"]["icon"] as HudIcon).mood = clampf(mood / 10.0, 0.0, 1.0)
	var funds := sim.total_funds()
	_put("money", S.money(funds), "warn" if funds < 0 else "ok")
	_util(
		"power",
		float(st.get("power_need", 0.0)),
		float(st.get("power_cap", 0.0)),
		int(st.get("unpowered", 0))
	)
	_util(
		"water",
		float(st.get("water_need", 0.0)),
		float(st.get("water_cap", 0.0)),
		int(st.get("unwatered", 0))
	)
	_refresh_clock()
	var n := sim.events.size()
	var alerts: Dictionary = _chips["alerts"]
	(alerts["panel"] as Control).visible = n > 0
	if n > 0:
		var ev: Dictionary = sim.events[n - 1]
		_put("alerts", str(n), "fail")
		var latest := D.debrand(str(ev.get("label", "Incident")))
		if _alert_text.text != latest:
			_alert_text.text = latest
		var id := int(ev.get("id", -1))
		if id != _last_event_id:
			_blink = BLINK
		_last_event_id = id
	else:
		_last_event_id = -1
	(_chips["session"]["panel"] as Control).visible = sim.waiting_for_ai


## Mood on the 0..10 scale: the residents' sentiment when they are active, else tile happiness.
func mood_value() -> float:
	if ctx.residents != null and ctx.residents.is_active():
		return float(ctx.residents.sentiment.get("mood", 0.0)) * 10.0
	return float(ctx.sim.stats.get("happiness", 0.0)) * 10.0


## State of a chip: "ok", "good", "warn" or "fail" (tests and the legend read it).
func state_of(id: String) -> String:
	return str(_chips[id]["state"]) if _chips.has(id) else ""


## The value text of a chip ("1,168", "6.1", "−$3,222", "82%", "10:30", "2").
func text_of(id: String) -> String:
	return (_chips[id]["value"] as Label).text if _chips.has(id) else ""


## The chip's panel (tests check visibility and layout).
func chip(id: String) -> Control:
	return _chips[id]["panel"] if _chips.has(id) else null


func _process(delta: float) -> void:
	_t += delta
	if _t >= REFRESH:
		_t = 0.0
		_refresh_clock()
		if ctx != null and ctx.sim != null:
			(_chips["session"]["panel"] as Control).visible = ctx.sim.waiting_for_ai
	for id: String in _chips:
		var c: Dictionary = _chips[id]
		var p := float(c["pulse"])
		if p <= 0.0:
			continue
		p = maxf(0.0, p - delta)
		c["pulse"] = p
		var k := sin(p / PULSE * PI)
		var sb: StyleBoxFlat = c["box"]
		sb.bg_color = S.CHIP_BG.lerp(Color(0.12, 0.14, 0.2, 0.55), k)
		sb.border_color = (c["line"] as Color).lerp(Color(1, 1, 1, 0.5), k)
	if _blink > 0.0:
		_blink = maxf(0.0, _blink - delta)
		var a := 1.0 - 0.75 * absf(sin((BLINK - _blink) / BLINK * TAU))
		(_chips["alerts"]["panel"] as Control).modulate.a = a if _blink > 0.0 else 1.0


func _refresh_clock() -> void:
	if ctx == null or ctx.sim == null:
		return
	var day := "Day %d" % ctx.sim.day
	if _day.text != day:
		_day.text = day
	var clock := ctx.sky.clock_text() if ctx.sky != null else "--:--"
	_put("time", clock, "ok", false)
	var ts := ctx.mode.time_scale if ctx.mode != null else 1
	var sp := "%d×" % ts
	if _speed.text != sp:
		_speed.text = sp
		_speed.add_theme_color_override("font_color", S.TEXT_FAINT if ts == 1 else S.ACCENT)


func _on_time_scale(_s: int) -> void:
	_refresh_clock()


## need / cap as a load percentage; amber above 85 %, red when over capacity or any building is cut off.
func _util(id: String, need: float, cap: float, cut_off: int) -> void:
	var ratio := need / cap if cap > 0.0 else (1.5 if need > 0.0 else 0.0)
	var state := "good"
	if ratio > 1.0 or cut_off > 0:
		state = "fail"
	elif ratio > 0.85:
		state = "warn"
	var txt := "%d%%" % roundi(ratio * 100.0) if cap > 0.0 else ("—" if need <= 0.0 else "0%")
	_put(id, txt, state)


## Sets a chip's value and state; a changed value pulses the chip (pulse = false for the clock).
func _put(id: String, value: String, state: String, pulse: bool = true) -> void:
	var c: Dictionary = _chips[id]
	var l: Label = c["value"]
	if l.text != value:
		if pulse and not l.text.is_empty():
			c["pulse"] = PULSE
		l.text = value
	if str(c["state"]) != state:
		c["state"] = state
		var col: Color = STATE_COLORS.get(state, S.TEXT)
		# "good" tints only the icon: values stay white unless something needs attention.
		l.add_theme_color_override("font_color", S.TEXT if state == "good" else col)
		(c["icon"] as HudIcon).color = col if state != "ok" else S.TEXT
		# A chip that needs attention carries its colour on the hairline too.
		c["line"] = Color(col, 0.9) if state in ["warn", "fail"] else S.CHIP_LINE
		(c["box"] as StyleBoxFlat).border_color = c["line"]


func _group(row: HBoxContainer, align: BoxContainer.AlignmentMode, expand: bool) -> HBoxContainer:
	var g := HBoxContainer.new()
	g.mouse_filter = Control.MOUSE_FILTER_IGNORE
	g.alignment = align
	g.add_theme_constant_override("separation", 8)
	if expand:
		g.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		g.size_flags_stretch_ratio = 1.0
	row.add_child(g)
	return g


func _chip(parent: Control, id: String, icon: String) -> Dictionary:
	var sb := S.chip_box()
	var p := PanelContainer.new()
	p.name = id.capitalize()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_theme_stylebox_override("panel", sb)
	var h := HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_theme_constant_override("separation", 7)
	p.add_child(h)
	# On a backed pill the outline is enough: no icon or text shadow (fewer draw passes).
	var ic := HudIcon.new(icon, S.TEXT, ICON_PX)
	ic.shadow = false
	ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(ic)
	var v := S.chip_label("", VALUE_PX, S.TEXT, S.font())
	v.name = "Value"
	v.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	h.add_child(v)
	parent.add_child(p)
	var c := {
		"panel": p,
		"box": sb,
		"icon": ic,
		"value": v,
		"state": "",
		"pulse": 0.0,
		"line": S.CHIP_LINE
	}
	_chips[id] = c
	return c


func _time_chip(parent: Control) -> void:
	var c := _chip(parent, "time", "clock")
	var h: HBoxContainer = (c["panel"] as PanelContainer).get_child(0)
	_day = S.chip_label("", VALUE_PX, S.TEXT_DIM, S.font())
	_day.name = "Day"
	h.add_child(_day)
	h.move_child(_day, 1)
	_speed = S.chip_label("", 13, S.TEXT_FAINT, S.bold())
	_speed.name = "Speed"
	_speed.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	h.add_child(_speed)


func _session_chip(parent: Control) -> void:
	var c := _chip(parent, "session", "dot")
	(c["icon"] as HudIcon).color = S.AMBER
	(c["icon"] as HudIcon).custom_minimum_size = Vector2(10, 10)
	c["state"] = "warn"
	var v: Label = c["value"]
	v.text = "City hall in session"
	v.add_theme_font_size_override("font_size", 14)
	v.add_theme_color_override("font_color", S.TEXT_DIM)
	(c["panel"] as Control).visible = false


func _newest_event_id() -> int:
	if ctx.sim == null or ctx.sim.events.is_empty():
		return -1
	return int(ctx.sim.events[ctx.sim.events.size() - 1].get("id", -1))
