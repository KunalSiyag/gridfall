class_name Cinematic
extends Node
## Scripted ~30 s trailer for social posts. Drives the camera through the mayors, the residents,
## a construction row and nightfall, with captions and a ticker of live GMI mayor calls.
## Grow a city first with GRIDFALL_CINEMATIC=prep, then record with Movie Maker:
##   GRIDFALL_CINEMATIC=record godot --path . --write-movie out.avi --fixed-fps 30 --resolution 1920x1080

const SAVE := "user://gridfall_cinematic.json"
const FONT := preload("res://fonts/lilita_one_regular.ttf")
const OVERVIEW := Vector3(15.5, 0, 13.5)
const PREROLL_MIN := 3.0
const PREROLL_MAX := 45.0
const GOLD := Color("#FFB800")
const CYAN := Color("#00F0FF")
const REPO := "github.com/KunalSiyag/gridfall"

var main: Node
var rig: Node3D
var cam: Camera3D
var shots: Array[Dictionary] = []
var _started := false
var _pre_t := 0.0
var _t := 0.0
var _shot := -1
var _from: Dictionary = {}
var _cur: Dictionary = {"pos": OVERVIEW, "yaw": 28.0, "pitch": -40.0, "dist": 74.0}
var _follow := Vector3.ZERO
var _first_mi := -1
var _resident_id := ""
var _site_center := OVERVIEW
var _last_seen := OVERVIEW
var _downtown := OVERVIEW
var _live := 0
var _ticker_lines: Array[String] = []

var _title_box: Control
var _cap_box: Control
var _cap_title: Label
var _cap_sub: Label
var _ticker_box: Control
var _ticker_body: Label
var _end_box: Control


func run(p_main: Node) -> void:
	main = p_main
	rig = main.camera_rig
	cam = main.camera
	rig.set_process(false)
	rig.set_process_input(false)
	rig.set_process_unhandled_input(false)
	_build_overlay()
	main.brain.mayor_decided.connect(_on_decided)
	if not main.load_game(SAVE):
		push_error("Cinematic: no city at %s (run GRIDFALL_CINEMATIC=prep first)" % SAVE)
		get_tree().quit(1)
		return
	main.hud.visible = false
	# The unpowered/dry tile markers are a planning aid, not scenery.
	main.view._power_icons.visible = false
	main.view._water_icons.visible = false
	main.sky.fixed_hour = 10.0
	var cs: Array = main._construction_showcase()
	if not cs.is_empty():
		_site_center = cs[0]
	_downtown = _find_downtown()
	# The clock is stepped by hand per shot, so every take shows the same daily routine:
	# commute under the mayors, evening crowds for the residents, the trip home at night.
	main.sim.set_speed(0)
	shots = [
		{"name": "mayors", "dur": 5.5, "travel": 2.6, "yaw": 70.0, "pitch": -30.0, "dist": 17.0, "orbit": 10.0,
			"title": "5 AI mayors run the city", "sub": "Each one a different model, deciding live on GMI Cloud inference"},
		{"name": "residents", "dur": 6.0, "travel": 2.4, "yaw": 95.0, "pitch": -46.0, "dist": 7.5, "orbit": 14.0,
			"title": "~100 AI residents with their own minds", "sub": "Jobs, moods and commutes. They even fix the city themselves"},
		{"name": "construction", "dur": 6.5, "travel": 2.4, "yaw": 60.0, "pitch": -40.0, "dist": 9.0, "orbit": 24.0,
			"title": "Every building goes up in stages", "sub": "Excavators, cranes and resident work crews"},
		{"name": "night", "dur": 5.5, "travel": 2.2, "yaw": 28.0, "pitch": -33.0, "dist": 24.0, "orbit": 18.0, "hour": [10.0, 21.0],
			"title": "A living day and night", "sub": "Traffic, street lights and lit windows"},
		{"name": "end", "dur": 5.0, "travel": 2.6, "yaw": 45.0, "pitch": -42.0, "dist": 66.0, "orbit": 8.0, "hour": [21.0, 21.5]},
	]
	print("GRIDFALL_CINE: preroll frame=%d live=%s day=%d" % [Engine.get_process_frames(), str(main.client.live_enabled), main.sim.day])


