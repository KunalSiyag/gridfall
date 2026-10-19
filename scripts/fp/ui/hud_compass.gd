extends Control
## Compass strip (slice B), top centre under the chips: ticks and cardinal letters for the view
## heading on a soft backing band, plus the waypoint and up to 3 pings drawn on the strip (a letter
## under a marker fades out) with their distance in metres below. Markers beyond the strip's span
## pin to its ends as chevrons. Redrawn when the heading moves and at 4 Hz for the distances.

const S := preload("res://scripts/fp/ui/hud_style.gd")
const WS := preload("res://scripts/fp/world_scale.gd")

const WIDTH := 460.0
const HEIGHT := 46.0
## Heading span shown across the strip (radians).
const SPAN := deg_to_rad(160.0)
const REFRESH := 0.25
const LETTERS := {0: "N", 45: "NE", 90: "E", 135: "SE", 180: "S", 225: "SW", 270: "W", 315: "NW"}
## Rows: the centre notch at the top, the band with ticks, letters and markers, distances below.
const BAND_TOP := 7.0
const BAND_H := 23.0
const ROW_Y := BAND_TOP + BAND_H * 0.5
const DIST_Y := BAND_TOP + BAND_H + 12.0
const MAX_PINGS := 3
## Horizontal spacing of chevrons stacked at one end of the strip.
const STACK_PX := 11.0
## Least space between two distance labels, and how far a label may slide from its marker.
const LABEL_GAP := 6.0
const LABEL_SLIDE := 24.0
## Draw order (later on top) and label priority (lower first).
const ORDER := {"ping": 0, "event": 1, "waypoint": 2}

var ctx: FpContext
var hud: Node
## Heading of the view, radians clockwise from north (-Z).
var bearing: float = 0.0
## Each: {"bearing": float, "dist": String, "color": Color, "kind": "waypoint"|"event"|"ping", "alpha": float}
var markers: Array[Dictionary] = []
var _t: float = 0.0
var _drawn_bearing: float = INF
var _band: ImageTexture


## hud is the FpHud (pings and the waypoint come from it).
func setup(p_ctx: FpContext, p_hud: Node) -> void:
	ctx = p_ctx
	hud = p_hud
	name = "Compass"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	anchor_left = 0.5
	anchor_right = 0.5
	offset_left = -WIDTH * 0.5
	offset_right = WIDTH * 0.5
	# top_bar starts at y 12: the chips take 24..54, the strip 60..106.
	offset_top = 48
	offset_bottom = 48 + HEIGHT
	_band = _band_texture()


## Heading in radians clockwise from north for a forward vector (yaw convention of S0 §11).
static func heading_of(f: Vector3) -> float:
	return atan2(f.x, -f.z)


## Bearing from a to b, radians clockwise from north.
static func bearing_to(a: Vector3, b: Vector3) -> float:
	return atan2(b.x - a.x, -(b.z - a.z))


## Screen x (local) of a bearing, or NAN outside the span.
func x_of(b: float) -> float:
	var rel := wrapf(b - bearing, -PI, PI)
	if absf(rel) > SPAN * 0.5:
		return NAN
	return WIDTH * 0.5 + rel / SPAN * WIDTH


func _process(delta: float) -> void:
	if ctx == null or ctx.player == null or not is_visible_in_tree():
		return
	bearing = heading_of(ctx.player.forward())
	_t += delta
	if _t >= REFRESH:
		_t = 0.0
		_collect()
		queue_redraw()
	elif absf(wrapf(bearing - _drawn_bearing, -PI, PI)) > 0.0015:
		queue_redraw()


func _collect() -> void:
	markers.clear()
	var me := ctx.player.position
	var wp: Variant = hud.call("waypoint") if hud != null else null
	if wp != null:
		var p: Vector3 = wp
		markers.append({"bearing": bearing_to(me, p), "dist": S.distance(_flat(me, p)), "color": S.ACCENT, "kind": "waypoint", "alpha": 1.0})
	var pings: Array = hud.get("pings") if hud != null else []
	var n := 0
	for k in range(pings.size() - 1, -1, -1):
		if n >= MAX_PINGS:
			break
		var e: Dictionary = pings[k]
		var p: Vector3 = e["pos"]
		var is_event := str(e["reason"]).begins_with("event:")
		markers.append({"bearing": bearing_to(me, p), "dist": S.distance(_flat(me, p)), "color": S.RED if is_event else S.AMBER, "kind": "event" if is_event else "ping", "alpha": float(e.get("alpha", 1.0))})
		n += 1


