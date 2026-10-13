// haptics_backend_null.cpp — host backend (Linux container tests, macOS editor). Plays nothing, keeps the
// registered-pattern table so play_registered() behaves like the iOS backend (false for unknown names).
#include "haptics_backend.h"

#include <set>

namespace lane1::haptics {

namespace {

class NullBackend final : public Backend {
public:
	const char *name() const override { return "null"; }
	bool is_supported() const override { return false; }
	bool start() override {
		running_ = true;
		return true;
	}
	void stop() override { running_ = false; }
	bool transient(double, double) override { return true; }
	bool continuous(double, double, double) override { return true; }
	bool register_pattern(const std::string &name, const std::string &ahap_json) override {
		// Cheap structural check only; the iOS backend validates with CHHapticPattern initWithDictionary:.
		const bool looks_like_ahap = ahap_json.find("\"Pattern\"") != std::string::npos;
		if (looks_like_ahap) {
			patterns_.insert(name);
		}
		return looks_like_ahap;
	}
	bool play_registered(const std::string &name) override { return patterns_.count(name) > 0; }
	bool play_pattern(const std::string &ahap_json) override {
		return ahap_json.find("\"Pattern\"") != std::string::npos;
	}
	void selection() override {}
	void impact(ImpactStyle, double) override {}
	void prepare() override {}
	std::string thermal_state() const override { return "unknown"; }
	bool is_low_power_mode() const override { return false; }
	int64_t thermal_change_count() const override { return 0; }
	std::string state_fields() const override {
		return std::string("\"running\":") + (running_ ? "true" : "false") +
				",\"patterns\":" + std::to_string(patterns_.size());
	}

private:
	bool running_ = false;
	std::set<std::string> patterns_;
};

} // namespace

std::unique_ptr<Backend> make_backend() {
	return std::make_unique<NullBackend>();
}

} // namespace lane1::haptics
