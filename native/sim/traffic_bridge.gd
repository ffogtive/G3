class_name TrafficBridge
extends RefCounted
## Sim-side handle on traffic (NATIVE_PORT 3-2): wraps the C++ `Traffic` class from res://ext/traffic.gdextension
## when ClassDB has it, else runs a small GDScript "creep" model (per-lane follow-the-leader, no pairwise
## IDM, fine for <= 160 cars) so the game always runs, e.g. on a Mac build whose ext failed to link.
##
## 가설: ✅ the view only needs [id, kind, lane, x, s, yaw, v, lamp_bits] per car per frame, so both backends
##       can sit behind one buffer contract; ❓ the creep model is good enough to look like a jam.
##
## The C++ class is only reached through ClassDB/Object.call, never by name, so this file parses without the ext.
##
## Fixed interface (sim <-> view):
##   setup(stage, cfg, seed); step(dt, player_state); count(); read_into(buf[, alpha]); events();
##   honk(player_lane, player_s); request_lane(player_lane, target_lane, player_s); kind_names()
## Buffer records (STRIDE 8): NPC cars first (count_npc()), then the opposite carriageway (lane = -1 - j,
## yaw = PI, id = OPP_ID_BASE + k). kind = index into kind_names(); per-record variant/colour: car_specs().
## player_state: {lane: float, s: float, v: float, x: float} (+ optional len, w, mode: String, time: float).

const STRIDE: int = 8
const OPP_ID_BASE: int = 100000
const LAMP_BRAKE: int = 1
const LAMP_BLINK_LEFT: int = 2
const LAMP_BLINK_RIGHT: int = 4
const LAMP_HIGHBEAM: int = 8
const LAMP_HAZARD: int = 16
const LAMP_HEADLIGHTS: int = 32
const LAMP_VILLAIN: int = 64
const LAMP_MINI: int = 128
const NATIVE_CLASS: StringName = &"Traffic"
const GDEXT_PATH: String = "res://ext/traffic.gdextension"
const _DB := preload("res://core/db.gd")

var _core: Object = null  # C++ Traffic, or null when the fallback runs
var _creep: _Creep = null
var _tables: Dictionary = {}
var _stage: Dictionary = {}
var _setup_info: Dictionary = {}
var _time: float = 0.0
var _phase: String = "jam"
var _allow_events: bool = true
var _jam_like: bool = true
var _focus_s: float = NAN
var _villains_external: bool = false
var _villains: Array[Dictionary] = []
var _events: Array[Dictionary] = []
var _player: Dictionary = {"lane": 3.0, "s": 0.0, "v": 0.0, "x": 5.4, "len": 4.2, "w": 1.92, "mode": "jam"}
var _kind_names: PackedStringArray = []
var _specs: Array[Dictionary] = []


static var _load_tried: bool = false


## True when the C++ ext is registered. Tries GDExtensionManager.load_extension at most once per process (a fresh
## .godot/ has not registered it yet); a failed load prints its errors once, then one INFO line, never again.
static func native_available() -> bool:
	if ClassDB.class_exists(NATIVE_CLASS):
		return true
	if not _load_tried:
		_load_tried = true
		if FileAccess.file_exists(GDEXT_PATH) and not GDExtensionManager.is_extension_loaded(GDEXT_PATH):
			GDExtensionManager.load_extension(GDEXT_PATH)
		if not ClassDB.class_exists(NATIVE_CLASS):
			print("INFO traffic: C++ extension unavailable -> GDScript fallback")
	return ClassDB.class_exists(NATIVE_CLASS)


