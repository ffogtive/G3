extends RefCounted
## docs/SKILLS.md §7-1 e2e gate: the autopilot's skill policy plays 1-1 on GameSim with a loadout (jump + drone, the
## finish rotating rocket / balloon / heli / ufo) for 5 seeds × {native traffic, GDScript fallback = the iPhone build}.
##   가설: with skills.hpMul 1.25 the boss fight stays 10–20 s of real time while the skills (t3 / t5 at least once)
##         and items fire, every cast keeps its real-time budget (t1 0.5, t3 1.2, t5 2.5, items 1.0 s; a cast that overlaps
##         the other channel is exempt: the other cast's hitstop / slow-mo stretches its sim-time hits) and the finish
##         releases the jam at done + releaseDelay.
## Runs in the e2e suite: godot47 --headless --path native -s res://tests/run_tests.gd -- --suite=e2e

const SUITE := "e2e"
const _DB := preload("res://core/db.gd")
const SEEDS: Array[int] = [1007, 3, 11, 42, 77]
const FINISHES: Array[String] = ["rocket", "balloon", "heli", "ufo"]
const LIMIT_S: float = 150.0
const BUDGET: Dictionary = {"t1_horn": 0.5, "t1_wave": 0.5, "t3_carpet": 1.2, "t5_finish": 2.5, "mv_jump": 1.0, "mv_drone": 1.0, "mv_tow": 1.0}

var _fails: int = 0


func _check(ok: bool, what: String) -> void:
	print(("PASS" if ok else "FAIL") + " e2e_skills: " + what)
	if not ok:
		_fails += 1


func run() -> int:
	var stage: Dictionary = _DB.find_stage(_DB.load_json("res://data/stages.json"), 1)
	var skc: Dictionary = (_DB.load_traffic_tables()["config"] as Dictionary).get("skills", {})
	var fc: Dictionary = skc.get("finish", {})
	var times: Array[float] = []
	var tiers: Dictionary = {}
	for fb: bool in [false, true]:
		if not fb and not TrafficBridge.native_available():
			print("SKIP e2e_skills: C++ Traffic not loaded (native path)")
			continue
		for i: int in SEEDS.size():
			var sd: int = SEEDS[i]
			var fin: String = FINISHES[(i + (1 if fb else 0)) % FINISHES.size()]
			var tables: Dictionary = _DB.load_traffic_tables()
			tables["options"] = {"loadout": {"finish": fin, "items": ["mv_jump", "mv_drone"]}}
			var sim := GameSim.new()
			sim.force_fallback = fb
			sim.setup(stage, tables, sd)
			sim.autopilot = Autopilot.new(sd * 13 + 1)
			var boss_t0: float = -1.0
			var kill_t: float = -1.0
			var rel_t: float = -1.0
			var starts: Dictionary = {}
			var overlap: Dictionary = {}   # chan -> the other channel was casting too (its hitstop / slow-mo stretches this one)
			var shared: int = 0
			var over: Array[String] = []
			var finishers: Array[String] = []
			var used: Dictionary = {}
			while sim.time < LIMIT_S and sim.phase != &"result":
				sim.step(Cfg.TICK)
				for e: Dictionary in sim.events():
					match str(e["type"]):
						"phase":
							if e["phase"] == &"boss" and boss_t0 < 0.0:
								boss_t0 = sim.real_time
							elif e["phase"] == &"kill":
								kill_t = sim.real_time
							elif e["phase"] == &"release":
								rel_t = sim.real_time
						"skill_start":
							var ch: String = str(e["chan"])
							var other: String = "item" if ch == "rage" else "rage"
							starts[ch] = sim.real_time
							overlap[ch] = starts.has(other)
							if starts.has(other):
								overlap[other] = true
							used[str(e["id"])] = int(used.get(str(e["id"]), 0)) + 1
						"skill_end":
							var ch2: String = str(e["chan"])
							var took: float = sim.real_time - float(starts.get(ch2, sim.real_time))
							if bool(overlap.get(ch2, false)):
								shared += 1
							elif took > float(BUDGET.get(str(e["id"]), 2.5)) + 2.0 * Cfg.TICK:
								over.append("%s %.2f s" % [str(e["id"]), took])
							starts.erase(ch2)
							overlap.erase(ch2)
						"finisher":
							finishers.append(str(e["id"]))
			var name: String = "%s seed %d (%s)" % ["fallback" if fb else "native", sd, fin]
			var boss_real: float = kill_t - boss_t0
			var budget_rel: float = float((fc.get(fin, {}) as Dictionary).get("done", 2.5)) + float(fc.get("releaseDelay", 0.3))
			for k: Variant in used.keys():
				tiers[k] = int(tiers.get(k, 0)) + int(used[k])
			print("INFO e2e_skills: %s → %s at %.1f s, boss %.1f s real / %.1f s sim, kill → release %.2f s, used %s (%d overlapped), hp %d" % [name,
				sim.phase, sim.real_time, boss_real, sim.boss_clock, rel_t - kill_t, str(used), shared, sim.hp])
			if sim.phase == &"result":
				times.append(boss_real)
			_check(sim.phase == &"result", "%s: reaches the result card" % name)
			_check(boss_real >= 10.0 and boss_real <= 20.0 and sim.boss_clock >= float(skc.get("minKillT", 6.0)),
				"%s: boss %.1f s real in 10–20 s, %.1f s sim ≥ minKillT" % [name, boss_real, sim.boss_clock])
			_check(int(used.get("t3_carpet", 0)) + int(used.get("t5_finish", 0)) >= 1 and finishers == [fin],
				"%s: t3 or t5 used (t3 %d, t5 %d), finished by finisher %s" % [name, int(used.get("t3_carpet", 0)), int(used.get("t5_finish", 0)), str(finishers)])
			_check(over.is_empty() and rel_t - kill_t <= budget_rel + 0.05,
				"%s: casts alone within the real-time budget %s, kill → release %.2f ≤ %.2f s (done + releaseDelay)" % [name, str(over),
				rel_t - kill_t, budget_rel])
	if not times.is_empty():
		times.sort()
		print("INFO e2e_skills: boss real time min %.1f / median %.1f / max %.1f s over %d runs; skill uses %s" % [times[0],
			times[times.size() / 2], times[-1], times.size(), str(tiers)])
	return _fails
