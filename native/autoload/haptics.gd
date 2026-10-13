extends Node
## Haptics autoload (docs/NATIVE_PORT.md 2 햅틱 맵; autoload order 3-1: DB SaveGame InputBuffer Audio Haptics Fx UI).
##
## 가설: ❓ 햅틱 맵(data/haptics.json)을 이벤트 이름 하나로 부르고, 백엔드는 런타임에 고르면 sim·view 코드는
##       플랫폼을 몰라도 된다. iOS는 Core Haptics 모듈(transient+sharpness, 미리 파싱한 AHAP), 그 밖의 모바일은
##       Input.vibrate_handheld(ms, amplitude), 데스크톱·헤드리스는 no-op.
##
## Routing (chosen once in _ready):
##   IOS      ClassDB has "IOSHaptics" (native/platform/ios). On iOS it drives Core Haptics; the Linux/macOS
##            host build of the same class is a null backend that only counts calls (container tests).
##   VIBRATE  OS.has_feature("mobile") without the module (Android until M2, or an iOS build whose module was
##            stubbed): plays the event's "android" list through Input.vibrate_handheld.
##   NONE     everything else.
## Rate limits come from the data (per-event minIntervalMs / maxPerSecond, global maxPerSecond = 12) and use
## real time (Time.get_ticks_msec), so hit-stop, slow-mo and pause never delay or swallow a haptic.
## Also logs NSProcessInfo thermal state every 10 s on device (NATIVE_PORT 2, 발열·배터리 행).

enum Backend { NONE, IOS, VIBRATE }

const DATA_PATH: String = "res://data/haptics.json"
const NATIVE_CLASS: StringName = &"IOSHaptics"
## Spacing for pattern entries whose "t" is null (rageFull ticks, releaseWave beats played as one pattern). ❓ tune on device.
const DEFAULT_STEP_S: float = 0.08
const DEFAULT_SHARPNESS: float = 0.5
const DEFAULT_VIBRATE_MS: int = 20
const THERMAL_LOG_INTERVAL_MS: int = 10000
const THERMAL_POLL_MS: int = 1000
const IMPACT_STYLES: Dictionary[String, int] = {
	"impactLight": 0, "impactMedium": 1, "impactHeavy": 2, "impactSoft": 3, "impactRigid": 4,
}

## Master switch (settings toggle; the data's global.settingKey names the save key).
var enabled: bool = true
## Periodic THERMAL log lines (on by default on mobile only).
var thermal_log_enabled: bool = OS.has_feature("mobile")
## Injectable for tests: called as vibrate_fn.call(duration_ms: int, amplitude: float).
var vibrate_fn: Callable = Input.vibrate_handheld
## Save/settings key from the data (global.settingKey), for the settings screen.
var setting_key: String = "haptics"

var _backend: Backend = Backend.NONE
var _native: RefCounted = null
var _events: Dictionary = {}
var _max_per_second: int = 12
var _recent_ms: PackedInt64Array = PackedInt64Array()
var _last_ms: Dictionary[String, int] = {}
var _event_recent_ms: Dictionary[String, PackedInt64Array] = {}
var _registered: Dictionary[String, bool] = {}
var _warned: Dictionary[String, bool] = {}
var _played: int = 0
var _dropped: int = 0
var _thermal_state: String = ""
var _thermal_changes: int = -1
var _next_thermal_poll_ms: int = 0
var _next_thermal_log_ms: int = 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	load_data(DATA_PATH)
	select_backend()


func _exit_tree() -> void:
	if _native != null:
		_native.call(&"stop")
	_native = null


func _process(_delta: float) -> void:
	if _backend != Backend.IOS or not thermal_log_enabled:
		return
	var now: int = Time.get_ticks_msec()
	if now < _next_thermal_poll_ms:
		return
	_next_thermal_poll_ms = now + THERMAL_POLL_MS
	var changes: int = int(_native.call(&"thermal_change_count"))
	if changes != _thermal_changes or now >= _next_thermal_log_ms:
		_thermal_changes = changes
		_next_thermal_log_ms = now + THERMAL_LOG_INTERVAL_MS
		_log_thermal()


## Loads (or reloads) the haptic map. A missing file leaves the map empty: haptic() becomes a no-op.
func load_data(path: String) -> bool:
	_events = {}
	_registered.clear()
	if not FileAccess.file_exists(path):
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		push_warning("Haptics: %s is not a JSON object" % path)
		return false
	var data: Dictionary = parsed
	var events: Variant = data.get("events", {})
	if events is Dictionary:
		_events = events
	var global: Variant = data.get("global", {})
	if global is Dictionary:
		var g: Dictionary = global
		_max_per_second = int(_num(g.get("maxPerSecond"), 12.0))
		setting_key = str(g.get("settingKey", setting_key))
	if _backend == Backend.IOS:
		_register_patterns()
	return true