## Main.js setupStage geometry + boss.js villain records for a stage (pure data, no ext needed).
## Returns {start_s, start_lane, front_s, jam_len, no_shoulder, villains: [{s, baseS, x, w, len, v, vNominal, kind, lane}]}.
static func stage_setup(stage: Dictionary, tables: Dictionary) -> Dictionary:
	var config: Dictionary = tables.get("config", {})
	var setup: Dictionary = config.get("setup", {})
	var approach: Dictionary = (tables.get("approach", {}) as Dictionary).get("default", {}).duplicate()
	var st_appr: Variant = stage.get("approach")
	if st_appr is Dictionary:
		for k: Variant in (st_appr as Dictionary).keys():
			if (st_appr as Dictionary)[k] != null:
				approach[k] = (st_appr as Dictionary)[k]
	var start_s: float = float(setup.get("startS", 0.0))
	var modes: Array = setup.get("noShoulderModes", ["closed", "none"])
	var no_shoulder: bool = modes.has(approach.get("shoulder", "open"))
	var jam_len: float = float(stage.get("jamLength", 170.0))
	var start_lane: int = int(setup.get("startLane", 3))
	if no_shoulder:
		jam_len = minf(jam_len, float(approach.get("jamLength", setup.get("noShoulderJamLength", 85.0))))
		start_lane = int(approach.get("startLane", setup.get("noShoulderStartLane", 1)))
	var front_s: float = start_s + jam_len + float(setup.get("frontGap", 30.0))
	var jam_speed: float = float(stage.get("jamSpeed", 2.4))
	var kinds: Dictionary = (tables.get("vehicle_kinds", {}) as Dictionary).get("kinds", {})
	var villains: Array[Dictionary] = []
	for spec_v: Variant in stage.get("villains", []):
		var spec: Dictionary = spec_v
		var kind: String = str(spec.get("kind", "villainSedan"))
		var k: Dictionary = kinds.get(kind, {})
		var color: int = 0
		if spec.get("color") != null:
			color = int(spec["color"])
		elif k.get("defaultColor") != null:
			color = int(k["defaultColor"])
		var dims: Dictionary = TrafficBridge.kind_dims(k, -1, color, true)
		var lane: float = float(spec.get("lane", 0))
		var v: float = 0.0 if spec.get("stopped") == true else jam_speed
		villains.append({
			"s": front_s, "baseS": front_s, "x": Cfg.lane_xf(lane),
			"w": float(dims.get("W", 2.0)), "len": float(dims.get("L", 4.8)),
			"v": v, "vNominal": v, "kind": kind, "lane": lane, "alive": true,
		})
	return {
		"start_s": start_s, "start_lane": start_lane, "front_s": front_s, "jam_len": jam_len,
		"no_shoulder": no_shoulder, "villains": villains, "approach": approach,
	}


## world.js: night = SKY[stage.sky].night (sky.json presets); tables may carry "sky", else res://data/sky.json.
static func is_night(stage: Dictionary, tables: Dictionary) -> bool:
	var sky: Variant = tables.get("sky")
	if not (sky is Dictionary):
		sky = _DB.load_json(_DB.DATA_DIR + "/sky.json")
	if not (sky is Dictionary):
		return false
	var preset: Variant = ((sky as Dictionary).get("presets", {}) as Dictionary).get(str(stage.get("sky", "day")))
	return preset is Dictionary and bool((preset as Dictionary).get("night", false))


## vehicle_kinds.json rule: variant = canon[seed % variants]; without a seed colorVariant ? color % variants : canon[0].
static func kind_dims(kind: Dictionary, seed: int, color: int, detailed: bool) -> Dictionary:
	var variants: int = maxi(1, int(kind.get("variants", 1)))
	var canon: Array = kind.get("canon", [0])
	var variant: int = 0
	if seed >= 0:
		variant = int(canon[seed % variants]) if canon.size() > 0 else 0
	elif bool(kind.get("colorVariant", false)):
		variant = color % variants
	else:
		variant = int(canon[0]) if canon.size() > 0 else 0
	var dims: Dictionary = kind.get("dims", {})
	var list: Array = dims.get("detailed" if detailed and dims.has("detailed") else "simple", [])
	var d: Dictionary = list[variant] if variant < list.size() else ({} if list.is_empty() else list[0])
	return {"L": float(d.get("L", 4.5)), "W": float(d.get("W", 1.9)), "H": float(d.get("H", 1.6)), "variant": variant}


