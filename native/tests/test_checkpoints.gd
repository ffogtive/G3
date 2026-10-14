extends RefCounted
## r3 A3: three distance checkpoints to the villain (150 / 100 / 60 m; jamLength ≥ 200 → 180 / 130 / 90 / 50) cut the
## straight approach into beats. Both traffic backends (force_fallback false/true), stages 1-1~1-10, autopilot.
##
## 가설: ✅ a reward every few seconds (rage +0.04 (long jams 0.03), score +100×ord, ×1.5 when the segment since the
##       previous one averaged ≥ 12 m/s — r3 final; was "inside 8 s", which marked nearly every checkpoint)
##       gives the approach a rhythm without changing the rage economy at the lock (≤ +0.15 vs. no checkpoints);
##       ❓ the beat on device (prototype C++ 1-1 ≈ 5 / 10 / 16 s, fallback + T1 ≈ 5 / 12 / 15 s).
##
## Checks: every threshold below d0 - 15 fires once, in order, before the boss phase, with d < threshold; none twice
## after a wreck → retry; state().checkpoints = [{d, done, fast}]; the summed checkpoint rage ≤ 0.15 and the rage at the
## lock vs. options.checkpoints = false (1-1, 1-4, 1-9) ≤ +0.15. Prints the beat (stage clock at each checkpoint).

const _DB := preload("res://core/db.gd")
const LIMIT_S: float = 160.0

var _fails: int = 0
var _stages: Variant = null
var _tables: Dictionary = {}


func _check(ok: bool, what: String) -> void:
	print(("PASS" if ok else "FAIL") + " checkpoints: " + what)
	if not ok:
		_fails += 1


func run() -> int:
	_stages = _DB.load_json("res://data/stages.json")
	_tables = _DB.load_traffic_tables()
	for fb: bool in [false, true]:
		var tag: String = "fallback" if fb else "native"
		var first_fast: int = 0
		var later: int = 0
		var later_fast: int = 0
		var runs: Dictionary = {}
		for id: int in range(1, 11):
			var r: Dictionary = _play(id, 1, fb, {})
			runs[id] = r
			_verify(tag, id, r)
			for c: Dictionary in (r["cps"] as Array):
				if int(c["i"]) == 0:
					first_fast += 1 if bool(c["fast"]) else 0
				else:
					later += 1
					later_fast += 1 if bool(c["fast"]) else 0
		# r3 final (device + code review, minor): "빠름!" fired on 36/38 first and 70/80 later checkpoints (the first one was
		# timed from the jam start, the 8 s window was longer than the ~5 s beat), so it said nothing. The first has no
		# previous checkpoint → never fast; a later one is fast when its segment averaged ≥ fastV (12 m/s).
		_check(first_fast == 0 and later > 0 and float(later_fast) / float(later) < 0.8,
			"%s: '빠름!' carries information — first checkpoint never fast (%d), later %d/%d fast (< 80 %%)" % [tag, first_fast,
			later_fast, later])
		for id: int in [1, 4, 9]:
			var r: Dictionary = runs[id]
			var b: Dictionary = _play(id, 1, fb, {"checkpoints": false})
			if bool(r["locked"]) and bool(b["locked"]):
				var d: float = float(r["rage_lock"]) - float(b["rage_lock"])
				_check(d <= 0.15 + 1e-6, "%s 1-%d: rage at the lock %.3f vs. %.3f without checkpoints (Δ %+.3f ≤ +0.15)" % [tag, id,
					float(r["rage_lock"]), float(b["rage_lock"]), d])
		_retry(fb)
	_shape()
	return _fails


func _sim(id: int, seed: int, fb: bool, opts: Dictionary) -> GameSim:
	var sim := GameSim.new()
	sim.force_fallback = fb
	var t: Dictionary = _tables.duplicate()
	t["options"] = opts
	sim.setup(_DB.find_stage(_stages, id), t, seed)
	return sim


## Expected thresholds for a stage from the data (d0 = ref_s - start s).
func _expected(sim: GameSim) -> Array[float]:
	var nk: Object = sim.get("neck") as Object
	var cc: Dictionary = {"at": [150, 100, 60], "atLong": [180, 130, 90, 50], "longJam": 200, "minLead": 15}  # spec defaults
	if nk != null:
		cc = (nk.get("cfg") as Dictionary).get("checkpoints", cc)
	var d0: float = sim.boss.ref_s() - sim.player.s
	var jl: float = float(sim.bridge.setup_info().get("jam_len", 170.0))
	var list: Array = cc["atLong"] if jl >= float(cc["longJam"]) else cc["at"]
	var out: Array[float] = []
	for d: Variant in list:
		if float(d) < d0 - float(cc["minLead"]):
			out.append(float(d))
	return out


