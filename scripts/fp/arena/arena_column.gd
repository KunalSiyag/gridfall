extends PanelContainer
## One mayor's column in the Ask-the-five panel: the mayor's person name in their colour with the
## model's badge and the source tag in the sub-line, a bar that fills while the answer is awaited
## (and the seconds it took), the finish order ("1st".."5th" for live answers only), the orders it
## would give in plain words with the plausibility flags, the public post, the thought, and, for a
## recorded or offline column, the note that it did not hear the question. The panel feeds it
## set_pending(), tick() and show_result(); nothing here reads the sim.

const D := preload("res://scripts/sim/sim_defs.gd")
const S := preload("res://scripts/fp/ui/hud_style.gd")
const WORDS := preload("res://scripts/fp/activity/activity_words.gd")

## The owner tag of every widget on the Ask page (see reown()).
const OWNER := "arena"
const NOTES := {
	"recorded": "Recorded from another game, did not hear your question.",
	"offline": "Offline planner, did not hear your question.",
}
const BAR_H := 6

var mi: int = 0
var tint := Color.WHITE
var rank_label: Label
var name_label: Label
var sub: HBoxContainer
var time_label: Label
var bar: ProgressBar
var body: VBoxContainer
var _pending: bool = false
var _result: Dictionary = {}


## The page's widgets belong to the Ask page, not to slice B: naming the models is this page's
## whole point (it compares them), so the street's no-branding scan leaves them out, as it leaves
## out the key page (gmi_key_panel.gd). Walks n and every child.
static func reown(n: Node) -> void:
	if n.get_meta(S.OWNER_META, "") == S.OWNER:
		n.set_meta(S.OWNER_META, OWNER)
	for c in n.get_children():
		reown(c)


func setup(p_mi: int) -> void:
	mi = p_mi
	tint = Color(str(D.MAYORS[mi]["color"]))
	name = "Column%d" % mi
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_stylebox_override(
		"panel",
		S.box(Color(1, 1, 1, 0.045), S.RADIUS, 10, 8, Color(tint.r, tint.g, tint.b, 0.35), 1)
	)
	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_theme_constant_override("separation", 5)
	add_child(col)
	rank_label = S.plain("", 24, tint, S.title())
	rank_label.name = "Rank"
	col.add_child(rank_label)
	name_label = S.plain(D.mayor_display(mi), 16, tint, S.bold())
	name_label.name = "Who"
	name_label.clip_text = true
	col.add_child(name_label)
	sub = HBoxContainer.new()
	sub.name = "Sub"
	sub.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sub.add_theme_constant_override("separation", 5)
	sub.add_child(S.badge(str(D.MAYORS[mi]["name"]), tint, 10))
	col.add_child(sub)
	bar = ProgressBar.new()
	bar.name = "Bar"
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.show_percentage = false
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.custom_minimum_size = Vector2(0, BAR_H)
	bar.add_theme_stylebox_override("background", S.box(Color(1, 1, 1, 0.08), 2, 0, 0))
	bar.add_theme_stylebox_override("fill", S.box(tint, 2, 0, 0))
	col.add_child(bar)
	time_label = S.plain("", 13, S.TEXT_DIM, S.font())
	time_label.name = "Time"
	col.add_child(time_label)
	body = VBoxContainer.new()
	body.name = "Body"
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_theme_constant_override("separation", 4)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(body)
	reown(self)
	clear("Waiting for a question.")


## Back to nothing asked yet (a new city), with line shown.
func clear(line: String) -> void:
	_pending = false
	_result = {}
	rank_label.text = ""
	bar.value = 0.0
	bar.visible = false
	time_label.text = ""
	_set_sub_source("")
	_reset_body()
	body.add_child(S.plain(line, 14, S.TEXT_DIM, S.font()))
	reown(body)


## The question went out: the bar starts filling.
func set_pending() -> void:
	_pending = true
	_result = {}
	rank_label.text = "…"
	bar.visible = true
	bar.value = 0.0
	bar.add_theme_stylebox_override("fill", S.box(tint, 2, 0, 0))
	time_label.text = "0.0 s"
	_set_sub_source("")
	_reset_body()
	body.add_child(S.plain("Thinking…", 14, S.TEXT_DIM, S.font()))
	reown(body)


## Advances the bar to elapsed seconds of timeout while the answer is awaited.
func tick(elapsed_s: float, timeout_s: float) -> void:
	if not _pending:
		return
	bar.value = clampf(elapsed_s / maxf(timeout_s, 0.1), 0.0, 1.0)
	time_label.text = "%.1f s" % elapsed_s


