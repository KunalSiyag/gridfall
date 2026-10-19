extends Control
## Place card (slice B) on interact_requested for kinds building, vehicle and pedestrian (a named
## resident is C's conversation, never a card). A building shows its name, address, district, use
## and density, status (power, water, fire, construction), and up to 6 residents who live or work
## there, with an "Ask someone here" button that emits card_action("ask_here", tile) for C to
## answer. B makes no LLM call. Pushes the &"card" modal; E or Esc closes it (consumed).

const D := preload("res://scripts/sim/sim_defs.gd")
const S := preload("res://scripts/fp/ui/hud_style.gd")
const HudIcon := preload("res://scripts/fp/ui/hud_icon.gd")

const MODAL := &"card"
const WIDTH := 400.0
const MAX_NAMES := 6
const SLIDE := 0.15
const KINDS := ["building", "vehicle", "pedestrian"]
const ZONE_NAMES := {D.ZONE_R: "Residential", D.ZONE_C: "Commercial", D.ZONE_I: "Industrial"}
const DENSITY := ["undeveloped", "low density", "mid density", "high density"]

var ctx: FpContext
var hud: Node
## The target the card shows ({} when closed).
var target: Dictionary = {}
## The Ask button (null unless a building card is open).
var ask_button: Button
var _panel: PanelContainer
var _body: VBoxContainer
var _age: float = 0.0
var _pushed: bool = false


func setup(p_ctx: FpContext, p_hud: Node) -> void:
	ctx = p_ctx
	hud = p_hud
	name = "PlaceCard"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	_panel = S.panel(S.PANEL_BG, 12, 22, 18)
	_panel.name = "Card"
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.anchor_top = 0.5
	_panel.anchor_bottom = 0.5
	_panel.offset_left = -WIDTH - 72.0
	_panel.offset_right = -72.0
	_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(_panel)
	_body = VBoxContainer.new()
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.add_theme_constant_override("separation", 10)
	_panel.add_child(_body)
	if ctx.bus != null:
		ctx.bus.interact_requested.connect(_on_interact)


## True while the card shows.
func is_open() -> bool:
	return visible


## Every text line on the card (tests).
func texts() -> PackedStringArray:
	return S.owned_texts(_panel)


## Opens the card for a target dict (kinds building, vehicle, pedestrian).
func open(t: Dictionary) -> void:
	target = t
	ask_button = null
	for c in _body.get_children():
		_body.remove_child(c)
		c.queue_free()
	match str(t.get("kind", "")):
		"building":
			_build_building(int(t.get("tile", -1)))
		"vehicle":
			_build_vehicle(t)
		_:
			_build_pedestrian(t)
	_footer()
	visible = true
	_age = 0.0
	_panel.offset_top = 0
	_panel.offset_bottom = 0
	if not _pushed:
		ctx.push_modal(MODAL)
		_pushed = true
	if ask_button != null and ask_button.is_inside_tree():
		ask_button.grab_focus.call_deferred()


## Closes the card and pops its modal (safe when closed).
func close() -> void:
	visible = false
	target = {}
	ask_button = null
	if _pushed:
		_pushed = false
		ctx.pop_modal(MODAL)


func _on_interact(t: Dictionary) -> void:
	if visible or not str(t.get("kind", "")) in KINDS:
		return
	if ctx.player != null and ctx.player.photo_mode:
		return
	open(t)


func _process(delta: float) -> void:
	if not visible:
		return
	if _age < SLIDE:
		_age = minf(SLIDE, _age + delta)
		var k := _age / SLIDE
		modulate.a = k
		_panel.offset_left = -WIDTH - 72.0 + 16.0 * (1.0 - k) * (1.0 - k)
		_panel.offset_right = _panel.offset_left + WIDTH


func _unhandled_input(event: InputEvent) -> void:
	if not visible or event.is_echo():
		return
	if event.is_action_pressed("interact") or event.is_action_pressed("pause_menu"):
		close()
		get_viewport().set_input_as_handled()


func _on_ask() -> void:
	var tile := int(target.get("tile", -1))
	close()
	if ctx.bus != null and tile >= 0:
		ctx.bus.card_action.emit("ask_here", tile)


