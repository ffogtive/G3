extends SceneTree
## Contact sheet of the baked meshes (Xvfb, Mobile renderer) + the layout JSON for the matching web render.
##   xvfb-run -a -s "-screen 0 1280x1024x24" godot47 --path native --rendering-method mobile --audio-driver Dummy \
##       -s res://tools/contact_sheet.gd -- --set=vehicles|props|big|road --out=/abs/sheet.png
##       [--layout=/abs/layout.json] [--shading=web|stock] [--lamps=off|on] [--ao=0..1] [--tint=1] [--frames=4]
##       [--compare=/abs/web.png] [--only=name,name]
##   then: node tools/bake-meshes.mjs --web-sheet=/abs/layout.json --png=/abs/web.png   (same cells, real web builders)
##
## --shading=web  : unshaded ShaderMaterial that evaluates Three r170 MeshLambert exactly — (hemi(n)·I + sun·I·max(n·l,0))/π
##                  with the stage-1 'day' preset (config.js SKY.day), no shadows/tonemap → pixel-comparable with the web.
##                  Lamp surfaces collapse by part id (custom0.y) unless lit; --ao mixes the baked AO channel in.
##                  This shader is also the reference implementation of the custom0 contract (lamps, tint, AO).
## --shading=stock: the .res default StandardMaterial3D surfaces under a DirectionalLight3D + shadows (out-of-box look).
## --compare      : per-pixel diff against a web PNG of the same layout → RESULT line + <out>_diff.png.

const VehicleTemplate := preload("res://assets/vehicles/vehicle_template.gd")
const DAY_HEMI_SKY: Color = Color8(0xbf, 0xe4, 0xff)
const DAY_HEMI_GROUND: Color = Color8(0x8a, 0x9a, 0x6a)
const DAY_HEMI_I: float = 1.25
const DAY_SUN: Color = Color8(0xff, 0xf4, 0xdc)
const DAY_SUN_I: float = 2.6
const DAY_SUN_POS: Vector3 = Vector3(-40, 80, 30)
const BACKGROUND: Color = Color8(0x6f, 0x73, 0x78)
## Lit lamps for --lamps=on: brake + head (setBrake, setHeadlights) and the left turn signal (setBlinker 'left').
const LAMPS_ON: PackedStringArray = ["brake_L", "brake_R", "brake_C", "head_L", "head_R", "head_C", "blink_FL", "blink_RL"]
const PART_IDS: Dictionary = {"brake_L": 1, "brake_R": 2, "brake_C": 3, "head_L": 4, "head_R": 5, "head_C": 6,
	"blink_FL": 13, "blink_RL": 15, "glow": 17}

const BODY_SHADER: String = """
shader_type spatial;
render_mode unshaded, cull_back;
uniform vec3 sun_dir;
uniform vec3 sun_col;
uniform vec3 hemi_sky;
uniform vec3 hemi_ground;
uniform float ao_strength = 0.0;
uniform vec3 emissive = vec3(0.0);
uniform bool lamp_surface = false;
uniform int lamp_mask = 0;          // bit i lights part id i (1..31); unlit parts collapse to a point (no draw)
uniform vec4 tint = vec4(0.0);      // rgb = sRGB paint, a > 0.5 → repaint vertices with custom0.z > 0
uniform vec4 flat_color = vec4(0.0); // a > 0 → ignore COLOR (glass/fx use the material colour), alpha = opacity
varying vec3 v_n;
varying vec4 v_c0;
vec3 srgb_to_linear(vec3 c) { return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c)); }
void vertex() {
	v_n = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_c0 = CUSTOM0;
	int id = int(CUSTOM0.y + 0.5);
	if (lamp_surface && id >= 1 && id < 32 && ((lamp_mask >> id) & 1) == 0) {
		VERTEX = vec3(0.0);
	}
}
void fragment() {
	vec3 srgb = flat_color.a > 0.0 ? flat_color.rgb : COLOR.rgb;
	float hao = 1.0;
	if (tint.a > 0.5 && v_c0.z > 0.0) {
		float k = v_c0.z;
		srgb = k < 1.0 ? tint.rgb * k : tint.rgb + (vec3(1.0) - tint.rgb) * (k - 1.0);
		hao = v_c0.w;
	}
	vec3 albedo = srgb_to_linear(srgb) * hao;
	if (lamp_surface) {
		ALBEDO = albedo;
	} else {
		vec3 n = normalize(v_n);
		vec3 hemi = mix(hemi_ground, hemi_sky, 0.5 * n.y + 0.5);
		vec3 lit = (hemi + sun_col * max(dot(n, sun_dir), 0.0)) / PI;
		ALBEDO = albedo * lit * mix(1.0, v_c0.x, ao_strength) + emissive;
	}
	// ALPHA_LINE (writing ALPHA at all makes Godot treat the material as transparent: only the glass variant does)
}
"""

