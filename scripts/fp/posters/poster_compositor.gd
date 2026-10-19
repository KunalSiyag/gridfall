extends Node
## Draws poster text over poster images (slice D): a one-shot SubViewport (update mode ONCE) holds
## the image and the layout's panels and Labels (Lilita One for display type, system serif and
## sans for newspaper and body copy), the result is read back as an Image, mipmapped and
## VRAM-compressed on a background thread and wrapped in an ImageTexture. One job renders at a time,
## nearest first. Headless runs skip the drawing and return the raw image, so tests check the
## pipeline and not the pixels of the text.

signal composited(job_id: String, tex: Texture2D)

const FONT_PATH := "res://fonts/lilita_one_regular.ttf"
const WORKER := preload("res://scripts/fp/posters/poster_worker.gd")
const SERIF := ["DejaVu Serif", "Georgia", "Times New Roman", "Liberation Serif", "Noto Serif", "serif"]
const SANS := ["Fira Sans", "Source Sans Pro", "DejaVu Sans", "Arial", "Liberation Sans", "Noto Sans", "sans-serif"]

var headless: bool = false
## Jobs finished so far (tests).
var done_count: int = 0
var _vp: SubViewport
var _root: Control
var _queue: Array[Dictionary] = []
var _busy: bool = false
var _current: String = ""
var _worker := WORKER.new()
var _fonts: Dictionary = {}
var _stripes: ImageTexture


func _ready() -> void:
	headless = DisplayServer.get_name() == "headless"
	if headless:
		return
	_vp = SubViewport.new()
	_vp.name = "PosterCompositor"
	_vp.disable_3d = true
	_vp.transparent_bg = false
	_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	_vp.size = Vector2i(64, 64)
	add_child(_vp)
	_root = Control.new()
	_root.name = "Root"
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vp.add_child(_root)


## Queues a composite of base under elements at px; composited(job_id, tex) follows (deferred,
## immediately with base when headless). order sorts the queue (smaller first, e.g. distance).
func enqueue(job_id: String, base: Texture2D, elements: Array, px: Vector2i, order: float = 0.0) -> void:
	cancel(job_id)
	if headless or _vp == null:
		done_count += 1
		composited.emit.call_deferred(job_id, base)
		return
	_queue.append({"id": job_id, "base": base, "elements": elements, "px": px, "order": order})


## Drops a queued job (a running one still finishes; listeners ignore stale ids).
func cancel(job_id: String) -> void:
	for k in range(_queue.size() - 1, -1, -1):
		if str(_queue[k]["id"]) == job_id:
			_queue.remove_at(k)


## True while job_id waits or renders.
func pending(job_id: String) -> bool:
	if _current == job_id:
		return true
	for j: Dictionary in _queue:
		if str(j["id"]) == job_id:
			return true
	return false


func queued() -> int:
	return _queue.size() + (1 if _busy else 0)


func _process(_dt: float) -> void:
	_drain()
	if _busy or _queue.is_empty() or _vp == null:
		return
	_queue.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["order"]) < float(b["order"]))
	_run(_queue.pop_front())


func _exit_tree() -> void:
	_worker.stop()


func _run(job: Dictionary) -> void:
	_busy = true
	_current = str(job["id"])
	for c in _root.get_children():
		c.free()
	var px: Vector2i = job["px"]
	_vp.size = px
	_root.position = Vector2.ZERO
	_root.size = Vector2(px)
	for e: Dictionary in job["elements"]:
		_add(e, job["base"], Vector2(px))
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	if not is_inside_tree():
		return
	var img := _vp.get_texture().get_image()
	_worker.push(Callable(WORKER, "finish_image"), {"id": job["id"], "image": img})
	_busy = false
	_current = ""


func _drain() -> void:
	for input: Dictionary in _worker.take_done():
		if bool(input.get("ok", false)):
			done_count += 1
			composited.emit(str(input["id"]), ImageTexture.create_from_image(input["image"]))


# ------------------------------------------------------------------ drawing

