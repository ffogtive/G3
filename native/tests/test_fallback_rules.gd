## r3 T1 (unit): the C++ stuck / let-in rules on the GDScript fallback (_Creep), checked on both backends.
## 가설: ✅ the iPhone fallback had no let-in, stuck assist, auto tow or shoulder honk, so every jam was "wait until lane 4
##       happens to open" (device feedback r3 #1/#3). Porting the C++ rules (RNG bits need not match) gives the same
##       answers here: honk at a breakdown → lane 4 opens ≤ 1.5 s, two assists → auto tow, a set_extras() body is a wall.
## Checks (force_fallback ∈ {false, true}; the native half is skipped without the ext):
##   1. honk on the shoulder behind the breakdown → kind letin and can_merge(3) == 0 within 1.5 s (median of 5 seeds,
##      all ≤ 2.2 s, fallback = C++ ± 0.25 s)
##   2. stopped behind the breakdown (mode jam): 2 assists → {type: auto_tow, id} and the obstacle is gone
##   3. set_extras([stopped extra]) on the shoulder / straddling 3·4: a PlayerSim driving at it never passes it;
##      gap_ahead / leader_of_player / can_merge see it (type "extra"), honk at it → {kind: "extra"}
##   4. info(): rage_horn = approach.rageHorn, assists, shoulder fields on both backends
extends RefCounted

const _DB := preload("res://core/db.gd")

var _fails: int = 0


func _check(ok: bool, what: String) -> void:
	print(("PASS" if ok else "FAIL") + " fallback_rules: " + what)
	if not ok:
		_fails += 1


func run() -> int:
	var modes: Array[bool] = [true]
	if TrafficBridge.native_available():
		modes.push_front(false)
	else:
		print("SKIP fallback_rules: C++ Traffic not loaded (native half)")
	for fb: bool in modes:
		var tag: String = "fallback" if fb else "native"
		_honk_letin(fb, tag)
		_auto_tow(fb, tag)
		_extras(fb, tag, false)
		_extras(fb, tag, true)
		_info(fb, tag)
	return _fails


func _stage(id: int) -> Dictionary:
	return _DB.find_stage(_DB.load_json(_DB.DATA_DIR + "/stages.json"), id)


func _breakdown(br: TrafficBridge) -> Dictionary:
	for o: Variant in br.obstacles():
		if str((o as Dictionary).get("kind", "")) == "breakdown":
			return o
	return {}