var _set: String = "vehicles"
var _out: String = ""
var _layout_path: String = ""
var _shading: String = "web"
var _lamps_on: bool = false
var _ao: float = 0.0
var _tint: bool = false
var _frames: int = 4
var _compare: String = ""
var _only: PackedStringArray = PackedStringArray()
var _body_shader: Shader
var _items: Array[Dictionary] = []


func _initialize() -> void:
	for arg: String in OS.get_cmdline_user_args():
		var kv: PackedStringArray = arg.trim_prefix("--").split("=", true, 1)
		var v: String = kv[1] if kv.size() > 1 else ""
		match kv[0]:
			"set": _set = v
			"out": _out = v
			"layout": _layout_path = v
			"shading": _shading = v
			"lamps": _lamps_on = v == "on"
			"ao": _ao = v.to_float()
			"tint": _tint = v == "1"
			"frames": _frames = maxi(1, v.to_int())
			"compare": _compare = v
			"only": _only = v.split(",", false)
	_main.call_deferred()


func _main() -> void:
	if _out.is_empty() or DisplayServer.get_name() == "headless":
		print("FAIL contact_sheet: need --out=<png> and a display (xvfb-run, no --headless)")
		quit(2)
		return
	_body_shader = Shader.new()
	_body_shader.code = BODY_SHADER
	root.msaa_3d = Viewport.MSAA_DISABLED if _shading == "web" else Viewport.MSAA_4X
	var world := Node3D.new()
	root.add_child(world)
	_collect_items()
	if _items.is_empty():
		print("FAIL contact_sheet: no baked assets for set %s" % _set)
		quit(1)
		return
	var bounds: AABB = _layout()
	for it: Dictionary in _items:
		world.add_child(_instance(it))
	var cam: Dictionary = _camera(world, bounds)
	_environment(world)
	if not _layout_path.is_empty():
		_write_layout(cam)
	for i: int in _frames:
		await process_frame
	await RenderingServer.frame_post_draw
	var img: Image = root.get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(_out.get_base_dir())
	img.save_png(_out)
	print("RESULT sheet=%s set=%s items=%d shading=%s lamps=%s ao=%.2f draws=%d method=%s" % [_out, _set, _items.size(), _shading,
		"on" if _lamps_on else "off", _ao, int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		RenderingServer.get_current_rendering_method()])
	if not _compare.is_empty():
		_compare_with(img)
	quit(0)