func _add(e: Dictionary, base: Texture2D, px: Vector2) -> void:
	var r: Rect2 = e["r"]
	var rect := Rect2(r.position * px, r.size * px)
	match str(e["t"]):
		"img":
			if base == null:
				return
			var tr := TextureRect.new()
			tr.texture = base
			tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
			tr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
			_place(tr, rect)
		"rect":
			var cr := ColorRect.new()
			cr.color = e["c"]
			_place(cr, rect)
		"grad":
			var g := Gradient.new()
			g.set_color(0, e["c0"])
			g.set_color(1, e["c1"])
			var gt := GradientTexture2D.new()
			gt.gradient = g
			gt.width = 64
			gt.height = 64
			gt.fill_from = Vector2(0, 0)
			gt.fill_to = Vector2(0, 1) if bool(e.get("vertical", false)) else Vector2(1, 0)
			var gr := TextureRect.new()
			gr.texture = gt
			gr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			gr.stretch_mode = TextureRect.STRETCH_SCALE
			_place(gr, rect)
		"stripes":
			var sr := TextureRect.new()
			sr.texture = _stripe_texture(e["c0"], e["c1"])
			sr.stretch_mode = TextureRect.STRETCH_TILE
			sr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			_place(sr, rect)
		"text":
			_text(e, rect, px.y)


func _place(c: Control, rect: Rect2) -> void:
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.position = rect.position
	c.size = rect.size
	_root.add_child(c)


func _text(e: Dictionary, rect: Rect2, poster_h: float) -> void:
	var s := str(e["s"])
	if bool(e.get("upper", false)):
		s = s.to_upper()
	if s.strip_edges().is_empty():
		return
	var font := _font(str(e["f"]))
	var display := str(e["f"]) == "display" or str(e["f"]) == "serif"
	var lines := int(e.get("lines", 1))
	var spacing := -0.1 if display else 0.0
	var fs := fit(font, s, rect.size, float(e["size"]) * poster_h, lines, spacing)
	var ls := LabelSettings.new()
	ls.font = font
	ls.font_size = fs
	ls.font_color = e["c"]
	ls.line_spacing = spacing * fs
	if bool(e.get("shadow", false)):
		ls.shadow_size = maxi(1, fs / 14)
		ls.shadow_color = Color(0, 0, 0, 0.55)
		ls.shadow_offset = Vector2(1, 1) * maxf(1.0, fs / 18.0)
	var l := Label.new()
	l.text = s
	l.label_settings = ls
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if lines > 1 else TextServer.AUTOWRAP_OFF
	l.max_lines_visible = lines
	l.horizontal_alignment = int(e.get("align", 0)) as HorizontalAlignment
	l.vertical_alignment = int(e.get("valign", 0)) as VerticalAlignment
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS if lines == 1 else TextServer.OVERRUN_NO_TRIMMING
	l.clip_text = lines == 1
	_place(l, rect)


## The largest font size <= max_px at which s wraps into at most `lines` lines inside box, with no
## word wider than the box (line_spacing is a fraction of the size).
static func fit(font: Font, s: String, box: Vector2, max_px: float, lines: int, line_spacing: float = 0.0) -> int:
	var fs := maxi(8, int(max_px))
	var words := s.split(" ", false)
	while fs > 8:
		var widest := 0.0
		for w in words:
			widest = maxf(widest, font.get_string_size(w, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x)
		if widest <= box.x:
			var lh := font.get_height(fs)
			var sz := font.get_multiline_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, box.x, fs) if lines > 1 else font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
			var n := maxi(1, int(round(sz.y / lh)))
			var h := float(n) * lh + float(n - 1) * line_spacing * fs
			if n <= lines and h <= box.y * 1.04 and (lines > 1 or sz.x <= box.x):
				return fs
		fs = int(float(fs) * 0.93)
	return 8


func _font(kind: String) -> Font:
	if _fonts.has(kind):
		return _fonts[kind]
	var f: Font = null
	match kind:
		"display":
			f = load(FONT_PATH) as Font if ResourceLoader.exists(FONT_PATH) else null
		"serif":
			var sf := SystemFont.new()
			sf.font_names = PackedStringArray(SERIF)
			sf.font_weight = 700
			f = sf
		"sans", "sans_bold":
			var sb := SystemFont.new()
			sb.font_names = PackedStringArray(SANS)
			sb.font_weight = 700 if kind == "sans_bold" else 500
			f = sb
	if f == null:
		f = ThemeDB.fallback_font
	_fonts[kind] = f
	return f


func _stripe_texture(c0: Color, c1: Color) -> ImageTexture:
	if _stripes != null:
		return _stripes
	var img := Image.create(32, 32, false, Image.FORMAT_RGB8)
	for y in range(32):
		for x in range(32):
			img.set_pixel(x, y, c0 if ((x + y) / 8) % 2 == 0 else c1)
	_stripes = ImageTexture.create_from_image(img)
	return _stripes
