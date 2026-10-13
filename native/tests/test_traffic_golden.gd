extends RefCounted
## T0: C++ Traffic.update replays the web's recorded ticks bit-for-bit (NATIVE_PORT 3-2/3-3, M1a/M1b).
##
## 가설: ❓ with the recorded dt, inputs (player, villains, extras, phase, focusS) and sin(t*0.42 + lane*1.9)
##       injected, every tick draws the same tagged RNG values and hashes to the same state as the JS.
## Goldens (tools/export-content.mjs, web-frozen 753549a):
##   traffic_ticks_stage1.json — 600 ticks of the live page (jam, IDM, stop&go, random brakes, opp recycling)
##   traffic_auto_stage1.json  — 4800 autopilot ticks jam -> boss -> kill -> release -> cruise -> result plus the
##                               18 calls main.js makes between updates (honk, miniHit, jolt, smash, rageHorn, release)
## Replay recipe = the golden's `replay` field. Runs with web_parity on (stuck assist gated on phase 'jam',
## the R2 bug the native build fixes). SKIPs when the ext is not built.

const GOLDEN: String = "res://tests/golden"
const FILES: Array[String] = ["traffic_ticks_stage1.json", "traffic_auto_stage1.json"]
const _DB := preload("res://core/db.gd")

var _fails: int = 0


func run() -> int:
	if not TrafficBridge.native_available():
		print("SKIP test_traffic_golden: C++ Traffic not built (bash tools/godot/build_ext.sh)")
		return 0
	var tables: Dictionary = _DB.load_traffic_tables()
	var stage: Dictionary = _DB.find_stage(_DB.load_json(_DB.DATA_DIR + "/stages.json"), 1)
	var spawn: Dictionary = _DB.load_json(GOLDEN + "/spawn_stage1.json")
	for file: String in FILES:
		var path: String = GOLDEN.path_join(file)
		if not FileAccess.file_exists(path):
			print("SKIP test_traffic_golden: %s missing" % file)
			continue
		var t0: int = Time.get_ticks_msec()
		var g: Dictionary = _DB.load_json(path)
		_replay(file, g, stage, tables, spawn, Time.get_ticks_msec() - t0)
	_check_r2(stage, tables, spawn)
	return _fails


## R2 (NATIVE_PORT M1b): the web runs stuck assist only in phase 'jam'; native runs it while jamLike
## (jam + boss before the front lock), so a player stuck behind the breakdown after the boss shows up still
## gets let in. web_parity=true restores the web gate for the golden replays above.
func _check_r2(stage: Dictionary, tables: Dictionary, spawn: Dictionary) -> void:
	var out: Array[int] = []
	for parity: bool in [false, true]:
		var tr: Object = ClassDB.instantiate(&"Traffic")
		tr.call(&"configure", tables)
		var gp: Dictionary = spawn["player"]
		tr.call(&"spawn_jam", stage, spawn["villains"], {"s": gp["s"], "lane": gp["lane"], "len": gp["len"], "w": gp["w"]}, 1007, false)
		tr.call(&"set_web_parity", parity)
		tr.call(&"set_context", "boss", false, true, NAN)
		var t: float = 0.0
		for k: int in 480:  # 4 s stuck at v = 0 in lane 3
			t += Cfg.TICK
			tr.call(&"set_player", 100.0, Cfg.lane_x(3), 0.0, 3, true)
			tr.call(&"update", Cfg.TICK, t)
		out.append(int((tr.call(&"get_info") as Dictionary)["assists"]))
	_check(out[0] > 0 and out[1] == 0, "R2: stuck assist during 'boss' while jamLike: native %d assists, web_parity %d" % [out[0], out[1]])


