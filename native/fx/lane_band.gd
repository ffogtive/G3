class_name LaneBand
extends MeshInstance3D
## DESIGN_REVIEW P0#2 range band: while the front lock is on, the villain's lane ±1 (the tack lock-on lanes,
## weapons.tack.laneRange) glows on the asphalt — green with chevrons flowing toward the villain when the player is
## inside it, grey when not — so "why do my tacks miss?" is answered on the road itself. One flat quad with an
## unshaded additive shader; fades in / out over 0.2 s (real time, advance()).

const SHADER: String = """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;
uniform vec4 col : source_color = vec4(0.24, 0.88, 0.56, 1.0);
uniform float alpha = 0.0;
uniform float t = 0.0;
uniform float len_m = 30.0;
uniform float wid_m = 10.8;
uniform float dir = 1.0;
void fragment() {
	vec2 m = vec2(UV.x * wid_m, UV.y * len_m);
	float ex = min(m.x, wid_m - m.x);
	float ey = min(m.y, len_m - m.y);
	float edge = smoothstep(0.0, 0.25, ex) * (1.0 - smoothstep(0.25, 0.55, ex));
	float fade = smoothstep(0.0, 6.0, ey);
	float cx = abs(m.x - wid_m * 0.5) * 0.55;
	float ch = fract((m.y * dir + cx) / 3.2 - t * 1.4);
	float chev = smoothstep(0.0, 0.08, ch) * (1.0 - smoothstep(0.3, 0.38, ch));
	float a = (0.16 + 0.55 * edge + 0.22 * chev) * fade * alpha;
	ALBEDO = col.rgb * a;
}
"""

var road: RoadGraph
var lane_w: float = 3.6
var _mat: ShaderMaterial
var _alpha: float = 0.0
var _want: float = 0.0
var _t: float = 0.0
var in_range: bool = false
var shown_lanes := Vector2i(-1, -1)


func _ready() -> void:
	var pm := PlaneMesh.new()
	pm.size = Vector2(1, 1)
	mesh = pm
	var sh := Shader.new()
	sh.code = SHADER
	_mat = ShaderMaterial.new()
	_mat.shader = sh
	material_override = _mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	visible = false


## Band over lanes [lane_lo, lane_hi] (0..4, 4 = shoulder), from s0 to s1; dir +1 = chevrons point to +s.
func set_band(on: bool, lane_lo: int, lane_hi: int, s0: float, s1: float, p_in_range: bool, dir: float = 1.0) -> void:
	_want = 1.0 if on else 0.0
	if not on:
		return
	in_range = p_in_range
	shown_lanes = Vector2i(lane_lo, lane_hi)
	var x0: float = RoadGraph.lane_x(float(lane_lo)) - lane_w * 0.5
	var x1: float = RoadGraph.lane_x(float(lane_hi)) + lane_w * 0.5
	var sa: float = minf(s0, s1)
	var sb: float = maxf(s0, s1)
	var mid_s: float = (sa + sb) * 0.5
	var xf: Transform3D = road.world(mid_s, (x0 + x1) * 0.5) if road != null else Transform3D(Basis(), Vector3((x0 + x1) * 0.5, 0, -mid_s))
	xf.origin.y += 0.06
	xf.basis = xf.basis.scaled(Vector3(x1 - x0, 1.0, sb - sa))
	transform = xf
	_mat.set_shader_parameter(&"len_m", sb - sa)
	_mat.set_shader_parameter(&"wid_m", x1 - x0)
	_mat.set_shader_parameter(&"dir", -dir)
	_mat.set_shader_parameter(&"col", Color8(0x3c, 0xe0, 0x8e) if in_range else Color8(0xd8, 0xde, 0xe8))


## From GameSim.state(): lock.active → band on the first alive villain's lane ±laneRange, spanning villain..player.
func apply_state(st: Dictionary, lane_range: int = 1) -> void:
	var lk: Dictionary = st.get("lock", {})
	var on: bool = str(st.get("phase", "")) == "boss" and bool(lk.get("active", false))
	var ref: Dictionary = {}
	for v: Variant in st.get("villains", []):
		if bool((v as Dictionary).get("alive", false)):
			ref = v
			break
	if not on or ref.is_empty():
		set_band(false, 0, 0, 0, 0, false)
		return
	var vl: int = roundi(float(ref.get("lane_pos", ref.get("lane", 0))))
	var p: Dictionary = st.get("player", {})
	var vs: float = float(ref.get("s", 0.0))
	var ps: float = float(p.get("s", vs))
	set_band(true, maxi(0, vl - lane_range), mini(4, vl + lane_range), minf(vs, ps) - 8.0, maxf(vs, ps) + 8.0,
		bool(lk.get("in_range", false)), signf(vs - ps) if vs != ps else 1.0)


func advance(dt: float) -> void:
	_t += dt
	_alpha = move_toward(_alpha, _want, dt / 0.2)
	visible = _alpha > 0.01
	if visible:
		var pulse: float = 1.0 if in_range else 1.7  # light grey on grey asphalt needs more gain than green
		_mat.set_shader_parameter(&"alpha", _alpha * pulse)
		_mat.set_shader_parameter(&"t", _t if in_range else _t * 0.3)
