extends RefCounted
## Poster layouts (slice D): what the compositor draws over a poster image for each family and
## aspect. A layout is a list of elements in normalized poster coordinates (0..1, y down):
##   {"t": "img", "r": Rect2}                      the poster image, cover-fitted
##   {"t": "rect", "r": Rect2, "c": Color}
##   {"t": "grad", "r": Rect2, "c0": Color, "c1": Color, "vertical": bool}
##   {"t": "stripes", "r": Rect2, "c0": Color, "c1": Color}
##   {"t": "text", "r": Rect2, "s": String, "f": "display"|"serif"|"sans"|"sans_bold", "c": Color,
##    "size": float (largest size, a fraction of the poster height), "lines": int, "align": 0|1|2,
##    "valign": 0|1|2, "upper": bool, "shadow": bool}
## Static and deterministic; the same layout composites the procedural fallback.

const D := preload("res://scripts/sim/sim_defs.gd")

## Brand colours of the ad pools: [deep panel, accent].
const AD_COLORS := {
	"ad_cafe": [Color(0.22, 0.13, 0.09), Color(0.96, 0.78, 0.46)],
	"ad_bakery": [Color(0.38, 0.2, 0.09), Color(1.0, 0.86, 0.56)],
	"ad_market": [Color(0.07, 0.3, 0.16), Color(1.0, 0.86, 0.24)],
	"ad_bookshop": [Color(0.12, 0.16, 0.28), Color(0.96, 0.8, 0.55)],
	"ad_fitness": [Color(0.07, 0.07, 0.08), Color(1.0, 0.34, 0.2)],
	"ad_cinema": [Color(0.36, 0.04, 0.07), Color(1.0, 0.82, 0.36)],
	"ad_bank": [Color(0.05, 0.17, 0.31), Color(0.56, 0.83, 0.96)],
	"ad_hardware": [Color(0.17, 0.17, 0.18), Color(1.0, 0.62, 0.1)],
	"ad_default": [Color(0.11, 0.11, 0.13), Color(0.97, 0.86, 0.5)],
}
const PAPER := Color(0.95, 0.94, 0.9)
const INK := Color(0.08, 0.08, 0.09)
const NAVY := Color(0.06, 0.18, 0.38)
const AMBER := Color(0.98, 0.72, 0.05)
const WHITE := Color(1, 1, 1)


## Pixel size of a composite for a poster of aspect w/h: 1024 wide for wide carriers, 512 for
## portrait ones, multiples of 4, at most 1024 tall; scale 2 for the full-screen viewer.
static func pixel_size(aspect: float, scale: int = 1) -> Vector2i:
	var w := 1024 if aspect >= 1.4 else 512
	var h := int(round(float(w) / maxf(aspect, 0.05)))
	if h > 1024:
		h = 1024
		w = int(round(1024.0 * aspect))
	w = maxi(4, w - w % 4)
	h = maxi(4, h - h % 4)
	return Vector2i(w * scale, h * scale)


## The elements for a family ("campaign", "gazette", "ad", "hoarding", "notice", "incident",
## "placard", "lease") at aspect w/h; kind is the assignment's pool ("ad_cafe").
static func build(family: String, kind: String, overlay: Dictionary, aspect: float) -> Array:
	var wide := aspect >= 1.4
	match family:
		"campaign":
			return _campaign_wide(overlay) if wide else _campaign_tall(overlay)
		"gazette":
			return _gazette(overlay, aspect)
		"ad":
			return _ad_wide(kind, overlay) if wide else _ad_tall(kind, overlay)
		"hoarding":
			if aspect >= 4.0:
				return _hoarding_banner(overlay)
			return _hoarding_wide(overlay) if wide else _ad_tall("ad_default", {"name": overlay.get("name", ""), "tagline": overlay.get("title", ""), "address": overlay.get("builder", "")})
		"notice", "incident":
			return _notice(overlay, family == "incident")
		"placard":
			return _placard(overlay)
		"lease":
			return _lease(overlay)
	return [{"t": "img", "r": Rect2(0, 0, 1, 1)}]


