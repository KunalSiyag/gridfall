class_name WarmSignature
extends RefCounted
## What decides which shader programs a material needs, as a short string: two materials with the
## same signature link the same programs (the browser's driver caches by generated source), so the
## warm-up draws one of them, not all fifteen hundred a grown city holds. A StandardMaterial3D /
## ORMMaterial3D generates its shader from its flags and enums (shading, transparency, blend, cull,
## billboard, triplanar, texture channels...) and from which texture slots are filled, never from
## the colour, roughness or texture content, so the signature is every bool and enum property plus
## "slot filled" for each object property. A ShaderMaterial's program follows its shader. Anything
## else falls back to its class and instance. The signature is deliberately finer than Godot's own
## key (it also separates properties the key ignores): a finer split only costs a second copy, a
## coarser one would leave a program to link in play. describe() / build() turn a material into a
## small dictionary and back (tools/warm_variants.gd writes data/warm_orbit_variants.json with
## them): the Planner's materials are made when the Planner first opens, so the warm-up rebuilds a
## stand-in with the same signature from the catalogue.

## Properties that never reach the generated shader (or that this class handles itself).
const SKIP := {
	"resource_local_to_scene": true,
	"resource_name": true,
	"resource_path": true,
	"render_priority": true,
	"script": true,
}

static var _cache: Dictionary = {}
## Class name -> [[property, type], ...]: the bool, enum and object properties of that class (the
## property list is the expensive part of a signature, and a class has one list).
static var _names: Dictionary = {}


## Forgets the per-material cache (a collect pass calls it before and after).
static func clear_cache() -> void:
	_cache.clear()


static func of(mat: Material) -> String:
	if mat == null:
		return "null"
	var id := mat.get_instance_id()
	if _cache.has(id):
		return _cache[id]
	var sig := _compute(mat)
	_cache[id] = sig
	return sig


static func _compute(mat: Material) -> String:
	if mat is ShaderMaterial:
		var sh := (mat as ShaderMaterial).shader
		if sh == null:
			return "S:none"
		return "S:" + (sh.resource_path if sh.resource_path != "" else str(sh.get_instance_id()))
	if mat is BaseMaterial3D:
		var parts: PackedStringArray = [mat.get_class()]
		for pair: Array in _props_of(mat):
			var pname: String = pair[0]
			var v: Variant = mat.get(pname)
			if int(pair[1]) == TYPE_OBJECT:
				if v != null:
					parts.append(pname)
			elif int(pair[1]) == TYPE_BOOL:
				if bool(v):
					parts.append(pname)
			else:
				parts.append("%s=%d" % [pname, int(v)])
		return "B:" + ",".join(parts)
	return "O:%s:%d" % [mat.get_class(), mat.get_instance_id()]


## The properties that count for a material's class, from the first material of the class seen. A
## property the editor hides in some states (a billboard's "keep scale") is still listed, so every
## material of the class is read through the same names.
static func _props_of(mat: Material) -> Array:
	var cls := mat.get_class()
	if _names.has(cls):
		return _names[cls]
	var out: Array = []
	for prop: Dictionary in mat.get_property_list():
		var pname: String = prop["name"]
		if SKIP.has(pname) or pname.begins_with("resource_") or pname.contains("/"):
			continue
		if int(prop["type"]) in [TYPE_BOOL, TYPE_INT, TYPE_OBJECT]:
			out.append([pname, int(prop["type"])])
	_names[cls] = out
	return out


## A small dictionary a stand-in can be rebuilt from: {"t": "std", "class", "props": {name: value},
## "slots": [names of the filled texture slots]} or {"t": "shader", "shader": path}. Null for a
## material this cannot rebuild (a ShaderMaterial whose shader has no path, anything else).
static func describe(mat: Material) -> Variant:
	if mat is ShaderMaterial:
		var sh := (mat as ShaderMaterial).shader
		if sh == null or sh.resource_path == "":
			return null
		return {"t": "shader", "shader": sh.resource_path}
	if mat is BaseMaterial3D:
		var props := {}
		var slots: Array = []
		for pair: Array in _props_of(mat):
			var pname: String = pair[0]
			var v: Variant = mat.get(pname)
			if int(pair[1]) == TYPE_OBJECT:
				if v != null:
					slots.append(pname)
			elif int(pair[1]) == TYPE_BOOL:
				props[pname] = bool(v)
			else:
				props[pname] = int(v)
		return {"t": "std", "class": mat.get_class(), "props": props, "slots": slots}
	return null


## A material with the signature of the one describe() read, or null. Texture slots get a 2x2 white
## image (only that the slot is filled counts), shaders load from their path.
static func build(spec: Dictionary) -> Material:
	if str(spec.get("t", "")) == "shader":
		var path := str(spec.get("shader", ""))
		if not ResourceLoader.exists(path):
			return null
		var sh := load(path) as Shader
		if sh == null:
			return null
		var sm := ShaderMaterial.new()
		sm.shader = sh
		return sm
	if str(spec.get("t", "")) != "std":
		return null
	var m: BaseMaterial3D = (
		ORMMaterial3D.new()
		if str(spec.get("class", "")) == "ORMMaterial3D"
		else StandardMaterial3D.new()
	)
	var props: Dictionary = spec.get("props", {})
	for pname: String in props:
		m.set(pname, props[pname])
	var img := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	var tex := ImageTexture.create_from_image(img)
	for pname: String in spec.get("slots", []):
		if pname != "next_pass":
			m.set(pname, tex)
	return m
