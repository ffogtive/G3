class_name FightFx
extends Node3D
## 3D fight juice (NATIVE_PORT M1b FX: 스파크, 폭발, 연기, 잔해, 컨페티, 충격파, 해방 파도) driven by GameSim events.
##  - particles: one pooled voxel system, three MultiMeshes = lit cubes (debris, confetti; shrink out, bounce on the
##    road), additive glow cubes stretched along velocity (sparks, fireball), alpha smoke puffs (grow, fade).
##  - shockwave rings (flat additive torus), short omni flashes, projectiles (tacks spin on their arc, the rage bomb
##    trails smoke), N4 range band (LaneBand), release wave: a green band sweeping from the front of the jam to its
##    tail at tune.releaseWaveSpeed, popping a ✓ over every car it frees (wave_cars(npc buffer)) — the red brake-light
##    sea "turns green" — with confetti over the player.
## Deterministic: one RandomNumberGenerator seeded in setup(seed); time is advance(dt) (real dt from game.gd, or
## fixed steps from shots); nothing reads Engine time or randf(). Shakes / FOV punches go to `camera_rig` if set.
## Wiring: setup(road, seed); on_event(e, state) per drained sim event; sync(state, npc_buffer) + advance(dt) per frame.

const MAX_LIT: int = 700
const MAX_GLOW: int = 700
const MAX_SMOKE: int = 220
const STRIDE: int = 8           # TrafficBridge buffer [id, kind, lane, x, s, yaw, v, bits]
const YELLOW := Color8(0xff, 0xd2, 0x3f)
const ORANGE := Color8(0xff, 0x7a, 0x1a)
const CONFETTI: Array[Color] = [Color8(0xff, 0x3b, 0x30), Color8(0xff, 0xd2, 0x3f), Color8(0x3c, 0xe0, 0x8e),
	Color8(0x2f, 0x6f, 0xd6), Color8(0xb1, 0x5c, 0xff), Color8(0xff, 0x8a, 0x1f), Color8(0x14, 0xd3, 0xe0)]

var road: RoadGraph
var camera_rig: CameraRig
var rng := RandomNumberGenerator.new()
## true: the caller advances time (advance(dt)); false: _process(delta).
var manual: bool = false
## Jam front / tail s (GameSim.front_s / tail_s): the release wave runs front → tail like the sim's.
var front_s: float = NAN
var tail_s: float = NAN
var band: LaneBand
var wave_speed: float = 70.0
var now: float = 0.0
## Release wave: front s now (NAN = idle), tail s, ids already popped.
var wave_s: float = NAN
var wave_tail: float = -45.0
var wave_popped: int = 0
var _wave_done: Dictionary = {}
var _wave_mi: MeshInstance3D
var _wave_mat: ShaderMaterial
var _wave_a: float = 0.0
var _wave_burst: float = 0.0
var _wave_start: float = NAN
var _curtain: MeshInstance3D
var _curtain_mat: ShaderMaterial

var _mm: Array[MultiMeshInstance3D] = []      # 0 lit, 1 glow, 2 smoke
var _parts: Array[Array] = [[], [], []]       # per system: Array of Dictionary {p, v, r, w, s0, s1, life, age, c, g, drag, bounce, shape}
var _bufs: Array[PackedFloat32Array] = [PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array()]  # reused MultiMesh buffers
var _rings: Array[Dictionary] = []            # {mi, mat, born, dur, r0, r1, col}
var _lights: Array[Dictionary] = []           # {light, born, dur, e}
var _tack_mm: MultiMeshInstance3D
var _bomb_mm: MultiMeshInstance3D
var _check_mm: MultiMeshInstance3D
var _checks: Array[Dictionary] = []           # {p, born}
var _glow_mm: MultiMeshInstance3D             # green under-glow of each freed car: the red sea turns green
var _delayed: Array[Dictionary] = []          # {at, fn: Callable}
var _bomb_trail_t: float = 0.0
var _state: Dictionary = {}


func setup(p_road: RoadGraph, seed: int, tune: Dictionary = {}, p_front_s: float = NAN, p_tail_s: float = NAN) -> void:
	road = p_road
	rng.seed = seed * 7919 + 17
	wave_speed = float(tune.get("releaseWaveSpeed", 70.0))
	front_s = p_front_s
	tail_s = p_tail_s
	if band != null:
		band.road = p_road


