// json_exact — JSON -> Variant with correctly rounded numbers.
//
// 가설: ✅ Godot 4.7.2's String::to_float (used by JSON.parse and the GDScript tokenizer) is not correctly
//       rounded for 16-17 significant digits: "0.9794402686925605" and "109.68132757457593" come out 1 ulp
//       off (checked against CPython struct.pack). The JS exporter writes shortest round-trip doubles, so
//       stages.json (113 such numbers) and every golden need a correctly rounded parser for bit parity.
// Output mirrors JSON.parse_string: Dictionary (insertion order) / Array / String / float / bool / null.
#pragma once

#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace lane1 {

// Returns null and sets r_error (when given) on malformed input.
godot::Variant parse_json_exact(const godot::String &p_text, godot::String *r_error = nullptr);

} // namespace lane1
