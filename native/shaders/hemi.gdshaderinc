// Hemisphere ambient shared by every lit voxel material (NATIVE_PORT 2 반구광).
// Ambient mode A (default): hemi_in_shader = false, Environment ambient = SKY whose radiance pass is the 2-colour
//   hemi sky (shaders/sky.gdshader, AT_CUBEMAP_PASS). Mode B: hemi_in_shader = true, Environment ambient disabled and
//   the exact Three r170 HemisphereLight term mix(ground, sky, 0.5·n.y + 0.5) · albedo is added here as emission.
// hemi_sky / hemi_ground are LINEAR colours already multiplied by intensity / π (Three Lambert BRDF).
uniform bool hemi_in_shader = false;
uniform vec3 hemi_sky = vec3(0.208, 0.311, 0.398);
uniform vec3 hemi_ground = vec3(0.101, 0.130, 0.058);

vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

vec3 hemi_term(vec3 world_normal) {
	return mix(hemi_ground, hemi_sky, 0.5 * world_normal.y + 0.5);
}