func _process(delta: float) -> void:
	if shots.is_empty():
		return
	if not _started:
		_pre_t += delta
		_cur = {"pos": OVERVIEW, "yaw": 28.0 + _pre_t * 1.2, "pitch": -40.0, "dist": 74.0}
		_apply_cam(_cur)
		_title_box.modulate.a = clampf(_pre_t / 0.6, 0.0, 1.0)
		if (_first_mi >= 0 and _pre_t > PREROLL_MIN) or _pre_t > PREROLL_MAX:
			_started = true
			if _first_mi < 0:
				_first_mi = 0
			print("GRIDFALL_CINE: start frame=%d preroll=%.1fs" % [Engine.get_process_frames(), _pre_t])
		return
	_t += delta
	_title_box.modulate.a = clampf(1.0 - _t / 0.7, 0.0, 1.0)
	var acc := 0.0
	var idx := shots.size()
	for k in range(shots.size()):
		if _t < acc + float(shots[k]["dur"]):
			idx = k
			break
		acc += float(shots[k]["dur"])
	if idx >= shots.size():
		_finish()
		return
	if idx != _shot:
		_enter(idx)
	var s: Dictionary = shots[idx]
	var lt := _t - acc
	var dur := float(s["dur"])
	var target := _target_pos(s)
	_follow = target if lt < delta * 1.5 else _follow.lerp(target, minf(1.0, delta * 2.5))
	var to := {"pos": _follow, "yaw": float(s["yaw"]) + float(s["orbit"]) * lt / dur, "pitch": float(s["pitch"]), "dist": float(s["dist"]) * (1.0 - 0.08 * lt / dur)}
	_cur = _blend(_from, to, smoothstep(0.0, float(s["travel"]), lt))
	_apply_cam(_cur)
	if s.has("hour"):
		var h: Array = s["hour"]
		main.sky.fixed_hour = lerpf(float(h[0]), float(h[1]), smoothstep(0.0, dur * 0.8, lt))
	var fade := smoothstep(0.0, 0.45, lt) * smoothstep(dur, dur - 0.45, lt)
	if s.has("title"):
		_cap_box.modulate.a = fade
		_end_box.modulate.a = 0.0
	else:
		_cap_box.modulate.a = 0.0
		_end_box.modulate.a = smoothstep(0.6, 1.6, lt)
		_ticker_box.modulate.a = 1.0 - smoothstep(0.0, 0.8, lt)


func _enter(idx: int) -> void:
	_shot = idx
	_from = _cur.duplicate()
	var s: Dictionary = shots[idx]
	if s.has("title"):
		_cap_title.text = str(s["title"])
		_cap_sub.text = str(s["sub"])
	match str(s["name"]):
		"mayors":
			_step_to(3)
		"night":
			_step_to(4)
	if str(s["name"]) == "construction":
		_site_center = _busiest_sites(_site_center)
	if str(s["name"]) == "residents":
		_resident_id = _pick_resident()
		if main.view.avatars != null:
			main.view.avatars.select(_resident_id)
	elif main.view.avatars != null:
		main.view.avatars.select("")
	print("GRIDFALL_CINE: shot %s at t=%.1f frame=%d" % [s["name"], _t, Engine.get_process_frames()])


## Runs growth ticks until tick_in_day reaches `tick` (4 means the day's last tick has run).
func _step_to(tick: int) -> void:
	var guard := 0
	while main.sim.tick_in_day < tick and guard < 4:
		guard += 1
		var last: bool = main.sim.tick_in_day == 3
		main.sim.step_tick()
		if last:
			break


func _target_pos(s: Dictionary) -> Vector3:
	match str(s["name"]):
		"mayors":
			return main.view.avatar_position(_first_mi)
		"residents":
			return _last_seen
		"construction":
			return _site_center
		"night":
			return _downtown
	return OVERVIEW


func _blend(a: Dictionary, b: Dictionary, p: float) -> Dictionary:
	return {
		"pos": (a["pos"] as Vector3).lerp(b["pos"], p),
		"yaw": lerpf(float(a["yaw"]), float(b["yaw"]), p),
		"pitch": lerpf(float(a["pitch"]), float(b["pitch"]), p),
		# Zoom in log space so a long push-in does not rush its last few metres.
		"dist": exp(lerpf(log(float(a["dist"])), log(float(b["dist"])), p)),
	}


func _apply_cam(s: Dictionary) -> void:
	rig.position = s["pos"]
	rig.rotation_degrees = Vector3(float(s["pitch"]), float(s["yaw"]), 0.0)
	cam.position = Vector3(0.0, 0.0, float(s["dist"]))


