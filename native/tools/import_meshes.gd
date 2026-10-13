extends SceneTree
## Bake importer (NATIVE_PORT 3-6/3-7): tools/bake-meshes.mjs output (<in>/index.json + <category>/<name>.json/.bin)
## → res://assets/<category>/<name>.res (ArrayMesh, default materials, metadata "bake")
##   + vehicles: res://assets/vehicles/<name>.tres (vehicle_template.gd) and <name>.<node>.res pivoted sub-meshes.
##
##   godot47 --headless --path native -s res://tools/import_meshes.gd -- --in=/abs/path/to/bake [--only=sedan,tree]
##       [--out=res://assets] [--compress]
##
## Per surface: triangle winding is flipped (bake = Three CCW, Godot front faces = CW), colour is sRGB8 (materials use
## vertex_color_is_srgb), custom0 is stored as RGBA_HALF (ao, part id, paint k, height ao), panel UVs get v = 1 − v
## (Three CanvasTexture flipY). Exit code = number of models that failed (capped at 125).

const VehicleTemplate := preload("res://assets/vehicles/vehicle_template.gd")
const CUSTOM0_FORMAT: int = Mesh.ARRAY_CUSTOM_RGBA_HALF << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
const EXIT_CAP: int = 125

var _in_dir: String = ""
var _out_root: String = "res://assets"
var _only: PackedStringArray = PackedStringArray()
var _compress: bool = false


func _initialize() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--in="):
			_in_dir = arg.trim_prefix("--in=")
		elif arg.begins_with("--out="):
			_out_root = arg.trim_prefix("--out=")
		elif arg.begins_with("--only="):
			_only = arg.trim_prefix("--only=").split(",", false)
		elif arg == "--compress":
			_compress = true
	_main.call_deferred()


func _main() -> void:
	if _in_dir.is_empty():
		print("FAIL import_meshes: missing --in=<bake dir> (output of node tools/bake-meshes.mjs)")
		quit(2)
		return
	var index: Dictionary = _read_json(_in_dir.path_join("index.json"))
	if index.is_empty():
		quit(2)
		return
	var t0: int = Time.get_ticks_msec()
	var failed: int = 0
	var done: int = 0
	for entry: Dictionary in index.get("models", []):
		var name: String = str(entry.get("name", ""))
		if not _only.is_empty() and not _matches(name):
			continue
		var err: String = _import_model(_in_dir.path_join(str(entry.get("json", ""))))
		if err.is_empty():
			done += 1
		else:
			failed += 1
			print("FAIL import %s: %s" % [name, err])
	print("RESULT import_meshes: %d imported, %d failed, %.1f s" % [done, failed, (Time.get_ticks_msec() - t0) / 1000.0])
	quit(mini(failed, EXIT_CAP))


func _matches(name: String) -> bool:
	for o: String in _only:
		if name.contains(o):
			return true
	return false


func _read_json(path: String) -> Dictionary:
	var text: String = FileAccess.get_file_as_string(path)
	if text.is_empty():
		print("FAIL import_meshes: cannot read %s (%s)" % [path, error_string(FileAccess.get_open_error())])
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		print("FAIL import_meshes: %s is not a JSON object" % path)
		return {}
	return parsed


