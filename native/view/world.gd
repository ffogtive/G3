class_name WorldView
extends Node3D
## Stage world (port of game/js/world.js for the day preset, NATIVE_PORT 2 / M1a):
##  - lighting = the web's conditions: Lambert, HemisphereLight → 2-colour ambient sky (or the exact hemi term in the
##    voxel shaders, debug "ambient mode"), DirectionalLight energy = Three intensity / π, Linear tonemap (exposure 1)
##  - better than the web: PSSM 2-split soft sun shadows (max 80 m), HDR lamps + glow, MSAA 4x, debanding, depth fog
##  - geometry: baked road segments + text-free props, placed with the web's own mulberry32(id·7919+13) loop (res://core/mulberry32.gd) so the
##    layout matches world.js prop for prop, then merged into one mesh per 120 m chunk and caster class (draw calls
##    stay flat however many trees there are).

const SEG_LEN: float = 40.0
const ROAD_RIGHT: float = 7.2
const SHOULDER_W: float = 3.0
const OPP_ROAD_LEFT: float = -23.7
const CHUNK_LEN: float = 120.0
const ROAD_VARIANTS: int = 4
const PROP_VARIANTS: Dictionary = {"tree": 12, "pine": 8, "bush": 6, "paddy": 9, "house": 8, "church": 4, "mountain": 10,
	"cloud": 8, "cctv": 1}
const NO_SHADOW: PackedStringArray = ["paddy", "mountain", "cloud"]
const SKY_SHADER: Shader = preload("res://shaders/sky.gdshader")
const GROUND_SHADER: Shader = preload("res://shaders/ground.gdshader")

enum Ambient { SKY = 0, SHADER_HEMI = 1, FLAT = 2 }

var factory: VehicleFactory
var road: RoadGraph
var preset: Dictionary = {}
var env: Environment
var world_env: WorldEnvironment
var sun: DirectionalLight3D
var sky_mat: ShaderMaterial
var ground_mat: ShaderMaterial
var ambient_mode: int = Ambient.SKY
var stats: Dictionary = {}
var _hemi_sky_lin := Vector3.ZERO
var _hemi_ground_lin := Vector3.ZERO
var _sun_dir := Vector3(-0.4, 0.8, 0.3).normalized()
var _instances: Array[Dictionary] = []      # {mesh: ArrayMesh, xf: Transform3D, cast: bool, chunk: int}
## Overhead gantries (separate instances, not merged): {node: MeshInstance3D, s: float}; faded like world.js update().
var overheads: Array[Dictionary] = []
var _mesh_cache: Dictionary = {}


## marks: {startS, frontS}; obstacles: TrafficBridge/TrafficStub obstacles() list ({kind, s, x, len, detail}).
func build(stage: Dictionary, p_factory: VehicleFactory, p_road: RoadGraph, marks: Dictionary, obstacles: Array) -> void:
	factory = p_factory
	road = p_road
	var t0: int = Time.get_ticks_usec()
	_apply_sky(str(stage.get("sky", "day")))
	var start_s: float = float(marks.get("startS", 0.0))
	var front_s: float = float(marks.get("frontS", 200.0))
	_ground(start_s - 160.0, front_s + 950.0)
	_layout(stage, start_s - 160.0, front_s + 950.0, start_s, front_s)
	_obstacle_props(obstacles)
	_merge_chunks()
	stats["build_ms"] = float(Time.get_ticks_usec() - t0) / 1000.0


# ───────────────────────────── lighting / environment

