extends RefCounted
## R2 (NATIVE_PORT M1b web bug list): the stuck assist (rubber band let-in, forced opening, auto tow) runs while
## the game is jam-like — the jam AND the boss phase before the front lock — not only in phase 'jam' as in the
## web (traffic.js:342), where a shoulder breakdown + no gap next to it soft-locks after the discovery.
## Test: discovery done, player parked behind the shoulder breakdown → it gets out within 4 s; with the
## web-parity gate the same setup gets no assist at all (proves the gate is what changed).
##
## 가설: ✅ GameSim passes jam_like = jam || (boss && !locked) to the core, whose stuck assist already keys on it.

const _DB := preload("res://core/db.gd")

var _fails: int = 0


func _check(ok: bool, what: String) -> void:
	print(("PASS" if ok else "FAIL") + " boss_stuck: " + what)
	if not ok:
		_fails += 1


func run() -> int:
	if not TrafficBridge.native_available():
		print("SKIP boss_stuck: C++ Traffic not loaded (the stuck assist lives in the core)")
		return 0
	var stage: Dictionary = _DB.find_stage(_DB.load_json("res://data/stages.json"), 1)
	var native: Dictionary = _stuck_run(stage, false)
	_check(int(native["assists"]) > 0, "R2: stuck assist fires in boss-before-lock (%d assist(s))" % int(native["assists"]))
	_check(bool(native["escaped"]), "R2: out from behind the breakdown in %.2f s (≤ 4 s)" % float(native["t"]))
	var web: Dictionary = _stuck_run(stage, true)
	_check(int(web["assists"]) == 0, "R2: web gate (phase=='jam') gives no assist after discovery (%d)" % int(web["assists"]))
	return _fails


func _stuck_run(stage: Dictionary, web_gate: bool) -> Dictionary:
	var sim := GameSim.new()
	sim.setup(stage, _DB.load_traffic_tables(), -1)
	if web_gate:
		sim.bridge.native().call(&"set_web_parity", true)
	sim.input(&"continue")
	while sim.phase != &"jam":
		sim.step(Cfg.TICK)
	var ob: Dictionary = {}
	for o: Variant in sim.bridge.obstacles():
		if str((o as Dictionary)["kind"]) == "breakdown":
			ob = o
	var p: PlayerSim = sim.player
	p.s = float(ob["s"]) - float(ob["len"]) / 2.0 - p.len / 2.0 - 0.6
	p.lane = Cfg.SHOULDER_LANE
	p.x = Cfg.lane_x(p.lane)
	p.lc_from = p.x
	p.lc_t = 1.0
	p.v = 0.0
	sim._enter(&"boss")  # discovery already happened (the villain's 35 m ring is a long way ahead: forced)
	sim.autopilot = Autopilot.new(3)
	var a0: int = int(sim.bridge.info().get("assists", 0))
	var t0: float = sim.time
	var escaped: bool = false
	while sim.time - t0 < 4.0 and sim.phase == &"boss" and not sim.front_locked:
		sim.step(Cfg.TICK)
		sim.events()
		if p.lane != Cfg.SHOULDER_LANE or p.s > float(ob["s"]) + float(ob["len"]) / 2.0:
			escaped = true
			break
	return {"assists": int(sim.bridge.info().get("assists", 0)) - a0, "escaped": escaped, "t": sim.time - t0}
