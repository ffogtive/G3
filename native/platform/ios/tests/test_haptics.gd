extends Node
## T0 test for the IOSHaptics GDExtension (host null backend) and the Haptics autoload routing.
## Follows native/tests/run_tests.gd conventions (run() -> int failures, PASS/FAIL/SKIP lines); meant to live at
## native/tests/test_haptics.gd. Needs the host library: `bash tools/mac/build_ios_ext.sh --host`.
##
## 가설: ✅ C 인터페이스 바인딩(Variant call / ptrcall, float·int·bool·String, RefCounted 수명)은 플랫폼과 무관하므로
##       Linux null 백엔드로 검증하면 iOS에서는 Core Haptics 호출부(.mm)만 남는다.

const SUITE: String = "unit"
const HAPTICS_SCRIPT: String = "res://autoload/haptics.gd"
const NATIVE: StringName = &"IOSHaptics"
const EPS: float = 0.0005

var _fails: int = 0


func run() -> int:
	if not ClassDB.class_exists(NATIVE):
		print("SKIP test_haptics: IOSHaptics not registered (build it: bash tools/mac/build_ios_ext.sh --host)")
		return 0
	_test_native_call_path()
	_test_native_ptrcall_path()
	_test_native_refcount()
	_test_ahap_builder()
	await _test_autoload_ios_route()
	await _test_autoload_vibrate_route()
	return _fails


func _check(cond: bool, what: String) -> void:
	if cond:
		print("PASS haptics: %s" % what)
	else:
		_fails += 1
		print("FAIL haptics: %s" % what)


func _state(h: Object) -> Dictionary:
	var parsed: Variant = JSON.parse_string(str(h.call(&"debug_state")))
	return parsed if parsed is Dictionary else {}


func _test_native_call_path() -> void:
	var h: RefCounted = ClassDB.instantiate(NATIVE) as RefCounted
	_check(h != null, "ClassDB.instantiate(IOSHaptics)")
	if h == null:
		return
	_check(str(h.call(&"backend_name")) == "null", "host backend is 'null'")
	_check(not bool(h.call(&"is_supported")), "null backend reports unsupported")
	_check(str(h.call(&"build_info")).begins_with("lane1_haptics "), "build_info: %s" % str(h.call(&"build_info")))
	var before: Dictionary = _state(h)
	var calls0: Dictionary = before.get("calls", {})
	_check(bool(h.call(&"start")), "start() -> true")
	_check(bool(h.call(&"transient", 0.5, 0.7)), "transient(0.5, 0.7) -> true")
	var s: Dictionary = _state(h)
	var last: Dictionary = s.get("last", {})
	var calls: Dictionary = s.get("calls", {})
	_check(int(calls.get("transient", -1)) == int(calls0.get("transient", 0)) + 1, "transient counted once")
	_check(absf(float(last.get("intensity", -1.0)) - 0.5) < EPS and absf(float(last.get("sharpness", -1.0)) - 0.7) < EPS,
			"float args survive the Variant call path (%s)" % str(last))
	h.call(&"transient", 2.0, -1.0)
	last = _state(h).get("last", {})
	_check(float(last.get("intensity", -1.0)) == 1.0 and float(last.get("sharpness", -1.0)) == 0.0, "intensity/sharpness clamped to [0,1]")
	h.call(&"transient", 1, 0)
	last = _state(h).get("last", {})
	_check(float(last.get("intensity", -1.0)) == 1.0, "int arguments accepted for float parameters")
	_check(bool(h.call(&"continuous", 0.4, 0.2, 0.08)), "continuous() -> true")
	last = _state(h).get("last", {})
	_check(absf(float(last.get("duration", -1.0)) - 0.08) < EPS, "duration arg (%s)" % str(last.get("duration")))
	var ahap: String = JSON.stringify({"Version": 1.0, "Pattern": [{"Event": {"Time": 0.0, "EventType": "HapticTransient"}}]})
	_check(bool(h.call(&"register_pattern", "t_one", ahap)), "register_pattern(String, String) -> true")
	_check(bool(h.call(&"play_registered", "t_one")), "play_registered(known) -> true")
	_check(not bool(h.call(&"play_registered", "t_unknown")), "play_registered(unknown) -> false")
	_check(not bool(h.call(&"register_pattern", "t_bad", "{}")), "register_pattern rejects a non-AHAP string")
	_check(bool(h.call(&"play_pattern", ahap)), "play_pattern(String) -> true")
	h.call(&"impact", 2, 0.5)
	_check(int(_state(h).get("last", {}).get("impact_style", -1)) == 2, "impact(style=2) passes the int")
	h.call(&"impact", 99, 0.5)
	_check(int(_state(h).get("last", {}).get("impact_style", -1)) == 4, "impact style clamped to rigid (4)")
	h.call(&"selection")
	h.call(&"prepare")
	_check(str(h.call(&"thermal_state")) == "unknown", "thermal_state() on host is 'unknown'")
	_check(not bool(h.call(&"is_low_power_mode")), "is_low_power_mode() -> false on host")
	_check(int(h.call(&"thermal_change_count")) == 0, "thermal_change_count() -> 0 on host")
	var name_with_unicode: String = "패턴_✓"
	_check(bool(h.call(&"register_pattern", name_with_unicode, ahap)) and str(_state(h).get("last", {}).get("pattern", "")) == name_with_unicode,
			"UTF-8 String round trip (%s)" % name_with_unicode)
	h.call(&"stop")