func _apply_sky(sky_name: String) -> void:
	preset = ViewData.sky(sky_name)
	var hemi_i: float = float(preset.get("hemiI", 1.25))
	_hemi_sky_lin = _lin(ViewData.hex(preset.get("hemiSky", 0xbfe4ff))) * (hemi_i / PI)
	_hemi_ground_lin = _lin(ViewData.hex(preset.get("hemiGround", 0x8a9a6a))) * (hemi_i / PI)
	var sp: Array = preset.get("sunPos", [-40, 80, 30])
	_sun_dir = Vector3(float(sp[0]), float(sp[1]), float(sp[2])).normalized()

	sky_mat = ShaderMaterial.new()
	sky_mat.shader = SKY_SHADER
	sky_mat.set_shader_parameter(&"top_color", ViewData.hex(preset.get("top", 0x5fb8ff)))
	sky_mat.set_shader_parameter(&"bottom_color", ViewData.hex(preset.get("bottom", 0xd8f0ff)))
	sky_mat.set_shader_parameter(&"hemi_sky_rad", _hemi_sky_lin)
	sky_mat.set_shader_parameter(&"hemi_ground_rad", _hemi_ground_lin)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_32
	sky.process_mode = Sky.PROCESS_MODE_QUALITY

	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.tonemap_exposure = 1.0
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	# depth fog = Three linear Fog(color, near, far)
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = ViewData.hex(preset.get("fog", 0xcfeaff))
	env.fog_light_energy = 1.0
	env.fog_density = 1.0
	env.fog_depth_begin = float(preset.get("fogNear", 120.0))
	env.fog_depth_end = float(preset.get("fogFar", 420.0))
	env.fog_depth_curve = 1.0
	env.fog_sky_affect = 0.0
	env.fog_sun_scatter = 0.0
	env.fog_aerial_perspective = 0.0
	# glow: only HDR lamps (> 1.0) bloom — the 'red sea' of brake lights
	env.glow_enabled = true
	env.glow_hdr_threshold = 1.0
	env.glow_hdr_scale = 2.0
	env.glow_intensity = 0.8
	env.glow_strength = 1.0
	env.glow_bloom = 0.0
	# The purple rear windows (art review: R +31..+42) were glow spill from the lamps right below them: with glow off
	# they match the web to ±3. A/B (pinned web frame, 2026-10-13): levels 2+ spill into the glass whatever the blend
	# mode (ADDITIVE and SCREEN measured the same); level 1 only keeps a tight halo with the windows at web ±3
	# (a 0.1 trace of level 2 already gave +9). Lamp cores already sit at the Mobile HDR ceiling (~2.0, voxel.gdshader), so no hotter core.
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	var levels: PackedFloat32Array = [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
	for i: int in 7:
		env.set_glow_level(i, levels[i])
	world_env = WorldEnvironment.new()
	world_env.name = "Env"
	world_env.environment = env
	add_child(world_env)
	set_ambient_mode(ambient_mode)

	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_color = ViewData.hex(preset.get("sun", 0xfff4dc))
	sun.light_energy = float(preset.get("sunI", 2.6)) / PI
	sun.light_specular = 0.0
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = 80.0
	sun.directional_shadow_split_1 = 0.3
	sun.directional_shadow_blend_splits = true
	sun.directional_shadow_fade_start = 0.85
	sun.shadow_bias = 0.1          # 0.04 / 1.2 gave acne on flat roofs (A/B shots, 2026-10-13)
	sun.shadow_normal_bias = 2.0
	sun.shadow_blur = 0.6           # with SOFT_MEDIUM: clean penumbra (SOFT_LOW + 1.0 left dither grain, art review)
	add_child(sun)
	sun.basis = Basis.looking_at(-_sun_dir, Vector3.UP if absf(_sun_dir.y) < 0.99 else Vector3.FORWARD)
	RenderingServer.directional_shadow_atlas_set_size(2048, true)
	# == rendering/lights_and_shadows/directional_shadow/soft_shadow_filter_quality(.mobile)=3 in project.godot.
	# Device fallback if A15 GPU time is short: SOFT_LOW with shadow_blur 0.5 (docs/NATIVE_PORT.md 9).
	RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM)

	factory.set_param(&"hemi_sky", _hemi_sky_lin)
	factory.set_param(&"hemi_ground", _hemi_ground_lin)


## Ambient A/B (debug panel): SKY = 2-colour radiance sky, SHADER_HEMI = exact Three hemi term in the shaders
## (environment ambient off), FLAT = one colour (hemi average) as a baseline.
func set_ambient_mode(mode: int) -> void:
	ambient_mode = mode
	if env == null:
		return
	var in_shader: bool = mode == Ambient.SHADER_HEMI
	match mode:
		Ambient.SKY:
			env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
			env.ambient_light_sky_contribution = 1.0
			env.ambient_light_energy = 1.0
		Ambient.SHADER_HEMI:
			env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
			env.ambient_light_color = Color.BLACK
			env.ambient_light_energy = 0.0
		_:
			var avg: Vector3 = (_hemi_sky_lin + _hemi_ground_lin) * 0.5
			env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
			env.ambient_light_color = Color(avg.x, avg.y, avg.z).linear_to_srgb()
			env.ambient_light_energy = 1.0
	if factory != null:
		factory.set_param(&"hemi_in_shader", in_shader)
	if ground_mat != null:
		ground_mat.set_shader_parameter(&"hemi_in_shader", in_shader)


