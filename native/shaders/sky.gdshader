// Sky: background = port of the web scenery.sky dome (makeSkyDome: mix(bottom, top, pow(h, exponent)) + horizon
// lift), radiance/ambient pass = the 2-colour HemisphereLight sky (NATIVE_PORT 2: "ambient 전용 2색 sky").
// One shader does both: AT_CUBEMAP_PASS is true only while Godot renders the radiance cubemap that feeds
// ambient_light_source = SKY, so the visible gradient never leaks into the lighting.
shader_type sky;
render_mode use_debanding;

uniform vec3 top_color : source_color = vec3(0.373, 0.722, 1.0);
uniform vec3 bottom_color : source_color = vec3(0.847, 0.941, 1.0);
uniform float exponent = 0.6;
// linear radiance (= colour · intensity / π) of the upper / lower hemisphere for the ambient pass
uniform vec3 hemi_sky_rad = vec3(0.208, 0.311, 0.398);
uniform vec3 hemi_ground_rad = vec3(0.101, 0.130, 0.058);
uniform bool ambient_from_hemi = true;

void sky() {
	if (AT_CUBEMAP_PASS && ambient_from_hemi) {
		COLOR = EYEDIR.y >= 0.0 ? hemi_sky_rad : hemi_ground_rad;
	} else {
		float h = clamp(EYEDIR.y, 0.0, 1.0);
		vec3 col = mix(bottom_color, top_color, pow(h, exponent));
		col = mix(col, bottom_color * 1.04, smoothstep(0.08, 0.0, h) * 0.5);
		COLOR = col;
	}
}