func _play(id: int, seed: int, fb: bool, opts: Dictionary) -> Dictionary:
	var sim := _sim(id, seed, fb, opts)
	sim.autopilot = Autopilot.new(seed * 13 + 1)
	var want: Array[float] = _expected(sim)
	var cps: Array[Dictionary] = []
	var boss_clock: float = -1.0
	var bad_order: String = ""
	while sim.time < LIMIT_S and not sim.front_locked:
		sim.step(Cfg.TICK)
		for e: Dictionary in sim.events():
			if str(e["type"]) == "checkpoint":
				var rec: Dictionary = e.duplicate()
				rec["clock"] = sim.stage_clock
				rec["boss"] = sim.phase == &"boss"
				cps.append(rec)
				if float(e["dist"]) >= float(e["d"]):
					bad_order = "dist %.1f ≥ %.1f" % [float(e["dist"]), float(e["d"])]
			elif str(e["type"]) == "phase" and e["phase"] == &"boss" and boss_clock < 0.0:
				boss_clock = sim.stage_clock
	return {"locked": sim.front_locked, "cps": cps, "want": want, "boss_clock": boss_clock, "rage_lock": sim.rage,
		"bad": bad_order, "state": sim.state().get("checkpoints", [])}


func _verify(tag: String, id: int, r: Dictionary) -> void:
	var cps: Array = r["cps"]
	var want: Array[float] = r["want"]
	var label: String = "%s 1-%d" % [tag, id]
	_check(bool(r["locked"]), "%s: autopilot reaches the lock within %.0f s" % [label, LIMIT_S])
	var ds: Array[float] = []
	var order_ok: bool = true
	var before_boss: bool = true
	var rage_sum: float = 0.0
	var beat: PackedStringArray = []
	for k: int in cps.size():
		var c: Dictionary = cps[k]
		ds.append(float(c["d"]))
		order_ok = order_ok and int(c["i"]) == k and int(c["ord"]) == k + 1
		before_boss = before_boss and not bool(c["boss"]) and (float(r["boss_clock"]) < 0.0 or float(c["clock"]) <= float(r["boss_clock"]) + 1e-6)
		rage_sum += float(c["rage"])
		beat.append("%.0fm@%.1fs%s" % [float(c["d"]), float(c["clock"]), "*" if bool(c["fast"]) else ""])
	print("INFO checkpoints: %s beat %s (boss at %.1f s; * = fast ×1.5)" % [label, " ".join(beat), float(r["boss_clock"])])
	_check(ds == want, "%s: fired %s = expected %s (each once)" % [label, str(ds), str(want)])
	_check(order_ok and r["bad"] == "", "%s: in order, each below its threshold %s" % [label, r["bad"]])
	_check(before_boss, "%s: all before the boss phase" % label)
	_check(rage_sum <= 0.15 + 1e-6, "%s: checkpoint rage %.3f ≤ 0.15" % [label, rage_sum])
	var st: Array = r["state"]
	var done_ok: bool = st.size() == want.size()
	for c: Variant in st:
		done_ok = done_ok and bool((c as Dictionary).get("done", false))
	_check(done_ok, "%s: state().checkpoints all done at the lock (%d)" % [label, st.size()])


## Wreck after the lock → retry 33 m behind the villain: no checkpoint fires again; they stay done.
func _retry(fb: bool) -> void:
	var tag: String = "fallback" if fb else "native"
	var sim := _sim(1, 5, fb, {})
	sim.autopilot = Autopilot.new(5)
	var n: int = 0
	var t_end: float = LIMIT_S
	while sim.time < t_end and not sim.front_locked:
		sim.step(Cfg.TICK)
		for e: Dictionary in sim.events():
			n += 1 if str(e["type"]) == "checkpoint" else 0
	var first: int = n
	sim.apply_damage(999.0, "test wreck")
	var retried: bool = false
	while sim.time < t_end and not (retried and sim.front_locked):
		sim.step(Cfg.TICK)
		for e: Dictionary in sim.events():
			n += 1 if str(e["type"]) == "checkpoint" else 0
			retried = retried or str(e["type"]) == "retry"
	var st: Array = sim.state()["checkpoints"]
	var all_done: bool = not st.is_empty()
	for c: Variant in st:
		all_done = all_done and bool((c as Dictionary)["done"])
	_check(retried and first > 0 and n == first and all_done,
		"%s 1-1: wreck → retry → re-lock: %d checkpoint events before, %d after (no duplicates), state all done" % [tag, first, n - first])


func _shape() -> void:
	var sim := _sim(4, 1, false, {})
	var st: Array = sim.state().get("checkpoints", [])
	var ok: bool = st.size() == 4
	for c: Variant in st:
		ok = ok and (c as Dictionary).has("d") and (c as Dictionary).has("done") and (c as Dictionary).has("fast") and not bool((c as Dictionary)["done"])
	_check(ok, "1-4 (jamLength 200) state().checkpoints = 4 × {d, done, fast} from atLong: %s" % str(st))
	var off := _sim(1, 1, false, {"checkpoints": false})
	_check((off.state().get("checkpoints", [1]) as Array).is_empty(), "options.checkpoints = false → no checkpoints")
