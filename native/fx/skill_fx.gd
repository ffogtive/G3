class_name SkillFx
extends Node3D
## 3D juice of the rage ladder, the item skills and the finishers (docs/SKILLS.md 2-3, 3-3, 4; interface §6 fight_fx).
##
## 가설: ❓ every skill reads in one glance from the high boss camera when it has ONE big shape of its own on the impact
##       tick — t1 a fan of yellow ")))" sound arcs that slam into the villain's bumper, t3 a rain of 12 caltrops onto
##       a blinking 3-lane strip that stays as a decal, t5 a golden lock-on ring that sucks sparks in and bursts into a
##       light pillar, jump a dust ring + road crack, drone a police drone that dives and drops 6 bomblets — plus a comic
##       starburst on the hit. Particles stay inside FightFx's caps (lit 700 · glow 700 · smoke 220); 8 decals.
##
## Owned by FightFx (child; uses its pooled emitters, road, RNG and time). FightFx.on_event forwards skill_start /
## skill_hit / skill_end / finisher / kill / gone; FightFx.sync → sync(state); FightFx.advance(dt) → advance(dt) with
## the same (sim-scaled) dt, so slow-mo slows the shapes and hit-stop freezes them.
## Primitives (public, used by the recipes and the shots): arc_wave(from, to, …), carpet(lanes, s0, s1, n),
## drone_dive(from, to, t), beam(pos, h, dur), star_twinkle(pos), dust_ring(pos, r), burst(pos, size, col),
## decal(pos, kind, size, life) with kinds tack_strip · skid · scorch · crack.
## Finisher props follow the dying villain from the state (s, x, y, death_t) and fire their beats as death_t passes
## the finish timeline (SkillCues.finish_beats): rocket = ignition fireball + flame/smoke trail + scorch, balloon =
## 6 balloons popping out of the roof on strings, heli = police helicopter descending, hook + cable, lift-off,
## ufo = saucer + flickering tractor beam, blink-out. The ★ twinkles in frame where the car left (gone).
## Tone (DESIGN_REVIEW #14): cartoon enforcement parody — no ramming, no injury; the villain is lifted away.

const DECALS: int = 8
const GOLD := Color8(0xff, 0xd2, 0x3f)
const ORANGE := Color8(0xff, 0x7a, 0x1a)
const WAVE_COL := Color8(0xff, 0xd2, 0x3a)
const DUST := Color(0.62, 0.6, 0.56, 0.7)
const ASPHALT := Color8(0x3a, 0x3e, 0x46)
const RUBBER := Color8(0x1a, 0x1c, 0x20)
const BALLOON_COLS: Array[Color] = [Color8(0xff, 0x3b, 0x30), Color8(0xff, 0xd2, 0x3f), Color8(0x3c, 0xe0, 0x8e),
	Color8(0x2f, 0x6f, 0xd6), Color8(0xb1, 0x5c, 0xff), Color8(0xff, 0x8a, 0x1f)]

var fx: FightFx
var road: RoadGraph:
	get:
		return fx.road if fx != null else null

var _arcs: Array[Dictionary] = []        # {mi, mat, born, dur, p0, p1, w0, w1, col, yaw}
var _tk_mm: MultiMeshInstance3D
var _tacks: Array[Dictionary] = []       # {p0, p1, t0, t1, h, spin, landed, group}
var _strip: MeshInstance3D
var _strip_mat: ShaderMaterial
var _strip_until: float = -99.0
var _strip_born: float = -99.0
var _decals: Array[Dictionary] = []      # {node, born, life}
var _decal_tex: Dictionary = {}          # kind → [albedo, emission | null]
var _bursts: Array[Dictionary] = []      # {mi, mat, born, dur, size, col, rot}
var _stars: Array[Dictionary] = []       # {mi, mat, born, dur, size}
var _marker: Node3D
var _marker_mat: StandardMaterial3D
var _marker_on: Dictionary = {}          # {target, born, dur}
var _pillars: Array[Dictionary] = []     # {mi, mat, born, dur, col}
var _drone: Node3D
var _drone_rotors: Array[Node3D] = []
var _drone_leds: Array[StandardMaterial3D] = []
var _drone_on: Dictionary = {}           # {born, arrive, p0, target, leave_at, n, drops}
var _bombs: Array[Dictionary] = []       # {t0, t1, p0, target, off}
var _bomb_mm: MultiMeshInstance3D
var _balloons: Node3D
var _balloon_nodes: Array[Node3D] = []
var _heli: Node3D
var _heli_rotor: Node3D
var _heli_tail: Node3D
var _ufo: Node3D
var _ufo_lights: Array[StandardMaterial3D] = []
var _ufo_beam: MeshInstance3D
var _ufo_beam_mat: ShaderMaterial
var _strings: Array[MeshInstance3D] = []
var _fin: Dictionary = {}                # {id, target, born, beats, done, last_pos, gone_at, trail_t}
var _vel: Dictionary = {}                # villain id → [s, now, v]
var _mats: Dictionary = {}
var _state: Dictionary = {}


func _ready() -> void:
	# sound-wave arcs (t1, jump): flat additive crescents
	var arc_mesh: ArrayMesh = _crescent_mesh()
	for i: int in 8:
		var mi := MeshInstance3D.new()
		mi.mesh = arc_mesh
		var m := _add_mat(Color.WHITE)
		mi.material_override = m
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		add_child(mi)
		_arcs.append({"mi": mi, "mat": m, "born": -99.0, "dur": 0.2})
	# carpet tacks (own pool: the projectile MultiMesh is rewritten from the sim every frame)
	_tk_mm = _mm(fx._caltrop_mesh() if fx != null else BoxMesh.new(), fx._metal() if fx != null else StandardMaterial3D.new(), 24)
	var bm := CapsuleMesh.new()
	bm.radius = 0.16
	bm.height = 0.62
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = Color8(0x22, 0x26, 0x2e)
	bmat.emission_enabled = true
	bmat.emission = Color8(0xff, 0x5a, 0x1f)
	bmat.emission_energy_multiplier = 0.6
	_bomb_mm = _mm(bm, bmat, 8)
	# t3 telegraph strip
	_strip = MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(1, 1)
	_strip.mesh = pm
	var sh := Shader.new()
	sh.code = STRIP_SHADER
	_strip_mat = ShaderMaterial.new()
	_strip_mat.shader = sh
	_strip.material_override = _strip_mat
	_strip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_strip.visible = false
	add_child(_strip)
	# decals
	for kind: String in ["tack_strip", "skid", "scorch", "crack"]:
		_decal_tex[kind] = _make_decal_tex(kind)
	for i: int in DECALS:
		var d := Decal.new()
		d.visible = false
		d.upper_fade = 0.2
		d.lower_fade = 0.2
		d.cull_mask = 0xFFFFF
		add_child(d)
		_decals.append({"node": d, "born": -99.0, "life": 1.0})
	# comic bursts + ★ twinkles (billboards on top)
	var burst_tex: ImageTexture = _burst_texture()
	for i: int in 4:
		_bursts.append(_billboard(burst_tex, false, 3))
	var star_tex: ImageTexture = _star_texture()
	for i: int in 3:
		_stars.append(_billboard(star_tex, true, 4))
	# t5 lock-on marker: gold ring + 4 inward chevrons, flat on the road
	_marker = Node3D.new()
	_marker.visible = false
	add_child(_marker)
	_marker_mat = _add_mat(GOLD)
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.9
	tm.outer_radius = 1.0
	tm.rings = 48
	tm.ring_segments = 4
	ring.mesh = tm
	ring.material_override = _marker_mat
	ring.scale = Vector3(1, 0.05, 1)
	_marker.add_child(ring)
	var chev: ArrayMesh = _chevron_mesh()
	for i: int in 4:
		var c := MeshInstance3D.new()
		c.mesh = chev
		c.material_override = _marker_mat
		c.rotation.y = TAU * float(i) / 4.0
		_marker.add_child(c)
	# light pillars (t5 impact gold; UFO uses its own beam)
	var cyl := CylinderMesh.new()
	cyl.top_radius = 1.0
	cyl.bottom_radius = 1.0
	cyl.height = 1.0
	cyl.cap_top = false
	cyl.cap_bottom = false
	cyl.radial_segments = 20
	cyl.rings = 1
	for i: int in 2:
		var mi := MeshInstance3D.new()
		mi.mesh = cyl
		var s2 := Shader.new()
		s2.code = BEAM_SHADER
		var mm := ShaderMaterial.new()
		mm.shader = s2
		mi.material_override = mm
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		add_child(mi)
		_pillars.append({"mi": mi, "mat": mm, "born": -99.0, "dur": 0.5, "col": GOLD})
	_build_drone()
	_build_balloons()
	_build_heli()
	_build_ufo()
	for i: int in 7:
		var sm := MeshInstance3D.new()
		var b := BoxMesh.new()
		b.size = Vector3(0.05, 0.05, 1.0)
		sm.mesh = b
		sm.material_override = _solid(Color8(0xf4, 0xf4, 0xf2) if i < 6 else Color8(0x2a, 0x2f, 0x38))
		sm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		sm.visible = false
		add_child(sm)
		_strings.append(sm)


