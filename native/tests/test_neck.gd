extends RefCounted
## r3 A1 (approach pace ×0.78) + A2 (bottleneck plug + per-stage valve), both traffic backends (force_fallback false/true).
##
## 가설: ❌ "frontGap 30 m 빈칸" → ✅ the hole behind the villain is the queue's mean target speed (0.84× jamSpeed) being
##       slower than the villain (1.0×); slowing the villain to ×0.78 before the lock keeps the first bumper ≤ 4.9 m.
##       ✅ even then the lock comes ~2.4 s after the boss phase (the last 22 m of the shoulder are empty), so a plug 9 m
##       behind the villain that only the stage's verb opens turns the approach into a 4–10 s beat; ❓ the feel on device.
##
## A1 (neck plug off = the shipped data): at the boss-entry tick, stages 1-1~1-4 / 1-6~1-10:
##   - first bumper gap (front body's rear → next body's front) in the villain lanes and their neighbours ≤ 4.9 m
##     (1-3 spaced lanes 0/1 excluded; 1-2 / 1-9 zig stages have no first-bumper gate: both cores hold every lane's
##     followers behind front_line - 8 m, the weave buffer);
##   - holes ≥ 5.6 m within 40 m behind the villain, summed over lanes 0-3, ≤ 1 (the zig buffer gap excluded);
##   - the same run with options.pace = 1.0 is printed as the baseline; 1-5 (frontGlue false) runs at pace 1.0 and its
##     pre-lock time equals the pace-1.0 run ±10 %.
## A2 (options.neck = true), 1-1~1-10 (1-5 has no plug): verb bot boss→lock 4–10 s; naive bot opens at safety ±0.5 s on
##   the bottleneck clock (1-3's verb is "do nothing": it opens on the quiet timer) and locks ≤ 3 s after that (≤ safety
##   + 3; a shoulder cheater cutting in between pauses the clock, its honk is the bridge's); spam bot ≥ 1.5× the verb bot
##   (not 1-1); no overlap with the plug and no villain pass-through before the lock; while the bottleneck is on no
##   TrafficBridge.honk (every honk_reply carries neck: true) and no stuck-assist increase; plus unit checks (defaults off,
##   jam hop blocked, rage t1 opens it, honk from afar → stubborn, state().neck shape).
## Default: seeds [1, 2] for A1, seed 1 for the bots. `-- --full` (runner user arg): seeds 1–5 everywhere (the r3 gate).

## Multi-seed autopilot matrix over both backends (~3 min): e2e like the other autoplay matrices (native-check step 6).
##   godot47 --headless --path native -s res://tests/run_tests.gd -- --suite=e2e --filter=test_neck [--full]
const SUITE := "e2e"
const _DB := preload("res://core/db.gd")
const A1_STAGES: Array[int] = [1, 2, 3, 4, 6, 7, 8, 9, 10]
const NECK_STAGES: Array[int] = [1, 2, 3, 4, 6, 7, 8, 9, 10]
const LIMIT_S: float = 160.0

var _fails: int = 0
var _stages: Variant = null
var _tables: Dictionary = {}
var _full: bool = false


func _check(ok: bool, what: String) -> void:
	print(("PASS" if ok else "FAIL") + " neck: " + what)
	if not ok:
		_fails += 1


func run() -> int:
	_full = OS.get_cmdline_user_args().has("--full")
	_stages = _DB.load_json("res://data/stages.json")
	_tables = _DB.load_traffic_tables()
	var t0: int = Time.get_ticks_msec()
	_unit()
	for fb: bool in [false, true]:
		_a1(fb)
	for fb: bool in [false, true]:
		_a2(fb)
	print("INFO neck: %.1f s (full=%s)" % [(Time.get_ticks_msec() - t0) / 1000.0, _full])
	return _fails


func _stage(id: int) -> Dictionary:
	return _DB.find_stage(_stages, id)


func _sim(id: int, seed: int, fb: bool, opts: Dictionary = {}) -> GameSim:
	var sim := GameSim.new()
	sim.force_fallback = fb
	var t: Dictionary = _tables.duplicate()
	t["options"] = opts
	sim.setup(_stage(id), t, seed)
	return sim


