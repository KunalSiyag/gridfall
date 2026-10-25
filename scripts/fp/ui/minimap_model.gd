extends RefCounted
## The minimap's tile images (slice B), one pixel per tile of the 192 x 192 world:
## `image` holds the display colour, `data` the shape class, level and district the map shader
## draws from (roads joined to their neighbours, inset buildings, smooth shores), and `survey`
## one texel per 16 x 16 plot (unsurveyed land is hazed). Repainted per tile on tiles_changed,
## per district on territory_changed, in full only on world_ready.

const D := preload("res://scripts/sim/sim_defs.gd")

# Shape classes (data.r); the map shader (ui/fp/map.gdshader) uses the same numbers.
const CLS_LAND := 0
const CLS_ROAD := 1
const CLS_WATER := 2
const CLS_PARK := 3
const CLS_FOREST := 4
const CLS_LOT := 5
const CLS_BUILDING := 6
const CLS_SERVICE := 7
const CLS_SITE := 8
const CLS_RUBBLE := 9
const CLS_BRIDGE := 10
const CLS_LANDMARK := 11

# A calm, low-saturation palette: dark ground, near-white roads, blue water, neutral blocks with a
# faint tint per use. Colour is for reading the street grid, not for decoration.
const COL_LAND := Color(0.125, 0.145, 0.165)
const COL_WILD := Color(0.105, 0.12, 0.14)
const COL_WATER := Color(0.125, 0.265, 0.365)
const COL_ROAD := Color(0.86, 0.88, 0.91)
## Unpaved road grades (gravel, dirt track, grass trail): fainter and warmer than paved roads.
const COL_UNPAVED := [Color(0.62, 0.6, 0.56), Color(0.5, 0.42, 0.32), Color(0.36, 0.4, 0.3)]
const COL_PARK := Color(0.19, 0.30, 0.215)
const COL_FOREST := Color(0.135, 0.19, 0.16)
const COL_SITE := Color(0.36, 0.31, 0.245)
const COL_RUBBLE := Color(0.27, 0.255, 0.245)
const COL_SERVICE := Color(0.30, 0.295, 0.375)
const COL_LANDMARK := Color(0.44, 0.39, 0.27)
## Zone building colours at level 2; level 1 is a little darker, level 3 a little lighter.
const ZONE_COLORS := {
	D.ZONE_R: Color(0.255, 0.315, 0.285),
	D.ZONE_C: Color(0.255, 0.295, 0.37),
	D.ZONE_I: Color(0.335, 0.305, 0.255),
}
const LEVEL_SHADE := [0.82, 0.92, 1.0, 1.12]
const LANDMARKS := [D.HALL, D.STADIUM, D.UNIVERSITY, D.AIRPORT]
const PLOTS_X := D.W / D.PLOT
const PLOTS_Y := D.H / D.PLOT
## Size of the tile-state lookup: kind (5 bits), level (2), terrain (2), district + 1 (4).
const KEYS := 8192

var sim: CitySim
## Display colour per tile (RGBA8, 192 x 192).
var image: Image
## Shape data per tile: r = class, g = level, b = flags (1 = burning), a = district + 1.
var data: Image
## One texel per plot: 255 surveyed, 0 hazed.
var survey: Image
var texture: ImageTexture
var data_texture: ImageTexture
var survey_texture: ImageTexture
## Test hook: tiles painted since the last reset_counters().
var repainted_count: int = 0
## Test hook: full repaints so far.
var full_repaints: int = 0
## Milliseconds the last full repaint took.
var last_full_ms: float = 0.0
## Tile state key -> colour and data as little-endian RGBA8 words (colour 0 = not built yet).
var _lut_col: PackedInt32Array = PackedInt32Array()
var _lut_dat: PackedInt32Array = PackedInt32Array()
## The images' bytes; the single source both the full and the per-tile paint write.
var _col: PackedByteArray = PackedByteArray()
var _dat: PackedByteArray = PackedByteArray()