## Returns "" on success, else the reason.
func _import_model(json_path: String) -> String:
	var h: Dictionary = _read_json(json_path)
	if h.is_empty():
		return "bad header"
	if int(h.get("schema", 0)) != 1:
		return "unsupported schema %s" % str(h.get("schema"))
	var bin: PackedByteArray = FileAccess.get_file_as_bytes(json_path.get_base_dir().path_join(str(h.get("bin", ""))))
	if bin.size() != int(h.get("bin_bytes", -1)):
		return "bin size %d != header %d" % [bin.size(), int(h.get("bin_bytes", -1))]
	var name: String = str(h["name"])
	var category: String = str(h["category"])
	var dir: String = _out_root.path_join(category)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))

	var meshes: Dictionary = {}       # node name → ArrayMesh
	var transforms: Dictionary = {}   # node name → Array[Transform3D]
	var parts: Dictionary = {}        # main node parts
	var surface_names: PackedStringArray = PackedStringArray()
	for node: Dictionary in h.get("nodes", []):
		var node_name: String = str(node["name"])
		var node_parts: Dictionary = {}
		var node_surfaces: PackedStringArray = PackedStringArray()
		var mesh: ArrayMesh = _build_mesh(node, bin, node_parts, node_surfaces)
		if mesh == null:
			return "node %s: bad buffers" % node_name
		mesh.resource_name = name if node_name == "main" else "%s.%s" % [name, node_name]
		meshes[node_name] = mesh
		var xf: Array[Transform3D] = []
		for m: Array in node.get("placements", []):
			xf.append(_transform_from_three(m))
		transforms[node_name] = xf
		if node_name == "main":
			parts = node_parts
			surface_names = node_surfaces
		else:
			mesh.set_meta(&"bake", {"parts": node_parts, "surfaces": node_surfaces})

	var main: ArrayMesh = meshes.get("main") as ArrayMesh
	if main == null:
		return "no main node"
	var js: Dictionary = h.get("js", {})
	var bbox: Dictionary = js.get("bbox", {})
	var js_ref: Dictionary = {
		"bbox": _aabb_from(bbox),
		"tris": int(js.get("tris", 0)),
		"welded_vertices": int(js.get("welded_vertices", 0)),
		"source": h.get("source", {}),
		"web_frozen_sha": str(h.get("web_frozen_sha", "")),
		"three": str(h.get("three", "")),
	}
	var points: Dictionary = _points(h.get("points", {}))
	var meta: Dictionary = {
		"name": name, "category": category, "m1a": bool(h.get("m1a", false)),
		"surfaces": surface_names, "parts": parts, "points": points, "js_ref": js_ref, "ao": h.get("ao", {}),
		"panels": _panels(h),
	}
	if category != "vehicles":
		main.set_meta(&"bake", meta)
		return _save(main, dir.path_join("%s.res" % name))

	# vehicles: sub-meshes as their own .res, template .tres pointing at everything
	var tpl: Resource = VehicleTemplate.new()
	var v: Dictionary = h.get("vehicle", {})
	tpl.set(&"kind", StringName(str(v.get("kind", ""))))
	tpl.set(&"variant", int(v.get("variant", 0)))
	tpl.set(&"detailed", bool(v.get("detailed", false)))
	tpl.set(&"npc", bool(v.get("npc", false)))
	tpl.set(&"npc_weight", float(v.get("npc_weight", 0.0)))
	var dims: Dictionary = v.get("dims", {})
	tpl.set(&"length", float(dims.get("L", 0.0)))
	tpl.set(&"width", float(dims.get("W", 0.0)))
	tpl.set(&"height", float(dims.get("H", 0.0)))
	tpl.set(&"wheel_radius", float(v.get("wheel_radius", 0.0)))
	var err: String = _save(main, dir.path_join("%s.res" % name))
	if not err.is_empty():
		return err
	tpl.set(&"mesh", load(dir.path_join("%s.res" % name)))
	tpl.set(&"surface_names", surface_names)
	tpl.set(&"parts", parts)
	var groups: Dictionary = {}
	var all_groups: Dictionary = v.get("lamp_groups", {})
	for g: String in all_groups:
		var present: PackedStringArray = PackedStringArray()
		for p: String in all_groups[g]:
			if parts.has(p):
				present.append(p)
		if not present.is_empty():
			groups[g] = present
	tpl.set(&"lamp_groups", groups)
	var off: Dictionary = {}
	var off_src: Dictionary = v.get("lamp_off_multiplier", {})
	for k: String in off_src:
		off[k] = Color.html(str(off_src[k]))
	tpl.set(&"lamp_off_multiplier", off)
	var subs: Dictionary = {}
	for node_name: String in meshes:
		if node_name == "main":
			continue
		var sub_path: String = dir.path_join("%s.%s.res" % [name, node_name])
		err = _save(meshes[node_name] as ArrayMesh, sub_path)
		if not err.is_empty():
			return err
		subs[node_name] = {"mesh": load(sub_path), "transforms": transforms[node_name]}
	tpl.set(&"sub_meshes", subs)
	var wheels: Array = []
	for w: Dictionary in v.get("merged_wheels", []):
		var c: Array = w.get("center", [0.0, 0.0, 0.0])
		var part: String = str(w.get("part", ""))
		wheels.append({"part": part, "id": int((parts.get(part, {}) as Dictionary).get("id", -1)),
			"center": Vector3(float(c[0]), float(c[1]), float(c[2])),
			"radius": float(w.get("radius", 0.0)), "width": float(w.get("width", 0.0))})
	tpl.set(&"merged_wheels", wheels)
	if v.get("beacon_pos") is Array:
		var b: Array = v["beacon_pos"]
		points["beaconPos"] = Vector3(float(b[0]), float(b[1]), float(b[2]))
	tpl.set(&"points", points)
	var pl: Dictionary = {}
	var pl_src: Dictionary = h.get("points_local", {})
	for k: String in pl_src:
		var e: Dictionary = pl_src[k]
		var p: Array = e.get("pos", [0.0, 0.0, 0.0])
		pl[k] = {"node": str(e.get("node", "")), "pos": Vector3(float(p[0]), float(p[1]), float(p[2]))}
	tpl.set(&"points_local", pl)
	var paint: Dictionary = v.get("paint", {})
	tpl.set(&"paint_default", Color.html(str(paint.get("default", "#ffffff"))))
	tpl.set(&"tintable", bool(paint.get("tintable", false)))
	tpl.set(&"livery", bool(paint.get("livery", false)))
	js_ref["paint_fit"] = paint
	js_ref["ao"] = h.get("ao", {})
	tpl.set(&"js_ref", js_ref)
	return _save(tpl, dir.path_join("%s.tres" % name))


