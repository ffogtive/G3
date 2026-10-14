extends RefCounted
## R1 (NATIVE_PORT M1b web bug list) + P0#6 (DESIGN_REVIEW 2026-10-13):
##   R1  wreck after the boss entered HP phase 2 → retry: the attack table, intervalMul, movement personality
##       (slow) and villain HP/tires are phase 2's, not the spawn values the web restores (main.js:712).
##   P0#6 the result card counts the whole stage: time across attempts, min HP 0, tows 1, ★2 failed.
##
## 가설: ✅ snapshotting BossSim's phase-applied state (not just phaseIdx) and keeping the stage clock outside the
##       per-attempt reset fixes both; the jam is re-spawned so the villain stays anchored to its front.

const _DB := preload("res://core/db.gd")

var _fails: int = 0
var _tables: Dictionary = {}


func _check(ok: bool, what: String) -> void:
	print(("PASS" if ok else "FAIL") + " boss_retry: " + what)
	if not ok:
		_fails += 1


func _run(sim: GameSim, cond: Callable, max_t: float) -> bool:
	var t_end: float = sim.real_time + max_t
	while sim.real_time < t_end:
		sim.step(Cfg.TICK)
		sim.events()
		if cond.call():
			return true
	return false


func run() -> int:
	_tables = _DB.load_traffic_tables()
	var stage: Dictionary = _DB.find_stage(_DB.load_json("res://data/stages.json"), 1)
	_r1(stage)
	_honest_card(stage)
	return _fails


func _r1(base: Dictionary) -> void:
	var st: Dictionary = base.duplicate(true)
	st["sig"] = ""  # generic boss: the attack table is what the phase changes
	st["attacks"] = [["highbeam", 1], ["throw", 1]]
	st["phases"] = [{"hp": 0.7, "attacks": [["smoke", 1]], "slow": true, "label": "2페이즈"}]
	var sim := GameSim.new()
	sim.setup(st, _tables, 21)
	sim.autopilot = Autopilot.new(21)
	_check(_run(sim, func() -> bool: return sim.front_locked, 120.0), "R1: autopilot reaches the front lock")
	var v: Dictionary = sim.boss.villains[0]
	sim.boss.damage(v, 50.0, 50.0, false)
	_run(sim, func() -> bool: return sim.boss.phase_idx == 1, 1.0)
	_check(sim.boss.phase_idx == 1 and sim.boss.attacks.has("smoke"), "R1: HP %.0f%% → boss phase 2 (attacks %s)" % [sim.boss.hp_frac() * 100.0, sim.boss.attacks])
	var want_attacks: Dictionary = sim.boss.attacks.duplicate()
	var want_mul: float = sim.boss.interval_mul
	var want_vn: float = float(v["v_nominal"])
	var want_hp: float = float(v["hp"])
	var want_tires: int = int(v["tires"])
	sim.autopilot = null
	sim.apply_damage(999.0, "test wreck")
	_check(sim.phase == &"wreck", "R1: lethal hit → wreck")
	_check(_run(sim, func() -> bool: return sim.phase == &"fail", 4.0), "R1: wreck → fail card")
	sim.input(&"retry")
	sim.step(Cfg.TICK)
	var nv: Dictionary = sim.boss.villains[0]
	_check(sim.phase == &"jam" or sim.phase == &"boss", "R1: retry → back on the road (%s)" % sim.phase)
	_check(sim.boss.attacks == want_attacks and is_equal_approx(sim.boss.interval_mul, want_mul) and sim.boss.phase_idx == 1,
		"R1: attack table %s, intervalMul %.2f, phase 2 kept" % [sim.boss.attacks, sim.boss.interval_mul])
	_check(is_equal_approx(float(nv["v_nominal"]), want_vn) and want_vn < float(st["jamSpeed"]),
		"R1: phase-2 movement kept (v_nominal %.2f, spawn %.2f)" % [float(nv["v_nominal"]), float(st["jamSpeed"])])
	_check(is_equal_approx(float(nv["hp"]), want_hp) and int(nv["tires"]) == want_tires, "R1: villain HP %.0f / tires %d kept" % [float(nv["hp"]), int(nv["tires"])])
	_check(sim.hp == sim.hp_max and sim.player.lane == Cfg.SHOULDER_LANE and sim.boss.ref_s() - sim.player.s > 30.0,
		"R1: player on the shoulder %.0f m behind the villain with a fresh bumper" % (sim.boss.ref_s() - sim.player.s))
	var fresh := GameSim.new()
	fresh.setup(st, _tables, 21)
	_check(fresh.boss.attacks != want_attacks, "R1: a fresh spawn would have the phase-1 table %s (the web bug)" % fresh.boss.attacks)


func _honest_card(stage: Dictionary) -> void:
	var sim := GameSim.new()
	sim.setup(stage, _tables, 5)
	sim.autopilot = Autopilot.new(5)
	_run(sim, func() -> bool: return sim.front_locked, 120.0)
	_run(sim, func() -> bool: return false, 2.0)
	var clock_at_wreck: float = sim.stage_clock
	sim.apply_damage(999.0, "test wreck")
	_check(sim.fails == 1, "P0#6: wreck counted (fails %d)" % sim.fails)
	_check(_run(sim, func() -> bool: return sim.phase == &"result", 160.0), "P0#6: autopilot retries and finishes (t=%.1f)" % sim.time)
	var r: Dictionary = sim.state().get("result", {})
	if r.is_empty():
		_check(false, "P0#6: result card present")
		return
	print("INFO boss_retry: result time %.1f s (clock at wreck %.1f), hp %d, min %d, tows %d, stars %d, pay ×%.1f" % [float(r["time_s"]),
		clock_at_wreck, int(r["hp"]), int(r["min_hp"]), int(r["tows"]), int(r["stars"]), float(r["pay_mul"])])
	_check(float(r["time_s"]) > clock_at_wreck + 5.0, "P0#6: stage time spans both attempts (%.1f s > %.1f s)" % [float(r["time_s"]), clock_at_wreck])
	_check(int(r["min_hp"]) == 0 and int(r["tows"]) == 1, "P0#6: min HP 0 and 1 tow on the card")
	_check(not bool((r["missions"] as Array)[1]["done"]) and int(r["stars"]) <= 2, "P0#6: a tow fails ★2 (stars %d)" % int(r["stars"]))
	_check(is_equal_approx(float(r["pay_mul"]), 0.8), "P0#6: payout ×0.8 after one retry")