func _collect_items() -> void:
	if _set == "scene":
		_collect_scene()
		return
	var dirs: Dictionary = {"vehicles": "res://assets/vehicles", "props": "res://assets/props", "big": "res://assets/props", "road": "res://assets/road"}
	var dir: String = str(dirs.get(_set, ""))
	var files: PackedStringArray = DirAccess.get_files_at(dir)
	files.sort()
	for f: String in files:
		if _set == "vehicles":
			if not f.ends_with(".tres"):
				continue
			var tpl: Resource = load(dir.path_join(f))
			if tpl == null or tpl.get_script() != VehicleTemplate:
				continue
			_items.append({"name": f.get_basename(), "tpl": tpl, "source": (tpl.get(&"js_ref") as Dictionary).get("source", {}),
				"size": Vector3(float(tpl.get(&"width")), float(tpl.get(&"height")), float(tpl.get(&"length"))),
				"group": str(tpl.get(&"kind")), "npc_weight": float(tpl.get(&"npc_weight"))})
		elif f.ends_with(".res") and f.count(".") == 1:
			var mesh: ArrayMesh = load(dir.path_join(f)) as ArrayMesh
			if mesh == null or not mesh.has_meta(&"bake"):
				continue
			var big: bool = f.begins_with("mountain") or f.begins_with("paddy") or f.begins_with("cloud")
			if (_set == "big") != big and _set != "road":
				continue
			var a: AABB = mesh.get_aabb()
			_items.append({"name": f.get_basename(), "mesh": mesh, "source": ((mesh.get_meta(&"bake") as Dictionary).get("js_ref", {}) as Dictionary).get("source", {}),
				"size": a.size, "center": a.get_center(), "group": f.get_basename().get_slice("_v", 0)})
	if not _only.is_empty():
		_items = _items.filter(func(it: Dictionary) -> bool:
			for o: String in _only:
				if str(it["name"]) == o:
					return true
			return false)
	if _set == "vehicles":  # NPC kinds by spawn weight (NPC_KINDS), then player/villain
		_items.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			if a["npc_weight"] != b["npc_weight"]:
				return a["npc_weight"] > b["npc_weight"]
			return a["name"] < b["name"])


## Stage-1-like chase view: 4 day road segments, NPCs packed in lanes 0..3, player in lane 3, villain ahead in lane 0,
## roadside trees and the CCTV gantry. Positions are fixed so the web render matches.
func _collect_scene() -> void:
	for k: int in range(-1, 4):  # segment k covers s ∈ [40k, 40k+40] (world.js: seed = k·31 + stage.id → variant)
		var v: int = posmod(k * 31 + 1, 4)
		var road: ArrayMesh = load("res://assets/road/segment_v%d.res" % v) as ArrayMesh
		if road != null:
			_items.append({"name": "segment_v%d" % v, "mesh": road, "source": _src(road), "pos": Vector3(0, 0, -40.0 * k), "size": road.get_aabb().size})
	var lanes: Array = [
		["villainSedan_v0", "bus_v0", "sedan_v1", "suv_v0", "compact_v0", "sedan_v0"],
		["truck_v0", "sedan_v2", "pickup1t_v0", "taxi_v0", "suv_v1", "compact_v1"],
		["sedan_v0", "van_v0", "pickup1t_v1", "sedan_v1", "truck_v1", "suv_v0"],
		["bus_v1", "compact_v0", "taxi_v1", "van_v1", "pickup1t_v2", "player_v0"],
	]
	for lane: int in 4:
		var s: float = 48.0
		for name: String in lanes[lane]:
			var tpl: Resource = load("res://assets/vehicles/%s.tres" % name)
			if tpl == null:
				continue
			var l: float = float(tpl.get(&"length"))
			s -= l / 2.0
			_items.append({"name": name, "tpl": tpl, "source": (tpl.get(&"js_ref") as Dictionary).get("source", {}),
				"pos": Vector3((lane - 1.5) * 3.6, 0, -s), "size": Vector3(float(tpl.get(&"width")), float(tpl.get(&"height")), l)})
			s -= l / 2.0 + 1.9
	for e: Array in [["tree_v0", 16.0, 6.0], ["pine_v3", 19.0, 18.0], ["tree_v5", 15.5, 31.0], ["bush_v1", 14.2, 12.0],
			["tree_v9", 17.5, 44.0], ["pine_v6", -30.0, 10.0], ["tree_v2", -33.0, 36.0], ["cctv", 0.0, 52.0], ["house_v2", 42.0, 30.0]]:
		var m: ArrayMesh = load("res://assets/props/%s.res" % e[0]) as ArrayMesh
		if m != null:
			_items.append({"name": e[0], "mesh": m, "source": _src(m), "pos": Vector3(float(e[1]), 0, -float(e[2])), "size": m.get_aabb().size})


func _src(m: ArrayMesh) -> Dictionary:
	return ((m.get_meta(&"bake", {}) as Dictionary).get("js_ref", {}) as Dictionary).get("source", {})