func _save(res: Resource, path: String) -> String:
	var flags: int = ResourceSaver.FLAG_COMPRESS if _compress and path.ends_with(".res") else 0
	var err: Error = ResourceSaver.save(res, path, flags)
	if err != OK:
		return "save %s: %s" % [path, error_string(err)]
	res.take_over_path(path)
	return ""


## One bake node → ArrayMesh. Fills `parts` (part name → range dict) and `surface_names`.
func _build_mesh(node: Dictionary, bin: PackedByteArray, parts: Dictionary, surface_names: PackedStringArray) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	for s: Dictionary in node.get("surfaces", []):
		var nv: int = int(s["vertex_count"])
		var ni: int = int(s["index_count"])
		var buf: Dictionary = s["buffers"]
		var pos_f: PackedFloat32Array = bin.slice(int(buf["position"]), int(buf["position"]) + nv * 12).to_float32_array()
		var nrm_f: PackedFloat32Array = bin.slice(int(buf["normal"]), int(buf["normal"]) + nv * 12).to_float32_array()
		var col_b: PackedByteArray = bin.slice(int(buf["color"]), int(buf["color"]) + nv * 4)
		var cus_f: PackedFloat32Array = bin.slice(int(buf["custom0"]), int(buf["custom0"]) + nv * 16).to_float32_array()
		var idx_i: PackedInt32Array = bin.slice(int(buf["index"]), int(buf["index"]) + ni * 4).to_int32_array()
		if pos_f.size() != nv * 3 or nrm_f.size() != nv * 3 or col_b.size() != nv * 4 or cus_f.size() != nv * 4 or idx_i.size() != ni:
			return null
		var verts := PackedVector3Array()
		var norms := PackedVector3Array()
		var cols := PackedColorArray()
		verts.resize(nv)
		norms.resize(nv)
		cols.resize(nv)
		var custom := PackedByteArray()
		custom.resize(nv * 8)
		for i: int in nv:
			verts[i] = Vector3(pos_f[i * 3], pos_f[i * 3 + 1], pos_f[i * 3 + 2])
			norms[i] = Vector3(nrm_f[i * 3], nrm_f[i * 3 + 1], nrm_f[i * 3 + 2])
			# +0.25: Godot packs ARRAY_COLOR to RGBA8 by truncation; keep the byte exact either way.
			cols[i] = Color((col_b[i * 4] + 0.25) / 255.0, (col_b[i * 4 + 1] + 0.25) / 255.0, (col_b[i * 4 + 2] + 0.25) / 255.0, 1.0)
			for k: int in 4:
				custom.encode_half(i * 8 + k * 2, cus_f[i * 4 + k])
		for t: int in ni / 3:  # Three CCW → Godot CW
			var b: int = idx_i[t * 3 + 1]
			idx_i[t * 3 + 1] = idx_i[t * 3 + 2]
			idx_i[t * 3 + 2] = b
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = norms
		arrays[Mesh.ARRAY_COLOR] = cols
		arrays[Mesh.ARRAY_CUSTOM0] = custom
		arrays[Mesh.ARRAY_INDEX] = idx_i
		if buf.get("uv") != null:
			var uv_f: PackedFloat32Array = bin.slice(int(buf["uv"]), int(buf["uv"]) + nv * 8).to_float32_array()
			var uvs := PackedVector2Array()
			uvs.resize(nv)
			for i: int in nv:
				uvs[i] = Vector2(uv_f[i * 2], 1.0 - uv_f[i * 2 + 1])
			arrays[Mesh.ARRAY_TEX_UV] = uvs
		var si: int = mesh.get_surface_count()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, CUSTOM0_FORMAT)
		var sname: String = str(s["name"])
		mesh.surface_set_name(si, sname)
		mesh.surface_set_material(si, _material(s.get("material", {})))
		surface_names.append(sname)
		for p: Dictionary in s.get("parts", []):
			parts[str(p["name"])] = {
				"surface": si, "id": int(p["id"]),
				"first_index": int(p["first_index"]), "index_count": int(p["index_count"]),
				"first_vertex": int(p["first_vertex"]), "vertex_count": int(p["vertex_count"]),
				"aabb": _aabb_from(p.get("aabb", {}) if p.get("aabb") != null else {}),
			}
	return mesh