func _lin(c: Color) -> Vector3:
	var l: Color = c.srgb_to_linear()
	return Vector3(l.r, l.g, l.b)


## Sun and its shadow follow the focus (web world.update: sun at focus + sunDir·120). For a directional light only
## the direction matters; PSSM splits follow the camera.
func update_focus(_focus: Vector3) -> void:
	pass


# ───────────────────────────── ground (scenery.js makeGround)

func _ground(s_min: float, s_max: float) -> void:
	var img := Image.create(256, 256, false, Image.FORMAT_RGBA8)
	img.fill(Color.html("#7fbd53"))
	var r := Mulberry32.new(77 ^ 0x2545f491)  # scenery.js rng(seed): mulberry32(seed ^ 0x2545f491)
	var fields: PackedStringArray = ["#82c057", "#78b64e", "#88c75d", "#74b14c", "#8ac862", "#7cbc5f", "#93c762"]
	for i: int in 26:
		var col := Color.html(fields[int(r.next_float() * fields.size())])
		var w: float = 30.0 + r.next_float() * 70.0
		var h: float = 30.0 + r.next_float() * 70.0
		var x: float = r.next_float() * 256.0
		var y: float = r.next_float() * 256.0
		img.fill_rect(Rect2i(Vector2i(roundi(x), roundi(y)), Vector2i(roundi(w), roundi(h))).intersection(Rect2i(0, 0, 256, 256)), col)
	var dot := Color.html("#4f8a35")
	for i: int in 400:
		var x: int = int(r.next_float() * 256.0)
		var y: int = int(r.next_float() * 256.0)
		for dy: int in 2:
			for dx: int in 2:
				var px: int = mini(255, x + dx)
				var py: int = mini(255, y + dy)
				img.set_pixel(px, py, img.get_pixel(px, py).lerp(dot, 0.18))
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	ground_mat = ShaderMaterial.new()
	ground_mat.shader = GROUND_SHADER
	ground_mat.set_shader_parameter(&"field_tex", tex)
	ground_mat.set_shader_parameter(&"tiles", 3000.0 / 160.0)
	var pm := PlaneMesh.new()
	pm.size = Vector2(3000, 3000)
	pm.material = ground_mat
	var g := MeshInstance3D.new()
	g.name = "Ground"
	g.mesh = pm
	g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	g.position = Vector3(0, -0.06, -(s_min + s_max) * 0.5)
	add_child(g)


# ───────────────────────────── layout (world.js build, day)

