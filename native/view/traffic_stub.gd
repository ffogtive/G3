class_name TrafficStub
extends RefCounted
## View-side stand-in for res://sim/traffic_bridge.gd (TrafficBridge) until integration. Same public interface
## (setup / step / count / read_into / events / honk / request_lane / kind_names) so game.gd can swap it out, plus
## the optional view queries car_spec(), obstacles(), villain_states() and time() that TrafficBridge may adopt.
##
## Layout: the exact web spawn of stage 1 from res://tests/golden/spawn_stage1.json when present (dev builds),
## otherwise a seeded procedural jam (exported builds strip tests/). Motion: per-lane follow-the-leader IDM (one
## leader per car, no pairwise search), a stop&go wave on the front row, the web brake-light rule
## (acc < −0.25 ∨ v < 1.6 ∨ sin(1.3 t + φ) > 0.2, traffic.js:462) and scripted lane changes / cut-ins near the
## player so the N5 signal icons have something to show. This is NOT the parity model (that is the C++ Traffic).

const STRIDE: int = 8
const BIT_BRAKE: int = 1
const BIT_BLINK_L: int = 2
const BIT_BLINK_R: int = 4
const BIT_HIGHBEAM: int = 8
const BIT_HAZARD: int = 16
const BIT_HEAD: int = 32
const BIT_VILLAIN: int = 64
const BIT_MINI: int = 128

const KINDS: PackedStringArray = ["sedan", "compact", "suv", "taxi", "van", "pickup1t", "truck", "bus", "villainSedan"]
const GOLDEN_SPAWN: String = "res://tests/golden/spawn_stage%d.json"
const IDM_A: float = 1.1
const IDM_B: float = 2.0
const GAP0: float = 1.6
const HEADWAY: float = 0.9

var _cars: Array[Dictionary] = []      # driving + shoulder + villain + breakdown cars
var _opp: Array[Dictionary] = []
var _obstacles: Array[Dictionary] = []
var _events: Array[Dictionary] = []
var _time: float = 0.0
var _jam_v: float = 2.4
var _rng := RandomNumberGenerator.new()
var _next_script_t: float = 3.0
var _by_id: Dictionary = {}
var _player: Dictionary = {"lane": 3.0, "s": 0.0, "v": 0.0, "x": 5.4}
var _kind_index: Dictionary = {}
var source: String = ""


func setup(stage: Dictionary, cfg: Dictionary, seed: int) -> void:
	_rng.seed = seed
	_time = 0.0
	_cars.clear()
	_opp.clear()
	_obstacles.clear()
	_events.clear()
	_by_id.clear()
	for i: int in KINDS.size():
		_kind_index[KINDS[i]] = i
	var tr: Dictionary = cfg.get("traffic", {}) if cfg.get("traffic") is Dictionary else {}
	_jam_v = float(stage.get("jamSpeed", tr.get("jamSpeed", 2.4))) if stage.get("jamSpeed") != null else 2.4
	var path: String = GOLDEN_SPAWN % int(stage.get("id", 1))
	if FileAccess.file_exists(path):
		_load_golden(path)
		source = "golden:" + path.get_file()
	else:
		_procedural(stage)
		source = "procedural"
	for c: Dictionary in _cars:
		_by_id[int(c["id"])] = c


func _load_golden(path: String) -> void:
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	_jam_v = float((d.get("traffic", {}) as Dictionary).get("jamSpeed", _jam_v))
	for c: Dictionary in d["cars"]:
		var car := _car(int(c["id"]), str(c["kind"]), int(c["variant"]), int(c["color"]), int(c["lane"]), float(c["s"]),
			float(c["v"]), float(c["len"]), float(c["w"]))
		car["front"] = bool(c.get("frontRow", false)) or bool(c.get("isWall", false))
		car["phase"] = float(c.get("phase", 0.0))
		car["mini"] = c.get("mini") != null
		car["cheater"] = bool(c.get("isCheater", false))
		_cars.append(car)
	for v: Dictionary in d["villains"]:
		var vc := _car(1000 + int(v["index"]), str(v["kind"]), 0, int(v["color"]), int(v["lanePos"]), float(v["s"]),
			float(v["v"]), float(v["len"]), float(v["w"]))
		vc["villain"] = true
		vc["front"] = true
		_cars.append(vc)
	for o: Dictionary in d["obstacles"]:
		var det: Dictionary = o.get("detail", {}) if o.get("detail") is Dictionary else {}
		var ob: Dictionary = {"id": int(o["id"]), "kind": str(o["kind"]), "s": float(o["s"]), "x": float(o["x"]),
			"len": float(o["len"]), "detail": det}
		_obstacles.append(ob)
	for o: Dictionary in d["opp"]:
		_opp.append({"id": 2000 + _opp.size(), "kind": str(o["kind"]), "variant": int(o.get("variant", 0)),
			"color": int(o["color"]), "j": int(o["j"]), "s": float(o["s"]), "v": float(o["v"])})


