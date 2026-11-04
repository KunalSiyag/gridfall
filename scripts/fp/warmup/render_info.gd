class_name RenderInfo
extends Node
## Web probe aid (flag web_first_use_marks, web only): every SECONDS prints one console line with
## what the renderer drew in the last frame of the main viewport, so a Planner or street change
## shows its effect in objects, primitives and draw calls, separately for the visible pass and the
## shadow passes. RENDERINFO {"vis":{"obj":..,"prim":..,"draw":..},"shadow":{...},"mode":"orbit"}
## Never logs anything else; the tag is a fixed literal.

const SECONDS := 3.0
const LINE := "RENDERINFO "

var main: Node
var _t: float = 0.0
## Materials seen so far (instance ids), so a line names only the ones that came in since.
var _seen: Dictionary = {}


## Adds a RenderInfo under main when the probe marks are on (the web build with the flag), else
## nothing.
static func attach(m: Node) -> void:
	if not FirstUse.active() or m.get_node_or_null("RenderInfo") != null:
		return
	var n := RenderInfo.new()
	n.name = "RenderInfo"
	n.main = m
	m.add_child(n)


func _process(delta: float) -> void:
	_t += delta
	if _t < SECONDS:
		return
	_t = 0.0
	print(line())
	for l in new_materials(15):
		print(l)


## NEWMAT console lines for up to cap materials that came into the scene since the last call (the
## first call only learns them): what first shows in the mid-play shader hitches. Kind, a name or
## path of the material and the node that carries it; nothing player-written.
func new_materials(cap: int) -> Array[String]:
	var out: Array[String] = []
	var learn := _seen.is_empty()
	var stack: Array[Node] = [main]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		if not (n is GeometryInstance3D):
			continue
		var mats: Array[Material] = []
		if (n as GeometryInstance3D).material_override != null:
			mats.append((n as GeometryInstance3D).material_override)
		var mesh: Mesh = null
		if n is MeshInstance3D:
			mesh = (n as MeshInstance3D).mesh
		elif n is MultiMeshInstance3D and (n as MultiMeshInstance3D).multimesh != null:
			mesh = (n as MultiMeshInstance3D).multimesh.mesh
		if mesh != null:
			for s in mesh.get_surface_count():
				var m := mesh.surface_get_material(s)
				if m != null:
					mats.append(m)
		for m: Material in mats:
			var id := m.get_instance_id()
			if _seen.has(id):
				continue
			_seen[id] = true
			if learn or out.size() >= cap:
				continue
			var what := m.get_class() + ":" + m.resource_path.get_file()
			if m is ShaderMaterial and (m as ShaderMaterial).shader != null:
				what += ":" + (m as ShaderMaterial).shader.resource_path.get_file()
			elif m is BaseMaterial3D:
				var b := m as BaseMaterial3D
				what += ":%s tr%d cull%d" % [m.resource_name, int(b.transparency), int(b.cull_mode)]
				if b.albedo_texture != null:
					what += " " + b.albedo_texture.resource_path.get_file()
			var where := str(main.get_path_to(n)).left(60)
			out.append("NEWMAT t=%d %s @ %s" % [int(WebSupport.perf_now()), what, where])
	return out


## The console line for the main viewport as of the last drawn frame.
func line() -> String:
	var rid := get_viewport().get_viewport_rid()
	var out := {"mode": str(main.get("view_mode"))}
	var cam: Camera3D = main.call("active_camera")
	if cam != null:
		out["state"] = ShaderWarmup.render_state(cam, false)
	for pair: Array in [
		["vis", RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE],
		["shadow", RenderingServer.VIEWPORT_RENDER_INFO_TYPE_SHADOW]
	]:
		var t: int = pair[1]
		out[pair[0]] = {
			"obj":
			RenderingServer.viewport_get_render_info(
				rid,
				t as RenderingServer.ViewportRenderInfoType,
				RenderingServer.VIEWPORT_RENDER_INFO_OBJECTS_IN_FRAME
			),
			"prim":
			RenderingServer.viewport_get_render_info(
				rid,
				t as RenderingServer.ViewportRenderInfoType,
				RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME
			),
			"draw":
			RenderingServer.viewport_get_render_info(
				rid,
				t as RenderingServer.ViewportRenderInfoType,
				RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME
			),
		}
	return LINE + JSON.stringify(out, "", false)
