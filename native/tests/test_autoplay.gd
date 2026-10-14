extends RefCounted
## T1 (NATIVE_PORT M1b): the Autopilot plays 1-1 through GameSim to the result card for 10 seeds within 150 s of
## sim time, with zero script errors (the runner counts those). Invariants checked on every tick:
##   - hint is one line of ≤ 16 chars (P0#4 chip), progress in [0, 1];
##   - jam-like phases never take HP below the jam floor (P0#5, config hp.jamFloor);
##   - the villain never passes through the player (its front stays behind the player's rear while they share
##     a lane and the player is ahead), before or after the lock.
## Reports boss time per seed: the P0#7 target is 10–20 s.
##
## 가설: ✅ the web loop ported 1:1 + the P0 rules completes 1-1 for every seed; ❓ autopilot boss time ≈ a careful
##       human's (naive-bot gate is P1 #10).

const _DB := preload("res://core/db.gd")
const SEEDS: int = 10
const LIMIT_S: float = 150.0

var _fails: int = 0


func _check(ok: bool, what: String) -> void:
	print(("PASS" if ok else "FAIL") + " autoplay: " + what)
	if not ok:
		_fails += 1


func run() -> int:
	var stage: Dictionary = _DB.find_stage(_DB.load_json("res://data/stages.json"), 1)
	var tables: Dictionary = _DB.load_traffic_tables()
	var floor_hp: int = int((tables["config"]["hp"] as Dictionary).get("jamFloor", 60))
	var done: int = 0
	var boss_times: Array[float] = []
	for seed: int in range(1, SEEDS + 1):
		var sim := GameSim.new()
		sim.setup(stage, tables, seed)
		sim.autopilot = Autopilot.new(seed * 13 + 1)
		var bad_hint: String = ""
		var floor_broken: bool = false
		var through: String = ""
		while sim.time < LIMIT_S and sim.phase != &"result":
			sim.step(Cfg.TICK)
			sim.events()
			var h: String = sim.hint()
			if h.length() > 16 or h.contains("\n"):
				bad_hint = h
			if sim.is_jam_like() and sim.hp < floor_hp and sim.min_hp >= floor_hp:
				floor_broken = true
			for v: Dictionary in sim.boss.villains:
				if bool(v["alive"]) and through == "" and sim.player.s > float(v["base_s"]) \
						and sim.boss.player_in_lanes(sim.player, BossSim.lanes_of(v)) \
						and float(v["base_s"]) + float(v["len"]) / 2.0 > sim.player.s - sim.player.len / 2.0 + 0.5:
					through = "t=%.1f villain %.1f player %.1f" % [sim.time, float(v["base_s"]), sim.player.s]
		var r: Dictionary = sim.state().get("result", {})
		var ok: bool = sim.phase == &"result"
		done += 1 if ok else 0
		if ok:
			boss_times.append(float(r["boss_time_s"]))
		print("INFO autoplay: seed %d → %s at %.1f s (boss %.1f s, hp %s, min %s, tows %s, stars %s)" % [seed, sim.phase, sim.time,
			float(r.get("boss_time_s", -1.0)), r.get("hp"), r.get("min_hp"), r.get("tows"), r.get("stars")])
		_check(bad_hint == "", "seed %d: hint chip ≤ 16 chars, one line (%s)" % [seed, bad_hint])
		_check(not floor_broken, "seed %d: jam-like damage never crosses the jam floor %d" % [seed, floor_hp])
		_check(through == "", "seed %d: villain never drives through the player (%s)" % [seed, through])
	_check(done == SEEDS, "1-1 reaches the result within %.0f s for %d/%d seeds" % [LIMIT_S, done, SEEDS])
	if not boss_times.is_empty():
		boss_times.sort()
		var med: float = boss_times[boss_times.size() / 2]
		print("INFO autoplay: boss time min %.1f / median %.1f / max %.1f s" % [boss_times[0], med, boss_times[-1]])
		_check(med >= 10.0 and med <= 20.0, "median boss fight %.1f s inside the P0#7 target 10–20 s" % med)
	return _fails