func _draw() -> void:
	_drawn_bearing = bearing
	var f := S.bold()
	var cx := WIDTH * 0.5
	draw_texture_rect(_band, Rect2(0.0, BAND_TOP, WIDTH, BAND_H), false)
	# Where the markers land: x on the strip, or pinned to an end (stacked inward).
	var placed: Array[Dictionary] = []
	var ends := {-1: 0, 1: 0}
	var sorted := markers.duplicate()
	sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(ORDER[a["kind"]]) < int(ORDER[b["kind"]]))
	for m: Dictionary in sorted:
		var rel := wrapf(float(m["bearing"]) - bearing, -PI, PI)
		var inside := absf(rel) <= SPAN * 0.5
		var x := cx + clampf(rel / SPAN, -0.5, 0.5) * WIDTH
		var side := int(signf(rel)) if not inside else 0
		if side != 0:
			x -= side * (6.0 + STACK_PX * int(ends[side]))
			ends[side] = int(ends[side]) + 1
		placed.append({"m": m, "x": x, "side": side})
	var marker_xs := PackedFloat32Array()
	for e: Dictionary in placed:
		if int(e["side"]) == 0:
			marker_xs.append(float(e["x"]))
	# Ticks every 15 degrees, letters on the cardinals and intercardinals.
	var start := int(floor(rad_to_deg(bearing - SPAN * 0.5) / 15.0)) * 15
	var deg := start
	var ticks := PackedVector2Array()
	var tick_cols := PackedColorArray()
	while deg <= int(ceil(rad_to_deg(bearing + SPAN * 0.5))):
		var x := x_of(deg_to_rad(float(deg)))
		if not is_nan(x):
			var fade := _edge_fade(x) * _under_marker(x, marker_xs)
			var d := posmod(deg, 360)
			if LETTERS.has(d):
				var t: String = LETTERS[d]
				var card := t.length() == 1
				var fs := 15 if card else 11
				var col := Color(1, 1, 1, (0.96 if card else 0.62) * fade)
				var w := f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
				var base := Vector2(x - w * 0.5, ROW_Y + f.get_ascent(fs) * 0.36)
				draw_string_outline(f, base, t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 3, Color(0, 0, 0, 0.35 * fade))
				draw_string(f, base, t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
			else:
				ticks.append(Vector2(x, ROW_Y - 3.0))
				ticks.append(Vector2(x, ROW_Y + 3.0))
				tick_cols.append(Color(1, 1, 1, 0.4 * fade))
		deg += 15
	if not ticks.is_empty():
		draw_multiline_colors(ticks, tick_cols, 1.5)
	# Centre notch, above the band.
	draw_colored_polygon(PackedVector2Array([Vector2(cx - 4.5, 0.0), Vector2(cx + 4.5, 0.0), Vector2(cx, 5.0)]), Color(1, 1, 1, 0.92))
	# Markers on the strip (the waypoint on top), chevrons at the ends.
	for e: Dictionary in placed:
		var m: Dictionary = e["m"]
		var col: Color = m["color"]
		var side := int(e["side"])
		col.a *= float(m.get("alpha", 1.0)) * (1.0 if side == 0 else 0.7)
		var c := Vector2(float(e["x"]), ROW_Y)
		if side != 0:
			var tip := c + Vector2(side * 4.5, 0)
			var pts := PackedVector2Array([tip, c + Vector2(-side * 2.5, -5.0), c + Vector2(-side * 2.5, 5.0)])
			draw_colored_polygon(pts, col)
		elif str(m["kind"]) == "waypoint":
			_diamond(c, 7.0, Color(0.02, 0.03, 0.05, 0.55 * col.a))
			_diamond(c, 5.6, col)
		else:
			draw_circle(c, 6.2, Color(0.02, 0.03, 0.05, 0.55 * col.a), true, -1.0, true)
			draw_circle(c, 4.6, col, true, -1.0, true)
	# Distances under the markers on the strip, by priority; a label that would overlap one
	# already placed slides aside while it stays under its marker, else it is left out.
	var spans: Array[Vector2] = []
	var fs2 := 12
	for k in range(placed.size() - 1, -1, -1):
		var e: Dictionary = placed[k]
		if int(e["side"]) != 0:
			continue
		var m: Dictionary = e["m"]
		var t: String = m["dist"]
		var w := f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs2).x
		var mx := float(e["x"])
		var x0 := _label_x(mx, w, spans)
		if is_nan(x0):
			continue
		spans.append(Vector2(x0, x0 + w))
		var a := float(m.get("alpha", 1.0))
		var col := S.ACCENT.lerp(S.WHITE, 0.25) if str(m["kind"]) == "waypoint" else Color(1, 1, 1, 0.92)
		col.a *= a
		var base := Vector2(x0, DIST_Y)
		draw_string_outline(f, base, t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs2, 4, Color(0.01, 0.02, 0.04, 0.6 * a))
		draw_string(f, base, t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs2, col)