func _ready() -> void:
	var cube := BoxMesh.new()
	cube.size = Vector3.ONE
	var lit := StandardMaterial3D.new()
	lit.vertex_color_use_as_albedo = true
	lit.roughness = 0.85
	var glow := StandardMaterial3D.new()
	glow.vertex_color_use_as_albedo = true
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	glow.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glow.no_depth_test = false
	glow.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	var smoke := StandardMaterial3D.new()
	smoke.vertex_color_use_as_albedo = true
	smoke.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	smoke.roughness = 1.0
	smoke.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	var puff := SphereMesh.new()
	puff.radius = 0.5
	puff.height = 1.0
	puff.radial_segments = 8
	puff.rings = 4
	var defs: Array = [[cube, lit, MAX_LIT, true], [cube, glow, MAX_GLOW, false], [puff, smoke, MAX_SMOKE, false]]
	for d: Array in defs:
		var mmi := MultiMeshInstance3D.new()
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = d[0]
		mm.instance_count = int(d[2])
		mm.visible_instance_count = 0
		mmi.multimesh = mm
		mmi.material_override = d[1]
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if bool(d[3]) else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.extra_cull_margin = 4000.0
		add_child(mmi)
		_mm.append(mmi)
	_tack_mm = _make_mm(_caltrop_mesh(), _metal(), 48)
	var bomb_mesh := BoxMesh.new()
	bomb_mesh.size = Vector3(0.5, 0.5, 1.2)
	var bomb_mat := StandardMaterial3D.new()
	bomb_mat.albedo_color = Color8(0xff, 0x5a, 0x1f)
	bomb_mat.emission_enabled = true
	bomb_mat.emission = Color8(0xff, 0x7a, 0x1a)
	bomb_mat.emission_energy_multiplier = 2.5
	_bomb_mm = _make_mm(bomb_mesh, bomb_mat, 8)
	var quad := QuadMesh.new()
	quad.size = Vector2(1.6, 1.6)
	var cm := StandardMaterial3D.new()
	cm.albedo_texture = _check_texture()
	cm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	cm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	cm.billboard_keep_scale = true
	cm.vertex_color_use_as_albedo = true
	cm.no_depth_test = true
	cm.render_priority = 2
	_check_mm = _make_mm(quad, cm, 260)
	var gq := PlaneMesh.new()
	gq.size = Vector2(3.4, 6.4)
	var gm := StandardMaterial3D.new()
	gm.albedo_texture = _glow_texture()
	gm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	gm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	gm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	gm.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	gm.vertex_color_use_as_albedo = true
	_glow_mm = _make_mm(gq, gm, 260)
	band = LaneBand.new()
	band.name = "RangeBand"
	band.road = road
	add_child(band)
	_wave_mi = MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(1, 1)
	_wave_mi.mesh = pm
	var sh := Shader.new()
	sh.code = WAVE_SHADER
	_wave_mat = ShaderMaterial.new()
	_wave_mat.shader = sh
	_wave_mi.material_override = _wave_mat
	_wave_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_wave_mi.visible = false
	add_child(_wave_mi)
	# vertical light curtain on the wave front (reads as a glowing line from the high release camera)
	_curtain = MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(1, 1)
	_curtain.mesh = qm
	var csh := Shader.new()
	csh.code = CURTAIN_SHADER
	_curtain_mat = ShaderMaterial.new()
	_curtain_mat.shader = csh
	_curtain.material_override = _curtain_mat
	_curtain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_curtain.visible = false
	add_child(_curtain)
	for i: int in 4:
		var mi := MeshInstance3D.new()
		var tm := TorusMesh.new()
		tm.inner_radius = 0.86
		tm.outer_radius = 1.0
		tm.rings = 40
		tm.ring_segments = 6
		mi.mesh = tm
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		mi.material_override = m
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		add_child(mi)
		_rings.append({"mi": mi, "mat": m, "born": -99.0, "dur": 0.5, "r0": 1.0, "r1": 8.0, "col": Color.WHITE})
	for i: int in 2:
		var l := OmniLight3D.new()
		l.omni_range = 18.0
		l.light_energy = 0.0
		l.shadow_enabled = false
		l.visible = false
		add_child(l)
		_lights.append({"light": l, "born": -99.0, "dur": 0.3, "e": 0.0})


const WAVE_SHADER: String = """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;
uniform float alpha = 0.0;
uniform float t = 0.0;
uniform float len_m = 40.0;
void fragment() {
	// v = 0 at the leading edge (lowest s, toward the tail), 1 at the trailing end. PlaneMesh UV.y = 0 is at −Z, the
	// highest s, so flip it.
	float v = 1.0 - UV.y;
	float body = 1.0 - smoothstep(0.05, 1.0, v);
	float m = v * len_m;
	float cx = abs(UV.x - 0.5) * 9.0;
	float ch = fract((m + cx) / 4.5 + t * 2.0);
	float chev = smoothstep(0.0, 0.1, ch) * (1.0 - smoothstep(0.32, 0.42, ch));
	vec3 g = vec3(0.24, 0.95, 0.52);
	float edge = exp(-pow(m / 1.4, 2.0));
	float a = 1.25 * edge + 0.42 * body + 0.4 * chev * body;
	float side = smoothstep(0.0, 0.04, UV.x) * smoothstep(0.0, 0.04, 1.0 - UV.x);
	ALBEDO = (g + vec3(0.6) * edge) * a * alpha * side;
}
"""