## Places items on a grid (row-major; each group starts a new column for vehicles, rows of ~sqrt(n) otherwise).
func _layout() -> AABB:
	if _set == "scene":
		return AABB(Vector3(-12, 0, -80), Vector3(24, 4, 80))
	var gap: float = 1.2 if _set == "vehicles" else (6.0 if _set == "big" else 1.5)
	var cols: Array = []  # vehicles: one column per kind, variants stacked along z
	if _set == "vehicles":
		var by_group: Dictionary = {}
		for it: Dictionary in _items:
			if not by_group.has(it["group"]):
				by_group[it["group"]] = []
				cols.append(by_group[it["group"]])
			(by_group[it["group"]] as Array).append(it)
	elif _set == "road":
		cols = [[], []]
		for it: Dictionary in _items:
			(cols[1 if str(it["name"]).contains("_sb_") else 0] as Array).append(it)
	else:
		var n: int = ceili(sqrt(float(_items.size())))
		for i: int in _items.size():
			if i % n == 0:
				cols.append([])
			(cols[cols.size() - 1] as Array).append(_items[i])
	var x: float = 0.0
	var bounds := AABB()
	var first: bool = true
	for col: Array in cols:
		var w: float = 0.0
		for it: Dictionary in col:
			w = maxf(w, (it["size"] as Vector3).x)
		var z: float = 0.0
		for it: Dictionary in col:
			var s: Vector3 = it["size"]
			var c: Vector3 = it.get("center", Vector3(0, s.y / 2, 0))
			var depth: float = 40.0 if _set == "road" else s.z
			# vehicles face −Z; first variant nearest the camera (largest z)
			var pos := Vector3(x + w / 2 - c.x, 0.0, -(z + depth / 2) - (c.z if _set != "vehicles" else 0.0))
			if _set == "road":
				pos = Vector3(x, 0.0, -z)
			it["pos"] = pos
			var box := AABB(pos + c - s / 2, s)
			if _set == "vehicles":
				box = AABB(pos - Vector3(s.x / 2, 0, s.z / 2), s)
			bounds = box if first else bounds.merge(box)
			first = false
			z += depth + (0.0 if _set == "road" else gap)
		x += w + gap if _set != "road" else 140.0
	return bounds


func _instance(it: Dictionary) -> Node3D:
	var holder := Node3D.new()
	holder.name = str(it["name"])
	holder.position = it["pos"]
	if it.has("tpl"):
		var tpl: Resource = it["tpl"]
		var mi := MeshInstance3D.new()
		mi.mesh = tpl.get(&"mesh")
		_apply_materials(mi, it)
		holder.add_child(mi)
		var subs: Dictionary = tpl.get(&"sub_meshes")
		for node_name: String in subs:
			var e: Dictionary = subs[node_name]
			for xf: Transform3D in e["transforms"]:
				var smi := MeshInstance3D.new()
				smi.mesh = e["mesh"]
				smi.transform = xf
				_apply_materials(smi, it)
				holder.add_child(smi)
	else:
		var mi := MeshInstance3D.new()
		mi.mesh = it["mesh"]
		_apply_materials(mi, it)
		holder.add_child(mi)
	return holder


