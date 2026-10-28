extends FpFeature
## Campaign, newspaper, shop and notice posters on the streets (slice D). Wires the HY image client
## (GmiImageClient), the director (what each carrier shows), the surfaces (carriers and poster faces
## on tile holders) and the compositor (crisp text drawn over the image). Posters within VIS_PROP
## of the player get a composite with their text (at most MAX_COMPOSITES); farther ones show the
## shared image of their key. Billboards and shelter lightboxes glow at night. E on a poster opens
## a full-screen viewer. Offline (every gate) all art comes from the pre-baked set.

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const DIRECTOR := preload("res://scripts/fp/posters/poster_director.gd")
const SURFACES := preload("res://scripts/fp/posters/poster_surfaces.gd")
const COMPOSITOR := preload("res://scripts/fp/posters/poster_compositor.gd")
const LAYOUTS := preload("res://scripts/fp/posters/poster_layouts.gd")
const ART := preload("res://scripts/fp/posters/poster_art.gd")
const MAX_COMPOSITES := 32
## Night glow and composite upkeep run at 2 Hz.
const UPDATE_S := 0.5
const MODAL := &"poster"
## Emission energies (see glow()): billboards are lamp-lit at night only; shelter lightboxes are
## backlit, faint by day and brightest at night. Measured against the night exposure: above about
## 1.6 the white of a print blooms and its text loses contrast.
const NIGHT_BILLBOARD := 0.9
const DAY_SHELTER := 0.3
const NIGHT_SHELTER := 1.3
const OWNER := "posters"

var image_client: GmiImageClient
## Composite cap (MAX_COMPOSITES; tests lower it).
var max_composites: int = MAX_COMPOSITES
var director: DIRECTOR
var surfaces: SURFACES
var compositor: COMPOSITOR
## slot id -> slot (poster_surfaces.gd).
var slots: Dictionary = {}
## slot id -> assignment (poster_director.gd).
var assigned: Dictionary = {}
## key -> the poster image (pre-baked, cached, live or procedural).
var base_tex: Dictionary = {}
## composite id -> {"tex": Texture2D or null while rendering, "slots": {slot id: true}, "key"}.
var composites: Dictionary = {}
var _by_tile: Dictionary = {}
var _requested: Dictionary = {}
var _slot_comp: Dictionary = {}
var _slot_cid: Dictionary = {}
var _slot_mat: Dictionary = {}
var _mats: Dictionary = {}
## Lit materials with their glow kind: [[StandardMaterial3D, "billboard" | "shelter"]].
var _lit_mats: Array = []
var _t: float = 0.0
var _viewer: Control
var _viewer_tex: TextureRect
var _viewer_slot: String = ""
var _connected: Array[Array] = []


func feature_id() -> String:
	return "posters"


func setup(p_ctx: FpContext) -> void:
	super.setup(p_ctx)
	image_client = GmiImageClient.new()
	image_client.name = "ImageClient"
	add_child(image_client)
	image_client.setup(ctx.client, func() -> int: return ctx.sim.day if ctx.sim != null else 0)
	image_client.player_pos = ctx.player_position
	image_client.image_ready.connect(_on_image_ready)
	compositor = COMPOSITOR.new()
	compositor.name = "Compositor"
	add_child(compositor)
	compositor.composited.connect(_on_composited)
	director = DIRECTOR.new()
	director.setup(ctx)
	surfaces = SURFACES.new()
	if ctx.view != null:
		surfaces.setup(ctx)
		_link(ctx.view.tile_built, _on_tile_built)
		_link(ctx.view.tile_cleared, _on_tile_cleared)
	if ctx.brain != null:
		_link(ctx.brain.mayor_decided, on_mayor_decided)
		_link(ctx.brain.news_published, on_news)
		_link(ctx.brain.council_ruled, _on_council)
	if ctx.sim != null:
		_link(ctx.sim.event_started, _on_event)
		_link(ctx.sim.event_ended, _on_event)
		_link(ctx.sim.day_started, _on_day)
	if ctx.bus != null:
		_link(ctx.bus.interact_requested, _on_interact)
		_link(ctx.bus.world_ready, close_viewer)


