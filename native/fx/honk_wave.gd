class_name HonkWave
extends Node3D
## Horn feedback ring (N5 '경적 음파' in the world): an additive HDR ring that races ahead of the car on the road
## surface and fades (0.6 s). Pool of 3 so rapid honks overlap; drawn only while active (1 draw each).

const LIFE: float = 0.6
const SHADER_CODE: String = """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;
uniform float t = 0.0;
uniform vec3 tint : source_color = vec3(1.0, 0.82, 0.25);
void fragment() {
	vec2 q = (UV - 0.5) * 2.0;
	float r = length(q);
	float ring = smoothstep(0.80, 0.93, r) * (1.0 - smoothstep(0.93, 1.0, r));
	float fwd = smoothstep(0.35, -0.6, q.y);          // brighter ahead of the car (−Z)
	float a = ring * (0.35 + 0.65 * fwd) * (1.0 - t);
	ALBEDO = tint * 1.6 * a;
}
"""

var _rings: Array[MeshInstance3D] = []
var _age: Array[float] = []
var _shader: Shader


func _ready() -> void:
	_shader = Shader.new()
	_shader.code = SHADER_CODE
	for i: int in 3:
		var q := QuadMesh.new()
		q.orientation = PlaneMesh.FACE_Y
		q.size = Vector2(1, 1)
		var mi := MeshInstance3D.new()
		mi.mesh = q
		var m := ShaderMaterial.new()
		m.shader = _shader
		mi.material_override = m
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		mi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		add_child(mi)
		_rings.append(mi)
		_age.append(LIFE)


func emit_at(origin: Vector3) -> void:
	var best: int = 0
	for i: int in _age.size():
		if _age[i] > _age[best]:
			best = i
	_age[best] = 0.0
	_rings[best].global_position = origin + Vector3(0, 0.08, 0)
	_rings[best].visible = true


## true: the owner ages the rings with advance() (Game.manual: shots/tests run on sim time, not wall time).
var manual: bool = false


func _process(delta: float) -> void:
	if not manual:
		advance(delta)


func advance(delta: float) -> void:
	for i: int in _rings.size():
		if not _rings[i].visible:
			continue
		_age[i] += delta
		var k: float = clampf(_age[i] / LIFE, 0.0, 1.0)
		if k >= 1.0:
			_rings[i].visible = false
			continue
		var r: float = lerpf(3.0, 22.0, 1.0 - pow(1.0 - k, 2.0))
		_rings[i].scale = Vector3(r, 1, r)
		(_rings[i].material_override as ShaderMaterial).set_shader_parameter(&"t", k)


func active() -> int:
	var n: int = 0
	for r: MeshInstance3D in _rings:
		if r.visible:
			n += 1
	return n