func _neck(sim: GameSim) -> Object:
	return sim.get("neck") as Object


# --- unit ---------------------------------------------------------------------------------------------

func _unit() -> void:
	var sim := _sim(1, 3, false)
	var nk: Object = _neck(sim)
	_check(nk != null, "GameSim owns a NeckSim (sim.neck)")
	if nk == null:
		return
	_check(not bool(nk.get("enabled")), "data default.enabled = false: no plug until U3 lands (override with options.neck)")
	var st: Dictionary = sim.state()
	_check(st.get("neck") is Dictionary and not bool((st["neck"] as Dictionary).get("on", true)), "state().neck present, on = false by default")
	# pace data: 1-1 0.78, 1-5 1.0
	_check(is_equal_approx(float(sim.boss.get("pace")), 0.78), "A1: 1-1 villain pace %.2f = approachVMul 0.78 before the lock" % float(sim.boss.get("pace")))
	var s5 := _sim(5, 3, false)
	_check(is_equal_approx(float(s5.boss.get("pace")), 1.0), "A1: 1-5 frontGlue false → pace 1.0")
	# plug geometry
	var on := _sim(1, 3, false, {"neck": true})
	_run(on, func() -> bool: return on.phase == &"jam", 5.0)
	var pl: Dictionary = (_neck(on).get("plug") as Dictionary)
	var f: float = -INF
	for v: Dictionary in on.boss.villains:
		f = maxf(f, float(v["base_s"]))
	_check(not pl.is_empty() and absf(float(pl["s"]) - (f - 9.0)) < 0.05 and is_equal_approx(float(pl["x"]), Cfg.lane_x(Cfg.SHOULDER_LANE)),
		"A2: jam start → plug on the shoulder at F-9 (s %.1f, F %.1f)" % [float(pl.get("s", 0.0)), f])
	var ex: Array = on.bridge.call(&"extras") if on.bridge.has_method(&"extras") else []
	_run(on, func() -> bool: return false, 0.1)
	ex = on.bridge.call(&"extras") if on.bridge.has_method(&"extras") else []
	_check(not on.bridge.has_method(&"set_extras") or ex.size() == 1, "A2: plug handed to the traffic core every tick (bridge extras %d)" % ex.size())
	var s4 := _sim(4, 3, false, {"neck": true})
	_run(s4, func() -> bool: return s4.phase == &"jam", 5.0)
	var p4: Dictionary = (_neck(s4).get("plug") as Dictionary)
	_check(not p4.is_empty() and bool(_neck(s4).call(&"occupies", 3)) and bool(_neck(s4).call(&"occupies", 4)),
		"A2: 1-4 plug straddles lanes 3 and 4 (x %.2f)" % float(p4.get("x", 0.0)))
	# jam hop never clears the plug; honk from afar = stubborn; rage t1 opens it (exit fly)
	var h := _sim(7, 3, false, {"neck": true})
	h.autopilot = Autopilot.new(7)
	_check(_run(h, func() -> bool: return bool(_neck(h).call(&"is_active", h)), LIMIT_S), "A2: 1-7 autopilot reaches the bottleneck")
	h.autopilot = null
	var hn: Object = _neck(h)
	if h.player.lane == Cfg.SHOULDER_LANE and float(hn.call(&"gap", h)) > 6.5:
		h.last_horn = -99.0
		h.input(&"honk")
		var evs: Array[Dictionary] = _step(h)
		var far: bool = false
		for e: Dictionary in evs:
			if str(e["type"]) == "honk_reply" and str(e.get("data", "")) == "far":
				far = true
		_check(far and float(hn.get("_stubborn")) > 0.0, "A2: shoulder honk %.1f m from the plug (charging in) → 'far' + stubborn" % float(hn.call(&"gap", h)))
	_run(h, func() -> bool: return float(hn.call(&"gap", h)) < 1.5, 6.0)
	var hop: String = h.jam_hop(0.75)
	_check(hop == "blocked", "A2: jam hop behind the plug → '%s' (never hopped)" % hop)
	h.rage = 1.0
	var opened: Dictionary = {}
	h.input(&"rage")
	for i: int in 3:
		for e: Dictionary in _step(h):
			if str(e["type"]) == "neck_open":
				opened = e
	_check(str(opened.get("how", "")) == "rage" and str(opened.get("exit", "")) == "fly" and not bool(opened.get("bonus", true)),
		"A2: rage t1 at the bottleneck → neck_open how rage, exit fly, no bonus (%s)" % str(opened))
	var ns: Dictionary = h.state()["neck"]
	var keys_ok: bool = true
	for k: String in ["on", "s", "x", "len", "w", "kind", "valve", "phase", "chip", "safety_left", "exit", "t"]:
		keys_ok = keys_ok and ns.has(k)
	_check(keys_ok, "A2: state().neck carries {on, s, x, len, w, kind, valve, phase, chip, safety_left, exit, t}")


