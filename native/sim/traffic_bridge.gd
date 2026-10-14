class_name TrafficBridge
extends RefCounted
## Sim-side handle on traffic (NATIVE_PORT 3-2): wraps the C++ `Traffic` class from res://ext/traffic.gdextension
## when ClassDB has it, else runs a GDScript port of the same rules (_Creep: per-lane leaders + the C++ IDM, spawn_jam
## ①-④, stuck assist, let-in, honk, cheaters, minis, jam shape) so the game always runs, e.g. on an iPhone / Mac build
## whose ext failed to link.
##
## 가설: ✅ the view only needs [id, kind, lane, x, s, yaw, v, lamp_bits] per car per frame, so both backends
##       can sit behind one buffer contract.
##       ✅ r3 T1/T2 (device feedback r3 #1 "안 비켜줘서 기다리기", #3 "매번 똑같음"): the old creep had no let-in, stuck
##       assist, auto tow, shoulder honk, stage shoulder modes, cheaters, minis or lane kinds, so on the device every
##       stage was the same 45-95 s wait and 1-5 never reached the villain. The fallback now follows the C++ rules
##       (spawn draw order kept; update RNG is its own stream, so C++ goldens are untouched).
##
## The C++ class is only reached through ClassDB/Object.call, never by name, so this file parses without the ext.
##
## Fixed interface (sim <-> view):
##   setup(stage, cfg, seed); step(dt, player_state); count(); read_into(buf[, alpha]); events();
##   honk(player_lane, player_s); request_lane(player_lane, target_lane, player_s); kind_names()
## Buffer records (STRIDE 8): NPC cars first (count_npc()), then the opposite carriageway (lane = -1 - j,
## yaw = PI, id = OPP_ID_BASE + k). kind = index into kind_names(); per-record variant/colour: car_specs().
## player_state: {lane: float, s: float, v: float, x: float} (+ optional len, w, mode: String, time: float).
## Extras (r3 T1, A2 neck plug): set_extras([{s, x, w, len, v, alive, kind}]) — extra bodies (ids -1000 - i) that are
## leaders / lane blockers for the player and the NPCs on both backends (type "extra"); honk at one → {kind: "extra"}.

const STRIDE: int = 8
const OPP_ID_BASE: int = 100000
const EXTRA_ID_BASE: int = -1000
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
var _extras: Array[Dictionary] = []
var _events: Array[Dictionary] = []
var _player: Dictionary = {"lane": 3.0, "s": 0.0, "v": 0.0, "x": 5.4, "len": 4.2, "w": 1.92, "mode": "jam"}
var _kind_names: PackedStringArray = []
var _specs: Array[Dictionary] = []
var _tick: int = 0
var _state_tick: int = -1
var _state_cache: Dictionary = {}
var _obstacle_smash: Dictionary = {}  # obstacle id -> smash (cones / debris fly away)
var _honk_villain_range: float = 30.0
var _honk_probe_back: float = 0.5


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
		variant = int(canon[(seed % variants) % canon.size()]) if canon.size() > 0 else 0
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
	_extras = []
	_time = 0.0
	_events.clear()
	var hq: Dictionary = (((_tables.get("config", {}) as Dictionary).get("traffic", {}) as Dictionary).get("queries", {}) as Dictionary).get("honk", {})
	_honk_villain_range = float(hq.get("villainRange", 30.0))
	_honk_probe_back = float(hq.get("probeBack", 0.5))
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
	_obstacle_smash.clear()
	_state_tick = -1


## Fixed tick (Cfg.TICK). player_state: {lane, s, v, x} (+ len, w, mode, time).
func step(dt: float, player_state: Dictionary) -> void:
	_tick += 1
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
		_creep.step(dt, _time, _player, _villains, _phase, _allow_events, _jam_like, _focus_s)
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


## Drains the events raised since the last call: {type, id, data, value}. Types: brake_wave, cutin, mini_act,
## released, auto_tow, honk_reply.
func events() -> Array[Dictionary]:
	var out: Array[Dictionary] = _events
	_events = []
	return out


## Player honk (traffic.js honk). Returns {kind, id}; kind "" = nobody reacted, else
## cheater | yield | letin | noway | villain | tired | extra (the nearest body ahead is a set_extras() extra within the
## villain honk range: same answer on both backends, the extra never yields).
func honk(player_lane: int, player_s: float, siren: bool = false, trot: bool = false) -> Dictionary:
	_player["lane"] = float(player_lane)
	_player["s"] = player_s
	var r: Dictionary = _extra_honk(player_lane, player_s)
	if not r.is_empty():
		pass
	elif _core != null:
		_core.call(&"set_player", player_s, float(_player["x"]), float(_player["v"]), player_lane, str(_player["mode"]) == "jam")
		r = _core.call(&"honk", siren, trot)
	else:
		r = _creep.honk(_player, siren, trot)
	_events.append({"type": "honk_reply", "id": int(r.get("id", 0)), "data": str(r.get("kind", ""))})
	return r


func _extra_honk(player_lane: int, player_s: float) -> Dictionary:
	if _extras.is_empty():
		return {}
	var g: Dictionary = gap_ahead(player_lane, player_s + float(_player["len"]) / 2.0 - _honk_probe_back)
	if str(g.get("type", "")) == "extra" and float(g.get("gap", INF)) < _honk_villain_range:
		return {"kind": "extra", "id": int(g["id"])}
	return {}


## May the player start a lane change into target_lane now? (player.js:79 canMergeInto, previous tick's buckets)
func request_lane(player_lane: int, target_lane: int, player_s: float) -> bool:
	if target_lane < 0 or target_lane > Cfg.SHOULDER_LANE or absi(target_lane - player_lane) != 1:
		return false
	if _core != null:
		_core.call(&"set_player", player_s, float(_player["x"]), float(_player["v"]), player_lane, str(_player["mode"]) == "jam")
		return int(_core.call(&"can_merge_into", target_lane, 0.35)) == 0
	_player["lane"] = float(player_lane)
	_player["s"] = player_s
	return _creep.can_merge(target_lane, _player, 0.35) == 0


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
	if _creep != null:
		_creep.villains = villains  # leader / lane queries between steps see this tick's villains (fallback)


func villains() -> Array[Dictionary]:
	return _villains


## r3 T1 (A2 neck plug): extra bodies [{s, x, w, len, v, alive, kind}] (ids -1000 - i, type "extra") that block lanes
## by x occupancy like a villain: leaders for the player and the NPCs, gap_ahead / can_merge / lane_blocked / has_gap
## blockers, honk → {kind: "extra"}. Persist until the next call ([] clears); setup() clears them. Call it every tick
## before step() while they move. C++: set_extra_count / set_extra (queries see them from the next update on).
func set_extras(extras: Array) -> void:
	_extras = []
	for e: Variant in extras:
		if not (e is Dictionary):
			continue
		var d: Dictionary = e
		_extras.append({"s": float(d.get("s", 0.0)), "x": float(d.get("x", 0.0)), "w": float(d.get("w", 1.9)),
			"len": float(d.get("len", 4.5)), "v": float(d.get("v", 0.0)), "alive": bool(d.get("alive", true)),
			"kind": str(d.get("kind", ""))})
	if _core != null:
		_core.call(&"set_extra_count", _extras.size())
		for i: int in _extras.size():
			var x: Dictionary = _extras[i]
			_core.call(&"set_extra", i, float(x["s"]), float(x["x"]), float(x["w"]), float(x["len"]), float(x["v"]), bool(x["alive"]))
	elif _creep != null:
		_creep.extras = _extras


func extras() -> Array[Dictionary]:
	return _extras


func release(time: float, open_lane: int = 0) -> void:
	if _core != null:
		_core.call(&"release", time, -1.0, open_lane)
	elif _creep != null:
		_creep.release(time, open_lane)


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


# --- GameSim queries (M1b; res://sim/game_sim.gd). Same buckets as the last step(), like player.js. --------------

## Pushes the player record to the core without stepping (lane changes / leader queries between steps).
func sync_player(p: Dictionary) -> void:
	for k: String in ["lane", "s", "v", "x", "len", "w", "mode"]:
		if p.has(k):
			_player[k] = p[k]
	if _core != null:
		_core.call(&"set_player", float(_player["s"]), float(_player["x"]), float(_player["v"]), roundi(float(_player["lane"])),
				str(_player["mode"]) == "jam")
		_core.call(&"set_player_dims", float(_player["len"]), float(_player["w"]))


## {id, gap, type: car|obstacle|villain|extra|"", v, smash, lane}; gap = INF without a leader. Villain v is filled by GameSim.
func leader_of_player() -> Dictionary:
	var out: Dictionary = {"id": 0, "gap": INF, "type": "", "v": 0.0, "smash": false}
	if _core != null:
		var d: Dictionary = _core.call(&"leader_of_player")
		out["id"] = int(d.get("id", 0))
		out["gap"] = float(d.get("gap", INF))
		out["type"] = str(d.get("type", ""))
	elif _creep != null:
		out = _creep.leader(_player)
	if str(out["type"]) == "car":
		out["v"] = float(car_info(int(out["id"])).get("v", 0.0))
	elif str(out["type"]) == "obstacle":
		out["smash"] = bool(_obstacle_info().get(int(out["id"]), false))
	elif str(out["type"]) == "extra":
		var k: int = EXTRA_ID_BASE - int(out["id"])
		out["v"] = float((_extras[k] as Dictionary).get("v", 0.0)) if k >= 0 and k < _extras.size() else 0.0
	return out


## traffic.js gapAhead(lane, s, player): {gap, id, type} — the nearest body whose rear is ahead of s (player excluded).
func gap_ahead(lane: int, s: float) -> Dictionary:
	if _core != null:
		var d: Dictionary = _core.call(&"gap_ahead", lane, s)
		return {"gap": float(d.get("gap", INF)), "id": int(d.get("id", 0)), "type": str(d.get("type", ""))}
	if _creep != null:
		return _creep.gap_ahead(lane, s)
	return {"gap": INF, "id": 0, "type": ""}


## 0 = the player may merge into lane (traffic.js canMergeInto), else the blocker id (car / obstacle id, villain
## -100 - i, extra -1000 - i; -9999 = a C++ body without an id).
func can_merge(lane: int, margin: float = 0.35) -> int:
	if lane < 0 or lane > Cfg.SHOULDER_LANE:
		return -1
	if _core != null:
		return int(_core.call(&"can_merge_into", lane, margin))
	return 0 if _creep == null else _creep.can_merge(lane, _player, margin)


## traffic.js laneBlocked(lane, sMin, sMax, player) -> blocker id or 0.
func lane_blocked(lane: int, s_min: float, s_max: float) -> int:
	if _core != null:
		return int(_core.call(&"lane_blocked", lane, s_min, s_max, -1))
	return 0 if _creep == null else _creep.lane_blocked(lane, s_min, s_max, -1, null)


## The GDScript fallback backs NPC cars off the player when they end up inside it (a jam hop into a short slot), so
## GameSim.jam_hop may land in slots shorter than the car there (skills.items.mv_jump.jamMinSlot). The C++ IDM only
## stops them, so the native path keeps the strict slot (car + jamSlotPad).
func makes_room() -> bool:
	return _core == null and _creep != null


## {s, x, v, lane} of an NPC car by id (empty when unknown).
func car_info(id: int) -> Dictionary:
	if _core != null:
		if _state_tick != _tick:
			_state_cache = _core.call(&"get_state")
			_state_tick = _tick
		var ids: PackedInt32Array = _state_cache.get("ids", PackedInt32Array())
		var i: int = ids.find(id)
		if i < 0:
			return {}
		return {"s": (_state_cache["s"] as PackedFloat64Array)[i], "x": (_state_cache["x"] as PackedFloat64Array)[i],
			"v": (_state_cache["v"] as PackedFloat64Array)[i], "lane": (_state_cache["lane"] as PackedInt32Array)[i]}
	if _creep != null and id >= 1 and id <= _creep.n:
		var k: int = id - 1
		return {"s": _creep.s[k], "x": _creep.x[k], "v": _creep.v[k], "lane": _creep.lane[k]}
	return {}


## NPC ids in a lane with s in (s_min, s_max), sorted by s ascending (occupy relay: far to near).
func cars_in_lane(lane: int, s_min: float, s_max: float) -> PackedInt32Array:
	var pairs: Array = []
	if _core != null:
		car_info(0)  # refresh the per-tick cache
		var ids: PackedInt32Array = _state_cache.get("ids", PackedInt32Array())
		var ln: PackedInt32Array = _state_cache.get("lane", PackedInt32Array())
		var ss: PackedFloat64Array = _state_cache.get("s", PackedFloat64Array())
		for i: int in ids.size():
			if ln[i] == lane and ss[i] > s_min and ss[i] < s_max:
				pairs.append([ss[i], ids[i]])
	elif _creep != null:
		for i: int in _creep.n:
			if _creep.lane[i] == lane and _creep.s[i] > s_min and _creep.s[i] < s_max:
				pairs.append([_creep.s[i], _creep.ids[i]])
	pairs.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	var out := PackedInt32Array()
	for p: Array in pairs:
		out.append(int(p[1]))
	return out


## traffic.js rageHorn(player, range): {smashed, towed, cheaters, startled} id arrays (both backends: shoulder
## obstacles in [p.s - 2, p.s + range] smashed / towed (occupied shoulder), cheaters sent back to lane 3, startled cars).
func rage_horn(range_m: float) -> Dictionary:
	if _core != null:
		return _core.call(&"rage_horn", range_m)
	if _creep != null:
		var appr: Dictionary = _setup_info.get("approach", {}) if _setup_info.get("approach") is Dictionary else {}
		return _creep.rage_horn(_player, range_m, str(appr.get("shoulder", "open")) == "occupied")
	return {"smashed": PackedInt32Array(), "towed": PackedInt32Array(), "cheaters": PackedInt32Array(), "startled": PackedInt32Array()}


func smash(obstacle_id: int) -> bool:
	if _core != null:
		return bool(_core.call(&"smash", obstacle_id))
	return _creep != null and _creep.remove_obstacle(obstacle_id, true)


func remove_obstacle(obstacle_id: int) -> bool:
	if _core != null:
		return bool(_core.call(&"remove_obstacle", obstacle_id))
	return _creep != null and _creep.remove_obstacle(obstacle_id, false)


func jolt(id: int) -> void:
	if _core != null:
		_core.call(&"jolt", id)
	elif _creep != null:
		_creep.jolt(id)