func _layout(stage: Dictionary, s_min: float, s_max: float, start_s: float, front_s: float) -> void:
	var id: int = int(stage.get("id", 1))
	var rng := Mulberry32.new(Mulberry32.world_seed(id))
	var k0: int = floori(s_min / SEG_LEN)
	var k1: int = ceili(s_max / SEG_LEN)
	var barrier_from: int = k0 + 1 + int(rng.next_float() * 3.0)
	var barrier_len: int = 3 + int(rng.next_float() * 3.0)
	var edge_r: float = ROAD_RIGHT + SHOULDER_W + 4.0
	var edge_l: float = OPP_ROAD_LEFT - 4.0
	for k: int in range(k0, k1):
		var s0: float = float(k) * SEG_LEN
		var sb: bool = k >= barrier_from and k < barrier_from + barrier_len
		var seed: int = k * 31 + id
		var variant: int = ((seed % ROAD_VARIANTS) + ROAD_VARIANTS) % ROAD_VARIANTS
		_add("res://assets/road/segment_v%d%s.res" % [variant, "_sb_right" if sb else ""], 0.0, s0, 0.0, false, "road")
		if not sb:
			var n_tree: int = 1 + int(rng.next_float() * 3.0)
			for i: int in n_tree:
				var kind: String = "tree" if rng.next_float() < 0.5 else "pine"
				var ps: int = int(rng.next_float() * 1e5)
				var x: float = edge_r + rng.next_float() * 14.0
				var s: float = s0 + rng.next_float() * SEG_LEN
				_prop(kind, ps, x, s, rng.next_float() * 6.0)
			if rng.next_float() < 0.6:
				var ps: int = int(rng.next_float() * 1e5)
				var x: float = edge_r - 1.0 + rng.next_float() * 3.0
				_prop("bush", ps, x, s0 + rng.next_float() * SEG_LEN, 0.0)
		if rng.next_float() < 0.45:
			var ps: int = int(rng.next_float() * 1e5)
			var x: float = edge_r + 22.0 + rng.next_float() * 25.0
			_prop("paddy", ps, x, s0 + rng.next_float() * SEG_LEN, 0.0)
		if rng.next_float() < 0.18:
			var ps: int = int(rng.next_float() * 1e5)
			var x: float = edge_r + 30.0 + rng.next_float() * 30.0
			var s: float = s0 + rng.next_float() * SEG_LEN
			_prop("house", ps, x, s, rng.next_float() * 6.0)
		if k % 9 == 4:
			var ps: int = int(rng.next_float() * 1e5)
			var x: float = edge_r + 55.0 + rng.next_float() * 20.0
			_prop("church", ps, x, s0 + rng.next_float() * SEG_LEN, 0.0)
		if k % 3 == 0:
			var n: int = 2 + int(rng.next_float() * 2.0)
			for i: int in n:  # apartments carry '○동' text (M1c text panels): consume the RNG, draw nothing yet
				for _j: int in 4:
					rng.next_float()
		if k % 4 == 1:
			var ps: int = int(rng.next_float() * 1e5)
			var x: float = edge_r + 170.0 + rng.next_float() * 80.0
			var s: float = s0 + rng.next_float() * SEG_LEN
			_prop("mountain", ps, x, s, rng.next_float() * 6.0)
		var n_tree_l: int = 1 + int(rng.next_float() * 2.0)
		for i: int in n_tree_l:
			var kind: String = "pine" if rng.next_float() < 0.6 else "tree"
			var ps: int = int(rng.next_float() * 1e5)
			var x: float = edge_l - rng.next_float() * 16.0
			var s: float = s0 + rng.next_float() * SEG_LEN
			_prop(kind, ps, x, s, rng.next_float() * 6.0)
		if k % 4 == 2:
			for _j: int in 3:  # apartment (text): seed, x, s
				rng.next_float()
		if k % 3 == 1:
			var ps: int = int(rng.next_float() * 1e5)
			var x: float = edge_l - 150.0 - rng.next_float() * 100.0
			var s: float = s0 + rng.next_float() * SEG_LEN
			_prop("mountain", ps, x, s, rng.next_float() * 6.0)
	for i: int in 14:
		var x: float = -150.0 + rng.next_float() * 300.0
		var s: float = s_min + rng.next_float() * (s_max - s_min + 300.0)
		var y: float = 55.0 + rng.next_float() * 40.0
		_prop("cloud", i * 17 + id, x, s, 0.0, y)
	# world.js:187-193: two overhead gantry signs + three VMS. Frames and blank plates now (they anchor the
	# composition and cast the shadow band across the lanes); the plate text is M1c (SubViewport + Label → texture).
	_overhead("res://assets/props/gantry_sign_2l.res", 0.0, start_s + 46.0)
	_overhead("res://assets/props/gantry_sign_2l.res", 0.0, front_s + 150.0)
	for vs: float in [start_s + 105.0, front_s + 25.0, front_s + 260.0]:
		_add("res://assets/props/vms.res", 0.0, vs, 0.0, true, "vms")
	_prop("cctv", 0, 0.0, start_s + (front_s - start_s) * 0.55, 0.0)


func _prop(kind: String, seed: int, x: float, s: float, rot_y: float, y: float = 0.0) -> void:
	var nv: int = int(PROP_VARIANTS.get(kind, 1))
	var v: int = ((seed % nv) + nv) % nv
	var path: String = "res://assets/props/%s.res" % kind if nv == 1 else "res://assets/props/%s_v%d.res" % [kind, v]
	_add(path, x, s, rot_y, kind not in NO_SHADOW, kind, y)


func _add(path: String, x: float, s: float, rot_y: float, cast: bool, kind: String, y: float = 0.0) -> void:
	if not _mesh_cache.has(path):
		_mesh_cache[path] = load(path) if ResourceLoader.exists(path) else null
	var mesh: ArrayMesh = _mesh_cache[path]
	if mesh == null:
		push_warning("WorldView: missing %s" % path)
		return
	var xf: Transform3D = road.world(s, x, rot_y)
	xf.origin.y = y
	_instances.append({"mesh": mesh, "xf": xf, "cast": cast, "kind": kind, "chunk": floori(s / CHUNK_LEN)})
	stats[kind] = int(stats.get(kind, 0)) + 1


