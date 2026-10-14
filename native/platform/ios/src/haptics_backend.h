// haptics_backend.h — platform backend interface for the IOSHaptics GDExtension (NATIVE_PORT 2 햅틱 맵, M1a).
//
// One backend per binary: haptics_backend_ios.mm (Core Haptics + UIKit feedback generators, iOS) or
// haptics_backend_null.cpp (host builds: Linux tests, macOS editor). Values arrive pre-clamped from
// haptics_core.cpp (intensity/sharpness in [0, 1], duration in [0.001, 30] s). All calls come from the
// Godot main thread; backends must not call back into Godot.
#pragma once

#include <cstdint>
#include <memory>
#include <string>

namespace lane1::haptics {

// UIImpactFeedbackStyle order (UIKit): Light, Medium, Heavy, Soft, Rigid.
enum class ImpactStyle : int64_t {
	kLight = 0,
	kMedium = 1,
	kHeavy = 2,
	kSoft = 3,
	kRigid = 4,
};

class Backend {
public:
	virtual ~Backend() = default;

	// "corehaptics" or "null".
	virtual const char *name() const = 0;
	// Hardware can play Core Haptics patterns (false on the null backend).
	virtual bool is_supported() const = 0;

	// Engine lifecycle. start() is idempotent; the backend also restarts by itself after a reset,
	// a system stop, or when the app returns to the foreground, as long as start() was requested.
	virtual bool start() = 0;
	virtual void stop() = 0;

	virtual bool transient(double intensity, double sharpness) = 0;
	virtual bool continuous(double intensity, double sharpness, double duration) = 0;

	// AHAP-format JSON (Apple Haptic and Audio Pattern: {"Version":1,"Pattern":[{"Event":{...}}, ...]}).
	// register_pattern() parses once and caches by name; play_registered() only creates a player.
	virtual bool register_pattern(const std::string &name, const std::string &ahap_json) = 0;
	virtual bool play_registered(const std::string &name) = 0;
	virtual bool play_pattern(const std::string &ahap_json) = 0;

	// UIKit feedback generators (selection tick, impact with intensity) and their prepare().
	virtual void selection() = 0;
	virtual void impact(ImpactStyle style, double intensity) = 0;
	virtual void prepare() = 0;

	// NSProcessInfo.thermalState as "nominal" | "fair" | "serious" | "critical" ("unknown" on host).
	virtual std::string thermal_state() const = 0;
	virtual bool is_low_power_mode() const = 0;
	// Number of thermal-state changes observed since start (lets GDScript log transitions cheaply).
	virtual int64_t thermal_change_count() const = 0;

	// Backend-specific JSON object (no surrounding braces), e.g. "\"running\":true,\"resets\":0".
	virtual std::string state_fields() const = 0;
};

// Defined by exactly one backend translation unit per binary.
std::unique_ptr<Backend> make_backend();

} // namespace lane1::haptics