const CURTAIN_SHADER: String = """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;
uniform float alpha = 0.0;
uniform float t = 0.0;
void fragment() {
	float up = 1.0 - UV.y;                       // 0 at the road, 1 at the top
	float streak = 0.65 + 0.35 * sin(UV.x * 90.0 + t * 7.0) * sin(UV.x * 37.0 - t * 3.0);
	float side = smoothstep(0.0, 0.03, UV.x) * smoothstep(0.0, 0.03, 1.0 - UV.x);
	float a = pow(1.0 - up, 2.2) * streak * side * alpha;
	ALBEDO = vec3(0.35, 1.0, 0.6) * a * 1.4;
}
"""


func _make_mm(mesh: Mesh, mat: Material, n: int) -> MultiMeshInstance3D:
	var mmi := MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = n
	mm.visible_instance_count = 0
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.extra_cull_margin = 4000.0
	add_child(mmi)
	return mmi


func _metal() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color8(0x8a, 0x93, 0xa0)
	m.metallic = 0.7
	m.roughness = 0.3
	m.vertex_color_use_as_albedo = false
	return m


## Caltrop: four spikes along the tetrahedron axes (web weapons.js tack = 4 cones), ≈ 0.7 m across.
func _caltrop_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var dirs: Array[Vector3] = [Vector3(1, 1, 1), Vector3(-1, -1, 1), Vector3(-1, 1, -1), Vector3(1, -1, -1)]
	for d: Vector3 in dirs:
		var ax: Vector3 = d.normalized()
		var u: Vector3 = ax.cross(Vector3.UP if absf(ax.y) < 0.9 else Vector3.RIGHT).normalized()
		var w: Vector3 = ax.cross(u)
		var tip: Vector3 = ax * 0.42
		var r: float = 0.09
		for i: int in 4:
			var a0: float = TAU * float(i) / 4.0
			var a1: float = TAU * float(i + 1) / 4.0
			var b0: Vector3 = (u * cos(a0) + w * sin(a0)) * r
			var b1: Vector3 = (u * cos(a1) + w * sin(a1)) * r
			st.set_normal((b0 + b1).normalized())
			st.add_vertex(b0)
			st.add_vertex(b1)
			st.add_vertex(tip)
	st.generate_normals()
	return st.commit()


## Soft radial blob (32², white; tinted per instance).
func _glow_texture() -> ImageTexture:
	var n: int = 32
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y: int in n:
		for x: int in n:
			var d: float = Vector2(float(x) - 15.5, float(y) - 15.5).length() / 15.5
			var a: float = clampf(1.0 - d, 0.0, 1.0)
			img.set_pixel(x, y, Color(1, 1, 1, a * a))
	return ImageTexture.create_from_image(img)


## Green round ✓ badge (64², drawn once, deterministic).
func _check_texture() -> ImageTexture:
	var n: int = 64
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var c := Vector2(31.5, 31.5)
	for y: int in n:
		for x: int in n:
			var d: float = Vector2(x, y).distance_to(c)
			var col := Color(0, 0, 0, 0)
			if d < 31.0:
				col = Color8(0x17, 0x20, 0x2b)
			if d < 26.5:
				col = Color8(0x22, 0xc5, 0x5e)
			if d < 26.5 and y < 24 and d > 19.0:
				col = Color8(0x5a, 0xe6, 0x8c)
			img.set_pixel(x, y, Color(col, clampf(31.0 - d, 0.0, 1.0)) if d >= 30.0 else col)
	# check stroke
	var pts: Array[Vector2] = [Vector2(17, 33), Vector2(28, 44), Vector2(47, 22)]
	for seg: int in 2:
		var a: Vector2 = pts[seg]
		var b: Vector2 = pts[seg + 1]
		for k: int in 60:
			var p: Vector2 = a.lerp(b, float(k) / 59.0)
			for oy: int in range(-4, 5):
				for ox: int in range(-4, 5):
					if ox * ox + oy * oy <= 16:
						var q := Vector2i(roundi(p.x) + ox, roundi(p.y) + oy)
						if q.x >= 0 and q.y >= 0 and q.x < n and q.y < n:
							img.set_pixelv(q, Color.WHITE)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func _w(s: float, x: float, y: float = 0.0) -> Vector3:
	var p: Vector3 = road.position(s, x) if road != null else Vector3(x, 0, -s)
	p.y += y
	return p


# ───────────────────────────── emitters

func _spawn(sys: int, d: Dictionary) -> void:
	var arr: Array = _parts[sys]
	var cap: int = [MAX_LIT, MAX_GLOW, MAX_SMOKE][sys]
	if arr.size() >= cap:
		arr.pop_front()
	d["age"] = 0.0
	arr.append(d)


func _rand_dir(up: float = 1.0) -> Vector3:
	var a: float = rng.randf() * TAU
	var z: float = rng.randf_range(-0.2, 1.0) * up
	var r: float = sqrt(maxf(0.0, 1.0 - z * z))
	return Vector3(cos(a) * r, z, sin(a) * r)