func _link(sig: Signal, c: Callable) -> void:
	if not sig.is_connected(c):
		sig.connect(c)
		_connected.append([sig, c])


func on_world_rebuilt() -> void:
	close_viewer()
	_forget_all()
	if ctx.view == null:
		return
	for i in surfaces.candidates():
		var h := ctx.view.tile_holder(i)
		if h != null:
			_add_tile(i, h)
	director.seed_from_brain()
	_reassign_all()
	update_composites()


## Save section. Pure (S0 §6.4): the save path flushes the view's deferred rebuild queue first
## (Main._canonicalise_for_save), so the slot set read here is the canonical one a load
## re-derives from sim state, and a reload keeps the same posters instead of the carrier a tile
## has since become.
func to_dict() -> Dictionary:
	var d: Dictionary = director.to_dict()
	var ss := {}
	for id: String in assigned.keys():
		var a: Dictionary = assigned[id]
		ss[id] = {"key": a["key"], "kind": a["kind"], "family": a["family"], "size": a["size"], "overlay": a["overlay"]}
	d["slots"] = ss
	d["live_today"] = image_client.live_today
	d["live_session"] = image_client.live_session
	d["day"] = ctx.sim.day if ctx.sim != null else 0
	return d


func from_dict(d: Dictionary) -> void:
	close_viewer()
	if d.is_empty():
		director.campaigns = [{}, {}, {}, {}, {}]
		director.gazette = {}
		director.seed_from_brain()
		_reassign_all()
		update_composites()
		return
	director.from_dict(d)
	director.seed_from_brain()
	image_client.live_today = int(d.get("live_today", 0))
	image_client.live_session = maxi(image_client.live_session, int(d.get("live_session", 0)))
	_reassign_all()
	var saved: Variant = d.get("slots", {})
	if typeof(saved) == TYPE_DICTIONARY:
		for id: Variant in (saved as Dictionary).keys():
			var e: Variant = saved[id]
			if typeof(e) == TYPE_DICTIONARY and slots.has(str(id)):
				_restore_slot(str(id), e)
	update_composites()


func teardown() -> void:
	close_viewer()
	for pair: Array in _connected:
		var sig: Signal = pair[0]
		if sig.is_connected(pair[1]):
			sig.disconnect(pair[1])
	_connected.clear()
	for id: String in slots.keys():
		_free_nodes(slots[id])
	slots.clear()
	assigned.clear()
	_by_tile.clear()
	composites.clear()
	_slot_comp.clear()
	_slot_cid.clear()
	_slot_mat.clear()
	if image_client != null:
		image_client.close()


func _process(delta: float) -> void:
	_t += delta
	if _t < UPDATE_S:
		return
	_t = 0.0
	for e: Array in _lit_mats:
		(e[0] as StandardMaterial3D).emission_energy_multiplier = glow(str(e[1]))
	update_composites()


## Emission energy of a lit poster from view.night (0 noon .. 1 midnight). The emission is the
## print itself (EMISSION_OP_MULTIPLY), so this is how bright the print glows on its own.
func glow(kind: String = "billboard") -> float:
	var n := ctx.view.night if ctx != null and ctx.view != null else 0.0
	var dark := smoothstep(0.2, 0.75, n)
	if kind == "shelter":
		return lerpf(DAY_SHELTER, NIGHT_SHELTER, dark)
	return NIGHT_BILLBOARD * dark


# ------------------------------------------------------------------ tiles and slots

func _on_tile_built(i: int, holder: Node3D) -> void:
	if ctx.view.in_setup:
		return
	_add_tile(i, holder)
	for id: String in _by_tile.get(i, []):
		_assign(id)


func _on_tile_cleared(i: int) -> void:
	_drop_tile(i)


func _add_tile(i: int, holder: Node3D) -> void:
	_drop_tile(i)
	var ids: Array[String] = []
	for s: Dictionary in surfaces.scan(i, holder):
		slots[s["id"]] = s
		ids.append(s["id"])
	if not ids.is_empty():
		_by_tile[i] = ids


