// Traffic / Rng32 — GDScript-facing wrappers around traffic_core (docs/NATIVE_PORT.md 3-2, 3-3).
//
// GDScript never names these classes statically (native/sim/traffic_bridge.gd goes through ClassDB), so
// every script still parses on a build where the extension failed to load.
//
// Lifecycle (one stage):
//   configure({config, vehicle_kinds, mini_types, approach})   # DB tables, once
//   spawn_jam(stage, villains, {s, lane, len, w}, seed, night)  # traffic.js spawnJam
//   per tick: set_player(...), set_villain(...)/set_extra(...), set_context(...), update(dt, time)
//   between ticks: honk / rage_horn / mini_hit / smash / jolt / release / … (main.js call sites)
//   per frame: get_buffer(alpha) -> PackedFloat32Array, stride 8: [id, kind, lane, x, s, yaw, v, lamp_bits]
#pragma once

#include "traffic_core.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <cstdint>

namespace lane1 {

class Rng32 final : public godot::RefCounted {
	GDCLASS(Rng32, godot::RefCounted)

public:
	void set_seed(int64_t p_seed);
	[[nodiscard]] int64_t get_seed() const;
	int64_t next_u32();
	double next_float();
	[[nodiscard]] int64_t get_draws() const;

protected:
	static void _bind_methods();

private:
	sim::Mulberry32 rng_;
	int64_t seed_ = 0;
	int64_t draws_ = 0;
};

class Traffic final : public godot::RefCounted {
	GDCLASS(Traffic, godot::RefCounted)

public:
	// lamp_bits (shared with the GDScript fallback in traffic_bridge.gd)
	enum LampBits : int {
		LAMP_BRAKE = 1,
		LAMP_BLINK_LEFT = 2,
		LAMP_BLINK_RIGHT = 4,
		LAMP_HIGHBEAM = 8,
		LAMP_HAZARD = 16,
		LAMP_HEADLIGHTS = 32,
		LAMP_VILLAIN = 64,
		LAMP_MINI = 128,
	};
	static constexpr int STRIDE = 8;
	static constexpr int OPP_ID_BASE = 100000;

	// --- M1-0 API (kept: test_ext.gd) ---------------------------------------------------------
	void tick(double p_dt); // update(dt, sim_time + dt) with the stored context (no-op before spawn)
	[[nodiscard]] int64_t count() const; // NPC cars (cheaters and minis included), 0 before spawn
	[[nodiscard]] int64_t get_tick_count() const;
	[[nodiscard]] double get_sim_time() const;
	[[nodiscard]] static godot::String build_info();
	// Correctly rounded JSON (Godot's JSON.parse is 1 ulp off on 17-digit numbers, see json_exact.h).
	[[nodiscard]] static godot::Variant parse_json(const godot::String &p_text);

	// --- setup -----------------------------------------------------------------------------------
	bool configure(const godot::Dictionary &p_tables);
	[[nodiscard]] godot::PackedStringArray get_missing_params() const;
	[[nodiscard]] int64_t get_loaded_params() const;
	bool spawn_jam(const godot::Dictionary &p_stage, const godot::Array &p_villains, const godot::Dictionary &p_player_start,
			int64_t p_seed, bool p_night);
	[[nodiscard]] bool is_spawned() const;
	[[nodiscard]] godot::PackedStringArray kind_names() const;
	[[nodiscard]] int64_t kind_index(const godot::String &p_name) const;

	// --- per-tick inputs -------------------------------------------------------------------------
	void set_player(double p_s, double p_x, double p_v, int64_t p_lane, bool p_mode_jam);
	void set_player_dims(double p_len, double p_w);
	void set_player_stats(bool p_tow);
	void set_villain_count(int64_t p_n);
	void set_villain(int64_t p_i, double p_s, double p_base_s, double p_x, double p_w, double p_len, double p_v, double p_v_nominal,
			bool p_alive);
	void set_extra_count(int64_t p_n);
	void set_extra(int64_t p_i, double p_s, double p_x, double p_w, double p_len, double p_v, bool p_alive);
	// focus_s = NAN -> player.s (main.js passes G.killS during 'release').
	void set_context(const godot::String &p_phase, bool p_allow_events, bool p_jam_like, double p_focus_s);
	void set_web_parity(bool p_on);
	[[nodiscard]] bool get_web_parity() const;
	void set_sin_override(const godot::PackedFloat64Array &p_sin_lf); // one-shot, lanes 0..4
	void update(double p_dt, double p_time);