## stage: a stages.json record. cfg: {config, vehicle_kinds, mini_types, approach} (DB.traffic_tables()),
## or just config.json (the other tables are then read from res://data). seed < 0 -> stage.id*1000+7.
## Pass force_fallback=true to run the GDScript model even when the ext is there (tests).
func setup(stage: Dictionary, cfg: Dictionary, seed: int = -1, force_fallback: bool = false) -> void:
	_tables = cfg if cfg.has("config") else _DB.load_traffic_tables()
	if not cfg.has("config") and not cfg.is_empty():
		_tables["config"] = cfg
	_stage = stage
	_setup_info = TrafficBridge.stage_setup(stage, _tables)
	_villains = (_setup_info["villains"] as Array[Dictionary]).duplicate(true)
	_villains_external = false
	_time = 0.0
	_events.clear()
	var lane0: int = int(_setup_info["start_lane"])
	_player = {"lane": float(lane0), "s": float(_setup_info["start_s"]), "v": 0.0, "x": Cfg.lane_x(lane0),
		"len": 4.2, "w": 1.92, "mode": "jam"}
	var use_seed: int = seed if seed >= 0 else Mulberry32.traffic_seed(int(stage.get("id", 1)))
	var night: bool = TrafficBridge.is_night(stage, _tables)
	if not force_fallback and TrafficBridge.native_available():
		_core = ClassDB.instantiate(NATIVE_CLASS)
		_creep = null
		_core.call(&"configure", _tables)
		_core.call(&"spawn_jam", stage, _villains, {"s": _player["s"], "lane": lane0, "len": 4.2, "w": 1.92}, use_seed, night)
		_kind_names = _core.call(&"kind_names")
	else:
		_core = null
		_creep = _Creep.new()
		_creep.spawn(stage, _tables, _setup_info, use_seed, night)
		_kind_names = _creep.kind_names
	_specs.clear()


## Fixed tick (Cfg.TICK). player_state: {lane, s, v, x} (+ len, w, mode, time).
func step(dt: float, player_state: Dictionary) -> void:
	for k: String in ["lane", "s", "v", "x", "len", "w", "mode"]:
		if player_state.has(k):
			_player[k] = player_state[k]
	_time = float(player_state.get("time", _time + dt))
	if not _villains_external:
		for v: Dictionary in _villains:
			if bool(v.get("alive", true)):
				v["s"] = float(v["s"]) + float(v["v"]) * dt
				v["baseS"] = float(v["baseS"]) + float(v["v"]) * dt
	var lane: int = roundi(float(_player["lane"]))
	if _core != null:
		_core.call(&"set_player", float(_player["s"]), float(_player["x"]), float(_player["v"]), lane, str(_player["mode"]) == "jam")
		_core.call(&"set_player_dims", float(_player["len"]), float(_player["w"]))
		_core.call(&"set_villain_count", _villains.size())
		for i: int in _villains.size():
			var v: Dictionary = _villains[i]
			_core.call(&"set_villain", i, float(v["s"]), float(v.get("baseS", v["s"])), float(v["x"]), float(v["w"]), float(v["len"]),
					float(v["v"]), float(v.get("vNominal", v["v"])), bool(v.get("alive", true)))
		_core.call(&"set_context", _phase, _allow_events, _jam_like, _focus_s)
		_core.call(&"update", dt, _time)
		for e: Dictionary in _core.call(&"take_events"):
			_events.append(e)
	else:
		_creep.step(dt, _time, _player, _villains, _phase)
		_events.append_array(_creep.take_events())


## Records written by read_into(): NPC cars + opposite carriageway.
func count() -> int:
	if _core != null:
		return int(_core.call(&"count")) + int(_core.call(&"opp_count"))
	return _creep.count() if _creep != null else 0


func count_npc() -> int:
	if _core != null:
		return int(_core.call(&"count"))
	return _creep.n if _creep != null else 0


## Fills buf (resized to count()*STRIDE): [id, kind_index, lane, x, s, yaw, v, lamp_bits].
## alpha = Engine.get_physics_interpolation_fraction() in _process (1.0 = latest tick).
func read_into(buf: PackedFloat32Array, alpha: float = 1.0) -> void:
	buf.clear()
	if _core != null:
		buf.append_array(_core.call(&"get_buffer", alpha, true))
	elif _creep != null:
		_creep.write(buf, alpha)