func _diamond(c: Vector2, r: float, col: Color) -> void:
	draw_colored_polygon(PackedVector2Array([c + Vector2(0, -r), c + Vector2(r * 0.8, 0), c + Vector2(0, r), c + Vector2(-r * 0.8, 0)]), col)


func _edge_fade(x: float) -> float:
	var u := absf(x - WIDTH * 0.5) / (WIDTH * 0.5)
	return 1.0 - smoothstep(0.62, 1.0, u)


## 1 away from every marker, fading to 0.12 for a letter or tick right under one.
static func _under_marker(x: float, xs: PackedFloat32Array) -> float:
	var k := 1.0
	for mx in xs:
		k = minf(k, lerpf(0.12, 1.0, smoothstep(8.0, 20.0, absf(x - mx))))
	return k


## Left x of a w-wide label under the marker at mx, kept inside the strip and clear of the
## labels in spans (each Vector2(left, right)) by LABEL_GAP: centred if it fits, else slid aside
## while its centre stays within LABEL_SLIDE of the marker; NAN when it cannot be placed.
static func _label_x(mx: float, w: float, spans: Array[Vector2]) -> float:
	var x0 := clampf(mx - w * 0.5, 0.0, WIDTH - w)
	for _pass in range(2):
		var moved := false
		for q in spans:
			if x0 < q.y + LABEL_GAP and q.x < x0 + w + LABEL_GAP:
				x0 = q.y + LABEL_GAP if mx >= (q.x + q.y) * 0.5 else q.x - LABEL_GAP - w
				moved = true
		if not moved:
			break
	if x0 < 0.0 or x0 + w > WIDTH or absf(x0 + w * 0.5 - mx) > LABEL_SLIDE:
		return NAN
	for q in spans:
		if x0 < q.y + LABEL_GAP and q.x < x0 + w + LABEL_GAP:
			return NAN
	return x0


static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(b.x - a.x, b.z - a.z).length()


## The backing band: CHIP_BG at most 0.32 alpha in the middle, fading out toward both ends and
## softly at the top and bottom edges, so the strip reads over bright sky and busy facades.
static func _band_texture() -> ImageTexture:
	var w := 128
	var h := 16
	var img := Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
	for y in range(h):
		var v := absf((y + 0.5) / h * 2.0 - 1.0)
		var fy := 1.0 - smoothstep(0.55, 1.0, v)
		for x in range(w):
			var u := absf((x + 0.5) / w * 2.0 - 1.0)
			var fx := 1.0 - smoothstep(0.35, 1.0, u)
			img.set_pixel(x, y, Color(S.CHIP_BG.r, S.CHIP_BG.g, S.CHIP_BG.b, 0.32 * fx * fy))
	return ImageTexture.create_from_image(img)