func _replay(file: String, g: Dictionary, stage: Dictionary, tables: Dictionary, spawn: Dictionary, load_ms: int) -> void:
	var tr: Object = ClassDB.instantiate(&"Traffic")
	tr.call(&"configure", tables)
	var gp: Dictionary = spawn["player"]
	var gs: Dictionary = spawn["setup"]
	tr.call(&"spawn_jam", stage, spawn["villains"], {"s": gp["s"], "lane": gp["lane"], "len": gp["len"], "w": gp["w"]}, int(gs["seed"]), bool(gs["night"]))
	_check(int(tr.call(&"get_rng_draws")) == int(g["spawn_rng_draws"]), "%s: spawn draws %d == %d" % [file, tr.call(&"get_rng_draws"), g["spawn_rng_draws"]])
	var ids: PackedInt32Array = (tr.call(&"get_state") as Dictionary)["ids"]
	var gids: Array = g["car_ids"]
	_check(Array(ids) == gids.map(func(v: Variant) -> int: return int(v)), "%s: %d car ids in golden order" % [file, gids.size()])
	tr.call(&"set_web_parity", true)
	tr.call(&"set_trace", true)

	var events: Array = g.get("events", [])
	var ev_i: int = 0
	var ticks: Array = g["ticks"]
	var first_bad: String = ""
	var bad_ticks: int = 0
	var bad_events: int = 0
	var keyframes: int = 0
	var hc := HashingContext.new()
	var t_start: int = Time.get_ticks_usec()
	var tick_us: int = 0
	for tick_v: Variant in ticks:
		var tick: Dictionary = tick_v
		var i: int = int(tick["i"])
		# (1) calls made between updates, in order
		while ev_i < events.size() and int((events[ev_i] as Dictionary)["tick"]) == i:
			var why: String = _apply_event(tr, events[ev_i])
			if not why.is_empty():
				bad_events += 1
				if first_bad.is_empty():
					first_bad = "tick %d event %s: %s" % [i, (events[ev_i] as Dictionary)["m"], why]
			ev_i += 1
		var inp: Dictionary = tick["in"]
		# (2) obstacles main.js removed directly
		if inp.has("obstacleIds"):
			tr.call(&"set_obstacle_ids", PackedInt32Array(inp["obstacleIds"]))
		# (3) inputs + update
		_set_player(tr, inp["player"])
		var vs: Array = inp["villains"]
		tr.call(&"set_villain_count", vs.size())
		for k: int in vs.size():
			var v: Dictionary = vs[k]
			tr.call(&"set_villain", k, float(v["s"]), float(v.get("baseS", NAN)) if v.get("baseS") != null else NAN, float(v["x"]),
					float(v["w"]), float(v["len"]), float(v["v"]), float(v["vNominal"]) if v.get("vNominal") != null else NAN, bool(v["alive"]))
		var ex: Array = inp.get("extras", [])
		tr.call(&"set_extra_count", ex.size())
		for k: int in ex.size():
			var e: Dictionary = ex[k]
			tr.call(&"set_extra", k, float(e["s"]), float(e["x"]), float(e["w"]), float(e["len"]), float(e.get("v", 0.0)), e.get("alive") != false)
		tr.call(&"set_context", str(inp["phase"]), bool(inp["allowEvents"]), bool(inp.get("jamLike", true)),
				float(inp["focusS"]) if inp.get("focusS") != null else NAN)
		tr.call(&"set_sin_override", PackedFloat64Array(inp["sinLf"]))
		var u0: int = Time.get_ticks_usec()
		tr.call(&"update", float(inp["dt"]), float(inp["time"]))
		tick_us += Time.get_ticks_usec() - u0

		var out: Dictionary = tick["out"]
		var why_t: String = _compare_rng(tr.call(&"take_trace"), out.get("rng", []))
		if why_t.is_empty() and int(tr.call(&"obstacle_count")) != int(out["obstacles"]):
			why_t = "obstacles %d != %d" % [tr.call(&"obstacle_count"), out["obstacles"]]
		if why_t.is_empty():
			hc.start(HashingContext.HASH_SHA256)
			hc.update(tr.call(&"hash_bytes"))
			var h: String = hc.finish().hex_encode().substr(0, 16)
			if h != str(out["h"]):
				why_t = "hash %s != %s" % [h, out["h"]]
		if out.has("s"):
			keyframes += 1
			var kf: String = _compare_keyframe(tr.call(&"get_state"), out)
			if not kf.is_empty():
				why_t = kf if why_t.is_empty() else why_t + "; " + kf
		if not why_t.is_empty():
			bad_ticks += 1
			if first_bad.is_empty():
				first_bad = "tick %d (%s): %s" % [i, inp["phase"], why_t]
			if bad_ticks > 3:
				break  # one divergence cascades; the first one is what matters
	var wall_ms: float = (Time.get_ticks_usec() - t_start) / 1000.0
	_check(bad_ticks == 0 and bad_events == 0,
			"%s: %d ticks (%d keyframes) + %d events replay bit-exact: rng tags+u32, obstacle count, state hash%s"
			% [file, ticks.size(), keyframes, events.size(), "" if first_bad.is_empty() else " — FIRST DIFF " + first_bad])
	print("INFO test_traffic_golden: %s load %d ms, replay %.0f ms, update %.4f ms/tick avg incl. GDScript call (%s)"
			% [file, load_ms, wall_ms, tick_us / 1000.0 / maxf(1.0, ticks.size()), ClassDB.class_call_static(&"Traffic", &"build_info")])


