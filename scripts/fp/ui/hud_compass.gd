extends Control
## Compass strip (slice B), top centre under the chips: ticks and cardinal letters for the view
## heading, plus the waypoint and up to 3 pings with their distance in metres. Redrawn when the
## heading moves and at 4 Hz for the distances; markers beyond the strip's span pin to its ends.

const S := preload("res://scripts/fp/ui/hud_style.gd")
const WS := preload("res://scripts/fp/world_scale.gd")

const WIDTH := 460.0
const HEIGHT := 42.0
## Heading span shown across the strip (radians).
const SPAN := deg_to_rad(160.0)
const REFRESH := 0.25
const LETTERS := {0: "N", 45: "NE", 90: "E", 135: "SE", 180: "S", 225: "SW", 270: "W", 315: "NW"}
const LINE_Y := 13.0
const MAX_PINGS := 3

var ctx: FpContext
var hud: Node
## Heading of the view, radians clockwise from north (-Z).
var bearing: float = 0.0
## Each: {"bearing": float, "dist": String, "color": Color, "kind": "waypoint"|"event"|"ping"}
var markers: Array[Dictionary] = []
var _t: float = 0.0
var _drawn_bearing: float = INF


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
	# top_bar starts at y 12: the chips take 24..54, the strip 60..102.
	offset_top = 48
	offset_bottom = 48 + HEIGHT


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
		markers.append({"bearing": bearing_to(me, p), "dist": S.distance(_flat(me, p)), "color": S.ACCENT, "kind": "waypoint"})
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
	# Ticks every 15 degrees, letters on the cardinals and intercardinals.
	var start := int(floor(rad_to_deg(bearing - SPAN * 0.5) / 15.0)) * 15
	var deg := start
	while deg <= int(ceil(rad_to_deg(bearing + SPAN * 0.5))):
		var x := x_of(deg_to_rad(float(deg)))
		if not is_nan(x):
			var fade := _edge_fade(x)
			var d := posmod(deg, 360)
			if LETTERS.has(d):
				var t: String = LETTERS[d]
				var card := t.length() == 1
				var fs := 15 if card else 11
				var col := Color(1, 1, 1, (0.95 if card else 0.6) * fade)
				var w := f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
				var base := Vector2(x - w * 0.5, LINE_Y + 5.0 + f.get_ascent(fs) * 0.5)
				draw_string_outline(f, base, t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 3, Color(0, 0, 0, 0.45 * fade))
				draw_string(f, base, t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
			else:
				draw_line(Vector2(x, LINE_Y + 2.0), Vector2(x, LINE_Y + 7.0), Color(1, 1, 1, 0.38 * fade), 1.5, true)
		deg += 15
	# Centre notch.
	var notch := PackedVector2Array([Vector2(cx - 4.5, 0.0), Vector2(cx + 4.5, 0.0), Vector2(cx, 5.5)])
	draw_colored_polygon(notch, Color(1, 1, 1, 0.9))
	# Markers: waypoint and pings, pinned to the ends when outside the span.
	var fs2 := 11
	for m: Dictionary in markers:
		var rel := wrapf(float(m["bearing"]) - bearing, -PI, PI)
		var inside := absf(rel) <= SPAN * 0.5
		var x := cx + clampf(rel / SPAN, -0.5, 0.5) * WIDTH
		var col: Color = m["color"]
		col.a *= float(m.get("alpha", 1.0)) * (1.0 if inside else 0.55)
		var c := Vector2(x, LINE_Y + 4.5)
		if not inside:
			# Off the strip: a small chevron at the end, pointing the way to turn.
			var s := signf(rel)
			var tip := c + Vector2(s * 5.0, 0)
			draw_colored_polygon(PackedVector2Array([tip, c + Vector2(-s * 2.0, -5.0), c + Vector2(-s * 2.0, 5.0)]), col)
		elif str(m["kind"]) == "waypoint":
			_diamond(c, 6.0, col)
		else:
			draw_circle(c, 6.0, Color(0, 0, 0, 0.35 * col.a), true, -1.0, true)
			draw_circle(c, 4.0, col, true, -1.0, true)
		if inside:
			var t: String = m["dist"]
			var w := f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs2).x
			var base := Vector2(x - w * 0.5, LINE_Y + 23.0)
			draw_string_outline(f, base, t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs2, 3, Color(0, 0, 0, 0.5 * col.a))
			draw_string(f, base, t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs2, Color(col.r, col.g, col.b, col.a))


func _diamond(c: Vector2, r: float, col: Color) -> void:
	var pts := PackedVector2Array([c + Vector2(0, -r), c + Vector2(r * 0.8, 0), c + Vector2(0, r), c + Vector2(-r * 0.8, 0)])
	var shadow := PackedVector2Array()
	for p in pts:
		shadow.append(p + Vector2(0, 1))
	draw_colored_polygon(shadow, Color(0, 0, 0, 0.4 * col.a))
	draw_colored_polygon(pts, col)


func _edge_fade(x: float) -> float:
	var u := absf(x - WIDTH * 0.5) / (WIDTH * 0.5)
	return 1.0 - smoothstep(0.62, 1.0, u)


static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(b.x - a.x, b.z - a.z).length()
