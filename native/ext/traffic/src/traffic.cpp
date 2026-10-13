#include "traffic.h"

#include "json_exact.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cmath>
#include <cstring>
#include <limits>
#include <string>
#include <vector>

namespace lane1 {

using godot::Array;
using godot::Dictionary;
using godot::PackedByteArray;
using godot::PackedFloat32Array;
using godot::PackedFloat64Array;
using godot::PackedInt32Array;
using godot::PackedStringArray;
using godot::String;
using godot::Variant;

namespace {

constexpr const char *k_ext_version = "0.2.0-m1a";
#ifdef DEBUG_ENABLED
constexpr const char *k_build = "debug";
#else
constexpr const char *k_build = "release";
#endif

std::string to_std(const String &p_s) { return std::string(p_s.utf8().get_data()); }

bool truthy(const Variant &p_v) {
	switch (p_v.get_type()) {
		case Variant::NIL:
			return false;
		case Variant::BOOL:
			return bool(p_v);
		case Variant::INT:
			return int64_t(p_v) != 0;
		case Variant::FLOAT: {
			const double d = double(p_v);
			return d != 0 && !std::isnan(d);
		}
		case Variant::STRING:
			return !String(p_v).is_empty();
		default:
			return true;
	}
}

bool is_num(const Variant &p_v) { return p_v.get_type() == Variant::FLOAT || p_v.get_type() == Variant::INT; }

// Dotted path lookup in nested Dictionaries; NIL if any segment is missing.
Variant dig(const Variant &p_root, const char *p_path) {
	Variant cur = p_root;
	const char *seg = p_path;
	while (*seg) {
		const char *dot = std::strchr(seg, '.');
		const size_t n = dot ? static_cast<size_t>(dot - seg) : std::strlen(seg);
		if (cur.get_type() != Variant::DICTIONARY) {
			return Variant();
		}
		const Dictionary d = cur;
		const String key = String::utf8(seg, static_cast<int64_t>(n));
		if (!d.has(key)) {
			return Variant();
		}
		cur = d[key];
		seg = dot ? dot + 1 : seg + n;
	}
	return cur;
}

// Reads JSON tables into the core's Params; counts what was found so tests can assert full coverage.
struct ParamLoader {
	const Dictionary &root;
	int64_t loaded = 0;
	PackedStringArray missing;