## An overhead sign as its own MeshInstance3D so it can fade when it sits between the chase camera and the player.
func _overhead(path: String, x: float, s: float) -> void:
	if not _mesh_cache.has(path):
		_mesh_cache[path] = load(path) if ResourceLoader.exists(path) else null
	var mesh: ArrayMesh = _mesh_cache[path]
	if mesh == null:
		push_warning("WorldView: missing %s" % path)
		return
	var mi := MeshInstance3D.new()
	mi.name = "Overhead_%d" % overheads.size()
	mi.mesh = mesh
	for i: int in mesh.get_surface_count():
		var sname: String = mesh.surface_get_name(i)
		if sname == "panel":
			mi.set_surface_override_material(i, _blank_sign_material())
		elif sname != "glass" and sname != "fx":
			mi.set_surface_override_material(i, factory.mat_static)
	mi.transform = road.world(s, x, 0.0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(mi)
	# GeometryInstance3D.transparency is Forward+ only (ignored on Mobile), so fading swaps in alpha materials:
	# the frame as vertex-colour StandardMaterial3D (COLOR is sRGB8), the plate as the sign green, both with alpha f.
	var frame_fade := StandardMaterial3D.new()
	frame_fade.vertex_color_use_as_albedo = true
	frame_fade.vertex_color_is_srgb = true
	frame_fade.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var plate_fade: StandardMaterial3D = _blank_sign_material().duplicate() as StandardMaterial3D
	plate_fade.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	overheads.append({"node": mi, "s": s, "f": 1.0, "frame_fade": frame_fade, "plate_fade": plate_fade})
	stats["gantry"] = int(stats.get("gantry", 0)) + 1


var _blank_sign: StandardMaterial3D


## Until the M1c text panel: the web sign's board colour (scenery.js signMaterial #0b7a4b, white rim drawn later).
func _blank_sign_material() -> StandardMaterial3D:
	if _blank_sign == null:
		_blank_sign = StandardMaterial3D.new()
		_blank_sign.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_blank_sign.albedo_color = Color.html("#0b7a4b")
	return _blank_sign


## world.js update(): an overhead structure 12–30 m ahead of a raised camera fades to 0.22 opacity (it would cover
## the player in the chase view), 1.0 elsewhere.
func update_overheads(cam_pos: Vector3) -> void:
	if overheads.is_empty():
		return
	var cs: float = road.to_road(cam_pos).x
	for o: Dictionary in overheads:
		var d: float = float(o["s"]) - cs
		var f: float = 1.0
		if cam_pos.y > 5.0 and d > -2.0 and d < 30.0:
			f = 0.22 + 0.78 * clampf((d - 12.0) / 18.0, 0.0, 1.0)
		if absf(float(o["f"]) - f) <= 0.01:
			continue
		o["f"] = f
		var mi: MeshInstance3D = o["node"]
		var ff: StandardMaterial3D = o["frame_fade"]
		var pf: StandardMaterial3D = o["plate_fade"]
		ff.albedo_color.a = f
		pf.albedo_color.a = f
		var opaque: bool = f > 0.995
		for i: int in mi.mesh.get_surface_count():
			var sname: String = mi.mesh.surface_get_name(i)
			if sname == "panel":
				mi.set_surface_override_material(i, _blank_sign_material() if opaque else pf)
			elif sname != "glass" and sname != "fx":
				mi.set_surface_override_material(i, factory.mat_static if opaque else ff)


func _obstacle_props(obstacles: Array) -> void:
	for o: Variant in obstacles:
		if not (o is Dictionary):
			continue
		var d: Dictionary = o
		var s: float = float(d.get("s", 0.0))
		var x: float = float(d.get("x", 9.0 - 0.1))
		match str(d.get("kind", "")):
			"cones":  # shoulder.js: 6 cones in a diagonal taper, local (−0.9 + 1.8 i/5, −5 + 2 i)
				for i: int in 6:
					_add("res://assets/props/cone.res", x - 0.9 + float(i) / 5.0 * 1.8, s + 5.0 - 2.0 * float(i), 0.0, true, "cone")
			"breakdown":
				var det: Dictionary = d.get("detail", {}) if d.get("detail") is Dictionary else {}
				if bool(det.get("triangle", true)):
					var car_len: float = float(det.get("carLen", 4.6))
					_add("res://assets/props/warning_triangle.res", x, s - (car_len * 0.5 + 1.5 - 2.4), 0.0, true, "triangle")


# ───────────────────────────── static batching

## One ArrayMesh per (chunk, shadow class): positions/normals transformed on the CPU (native Transform3D ×
## PackedVector3Array), colours + CUSTOM0 (RGBA half) copied, indices offset. Panel surfaces (UV'd text quads,
## sound-barrier glass) stay separate MeshInstance3Ds with their stock materials.
func _merge_chunks() -> void:
	var groups: Dictionary = {}
	for it: Dictionary in _instances:
		var key: String = "%d|%s" % [int(it["chunk"]), "road" if it["kind"] == "road" else ("cast" if it["cast"] else "flat")]
		if not groups.has(key):
			groups[key] = []
		(groups[key] as Array).append(it)
	var keys: Array = groups.keys()
	keys.sort()
	var n_meshes: int = 0
	var n_panels: int = 0
	var verts: int = 0
	for key: String in keys:
		var items: Array = groups[key]
		var pos := PackedVector3Array()
		var nrm := PackedVector3Array()
		var col := PackedColorArray()
		var c0 := PackedByteArray()
		var idx := PackedInt32Array()
		for it: Dictionary in items:
			var mesh: ArrayMesh = it["mesh"]
			var xf: Transform3D = it["xf"]
			for s: int in mesh.get_surface_count():
				var sname: String = mesh.surface_get_name(s)
				if sname == "panel" or sname == "glass" or sname == "fx":
					var mi := MeshInstance3D.new()
					mi.mesh = _single_surface(mesh, s)
					mi.transform = xf
					mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
					add_child(mi)
					n_panels += 1
					continue
				var a: Array = mesh.surface_get_arrays(s)
				var base: int = pos.size()
				pos.append_array(xf * (a[Mesh.ARRAY_VERTEX] as PackedVector3Array))
				nrm.append_array(Transform3D(xf.basis, Vector3.ZERO) * (a[Mesh.ARRAY_NORMAL] as PackedVector3Array))
				col.append_array(a[Mesh.ARRAY_COLOR] as PackedColorArray)
				c0.append_array(a[Mesh.ARRAY_CUSTOM0] as PackedByteArray)
				var si: PackedInt32Array = a[Mesh.ARRAY_INDEX]
				var off: int = idx.size()
				idx.resize(off + si.size())
				for j: int in si.size():
					idx[off + j] = si[j] + base
		if pos.is_empty():
			continue
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = pos
		arrays[Mesh.ARRAY_NORMAL] = nrm
		arrays[Mesh.ARRAY_COLOR] = col
		arrays[Mesh.ARRAY_CUSTOM0] = c0
		arrays[Mesh.ARRAY_INDEX] = idx
		var am := ArrayMesh.new()
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
			Mesh.ARRAY_CUSTOM_RGBA_HALF << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
		am.surface_set_material(0, factory.mat_static)
		var mi := MeshInstance3D.new()
		mi.name = "Chunk_" + key.replace("|", "_")
		mi.mesh = am
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if key.ends_with("cast") \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		n_meshes += 1
		verts += pos.size()
	stats["chunk_meshes"] = n_meshes
	stats["panel_meshes"] = n_panels
	stats["static_vertices"] = verts
	stats["instances"] = _instances.size()
	_instances.clear()


func _single_surface(mesh: ArrayMesh, s: int) -> ArrayMesh:
	var key: String = "%s#%d" % [mesh.resource_path, s]
	if _mesh_cache.has(key):
		return _mesh_cache[key]
	var am := ArrayMesh.new()
	var fmt: int = mesh.surface_get_format(s)
	var flags: int = fmt & (Mesh.ARRAY_FORMAT_CUSTOM_MASK << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
	am.add_surface_from_arrays(mesh.surface_get_primitive_type(s), mesh.surface_get_arrays(s), [], {}, flags)
	am.surface_set_material(0, mesh.surface_get_material(s))
	_mesh_cache[key] = am
	return am
