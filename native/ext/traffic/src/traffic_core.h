// traffic_core — engine-independent C++17 port of game/js/traffic.js (web-frozen 753549a).
//
// 가설: ❓ a line-by-line port (same draw order, same float expression order, stable bucket order,
//       -ffp-contract=off) reproduces the web goldens bit-for-bit; sin() is the only libm call that
//       feeds state, so replays inject the recorded value (set_sin_override).
//
// Rules kept from the JS (each one is a golden-visible behaviour):
//  - One Mulberry32 stream per stage; spawnJam and update draw in the JS order (tags in rng_trace_*.json).
//  - Buckets are rebuilt at the top of update() from [cars, obstacles, player, alive villains, extras]
//    and stable-sorted by s. Queries between updates (honk, letIn, canMergeInto …) use the previous
//    tick's buckets, and entities moved during update keep their start-of-tick bucket order (leaderOf
//    scans linearly with live s, like the JS).
//  - Obstacles removed between rebuilds stay in the buckets until the next update (JS splices the array
//    but not the buckets).
// No Godot types here: traffic.cpp wraps this for GDScript, tests can drive it directly.
#pragma once

#include "rng32.h"

#include <array>
#include <cstdint>
#include <deque>
#include <limits>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace lane1::sim {

constexpr int NUM_LANES = 4;
constexpr int SHOULDER_LANE = 4;
constexpr int ALL_LANES = NUM_LANES + 1;
constexpr double INF = std::numeric_limits<double>::infinity();

struct Dim {
	double L = 4.5, W = 1.9, H = 1.6;
};

struct KindInfo {
	std::string name;
	int variants = 1;
	std::vector<int> canon{ 0 };
	bool color_variant = false;
	std::vector<Dim> simple;
	std::vector<Dim> detailed;
};

using WeightTable = std::vector<std::pair<int, double>>; // (kind index, weight), order = draw order

enum class LaneKind : uint8_t { Packed, Train, Flow, Spaced, Pass };
enum class EType : uint8_t { Car, Obstacle, Player, Villain, Extra };
enum class ObKind : uint8_t { Breakdown, Cones, Debris };

// All tunables, defaults = the JS literals (traffic.js / shoulder.js / config.js TUNE @ 753549a).
// traffic.cpp overrides them from config.json (traffic.*, tune.*, road.*); the names follow those keys.
struct Params {
	double lane_w = 3.6;
	double half_lane_margin = 0.6; // occupancy.halfLaneMargin -> LANE_HALF_OCC = laneW/2 - 0.6
	std::array<double, 4> opp_lane_x{ { -11.1, -14.7, -18.299999999999997, -21.9 } };

	struct Car {
		double mono_p = 0.68, seed_scale = 1e6, personal_base = 0.97, personal_span = 0.06;
		double lc_dur_default = 1.8, v_free_default = 30, len_fallback = 4.5, w_fallback = 1.9;
	} car;

	struct Gap {
		double base, span;
	};
	struct Spawn {
		double wall_offset_span = 1.2, empty_front_rear_back = 3;
		Gap gap_packed{ 1.5, 1.7 }, gap_train{ 1.2, 0.5 }, gap_flow{ 2.6, 2 }, gap_spaced{ 7, 5 }, gap_pass{ 9, 5 };
		bool packed_divided_by_density = true;
		double lead_base = 2.2, lead_span = 1.6, lead_spaced_base = 9, lead_spaced_span = 4, lead_zig_extra = 6;
		double lane_car_v0_mul = 0.7, player_hole_half = 3.4, player_hole_push_back = 2, tail_behind_player = 45;
		double shoulder_start_ahead = 38, shoulder_end_before_front = 22, jitter_base = 0.25, jitter_span = 0.5;
		double cheater_spawn_v = 4.5, cheater_v_base = 4, cheater_v_span = 2.5;
		int crowded_cheaters = 3;
		double obstacle_x_offset = 0.1;
		int blocked_count = 5;
		double blocked_spacing = 12, blocked_start_frac = 0.45;
		double barrier_from_behind_player = 20, barrier_past_front = 30, barrier_spacing = 6;
		int minis_base = 2, minis_max = 4, minis_per_difficulty = 3;
		double minis_cool_base = 0.6, minis_hp = 12, minis_window = 30;
		int opp_count = 26, opp_lanes = 4;
		double opp_mono_p = 0.7, opp_s_behind = 100, opp_s_span = 520, opp_v_base = 24, opp_v_per_lane = 2, opp_v_span = 12;
	} spawn;