## A resident at the outdoor spot (park, stadium, building site) where most people have gathered.
## Destinations stay put, unlike walkers who may head indoors mid-shot.
func _pick_resident() -> String:
	var D := preload("res://scripts/sim/sim_defs.gd")
	var groups: Dictionary = {}
	for r: Dictionary in main.residents.people:
		var state := str(r.get("state", ""))
		if not (state.begins_with("at the") or state.begins_with("building") or state.begins_with("helping")):
			continue
		var at := int(r["at"])
		if not groups.has(at):
			groups[at] = []
		(groups[at] as Array).append(str(r["id"]))
	var best := -1
	for at: int in groups.keys():
		if best < 0 or (groups[at] as Array).size() > (groups[best] as Array).size():
			best = at
	if best < 0:
		print("GRIDFALL_CINE: no outdoor gathering")
		return ""
	_last_seen = Vector3(D.tx(best), 0, D.ty(best))
	print("GRIDFALL_CINE: %d residents gathered at (%d,%d)" % [(groups[best] as Array).size(), D.tx(best), D.ty(best)])
	return str((groups[best] as Array)[0])


## Centre of the densest cluster of open construction sites, so the shot shows several stages.
func _busiest_sites(fallback: Vector3) -> Vector3:
	var D := preload("res://scripts/sim/sim_defs.gd")
	var pts: Array[Vector2] = []
	var wts: Array[float] = []
	for i: int in main.sim.sites.keys():
		var plan := str(main.sim.sites[i].get("plan", ""))
		# Upgrades keep the old building standing, so they read as finished from the air.
		if plan not in ["build", "light", "zone_new", "zone_house", "zone_tower"]:
			continue
		pts.append(Vector2(D.tx(i), D.ty(i)))
		# Early stages (fence, dig, slab) carry the machines, which read best on camera.
		var early := int(main.sim.sites[i].get("stage", 0)) <= 2
		wts.append(1.0 + (1.0 if plan == "build" else 0.0) + (3.0 if early else 0.0))
	var best := -1.0
	var best_c := Vector2.ZERO
	for p in pts:
		var n := 0.0
		var c := Vector2.ZERO
		for k in range(pts.size()):
			if p.distance_to(pts[k]) <= 3.5:
				n += wts[k]
				c += pts[k] * wts[k]
		if n > best:
			best = n
			best_c = c / n
	print("GRIDFALL_CINE: %d new-build sites, busiest cluster weight %.0f" % [pts.size(), best])
	return fallback if best < 2.0 else Vector3(best_c.x, 0, best_c.y)


func _find_downtown() -> Vector3:
	var D := preload("res://scripts/sim/sim_defs.gd")
	var sim: CitySim = main.sim
	var best := -1
	var best_l := -1
	for i in range(D.W * D.H):
		if sim.kind[i] == D.ZONE_C and sim.level[i] > best_l:
			best_l = sim.level[i]
			best = i
	return OVERVIEW if best < 0 else Vector3(D.tx(best), 0, D.ty(best))


func _on_decided(mi: int, entry: Dictionary) -> void:
	var src := str(entry.get("source", ""))
	var D := preload("res://scripts/sim/sim_defs.gd")
	var m: Dictionary = D.MAYORS[mi]
	print("GRIDFALL_CINE: mayor %s source=%s latency=%dms" % [m["name"], src, int(entry.get("latency_ms", 0))])
	if _first_mi < 0:
		_first_mi = mi
	if src != "live":
		return
	_live += 1
	var model := str(m["model"]).get_slice("/", 1) if str(m["model"]).contains("/") else str(m["model"])
	var line := "%s  ·  %.1fs\n      %s" % [model, float(entry.get("latency_ms", 0)) / 1000.0, _action_text(entry)]
	_ticker_lines.push_front(line)
	_ticker_lines = _ticker_lines.slice(0, 3)
	_ticker_body.text = "\n".join(_ticker_lines)
	_ticker_box.modulate.a = 1.0