func sparks(pos: Vector3, n: int, speed: float = 10.0, col: Color = YELLOW, size: float = 0.16) -> void:
	for i: int in n:
		var v: Vector3 = _rand_dir() * speed * rng.randf_range(0.45, 1.0)
		_spawn(1, {"p": pos, "v": v, "r": Vector3.ZERO, "w": Vector3.ZERO, "s0": size * rng.randf_range(0.7, 1.3), "s1": 0.0,
			"life": rng.randf_range(0.22, 0.45), "c": col.lerp(Color.WHITE, rng.randf() * 0.4), "g": 16.0, "drag": 2.5,
			"bounce": 0.3, "shape": 1})


func debris(pos: Vector3, n: int, col: Color, speed: float = 8.0, size: float = 0.36) -> void:
	for i: int in n:
		var v: Vector3 = _rand_dir() * speed * rng.randf_range(0.4, 1.0) + Vector3(0, rng.randf_range(2.0, 6.0), 0)
		var c: Color = col.darkened(rng.randf() * 0.35)
		_spawn(0, {"p": pos + _rand_dir() * 0.4, "v": v, "r": Vector3(rng.randf() * TAU, rng.randf() * TAU, 0),
			"w": Vector3(rng.randf_range(-9, 9), rng.randf_range(-9, 9), rng.randf_range(-9, 9)), "s0": size * rng.randf_range(0.5, 1.2),
			"s1": 0.0, "life": rng.randf_range(0.9, 1.6), "c": c, "g": 24.0, "drag": 0.6, "bounce": 0.35, "shape": 0})


func smoke(pos: Vector3, n: int, col: Color = Color(0.35, 0.36, 0.4, 0.75), size: float = 1.2) -> void:
	for i: int in n:
		var v: Vector3 = _rand_dir(0.6) * rng.randf_range(0.8, 3.0) + Vector3(0, rng.randf_range(1.2, 3.2), 0)
		_spawn(2, {"p": pos + _rand_dir() * 0.6, "v": v, "r": Vector3.ZERO, "w": Vector3.ZERO, "s0": size * rng.randf_range(0.5, 0.8),
			"s1": size * rng.randf_range(1.6, 2.6), "life": rng.randf_range(0.8, 1.6), "c": col, "g": -0.6, "drag": 1.6,
			"bounce": 0.0, "shape": 2})


func fireball(pos: Vector3, n: int, size: float = 1.4) -> void:
	for i: int in n:
		var v: Vector3 = _rand_dir() * rng.randf_range(2.0, 7.0) * size + Vector3(0, 2.0, 0)
		var c: Color = YELLOW.lerp(Color8(0xff, 0x4a, 0x1a), rng.randf())
		_spawn(1, {"p": pos + _rand_dir() * 0.5 * size, "v": v, "r": Vector3(rng.randf() * TAU, rng.randf() * TAU, 0),
			"w": Vector3(rng.randf_range(-4, 4), rng.randf_range(-4, 4), 0), "s0": size * rng.randf_range(0.6, 1.3), "s1": 0.0,
			"life": rng.randf_range(0.28, 0.55), "c": c, "g": -3.0, "drag": 3.5, "bounce": 0.0, "shape": 3})


func confetti(pos: Vector3, n: int, spread: float = 6.0, up: float = 11.0) -> void:
	for i: int in n:
		var v := Vector3(rng.randf_range(-1, 1) * spread, rng.randf_range(0.6, 1.0) * up, rng.randf_range(-1, 1) * spread)
		_spawn(0, {"p": pos + Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1)), "v": v,
			"r": Vector3(rng.randf() * TAU, rng.randf() * TAU, rng.randf() * TAU),
			"w": Vector3(rng.randf_range(-12, 12), rng.randf_range(-6, 6), rng.randf_range(-12, 12)), "s0": 1.0, "s1": 1.0,
			"life": rng.randf_range(2.2, 3.4), "c": CONFETTI[rng.randi_range(0, CONFETTI.size() - 1)], "g": 7.0, "drag": 1.9,
			"bounce": 0.0, "shape": 4, "flut": rng.randf() * TAU})


func ring(pos: Vector3, r1: float, col: Color, dur: float = 0.45, r0: float = 0.6) -> void:
	var best: Dictionary = _rings[0]
	for rg: Dictionary in _rings:
		if now - float(rg["born"]) > float(rg["dur"]):
			best = rg
			break
		if float(rg["born"]) < float(best["born"]):
			best = rg
	best["born"] = now
	best["dur"] = dur
	best["r0"] = r0
	best["r1"] = r1
	best["col"] = col
	(best["mi"] as MeshInstance3D).position = pos + Vector3(0, 0.15, 0)


func light(pos: Vector3, energy: float, dur: float, col: Color = Color8(0xff, 0xb0, 0x50)) -> void:
	var best: Dictionary = _lights[0]
	for l: Dictionary in _lights:
		if float(l["born"]) < float(best["born"]):
			best = l
	best["born"] = now
	best["dur"] = dur
	best["e"] = energy
	var ol: OmniLight3D = best["light"]
	ol.position = pos + Vector3(0, 2.0, 0)
	ol.light_color = col


