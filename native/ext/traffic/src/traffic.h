// Traffic — C++ traffic core exposed to GDScript (docs/NATIVE_PORT.md 3-2).
//
// M1-0 placeholder: only fixed-tick bookkeeping, so the GDExtension build/load path can be gated
// (Linux .so headless, later iOS xcframework / Android .so). M1a adds Rng32, spawnJam, lane buckets,
// IDM, lane changes, stuck assist, honk/letIn and the NPC MultiMesh buffer writes behind this class.
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/string.hpp>

#include <cstdint>

namespace lane1 {

class Traffic final : public godot::RefCounted {
	GDCLASS(Traffic, godot::RefCounted)

public:
	// Advances the simulation by p_dt seconds (one sim tick; SIM_HZ = 120 -> 1/120 s).
	// p_dt must be finite and >= 0 (0 = paused / hit-stop tick).
	void tick(double p_dt);
	// Number of simulated entities (always 0 until spawnJam lands in M1a).
	[[nodiscard]] int64_t count() const;
	[[nodiscard]] int64_t get_tick_count() const;
	[[nodiscard]] double get_sim_time() const;
	// "traffic <ext version> godot-cpp <ver> api <ver> <build type>" — for test logs and bug reports.
	[[nodiscard]] static godot::String build_info();

protected:
	static void _bind_methods();

private:
	int64_t tick_count_ = 0;
	double sim_time_ = 0.0;
	int64_t entity_count_ = 0;
};

} // namespace lane1