	// --- calls between ticks -----------------------------------------------------------------------
	godot::Dictionary honk(bool p_siren, bool p_trot); // {kind: "" | cheater | yield | letin | noway | villain | tired, id}
	godot::Dictionary rage_horn(double p_range); // {smashed, towed, cheaters, startled: PackedInt32Array}
	godot::String mini_hit(int64_t p_car_id, double p_dmg); // "" | "hit" | "down"
	bool smash(int64_t p_obstacle_id);
	bool remove_obstacle(int64_t p_obstacle_id);
	void set_obstacle_ids(const godot::PackedInt32Array &p_ids); // drop the obstacles not listed
	void jolt(int64_t p_id);
	void release(double p_time, double p_wave_speed, int64_t p_open_lane); // wave_speed <= 0 -> TUNE default
	void drop_walls(const godot::PackedInt32Array &p_lanes, double p_meters);
	void emit_brake_wave(int64_t p_lane, double p_s, double p_strength);
	int64_t let_in_player(int64_t p_lane, bool p_force);

	// --- queries (previous tick's buckets) -----------------------------------------------------------
	[[nodiscard]] godot::Dictionary leader_of_player() const; // {id, gap, type}
	[[nodiscard]] int64_t can_merge_into(int64_t p_lane, double p_margin) const; // blocker id, 0 = free
	[[nodiscard]] int64_t lane_blocked(int64_t p_lane, double p_s_min, double p_s_max, int64_t p_exclude_id) const;
	[[nodiscard]] godot::Dictionary gap_ahead(int64_t p_lane, double p_s) const; // excludes the player
	[[nodiscard]] int64_t mini_target() const;
	[[nodiscard]] godot::PackedInt32Array cars_behind_front(int64_t p_n, double p_range) const;

	// --- outputs -----------------------------------------------------------------------------------
	[[nodiscard]] int64_t opp_count() const;
	[[nodiscard]] int64_t obstacle_count() const;
	[[nodiscard]] godot::PackedFloat32Array get_buffer(double p_alpha, bool p_include_opp) const;
	// MultiMesh-ready transforms (RenderingServer.multimesh_set_buffer layout, 12 floats per instance:
	// basis rows + origin) for the given record ids in that order — the view groups ids per (kind, variant)
	// MultiMesh once, then copies one buffer per mesh per frame. Unknown ids get a zero-scale transform.
	// World = (x, 0, -s) rotated by yaw about +Y (straight road; RoadGraph mapping arrives with curves).
	[[nodiscard]] godot::PackedFloat32Array get_transforms_for(const godot::PackedInt32Array &p_ids, double p_alpha) const;
	[[nodiscard]] godot::Array get_car_specs() const;
	[[nodiscard]] godot::Array get_obstacles() const;
	[[nodiscard]] godot::Array get_opp() const;
	[[nodiscard]] godot::PackedFloat64Array get_barrier() const;
	[[nodiscard]] godot::Dictionary get_info() const;
	[[nodiscard]] godot::Dictionary get_state() const; // ids, s, v, x (f64), lane, opp_s, obstacles
	[[nodiscard]] godot::PackedByteArray hash_bytes() const; // traffic golden `h` preimage
	godot::Array take_events();

	// --- RNG trace (tests) -----------------------------------------------------------------------------
	void set_trace(bool p_on);
	godot::Array take_trace(); // [[tag, u32], …]
	[[nodiscard]] int64_t get_rng_draws() const;
	[[nodiscard]] double peek_rng() const; // next draw without consuming it

protected:
	static void _bind_methods();

private:
	sim::TrafficCore core_;
	bool configured_ = false;
	int64_t tick_count_ = 0;
	double sim_time_ = 0.0;
	int64_t loaded_params_ = 0;
	godot::PackedStringArray missing_params_;
	godot::Dictionary approach_default_;
};

} // namespace lane1