## Nearest mini (lane 3 lamp LAMP_MINI) within [-3, 26] m and 1.2 lanes of the player (both backends).
func mini_target() -> int:
	if _core != null:
		return int(_core.call(&"mini_target"))
	return _creep.mini_target(_player) if _creep != null else 0


## "" (no effect) | "hit" | "down"
func mini_hit(car_id: int, dmg: float) -> String:
	if _core != null:
		return str(_core.call(&"mini_hit", car_id, dmg))
	return _creep.mini_hit(car_id, dmg) if _creep != null else ""


func drop_walls(lanes: PackedInt32Array, meters: float) -> void:
	if _core != null:
		_core.call(&"drop_walls", lanes, meters)
	elif _creep != null:
		_creep.drop_walls(lanes, meters)


## First n jam cars (spawn order; not walls / cheaters / released) within range m behind the front line (frontRage).
func cars_behind_front(n: int, range_m: float) -> PackedInt32Array:
	if _core != null:
		return _core.call(&"cars_behind_front", n, range_m)
	return _creep.cars_behind_front(n, range_m) if _creep != null else PackedInt32Array()


## {front_line, front_v, jam_speed, s_tail, released, released_count, zigzag, shoulder_closed, shoulder, gap_check,
## fatigue, rubber, rage_horn, night, assists, waves, time, lane_kind} (Traffic.get_info; the same keys on the fallback).
func info() -> Dictionary:
	if _core != null:
		return _core.call(&"get_info")
	if _creep != null:
		return _creep.info()
	return {"front_line": 0.0, "s_tail": float(_setup_info.get("start_s", 0.0)) - 45.0, "released": false, "released_count": 0,
		"shoulder_closed": bool(_setup_info.get("no_shoulder", false)), "assists": 0}


func _obstacle_info() -> Dictionary:
	if _obstacle_smash.is_empty():
		for o: Variant in obstacles():
			_obstacle_smash[int((o as Dictionary)["id"])] = bool((o as Dictionary).get("smash", false))
	return _obstacle_smash