	struct LaneIdm {
		double T, s0, a_max, v0_mul;
	};
	struct Idm {
		double b = 3, acc_min = -9, brake_v0 = 0.01, v_floor = 0.1, gap_floor = 0.3, stop_gap = 0.25;
		LaneIdm train{ 0.45, 1.2, 1.6, 1.0 }, flow{ 0.8, 2.2, 1.6, 0.95 }, spaced{ 1.6, 5.5, 1.4, 1.05 };
		LaneIdm pass{ 1.0, 3.0, 2.0, 2.2 }; // v0_mul = jamShape.passV fallback
		LaneIdm packed{ 0.5, 1.4, 1.8, 1.25 };
		double lf_base = 0.35, lf_amp = 0.65, lf_freq = 0.42, lf_lane_phase = 1.9;
		double rel_T = 0.5, rel_s0 = 2.0, rel_a_max = 4.6, rel_a_max_slow = 2.6;
		double wall_T = 0.5, wall_s0 = 1.5, wall_a_max = 3.0, wall_follow = 0.9;
		double cheat_T = 0.6, cheat_s0 = 2.0, cheat_a_max = 2.5, cheat_v0_fallback = 5;
		double pull_T = 0.3, pull_s0 = 1.0, pull_a_max = 3.6, pull_v0_mul = 2.2, pull_v0_mul_let_in = 3.6;
		double villain_wall_back = 3, villain_wall_zig_extra = 5;
	} idm;

	struct Update {
		double brake_rate = 0.6, brake_behind = 10, brake_ahead = 80, brake_hold_base = 0.6, brake_hold_span = 0.7;
		double stuck_v_below = 2.5, stuck_decay = 2, stuck_rubber_fallback = 2.5, stuck_safety_fallback = 4;
		double stuck_pull_after = 1, tow_probe_ahead = 16, tow_probe_behind = 6;
		int auto_tow_after = 2;
		double ch_first_delay = 6, ch_min_player_v = 8, ch_next_base = 7, ch_next_span = 5;
		double ch_window_min = 14, ch_window_max = 30, ch_block_margin = 2, ch_v_base = 4, ch_v_span = 2, ch_lc_dur = 0.9;
		double mini_ds_min = 4, mini_ds_max = 30;
		double cutin_ds_min = 10, cutin_block_margin = 2, cutin_v = 3.5, cutin_lc_dur = 0.8, cutin_cool = 3;
		double throw_cool_base = 2.0, throw_cool_span = 1.2;
		int throw_max_acts = 2;
		double rel_hazard = 1.05, rel_next_lc_base = 0.4, rel_next_lc_span = 0.6, rel_lane_delay_cap = 3;
		double rel_wall_extra = 0.35, rel_car_extra = 0.08;
		double lc_dt_floor = 1e-4, lc_yaw_min_v = 2, lc_yaw_gain = 0.8;
		double pr_next_base = 0.8, pr_next_span = 0.8, pr_slow_margin = 3, pr_slow_lc_dur = 1.4;
		double pr_look_gap = 22, pr_v_margin = 3, pr_pass_margin = 3.5, pr_pass_lc_dur = 0.95;
		double pr_cheater_return_margin = 2.5, pr_cheater_return_lc_dur = 1.2;
		double opp_recycle_behind = 130, opp_respawn_ahead = 280, opp_respawn_span = 160;
		double wave_amp = 0.88, wave_speed = 6, wave_hold = 0.6, wave_life = 6, wave_min_strength = 0.15;
		double wave_hit_margin = 1.2, wave_hold_cap = 2.5;
		double ys_behind = 20, ys_ahead = 5, ys_hold_fallback = 2.5, ys_period_fallback = 2.5;
		double ys_wave_offset = 1, ys_wave_strength = 0.7, ys_wave_amp = 0.8;
		double bl_acc_below = -0.25, bl_v_below = 1.6, bl_flicker_freq = 1.3, bl_flicker_above = 0.2;
		double hz_period = 0.5, hz_on_frac = 0.27, hz_cheater_freq = 2.2;
	} upd;