func _step(sim: GameSim) -> Array[Dictionary]:
	sim.step(Cfg.TICK)
	return sim.events()


func _run(sim: GameSim, cond: Callable, max_t: float) -> bool:
	var t_end: float = sim.time + max_t
	while sim.time < t_end:
		sim.step(Cfg.TICK)
		sim.events()
		if cond.call():
			return true
	return false


# --- A1 ---------------------------------------------------------------------------------------------

func _a1(fb: bool) -> void:
	var tag: String = "fallback" if fb else "native"
	if not fb and not TrafficBridge.native_available():
		print("INFO neck: C++ traffic not loaded → native A1 rows run on the fallback")
	var seeds: Array = range(1, 6) if _full else [1, 2]
	var worst_gap: float = 0.0
	var worst_holes: int = 0
	var rows: PackedStringArray = []
	for id: int in A1_STAGES:
		var gaps: Array[float] = []
		var holes: Array[int] = []
		var base_gaps: Array[float] = []
		var base_holes: Array[int] = []
		for seed: int in seeds:
			var m: Dictionary = _entry_metrics(id, seed, fb, {})
			var b: Dictionary = _entry_metrics(id, seed, fb, {"pace": 1.0})
			if m.is_empty():
				_check(false, "A1 %s 1-%d seed %d: boss phase reached within %.0f s" % [tag, id, seed, LIMIT_S])
				continue
			gaps.append(float(m["gap"]))
			holes.append(int(m["holes"]))
			if not b.is_empty():
				base_gaps.append(float(b["gap"]))
				base_holes.append(int(b["holes"]))
			var ok: bool = float(m["gap"]) <= 4.9 and int(m["holes"]) <= 1
			if not ok:
				print("INFO neck: A1 %s 1-%d seed %d detail %s" % [tag, id, seed, m["detail"]])
			_check(ok, "A1 %s 1-%d seed %d: first bumper %.1f m ≤ 4.9, holes ≥5.6 m %d ≤ 1 (pace 1.0: %.1f m / %d)" % [tag, id, seed,
				float(m["gap"]), int(m["holes"]), float(b.get("gap", -1.0)), int(b.get("holes", -1))])
			worst_gap = maxf(worst_gap, float(m["gap"]))
			worst_holes = maxi(worst_holes, int(m["holes"]))
		rows.append("1-%d gap %s holes %s | pace1 gap %s holes %s" % [id, _fmt(gaps), str(holes), _fmt(base_gaps), str(base_holes)])
	for r: String in rows:
		print("INFO neck: A1 %s %s" % [tag, r])
	print("INFO neck: A1 %s worst first bumper %.2f m, worst holes %d" % [tag, worst_gap, worst_holes])
	# 1-5: frontGlue false → the pre-lock time is the pace-1.0 run's
	var l5: float = _lock_time(5, 1, fb, {})
	var l5b: float = _lock_time(5, 1, fb, {"pace": 1.0})
	_check(l5 > 0.0 and l5b > 0.0 and absf(l5 - l5b) <= 0.1 * l5b,
		"A1 %s 1-5 pre-lock time %.1f s vs pace 1.0 %.1f s (±10%%)" % [tag, l5, l5b])


