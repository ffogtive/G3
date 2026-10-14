// traffic_core.cpp — see traffic_core.h. Line refs are game/js/traffic.js @ web-frozen 753549a unless noted.
//
// Floating point: every expression keeps the JS evaluation order (a + b * c stays (a + (b * c)), left-assoc
// chains stay left-assoc). The build uses -ffp-contract=off so no FMA fusion changes the rounding.
// Math.max/Math.min go through jmax/jmin (JS semantics for NaN and signed zero; the state hash sees -0).
#include "traffic_core.h"

#include <algorithm>
#include <cmath>

namespace lane1::sim {

namespace {

constexpr double k_pi = 3.141592653589793; // Math.PI

inline double jmax(double p_a, double p_b) {
	if (std::isnan(p_a) || std::isnan(p_b)) {
		return std::numeric_limits<double>::quiet_NaN();
	}
	if (p_a > p_b) {
		return p_a;
	}
	if (p_b > p_a) {
		return p_b;
	}
	return std::signbit(p_a) ? p_b : p_a; // equal: +0 wins over -0
}

inline double jmin(double p_a, double p_b) {
	if (std::isnan(p_a) || std::isnan(p_b)) {
		return std::numeric_limits<double>::quiet_NaN();
	}
	if (p_a < p_b) {
		return p_a;
	}
	if (p_b < p_a) {
		return p_b;
	}
	return std::signbit(p_a) ? p_a : p_b; // equal: -0 wins over +0
}

// JS `%` on doubles = C fmod (sign of the dividend).
inline double jmod(double p_a, double p_b) { return std::fmod(p_a, p_b); }

struct CarTags {
	const char *mono, *color, *seed, *personal, *phase;
};
constexpr CarTags k_tags_wall{ "wall/car.mono", "wall/car.color", "wall/car.seed", "wall/car.personal", "wall/car.phase" };
constexpr CarTags k_tags_lane{ "lane/car.mono", "lane/car.color", "lane/car.seed", "lane/car.personal", "lane/car.phase" };
constexpr CarTags k_tags_cheater{ "cheater/car.mono", "cheater/car.color", "cheater/car.seed", "cheater/car.personal",
	"cheater/car.phase" };

const CarTags &car_tags(const char *p_ctx) {
	if (p_ctx[0] == 'w') {
		return k_tags_wall;
	}
	if (p_ctx[0] == 'c') {
		return k_tags_cheater;
	}
	return k_tags_lane;
}

const Dim *dim_of(const KindInfo &p_k, int p_variant, bool p_detailed) {
	const std::vector<Dim> &d = p_detailed && !p_k.detailed.empty() ? p_k.detailed : p_k.simple;
	if (p_variant >= 0 && p_variant < static_cast<int>(d.size())) {
		return &d[static_cast<size_t>(p_variant)];
	}
	return d.empty() ? nullptr : &d[0];
}

// vehicle_kinds.json doc: no seed -> colorVariant ? color % variants : canon[0].
int variant_without_seed(const KindInfo &p_k, uint32_t p_color) {
	if (p_k.color_variant && p_k.variants > 0) {
		return static_cast<int>(p_color % static_cast<uint32_t>(p_k.variants));
	}
	return p_k.canon.empty() ? 0 : p_k.canon[0];
}

} // namespace

int Tables::kind_index(const std::string &p_name) const {
	for (size_t i = 0; i < kinds.size(); ++i) {
		if (kinds[i].name == p_name) {
			return static_cast<int>(i);
		}
	}
	return -1;
}

// ------------------------------------------------------------------------------------------------ rng
double TrafficCore::draw(const char *p_tag) {
	const uint32_t u = rng.next_u32();
	++draws;
	if (trace_on) {
		trace.emplace_back(p_tag, u);
	}
	return static_cast<double>(u) / 4294967296.0;
}

// traffic.js:39 pickWeighted
int TrafficCore::pick_weighted(const WeightTable &p_table, const char *p_tag) {
	double total = 0;
	for (const auto &e : p_table) {
		total += e.second;
	}
	double r = draw(p_tag) * total;
	for (const auto &e : p_table) {
		if ((r -= e.second) <= 0) {
			return e.first;
		}
	}
	return p_table.empty() ? -1 : p_table[0].first;
}

// ------------------------------------------------------------------------------------------------ setup
void TrafficCore::clear() {
	storage.clear();
	cars.clear();
	obstacles.clear();
	opp.clear();
	for (auto &b : buckets) {
		b.clear();
	}
	barrier_s.clear();
	waves.clear();
	events.clear();
	released = false;
	released_count = 0;
	stuck_t = 0;
	assists = 0;
	next_id = 1;
	spawned = false;
	tick_count = 0;
}

void TrafficCore::set_villain_count(int p_n) {
	const size_t n = static_cast<size_t>(std::max(0, p_n));
	while (villains.size() < n) {
		auto v = std::make_unique<Ent>();
		v->type = EType::Villain;
		v->is_villain = true;
		villains.push_back(std::move(v));
	}
	villains.resize(n);
}

void TrafficCore::set_extra_count(int p_n) {
	const size_t n = static_cast<size_t>(std::max(0, p_n));
	while (extras.size() < n) {
		auto e = std::make_unique<Ent>();
		e->type = EType::Extra;
		extras.push_back(std::move(e));
	}
	extras.resize(n);
}

bool TrafficCore::occupies(const Ent &p_e, int p_lane) const {
	const double half_occ = P.lane_w / 2 - P.half_lane_margin;
	return std::fabs(p_e.x - lane_x(p_lane)) < p_e.w / 2 + half_occ;
}

LaneKind TrafficCore::lane_kind_of(int p_lane) const {
	return stage.lane_kind[static_cast<size_t>(std::min(NUM_LANES - 1, std::max(0, p_lane)))];
}

// traffic.js:83 _makeCar
Ent &TrafficCore::make_car(int p_kind, int p_lane, double p_s, double p_v, const char *p_ctx) {
	const CarTags &tg = car_tags(p_ctx);
	const bool mono = draw(tg.mono) < P.car.mono_p;
	const std::vector<uint32_t> &palette = mono ? T.colors_mono : T.colors_pop;
	const double rc = draw(tg.color);
	const uint32_t color = palette.empty() ? 0u : palette[static_cast<size_t>(std::floor(rc * static_cast<double>(palette.size())))];
	const int64_t seed = static_cast<int64_t>(std::floor(draw(tg.seed) * P.car.seed_scale));
	storage.emplace_back();
	Ent &c = storage.back();
	c.type = EType::Car;
	c.kind = p_kind;
	c.color = color;
	c.seed = seed;
	c.variant = 0;
	c.len = P.car.len_fallback;
	c.w = P.car.w_fallback;
	if (p_kind >= 0 && p_kind < static_cast<int>(T.kinds.size())) {
		const KindInfo &k = T.kinds[static_cast<size_t>(p_kind)];
		if (k.variants > 0 && !k.canon.empty()) {
			c.variant = k.canon[static_cast<size_t>(seed % k.variants) % k.canon.size()];
		}
		if (const Dim *d = dim_of(k, c.variant, false)) {
			c.len = d->L > 0 ? d->L : P.car.len_fallback; // `ud.length || 4.5`
			c.w = d->W > 0 ? d->W : P.car.w_fallback;
		}
	}
	c.id = next_id++;
	c.lane = c.lane_from = c.lane_to = p_lane;
	c.lc_t = 1;
	c.lc_dur = P.car.lc_dur_default;
	c.x = lane_x(p_lane);
	c.s = p_s;
	c.v = p_v;
	c.a = 0;
	c.personal = P.car.personal_base + draw(tg.personal) * P.car.personal_span;
	c.phase = draw(tg.phase) * k_pi * 2;
	c.v_free = P.car.v_free_default;
	c.slow = std::find(T.slow_kinds.begin(), T.slow_kinds.end(), p_kind) != T.slow_kinds.end();
	c.prev_x = c.x;
	c.prev_s = c.s;
	cars.push_back(&c);
	return c;
}

// shoulder.js:44 buildShoulderObstacle + traffic.js:200-205
Ent &TrafficCore::add_obstacle(ObKind p_kind, double p_s, bool p_dark) {
	ObstacleDetail det;
	double len = 4.2, w = 2.0;
	if (p_kind == ObKind::Breakdown) {
		const int ck = T.breakdown_kinds[static_cast<size_t>(std::floor(draw("obstacle/breakdown.kind") * 4))];
		const uint32_t color = T.breakdown_colors[static_cast<size_t>(std::floor(draw("obstacle/breakdown.color") * 4))];
		double car_len = 4.6; // `car.userData.length || 4.6`
		int variant = 0;
		if (ck >= 0 && ck < static_cast<int>(T.kinds.size())) {
			const KindInfo &k = T.kinds[static_cast<size_t>(ck)];
			variant = variant_without_seed(k, color);
			if (const Dim *d = dim_of(k, variant, false)) {
				car_len = d->L > 0 ? d->L : 4.6;
			}
		}
		det.car_kind = ck;
		det.car_variant = variant;
		det.car_color = color;
		det.car_len = car_len;
		det.rot_y = (draw("obstacle/breakdown.rotY") - 0.5) * 0.12;
		det.triangle = !p_dark;
		len = car_len + 3.4;
		w = 2.1;
	} else if (p_kind == ObKind::Cones) {
		len = 11.5;
		w = 2.4;
	} else {
		const int nb = 2 + static_cast<int>(std::floor(draw("obstacle/debris.count") * 2));
		for (int i = 0; i < nb; ++i) {
			const double bx = (draw("obstacle/debris.box.x") - 0.5) * 1.4;
			const double bz = (draw("obstacle/debris.box.z") - 0.5) * 2.2;
			const double br = draw("obstacle/debris.box.rotY") * 3;
			det.boxes.push_back({ { bx, bz, br } });
		}
		det.tire_x = (draw("obstacle/debris.tire.x") - 0.5) * 1.2;
		len = 4.2;
		w = 2.0;
	}
	storage.emplace_back();
	Ent &e = storage.back();
	e.type = EType::Obstacle;
	e.id = next_id++;
	e.ob_kind = p_kind;
	e.s = p_s;
	e.x = lane_x(SHOULDER_LANE) - P.spawn.obstacle_x_offset;
	e.len = len;
	e.w = w;
	e.v = 0;
	e.lane = e.lane_from = e.lane_to = SHOULDER_LANE;
	e.hazard_car = p_kind == ObKind::Breakdown && !p_dark;
	e.smash = p_kind != ObKind::Breakdown;
	e.detail = std::move(det);
	e.prev_x = e.x;
	e.prev_s = e.s;
	obstacles.push_back(&e);
	return e;
}

// traffic.js:108 spawnJam
void TrafficCore::spawn_jam(const StageSpec &p_stage, const std::vector<VillainSpec> &p_villains, double p_player_s,
		int p_player_lane, uint32_t p_seed, bool p_night) {
	clear();
	stage = p_stage;
	night = p_night;
	rng = Mulberry32(p_seed);
	draws = 0;
	trace.clear();
	has_next_cheater = false;
	approach = stage.approach;
	shoulder_closed = approach.shoulder == "closed" || approach.shoulder == "none";
	stuck_for = 0;
	double s_front = -INF;
	for (const VillainSpec &v : p_villains) {
		s_front = jmax(s_front, v.s);
	}
	front_line = s_front;
	front_v = stage.jam_speed;
	jam_speed = stage.jam_speed;
	const double density = stage.density != 0 && !std::isnan(stage.density) ? stage.density : 1; // `stage.density || 1`
	const double tail = p_player_s - P.spawn.tail_behind_player;
	s_tail = tail;
	const double half_occ = P.lane_w / 2 - P.half_lane_margin;
	auto occ = [&](double p_x, double p_w, int p_lane) { return std::fabs(p_x - lane_x(p_lane)) < p_w / 2 + half_occ; };

	// ① front row (walls)
	std::array<bool, NUM_LANES> villain_lanes{};
	for (const VillainSpec &v : p_villains) {
		for (int i = 0; i < NUM_LANES; ++i) {
			if (occ(v.x, v.w, i)) {
				villain_lanes[static_cast<size_t>(i)] = true;
			}
		}
	}
	const bool zig = stage.zig;
	if (zig) {
		for (int l = stage.zig_center - 1; l <= stage.zig_center + 1; ++l) {
			if (l >= 0 && l < NUM_LANES) {
				villain_lanes[static_cast<size_t>(l)] = true;
			}
		}
	}
	const std::array<int, NUM_LANES> &fr = stage.has_front_row ? stage.front_row : T.front_row_fallback;
	std::array<double, NUM_LANES> front_rear{ { INF, INF, INF, INF } };
	for (const VillainSpec &v : p_villains) {
		for (int i = 0; i < NUM_LANES; ++i) {
			if (occ(v.x, v.w, i)) {
				front_rear[static_cast<size_t>(i)] = jmin(front_rear[static_cast<size_t>(i)], v.s - v.len / 2);
			}
		}
	}
	zigzag = zig;
	for (int l = 0; l < NUM_LANES; ++l) {
		if (villain_lanes[static_cast<size_t>(l)] || fr[static_cast<size_t>(l)] < 0) {
			continue;
		}
		const double off = (draw("wall.offset") - 0.5) * P.spawn.wall_offset_span;
		Ent &c = make_car(fr[static_cast<size_t>(l)], l, s_front + off, stage.jam_speed, "wall");
		c.is_wall = true;
		c.wall_offset = off;
		front_rear[static_cast<size_t>(l)] = c.s - c.len / 2;
	}
	for (double &fr_l : front_rear) {
		if (!std::isfinite(fr_l)) {
			fr_l = s_front - P.spawn.empty_front_rear_back;
		}
	}

	// ② jam lanes (JamShaper lane kinds)
	waves.clear();
	jam_src_t = 0;
	for (int l = 0; l < NUM_LANES; ++l) {
		const LaneKind lk = stage.lane_kind[static_cast<size_t>(l)];
		auto gap_of = [&]() -> double {
			switch (lk) {
				case LaneKind::Spaced:
					return P.spawn.gap_spaced.base + draw("lane/gap.spaced") * P.spawn.gap_spaced.span;
				case LaneKind::Pass:
					return P.spawn.gap_pass.base + draw("lane/gap.pass") * P.spawn.gap_pass.span;
				case LaneKind::Train:
					return P.spawn.gap_train.base + draw("lane/gap.train") * P.spawn.gap_train.span;
				case LaneKind::Flow:
					return P.spawn.gap_flow.base + draw("lane/gap.flow") * P.spawn.gap_flow.span;
				case LaneKind::Packed:
				default: {
					const double g = P.spawn.gap_packed.base + draw("lane/gap.packed") * P.spawn.gap_packed.span;
					return P.spawn.packed_divided_by_density ? g / density : g;
				}
			}
		};
		const double lead = lk == LaneKind::Spaced ? P.spawn.lead_spaced_base + draw("lead.spaced") * P.spawn.lead_spaced_span
												   : P.spawn.lead_base + draw("lead") * P.spawn.lead_span;
		double cursor = front_rear[static_cast<size_t>(l)] - lead -
				(villain_lanes[static_cast<size_t>(l)] && zig ? P.spawn.lead_zig_extra : 0);
		while (cursor > tail) {
			const int kind = pick_weighted(T.npc_kinds, "lane/pickWeighted");
			Ent &tmp = make_car(kind, l, 0, stage.jam_speed * P.spawn.lane_car_v0_mul, "lane");
			double s = cursor - tmp.len / 2;
			const double hole = P.spawn.player_hole_half;
			if (l == p_player_lane && s + tmp.len / 2 > p_player_s - hole && s - tmp.len / 2 < p_player_s + hole) {
				s = p_player_s - hole - tmp.len / 2 - P.spawn.player_hole_push_back;
			}
			tmp.s = s;
			tmp.prev_s = s;
			cursor = s - tmp.len / 2 - gap_of();
		}
	}

	// ③ shoulder: obstacles + cheaters
	const std::string &mode = approach.shoulder;
	std::vector<std::pair<std::string, int>> spec = stage.has_shoulder ? stage.shoulder : T.shoulder_fallback;
	if (shoulder_closed) {
		spec.clear();
	} else if (mode == "crowded") {
		std::vector<std::pair<std::string, int>> f;
		for (const auto &e : spec) {
			if (e.first != "cheater") {
				f.push_back(e);
			}
		}
		f.emplace_back("cheater", P.spawn.crowded_cheaters);
		spec = std::move(f);
	} else if (mode == "dark") {
		spec = T.dark_spec;
	} else if (mode == "debris") {
		spec = T.debris_spec;
	}
	struct Item {
		std::string kind;
		bool fixed = false;
		double at = 0;
	};
	std::vector<Item> list;
	for (const auto &e : spec) {
		for (int i = 0; i < e.second; ++i) {
			list.push_back({ e.first, false, 0 });
		}
	}
	if (mode == "closed") {
		const double sa = p_player_s - P.spawn.barrier_from_behind_player;
		const double sb = s_front + P.spawn.barrier_past_front;
		for (double s = sa; s < sb; s += P.spawn.barrier_spacing) {
			barrier_s.push_back(s);
		}
	}
	if (mode == "blocked") {
		const double b0 = p_player_s + (s_front - p_player_s) * P.spawn.blocked_start_frac;
		for (int k = 0; k < P.spawn.blocked_count; ++k) {
			list.push_back({ "cones", true, b0 + k * P.spawn.blocked_spacing });
		}
	}
	for (int i = static_cast<int>(list.size()) - 1; i > 0; --i) {
		const int j = static_cast<int>(std::floor(draw("shoulder.shuffle") * (i + 1)));
		std::swap(list[static_cast<size_t>(i)], list[static_cast<size_t>(j)]);
	}
	const double s0 = p_player_s + P.spawn.shoulder_start_ahead;
	const double s1 = s_front - P.spawn.shoulder_end_before_front;
	const double step = (s1 - s0) / std::max<double>(1, static_cast<double>(list.size()));
	for (size_t i = 0; i < list.size(); ++i) {
		const Item &item = list[i];
		const double s = !item.fixed ? s0 + step * (static_cast<double>(i) + P.spawn.jitter_base + draw("shoulder.jitter") * P.spawn.jitter_span)
									 : item.at;
		if (item.kind == "cheater") {
			const int k = pick_weighted(T.cheater_kinds, "cheater/pickWeighted");
			Ent &c = make_car(k, SHOULDER_LANE, s, P.spawn.cheater_spawn_v, "cheater");
			c.is_cheater = true;
			c.cheater_v = P.spawn.cheater_v_base + draw("cheater.v") * P.spawn.cheater_v_span;
			continue;
		}
		const ObKind ok = item.kind == "breakdown" ? ObKind::Breakdown : item.kind == "cones" ? ObKind::Cones : ObKind::Debris;
		// shoulder.js: anything that is not breakdown/cones builds debris; smash = kind !== 'breakdown'
		Ent &e = add_obstacle(ok, s, mode == "dark");
		e.detail.name = item.kind;
	}

	// ③-2 minis on lane 3
	int n_mini = 0;
	if (stage.has_minis) {
		n_mini = stage.minis;
	} else {
		const double diff = stage.has_difficulty ? stage.difficulty : static_cast<double>(stage.id);
		n_mini = std::min(P.spawn.minis_max, P.spawn.minis_base + static_cast<int>(std::floor(diff / P.spawn.minis_per_difficulty)));
	}
	const double win = P.spawn.minis_window;
	std::vector<Ent *> lane3;
	for (Ent *c : cars) {
		if (c->lane == NUM_LANES - 1 && !c->is_wall && !c->is_cheater && c->s > p_player_s + win && c->s < s_front - win) {
			lane3.push_back(c);
		}
	}
	std::stable_sort(lane3.begin(), lane3.end(), [](const Ent *p_a, const Ent *p_b) { return p_a->s < p_b->s; });
	const int n_types = static_cast<int>(T.mini_types.size());
	for (int i = 0; i < n_mini && !lane3.empty(); ++i) {
		const double want = p_player_s + win + ((s_front - win) - (p_player_s + win)) * (i + 0.5) / n_mini;
		size_t bi = 0;
		for (size_t k = 0; k < lane3.size(); ++k) {
			if (std::fabs(lane3[k]->s - want) < std::fabs(lane3[bi]->s - want)) {
				bi = k;
			}
		}
		Ent *best = lane3[bi];
		lane3.erase(lane3.begin() + static_cast<std::ptrdiff_t>(bi));
		const int type = static_cast<int>(std::floor(draw("mini.type") * n_types));
		best->has_mini = true;
		best->mini.type = type;
		best->mini.hp = P.spawn.minis_hp;
		best->mini.max = P.spawn.minis_hp;
		best->mini.cool = P.spawn.minis_cool_base + draw("mini.cool");
		best->mini.acted = 0;
		best->mini.done = false;
		best->alive = true;
	}

	// ④ opposite carriageway
	for (int i = 0; i < P.spawn.opp_count; ++i) {
		Opp o;
		o.j = static_cast<int>(std::floor(draw("opp.lane") * P.spawn.opp_lanes));
		o.kind = pick_weighted(T.npc_kinds, "opp/pickWeighted");
		const std::vector<uint32_t> &pal = draw("opp.mono") < P.spawn.opp_mono_p ? T.colors_mono : T.colors_pop;
		const double rc = draw("opp.color");
		o.color = pal.empty() ? 0u : pal[static_cast<size_t>(std::floor(rc * static_cast<double>(pal.size())))];
		if (o.kind >= 0 && o.kind < static_cast<int>(T.kinds.size())) {
			o.variant = variant_without_seed(T.kinds[static_cast<size_t>(o.kind)], o.color);
		}
		o.s = p_player_s - P.spawn.opp_s_behind + draw("opp.s") * P.spawn.opp_s_span;
		o.v = P.spawn.opp_v_base + draw("opp.v") * P.spawn.opp_v_span - o.j * P.spawn.opp_v_per_lane;
		o.prev_s = o.s;
		opp.push_back(o);
	}
	for (Ent *c : cars) {
		c->brake_on = true; // traffic.js:240 setBrake(mesh, true) (visual only; the JS flag stays false)
	}
	spawn_draws = static_cast<int>(draws);
	spawned = true;
	time = 0;
}

// ------------------------------------------------------------------------------------------------ buckets
void TrafficCore::build_buckets() {
	for (auto &b : buckets) {
		b.clear();
	}
	int idx = 0;
	auto add = [&](Ent *p_e) {
		p_e->bucket_idx = idx++;
		for (int i = 0; i < ALL_LANES; ++i) {
			if (occupies(*p_e, i)) {
				buckets[static_cast<size_t>(i)].push_back(p_e);
			}
		}
	};
	for (Ent *c : cars) {
		add(c);
	}
	for (Ent *o : obstacles) {
		add(o);
	}
	add(&player);
	for (Ent *v : alive_villains_) {
		add(v);
	}
	for (auto &e : extras) {
		if (e->alive) {
			add(e.get());
		}
	}
	// JS Array.prototype.sort is stable: (s, insertion index) is the same total order.
	for (auto &b : buckets) {
		std::sort(b.begin(), b.end(), [](const Ent *p_a, const Ent *p_b) {
			if (p_a->s < p_b->s) {
				return true;
			}
			if (p_b->s < p_a->s) {
				return false;
			}
			return p_a->bucket_idx < p_b->bucket_idx;
		});
	}
}

// traffic.js:249 leaderOf
TrafficCore::Leader TrafficCore::leader_of(const Ent &p_e) const {
	Leader out;
	for (int i = 0; i < ALL_LANES; ++i) {
		if (!occupies(p_e, i)) {
			continue;
		}
		for (Ent *o : buckets[static_cast<size_t>(i)]) {
			if (o == &p_e || o->s <= p_e.s) {
				continue;
			}
			const double gap = (o->s - o->len / 2) - (p_e.s + p_e.len / 2);
			if (gap < out.gap) {
				out.gap = gap;
				out.car = o;
			}
			break;
		}
	}
	if (!out.car) {
		out.gap = INF;
	}
	return out;
}

Ent *TrafficCore::lane_blocked(int p_lane, double p_s_min, double p_s_max, const Ent *p_exclude) const {
	if (p_lane < 0 || p_lane >= ALL_LANES) {
		return nullptr;
	}
	for (Ent *o : buckets[static_cast<size_t>(p_lane)]) {
		if (o == p_exclude) {
			continue;
		}
		if (o->s + o->len / 2 > p_s_min && o->s - o->len / 2 < p_s_max) {
			return o;
		}
	}
	return nullptr;
}

Ent *TrafficCore::can_merge_into(int p_lane, const Ent &p_who, double p_margin) const {
	if (p_lane < 0 || p_lane >= ALL_LANES) {
		return nullptr;
	}
	const double s_min = p_who.s - p_who.len / 2 - p_margin;
	const double s_max = p_who.s + p_who.len / 2 + p_margin;
	for (Ent *o : buckets[static_cast<size_t>(p_lane)]) {
		if (o == &p_who) {
			continue;
		}
		const double o_front = o->s + o->len / 2;
		const double o_rear = o->s - o->len / 2;
		if (o_front <= s_min || o_rear >= s_max) {
			continue;
		}
		if (o->yield_until > time && o->s < p_who.s && o_front - (p_who.s - p_who.len / 2) < P.q.merge_yield_overlap) {
			continue;
		}
		return o;
	}
	return nullptr;
}

TrafficCore::Leader TrafficCore::gap_ahead(int p_lane, double p_s, const Ent *p_exclude) const {
	Leader out;
	if (p_lane < 0 || p_lane >= ALL_LANES) {
		return out;
	}
	for (Ent *o : buckets[static_cast<size_t>(p_lane)]) {
		if (o == p_exclude) {
			continue;
		}
		const double rear = o->s - o->len / 2;
		if (rear > p_s && rear - p_s < out.gap) {
			out.gap = rear - p_s;
			out.car = o;
		}
	}
	return out;
}

// ------------------------------------------------------------------------------------------------ release
// traffic.js:307 release
void TrafficCore::release(double p_time, double p_wave_speed, int p_open_lane) {
	const double ws = (p_wave_speed > 0 && std::isfinite(p_wave_speed)) ? p_wave_speed : P.tune.release_wave_speed;
	released = true;
	release_time = p_time;
	const double front = front_line;
	const double lo = P.tune.release_lo, hi = P.tune.release_hi, tlo = P.tune.truck_lo, thi = P.tune.truck_hi;
	for (Ent *c : cars) {
		const double lane_delay = jmin(P.upd.rel_lane_delay_cap, std::fabs(jmin(3, c->lane) - p_open_lane)) * P.tune.release_lane_delay;
		c->release_at = p_time + jmax(0, front - c->s) / ws + lane_delay + (c->is_wall ? P.upd.rel_wall_extra : P.upd.rel_car_extra);
		c->v_free = c->slow ? tlo + draw("release.vFree.slow") * (thi - tlo) : lo + draw("release.vFree") * (hi - lo);
	}
}

// ------------------------------------------------------------------------------------------------ update
// traffic.js:322 update
void TrafficCore::update(double p_dt, double p_time) {
	const double dt = p_dt;
	time = p_time;
	alive_villains_.clear();
	for (auto &v : villains) {
		if (v->alive) {
			alive_villains_.push_back(v.get());
		}
	}
	if (!alive_villains_.empty()) {
		double fl = -INF;
		for (Ent *v : alive_villains_) {
			fl = jmax(fl, v->has_base_s ? v->base_s : v->s);
		}
		front_line = fl;
		const Ent *v0 = alive_villains_[0];
		front_v = v0->has_v_nominal ? v0->v_nominal : v0->v;
	}
	for (Ent *c : cars) {
		c->prev_x = c->x;
		c->prev_s = c->s;
		c->prev_yaw = c->yaw;
	}
	for (Opp &o : opp) {
		o.prev_s = o.s;
	}
	build_buckets();

	const double t = p_time;
	const double jam_v = jam_speed;

	// random brake (brake waves)
	if (!released && draw("brake.roll") < dt * P.upd.brake_rate) {
		std::vector<Ent *> cand;
		for (Ent *c : cars) {
			if (!c->is_wall && !c->is_cheater && lane_kind_of(c->lane) != LaneKind::Pass && c->s > player.s - P.upd.brake_behind &&
					c->s < player.s + P.upd.brake_ahead) {
				cand.push_back(c);
			}
		}
		if (!cand.empty()) {
			Ent *c = cand[static_cast<size_t>(std::floor(draw("brake.pick") * static_cast<double>(cand.size())))];
			c->brake_t = P.upd.brake_hold_base + draw("brake.hold") * P.upd.brake_hold_span;
			push_event("brake_wave", c->id, "random", c->brake_t);
		}
	}
	// stuck assist (R2: native gates on jamLike; the web oracle on phase == 'jam')
	if (!released && (web_parity ? phase_jam : jam_like)) {
		stuck_assist(dt);
	}
	// shoulder cheater event
	if (!has_next_cheater) {
		next_cheater = t + P.upd.ch_first_delay;
		has_next_cheater = true;
	}
	if (allow_events && player.lane == SHOULDER_LANE && player.v > P.upd.ch_min_player_v && t > next_cheater) {
		next_cheater = t + P.upd.ch_next_base + draw("cheaterEvent.next") * P.upd.ch_next_span;
		spawn_cheater_ahead();
	}
	// minis act when the player comes up from behind
	if (!released && phase_jam) {
		for (Ent *c : cars) {
			if (!c->has_mini || c->mini.done) {
				continue;
			}
			Mini &m = c->mini;
			const double ds = c->s - player.s;
			if (ds < P.upd.mini_ds_min || ds > P.upd.mini_ds_max) {
				continue;
			}
			m.cool -= dt;
			if (m.cool > 0) {
				continue;
			}
			const std::string &type = m.type >= 0 && m.type < static_cast<int>(T.mini_types.size()) ? T.mini_types[static_cast<size_t>(m.type)]
																									: std::string();
			if (type == "cutin") {
				if (m.acted < 1 && ds > P.upd.cutin_ds_min &&
						!lane_blocked(SHOULDER_LANE, c->s - c->len / 2 - P.upd.cutin_block_margin, c->s + c->len / 2 + P.upd.cutin_block_margin, c)) {
					m.acted++;
					c->is_cheater = true;
					c->cheater_v = P.upd.cutin_v;
					start_lane_change(*c, SHOULDER_LANE, P.upd.cutin_lc_dur);
					push_event("cutin", c->id, "mini");
				}
				m.cool = P.upd.cutin_cool;
			} else if (m.acted < P.upd.throw_max_acts) {
				m.acted++;
				m.cool = P.upd.throw_cool_base + draw("mini.throwCool") * P.upd.throw_cool_span;
				push_event("mini_act", c->id, type);
			}
		}
	}
	if (!released) {
		update_jam_shape(dt, t, alive_villains_);
	}

	const Params::Idm &I = P.idm;
	for (Ent *cp : cars) {
		Ent &c = *cp;
		if (!c.released && t >= c.release_at) {
			c.released = true;
			c.hazard_until = t + P.upd.rel_hazard;
			c.next_lc_at = t + P.upd.rel_next_lc_base + draw("release.nextLc") * P.upd.rel_next_lc_span;
			released_count++;
			push_event("released", c.id);
		}
		const LaneKind lk = lane_kind_of(c.lane);
		double v0 = 0, T_ = 0, s0 = 0, a_max = 0;
		if (c.released) {
			v0 = c.v_free;
			T_ = I.rel_T;
			s0 = I.rel_s0;
			a_max = c.slow ? I.rel_a_max_slow : I.rel_a_max;
		} else if (c.is_wall) {
			const double target = front_line + c.wall_offset - c.wall_back;
			v0 = jmax(0, front_v + (target - c.s) * I.wall_follow);
			T_ = I.wall_T;
			s0 = I.wall_s0;
			a_max = I.wall_a_max;
		} else if (c.is_cheater) {
			v0 = c.cheater_v != 0 && !std::isnan(c.cheater_v) ? c.cheater_v : I.cheat_v0_fallback;
			T_ = I.cheat_T;
			s0 = I.cheat_s0;
			a_max = I.cheat_a_max;
		} else if (lk == LaneKind::Train) {
			v0 = jam_v * I.train.v0_mul;
			T_ = I.train.T;
			s0 = I.train.s0;
			a_max = I.train.a_max;
		} else if (lk == LaneKind::Flow) {
			v0 = jam_v * I.flow.v0_mul * c.personal;
			T_ = I.flow.T;
			s0 = I.flow.s0;
			a_max = I.flow.a_max;
		} else if (lk == LaneKind::Spaced) {
			v0 = jam_v * I.spaced.v0_mul * c.personal;
			T_ = I.spaced.T;
			s0 = I.spaced.s0;
			a_max = I.spaced.a_max;
		} else if (lk == LaneKind::Pass) {
			v0 = jam_v * (stage.has_pass_v ? stage.pass_v : I.pass.v0_mul) * c.personal;
			T_ = I.pass.T;
			s0 = I.pass.s0;
			a_max = I.pass.a_max;
		} else {
			// lane-wide stop & go (traffic.js:406) — the only libm call that feeds state
			const int li = std::max(0, std::min(ALL_LANES - 1, c.lane));
			const double sv = sin_override ? sin_lf[static_cast<size_t>(li)] : std::sin(t * I.lf_freq + c.lane * I.lf_lane_phase);
			const double lf = I.lf_base + I.lf_amp * (0.5 + 0.5 * sv);
			v0 = jam_v * c.personal * lf * I.packed.v0_mul;
			T_ = I.packed.T;
			s0 = I.packed.s0;
			a_max = I.packed.a_max;
		}
		if (c.pull_t > 0 && !c.released) {
			c.pull_t -= dt;
			v0 = jmax(v0, jam_v * (c.let_in_boost ? I.pull_v0_mul_let_in : I.pull_v0_mul));
			a_max = I.pull_a_max;
			T_ = I.pull_T;
			s0 = I.pull_s0;
		} else {
			c.let_in_boost = false;
		}
		if (c.brake_t > 0) {
			c.brake_t -= dt;
			v0 = I.brake_v0;
		}

		// IDM
		const Leader L = leader_of(c);
		double gap = INF, dv = 0, lv = 0;
		if (L.car) {
			gap = L.gap;
			lv = L.car->v;
			dv = c.v - lv;
		}
		if (!c.released && !c.is_wall && !c.is_cheater && lk != LaneKind::Pass) {
			const double g2 = (front_line - I.villain_wall_back - (zigzag ? I.villain_wall_zig_extra : 0)) - (c.s + c.len / 2);
			if (g2 < gap) {
				gap = g2;
				dv = c.v - front_v;
				lv = front_v;
			}
		}
		const double b = I.b;
		const double s_star = s0 + jmax(0, c.v * T_ + (c.v * dv) / (2 * std::sqrt(a_max * b)));
		const double vr = c.v / jmax(I.v_floor, v0);
		const double q = s_star / jmax(I.gap_floor, gap);
		double acc = a_max * (1 - vr * vr * vr * vr) - a_max * (q * q); // Math.pow(x, 2) == x * x (V8 fast path)
		acc = jmax(I.acc_min, jmin(a_max, acc));
		c.a = acc;
		c.v = jmax(0, c.v + acc * dt);
		c.s += c.v * dt;
		if (L.car && gap < I.stop_gap && L.car != &player) {
			c.v = jmin(c.v, jmax(0, lv));
		}

		// lane change progress
		if (c.lc_t < 1) {
			c.lc_t = jmin(1, c.lc_t + dt / c.lc_dur);
			const double e = c.lc_t * c.lc_t * (3 - 2 * c.lc_t);
			const double nx = lane_x(c.lane_from) + (lane_x(c.lane_to) - lane_x(c.lane_from)) * e;
			c.yaw = -std::atan2((nx - c.x) / jmax(dt, P.upd.lc_dt_floor), jmax(P.upd.lc_yaw_min_v, c.v)) * P.upd.lc_yaw_gain;
			c.x = nx;
			if (c.lc_t >= 1) {
				c.lane = c.lane_to;
				c.yaw = 0;
				c.blink = 0;
				if (c.is_cheater && c.lane != SHOULDER_LANE) {
					c.is_cheater = false;
				}
			}
		} else if (c.released && t > c.next_lc_at) {
			post_release_lane_change(c);
		} else if (c.is_cheater && released) {
			if (safe_to_enter(c, NUM_LANES - 1, P.upd.pr_cheater_return_margin)) {
				start_lane_change(c, NUM_LANES - 1, P.upd.pr_cheater_return_lc_dur);
			}
		}

		// visual state (lamp bits only; no sim feedback)
		if (c.bump_jolt > 0) {
			c.bump_jolt = jmax(0, c.bump_jolt - dt * 3);
		}
		c.brake_on = !c.released && (acc < P.upd.bl_acc_below || c.v < P.upd.bl_v_below || c.brake_t > 0 ||
											std::sin(t * P.upd.bl_flicker_freq + c.phase) > P.upd.bl_flicker_above);
		const double hp = P.upd.hz_period;
		c.hazard_on = (t < c.hazard_until && jmod(jmod(t - c.hazard_until, hp) + hp, hp) < P.upd.hz_on_frac) ||
				(c.is_cheater && jmod(std::floor(t * P.upd.hz_cheater_freq), 2) == 0);
	}
	for (Ent *o : obstacles) {
		o->hazard_on = o->hazard_car && jmod(std::floor(t * 2), 2) == 0;
	}

	// opposite carriageway
	const double focus = has_focus ? focus_s : player.s;
	for (Opp &o : opp) {
		o.s -= o.v * dt;
		if (o.s < focus - P.upd.opp_recycle_behind) {
			o.s = focus + P.upd.opp_respawn_ahead + draw("opp.respawn") * P.upd.opp_respawn_span;
			o.prev_s = o.s;
		}
	}
	sin_override = false;
	++tick_count;
}

// traffic.js:479 _postReleaseLaneChange
void TrafficCore::post_release_lane_change(Ent &p_c) {
	p_c.next_lc_at = time + P.upd.pr_next_base + draw("postRelease.next") * P.upd.pr_next_span;
	if (p_c.lane == SHOULDER_LANE) {
		return;
	}
	if (p_c.slow) {
		const int tl = p_c.lane + 1;
		if (tl <= NUM_LANES - 1 && safe_to_enter(p_c, tl, P.upd.pr_slow_margin)) {
			start_lane_change(p_c, tl, P.upd.pr_slow_lc_dur);
		}
		return;
	}
	const Leader L = leader_of(p_c);
	if (L.car && L.gap < P.upd.pr_look_gap && L.car->v < p_c.v_free - P.upd.pr_v_margin && p_c.lane > 0) {
		const int tl = p_c.lane - 1;
		if (safe_to_enter(p_c, tl, P.upd.pr_pass_margin)) {
			start_lane_change(p_c, tl, P.upd.pr_pass_lc_dur);
		}
	}
}

// traffic.js:496 _stuckAssist
void TrafficCore::stuck_assist(double p_dt) {
	const Approach &A = approach;
	if (player.v < P.upd.stuck_v_below && player.mode_jam) {
		stuck_t = stuck_t + p_dt;
		stuck_for = stuck_for + p_dt;
	} else {
		stuck_t = jmax(0, stuck_t - p_dt * P.upd.stuck_decay);
		stuck_for = 0;
	}
	if (stuck_t < (A.has_rubber ? A.rubber : P.upd.stuck_rubber_fallback)) {
		return;
	}
	stuck_t = 0;
	int tl = player.lane == SHOULDER_LANE ? NUM_LANES - 1 : std::min(SHOULDER_LANE, player.lane + 1);
	if (tl == SHOULDER_LANE && shoulder_closed) {
		tl = NUM_LANES - 1 == player.lane ? player.lane - 1 : tl - 1;
	}
	const bool force = !A.gap_check || stuck_for > (A.has_rubber_safety ? A.rubber_safety : P.upd.stuck_safety_fallback);
	if (force || has_gap(tl, player)) {
		let_in(tl, player, true);
	} else if (player.lane < NUM_LANES && stuck_for > P.upd.stuck_pull_after) {
		pull_ahead();
	}
	assists++;
	if (player.lane >= NUM_LANES - 1) {
		for (size_t i = 0; i < obstacles.size(); ++i) {
			Ent *o = obstacles[i];
			if (!o->smash && o->s - o->len / 2 < player.s + P.upd.tow_probe_ahead && o->s + o->len / 2 > player.s - P.upd.tow_probe_behind) {
				if (++o->stuck_n >= P.upd.auto_tow_after) {
					obstacles.erase(obstacles.begin() + static_cast<std::ptrdiff_t>(i));
					push_event("auto_tow", o->id);
				}
				break;
			}
		}
	}
}

// traffic.js:525 emitBrakeWave
void TrafficCore::emit_brake_wave(int p_lane, double p_s, double p_strength, double p_amp, double p_speed, double p_hold, double p_life) {
	if (p_lane < 0 || p_lane >= NUM_LANES) {
		return;
	}
	Wave w;
	w.lane = p_lane;
	w.s = p_s;
	w.strength = p_strength;
	w.amp = std::isnan(p_amp) ? P.upd.wave_amp : p_amp;
	w.speed = std::isnan(p_speed) ? P.upd.wave_speed : p_speed;
	w.hold = std::isnan(p_hold) ? P.upd.wave_hold : p_hold;
	w.life = std::isnan(p_life) ? P.upd.wave_life : p_life;
	waves.push_back(std::move(w));
	push_event("brake_wave", 0, "wave", p_s);
}

// traffic.js:529 _updateJamShape
void TrafficCore::update_jam_shape(double p_dt, double p_t, const std::vector<Ent *> &p_alive) {
	for (int i = static_cast<int>(waves.size()) - 1; i >= 0; --i) {
		Wave &w = waves[static_cast<size_t>(i)];
		w.s -= w.speed * p_dt;
		w.life -= p_dt;
		if (w.life <= 0 || w.strength < P.upd.wave_min_strength) {
			waves.erase(waves.begin() + i);
			continue;
		}
		for (Ent *c : buckets[static_cast<size_t>(w.lane)]) {
			if (!c->is_npc() || c->released || c->is_wall || std::find(w.hit.begin(), w.hit.end(), c) != w.hit.end()) {
				continue;
			}
			if (std::fabs(c->s - w.s) < c->len / 2 + P.upd.wave_hit_margin) {
				w.hit.push_back(c);
				c->brake_t = jmax(c->brake_t, w.hold * jmin(P.upd.wave_hold_cap, w.strength));
				w.strength *= w.amp;
			}
		}
	}
	const std::vector<JamSource> &src = stage.sources;
	if (src.empty() || p_alive.empty()) {
		return;
	}
	const Ent *v = p_alive[0];
	jam_src_t -= p_dt;
	for (const JamSource &S : src) {
		if (S.type == "yield" && jam_src_t <= 0) {
			const int lane = S.lane;
			if (lane < 0 || lane >= ALL_LANES) {
				continue;
			}
			Ent *best = nullptr;
			for (Ent *c : buckets[static_cast<size_t>(lane)]) {
				if (c->is_npc() && !c->is_wall && !c->released && !c->yielded && c->brake_t <= 0 && c->s > v->s - P.upd.ys_behind &&
						c->s < v->s + P.upd.ys_ahead) {
					if (!best || c->s > best->s) {
						best = c;
					}
				}
			}
			if (best) {
				best->brake_t = S.has_hold ? S.hold : P.upd.ys_hold_fallback;
				best->yielded = true;
				best->yield_pocket = p_t;
				emit_brake_wave(lane, best->s - best->len / 2 - P.upd.ys_wave_offset, P.upd.ys_wave_strength, P.upd.ys_wave_amp,
						std::numeric_limits<double>::quiet_NaN(), std::numeric_limits<double>::quiet_NaN(),
						std::numeric_limits<double>::quiet_NaN());
			}
		}
	}
	if (jam_src_t <= 0) {
		jam_src_t = src[0].has_period ? src[0].period : P.upd.ys_period_fallback;
	}
}

// traffic.js:571 _hasGap
bool TrafficCore::has_gap(int p_lane, const Ent &p_who) const {
	if (p_lane < 0 || p_lane >= ALL_LANES) {
		return false;
	}
	const double need = (p_who.len != 0 ? p_who.len : P.q.has_gap_len_fallback) + P.q.has_gap_extra;
	const Ent *ahead = nullptr;
	const Ent *behind = nullptr;
	for (const Ent *o : buckets[static_cast<size_t>(p_lane)]) {
		if (o == &p_who) {
			continue;
		}
		if (o->s >= p_who.s) {
			if (!ahead || o->s < ahead->s) {
				ahead = o;
			}
		} else if (!behind || o->s > behind->s) {
			behind = o;
		}
	}
	const double front = ahead ? ahead->s - ahead->len / 2 : INF;
	const double back = behind ? behind->s + behind->len / 2 : -INF;
	if (front - back < need) {
		return false;
	}
	return front > p_who.s - P.q.has_gap_window && back < p_who.s + P.q.has_gap_window;
}

// traffic.js:601 _pullAhead
void TrafficCore::pull_ahead() {
	if (player.lane < 0 || player.lane >= ALL_LANES) {
		return;
	}
	for (Ent *o : buckets[static_cast<size_t>(player.lane)]) {
		if (!o->is_npc() || o->is_wall || o->released) {
			continue;
		}
		const double d = o->s - player.s;
		if (d > 0 && d < P.q.pull_ahead_range) {
			o->pull_t = jmax(o->pull_t, P.q.pull_ahead_hold);
		}
	}
}

void TrafficCore::drop_walls(const std::vector<int> &p_lanes, double p_meters) {
	for (Ent *c : cars) {
		if (c->is_wall && std::find(p_lanes.begin(), p_lanes.end(), c->lane) != p_lanes.end()) {
			c->wall_back = p_meters;
		}
	}
}

// traffic.js:615 letIn
Ent *TrafficCore::let_in(int p_lane, Ent &p_who, bool p_force) {
	if (approach.gap_check && !p_force && !has_gap(p_lane, p_who)) {
		return nullptr;
	}
	if (p_lane < 0 || p_lane >= ALL_LANES) {
		return nullptr;
	}
	Ent *who = nullptr;
	for (Ent *o : buckets[static_cast<size_t>(p_lane)]) {
		if (!o->is_npc() || o->is_wall || o->released) {
			continue;
		}
		const double d = o->s - p_who.s;
		if (d > P.q.let_in_ahead_min && d < P.q.let_in_ahead_max) {
			o->pull_t = jmax(o->pull_t, P.q.let_in_pull);
			o->let_in_boost = true;
			who = who ? who : o;
		} else if (d <= P.q.let_in_ahead_min && d > P.q.let_in_behind_max) {
			o->brake_t = jmax(o->brake_t, P.q.let_in_brake);
			o->yield_until = time + P.q.let_in_yield_for;
			who = who ? who : o;
		}
	}
	return who;
}

// traffic.js:622 _spawnCheaterAhead
void TrafficCore::spawn_cheater_ahead() {
	std::vector<Ent *> cands;
	for (Ent *c : cars) {
		const double d = c->s - player.s;
		if (c->lane == NUM_LANES - 1 && !c->is_wall && !c->released && c->lc_t >= 1 && d > P.upd.ch_window_min && d < P.upd.ch_window_max) {
			cands.push_back(c);
		}
	}
	if (cands.empty()) {
		return;
	}
	Ent *c = cands[static_cast<size_t>(std::floor(draw("cheaterEvent.pick") * static_cast<double>(cands.size())))];
	if (lane_blocked(SHOULDER_LANE, c->s - c->len / 2 - P.upd.ch_block_margin, c->s + c->len / 2 + P.upd.ch_block_margin, c)) {
		return;
	}
	c->is_cheater = true;
	c->cheater_v = P.upd.ch_v_base + draw("cheaterEvent.v") * P.upd.ch_v_span;
	start_lane_change(*c, SHOULDER_LANE, P.upd.ch_lc_dur);
	push_event("cutin", c->id, "cheater");
}

// traffic.js:634 _safeToEnter
bool TrafficCore::safe_to_enter(const Ent &p_c, int p_lane, double p_margin) const {
	if (p_lane < 0 || p_lane >= ALL_LANES) {
		return true;
	}
	const double touch = P.q.safe_touch;
	for (const Ent *o : buckets[static_cast<size_t>(p_lane)]) {
		if (o == &p_c) {
			continue;
		}
		const double ahead = (o->s - o->len / 2) - (p_c.s + p_c.len / 2);
		const double behind = (p_c.s - p_c.len / 2) - (o->s + o->len / 2);
		if (ahead > touch && ahead < p_margin) {
			return false;
		}
		if (behind > touch && behind < p_margin + jmax(0, o->v - p_c.v) * P.q.safe_closing_gain) {
			return false;
		}
		if (ahead <= touch && behind <= touch) {
			return false;
		}
	}
	return true;
}

// traffic.js:646 _startLaneChange
void TrafficCore::start_lane_change(Ent &p_c, int p_lane, double p_dur) {
	p_c.blink = (p_c.is_cheater || p_c.has_mini) ? 0 : (p_lane > p_c.lane ? 1 : -1);
	p_c.lane_from = p_c.lane;
	p_c.lane_to = p_lane;
	p_c.lc_t = 0;
	p_c.lc_dur = p_dur;
	p_c.lane = p_lane;
}

// traffic.js:654 honk
HonkResult TrafficCore::honk(bool p_siren, bool p_trot) {
	HonkResult r;
	const int pl = player.lane;
	const double range = p_siren ? P.q.honk_range_siren : p_trot ? P.q.honk_range_trot : P.q.honk_range;
	const Leader ga = gap_ahead(pl, player.s + player.len / 2 - P.q.honk_probe_back, &player);
	Ent *who = ga.car;
	const double gap = ga.gap;
	if (who && who->is_villain && gap < P.q.honk_villain_range) {
		r.kind = "villain";
		r.id = who->id;
		r.villain = true;
		return r;
	}
	if (pl == SHOULDER_LANE) {
		if (who && who->is_cheater && who->lc_t >= 1 && who->lane == SHOULDER_LANE &&
				gap < (p_siren ? P.q.honk_cheater_range_siren : P.q.honk_cheater_range)) {
			let_in(NUM_LANES - 1, *who, true);
			start_lane_change(*who, NUM_LANES - 1, P.q.honk_cheater_lc_dur);
			who->cheater_v = 0;
			r.kind = "cheater";
			r.id = who->id;
			return r;
		}
		if (who && who->type == EType::Obstacle && gap < range) {
			Ent *c = let_in(NUM_LANES - 1, player, false);
			r.kind = c ? "letin" : "noway";
			r.id = c ? c->id : who->id;
			return r;
		}
		return r;
	}
	if (!who || gap > range - P.q.honk_range_slack || who->released) {
		return r;
	}
	if (approach.fatigue && who->is_npc()) {
		if (who->honk_t != 0 && time - who->honk_t > P.q.honk_fatigue_relax) {
			who->honk_n = std::max(0, who->honk_n - 1);
		}
		who->honk_n = who->honk_n + 1;
		who->honk_t = time;
		if (who->honk_n >= P.q.honk_fatigue_ignore_at || (who->honk_n == 2 && draw("honk.fatigue") < P.q.honk_fatigue_half_p)) {
			r.kind = "tired";
			r.id = who->id;
			return r;
		}
	}
	if (who->is_npc() && !who->is_wall && who->lc_t >= 1) {
		for (int tl : { who->lane - 1, who->lane + 1 }) {
			if (tl < 0 || tl >= NUM_LANES) {
				continue;
			}
			if (safe_to_enter(*who, tl, P.q.honk_yield_margin)) {
				start_lane_change(*who, tl, P.q.honk_yield_lc_dur);
				r.kind = "yield";
				r.id = who->id;
				return r;
			}
		}
	}
	Ent *c = let_in(std::min(SHOULDER_LANE, pl + 1), player, false);
	r.kind = c ? "letin" : "noway";
	r.id = c ? c->id : who->id;
	return r;
}

// traffic.js:697 rageHorn
RageResult TrafficCore::rage_horn(double p_range) {
	RageResult out;
	const double s0 = player.s - P.q.rage_behind;
	const double s1 = player.s + p_range;
	const std::vector<Ent *> copy = obstacles;
	for (Ent *o : copy) {
		if (o->s < s0 || o->s > s1) {
			continue;
		}
		if (!o->smash && !(approach.shoulder == "occupied" || player.stats_tow)) {
			continue;
		}
		obstacles.erase(std::find(obstacles.begin(), obstacles.end(), o));
		(o->smash ? out.smashed : out.towed).push_back(o->id);
	}
	for (Ent *c : cars) {
		if (c->released || c->s < s0 || c->s > s1) {
			continue;
		}
		if ((c->is_cheater || c->lane == SHOULDER_LANE) && c->lc_t >= 1) {
			let_in(NUM_LANES - 1, *c, true);
			start_lane_change(*c, NUM_LANES - 1, P.q.rage_lc_dur);
			c->cheater_v = 0;
			out.cheaters.push_back(c->id);
		} else if (c->lane >= NUM_LANES - 2 && !c->is_wall) {
			c->bump_jolt = 1;
			c->brake_t = jmax(c->brake_t, P.q.rage_startled_hold);
			out.startled.push_back(c->id);
		}
	}
	return out;
}

Ent *TrafficCore::mini_target() const {
	Ent *best = nullptr;
	double bd = INF;
	for (Ent *c : cars) {
		if (!c->has_mini || c->mini.done) {
			continue;
		}
		const double ds = c->s - player.s;
		if (ds < P.q.mini_target_behind || ds > P.q.mini_target_ahead) {
			continue;
		}
		if (std::fabs(c->x - player.x) > P.lane_w * P.q.mini_target_lateral) {
			continue;
		}
		if (ds < bd) {
			bd = ds;
			best = c;
		}
	}
	return best;
}

// traffic.js:737 miniHit
std::string TrafficCore::mini_hit(int p_car_id, double p_dmg) {
	Ent *c = find_car(p_car_id);
	if (!c || !c->has_mini || c->mini.done) {
		return std::string();
	}
	Mini &m = c->mini;
	m.hp -= p_dmg;
	c->bump_jolt = P.q.mini_hit_jolt;
	if (m.hp > 0) {
		return "hit";
	}
	m.done = true;
	c->alive = false;
	c->brake_t = P.q.mini_hit_brake;
	c->hazard_until = time + P.q.mini_hit_hazard;
	if (c->is_cheater && c->lane == SHOULDER_LANE) {
		let_in(NUM_LANES - 1, *c, false);
		start_lane_change(*c, NUM_LANES - 1, P.q.mini_hit_lc_dur);
		c->cheater_v = 0;
	}
	return "down";
}

std::vector<int> TrafficCore::cars_behind_front(int p_n, double p_range) const {
	std::vector<int> out;
	for (const Ent *c : cars) {
		if (static_cast<int>(out.size()) >= p_n) {
			break;
		}
		if (!c->released && !c->is_wall && !c->is_cheater && front_line - c->s < p_range && front_line - c->s > 0) {
			out.push_back(c->id);
		}
	}
	return out;
}

bool TrafficCore::smash(int p_obstacle_id) { return remove_obstacle(p_obstacle_id); }

bool TrafficCore::remove_obstacle(int p_obstacle_id) {
	for (auto it = obstacles.begin(); it != obstacles.end(); ++it) {
		if ((*it)->id == p_obstacle_id) {
			obstacles.erase(it);
			return true;
		}
	}
	return false;
}

void TrafficCore::jolt(int p_car_id) {
	if (Ent *c = find_any(p_car_id)) {
		c->bump_jolt = 1;
	}
}

Ent *TrafficCore::find_car(int p_id) {
	// ids are assigned in spawn order, so cars[] is sorted by id except for interleaved obstacles.
	for (Ent *c : cars) {
		if (c->id == p_id) {
			return c;
		}
	}
	return nullptr;
}

Ent *TrafficCore::find_obstacle(int p_id) {
	for (Ent *o : obstacles) {
		if (o->id == p_id) {
			return o;
		}
	}
	return nullptr;
}

Ent *TrafficCore::find_any(int p_id) {
	if (Ent *c = find_car(p_id)) {
		return c;
	}
	for (Ent &e : storage) {
		if (e.id == p_id) {
			return &e;
		}
	}
	return nullptr;
}

void TrafficCore::push_event(const char *p_type, int p_id, const std::string &p_data, double p_value) {
	if (events.size() < 4096) { // bounded if nobody drains them
		events.push_back(Event{ p_type, p_id, p_data, p_value });
	}
}

} // namespace lane1::sim