func _drop_tile(i: int) -> void:
	for id: String in _by_tile.get(i, []):
		_release_composite(id)
		if slots.has(id):
			_free_nodes(slots[id])
		slots.erase(id)
		assigned.erase(id)
		_slot_cid.erase(id)
		_slot_mat.erase(id)
	_by_tile.erase(i)


func _free_nodes(s: Dictionary) -> void:
	for n: Variant in s.get("nodes", []):
		if is_instance_valid(n):
			(n as Node).free()


func _forget_all() -> void:
	for id: String in slots.keys():
		_free_nodes(slots[id])
	slots.clear()
	assigned.clear()
	_by_tile.clear()
	for cid: String in composites.keys():
		compositor.cancel(cid)
	composites.clear()
	_slot_comp.clear()
	_slot_cid.clear()
	_slot_mat.clear()


func _reassign_all() -> void:
	for id: String in slots.keys():
		_assign(id)


## Re-evaluates one slot; returns true when what it shows changed.
func _assign(id: String) -> bool:
	var s: Dictionary = slots[id]
	var a: Dictionary = director.assign(s)
	return _set_assignment(id, a)


func _set_assignment(id: String, a: Dictionary) -> bool:
	var s: Dictionary = slots[id]
	var old: Dictionary = assigned.get(id, {})
	if a.is_empty():
		assigned.erase(id)
		_release_composite(id)
		_show(s, null)
		return not old.is_empty()
	if not old.is_empty() and str(old["key"]) == str(a["key"]) and old["overlay"] == a["overlay"] and str(old["kind"]) == str(a["kind"]):
		return false
	assigned[id] = a
	_release_composite(id)
	_slot_cid[id] = ("%s|%s|%s|%s" % [a["key"], a["kind"], JSON.stringify(a["overlay"]), str(_px(s))]).sha256_text().left(24)
	_request(a, s["pos"])
	_apply(id)
	return true


func _restore_slot(id: String, e: Dictionary) -> void:
	var key := str(e.get("key", ""))
	if key.is_empty():
		return
	var kind := str(e.get("kind", ""))
	var a := {"key": key, "kind": kind, "family": str(e.get("family", kind.get_slice("_", 0))), "prompt": _prompt_of(key),
		"size": str(e.get("size", "")), "priority": 0, "overlay": DIRECTOR._restore({"overlay": e.get("overlay", {})})["overlay"]}
	_set_assignment(id, a)


func _prompt_of(key: String) -> String:
	for c: Dictionary in director.campaigns:
		if str(c.get("key", "")) == key:
			return str(c.get("prompt", ""))
	if str(director.gazette.get("key", "")) == key:
		return str(director.gazette.get("prompt", ""))
	return ""


func _request(a: Dictionary, pos: Vector3) -> void:
	var key := str(a["key"])
	if str(a["family"]) == "lease":
		base_tex[key] = ART.procedural("lease", key)
		return
	if base_tex.has(key) or _requested.has(key):
		return
	_requested[key] = true
	if str(a["prompt"]).is_empty():
		image_client.request_key(key, str(a["kind"]), str(a["size"]))
	else:
		image_client.request(str(a["kind"]), str(a["prompt"]), str(a["size"]), int(a["priority"]), pos)


func _on_image_ready(key: String, tex: Texture2D, meta: Dictionary) -> void:
	if tex == null:
		return
	var changed: bool = base_tex.get(key, null) != tex
	base_tex[key] = tex
	if not changed:
		return
	for id: String in assigned.keys():
		if str(assigned[id]["key"]) != key:
			continue
		if _slot_comp.has(id):
			var cid: String = _slot_comp[id]
			_enqueue_composite(cid, id, 0.0)
		_apply(id)
	if ctx.bus != null:
		ctx.bus.poster_ready.emit({"key": key, "kind": str(meta.get("kind", "")), "texture": tex, "meta": meta})


# ------------------------------------------------------------------ materials

