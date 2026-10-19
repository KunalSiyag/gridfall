extends RefCounted
## Poster palettes and the procedural fallback art (slice D): a soft two-tone gradient in the
## colours of the poster's kind (or its mayor), so a poster is never blank offline or while its
## image is on the way. Static and deterministic from the cache key.

const D := preload("res://scripts/sim/sim_defs.gd")

## Base colours per poster family: [deep, light, accent].
const PALETTES := {
	"campaign": [Color(0.09, 0.11, 0.2), Color(0.32, 0.38, 0.55), Color(1.0, 0.72, 0.0)],
	"gazette": [Color(0.18, 0.2, 0.24), Color(0.62, 0.64, 0.66), Color(0.85, 0.12, 0.1)],
	"ad": [Color(0.16, 0.1, 0.08), Color(0.78, 0.55, 0.32), Color(0.98, 0.84, 0.45)],
	"hoarding": [Color(0.08, 0.2, 0.2), Color(0.42, 0.66, 0.62), Color(0.98, 0.78, 0.15)],
	"notice": [Color(0.06, 0.16, 0.32), Color(0.46, 0.58, 0.74), Color(0.95, 0.95, 0.92)],
	"incident": [Color(0.22, 0.1, 0.02), Color(0.82, 0.46, 0.06), Color(1.0, 0.78, 0.1)],
	"placard": [Color(0.24, 0.06, 0.06), Color(0.66, 0.42, 0.3), Color(0.96, 0.92, 0.84)],
	"lease": [Color(0.86, 0.85, 0.82), Color(0.98, 0.97, 0.94), Color(0.72, 0.1, 0.08)],
}

## Shared gradient textures, by key (procedural art never changes for a key).
static var _cache: Dictionary = {}


## The poster family of a kind or pool name: "campaign_argon" -> "campaign".
static func family(kind: String) -> String:
	return kind.get_slice("_", 0)


## [deep, light, accent] for a kind or pool; campaigns of a mayor use the mayor's colour.
static func palette(kind: String) -> Array:
	var fam := family(kind)
	var p: Array = (PALETTES.get(fam, PALETTES["ad"]) as Array).duplicate()
	if fam == "campaign":
		var mi := mayor_index(kind.get_slice("_", 1))
		if mi >= 0:
			var c := Color(str(D.MAYORS[mi]["color"]))
			p = [c.darkened(0.78), c.darkened(0.35).lerp(Color(0.5, 0.52, 0.56), 0.35), c]
	return p


## Index of the mayor with this id ("argon"), or -1.
static func mayor_index(id: String) -> int:
	for k in range(D.MAYORS.size()):
		if str(D.MAYORS[k]["id"]) == id:
			return k
	return -1


## A gradient texture for a poster of this kind; the angle and stops vary with the key.
static func procedural(kind: String, key: String) -> Texture2D:
	var ck := kind + "|" + key
	if _cache.has(ck):
		return _cache[ck]
	var p := palette(kind)
	var h := absi(key.hash())
	var g := Gradient.new()
	g.set_color(0, p[0])
	g.set_color(1, p[1])
	g.add_point(0.55 + float(h % 20) * 0.01, (p[0] as Color).lerp(p[1], 0.45))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.width = 256
	t.height = 256
	t.fill = GradientTexture2D.FILL_RADIAL if h % 3 == 0 else GradientTexture2D.FILL_LINEAR
	var a := float(h % 360) * PI / 180.0
	t.fill_from = Vector2(0.5, 0.5) - Vector2(cos(a), sin(a)) * 0.5
	t.fill_to = Vector2(0.5, 0.5) + Vector2(cos(a), sin(a)) * 0.5
	if t.fill == GradientTexture2D.FILL_RADIAL:
		t.fill_from = Vector2(0.3 + float(h % 5) * 0.1, 0.35)
		t.fill_to = Vector2(1.1, 1.1)
	if _cache.size() > 64:
		_cache.clear()
	_cache[ck] = t
	return t