## Typed calls compile to validated/ptr calls in GDScript; build the script at runtime so this file still
## parses on platforms where the class is absent.
func _test_native_ptrcall_path() -> void:
	var gd: GDScript = GDScript.new()
	gd.source_code = """extends RefCounted
func probe() -> Array:
	var h: IOSHaptics = IOSHaptics.new()
	var ok: bool = h.transient(0.25, 0.125)
	var name: String = h.backend_name()
	var state: String = h.debug_state()
	var changes: int = h.thermal_change_count()
	h.impact(1, 0.75)
	var reg: bool = h.register_pattern("ptr", '{"Version":1,"Pattern":[]}')
	return [ok, name, state, changes, reg, h.debug_state()]
"""
	var err: Error = gd.reload()
	_check(err == OK, "typed IOSHaptics script compiles (class visible to the GDScript analyzer)")
	if err != OK:
		return
	var probe: RefCounted = gd.new() as RefCounted
	var out: Array = probe.call(&"probe")
	_check(out.size() == 6 and bool(out[0]) and str(out[1]) == "null" and int(out[3]) == 0 and bool(out[4]), "ptrcall returns bool/String/int (%s)" % str(out.slice(0, 5) if out.size() >= 5 else out))
	var parsed: Variant = JSON.parse_string(str(out[2]) if out.size() > 2 else "")
	var last: Dictionary = (parsed as Dictionary).get("last", {}) if parsed is Dictionary else {}
	_check(absf(float(last.get("intensity", -1.0)) - 0.25) < EPS and absf(float(last.get("sharpness", -1.0)) - 0.125) < EPS,
			"float args survive ptrcall (%s)" % str(last))
	var parsed2: Variant = JSON.parse_string(str(out[5]) if out.size() > 5 else "")
	var last2: Dictionary = (parsed2 as Dictionary).get("last", {}) if parsed2 is Dictionary else {}
	_check(int(last2.get("impact_style", -1)) == 1 and absf(float(last2.get("intensity", -1.0)) - 0.75) < EPS,
			"int + float ptrcall args (impact) (%s)" % str(last2))


func _test_native_refcount() -> void:
	var probe: RefCounted = ClassDB.instantiate(NATIVE) as RefCounted
	var base: int = int(_state(probe).get("instances", -1))
	var extra: RefCounted = ClassDB.instantiate(NATIVE) as RefCounted
	var with_extra: int = int(_state(probe).get("instances", -1))
	extra = null
	var after: int = int(_state(probe).get("instances", -1))
	_check(with_extra == base + 1 and after == base, "RefCounted lifecycle: instances %d -> %d -> %d" % [base, with_extra, after])
	probe = null


