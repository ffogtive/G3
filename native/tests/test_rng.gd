extends RefCounted
## T0: mulberry32 == the JS stream (native/tests/golden/rng_stage1.json: seed 1007, 1000 values).
##
## 가설: ✅(M0 bench) uint32 C++ and masked GDScript reproduce the JS stream bit-for-bit (NATIVE_PORT 3-3).
## Checks the GDScript Mulberry32 (always), the C++ Rng32 (when the ext is built), the f64 view u32/2^32,
## and that Godot's own JSON parser is the 1-ulp-off one (so the exact parser stays needed).

const GOLDEN: String = "res://tests/golden/rng_stage1.json"
const _DB := preload("res://core/db.gd")

var _fails: int = 0


func run() -> int:
	var g: Dictionary = _DB.load_json(GOLDEN)
	var u32: Array = g.get("u32", [])
	var f64: Array = g.get("f64", [])
	var seed: int = int(g.get("seed", 0))
	_check(seed == Mulberry32.traffic_seed(1) and u32.size() == 1000 and f64.size() == 1000,
			"golden: seed %d == stage 1 traffic seed, 1000 u32 + 1000 f64" % seed)
	if u32.size() != 1000:
		return _fails

	var gd := Mulberry32.new(seed)
	var bad_u: int = -1
	var bad_f: int = -1
	for i: int in 1000:
		var u: int = gd.next_u32()
		if u != int(u32[i]) and bad_u < 0:
			bad_u = i
		if float(u) / 4294967296.0 != float(f64[i]) and bad_f < 0:
			bad_f = i
	_check(bad_u < 0, "GDScript Mulberry32: 1000 u32 == JS%s" % ("" if bad_u < 0 else " (first diff #%d)" % bad_u))
	var exact: bool = ClassDB.class_exists(&"Traffic")
	if exact:
		_check(bad_f < 0, "f64 = u32 / 2^32 == golden f64 (17 digits, exact parser)%s" % ("" if bad_f < 0 else " (first diff #%d)" % bad_f))
	var again := Mulberry32.new(seed)
	_check(is_equal_approx(again.next_float(), float(f64[0])) and again.draws == 1, "next_float() + draws counter")
	_check(Mulberry32.imul(0xFFFFFFFF, 0xFFFFFFFF) == 1 and Mulberry32.imul(0x6D2B79F5, 0x10001) == (0x6D2B79F5 * 0x10001) & 0xFFFFFFFF,
			"imul wraps like Math.imul")

	if not ClassDB.class_exists(&"Rng32"):
		print("SKIP test_rng: C++ Rng32 not built (bash tools/godot/build_ext.sh)")
		return _fails
	var cpp: Object = ClassDB.instantiate(&"Rng32")
	cpp.call(&"set_seed", seed)
	var bad_c: int = -1
	var bad_cf: int = -1
	for i: int in 1000:
		if int(cpp.call(&"next_u32")) != int(u32[i]) and bad_c < 0:
			bad_c = i
	cpp.call(&"set_seed", seed)
	for i: int in 1000:
		if float(cpp.call(&"next_float")) != float(f64[i]) and bad_cf < 0:
			bad_cf = i
	_check(bad_c < 0 and bad_cf < 0 and int(cpp.call(&"get_draws")) == 1000,
			"C++ Rng32: 1000 u32 and 1000 f64 == JS%s" % ("" if bad_c < 0 and bad_cf < 0 else " (u32 #%d f64 #%d)" % [bad_c, bad_cf]))

	# Why DB uses Traffic.parse_json: Godot's parser rounds this golden value differently (1 ulp).
	var text: String = "[0.9794402686925605, 109.68132757457593]"
	var godot_v: Array = JSON.parse_string(text)
	var exact_v: Array = ClassDB.class_call_static(&"Traffic", &"parse_json", text)
	var bits_exact: String = PackedFloat64Array([exact_v[0], exact_v[1]]).to_byte_array().hex_encode()
	var bits_godot: String = PackedFloat64Array([godot_v[0], godot_v[1]]).to_byte_array().hex_encode()
	_check(bits_exact == "a4704d1e9357ef3faaaaf8de9a6b5b40", "Traffic.parse_json is correctly rounded (bits %s)" % bits_exact)
	print("INFO test_rng: Godot JSON.parse bits %s (%s)" % [bits_godot, "same" if bits_godot == bits_exact else "1-ulp off -> exact parser needed"])
	var nested: Variant = ClassDB.class_call_static(&"Traffic", &"parse_json", "{\"a\":[1,true,null,\"\\u00e9\\ud83d\\ude00\"],\"b\":{}}")
	_check(nested is Dictionary and ((nested as Dictionary)["a"] as Array)[3] == "é😀" and ((nested as Dictionary)["a"] as Array)[0] is float,
			"Traffic.parse_json: nesting, escapes, numbers as float (like JSON.parse_string)")
	return _fails


func _check(ok: bool, what: String) -> void:
	if ok:
		print("PASS test_rng: %s" % what)
	else:
		_fails += 1
		print("FAIL test_rng: %s" % what)