func _action_text(entry: Dictionary) -> String:
	for v: Variant in entry.get("actions", []):
		var rec: Dictionary = v
		if not bool(rec.get("ok", false)):
			continue
		var a: Dictionary = rec.get("action", {})
		match str(a.get("type", "")):
			"build":
				return "builds a " + str(a.get("building", "building")).replace("_", " ")
			"zone":
				var z := str(a.get("zone", a.get("kind", ""))).to_upper().left(1)
				return "zones new " + str({"R": "homes", "C": "shops", "I": "industry"}.get(z, "land"))
			"road":
				return "lays new roads"
			"annex":
				return "annexes new land"
			"bulldoze":
				return "clears old lots"
			"set_tax", "tax":
				return "adjusts taxes"
			"emergency":
				return "dispatches emergency crews"
			"grant":
				return "funds a neighbour"
		return str(a.get("type", "acts")).replace("_", " ")
	return "saves money for tomorrow"


func _finish() -> void:
	set_process(false)
	print("GRIDFALL_CINE: done frame=%d live_mayor_calls=%d" % [Engine.get_process_frames(), _live])
	main.audio._exit_tree()
	get_tree().quit(0)


# ------------------------------------------------------------------ overlay

func _build_overlay() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 20
	add_child(layer)
	_title_box = _full(layer, CenterContainer.new())
	var tv := VBoxContainer.new()
	tv.alignment = BoxContainer.ALIGNMENT_CENTER
	_title_box.add_child(tv)
	tv.add_child(_text("GRIDFALL", 120, Color.WHITE, 14))
	tv.add_child(_text("A SimCity where every decision is made by AI", 34, GOLD, 8))

	_cap_box = _full(layer, MarginContainer.new())
	_margins(_cap_box, 56, 56)
	var cv := VBoxContainer.new()
	cv.alignment = BoxContainer.ALIGNMENT_END
	_cap_box.add_child(cv)
	var cp := _panel(GOLD)
	cp.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	cv.add_child(cp)
	var cpv := VBoxContainer.new()
	cp.add_child(cpv)
	_cap_title = _text("", 48, Color.WHITE, 8)
	_cap_sub = _text("", 27, Color(0.86, 0.9, 0.96), 5)
	cpv.add_child(_cap_title)
	cpv.add_child(_cap_sub)
	_cap_box.modulate.a = 0.0

	_ticker_box = _full(layer, MarginContainer.new())
	_margins(_ticker_box, 36, 36)
	var tvb := VBoxContainer.new()
	_ticker_box.add_child(tvb)
	var tp := _panel(CYAN)
	tp.size_flags_horizontal = Control.SIZE_SHRINK_END
	# A fixed width keeps the shrink-end layout from drifting off screen as lines change.
	tp.custom_minimum_size = Vector2(480, 0)
	tvb.add_child(tp)
	var tpv := VBoxContainer.new()
	tp.add_child(tpv)
	tpv.add_child(_text("●  LIVE  ·  GMI Cloud inference", 24, Color(1.0, 0.36, 0.36), 5))
	_ticker_body = _text("", 19, Color(0.9, 0.95, 1.0), 4)
	tpv.add_child(_ticker_body)
	_ticker_box.modulate.a = 0.0

	_end_box = _full(layer, CenterContainer.new())
	var ep := _panel(GOLD)
	_end_box.add_child(ep)
	var ev := VBoxContainer.new()
	ev.alignment = BoxContainer.ALIGNMENT_CENTER
	ep.add_child(ev)
	for row: Array in [["GRIDFALL", 92, Color.WHITE], ["Built with Factory AI Droid", 40, GOLD], ["+ GMI Cloud inference", 40, CYAN], [REPO, 32, Color(0.9, 0.93, 1.0)]]:
		var l := _text(str(row[0]), int(row[1]), row[2], 10)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		ev.add_child(l)
	_end_box.modulate.a = 0.0


func _full(layer: CanvasLayer, c: Control) -> Control:
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(c)
	return c


func _margins(c: Control, h: int, v: int) -> void:
	for side: String in ["left", "right"]:
		c.add_theme_constant_override("margin_" + side, h)
	for side: String in ["top", "bottom"]:
		c.add_theme_constant_override("margin_" + side, v)


func _panel(accent: Color) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.03, 0.05, 0.09, 0.74)
	sb.set_corner_radius_all(16)
	sb.border_width_left = 7
	sb.border_color = accent
	sb.content_margin_left = 30
	sb.content_margin_right = 30
	sb.content_margin_top = 18
	sb.content_margin_bottom = 20
	p.add_theme_stylebox_override("panel", sb)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p


func _text(t: String, size_px: int, col: Color, outline: int) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_override("font", FONT)
	l.add_theme_font_size_override("font_size", size_px)
	l.add_theme_color_override("font_color", col)
	l.add_theme_constant_override("outline_size", outline)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.55))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l
