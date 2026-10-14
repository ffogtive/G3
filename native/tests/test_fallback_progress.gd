## r3 T1 (e2e): fallback approach pace — autopilot, force_fallback ∈ {false, true}, 1-1 … 1-4 × seeds 1-5.
## 가설: ✅ the device fallback (_Creep) had no let-in / stuck assist / auto tow / shoulder honk, so the approach was
##       45-95 s (2.3-3.8× native), stopped 47-65 % of the time and 26-68 honks got no reaction; with the C++ rules
##       ported the fallback approach lands within 1.5× of native.
## Gates per run (fallback): jam → boss ≤ 30 s and ≤ 1.5 × the native run (same stage / seed), stopped (v < 1) ≤ 30 % of
## the jam phase (or ≤ native + 5 pp where the stage stops more on native too), unanswered honks (honk_reply "") ≤ 8.
## Native runs are the reference (reported, not gated).
extends RefCounted

const SUITE := "e2e"
const _DB := preload("res://core/db.gd")
const GameRun := preload("res://tests/fallback_run.gd")
const STAGES: Array[int] = [1, 2, 3, 4]
const SEEDS: Array[int] = [1, 2, 3, 4, 5]
const LIMIT_S: float = 120.0

var _fails: int = 0


func _check(ok: bool, what: String) -> void:
	print(("PASS" if ok else "FAIL") + " fallback_progress: " + what)
	if not ok:
		_fails += 1


func run() -> int:
	var st_all: Variant = _DB.load_json(_DB.DATA_DIR + "/stages.json")
	var native: bool = TrafficBridge.native_available()
	if not native:
		print("SKIP fallback_progress: C++ Traffic not loaded — the 1.5× native gate is skipped, absolute gates still run")
	var worst_ratio: float = 0.0
	var worst_jam: float = 0.0
	var worst_stop: float = 0.0
	var worst_none: int = 0
	for sid: int in STAGES:
		var stage: Dictionary = _DB.find_stage(st_all, sid)
		for sd: int in SEEDS:
			var f: Dictionary = GameRun.approach(stage, sd, true, LIMIT_S)
			var n: Dictionary = GameRun.approach(stage, sd, false, LIMIT_S) if native else {}
			var ratio: float = float(f["jam"]) / maxf(0.1, float(n["jam"])) if native else 0.0
			# stopped share: ≤ 30 %, or no worse than the native run (+5 pp) where the stage itself stops more (1-4 seed 5:
			# native 37 % on the very same trajectory — blocked shoulder + gapCheck, not the fallback)
			var stop_cap: float = maxf(0.30, float(n["stop"]) + 0.05) if native else 0.30
			var ok: bool = float(f["jam"]) > 0.0 and float(f["jam"]) <= 30.0 and float(f["stop"]) <= stop_cap and int(f["none"]) <= 8
			if native:
				ok = ok and ratio <= 1.5
			worst_ratio = maxf(worst_ratio, ratio)
			worst_jam = maxf(worst_jam, float(f["jam"]) if float(f["jam"]) > 0.0 else 999.0)
			worst_stop = maxf(worst_stop, float(f["stop"]))
			worst_none = maxi(worst_none, int(f["none"]))
			_check(ok, "1-%d seed %d: fallback jam→boss %.1f s (native %s, ×%.2f), stopped %.0f %% (native %s, cap %.0f %%), unanswered honks %d, assists %d, tows %d, honks %s" % [
				sid, sd, float(f["jam"]), ("%.1f s" % float(n["jam"])) if native else "-", ratio, 100.0 * float(f["stop"]),
				("%.0f %%" % (100.0 * float(n["stop"]))) if native else "-", 100.0 * stop_cap, int(f["none"]),
				int(f["assists"]), int(f["tows"]), JSON.stringify(f["honks"])])
	print("INFO fallback_progress: worst fallback jam→boss %.1f s, worst ×native %.2f, worst stopped %.0f %%, worst unanswered %d" % [
		worst_jam, worst_ratio, 100.0 * worst_stop, worst_none])
	return _fails