	struct Queries {
		double merge_margin = 0.35, merge_yield_overlap = 1.3;
		double has_gap_extra = 1, has_gap_len_fallback = 4.2, has_gap_window = 6;
		double let_in_ahead_min = -3.5, let_in_ahead_max = 22, let_in_behind_max = -14;
		double let_in_pull = 2.2, let_in_brake = 2.2, let_in_yield_for = 2.8;
		double pull_ahead_range = 18, pull_ahead_hold = 1.2;
		double safe_touch = -0.1, safe_closing_gain = 1.5;
		double honk_range = 18, honk_range_siren = 45, honk_range_trot = 24, honk_range_slack = 2, honk_probe_back = 0.5;
		double honk_villain_range = 30, honk_cheater_range = 30, honk_cheater_range_siren = 50, honk_cheater_lc_dur = 1.1;
		double honk_fatigue_relax = 8, honk_fatigue_half_p = 0.5, honk_yield_margin = 1.6, honk_yield_lc_dur = 0.85;
		int honk_fatigue_ignore_at = 3;
		double rage_behind = 2, rage_lc_dur = 0.7, rage_startled_hold = 0.5;
		double mini_hit_jolt = 0.6, mini_hit_brake = 2.5, mini_hit_hazard = 4, mini_hit_lc_dur = 0.9;
		double mini_target_behind = -3, mini_target_ahead = 26, mini_target_lateral = 1.2;
		int behind_front_n = 6;
		double behind_front_range = 35;
	} q;

	struct Tune {
		double release_lane_delay = 0.45, release_wave_speed = 70;
		double release_lo = 25, release_hi = 30, truck_lo = 22, truck_hi = 25;
		double rage_horn_range = 48;
	} tune;
};

// Per-stage approach rules ({...TUNE.approach, ...stage.approach}).
struct Approach {
	std::string shoulder = "open";
	bool gap_check = true;
	bool fatigue = true;
	double rubber = 2.5; // NaN = absent -> fallback
	double rubber_safety = 4;
	double rage_horn = 24;
	bool has_rubber = true, has_rubber_safety = true, has_rage_horn = true;
};

struct Mini {
	int type = 0;
	double hp = 12, max = 12, cool = 0;
	int acted = 0;
	bool done = false;
};

struct ObstacleDetail {
	std::string name; // shoulder spec kind (breakdown | cones | debris | …)
	int car_kind = -1, car_variant = 0;
	uint32_t car_color = 0;
	double car_len = 0, rot_y = 0;
	bool triangle = false;
	std::vector<std::array<double, 3>> boxes; // debris boxes: x, z, rotY
	double tire_x = 0;
};

struct Ent {
	int id = 0;
	EType type = EType::Car;
	int kind = -1, variant = 0;
	uint32_t color = 0;
	int64_t seed = -1;
	int lane = 0, lane_from = 0, lane_to = 0;
	double lc_t = 1, lc_dur = 1.8;
	double x = 0, s = 0, v = 0, a = 0, len = 4.5, w = 1.9;
	double personal = 1, phase = 0, brake_t = 0, pull_t = 0;
	bool brake_on = false, hazard_on = false;
	double hazard_until = 0;
	bool released = false;
	double release_at = INF, v_free = 30;
	bool slow = false, is_wall = false, is_cheater = false;
	double next_lc_at = 0, bump_jolt = 0, yaw = 0;
	double wall_offset = 0, wall_back = 0;
	double cheater_v = 0; // JS `c.cheaterV || 5`: 0 and undefined are both falsy
	double yield_until = -INF;
	int honk_n = 0;
	double honk_t = 0; // JS `who.honkT && …`: 0 = unset
	bool let_in_boost = false, yielded = false;
	double yield_pocket = 0;
	bool has_mini = false;
	Mini mini;
	bool alive = true;
	int blink = 0; // -1 left, +1 right, 0 none
	// obstacles
	ObKind ob_kind = ObKind::Cones;
	bool smash = false, hazard_car = false;
	int stuck_n = 0;
	ObstacleDetail detail;
	// villains / player / extras
	bool is_villain = false;
	double base_s = 0, v_nominal = 0;
	bool has_base_s = false, has_v_nominal = false;
	bool mode_jam = false; // player.mode === 'jam'
	bool stats_tow = false;
	// interpolation (state at the start of the last update)
	double prev_x = 0, prev_s = 0, prev_yaw = 0;
	int bucket_idx = 0;