func _test_ahap_builder() -> void:
	var script: GDScript = load(HAPTICS_SCRIPT) as GDScript
	var kill: Dictionary = script.call(&"build_ahap", [
		{"type": "transient", "intensity": 1.0, "sharpness": 0.7, "t": 0},
		{"type": "continuous", "intensity": 0.6, "sharpness": 0.2, "t": 0, "dur": 0.6, "decayTo": 0},
	])
	var pattern: Array = kill.get("Pattern", [])
	_check(pattern.size() == 3, "villainKill -> transient + continuous + intensity curve (%d items)" % pattern.size())
	if pattern.size() == 3:
		var curve: Dictionary = (pattern[2] as Dictionary).get("ParameterCurve", {})
		var points: Array = curve.get("ParameterCurveControlPoints", [])
		_check(str(curve.get("ParameterID", "")) == "HapticIntensityControl" and points.size() == 2 and float((points[1] as Dictionary).get("ParameterValue", -1)) == 0.0,
				"decayTo 0 -> HapticIntensityControl 1.0 -> 0.0")
		var cont: Dictionary = (pattern[1] as Dictionary).get("Event", {})
		_check(str(cont.get("EventType", "")) == "HapticContinuous" and absf(float(cont.get("EventDuration", 0)) - 0.6) < EPS, "continuous EventDuration")
	var ticks: Dictionary = script.call(&"build_ahap", [
		{"type": "transient", "intensity": 0.3, "sharpness": 0.8, "t": 0},
		{"type": "transient", "intensity": 0.6, "sharpness": 0.8, "t": null},
		{"type": "transient", "intensity": 0.9, "sharpness": 0.8, "t": null},
	])
	var times: Array[float] = []
	for item: Variant in ticks.get("Pattern", []):
		times.append(float(((item as Dictionary).get("Event", {}) as Dictionary).get("Time", -1.0)))
	_check(times.size() == 3 and absf(times[1] - 0.08) < EPS and absf(times[2] - 0.16) < EPS, "t = null entries spaced by DEFAULT_STEP_S (%s)" % str(times))
	var inherit: Dictionary = script.call(&"build_ahap", [
		{"type": "transient", "intensity": 0.8, "sharpness": 0.2, "t": 0},
		{"type": "continuous", "intensity": 0.4, "sharpness": null, "t": 0, "dur": 0.08, "decayTo": null},
	])
	var inherit_pattern: Array = inherit.get("Pattern", [])
	var cont_params: Array = ((inherit_pattern[1] as Dictionary).get("Event", {}) as Dictionary).get("EventParameters", []) if inherit_pattern.size() > 1 else []
	_check(inherit_pattern.size() == 2 and cont_params.size() == 2 and absf(float((cont_params[1] as Dictionary).get("ParameterValue", -1)) - 0.2) < EPS,
			"null sharpness inherits the previous entry; no curve when decayTo is null")
	var none: Dictionary = script.call(&"build_ahap", [{"type": "selection"}])
	_check((none.get("Pattern", [1]) as Array).is_empty(), "generator-only entries produce no AHAP events")


func _new_haptics() -> Node:
	var node: Node = (load(HAPTICS_SCRIPT) as GDScript).new() as Node
	add_child(node)  # runs _ready: load_data + select_backend
	return node


