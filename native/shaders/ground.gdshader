// Field patchwork ground (port of scenery.js makeGround: 256² canvas texture, repeat size/160, nearest mag filter,
// MeshLambertMaterial). The texture is generated at load by world.gd with the same rng(77) recipe.
shader_type spatial;
render_mode diffuse_lambert, specular_disabled;

#include "res://shaders/hemi.gdshaderinc"

uniform sampler2D field_tex : source_color, filter_nearest_mipmap, repeat_enable;
uniform float tiles = 18.75;

void fragment() {
	vec3 albedo = texture(field_tex, UV * tiles).rgb;
	ALBEDO = albedo;
	if (hemi_in_shader) {
		vec3 wn = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
		EMISSION = albedo * hemi_term(wn);
	}
}
