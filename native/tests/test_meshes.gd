extends RefCounted
## T0: baked meshes (tools/bake-meshes.mjs → tools/import_meshes.gd → res://assets/**) load and still match the
## frozen web build they were baked from (NATIVE_PORT 3-7 "검증: 삼각형 수, 치수", M1a bake set).
##
## Per model (every res://assets/{vehicles,props,road}/<name>.res, sub-meshes <name>.<node>.res via their template):
##   - loads as ArrayMesh (props/road: meta "bake") or VehicleTemplate (.tres, vehicles),
##   - vertex count == welded vertex count recorded by the bake, triangles (× placements) == the JS triangle count,
##   - AABB (main + sub-meshes at their placements) == the JS Box3 within AABB_TOL (1 cm),
##   - Godot winding: front faces are CW (the importer flipped Three's CCW), i.e. (b−a)×(c−a) opposes the normal,
##   - every part range lies inside its surface and carries its part id in custom0.y; custom0.x (AO) is in [0, 1].
## Per vehicle: lamp parts brake L/R, head L/R, blink FL/FR/RL/RR, ≥ 2 hazard lamps; 4+ wheels (merged or sub-mesh);
##   NPC paint is tintable unless the kind has a livery; dims == vehicle_kinds.json.
## Bake set: the 8 NPC kinds of config.json npc.kinds × every canonical variant (vehicle_kinds.json canon[]), player,
##   road segments v0..v3 (± right sound barrier), text-free props, CCTV, cone, warning triangle.
## Rebuild: node tools/bake-meshes.mjs && godot47 --headless --path native -s res://tools/import_meshes.gd -- --in=<out>

const VehicleTemplate := preload("res://assets/vehicles/vehicle_template.gd")
const CATEGORIES: PackedStringArray = ["vehicles", "props", "road"]
const AABB_TOL: float = 0.01
const DIMS_TOL: float = 1e-4
const WINDING_MIN: float = 0.995
const CONFIG_PATH: String = "res://data/config.json"
const KINDS_PATH: String = "res://data/vehicle_kinds.json"
const LAMPS_REQUIRED: PackedStringArray = ["brake_L", "brake_R", "head_L", "head_R",
	"blink_FL", "blink_FR", "blink_RL", "blink_RR"]
const PROPS_REQUIRED: Dictionary = {"tree": 12, "pine": 8, "bush": 6, "paddy": 9, "house": 8, "church": 4,
	"mountain": 10, "cloud": 8}
const SINGLE_REQUIRED: PackedStringArray = ["props/cctv", "props/cone", "props/warning_triangle", "vehicles/player_v0"]

var _fails: int = 0
var _checked: int = 0


func run() -> int:
	var found: Dictionary = _discover()  # "category/name" → path (.tres for vehicles, .res otherwise)
	_check_bake_set(found)
	var t0: int = Time.get_ticks_msec()
	var keys: Array = found.keys()
	keys.sort()
	for key: String in keys:
		var path: String = found[key]
		if path.ends_with(".tres"):
			_check_vehicle(key, path)
		else:
			_check_scenery(key, path)
	print("INFO test_meshes: %d models checked in %d ms" % [_checked, Time.get_ticks_msec() - t0])
	return _fails


func _check(cond: bool, what: String) -> void:
	if cond:
		return
	_fails += 1
	print("FAIL test_meshes: %s" % what)


## Main assets only: vehicles are found by their .tres, sub-meshes (<name>.<node>.res) through the template.
func _discover() -> Dictionary:
	var out: Dictionary = {}
	for cat: String in CATEGORIES:
		var dir: String = "res://assets".path_join(cat)
		for file: String in DirAccess.get_files_at(dir):
			var base: String = file.get_basename()
			if base.contains("."):
				continue
			if cat == "vehicles" and file.get_extension() == "tres":
				out["%s/%s" % [cat, base]] = dir.path_join(file)
			elif cat != "vehicles" and file.get_extension() == "res":
				out["%s/%s" % [cat, base]] = dir.path_join(file)
	return out