## Shows a slot's composite when it has one, else its key's image cropped to the slot.
func _apply(id: String) -> void:
	var s: Dictionary = slots[id]
	var a: Dictionary = assigned.get(id, {})
	if a.is_empty():
		_show(s, null)
		return
	var tex: Texture2D = null
	var crop := true
	var cid: String = _slot_comp.get(id, "")
	if not cid.is_empty() and composites.has(cid) and composites[cid]["tex"] != null:
		tex = composites[cid]["tex"]
		crop = false
	elif base_tex.has(str(a["key"])):
		tex = base_tex[str(a["key"])]
	if tex == null:
		_show(s, null)
		return
	var size: Vector2 = s["size"]
	var mat := _material(tex, str(s["lit"]), size.x / maxf(size.y, 1e-6) if crop else -1.0)
	_slot_mat[id] = mat
	_show(s, mat)


func _show(s: Dictionary, mat: Material) -> void:
	for f: Dictionary in s["faces"]:
		var mi: MeshInstance3D = f["mesh"]
		if is_instance_valid(mi):
			mi.material_override = mat
			mi.visible = mat != null


## One material per image (and per slot aspect for cropped images, per glow kind), shared by every
## slot that shows it. aspect < 0: the texture already has the slot's aspect.
func _material(tex: Texture2D, lit: String, aspect: float) -> StandardMaterial3D:
	var k := "%d|%s|%.2f" % [tex.get_instance_id(), lit, aspect]
	if _mats.has(k):
		return _mats[k]
	if _mats.size() > 160:
		_prune_materials()
	var m := StandardMaterial3D.new()
	m.albedo_texture = tex
	m.roughness = 0.85
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	if aspect > 0.0 and tex.get_height() > 0:
		var ta := float(tex.get_width()) / float(tex.get_height())
		if ta > aspect:
			m.uv1_scale = Vector3(aspect / ta, 1, 1)
			m.uv1_offset = Vector3((1.0 - aspect / ta) * 0.5, 0, 0)
		else:
			m.uv1_scale = Vector3(1, ta / aspect, 1)
			m.uv1_offset = Vector3(0, (1.0 - ta / aspect) * 0.5, 0)
	if not lit.is_empty():
		# MULTIPLY: the glow is the print itself. The default ADD operator would add the emission
		# colour to the texture and wash the whole face out to white at night.
		m.emission_enabled = true
		m.emission = Color(1, 1, 1)
		m.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY
		m.emission_texture = tex
		m.emission_energy_multiplier = glow(lit)
		_lit_mats.append([m, lit])
	_mats[k] = m
	return m


func _prune_materials() -> void:
	var used := {}
	for m: Variant in _slot_mat.values():
		used[m] = true
	for k: String in _mats.keys():
		if not used.has(_mats[k]):
			_mats.erase(k)
	_lit_mats = _lit_mats.filter(func(e: Array) -> bool: return used.has(e[0]))


# ------------------------------------------------------------------ composites