## Creates blank images and textures for p_sim (paint them with full_repaint()).
func setup(p_sim: CitySim) -> void:
	sim = p_sim
	_lut_col.resize(KEYS)
	_lut_dat.resize(KEYS)
	image = Image.create_empty(D.W, D.H, false, Image.FORMAT_RGBA8)
	data = Image.create_empty(D.W, D.H, false, Image.FORMAT_RGBA8)
	survey = Image.create_empty(PLOTS_X, PLOTS_Y, false, Image.FORMAT_L8)
	image.fill(COL_WILD)
	_col = image.get_data()
	_dat = data.get_data()
	texture = ImageTexture.create_from_image(image)
	data_texture = ImageTexture.create_from_image(data)
	survey_texture = ImageTexture.create_from_image(survey)


## Repaints every tile and plot (world_ready only; budget 15 ms). Runs of equal tile state reuse
## the previous lookup, and the words go to the images in one native conversion.
func full_repaint() -> void:
	if sim == null or sim.kind.size() != D.W * D.H:
		return
	var t0 := Time.get_ticks_usec()
	var n := D.W * D.H
	var col := PackedInt32Array()
	col.resize(n)
	var dat := PackedInt32Array()
	dat.resize(n)
	var kind := sim.kind
	var level := sim.level
	var terrain := sim.terrain
	var district := sim.district
	var lut_c := _lut_col
	var lut_d := _lut_dat
	var last := -1
	var c0 := 0
	var c1 := 0
	for i in range(n):
		var key := ((kind[i] & 31) << 8) | ((level[i] & 3) << 6) | ((terrain[i] & 3) << 4) | ((district[i] + 1) & 15)
		if key != last:
			last = key
			c0 = lut_c[key]
			if c0 == 0:
				_build_entry(key, kind[i], level[i], terrain[i], district[i])
				c0 = lut_c[key]
			c1 = lut_d[key]
		col[i] = c0
		dat[i] = c1
	var burning := sim.burning
	for i in sim.active:
		if burning[i] > 0:
			dat[i] = dat[i] | 0x10000
	_col = col.to_byte_array()
	_dat = dat.to_byte_array()
	_sync_images()
	_paint_survey(false)
	flush()
	repainted_count += n
	full_repaints += 1
	last_full_ms = (Time.get_ticks_usec() - t0) / 1000.0


## Repaints only the given tiles (tiles_changed). upload = false leaves the GPU copy to flush(),
## so several changes in one frame upload once.
func repaint(indices: PackedInt32Array, upload: bool = true) -> void:
	if sim == null or indices.is_empty() or sim.kind.size() != D.W * D.H:
		return
	for i in indices:
		if i < 0 or i >= D.W * D.H:
			continue
		_paint(i)
	_sync_images()
	if upload:
		flush()


## Uploads the images to their textures.
func flush() -> void:
	texture.update(image)
	data_texture.update(data)
	survey_texture.update(survey)


## Repaints the tiles of district mi (plus a one-tile rim) and the survey haze (territory_changed).
func repaint_district(mi: int, upload: bool = true) -> void:
	if sim == null or sim.kind.size() != D.W * D.H:
		return
	var r := sim.district_rect(mi) if mi >= 0 else Rect2i()
	if r.size.x > 0 and r.size.y > 0:
		r = r.grow(1)
		for y in range(maxi(r.position.y, D.Y0), mini(r.end.y, D.Y0 + D.H)):
			for x in range(maxi(r.position.x, D.X0), mini(r.end.x, D.X0 + D.W)):
				_paint(D.idx(x, y))
		_sync_images()
	_paint_survey(false)
	if upload:
		flush()