func _read_json(path: String) -> Dictionary:
	var text: String = FileAccess.get_file_as_string(path)
	var data: Variant = JSON.parse_string(text)
	return data if data is Dictionary else {}


func _check_bake_set(found: Dictionary) -> void:
	var cfg: Dictionary = _read_json(CONFIG_PATH)
	var kinds: Dictionary = (_read_json(KINDS_PATH).get("kinds", {}) as Dictionary)
	var npc: Array = (cfg.get("npc", {}) as Dictionary).get("kinds", [])
	_check(npc.size() == 8, "config.json npc.kinds has the 8 M1a NPC kinds (got %d)" % npc.size())
	for e: Array in npc:
		var kind: String = str(e[0])
		for v: int in _canon_variants(kinds.get(kind, {}) as Dictionary):
			_check(found.has("vehicles/%s_v%d" % [kind, v]), "baked NPC vehicles/%s_v%d (vehicle_kinds canon)" % [kind, v])
	for key: String in SINGLE_REQUIRED:
		_check(found.has(key), "baked %s" % key)
	for v: int in 4:
		_check(found.has("road/segment_v%d" % v), "baked road/segment_v%d" % v)
		_check(found.has("road/segment_v%d_sb_right" % v), "baked road/segment_v%d_sb_right" % v)
	for kind: String in PROPS_REQUIRED:
		for v: int in int(PROPS_REQUIRED[kind]):
			_check(found.has("props/%s_v%d" % [kind, v]), "baked props/%s_v%d" % [kind, v])


func _canon_variants(def: Dictionary) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	var canon: Array = def.get("canon", [0])
	for c: Variant in canon:
		if not out.has(int(c)):
			out.append(int(c))
	if out.is_empty():
		out.append(0)
	return out


