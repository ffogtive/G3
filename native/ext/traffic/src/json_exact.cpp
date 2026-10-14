#include "json_exact.h"

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include <cstdlib>
#include <cstring>
#include <string>

#if defined(__has_include)
#if __has_include(<charconv>)
#include <charconv>
#endif
#endif

namespace lane1 {

namespace {

struct Parser {
	const char *p = nullptr;
	const char *end = nullptr;
	std::string err;
	int depth = 0;

	void ws() {
		while (p < end && (*p == ' ' || *p == '\n' || *p == '\r' || *p == '\t')) {
			++p;
		}
	}

	bool fail(const char *p_msg) {
		if (err.empty()) {
			err = p_msg;
		}
		return false;
	}

	static void put_utf8(std::string &r_out, uint32_t p_cp) {
		if (p_cp < 0x80) {
			r_out += static_cast<char>(p_cp);
		} else if (p_cp < 0x800) {
			r_out += static_cast<char>(0xC0 | (p_cp >> 6));
			r_out += static_cast<char>(0x80 | (p_cp & 0x3F));
		} else if (p_cp < 0x10000) {
			r_out += static_cast<char>(0xE0 | (p_cp >> 12));
			r_out += static_cast<char>(0x80 | ((p_cp >> 6) & 0x3F));
			r_out += static_cast<char>(0x80 | (p_cp & 0x3F));
		} else {
			r_out += static_cast<char>(0xF0 | (p_cp >> 18));
			r_out += static_cast<char>(0x80 | ((p_cp >> 12) & 0x3F));
			r_out += static_cast<char>(0x80 | ((p_cp >> 6) & 0x3F));
			r_out += static_cast<char>(0x80 | (p_cp & 0x3F));
		}
	}

	bool hex4(uint32_t &r_v) {
		if (end - p < 4) {
			return fail("short \\u escape");
		}
		r_v = 0;
		for (int i = 0; i < 4; ++i) {
			const char c = *p++;
			r_v <<= 4;
			if (c >= '0' && c <= '9') {
				r_v |= static_cast<uint32_t>(c - '0');
			} else if (c >= 'a' && c <= 'f') {
				r_v |= static_cast<uint32_t>(c - 'a' + 10);
			} else if (c >= 'A' && c <= 'F') {
				r_v |= static_cast<uint32_t>(c - 'A' + 10);
			} else {
				return fail("bad \\u escape");
			}
		}
		return true;
	}

	bool string(std::string &r_out) {
		++p; // opening quote
		while (p < end && *p != '"') {
			const char c = *p++;
			if (c != '\\') {
				r_out += c;
				continue;
			}
			if (p >= end) {
				return fail("dangling escape");
			}
			const char e = *p++;
			switch (e) {
				case '"':
				case '\\':
				case '/':
					r_out += e;
					break;
				case 'b':
					r_out += '\b';
					break;
				case 'f':
					r_out += '\f';
					break;
				case 'n':
					r_out += '\n';
					break;
				case 'r':
					r_out += '\r';
					break;
				case 't':
					r_out += '\t';
					break;
				case 'u': {
					uint32_t cp = 0;
					if (!hex4(cp)) {
						return false;
					}
					if (cp >= 0xD800 && cp <= 0xDBFF && end - p >= 6 && p[0] == '\\' && p[1] == 'u') {
						p += 2;
						uint32_t lo = 0;
						if (!hex4(lo)) {
							return false;
						}
						cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
					}
					put_utf8(r_out, cp);
					break;
				}
				default:
					return fail("bad escape");
			}
		}
		if (p >= end) {
			return fail("unterminated string");
		}
		++p; // closing quote
		return true;
	}

	bool number(double &r_d) {
		const char *s = p;
		while (p < end && (std::strchr("+-0123456789.eE", *p) != nullptr)) {
			++p;
		}
		if (p == s) {
			return fail("expected value");
		}
#if defined(__cpp_lib_to_chars) && __cpp_lib_to_chars >= 201611L
		const auto res = std::from_chars(s, p, r_d);
		if (res.ec != std::errc() || res.ptr != p) {
			return fail("bad number");
		}
#else
		const std::string tok(s, static_cast<size_t>(p - s));
		char *stop = nullptr;
		r_d = std::strtod(tok.c_str(), &stop);
		if (stop != tok.c_str() + tok.size()) {
			return fail("bad number");
		}
#endif
		return true;
	}

	bool literal(const char *p_word) {
		const size_t n = std::strlen(p_word);
		if (static_cast<size_t>(end - p) < n || std::strncmp(p, p_word, n) != 0) {
			return fail("bad literal");
		}
		p += n;
		return true;
	}

	bool value(godot::Variant &r_v) {
		ws();
		if (p >= end) {
			return fail("unexpected end");
		}
		if (++depth > 512) {
			return fail("nesting too deep");
		}
		bool ok = true;
		const char c = *p;
		if (c == '{') {
			++p;
			godot::Dictionary d;
			ws();
			if (p < end && *p == '}') {
				++p;
			} else {
				while (ok) {
					ws();
					if (p >= end || *p != '"') {
						ok = fail("expected key");
						break;
					}
					std::string key;
					if (!string(key)) {
						ok = false;
						break;
					}
					ws();
					if (p >= end || *p != ':') {
						ok = fail("expected ':'");
						break;
					}
					++p;
					godot::Variant v;
					if (!value(v)) {
						ok = false;
						break;
					}
					d[godot::String::utf8(key.c_str(), static_cast<int64_t>(key.size()))] = v;
					ws();
					if (p < end && *p == ',') {
						++p;
						continue;
					}
					if (p < end && *p == '}') {
						++p;
						break;
					}
					ok = fail("expected ',' or '}'");
				}
			}
			r_v = d;
		} else if (c == '[') {
			++p;
			godot::Array a;
			ws();
			if (p < end && *p == ']') {
				++p;
			} else {
				while (ok) {
					godot::Variant v;
					if (!value(v)) {
						ok = false;
						break;
					}
					a.push_back(v);
					ws();
					if (p < end && *p == ',') {
						++p;
						continue;
					}
					if (p < end && *p == ']') {
						++p;
						break;
					}
					ok = fail("expected ',' or ']'");
				}
			}
			r_v = a;
		} else if (c == '"') {
			std::string s;
			ok = string(s);
			r_v = godot::String::utf8(s.c_str(), static_cast<int64_t>(s.size()));
		} else if (c == 't') {
			ok = literal("true");
			r_v = true;
		} else if (c == 'f') {
			ok = literal("false");
			r_v = false;
		} else if (c == 'n') {
			ok = literal("null");
			r_v = godot::Variant();
		} else {
			double d = 0;
			ok = number(d);
			r_v = d;
		}
		--depth;
		return ok;
	}
};

} // namespace

godot::Variant parse_json_exact(const godot::String &p_text, godot::String *r_error) {
	const godot::CharString utf8 = p_text.utf8();
	Parser ps;
	ps.p = utf8.get_data();
	ps.end = ps.p + utf8.length();
	godot::Variant out;
	bool ok = ps.value(out);
	ps.ws();
	if (ok && ps.p != ps.end) {
		ok = ps.fail("trailing characters");
	}
	if (!ok) {
		if (r_error) {
			*r_error = godot::String("json_exact: ") + godot::String(ps.err.c_str()) + " at byte " +
					godot::String::num_int64(static_cast<int64_t>(ps.p - utf8.get_data()));
		}
		return godot::Variant();
	}
	return out;
}

} // namespace lane1