## Shape class of a tile from its kind, level and terrain.
static func tile_class(k: int, l: int, t: int) -> int:
	if k == D.ROAD:
		return CLS_BRIDGE if t == D.WATER else CLS_ROAD
	if t == D.WATER:
		return CLS_WATER
	match k:
		D.EMPTY:
			return CLS_LAND
		D.FOREST:
			return CLS_FOREST
		D.PARK:
			return CLS_PARK
		D.SITE:
			return CLS_SITE
		D.RUBBLE:
			return CLS_RUBBLE
	if D.is_zone(k):
		return CLS_LOT if l <= 0 else CLS_BUILDING
	if k in LANDMARKS:
		return CLS_LANDMARK
	return CLS_SERVICE


## Display colour of a tile (before the shader's haze).
static func tile_color(k: int, l: int, t: int, d: int) -> Color:
	var cls := tile_class(k, l, t)
	match cls:
		CLS_ROAD:
			return COL_ROAD if l <= D.GRADE_PAVED else COL_UNPAVED[mini(l, D.GRADE_TRAIL) - 1]
		CLS_BRIDGE:
			return COL_ROAD
		CLS_WATER:
			return COL_WATER
		CLS_PARK:
			return COL_PARK
		CLS_FOREST:
			return COL_FOREST
		CLS_SITE:
			return COL_SITE
		CLS_RUBBLE:
			return COL_RUBBLE
		CLS_LANDMARK:
			return COL_LANDMARK
		CLS_SERVICE:
			return COL_SERVICE
		CLS_LOT:
			return COL_LAND.lerp(ZONE_COLORS[k], 0.35)
		CLS_BUILDING:
			var c: Color = ZONE_COLORS[k]
			var f: float = LEVEL_SHADE[clampi(l, 0, 3)]
			return Color(minf(c.r * f, 1.0), minf(c.g * f, 1.0), minf(c.b * f, 1.0))
	return land_color(d)


## Ground colour of district d (-1 = unclaimed wilderness): a faint wash of the mayor's colour.
static func land_color(d: int) -> Color:
	if d < 0 or d >= D.MAYORS.size():
		return COL_WILD
	return COL_LAND.lerp(Color(str(D.MAYORS[d]["color"])), 0.02)


## Image pixel of world tile (x, y).
static func pixel_of(x: int, y: int) -> Vector2i:
	return Vector2i(x - D.X0, y - D.Y0)


## Zeroes the test counters.
func reset_counters() -> void:
	repainted_count = 0


func _paint(i: int) -> void:
	var key := ((sim.kind[i] & 31) << 8) | ((sim.level[i] & 3) << 6) | ((sim.terrain[i] & 3) << 4) | ((sim.district[i] + 1) & 15)
	if _lut_col[key] == 0:
		_build_entry(key, sim.kind[i], sim.level[i], sim.terrain[i], sim.district[i])
	_col.encode_s32(i * 4, _lut_col[key])
	_dat.encode_s32(i * 4, _lut_dat[key] | (0x10000 if sim.burning[i] > 0 else 0))
	repainted_count += 1


## Fills the lookup words for one tile state.
func _build_entry(key: int, k: int, l: int, t: int, d: int) -> void:
	var c := tile_color(k, l, t, d)
	_lut_col[key] = c.r8 | (c.g8 << 8) | (c.b8 << 16) | (255 << 24)
	_lut_dat[key] = tile_class(k, l, t) | (clampi(l, 0, 3) << 8) | (clampi(d + 1, 0, 255) << 24)


## Points the CPU images at the current bytes (Image.set_data shares the buffer until it changes).
func _sync_images() -> void:
	image.set_data(D.W, D.H, false, Image.FORMAT_RGBA8, _col)
	data.set_data(D.W, D.H, false, Image.FORMAT_RGBA8, _dat)


func _paint_survey(upload: bool = true) -> void:
	for py in range(PLOTS_Y):
		for px in range(PLOTS_X):
			var p := Vector2i(px + D.X0 / D.PLOT, py + D.Y0 / D.PLOT)
			var on := sim.is_surveyed(p.x * D.PLOT, p.y * D.PLOT)
			survey.set_pixel(px, py, Color8(255, 255, 255) if on else Color8(0, 0, 0))
	if upload:
		survey_texture.update(survey)