## Gives slots within VIS_PROP of the player a composite (nearest first, at most MAX_COMPOSITES
## distinct ones) and releases the composite of slots beyond 1.25 * VIS_PROP. When the cap is
## reached, the composites of the farthest slots make room for nearer ones.
func update_composites() -> void:
	if ctx == null:
		return
	var here := ctx.player_position()
	var near: Array = []
	var held: Array = []
	for id: String in assigned.keys():
		var s: Dictionary = slots[id]
		var p: Vector3 = s["pos"]
		var dist := Vector2(p.x - here.x, p.z - here.z).length()
		if _slot_comp.has(id):
			if dist > 1.25 * WS.VIS_PROP:
				_release_composite(id)
				_apply(id)
				continue
			held.append([dist, id])
		if dist <= WS.VIS_PROP and base_tex.has(str(assigned[id]["key"])):
			near.append([dist, id])
	near.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	# The composites the nearest slots want, nearest first (slots with the same poster share one).
	var want := {}
	for e: Array in near:
		var cid: String = _slot_cid.get(str(e[1]), "")
		if not cid.is_empty() and not want.has(cid):
			if want.size() >= max_composites:
				break
			want[cid] = true
	var missing := 0
	for cid: String in want.keys():
		if not composites.has(cid):
			missing += 1
	if composites.size() + missing > max_composites:
		held.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) > float(b[0]))
		for e: Array in held:
			if composites.size() + missing <= max_composites:
				break
			var hid: String = e[1]
			if _slot_comp.has(hid) and not want.has(str(_slot_comp[hid])):
				_release_composite(hid)
				_apply(hid)
	for e: Array in near:
		var id: String = e[1]
		var cid: String = _slot_cid.get(id, "")
		if cid.is_empty() or not want.has(cid) or str(_slot_comp.get(id, "")) == cid:
			continue
		if not composites.has(cid):
			if composites.size() >= max_composites:
				continue
			composites[cid] = {"tex": null, "slots": {}, "key": str(assigned[id]["key"])}
			_enqueue_composite(cid, id, float(e[0]))
		composites[cid]["slots"][id] = true
		_slot_comp[id] = cid
		_apply(id)


func _enqueue_composite(cid: String, id: String, order: float) -> void:
	var a: Dictionary = assigned[id]
	var s: Dictionary = slots[id]
	var size: Vector2 = s["size"]
	var aspect := size.x / maxf(size.y, 1e-6)
	var els := LAYOUTS.build(str(a["family"]), str(a["kind"]), a["overlay"], aspect)
	var base: Texture2D = base_tex.get(str(a["key"]), null)
	compositor.enqueue(cid, base, els, LAYOUTS.pixel_size(aspect), order)


func _release_composite(id: String) -> void:
	if not _slot_comp.has(id):
		return
	var cid: String = _slot_comp[id]
	_slot_comp.erase(id)
	if not composites.has(cid):
		return
	(composites[cid]["slots"] as Dictionary).erase(id)
	if (composites[cid]["slots"] as Dictionary).is_empty():
		compositor.cancel(cid)
		composites.erase(cid)


func _on_composited(cid: String, tex: Texture2D) -> void:
	if cid.begins_with("viewer|"):
		if _viewer_tex != null and cid == "viewer|" + _viewer_slot and tex != null:
			_viewer_tex.texture = tex
		return
	if not composites.has(cid) or tex == null:
		return
	composites[cid]["tex"] = tex
	for id: String in (composites[cid]["slots"] as Dictionary).keys():
		if slots.has(id):
			_apply(id)


static func _px(s: Dictionary) -> Vector2i:
	var size: Vector2 = s["size"]
	return LAYOUTS.pixel_size(size.x / maxf(size.y, 1e-6))


# ------------------------------------------------------------------ sources

## CityBrain.mayor_decided: refreshes the mayor's campaign on every billboard and wall showing it.
func on_mayor_decided(mi: int, entry: Dictionary) -> void:
	if director.on_mayor_decided(mi, entry):
		_reassign_carriers(["billboard", "wall"])


## CityBrain.news_published: a new Gazette front page at every shelter.
func on_news(paper: Dictionary) -> void:
	if director.on_news(paper):
		_reassign_carriers(["shelter"])


func _on_council(_ruling: Dictionary) -> void:
	_reassign_carriers(["wall"])


func _on_event(_ev: Dictionary) -> void:
	_reassign_carriers(["wall"])


func _on_day(_day: int) -> void:
	_reassign_carriers(["wall", "shelter"])


func _reassign_carriers(kinds: Array) -> void:
	for id: String in slots.keys():
		if str(slots[id]["carrier"]) in kinds:
			_assign(id)


# ------------------------------------------------------------------ interaction