const STRIP_SHADER: String = """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;
uniform float alpha = 0.0;
uniform float t = 0.0;
void fragment() {
	float v = UV.y * 6.0 + t * 5.0;
	float chev = smoothstep(0.0, 0.15, fract(v + abs(UV.x - 0.5) * 2.0)) * (1.0 - smoothstep(0.35, 0.5, fract(v + abs(UV.x - 0.5) * 2.0)));
	float edge = max(smoothstep(0.08, 0.0, UV.x) + smoothstep(0.92, 1.0, UV.x), smoothstep(0.05, 0.0, UV.y) + smoothstep(0.95, 1.0, UV.y));
	float blink = 0.55 + 0.45 * step(0.5, fract(t * 6.0));
	ALBEDO = vec3(1.0, 0.45, 0.08) * (0.5 + 1.1 * chev + 2.2 * edge) * alpha * blink;
}
"""

const BEAM_SHADER: String = """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;
uniform vec4 col : source_color = vec4(1.0, 0.85, 0.3, 1.0);
uniform float alpha = 0.0;
uniform float t = 0.0;
void fragment() {
	float up = 1.0 - UV.y;                                   // 0 bottom, 1 top
	float bands = 0.7 + 0.3 * sin(up * 40.0 - t * 18.0);
	float rim = pow(1.0 - abs(dot(NORMAL, VIEW)), 1.5);       // brighter at the silhouette
	float a = (1.0 - smoothstep(0.55, 1.0, up)) * (0.35 + 0.65 * rim) * bands * alpha;
	ALBEDO = col.rgb * a * 1.6;
}
"""


# ───────────────────────────── builders

func _mm(mesh: Mesh, mat: Material, n: int) -> MultiMeshInstance3D:
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


