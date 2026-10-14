extends RefCounted
## r3 final (feel review, major): the fight length a person gets, not the pilot's. tests/human_bot.gd (late thumb, 압정
## held 0.7–1.5 s / let go 0.25–0.7 s, rage at a rolled goal, the plug's verb only after reading the chip) on the shipped
## data (병목 plug on), 1-1~1-4 × run seeds n = 0..2 (`-- --full`: 0..4) × bot seed 1 × both traffic backends.
##
## 가설: ❌ "hpMul 1.7 → 1.45 shortens it" — measured: the same human moved 0.5–1.5 s (combo / skill hits are a fraction of
##       max HP). ✅ the gap to the pilot (boss entry → kill 12.7–17.6 s) was the thumb: with fire held 100 % the human
##       ran 16.4–18.2 s. weapons.tack.holdGrace 0.5 s (the volley keeps going after a short lift) → rage users 16–18 s,
##       rage savers 18.5–22 s, the pilot (a held button) unchanged. ❓ the feel on device.
## Gates (per stage, per backend): every run reaches the result; boss entry → kill median ≤ 20 s for pol natural (uses
## rage), ≤ 24 s for pol save (no rage before the lock: it waits out the plug's verb). The pilot numbers stay in
## test_e2e_skills (C2).
##   godot47 --headless --path native -s res://tests/run_tests.gd -- --suite=e2e --filter=test_e2e_human [--full]

const SUITE := "e2e"
const _DB := preload("res://core/db.gd")
const _Human := preload("res://tests/human_bot.gd")
const STAGES: Array[int] = [1, 2, 3, 4]
const LIMIT_S: float = 200.0
const GATE: Dictionary = {"natural": 20.0, "save": 24.0}

var _fails: int = 0


func _check(ok: bool, what: String) -> void:
	print(("PASS" if ok else "FAIL") + " e2e_human: " + what)
	if not ok:
		_fails += 1


func run() -> int:
	var full: bool = OS.get_cmdline_user_args().has("--full")
	var stages: Dictionary = _DB.load_json("res://data/stages.json")
	var tables: Dictionary = _DB.load_traffic_tables()
	var t0: int = Time.get_ticks_msec()
	for fb: bool in [false, true]:
		var tag: String = "fallback" if fb else "native"
		for pol: String in GATE:
			for id: int in STAGES:
				var bk: Array[float] = []
				var rows: PackedStringArray = []
				var done: int = 0
				var n_runs: int = 5 if full else 3
				for n: int in n_runs:
					var r: Dictionary = _run(_DB.find_stage(stages, id), tables, fb, n, pol)
					done += 1 if bool(r["done"]) else 0
					if float(r["boss_to_kill"]) >= 0.0:
						bk.append(float(r["boss_to_kill"]))
					rows.append("n%d %.1f/%.1f" % [n, float(r["boss_to_kill"]), float(r["lock_to_kill"])])
				bk.sort()
				var med: float = bk[bk.size() / 2] if not bk.is_empty() else INF
				print("INFO e2e_human: %s %s 1-%d boss→kill/lock→kill %s" % [tag, pol, id, ", ".join(rows)])
				_check(done == n_runs, "%s %s 1-%d: %d/%d runs reach the result" % [tag, pol, id, done, n_runs])
				_check(med <= float(GATE[pol]), "%s %s 1-%d: boss entry → kill median %.1f s ≤ %.0f s" % [tag, pol, id, med, float(GATE[pol])])
	print("INFO e2e_human: %.1f s" % ((Time.get_ticks_msec() - t0) / 1000.0))
	return _fails


func _run(stage: Dictionary, tables: Dictionary, fb: bool, n: int, pol: String) -> Dictionary:
	var sid: int = int(stage.get("id", 0))
	var t: Dictionary = tables.duplicate()
	t["options"] = {"loadout": {}}
	var sim := GameSim.new()
	sim.force_fallback = fb
	var seed: int = Mulberry32.run_seed(sid, n)
	sim.setup(stage, t, seed)
	sim.autopilot = _Human.new(seed * 13 + 1 + 100003, pol)
	var t_boss: float = -1.0
	var t_lock: float = -1.0
	var t_kill: float = -1.0
	while sim.time < LIMIT_S and sim.phase != &"result":
		sim.step(Cfg.TICK)
		for e: Dictionary in sim.events():
			if str(e["type"]) == "phase":
				if e["phase"] == &"boss" and t_boss < 0.0:
					t_boss = sim.real_time
				elif e["phase"] == &"kill" and t_kill < 0.0:
					t_kill = sim.real_time
			elif str(e["type"]) == "lock" and t_lock < 0.0:
				t_lock = sim.real_time
	return {"done": sim.phase == &"result", "boss_to_kill": t_kill - t_boss if t_kill >= 0.0 and t_boss >= 0.0 else -1.0,
		"lock_to_kill": t_kill - t_lock if t_kill >= 0.0 and t_lock >= 0.0 else -1.0}
