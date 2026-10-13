// Contact blob under every car (NATIVE_PORT 2 "차 밑에는 접지 블롭 그림자"): multiplies the road by a soft rounded
// rectangle. Drawn as one MultiMesh of unit quads (x = width, z = length via the instance basis).
shader_type spatial;
render_mode unshaded, blend_mul, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

uniform float strength : hint_range(0.0, 1.0) = 0.42;
uniform float fade_far = 140.0;
varying float v_dist;

void vertex() {
	v_dist = length((MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz);
}

void fragment() {
	vec2 q = abs(UV - 0.5) * 2.0;          // 0 centre … 1 edge
	float d = length(max(q - vec2(0.55, 0.7), 0.0) / vec2(0.45, 0.3));
	float a = (1.0 - smoothstep(0.0, 1.0, d)) * strength * (1.0 - smoothstep(fade_far * 0.6, fade_far, v_dist));
	ALBEDO = vec3(1.0 - a);
}