func explosion(pos: Vector3, scale: float = 1.0, col: Color = Color8(0xd9, 0xc9, 0xa3)) -> void:
	fireball(pos + Vector3(0, 0.8, 0), roundi(18 * scale), 1.3 * scale)
	sparks(pos + Vector3(0, 0.8, 0), roundi(28 * scale), 14.0 * scale, YELLOW, 0.2)
	debris(pos + Vector3(0, 0.8, 0), roundi(12 * scale), col, 9.0 * scale, 0.42)
	debris(pos + Vector3(0, 0.6, 0), roundi(6 * scale), Color8(0x2a, 0x2f, 0x38), 7.0 * scale, 0.3)
	smoke(pos + Vector3(0, 1.0, 0), roundi(8 * scale), Color(0.28, 0.28, 0.31, 0.55), minf(1.6, 1.2 * scale))
	ring(pos, 9.0 * scale, Color(1.0, 0.75, 0.3, 0.9), 0.5)
	light(pos, 6.0 * scale, 0.35)
	_shake(0.45 * scale)


func _shake(t: float) -> void:
	if camera_rig != null:
		camera_rig.add_shake(t)


func _after(delay: float, fn: Callable) -> void:
	_delayed.append({"at": now + delay, "fn": fn})


# ───────────────────────────── sim events

func _villain(st: Dictionary, id: int) -> Dictionary:
	for v: Variant in st.get("villains", []):
		if int((v as Dictionary).get("id", -1)) == id:
			return v
	return {}


func _player_pos(st: Dictionary, y: float = 0.8) -> Vector3:
	var p: Dictionary = st.get("player", {})
	return _w(float(p.get("s", 0.0)), float(p.get("x", 0.0)), y)


func on_event(e: Dictionary, st: Dictionary = {}) -> void:
	if not st.is_empty():
		_state = st
	st = _state
	match str(e.get("type", "")):
		"fire":
			var mp: Vector3 = _w(float(e.get("from_s", 0.0)), float(e.get("from_x", 0.0)), 1.4)
			sparks(mp, 4, 4.0, Color8(0xff, 0xe6, 0x80), 0.12)
		"hit":
			var hp: Vector3 = _w(float(e.get("s", 0.0)), float(e.get("x", 0.0)), 0.6)
			var kind: String = str(e.get("kind", "tack"))
			if kind == "bomb":
				var v: Dictionary = _villain(st, int(e.get("target_id", -1)))
				explosion(hp, 0.9, _vcol(v))
			elif kind == "mini":
				sparks(hp, 10, 8.0)
				if bool(e.get("down", false)):
					explosion(hp, 0.45)
			else:
				var win: bool = bool(e.get("window", false))
				sparks(hp, 22 if win else 9, 12.0 if win else 8.0, Color8(0xff, 0xb4, 0x00) if win else YELLOW, 0.18 if win else 0.14)
				debris(hp, 3, Color8(0x22, 0x24, 0x28), 5.0, 0.18)
				if win:
					ring(hp, 4.0, Color(1.0, 0.8, 0.2, 0.9), 0.3)
					_shake(0.22)
				else:
					_shake(0.06)
			if int(e.get("popped", 0)) > 0:
				debris(hp, 12, Color8(0x1a, 0x1c, 0x20), 9.0, 0.3)
				smoke(hp, 5, Color(0.25, 0.25, 0.27, 0.7), 1.0)
				ring(hp, 5.0, Color(1, 1, 1, 0.7), 0.3)
				_shake(0.3)
		"miss":
			var dp: Vector3 = _w(float(e.get("s", 0.0)), float(e.get("x", 0.0)), 0.1)
			smoke(dp, 3, Color(0.62, 0.6, 0.56, 0.6), 0.7)
			debris(dp, 3, Color8(0x6a, 0x70, 0x78), 4.0, 0.14)
		"bomb":
			pass
		"damage":
			var pp: Vector3 = _player_pos(st, 1.0)
			sparks(pp, 14, 9.0, Color8(0xff, 0x6a, 0x3a), 0.16)
			debris(pp, 4, Color8(0xff, 0xcc, 0x28), 6.0, 0.22)
			_shake(clampf(float(e.get("amount", 5)) / 25.0, 0.15, 0.6))
		"bump":
			if float(e.get("dmg", 0)) > 0.0 or float(e.get("rel_v", 0.0)) > 4.0:
				sparks(_player_pos(st, 0.8) + Vector3(0, 0, -2.0), 8, 7.0)
				_shake(0.15)
		"smash":
			debris(_player_pos(st, 0.6) + Vector3(0, 0, -3.0), 8, Color8(0xff, 0x7a, 0x1a), 9.0, 0.3)
		"stun":
			var sv: Dictionary = _villain(st, int(e.get("id", -1)))
			if not sv.is_empty():
				ring(_w(float(sv["s"]), float(sv["x"]), 0.2), 4.5, Color(1.0, 0.9, 0.3, 0.9), 0.35)
		"boss_phase":
			for v2: Variant in st.get("villains", []):
				if bool((v2 as Dictionary).get("alive", false)):
					ring(_w(float(v2["s"]), float(v2["x"]), 0.2), 7.0, Color(1.0, 0.3, 0.2, 0.9), 0.45)
			_shake(0.35)
		"kill":
			var kp: Vector3 = _w(float(e.get("s", 0.0)), float(e.get("x", 0.0)), 0.4)
			var kv: Dictionary = _villain(st, int(e.get("id", -1)))
			explosion(kp, 1.6, _vcol(kv))
			ring(kp, 16.0, Color(1, 1, 1, 0.8), 0.7, 1.0)
			_after(0.18, func() -> void: explosion(kp + Vector3(1.2, 0.4, -1.0), 0.8, _vcol(kv)))
			_after(0.4, func() -> void: confetti(kp + Vector3(0, 1.0, 0), 70, 7.0, 13.0))
			_shake(0.9)
		"rage_horn":
			ring(_player_pos(st, 0.3), 14.0, Color(1.0, 0.55, 0.15, 0.9), 0.5)
			_shake(0.3)
		"release":
			start_wave(front_s, tail_s)
			var cp: Vector3 = _player_pos(st, 4.0)
			confetti(cp, 90, 9.0, 12.0)
		"wreck":
			explosion(_player_pos(st, 0.6), 0.9, Color8(0xff, 0xcc, 0x28))