static func _t(r: Rect2, s: String, f: String, c: Color, size: float, lines: int, align: int = 0, valign: int = 0, upper: bool = false, shadow: bool = false) -> Dictionary:
	return {"t": "text", "r": r, "s": D.debrand(s), "f": f, "c": c, "size": size, "lines": lines, "align": align,
		"valign": valign, "upper": upper, "shadow": shadow}


static func _mayor_colors(overlay: Dictionary) -> Array:
	var c := Color(str(overlay.get("color", "#FFB800")))
	return [c.darkened(0.8).lerp(Color(0.04, 0.05, 0.09), 0.25), c]


static func _campaign_wide(o: Dictionary) -> Array:
	var cols := _mayor_colors(o)
	var name := str(o.get("name", ""))
	return [
		{"t": "img", "r": Rect2(0.4, 0, 0.6, 1)},
		{"t": "grad", "r": Rect2(0.4, 0.55, 0.6, 0.45), "c0": Color(0, 0, 0, 0), "c1": Color(0, 0, 0, 0.45), "vertical": true},
		{"t": "rect", "r": Rect2(0, 0, 0.4, 1), "c": cols[0]},
		{"t": "rect", "r": Rect2(0.392, 0, 0.012, 1), "c": cols[1]},
		_t(Rect2(0.045, 0.09, 0.33, 0.13), str(o.get("call", "RE-ELECT")), "display", cols[1], 0.12, 1),
		_t(Rect2(0.045, 0.21, 0.33, 0.36), name, "display", WHITE, 0.2, 2, 0, 1, true),
		_t(Rect2(0.045, 0.58, 0.33, 0.08), "for " + str(o.get("district", "")), "sans_bold", Color(1, 1, 1, 0.85), 0.062, 1),
		_t(Rect2(0.045, 0.68, 0.33, 0.24), "“%s”" % str(o.get("slogan", "")), "sans", WHITE, 0.07, 3),
		_t(Rect2(0.43, 0.9, 0.55, 0.07), "Paid for by Friends of " + name, "sans", Color(1, 1, 1, 0.75), 0.036, 1, 2, 1, false, true),
	]


static func _campaign_tall(o: Dictionary) -> Array:
	var cols := _mayor_colors(o)
	return [
		{"t": "img", "r": Rect2(0, 0, 1, 0.56)},
		{"t": "rect", "r": Rect2(0, 0.56, 1, 0.44), "c": cols[0]},
		{"t": "rect", "r": Rect2(0, 0.553, 1, 0.012), "c": cols[1]},
		_t(Rect2(0.07, 0.59, 0.86, 0.06), str(o.get("call", "RE-ELECT")), "display", cols[1], 0.05, 1),
		_t(Rect2(0.07, 0.645, 0.86, 0.14), str(o.get("name", "")), "display", WHITE, 0.1, 2, 0, 1, true),
		_t(Rect2(0.07, 0.79, 0.86, 0.045), "for " + str(o.get("district", "")), "sans_bold", Color(1, 1, 1, 0.85), 0.032, 1),
		_t(Rect2(0.07, 0.84, 0.86, 0.13), "“%s”" % str(o.get("slogan", "")), "sans", WHITE, 0.034, 3),
	]