func _add_mat(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.albedo_color = col
	return m


func _solid(col: Color, emissive: float = 0.0, alpha: float = 1.0, metal: float = 0.0) -> StandardMaterial3D:
	var key: String = "%s/%.2f/%.2f/%.2f" % [col.to_html(), emissive, alpha, metal]
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(col, alpha)
	m.roughness = 0.35 if metal > 0.0 else 0.6
	m.metallic = metal
	if alpha < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
	if emissive > 0.0:
		m.emission_enabled = true
		m.emission = col
		m.emission_energy_multiplier = emissive
	_mats[key] = m
	return m


func _part(parent: Node3D, mesh: Mesh, mat: Material, pos: Vector3, rot: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	parent.add_child(mi)
	return mi


func _bx(x: float, y: float, z: float) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = Vector3(x, y, z)
	return b


func _cy(top: float, bottom: float, h: float, seg: int = 16) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = top
	c.bottom_radius = bottom
	c.height = h
	c.radial_segments = seg
	c.rings = 1
	return c


func _sp(r: float, h: float, hemi: bool = false) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = r
	s.height = h
	s.radial_segments = 14
	s.rings = 8
	s.is_hemisphere = hemi
	return s


## Police drone (≈ 2.4 m across at scale 1.35): white body, blue canopy, crossed arms, 4 spinning rotors, red/blue
## blinking lights, camera pod.
func _build_drone() -> void:
	_drone = Node3D.new()
	_drone.visible = false
	add_child(_drone)
	var white: StandardMaterial3D = _solid(Color8(0xf4, 0xf4, 0xf2))
	var dark: StandardMaterial3D = _solid(Color8(0x2a, 0x2f, 0x38))
	_part(_drone, _bx(0.9, 0.3, 1.0), white, Vector3.ZERO)
	_part(_drone, _bx(0.6, 0.16, 0.6), _solid(Color8(0x2f, 0x6f, 0xd6)), Vector3(0, 0.22, 0))
	_part(_drone, _bx(0.3, 0.22, 0.26), dark, Vector3(0, -0.24, -0.36))
	for k: int in 2:
		_part(_drone, _bx(2.0, 0.09, 0.14), dark, Vector3.ZERO, Vector3(0, PI * 0.25 + PI * 0.5 * float(k), 0))
	var blur: StandardMaterial3D = _solid(Color(0.9, 0.92, 0.95), 0.0, 0.32)
	for i: int in 4:
		var a: float = PI * 0.25 + PI * 0.5 * float(i)
		var p := Vector3(cos(a) * 0.95, 0.12, sin(a) * 0.95)
		_part(_drone, _cy(0.1, 0.1, 0.16, 8), dark, p - Vector3(0, 0.05, 0))
		var r := Node3D.new()
		r.position = p + Vector3(0, 0.06, 0)
		_drone.add_child(r)
		_part(r, _cy(0.5, 0.5, 0.02, 18), blur, Vector3.ZERO)
		_part(r, _bx(0.95, 0.025, 0.09), dark, Vector3.ZERO)
		_drone_rotors.append(r)
	for i: int in 2:
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = Color8(0xff, 0x3b, 0x30) if i == 0 else Color8(0x3a, 0x8b, 0xff)
		_drone_leds.append(m)
		_part(_drone, _bx(0.18, 0.12, 0.12), m, Vector3(-0.3 if i == 0 else 0.3, 0.16, -0.5))
	_drone.scale = Vector3.ONE * 1.35


func _build_balloons() -> void:
	_balloons = Node3D.new()
	_balloons.visible = false
	_balloons.scale = Vector3.ONE * 1.3
	add_child(_balloons)
	var offs: Array[Vector3] = [Vector3(-0.75, 0.2, 0.1), Vector3(0.7, 0.35, -0.2), Vector3(0.0, 0.85, 0.45),
		Vector3(-0.35, 1.25, -0.4), Vector3(0.45, 1.45, 0.35), Vector3(0.05, 0.05, -0.75)]
	for i: int in 6:
		var b := Node3D.new()
		b.position = offs[i] + Vector3(0, 2.2, 0)
		_balloons.add_child(b)
		var col: Color = BALLOON_COLS[i]
		var m := StandardMaterial3D.new()
		m.albedo_color = col
		m.roughness = 0.25
		m.metallic_specular = 0.8
		m.rim_enabled = true
		m.rim = 0.4
		var body := _part(b, _sp(0.62, 1.4), m, Vector3.ZERO)
		body.scale = Vector3(1, 1.0, 1)
		_part(b, _cy(0.02, 0.1, 0.16, 8), m, Vector3(0, -0.74, 0))
		var hl := _part(b, _sp(0.15, 0.3), _solid(Color.WHITE, 0.6, 0.7), Vector3(-0.22, 0.28, -0.42))
		hl.scale = Vector3(1, 1.4, 0.5)
		_balloon_nodes.append(b)


## Police helicopter (cartoon): white cabin with a blue stripe, glass nose, tail boom + fin + tail rotor, two-blade
## main rotor with a blur disc, skids, belly hook.
func _build_heli() -> void:
	_heli = Node3D.new()
	_heli.visible = false
	add_child(_heli)
	var white: StandardMaterial3D = _solid(Color8(0xf4, 0xf4, 0xf2))
	var blue: StandardMaterial3D = _solid(Color8(0x2f, 0x6f, 0xd6))
	var dark: StandardMaterial3D = _solid(Color8(0x2a, 0x2f, 0x38))
	_part(_heli, _bx(1.7, 1.5, 2.7), white, Vector3.ZERO)
	_part(_heli, _bx(1.74, 0.32, 2.74), blue, Vector3(0, -0.1, 0))
	_part(_heli, _bx(1.5, 0.95, 0.9), _solid(Color8(0x25, 0x3a, 0x5c), 0.0, 1.0, 0.4), Vector3(0, 0.15, -1.45))
	_part(_heli, _bx(0.4, 0.4, 3.4), white, Vector3(0, 0.35, 2.9))
	_part(_heli, _bx(0.1, 1.0, 0.7), blue, Vector3(0, 0.85, 4.4))
	_heli_tail = Node3D.new()
	_heli_tail.position = Vector3(0.18, 0.75, 4.45)
	_heli.add_child(_heli_tail)
	_part(_heli_tail, _bx(0.04, 1.3, 0.14), dark, Vector3.ZERO)
	_part(_heli, _bx(0.25, 0.4, 0.25), dark, Vector3(0, 0.95, 0))
	_heli_rotor = Node3D.new()
	_heli_rotor.position = Vector3(0, 1.2, 0)
	_heli.add_child(_heli_rotor)
	_part(_heli_rotor, _bx(7.6, 0.06, 0.32), dark, Vector3.ZERO)
	_part(_heli_rotor, _bx(0.32, 0.06, 7.6), dark, Vector3.ZERO)
	_part(_heli_rotor, _cy(3.8, 3.8, 0.02, 28), _solid(Color(0.85, 0.88, 0.92), 0.0, 0.18), Vector3.ZERO)
	for sx: float in [-0.75, 0.75]:
		_part(_heli, _bx(0.12, 0.12, 3.0), dark, Vector3(sx, -1.15, 0))
		_part(_heli, _bx(0.08, 0.45, 0.08), dark, Vector3(sx, -0.9, -0.7))
		_part(_heli, _bx(0.08, 0.45, 0.08), dark, Vector3(sx, -0.9, 0.7))
	_part(_heli, _bx(0.3, 0.3, 0.3), _solid(Color8(0xff, 0xd2, 0x3f)), Vector3(0, -0.95, 0.2))
	var red := StandardMaterial3D.new()
	red.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	red.albedo_color = Color8(0xff, 0x3b, 0x30)
	_part(_heli, _bx(0.2, 0.15, 0.2), red, Vector3(0, 0.82, 1.0))
	_heli.scale = Vector3.ONE * 1.15


func _build_ufo() -> void:
	_ufo = Node3D.new()
	_ufo.visible = false
	add_child(_ufo)
	var silver: StandardMaterial3D = _solid(Color8(0xc8, 0xd0, 0xdc), 0.0, 1.0, 0.75)
	_part(_ufo, _cy(3.2, 1.7, 0.55, 28), silver, Vector3.ZERO)
	_part(_ufo, _cy(1.9, 3.2, 0.4, 28), silver, Vector3(0, 0.47, 0))
	var glass := StandardMaterial3D.new()
	glass.albedo_color = Color(0.45, 1.0, 0.85, 0.55)
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass.emission_enabled = true
	glass.emission = Color8(0x3c, 0xe0, 0xb0)
	glass.emission_energy_multiplier = 0.7
	glass.roughness = 0.1
	_part(_ufo, _sp(1.25, 1.25, true), glass, Vector3(0, 0.66, 0))
	_part(_ufo, _cy(0.9, 1.1, 0.12, 20), _solid(Color8(0x2a, 0x2f, 0x38)), Vector3(0, -0.33, 0))
	for i: int in 2:
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = Color8(0xff, 0xd2, 0x3f) if i == 0 else Color8(0x14, 0xd3, 0xe0)
		_ufo_lights.append(m)
	for i: int in 10:
		var a: float = TAU * float(i) / 10.0
		_part(_ufo, _sp(0.17, 0.34), _ufo_lights[i % 2], Vector3(cos(a) * 2.75, 0.18, sin(a) * 2.75))
	_ufo_beam = MeshInstance3D.new()
	_ufo_beam.mesh = _cy(1.0, 2.3, 1.0, 22)
	(_ufo_beam.mesh as CylinderMesh).cap_top = false
	(_ufo_beam.mesh as CylinderMesh).cap_bottom = false
	var s2 := Shader.new()
	s2.code = BEAM_SHADER
	_ufo_beam_mat = ShaderMaterial.new()
	_ufo_beam_mat.shader = s2
	_ufo_beam_mat.set_shader_parameter(&"col", Color(0.45, 1.0, 0.75, 1.0))
	_ufo_beam.material_override = _ufo_beam_mat
	_ufo_beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ufo_beam.visible = false
	add_child(_ufo_beam)


## Flat crescent (opening toward +Z, bulging toward −Z), unit outer radius, ±62°; thick bright front edge.
func _crescent_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n: int = 18
	var a0: float = -deg_to_rad(62.0)
	var a1: float = deg_to_rad(62.0)
	for i: int in n:
		var u0: float = lerpf(a0, a1, float(i) / float(n))
		var u1: float = lerpf(a0, a1, float(i + 1) / float(n))
		var fade0: float = 1.0 - pow(absf(float(i) / float(n) * 2.0 - 1.0), 3.0)
		var fade1: float = 1.0 - pow(absf(float(i + 1) / float(n) * 2.0 - 1.0), 3.0)
		var o0 := Vector3(sin(u0), 0, -cos(u0))
		var o1 := Vector3(sin(u1), 0, -cos(u1))
		for tri: Array in [[o0 * 0.7, o1 * 0.7, o1, 0.0, 0.0, 1.0], [o0 * 0.7, o1, o0, 0.0, 1.0, 1.0]]:
			var cs: Array[float] = [tri[3], tri[4], tri[5]]
			var ps: Array[Vector3] = [tri[0], tri[1], tri[2]]
			for k: int in 3:
				var f: float = fade0 if ps[k].is_equal_approx(o0) or ps[k].is_equal_approx(o0 * 0.7) else fade1
				st.set_color(Color(1, 1, 1, (0.25 + 0.75 * cs[k]) * f))
				st.add_vertex(ps[k])
	return st.commit()


func _chevron_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var pts: Array[Vector3] = [Vector3(-0.32, 0, -1.55), Vector3(0, 0, -1.12), Vector3(0.32, 0, -1.55),
		Vector3(0, 0, -1.3)]
	for idx: int in [0, 1, 3, 3, 1, 2]:
		st.set_color(Color.WHITE)
		st.add_vertex(pts[idx])
	return st.commit()


func _billboard(tex: Texture2D, additive: bool, prio: int) -> Dictionary:
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(1, 1)
	mi.mesh = q
	var m := StandardMaterial3D.new()
	m.albedo_texture = tex
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.billboard_keep_scale = true
	m.no_depth_test = true
	m.render_priority = prio
	if additive:
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visible = false
	add_child(mi)
	return {"mi": mi, "mat": m, "born": -99.0, "dur": 0.2, "size": 1.0}


## 12-point comic starburst (128²): white core, gold ring, orange spikes, dark outline.
func _burst_texture() -> ImageTexture:
	var n: int = 128
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var c := Vector2(63.5, 63.5)
	for y: int in n:
		for x: int in n:
			var d: Vector2 = Vector2(x, y) - c
			var a: float = atan2(d.y, d.x)
			var r: float = d.length() / 63.5
			var spike: float = 0.62 + 0.36 * pow(absf(cos(a * 6.0)), 6.0) + 0.06 * cos(a * 18.0)
			var col := Color(0, 0, 0, 0)
			if r < spike + 0.05:
				col = Color8(0x17, 0x20, 0x2b)
			if r < spike:
				col = Color8(0xff, 0x7a, 0x1a)
			if r < spike * 0.78:
				col = Color8(0xff, 0xd2, 0x3f)
			if r < spike * 0.45:
				col = Color(1, 1, 0.92)
			img.set_pixel(x, y, col)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


## 4-point sparkle (64²) with a soft glow (additive).
func _star_texture() -> ImageTexture:
	var n: int = 64
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y: int in n:
		for x: int in n:
			var d := Vector2(float(x) - 31.5, float(y) - 31.5) / 31.5
			var cross: float = maxf(pow(maxf(0.0, 1.0 - absf(d.x) * 7.0), 1.5) * (1.0 - absf(d.y)),
				pow(maxf(0.0, 1.0 - absf(d.y) * 7.0), 1.5) * (1.0 - absf(d.x)))
			var glow: float = pow(maxf(0.0, 1.0 - d.length()), 2.5)
			var a: float = clampf(cross * 1.3 + glow * 0.9, 0.0, 1.0)
			img.set_pixel(x, y, Color(1, 0.97, 0.8, a))
	return ImageTexture.create_from_image(img)


## Decal textures (deterministic: a local RNG with a fixed seed per kind).
func _make_decal_tex(kind: String) -> Array:
	var r := RandomNumberGenerator.new()
	r.seed = hash(kind)
	var n: int = 128
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var emi: Image = null
	match kind:
		"tack_strip":  # scattered caltrops (dark crosses) with orange glints, dashed orange edge marks
			for i: int in 70:
				var p := Vector2i(r.randi_range(6, n - 7), r.randi_range(4, n - 5))
				for k: int in range(-3, 4):
					_px(img, p + Vector2i(k, 0), Color(0.08, 0.08, 0.1, 0.95))
					_px(img, p + Vector2i(0, k), Color(0.08, 0.08, 0.1, 0.95))
				_px(img, p + Vector2i(1, -1), Color(1.0, 0.7, 0.3, 1.0))
			for y: int in range(0, n, 10):
				for x: int in [1, 2, n - 3, n - 2]:
					for k: int in 5:
						_px(img, Vector2i(x, y + k), Color(1.0, 0.48, 0.1, 0.9))
		"skid":  # one tyre streak: dark band with tread noise, fading at both ends
			for y: int in n:
				var fade: float = sin(PI * float(y) / float(n - 1))
				for x: int in range(40, 88):
					var e: float = 1.0 - pow(absf(float(x) - 63.5) / 24.0, 4.0)
					var tread: float = 0.75 + 0.25 * r.randf()
					img.set_pixel(x, y, Color(0.04, 0.04, 0.05, 0.85 * e * fade * tread))
		"scorch", "crack":
			var c := Vector2(63.5, 63.5)
			for y: int in n:
				for x: int in n:
					var d: Vector2 = Vector2(x, y) - c
					var a: float = atan2(d.y, d.x)
					var rr: float = d.length() / 63.5
					var edge: float = 0.78 + 0.14 * sin(a * 7.0 + 1.3) + 0.08 * sin(a * 13.0)
					if kind == "scorch":
						var k: float = clampf(1.0 - rr / edge, 0.0, 1.0)
						img.set_pixel(x, y, Color(0.03, 0.025, 0.02, pow(k, 0.6) * 0.92))
					elif rr < 0.18:
						img.set_pixel(x, y, Color(0.05, 0.05, 0.06, 0.5 * (1.0 - rr / 0.18)))
			if kind == "crack":  # 9 jagged cracks from the centre
				for i: int in 9:
					var a2: float = TAU * float(i) / 9.0 + r.randf_range(-0.2, 0.2)
					var p := c
					for st: int in 22:
						a2 += r.randf_range(-0.35, 0.35)
						p += Vector2(cos(a2), sin(a2)) * 2.6
						for o: Vector2i in [Vector2i.ZERO, Vector2i(1, 0), Vector2i(0, 1)]:
							_px(img, Vector2i(p) + o, Color(0.02, 0.02, 0.03, 0.95 * (1.0 - float(st) / 24.0)))
			else:  # embers: emission dots near the centre
				emi = Image.create(n, n, false, Image.FORMAT_RGBA8)
				emi.fill(Color(0, 0, 0, 1))
				for i: int in 40:
					var q := c + Vector2(r.randf_range(-1, 1), r.randf_range(-1, 1)) * 30.0
					for o: Vector2i in [Vector2i.ZERO, Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
						_px(emi, Vector2i(q) + o, Color(1.0, 0.45, 0.1, 1))
	img.generate_mipmaps()
	var out: Array = [ImageTexture.create_from_image(img), null]
	if emi != null:
		out[1] = ImageTexture.create_from_image(emi)
	return out


func _px(img: Image, p: Vector2i, c: Color) -> void:
	if p.x >= 0 and p.y >= 0 and p.x < img.get_width() and p.y < img.get_height():
		img.set_pixelv(p, c)


# ───────────────────────────── primitives

func _w(s: float, x: float, y: float = 0.0) -> Vector3:
	return fx._w(s, x, y) if fx != null else Vector3(x, y, -s)


func _now() -> float:
	return fx.now if fx != null else 0.0


## n travelling sound arcs from → to (world), widths w0 → w1 m, `gap` s apart, each `dur` s (t1 shockwave, jump).
func arc_wave(from: Vector3, to: Vector3, n: int = 3, col: Color = WAVE_COL, w0: float = 2.5, w1: float = 7.0,
		dur: float = 0.18, gap: float = 0.06) -> void:
	var dir: Vector3 = to - from
	dir.y = 0.0
	var yaw: float = atan2(-dir.x, -dir.z) if dir.length() > 0.01 else 0.0
	for i: int in n:
		var best: Dictionary = _arcs[0]
		for a: Dictionary in _arcs:
			if float(a["born"]) < float(best["born"]):
				best = a
		best["born"] = _now() + gap * float(i)
		best["dur"] = dur
		best["p0"] = from
		best["p1"] = to
		best["w0"] = w0 * (1.0 + 0.15 * float(i))
		best["w1"] = w1 * (1.0 + 0.12 * float(i))
		best["col"] = col
		best["yaw"] = yaw


## Caltrop carpet: n tacks thrown from the player's roof (3 volleys) onto `lanes` between s0 and s1, landing in
## `groups` waves at t_land0 + g·gap (FX time from now). Shows the blinking telegraph strip until the first landing.
func carpet(lanes: PackedInt32Array, s0: float, s1: float, n: int = 12, groups: int = 4, t_land0: float = 0.4,
		gap: float = 0.05) -> void:
	var p: Dictionary = (_state.get("player", {}) as Dictionary)
	var roof: Vector3 = _w(float(p.get("s", s1 + 8.0)), float(p.get("x", 0.0)), 1.9)
	var lo: int = 99
	var hi: int = -99
	for l: int in lanes:
		lo = mini(lo, l)
		hi = maxi(hi, l)
	if lanes.is_empty():
		lo = 0
		hi = 2
	var x0: float = RoadGraph.lane_x(float(lo)) - RoadGraph.LANE_W * 0.45
	var x1: float = RoadGraph.lane_x(float(hi)) + RoadGraph.LANE_W * 0.45
	var t: float = _now()
	_tacks.clear()
	for i: int in n:
		var g: int = i % groups
		var volley: int = i / groups
		var fx_x: float = lerpf(x0, x1, (float(i % 3) + fx.rng.randf_range(0.15, 0.85)) / 3.0)
		var fx_s: float = lerpf(s0, s1, (float(i) + fx.rng.randf_range(0.0, 0.9)) / float(n))
		var t0: float = t + 0.07 * float(volley)
		var t1: float = t + t_land0 + gap * float(g)
		_tacks.append({"p0": roof, "p1": _w(fx_s, fx_x, 0.12), "t0": t0, "t1": maxf(t0 + 0.12, t1), "h": 5.5 + fx.rng.randf() * 2.5,
			"spin": fx.rng.randf_range(8.0, 14.0), "landed": false, "group": g})
	for v: int in 3:
		fx._after(0.07 * float(v), func() -> void:
			fx.sparks(roof + Vector3(0, 0.3, 0), 8, 7.0, Color8(0xff, 0xe6, 0x80), 0.16)
			fx.light(roof, 2.5, 0.12, Color8(0xff, 0xc0, 0x60)))
	# telegraph strip over the target zone
	var xf: Transform3D = road.world((s0 + s1) * 0.5, (x0 + x1) * 0.5) if road != null else Transform3D(Basis(), Vector3((x0 + x1) * 0.5, 0, -(s0 + s1) * 0.5))
	xf.origin.y += 0.06
	xf.basis = xf.basis.scaled(Vector3(x1 - x0, 1.0, absf(s1 - s0)))
	_strip.transform = xf
	_strip_born = t
	_strip_until = t + t_land0 + 0.02


## Lands every tack of group g now (the sim's skill_hit idx g may come a tick before the planned time).
func land_group(g: int) -> void:
	for tk: Dictionary in _tacks:
		if int(tk["group"]) == g and float(tk["t1"]) > _now():
			tk["t1"] = maxf(_now(), float(tk["t0"]) + 0.05)


## Police drone: flies from → above `target_id` in `t` s, hovers over it, drops `n` bomblets from t − 0.12 s every gap.
func drone_dive(from: Vector3, target_id: int, t: float = 0.7, n: int = 6, gap: float = 0.05) -> void:
	var t0: float = _now()
	_drone_on = {"born": t0, "arrive": t0 + t, "p0": from, "target": target_id, "leave_at": t0 + t + gap * float(n) + 0.3,
		"dest": from + Vector3(0, 3.0, -12.0)}
	_drone.visible = true
	_bombs.clear()
	for i: int in n:
		_bombs.append({"t0": t0 + t - 0.13 + gap * float(i), "t1": t0 + t + gap * float(i), "target": target_id,
			"off": (float(i) / float(maxi(1, n - 1)) - 0.5) * 3.4})


## Additive light pillar (t5 impact) at pos, h m tall, dur s.
func beam(pos: Vector3, h: float = 16.0, dur: float = 0.55, col: Color = GOLD, r: float = 2.2) -> void:
	var best: Dictionary = _pillars[0]
	for p: Dictionary in _pillars:
		if float(p["born"]) < float(best["born"]):
			best = p
	best["born"] = _now()
	best["dur"] = dur
	best["r"] = r
	var mi: MeshInstance3D = best["mi"]
	mi.position = pos + Vector3(0, h * 0.5, 0)
	mi.scale = Vector3(r, h, r)
	(best["mat"] as ShaderMaterial).set_shader_parameter(&"col", col)


## ★ twinkle (the car is gone): a sparkle that pops and turns, plus a few glints.
func star_twinkle(pos: Vector3, size: float = 4.0) -> void:
	var best: Dictionary = _stars[0]
	for s: Dictionary in _stars:
		if float(s["born"]) < float(best["born"]):
			best = s
	best["born"] = _now()
	best["dur"] = 0.75
	best["size"] = size
	(best["mi"] as MeshInstance3D).position = pos
	fx.sparks(pos, 10, 6.0, Color8(0xff, 0xf3, 0xb8), 0.14)


func dust_ring(pos: Vector3, r: float = 8.0) -> void:
	fx.ring(pos, r, Color(0.85, 0.82, 0.75, 0.85), 0.45, 1.0)
	for i: int in 14:
		var a: float = TAU * float(i) / 14.0
		var d := Vector3(cos(a), 0, sin(a))
		fx._spawn(2, {"p": pos + d * 1.2 + Vector3(0, 0.3, 0), "v": d * fx.rng.randf_range(7.0, 10.0) + Vector3(0, 0.8, 0),
			"r": Vector3.ZERO, "w": Vector3.ZERO, "s0": 0.8, "s1": 2.2, "life": fx.rng.randf_range(0.6, 0.9), "c": DUST,
			"g": -0.4, "drag": 3.2, "bounce": 0.0, "shape": 2})


## Comic starburst billboard: pops in (back-out), holds, fades — the readable "쾅" of an impact.
func burst(pos: Vector3, size: float = 2.6, col: Color = Color.WHITE, dur: float = 0.24) -> void:
	var best: Dictionary = _bursts[0]
	for b: Dictionary in _bursts:
		if float(b["born"]) < float(best["born"]):
			best = b
	best["born"] = _now()
	best["dur"] = dur
	best["size"] = size
	best["rot"] = fx.rng.randf_range(-0.4, 0.4)
	(best["mat"] as StandardMaterial3D).albedo_color = col
	(best["mi"] as MeshInstance3D).position = pos


## Road decal from the pool of 8 (oldest reused): kind = tack_strip | skid | scorch | crack, size (x, depth, z) m.
func decal(pos: Vector3, kind: String, size: Vector3 = Vector3(4, 1, 4), life: float = 3.0, yaw: float = 0.0) -> void:
	var best: Dictionary = _decals[0]
	for d: Dictionary in _decals:
		if not (d["node"] as Decal).visible:
			best = d
			break
		if float(d["born"]) < float(best["born"]):
			best = d
	var dn: Decal = best["node"]
	var tex: Array = _decal_tex.get(kind, _decal_tex["scorch"])
	dn.texture_albedo = tex[0]
	dn.texture_emission = tex[1]
	dn.emission_energy = 2.0 if tex[1] != null else 0.0
	dn.size = size
	dn.position = pos + Vector3(0, size.y * 0.25, 0)
	dn.rotation = Vector3(0, yaw, 0)
	dn.modulate = Color(1, 1, 1, 1)
	dn.visible = true
	best["born"] = _now()
	best["life"] = life


# ───────────────────────────── events

func _villain(id: int) -> Dictionary:
	for v: Variant in _state.get("villains", []):
		if int((v as Dictionary).get("id", -1)) == id:
			return v
	var vs: Array = _state.get("villains", [])
	return vs[0] if not vs.is_empty() and id < 0 else {}


func _vspeed(id: int) -> float:
	var r: Variant = _vel.get(id)
	if r is Array:
		return float((r as Array)[2])
	return float((_state.get("player", {}) as Dictionary).get("v", 8.0))


func on_event(e: Dictionary, st: Dictionary) -> void:
	_state = st
	match str(e.get("type", "")):
		"skill_start":
			_on_start(e)
		"skill_hit":
			_on_hit(e)
		"skill_end":
			match str(e.get("id", "")):
				"t5_finish":
					_marker_on = {}
				"t3_carpet":
					_strip_until = minf(_strip_until, _now())
		"finisher":
			start_finish(str(e.get("id", "rocket")), int(e.get("target_id", -1)))
		"kill":
			if bool(e.get("last", true)) and not str(e.get("finish", "")).is_empty():
				start_finish(str(e.get("finish", "rocket")), int(e.get("id", -1)))
		"gone":
			_on_gone(e)


func _on_start(e: Dictionary) -> void:
	var id: String = str(e.get("id", ""))
	var p: Dictionary = _state.get("player", {})
	var ps: float = float(p.get("s", 0.0))
	var px: float = float(p.get("x", 0.0))
	var tid: int = int(e.get("target_id", -1))
	var v: Dictionary = _villain(tid)
	match id:
		"t1_wave":
			var vs: float = float(v.get("s", ps - 12.0)) + float(v.get("len", 4.6)) * 0.5
			var from: Vector3 = _w(ps - 2.4, px, 0.55)
			var to: Vector3 = _w(vs + _vspeed(tid) * 0.12, float(v.get("x", px)), 0.55)
			arc_wave(from, to, 3, WAVE_COL, 3.4, 8.5, 0.24, 0.05)
			fx.ring(from, 4.0, Color(1.0, 0.85, 0.3, 0.9), 0.25, 0.6)
			for i: int in 12:
				var d: Vector3 = (to - from).normalized().rotated(Vector3.UP, fx.rng.randf_range(-0.5, 0.5))
				fx._spawn(1, {"p": from + Vector3(0, fx.rng.randf_range(0.0, 0.6), 0), "v": d * fx.rng.randf_range(18.0, 30.0),
					"r": Vector3.ZERO, "w": Vector3.ZERO, "s0": 0.16, "s1": 0.0, "life": 0.18, "c": WAVE_COL, "g": 0.0, "drag": 2.0,
					"bounce": 0.0, "shape": 1})
		"t1_horn":
			var f0: Vector3 = _w(ps + 2.6, px, 0.6)
			var f1: Vector3 = _w(ps + 22.0, (px + RoadGraph.SHOULDER_X) * 0.5, 0.6)
			arc_wave(f0, f1, 3, Color8(0xff, 0xb4, 0x3a), 3.0, 9.0, 0.3, 0.06)
		"t3_carpet":
			var key_cfg: Dictionary = SkillCues.cfg().get("t3", {}) if SkillCues.cfg().get("t3") is Dictionary else {}
			var delay: float = float(key_cfg.get("delay", 0.4))
			var gap: float = float(key_cfg.get("hitGap", 0.05))
			var hits: int = int(key_cfg.get("hits", 4))
			var strip: float = float(key_cfg.get("strip", 12.0))
			var sv: float = float(v.get("s", ps - 12.0))
			var sc: float = sv + float(v.get("len", 4.6)) * 0.5 + _vspeed(tid) * (delay + gap * float(hits) * 0.5) - 1.0
			var lanes: PackedInt32Array = e.get("lanes", PackedInt32Array()) if e.get("lanes") is PackedInt32Array else PackedInt32Array()
			if lanes.is_empty():
				var vl: int = int(v.get("lane", 1))
				lanes = PackedInt32Array([maxi(0, vl - 1), vl, mini(3, vl + 1)])
			carpet(lanes, sc - strip * 0.5, sc + strip * 0.5, int(key_cfg.get("tacks", 12)), hits, delay, gap)
		"t5_finish":
			_marker_on = {"target": tid, "born": _now(), "dur": float(((SkillCues.cfg().get("t5", {}) as Dictionary) if SkillCues.cfg().get("t5") is Dictionary else {}).get("delay", 0.35))}
			_marker.visible = true
			var c: Vector3 = _w(float(v.get("s", ps - 12.0)), float(v.get("x", px)), 1.0)
			for i: int in 26:  # sparks sucked in from a 7 m ring, arriving on the impact tick
				var a: float = TAU * float(i) / 26.0 + fx.rng.randf() * 0.2
				var start: Vector3 = c + Vector3(cos(a) * 7.5, fx.rng.randf_range(-0.6, 2.4), sin(a) * 7.5)
				var life: float = float(_marker_on["dur"]) * fx.rng.randf_range(0.8, 1.0)
				fx._spawn(1, {"p": start, "v": (c - start) / life, "r": Vector3.ZERO, "w": Vector3.ZERO, "s0": 0.22, "s1": 0.0,
					"life": life, "c": GOLD.lerp(Color.WHITE, fx.rng.randf() * 0.5), "g": 0.0, "drag": 0.0, "bounce": 0.0, "shape": 1})
			fx.light(c, 3.0, 0.4, Color8(0xff, 0xc8, 0x40))
			for i: int in 10:  # gold sparks rising off the player's car (the button's gold)
				fx._spawn(1, {"p": _w(ps, px, 1.0) + Vector3(fx.rng.randf_range(-1, 1), 0, fx.rng.randf_range(-2, 2)),
					"v": Vector3(0, fx.rng.randf_range(6.0, 10.0), 0), "r": Vector3.ZERO, "w": Vector3.ZERO, "s0": 0.18, "s1": 0.0,
					"life": 0.35, "c": GOLD, "g": 0.0, "drag": 1.5, "bounce": 0.0, "shape": 1})
		"mv_jump":
			var wp: Vector3 = _w(ps, px, 0.2)
			fx.smoke(wp, 6, DUST, 0.9)
			fx.sparks(wp, 6, 5.0, Color8(0xff, 0xf3, 0xb8), 0.12)
		"mv_drone":
			var dcfg: Dictionary = SkillCues._item("mv_drone")
			drone_dive(_w(ps, px, 2.4), tid, float(dcfg.get("delay", 0.7)), int(dcfg.get("bomblets", 6)), float(dcfg.get("bombGap", 0.05)))
			fx.sparks(_w(ps, px, 2.2), 8, 5.0, Color8(0x9a, 0xc8, 0xff), 0.12)


func _on_hit(e: Dictionary) -> void:
	var id: String = str(e.get("id", ""))
	var idx: int = int(e.get("idx", 0))
	var n: int = int(e.get("n", 1))
	var tid: int = int(e.get("target_id", -1))
	var v: Dictionary = _villain(tid)
	var hs: float = float(e.get("s", v.get("s", 0.0)))
	var hx: float = float(e.get("x", v.get("x", 0.0)))
	var vlen: float = float(v.get("len", 4.6))
	var vcol: Color = fx._vcol(v)
	var popped: bool = int(e.get("popped", 0)) > 0
	var killed: bool = bool(e.get("killed", false))
	match id:
		"t1_wave":
			var bump: Vector3 = _w(float(v.get("s", hs)) + vlen * 0.5, float(v.get("x", hx)), 0.8)
			fx.sparks(bump, 16, 11.0, WAVE_COL, 0.18)
			fx.smoke(_w(float(v.get("s", hs)) - vlen * 0.5, float(v.get("x", hx)), 0.4), 6, Color(0.3, 0.3, 0.33, 0.7), 0.9)
			fx.ring(bump, 5.0, Color(1.0, 0.85, 0.3, 0.9), 0.3)
			burst(bump + Vector3(0, 1.2, 1.2), 2.6, Color(1, 1, 0.85))
			fx.ring(_w(float(v.get("s", hs)), float(v.get("x", hx)), 0.2), 7.5, Color(1.0, 0.82, 0.25, 0.85), 0.4, 1.5)
			fx.light(bump, 3.5, 0.18, Color8(0xff, 0xd0, 0x50))
		"t3_carpet":
			land_group(idx)
			var hp: Vector3 = _w(hs, hx, 0.4)
			if idx == 0:
				var lo: float = INF
				var hi: float = -INF
				var s0: float = INF
				var s1: float = -INF
				for tk: Dictionary in _tacks:
					var q: Vector2 = road.to_road(tk["p1"] as Vector3) if road != null else Vector2(-(tk["p1"] as Vector3).z, (tk["p1"] as Vector3).x)
					s0 = minf(s0, q.x)
					s1 = maxf(s1, q.x)
					lo = minf(lo, q.y)
					hi = maxf(hi, q.y)
				if is_finite(lo):
					decal(_w((s0 + s1) * 0.5, (lo + hi) * 0.5, 0.0), "tack_strip", Vector3(hi - lo + 1.2, 1.0, s1 - s0 + 1.5), 3.0)
				for k: int in 2:  # skid marks behind the villain's wheels (it brakes on the carpet)
					var wx: float = float(v.get("x", hx)) + (-0.75 if k == 0 else 0.75)
					decal(_w(float(v.get("s", hs)) - vlen * 0.2, wx, 0.0), "skid", Vector3(0.7, 0.8, 5.0), 2.6)
				burst(hp + Vector3(0, 1.8, 0), 3.2, Color(1, 0.92, 0.75))
				fx.ring(hp, 6.0, Color(1.0, 0.55, 0.15, 0.9), 0.35)
			else:
				fx.sparks(hp + Vector3(0, 0.4, 0), 6, 8.0, YELLOW_HOT, 0.16)
			if popped:
				fx.debris(hp, 12, RUBBER, 9.0, 0.3)
				fx.smoke(hp, 5, Color(0.25, 0.25, 0.27, 0.7), 1.0)
				fx.ring(hp, 5.0, Color(1, 1, 1, 0.7), 0.3)
				burst(hp + Vector3(0, 1.2, 0), 2.4, Color(1, 1, 1))
				fx._shake(0.5)
			else:
				fx._shake(0.25)
		"t5_finish":
			_marker_on = {}
			_marker.visible = false
			var c: Vector3 = _w(float(v.get("s", hs)), float(v.get("x", hx)), 0.2)
			beam(c, 14.0, 0.4, GOLD, 1.3)
			burst(c + Vector3(0, 2.4, 0), 3.0 if killed else 4.4, Color(1, 1, 0.9), 0.22 if killed else 0.3)
			fx.ring(c, 16.0, Color(1.0, 0.85, 0.3, 0.7), 0.55, 1.0)
			fx.sparks(c + Vector3(0, 1.0, 0), 34, 16.0, GOLD, 0.2)
			if not killed:  # the kill tick has its own explosion stack
				fx.explosion(c, 1.25, vcol)
				fx._after(0.16, func() -> void: fx.explosion(c + Vector3(1.0, 0.4, -0.8), 0.6, vcol))
			fx._shake(0.9)
		"mv_jump":
			var pl: Dictionary = _state.get("player", {})
			var lp: Vector3 = _w(float(pl.get("s", hs)), float(pl.get("x", hx)), 0.1)  # the hit s/x is the villain's
			dust_ring(lp, 8.0)
			fx.debris(lp + Vector3(0, 0.3, 0), 10, ASPHALT, 8.0, 0.28)
			fx.smoke(lp, 8, DUST, 1.1)
			decal(lp, "crack", Vector3(5.0, 1.0, 5.0), 2.5, fx.rng.randf() * TAU)
			burst(lp + Vector3(0, 1.6, 0), 3.0, Color(1, 0.96, 0.88))
			if not v.is_empty():
				arc_wave(lp + Vector3(0, 0.4, 0), _w(float(v["s"]) + vlen * 0.5, float(v["x"]), 0.5), 2, ORANGE, 3.0, 6.0, 0.16, 0.05)
			fx._shake(0.45)
		"mv_drone":
			if v.is_empty() or tid < 0:  # jam: the sim resolves on the cast tick (mini caught / obstacle cleared)
				var jp: Vector3 = _w(hs, hx, 0.6)
				var wait: float = 0.3
				if not _drone_on.is_empty():
					_drone_on["dest"] = jp
					_drone_on["arrive"] = _now() + wait
					_drone_on["leave_at"] = _now() + wait + 0.35
					_bombs = [{"t0": _now() + wait - 0.12, "t1": _now() + wait, "target": -1, "off": 0.0}]
				fx._after(wait, func() -> void:
					fx.explosion(jp, 0.5, ORANGE)
					burst(jp + Vector3(0, 1.4, 0), 2.4, Color(1, 0.95, 0.85))
					fx.ring(Vector3(jp.x, 0.1, jp.z), 5.0, Color(1.0, 0.6, 0.2, 0.9), 0.35))
				return
			var bp: Vector3 = _w(hs, hx, float(v.get("y", 0.0)) + 1.3)
			fx.explosion(bp, 0.5, vcol)
			fx.sparks(bp, 6, 9.0, YELLOW_HOT, 0.14)
			fx._shake(0.15)
			if idx >= n - 1:
				fx.ring(_w(hs, hx, 0.2), 6.0, Color(1.0, 0.6, 0.2, 0.9), 0.4)
				burst(bp + Vector3(0, 1.2, 0), 2.8, Color(1, 0.95, 0.85))


const YELLOW_HOT := Color8(0xff, 0xb4, 0x00)


func _on_gone(e: Dictionary) -> void:
	if _fin.is_empty() or str(_fin.get("id", "")) == "pullover":
		return
	var p: Vector3 = _fin.get("last_pos", Vector3.INF)
	if not p.is_finite():
		return
	star_twinkle(_in_frame(p), 4.5)
	_fin["gone_at"] = _now()


## A world point the camera sees: p itself when it projects inside the top 12 %..90 % band, else the point on the
## same screen column at 14 % from the top, at p's depth (the car left the frame upward: ★ where it went).
func _in_frame(p: Vector3) -> Vector3:
	var cam: Camera3D = fx.camera_rig if fx != null else null
	if cam == null or not cam.is_inside_tree() or cam.is_position_behind(p):
		return p
	var vp: Vector2 = cam.get_viewport().get_visible_rect().size
	var sp: Vector2 = cam.unproject_position(p)
	if sp.y >= vp.y * 0.12 and sp.y <= vp.y * 0.9 and sp.x >= 0.0 and sp.x <= vp.x:
		return p
	var depth: float = (p - cam.global_position).dot(-cam.global_transform.basis.z)
	return cam.project_position(Vector2(clampf(sp.x, vp.x * 0.15, vp.x * 0.85), vp.y * 0.14), maxf(4.0, depth))


## Finisher props on target_id (kill tick; the finisher event of the same tick re-labels it).
func start_finish(id: String, target_id: int) -> void:
	if not _fin.is_empty() and int(_fin["target"]) == target_id and not _fin.has("gone_at"):
		_fin["id"] = id
		_fin["beats"] = SkillCues.finish_beats(id)
		return
	_fin = {"id": id, "target": target_id, "born": _now(), "beats": SkillCues.finish_beats(id), "done": {},
		"last_pos": Vector3.INF, "trail_t": -1.0}


# ───────────────────────────── per frame

func sync(st: Dictionary) -> void:
	_state = st
	for v: Variant in st.get("villains", []):
		var d: Dictionary = v
		var id: int = int(d.get("id", -1))
		var s: float = float(d.get("s", 0.0))
		var prev: Variant = _vel.get(id)
		if prev is Array and _now() - float((prev as Array)[1]) > 0.05:
			var dt_: float = _now() - float((prev as Array)[1])
			var sp: float = (s - float((prev as Array)[0])) / dt_
			_vel[id] = [s, _now(), lerpf(float((prev as Array)[2]), sp, 0.5)]
		elif not prev is Array:
			_vel[id] = [s, _now(), float((st.get("player", {}) as Dictionary).get("v", 8.0))]
	_sync_finish()


func _sync_finish() -> void:
	if _fin.is_empty():
		_balloons.visible = false
		_heli.visible = false
		_ufo.visible = false
		_ufo_beam.visible = false
		for sm: MeshInstance3D in _strings:
			sm.visible = false
		return
	var v: Dictionary = _villain(int(_fin["target"]))
	var id: String = str(_fin["id"])
	var gone: bool = v.is_empty() or bool(v.get("gone", false))
	var t: float = float(v.get("death_t", 0.0)) if not gone else INF
	var beats: Dictionary = _fin["beats"]
	var done: Dictionary = _fin["done"]
	var car: Vector3 = _w(float(v.get("s", 0.0)), float(v.get("x", 0.0)), float(v.get("y", 0.0))) if not v.is_empty() else _fin["last_pos"]
	if not gone:
		_fin["last_pos"] = car + Vector3(0, 1.0, 0)
	elif not _fin.has("gone_at"):
		_fin["gone_at"] = _now()  # the state saw it gone before (or without) the gone event
	if gone and not _fin.has("prop_at_gone"):
		_fin["prop_at_gone"] = {"heli": _heli.position, "ufo": _ufo.position}
	var fresh: Callable = func(k: String) -> bool:
		if done.has(k) or t + 1e-6 < float(beats.get(k, INF)):
			return false
		done[k] = true
		return true
	match id:
		"rocket":
			if fresh.call("lift") and not gone:
				var g: Vector3 = Vector3(car.x, 0.1, car.z)
				fx.fireball(g + Vector3(0, 0.5, 0), 30, 1.6)
				fx.smoke(g, 10, Color(0.75, 0.74, 0.72, 0.7), 1.8)
				fx.ring(g, 9.0, Color(1.0, 0.6, 0.2, 0.9), 0.45)
				fx.light(g, 8.0, 0.4)
				decal(g, "scorch", Vector3(5.5, 1.0, 5.5), 3.5, fx.rng.randf() * TAU)
				burst(g + Vector3(0, 1.0, 0), 2.2, Color(1, 0.95, 0.8), 0.16)
				fx._shake(0.6)
				_fin["trail_t"] = _now()
			if done.has("lift") and not gone and _now() - float(_fin["trail_t"]) >= 0.035:
				_fin["trail_t"] = _now()
				var under: Vector3 = car + Vector3(0, -0.2, 0)
				fx.fireball(under, 2, 0.75)
				fx.smoke(under, 1, Color(0.82, 0.8, 0.78, 0.6), 1.3)
		"balloon":
			var lift: float = float(beats.get("lift", 0.5))
			if fresh.call("lift") and not gone:
				fx.confetti(car + Vector3(0, 2.0, 0), 30, 4.0, 7.0)
				_fin["pop_at"] = _now()
			if done.has("lift"):
				_balloons.visible = true
				var anchor: Vector3 = car + Vector3(0, 1.55, 0) if not gone else (_fin["last_pos"] as Vector3) + Vector3(0, 0.6 + (_now() - float(_fin.get("gone_at", _now()))) * 6.0, 0)
				var sway: float = sin(_now() * 3.1) * 0.12
				_balloons.position = anchor
				_balloons.rotation = Vector3(sway * 0.5, 0, sway)
				var age: float = _now() - float(_fin.get("pop_at", _now()))
				for i: int in _balloon_nodes.size():
					var k: float = clampf((age - 0.06 * float(i)) / 0.16, 0.0, 1.0)
					var sc: float = UiDraw.back_out(k, 3.0) if k > 0.0 else 0.001
					if gone:
						sc *= clampf(1.0 - (_now() - float(_fin.get("gone_at", _now()))) / 0.8, 0.0, 1.0)
					_balloon_nodes[i].scale = Vector3.ONE * maxf(0.001, sc)
					_balloon_nodes[i].position.y = 2.2 + [0.2, 0.35, 0.85, 1.25, 1.45, 0.05][i] + sin(_now() * 2.3 + float(i)) * 0.08
					if k > 0.0 and not done.has("b%d" % i):
						done["b%d" % i] = true
						fx.sparks(_balloon_nodes[i].global_position, 5, 4.0, BALLOON_COLS[i], 0.12)
					_string_between(i, anchor + Vector3(0, 0.1, 0), _balloon_nodes[i].global_position - Vector3(0, 0.8 * maxf(0.01, sc), 0), sc > 0.05)
			if gone and _now() - float(_fin.get("gone_at", _now())) > 0.8:
				_balloons.visible = false
				for sm: MeshInstance3D in _strings:
					sm.visible = false
		"heli":
			var settle: float = float(beats.get("settle", 0.3))
			var hook: float = float(beats.get("hook", 0.9))
			if t >= settle and not gone:
				_heli.visible = true
				var k: float = clampf((t - settle) / maxf(0.05, hook - settle), 0.0, 1.0)
				var e2: float = 1.0 - pow(1.0 - k, 3.0)
				var hover: Vector3 = car + Vector3(0, 6.2, 0.4)
				var high: Vector3 = car + Vector3(0, 19.0, 9.0)
				_heli.position = high.lerp(hover, e2) + Vector3(0, sin(_now() * 4.0) * 0.12, 0)
				_heli.rotation = Vector3(-0.12 * (1.0 - e2) + (0.1 if t > hook else 0.0), 0, sin(_now() * 2.0) * 0.04)
				if int(_now() * 12.0) != int((_now() - 0.016) * 12.0):
					fx.smoke(Vector3(car.x, 0.2, car.z) + Vector3(fx.rng.randf_range(-3, 3), 0, fx.rng.randf_range(-3, 3)), 1,
						Color(0.8, 0.8, 0.78, 0.45), 1.6)
			if fresh.call("hook") and not gone:
				fx.sparks(car + Vector3(0, 1.7, 0), 14, 6.0, YELLOW_HOT, 0.14)
				burst(car + Vector3(0, 2.6, 0), 2.2, Color(1, 1, 1))
				fx._shake(0.3)
			if done.has("hook") and not gone:
				_string_between(6, _heli.position + Vector3(0, -1.2, 0), car + Vector3(0, 1.6, 0), true)
			else:
				_strings[6].visible = false
			if gone:
				var ga: float = _now() - float(_fin.get("gone_at", _now()))
				_heli.visible = ga < 1.0 and done.has("hook")
				_heli.position = (_fin["prop_at_gone"]["heli"] as Vector3) + Vector3(0, 9.0, -14.0) * ga
				_heli.rotation.x = 0.25
		"ufo":
			var settle2: float = float(beats.get("settle", 0.15))
			var beam_t: float = float(beats.get("beam", 0.4))
			var tw: float = float(beats.get("twinkle", 1.8))
			if t >= settle2 or gone:
				_ufo.visible = true
				var fade_in: float = clampf((t - settle2) / 0.25, 0.0, 1.0) if not gone else 1.0
				var base: Vector3 = Vector3(car.x, maxf(car.y + 9.5, 11.0), car.z) if not gone else (_fin["last_pos"] as Vector3) + Vector3(0, 8.5, 0)
				_ufo.position = base + Vector3(0, sin(_now() * 3.0) * 0.25 + (1.0 - fade_in) * 4.0, 0)
				_ufo.rotation.y = _now() * 2.2
				_ufo.scale = Vector3.ONE * 0.72 * (0.4 + 0.6 * fade_in)
				var blink: bool = int(_now() * 8.0) % 2 == 0
				_ufo_lights[0].albedo_color = Color8(0xff, 0xd2, 0x3f) if blink else Color8(0x14, 0xd3, 0xe0)
				_ufo_lights[1].albedo_color = Color8(0x14, 0xd3, 0xe0) if blink else Color8(0xff, 0xd2, 0x3f)
				var on: bool = not gone and t >= beam_t and t < tw + 0.05
				var flick: float = 1.0 if t > beam_t + 0.25 else (1.0 if int(_now() * 40.0) % 2 == 0 else 0.25)
				_ufo_beam.visible = on
				if on:
					var top: float = _ufo.position.y - 0.4
					_ufo_beam.position = Vector3(_ufo.position.x, top * 0.5, _ufo.position.z)
					_ufo_beam.scale = Vector3(1.2, top, 1.2)
					_ufo_beam_mat.set_shader_parameter(&"alpha", flick * (0.9 + 0.1 * sin(_now() * 30.0)))
					_ufo_beam_mat.set_shader_parameter(&"t", _now())
					if int(_now() * 30.0) != int((_now() - 0.016) * 30.0):
						fx._spawn(1, {"p": Vector3(car.x, 0.3, car.z) + Vector3(fx.rng.randf_range(-1.6, 1.6), 0, fx.rng.randf_range(-1.6, 1.6)),
							"v": Vector3(0, fx.rng.randf_range(4.0, 7.0), 0), "r": Vector3.ZERO, "w": Vector3.ZERO, "s0": 0.14, "s1": 0.0,
							"life": 0.6, "c": Color8(0x9a, 0xff, 0xd0), "g": 0.0, "drag": 0.2, "bounce": 0.0, "shape": 1})
			if fresh.call("twinkle"):
				var vp: Vector3 = car + Vector3(0, 1.0, 0)
				burst(vp, 2.6, Color(0.7, 1, 0.9), 0.2)
				fx.sparks(vp, 24, 8.0, Color8(0x9a, 0xff, 0xd0), 0.16)
			if gone:
				var ga2: float = _now() - float(_fin.get("gone_at", _now()))
				_ufo.position = (_fin["prop_at_gone"]["ufo"] as Vector3) + Vector3(0, 26.0, -8.0) * ga2 * ga2 * 2.0
				_ufo.visible = ga2 < 0.5
				_ufo_beam.visible = false
	if gone and _fin.has("gone_at") and _now() - float(_fin["gone_at"]) > 1.2:
		_fin = {}


func _string_between(i: int, a: Vector3, b: Vector3, on: bool) -> void:
	var sm: MeshInstance3D = _strings[i]
	var d: Vector3 = b - a
	sm.visible = on and d.length() > 0.05
	if not sm.visible:
		return
	var up: Vector3 = Vector3.UP if absf(d.normalized().dot(Vector3.UP)) < 0.98 else Vector3.RIGHT
	sm.global_transform = Transform3D(Basis.looking_at(d.normalized(), up).scaled(Vector3(1, 1, d.length())), (a + b) * 0.5)


func advance(dt: float) -> void:
	var t: float = _now()
	# arcs
	for a: Dictionary in _arcs:
		var mi: MeshInstance3D = a["mi"]
		var k: float = (t - float(a["born"])) / float(a["dur"])
		mi.visible = k >= 0.0 and k < 1.0
		if mi.visible:
			var e: float = 1.0 - pow(1.0 - k, 2.0)
			var w: float = lerpf(float(a["w0"]), float(a["w1"]), e)
			mi.position = (a["p0"] as Vector3).lerp(a["p1"] as Vector3, e)
			mi.rotation = Vector3(0, float(a["yaw"]), 0)
			mi.scale = Vector3(w, 1.0, w * 0.55)
			var c: Color = a["col"]
			(a["mat"] as StandardMaterial3D).albedo_color = Color(c.r * 2.2, c.g * 2.2, c.b * 2.2, 1.0 - k * k)  # HDR: reads on asphalt
	# carpet tacks
	var mm: MultiMesh = _tk_mm.multimesh
	var nt: int = 0
	var keep: Array[Dictionary] = []
	for tk: Dictionary in _tacks:
		var t0: float = float(tk["t0"])
		var t1: float = float(tk["t1"])
		if t > t1 + 1.8:
			continue
		keep.append(tk)
		if t < t0 or nt >= mm.instance_count:
			continue
		var p: Vector3
		var sc: float = 1.7  # cartoon scale: a caltrop must read from the high boss camera
		var rot: Vector3
		if t < t1:
			var k2: float = (t - t0) / maxf(0.01, t1 - t0)
			p = (tk["p0"] as Vector3).lerp(tk["p1"] as Vector3, k2) + Vector3(0, float(tk["h"]) * 4.0 * k2 * (1.0 - k2), 0)
			rot = Vector3(t * float(tk["spin"]), t * float(tk["spin"]) * 0.7, 0)
			if dt > 0.0 and nt % 2 == 0:  # glint trail: the rain reads as streaks
				fx._spawn(1, {"p": p, "v": Vector3.ZERO, "r": Vector3.ZERO, "w": Vector3.ZERO, "s0": 0.2, "s1": 0.0, "life": 0.12,
					"c": Color8(0xff, 0xe6, 0x80), "g": 0.0, "drag": 0.0, "bounce": 0.0, "shape": 3})
		else:
			if not bool(tk["landed"]):
				tk["landed"] = true
				var lp: Vector3 = tk["p1"]
				fx.sparks(lp + Vector3(0, 0.2, 0), 6, 7.0, Color8(0xff, 0xe6, 0x80), 0.13)
				fx.debris(lp + Vector3(0, 0.2, 0), 2, RUBBER, 4.0, 0.16)
			var k3: float = t - t1
			p = (tk["p1"] as Vector3) + Vector3(0, absf(sin(k3 * 18.0)) * 0.25 * maxf(0.0, 1.0 - k3 * 4.0), 0)
			rot = Vector3(0.6, float(tk["spin"]), 0.3)
			sc *= clampf((t1 + 1.8 - t) / 0.4, 0.0, 1.0)
		mm.set_instance_transform(nt, Transform3D(Basis.from_euler(rot).scaled(Vector3.ONE * maxf(0.01, sc)), p))
		mm.set_instance_color(nt, Color.WHITE)
		nt += 1
	_tacks = keep
	mm.visible_instance_count = nt
	# telegraph strip
	_strip.visible = t >= _strip_born and t < _strip_until
	if _strip.visible:
		_strip_mat.set_shader_parameter(&"alpha", clampf((t - _strip_born) / 0.08, 0.0, 1.0))
		_strip_mat.set_shader_parameter(&"t", t)
	# decals: hold, then fade over the last 40 %
	for d: Dictionary in _decals:
		var dn: Decal = d["node"]
		if not dn.visible:
			continue
		var k4: float = (t - float(d["born"])) / float(d["life"])
		if k4 >= 1.0:
			dn.visible = false
		else:
			dn.modulate = Color(1, 1, 1, 1.0 if k4 < 0.6 else (1.0 - k4) / 0.4)
	# bursts: pop (back-out) to size, hold, fade + shrink
	for b: Dictionary in _bursts:
		var mi2: MeshInstance3D = b["mi"]
		var age: float = t - float(b["born"])
		var dur: float = float(b["dur"])
		mi2.visible = age >= 0.0 and age < dur
		if mi2.visible:
			var k5: float = age / dur
			var sc2: float = float(b["size"]) * (UiDraw.back_out(minf(1.0, age / 0.07), 3.0) if age < 0.07 else 1.0 + 0.15 * k5)
			mi2.scale = Vector3.ONE * maxf(0.01, sc2)
			mi2.rotation = Vector3(0, 0, float(b.get("rot", 0.0)))
			var c2: Color = (b["mat"] as StandardMaterial3D).albedo_color
			(b["mat"] as StandardMaterial3D).albedo_color = Color(c2.r, c2.g, c2.b, 1.0 if k5 < 0.55 else (1.0 - k5) / 0.45)
	for s: Dictionary in _stars:
		var mi3: MeshInstance3D = s["mi"]
		var age2: float = t - float(s["born"])
		var dur2: float = float(s["dur"])
		mi3.visible = age2 >= 0.0 and age2 < dur2
		if mi3.visible:
			var k6: float = age2 / dur2
			mi3.scale = Vector3.ONE * float(s["size"]) * sin(PI * minf(1.0, k6 * 1.15)) * (1.0 + 0.3 * sin(age2 * 30.0))
			mi3.rotation = Vector3(0, 0, age2 * 3.0)
	# t5 marker: shrinking gold ring over the target
	if not _marker_on.is_empty():
		var mv: Dictionary = _villain(int(_marker_on["target"]))
		if mv.is_empty():
			_marker_on = {}
			_marker.visible = false
		else:
			var k7: float = clampf((t - float(_marker_on["born"])) / maxf(0.05, float(_marker_on["dur"])), 0.0, 1.0)
			var r: float = lerpf(9.0, 3.4, 1.0 - pow(1.0 - k7, 2.0))
			_marker.position = _w(float(mv.get("s", 0.0)), float(mv.get("x", 0.0)), 0.12)
			_marker.scale = Vector3(r, 1.0, r)
			_marker.rotation.y = t * 4.0
			_marker_mat.albedo_color = Color(GOLD, clampf(0.75 + 0.25 * sin(t * 40.0) * k7, 0.0, 1.0))
	else:
		_marker.visible = false
	for pl: Dictionary in _pillars:
		var mi4: MeshInstance3D = pl["mi"]
		var k8: float = (t - float(pl["born"])) / float(pl["dur"])
		mi4.visible = k8 >= 0.0 and k8 < 1.0
		if mi4.visible:
			var rr: float = float(pl.get("r", 2.2)) * (1.0 + 0.35 * (1.0 - k8))
			mi4.scale = Vector3(rr, mi4.scale.y, rr)
			(pl["mat"] as ShaderMaterial).set_shader_parameter(&"alpha", 0.55 * (1.0 - k8) * (1.0 - k8))
			(pl["mat"] as ShaderMaterial).set_shader_parameter(&"t", t)
	_step_drone(t)
	for r2: Node3D in _drone_rotors:
		r2.rotation.y += dt * 60.0
	_heli_rotor.rotation.y += dt * 28.0
	_heli_tail.rotation.x += dt * 40.0


func _step_drone(t: float) -> void:
	if _drone_on.is_empty():
		_drone.visible = false
		_bomb_mm.multimesh.visible_instance_count = 0
		return
	var v: Dictionary = _villain(int(_drone_on["target"])) if int(_drone_on["target"]) >= 0 else {}
	var over: Vector3 = _w(float(v.get("s", 0.0)), float(v.get("x", 0.0)), float(v.get("y", 0.0)) + 5.6) if not v.is_empty() \
		else (_drone_on["dest"] as Vector3) + Vector3(0, 5.0, 0)
	var born: float = float(_drone_on["born"])
	var arrive: float = float(_drone_on["arrive"])
	var leave: float = float(_drone_on["leave_at"])
	var p: Vector3
	if t < arrive:
		var k: float = clampf((t - born) / maxf(0.05, arrive - born), 0.0, 1.0)
		var e: float = k * k * (3.0 - 2.0 * k)
		p = (_drone_on["p0"] as Vector3).lerp(over, e) + Vector3(0, 3.0 * sin(PI * k), 0)
		_drone.rotation = Vector3(-0.35 * sin(PI * k), 0, 0)
	elif t < leave:
		p = over + Vector3(0, sin(t * 9.0) * 0.12, 0)
		_drone.rotation = Vector3(0.08 * sin(t * 7.0), 0, 0.06 * sin(t * 5.0))
	else:
		var k2: float = (t - leave) / 0.5
		p = over + Vector3(0, 6.0 * k2, -10.0 * k2)
		_drone.rotation = Vector3(-0.4, 0, 0)
		if k2 >= 1.0:
			_drone_on = {}
			_drone.visible = false
			return
	_drone.position = p
	_drone.visible = true
	var on: bool = int(t * 10.0) % 2 == 0
	_drone_leds[0].albedo_color = Color8(0xff, 0x3b, 0x30) if on else Color8(0x40, 0x10, 0x10)
	_drone_leds[1].albedo_color = Color8(0x3a, 0x8b, 0xff) if not on else Color8(0x10, 0x18, 0x40)
	var bmm: MultiMesh = _bomb_mm.multimesh
	var nb: int = 0
	for b: Dictionary in _bombs:
		var t0: float = float(b["t0"])
		var t1: float = float(b["t1"])
		if t < t0 or t >= t1 or nb >= bmm.instance_count:
			continue
		var k3: float = (t - t0) / maxf(0.01, t1 - t0)
		var tgt: Vector3 = _w(float(v.get("s", 0.0)) + float(b["off"]), float(v.get("x", 0.0)), float(v.get("y", 0.0)) + 1.4) \
			if not v.is_empty() else (_drone_on["dest"] as Vector3)
		var bp: Vector3 = (p + Vector3(0, -0.4, 0)).lerp(tgt, k3 * k3)
		bmm.set_instance_transform(nb, Transform3D(Basis(), bp))
		bmm.set_instance_color(nb, Color.WHITE)
		nb += 1
	bmm.visible_instance_count = nb


## Live counts (tests / shot RESULT lines).
func counts() -> Dictionary:
	var dec: int = 0
	for d: Dictionary in _decals:
		if (d["node"] as Decal).visible:
			dec += 1
	return {"decals": dec, "tacks": _tacks.size(), "drone": _drone.visible, "props": [_balloons.visible, _heli.visible, _ufo.visible],
		"finish": str(_fin.get("id", ""))}