func _fmt(a: Array[float]) -> String:
	var parts: PackedStringArray = []
	for x: float in a:
		parts.append("%.1f" % x)
	return "[" + ", ".join(parts) + "]"


## Autopilot to the first boss tick; {gap, holes, detail} ({} when it never gets there).
func _entry_metrics(id: int, seed: int, fb: bool, opts: Dictionary) -> Dictionary:
	var sim := _sim(id, seed, fb, opts)
	sim.autopilot = Autopilot.new(seed * 13 + 1)
	if not _run(sim, func() -> bool: return sim.phase == &"boss", LIMIT_S):
		return {}
	return _front_metrics(sim)


func _lock_time(id: int, seed: int, fb: bool, opts: Dictionary) -> float:
	var sim := _sim(id, seed, fb, opts)
	sim.autopilot = Autopilot.new(seed * 13 + 1)
	if not _run(sim, func() -> bool: return sim.front_locked, LIMIT_S):
		return -1.0
	return sim.stage_clock


## Bodies per lane (NPC cars by buffer lane, alive villains by lanes_of, the player) and the two A1 numbers.
func _front_metrics(sim: GameSim) -> Dictionary:
	var st: Dictionary = sim.stage
	var f: float = -INF
	var vlanes: Dictionary = {}
	for v: Dictionary in sim.boss.alive():
		f = maxf(f, float(v["base_s"]))
		for l: int in BossSim.lanes_of(v):
			vlanes[l] = true
	var excl_gap: Dictionary = {}
	var excl_all: Dictionary = {}
	var zig_lanes: Dictionary = {}
	var shape: Variant = st.get("jamShape")
	if shape is Dictionary and (shape as Dictionary).get("lanes") is Array:
		var ls: Array = (shape as Dictionary)["lanes"]
		for l: int in ls.size():
			if str(ls[l]) in ["spaced", "pass"]:
				excl_gap[l] = true
				excl_all[l] = true
	if st.get("zig") == true:
		for v: Dictionary in sim.boss.alive():
			var zc: int = clampi(roundi(float(v["home_lane"])), 1, 2)
			for l: int in [zc - 1, zc, zc + 1]:
				zig_lanes[l] = true
				excl_gap[l] = true
				vlanes[l] = true  # the sweep is the villain's: its neighbours are measured
	var bodies: Array = [[], [], [], []]
	var buf := PackedFloat32Array()
	sim.bridge.read_into(buf)
	var specs: Array[Dictionary] = sim.bridge.car_specs()
	for k: int in sim.bridge.count_npc():
		var o: int = k * TrafficBridge.STRIDE
		var ln: int = int(buf[o + 2])
		var cs: float = buf[o + 4]
		if ln < 0 or ln > 3 or cs < f - 70.0 or cs > f + 30.0:
			continue
		var cl: float = float(specs[k]["len"]) if k < specs.size() else 4.4
		(bodies[ln] as Array).append([cs + cl / 2.0, cs - cl / 2.0, "car"])
	for v: Dictionary in sim.boss.alive():
		for l: int in BossSim.lanes_of(v):
			(bodies[l] as Array).append([float(v["s"]) + float(v["len"]) / 2.0, float(v["s"]) - float(v["len"]) / 2.0, "villain"])
	for l: int in 4:
		if sim.player.occupies(l):
			(bodies[l] as Array).append([sim.player.s + sim.player.len / 2.0, sim.player.s - sim.player.len / 2.0, "player"])
	var worst: float = 0.0
	var holes: int = 0
	var detail: PackedStringArray = []
	for l: int in 4:
		if excl_all.has(l):
			continue
		var b: Array = bodies[l]
		b.sort_custom(func(a: Array, c: Array) -> bool: return float(a[0]) > float(c[0]))
		var near: bool = vlanes.has(l) or vlanes.has(l - 1) or vlanes.has(l + 1)
		var zig: bool = st.get("zig") == true
		if near and not excl_gap.has(l) and not zig and b.size() >= 2:
			var g0: float = float(b[0][1]) - float(b[1][0])
			worst = maxf(worst, g0)
			detail.append("L%d first %.1f (%s)" % [l, g0, b[0][2]])
		for i: int in b.size() - 1:
			if float(b[i + 1][0]) < f - 40.0:
				break
			if zig and i == 0:
				continue  # the zig weave buffer (followers held at front_line - 8 in every lane, both cores)
			if zig_lanes.has(l) and str(b[i][2]) == "villain":
				continue
			var g: float = float(b[i][1]) - float(b[i + 1][0])
			if g >= 5.6:
				holes += 1
				detail.append("L%d hole %.1f at %.1f" % [l, g, float(b[i + 1][0]) - f])
	return {"gap": worst, "holes": holes, "detail": ", ".join(detail)}