## Ray against the poster faces within max_dist: the nearest front-facing hit.
func pick(origin: Vector3, dir: Vector3, max_dist: float) -> Dictionary:
	var dn := dir.normalized()
	var best := {}
	var best_t := max_dist
	for id: String in assigned.keys():
		var s: Dictionary = slots[id]
		var sp: Vector3 = s["pos"]
		if sp.distance_to(origin) > max_dist + 0.3:
			continue
		for f: Dictionary in s["faces"]:
			var n: Vector3 = f["normal"]
			var denom := dn.dot(n)
			if denom > -1e-4:
				continue
			var t := ((f["center"] as Vector3) - origin).dot(n) / denom
			if t < 0.0 or t > best_t:
				continue
			var p := origin + dn * t
			var rel := p - (f["center"] as Vector3)
			var half: Vector2 = f["half"]
			if absf(rel.dot(f["right"])) <= half.x and absf(rel.dot(f["up"])) <= half.y:
				best_t = t
				best = target_for(id, p, t)
	return best


## The interaction target of slot id (S0 §9 target dict).
func target_for(id: String, p: Vector3, dist: float) -> Dictionary:
	var a: Dictionary = assigned.get(id, {})
	var s: Dictionary = slots[id]
	return {"kind": "poster", "id": str(a.get("key", "")), "tile": int(s["tile"]), "pos": p, "dist": dist,
		"label": "Look at " + title_of(a), "data": {"slot": id, "family": a.get("family", ""), "kind": a.get("kind", ""), "overlay": a.get("overlay", {})}}


## A short human title for an assignment ("Ada Okafor's campaign poster").
static func title_of(a: Dictionary) -> String:
	var o: Dictionary = a.get("overlay", {})
	match str(a.get("family", "")):
		"campaign":
			return "%s's campaign poster" % str(o.get("name", "the mayor"))
		"gazette":
			return "the GridFall Gazette"
		"ad":
			return "the %s ad" % str(o.get("name", "shop"))
		"hoarding":
			return "Coming soon: %s" % str(o.get("name", ""))
		"notice":
			return "public notice: %s" % str(o.get("title", ""))
		"incident":
			return "warning: %s" % str(o.get("title", ""))
		"placard":
			return "protest flyer"
		"lease":
			return "For lease · %s" % str(o.get("address", ""))
	return "poster"


func _on_interact(t: Dictionary) -> void:
	if str(t.get("kind", "")) != "poster":
		return
	var data: Dictionary = t.get("data", {})
	var id := str(data.get("slot", ""))
	if not assigned.has(id):
		id = ""
		for sid: String in assigned.keys():
			if str(assigned[sid]["key"]) == str(t.get("id", "")):
				id = sid
				break
	if not id.is_empty():
		open_viewer(id)


## Full-screen view of a poster in the HUD's overlay slot (modal "poster"; E or Esc closes it).
func open_viewer(id: String) -> void:
	if ctx.hud == null or not assigned.has(id):
		return
	close_viewer()
	var a: Dictionary = assigned[id]
	var s: Dictionary = slots[id]
	var root := Control.new()
	root.name = "PosterViewer"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	var bg := ColorRect.new()
	bg.color = Color(0.02, 0.02, 0.03, 0.9)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bg)
	var tr := TextureRect.new()
	tr.set_anchors_preset(Control.PRESET_FULL_RECT)
	tr.offset_left = 48
	tr.offset_top = 40
	tr.offset_right = -48
	tr.offset_bottom = -72
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var cid: String = _slot_comp.get(id, "")
	tr.texture = composites[cid]["tex"] if not cid.is_empty() and composites.has(cid) and composites[cid]["tex"] != null else base_tex.get(str(a["key"]), null)
	root.add_child(tr)
	var cap := Label.new()
	cap.text = "%s     [E] / [Esc]  Close" % title_of(a).capitalize()
	cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cap.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	cap.offset_top = -56
	cap.offset_bottom = -20
	cap.add_theme_font_size_override("font_size", 20)
	cap.add_theme_color_override("font_color", Color(0.92, 0.92, 0.95))
	root.add_child(cap)
	ctx.hud.slot("overlay").add_child(root)
	_viewer = root
	_viewer_tex = tr
	_viewer_slot = id
	ctx.push_modal(MODAL)
	var size: Vector2 = s["size"]
	var aspect := size.x / maxf(size.y, 1e-6)
	compositor.enqueue("viewer|" + id, base_tex.get(str(a["key"]), null), LAYOUTS.build(str(a["family"]), str(a["kind"]), a["overlay"], aspect), LAYOUTS.pixel_size(aspect, 2), -1.0)