static func _gazette(o: Dictionary, aspect: float) -> Array:
	var square := aspect > 0.75
	var head_h := 0.26 if square else 0.24
	var photo_y := 0.2 + head_h + 0.02
	var out := [
		{"t": "rect", "r": Rect2(0, 0, 1, 1), "c": PAPER},
		_t(Rect2(0.05, 0.025, 0.9, 0.11), str(o.get("masthead", "GRIDFALL GAZETTE")), "serif", INK, 0.085, 1, 1, 1),
		{"t": "rect", "r": Rect2(0.05, 0.14, 0.9, 0.005), "c": INK},
		_t(Rect2(0.05, 0.148, 0.9, 0.04), "DAY %d  ·  CITY EDITION  ·  50¢" % int(o.get("day", 1)), "sans_bold", Color(0.25, 0.25, 0.27), 0.027, 1, 1, 1),
		{"t": "rect", "r": Rect2(0.05, 0.19, 0.9, 0.002), "c": INK},
		_t(Rect2(0.05, 0.205, 0.9, head_h), str(o.get("headline", "")), "serif", INK, 0.07, 4, 0, 1),
		{"t": "img", "r": Rect2(0.05, photo_y, 0.9, 0.9 - photo_y)},
	]
	var story := str(o.get("story", ""))
	if not story.is_empty():
		out.append(_t(Rect2(0.05, 0.91, 0.9, 0.07), story, "sans_bold", Color(0.2, 0.2, 0.22), 0.028, 2))
	return out


static func _ad_cols(kind: String) -> Array:
	return AD_COLORS.get(kind, AD_COLORS["ad_default"])


static func _ad_wide(kind: String, o: Dictionary) -> Array:
	var cols := _ad_cols(kind)
	return [
		{"t": "img", "r": Rect2(0, 0, 1, 1)},
		{"t": "grad", "r": Rect2(0, 0, 0.62, 1), "c0": Color(cols[0].r, cols[0].g, cols[0].b, 0.92), "c1": Color(cols[0].r, cols[0].g, cols[0].b, 0.0), "vertical": false},
		{"t": "rect", "r": Rect2(0.045, 0.14, 0.07, 0.022), "c": cols[1]},
		_t(Rect2(0.045, 0.19, 0.46, 0.4), str(o.get("name", "")), "display", WHITE, 0.19, 2, 0, 1, false, true),
		_t(Rect2(0.045, 0.6, 0.46, 0.12), str(o.get("tagline", "")), "sans_bold", cols[1], 0.08, 1, 0, 1, false, true),
		_t(Rect2(0.045, 0.75, 0.46, 0.1), str(o.get("address", "")), "sans", Color(1, 1, 1, 0.9), 0.056, 1, 0, 1, false, true),
	]


static func _ad_tall(kind: String, o: Dictionary) -> Array:
	var cols := _ad_cols(kind)
	return [
		{"t": "img", "r": Rect2(0, 0, 1, 0.62)},
		{"t": "rect", "r": Rect2(0, 0.62, 1, 0.38), "c": cols[0]},
		{"t": "rect", "r": Rect2(0.07, 0.655, 0.12, 0.008), "c": cols[1]},
		_t(Rect2(0.07, 0.675, 0.86, 0.15), str(o.get("name", "")), "display", WHITE, 0.075, 2, 0, 1),
		_t(Rect2(0.07, 0.83, 0.86, 0.06), str(o.get("tagline", "")), "sans_bold", cols[1], 0.036, 1),
		_t(Rect2(0.07, 0.895, 0.86, 0.06), str(o.get("address", "")), "sans", Color(1, 1, 1, 0.85), 0.03, 1),
	]


static func _hoarding_wide(o: Dictionary) -> Array:
	var c := Color(str(o.get("color", "#F2C230")))
	return [
		{"t": "img", "r": Rect2(0, 0, 1, 1)},
		{"t": "grad", "r": Rect2(0, 0.4, 1, 0.6), "c0": Color(0, 0, 0, 0), "c1": Color(0, 0, 0, 0.78), "vertical": true},
		{"t": "rect", "r": Rect2(0.035, 0.07, 0.3, 0.15), "c": c},
		_t(Rect2(0.045, 0.075, 0.28, 0.14), str(o.get("title", "COMING SOON")), "display", INK, 0.11, 1, 1, 1),
		_t(Rect2(0.035, 0.5, 0.93, 0.28), str(o.get("name", "")), "display", WHITE, 0.2, 2, 0, 2, false, true),
		_t(Rect2(0.035, 0.8, 0.93, 0.12), str(o.get("builder", "")), "sans_bold", Color(1, 1, 1, 0.9), 0.07, 1, 0, 1, false, true),
	]