## Default look that renders the web colours with stock materials (Lambert, no specular). The view replaces lamp and
## body materials with its shaders (lamp states, NPC tint, AO strength); see res://assets/README.md.
func _material(desc: Dictionary) -> Material:
	var m := StandardMaterial3D.new()
	if str(desc.get("shading", "lambert")) == "unlit":
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	else:
		m.diffuse_mode = BaseMaterial3D.DIFFUSE_LAMBERT
		m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		m.roughness = 1.0
		m.metallic_specular = 0.0
	if bool(desc.get("vertex_colors", false)):
		m.vertex_color_use_as_albedo = true
		m.vertex_color_is_srgb = true
	else:
		var c: Color = Color.html(str(desc.get("color", "#ffffff")))
		c.a = float(desc.get("opacity", 1.0))
		m.albedo_color = c
	if bool(desc.get("transparent", false)):
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		if str(desc.get("blend", "mix")) == "add":
			m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		if not bool(desc.get("depth_write", true)):
			m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	if bool(desc.get("double_sided", false)):
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
	if desc.has("emissive"):
		m.emission_enabled = true
		m.emission = Color.html(str(desc["emissive"]))
		m.emission_energy_multiplier = float(desc.get("emissive_intensity", 1.0))
	return m


## Three Matrix4.toArray() is column-major.
func _transform_from_three(e: Array) -> Transform3D:
	var f: PackedFloat32Array = PackedFloat32Array(e)
	return Transform3D(Basis(Vector3(f[0], f[1], f[2]), Vector3(f[4], f[5], f[6]), Vector3(f[8], f[9], f[10])), Vector3(f[12], f[13], f[14]))


func _aabb_from(b: Dictionary) -> AABB:
	if not b.has("min"):
		return AABB()
	var lo: Array = b["min"]
	var hi: Array = b["max"]
	var p := Vector3(float(lo[0]), float(lo[1]), float(lo[2]))
	return AABB(p, Vector3(float(hi[0]), float(hi[1]), float(hi[2])) - p)


func _points(src: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k: String in src:
		var v: Array = src[k]
		if not v.is_empty() and v[0] is Array:
			var arr := PackedVector3Array()
			for q: Array in v:
				arr.append(Vector3(float(q[0]), float(q[1]), float(q[2])))
			out[k] = arr
		else:
			out[k] = Vector3(float(v[0]), float(v[1]), float(v[2]))
	return out


func _panels(h: Dictionary) -> Array:
	var out: Array = []
	for node: Dictionary in h.get("nodes", []):
		for s: Dictionary in node.get("surfaces", []):
			var mat: Dictionary = s.get("material", {})
			for p: Dictionary in mat.get("panels", []):
				out.append(p)
	return out