func _set_player(tr: Object, p: Dictionary) -> void:
	tr.call(&"set_player", float(p["s"]), float(p["x"]), float(p["v"]), int(p["lane"]), str(p.get("mode", "jam")) == "jam")
	tr.call(&"set_player_dims", float(p.get("len", 4.2)), float(p.get("w", 1.92)))
	var stats: Variant = p.get("stats")
	tr.call(&"set_player_stats", stats is Dictionary and (stats as Dictionary).get("tow") == true)


func _apply_event(tr: Object, ev: Dictionary) -> String:
	_set_player(tr, ev["player"])
	var m: String = str(ev["m"])
	var args: Array = ev["args"]
	var ret: Variant = ev.get("ret")
	var why: String = ""
	match m:
		"honk":
			var opts: Dictionary = args[1] if args.size() > 1 and args[1] is Dictionary else {}
			var r: Dictionary = tr.call(&"honk", opts.get("siren") == true, opts.get("trot") == true)
			var want_kind: String = "" if ret == null else str((ret as Dictionary)["kind"])
			var want_id: int = 0 if ret == null else int((ret as Dictionary)["car"])
			if str(r["kind"]) != want_kind or (want_kind != "" and int(r["id"]) != want_id):
				why = "honk -> %s/%d, want %s/%d" % [r["kind"], r["id"], want_kind, want_id]
		"miniHit":
			var r2: String = tr.call(&"mini_hit", int((args[0] as Dictionary)["$car"]), float(args[1]))
			if r2 != ("" if ret == null else str(ret)):
				why = "miniHit -> '%s', want %s" % [r2, ret]
		"jolt":
			tr.call(&"jolt", int((args[0] as Dictionary)["$car"]))
		"smash":
			var ok: bool = tr.call(&"smash", int((args[0] as Dictionary)["$obs"]))
			if ok != (ret != null):
				why = "smash -> %s, want %s" % [ok, ret]
		"rageHorn":
			var r3: Dictionary = tr.call(&"rage_horn", float(args[1]))
			for k: String in ["smashed", "towed", "cheaters", "startled"]:
				var want: Array = ((ret as Dictionary)[k] as Array).map(func(v: Variant) -> int: return int(v))
				if Array(r3[k] as PackedInt32Array) != want:
					why = "rageHorn.%s %s != %s" % [k, r3[k], want]
		"release":
			var ws: float = -1.0 if args[1] is Dictionary else float(args[1])
			tr.call(&"release", float(args[0]), ws, int(args[2]) if args.size() > 2 else 0)
		_:
			why = "unknown event method %s" % m
	var rng_why: String = _compare_rng(tr.call(&"take_trace"), ev.get("rng", []))
	return why if rng_why.is_empty() else (rng_why if why.is_empty() else why + "; " + rng_why)


func _compare_rng(got: Array, want: Array) -> String:
	if got.size() != want.size():
		return "rng draws %d != %d (got %s want %s)" % [got.size(), want.size(), got.slice(0, 4), want.slice(0, 4)]
	for k: int in got.size():
		var a: Array = got[k]
		var b: Array = want[k]
		if str(a[0]) != str(b[0]) or int(a[1]) != int(b[1]):
			return "rng #%d %s != %s" % [k, a, b]
	return ""


func _compare_keyframe(st: Dictionary, out: Dictionary) -> String:
	var ids: PackedInt32Array = st["ids"]
	var s: PackedFloat64Array = st["s"]
	var v: PackedFloat64Array = st["v"]
	var x: PackedFloat64Array = st["x"]
	var lanes: PackedInt32Array = st["lane"]
	var gs: Array = out["s"]
	var gv: Array = out["v"]
	var gl: Array = out["lane"]
	var gx: Dictionary = out.get("x", {})
	for k: int in ids.size():
		if s[k] != float(gs[k]) or v[k] != float(gv[k]) or lanes[k] != int(gl[k]):
			return "car %d s/v/lane %.17f/%.17f/%d != %.17f/%.17f/%d" % [ids[k], s[k], v[k], lanes[k], gs[k], gv[k], gl[k]]
		var want_x: float = float(gx[str(ids[k])]) if gx.has(str(ids[k])) else Cfg.lane_x(lanes[k])
		if x[k] != want_x:
			return "car %d x %.17f != %.17f" % [ids[k], x[k], want_x]
	var os: PackedFloat64Array = st["opp_s"]
	var go: Array = out["opp_s"]
	for k: int in os.size():
		if os[k] != float(go[k]):
			return "opp %d s %.17f != %.17f" % [k, os[k], go[k]]
	return ""


func _check(ok: bool, what: String) -> void:
	if ok:
		print("PASS test_traffic_golden: %s" % what)
	else:
		_fails += 1
		print("FAIL test_traffic_golden: %s" % what)