func _vcol(v: Dictionary) -> Color:
	var c: int = int(v.get("color", 0xd9c9a3))
	return Color8((c >> 16) & 0xff, (c >> 8) & 0xff, c & 0xff)


## Release wave from the front of the jam (front_s) back to its tail; NAN front = 30 m ahead of the player.
func start_wave(front_s: float, tail_s: float) -> void:
	var ps: float = float((_state.get("player", {}) as Dictionary).get("s", 0.0))
	wave_s = front_s if is_finite(front_s) else ps + 30.0
	wave_tail = tail_s if is_finite(tail_s) else ps - 220.0
	wave_popped = 0
	_wave_start = wave_s
	_wave_done.clear()


# ───────────────────────────── per frame

## Frame sync: range band + projectiles from the state, ✓ pops from the NPC buffer as the release wave passes.
func sync(st: Dictionary, npc_buf: PackedFloat32Array = PackedFloat32Array()) -> void:
	_state = st
	band.apply_state(st)
	var pr: Array = st.get("projectiles", [])
	var tk: int = 0
	var bm: int = 0
	var tmm: MultiMesh = _tack_mm.multimesh
	var bmm: MultiMesh = _bomb_mm.multimesh
	for q: Variant in pr:
		var d: Dictionary = q
		var pos: Vector3 = _w(float(d.get("s", 0.0)), float(d.get("x", 0.0)), float(d.get("y", 0.5)))
		var p: float = float(d.get("p", 0.0))
		if str(d.get("kind", "")) == "tack" and tk < tmm.instance_count:
			var b := Basis.from_euler(Vector3(p * 9.0, p * 13.0 + float(tk), p * 5.0)).scaled(Vector3.ONE * 0.95)
			tmm.set_instance_transform(tk, Transform3D(b, pos))
			tmm.set_instance_color(tk, Color.WHITE)
			tk += 1
		elif str(d.get("kind", "")) == "bomb" and bm < bmm.instance_count:
			bmm.set_instance_transform(bm, Transform3D(Basis.from_euler(Vector3(0, 0, p * 12.0)), pos))
			bmm.set_instance_color(bm, Color.WHITE)
			bm += 1
			if now - _bomb_trail_t > 0.03:
				smoke(pos, 1, Color(0.85, 0.85, 0.85, 0.55), 0.6)
				fireball(pos, 1, 0.5)
	tmm.visible_instance_count = tk
	bmm.visible_instance_count = bm
	if bm > 0 and now - _bomb_trail_t > 0.03:
		_bomb_trail_t = now
	if is_finite(wave_s) and not npc_buf.is_empty():
		var n: int = npc_buf.size() / STRIDE
		for k: int in n:
			var o: int = k * STRIDE
			var id: int = int(npc_buf[o])
			if _wave_done.has(id):
				continue
			var cs: float = npc_buf[o + 4]
			if cs >= wave_s and cs <= maxf(wave_s + 60.0, _wave_start + 90.0):
				_wave_done[id] = true
				wave_popped += 1
				var cp: Vector3 = _w(cs, npc_buf[o + 3], 3.2)
				_checks.append({"p": cp, "born": now + rng.randf() * 0.08})
				if _checks.size() > 250:
					_checks.pop_front()
				sparks(cp - Vector3(0, 1.4, 0), 2, 4.0, Color8(0x5a, 0xff, 0x9c), 0.12)


