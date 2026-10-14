// haptics_core.cpp — see haptics_core.h.
#include "haptics_core.h"

#include <algorithm>
#include <cmath>
#include <cstdio>

namespace lane1::haptics {

namespace {

Core *g_core = nullptr;

void append_kv(std::string &out, const char *key, const std::string &raw_value) {
	if (out.size() > 1) {
		out += ',';
	}
	out += json_quote(key);
	out += ':';
	out += raw_value;
}

std::string num(double v) {
	char buf[32];
	std::snprintf(buf, sizeof(buf), "%.4f", v);
	return buf;
}

std::string num(int64_t v) {
	return std::to_string(v);
}

std::string boolean(bool v) {
	return v ? "true" : "false";
}

} // namespace

std::string json_quote(const std::string &s) {
	std::string out;
	out.reserve(s.size() + 2);
	out += '"';
	for (const char c : s) {
		switch (c) {
			case '"':
				out += "\\\"";
				break;
			case '\\':
				out += "\\\\";
				break;
			case '\n':
				out += "\\n";
				break;
			case '\r':
				out += "\\r";
				break;
			case '\t':
				out += "\\t";
				break;
			default:
				if (static_cast<unsigned char>(c) < 0x20) {
					char buf[8];
					std::snprintf(buf, sizeof(buf), "\\u%04x", static_cast<unsigned>(static_cast<unsigned char>(c)));
					out += buf;
				} else {
					out += c;
				}
		}
	}
	out += '"';
	return out;
}

Core &Core::get() {
	if (g_core == nullptr) {
		g_core = new Core();
	}
	return *g_core;
}

void Core::shutdown() {
	if (g_core != nullptr) {
		if (g_core->backend_) {
			g_core->backend_->stop();
		}
		delete g_core;
		g_core = nullptr;
	}
}

double Core::clamp01(double v) {
	if (!std::isfinite(v)) {
		return 0.0;
	}
	return std::clamp(v, 0.0, 1.0);
}

double Core::clamp_duration(double seconds) {
	if (!std::isfinite(seconds)) {
		return 0.001;
	}
	return std::clamp(seconds, 0.001, 30.0);
}

Backend &Core::backend() {
	if (!backend_) {
		backend_ = make_backend();
	}
	return *backend_;
}

const char *Core::backend_name() {
	return backend().name();
}

bool Core::is_supported() {
	return backend().is_supported();
}

bool Core::start() {
	++calls_.start;
	const bool ok = backend().start();
	calls_.failed += ok ? 0 : 1;
	return ok;
}

void Core::stop() {
	++calls_.stop;
	backend().stop();
}

bool Core::transient(double intensity, double sharpness) {
	++calls_.transient;
	last_.intensity = clamp01(intensity);
	last_.sharpness = clamp01(sharpness);
	last_.duration = 0.0;
	const bool ok = backend().transient(last_.intensity, last_.sharpness);
	calls_.failed += ok ? 0 : 1;
	return ok;
}

bool Core::continuous(double intensity, double sharpness, double duration) {
	++calls_.continuous;
	last_.intensity = clamp01(intensity);
	last_.sharpness = clamp01(sharpness);
	last_.duration = clamp_duration(duration);
	const bool ok = backend().continuous(last_.intensity, last_.sharpness, last_.duration);
	calls_.failed += ok ? 0 : 1;
	return ok;
}

bool Core::register_pattern(const std::string &name, const std::string &ahap_json) {
	++calls_.register_pattern;
	last_.pattern = name;
	const bool ok = !name.empty() && backend().register_pattern(name, ahap_json);
	calls_.failed += ok ? 0 : 1;
	return ok;
}

bool Core::play_registered(const std::string &name) {
	++calls_.play_registered;
	last_.pattern = name;
	const bool ok = backend().play_registered(name);
	calls_.failed += ok ? 0 : 1;
	return ok;
}

bool Core::play_pattern(const std::string &ahap_json) {
	++calls_.play_pattern;
	last_.pattern = "<inline>";
	const bool ok = backend().play_pattern(ahap_json);
	calls_.failed += ok ? 0 : 1;
	return ok;
}

void Core::selection() {
	++calls_.selection;
	backend().selection();
}

void Core::impact(int64_t style, double intensity) {
	++calls_.impact;
	const int64_t s = std::clamp<int64_t>(style, static_cast<int64_t>(ImpactStyle::kLight), static_cast<int64_t>(ImpactStyle::kRigid));
	last_.impact_style = s;
	last_.intensity = clamp01(intensity);
	backend().impact(static_cast<ImpactStyle>(s), last_.intensity);
}

void Core::prepare() {
	++calls_.prepare;
	backend().prepare();
}

std::string Core::thermal_state() {
	return backend().thermal_state();
}

bool Core::is_low_power_mode() {
	return backend().is_low_power_mode();
}

int64_t Core::thermal_change_count() {
	return backend().thermal_change_count();
}

std::string Core::debug_state() {
	Backend &b = backend();
	std::string calls = "{";
	append_kv(calls, "start", num(calls_.start));
	append_kv(calls, "stop", num(calls_.stop));
	append_kv(calls, "transient", num(calls_.transient));
	append_kv(calls, "continuous", num(calls_.continuous));
	append_kv(calls, "register_pattern", num(calls_.register_pattern));
	append_kv(calls, "play_registered", num(calls_.play_registered));
	append_kv(calls, "play_pattern", num(calls_.play_pattern));
	append_kv(calls, "selection", num(calls_.selection));
	append_kv(calls, "impact", num(calls_.impact));
	append_kv(calls, "prepare", num(calls_.prepare));
	append_kv(calls, "failed", num(calls_.failed));
	calls += '}';

	std::string last = "{";
	append_kv(last, "intensity", num(last_.intensity));
	append_kv(last, "sharpness", num(last_.sharpness));
	append_kv(last, "duration", num(last_.duration));
	append_kv(last, "impact_style", num(last_.impact_style));
	append_kv(last, "pattern", json_quote(last_.pattern));
	last += '}';

	std::string out = "{";
	append_kv(out, "backend", json_quote(b.name()));
	append_kv(out, "supported", boolean(b.is_supported()));
	append_kv(out, "instances", num(instances_));
	append_kv(out, "thermal", json_quote(b.thermal_state()));
	append_kv(out, "low_power", boolean(b.is_low_power_mode()));
	append_kv(out, "calls", calls);
	append_kv(out, "last", last);
	append_kv(out, "native", "{" + b.state_fields() + "}");
	out += '}';
	return out;
}

} // namespace lane1::haptics
