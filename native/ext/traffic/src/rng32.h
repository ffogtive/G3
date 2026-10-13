// Rng32 — mulberry32, bit-identical to game/js/traffic.js `mulberry32` (NATIVE_PORT 3-3).
//
// JS reference:
//   a |= 0; a = (a + 0x6d2b79f5) | 0;
//   let t = Math.imul(a ^ (a >>> 15), 1 | a);
//   t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
//   return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
// Math.imul / `| 0` are 32-bit wrap-around ops, which is exactly uint32_t arithmetic in C++.
#pragma once

#include <cstdint>

namespace lane1::sim {

struct Mulberry32 {
	uint32_t a = 0;

	explicit Mulberry32(uint32_t p_seed = 0) :
			a(p_seed) {}

	uint32_t next_u32() {
		a += 0x6d2b79f5u;
		uint32_t t = (a ^ (a >> 15)) * (1u | a);
		t = (t + ((t ^ (t >> 7)) * (61u | t))) ^ t;
		return t ^ (t >> 14);
	}
	// u32 / 2^32 in [0, 1): exact in double (24+ spare mantissa bits).
	double next() { return static_cast<double>(next_u32()) / 4294967296.0; }
};

} // namespace lane1::sim