## Picks the backend (see class doc). Called from _ready; tests may call it again after changing state.
func select_backend() -> void:
	_native = null
	_backend = Backend.NONE
	if ClassDB.class_exists(NATIVE_CLASS) and ClassDB.can_instantiate(NATIVE_CLASS):
		_native = ClassDB.instantiate(NATIVE_CLASS) as RefCounted
	if _native != null:
		_backend = Backend.IOS
		_native.call(&"start")
		_register_patterns()
		_native.call(&"prepare")
		_thermal_changes = -1
		_next_thermal_poll_ms = 0
	elif OS.has_feature("mobile"):
		_backend = Backend.VIBRATE


## Plays the haptic mapped to `event` (a key of data/haptics.json "events"). `step` >= 0 plays only that
## entry of the pattern (for beats driven by gameplay, e.g. releaseWave). Returns true when something played.
func haptic(event: String, step: int = -1) -> bool:
	if not enabled or _backend == Backend.NONE:
		return false
	var spec_v: Variant = _events.get(event)
	if not spec_v is Dictionary:
		if not _warned.has(event):
			_warned[event] = true
			push_warning("Haptics: unknown event '%s' (add it to native/data/src/haptics.json)" % event)
		return false
	var spec: Dictionary = spec_v
	if not _admit(event, spec, Time.get_ticks_msec()):
		_dropped += 1
		return false
	var played: bool = _play_ios(event, spec, step) if _backend == Backend.IOS else _play_vibrate(spec, step)
	if played:
		_played += 1
	return played


## Warms the UIKit feedback generators (call at phase start, NATIVE_PORT 2).
func prepare() -> void:
	if _native != null:
		_native.call(&"prepare")


## "nominal" | "fair" | "serious" | "critical" on iOS, "unknown" elsewhere.
func thermal_state() -> String:
	if _native != null:
		return str(_native.call(&"thermal_state"))
	return "unknown"


func is_low_power_mode() -> bool:
	return _native != null and bool(_native.call(&"is_low_power_mode"))


## "ios:corehaptics" | "ios:null" (host build) | "vibrate" | "none".
func backend_name() -> String:
	match _backend:
		Backend.IOS:
			return "ios:%s" % str(_native.call(&"backend_name"))
		Backend.VIBRATE:
			return "vibrate"
	return "none"


func stats() -> Dictionary:
	return {
		"backend": backend_name(),
		"played": _played,
		"dropped": _dropped,
		"registered": _registered.size(),
		"events": _events.size(),
	}


## Native module state as JSON (empty when the module is absent). For the debug panel and tests.
func native_debug_state() -> String:
	return str(_native.call(&"debug_state")) if _native != null else ""


## Event names in the loaded map (sorted), for the T0 event-contract test.
func event_names() -> PackedStringArray:
	var names: PackedStringArray = PackedStringArray(_events.keys())
	names.sort()
	return names


## AHAP dictionary (Apple Haptic and Audio Pattern) for the transient/continuous entries of one event.
## Entries with t = null follow the previous entry by DEFAULT_STEP_S; continuous "decayTo" becomes a
## HapticIntensityControl curve from 1.0 to decayTo / intensity; null sharpness inherits the previous entry's.
static func build_ahap(entries: Array) -> Dictionary:
	var pattern: Array[Dictionary] = []
	var t_prev: float = -DEFAULT_STEP_S
	var sharp_prev: float = DEFAULT_SHARPNESS
	for entry_v: Variant in entries:
		if not entry_v is Dictionary:
			continue
		var entry: Dictionary = entry_v
		var type: String = str(entry.get("type", ""))
		if type != "transient" and type != "continuous":
			continue
		var t: float = _num(entry.get("t"), t_prev + DEFAULT_STEP_S)
		var intensity: float = clampf(_num(entry.get("intensity"), 1.0), 0.0, 1.0)
		var sharpness: float = clampf(_num(entry.get("sharpness"), sharp_prev), 0.0, 1.0)
		var params: Array[Dictionary] = [
			{"ParameterID": "HapticIntensity", "ParameterValue": intensity},
			{"ParameterID": "HapticSharpness", "ParameterValue": sharpness},
		]
		if type == "transient":
			pattern.append({"Event": {"Time": t, "EventType": "HapticTransient", "EventParameters": params}})
		else:
			var duration: float = maxf(_num(entry.get("dur"), 0.1), 0.001)
			pattern.append({"Event": {
				"Time": t, "EventType": "HapticContinuous", "EventDuration": duration, "EventParameters": params,
			}})
			var decay_to: Variant = entry.get("decayTo")
			if decay_to is float or decay_to is int:
				var end_scale: float = clampf(float(decay_to) / maxf(intensity, 0.001), 0.0, 1.0)
				pattern.append({"ParameterCurve": {
					"ParameterID": "HapticIntensityControl", "Time": t,
					"ParameterCurveControlPoints": [
						{"Time": 0.0, "ParameterValue": 1.0},
						{"Time": duration, "ParameterValue": end_scale},
					],
				}})
		t_prev = t
		sharp_prev = sharpness
	return {"Version": 1.0, "Pattern": pattern}


static func _num(value: Variant, fallback: float) -> float:
	if value is float or value is int:
		return float(value)
	return fallback