# ================================================================================================
# GDScript fallback (_Creep): a port of traffic_core.cpp for builds without the ext (iPhone / Mac fallback).
# - spawn(): spawn_jam ①-④ in the C++ draw order (front-row walls, jamShape lane kinds + gaps, stage shoulder spec and
#   approach.shoulder modes with cheaters / blocked cones / dark & debris specs, minis on lane 3, opposite cars).
# - step(): random brakes, stuck assist (let-in / pull-ahead / auto tow), the shoulder cheater event, minis acting,
#   brake waves + yield sources, then per-lane leaders (cars, player, obstacles, villains, extras, the villain wall)
#   through the C++ IDM per lane kind, lane changes, release wave and post-release lane changes, lamps.
# - queries: honk (cheater / letin / noway / yield / tired / villain), can_merge (yield_until exception), gap_ahead,
#   lane_blocked, leader, rage_horn, mini_target / mini_hit, cars_behind_front, drop_walls.
# Same draw order and float expression order as the C++ (one Mulberry32 per stage, cars updated in spawn order, lane
# lists + x-occupancy bits taken at the step start like build_buckets), so with the same seed and inputs it follows the
# C++ run tick for tick through jam and fight (r3 measurement: 1-1 … 1-10 jam → boss identical); it is still not a
# golden (Godot JSON vs exact parser, release-phase edge cases). Kept on purpose: obstacle ids are 10000 + k (cars keep
# id = index + 1; the C++ shares one id space), and NPCs back off the player when they end up inside it
# (TrafficBridge.makes_room()).
class _Creep:
	extends RefCounted

	const LK_PACKED: int = 0
	const LK_TRAIN: int = 1
	const LK_FLOW: int = 2
	const LK_SPACED: int = 3
	const LK_PASS: int = 4
	const LK_NAMES: Array = ["packed", "train", "flow", "spaced", "pass"]
	const BK_KINDS: Array = ["sedan", "van", "pickup1t", "compact"]  # shoulder.js:49
	const BK_COLORS: Array = [0xf4f4f2, 0x9aa1a9, 0x2b2d31, 0x2a5db0]
	const T_CAR: int = -1
	const T_PLAYER: int = 0
	const T_OBSTACLE: int = 1
	const T_VILLAIN: int = 2
	const T_EXTRA: int = 3
	const TYPE_NAMES: Array = ["player", "obstacle", "villain", "extra"]
	const PLAYER_ID: int = -1

	# --- public state (TrafficBridge reads these) -----------------------------------------------------
	var n: int = 0
	var kind_names: PackedStringArray = []
	var obstacles: Array = []
	## Boss-sim villain records ({s, baseS, x, w, len, v, vNominal, alive}, TrafficBridge.set_villains / step): leaders and
	## lane blockers by x occupancy (device feedback 2026-10-14 #1: the player drove through the villain).
	var villains: Array[Dictionary] = []
	## TrafficBridge.set_extras() bodies ({s, x, w, len, v, alive, kind}; ids -1000 - i), handled like villains.
	var extras: Array[Dictionary] = []
	var released: bool = false
	var released_count: int = 0
	var assists: int = 0
	var night: bool = false
	var t: float = 0.0
	var front_line: float = 200.0
	var front_v: float = 2.4
	var jam_speed: float = 2.4
	var s_tail: float = -45.0
	var zigzag: bool = false
	var shoulder_mode: String = "open"
	var shoulder_closed: bool = false
	var gap_check: bool = true
	var fatigue: bool = true
	var rubber: float = 2.5
	var rubber_safety: float = 4.0
	var rage_horn_m: float = 24.0
	var lane_kind := PackedInt32Array([0, 0, 0, 0])

	# --- per car ------------------------------------------------------------------------------------
	var ids := PackedInt32Array()
	var kind := PackedInt32Array()
	var variant := PackedInt32Array()
	var color := PackedInt64Array()
	var lane := PackedInt32Array()
	var lane_from := PackedInt32Array()
	var lc_t := PackedFloat64Array()
	var lc_dur := PackedFloat64Array()
	var s := PackedFloat64Array()
	var x := PackedFloat64Array()
	var v := PackedFloat64Array()
	var ln := PackedFloat64Array()
	var wd := PackedFloat64Array()
	var personal := PackedFloat64Array()
	var phase := PackedFloat64Array()
	var brake_t := PackedFloat64Array()
	var pull_t := PackedFloat64Array()
	var boost := PackedByteArray()
	var hazard_until := PackedFloat64Array()
	var rel := PackedByteArray()
	var release_at := PackedFloat64Array()
	var v_free := PackedFloat64Array()
	var slow := PackedByteArray()
	var wall := PackedByteArray()
	var cheat := PackedByteArray()
	var next_lc_at := PackedFloat64Array()
	var jolt_t := PackedFloat64Array()
	var yaw := PackedFloat64Array()
	var wall_off := PackedFloat64Array()
	var wall_back := PackedFloat64Array()
	var cheater_v := PackedFloat64Array()
	var yield_until := PackedFloat64Array()
	var honk_n := PackedInt32Array()
	var honk_t := PackedFloat64Array()
	var yielded := PackedByteArray()
	var mini := PackedByteArray()
	var mini_type := PackedInt32Array()
	var mini_hp := PackedFloat64Array()
	var mini_cool := PackedFloat64Array()
	var mini_acted := PackedInt32Array()
	var mini_done := PackedByteArray()
	var blink := PackedInt32Array()
	var lamp := PackedInt32Array()
	var acc_l := PackedFloat64Array()  # last IDM acceleration (brake light)
	var prev_s := PackedFloat64Array()
	var prev_x := PackedFloat64Array()
	var prev_yaw := PackedFloat64Array()
	# opposite carriageway
	var opp_j := PackedInt32Array()
	var opp_kind := PackedInt32Array()
	var opp_variant := PackedInt32Array()
	var opp_color := PackedInt64Array()
	var opp_s := PackedFloat64Array()
	var opp_v := PackedFloat64Array()
	var opp_prev := PackedFloat64Array()

	# --- internals ------------------------------------------------------------------------------------
	var _rng: Mulberry32 = null
	var _order: Array[PackedInt32Array] = []  # per lane: cars whose lane == l, s descending
	var _occ: Array[PackedInt32Array] = []  # per lane: _order + lane changers still leaving l, s descending
	var _order_dirty: bool = true
	var _in_step: bool = false
	var _stepped: bool = false  # lamp bits come from step state once a step ran (spawn: brake on, like the C++)
	var _home := PackedInt32Array()  # lane[i] at the last rebuild (the list a car is moved in)
	var _pos := PackedInt32Array()  # index of car i in _occ[_home[i]]
	var _om := PackedInt32Array()  # per car: bit l set = occupies lane l by x at the last step start (C++ bucket)
	var _moved_x := PackedInt32Array()  # cars that moved sideways in the last step (mask refresh at the next start)
	var _events: Array[Dictionary] = []
	var _kinds_tbl: Dictionary = {}
	var _minis := PackedInt32Array()
	var _mini_names: PackedStringArray = []
	var _stuck_n: Dictionary = {}
	## Obstacles removed since the last step start: the C++ buckets keep them until the next update (traffic_core.h:
	## "obstacles removed between rebuilds stay in the buckets"), so queries / leaders still see them for one tick.
	var _ghost_ob: Array = []
	var _p: Dictionary = {"lane": 3.0, "s": 0.0, "v": 0.0, "x": 5.4, "len": 4.2, "w": 1.92, "mode": "jam"}
	var _stuck_t: float = 0.0
	var _stuck_for: float = 0.0
	var _has_next_cheater: bool = false
	var _next_cheater: float = 0.0
	var _waves: Array[Dictionary] = []
	var _sources: Array[Dictionary] = []
	var _jam_src_t: float = 0.0
	var _pass_v: float = 2.2
	var _half_occ: float = 1.2

	# --- tunables (config.json traffic.* / tune.*; defaults = the C++ / JS literals) --------------------
	var _idm_b: float = 3.0
	var _acc_min: float = -9.0
	var _brake_v0: float = 0.01
	var _v_floor: float = 0.1
	var _gap_floor: float = 0.3
	var _stop_gap: float = 0.25
	var _lk_T := PackedFloat64Array([0.5, 0.45, 0.8, 1.6, 1.0])
	var _lk_s0 := PackedFloat64Array([1.4, 1.2, 2.2, 5.5, 3.0])
	var _lk_a := PackedFloat64Array([1.8, 1.6, 1.6, 1.4, 2.0])
	var _lk_mul := PackedFloat64Array([1.25, 1.0, 0.95, 1.05, 2.2])
	var _lf_base: float = 0.35
	var _lf_amp: float = 0.65
	var _lf_freq: float = 0.42
	var _lf_phase: float = 1.9
	var _rel_T: float = 0.5
	var _rel_s0: float = 2.0
	var _rel_a: float = 4.6
	var _rel_a_slow: float = 2.6
	var _wall_T: float = 0.5
	var _wall_s0: float = 1.5
	var _wall_a: float = 3.0
	var _wall_follow: float = 0.9
	var _ch_T: float = 0.6
	var _ch_s0: float = 2.0
	var _ch_a: float = 2.5
	var _ch_v0_fb: float = 5.0
	var _pull_T: float = 0.3
	var _pull_s0: float = 1.0
	var _pull_a: float = 3.6
	var _pull_mul: float = 2.2
	var _pull_mul_let_in: float = 3.6
	var _vw_back: float = 3.0
	var _vw_zig: float = 5.0
	var _brake_rate: float = 0.6
	var _brake_behind: float = 10.0
	var _brake_ahead: float = 80.0
	var _brake_hold_base: float = 0.6
	var _brake_hold_span: float = 0.7
	var _stuck_v_below: float = 2.5
	var _stuck_decay: float = 2.0
	var _stuck_pull_after: float = 1.0
	var _tow_ahead: float = 16.0
	var _tow_behind: float = 6.0
	var _auto_tow_after: int = 2
	var _ch_first_delay: float = 6.0
	var _ch_min_player_v: float = 8.0
	var _ch_next_base: float = 7.0
	var _ch_next_span: float = 5.0
	var _ch_win_min: float = 14.0
	var _ch_win_max: float = 30.0
	var _ch_block_margin: float = 2.0
	var _ch_v_base: float = 4.0
	var _ch_v_span: float = 2.0
	var _ch_lc_dur: float = 0.9
	var _mini_ds_min: float = 4.0
	var _mini_ds_max: float = 30.0
	var _cutin_ds_min: float = 10.0
	var _cutin_margin: float = 2.0
	var _cutin_v: float = 3.5
	var _cutin_lc_dur: float = 0.8
	var _cutin_cool: float = 3.0
	var _throw_cool_base: float = 2.0
	var _throw_cool_span: float = 1.2
	var _throw_max: int = 2
	var _rel_hazard: float = 1.05
	var _rel_lc_base: float = 0.4
	var _rel_lc_span: float = 0.6
	var _rel_lane_cap: float = 3.0
	var _rel_wall_extra: float = 0.35
	var _rel_car_extra: float = 0.08
	var _lc_dt_floor: float = 1e-4
	var _lc_yaw_min_v: float = 2.0
	var _lc_yaw_gain: float = 0.8
	var _pr_next_base: float = 0.8
	var _pr_next_span: float = 0.8
	var _pr_slow_margin: float = 3.0
	var _pr_slow_lc: float = 1.4
	var _pr_look_gap: float = 22.0
	var _pr_v_margin: float = 3.0
	var _pr_pass_margin: float = 3.5
	var _pr_pass_lc: float = 0.95
	var _pr_ch_margin: float = 2.5
	var _pr_ch_lc: float = 1.2
	var _opp_recycle: float = 130.0
	var _opp_ahead: float = 280.0
	var _opp_span: float = 160.0
	var _wave_amp: float = 0.88
	var _wave_speed: float = 6.0
	var _wave_hold: float = 0.6
	var _wave_life: float = 6.0
	var _wave_min: float = 0.15
	var _wave_margin: float = 1.2
	var _wave_cap: float = 2.5
	var _ys_behind: float = 20.0
	var _ys_ahead: float = 5.0
	var _ys_hold_fb: float = 2.5
	var _ys_period_fb: float = 2.5
	var _ys_wave_off: float = 1.0
	var _ys_wave_str: float = 0.7
	var _ys_wave_amp: float = 0.8
	var _bl_acc: float = -0.25
	var _bl_v: float = 1.6
	var _bl_freq: float = 1.3
	var _bl_above: float = 0.2
	var _hz_period: float = 0.5
	var _hz_on: float = 0.27
	var _hz_ch_freq: float = 2.2
	var _merge_yield_overlap: float = 1.3
	var _gap_extra: float = 1.0
	var _gap_len_fb: float = 4.2
	var _gap_window: float = 6.0
	var _li_ahead_min: float = -3.5
	var _li_ahead_max: float = 22.0
	var _li_behind_max: float = -14.0
	var _li_pull: float = 2.2
	var _li_brake: float = 2.2
	var _li_yield_for: float = 2.8
	var _pa_range: float = 18.0
	var _pa_hold: float = 1.2
	var _safe_touch: float = -0.1
	var _safe_gain: float = 1.5
	var _honk_range: float = 18.0
	var _honk_range_siren: float = 45.0
	var _honk_range_trot: float = 24.0
	var _honk_slack: float = 2.0
	var _honk_probe: float = 0.5
	var _honk_villain: float = 30.0
	var _honk_cheater: float = 30.0
	var _honk_cheater_siren: float = 50.0
	var _honk_cheater_lc: float = 1.1
	var _fat_relax: float = 8.0
	var _fat_half_p: float = 0.5
	var _fat_ignore_at: int = 3
	var _honk_yield_margin: float = 1.6
	var _honk_yield_lc: float = 0.85
	var _rage_behind: float = 2.0
	var _rage_lc: float = 0.7
	var _rage_hold: float = 0.5
	var _mh_jolt: float = 0.6
	var _mh_brake: float = 2.5
	var _mh_hazard: float = 4.0
	var _mh_lc: float = 0.9
	var _mt_behind: float = -3.0
	var _mt_ahead: float = 26.0
	var _mt_lateral: float = 1.2
	var _rel_lane_delay: float = 0.45
	var _rel_wave_speed: float = 70.0
	var _rel_lo: float = 25.0
	var _rel_hi: float = 30.0
	var _truck_lo: float = 22.0
	var _truck_hi: float = 25.0

	static func _num(root: Variant, path: String, def: float) -> float:
		var cur: Variant = root
		for seg: String in path.split("."):
			if not (cur is Dictionary) or not (cur as Dictionary).has(seg):
				return def
			cur = (cur as Dictionary)[seg]
		return float(cur) if (cur is float or cur is int) else def

	static func _truthy(val: Variant, def: bool) -> bool:
		if val == null:
			return def
		if val is bool:
			return val
		if val is int or val is float:
			return float(val) != 0.0
		if val is String:
			return not (val as String).is_empty()
		return true

	func _load_params(cfg: Dictionary) -> void:
		var tr: Dictionary = cfg.get("traffic", {}) if cfg.get("traffic") is Dictionary else {}
		_half_occ = _num(cfg, "road.laneW", Cfg.LANE_W) / 2.0 - _num(tr, "occupancy.halfLaneMargin", 0.6)
		_idm_b = _num(tr, "idm.b", _idm_b)
		_acc_min = _num(tr, "idm.accMin", _acc_min)
		_brake_v0 = _num(tr, "idm.brakeV0", _brake_v0)
		_v_floor = _num(tr, "idm.vFloor", _v_floor)
		_gap_floor = _num(tr, "idm.gapFloor", _gap_floor)
		_stop_gap = _num(tr, "idm.stopGap", _stop_gap)
		var names: Array = ["packed", "train", "flow", "spaced", "pass"]
		for k: int in 5:
			var b: String = "idm.lanes." + str(names[k]) + "."
			_lk_T[k] = _num(tr, b + "T", _lk_T[k])
			_lk_s0[k] = _num(tr, b + "s0", _lk_s0[k])
			_lk_a[k] = _num(tr, b + "aMax", _lk_a[k])
			_lk_mul[k] = _num(tr, b + ("v0MulFallback" if k == LK_PASS else "v0Mul"), _lk_mul[k])
		_lf_base = _num(tr, "idm.lanes.packed.lfBase", _lf_base)
		_lf_amp = _num(tr, "idm.lanes.packed.lfAmp", _lf_amp)
		_lf_freq = _num(tr, "idm.lanes.packed.lfFreq", _lf_freq)
		_lf_phase = _num(tr, "idm.lanes.packed.lfLanePhase", _lf_phase)
		_rel_T = _num(tr, "idm.released.T", _rel_T)
		_rel_s0 = _num(tr, "idm.released.s0", _rel_s0)
		_rel_a = _num(tr, "idm.released.aMax", _rel_a)
		_rel_a_slow = _num(tr, "idm.released.aMaxSlow", _rel_a_slow)
		_wall_T = _num(tr, "idm.wall.T", _wall_T)
		_wall_s0 = _num(tr, "idm.wall.s0", _wall_s0)
		_wall_a = _num(tr, "idm.wall.aMax", _wall_a)
		_wall_follow = _num(tr, "idm.wall.follow", _wall_follow)
		_ch_T = _num(tr, "idm.cheater.T", _ch_T)
		_ch_s0 = _num(tr, "idm.cheater.s0", _ch_s0)
		_ch_a = _num(tr, "idm.cheater.aMax", _ch_a)
		_ch_v0_fb = _num(tr, "idm.cheater.v0Fallback", _ch_v0_fb)
		_pull_T = _num(tr, "idm.pull.T", _pull_T)
		_pull_s0 = _num(tr, "idm.pull.s0", _pull_s0)
		_pull_a = _num(tr, "idm.pull.aMax", _pull_a)
		_pull_mul = _num(tr, "idm.pull.v0Mul", _pull_mul)
		_pull_mul_let_in = _num(tr, "idm.pull.v0MulLetIn", _pull_mul_let_in)
		_vw_back = _num(tr, "idm.villainWall.back", _vw_back)
		_vw_zig = _num(tr, "idm.villainWall.zigExtra", _vw_zig)
		var u: String = "update."
		_brake_rate = _num(tr, u + "randomBrake.ratePerSec", _brake_rate)
		_brake_behind = _num(tr, u + "randomBrake.behindPlayer", _brake_behind)
		_brake_ahead = _num(tr, u + "randomBrake.aheadPlayer", _brake_ahead)
		_brake_hold_base = _num(tr, u + "randomBrake.holdBase", _brake_hold_base)
		_brake_hold_span = _num(tr, u + "randomBrake.holdSpan", _brake_hold_span)
		_stuck_v_below = _num(tr, u + "stuck.vBelow", _stuck_v_below)
		_stuck_decay = _num(tr, u + "stuck.decay", _stuck_decay)
		rubber = _num(tr, u + "stuck.rubberFallback", rubber)
		rubber_safety = _num(tr, u + "stuck.rubberSafetyFallback", rubber_safety)
		_stuck_pull_after = _num(tr, u + "stuck.pullAheadAfter", _stuck_pull_after)
		_tow_ahead = _num(tr, u + "stuck.towProbeAhead", _tow_ahead)
		_tow_behind = _num(tr, u + "stuck.towProbeBehind", _tow_behind)
		_auto_tow_after = int(_num(tr, u + "stuck.autoTowAfter", _auto_tow_after))
		_ch_first_delay = _num(tr, u + "cheaterEvent.firstDelay", _ch_first_delay)
		_ch_min_player_v = _num(tr, u + "cheaterEvent.minPlayerV", _ch_min_player_v)
		_ch_next_base = _num(tr, u + "cheaterEvent.nextBase", _ch_next_base)
		_ch_next_span = _num(tr, u + "cheaterEvent.nextSpan", _ch_next_span)
		_ch_win_min = _num(tr, u + "cheaterEvent.windowMin", _ch_win_min)
		_ch_win_max = _num(tr, u + "cheaterEvent.windowMax", _ch_win_max)
		_ch_block_margin = _num(tr, u + "cheaterEvent.blockMargin", _ch_block_margin)
		_ch_v_base = _num(tr, u + "cheaterEvent.vBase", _ch_v_base)
		_ch_v_span = _num(tr, u + "cheaterEvent.vSpan", _ch_v_span)
		_ch_lc_dur = _num(tr, u + "cheaterEvent.lcDur", _ch_lc_dur)
		_mini_ds_min = _num(tr, u + "minis.dsMin", _mini_ds_min)
		_mini_ds_max = _num(tr, u + "minis.dsMax", _mini_ds_max)
		_cutin_ds_min = _num(tr, u + "minis.cutin.dsMin", _cutin_ds_min)
		_cutin_margin = _num(tr, u + "minis.cutin.blockMargin", _cutin_margin)
		_cutin_v = _num(tr, u + "minis.cutin.v", _cutin_v)
		_cutin_lc_dur = _num(tr, u + "minis.cutin.lcDur", _cutin_lc_dur)
		_cutin_cool = _num(tr, u + "minis.cutin.cool", _cutin_cool)
		_throw_cool_base = _num(tr, u + "minis.throw.coolBase", _throw_cool_base)
		_throw_cool_span = _num(tr, u + "minis.throw.coolSpan", _throw_cool_span)
		_throw_max = int(_num(tr, u + "minis.throw.maxActs", _throw_max))
		_rel_hazard = _num(tr, u + "release.hazard", _rel_hazard)
		_rel_lc_base = _num(tr, u + "release.nextLcBase", _rel_lc_base)
		_rel_lc_span = _num(tr, u + "release.nextLcSpan", _rel_lc_span)
		_rel_lane_cap = _num(tr, u + "release.laneDelayCap", _rel_lane_cap)
		_rel_wall_extra = _num(tr, u + "release.wallExtra", _rel_wall_extra)
		_rel_car_extra = _num(tr, u + "release.carExtra", _rel_car_extra)
		_lc_dt_floor = _num(tr, u + "laneChange.dtFloor", _lc_dt_floor)
		_lc_yaw_min_v = _num(tr, u + "laneChange.yawMinV", _lc_yaw_min_v)
		_lc_yaw_gain = _num(tr, u + "laneChange.yawGain", _lc_yaw_gain)
		_pr_next_base = _num(tr, u + "postRelease.nextBase", _pr_next_base)
		_pr_next_span = _num(tr, u + "postRelease.nextSpan", _pr_next_span)
		_pr_slow_margin = _num(tr, u + "postRelease.slowMargin", _pr_slow_margin)
		_pr_slow_lc = _num(tr, u + "postRelease.slowLcDur", _pr_slow_lc)
		_pr_look_gap = _num(tr, u + "postRelease.lookGap", _pr_look_gap)
		_pr_v_margin = _num(tr, u + "postRelease.vMargin", _pr_v_margin)
		_pr_pass_margin = _num(tr, u + "postRelease.passMargin", _pr_pass_margin)
		_pr_pass_lc = _num(tr, u + "postRelease.passLcDur", _pr_pass_lc)
		_pr_ch_margin = _num(tr, u + "postRelease.cheaterReturnMargin", _pr_ch_margin)
		_pr_ch_lc = _num(tr, u + "postRelease.cheaterReturnLcDur", _pr_ch_lc)
		_opp_recycle = _num(tr, u + "opp.recycleBehind", _opp_recycle)
		_opp_ahead = _num(tr, u + "opp.respawnAhead", _opp_ahead)
		_opp_span = _num(tr, u + "opp.respawnSpan", _opp_span)
		_wave_amp = _num(tr, u + "jamWave.amp", _wave_amp)
		_wave_speed = _num(tr, u + "jamWave.speed", _wave_speed)
		_wave_hold = _num(tr, u + "jamWave.hold", _wave_hold)
		_wave_life = _num(tr, u + "jamWave.life", _wave_life)
		_wave_min = _num(tr, u + "jamWave.minStrength", _wave_min)
		_wave_margin = _num(tr, u + "jamWave.hitMargin", _wave_margin)
		_wave_cap = _num(tr, u + "jamWave.holdCap", _wave_cap)
		_ys_behind = _num(tr, u + "yieldSource.behind", _ys_behind)
		_ys_ahead = _num(tr, u + "yieldSource.ahead", _ys_ahead)
		_ys_hold_fb = _num(tr, u + "yieldSource.holdFallback", _ys_hold_fb)
		_ys_period_fb = _num(tr, u + "yieldSource.periodFallback", _ys_period_fb)
		_ys_wave_off = _num(tr, u + "yieldSource.waveOffset", _ys_wave_off)
		_ys_wave_str = _num(tr, u + "yieldSource.waveStrength", _ys_wave_str)
		_ys_wave_amp = _num(tr, u + "yieldSource.waveAmp", _ys_wave_amp)
		_bl_acc = _num(tr, u + "brakeLight.accBelow", _bl_acc)
		_bl_v = _num(tr, u + "brakeLight.vBelow", _bl_v)
		_bl_freq = _num(tr, u + "brakeLight.flickerFreq", _bl_freq)
		_bl_above = _num(tr, u + "brakeLight.flickerAbove", _bl_above)
		_hz_period = _num(tr, u + "hazard.period", _hz_period)
		_hz_on = _num(tr, u + "hazard.onFrac", _hz_on)
		_hz_ch_freq = _num(tr, u + "hazard.cheaterFreq", _hz_ch_freq)
		var q: String = "queries."
		_merge_yield_overlap = _num(tr, q + "canMergeInto.yieldOverlap", _merge_yield_overlap)
		_gap_extra = _num(tr, q + "hasGap.extra", _gap_extra)
		_gap_len_fb = _num(tr, q + "hasGap.lenFallback", _gap_len_fb)
		_gap_window = _num(tr, q + "hasGap.window", _gap_window)
		_li_ahead_min = _num(tr, q + "letIn.aheadMin", _li_ahead_min)
		_li_ahead_max = _num(tr, q + "letIn.aheadMax", _li_ahead_max)
		_li_behind_max = _num(tr, q + "letIn.behindMax", _li_behind_max)
		_li_pull = _num(tr, q + "letIn.pull", _li_pull)
		_li_brake = _num(tr, q + "letIn.brake", _li_brake)
		_li_yield_for = _num(tr, q + "letIn.yieldFor", _li_yield_for)
		_pa_range = _num(tr, q + "pullAhead.range", _pa_range)
		_pa_hold = _num(tr, q + "pullAhead.hold", _pa_hold)
		_safe_touch = _num(tr, q + "safeToEnter.touch", _safe_touch)
		_safe_gain = _num(tr, q + "safeToEnter.closingGain", _safe_gain)
		_honk_range = _num(tr, q + "honk.range", _honk_range)
		_honk_range_siren = _num(tr, q + "honk.rangeSiren", _honk_range_siren)
		_honk_range_trot = _num(tr, q + "honk.rangeTrot", _honk_range_trot)
		_honk_slack = _num(tr, q + "honk.rangeSlack", _honk_slack)
		_honk_probe = _num(tr, q + "honk.probeBack", _honk_probe)
		_honk_villain = _num(tr, q + "honk.villainRange", _honk_villain)
		_honk_cheater = _num(tr, q + "honk.cheaterRange", _honk_cheater)
		_honk_cheater_siren = _num(tr, q + "honk.cheaterRangeSiren", _honk_cheater_siren)
		_honk_cheater_lc = _num(tr, q + "honk.cheaterLcDur", _honk_cheater_lc)
		_fat_relax = _num(tr, q + "honk.fatigueRelax", _fat_relax)
		_fat_half_p = _num(tr, q + "honk.fatigueHalfP", _fat_half_p)
		_fat_ignore_at = int(_num(tr, q + "honk.fatigueIgnoreAt", _fat_ignore_at))
		_honk_yield_margin = _num(tr, q + "honk.yieldMargin", _honk_yield_margin)
		_honk_yield_lc = _num(tr, q + "honk.yieldLcDur", _honk_yield_lc)
		_rage_behind = _num(tr, q + "rageHorn.behind", _rage_behind)
		_rage_lc = _num(tr, q + "rageHorn.lcDur", _rage_lc)
		_rage_hold = _num(tr, q + "rageHorn.startledHold", _rage_hold)
		_mh_jolt = _num(tr, q + "miniHit.jolt", _mh_jolt)
		_mh_brake = _num(tr, q + "miniHit.brake", _mh_brake)
		_mh_hazard = _num(tr, q + "miniHit.hazard", _mh_hazard)
		_mh_lc = _num(tr, q + "miniHit.lcDur", _mh_lc)
		_mt_behind = _num(tr, q + "miniTarget.behind", _mt_behind)
		_mt_ahead = _num(tr, q + "miniTarget.ahead", _mt_ahead)
		_mt_lateral = _num(tr, q + "miniTarget.lateralLanes", _mt_lateral)
		_rel_lane_delay = _num(cfg, "tune.releaseLaneDelay", _rel_lane_delay)
		_rel_wave_speed = _num(cfg, "tune.releaseWaveSpeed", _rel_wave_speed)
		var rs: Variant = (cfg.get("tune", {}) as Dictionary).get("releaseSpeed") if cfg.get("tune") is Dictionary else null
		if rs is Array and (rs as Array).size() >= 2:
			_rel_lo = float(rs[0])
			_rel_hi = float(rs[1])
		var ts: Variant = (cfg.get("tune", {}) as Dictionary).get("truckFreeSpeed") if cfg.get("tune") is Dictionary else null
		if ts is Array and (ts as Array).size() >= 2:
			_truck_lo = float(ts[0])
			_truck_hi = float(ts[1])

	# --- spawn (traffic_core.cpp spawn_jam, same draw order) --------------------------------------------

	func _draw() -> float:
		return _rng.next_float()

	func _kind_idx(name: String) -> int:
		return kind_names.find(name)

	func _weights(list: Variant) -> Array:
		var out: Array = []
		if list is Array:
			for e: Variant in list:
				if e is Array and (e as Array).size() >= 2:
					out.append([_kind_idx(str(e[0])), float(e[1])])
		return out

	func _pick(table: Array) -> int:
		var total: float = 0.0
		for e: Array in table:
			total += float(e[1])
		var r: float = _draw() * total
		for e: Array in table:
			r -= float(e[1])
			if r <= 0.0:
				return int(e[0])
		return int((table[0] as Array)[0]) if not table.is_empty() else -1

	func _kind_rec(k: int) -> Dictionary:
		return _kinds_tbl.get(kind_names[k], {}) if k >= 0 and k < kind_names.size() else {}

	static func _variant_without_seed(kd: Dictionary, col: int) -> int:
		var variants: int = int(kd.get("variants", 1))
		if bool(kd.get("colorVariant", false)) and variants > 0:
			return col % variants
		var canon: Array = kd.get("canon", [0])
		return int(canon[0]) if not canon.is_empty() else 0

	static func _dims_of(kd: Dictionary, var_i: int) -> Dictionary:
		var list: Array = (kd.get("dims", {}) as Dictionary).get("simple", [])
		if list.is_empty():
			return {}
		return list[var_i] if var_i >= 0 and var_i < list.size() else list[0]

	## traffic.js _makeCar: draws mono, color, seed, personal, phase (in that order).
	func _make_car(k: int, l: int, sv: float, vv: float, mono_list: Array, pop_list: Array, mono_p: float) -> int:
		var is_mono: bool = _draw() < mono_p
		var pal: Array = mono_list if is_mono else pop_list
		var rc: float = _draw()
		var col: int = int(pal[int(floor(rc * pal.size()))]) if not pal.is_empty() else 0
		var seed: int = int(floor(_draw() * 1e6))
		var kd: Dictionary = _kind_rec(k)
		var var_i: int = 0
		var L: float = 4.5
		var W: float = 1.9
		if not kd.is_empty():
			var variants: int = int(kd.get("variants", 1))
			var canon: Array = kd.get("canon", [0])
			if canon.is_empty():
				canon = [0]
			if variants > 0:
				var_i = int(canon[(seed % variants) % canon.size()])
			var d: Dictionary = _Creep._dims_of(kd, var_i)
			if float(d.get("L", 0.0)) > 0.0:
				L = float(d["L"])
			if float(d.get("W", 0.0)) > 0.0:
				W = float(d["W"])
		var i: int = n
		n += 1
		ids.append(i + 1)
		kind.append(k)
		variant.append(var_i)
		color.append(col)
		lane.append(l)
		lane_from.append(l)
		lc_t.append(1.0)
		lc_dur.append(1.8)
		s.append(sv)
		x.append(Cfg.lane_x(l))
		v.append(vv)
		ln.append(L)
		wd.append(W)
		personal.append(0.97 + _draw() * 0.06)
		phase.append(_draw() * PI * 2.0)
		brake_t.append(0.0)
		pull_t.append(0.0)
		boost.append(0)
		hazard_until.append(0.0)
		rel.append(0)
		release_at.append(INF)
		v_free.append(30.0)
		slow.append(0)
		wall.append(0)
		cheat.append(0)
		next_lc_at.append(0.0)
		jolt_t.append(0.0)
		yaw.append(0.0)
		wall_off.append(0.0)
		wall_back.append(0.0)
		cheater_v.append(0.0)
		yield_until.append(-INF)
		honk_n.append(0)
		honk_t.append(0.0)
		yielded.append(0)
		mini.append(0)
		mini_type.append(0)
		mini_hp.append(0.0)
		mini_cool.append(0.0)
		mini_acted.append(0)
		mini_done.append(0)
		blink.append(0)
		lamp.append(LAMP_BRAKE)
		acc_l.append(0.0)
		prev_s.append(sv)
		prev_x.append(x[i])
		prev_yaw.append(0.0)
		return i

	## shoulder.js buildShoulderObstacle + traffic.js:200-205 (breakdown: kind / colour / rotY draws; debris: count, boxes, tire).
	func _add_obstacle(kname: String, so: float, dark: bool, x_off: float) -> void:
		var det: Dictionary = {}
		var olen: float = 4.2
		var ow: float = 2.0
		var is_bd: bool = kname == "breakdown"
		if is_bd:
			var ck: int = _kind_idx(str(BK_KINDS[int(floor(_draw() * 4.0))]))
			var col: int = int(BK_COLORS[int(floor(_draw() * 4.0))])
			var car_len: float = 4.6
			var var_i: int = 0
			var kd: Dictionary = _kind_rec(ck)
			if not kd.is_empty():
				var_i = _Creep._variant_without_seed(kd, col)
				var d: Dictionary = _Creep._dims_of(kd, var_i)
				if float(d.get("L", 0.0)) > 0.0:
					car_len = float(d["L"])
			det = {"carKind": kind_names[ck] if ck >= 0 else "", "variant": var_i, "color": col, "carLen": car_len,
				"rotY": (_draw() - 0.5) * 0.12, "triangle": not dark}
			olen = car_len + 3.4
			ow = 2.1
		elif kname == "cones":
			olen = 11.5
			ow = 2.4
		else:
			var boxes: Array = []
			var nb: int = 2 + int(floor(_draw() * 2.0))
			for b: int in nb:
				var bx: float = (_draw() - 0.5) * 1.4
				var bz: float = (_draw() - 0.5) * 2.2
				var br: float = _draw() * 3.0
				boxes.append({"x": bx, "z": bz, "rotY": br})
			det = {"boxes": boxes, "tireX": (_draw() - 0.5) * 1.2}
		obstacles.append({"id": 10000 + obstacles.size(), "kind": kname, "s": so, "x": Cfg.lane_x(Cfg.SHOULDER_LANE) - x_off,
			"len": olen, "w": ow, "smash": not is_bd, "hazard": is_bd and not dark, "detail": det})

	func spawn(stage: Dictionary, tables: Dictionary, info: Dictionary, seed: int, p_night: bool) -> void:
		_rng = Mulberry32.new(seed)
		night = p_night
		var config: Dictionary = tables.get("config", {}) if tables.get("config") is Dictionary else {}
		_load_params(config)
		var tr: Dictionary = config.get("traffic", {}) if config.get("traffic") is Dictionary else {}
		var sp: Dictionary = tr.get("spawn", {}) if tr.get("spawn") is Dictionary else {}
		_kinds_tbl = (tables.get("vehicle_kinds", {}) as Dictionary).get("kinds", {})
		kind_names = PackedStringArray(_kinds_tbl.keys())
		var npc: Dictionary = config.get("npc", {})
		var npc_w: Array = _weights(npc.get("kinds", [["sedan", 1]]))
		var cheat_w: Array = _weights(sp.get("cheaterKinds", [["sedan", 3], ["suv", 2], ["compact", 1]]))
		var mono_list: Array = npc.get("colorsMono", [0xf4f4f2])
		var pop_list: Array = npc.get("colorsPop", mono_list)
		var mono_p: float = _num(tr, "car.monoP", 0.68)
		var slow_names: Array = (tr.get("car", {}) as Dictionary).get("slowKinds", ["truck", "bus", "pickup1t"]) if tr.get("car") is Dictionary else []
		_mini_names = []
		var mt: Variant = (tables.get("mini_types", {}) as Dictionary).get("types", []) if tables.get("mini_types") is Dictionary else []
		for m: Variant in (mt as Array):
			_mini_names.append(str((m as Dictionary).get("id", "")))
		# stage spec
		jam_speed = float(stage.get("jamSpeed", 2.4))
		front_v = jam_speed
		var dens_v: Variant = stage.get("density")
		var density: float = float(dens_v) if (dens_v is float or dens_v is int) and float(dens_v) != 0.0 else 1.0
		var zig: bool = _Creep._truthy(stage.get("zig"), false)
		var atk: Variant = stage.get("attacks")
		if atk is Array:
			for e: Variant in atk:
				if e is Array and (e as Array).size() >= 2 and str(e[0]) == "zigzag" and _Creep._truthy(e[1], false):
					zig = true
		elif atk is Dictionary and _Creep._truthy((atk as Dictionary).get("zigzag"), false):
			zig = true
		zigzag = zig
		var zc: Variant = stage.get("zigCenter")
		var zig_center: int = int(zc) if (zc is int or zc is float) else 1
		var js: Dictionary = stage.get("jamShape") if stage.get("jamShape") is Dictionary else {}
		lane_kind = PackedInt32Array([LK_PACKED, LK_PACKED, LK_PACKED, LK_PACKED])
		if js.get("lanes") is Array:
			var L: Array = js["lanes"]
			for i: int in mini(4, L.size()):
				if _Creep._truthy(L[i], false):
					var ki: int = LK_NAMES.find(str(L[i]))
					lane_kind[i] = ki if ki >= 0 else LK_PACKED
		_pass_v = float(js["passV"]) if (js.get("passV") is float or js.get("passV") is int) else _lk_mul[LK_PASS]
		_sources = []
		if js.get("sources") is Array:
			for src: Variant in js["sources"]:
				var sd: Dictionary = src
				_sources.append({"type": str(sd.get("type", "")), "lane": int(sd.get("lane", 0)) if (sd.get("lane") is int or sd.get("lane") is float) else 0,
					"hold": float(sd["hold"]) if (sd.get("hold") is int or sd.get("hold") is float) else _ys_hold_fb,
					"period": float(sd["period"]) if (sd.get("period") is int or sd.get("period") is float) else _ys_period_fb})
		_jam_src_t = 0.0
		_waves = []
		var appr: Dictionary = info.get("approach", {}) if info.get("approach") is Dictionary else {}
		shoulder_mode = str(appr.get("shoulder", "open"))
		shoulder_closed = shoulder_mode == "closed" or shoulder_mode == "none"
		gap_check = _Creep._truthy(appr.get("gapCheck"), true)
		fatigue = _Creep._truthy(appr.get("fatigue"), true)
		if appr.get("rubber") is float or appr.get("rubber") is int:
			rubber = float(appr["rubber"])
		if appr.get("rubberSafety") is float or appr.get("rubberSafety") is int:
			rubber_safety = float(appr["rubberSafety"])
		if appr.get("rageHorn") is float or appr.get("rageHorn") is int:
			rage_horn_m = float(appr["rageHorn"])
		var p_s: float = float(info["start_s"])
		var p_lane: int = int(info["start_lane"])
		var vls: Array = info["villains"]
		var s_front: float = -INF
		for vv: Variant in vls:
			s_front = maxf(s_front, float((vv as Dictionary)["s"]))
		front_line = s_front
		var tail: float = p_s - _num(sp, "tailBehindPlayer", 45.0)
		s_tail = tail
		# ① front row (walls)
		var villain_lanes: Array[bool] = [false, false, false, false]
		var front_rear: Array[float] = [INF, INF, INF, INF]
		for vv: Variant in vls:
			var vd: Dictionary = vv
			for l: int in 4:
				if absf(float(vd["x"]) - Cfg.lane_x(l)) < float(vd["w"]) / 2.0 + _half_occ:
					villain_lanes[l] = true
					front_rear[l] = minf(front_rear[l], float(vd["s"]) - float(vd["len"]) / 2.0)
		if zig:
			for l: int in range(zig_center - 1, zig_center + 2):
				if l >= 0 and l < 4:
					villain_lanes[l] = true
		var fr_kinds: Array = [-1, -1, -1, -1]
		var fr: Variant = stage.get("frontRow")
		if not (fr is Array):
			fr = sp.get("frontRowFallback", [null, "truck", "truck", "truck"])
		for i: int in mini(4, (fr as Array).size()):
			fr_kinds[i] = _kind_idx(str(fr[i])) if fr[i] is String else -1
		var wos: float = _num(sp, "wallOffsetSpan", 1.2)
		for l: int in 4:
			if villain_lanes[l] or int(fr_kinds[l]) < 0:
				continue
			var off: float = (_draw() - 0.5) * wos
			var i: int = _make_car(int(fr_kinds[l]), l, s_front + off, jam_speed, mono_list, pop_list, mono_p)
			wall[i] = 1
			wall_off[i] = off
			front_rear[l] = s[i] - ln[i] / 2.0
		for l: int in 4:
			if not is_finite(front_rear[l]):
				front_rear[l] = s_front - _num(sp, "emptyFrontRearBack", 3.0)
		# ② jam lanes (JamShaper lane kinds)
		var g_base: Array = [_num(sp, "gap.packed.base", 1.5), _num(sp, "gap.train.base", 1.2), _num(sp, "gap.flow.base", 2.6),
			_num(sp, "gap.spaced.base", 7.0), _num(sp, "gap.pass.base", 9.0)]
		var g_span: Array = [_num(sp, "gap.packed.span", 1.7), _num(sp, "gap.train.span", 0.5), _num(sp, "gap.flow.span", 2.0),
			_num(sp, "gap.spaced.span", 5.0), _num(sp, "gap.pass.span", 5.0)]
		var by_density: bool = _Creep._truthy((((sp.get("gap", {}) as Dictionary).get("packed", {}) as Dictionary).get("dividedByDensity", true)) if sp.get("gap") is Dictionary else true, true)
		var hole: float = _num(sp, "playerHoleHalf", 3.4)
		var push_back: float = _num(sp, "playerHolePushBack", 2.0)
		var v0_mul: float = _num(sp, "laneCarV0Mul", 0.7)
		for l: int in 4:
			var lk: int = lane_kind[l]
			var lead: float
			if lk == LK_SPACED:
				lead = _num(sp, "leadGap.spacedBase", 9.0) + _draw() * _num(sp, "leadGap.spacedSpan", 4.0)
			else:
				lead = _num(sp, "leadGap.base", 2.2) + _draw() * _num(sp, "leadGap.span", 1.6)
			var cursor: float = front_rear[l] - lead - (_num(sp, "leadGap.zigExtra", 6.0) if villain_lanes[l] and zig else 0.0)
			while cursor > tail:
				var k: int = _pick(npc_w)
				var i: int = _make_car(k, l, 0.0, jam_speed * v0_mul, mono_list, pop_list, mono_p)
				var sc: float = cursor - ln[i] / 2.0
				if l == p_lane and sc + ln[i] / 2.0 > p_s - hole and sc - ln[i] / 2.0 < p_s + hole:
					sc = p_s - hole - ln[i] / 2.0 - push_back
				s[i] = sc
				prev_s[i] = sc
				var g: float = float(g_base[lk]) + _draw() * float(g_span[lk])
				if lk == LK_PACKED and by_density:
					g = g / density
				cursor = sc - ln[i] / 2.0 - g
		# ③ shoulder: obstacles + cheaters (stage.shoulder spec, approach.shoulder mode)
		var spec: Array = stage.get("shoulder") if stage.get("shoulder") is Array else sp.get("shoulderFallbackSpec", [])
		if shoulder_closed:
			spec = []
		elif shoulder_mode == "crowded":
			var f: Array = []
			for e: Variant in spec:
				if str((e as Array)[0]) != "cheater":
					f.append(e)
			f.append(["cheater", int(_num(sp, "crowdedCheaters", 3))])
			spec = f
		elif shoulder_mode == "dark":
			spec = sp.get("darkSpec", [])
		elif shoulder_mode == "debris":
			spec = sp.get("debrisSpec", [])
		var items: Array = []  # [kind, fixed, at]
		for e: Variant in spec:
			if e is Array and (e as Array).size() >= 2:
				for c: int in int(float(e[1])):
					items.append([str(e[0]), false, 0.0])
		if shoulder_mode == "blocked":
			var b0: float = p_s + (s_front - p_s) * _num(sp, "blocked.startFrac", 0.45)
			for k: int in int(_num(sp, "blocked.count", 5)):
				items.append(["cones", true, b0 + k * _num(sp, "blocked.spacing", 12.0)])
		for i: int in range(items.size() - 1, 0, -1):
			var j: int = int(floor(_draw() * (i + 1)))
			var tmp: Variant = items[i]
			items[i] = items[j]
			items[j] = tmp
		var s0: float = p_s + _num(sp, "shoulderStartAhead", 38.0)
		var s1: float = s_front - _num(sp, "shoulderEndBeforeFront", 22.0)
		var stp: float = (s1 - s0) / maxf(1.0, float(items.size()))
		var x_off: float = _num(sp, "obstacleXOffset", 0.1)
		for i: int in items.size():
			var it: Array = items[i]
			var so: float = s0 + stp * (i + _num(sp, "jitterBase", 0.25) + _draw() * _num(sp, "jitterSpan", 0.5)) if not bool(it[1]) else float(it[2])
			if str(it[0]) == "cheater":
				var k: int = _pick(cheat_w)
				var c: int = _make_car(k, Cfg.SHOULDER_LANE, so, _num(sp, "cheaterSpawnV", 4.5), mono_list, pop_list, mono_p)
				cheat[c] = 1
				cheater_v[c] = _num(sp, "cheaterVBase", 4.0) + _draw() * _num(sp, "cheaterVSpan", 2.5)
				continue
			_add_obstacle(str(it[0]), so, shoulder_mode == "dark", x_off)
		# slow kinds (release speeds)
		for i: int in n:
			if slow_names.has(kind_names[kind[i]] if kind[i] >= 0 else ""):
				slow[i] = 1
		# ③-2 minis on lane 3
		var n_mini: int = 0
		if stage.get("minis") is int or stage.get("minis") is float:
			n_mini = int(stage["minis"])
		else:
			var diff: float = float(stage["difficulty"]) if (stage.get("difficulty") is int or stage.get("difficulty") is float) else float(stage.get("id", 1))
			n_mini = mini(int(_num(sp, "minis.max", 4)), int(_num(sp, "minis.base", 2)) + int(floor(diff / _num(sp, "minis.perDifficulty", 3.0))))
		var win: float = _num(sp, "minis.window", 30.0)
		var lane3: Array = []
		for i: int in n:
			if lane[i] == 3 and wall[i] == 0 and cheat[i] == 0 and s[i] > p_s + win and s[i] < s_front - win:
				lane3.append(i)
		lane3.sort_custom(func(a: int, b: int) -> bool: return s[a] < s[b] or (s[a] == s[b] and a < b))
		var n_types: int = _mini_names.size()
		_minis = PackedInt32Array()
		for m: int in n_mini:
			if lane3.is_empty():
				break
			var want: float = p_s + win + ((s_front - win) - (p_s + win)) * (m + 0.5) / n_mini
			var bi: int = 0
			for k: int in lane3.size():
				if absf(s[lane3[k]] - want) < absf(s[lane3[bi]] - want):
					bi = k
			var best: int = lane3[bi]
			lane3.remove_at(bi)
			mini[best] = 1
			mini_type[best] = int(floor(_draw() * n_types))
			mini_hp[best] = _num(sp, "minis.hp", 12.0)
			mini_cool[best] = _num(sp, "minis.coolBase", 0.6) + _draw()
			mini_acted[best] = 0
			mini_done[best] = 0
			_minis.append(best)
		# ④ opposite carriageway
		for k: int in int(_num(sp, "opp.count", 26)):
			var j: int = int(floor(_draw() * _num(sp, "opp.lanes", 4.0)))
			var ok: int = _pick(npc_w)
			var pal: Array = mono_list if _draw() < _num(sp, "opp.monoP", 0.7) else pop_list
			var rc: float = _draw()
			var col: int = int(pal[int(floor(rc * pal.size()))]) if not pal.is_empty() else 0
			opp_j.append(j)
			opp_kind.append(ok)
			opp_color.append(col)
			opp_variant.append(_Creep._variant_without_seed(_kind_rec(ok), col) if ok >= 0 else 0)
			opp_s.append(p_s - _num(sp, "opp.sBehind", 100.0) + _draw() * _num(sp, "opp.sSpan", 520.0))
			opp_v.append(_num(sp, "opp.vBase", 24.0) + _draw() * _num(sp, "opp.vSpan", 12.0) - j * _num(sp, "opp.vPerLane", 2.0))
		opp_prev = opp_s.duplicate()
		for i: int in n:
			lamp[i] = LAMP_BRAKE | (LAMP_HEADLIGHTS if night else 0) | (LAMP_MINI if mini[i] == 1 else 0)
		_order_dirty = true
		_build_masks()

	func count() -> int:
		return n + opp_s.size()

	func lane_kind_of(l: int) -> int:
		return lane_kind[clampi(l, 0, 3)]

	func _rebuild_order() -> void:
		var lists: Array = [[], [], [], [], []]
		var occ: Array = [[], [], [], [], []]
		_home.resize(n)
		for i: int in n:
			var l: int = lane[i]
			_home[i] = l
			if l < 0 or l > 4:
				continue
			(lists[l] as Array).append(i)
			(occ[l] as Array).append(i)
			if lc_t[i] < 1.0 and lane_from[i] != l and lane_from[i] >= 0 and lane_from[i] <= 4:
				(occ[lane_from[i]] as Array).append(i)
		var by_s: Callable = func(a: int, b: int) -> bool: return s[a] > s[b]
		_order.clear()
		_occ.clear()
		_pos.resize(n)
		for l: int in 5:
			(lists[l] as Array).sort_custom(by_s)
			(occ[l] as Array).sort_custom(by_s)
			_order.append(PackedInt32Array(lists[l]))
			_occ.append(PackedInt32Array(occ[l]))
			var oc: Array = occ[l]
			for k: int in oc.size():
				if lane[int(oc[k])] == l:
					_pos[int(oc[k])] = k
		_order_dirty = false

	## Rebuilds the lane lists when lanes changed — never inside step(): like the C++ buckets (built at the top of
	## update) the lists stay those of the tick start until the next step (a car that starts a lane change mid-loop
	## would otherwise be moved twice).
	func _fresh() -> void:
		if _order_dirty and not _in_step:
			_rebuild_order()

	func _p_occupies(p: Dictionary, l: int) -> bool:
		return absf(float(p.get("x", Cfg.lane_x(roundi(float(p["lane"]))))) - Cfg.lane_x(l)) < float(p.get("w", 1.92)) / 2.0 + _half_occ

	func _body_occupies(d: Dictionary, l: int) -> bool:
		return bool(d.get("alive", true)) and absf(float(d["x"]) - Cfg.lane_x(l)) < float(d["w"]) / 2.0 + _half_occ

	## Car j is in lane l's bucket (C++ build_buckets: x occupancy at the start of the last step). _occ[l] holds every car
	## that can be (primary lane + lane changers leaving l); this drops a lane changer that has not reached / has left l.
	func _ox(j: int, l: int) -> bool:
		return (_om[j] & (1 << l)) != 0

	## Lane occupancy bits from x (the C++ build_buckets test |x - laneX| < w/2 + LANE_W/2 - 0.6). x only moves inside
	## step() (lane change progress), so _move refreshes the mask of the cars it moves sideways: the mask is the x of the
	## step start for the next step and for queries between steps, like the C++ buckets.
	func _build_masks() -> void:
		_om.resize(n)
		for i: int in n:
			_mask_of(i)

	func _mask_of(i: int) -> void:
		var m: int = 0
		var hw: float = wd[i] / 2.0 + _half_occ
		var xi: float = x[i]
		for l: int in 5:
			if absf(xi - Cfg.lane_x(l)) < hw:
				m |= 1 << l
		_om[i] = m

	## traffic.js occupies(): |x - laneX(lane)| < w/2 + LANE_W/2 - 0.6 (alive villains only, like alive_villains_).
	static func villain_in_lane(vd: Dictionary, l: int) -> bool:
		return bool(vd.get("alive", true)) and absf(float(vd["x"]) - Cfg.lane_x(l)) < float(vd["w"]) / 2.0 + Cfg.LANE_W / 2.0 - 0.6

	## Non-car bodies in lane l: [s, len, v, type, id] (obstacles on the shoulder, villains, extras, + the player).
	func _others(l: int, p: Dictionary, with_player: bool) -> Array:
		var out: Array = []
		if l == Cfg.SHOULDER_LANE:
			for o: Variant in obstacles:
				var od: Dictionary = o
				out.append([float(od["s"]), float(od["len"]), 0.0, T_OBSTACLE, int(od["id"])])
			for o: Variant in _ghost_ob:
				var gd: Dictionary = o
				out.append([float(gd["s"]), float(gd["len"]), 0.0, T_OBSTACLE, int(gd["id"])])
		for k: int in villains.size():
			var vd: Dictionary = villains[k]
			if _body_occupies(vd, l):
				out.append([float(vd["s"]), float(vd["len"]), float(vd.get("v", 0.0)), T_VILLAIN, -100 - k])
		for k: int in extras.size():
			var ed: Dictionary = extras[k]
			if _body_occupies(ed, l):
				out.append([float(ed["s"]), float(ed["len"]), float(ed.get("v", 0.0)), T_EXTRA, EXTRA_ID_BASE - k])
		if with_player and _p_occupies(p, l):
			out.append([float(p["s"]), float(p.get("len", 4.2)), float(p.get("v", 0.0)), T_PLAYER, PLAYER_ID])
		return out

	# --- update ---------------------------------------------------------------------------------------

	func step(dt: float, time: float, player: Dictionary, p_villains: Array[Dictionary], phase_name: String,
			allow_events: bool = true, jam_like: bool = true, focus_s: float = NAN) -> void:
		t = time
		_p = player
		villains = p_villains
		var fl: float = -INF
		var have_v: bool = false
		for vd: Dictionary in villains:
			if bool(vd.get("alive", true)):
				fl = maxf(fl, float(vd.get("baseS", vd["s"])))
				if not have_v:
					front_v = float(vd.get("vNominal", vd.get("v", jam_speed)))
					have_v = true
		if have_v:
			front_line = fl
		prev_s = s.duplicate()
		prev_x = x.duplicate()
		prev_yaw = yaw.duplicate()
		opp_prev = opp_s.duplicate()
		_ghost_ob.clear()
		for i: int in _moved_x:
			_mask_of(i)
		_moved_x = PackedInt32Array()
		_fresh()
		_in_step = true
		var p_s: float = float(player["s"])
		var p_lane: int = roundi(float(player["lane"]))
		var p_v: float = float(player.get("v", 0.0))
		# random brake
		if not released and _draw() < dt * _brake_rate:
			var cand: Array = []
			for i: int in n:
				if wall[i] == 0 and cheat[i] == 0 and lane_kind_of(lane[i]) != LK_PASS and s[i] > p_s - _brake_behind and s[i] < p_s + _brake_ahead:
					cand.append(i)
			if not cand.is_empty():
				var c: int = cand[int(floor(_draw() * cand.size()))]
				brake_t[c] = _brake_hold_base + _draw() * _brake_hold_span
				_push("brake_wave", ids[c], "random", brake_t[c])
		# stuck assist (R2: native gates on jamLike)
		if not released and jam_like:
			_stuck_assist(dt, player)
		# shoulder cheater event
		if not _has_next_cheater:
			_next_cheater = t + _ch_first_delay
			_has_next_cheater = true
		if allow_events and p_lane == Cfg.SHOULDER_LANE and p_v > _ch_min_player_v and t > _next_cheater:
			_next_cheater = t + _ch_next_base + _draw() * _ch_next_span
			_spawn_cheater_ahead(player)
		# minis act when the player comes up from behind
		if not released and phase_name == "jam":
			for i: int in _minis:
				if mini_done[i] == 1:
					continue
				var ds: float = s[i] - p_s
				if ds < _mini_ds_min or ds > _mini_ds_max:
					continue
				mini_cool[i] -= dt
				if mini_cool[i] > 0.0:
					continue
				var ty: String = _mini_names[mini_type[i]] if mini_type[i] >= 0 and mini_type[i] < _mini_names.size() else ""
				if ty == "cutin":
					if mini_acted[i] < 1 and ds > _cutin_ds_min \
							and lane_blocked(Cfg.SHOULDER_LANE, s[i] - ln[i] / 2.0 - _cutin_margin, s[i] + ln[i] / 2.0 + _cutin_margin, i, player) == 0:
						mini_acted[i] += 1
						cheat[i] = 1
						cheater_v[i] = _cutin_v
						_start_lc(i, Cfg.SHOULDER_LANE, _cutin_lc_dur)
						_push("cutin", ids[i], "mini")
					mini_cool[i] = _cutin_cool
				elif mini_acted[i] < _throw_max:
					mini_acted[i] += 1
					mini_cool[i] = _throw_cool_base + _draw() * _throw_cool_span
					_push("mini_act", ids[i], ty)
		if not released:
			_jam_shape(dt)
		_move(dt, player)
		_in_step = false
		_stepped = true
		# opposite carriageway
		var focus: float = focus_s if not is_nan(focus_s) else p_s
		for k: int in opp_s.size():
			opp_s[k] -= opp_v[k] * dt
			if opp_s[k] < focus - _opp_recycle:
				opp_s[k] = focus + _opp_ahead + _draw() * _opp_span
				opp_prev[k] = opp_s[k]

	## Per-lane leaders + IDM (traffic.js:322 update car loop), cars in spawn order like the C++ `cars` loop (a car
	## moved earlier in the loop is seen at its new s, as in leaderOf's live scan). Read-only per-car arrays are taken
	## as locals (GDScript member reads cost more than local ones); written arrays stay members.
	func _move(dt: float, player: Dictionary) -> void:
		var p_rear: float = float(player["s"]) - float(player.get("len", 4.2)) / 2.0
		var sq_b: float = _idm_b
		var vw: float = front_line - _vw_back - (_vw_zig if zigzag else 0.0)
		# non-car bodies per lane, s ascending (+ their s for bsearch)
		var blk: Array = []
		var blk_s: Array = []
		for l: int in 5:
			var arr: Array = _others(l, player, true)
			if arr.size() > 1:
				arr.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
			var ss := PackedFloat64Array()
			for b: Array in arr:
				ss.append(float(b[0]))
			blk.append(arr)
			blk_s.append(ss)
		var shoved := PackedByteArray()
		shoved.resize(n)
		shoved.fill(0)
		var occ: Array[PackedInt32Array] = _occ
		var home: PackedInt32Array = _home
		var pos: PackedInt32Array = _pos
		var om: PackedInt32Array = _om
		var lnr: PackedFloat64Array = ln
		var wallr: PackedByteArray = wall
		var lkr: PackedInt32Array = lane_kind
		var lane_x0: float = Cfg.lane_x(0)
		var lw: float = Cfg.LANE_W
		var moved_x: PackedInt32Array = _moved_x
		var lf_l := PackedFloat64Array()  # lane-wide stop & go, sin(t*lfFreq + lane*lfLanePhase) (same value per lane)
		for l: int in 5:
			lf_l.append(_lf_base + _lf_amp * (0.5 + 0.5 * sin(t * _lf_freq + l * _lf_phase)))
		for i: int in n:
			var l: int = home[i]
			var si: float = s[i]
			var vi: float = v[i]
			var hl: float = lnr[i] * 0.5
			# release wave
			if rel[i] == 0 and t >= release_at[i]:
				rel[i] = 1
				hazard_until[i] = t + _rel_hazard
				next_lc_at[i] = t + _rel_lc_base + _draw() * _rel_lc_span
				released_count += 1
				_push("released", ids[i])
			var is_rel: bool = rel[i] == 1
			var is_wall: bool = wallr[i] == 1
			var is_ch: bool = cheat[i] == 1
			var li: int = lane[i]
			var lk: int = lkr[li if li < 4 else 3]
			var v0: float
			var T_: float
			var s0: float
			var a_max: float
			if is_rel:
				v0 = v_free[i]
				T_ = _rel_T
				s0 = _rel_s0
				a_max = _rel_a_slow if slow[i] == 1 else _rel_a
			elif is_wall:
				v0 = maxf(0.0, front_v + (front_line + wall_off[i] - wall_back[i] - si) * _wall_follow)
				T_ = _wall_T
				s0 = _wall_s0
				a_max = _wall_a
			elif is_ch:
				v0 = cheater_v[i] if cheater_v[i] != 0.0 else _ch_v0_fb
				T_ = _ch_T
				s0 = _ch_s0
				a_max = _ch_a
			else:
				T_ = _lk_T[lk]
				s0 = _lk_s0[lk]
				a_max = _lk_a[lk]
				if lk == LK_PACKED:
					v0 = jam_speed * personal[i] * lf_l[li] * _lk_mul[lk]
				elif lk == LK_TRAIN:
					v0 = jam_speed * _lk_mul[lk]
				elif lk == LK_PASS:
					v0 = jam_speed * _pass_v * personal[i]
				else:
					v0 = jam_speed * _lk_mul[lk] * personal[i]
			if pull_t[i] > 0.0 and not is_rel:
				pull_t[i] -= dt
				v0 = maxf(v0, jam_speed * (_pull_mul_let_in if boost[i] == 1 else _pull_mul))
				a_max = _pull_a
				T_ = _pull_T
				s0 = _pull_s0
			elif boost[i] != 0:
				boost[i] = 0
			if brake_t[i] > 0.0:
				brake_t[i] -= dt
				v0 = _brake_v0
			# leader (C++ leader_of): per lane the car occupies by x, the first body ahead (smallest s > s_i)
			var has_l: bool = false
			var gap: float = INF
			var lv: float = 0.0
			var lead_player: bool = false
			var limit: float = INF
			var front_i: float = si + hl
			var om_i: int = om[i]
			if om_i == (1 << l):
				# the common case: one lane — the car right ahead in its lane list, or a body (bsearch)
				var best_s: float = INF
				var L: PackedInt32Array = occ[l]
				var j: int = pos[i] - 1
				var steps: int = 0
				while j >= 0 and steps < 6:
					var c: int = L[j]
					if s[c] > si and (om[c] & om_i) != 0:
						best_s = s[c]
						gap = (best_s - lnr[c] * 0.5) - front_i
						lv = v[c]
						has_l = true
						if shoved[c] == 1:
							limit = best_s - lnr[c] * 0.5
						break
					j -= 1
					steps += 1
				var ss: PackedFloat64Array = blk_s[l]
				if not ss.is_empty():
					var bi: int = ss.bsearch(si, false)
					if bi < ss.size() and ss[bi] < best_s:
						var bb: Array = (blk[l] as Array)[bi]
						gap = (ss[bi] - float(bb[1]) * 0.5) - front_i
						lv = float(bb[2])
						has_l = true
						lead_player = int(bb[3]) == T_PLAYER
						limit = p_rear if lead_player else INF
			else:
				# mid lane change: every lane the car occupies by x (C++ leader_of), the smallest gap wins
				for la: int in 5:
					if (om_i & (1 << la)) == 0:
						continue
					var best_s2: float = INF
					var g: float = INF
					var gv: float = 0.0
					var g_player: bool = false
					var g_limit: float = INF
					var L3: PackedInt32Array = occ[la]
					# own lane: walk up from the car's slot; a lane it is crossing into / out of: from the rear end
					var j2: int = (pos[i] if la == l else L3.size()) - 1
					var steps2: int = 0
					while j2 >= 0 and steps2 < 6:
						var c2: int = L3[j2]
						if c2 != i and s[c2] > si and (om[c2] & (1 << la)) != 0:
							best_s2 = s[c2]
							g = (best_s2 - lnr[c2] * 0.5) - front_i
							gv = v[c2]
							if shoved[c2] == 1:
								g_limit = best_s2 - lnr[c2] * 0.5
							break
						j2 -= 1
						if la == l:
							steps2 += 1
					var ss2: PackedFloat64Array = blk_s[la]
					if not ss2.is_empty():
						var bi2: int = ss2.bsearch(si, false)
						if bi2 < ss2.size() and ss2[bi2] < best_s2:
							var bb2: Array = (blk[la] as Array)[bi2]
							best_s2 = ss2[bi2]
							g = (best_s2 - float(bb2[1]) * 0.5) - front_i
							gv = float(bb2[2])
							g_player = int(bb2[3]) == T_PLAYER
							g_limit = p_rear if g_player else INF
					if best_s2 < INF and g < gap:
						has_l = true
						gap = g
						lv = gv
						lead_player = g_player
						limit = g_limit
			var dv: float = vi - lv if has_l else 0.0
			if not is_rel and not is_wall and not is_ch and lk != LK_PASS:
				var g2: float = vw - front_i
				if g2 < gap:
					gap = g2
					dv = vi - front_v
					lv = front_v
			var s_star: float = s0 + maxf(0.0, vi * T_ + (vi * dv) / (2.0 * sqrt(a_max * sq_b)))
			var vr: float = vi / maxf(_v_floor, v0)
			var q: float = s_star / maxf(_gap_floor, gap)
			var acc: float = a_max * (1.0 - vr * vr * vr * vr) - a_max * (q * q)  # JS order (bit parity with C++)
			acc = maxf(_acc_min, minf(a_max, acc))
			vi = maxf(0.0, vi + acc * dt)
			si += vi * dt
			if has_l and gap < _stop_gap and not lead_player:
				vi = minf(vi, maxf(0.0, lv))
			# inside the player (or a car it shoved): back off (TrafficBridge.makes_room)
			if limit < INF and not is_wall and not is_rel:
				var ov: float = si + hl + 0.05 - limit
				if ov > 0.0:
					si -= minf(ov, 14.0 * dt)
					vi = 0.0
					shoved[i] = 1
			s[i] = si
			v[i] = vi
			# lane change progress
			if lc_t[i] < 1.0:
				lc_t[i] = minf(1.0, lc_t[i] + dt / lc_dur[i])
				var e: float = lc_t[i] * lc_t[i] * (3.0 - 2.0 * lc_t[i])
				var xf: float = lane_x0 + lane_from[i] * lw
				var nx: float = xf + ((lane_x0 + li * lw) - xf) * e
				yaw[i] = -atan2((nx - x[i]) / maxf(dt, _lc_dt_floor), maxf(_lc_yaw_min_v, vi)) * _lc_yaw_gain
				x[i] = nx
				if lc_t[i] >= 1.0:
					yaw[i] = 0.0
					blink[i] = 0
					lane_from[i] = li
					if is_ch and li != Cfg.SHOULDER_LANE:
						cheat[i] = 0
					_order_dirty = true
				moved_x.append(i)
			elif is_rel and t > next_lc_at[i]:
				_post_release_lc(i, player)
			elif is_ch and released:
				if _safe_to_enter(i, Cfg.NUM_LANES - 1, _pr_ch_margin, player):
					_start_lc(i, Cfg.NUM_LANES - 1, _pr_ch_lc)
			# lamps: acc for write() (visual only)
			acc_l[i] = acc
			if jolt_t[i] > 0.0:
				jolt_t[i] = maxf(0.0, jolt_t[i] - dt * 3.0)
		_moved_x = moved_x  # their bucket bits are refreshed at the next step start (C++ builds buckets there)
		# keep the lane lists sorted (a back-off or a pass can swap neighbours)
		for l: int in 5:
			var L2: PackedInt32Array = _order[l]
			for k: int in range(1, L2.size()):
				if s[L2[k]] > s[L2[k - 1]] + 1e-6:
					_order_dirty = true
					break

	func _start_lc(i: int, to: int, dur: float) -> void:
		blink[i] = 0 if (cheat[i] == 1 or mini[i] == 1) else (1 if to > lane[i] else -1)
		lane_from[i] = lane[i]
		lane[i] = to
		lc_t[i] = 0.0
		lc_dur[i] = dur
		_order_dirty = true

	func _post_release_lc(i: int, player: Dictionary) -> void:
		next_lc_at[i] = t + _pr_next_base + _draw() * _pr_next_span
		if lane[i] == Cfg.SHOULDER_LANE:
			return
		if slow[i] == 1:
			var tl: int = lane[i] + 1
			if tl <= Cfg.NUM_LANES - 1 and _safe_to_enter(i, tl, _pr_slow_margin, player):
				_start_lc(i, tl, _pr_slow_lc)
			return
		var L: Array = _car_leader(i, player)
		if not L.is_empty() and float(L[0]) < _pr_look_gap and float(L[1]) < v_free[i] - _pr_v_margin and lane[i] > 0:
			if _safe_to_enter(i, lane[i] - 1, _pr_pass_margin, player):
				_start_lc(i, lane[i] - 1, _pr_pass_lc)

	## [gap, v] of the nearest body ahead of car i in its lane, [] = none.
	func _car_leader(i: int, player: Dictionary) -> Array:
		_fresh()
		var l: int = lane[i]
		var best_s: float = INF
		var gap: float = INF
		var lv: float = 0.0
		for j: int in _occ[l]:
			if j != i and s[j] > s[i] and s[j] < best_s and _ox(j, l):
				best_s = s[j]
				gap = (s[j] - ln[j] / 2.0) - (s[i] + ln[i] / 2.0)
				lv = v[j]
		for b: Array in _others(l, player, true):
			if float(b[0]) > s[i] and float(b[0]) < best_s:
				best_s = float(b[0])
				gap = (float(b[0]) - float(b[1]) / 2.0) - (s[i] + ln[i] / 2.0)
				lv = float(b[2])
		return [] if best_s == INF else [gap, lv]

	## [gap, v, is_player] of the body with the smallest centre s ahead of car i in lane l (bucket semantics), [] = none.
	func _lane_leader(i: int, l: int, player: Dictionary) -> Array:
		var best_s: float = INF
		var out: Array = []
		var front_i: float = s[i] + ln[i] / 2.0
		for j: int in _occ[l]:
			if j != i and s[j] > s[i] and s[j] < best_s and _ox(j, l):
				best_s = s[j]
				out = [(s[j] - ln[j] / 2.0) - front_i, v[j], false]
		for b: Array in _others(l, player, true):
			if float(b[0]) > s[i] and float(b[0]) < best_s:
				best_s = float(b[0])
				out = [(float(b[0]) - float(b[1]) / 2.0) - front_i, float(b[2]), int(b[3]) == T_PLAYER]
		return out

	## traffic.js:496 _stuckAssist.
	func _stuck_assist(dt: float, p: Dictionary) -> void:
		var mode_jam: bool = str(p.get("mode", "jam")) == "jam"
		if float(p.get("v", 0.0)) < _stuck_v_below and mode_jam:
			_stuck_t += dt
			_stuck_for += dt
		else:
			_stuck_t = maxf(0.0, _stuck_t - dt * _stuck_decay)
			_stuck_for = 0.0
		if _stuck_t < rubber:
			return
		_stuck_t = 0.0
		var pl: int = roundi(float(p["lane"]))
		var tl: int = Cfg.NUM_LANES - 1 if pl == Cfg.SHOULDER_LANE else mini(Cfg.SHOULDER_LANE, pl + 1)
		if tl == Cfg.SHOULDER_LANE and shoulder_closed:
			tl = pl - 1 if pl == Cfg.NUM_LANES - 1 else tl - 1
		var force: bool = not gap_check or _stuck_for > rubber_safety
		var p_s: float = float(p["s"])
		var p_len: float = float(p.get("len", 4.2))
		if force or has_gap(tl, p_s, p_len, -1, p):
			let_in(tl, p_s, p_len, true, -1, p)
		elif pl < Cfg.SHOULDER_LANE and _stuck_for > _stuck_pull_after:
			_pull_ahead(p)
		assists += 1
		if pl >= Cfg.NUM_LANES - 1:
			for k: int in obstacles.size():
				var od: Dictionary = obstacles[k]
				var half: float = float(od["len"]) / 2.0
				if not bool(od.get("smash", false)) and float(od["s"]) - half < p_s + _tow_ahead and float(od["s"]) + half > p_s - _tow_behind:
					var oid: int = int(od["id"])
					_stuck_n[oid] = int(_stuck_n.get(oid, 0)) + 1
					if int(_stuck_n[oid]) >= _auto_tow_after:
						_ghost_ob.append(od)
						obstacles.remove_at(k)
						_push("auto_tow", oid)
					break

	func _pull_ahead(p: Dictionary) -> void:
		var pl: int = roundi(float(p["lane"]))
		if pl < 0 or pl > 4:
			return
		_fresh()
		for i: int in _occ[pl]:
			if wall[i] == 1 or rel[i] == 1 or not _ox(i, pl):
				continue
			var d: float = s[i] - float(p["s"])
			if d > 0.0 and d < _pa_range:
				pull_t[i] = maxf(pull_t[i], _pa_hold)

	## traffic.js:571 _hasGap: a slot of who_len + 1 m in lane l within ±6 m of who_s (who = the player when who_idx < 0).
	func has_gap(l: int, who_s: float, who_len: float, who_idx: int, p: Dictionary) -> bool:
		if l < 0 or l > 4:
			return false
		_fresh()
		var need: float = (who_len if who_len != 0.0 else _gap_len_fb) + _gap_extra
		var a_s: float = INF
		var a_rear: float = INF
		var b_s: float = -INF
		var b_front: float = -INF
		for i: int in _occ[l]:
			if i == who_idx or not _ox(i, l):
				continue
			if s[i] >= who_s:
				if s[i] < a_s:
					a_s = s[i]
					a_rear = s[i] - ln[i] / 2.0
			elif s[i] > b_s:
				b_s = s[i]
				b_front = s[i] + ln[i] / 2.0
		for b: Array in _others(l, p, who_idx >= 0):
			var bs: float = float(b[0])
			if bs >= who_s:
				if bs < a_s:
					a_s = bs
					a_rear = bs - float(b[1]) / 2.0
			elif bs > b_s:
				b_s = bs
				b_front = bs + float(b[1]) / 2.0
		if a_rear - b_front < need:
			return false
		return a_rear > who_s - _gap_window and b_front < who_s + _gap_window

	## traffic.js:615 letIn: cars in lane l ahead of who (-3.5 … 22 m) pull away 2.2 s (×3.6 jamSpeed), cars behind
	## (-14 … -3.5 m) brake 2.2 s and yield 2.8 s (can_merge lets the player overlap them ≤ 1.3 m). Returns the rearmost
	## car index it moved (-1 = none).
	func let_in(l: int, who_s: float, who_len: float, force: bool, who_idx: int, p: Dictionary) -> int:
		if gap_check and not force and not has_gap(l, who_s, who_len, who_idx, p):
			return -1
		if l < 0 or l > 4:
			return -1
		_fresh()
		var who: int = -1
		for i: int in _occ[l]:
			if wall[i] == 1 or rel[i] == 1 or not _ox(i, l):  # who itself is not skipped (traffic.js letIn)
				continue
			var d: float = s[i] - who_s
			if d > _li_ahead_min and d < _li_ahead_max:
				pull_t[i] = maxf(pull_t[i], _li_pull)
				boost[i] = 1
				who = i
			elif d <= _li_ahead_min and d > _li_behind_max:
				brake_t[i] = maxf(brake_t[i], _li_brake)
				yield_until[i] = t + _li_yield_for
				who = i
		return who

	func _spawn_cheater_ahead(p: Dictionary) -> void:
		var p_s: float = float(p["s"])
		var cands: Array = []
		for i: int in n:
			var d: float = s[i] - p_s
			if lane[i] == Cfg.NUM_LANES - 1 and wall[i] == 0 and rel[i] == 0 and lc_t[i] >= 1.0 and d > _ch_win_min and d < _ch_win_max:
				cands.append(i)
		if cands.is_empty():
			return
		var c: int = cands[int(floor(_draw() * cands.size()))]
		if lane_blocked(Cfg.SHOULDER_LANE, s[c] - ln[c] / 2.0 - _ch_block_margin, s[c] + ln[c] / 2.0 + _ch_block_margin, c, p) != 0:
			return
		cheat[c] = 1
		cheater_v[c] = _ch_v_base + _draw() * _ch_v_span
		_start_lc(c, Cfg.SHOULDER_LANE, _ch_lc_dur)
		_push("cutin", ids[c], "cheater")

	## traffic.js:529 _updateJamShape: brake waves running back up a lane + jamShape.sources (yield pockets).
	func _jam_shape(dt: float) -> void:
		for wi: int in range(_waves.size() - 1, -1, -1):
			var w: Dictionary = _waves[wi]
			w["s"] = float(w["s"]) - float(w["speed"]) * dt
			w["life"] = float(w["life"]) - dt
			if float(w["life"]) <= 0.0 or float(w["strength"]) < _wave_min:
				_waves.remove_at(wi)
				continue
			var hit: Dictionary = w["hit"]
			for i: int in _occ[int(w["lane"])]:
				if rel[i] == 1 or wall[i] == 1 or hit.has(i) or not _ox(i, int(w["lane"])):
					continue
				if absf(s[i] - float(w["s"])) < ln[i] / 2.0 + _wave_margin:
					hit[i] = true
					brake_t[i] = maxf(brake_t[i], float(w["hold"]) * minf(_wave_cap, float(w["strength"])))
					w["strength"] = float(w["strength"]) * float(w["amp"])
		if _sources.is_empty():
			return
		var vs: float = NAN
		for vd: Dictionary in villains:
			if bool(vd.get("alive", true)):
				vs = float(vd["s"])
				break
		if is_nan(vs):
			return
		_jam_src_t -= dt
		for S: Dictionary in _sources:
			if str(S["type"]) == "yield" and _jam_src_t <= 0.0:
				var l: int = int(S["lane"])
				if l < 0 or l > 4:
					continue
				var best: int = -1
				for i: int in _occ[l]:
					if wall[i] == 0 and rel[i] == 0 and yielded[i] == 0 and brake_t[i] <= 0.0 and s[i] > vs - _ys_behind and s[i] < vs + _ys_ahead \
							and _ox(i, l):
						if best < 0 or s[i] > s[best]:
							best = i
				if best >= 0:
					brake_t[best] = float(S["hold"])
					yielded[best] = 1
					emit_brake_wave(l, s[best] - ln[best] / 2.0 - _ys_wave_off, _ys_wave_str, _ys_wave_amp)
		if _jam_src_t <= 0.0:
			_jam_src_t = float(_sources[0]["period"])

	func emit_brake_wave(l: int, ws: float, strength: float, amp: float = NAN) -> void:
		if l < 0 or l >= Cfg.NUM_LANES:
			return
		_waves.append({"lane": l, "s": ws, "strength": strength, "amp": _wave_amp if is_nan(amp) else amp, "speed": _wave_speed,
			"hold": _wave_hold, "life": _wave_life, "hit": {}})
		_push("brake_wave", 0, "wave", ws)

	func release(time: float, open_lane: int = 0) -> void:
		released = true
		var ws: float = _rel_wave_speed
		for i: int in n:
			var lane_delay: float = minf(_rel_lane_cap, absf(float(mini(3, lane[i]) - open_lane))) * _rel_lane_delay
			release_at[i] = time + maxf(0.0, front_line - s[i]) / ws + lane_delay + (_rel_wall_extra if wall[i] == 1 else _rel_car_extra)
			v_free[i] = (_truck_lo + _draw() * (_truck_hi - _truck_lo)) if slow[i] == 1 else (_rel_lo + _draw() * (_rel_hi - _rel_lo))

	# --- queries --------------------------------------------------------------------------------------

	## traffic.js:634 _safeToEnter (the player and the other bodies count).
	func _safe_to_enter(i: int, l: int, margin: float, p: Dictionary) -> bool:
		if l < 0 or l > 4:
			return true
		_fresh()
		var cf: float = s[i] + ln[i] / 2.0
		var cr: float = s[i] - ln[i] / 2.0
		for j: int in _occ[l]:
			if j == i or not _ox(j, l):
				continue
			var ahead: float = (s[j] - ln[j] / 2.0) - cf
			var behind: float = cr - (s[j] + ln[j] / 2.0)
			if ahead > _safe_touch and ahead < margin:
				return false
			if behind > _safe_touch and behind < margin + maxf(0.0, v[j] - v[i]) * _safe_gain:
				return false
			if ahead <= _safe_touch and behind <= _safe_touch:
				return false
		for b: Array in _others(l, p, true):
			var ahead2: float = (float(b[0]) - float(b[1]) / 2.0) - cf
			var behind2: float = cr - (float(b[0]) + float(b[1]) / 2.0)
			if ahead2 > _safe_touch and ahead2 < margin:
				return false
			if behind2 > _safe_touch and behind2 < margin + maxf(0.0, float(b[2]) - v[i]) * _safe_gain:
				return false
			if ahead2 <= _safe_touch and behind2 <= _safe_touch:
				return false
		return true

	## The body ahead of `probe` in lane l with the nearest rear (player excluded): {gap, id, type, idx (car index or -1)}.
	func _gap_ahead(l: int, probe: float) -> Dictionary:
		var best: float = INF
		var who: int = 0
		var typ: String = ""
		var idx: int = -1
		if l >= 0 and l <= 4:
			_fresh()
			for i: int in _occ[l]:
				var rear: float = s[i] - ln[i] / 2.0
				if rear > probe and rear - probe < best and _ox(i, l):
					best = rear - probe
					who = ids[i]
					typ = "car"
					idx = i
			for b: Array in _others(l, _p, false):
				var rb: float = float(b[0]) - float(b[1]) / 2.0
				if rb > probe and rb - probe < best:
					best = rb - probe
					who = int(b[4])
					typ = str(TYPE_NAMES[int(b[3])])
					idx = -1
		return {"gap": best, "id": who, "type": typ, "idx": idx}

	func gap_ahead(l: int, probe: float) -> Dictionary:
		var g: Dictionary = _gap_ahead(l, probe)
		return {"gap": g["gap"], "id": g["id"], "type": g["type"]}

	## leader_of(player): per lane the player occupies (x), the body with the smallest centre s ahead of the player's
	## centre; gap = its rear − the player's nose (may be < 0). {id, gap, type, v, smash}.
	func leader(p: Dictionary) -> Dictionary:
		_p = p
		_fresh()
		var p_s: float = float(p["s"])
		var nose: float = p_s + float(p.get("len", 4.2)) / 2.0
		var out: Dictionary = {"id": 0, "gap": INF, "type": "", "v": 0.0, "smash": false}
		for l: int in 5:
			if not _p_occupies(p, l):
				continue
			var best_s: float = INF
			var g: float = INF
			var id: int = 0
			var typ: String = ""
			var lv: float = 0.0
			for i: int in _occ[l]:
				if s[i] > p_s and s[i] < best_s and _ox(i, l):
					best_s = s[i]
					g = (s[i] - ln[i] / 2.0) - nose
					id = ids[i]
					typ = "car"
					lv = v[i]
			for b: Array in _others(l, p, false):
				if float(b[0]) > p_s and float(b[0]) < best_s:
					best_s = float(b[0])
					g = (float(b[0]) - float(b[1]) / 2.0) - nose
					id = int(b[4])
					typ = str(TYPE_NAMES[int(b[3])])
					lv = float(b[2])
			if typ != "" and g < float(out["gap"]):
				out = {"id": id, "gap": g, "type": typ, "v": lv, "smash": false}
		if str(out["type"]) == "obstacle":
			for o: Variant in obstacles + _ghost_ob:
				if int((o as Dictionary)["id"]) == int(out["id"]):
					out["smash"] = bool((o as Dictionary).get("smash", false))
		return out

	## traffic.js canMergeInto: 0 = free, else the blocker id. A car yielding (let-in) behind the player that overlaps it
	## by < 1.3 m does not block.
	func can_merge(l: int, p: Dictionary, margin: float) -> int:
		if l < 0 or l > 4:
			return -1
		_p = p
		_fresh()
		var p_s: float = float(p["s"])
		var half: float = float(p.get("len", 4.2)) / 2.0
		var lo: float = p_s - half - margin
		var hi: float = p_s + half + margin
		for i: int in _occ[l]:
			var f: float = s[i] + ln[i] / 2.0
			var r: float = s[i] - ln[i] / 2.0
			if f <= lo or r >= hi or not _ox(i, l):
				continue
			if yield_until[i] > t and s[i] < p_s and f - (p_s - half) < _merge_yield_overlap:
				continue
			return ids[i]
		for b: Array in _others(l, p, false):
			var bf: float = float(b[0]) + float(b[1]) / 2.0
			var br: float = float(b[0]) - float(b[1]) / 2.0
			if bf <= lo or br >= hi:
				continue
			return int(b[4])
		return 0

	## Any body overlapping (s_min, s_max) in lane l → its id (the player = -1 when p is given and it occupies l), else 0.
	func lane_blocked(l: int, s_min: float, s_max: float, exclude_idx: int, p: Variant) -> int:
		if l < 0 or l > 4:
			return 0
		_fresh()
		for i: int in _occ[l]:
			if i == exclude_idx or not _ox(i, l):
				continue
			if s[i] + ln[i] / 2.0 > s_min and s[i] - ln[i] / 2.0 < s_max:
				return ids[i]
		var pd: Dictionary = p if p is Dictionary else _p
		for b: Array in _others(l, pd, p is Dictionary):
			if float(b[0]) + float(b[1]) / 2.0 > s_min and float(b[0]) - float(b[1]) / 2.0 < s_max:
				return int(b[4])
		return 0

	## traffic.js:654 honk (the bridge answers set_extras() bodies first).
	func honk(p: Dictionary, siren: bool, trot: bool) -> Dictionary:
		_p = p
		var pl: int = roundi(float(p["lane"]))
		if pl < 0 or pl > 4:
			return {"kind": "", "id": 0}
		var p_s: float = float(p["s"])
		var p_len: float = float(p.get("len", 4.2))
		var rng_m: float = _honk_range_siren if siren else (_honk_range_trot if trot else _honk_range)
		var ga: Dictionary = _gap_ahead(pl, p_s + p_len / 2.0 - _honk_probe)
		var typ: String = str(ga["type"])
		var gap: float = float(ga["gap"])
		var wi: int = int(ga["idx"])
		if typ == "villain" and gap < _honk_villain:
			return {"kind": "villain", "id": int(ga["id"])}
		if pl == Cfg.SHOULDER_LANE:
			if typ == "car" and cheat[wi] == 1 and lc_t[wi] >= 1.0 and lane[wi] == Cfg.SHOULDER_LANE \
					and gap < (_honk_cheater_siren if siren else _honk_cheater):
				let_in(Cfg.NUM_LANES - 1, s[wi], ln[wi], true, wi, p)
				_start_lc(wi, Cfg.NUM_LANES - 1, _honk_cheater_lc)
				cheater_v[wi] = 0.0
				return {"kind": "cheater", "id": ids[wi]}
			if typ == "obstacle" and gap < rng_m:
				var c: int = let_in(Cfg.NUM_LANES - 1, p_s, p_len, false, -1, p)
				return {"kind": "letin" if c >= 0 else "noway", "id": ids[c] if c >= 0 else int(ga["id"])}
			return {"kind": "", "id": 0}
		if typ == "" or gap > rng_m - _honk_slack or (typ == "car" and rel[wi] == 1):
			return {"kind": "", "id": 0}
		if fatigue and typ == "car":
			if honk_t[wi] != 0.0 and t - honk_t[wi] > _fat_relax:
				honk_n[wi] = maxi(0, honk_n[wi] - 1)
			honk_n[wi] += 1
			honk_t[wi] = t
			if honk_n[wi] >= _fat_ignore_at or (honk_n[wi] == 2 and _draw() < _fat_half_p):
				return {"kind": "tired", "id": ids[wi]}
		if typ == "car" and wall[wi] == 0 and lc_t[wi] >= 1.0:
			for tl: int in [lane[wi] - 1, lane[wi] + 1]:
				if tl < 0 or tl >= Cfg.NUM_LANES:
					continue
				if _safe_to_enter(wi, tl, _honk_yield_margin, p):
					_start_lc(wi, tl, _honk_yield_lc)
					return {"kind": "yield", "id": ids[wi]}
		var c2: int = let_in(mini(Cfg.SHOULDER_LANE, pl + 1), p_s, p_len, false, -1, p)
		return {"kind": "letin" if c2 >= 0 else "noway", "id": ids[c2] if c2 >= 0 else int(ga["id"])}

	## traffic.js:697 rageHorn: shoulder obstacles in [p.s - 2, p.s + range] smashed (cones / debris) or towed (tow_ok),
	## cheaters / shoulder cars sent back to lane 3 (let-in), cars in lanes 2-3 startled (brake 0.5 s).
	func rage_horn(p: Dictionary, range_m: float, tow_ok: bool) -> Dictionary:
		_p = p
		var smashed := PackedInt32Array()
		var towed := PackedInt32Array()
		var chs := PackedInt32Array()
		var startled := PackedInt32Array()
		var s0: float = float(p["s"]) - _rage_behind
		var s1: float = float(p["s"]) + range_m
		var keep: Array = []
		for o: Variant in obstacles:
			var od: Dictionary = o
			var os: float = float(od["s"])
			var sm: bool = bool(od.get("smash", false))
			if os < s0 or os > s1 or not (sm or tow_ok):
				keep.append(od)
			elif sm:
				smashed.append(int(od["id"]))
				_ghost_ob.append(od)
			else:
				towed.append(int(od["id"]))
				_ghost_ob.append(od)
		obstacles = keep
		for i: int in n:
			if rel[i] == 1 or s[i] < s0 or s[i] > s1:
				continue
			if (cheat[i] == 1 or lane[i] == Cfg.SHOULDER_LANE) and lc_t[i] >= 1.0:
				let_in(Cfg.NUM_LANES - 1, s[i], ln[i], true, i, p)
				_start_lc(i, Cfg.NUM_LANES - 1, _rage_lc)
				cheater_v[i] = 0.0
				chs.append(ids[i])
			elif lane[i] >= Cfg.NUM_LANES - 2 and wall[i] == 0:
				jolt_t[i] = 1.0
				brake_t[i] = maxf(brake_t[i], _rage_hold)
				startled.append(ids[i])
		return {"smashed": smashed, "towed": towed, "cheaters": chs, "startled": startled}

	func mini_target(p: Dictionary) -> int:
		var best: int = 0
		var bd: float = INF
		var p_s: float = float(p["s"])
		var p_x: float = float(p.get("x", Cfg.lane_x(roundi(float(p["lane"])))))
		for i: int in _minis:
			if mini_done[i] == 1:
				continue
			var ds: float = s[i] - p_s
			if ds < _mt_behind or ds > _mt_ahead:
				continue
			if absf(x[i] - p_x) > Cfg.LANE_W * _mt_lateral:
				continue
			if ds < bd:
				bd = ds
				best = ids[i]
		return best

	## traffic.js:737 miniHit: "" | "hit" | "down" (a downed cutin mini on the shoulder goes back to lane 3).
	func mini_hit(id: int, dmg: float) -> String:
		var i: int = id - 1
		if i < 0 or i >= n or mini[i] == 0 or mini_done[i] == 1:
			return ""
		mini_hp[i] -= dmg
		jolt_t[i] = _mh_jolt
		if mini_hp[i] > 0.0:
			return "hit"
		mini_done[i] = 1
		brake_t[i] = _mh_brake
		hazard_until[i] = t + _mh_hazard
		if cheat[i] == 1 and lane[i] == Cfg.SHOULDER_LANE:
			let_in(Cfg.NUM_LANES - 1, s[i], ln[i], false, i, _p)
			_start_lc(i, Cfg.NUM_LANES - 1, _mh_lc)
			cheater_v[i] = 0.0
		lamp[i] = lamp[i] & ~LAMP_MINI
		return "down"

	func cars_behind_front(cnt: int, range_m: float) -> PackedInt32Array:
		var out := PackedInt32Array()
		for i: int in n:
			if out.size() >= cnt:
				break
			if rel[i] == 0 and wall[i] == 0 and cheat[i] == 0 and front_line - s[i] < range_m and front_line - s[i] > 0.0:
				out.append(ids[i])
		return out

	func drop_walls(lanes: PackedInt32Array, meters: float) -> void:
		for i: int in n:
			if wall[i] == 1 and lanes.has(lane[i]):
				wall_back[i] = meters

	func jolt(id: int) -> void:
		if id >= 1 and id <= n:
			jolt_t[id - 1] = 1.0

	## Device feedback 2026-10-14 ("갓길 장애물 그냥 통과함"): smashable obstacles go away when hit; the breakdown stays.
	func remove_obstacle(id: int, only_smashable: bool) -> bool:
		for k: int in obstacles.size():
			var od: Dictionary = obstacles[k]
			if int(od["id"]) == id:
				if only_smashable and not bool(od.get("smash", false)):
					return false
				_ghost_ob.append(od)
				obstacles.remove_at(k)
				return true
		return false

	func info() -> Dictionary:
		var lk := PackedStringArray()
		for l: int in 4:
			lk.append(str(LK_NAMES[lane_kind[l]]))
		return {"front_line": front_line, "front_v": front_v, "jam_speed": jam_speed, "s_tail": s_tail, "released": released,
			"released_count": released_count, "zigzag": zigzag, "shoulder_closed": shoulder_closed, "shoulder": shoulder_mode,
			"gap_check": gap_check, "fatigue": fatigue, "rubber": rubber, "rage_horn": rage_horn_m, "night": night,
			"assists": assists, "waves": _waves.size(), "time": t, "lane_kind": lk}

	# --- view side ------------------------------------------------------------------------------------

	## Lamp bits of car i from the last step (traffic.cpp get_buffer: brake, blink, hazard, mini, headlights). Computed
	## when the buffer is read (the view reads once per frame, the sim ticks twice per frame).
	func lamp_bits(i: int) -> int:
		if not _stepped:
			return lamp[i]
		var bits: int = LAMP_HEADLIGHTS if night else 0
		if rel[i] == 0 and (acc_l[i] < _bl_acc or v[i] < _bl_v or brake_t[i] > 0.0 or sin(t * _bl_freq + phase[i]) > _bl_above):
			bits |= LAMP_BRAKE
		if blink[i] < 0:
			bits |= LAMP_BLINK_LEFT
		elif blink[i] > 0:
			bits |= LAMP_BLINK_RIGHT
		if (t < hazard_until[i] and fposmod(t - hazard_until[i], _hz_period) < _hz_on) or (cheat[i] == 1 and int(floor(t * _hz_ch_freq)) % 2 == 0):
			bits |= LAMP_HAZARD
		if mini[i] == 1 and mini_done[i] == 0:
			bits |= LAMP_MINI
		return bits

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
			buf[o + 5] = prev_yaw[i] + (yaw[i] - prev_yaw[i]) * a
			buf[o + 6] = v[i]
			buf[o + 7] = lamp_bits(i)
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
			var yw: float = 0.0
			var sc: float = 1.0
			if id >= OPP_ID_BASE and id - OPP_ID_BASE < opp_s.size():
				var j: int = id - OPP_ID_BASE
				px = Cfg.OPP_LANE_X[opp_j[j]]
				ps = opp_prev[j] + (opp_s[j] - opp_prev[j]) * a
				yw = PI
			elif id >= 1 and id <= n:
				var i: int = id - 1
				px = prev_x[i] + (x[i] - prev_x[i]) * a
				ps = prev_s[i] + (s[i] - prev_s[i]) * a
				yw = prev_yaw[i] + (yaw[i] - prev_yaw[i]) * a
			else:
				sc = 0.0
			var o: int = k * 12
			out[o] = cos(yw) * sc
			out[o + 2] = sin(yw) * sc
			out[o + 3] = px
			out[o + 5] = sc
			out[o + 8] = -sin(yw) * sc
			out[o + 10] = cos(yw) * sc
			out[o + 11] = -ps
		return out

	func specs() -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		for i: int in n:
			out.append({"id": ids[i], "kind": kind[i], "kind_name": kind_names[kind[i]] if kind[i] >= 0 else "",
				"variant": variant[i], "color": color[i], "len": ln[i], "w": wd[i]})
		for k: int in opp_s.size():
			out.append({"id": OPP_ID_BASE + k, "kind": opp_kind[k], "kind_name": kind_names[opp_kind[k]] if opp_kind[k] >= 0 else "",
				"variant": opp_variant[k], "color": opp_color[k], "len": 0.0, "w": 0.0})
		return out

	func _push(ty: String, id: int, data: String = "", value: float = 0.0) -> void:
		if _events.size() < 4096:
			_events.append({"type": ty, "id": id, "data": data, "value": value})

	func take_events() -> Array[Dictionary]:
		var out: Array[Dictionary] = _events
		_events = []
		return out
