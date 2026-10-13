#include "traffic.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>

#include <cmath>

namespace lane1 {

namespace {
constexpr const char *k_ext_version = "0.1.0-m1-0";
#ifdef DEBUG_ENABLED
constexpr const char *k_build = "debug";
#else
constexpr const char *k_build = "release";
#endif
} // namespace

void Traffic::tick(double p_dt) {
	ERR_FAIL_COND_MSG(!std::isfinite(p_dt) || p_dt < 0.0, "Traffic.tick: dt must be finite and >= 0.");
	++tick_count_;
	sim_time_ += p_dt;
}

int64_t Traffic::count() const {
	return entity_count_;
}

int64_t Traffic::get_tick_count() const {
	return tick_count_;
}

double Traffic::get_sim_time() const {
	return sim_time_;
}

godot::String Traffic::build_info() {
	return godot::vformat("traffic %s godot-cpp %s api %s %s", k_ext_version, LANE1_GODOT_CPP_VERSION,
			LANE1_GODOT_API_VERSION, k_build);
}

void Traffic::_bind_methods() {
	using godot::ClassDB;
	using godot::D_METHOD;
	ClassDB::bind_method(D_METHOD("tick", "dt"), &Traffic::tick);
	ClassDB::bind_method(D_METHOD("count"), &Traffic::count);
	ClassDB::bind_method(D_METHOD("get_tick_count"), &Traffic::get_tick_count);
	ClassDB::bind_method(D_METHOD("get_sim_time"), &Traffic::get_sim_time);
	ClassDB::bind_static_method(Traffic::get_class_static(), D_METHOD("build_info"), &Traffic::build_info);
}

} // namespace lane1