# --- A2 ---------------------------------------------------------------------------------------------

func _a2(fb: bool) -> void:
	var tag: String = "fallback" if fb else "native"
	var seeds: Array = range(1, 6) if _full else [1]
	for id: int in NECK_STAGES:
		var safety: float = _safety(id, fb)
		var verb_t: Array[float] = []
		var spam_t: Array[float] = []
		for seed: int in seeds:
			var vr: Dictionary = _neck_run(id, seed, fb, "verb")
			var nr: Dictionary = _neck_run(id, seed, fb, "naive")
			var sr: Dictionary = _neck_run(id, seed, fb, "spam")
			var label: String = "A2 %s 1-%d seed %d" % [tag, id, seed]
			for r: Dictionary in [vr, nr, sr]:
				_check(bool(r["locked"]), "%s %s: locks within %.0f s (boss→lock %.1f s, open %s/%s at %.1f s)" % [label, r["mode"], LIMIT_S,
					float(r["lock"]), r["how"], r["exit"], float(r["open_t"])])
				_check(r["overlap"] == "" and r["through"] == "", "%s %s: no plug overlap (%s), no villain pass-through (%s)" % [label, r["mode"],
					r["overlap"], r["through"]])
				_check(int(r["bridge_honks"]) == 0 and int(r["assists"]) == 0, "%s %s: bottleneck on → bridge.honk %d, stuck assists +%d" % [label,
					r["mode"], int(r["bridge_honks"]), int(r["assists"])])
			if bool(vr["locked"]):
				verb_t.append(float(vr["lock"]))
				_check(float(vr["lock"]) >= 4.0 and float(vr["lock"]) <= 10.0 and bool(vr["bonus"]),
					"%s verb: boss→lock %.1f s in 4–10 s via the verb (how %s, bonus %s)" % [label, float(vr["lock"]), vr["how"], vr["bonus"]])
			if bool(nr["locked"]):
				if id == 3:
					_check(str(nr["how"]) == "verb", "%s naive: 1-3's verb is waiting quietly → opens on the quiet timer (%s at %.1f s)" % [label,
						nr["how"], float(nr["open_t"])])
				else:
					_check(str(nr["how"]) == "safety" and absf(float(nr["open_t"]) - safety) <= 0.5,
						"%s naive: opens by itself at %.1f s (safety %.0f ±0.5, how %s)" % [label, float(nr["open_t"]), safety, nr["how"]])
				_check(float(nr["after_open"]) <= 3.0, "%s naive: lock %.1f s after it gave way (≤ safety + 3 on the bottleneck clock; boss→lock %.1f s)" % [label,
					float(nr["after_open"]), float(nr["lock"])])
			if bool(sr["locked"]):
				spam_t.append(float(sr["lock"]))
		if id != 1 and not verb_t.is_empty() and not spam_t.is_empty():
			var mv: float = _mean(verb_t)
			var ms: float = _mean(spam_t)
			_check(ms >= 1.5 * mv, "A2 %s 1-%d: honk spam %.1f s ≥ 1.5 × verb %.1f s" % [tag, id, ms, mv])
		print("INFO neck: A2 %s 1-%d verb %s spam %s" % [tag, id, _fmt(verb_t), _fmt(spam_t)])