func advance(dt: float) -> void:
	now += dt
	band.advance(dt)
	var keep: Array[Dictionary] = []
	for d: Dictionary in _delayed:
		if now >= float(d["at"]):
			(d["fn"] as Callable).call()
		else:
			keep.append(d)
	_delayed = keep
	for sys: int in 3:
		_step_sys(sys, dt)
	for rg: Dictionary in _rings:
		var mi: MeshInstance3D = rg["mi"]
		var k: float = (now - float(rg["born"])) / float(rg["dur"])
		mi.visible = k >= 0.0 and k < 1.0
		if mi.visible:
			var r: float = lerpf(float(rg["r0"]), float(rg["r1"]), 1.0 - pow(1.0 - k, 3.0))
			mi.scale = Vector3(r, 0.2 + 0.4 * (1.0 - k), r)  # flat: a tall additive ring read as haze when it swept the camera
			var c: Color = rg["col"]
			(rg["mat"] as StandardMaterial3D).albedo_color = Color(c.r, c.g, c.b, c.a * (1.0 - k))
	for l: Dictionary in _lights:
		var ol: OmniLight3D = l["light"]
		var k2: float = (now - float(l["born"])) / float(l["dur"])
		ol.visible = k2 >= 0.0 and k2 < 1.0
		ol.light_energy = float(l["e"]) * maxf(0.0, 1.0 - k2)
	_step_wave(dt)
	_step_checks()


func _step_sys(sys: int, dt: float) -> void:
	var arr: Array = _parts[sys]
	var mm: MultiMesh = _mm[sys].multimesh
	if arr.is_empty():
		if mm.visible_instance_count != 0:
			mm.visible_instance_count = 0
		return
	var alive: Array = []
	var buf: PackedFloat32Array = _bufs[sys]
	if buf.size() != mm.instance_count * 16:
		buf.resize(mm.instance_count * 16)
	var n: int = 0
	for q: Variant in arr:
		var d: Dictionary = q
		var age: float = float(d["age"]) + dt
		d["age"] = age
		var life: float = float(d["life"])
		if age >= life:
			continue
		var v: Vector3 = d["v"]
		v.y -= float(d["g"]) * dt
		v *= exp(-float(d["drag"]) * dt)
		var shape: int = int(d["shape"])
		if shape == 4:
			var fl: float = float(d["flut"]) + age * 5.0
			d["flut"] = fl
			v.x += sin(fl) * 6.0 * dt
			v.z += cos(fl * 0.7) * 6.0 * dt
			v.y = maxf(v.y, -3.2)
		var p: Vector3 = d["p"] + v * dt
		var ground: float = 0.08
		if p.y < ground and float(d["bounce"]) > 0.0:
			p.y = ground
			if v.y < 0.0:
				v.y = -v.y * float(d["bounce"])
				v.x *= 0.6
				v.z *= 0.6
				d["w"] = (d["w"] as Vector3) * 0.5
		elif p.y < 0.02 and shape == 4:
			p.y = 0.02
			v = Vector3.ZERO
			d["w"] = Vector3.ZERO
		d["p"] = p
		d["v"] = v
		var r: Vector3 = d["r"] + (d["w"] as Vector3) * dt
		d["r"] = r
		alive.append(d)
		if n >= mm.instance_count:
			continue
		var k: float = age / life
		var col: Color = d["c"]
		var sz: float
		var b: Basis
		match shape:
			1:  # spark: stretched along velocity
				sz = float(d["s0"]) * (1.0 - k)
				var sp: float = v.length()
				b = Basis.looking_at(v.normalized() if sp > 0.01 else Vector3.FORWARD, Vector3.UP if absf(v.normalized().y) < 0.95 else Vector3.RIGHT)
				b = b.scaled(Vector3(sz, sz, sz * (1.0 + minf(5.0, sp * 0.18))))
				col = Color(col.r, col.g, col.b, 1.0 - k * k)
			3:  # fireball cube: swell then shrink, yellow → red → dark
				var sw: float = sin(PI * minf(1.0, k * 1.4))
				sz = float(d["s0"]) * (0.5 + 0.8 * sw)
				b = Basis.from_euler(r).scaled(Vector3.ONE * sz)
				col = col.lerp(Color8(0x7a, 0x14, 0x08), k)
				col.a = 1.0 - k
			2:  # smoke: grow, fade
				sz = lerpf(float(d["s0"]), float(d["s1"]), 1.0 - pow(1.0 - k, 2.0))
				b = Basis().scaled(Vector3.ONE * sz)
				col = Color(col.r, col.g, col.b, col.a * (1.0 - k) * minf(1.0, age / 0.08))
			4:  # confetti: thin card, spins, shrinks at the very end
				var s4: float = 1.0 if k < 0.85 else (1.0 - k) / 0.15
				b = Basis.from_euler(r).scaled(Vector3(0.34, 0.035, 0.22) * s4)
			_:  # debris cube: shrink out over the last 40 %
				sz = float(d["s0"]) * (1.0 if k < 0.6 else (1.0 - k) / 0.4)
				b = Basis.from_euler(r).scaled(Vector3.ONE * sz)
		var o: int = n * 16
		buf[o + 0] = b.x.x
		buf[o + 1] = b.y.x
		buf[o + 2] = b.z.x
		buf[o + 3] = p.x
		buf[o + 4] = b.x.y
		buf[o + 5] = b.y.y
		buf[o + 6] = b.z.y
		buf[o + 7] = p.y
		buf[o + 8] = b.x.z
		buf[o + 9] = b.y.z
		buf[o + 10] = b.z.z
		buf[o + 11] = p.z
		buf[o + 12] = col.r
		buf[o + 13] = col.g
		buf[o + 14] = col.b
		buf[o + 15] = col.a
		n += 1
	_parts[sys] = alive
	_bufs[sys] = buf
	mm.buffer = buf
	mm.visible_instance_count = n