func _admit(event: String, spec: Dictionary, now: int) -> bool:
	var min_gap: int = int(_num(spec.get("minIntervalMs"), 0.0))
	if min_gap > 0 and _last_ms.has(event) and now - _last_ms[event] < min_gap:
		return false
	var per_event: int = int(_num(spec.get("maxPerSecond"), 0.0))
	var mine: PackedInt64Array = PackedInt64Array()
	if per_event > 0:
		mine = _prune(_event_recent_ms.get(event, PackedInt64Array()), now)
		if mine.size() >= per_event:
			_event_recent_ms[event] = mine
			return false
	_recent_ms = _prune(_recent_ms, now)
	if _max_per_second > 0 and _recent_ms.size() >= _max_per_second:
		return false
	_recent_ms.append(now)
	_last_ms[event] = now
	if per_event > 0:
		mine.append(now)
		_event_recent_ms[event] = mine
	return true


static func _prune(stamps: PackedInt64Array, now: int) -> PackedInt64Array:
	var kept: PackedInt64Array = PackedInt64Array()
	for s: int in stamps:
		if now - s < 1000:
			kept.append(s)
	return kept


func _register_patterns() -> void:
	_registered.clear()
	if _native == null:
		return
	for name_v: Variant in _events.keys():
		var event: String = str(name_v)
		var spec_v: Variant = _events[name_v]
		if not spec_v is Dictionary:
			continue
		var entries: Variant = (spec_v as Dictionary).get("ios", [])
		if not entries is Array:
			continue
		var ahap: Dictionary = build_ahap(entries)
		if (ahap["Pattern"] as Array).is_empty():
			continue  # generator-only events (selection / impact*) are played directly
		if bool(_native.call(&"register_pattern", event, JSON.stringify(ahap))):
			_registered[event] = true
		else:
			push_warning("Haptics: IOSHaptics rejected the AHAP pattern for '%s'" % event)


func _play_ios(event: String, spec: Dictionary, step: int) -> bool:
	var entries_v: Variant = spec.get("ios", [])
	if not entries_v is Array:
		return false
	var entries: Array = entries_v
	if step >= 0:
		return step < entries.size() and _play_ios_entry(entries[step])
	var played: bool = false
	if _registered.has(event):
		played = bool(_native.call(&"play_registered", event))
	for entry_v: Variant in entries:
		if entry_v is Dictionary and _is_generator(entry_v as Dictionary):
			played = _play_ios_entry(entry_v) or played
	return played


static func _is_generator(entry: Dictionary) -> bool:
	var type: String = str(entry.get("type", ""))
	return type == "selection" or IMPACT_STYLES.has(type)


func _play_ios_entry(entry_v: Variant) -> bool:
	if not entry_v is Dictionary:
		return false
	var entry: Dictionary = entry_v
	var type: String = str(entry.get("type", ""))
	var intensity: float = _num(entry.get("intensity"), 1.0)
	var sharpness: float = _num(entry.get("sharpness"), DEFAULT_SHARPNESS)
	match type:
		"transient":
			return bool(_native.call(&"transient", intensity, sharpness))
		"continuous":
			if entry.get("decayTo") != null:
				return bool(_native.call(&"play_pattern", JSON.stringify(build_ahap([entry]))))
			return bool(_native.call(&"continuous", intensity, sharpness, _num(entry.get("dur"), 0.1)))
		"selection":
			_native.call(&"selection")
			return true
	if IMPACT_STYLES.has(type):
		_native.call(&"impact", IMPACT_STYLES[type], intensity)
		return true
	return false


func _play_vibrate(spec: Dictionary, step: int) -> bool:
	var entries_v: Variant = spec.get("android", [])
	if not entries_v is Array or (entries_v as Array).is_empty():
		return false
	var entries: Array = entries_v
	if step >= 0:
		if step >= entries.size():
			return false
		entries = [entries[step]]
	var t_prev: float = -DEFAULT_STEP_S
	for entry_v: Variant in entries:
		if not entry_v is Dictionary:
			continue
		var entry: Dictionary = entry_v
		var t: float = 0.0 if step >= 0 else _num(entry.get("t"), t_prev + DEFAULT_STEP_S)
		var ms: int = int(_num(entry.get("ms"), DEFAULT_VIBRATE_MS))
		var amplitude: float = _num(entry.get("amp"), -1.0)  # -1 = device default amplitude
		if t <= 0.0 or not is_inside_tree():
			vibrate_fn.call(ms, amplitude)
		else:
			get_tree().create_timer(t, true, false, true).timeout.connect(vibrate_fn.bind(ms, amplitude))
		t_prev = t
	return true


func _log_thermal() -> void:
	var state: String = thermal_state()
	if state != _thermal_state and not _thermal_state.is_empty():
		print("THERMAL change %s -> %s" % [_thermal_state, state])
	_thermal_state = state
	print("THERMAL t=%.1f state=%s low_power=%s fps=%d" % [
		Time.get_ticks_msec() / 1000.0, state, str(is_low_power_mode()), Engine.get_frames_per_second(),
	])