## The mayor's answer (an ArenaAsk result) lands.
func show_result(r: Dictionary) -> void:
	_pending = false
	_result = r
	var live := str(r.get("source", "")) == "live"
	rank_label.text = _rank_text(r)
	bar.visible = live
	bar.value = 1.0
	bar.add_theme_stylebox_override("fill", S.box(S.GOOD if live else S.AMBER, 2, 0, 0))
	time_label.text = ("%.1f s" % float(r.get("elapsed_s", 0.0))) if live else ""
	_set_sub_source(str(r.get("source", "")))
	_reset_body()
	var err := str(r.get("error", ""))
	if not err.is_empty():
		body.add_child(_note("Live call failed: " + err, S.RED))
	if NOTES.has(str(r.get("source", ""))):
		body.add_child(_note(str(NOTES[str(r["source"])]), S.AMBER))
	# The orders come first: they are what the page compares, and the thoughts run long.
	_orders(r)
	var prop := str(r.get("proposal", ""))
	if not prop.is_empty():
		_section("Would propose", prop, S.TEXT)
	_section("Public post", str(r.get("post", "")), S.TEXT)
	_section("Thought", str(r.get("thought", "")), S.TEXT)
	reown(body)


## What the column shows, one string per label (the test's and the smoke's view of it).
func texts() -> PackedStringArray:
	var out := PackedStringArray()
	_collect(self, out)
	return out


## The order words of the last result, one per proposed action, flags appended ("" before one).
func order_lines() -> PackedStringArray:
	var out := PackedStringArray()
	for n in body.find_children("Order*", "Label", true, false):
		out.append((n as Label).text)
	return out


func result() -> Dictionary:
	return _result


func is_pending() -> bool:
	return _pending


static func _rank_text(r: Dictionary) -> String:
	if str(r.get("source", "")) != "live":
		return "-"
	return ArenaAsk.ordinal(int(r.get("finish_rank", 0)))


func _set_sub_source(source: String) -> void:
	while sub.get_child_count() > 1:
		var c := sub.get_child(sub.get_child_count() - 1)
		sub.remove_child(c)
		c.queue_free()
	var col := S.GOOD
	var word := ""
	match source:
		"live":
			word = "LIVE"
		"recorded":
			word = "RECORDED"
			col = S.AMBER
		"offline":
			word = "OFFLINE"
			col = S.AMBER
	if not word.is_empty():
		var b := S.badge(word, col, 10)
		b.name = "SourceBadge"
		sub.add_child(b)
		reown(b)


func _reset_body() -> void:
	for c in body.get_children():
		body.remove_child(c)
		c.queue_free()


func _note(t: String, col: Color) -> Label:
	var l := S.plain(t, 13, col, S.bold())
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


func _section(title: String, text: String, col: Color) -> void:
	body.add_child(S.caps_label(title, 11, S.AMBER, 0))
	var t := S.plain(text if not text.is_empty() else "(nothing said)", 14, col, S.font())
	t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(t)


## The proposed orders in plain words, the flagged ones in red with the reason after a dot.
func _orders(r: Dictionary) -> void:
	var acts: Array = r.get("actions", [])
	var flags: Array = r.get("flags", [])
	body.add_child(S.caps_label("Would do", 11, S.AMBER, 0))
	if acts.is_empty():
		body.add_child(S.plain("No orders: holds off.", 14, S.TEXT_DIM, S.font()))
		return
	var clean := 0
	for i in range(acts.size()):
		var words := WORDS.action_words(acts[i])
		if words.is_empty():
			words = "An order the city does not know"
		var why: Array[String] = []
		for f: Variant in flags:
			if typeof(f) == TYPE_DICTIONARY and int((f as Dictionary)["i"]) == i:
				why.append(str((f as Dictionary)["text"]))
		var line := "%d. %s" % [i + 1, words]
		var col := S.TEXT
		if not why.is_empty():
			line += " · " + ", ".join(PackedStringArray(why))
			col = S.RED
		else:
			clean += 1
		var l := S.plain(line, 14, col, S.font())
		l.name = "Order%d" % i
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		body.add_child(l)
	var extra := int(r.get("extra_actions", 0))
	var tail := "%d of %d orders look workable" % [clean, acts.size()]
	if extra > 0:
		tail += " (+%d past the daily limit)" % extra
	body.add_child(S.plain(tail, 12, S.TEXT_DIM, S.font()))


static func _collect(n: Node, out: PackedStringArray) -> void:
	if n is Label:
		out.append((n as Label).text)
	for c in n.get_children():
		_collect(c, out)
