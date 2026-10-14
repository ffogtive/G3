extends RefCounted
## rvA (2026-10-14 review) e2e gate for the rage ladder on the iPhone path: the GDScript fallback traffic with the
## items loadout (jump + drone), no rage top-ups, a patient human policy (Autopilot.policy "max_exec": save the bar,
## t5 once the villain is under the execute line).
##   가설: ✅ with rageGain.lock 0.3 the fight reaches MAX and the t5 execute in ≥ 8/10 runs and the boss stays
##         10–20 s real. (lock 0.2: the drone shortens the fallback jam, ~0.32 rage at the lock, MAX 0/10.)
## Runs in the e2e suite: godot47 --headless --path native -s res://tests/run_tests.gd -- --suite=e2e

const SUITE := "e2e"
const _DB := preload("res://core/db.gd")
const SEEDS: Array[int] = [1007, 3, 11, 42, 77, 5, 21, 99, 123, 4242]
const LIMIT_S: float = 150.0

var _fails: int = 0


func _check(ok: bool, what: String) -> void:
	print(("PASS" if ok else "FAIL") + " e2e_economy: " + what)
	if not ok:
		_fails += 1


func run() -> int:
	var stage: Dictionary = _DB.find_stage(_DB.load_json("res://data/stages.json"), 1)
	var execs: int = 0
	var in_band: int = 0
	var results: int = 0
	var lines: PackedStringArray = []
	for sd: int in SEEDS:
		var tables: Dictionary = _DB.load_traffic_tables()
		tables["options"] = {"loadout": {"finish": "rocket", "items": ["mv_jump", "mv_drone"]}}
		var sim := GameSim.new()
		sim.force_fallback = true
		sim.setup(stage, tables, sd)
		sim.autopilot = Autopilot.new(sd * 13 + 1)
		sim.autopilot.policy = "max_exec"
		var boss_t0: float = -1.0
		var kill_t: float = -1.0
		var lock_rage: float = -1.0
		var executed: bool = false
		var max_segs: int = 0
		while sim.time < LIMIT_S and sim.phase != &"result":
			sim.step(Cfg.TICK)
			if sim.phase == &"boss" and sim.front_locked:
				max_segs = maxi(max_segs, sim.skills.segs(sim))
			for e: Dictionary in sim.events():
				match str(e["type"]):
					"phase":
						if e["phase"] == &"boss" and boss_t0 < 0.0:
							boss_t0 = sim.real_time
						elif e["phase"] == &"kill":
							kill_t = sim.real_time
					"lock":
						lock_rage = sim.rage
					"skill_hit":
						if str(e.get("id", "")) == "t5_finish" and bool(e.get("killed", false)):
							executed = true
		var boss_real: float = kill_t - boss_t0
		if sim.phase == &"result":
			results += 1
		if executed:
			execs += 1
		if boss_real >= 10.0 and boss_real <= 20.0:
			in_band += 1
		lines.append("seed %d: %s, rage at lock %.2f, max segs %d, execute %s, boss %.1f s" % [sd, sim.phase, lock_rage, max_segs,
			str(executed), boss_real])
	for l: String in lines:
		print("INFO e2e_economy: fallback items max_exec " + l)
	_check(results == SEEDS.size(), "fallback + items: every run reaches the result card (%d/%d)" % [results, SEEDS.size()])
	_check(execs >= 8, "fallback + items, no top-ups: MAX → t5 execute in ≥ 8/10 runs (%d/%d)" % [execs, SEEDS.size()])
	_check(in_band >= 8, "fallback + items: boss 10–20 s real in ≥ 8/10 runs (%d/%d)" % [in_band, SEEDS.size()])
	return _fails
