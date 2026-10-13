// haptics_core.h — Godot-independent facade over the platform Backend (clamping, call counters, debug JSON).
//
// The GDExtension binding (haptics_gdextension.cpp) forwards every IOSHaptics method here, so the same
// logic runs on iOS and in the Linux/macOS host builds that the container tests load.
#pragma once

#include "haptics_backend.h"

#include <cstdint>
#include <memory>
#include <string>

namespace lane1::haptics {

class Core {
public:
	// Process-wide instance; the backend is created on first use (main thread).
	static Core &get();
	// Stops the engine and destroys the backend (extension deinitialization).
	static void shutdown();

	const char *backend_name();
	bool is_supported();
	bool start();
	void stop();
	bool transient(double intensity, double sharpness);
	bool continuous(double intensity, double sharpness, double duration);
	bool register_pattern(const std::string &name, const std::string &ahap_json);
	bool play_registered(const std::string &name);
	bool play_pattern(const std::string &ahap_json);
	void selection();
	void impact(int64_t style, double intensity);
	void prepare();
	std::string thermal_state();
	bool is_low_power_mode();
	int64_t thermal_change_count();
	// {"backend":..,"supported":..,"instances":..,"calls":{..},"last":{..},"native":{..}}
	std::string debug_state();

	void on_instance_created() { ++instances_; }
	void on_instance_freed() { --instances_; }

	// Shared clamps (also used by tests through debug_state()).
	static double clamp01(double v);
	static double clamp_duration(double seconds);

private:
	Core() = default;
	Backend &backend();

	std::unique_ptr<Backend> backend_;
	int64_t instances_ = 0;
	struct Calls {
		int64_t start = 0, stop = 0, transient = 0, continuous = 0, register_pattern = 0, play_registered = 0,
				play_pattern = 0, selection = 0, impact = 0, prepare = 0, failed = 0;
	} calls_;
	struct Last {
		double intensity = 0.0, sharpness = 0.0, duration = 0.0;
		int64_t impact_style = -1;
		std::string pattern;
	} last_;
};

// JSON string literal with escaping (quotes included).
std::string json_quote(const std::string &s);

} // namespace lane1::haptics
