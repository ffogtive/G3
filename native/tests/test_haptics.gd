extends Node
## Haptics tests run by run_tests.gd:
##   1. the IOSHaptics extension test that lives with the iOS tooling (res://platform/ios/tests/test_haptics.gd); it
##      SKIPs by itself when the host IOSHaptics library is not built;
##   2. r3 F1 data contract (always runs): the combo haptics (combo5 · combo10 · combo20 · comboBreak) and the stronger
##      t1 충격파 peak are in data/haptics.json with the spec shapes, and the Haptics autoload loads and plays them
##      (forced vibrate backend, recorder instead of Input.vibrate_handheld).
## 가설(r3 F1): ❓ a combo reward the thumb can feel (×10 = two crisp taps 60 ms apart, ×20 = a heavy hit + 80 ms rumble,
##       break = one light tap) tells the combo apart from the steady tackHit ticks without looking at the badge.
## View-only data: identical on the C++ traffic and the GDScript fallback (no sim involved).

const SUITE: String = "unit"
const TEST_PATH: String = "res://platform/ios/tests/test_haptics.gd"
const DATA: String = "res://data/haptics.json"
const HAPTICS_SCRIPT: String = "res://autoload/haptics.gd"
const EPS: float = 0.0005
const NEW_KEYS: PackedStringArray = ["combo5", "combo10", "combo20", "comboBreak"]

var _fails: int = 0


func _check(ok: bool, what: String) -> void:
	print(("PASS" if ok else "FAIL") + " haptics_f1: " + what)
	if not ok:
		_fails += 1


func run() -> int:
	var t: Node = (load(TEST_PATH) as GDScript).new() as Node
	add_child(t)
	var fails: int = await t.call(&"run")
	t.queue_free()
	_data()
	await _autoload()
	return fails + _fails


static func _ios(spec: Dictionary) -> Array:
	return spec.get("ios", []) if spec.get("ios") is Array else []


static func _and(spec: Dictionary) -> Array:
	return spec.get("android", []) if spec.get("android") is Array else []