## The stage's plug safety from the sim's merged neck config (8 s when the sim has no neck, i.e. pre-r3 code).
func _safety(id: int, fb: bool) -> float:
	var nk: Object = _neck(_sim(id, 1, fb))
	if nk == null:
		return 8.0
	return float(((nk.get("cfg") as Dictionary).get("plug", {}) as Dictionary).get("safety", 8.0))


func _mean(a: Array[float]) -> float:
	var t: float = 0.0
	for x: float in a:
		t += x
	return t / maxf(1.0, a.size())


## One autopilot run with the plug on, to the lock: boss→lock, the open record and the per-tick invariants.
func _neck_run(id: int, seed: int, fb: bool, mode: String) -> Dictionary:
	var sim := _sim(id, seed, fb, {"neck": true})
	var ap := Autopilot.new(seed * 13 + 1)
	ap.set("neck_mode", mode)
	sim.autopilot = ap
	var nk: Object = _neck(sim)
	var out: Dictionary = {"mode": mode, "locked": false, "lock": -1.0, "how": "", "exit": "", "bonus": false, "open_t": -1.0,
		"overlap": "", "through": "", "bridge_honks": 0, "assists": 0, "lock_n": -1.0, "after_open": -1.0}
	var open_time: float = -1.0
	var boss_t: float = -1.0
	var neck_t: float = -1.0
	var assists0: int = -1
	while sim.time < LIMIT_S and not sim.front_locked:
		var active: bool = nk != null and bool(nk.call(&"is_active", sim))
		sim.step(Cfg.TICK)
		for e: Dictionary in sim.events():
			match str(e["type"]):
				"phase":
					if e["phase"] == &"boss" and boss_t < 0.0:
						boss_t = sim.time
				"honk_reply":
					# on before and after the tick (a shoulder cheater cutting in between pauses the bottleneck; its honk is
					# TrafficBridge.honk's by design)
					if active and not bool(e.get("neck", false)) and nk != null and bool(nk.call(&"is_active", sim)):
						out["bridge_honks"] = int(out["bridge_honks"]) + 1
				"neck_active":
					if neck_t < 0.0:
						neck_t = sim.time
				"neck_open":
					if str(out["how"]) == "":
						open_time = sim.time
						out["how"] = str(e["how"])
						out["exit"] = str(e["exit"])
						out["bonus"] = bool(e["bonus"])
						out["open_t"] = float(e["t"])
		if nk == null:
			continue
		var on_now: bool = bool(nk.call(&"is_active", sim))
		var ai: int = int(sim.bridge.info().get("assists", 0))
		if on_now and assists0 < 0:
			assists0 = ai
		elif on_now and ai > assists0:
			out["assists"] = ai - assists0
		if out["overlap"] == "" and bool(nk.call(&"blocking")):
			var pl: Dictionary = nk.get("plug")
			var p: PlayerSim = sim.player
			if absf(p.s - float(pl["s"])) < (p.len + float(pl["len"])) / 2.0 - 0.05 and absf(p.x - float(pl["x"])) < (p.w + float(pl["w"])) / 2.0 - 0.05:
				out["overlap"] = "t=%.2f player %.2f/%.2f plug %.2f/%.2f" % [sim.time, p.s, p.x, float(pl["s"]), float(pl["x"])]
		for v: Dictionary in sim.boss.villains:
			if bool(v["alive"]) and out["through"] == "" and sim.player.s > float(v["base_s"]) \
					and sim.boss.player_in_lanes(sim.player, BossSim.lanes_of(v)) \
					and float(v["base_s"]) + float(v["len"]) / 2.0 > sim.player.s - sim.player.len / 2.0 + 0.5:
				out["through"] = "t=%.1f villain %.1f player %.1f" % [sim.time, float(v["base_s"]), sim.player.s]
	out["locked"] = sim.front_locked
	out["lock"] = sim.time - boss_t if sim.front_locked and boss_t >= 0.0 else -1.0
	out["lock_n"] = sim.time - neck_t if sim.front_locked and neck_t >= 0.0 else -1.0
	out["after_open"] = sim.time - open_time if sim.front_locked and open_time >= 0.0 else -1.0
	return out