func close_viewer() -> void:
	if _viewer == null:
		return
	compositor.cancel("viewer|" + _viewer_slot)
	if is_instance_valid(_viewer):
		_viewer.queue_free()
	_viewer = null
	_viewer_tex = null
	_viewer_slot = ""
	if ctx != null and ctx.has_modal(MODAL):
		ctx.pop_modal(MODAL)


## True while the full-screen viewer is open.
func viewer_open() -> bool:
	return _viewer != null


func _unhandled_input(event: InputEvent) -> void:
	if _viewer == null or event.is_echo():
		return
	if event.is_action_pressed("interact") or event.is_action_pressed("pause_menu"):
		close_viewer()
		get_viewport().set_input_as_handled()


# ------------------------------------------------------------------ smoke and photo tour

func self_test() -> Dictionary:
	var counts := {}
	for s: Dictionary in slots.values():
		counts[s["carrier"]] = int(counts.get(s["carrier"], 0)) + 1
	var c_lots := 0
	if ctx.sim != null:
		for i in ctx.sim.active:
			if ctx.sim.kind[i] == D.ZONE_C and ctx.sim.level[i] > 0:
				c_lots += 1
	var detail := "%d surfaces %s, %d assigned, %d composites (%d drawn, main thread max read %.2f / upload %.2f ms), client %s" % [slots.size(),
		str(counts), assigned.size(), composites.size(), compositor.done_count, compositor.max_read_ms, compositor.max_upload_ms, str(image_client.stats)]
	if slots.is_empty():
		return {"ok": c_lots == 0, "detail": ("no C lots yet; " if c_lots == 0 else "no poster surface with %d C lots; " % c_lots) + detail}
	return {"ok": not assigned.is_empty(), "detail": detail}


## "billboard" (the billboard nearest City Hall, framed at 6 m), "bus_shelter" and the billboard
## again at night, all eye-level.
func photo_shots() -> Array:
	var out: Array = []
	var origin: Vector3 = ctx.mode.spawn_point()["pos"] if ctx.mode != null else Vector3(16, 0, 16)
	var bb := _frame_shot("billboard", origin, 0.3, 10.5)
	if not bb.is_empty():
		out.append(bb)
		var night := bb.duplicate()
		night["name"] = "billboard_night"
		night["hour"] = 22.5
		out.append(night)
	var sh := _frame_shot("shelter", origin, 0.16, 10.5)
	if not sh.is_empty():
		sh["name"] = "bus_shelter"
		out.append(sh)
	return out


## A pose standing `dist` in front of the nearest slot of a carrier, looking at its centre.
func _frame_shot(carrier: String, origin: Vector3, dist: float, hour: float) -> Dictionary:
	var best := {}
	var best_d := INF
	for id: String in assigned.keys():
		var s: Dictionary = slots[id]
		if str(s["carrier"]) != carrier:
			continue
		for f: Dictionary in s["faces"]:
			var n: Vector3 = f["normal"]
			var c: Vector3 = f["center"]
			var feet := Vector3(c.x, 0, c.z) + Vector3(n.x, 0, n.z).normalized() * dist
			if ctx.collision != null and (ctx.collision.is_blocked(feet, WS.PLAYER_RADIUS) or is_nan(ctx.collision.ground_height(feet))):
				continue
			var d := feet.distance_to(origin)
			if d < best_d:
				best_d = d
				var eye := Vector3(feet.x, WS.EYE, feet.z)
				var to := c - eye
				var yaw := rad_to_deg(atan2(-to.x, -to.z))
				var pitch := rad_to_deg(atan2(to.y, Vector2(to.x, to.z).length()))
				best = {"name": carrier, "pos": feet, "yaw": yaw, "pitch": pitch, "hour": hour}
	return best