	[[nodiscard]] bool is_npc() const { return type == EType::Car; }
};

struct Opp {
	int j = 0, kind = -1, variant = 0;
	uint32_t color = 0;
	double s = 0, v = 0, prev_s = 0;
};

struct Wave {
	int lane = 0;
	double s = 0, strength = 1, amp = 0.88, speed = 6, hold = 0.6, life = 6;
	std::vector<const Ent *> hit;
};

struct JamSource {
	std::string type;
	int lane = 0;
	double hold = 2.5, period = 2.5;
	bool has_hold = false, has_period = false;
};

struct Event {
	std::string type; // released, cheater, mini_act, auto_tow, brake, brake_wave, cutin
	int id = 0;
	std::string data;
	double value = 0;
};

struct StageSpec {
	int id = 1;
	double jam_speed = 2.4, density = 1;
	bool zig = false;
	int zig_center = 1;
	bool has_front_row = false;
	std::array<int, NUM_LANES> front_row{ { -1, -1, -1, -1 } }; // kind index or -1
	bool has_jam_shape = false;
	std::array<LaneKind, NUM_LANES> lane_kind{ { LaneKind::Packed, LaneKind::Packed, LaneKind::Packed, LaneKind::Packed } };
	bool has_pass_v = false;
	double pass_v = 2.2;
	std::vector<JamSource> sources;
	bool has_shoulder = false;
	std::vector<std::pair<std::string, int>> shoulder; // [[kind, n]]
	bool has_minis = false;
	int minis = 0;
	bool has_difficulty = false;
	double difficulty = 1;
	Approach approach;
};

struct VillainSpec {
	double s = 0, x = 0, w = 1.84, len = 4.9;
	double base_s = 0, v = 0, v_nominal = 0;
	bool has_base_s = true, has_v_nominal = true;
};

struct HonkResult {
	std::string kind; // "" = null, cheater | yield | letin | noway | villain | tired
	int id = 0;
	bool villain = false;
};

struct RageResult {
	std::vector<int> smashed, towed, cheaters, startled;
};

struct Tables {
	std::vector<KindInfo> kinds; // index = kind id
	WeightTable npc_kinds, cheater_kinds;
	std::vector<uint32_t> colors_mono, colors_pop;
	std::vector<int> slow_kinds;
	std::vector<std::string> mini_types; // order = RNG order
	std::array<int, 4> breakdown_kinds{ { -1, -1, -1, -1 } }; // shoulder.js:49
	std::array<uint32_t, 4> breakdown_colors{ { 0xf4f4f2u, 0x9aa1a9u, 0x2b2d31u, 0x2a5db0u } };
	std::array<int, NUM_LANES> front_row_fallback{ { -1, -1, -1, -1 } };
	std::vector<std::pair<std::string, int>> shoulder_fallback, dark_spec, debris_spec;
	[[nodiscard]] int kind_index(const std::string &p_name) const;
};

class TrafficCore {
public:
	Params P;
	Tables T;

	// --- setup ---------------------------------------------------------------------------------
	void clear();
	void spawn_jam(const StageSpec &p_stage, const std::vector<VillainSpec> &p_villains, double p_player_s,
			int p_player_lane, uint32_t p_seed, bool p_night);

	// --- per-tick inputs ---------------------------------------------------------------------------
	Ent player;
	std::vector<std::unique_ptr<Ent>> villains; // identity kept across ticks
	std::vector<std::unique_ptr<Ent>> extras;
	void set_villain_count(int p_n);
	void set_extra_count(int p_n);
	bool phase_jam = true;
	bool allow_events = true;
	bool jam_like = true;
	bool has_focus = false;
	double focus_s = 0;
	// R2 (NATIVE_PORT M1b): stuck assist runs while jamLike (native) or only in phase 'jam' (web oracle).
	bool web_parity = false;
	// One-shot override of sin(t*lfFreq + lane*lfLanePhase) for lanes 0..4 (golden replay, libm-free).
	bool sin_override = false;
	std::array<double, ALL_LANES> sin_lf{};