func _step_wave(dt: float) -> void:
	if not is_finite(wave_s):
		_wave_a = move_toward(_wave_a, 0.0, dt / 0.4)
		_wave_mi.visible = _wave_a > 0.01
		_curtain.visible = _wave_mi.visible
		if _wave_mi.visible:
			_wave_mat.set_shader_parameter(&"alpha", _wave_a)
			_curtain_mat.set_shader_parameter(&"alpha", _wave_a)
		return
	wave_s -= wave_speed * dt
	_wave_a = move_toward(_wave_a, 1.0, dt / 0.15)
	_wave_burst += dt
	while _wave_burst > 0.12:  # confetti puffs riding the wave front across the lanes
		_wave_burst -= 0.12
		var lane: float = float(rng.randi_range(0, 3))
		confetti(_w(wave_s, RoadGraph.lane_x(lane), 2.5), 7, 2.5, 9.0)
		sparks(_w(wave_s, RoadGraph.lane_x(lane), 0.4), 3, 6.0, Color8(0x5a, 0xff, 0x9c), 0.14)
	var length: float = 46.0
	var x0: float = RoadGraph.MEDIAN_X + 0.6
	var x1: float = RoadGraph.SHOULDER_X + 1.8
	var xf: Transform3D = road.world(wave_s + length * 0.5, (x0 + x1) * 0.5) if road != null else Transform3D(Basis(), Vector3((x0 + x1) * 0.5, 0, -(wave_s + length * 0.5)))
	xf.origin.y += 0.08
	xf.basis = xf.basis.scaled(Vector3(x1 - x0, 1.0, length))
	_wave_mi.transform = xf
	_wave_mi.visible = true
	_wave_mat.set_shader_parameter(&"alpha", _wave_a)
	_wave_mat.set_shader_parameter(&"t", now)
	_wave_mat.set_shader_parameter(&"len_m", length)
	var cxf: Transform3D = road.world(wave_s, (x0 + x1) * 0.5) if road != null else Transform3D(Basis(), Vector3((x0 + x1) * 0.5, 0, -wave_s))
	cxf.origin.y += 3.0
	cxf.basis = cxf.basis.scaled(Vector3(x1 - x0, 6.0, 1.0))
	_curtain.transform = cxf
	_curtain.visible = true
	_curtain_mat.set_shader_parameter(&"alpha", _wave_a)
	_curtain_mat.set_shader_parameter(&"t", now)
	if wave_s < wave_tail - 20.0:
		wave_s = NAN


const CHECK_LIFE: float = 2.4


func _step_checks() -> void:
	var mm: MultiMesh = _check_mm.multimesh
	var gm: MultiMesh = _glow_mm.multimesh
	var n: int = 0
	var keep: Array[Dictionary] = []
	for c: Dictionary in _checks:
		var age: float = now - float(c["born"])
		if age > CHECK_LIFE:
			continue
		keep.append(c)
		if age < 0.0 or n >= mm.instance_count:
			continue
		var pop: float = UiDraw.back_out(age / 0.22, 3.0) if age < 0.22 else 1.0
		var a: float = 1.0 if age < CHECK_LIFE - 0.6 else (CHECK_LIFE - age) / 0.6
		var p: Vector3 = c["p"] + Vector3(0, minf(age, 1.0) * 1.0, 0)
		mm.set_instance_transform(n, Transform3D(Basis().scaled(Vector3.ONE * maxf(0.01, pop)), p))
		mm.set_instance_color(n, Color(1, 1, 1, a))
		var g: Vector3 = c["p"]
		g.y = 0.1
		var gs: float = 0.6 + 0.4 * minf(1.0, age / 0.25)
		gm.set_instance_transform(n, Transform3D(Basis().scaled(Vector3(gs, 1.0, gs)), g))
		gm.set_instance_color(n, Color(0.3, 1.0, 0.55, 0.85 * a))
		n += 1
	_checks = keep
	mm.visible_instance_count = n
	gm.visible_instance_count = n


func _process(delta: float) -> void:
	if not manual:
		advance(delta)


## Live particle count per system (tests / shot RESULT lines).
func counts() -> Dictionary:
	return {"lit": (_parts[0] as Array).size(), "glow": (_parts[1] as Array).size(), "smoke": (_parts[2] as Array).size(),
		"checks": _checks.size(), "wave": is_finite(wave_s)}