func _procedural(stage: Dictionary) -> void:
	var front: float = float(stage.get("jamLength", 170.0)) + 30.0
	var id: int = 1
	for lane: int in 4:
		var s: float = front
		while s > -45.0:
			var kind: String = KINDS[_rng.randi_range(0, 7)]
			var len_m: float = 11.5 if kind == "bus" else (7.5 if kind == "truck" else 4.6)
			var car := _car(id, kind, 0, [0xf4f4f2, 0x2b2d31, 0x9aa1a9, 0x3b5bd6][_rng.randi_range(0, 3)], lane, s,
				_jam_v, len_m, 1.9)
			car["front"] = s == front
			car["phase"] = _rng.randf() * TAU
			_cars.append(car)
			id += 1
			s -= len_m + 2.0 + _rng.randf() * 4.0
	var vc := _car(1000, "villainSedan", 0, 0xd9c8a3, 0, front + 6.0, _jam_v, 4.9, 1.84)
	vc["villain"] = true
	vc["front"] = true
	_cars.append(vc)
	for j: int in 26:
		_opp.append({"id": 2000 + j, "kind": KINDS[j % 6], "variant": 0, "color": 0x6b7179, "j": j % 3,
			"s": -100.0 + float(j) * 30.0, "v": 26.0})


func _car(id: int, kind: String, variant: int, color: int, lane: int, s: float, v: float, len_m: float, w: float) -> Dictionary:
	return {"id": id, "kind": kind, "variant": variant, "color": color, "lane": lane, "lane_from": lane, "lane_to": lane,
		"lc_t": 1.0, "lc_dur": 1.8, "x": RoadGraph.lane_x(float(lane)), "s": s, "v": v, "a": 0.0, "yaw": 0.0,
		"len": len_m, "w": w, "phase": 0.0, "front": false, "villain": false, "mini": false, "cheater": false,
		"parked": false, "hazard_car": false, "blink": 0, "signal": true, "brake": false, "brake_t": 0.0}


func step(dt: float, player_state: Dictionary) -> void:
	_player = player_state
	_time += dt
	# per-lane leader search on a sorted copy (one sort per tick; insertion order is nearly sorted already)
	var lanes: Array = [[], [], [], [], []]
	for c: Dictionary in _cars:
		if bool(c["parked"]):
			continue
		lanes[clampi(int(c["lane_to"]), 0, 4)].append(c)
		if float(c["lc_t"]) < 1.0 and int(c["lane_from"]) != int(c["lane_to"]):
			lanes[clampi(int(c["lane_from"]), 0, 4)].append(c)
	for c: Dictionary in _cars:
		c["_gap"] = INF
		c["_lv"] = _jam_v
	for arr: Array in lanes:
		arr.sort_custom(func(p: Dictionary, q: Dictionary) -> bool: return float(p["s"]) > float(q["s"]))
		for k: int in range(1, arr.size()):
			var c: Dictionary = arr[k]
			var L: Dictionary = arr[k - 1]
			var g: float = float(L["s"]) - float(L["len"]) * 0.5 - (float(c["s"]) + float(c["len"]) * 0.5)
			if g < float(c["_gap"]):
				c["_gap"] = g
				c["_lv"] = float(L["v"])
	var ps: float = float(_player.get("s", 0.0))
	var plane: int = int(roundf(float(_player.get("lane", 3.0))))
	for c: Dictionary in _cars:
		if bool(c["parked"]):
			continue
		var lane: int = clampi(int(c["lane_to"]), 0, 4)
		var lead_gap: float = float(c["_gap"])
		var lead_v: float = float(c["_lv"])
		# the player is a leader too (cars behind the player in its lane)
		if plane == lane and ps > float(c["s"]):
			var pg: float = ps - 2.1 - (float(c["s"]) + float(c["len"]) * 0.5)
			if pg < lead_gap:
				lead_gap = pg
				lead_v = float(_player.get("v", 0.0))
		var v: float = float(c["v"])
		var v0: float = _jam_v * (1.0 + 0.45 * sin(_time * 0.42 + float(lane) * 1.9 + float(c["phase"]) * 0.2))
		if bool(c["front"]):
			v0 = maxf(0.4, _jam_v * (1.0 + 0.6 * sin(_time * 0.42 + float(lane) * 1.9)))
		var acc: float
		if lead_gap == INF:
			acc = IDM_A * (1.0 - pow(v / maxf(0.1, v0), 4.0))
		else:
			var sstar: float = GAP0 + maxf(0.0, v * HEADWAY + v * (v - lead_v) / (2.0 * sqrt(IDM_A * IDM_B)))
			acc = IDM_A * (1.0 - pow(v / maxf(0.1, v0), 4.0)) - IDM_A * pow(sstar / maxf(0.3, lead_gap), 2.0)
		acc = clampf(acc, -6.0, IDM_A)
		c["a"] = acc
		v = maxf(0.0, v + acc * dt)
		if lead_gap < 0.25:
			v = minf(v, maxf(0.0, lead_v))
		c["v"] = v
		c["s"] = float(c["s"]) + v * dt
		if float(c["brake_t"]) > 0.0:
			c["brake_t"] = float(c["brake_t"]) - dt
		c["brake"] = acc < -0.25 or v < 1.6 or float(c["brake_t"]) > 0.0 or sin(_time * 1.3 + float(c["phase"])) > 0.2
		# lane change progress (smoothstep, web traffic.js:435)
		if float(c["lc_t"]) < 1.0:
			c["lc_t"] = minf(1.0, float(c["lc_t"]) + dt / float(c["lc_dur"]))
			var e: float = float(c["lc_t"]) * float(c["lc_t"]) * (3.0 - 2.0 * float(c["lc_t"]))
			var nx: float = lerpf(RoadGraph.lane_x(float(c["lane_from"])), RoadGraph.lane_x(float(c["lane_to"])), e)
			c["yaw"] = -atan2((nx - float(c["x"])) / maxf(dt, 1e-4), maxf(2.0, v)) * 0.8
			c["x"] = nx
			if float(c["lc_t"]) >= 1.0:
				c["lane"] = c["lane_to"]
				c["yaw"] = 0.0
				c["blink"] = 0
	for o: Dictionary in _opp:
		o["s"] = float(o["s"]) - float(o["v"]) * dt
		if float(o["s"]) < ps - 160.0:
			o["s"] = float(o["s"]) + 520.0
	if _time >= _next_script_t:
		_scripted_lane_change(ps, plane)