func _apply_materials(mi: MeshInstance3D, it: Dictionary) -> void:
	if _shading != "web":
		return
	var mesh: ArrayMesh = mi.mesh as ArrayMesh
	var vehicle: bool = it.has("tpl")
	for s: int in mesh.get_surface_count():
		var sname: String = mesh.surface_get_name(s)
		var base: StandardMaterial3D = mesh.surface_get_material(s) as StandardMaterial3D
		var lamp: bool = sname == "lamps" or sname == "fx"
		var transparent: bool = not lamp and base != null and base.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED
		var m := ShaderMaterial.new()
		m.shader = _transparent_shader() if transparent else _body_shader
		if transparent:
			m.render_priority = 1
		m.set_shader_parameter(&"sun_dir", DAY_SUN_POS.normalized())
		m.set_shader_parameter(&"sun_col", _lin(DAY_SUN) * DAY_SUN_I)
		m.set_shader_parameter(&"hemi_sky", _lin(DAY_HEMI_SKY) * DAY_HEMI_I)
		m.set_shader_parameter(&"hemi_ground", _lin(DAY_HEMI_GROUND) * DAY_HEMI_I)
		m.set_shader_parameter(&"ao_strength", _ao)
		if base != null and base.emission_enabled:
			m.set_shader_parameter(&"emissive", _lin(base.emission) * base.emission_energy_multiplier)
		if base != null and not base.vertex_color_use_as_albedo:
			var c: Color = base.albedo_color
			m.set_shader_parameter(&"flat_color", Vector4(c.r, c.g, c.b, c.a))
		if lamp:
			var mask: int = 0
			if not vehicle:
				mask = 0x7ffffffe  # scenery unlit parts (glow) are always on
			else:
				mask = 1 << int(PART_IDS["glow"])
				if _lamps_on:
					for p: String in LAMPS_ON:
						mask |= 1 << int(PART_IDS[p])
			m.set_shader_parameter(&"lamp_surface", true)
			m.set_shader_parameter(&"lamp_mask", mask)
		if _tint and vehicle and bool((it["tpl"] as Resource).get(&"tintable")):
			var paint: Color = Color8(0x2f, 0x6f, 0xd6)  # NPC_COLORS_POP[0]
			m.set_shader_parameter(&"tint", Vector4(paint.r, paint.g, paint.b, 1.0))
		mi.set_surface_override_material(s, m)


var _transparent: Shader


func _transparent_shader() -> Shader:
	if _transparent == null:
		_transparent = Shader.new()
		_transparent.code = BODY_SHADER.replace("render_mode unshaded, cull_back;", "render_mode unshaded, cull_back, blend_mix, depth_draw_opaque;") \
			.replace("// ALPHA_LINE", "ALPHA = flat_color.a; //")
	return _transparent


func _lin(c: Color) -> Vector3:
	var l: Color = c.srgb_to_linear()
	return Vector3(l.r, l.g, l.b)


func _camera(world: Node3D, b: AABB) -> Dictionary:
	var cam := Camera3D.new()
	world.add_child(cam)
	cam.current = true
	if _set == "scene":  # game chase cam (vehicles.js header: ≈16 m up, 18 m behind), player in lane 3 at s≈6
		cam.fov = 55.0
		cam.near = 0.5
		cam.far = 400.0
		cam.look_at_from_position(Vector3(4.2, 13.5, 13.0), Vector3(0.5, 0.0, -24.0), Vector3.UP)
		return {"pos": cam.position, "target": Vector3(0.5, 0.0, -24.0), "fov": cam.fov, "near": cam.near, "far": cam.far}
	cam.fov = 20.0 if _set != "road" else 30.0
	var target: Vector3 = b.get_center()
	var dir: Vector3 = Vector3(0.55, 0.9, 1.0).normalized() if _set != "road" else Vector3(0.25, 1.1, 1.0).normalized()
	var r: float = b.size.length() * 0.5
	var dist: float = r / sin(deg_to_rad(cam.fov) * 0.5)
	var vs := Vector2(root.size)
	for i: int in 6:  # fit the projected bounds to 92 % of the viewport, centred
		cam.look_at_from_position(target + dir * dist, target, Vector3.UP)
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for k: int in 8:
			var p: Vector2 = cam.unproject_position(b.get_endpoint(k))
			lo = lo.min(p)
			hi = hi.max(p)
		var world_per_px: float = 2.0 * dist * tan(deg_to_rad(cam.fov) * 0.5) / vs.y
		var off: Vector2 = (lo + hi) * 0.5 - vs * 0.5
		target += cam.global_transform.basis.x * off.x * world_per_px - cam.global_transform.basis.y * off.y * world_per_px
		dist *= maxf((hi.x - lo.x) / (vs.x * 0.92), (hi.y - lo.y) / (vs.y * 0.92))
	cam.look_at_from_position(target + dir * dist, target, Vector3.UP)
	cam.near = maxf(0.1, dist - r * 2.0)
	cam.far = dist + r * 2.0
	return {"pos": cam.position, "target": target, "fov": cam.fov, "near": cam.near, "far": cam.far}