func _test_autoload_ios_route() -> void:
	var hx: Node = _new_haptics()
	var stats: Dictionary = hx.call(&"stats")
	_check(str(stats.get("backend", "")) == "ios:null", "routes to IOSHaptics when the class exists (%s)" % str(stats.get("backend")))
	var names: PackedStringArray = hx.call(&"event_names")
	_check(names.size() >= 15, "haptics.json loaded (%d events)" % names.size())
	var expected_registered: int = 0
	for event: String in names:
		var spec: Dictionary = (hx.get(&"_events") as Dictionary)[event]
		var has_android: bool = spec.get("android") is Array and not (spec.get("android") as Array).is_empty()
		var has_ios: bool = spec.get("ios") is Array and not (spec.get("ios") as Array).is_empty()
		if not (has_android and has_ios):
			_check(false, "event '%s' has both ios and android entries" % event)
		var ahap: Dictionary = (load(HAPTICS_SCRIPT) as GDScript).call(&"build_ahap", spec.get("ios", []))
		if not (ahap.get("Pattern", []) as Array).is_empty():
			expected_registered += 1
	_check(int(stats.get("registered", -1)) == expected_registered, "every Core Haptics event pre-registered (%d/%d)" % [int(stats.get("registered", -1)), expected_registered])
	var native_before: Dictionary = JSON.parse_string(str(hx.call(&"native_debug_state")))
	var reg_before: int = int((native_before.get("calls", {}) as Dictionary).get("play_registered", 0))
	var sel_before: int = int((native_before.get("calls", {}) as Dictionary).get("selection", 0))
	_check(bool(hx.call(&"haptic", "horn")), "haptic('horn') plays")
	_check(bool(hx.call(&"haptic", "laneChange")), "haptic('laneChange') plays (selection generator)")
	_check(not bool(hx.call(&"haptic", "noSuchEvent")), "unknown event -> false")
	var native_after: Dictionary = JSON.parse_string(str(hx.call(&"native_debug_state")))
	var calls_after: Dictionary = native_after.get("calls", {})
	_check(int(calls_after.get("play_registered", 0)) == reg_before + 1 and int(calls_after.get("selection", 0)) == sel_before + 1,
			"horn -> play_registered, laneChange -> selection()")
	_check(bool(hx.call(&"haptic", "tackHit")), "tackHit first hit plays")
	_check(not bool(hx.call(&"haptic", "tackHit")), "tackHit within minIntervalMs (120) is dropped")
	_check(bool(hx.call(&"haptic", "releaseWave", 2)), "releaseWave step 2 plays a single beat")
	_check(str(hx.call(&"thermal_state")) == "unknown", "Haptics.thermal_state() passes through")
	hx.set(&"enabled", false)
	_check(not bool(hx.call(&"haptic", "horn")), "disabled -> no haptic")
	hx.queue_free()
	await get_tree().process_frame
	# Global cap: 12 per second across events.
	var hy: Node = _new_haptics()
	var admitted: int = 0
	for event: String in hy.call(&"event_names"):
		if bool(hy.call(&"haptic", event)):
			admitted += 1
	_check(admitted == 12, "global maxPerSecond = 12 (admitted %d of %d)" % [admitted, (hy.call(&"event_names") as PackedStringArray).size()])
	hy.queue_free()
	await get_tree().process_frame


func _test_autoload_vibrate_route() -> void:
	var hv: Node = _new_haptics()
	var calls: Array[Vector2] = []
	var recorder: Callable = func(ms: int, amp: float) -> void: calls.append(Vector2(ms, amp))
	hv.set(&"_native", null)
	hv.set(&"_backend", 2)  # Backend.VIBRATE
	hv.set(&"vibrate_fn", recorder)
	_check(str(hv.call(&"backend_name")) == "vibrate", "forced vibrate backend")
	_check(bool(hv.call(&"haptic", "wreck")), "haptic('wreck') via vibrate_handheld")
	_check(calls.size() == 1 and calls[0] == Vector2(80, 1.0), "first wreck pulse immediate: 80 ms @ 1.0 (%s)" % str(calls))
	await get_tree().create_timer(0.2, true, false, true).timeout
	_check(calls.size() == 2 and calls[1].x == 300 and absf(calls[1].y - 0.2) < EPS, "second wreck pulse after t=0.08 s: 300 ms @ 0.2 (%s)" % str(calls))
	calls.clear()
	_check(bool(hv.call(&"haptic", "rageFull")), "rageFull with null amp/t")
	await get_tree().create_timer(0.3, true, false, true).timeout
	_check(calls.size() == 3 and calls[0].y == -1.0, "rageFull: 3 pulses, null amp -> device default (-1) (%s)" % str(calls))
	hv.queue_free()
	await get_tree().process_frame