## A car 6–30 m ahead of the player moves into the player's lane (1 in 3 without a blinker: the N5 'no-blinker
## cut-in') or, failing that, a car ahead in the player's lane signals and leaves it. Deterministic from the seed.
func _scripted_lane_change(ps: float, plane: int) -> void:
	_next_script_t = _time + 1.6 + _rng.randf() * 1.6
	var into: Array[Dictionary] = []
	var away: Array[Dictionary] = []
	for c: Dictionary in _cars:
		var ds: float = float(c["s"]) - ps
		if ds < 6.0 or ds > 30.0 or float(c["lc_t"]) < 1.0 or bool(c["front"]) or bool(c["parked"]) or bool(c["villain"]):
			continue
		var lane: int = int(c["lane"])
		if lane < 4 and absi(lane - plane) == 1 and _lane_free(plane, float(c["s"]), float(c["len"]), c, -0.4) and absf(float(c["s"]) - ps) > (float(c["len"]) + 4.2) * 0.5 + 1.0:
			into.append(c)
		elif lane == plane:
			for to: int in [plane - 1, plane + 1]:
				if to >= 0 and to <= 3 and _lane_free(to, float(c["s"]), float(c["len"]), c, -0.4):
					away.append({"car": c, "to": to})
					break
	var c: Dictionary
	var to: int
	var signal_on: bool = true
	if not into.is_empty():
		c = into[_rng.randi_range(0, into.size() - 1)]
		to = plane
		signal_on = _rng.randf() > 0.34
	elif not away.is_empty():
		var pick: Dictionary = away[_rng.randi_range(0, away.size() - 1)]
		c = pick["car"]
		to = int(pick["to"])
	else:
		return
	c["lane_from"] = c["lane"]
	c["lane_to"] = to
	c["lc_t"] = 0.0
	c["lc_dur"] = 1.6 if signal_on else 0.9
	c["blink"] = (BIT_BLINK_R if to > int(c["lane"]) else BIT_BLINK_L) if signal_on else 0
	c["signal"] = signal_on
	_events.append({"type": "cutin", "id": int(c["id"]), "data": {"blinker": signal_on, "from": int(c["lane"]), "to": to}})


func _lane_free(lane: int, s: float, len_m: float, self_car: Dictionary, margin: float = 1.2) -> bool:
	for o: Dictionary in _cars:
		if is_same(o, self_car) or bool(o["parked"]):
			continue
		if int(o["lane_to"]) == lane or int(o["lane"]) == lane:
			if absf(float(o["s"]) - s) < (float(o["len"]) + len_m) * 0.5 + margin:
				return false
	return true


func count() -> int:
	return _cars.size() + _opp.size()


