extends RefCounted
## GameSim contract + determinism (NATIVE_PORT 3-2/3-3): two autopilot runs of 1-1 with the same seed produce the
## same event log and final state bit for bit; another seed differs. Also checks the fixed state() shape the
## view/UI read, the event types, and the T0 perf budget (GameSim ≤ 2 ms/tick in the container).
##
## 가설: ✅ every random draw in sim/ comes from a seeded RandomNumberGenerator (boss, weapons, cosmetic, autopilot)
##       or the C++ mulberry32, so a seed fixes the whole run.

const _DB := preload("res://core/db.gd")
const PHASES: Array[StringName] = [&"intro", &"jam", &"boss", &"kill", &"release", &"cruise", &"result", &"wreck", &"fail"]

var _fails: int = 0


func _check(ok: bool, what: String) -> void:
	print(("PASS" if ok else "FAIL") + " game_sim: " + what)
	if not ok:
		_fails += 1


func run() -> int:
	var stage: Dictionary = _DB.find_stage(_DB.load_json("res://data/stages.json"), 1)
	var tables: Dictionary = _DB.load_traffic_tables()
	var a: Dictionary = _play(stage, tables, 4242)
	var b: Dictionary = _play(stage, tables, 4242)
	var c: Dictionary = _play(stage, tables, 4243)
	print("INFO game_sim: %d events, end %s at %.2f s, %.0f µs/tick" % [int(a["n"]), a["phase"], float(a["t"]), float(a["us"])])
	_check(a["hash"] == b["hash"] and a["final"] == b["final"], "same seed → identical event log + final state (%s)" % str(a["hash"]).substr(0, 12))
	_check(a["hash"] != c["hash"], "seed 4243 → a different run (the check is live)")
	_check(a["phase"] == &"result", "the run reaches the result card")
	_check(float(a["us"]) < 2000.0, "T0 perf: GameSim %.0f µs/tick ≤ 2000" % float(a["us"]))
	var types: Dictionary = a["types"]
	for t: String in ["phase", "lock", "fire", "hit", "stun", "damage", "kill", "release", "honk", "honk_reply", "bubble"]:
		_check(types.has(t), "event type '%s' raised (%d)" % [t, int(types.get(t, 0))])
	_shape(stage, tables)
	return _fails


func _play(stage: Dictionary, tables: Dictionary, seed: int) -> Dictionary:
	var sim := GameSim.new()
	sim.setup(stage, tables, seed)
	sim.autopilot = Autopilot.new(seed)
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var n: int = 0
	var types: Dictionary = {}
	var ticks: int = 0
	var t0: int = Time.get_ticks_usec()
	while sim.time < 150.0 and sim.phase != &"result":
		sim.step(Cfg.TICK)
		ticks += 1
		for e: Dictionary in sim.events():
			n += 1
			types[str(e["type"])] = int(types.get(str(e["type"]), 0)) + 1
			ctx.update(var_to_bytes(e))
	var us: float = (Time.get_ticks_usec() - t0) / float(maxi(1, ticks))
	var st: Dictionary = sim.state()
	var final: PackedByteArray = var_to_bytes([st["player"], st["villains"], st.get("result", {}), sim.time])
	return {"hash": ctx.finish().hex_encode(), "final": final, "n": n, "types": types, "phase": sim.phase, "t": sim.time, "us": us}


func _shape(stage: Dictionary, tables: Dictionary) -> void:
	var sim := GameSim.new()
	sim.setup(stage, tables, -1)
	for i: int in 600:
		sim.step(Cfg.TICK)
	var st: Dictionary = sim.state()
	var ok: bool = PHASES.has(st["phase"]) and st.has("t") and st["hint"] is String and st["distance_m"] is float and st["progress"] is float
	for k: String in ["s", "x", "lane", "v", "hp", "hp_max", "rage", "boost"]:
		ok = ok and (st["player"] as Dictionary).has(k)
	for k: String in ["id", "kind", "s", "x", "lane", "hp", "hp_max", "alive", "dying", "tell", "vulnerable"]:
		ok = ok and ((st["villains"] as Array)[0] as Dictionary).has(k)
	for k: String in ["active", "in_range", "target_id", "reason"]:
		ok = ok and (st["lock"] as Dictionary).has(k)
	_check(ok and ((st["villains"] as Array)[0] as Dictionary)["tell"] is StringName, "state() carries the fixed interface keys (phase %s)" % st["phase"])
	_check(sim.traffic() is TrafficBridge and sim.traffic().count() > 100, "traffic() hands out the bridge for the NPC buffer")
	var prog: float = float(st["progress"])
	var dist: float = float(st["distance_m"])
	var ref: float = sim.boss.ref_s()
	_check(is_equal_approx(prog, clampf((sim.player.s - sim.start_s) / (ref - sim.start_s), 0.0, 1.0)) and is_equal_approx(dist, ref - sim.player.s),
		"N1: progress %.3f and distance %.1f m come from the same live villain s" % [prog, dist])