func _check_vehicle(key: String, path: String) -> void:
	var tpl: Resource = load(path)
	_check(tpl != null and tpl.get_script() == VehicleTemplate, "%s loads as VehicleTemplate" % key)
	if tpl == null or tpl.get_script() != VehicleTemplate:
		return
	_checked += 1
	var mesh: ArrayMesh = tpl.get(&"mesh") as ArrayMesh
	_check(mesh != null, "%s: template mesh loads" % key)
	if mesh == null:
		return
	var js: Dictionary = tpl.get(&"js_ref")
	var parts: Dictionary = tpl.get(&"parts")
	# main mesh + pivoted sub-meshes at every placement (detailed wheels, driver, cannon)
	var verts: int = _vertex_count(mesh)
	var tris: int = _tri_count(mesh)
	var box: AABB = mesh.get_aabb()
	var subs: Dictionary = tpl.get(&"sub_meshes")
	for node: String in subs:
		var e: Dictionary = subs[node]
		var sub: ArrayMesh = e.get("mesh") as ArrayMesh
		_check(sub != null, "%s: sub-mesh %s loads" % [key, node])
		if sub == null:
			continue
		var xfs: Array = e.get("transforms", [])
		_check(not xfs.is_empty(), "%s: sub-mesh %s has placements" % [key, node])
		verts += _vertex_count(sub)
		tris += _tri_count(sub) * xfs.size()
		for xf: Transform3D in xfs:
			box = box.merge(xf * sub.get_aabb())
		var sub_meta: Dictionary = sub.get_meta(&"bake", {})
		_check_mesh_data("%s.%s" % [key, node], sub, sub_meta.get("parts", {}) as Dictionary)
	_check_counts(key, verts, tris, box, js)
	_check_mesh_data(key, mesh, parts)

	# lamps the view drives (setBrake / setHeadlights / setBlinker / setHazard)
	var lamps_surface: int = Array(tpl.get(&"surface_names")).find("lamps")
	for p: String in LAMPS_REQUIRED:
		_check(parts.has(p), "%s: lamp part %s present" % [key, p])
		if parts.has(p):
			_check(int((parts[p] as Dictionary)["surface"]) == lamps_surface, "%s: %s lives in the lamps surface" % [key, p])
	var groups: Dictionary = tpl.get(&"lamp_groups")
	for g: String in ["brake", "head", "hazard", "blink_L", "blink_R"]:
		_check(groups.has(g), "%s: lamp group %s" % [key, g])
	_check((groups.get("hazard", PackedStringArray()) as PackedStringArray).size() >= 2, "%s: ≥ 2 hazard lamps" % key)
	# wheels: merged into a static body (NPC) or a spinning sub-mesh (detailed)
	var wheels: int = (tpl.get(&"merged_wheels") as Array).size()
	if subs.has("wheel"):
		wheels += ((subs["wheel"] as Dictionary).get("transforms", []) as Array).size()
	_check(wheels >= 4, "%s: ≥ 4 wheels (got %d)" % [key, wheels])
	for w: Dictionary in tpl.get(&"merged_wheels"):
		_check(parts.has(str(w.get("part", ""))) and float(w.get("radius", 0.0)) > 0.1,
			"%s: merged wheel %s has a part range and radius" % [key, str(w.get("part", ""))])

	# paint + dims vs the content export
	var npc: bool = bool(tpl.get(&"npc"))
	if npc:
		_check(bool(tpl.get(&"tintable")) != bool(tpl.get(&"livery")),
			"%s: NPC paint is runtime-tintable unless the kind forces a livery" % key)
		var fit: Dictionary = js.get("paint_fit", {})
		_check(int(fit.get("nonfit_vertices", -1)) == 0, "%s: paint fit has no non-fitting vertices" % key)
	var kind: String = str(tpl.get(&"kind"))
	var def: Dictionary = (_read_json(KINDS_PATH).get("kinds", {}) as Dictionary).get(kind, {})
	var dims_set: Array = ((def.get("dims", {}) as Dictionary).get(
		"detailed" if bool(tpl.get(&"detailed")) else "simple", []) as Array)
	var v: int = int(tpl.get(&"variant"))
	if v < dims_set.size():
		var d: Dictionary = dims_set[v]
		_check(absf(float(tpl.get(&"length")) - float(d.get("L", 0.0))) < DIMS_TOL
			and absf(float(tpl.get(&"width")) - float(d.get("W", 0.0))) < DIMS_TOL
			and absf(float(tpl.get(&"height")) - float(d.get("H", 0.0))) < DIMS_TOL,
			"%s: dims %.3f×%.3f×%.3f == vehicle_kinds.json %s" % [key, float(tpl.get(&"length")),
				float(tpl.get(&"width")), float(tpl.get(&"height")), str(d)])
	else:
		print("INFO test_meshes: %s: no vehicle_kinds.json dims for variant %d" % [key, v])


func _check_scenery(key: String, path: String) -> void:
	var mesh: ArrayMesh = load(path) as ArrayMesh
	_check(mesh != null, "%s loads as ArrayMesh" % key)
	if mesh == null:
		return
	_checked += 1
	var meta: Dictionary = mesh.get_meta(&"bake", {})
	_check(not meta.is_empty(), "%s: has bake metadata" % key)
	if meta.is_empty():
		return
	_check_counts(key, _vertex_count(mesh), _tri_count(mesh), mesh.get_aabb(), meta.get("js_ref", {}) as Dictionary)
	_check_mesh_data(key, mesh, meta.get("parts", {}) as Dictionary)


func _check_counts(key: String, verts: int, tris: int, box: AABB, js: Dictionary) -> void:
	_check(verts == int(js.get("welded_vertices", -1)),
		"%s: vertex count %d == bake %d" % [key, verts, int(js.get("welded_vertices", -1))])
	_check(tris == int(js.get("tris", -1)), "%s: triangles %d == JS %d" % [key, tris, int(js.get("tris", -1))])
	var ref: AABB = js.get("bbox", AABB())
	var d0: Vector3 = (box.position - ref.position).abs()
	var d1: Vector3 = (box.end - ref.end).abs()
	_check(maxf(d0[d0.max_axis_index()], d1[d1.max_axis_index()]) <= AABB_TOL,
		"%s: AABB %s ≈ JS %s (±%.0f cm)" % [key, str(box), str(ref), AABB_TOL * 100.0])