	void num(const char *p_path, double &r_out) {
		const Variant v = dig(root, p_path);
		if (is_num(v)) {
			r_out = double(v);
			++loaded;
		} else {
			missing.push_back(String(p_path));
		}
	}
	void num(const char *p_path, int &r_out) {
		double d = r_out;
		num(p_path, d);
		r_out = static_cast<int>(d);
	}
	void flag(const char *p_path, bool &r_out) {
		const Variant v = dig(root, p_path);
		if (v.get_type() == Variant::BOOL) {
			r_out = bool(v);
			++loaded;
		} else {
			missing.push_back(String(p_path));
		}
	}
	void pair(const char *p_path, double &r_a, double &r_b) {
		const Variant v = dig(root, p_path);
		if (v.get_type() == Variant::ARRAY && Array(v).size() >= 2) {
			const Array a = v;
			r_a = double(a[0]);
			r_b = double(a[1]);
			++loaded;
		} else {
			missing.push_back(String(p_path));
		}
	}
	void lane(const char *p_base, sim::Params::LaneIdm &r_l, const char *p_mul_key) {
		const std::string b(p_base);
		num((b + ".T").c_str(), r_l.T);
		num((b + ".s0").c_str(), r_l.s0);
		num((b + ".aMax").c_str(), r_l.a_max);
		num((b + "." + p_mul_key).c_str(), r_l.v0_mul);
	}
};

void load_params(ParamLoader &L, sim::Params &P) {
	L.num("config.road.laneW", P.lane_w);
	L.num("config.traffic.occupancy.halfLaneMargin", P.half_lane_margin);
	{
		const Variant v = dig(L.root, "config.road.oppLaneX");
		if (v.get_type() == Variant::ARRAY && Array(v).size() >= 4) {
			const Array a = v;
			for (int i = 0; i < 4; ++i) {
				P.opp_lane_x[static_cast<size_t>(i)] = double(a[i]);
			}
			++L.loaded;
		} else {
			L.missing.push_back("config.road.oppLaneX");
		}
	}
	auto &c = P.car;
	L.num("config.traffic.car.monoP", c.mono_p);
	L.num("config.traffic.car.seedScale", c.seed_scale);
	L.num("config.traffic.car.personalBase", c.personal_base);
	L.num("config.traffic.car.personalSpan", c.personal_span);
	L.num("config.traffic.car.lcDurDefault", c.lc_dur_default);
	L.num("config.traffic.car.vFreeDefault", c.v_free_default);
	L.num("config.traffic.car.lenFallback", c.len_fallback);
	L.num("config.traffic.car.wFallback", c.w_fallback);

	auto &s = P.spawn;
	const char *sp = "config.traffic.spawn.";
	auto sn = [&](const char *p_k, double &r) { L.num((std::string(sp) + p_k).c_str(), r); };
	auto si = [&](const char *p_k, int &r) { L.num((std::string(sp) + p_k).c_str(), r); };
	sn("wallOffsetSpan", s.wall_offset_span);
	sn("emptyFrontRearBack", s.empty_front_rear_back);
	sn("gap.packed.base", s.gap_packed.base);
	sn("gap.packed.span", s.gap_packed.span);
	L.flag("config.traffic.spawn.gap.packed.dividedByDensity", s.packed_divided_by_density);
	sn("gap.train.base", s.gap_train.base);
	sn("gap.train.span", s.gap_train.span);
	sn("gap.flow.base", s.gap_flow.base);
	sn("gap.flow.span", s.gap_flow.span);
	sn("gap.spaced.base", s.gap_spaced.base);
	sn("gap.spaced.span", s.gap_spaced.span);
	sn("gap.pass.base", s.gap_pass.base);
	sn("gap.pass.span", s.gap_pass.span);
	sn("leadGap.base", s.lead_base);
	sn("leadGap.span", s.lead_span);
	sn("leadGap.spacedBase", s.lead_spaced_base);
	sn("leadGap.spacedSpan", s.lead_spaced_span);
	sn("leadGap.zigExtra", s.lead_zig_extra);
	sn("laneCarV0Mul", s.lane_car_v0_mul);
	sn("playerHoleHalf", s.player_hole_half);
	sn("playerHolePushBack", s.player_hole_push_back);
	sn("tailBehindPlayer", s.tail_behind_player);
	sn("shoulderStartAhead", s.shoulder_start_ahead);
	sn("shoulderEndBeforeFront", s.shoulder_end_before_front);
	sn("jitterBase", s.jitter_base);
	sn("jitterSpan", s.jitter_span);
	sn("cheaterSpawnV", s.cheater_spawn_v);
	sn("cheaterVBase", s.cheater_v_base);
	sn("cheaterVSpan", s.cheater_v_span);
	si("crowdedCheaters", s.crowded_cheaters);
	sn("obstacleXOffset", s.obstacle_x_offset);
	si("blocked.count", s.blocked_count);
	sn("blocked.spacing", s.blocked_spacing);
	sn("blocked.startFrac", s.blocked_start_frac);
	sn("barrier.fromBehindPlayer", s.barrier_from_behind_player);
	sn("barrier.pastFront", s.barrier_past_front);
	sn("barrier.spacing", s.barrier_spacing);
	si("minis.base", s.minis_base);
	si("minis.max", s.minis_max);
	si("minis.perDifficulty", s.minis_per_difficulty);
	sn("minis.coolBase", s.minis_cool_base);
	sn("minis.hp", s.minis_hp);
	sn("minis.window", s.minis_window);
	si("opp.count", s.opp_count);
	si("opp.lanes", s.opp_lanes);
	sn("opp.monoP", s.opp_mono_p);
	sn("opp.sBehind", s.opp_s_behind);
	sn("opp.sSpan", s.opp_s_span);
	sn("opp.vBase", s.opp_v_base);
	sn("opp.vPerLane", s.opp_v_per_lane);
	sn("opp.vSpan", s.opp_v_span);

	auto &I = P.idm;
	L.num("config.traffic.idm.b", I.b);
	L.num("config.traffic.idm.accMin", I.acc_min);
	L.num("config.traffic.idm.brakeV0", I.brake_v0);
	L.num("config.traffic.idm.vFloor", I.v_floor);
	L.num("config.traffic.idm.gapFloor", I.gap_floor);
	L.num("config.traffic.idm.stopGap", I.stop_gap);
	L.lane("config.traffic.idm.lanes.train", I.train, "v0Mul");
	L.lane("config.traffic.idm.lanes.flow", I.flow, "v0Mul");
	L.lane("config.traffic.idm.lanes.spaced", I.spaced, "v0Mul");
	L.lane("config.traffic.idm.lanes.pass", I.pass, "v0MulFallback");
	L.lane("config.traffic.idm.lanes.packed", I.packed, "v0Mul");
	L.num("config.traffic.idm.lanes.packed.lfBase", I.lf_base);
	L.num("config.traffic.idm.lanes.packed.lfAmp", I.lf_amp);
	L.num("config.traffic.idm.lanes.packed.lfFreq", I.lf_freq);
	L.num("config.traffic.idm.lanes.packed.lfLanePhase", I.lf_lane_phase);
	L.num("config.traffic.idm.released.T", I.rel_T);
	L.num("config.traffic.idm.released.s0", I.rel_s0);
	L.num("config.traffic.idm.released.aMax", I.rel_a_max);
	L.num("config.traffic.idm.released.aMaxSlow", I.rel_a_max_slow);
	L.num("config.traffic.idm.wall.T", I.wall_T);
	L.num("config.traffic.idm.wall.s0", I.wall_s0);
	L.num("config.traffic.idm.wall.aMax", I.wall_a_max);
	L.num("config.traffic.idm.wall.follow", I.wall_follow);
	L.num("config.traffic.idm.cheater.T", I.cheat_T);
	L.num("config.traffic.idm.cheater.s0", I.cheat_s0);
	L.num("config.traffic.idm.cheater.aMax", I.cheat_a_max);
	L.num("config.traffic.idm.cheater.v0Fallback", I.cheat_v0_fallback);
	L.num("config.traffic.idm.pull.T", I.pull_T);
	L.num("config.traffic.idm.pull.s0", I.pull_s0);
	L.num("config.traffic.idm.pull.aMax", I.pull_a_max);
	L.num("config.traffic.idm.pull.v0Mul", I.pull_v0_mul);
	L.num("config.traffic.idm.pull.v0MulLetIn", I.pull_v0_mul_let_in);
	L.num("config.traffic.idm.villainWall.back", I.villain_wall_back);
	L.num("config.traffic.idm.villainWall.zigExtra", I.villain_wall_zig_extra);

	auto &u = P.upd;
	const char *up = "config.traffic.update.";
	auto un = [&](const char *p_k, double &r) { L.num((std::string(up) + p_k).c_str(), r); };
	auto ui = [&](const char *p_k, int &r) { L.num((std::string(up) + p_k).c_str(), r); };
	un("randomBrake.ratePerSec", u.brake_rate);
	un("randomBrake.behindPlayer", u.brake_behind);
	un("randomBrake.aheadPlayer", u.brake_ahead);
	un("randomBrake.holdBase", u.brake_hold_base);
	un("randomBrake.holdSpan", u.brake_hold_span);
	un("stuck.vBelow", u.stuck_v_below);
	un("stuck.decay", u.stuck_decay);
	un("stuck.rubberFallback", u.stuck_rubber_fallback);
	un("stuck.rubberSafetyFallback", u.stuck_safety_fallback);
	un("stuck.pullAheadAfter", u.stuck_pull_after);
	un("stuck.towProbeAhead", u.tow_probe_ahead);
	un("stuck.towProbeBehind", u.tow_probe_behind);
	ui("stuck.autoTowAfter", u.auto_tow_after);
	un("cheaterEvent.firstDelay", u.ch_first_delay);
	un("cheaterEvent.minPlayerV", u.ch_min_player_v);
	un("cheaterEvent.nextBase", u.ch_next_base);
	un("cheaterEvent.nextSpan", u.ch_next_span);
	un("cheaterEvent.windowMin", u.ch_window_min);
	un("cheaterEvent.windowMax", u.ch_window_max);
	un("cheaterEvent.blockMargin", u.ch_block_margin);
	un("cheaterEvent.vBase", u.ch_v_base);
	un("cheaterEvent.vSpan", u.ch_v_span);
	un("cheaterEvent.lcDur", u.ch_lc_dur);
	un("minis.dsMin", u.mini_ds_min);
	un("minis.dsMax", u.mini_ds_max);
	un("minis.cutin.dsMin", u.cutin_ds_min);
	un("minis.cutin.blockMargin", u.cutin_block_margin);
	un("minis.cutin.v", u.cutin_v);
	un("minis.cutin.lcDur", u.cutin_lc_dur);
	un("minis.cutin.cool", u.cutin_cool);
	un("minis.throw.coolBase", u.throw_cool_base);
	un("minis.throw.coolSpan", u.throw_cool_span);
	ui("minis.throw.maxActs", u.throw_max_acts);
	un("release.hazard", u.rel_hazard);
	un("release.nextLcBase", u.rel_next_lc_base);
	un("release.nextLcSpan", u.rel_next_lc_span);
	un("release.laneDelayCap", u.rel_lane_delay_cap);
	un("release.wallExtra", u.rel_wall_extra);
	un("release.carExtra", u.rel_car_extra);
	un("laneChange.dtFloor", u.lc_dt_floor);
	un("laneChange.yawMinV", u.lc_yaw_min_v);
	un("laneChange.yawGain", u.lc_yaw_gain);
	un("postRelease.nextBase", u.pr_next_base);
	un("postRelease.nextSpan", u.pr_next_span);
	un("postRelease.slowMargin", u.pr_slow_margin);
	un("postRelease.slowLcDur", u.pr_slow_lc_dur);
	un("postRelease.lookGap", u.pr_look_gap);
	un("postRelease.vMargin", u.pr_v_margin);
	un("postRelease.passMargin", u.pr_pass_margin);
	un("postRelease.passLcDur", u.pr_pass_lc_dur);
	un("postRelease.cheaterReturnMargin", u.pr_cheater_return_margin);
	un("postRelease.cheaterReturnLcDur", u.pr_cheater_return_lc_dur);
	un("opp.recycleBehind", u.opp_recycle_behind);
	un("opp.respawnAhead", u.opp_respawn_ahead);
	un("opp.respawnSpan", u.opp_respawn_span);
	un("jamWave.amp", u.wave_amp);
	un("jamWave.speed", u.wave_speed);
	un("jamWave.hold", u.wave_hold);
	un("jamWave.life", u.wave_life);
	un("jamWave.minStrength", u.wave_min_strength);
	un("jamWave.hitMargin", u.wave_hit_margin);
	un("jamWave.holdCap", u.wave_hold_cap);
	un("yieldSource.behind", u.ys_behind);
	un("yieldSource.ahead", u.ys_ahead);
	un("yieldSource.holdFallback", u.ys_hold_fallback);
	un("yieldSource.periodFallback", u.ys_period_fallback);
	un("yieldSource.waveOffset", u.ys_wave_offset);
	un("yieldSource.waveStrength", u.ys_wave_strength);
	un("yieldSource.waveAmp", u.ys_wave_amp);
	un("brakeLight.accBelow", u.bl_acc_below);
	un("brakeLight.vBelow", u.bl_v_below);
	un("brakeLight.flickerFreq", u.bl_flicker_freq);
	un("brakeLight.flickerAbove", u.bl_flicker_above);
	un("hazard.period", u.hz_period);
	un("hazard.onFrac", u.hz_on_frac);
	un("hazard.cheaterFreq", u.hz_cheater_freq);

	auto &q = P.q;
	const char *qp = "config.traffic.queries.";
	auto qn = [&](const char *p_k, double &r) { L.num((std::string(qp) + p_k).c_str(), r); };
	auto qi = [&](const char *p_k, int &r) { L.num((std::string(qp) + p_k).c_str(), r); };
	qn("canMergeInto.margin", q.merge_margin);
	qn("canMergeInto.yieldOverlap", q.merge_yield_overlap);
	qn("hasGap.extra", q.has_gap_extra);
	qn("hasGap.lenFallback", q.has_gap_len_fallback);
	qn("hasGap.window", q.has_gap_window);
	qn("letIn.aheadMin", q.let_in_ahead_min);
	qn("letIn.aheadMax", q.let_in_ahead_max);
	qn("letIn.behindMax", q.let_in_behind_max);
	qn("letIn.pull", q.let_in_pull);
	qn("letIn.brake", q.let_in_brake);
	qn("letIn.yieldFor", q.let_in_yield_for);
	qn("pullAhead.range", q.pull_ahead_range);
	qn("pullAhead.hold", q.pull_ahead_hold);
	qn("safeToEnter.touch", q.safe_touch);
	qn("safeToEnter.closingGain", q.safe_closing_gain);
	qn("honk.range", q.honk_range);
	qn("honk.rangeSiren", q.honk_range_siren);
	qn("honk.rangeTrot", q.honk_range_trot);
	qn("honk.rangeSlack", q.honk_range_slack);
	qn("honk.probeBack", q.honk_probe_back);
	qn("honk.villainRange", q.honk_villain_range);
	qn("honk.cheaterRange", q.honk_cheater_range);
	qn("honk.cheaterRangeSiren", q.honk_cheater_range_siren);
	qn("honk.cheaterLcDur", q.honk_cheater_lc_dur);
	qn("honk.fatigueRelax", q.honk_fatigue_relax);
	qn("honk.fatigueHalfP", q.honk_fatigue_half_p);
	qn("honk.yieldMargin", q.honk_yield_margin);
	qn("honk.yieldLcDur", q.honk_yield_lc_dur);
	qi("honk.fatigueIgnoreAt", q.honk_fatigue_ignore_at);
	qn("rageHorn.behind", q.rage_behind);
	qn("rageHorn.lcDur", q.rage_lc_dur);
	qn("rageHorn.startledHold", q.rage_startled_hold);
	qn("miniHit.jolt", q.mini_hit_jolt);
	qn("miniHit.brake", q.mini_hit_brake);
	qn("miniHit.hazard", q.mini_hit_hazard);
	qn("miniHit.lcDur", q.mini_hit_lc_dur);
	qn("miniTarget.behind", q.mini_target_behind);
	qn("miniTarget.ahead", q.mini_target_ahead);
	qn("miniTarget.lateralLanes", q.mini_target_lateral);
	qi("carsBehindFront.n", q.behind_front_n);
	qn("carsBehindFront.range", q.behind_front_range);

	L.num("config.tune.releaseLaneDelay", P.tune.release_lane_delay);
	L.num("config.tune.releaseWaveSpeed", P.tune.release_wave_speed);
	L.pair("config.tune.releaseSpeed", P.tune.release_lo, P.tune.release_hi);
	L.pair("config.tune.truckFreeSpeed", P.tune.truck_lo, P.tune.truck_hi);
	L.num("config.tune.rageHornRange", P.tune.rage_horn_range);
}

sim::WeightTable weight_table(const sim::Tables &p_t, const Variant &p_v, PackedStringArray &r_missing, const char *p_name) {
	sim::WeightTable out;
	if (p_v.get_type() != Variant::ARRAY) {
		r_missing.push_back(String(p_name));
		return out;
	}
	const Array a = p_v;
	for (int64_t i = 0; i < a.size(); ++i) {
		const Array e = a[i];
		if (e.size() < 2) {
			continue;
		}
		out.emplace_back(p_t.kind_index(to_std(String(e[0]))), double(e[1]));
	}
	return out;
}

std::vector<std::pair<std::string, int>> spec_list(const Variant &p_v) {
	std::vector<std::pair<std::string, int>> out;
	if (p_v.get_type() != Variant::ARRAY) {
		return out;
	}
	const Array a = p_v;
	for (int64_t i = 0; i < a.size(); ++i) {
		const Array e = a[i];
		if (e.size() < 2) {
			continue;
		}
		out.emplace_back(to_std(String(e[0])), static_cast<int>(double(e[1])));
	}
	return out;
}

std::vector<uint32_t> colors(const Variant &p_v) {
	std::vector<uint32_t> out;
	if (p_v.get_type() != Variant::ARRAY) {
		return out;
	}
	const Array a = p_v;
	for (int64_t i = 0; i < a.size(); ++i) {
		out.push_back(static_cast<uint32_t>(int64_t(a[i])));
	}
	return out;
}

sim::LaneKind lane_kind_of(const String &p_s) {
	if (p_s == "train") {
		return sim::LaneKind::Train;
	}
	if (p_s == "flow") {
		return sim::LaneKind::Flow;
	}
	if (p_s == "spaced") {
		return sim::LaneKind::Spaced;
	}
	if (p_s == "pass") {
		return sim::LaneKind::Pass;
	}
	return sim::LaneKind::Packed;
}

const char *lane_kind_name(sim::LaneKind p_k) {
	switch (p_k) {
		case sim::LaneKind::Train:
			return "train";
		case sim::LaneKind::Flow:
			return "flow";
		case sim::LaneKind::Spaced:
			return "spaced";
		case sim::LaneKind::Pass:
			return "pass";
		default:
			return "packed";
	}
}

void apply_approach(sim::Approach &r_a, const Variant &p_v) {
	if (p_v.get_type() != Variant::DICTIONARY) {
		return;
	}
	const Dictionary d = p_v;
	if (d.has("shoulder") && d["shoulder"].get_type() == Variant::STRING) {
		r_a.shoulder = to_std(String(d["shoulder"]));
	}
	if (d.has("gapCheck") && d["gapCheck"].get_type() != Variant::NIL) {
		r_a.gap_check = truthy(d["gapCheck"]);
	}
	if (d.has("fatigue") && d["fatigue"].get_type() != Variant::NIL) {
		r_a.fatigue = truthy(d["fatigue"]);
	}
	if (d.has("rubber") && is_num(d["rubber"])) {
		r_a.rubber = double(d["rubber"]);
		r_a.has_rubber = true;
	}
	if (d.has("rubberSafety") && is_num(d["rubberSafety"])) {
		r_a.rubber_safety = double(d["rubberSafety"]);
		r_a.has_rubber_safety = true;
	}
	if (d.has("rageHorn") && is_num(d["rageHorn"])) {
		r_a.rage_horn = double(d["rageHorn"]);
		r_a.has_rage_horn = true;
	}
}

PackedInt32Array to_packed(const std::vector<int> &p_v) {
	PackedInt32Array out;
	out.resize(static_cast<int64_t>(p_v.size()));
	for (size_t i = 0; i < p_v.size(); ++i) {
		out.set(static_cast<int64_t>(i), p_v[i]);
	}
	return out;
}

const char *type_name(sim::EType p_t) {
	switch (p_t) {
		case sim::EType::Car:
			return "car";
		case sim::EType::Obstacle:
			return "obstacle";
		case sim::EType::Player:
			return "player";
		case sim::EType::Villain:
			return "villain";
		default:
			return "extra";
	}
}

} // namespace

// =============================================================================================== Rng32
void Rng32::set_seed(int64_t p_seed) {
	seed_ = p_seed;
	rng_ = sim::Mulberry32(static_cast<uint32_t>(p_seed));
	draws_ = 0;
}
int64_t Rng32::get_seed() const { return seed_; }
int64_t Rng32::next_u32() {
	++draws_;
	return static_cast<int64_t>(rng_.next_u32());
}
double Rng32::next_float() {
	++draws_;
	return rng_.next();
}
int64_t Rng32::get_draws() const { return draws_; }

void Rng32::_bind_methods() {
	using godot::ClassDB;
	using godot::D_METHOD;
	ClassDB::bind_method(D_METHOD("set_seed", "seed"), &Rng32::set_seed);
	ClassDB::bind_method(D_METHOD("get_seed"), &Rng32::get_seed);
	ClassDB::bind_method(D_METHOD("next_u32"), &Rng32::next_u32);
	ClassDB::bind_method(D_METHOD("next_float"), &Rng32::next_float);
	ClassDB::bind_method(D_METHOD("get_draws"), &Rng32::get_draws);
}

// ============================================================================================= Traffic
void Traffic::tick(double p_dt) {
	ERR_FAIL_COND_MSG(!std::isfinite(p_dt) || p_dt < 0.0, "Traffic.tick: dt must be finite and >= 0.");
	sim_time_ += p_dt;
	if (core_.spawned) {
		core_.update(p_dt, sim_time_);
	}
	++tick_count_;
}

int64_t Traffic::count() const { return core_.spawned ? static_cast<int64_t>(core_.cars.size()) : 0; }
int64_t Traffic::get_tick_count() const { return tick_count_; }
double Traffic::get_sim_time() const { return sim_time_; }

godot::String Traffic::build_info() {
	return godot::vformat("traffic %s godot-cpp %s api %s %s", k_ext_version, LANE1_GODOT_CPP_VERSION, LANE1_GODOT_API_VERSION, k_build);
}

godot::Variant Traffic::parse_json(const String &p_text) {
	String err;
	Variant v = parse_json_exact(p_text, &err);
	if (!err.is_empty()) {
		ERR_PRINT(err);
	}
	return v;
}

bool Traffic::configure(const Dictionary &p_tables) {
	sim::Params P; // defaults = JS literals
	sim::Tables T;
	ParamLoader L{ p_tables, 0, PackedStringArray() };
	// kinds (vehicle_kinds.json): index = file order
	const Variant kv = dig(p_tables, "vehicle_kinds.kinds");
	ERR_FAIL_COND_V_MSG(kv.get_type() != Variant::DICTIONARY, false, "Traffic.configure: vehicle_kinds.kinds missing");
	const Dictionary kinds = kv;
	const Array names = kinds.keys();
	for (int64_t i = 0; i < names.size(); ++i) {
		const Dictionary k = kinds[names[i]];
		sim::KindInfo ki;
		ki.name = to_std(String(names[i]));
		ki.variants = static_cast<int>(int64_t(k.get("variants", 1)));
		ki.color_variant = truthy(k.get("colorVariant", false));
		ki.canon.clear();
		const Array canon = k.get("canon", Array());
		for (int64_t j = 0; j < canon.size(); ++j) {
			ki.canon.push_back(static_cast<int>(int64_t(canon[j])));
		}
		if (ki.canon.empty()) {
			ki.canon.push_back(0);
		}
		auto dims = [](const Variant &p_v, std::vector<sim::Dim> &r_out) {
			if (p_v.get_type() != Variant::ARRAY) {
				return;
			}
			const Array a = p_v;
			for (int64_t j = 0; j < a.size(); ++j) {
				const Dictionary d = a[j];
				r_out.push_back(sim::Dim{ double(d.get("L", 0)), double(d.get("W", 0)), double(d.get("H", 0)) });
			}
		};
		dims(dig(k, "dims.simple"), ki.simple);
		dims(dig(k, "dims.detailed"), ki.detailed);
		T.kinds.push_back(std::move(ki));
	}
	T.npc_kinds = weight_table(T, dig(p_tables, "config.npc.kinds"), L.missing, "config.npc.kinds");
	T.colors_mono = colors(dig(p_tables, "config.npc.colorsMono"));
	T.colors_pop = colors(dig(p_tables, "config.npc.colorsPop"));
	T.cheater_kinds = weight_table(T, dig(p_tables, "config.traffic.spawn.cheaterKinds"), L.missing, "config.traffic.spawn.cheaterKinds");
	{
		const Variant sk = dig(p_tables, "config.traffic.car.slowKinds");
		if (sk.get_type() == Variant::ARRAY) {
			const Array a = sk;
			for (int64_t i = 0; i < a.size(); ++i) {
				T.slow_kinds.push_back(T.kind_index(to_std(String(a[i]))));
			}
		} else {
			L.missing.push_back("config.traffic.car.slowKinds");
		}
	}
	{
		const Variant fr = dig(p_tables, "config.traffic.spawn.frontRowFallback");
		if (fr.get_type() == Variant::ARRAY) {
			const Array a = fr;
			for (int64_t i = 0; i < a.size() && i < sim::NUM_LANES; ++i) {
				T.front_row_fallback[static_cast<size_t>(i)] = a[i].get_type() == Variant::STRING ? T.kind_index(to_std(String(a[i]))) : -1;
			}
		} else {
			L.missing.push_back("config.traffic.spawn.frontRowFallback");
		}
	}
	T.shoulder_fallback = spec_list(dig(p_tables, "config.traffic.spawn.shoulderFallbackSpec"));
	T.dark_spec = spec_list(dig(p_tables, "config.traffic.spawn.darkSpec"));
	T.debris_spec = spec_list(dig(p_tables, "config.traffic.spawn.debrisSpec"));
	{
		const char *bk[4] = { "sedan", "van", "pickup1t", "compact" }; // shoulder.js:49
		for (int i = 0; i < 4; ++i) {
			T.breakdown_kinds[static_cast<size_t>(i)] = T.kind_index(bk[i]);
		}
	}
	{
		const Variant mt = dig(p_tables, "mini_types.types");
		if (mt.get_type() == Variant::ARRAY) {
			const Array a = mt;
			for (int64_t i = 0; i < a.size(); ++i) {
				T.mini_types.push_back(to_std(String(Dictionary(a[i]).get("id", ""))));
			}
		} else {
			L.missing.push_back("mini_types.types");
		}
	}
	load_params(L, P);
	const Variant ad = dig(p_tables, "approach.default");
	approach_default_ = ad.get_type() == Variant::DICTIONARY ? Dictionary(ad) : Dictionary();
	if (approach_default_.is_empty()) {
		L.missing.push_back("approach.default");
	}
	core_.P = P;
	core_.T = std::move(T);
	loaded_params_ = L.loaded;
	missing_params_ = L.missing;
	configured_ = true;
	return true;
}

PackedStringArray Traffic::get_missing_params() const { return missing_params_; }
int64_t Traffic::get_loaded_params() const { return loaded_params_; }

bool Traffic::spawn_jam(const Dictionary &p_stage, const Array &p_villains, const Dictionary &p_player_start, int64_t p_seed, bool p_night) {
	ERR_FAIL_COND_V_MSG(!configured_, false, "Traffic.spawn_jam: call configure() first");
	ERR_FAIL_COND_V_MSG(p_villains.is_empty(), false, "Traffic.spawn_jam: needs at least one villain (sFront = max villain s)");
	sim::StageSpec st;
	st.id = static_cast<int>(int64_t(p_stage.get("id", 1)));
	st.jam_speed = double(p_stage.get("jamSpeed", 2.4));
	const Variant dens = p_stage.get("density", Variant());
	st.density = is_num(dens) ? double(dens) : 1.0;
	bool zig = truthy(p_stage.get("zig", Variant()));
	const Variant atk = p_stage.get("attacks", Variant());
	if (atk.get_type() == Variant::ARRAY) { // [[kind, weight]] (exported from the JS object)
		const Array a = atk;
		for (int64_t i = 0; i < a.size(); ++i) {
			const Array e = a[i];
			if (e.size() >= 2 && String(e[0]) == "zigzag" && truthy(e[1])) {
				zig = true;
			}
		}
	} else if (atk.get_type() == Variant::DICTIONARY && truthy(Dictionary(atk).get("zigzag", Variant()))) {
		zig = true;
	}
	st.zig = zig;
	const Variant zc = p_stage.get("zigCenter", Variant());
	st.zig_center = is_num(zc) ? static_cast<int>(double(zc)) : 1;
	const Variant fr = p_stage.get("frontRow", Variant());
	if (fr.get_type() == Variant::ARRAY) {
		st.has_front_row = true;
		const Array a = fr;
		for (int64_t i = 0; i < a.size() && i < sim::NUM_LANES; ++i) {
			st.front_row[static_cast<size_t>(i)] = a[i].get_type() == Variant::STRING ? core_.T.kind_index(to_std(String(a[i]))) : -1;
		}
	}
	const Variant js = p_stage.get("jamShape", Variant());
	if (js.get_type() == Variant::DICTIONARY) {
		const Dictionary d = js;
		st.has_jam_shape = true;
		const Variant lanes = d.get("lanes", Variant());
		if (lanes.get_type() == Variant::ARRAY) {
			const Array a = lanes;
			for (int64_t i = 0; i < a.size() && i < sim::NUM_LANES; ++i) {
				if (truthy(a[i])) {
					st.lane_kind[static_cast<size_t>(i)] = lane_kind_of(String(a[i]));
				}
			}
		}
		const Variant pv = d.get("passV", Variant());
		if (is_num(pv)) {
			st.has_pass_v = true;
			st.pass_v = double(pv);
		}
		const Variant srcs = d.get("sources", Variant());
		if (srcs.get_type() == Variant::ARRAY) {
			const Array a = srcs;
			for (int64_t i = 0; i < a.size(); ++i) {
				const Dictionary s = a[i];
				sim::JamSource js_;
				js_.type = to_std(String(s.get("type", "")));
				const Variant ln = s.get("lane", Variant());
				js_.lane = is_num(ln) ? static_cast<int>(double(ln)) : 0;
				const Variant hd = s.get("hold", Variant());
				js_.has_hold = is_num(hd);
				js_.hold = js_.has_hold ? double(hd) : 2.5;
				const Variant pd = s.get("period", Variant());
				js_.has_period = is_num(pd);
				js_.period = js_.has_period ? double(pd) : 2.5;
				st.sources.push_back(js_);
			}
		}
	}
	const Variant sh = p_stage.get("shoulder", Variant());
	if (sh.get_type() == Variant::ARRAY) {
		st.has_shoulder = true;
		st.shoulder = spec_list(sh);
	}
	const Variant mn = p_stage.get("minis", Variant());
	if (is_num(mn)) {
		st.has_minis = true;
		st.minis = static_cast<int>(double(mn));
	}
	const Variant df = p_stage.get("difficulty", Variant());
	if (is_num(df)) {
		st.has_difficulty = true;
		st.difficulty = double(df);
	}
	apply_approach(st.approach, approach_default_);
	apply_approach(st.approach, p_stage.get("approach", Variant()));

	std::vector<sim::VillainSpec> vs;
	for (int64_t i = 0; i < p_villains.size(); ++i) {
		const Dictionary d = p_villains[i];
		sim::VillainSpec v;
		v.s = double(d.get("s", 0));
		v.x = double(d.get("x", 0));
		v.w = double(d.get("w", 1.84));
		v.len = double(d.get("len", 4.9));
		v.base_s = double(d.get("baseS", v.s));
		v.v = double(d.get("v", st.jam_speed));
		v.v_nominal = double(d.get("vNominal", v.v));
		vs.push_back(v);
	}
	const double ps = double(p_player_start.get("s", 0));
	const int pl = static_cast<int>(int64_t(p_player_start.get("lane", 3)));
	core_.spawn_jam(st, vs, ps, pl, static_cast<uint32_t>(p_seed), p_night);
	// player + villains start where the stage put them
	sim::Ent &P = core_.player;
	P.type = sim::EType::Player;
	P.id = -1;
	P.s = ps;
	P.lane = pl;
	P.x = core_.lane_x(pl);
	P.len = double(p_player_start.get("len", 4.2));
	P.w = double(p_player_start.get("w", 1.92));
	P.v = 0;
	P.mode_jam = true;
	core_.set_villain_count(static_cast<int>(vs.size()));
	for (size_t i = 0; i < vs.size(); ++i) {
		sim::Ent &v = *core_.villains[i];
		v.id = -100 - static_cast<int>(i);
		v.s = vs[i].s;
		v.base_s = vs[i].base_s;
		v.has_base_s = true;
		v.x = vs[i].x;
		v.w = vs[i].w;
		v.len = vs[i].len;
		v.v = vs[i].v;
		v.v_nominal = vs[i].v_nominal;
		v.has_v_nominal = true;
		v.alive = true;
	}
	core_.set_extra_count(0);
	sim_time_ = 0;
	return true;
}

bool Traffic::is_spawned() const { return core_.spawned; }

PackedStringArray Traffic::kind_names() const {
	PackedStringArray out;
	for (const auto &k : core_.T.kinds) {
		out.push_back(String::utf8(k.name.c_str()));
	}
	return out;
}

int64_t Traffic::kind_index(const String &p_name) const { return core_.T.kind_index(to_std(p_name)); }

void Traffic::set_player(double p_s, double p_x, double p_v, int64_t p_lane, bool p_mode_jam) {
	sim::Ent &P = core_.player;
	P.type = sim::EType::Player;
	P.s = p_s;
	P.x = p_x;
	P.v = p_v;
	P.lane = static_cast<int>(p_lane);
	P.mode_jam = p_mode_jam;
}

void Traffic::set_player_dims(double p_len, double p_w) {
	core_.player.len = p_len;
	core_.player.w = p_w;
}

void Traffic::set_player_stats(bool p_tow) { core_.player.stats_tow = p_tow; }

void Traffic::set_villain_count(int64_t p_n) { core_.set_villain_count(static_cast<int>(p_n)); }

void Traffic::set_villain(int64_t p_i, double p_s, double p_base_s, double p_x, double p_w, double p_len, double p_v, double p_v_nominal,
		bool p_alive) {
	ERR_FAIL_INDEX(p_i, static_cast<int64_t>(core_.villains.size()));
	sim::Ent &v = *core_.villains[static_cast<size_t>(p_i)];
	v.s = p_s;
	v.has_base_s = !std::isnan(p_base_s);
	v.base_s = p_base_s;
	v.x = p_x;
	v.w = p_w;
	v.len = p_len;
	v.v = p_v;
	v.has_v_nominal = !std::isnan(p_v_nominal);
	v.v_nominal = p_v_nominal;
	v.alive = p_alive;
}

void Traffic::set_extra_count(int64_t p_n) { core_.set_extra_count(static_cast<int>(p_n)); }

void Traffic::set_extra(int64_t p_i, double p_s, double p_x, double p_w, double p_len, double p_v, bool p_alive) {
	ERR_FAIL_INDEX(p_i, static_cast<int64_t>(core_.extras.size()));
	sim::Ent &e = *core_.extras[static_cast<size_t>(p_i)];
	e.id = -1000 - static_cast<int>(p_i);
	e.s = p_s;
	e.x = p_x;
	e.w = p_w;
	e.len = p_len;
	e.v = p_v;
	e.alive = p_alive;
}

void Traffic::set_context(const String &p_phase, bool p_allow_events, bool p_jam_like, double p_focus_s) {
	core_.phase_jam = p_phase == "jam";
	core_.allow_events = p_allow_events;
	core_.jam_like = p_jam_like;
	core_.has_focus = !std::isnan(p_focus_s);
	core_.focus_s = p_focus_s;
}

void Traffic::set_web_parity(bool p_on) { core_.web_parity = p_on; }
bool Traffic::get_web_parity() const { return core_.web_parity; }

void Traffic::set_sin_override(const PackedFloat64Array &p_sin_lf) {
	ERR_FAIL_COND_MSG(p_sin_lf.size() < sim::ALL_LANES, "Traffic.set_sin_override: need 5 values (lanes 0..4)");
	for (int i = 0; i < sim::ALL_LANES; ++i) {
		core_.sin_lf[static_cast<size_t>(i)] = p_sin_lf[i];
	}
	core_.sin_override = true;
}

void Traffic::update(double p_dt, double p_time) {
	ERR_FAIL_COND_MSG(!core_.spawned, "Traffic.update: spawn_jam() first");
	ERR_FAIL_COND_MSG(!std::isfinite(p_dt) || p_dt < 0.0, "Traffic.update: dt must be finite and >= 0.");
	core_.update(p_dt, p_time);
	sim_time_ = p_time;
	++tick_count_;
}

Dictionary Traffic::honk(bool p_siren, bool p_trot) {
	Dictionary out;
	const sim::HonkResult r = core_.honk(p_siren, p_trot);
	out["kind"] = String(r.kind.c_str());
	out["id"] = r.id;
	return out;
}

Dictionary Traffic::rage_horn(double p_range) {
	const sim::RageResult r = core_.rage_horn(p_range);
	Dictionary out;
	out["smashed"] = to_packed(r.smashed);
	out["towed"] = to_packed(r.towed);
	out["cheaters"] = to_packed(r.cheaters);
	out["startled"] = to_packed(r.startled);
	return out;
}

String Traffic::mini_hit(int64_t p_car_id, double p_dmg) { return String(core_.mini_hit(static_cast<int>(p_car_id), p_dmg).c_str()); }
bool Traffic::smash(int64_t p_obstacle_id) { return core_.smash(static_cast<int>(p_obstacle_id)); }
bool Traffic::remove_obstacle(int64_t p_obstacle_id) { return core_.remove_obstacle(static_cast<int>(p_obstacle_id)); }

void Traffic::set_obstacle_ids(const PackedInt32Array &p_ids) {
	std::vector<sim::Ent *> keep;
	for (sim::Ent *o : core_.obstacles) {
		if (p_ids.has(o->id)) {
			keep.push_back(o);
		}
	}
	core_.obstacles = std::move(keep);
}

void Traffic::jolt(int64_t p_id) { core_.jolt(static_cast<int>(p_id)); }

void Traffic::release(double p_time, double p_wave_speed, int64_t p_open_lane) {
	core_.release(p_time, p_wave_speed, static_cast<int>(p_open_lane));
}

void Traffic::drop_walls(const PackedInt32Array &p_lanes, double p_meters) {
	std::vector<int> lanes;
	for (int64_t i = 0; i < p_lanes.size(); ++i) {
		lanes.push_back(p_lanes[i]);
	}
	core_.drop_walls(lanes, p_meters);
}

void Traffic::emit_brake_wave(int64_t p_lane, double p_s, double p_strength) {
	const double nan = std::numeric_limits<double>::quiet_NaN();
	core_.emit_brake_wave(static_cast<int>(p_lane), p_s, p_strength, nan, nan, nan, nan);
}

int64_t Traffic::let_in_player(int64_t p_lane, bool p_force) {
	const sim::Ent *c = core_.let_in(static_cast<int>(p_lane), core_.player, p_force);
	return c ? c->id : 0;
}

Dictionary Traffic::leader_of_player() const {
	const auto L = core_.leader_of(core_.player);
	Dictionary out;
	out["id"] = L.car ? L.car->id : 0;
	out["gap"] = L.gap;
	out["type"] = L.car ? String(type_name(L.car->type)) : String();
	return out;
}

int64_t Traffic::can_merge_into(int64_t p_lane, double p_margin) const {
	const sim::Ent *o = core_.can_merge_into(static_cast<int>(p_lane), core_.player, p_margin);
	return o ? (o->id != 0 ? o->id : -9999) : 0;
}

int64_t Traffic::lane_blocked(int64_t p_lane, double p_s_min, double p_s_max, int64_t p_exclude_id) const {
	const sim::Ent *ex = p_exclude_id == -1 ? &core_.player : nullptr;
	if (!ex && p_exclude_id != 0) {
		for (const sim::Ent *c : core_.cars) {
			if (c->id == p_exclude_id) {
				ex = c;
			}
		}
	}
	const sim::Ent *o = core_.lane_blocked(static_cast<int>(p_lane), p_s_min, p_s_max, ex);
	return o ? (o->id != 0 ? o->id : -9999) : 0;
}

Dictionary Traffic::gap_ahead(int64_t p_lane, double p_s) const {
	const auto g = core_.gap_ahead(static_cast<int>(p_lane), p_s, &core_.player);
	Dictionary out;
	out["gap"] = g.gap;
	out["id"] = g.car ? g.car->id : 0;
	out["type"] = g.car ? String(type_name(g.car->type)) : String();
	return out;
}

int64_t Traffic::mini_target() const {
	const sim::Ent *c = core_.mini_target();
	return c ? c->id : 0;
}

PackedInt32Array Traffic::cars_behind_front(int64_t p_n, double p_range) const {
	return to_packed(core_.cars_behind_front(static_cast<int>(p_n), p_range));
}

int64_t Traffic::opp_count() const { return static_cast<int64_t>(core_.opp.size()); }
int64_t Traffic::obstacle_count() const { return static_cast<int64_t>(core_.obstacles.size()); }

PackedFloat32Array Traffic::get_buffer(double p_alpha, bool p_include_opp) const {
	const double a = std::isfinite(p_alpha) ? std::max(0.0, std::min(1.0, p_alpha)) : 1.0;
	const size_t n = core_.cars.size() + (p_include_opp ? core_.opp.size() : 0);
	PackedFloat32Array buf;
	buf.resize(static_cast<int64_t>(n * STRIDE));
	float *w = buf.ptrw();
	const int head = core_.night ? LAMP_HEADLIGHTS : 0;
	size_t k = 0;
	for (const sim::Ent *c : core_.cars) {
		int bits = head;
		bits |= c->brake_on ? LAMP_BRAKE : 0;
		bits |= c->blink < 0 ? LAMP_BLINK_LEFT : 0;
		bits |= c->blink > 0 ? LAMP_BLINK_RIGHT : 0;
		bits |= c->hazard_on ? LAMP_HAZARD : 0;
		bits |= (c->has_mini && !c->mini.done) ? LAMP_MINI : 0;
		float *r = w + k * STRIDE;
		r[0] = static_cast<float>(c->id);
		r[1] = static_cast<float>(c->kind);
		r[2] = static_cast<float>(c->lane);
		r[3] = static_cast<float>(c->prev_x + (c->x - c->prev_x) * a);
		r[4] = static_cast<float>(c->prev_s + (c->s - c->prev_s) * a);
		r[5] = static_cast<float>(c->prev_yaw + (c->yaw - c->prev_yaw) * a);
		r[6] = static_cast<float>(c->v);
		r[7] = static_cast<float>(bits);
		++k;
	}
	if (p_include_opp) {
		for (size_t i = 0; i < core_.opp.size(); ++i) {
			const sim::Opp &o = core_.opp[i];
			float *r = w + k * STRIDE;
			r[0] = static_cast<float>(OPP_ID_BASE + static_cast<int>(i));
			r[1] = static_cast<float>(o.kind);
			r[2] = static_cast<float>(-1 - o.j);
			r[3] = static_cast<float>(core_.P.opp_lane_x[static_cast<size_t>(std::max(0, std::min(3, o.j)))]);
			r[4] = static_cast<float>(o.prev_s + (o.s - o.prev_s) * a);
			r[5] = static_cast<float>(3.141592653589793);
			r[6] = static_cast<float>(o.v);
			r[7] = static_cast<float>(head);
			++k;
		}
	}
	return buf;
}

PackedFloat32Array Traffic::get_transforms_for(const PackedInt32Array &p_ids, double p_alpha) const {
	const double a = std::isfinite(p_alpha) ? std::max(0.0, std::min(1.0, p_alpha)) : 1.0;
	// id -> car (ids are small positive ints assigned at spawn)
	int max_id = 0;
	for (const sim::Ent *c : core_.cars) {
		max_id = std::max(max_id, c->id);
	}
	std::vector<const sim::Ent *> by_id(static_cast<size_t>(max_id) + 1, nullptr);
	for (const sim::Ent *c : core_.cars) {
		by_id[static_cast<size_t>(c->id)] = c;
	}
	PackedFloat32Array buf;
	buf.resize(p_ids.size() * 12);
	float *w = buf.ptrw();
	for (int64_t i = 0; i < p_ids.size(); ++i) {
		const int id = p_ids[i];
		double x = 0, s = 0, yaw = 0, scale = 1;
		if (id >= OPP_ID_BASE && id - OPP_ID_BASE < static_cast<int>(core_.opp.size())) {
			const sim::Opp &o = core_.opp[static_cast<size_t>(id - OPP_ID_BASE)];
			x = core_.P.opp_lane_x[static_cast<size_t>(std::max(0, std::min(3, o.j)))];
			s = o.prev_s + (o.s - o.prev_s) * a;
			yaw = 3.141592653589793;
		} else if (id > 0 && id <= max_id && by_id[static_cast<size_t>(id)]) {
			const sim::Ent *c = by_id[static_cast<size_t>(id)];
			x = c->prev_x + (c->x - c->prev_x) * a;
			s = c->prev_s + (c->s - c->prev_s) * a;
			yaw = c->prev_yaw + (c->yaw - c->prev_yaw) * a;
		} else {
			scale = 0;
		}
		const float cy = static_cast<float>(std::cos(yaw) * scale);
		const float sy = static_cast<float>(std::sin(yaw) * scale);
		float *r = w + i * 12;
		r[0] = cy;
		r[1] = 0;
		r[2] = sy;
		r[3] = static_cast<float>(x);
		r[4] = 0;
		r[5] = static_cast<float>(scale);
		r[6] = 0;
		r[7] = 0;
		r[8] = -sy;
		r[9] = 0;
		r[10] = cy;
		r[11] = static_cast<float>(-s);
	}
	return buf;
}

Array Traffic::get_car_specs() const {
	Array out;
	for (const sim::Ent *c : core_.cars) {
		Dictionary d;
		d["id"] = c->id;
		d["kind"] = c->kind;
		d["kind_name"] = c->kind >= 0 ? String::utf8(core_.T.kinds[static_cast<size_t>(c->kind)].name.c_str()) : String();
		d["variant"] = c->variant;
		d["color"] = static_cast<int64_t>(c->color);
		d["seed"] = c->seed;
		d["lane"] = c->lane;
		d["s"] = c->s;
		d["x"] = c->x;
		d["v"] = c->v;
		d["len"] = c->len;
		d["w"] = c->w;
		d["personal"] = c->personal;
		d["phase"] = c->phase;
		d["is_wall"] = c->is_wall;
		d["wall_offset"] = c->wall_offset;
		d["is_cheater"] = c->is_cheater;
		d["cheater_v"] = c->cheater_v;
		d["slow"] = c->slow;
		d["lc_t"] = c->lc_t;
		d["lc_dur"] = c->lc_dur;
		d["v_free"] = c->v_free;
		d["released"] = c->released;
		if (c->has_mini) {
			Dictionary m;
			const int t = c->mini.type;
			m["type"] = t >= 0 && t < static_cast<int>(core_.T.mini_types.size()) ? String(core_.T.mini_types[static_cast<size_t>(t)].c_str()) : String();
			m["hp"] = c->mini.hp;
			m["max"] = c->mini.max;
			m["cool"] = c->mini.cool;
			m["acted"] = c->mini.acted;
			m["done"] = c->mini.done;
			d["mini"] = m;
		} else {
			d["mini"] = Variant();
		}
		out.push_back(d);
	}
	return out;
}

Array Traffic::get_obstacles() const {
	Array out;
	for (const sim::Ent *o : core_.obstacles) {
		Dictionary d;
		d["id"] = o->id;
		d["kind"] = String::utf8(o->detail.name.c_str());
		d["s"] = o->s;
		d["x"] = o->x;
		d["len"] = o->len;
		d["w"] = o->w;
		d["smash"] = o->smash;
		d["hazard"] = o->hazard_car;
		Dictionary det;
		if (o->ob_kind == sim::ObKind::Breakdown) {
			det["carKind"] = o->detail.car_kind >= 0 ? String::utf8(core_.T.kinds[static_cast<size_t>(o->detail.car_kind)].name.c_str()) : String();
			det["variant"] = o->detail.car_variant;
			det["color"] = static_cast<int64_t>(o->detail.car_color);
			det["carLen"] = o->detail.car_len;
			det["rotY"] = o->detail.rot_y;
			det["triangle"] = o->detail.triangle;
		} else if (o->ob_kind == sim::ObKind::Debris) {
			Array boxes;
			for (const auto &b : o->detail.boxes) {
				Dictionary bd;
				bd["x"] = b[0];
				bd["z"] = b[1];
				bd["rotY"] = b[2];
				boxes.push_back(bd);
			}
			det["boxes"] = boxes;
			det["tireX"] = o->detail.tire_x;
		}
		d["detail"] = det;
		out.push_back(d);
	}
	return out;
}

Array Traffic::get_opp() const {
	Array out;
	for (const sim::Opp &o : core_.opp) {
		Dictionary d;
		d["j"] = o.j;
		d["kind"] = o.kind >= 0 ? String::utf8(core_.T.kinds[static_cast<size_t>(o.kind)].name.c_str()) : String();
		d["variant"] = o.variant;
		d["color"] = static_cast<int64_t>(o.color);
		d["s"] = o.s;
		d["v"] = o.v;
		out.push_back(d);
	}
	return out;
}

PackedFloat64Array Traffic::get_barrier() const {
	PackedFloat64Array out;
	for (double s : core_.barrier_s) {
		out.push_back(s);
	}
	return out;
}

Dictionary Traffic::get_info() const {
	Dictionary d;
	d["front_line"] = core_.front_line;
	d["front_v"] = core_.front_v;
	d["jam_speed"] = core_.jam_speed;
	d["s_tail"] = core_.s_tail;
	d["released"] = core_.released;
	d["released_count"] = core_.released_count;
	d["zigzag"] = core_.zigzag;
	d["shoulder_closed"] = core_.shoulder_closed;
	d["shoulder"] = String(core_.approach.shoulder.c_str());
	d["gap_check"] = core_.approach.gap_check;
	d["fatigue"] = core_.approach.fatigue;
	d["rubber"] = core_.approach.rubber;
	d["rage_horn"] = core_.approach.rage_horn;
	d["night"] = core_.night;
	d["assists"] = core_.assists;
	d["draws"] = core_.draws;
	d["spawn_draws"] = core_.spawn_draws;
	d["waves"] = static_cast<int64_t>(core_.waves.size());
	d["time"] = core_.time;
	d["web_parity"] = core_.web_parity;
	PackedStringArray lk;
	for (sim::LaneKind k : core_.stage.lane_kind) {
		lk.push_back(lane_kind_name(k));
	}
	d["lane_kind"] = lk;
	return d;
}

Dictionary Traffic::get_state() const {
	PackedInt32Array ids, lanes;
	PackedFloat64Array s, v, x, opp_s;
	for (const sim::Ent *c : core_.cars) {
		ids.push_back(c->id);
		lanes.push_back(c->lane);
		s.push_back(c->s);
		v.push_back(c->v);
		x.push_back(c->x);
	}
	for (const sim::Opp &o : core_.opp) {
		opp_s.push_back(o.s);
	}
	Dictionary d;
	d["ids"] = ids;
	d["lane"] = lanes;
	d["s"] = s;
	d["v"] = v;
	d["x"] = x;
	d["opp_s"] = opp_s;
	d["obstacles"] = static_cast<int64_t>(core_.obstacles.size());
	return d;
}

PackedByteArray Traffic::hash_bytes() const {
	const size_t n = core_.cars.size();
	const size_t m = core_.opp.size();
	PackedByteArray out;
	out.resize(static_cast<int64_t>(n * 8 * 3 + m * 8 + n + 4));
	uint8_t *w = out.ptrw();
	size_t k = 0;
	auto put = [&](double p_d) {
		uint64_t u = 0;
		std::memcpy(&u, &p_d, 8);
		for (int b = 0; b < 8; ++b) {
			w[k++] = static_cast<uint8_t>(u >> (8 * b));
		}
	};
	for (const sim::Ent *c : core_.cars) {
		put(c->s);
	}
	for (const sim::Ent *c : core_.cars) {
		put(c->v);
	}
	for (const sim::Ent *c : core_.cars) {
		put(c->x);
	}
	for (const sim::Opp &o : core_.opp) {
		put(o.s);
	}
	for (const sim::Ent *c : core_.cars) {
		w[k++] = static_cast<uint8_t>(c->lane);
	}
	const uint32_t ob = static_cast<uint32_t>(core_.obstacles.size());
	for (int b = 0; b < 4; ++b) {
		w[k++] = static_cast<uint8_t>(ob >> (8 * b));
	}
	return out;
}

Array Traffic::take_events() {
	Array out;
	for (const sim::Event &e : core_.events) {
		Dictionary d;
		d["type"] = String(e.type.c_str());
		d["id"] = e.id;
		d["data"] = String::utf8(e.data.c_str());
		d["value"] = e.value;
		out.push_back(d);
	}
	core_.events.clear();
	return out;
}

void Traffic::set_trace(bool p_on) {
	core_.trace_on = p_on;
	core_.trace.clear();
}

Array Traffic::take_trace() {
	Array out;
	for (const auto &e : core_.trace) {
		Array p;
		p.push_back(String(e.first));
		p.push_back(static_cast<int64_t>(e.second));
		out.push_back(p);
	}
	core_.trace.clear();
	return out;
}

int64_t Traffic::get_rng_draws() const { return core_.draws; }

double Traffic::peek_rng() const {
	sim::Mulberry32 copy = core_.rng;
	return copy.next();
}

void Traffic::_bind_methods() {
	using godot::ClassDB;
	using godot::D_METHOD;
	ClassDB::bind_method(D_METHOD("tick", "dt"), &Traffic::tick);
	ClassDB::bind_method(D_METHOD("count"), &Traffic::count);
	ClassDB::bind_method(D_METHOD("get_tick_count"), &Traffic::get_tick_count);
	ClassDB::bind_method(D_METHOD("get_sim_time"), &Traffic::get_sim_time);
	ClassDB::bind_static_method(Traffic::get_class_static(), D_METHOD("build_info"), &Traffic::build_info);
	ClassDB::bind_static_method(Traffic::get_class_static(), D_METHOD("parse_json", "text"), &Traffic::parse_json);

	ClassDB::bind_method(D_METHOD("configure", "tables"), &Traffic::configure);
	ClassDB::bind_method(D_METHOD("get_missing_params"), &Traffic::get_missing_params);
	ClassDB::bind_method(D_METHOD("get_loaded_params"), &Traffic::get_loaded_params);
	ClassDB::bind_method(D_METHOD("spawn_jam", "stage", "villains", "player_start", "seed", "night"), &Traffic::spawn_jam);
	ClassDB::bind_method(D_METHOD("is_spawned"), &Traffic::is_spawned);
	ClassDB::bind_method(D_METHOD("kind_names"), &Traffic::kind_names);
	ClassDB::bind_method(D_METHOD("kind_index", "name"), &Traffic::kind_index);

	ClassDB::bind_method(D_METHOD("set_player", "s", "x", "v", "lane", "mode_jam"), &Traffic::set_player);
	ClassDB::bind_method(D_METHOD("set_player_dims", "len", "w"), &Traffic::set_player_dims);
	ClassDB::bind_method(D_METHOD("set_player_stats", "tow"), &Traffic::set_player_stats);
	ClassDB::bind_method(D_METHOD("set_villain_count", "n"), &Traffic::set_villain_count);
	ClassDB::bind_method(D_METHOD("set_villain", "i", "s", "base_s", "x", "w", "len", "v", "v_nominal", "alive"), &Traffic::set_villain);
	ClassDB::bind_method(D_METHOD("set_extra_count", "n"), &Traffic::set_extra_count);
	ClassDB::bind_method(D_METHOD("set_extra", "i", "s", "x", "w", "len", "v", "alive"), &Traffic::set_extra);
	ClassDB::bind_method(D_METHOD("set_context", "phase", "allow_events", "jam_like", "focus_s"), &Traffic::set_context);
	ClassDB::bind_method(D_METHOD("set_web_parity", "on"), &Traffic::set_web_parity);
	ClassDB::bind_method(D_METHOD("get_web_parity"), &Traffic::get_web_parity);
	ClassDB::bind_method(D_METHOD("set_sin_override", "sin_lf"), &Traffic::set_sin_override);
	ClassDB::bind_method(D_METHOD("update", "dt", "time"), &Traffic::update);

	ClassDB::bind_method(D_METHOD("honk", "siren", "trot"), &Traffic::honk);
	ClassDB::bind_method(D_METHOD("rage_horn", "range"), &Traffic::rage_horn);
	ClassDB::bind_method(D_METHOD("mini_hit", "car_id", "dmg"), &Traffic::mini_hit);
	ClassDB::bind_method(D_METHOD("smash", "obstacle_id"), &Traffic::smash);
	ClassDB::bind_method(D_METHOD("remove_obstacle", "obstacle_id"), &Traffic::remove_obstacle);
	ClassDB::bind_method(D_METHOD("set_obstacle_ids", "ids"), &Traffic::set_obstacle_ids);
	ClassDB::bind_method(D_METHOD("jolt", "id"), &Traffic::jolt);
	ClassDB::bind_method(D_METHOD("release", "time", "wave_speed", "open_lane"), &Traffic::release);
	ClassDB::bind_method(D_METHOD("drop_walls", "lanes", "meters"), &Traffic::drop_walls);
	ClassDB::bind_method(D_METHOD("emit_brake_wave", "lane", "s", "strength"), &Traffic::emit_brake_wave);
	ClassDB::bind_method(D_METHOD("let_in_player", "lane", "force"), &Traffic::let_in_player);

	ClassDB::bind_method(D_METHOD("leader_of_player"), &Traffic::leader_of_player);
	ClassDB::bind_method(D_METHOD("can_merge_into", "lane", "margin"), &Traffic::can_merge_into);
	ClassDB::bind_method(D_METHOD("lane_blocked", "lane", "s_min", "s_max", "exclude_id"), &Traffic::lane_blocked);
	ClassDB::bind_method(D_METHOD("gap_ahead", "lane", "s"), &Traffic::gap_ahead);
	ClassDB::bind_method(D_METHOD("mini_target"), &Traffic::mini_target);
	ClassDB::bind_method(D_METHOD("cars_behind_front", "n", "range"), &Traffic::cars_behind_front);

	ClassDB::bind_method(D_METHOD("opp_count"), &Traffic::opp_count);
	ClassDB::bind_method(D_METHOD("obstacle_count"), &Traffic::obstacle_count);
	ClassDB::bind_method(D_METHOD("get_buffer", "alpha", "include_opp"), &Traffic::get_buffer);
	ClassDB::bind_method(D_METHOD("get_transforms_for", "ids", "alpha"), &Traffic::get_transforms_for);
	ClassDB::bind_method(D_METHOD("get_car_specs"), &Traffic::get_car_specs);
	ClassDB::bind_method(D_METHOD("get_obstacles"), &Traffic::get_obstacles);
	ClassDB::bind_method(D_METHOD("get_opp"), &Traffic::get_opp);
	ClassDB::bind_method(D_METHOD("get_barrier"), &Traffic::get_barrier);
	ClassDB::bind_method(D_METHOD("get_info"), &Traffic::get_info);
	ClassDB::bind_method(D_METHOD("get_state"), &Traffic::get_state);
	ClassDB::bind_method(D_METHOD("hash_bytes"), &Traffic::hash_bytes);
	ClassDB::bind_method(D_METHOD("take_events"), &Traffic::take_events);

	ClassDB::bind_method(D_METHOD("set_trace", "on"), &Traffic::set_trace);
	ClassDB::bind_method(D_METHOD("take_trace"), &Traffic::take_trace);
	ClassDB::bind_method(D_METHOD("get_rng_draws"), &Traffic::get_rng_draws);
	ClassDB::bind_method(D_METHOD("peek_rng"), &Traffic::peek_rng);
}

} // namespace lane1
