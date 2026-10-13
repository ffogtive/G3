// Baked voxel vertex-colour meshes: vehicles (MultiMesh NPCs and hero MeshInstances), props, road
// (NATIVE_PORT 2 / 3-7; channel contract in res://assets/README.md).
//  COLOR    sRGB8 web hex (incl. the web height AO)            CUSTOM0.x  ray-cast AO visibility (toggle: ao_strength)
//  CUSTOM0.y part id (0 body, 1-3 brake, 4-6 head, 7-12 hazard, 13-16 blink FL/FR/RL/RR, 17 glow, 24 beam, 32+ wheels)
//  CUSTOM0.z paint shade k (runtime NPC tint)                  CUSTOM0.w  height-AO factor for the tint path
// Lamps are part of the same draw: a lamp vertex is rendered as pure emission (HDR when lit → glow 'red sea'),
// an off lamp shows the web's MeshBasic off colour, a hidden lamp (blinker off, no beam) collapses to a point.
shader_type spatial;
render_mode diffuse_lambert, specular_disabled, cull_back;

#include "res://shaders/hemi.gdshaderinc"

// 0 = static scenery (every lamp part is an always-on glow), 1 = NPC MultiMesh (INSTANCE_CUSTOM = sRGB paint.rgb
// or r < 0 for no tint, a = lamp bits), 2 = hero MeshInstance3D (instance uniforms below).
uniform int source = 0;
uniform float ao_strength : hint_range(0.0, 1.0) = 0.55;
uniform float ao_light_affect : hint_range(0.0, 1.0) = 0.0;  // AO darkens ambient only (palette under sun kept)
// lit-lamp HDR multipliers (Mobile HDR buffer saturates at 2.0; glow_hdr_threshold = 1.0)
uniform float brake_energy = 2.2;
uniform float blink_energy = 2.4;
uniform float hazard_energy = 2.2;
uniform float head_energy = 1.4;
uniform float highbeam_energy = 2.6;
uniform float glow_energy = 1.0;
uniform float static_glow_energy = 1.0;
// web MeshBasic "off" colours (vehicles.js MAT.brakeOff / hazardOff / headOff), linear
uniform vec3 off_brake = vec3(0.392, 0.034, 0.034);
uniform vec3 off_hazard = vec3(0.102, 0.068, 0.030);
uniform vec3 off_head = vec3(0.323, 0.323, 0.279);
// lamp bits (TrafficBridge contract): 1 brake, 2 blink L lit, 4 blink R lit, 8 highbeam, 16 hazard lit, 32 headlights
instance uniform vec4 hero_paint = vec4(0.0);
instance uniform int hero_lamps = 0;
instance uniform float hero_flash = 0.0;

varying vec3 v_paint;
varying float v_tint;
varying vec4 v_c0;
varying float v_emit;
varying vec3 v_emit_mul;

void vertex() {
	v_c0 = CUSTOM0;
	int bits = 0;
	v_tint = 0.0;
	v_paint = vec3(1.0);
	if (source == 1) {
		bits = int(INSTANCE_CUSTOM.a + 0.5);
		if (INSTANCE_CUSTOM.r >= 0.0) {
			v_tint = 1.0;
			v_paint = INSTANCE_CUSTOM.rgb;
		}
	} else if (source == 2) {
		bits = hero_lamps;
		v_tint = hero_paint.a;
		v_paint = hero_paint.rgb;
	}
	int id = int(CUSTOM0.y + 0.5);
	v_emit = 0.0;
	v_emit_mul = vec3(1.0);
	if (id >= 1 && id < 32) {
		bool hide = false;
		if (source == 0) {
			v_emit = static_glow_energy;
		} else if (id <= 3) {
			bool on = (bits & 1) != 0;
			v_emit = on ? brake_energy : 1.0;
			v_emit_mul = on ? vec3(1.0) : off_brake;
		} else if (id <= 6) {
			bool hb = (bits & 8) != 0;
			bool on = hb || (bits & 32) != 0;
			v_emit = hb ? highbeam_energy : (on ? head_energy : 1.0);
			v_emit_mul = on ? vec3(1.0) : off_head;
		} else if (id <= 12) {
			bool on = (bits & 16) != 0;
			v_emit = on ? hazard_energy : 1.0;
			v_emit_mul = on ? vec3(1.0) : off_hazard;
		} else if (id <= 16) {
			bool left = id == 13 || id == 15;
			bool on = left ? (bits & 2) != 0 : (bits & 4) != 0;
			v_emit = blink_energy;
			hide = !on;
		} else if (id == 17) {
			v_emit = glow_energy;
		} else if (id == 24) {
			v_emit = 0.6;
			hide = (bits & 8) == 0;
		} else {
			hide = true;  // sirens / strobes: not in the M1a set
		}
		if (hide) {
			VERTEX = vec3(0.0);
		}
	}
}

void fragment() {
	vec3 srgb = COLOR.rgb;
	float hao = 1.0;
	if (v_tint > 0.5 && v_c0.z > 0.0) {
		float k = v_c0.z;
		srgb = k < 1.0 ? v_paint * k : v_paint + (vec3(1.0) - v_paint) * (k - 1.0);
		hao = v_c0.w;
	}
	vec3 albedo = srgb_to_linear(srgb) * hao;
	if (v_emit > 0.0) {
		ALBEDO = vec3(0.0);
		EMISSION = albedo * v_emit_mul * v_emit;
	} else {
		float ao = mix(1.0, v_c0.x, ao_strength);
		ALBEDO = albedo;
		AO = ao;
		AO_LIGHT_AFFECT = ao_light_affect;
		vec3 e = vec3(hero_flash);
		if (hemi_in_shader) {
			vec3 wn = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
			e += albedo * hemi_term(wn) * ao;
		}
		EMISSION = e;
	}
}