func _environment(world: Node3D) -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = BACKGROUND
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	if _shading == "web":
		env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	else:
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = DAY_HEMI_SKY.lerp(DAY_HEMI_GROUND, 0.35)
		env.ambient_light_energy = DAY_HEMI_I / PI
		var sun := DirectionalLight3D.new()
		sun.light_color = DAY_SUN
		sun.light_energy = DAY_SUN_I / PI
		sun.shadow_enabled = true
		sun.directional_shadow_max_distance = 200.0
		world.add_child(sun)
		sun.look_at_from_position(DAY_SUN_POS.normalized() * 10.0, Vector3.ZERO, Vector3.UP)
	var we := WorldEnvironment.new()
	we.environment = env
	world.add_child(we)


func _write_layout(cam: Dictionary) -> void:
	var items: Array = []
	for it: Dictionary in _items:
		var p: Vector3 = it["pos"]
		var e: Dictionary = {"name": it["name"], "source": it["source"], "pos": [p.x, p.y, p.z]}
		if it.has("tpl") and _lamps_on:
			e["lamps"] = {"brake": true, "head": true, "blink": "left"}
		items.append(e)
	var cp: Vector3 = cam["pos"]
	var ct: Vector3 = cam["target"]
	var sun: Vector3 = DAY_SUN_POS.normalized()
	var layout: Dictionary = {
		"viewport": [root.size.x, root.size.y], "background": BACKGROUND.to_html(false).insert(0, "#"),
		"camera": {"pos": [cp.x, cp.y, cp.z], "target": [ct.x, ct.y, ct.z], "fov": cam["fov"], "near": cam["near"], "far": cam["far"]},
		"light": {"hemi_sky": "#" + DAY_HEMI_SKY.to_html(false), "hemi_ground": "#" + DAY_HEMI_GROUND.to_html(false), "hemi_intensity": DAY_HEMI_I,
			"sun_color": "#" + DAY_SUN.to_html(false), "sun_intensity": DAY_SUN_I, "sun_dir": [sun.x, sun.y, sun.z]},
		"items": items,
	}
	var f: FileAccess = FileAccess.open(_layout_path, FileAccess.WRITE)
	f.store_string(JSON.stringify(layout, " "))
	f.close()


func _compare_with(img: Image) -> void:
	var web: Image = Image.load_from_file(_compare)
	if web == null or web.get_size() != img.get_size():
		print("FAIL compare: %s missing or size differs" % _compare)
		return
	img.convert(Image.FORMAT_RGB8)
	web.convert(Image.FORMAT_RGB8)
	var w: int = img.get_width()
	var h: int = img.get_height()
	var diff := Image.create(w, h, false, Image.FORMAT_RGB8)
	var bg: Color = BACKGROUND
	var sum: float = 0.0
	var n_fg: int = 0
	var over16: int = 0
	var over48: int = 0
	for y: int in h:
		for x: int in w:
			var a: Color = img.get_pixel(x, y)
			var b: Color = web.get_pixel(x, y)
			var is_bg: bool = _near(a, bg) and _near(b, bg)
			var d: float = maxf(absf(a.r - b.r), maxf(absf(a.g - b.g), absf(a.b - b.b))) * 255.0
			diff.set_pixel(x, y, Color(minf(1.0, d / 64.0), minf(1.0, d / 64.0), minf(1.0, d / 64.0)))
			if is_bg:
				continue
			n_fg += 1
			sum += d
			if d > 16.0:
				over16 += 1
			if d > 48.0:
				over48 += 1
	var diff_path: String = _out.get_basename() + "_diff.png"
	diff.save_png(diff_path)
	print("RESULT compare=%s fg_px=%d mean_maxch_diff=%.2f over16=%.2f%% over48=%.2f%% diff=%s" % [_compare, n_fg,
		sum / maxf(1.0, n_fg), 100.0 * over16 / maxf(1.0, n_fg), 100.0 * over48 / maxf(1.0, n_fg), diff_path])


func _near(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b) < 3.0 / 255.0