func _build_building(i: int) -> void:
	var dir := ctx.directory
	var sim := ctx.sim
	if i < 0 or sim == null or dir == null or i >= sim.kind.size():
		_title(D.debrand(str(target.get("label", "A building"))), "")
		return
	var name_ := dir.place_name(i)
	var addr := dir.address(i)
	var title := name_ if not name_.is_empty() else (addr if not addr.is_empty() else _use_of(i))
	var sub := PackedStringArray()
	if not addr.is_empty() and addr != title:
		sub.append(addr)
	sub.append(dir.district_name(i))
	_title(title, " · ".join(sub))
	_line(_use_of(i), S.TEXT)
	# Status.
	var status := HFlowContainer.new()
	status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	status.add_theme_constant_override("h_separation", 8)
	status.add_theme_constant_override("v_separation", 6)
	var site := sim.site_info(i)
	if sim.burning[i] > 0:
		status.add_child(_pill("alert", "On fire", S.RED))
	if not site.is_empty():
		status.add_child(_pill("info", "Under construction · %d%%" % int(site.get("percent_done", 0)), S.AMBER))
	var k := sim.kind[i]
	var serviced := sim.level[i] > 0 if D.is_zone(k) else not k in [D.EMPTY, D.ROAD, D.PARK, D.FOREST, D.SITE, D.RUBBLE]
	if serviced:
		status.add_child(_pill("bolt", "Powered" if sim.powered[i] > 0 else "No power", S.GOOD if sim.powered[i] > 0 else S.RED))
		status.add_child(_pill("drop", "Water" if sim.watered[i] > 0 else "No water", S.GOOD if sim.watered[i] > 0 else S.RED))
	if status.get_child_count() > 0:
		_body.add_child(status)
	# People.
	var lives := PackedStringArray()
	var works := PackedStringArray()
	if ctx.residents != null and ctx.residents.is_active():
		for r: Dictionary in ctx.residents.people:
			if lives.size() + works.size() >= MAX_NAMES:
				break
			var who := _person(r)
			if int(r.get("home", -1)) == i:
				lives.append(who)
			elif int(r.get("work", -1)) == i:
				works.append(who)
	if not lives.is_empty():
		_section("LIVES HERE", lives)
	if not works.is_empty():
		_section("WORKS HERE", works)
	ask_button = S.pill_button("Ask someone here", 15)
	ask_button.name = "Ask"
	ask_button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	ask_button.pressed.connect(_on_ask)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 2)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.add_child(gap)
	_body.add_child(ask_button)


func _build_vehicle(t: Dictionary) -> void:
	var data: Dictionary = t.get("data", {})
	var title := D.debrand(str(t.get("label", "A vehicle")))
	_title(title.substr(0, 1).to_upper() + title.substr(1), "")
	var bits := PackedStringArray()
	var st := str(data.get("state", ""))
	if not st.is_empty():
		bits.append(st)
	var dest := str(data.get("dest_label", ""))
	if not dest.is_empty():
		bits.append("to " + dest)
	if data.has("mood"):
		var m := float(data["mood"])
		bits.append("mood %d/10" % roundi(m * 10.0 if m <= 1.0 else m))
	if not bits.is_empty():
		_line(D.debrand(" · ".join(bits)), S.TEXT)


func _build_pedestrian(t: Dictionary) -> void:
	var title := D.debrand(str(t.get("label", "a pedestrian")))
	_title(title.substr(0, 1).to_upper() + title.substr(1), "")
	_line("Out and about on the street", S.TEXT_DIM)


func _use_of(i: int) -> String:
	var k := ctx.sim.kind[i]
	var lv := clampi(ctx.sim.level[i], 0, 3)
	if D.is_zone(k):
		var use := str(ZONE_NAMES.get(k, "Zoned lot"))
		var biz := ctx.directory.business_kind(i)
		var line := "%s · %s" % [use, DENSITY[lv]]
		return (biz.capitalize() + " · " + line) if not biz.is_empty() else line
	if k == D.PARK:
		return "Public park"
	var lm := ctx.directory.landmark_name(i)
	return "Public building" if not lm.is_empty() else "Lot"


func _person(r: Dictionary) -> String:
	var n := str(r.get("name", "A resident"))
	var job := str(r.get("job_title", ""))
	return D.debrand(n + (", " + job if not job.is_empty() else ""))


func _title(t: String, sub: String) -> void:
	var l := S.plain(D.debrand(t), 22, S.WHITE, S.bold())
	l.name = "Title"
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(WIDTH - 44.0, 0)
	_body.add_child(l)
	if not sub.is_empty():
		var s := S.plain(D.debrand(sub), 14, S.TEXT_DIM, S.font())
		s.name = "Subtitle"
		s.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		s.custom_minimum_size = Vector2(WIDTH - 44.0, 0)
		_body.add_child(s)


func _line(t: String, col: Color) -> void:
	var l := S.plain(t, 15, col, S.font())
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(WIDTH - 44.0, 0)
	_body.add_child(l)


func _section(head: String, names: PackedStringArray) -> void:
	var v := VBoxContainer.new()
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_theme_constant_override("separation", 2)
	v.add_child(S.plain(head, 11, S.TEXT_FAINT, S.caps()))
	for n in names:
		v.add_child(S.plain(n, 15, S.TEXT, S.font()))
	_body.add_child(v)


func _pill(icon: String, t: String, col: Color) -> PanelContainer:
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_theme_stylebox_override("panel", S.box(Color(col.r, col.g, col.b, 0.12), 6, 8, 3))
	var h := HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_theme_constant_override("separation", 5)
	var ic := HudIcon.new(icon, col, 13.0)
	ic.shadow = false
	ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(ic)
	h.add_child(S.plain(t, 13, col.lerp(Color.WHITE, 0.35), S.bold()))
	p.add_child(h)
	return p


func _footer() -> void:
	var line := ColorRect.new()
	line.color = S.PANEL_LINE
	line.custom_minimum_size = Vector2(0, 1)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.add_child(line)
	var h := HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_theme_constant_override("separation", 6)
	for k: String in ["E", "Esc"]:
		var cap := S.key_cap(k, 12)
		cap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(cap)
	h.add_child(S.plain("Close", 14, S.TEXT_DIM, S.font()))
	_body.add_child(h)