	void update(double p_dt, double p_time);

	// --- calls made between updates (main.js) -------------------------------------------------------
	HonkResult honk(bool p_siren, bool p_trot);
	RageResult rage_horn(double p_range);
	std::string mini_hit(int p_car_id, double p_dmg); // "" | "hit" | "down"
	bool smash(int p_obstacle_id);
	bool remove_obstacle(int p_obstacle_id); // main.js splices obstacles directly (tow)
	void jolt(int p_car_id);
	void release(double p_time, double p_wave_speed, int p_open_lane);
	void drop_walls(const std::vector<int> &p_lanes, double p_meters);
	void emit_brake_wave(int p_lane, double p_s, double p_strength, double p_amp, double p_speed, double p_hold, double p_life);
	Ent *let_in(int p_lane, Ent &p_who, bool p_force);

	// --- queries (previous tick's buckets, like the web) ----------------------------------------------
	[[nodiscard]] bool occupies(const Ent &p_e, int p_lane) const;
	[[nodiscard]] double lane_x(double p_lane) const { return (p_lane - (NUM_LANES - 1) / 2.0) * P.lane_w; }
	struct Leader {
		Ent *car = nullptr;
		double gap = INF;
	};
	Leader leader_of(const Ent &p_e) const;
	Ent *lane_blocked(int p_lane, double p_s_min, double p_s_max, const Ent *p_exclude) const;
	Ent *can_merge_into(int p_lane, const Ent &p_who, double p_margin) const;
	Leader gap_ahead(int p_lane, double p_s, const Ent *p_exclude) const;
	Ent *mini_target() const;
	std::vector<int> cars_behind_front(int p_n, double p_range) const;
	Ent *find_car(int p_id);
	Ent *find_obstacle(int p_id);
	Ent *find_any(int p_id);

	// --- state ------------------------------------------------------------------------------------
	std::deque<Ent> storage; // cars + obstacles (stable addresses)
	std::vector<Ent *> cars;
	std::vector<Ent *> obstacles;
	std::vector<Opp> opp;
	std::array<std::vector<Ent *>, ALL_LANES> buckets;
	std::vector<double> barrier_s; // closed shoulder decor (no collision)
	std::vector<Wave> waves;
	std::vector<Event> events;
	Approach approach;
	StageSpec stage;
	Mulberry32 rng;
	double time = 0, front_line = 0, front_v = 0, jam_speed = 2.4, s_tail = 0;
	bool released = false, zigzag = false, shoulder_closed = false, night = false, spawned = false;
	double release_time = 0;
	int released_count = 0, assists = 0, next_id = 1;
	bool has_next_cheater = false;
	double next_cheater = 0;
	double stuck_t = 0, stuck_for = 0, jam_src_t = 0;
	int64_t tick_count = 0;
	int spawn_draws = 0;

	// RNG trace (tests): every draw as (tag, u32).
	bool trace_on = false;
	std::vector<std::pair<const char *, uint32_t>> trace;
	int64_t draws = 0;

private:
	double draw(const char *p_tag);
	int pick_weighted(const WeightTable &p_table, const char *p_tag);
	Ent &make_car(int p_kind, int p_lane, double p_s, double p_v, const char *p_ctx);
	Ent &add_obstacle(ObKind p_kind, double p_s, bool p_dark);
	void build_buckets();
	[[nodiscard]] LaneKind lane_kind_of(int p_lane) const;
	void stuck_assist(double p_dt);
	void spawn_cheater_ahead();
	bool has_gap(int p_lane, const Ent &p_who) const;
	void pull_ahead();
	bool safe_to_enter(const Ent &p_c, int p_lane, double p_margin) const;
	void start_lane_change(Ent &p_c, int p_lane, double p_dur);
	void post_release_lane_change(Ent &p_c);
	void update_jam_shape(double p_dt, double p_t, const std::vector<Ent *> &p_alive);
	void push_event(const char *p_type, int p_id, const std::string &p_data = std::string(), double p_value = 0);
	std::vector<Ent *> alive_villains_;
	std::vector<Ent *> bucket_extra_;
};

} // namespace lane1::sim
