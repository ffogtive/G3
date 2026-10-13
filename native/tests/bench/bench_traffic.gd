extends RefCounted
## T0 perf: traffic tick cost at the 90-stage car count (NATIVE_PORT 3-2, 4-2: "traffic p95 <= 0.5ms").
##
## 가설: ❓ the C++ port keeps p95 <= 0.5 ms/tick on this container for stage 90 (web Node: 0.40-0.49 ms).
## Measures 3600 ticks at SIM_HZ after a 120-tick warm-up:
##   core   = one Traffic.update() call (what the sim pays per tick; includes the GDScript->C++ call)
##   bridge = TrafficBridge.step() (player/villain setters + update + event drain, GDScript side)
##   fallback = the GDScript creep model on stage 1 (no ext; informative only)
## Writes res://build/perf.json (native/build is gitignored). Asserts core p95 <= 0.5 ms and, in a
## template_release build of the .so, bridge p95 <= 0.5 ms too.
##
## Run: godot47 --headless --path native -s res://tests/bench/run_bench.gd
## (or from a tests/test_*.gd wrapper with SUITE "perf" so run_tests.gd --suite=perf picks it up).

const SUITE: String = "perf"
const STAGE_ID: int = 90
const WARMUP: int = 120
const TICKS: int = 3600
const BUDGET_MS: float = 0.5
const OUT_PATH: String = "res://build/perf.json"
const _DB := preload("res://core/db.gd")

var _fails: int = 0


func run() -> int:
	var tables: Dictionary = _DB.load_traffic_tables()
	var stages: Variant = _DB.load_json(_DB.DATA_DIR + "/stages.json")
	var report: Dictionary = {"stage": STAGE_ID, "ticks": TICKS, "budget_ms": BUDGET_MS, "engine": Engine.get_version_info().string}
	if TrafficBridge.native_available():
		var info: String = str(ClassDB.class_call_static(&"Traffic", &"build_info"))
		var release_so: bool = info.ends_with(" release")
		report["ext"] = info
		var stage: Dictionary = _DB.find_stage(stages, STAGE_ID)
		var core: Dictionary = _bench_core(stage, tables)
		var bridge: Dictionary = _bench_bridge(stage, tables, false)
		report["core"] = core
		report["bridge"] = bridge
		print("INFO bench_traffic: %s" % info)
		print("INFO bench_traffic: stage %d, %d NPC + %d opposite cars, %d ticks: core p50 %.4f p95 %.4f max %.4f ms | bridge p50 %.4f p95 %.4f ms"
				% [STAGE_ID, core["npc"], core["opp"], TICKS, core["p50"], core["p95"], core["max"], bridge["p50"], bridge["p95"]])
		_check(int(core["npc"]) >= 150, "stage %d spawns the 90-stage car count (%d NPC, web reference 161)" % [STAGE_ID, core["npc"]])
		_check(float(core["p95"]) <= BUDGET_MS, "C++ Traffic.update p95 %.4f ms <= %.1f ms (%s .so)" % [core["p95"], BUDGET_MS, "release" if release_so else "debug"])
		if release_so:
			_check(float(bridge["p95"]) <= BUDGET_MS, "TrafficBridge.step p95 %.4f ms <= %.1f ms (release .so)" % [bridge["p95"], BUDGET_MS])
		else:
			print("INFO bench_traffic: debug .so loaded (editor feature 'debug'); the release-.so number comes from a release mapping, see native/ext/README.md")
	else:
		print("SKIP bench_traffic: C++ Traffic not built — only the GDScript fallback is measured")
	var fb: Dictionary = _bench_bridge(_DB.find_stage(stages, 1), tables, true)
	report["fallback_stage1"] = fb
	print("INFO bench_traffic: GDScript fallback stage 1, %d cars: p50 %.4f p95 %.4f ms/tick" % [fb["npc"], fb["p50"], fb["p95"]])
	_write(report)
	return _fails