func _data() -> void:
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(DATA))
	var ev: Dictionary = (raw as Dictionary).get("events", {}) if raw is Dictionary else {}
	var missing: PackedStringArray = []
	for n: String in NEW_KEYS:
		if not ev.has(n) or _ios(ev[n]).is_empty() or _and(ev[n]).is_empty():
			missing.append(n)
	_check(missing.is_empty(), "combo5 / combo10 / combo20 / comboBreak exist with ios + android patterns (missing %s)" % missing)
	if not missing.is_empty():
		return
	var hs: GDScript = load(HAPTICS_SCRIPT)
	# combo10: 0.5 / 0.9 × 2, 60 ms apart
	var c10: Array = _ios(ev["combo10"])
	var c10_ok: bool = c10.size() == 2
	for i: int in c10.size():
		var en: Dictionary = c10[i]
		c10_ok = c10_ok and str(en.get("type")) == "transient" and absf(float(en.get("intensity", 0)) - 0.5) < EPS \
			and absf(float(en.get("sharpness", 0)) - 0.9) < EPS and absf(float(en.get("t", -1)) - 0.06 * float(i)) < EPS
	var a10: Array = _and(ev["combo10"])
	c10_ok = c10_ok and a10.size() == 2 and absf(float((a10[1] as Dictionary).get("t", 0)) - 0.06) < EPS
	_check(c10_ok, "combo10 = two 0.5/0.9 transients 60 ms apart (android two pulses) %s" % JSON.stringify(c10))
	# combo20: 0.9 / 0.6 transient + an 80 ms continuous at 0.4
	var c20: Array = _ios(ev["combo20"])
	var c20_ok: bool = c20.size() == 2 and str((c20[0] as Dictionary).get("type")) == "transient" \
		and absf(float((c20[0] as Dictionary).get("intensity", 0)) - 0.9) < EPS and absf(float((c20[0] as Dictionary).get("sharpness", 0)) - 0.6) < EPS \
		and str((c20[1] as Dictionary).get("type")) == "continuous" and absf(float((c20[1] as Dictionary).get("dur", 0)) - 0.08) < EPS \
		and absf(float((c20[1] as Dictionary).get("intensity", 0)) - 0.4) < EPS
	var ah: Dictionary = hs.call(&"build_ahap", c20)
	var pat: Array = ah.get("Pattern", [])
	c20_ok = c20_ok and pat.size() >= 2 and str(((pat[1] as Dictionary).get("Event", {}) as Dictionary).get("EventType", "")) == "HapticContinuous"
	_check(c20_ok, "combo20 = 0.9/0.6 transient + 80 ms continuous 0.4 (AHAP %d entries)" % pat.size())
	# combo5 / comboBreak: one light generator tap each
	var light_ok: bool = true
	for n: String in ["combo5", "comboBreak"]:
		var e: Array = _ios(ev[n])
		light_ok = light_ok and e.size() == 1 and str((e[0] as Dictionary).get("type")) == "impactLight" and _and(ev[n]).size() == 1
	_check(light_ok, "combo5 and comboBreak = one impactLight tap (android one short pulse)")
	# t1 충격파: peak 0.8 + 120 ms tail
	var t1: Array = _ios(ev.get("skillT1", {}))
	var tail: Dictionary = t1[1] if t1.size() >= 2 else {}
	var peak: float = 0.0
	for en: Variant in t1:
		peak = maxf(peak, float((en as Dictionary).get("intensity", 0)))
	var t1_ok: bool = absf(peak - 0.8) < EPS and str(tail.get("type")) == "continuous" and absf(float(tail.get("dur", 0)) - 0.12) < EPS \
		and absf(float(tail.get("intensity", 0)) - 0.8) < EPS and int((_and(ev["skillT1"])[0] as Dictionary).get("ms", 0)) == 120
	_check(t1_ok, "skillT1 = peak 0.8 + 120 ms tail at 0.8 (android 120 ms) %s" % JSON.stringify(t1))
	# every cue name SkillCues fires for the combo exists here
	var cue_names: PackedStringArray = []
	for k: String in ["c5", "c10", "c20", "t1_wave"]:
		cue_names.append(str(SkillCues.HAPTIC_HIT.get(k, "")))
	cue_names.append("comboBreak")
	var absent: PackedStringArray = []
	for n: String in cue_names:
		if not ev.has(n):
			absent.append(n)
	_check(absent.is_empty(), "SkillCues combo / t1_wave haptic names are all in the map %s (absent %s)" % [cue_names, absent])


func _autoload() -> void:
	var hv: Node = (load(HAPTICS_SCRIPT) as GDScript).new() as Node
	add_child(hv)  # _ready: load_data + select_backend
	var names: PackedStringArray = hv.call(&"event_names")
	var loaded: bool = true
	for n: String in NEW_KEYS:
		loaded = loaded and names.has(n)
	_check(loaded, "Haptics autoload loads the 4 new keys (%d events)" % names.size())
	var calls: Array[Vector2] = []
	var recorder: Callable = func(ms: int, amp: float) -> void: calls.append(Vector2(ms, amp))
	hv.set(&"_native", null)
	hv.set(&"_backend", 2)  # Backend.VIBRATE (an Android / module-less build; iOS uses the AHAP above)
	hv.set(&"vibrate_fn", recorder)
	var played: Array[bool] = []
	for n: String in NEW_KEYS:
		played.append(bool(hv.call(&"haptic", n)))
	await get_tree().create_timer(0.15, true, false, true).timeout
	# combo5 1 + combo10 2 + combo20 2 + comboBreak 1 pulses
	_check(played == [true, true, true, true] and calls.size() == 6,
		"combo5 / combo10 / combo20 / comboBreak play through the vibrate route (%s, %d pulses %s)" % [played, calls.size(), calls])
	await get_tree().create_timer(0.2, true, false, true).timeout
	var first: bool = bool(hv.call(&"haptic", "combo10"))
	var again: bool = bool(hv.call(&"haptic", "combo10"))
	_check(first and not again, "combo10 twice inside its 150 ms min interval → the second is dropped (%s %s)" % [first, again])
	hv.queue_free()
	await get_tree().process_frame