## MultiMesh-ready transforms (12 floats per instance, RenderingServer.multimesh_set_buffer layout) for the
## given record ids in that order. The view groups ids per (kind, variant) mesh once (car_specs()), then per
## frame: RenderingServer.multimesh_set_buffer(mm_rid, bridge.transforms_for(ids, alpha)).
func transforms_for(ids: PackedInt32Array, alpha: float = 1.0) -> PackedFloat32Array:
	if _core != null:
		return _core.call(&"get_transforms_for", ids, alpha)
	return _creep.transforms_for(ids, alpha) if _creep != null else PackedFloat32Array()


## Drains the events raised since the last call: {type, id, data}. Types: brake_wave, cutin, mini_act,
## released, auto_tow, honk_reply.
func events() -> Array[Dictionary]:
	var out: Array[Dictionary] = _events
	_events = []
	return out


## Player honk (traffic.js honk). Returns {kind, id}; kind "" = nobody reacted, else
## cheater | yield | letin | noway | villain | tired.
func honk(player_lane: int, player_s: float, siren: bool = false, trot: bool = false) -> Dictionary:
	_player["lane"] = float(player_lane)
	_player["s"] = player_s
	var r: Dictionary
	if _core != null:
		_core.call(&"set_player", player_s, float(_player["x"]), float(_player["v"]), player_lane, str(_player["mode"]) == "jam")
		r = _core.call(&"honk", siren, trot)
	else:
		r = _creep.honk(player_lane, player_s, float(_player["len"]))
	_events.append({"type": "honk_reply", "id": int(r.get("id", 0)), "data": str(r.get("kind", ""))})
	return r


## May the player start a lane change into target_lane now? (player.js:79 canMergeInto, previous tick's buckets)
func request_lane(player_lane: int, target_lane: int, player_s: float) -> bool:
	if target_lane < 0 or target_lane > Cfg.SHOULDER_LANE or absi(target_lane - player_lane) != 1:
		return false
	if _core != null:
		_core.call(&"set_player", player_s, float(_player["x"]), float(_player["v"]), player_lane, str(_player["mode"]) == "jam")
		return int(_core.call(&"can_merge_into", target_lane, 0.35)) == 0
	return _creep.lane_free(target_lane, player_s, float(_player["len"]))


func kind_names() -> PackedStringArray:
	return _kind_names


# --- beyond the fixed interface -------------------------------------------------------------------

func is_native() -> bool:
	return _core != null


## The C++ Traffic object (null on the fallback) for golden tests and later M1b wiring.
func native() -> Object:
	return _core


func setup_info() -> Dictionary:
	return _setup_info


## main.js passes phase / allowEvents (= phase=='jam') / jamLike / focusS every tick.
func set_phase(phase: String, allow_events: bool, jam_like: bool, focus_s: float = NAN) -> void:
	_phase = phase
	_allow_events = allow_events
	_jam_like = jam_like
	_focus_s = focus_s


## Hand villain motion to the boss sim: [{s, baseS, x, w, len, v, vNominal, alive}] each tick.
func set_villains(villains: Array[Dictionary]) -> void:
	_villains_external = true
	_villains = villains


func villains() -> Array[Dictionary]:
	return _villains


func release(time: float, open_lane: int = 0) -> void:
	if _core != null:
		_core.call(&"release", time, -1.0, open_lane)
	elif _creep != null:
		_creep.release()


## Static appearance per record (same order as read_into): {id, kind, kind_name, variant, color, len, w}.
func car_specs() -> Array[Dictionary]:
	if not _specs.is_empty():
		return _specs
	if _core != null:
		for d: Dictionary in _core.call(&"get_car_specs"):
			_specs.append({"id": d["id"], "kind": d["kind"], "kind_name": d["kind_name"], "variant": d["variant"],
				"color": d["color"], "len": d["len"], "w": d["w"]})
		var k: int = 0
		for o: Dictionary in _core.call(&"get_opp"):
			var name: String = str(o["kind"])
			_specs.append({"id": OPP_ID_BASE + k, "kind": _kind_names.find(name), "kind_name": name,
				"variant": o["variant"], "color": o["color"], "len": 0.0, "w": 0.0})
			k += 1
	elif _creep != null:
		_specs = _creep.specs()
	return _specs