func _bench_core(stage: Dictionary, tables: Dictionary) -> Dictionary:
	var info: Dictionary = TrafficBridge.stage_setup(stage, tables)
	var tr: Object = ClassDB.instantiate(&"Traffic")
	tr.call(&"configure", tables)
	tr.call(&"spawn_jam", stage, info["villains"], {"s": info["start_s"], "lane": info["start_lane"], "len": 4.2, "w": 1.92},
			Mulberry32.traffic_seed(STAGE_ID), false)
	tr.call(&"set_context", "jam", true, true, NAN)
	var v0: Dictionary = (info["villains"] as Array)[0]
	var samples := PackedFloat64Array()
	samples.resize(TICKS)
	var t: float = 0.0
	var ps: float = float(info["start_s"])
	for k: int in WARMUP + TICKS:
		t += Cfg.TICK
		ps += 6.0 * Cfg.TICK  # player creeping up the shoulder (below the 8 m/s cheater trigger)
		var vs: float = float(v0["s"]) + float(v0["v"]) * t
		tr.call(&"set_player", ps, Cfg.lane_x(Cfg.SHOULDER_LANE), 6.0, Cfg.SHOULDER_LANE, true)
		tr.call(&"set_villain", 0, vs, vs, float(v0["x"]), float(v0["w"]), float(v0["len"]), float(v0["v"]), float(v0["vNominal"]), true)
		var u0: int = Time.get_ticks_usec()
		tr.call(&"update", Cfg.TICK, t)
		var us: int = Time.get_ticks_usec() - u0
		if k >= WARMUP:
			samples[k - WARMUP] = us / 1000.0
	var out: Dictionary = _stats(samples)
	out["npc"] = int(tr.call(&"count"))
	out["opp"] = int(tr.call(&"opp_count"))
	return out


func _bench_bridge(stage: Dictionary, tables: Dictionary, fallback: bool) -> Dictionary:
	var br := TrafficBridge.new()
	br.setup(stage, tables, -1, fallback)
	var info: Dictionary = br.setup_info()
	var samples := PackedFloat64Array()
	samples.resize(TICKS)
	var ps: float = float(info["start_s"])
	var buf := PackedFloat32Array()
	var player: Dictionary = {"lane": float(Cfg.SHOULDER_LANE), "s": ps, "v": 6.0, "x": Cfg.lane_x(Cfg.SHOULDER_LANE)}
	for k: int in WARMUP + TICKS:
		ps += 6.0 * Cfg.TICK
		player["s"] = ps
		var u0: int = Time.get_ticks_usec()
		br.step(Cfg.TICK, player)
		br.events()
		var us: int = Time.get_ticks_usec() - u0
		if k >= WARMUP:
			samples[k - WARMUP] = us / 1000.0
	br.read_into(buf)
	var out: Dictionary = _stats(samples)
	out["npc"] = br.count_npc()
	out["records"] = br.count()
	out["native"] = br.is_native()
	return out


func _stats(samples: PackedFloat64Array) -> Dictionary:
	var sorted: PackedFloat64Array = samples.duplicate()
	sorted.sort()
	var n: int = sorted.size()
	var sum: float = 0.0
	for x: float in sorted:
		sum += x
	return {
		"p50": sorted[n / 2], "p95": sorted[mini(n - 1, int(n * 0.95))], "p99": sorted[mini(n - 1, int(n * 0.99))],
		"max": sorted[n - 1], "mean": sum / maxf(1.0, n),
	}


func _write(report: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://build"))
	var f := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if f == null:
		print("INFO bench_traffic: could not write %s" % OUT_PATH)
		return
	f.store_string(JSON.stringify(report, "  ", false))
	f.close()
	print("INFO bench_traffic: wrote %s" % ProjectSettings.globalize_path(OUT_PATH))


func _check(ok: bool, what: String) -> void:
	if ok:
		print("PASS bench_traffic: %s" % what)
	else:
		_fails += 1
		print("FAIL bench_traffic: %s" % what)