## Steps the bridge with a parked player state for `secs`; returns the events.
func _hold(br: TrafficBridge, p: Dictionary, secs: float, t0: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var n: int = roundi(secs / Cfg.TICK)
	for i: int in n:
		p["time"] = t0 + (i + 1) * Cfg.TICK
		br.step(Cfg.TICK, p)
		out.append_array(br.events())
	return out


## Opened time (s) after a honk from the shoulder 3 m behind the 1-1 breakdown with a lane-4 car alongside, -1 = not
## within 2.5 s; also returns the honk kind and the blocker before the honk.
func _honk_open(fb: bool, seed: int) -> Dictionary:
	var stage: Dictionary = _stage(1)
	var br := TrafficBridge.new()
	br.setup(stage, _DB.load_traffic_tables(), seed, fb)
	var bd: Dictionary = _breakdown(br)
	if bd.is_empty():
		return {"open": -1.0, "kind": "no breakdown", "blocked": 0}
	var si: Dictionary = br.setup_info()
	var p: Dictionary = {"lane": float(si["start_lane"]), "s": float(si["start_s"]), "v": 0.0, "x": Cfg.lane_x(int(si["start_lane"])),
		"len": 4.2, "w": 1.92, "mode": "test"}
	var t: float = 0.0
	_hold(br, p, 1.0, t)
	t += 1.0
	# park on the shoulder 3 m behind the breakdown, alongside a lane-4 car (lane 4 blocked)
	p["lane"] = 4.0
	p["x"] = Cfg.lane_x(4)
	p["s"] = float(bd["s"]) - float(bd["len"]) / 2.0 - 2.1 - 3.0
	br.sync_player(p)
	_hold(br, p, 0.25, t)
	t += 0.25
	var blocked0: int = br.can_merge(3, 0.35)
	if blocked0 == 0:
		# slide back along lane 3 until a car is alongside (still within honk range of the breakdown)
		for k: int in 12:
			p["s"] = float(p["s"]) - 1.0
			br.sync_player(p)
			blocked0 = br.can_merge(3, 0.35)
			if blocked0 != 0:
				break
	var h: Dictionary = br.honk(4, float(p["s"]))
	var opened_at: float = -1.0
	for i: int in roundi(2.5 / Cfg.TICK):
		p["time"] = t + (i + 1) * Cfg.TICK
		br.step(Cfg.TICK, p)
		br.events()
		if br.can_merge(3, 0.35) == 0:
			opened_at = (i + 1) * Cfg.TICK
			break
	return {"open": opened_at, "kind": str(h.get("kind", "")), "blocked": blocked0}


## Gate: every honk is a letin with lane 4 blocked before it; lane 4 opens with a median ≤ 1.5 s and always within the
## 2.2 s pull (a car alongside just behind the player needs ~5 m to clear: C++ takes 1.9-2.1 s on seeds 3 / 5 too);
## the fallback opens within ±0.25 s of C++ on every seed.
func _honk_letin(fb: bool, tag: String) -> void:
	var detail: PackedStringArray = []
	var fast: int = 0
	var all_ok: bool = true
	var opens: Array[float] = []
	var seeds: Array[int] = [1007, 3, 11, 5, 42]
	for seed: int in seeds:
		var r: Dictionary = _honk_open(fb, seed)
		var op: float = float(r["open"])
		var good: bool = int(r["blocked"]) != 0 and str(r["kind"]) == "letin" and op >= 0.0 and op <= 2.2
		if fb and TrafficBridge.native_available():
			var nat: Dictionary = _honk_open(false, seed)
			good = good and absf(float(nat["open"]) - op) <= 0.25
			detail.append("s%d %s %.2fs (C++ %.2fs)" % [seed, str(r["kind"]), op, float(nat["open"])])
		else:
			detail.append("s%d %s %.2fs" % [seed, str(r["kind"]), op])
		fast += 1 if good and op <= 1.5 else 0
		all_ok = all_ok and good
		opens.append(op if op >= 0.0 else INF)
	opens.sort()
	var median: float = opens[opens.size() / 2]
	_check(all_ok and median <= 1.5, "%s: honk behind the 1-1 breakdown → letin, can_merge(3)==0 median %.2f s ≤ 1.5 s (%d/%d seeds ≤ 1.5 s), all ≤ 2.2 s (%s)" % [
		tag, median, fast, seeds.size(), ", ".join(detail)])


func _auto_tow(fb: bool, tag: String) -> void:
	var stage: Dictionary = _stage(1)
	var br := TrafficBridge.new()
	br.setup(stage, _DB.load_traffic_tables(), 1007, fb)
	var bd: Dictionary = _breakdown(br)
	if bd.is_empty():
		_check(false, "%s: stage 1 has a breakdown" % tag)
		return
	var si: Dictionary = br.setup_info()
	var p: Dictionary = {"lane": 4.0, "s": float(bd["s"]) - float(bd["len"]) / 2.0 - 2.1 - 1.0, "v": 0.0, "x": Cfg.lane_x(4),
		"len": 4.2, "w": 1.92, "mode": "jam"}
	br.set_phase("jam", true, true)
	var tow_id: int = 0
	var tow_t: float = -1.0
	var t: float = 0.0
	for i: int in roundi(5.0 / Cfg.TICK):
		t = (i + 1) * Cfg.TICK
		p["time"] = t
		br.step(Cfg.TICK, p)
		for e: Dictionary in br.events():
			if str(e.get("type", "")) == "auto_tow" and tow_id == 0:
				tow_id = int(e.get("id", 0))
				tow_t = t
		if tow_id != 0:
			break
	var gone: bool = true
	for o: Variant in br.obstacles():
		if int((o as Dictionary)["id"]) == int(bd["id"]):
			gone = false
	var assists: int = int(br.info().get("assists", 0))
	_check(tow_id == int(bd["id"]) and gone and assists >= 2,
		"%s: parked behind the breakdown, 2 assists → auto_tow (id %d want %d at %.2fs, assists %d, removed %s)" % [tag, tow_id, int(bd["id"]), tow_t, assists, gone])


## A PlayerSim driving into a stopped extra (shoulder, or straddling lanes 3·4 when straddle) never passes it.
func _extras(fb: bool, tag: String, straddle: bool) -> void:
	var stage: Dictionary = _stage(4 if straddle else 1)
	var tables: Dictionary = _DB.load_traffic_tables()
	var br := TrafficBridge.new()
	br.setup(stage, tables, 1007, fb)
	if not br.has_method(&"set_extras"):
		_check(false, "%s: TrafficBridge.set_extras exists" % tag)
		return
	var si: Dictionary = br.setup_info()
	var kinds: Dictionary = (tables["vehicle_kinds"] as Dictionary).get("kinds", {})
	var pl := PlayerSim.new()
	pl.setup(tables["config"].get("tune", {}), TrafficBridge.kind_dims(kinds.get("player", {}), -1, 0, true))
	# the player drives up the shoulder; the extra sits 22 m ahead (before the first shoulder item at start + 38 m)
	var lane: int = 4
	pl.reset(float(si["start_s"]), lane)
	var ex_x: float = (Cfg.lane_x(3) + Cfg.lane_x(4)) * 0.5 if straddle else Cfg.lane_x(4)
	var ex: Dictionary = {"s": pl.s + 22.0, "x": ex_x, "w": 1.9, "len": 4.5, "v": 0.0, "alive": true, "kind": "plug"}
	br.set_extras([ex])
	var t: float = 0.0
	var worst: float = -INF
	var passed: int = 0
	var leader_type: String = ""
	var leader_cb: Callable = func() -> Dictionary:
		br.sync_player(pl.traffic_state(t))
		return br.leader_of_player()
	for i: int in roundi(8.0 / Cfg.TICK):
		t = (i + 1) * Cfg.TICK
		br.set_extras([ex])
		pl.update(Cfg.TICK, {"mode": &"jam", "leader": leader_cb})
		br.step(Cfg.TICK, pl.traffic_state(t))
		br.events()
		var nose: float = pl.s + pl.len / 2.0
		worst = maxf(worst, nose - (float(ex["s"]) - float(ex["len"]) / 2.0))
		if pl.s > float(ex["s"]):
			passed += 1
	br.sync_player(pl.traffic_state(t))
	var L: Dictionary = br.leader_of_player()
	leader_type = str(L.get("type", ""))
	var ga: Dictionary = br.gap_ahead(lane, pl.s + pl.len / 2.0 - 0.5)
	var h: Dictionary = br.honk(lane, pl.s)
	var ok: bool = passed == 0 and worst < 0.25 and leader_type == "extra" and str(ga.get("type", "")) == "extra" \
		and str(h.get("kind", "")) == "extra" and int(h.get("id", 0)) == -1000
	var side_ok: bool = true
	if straddle:
		# alongside the straddling extra, lane 4 is blocked by it
		var p2: Dictionary = {"lane": 3.0, "s": float(ex["s"]), "v": 0.0, "x": Cfg.lane_x(3), "len": 4.2, "w": 1.92, "mode": "jam"}
		br.sync_player(p2)
		side_ok = br.can_merge(4, 0.35) == -1000 and br.lane_blocked(3, float(ex["s"]) - 1.0, float(ex["s"]) + 1.0) != 0
		br.sync_player(pl.traffic_state(t))
	_check(ok and side_ok, "%s: stopped extra %s is never passed (worst nose %.2f m, passed %d ticks, leader %s, gap_ahead %s %.1f, honk %s/%d, side %s)" % [
		tag, "straddling 3·4 (1-4)" if straddle else "on the shoulder (1-1)", worst, passed, leader_type, str(ga.get("type", "")),
		float(ga.get("gap", INF)), str(h.get("kind", "")), int(h.get("id", 0)), side_ok])


func _info(fb: bool, tag: String) -> void:
	for sid: int in [1, 5]:
		var stage: Dictionary = _stage(sid)
		var tables: Dictionary = _DB.load_traffic_tables()
		var br := TrafficBridge.new()
		br.setup(stage, tables, -1, fb)
		var inf: Dictionary = br.info()
		var appr: Dictionary = br.setup_info().get("approach", {})
		var want_rh: float = float(appr.get("rageHorn", 24.0))
		var keys_ok: bool = true
		for k: String in ["front_line", "s_tail", "released", "released_count", "shoulder_closed", "shoulder", "gap_check", "rage_horn", "assists"]:
			keys_ok = keys_ok and inf.has(k)
		_check(keys_ok and is_equal_approx(float(inf.get("rage_horn", -1.0)), want_rh) and str(inf.get("shoulder", "")) == str(appr.get("shoulder", "open")),
			"%s stage %d: info() has rage_horn %.0f (= approach %.0f), assists %s, shoulder '%s'" % [tag, sid, float(inf.get("rage_horn", -1.0)), want_rh,
			str(inf.get("assists", "?")), str(inf.get("shoulder", "?"))])