static func _hoarding_banner(o: Dictionary) -> Array:
	var c := Color(str(o.get("color", "#F2C230")))
	return [
		{"t": "img", "r": Rect2(0, 0, 0.3, 1)},
		{"t": "rect", "r": Rect2(0.3, 0, 0.7, 1), "c": Color(0.08, 0.09, 0.1)},
		{"t": "rect", "r": Rect2(0.3, 0, 0.012, 1), "c": c},
		_t(Rect2(0.33, 0.08, 0.64, 0.55), "%s: %s" % [str(o.get("title", "COMING SOON")).capitalize(), str(o.get("name", ""))], "display", WHITE, 0.5, 1, 0, 1),
		_t(Rect2(0.33, 0.62, 0.64, 0.32), str(o.get("builder", "")), "sans_bold", c, 0.28, 1, 0, 1),
	]


static func _notice(o: Dictionary, incident: bool) -> Array:
	var band := AMBER if incident else NAVY
	var head_c := INK if incident else WHITE
	var out := [{"t": "rect", "r": Rect2(0, 0, 1, 1), "c": Color(0.97, 0.97, 0.95)}, {"t": "rect", "r": Rect2(0, 0, 1, 0.15), "c": band}]
	if incident:
		out.append({"t": "stripes", "r": Rect2(0, 0.15, 1, 0.025), "c0": AMBER, "c1": INK})
	out.append(_t(Rect2(0.06, 0.018, 0.88, 0.04), "CITY OF GRIDFALL", "sans_bold", Color(head_c.r, head_c.g, head_c.b, 0.8), 0.028, 1))
	out.append(_t(Rect2(0.06, 0.055, 0.88, 0.085), str(o.get("header", "PUBLIC NOTICE")), "display", head_c, 0.07, 1, 0, 1))
	out.append({"t": "img", "r": Rect2(0.06, 0.2, 0.88, 0.31)})
	out.append(_t(Rect2(0.06, 0.535, 0.88, 0.15), str(o.get("title", "")), "display", INK if incident else NAVY, 0.06, 2, 0, 1))
	out.append(_t(Rect2(0.06, 0.69, 0.88, 0.2), str(o.get("body", "")), "sans", Color(0.15, 0.15, 0.17), 0.036, 5))
	out.append({"t": "rect", "r": Rect2(0.06, 0.905, 0.88, 0.003), "c": Color(0.6, 0.6, 0.62)})
	out.append(_t(Rect2(0.06, 0.915, 0.88, 0.05), str(o.get("footer", "")), "sans", Color(0.35, 0.35, 0.38), 0.024, 1))
	return out


static func _placard(o: Dictionary) -> Array:
	var red := Color(0.78, 0.08, 0.06)
	return [
		{"t": "rect", "r": Rect2(0, 0, 1, 1), "c": Color(0.96, 0.95, 0.9)},
		{"t": "img", "r": Rect2(0, 0, 1, 0.44)},
		{"t": "rect", "r": Rect2(0, 0.44, 1, 0.014), "c": red},
		_t(Rect2(0.06, 0.48, 0.88, 0.25), str(o.get("title", "")), "display", red, 0.085, 3, 0, 1, true),
		_t(Rect2(0.06, 0.74, 0.88, 0.11), str(o.get("body", "")), "sans_bold", INK, 0.04, 2),
		_t(Rect2(0.06, 0.87, 0.88, 0.09), str(o.get("footer", "")), "display", INK, 0.042, 1, 0, 1),
	]


static func _lease(o: Dictionary) -> Array:
	return [
		{"t": "rect", "r": Rect2(0, 0, 1, 1), "c": Color(0.97, 0.96, 0.93)},
		_t(Rect2(0.05, 0.06, 0.9, 0.5), str(o.get("address", "")), "display", INK, 0.34, 1, 1, 1),
		_t(Rect2(0.05, 0.58, 0.9, 0.34), "Call " + str(o.get("phone", "555-0142")), "sans_bold", Color(0.72, 0.1, 0.08), 0.24, 1, 1, 1),
	]