func read_into(buf: PackedFloat32Array) -> void:
	var n: int = count()
	if buf.size() != n * STRIDE:
		buf.resize(n * STRIDE)
	var i: int = 0
	for c: Dictionary in _cars:
		var bits: int = int(c["blink"])
		if bool(c["brake"]):
			bits |= BIT_BRAKE
		if bool(c["villain"]):
			bits |= BIT_VILLAIN
		if bool(c["mini"]):
			bits |= BIT_MINI
		if bool(c["hazard_car"]) and int(floorf(_time * 2.0)) % 2 == 0:
			bits |= BIT_HAZARD
		if bool(c["cheater"]) and int(floorf(_time * 2.2)) % 2 == 0:
			bits |= BIT_HAZARD
		var o: int = i * STRIDE
		buf[o] = float(c["id"])
		buf[o + 1] = float(_kind_index.get(c["kind"], 0))
		buf[o + 2] = float(c["lane"])
		buf[o + 3] = float(c["x"])
		buf[o + 4] = float(c["s"])
		buf[o + 5] = float(c["yaw"])
		buf[o + 6] = float(c["v"])
		buf[o + 7] = float(bits)
		i += 1
	for c: Dictionary in _opp:
		var o: int = i * STRIDE
		buf[o] = float(c["id"])
		buf[o + 1] = float(_kind_index.get(c["kind"], 0))
		buf[o + 2] = -1.0 - float(c["j"])
		buf[o + 3] = RoadGraph.opp_lane_x(int(c["j"]))
		buf[o + 4] = float(c["s"])
		buf[o + 5] = PI
		buf[o + 6] = -float(c["v"])
		buf[o + 7] = 0.0
		i += 1


func events() -> Array[Dictionary]:
	var out: Array[Dictionary] = _events.duplicate()
	_events.clear()
	return out


## Stage-1 approach rule (approach.honk = 'yield'): the car directly ahead within 30 m pulls over to the next lane
## if it can, otherwise answers 'noway'. Emits a honk_reply event either way.
func honk(player_lane: int, player_s: float) -> Dictionary:
	var best: Dictionary = {}
	var best_ds: float = 30.0
	for c: Dictionary in _cars:
		if int(c["lane"]) != player_lane or bool(c["parked"]):
			continue
		var ds: float = float(c["s"]) - player_s
		if ds > 0.0 and ds < best_ds:
			best_ds = ds
			best = c
	if best.is_empty():
		return {"kind": "none", "id": -1}
	var kind: String = "noway"
	if not bool(best["villain"]) and not bool(best["front"]) and float(best["lc_t"]) >= 1.0:
		for to: int in [player_lane + 1, player_lane - 1]:
			if to >= 0 and to <= 3 and _lane_free(to, float(best["s"]), float(best["len"]), best):
				best["lane_from"] = player_lane
				best["lane_to"] = to
				best["lc_t"] = 0.0
				best["lc_dur"] = 1.5
				best["blink"] = BIT_BLINK_R if to > player_lane else BIT_BLINK_L
				kind = "yield"
				break
	if kind == "noway":
		best["brake_t"] = 0.8
	var r: Dictionary = {"kind": kind, "id": int(best["id"])}
	_events.append({"type": "honk_reply", "id": int(best["id"]), "data": r})
	return r


func request_lane(player_lane: int, target_lane: int, player_s: float) -> bool:
	if target_lane < 0 or target_lane > 4 or absi(target_lane - player_lane) != 1:
		return false
	for c: Dictionary in _cars:
		if int(c["lane"]) == target_lane or int(c["lane_to"]) == target_lane:
			var half: float = float(c["len"]) * 0.5 + 2.1
			if absf(float(c["s"]) - player_s) < half + 0.8:
				return false
	return true


func kind_names() -> PackedStringArray:
	return KINDS


# ── optional view queries (not in the fixed interface; game.gd checks has_method) ──

## {kind, variant, color, len, w} for a car id (opposite-lane ids included).
func car_spec(id: int) -> Dictionary:
	if _by_id.has(id):
		var c: Dictionary = _by_id[id]
		return {"kind": c["kind"], "variant": c["variant"], "color": c["color"], "len": c["len"], "w": c["w"]}
	for o: Dictionary in _opp:
		if int(o["id"]) == id:
			return {"kind": o["kind"], "variant": o["variant"], "color": o["color"], "len": 4.6, "w": 1.84}
	return {}


func obstacles() -> Array[Dictionary]:
	return _obstacles


func villain_states() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for c: Dictionary in _cars:
		if bool(c["villain"]):
			out.append({"id": c["id"], "s": c["s"], "x": c["x"], "v": c["v"], "kind": c["kind"]})
	return out


func time() -> float:
	return _time


## Test hook: overwrite one car's dynamic state (shot_jam.gd --state= replays a web frame).
func set_car_state(id: int, st: Dictionary) -> void:
	var c: Dictionary = _by_id.get(id, {})
	if c.is_empty():
		return
	for k: String in st:
		c[k] = st[k]


func set_opp_state(index: int, s: float) -> void:
	if index >= 0 and index < _opp.size():
		_opp[index]["s"] = s