## Shoulder obstacles for the view: [{id, kind, s, x, len, w, smash, hazard, detail}].
func obstacles() -> Array:
	if _core != null:
		return _core.call(&"get_obstacles")
	return _creep.obstacles if _creep != null else []


# ================================================================================================
# GDScript fallback: per-lane follow-the-leader "creep". Same spawn shape as traffic.js (walls at the
# front row, jam lanes packed back to the tail, a hole at the player start, shoulder obstacles, 26
# opposite cars) but not the same RNG stream, and no pairwise IDM, cheaters, minis or stuck assist.
class _Creep:
	extends RefCounted

	const T_HEAD: float = 0.5
	const S0: float = 1.4
	const A_MAX: float = 1.8
	const A_MIN: float = -9.0

	var n: int = 0
	var kind_names: PackedStringArray = []
	var obstacles: Array = []
	var ids: PackedInt32Array = []
	var kind: PackedInt32Array = []
	var variant: PackedInt32Array = []
	var color: PackedInt64Array = []
	var lane: PackedInt32Array = []
	var lane_from: PackedInt32Array = []
	var s: PackedFloat64Array = []
	var x: PackedFloat64Array = []
	var v: PackedFloat64Array = []
	var ln: PackedFloat64Array = []
	var wd: PackedFloat64Array = []
	var personal: PackedFloat64Array = []
	var wall_off: PackedFloat64Array = []  # NAN = not a wall
	var lc_t: PackedFloat64Array = []
	var lamp: PackedInt32Array = []
	var prev_s: PackedFloat64Array = []
	var prev_x: PackedFloat64Array = []
	var opp_j: PackedInt32Array = []
	var opp_kind: PackedInt32Array = []
	var opp_s: PackedFloat64Array = []
	var opp_v: PackedFloat64Array = []
	var opp_prev: PackedFloat64Array = []
	var jam_speed: float = 2.4
	var front_line: float = 200.0
	var villain_lanes: Array[bool] = [false, false, false, false]
	var released: bool = false
	var night: bool = false
	var t: float = 0.0
	var _rng: Mulberry32 = null
	var _order: Array[PackedInt32Array] = []
	var _order_dirty: bool = true
	var _events: Array[Dictionary] = []
	var _kinds_tbl: Dictionary = {}

	func spawn(stage: Dictionary, tables: Dictionary, info: Dictionary, seed: int, p_night: bool) -> void:
		_rng = Mulberry32.new(seed)
		night = p_night
		var config: Dictionary = tables.get("config", {})
		_kinds_tbl = (tables.get("vehicle_kinds", {}) as Dictionary).get("kinds", {})
		kind_names = PackedStringArray(_kinds_tbl.keys())
		var npc: Dictionary = config.get("npc", {})
		var weights: Array = npc.get("kinds", [["sedan", 1]])
		var mono: Array = npc.get("colorsMono", [0xf4f4f2])
		jam_speed = float(stage.get("jamSpeed", 2.4))
		var density: float = float(stage.get("density", 1.0)) if stage.get("density") != null else 1.0
		var start_s: float = float(info["start_s"])
		var start_lane: int = int(info["start_lane"])
		front_line = float(info["front_s"])
		var villains: Array = info["villains"]
		var front_rear: Array[float] = [INF, INF, INF, INF]
		for vv: Variant in villains:
			var vd: Dictionary = vv
			for l: int in 4:
				if absf(float(vd["x"]) - Cfg.lane_x(l)) < float(vd["w"]) / 2.0 + 1.2:
					villain_lanes[l] = true
					front_rear[l] = minf(front_rear[l], float(vd["s"]) - float(vd["len"]) / 2.0)
		var fr: Variant = stage.get("frontRow")
		var front_row: Array = fr if fr is Array else [null, "truck", "truck", "truck"]
		for l: int in 4:
			if villain_lanes[l] or front_row[l] == null:
				continue
			var off: float = (_rng.next_float() - 0.5) * 1.2
			var i: int = _add(str(front_row[l]), l, front_line + off, jam_speed, mono)
			wall_off[i] = off
			front_rear[l] = s[i] - ln[i] / 2.0
		for l: int in 4:
			if not is_finite(front_rear[l]):
				front_rear[l] = front_line - 3.0
		var tail: float = start_s - 45.0
		for l: int in 4:
			var cursor: float = front_rear[l] - (2.2 + _rng.next_float() * 1.6)
			while cursor > tail:
				var i: int = _add(_pick(weights), l, 0.0, jam_speed * 0.7, mono)
				var sc: float = cursor - ln[i] / 2.0
				if l == start_lane and sc + ln[i] / 2.0 > start_s - 3.4 and sc - ln[i] / 2.0 < start_s + 3.4:
					sc = start_s - 3.4 - ln[i] / 2.0 - 2.0
				s[i] = sc
				prev_s[i] = sc
				cursor = sc - ln[i] / 2.0 - (1.5 + _rng.next_float() * 1.7) / density
		# shoulder obstacles: breakdown + cones spread like traffic.js (no cheaters in the fallback)
		var appr: Dictionary = info.get("approach", {})
		if not (str(appr.get("shoulder", "open")) in ["closed", "none"]):
			var s0: float = start_s + 38.0
			var s1: float = front_line - 22.0
			var kinds_ob: Array[String] = ["breakdown", "cones"]
			for k: int in kinds_ob.size():
				var so: float = s0 + (s1 - s0) / kinds_ob.size() * (k + 0.5)
				var is_bd: bool = kinds_ob[k] == "breakdown"
				obstacles.append({"id": 10000 + k, "kind": kinds_ob[k], "s": so, "x": 8.9,
					"len": 8.0 if is_bd else 11.5, "w": 2.1 if is_bd else 2.4, "smash": not is_bd, "hazard": is_bd, "detail": {}})
		for k: int in 26:
			var j: int = int(floor(_rng.next_float() * 4.0))
			opp_j.append(j)
			opp_kind.append(kind_names.find(_pick(weights)))
			opp_s.append(start_s - 100.0 + _rng.next_float() * 520.0)
			opp_v.append(24.0 + _rng.next_float() * 12.0 - j * 2.0)
		opp_prev = opp_s.duplicate()
		_order_dirty = true

	func _pick(weights: Array) -> String:
		var total: float = 0.0
		for e: Variant in weights:
			total += float((e as Array)[1])
		var r: float = _rng.next_float() * total
		for e: Variant in weights:
			r -= float((e as Array)[1])
			if r <= 0.0:
				return str((e as Array)[0])
		return str((weights[0] as Array)[0])

	func _add(kind_name: String, l: int, sv: float, vv: float, palette: Array) -> int:
		var k: Dictionary = _kinds_tbl.get(kind_name, {})
		var seed: int = int(floor(_rng.next_float() * 1e6))
		var d: Dictionary = TrafficBridge.kind_dims(k, seed, 0, false)
		var i: int = n
		n += 1
		ids.append(i + 1)
		kind.append(kind_names.find(kind_name))
		variant.append(int(d["variant"]))
		color.append(int(palette[int(floor(_rng.next_float() * palette.size()))]))
		lane.append(l)
		lane_from.append(l)
		s.append(sv)
		x.append(Cfg.lane_x(l))
		v.append(vv)
		ln.append(float(d["L"]))
		wd.append(float(d["W"]))
		personal.append(0.97 + _rng.next_float() * 0.06)
		wall_off.append(NAN)
		lc_t.append(1.0)
		lamp.append(LAMP_BRAKE)
		prev_s.append(sv)
		prev_x.append(x[i])
		return i

	func count() -> int:
		return n + opp_s.size()

	func _rebuild_order() -> void:
		_order.clear()
		for l: int in 5:
			var idx: Array[int] = []
			for i: int in n:
				if lane[i] == l:
					idx.append(i)
			idx.sort_custom(func(a: int, b: int) -> bool: return s[a] > s[b])
			_order.append(PackedInt32Array(idx))
		_order_dirty = false

	func step(dt: float, time: float, player: Dictionary, villains: Array[Dictionary], _phase: String) -> void:
		t = time
		if _order_dirty:
			_rebuild_order()
		for vd: Dictionary in villains:
			if bool(vd.get("alive", true)):
				front_line = float(vd.get("baseS", vd["s"]))
				break
		var p_s: float = float(player["s"])
		var p_lane: int = roundi(float(player["lane"]))
		var p_len: float = float(player.get("len", 4.2))
		for i: int in n:
			prev_s[i] = s[i]
			prev_x[i] = x[i]
		var sin_t: Array[float] = []
		for l: int in 5:
			sin_t.append(0.35 + 0.65 * (0.5 + 0.5 * sin(t * 0.42 + l * 1.9)))
		for l: int in 5:
			var lead_rear: float = INF
			var lead_v: float = 0.0
			if l < 4 and not released:
				lead_rear = front_line - 3.0
				lead_v = jam_speed
			var order: PackedInt32Array = _order[l]
			for k: int in order.size():
				var i: int = order[k]
				var rear_i: float = s[i] - ln[i] / 2.0
				var front_i: float = s[i] + ln[i] / 2.0
				var gap: float = lead_rear - front_i
				if l == p_lane and p_s - p_len / 2.0 > front_i - 0.01 and p_s - p_len / 2.0 < lead_rear:
					gap = p_s - p_len / 2.0 - front_i
				var target: float
				if released:
					target = 25.0
				elif not is_nan(wall_off[i]):
					target = maxf(0.0, jam_speed + (front_line + wall_off[i] - s[i]) * 0.9)
					gap = INF
				else:
					target = jam_speed * personal[i] * sin_t[l] * 1.25
				var cap: float = maxf(0.0, (gap - S0) / T_HEAD)
				var want: float = minf(target, cap)
				var dv: float = clampf(want - v[i], A_MIN * dt, (4.6 if released else A_MAX) * dt)
				v[i] = maxf(0.0, v[i] + dv)
				s[i] += v[i] * dt
				if lc_t[i] < 1.0:
					lc_t[i] = minf(1.0, lc_t[i] + dt / 0.85)
					var e: float = lc_t[i] * lc_t[i] * (3.0 - 2.0 * lc_t[i])
					x[i] = Cfg.lane_x(lane_from[i]) + (Cfg.lane_x(lane[i]) - Cfg.lane_x(lane_from[i])) * e
				var bits: int = LAMP_HEADLIGHTS if night else 0
				if not released and (dv < -0.25 * dt or v[i] < 1.6):
					bits |= LAMP_BRAKE
				if lc_t[i] < 1.0:
					bits |= LAMP_BLINK_LEFT if lane[i] < lane_from[i] else LAMP_BLINK_RIGHT
				lamp[i] = bits
				lead_rear = rear_i
				lead_v = v[i]
		var focus: float = p_s
		for k: int in opp_s.size():
			opp_prev[k] = opp_s[k]
			opp_s[k] -= opp_v[k] * dt
			if opp_s[k] < focus - 130.0:
				opp_s[k] = focus + 280.0 + _rng.next_float() * 160.0
				opp_prev[k] = opp_s[k]

	func release() -> void:
		released = true
		for i: int in n:
			_events.append({"type": "released", "id": ids[i], "data": ""})

	func honk(p_lane: int, p_s: float, p_len: float) -> Dictionary:
		if p_lane < 0 or p_lane > 4:
			return {"kind": "", "id": 0}
		if _order_dirty:
			_rebuild_order()
		var who: int = -1
		var best: float = INF
		for i: int in _order[p_lane]:
			var gap: float = (s[i] - ln[i] / 2.0) - (p_s + p_len / 2.0 - 0.5)
			if gap > 0.0 and gap < best:
				best = gap
				who = i
		if who < 0 or best > 16.0:
			return {"kind": "", "id": 0}
		if is_nan(wall_off[who]) and lc_t[who] >= 1.0 and p_lane < 4:
			for tl: int in [p_lane - 1, p_lane + 1]:
				if tl >= 0 and tl < 4 and lane_free(tl, s[who], ln[who] + 1.6):
					lane_from[who] = lane[who]
					lane[who] = tl
					lc_t[who] = 0.0
					_order_dirty = true
					return {"kind": "yield", "id": ids[who]}
		return {"kind": "noway", "id": ids[who]}

	func lane_free(l: int, p_s: float, p_len: float) -> bool:
		if _order_dirty:
			_rebuild_order()
		var lo: float = p_s - p_len / 2.0 - 0.35
		var hi: float = p_s + p_len / 2.0 + 0.35
		for i: int in _order[l]:
			if s[i] + ln[i] / 2.0 > lo and s[i] - ln[i] / 2.0 < hi:
				return false
		if l == 4:
			for o: Variant in obstacles:
				var od: Dictionary = o
				if float(od["s"]) + float(od["len"]) / 2.0 > lo and float(od["s"]) - float(od["len"]) / 2.0 < hi:
					return false
		return true

	func write(buf: PackedFloat32Array, alpha: float) -> void:
		buf.resize(count() * STRIDE)
		var a: float = clampf(alpha, 0.0, 1.0)
		for i: int in n:
			var o: int = i * STRIDE
			buf[o] = ids[i]
			buf[o + 1] = kind[i]
			buf[o + 2] = lane[i]
			buf[o + 3] = prev_x[i] + (x[i] - prev_x[i]) * a
			buf[o + 4] = prev_s[i] + (s[i] - prev_s[i]) * a
			buf[o + 5] = 0.0
			buf[o + 6] = v[i]
			buf[o + 7] = lamp[i]
		for k: int in opp_s.size():
			var o: int = (n + k) * STRIDE
			buf[o] = OPP_ID_BASE + k
			buf[o + 1] = opp_kind[k]
			buf[o + 2] = -1 - opp_j[k]
			buf[o + 3] = Cfg.OPP_LANE_X[opp_j[k]]
			buf[o + 4] = opp_prev[k] + (opp_s[k] - opp_prev[k]) * a
			buf[o + 5] = PI
			buf[o + 6] = opp_v[k]
			buf[o + 7] = LAMP_HEADLIGHTS if night else 0

	func transforms_for(want: PackedInt32Array, alpha: float) -> PackedFloat32Array:
		var a: float = clampf(alpha, 0.0, 1.0)
		var out := PackedFloat32Array()
		out.resize(want.size() * 12)
		for k: int in want.size():
			var id: int = want[k]
			var px: float = 0.0
			var ps: float = 0.0
			var yaw: float = 0.0
			var sc: float = 1.0
			if id >= OPP_ID_BASE and id - OPP_ID_BASE < opp_s.size():
				var j: int = id - OPP_ID_BASE
				px = Cfg.OPP_LANE_X[opp_j[j]]
				ps = opp_prev[j] + (opp_s[j] - opp_prev[j]) * a
				yaw = PI
			elif id >= 1 and id <= n:
				var i: int = id - 1
				px = prev_x[i] + (x[i] - prev_x[i]) * a
				ps = prev_s[i] + (s[i] - prev_s[i]) * a
			else:
				sc = 0.0
			var o: int = k * 12
			out[o] = cos(yaw) * sc
			out[o + 2] = sin(yaw) * sc
			out[o + 3] = px
			out[o + 5] = sc
			out[o + 8] = -sin(yaw) * sc
			out[o + 10] = cos(yaw) * sc
			out[o + 11] = -ps
		return out

	func specs() -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		for i: int in n:
			out.append({"id": ids[i], "kind": kind[i], "kind_name": kind_names[kind[i]] if kind[i] >= 0 else "",
				"variant": variant[i], "color": color[i], "len": ln[i], "w": wd[i]})
		for k: int in opp_s.size():
			out.append({"id": OPP_ID_BASE + k, "kind": opp_kind[k], "kind_name": kind_names[opp_kind[k]] if opp_kind[k] >= 0 else "",
				"variant": 0, "color": 0xf4f4f2, "len": 0.0, "w": 0.0})
		return out

	func take_events() -> Array[Dictionary]:
		var out: Array[Dictionary] = _events
		_events = []
		return out