func _vertex_count(mesh: ArrayMesh) -> int:
	var n: int = 0
	for s: int in mesh.get_surface_count():
		n += mesh.surface_get_array_len(s)
	return n


func _tri_count(mesh: ArrayMesh) -> int:
	var n: int = 0
	for s: int in mesh.get_surface_count():
		n += mesh.surface_get_array_index_len(s) / 3
	return n


## Winding, part ranges / ids, AO range for every surface of one ArrayMesh.
func _check_mesh_data(key: String, mesh: ArrayMesh, parts: Dictionary) -> void:
	var by_surface: Dictionary = {}  # surface → Array of [name, range]
	for p: String in parts:
		var r: Dictionary = parts[p]
		var s: int = int(r.get("surface", -1))
		if not by_surface.has(s):
			by_surface[s] = []
		(by_surface[s] as Array).append([p, r])
	for s: int in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(s)
		var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var nrm: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var custom: PackedByteArray = arrays[Mesh.ARRAY_CUSTOM0] if arrays[Mesh.ARRAY_CUSTOM0] != null else PackedByteArray()
		var sname: String = mesh.surface_get_name(s)
		_check(custom.size() == pos.size() * 8, "%s/%s: custom0 is RGBA_HALF per vertex" % [key, sname])
		# CW front faces: the flat normal of the CCW source triangle opposes (b − a) × (c − a) after the flip
		var good: int = 0
		var total: int = 0
		for t: int in idx.size() / 3:
			var a: Vector3 = pos[idx[t * 3]]
			var c: Vector3 = (pos[idx[t * 3 + 1]] - a).cross(pos[idx[t * 3 + 2]] - a)
			if c.length_squared() < 1e-14:
				continue
			total += 1
			if c.dot(nrm[idx[t * 3]]) < 0.0:
				good += 1
		_check(total == 0 or float(good) / float(total) >= WINDING_MIN,
			"%s/%s: %d/%d triangles wound CW against their normal" % [key, sname, good, total])
		if custom.size() != pos.size() * 8:
			continue
		var ao_min: float = 1.0
		var ao_max: float = 0.0
		for i: int in pos.size():
			var ao: float = custom.decode_half(i * 8)
			ao_min = minf(ao_min, ao)
			ao_max = maxf(ao_max, ao)
		_check(ao_min >= 0.0 and ao_max <= 1.0, "%s/%s: AO in [0, 1] (%.3f..%.3f)" % [key, sname, ao_min, ao_max])
		for pr: Array in by_surface.get(s, []):
			var r: Dictionary = pr[1]
			var fv: int = int(r["first_vertex"])
			var nv: int = int(r["vertex_count"])
			var fi: int = int(r["first_index"])
			var ni: int = int(r["index_count"])
			var inside: bool = fv >= 0 and nv > 0 and fv + nv <= pos.size() and fi >= 0 and ni > 0 and fi + ni <= idx.size()
			_check(inside, "%s/%s: part %s range inside the surface" % [key, sname, str(pr[0])])
			if not inside:
				continue
			var id: int = int(r["id"])
			var wrong: int = 0
			for i: int in range(fv, fv + nv):
				if int(roundf(custom.decode_half(i * 8 + 2))) != id:
					wrong += 1
			var stray: int = 0
			for i: int in range(fi, fi + ni):
				if idx[i] < fv or idx[i] >= fv + nv:
					stray += 1
			_check(wrong == 0 and stray == 0, "%s/%s: part %s (id %d) vertices carry custom0.y = id (%d wrong, %d stray indices)"
				% [key, sname, str(pr[0]), id, wrong, stray])
