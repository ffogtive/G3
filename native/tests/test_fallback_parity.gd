## r3 T2 (e2e): fallback per-stage content parity in play — autopilot on 1-1 … 1-10.
## 가설: ✅ the fallback had no stage shoulder modes, cheaters, minis, lane kinds, yield pockets or frontRage cars, so every
##       stage played the same on the device and 1-5 (closed shoulder, pass lane 0 + yield pocket) never reached the
##       villain (180-240 s soft-lock). With C++ spawn_jam ②③ + jamShape on _Creep:
## Gates:
##   - 1-5 fallback: jam start → front lock ≤ 90 s on seeds 1-5 (native 45-50 s)
##   - 1-1 … 1-10 × seeds 1-3: fallback jam → boss within ±35 % of native (same stage / seed)
##   - 1-1 fallback: a tack in the jam hits a mini (≥ 1 hit {kind: mini}) and ≥ 10 frontRage bubbles up to the lock
extends RefCounted

const SUITE := "e2e"
const _DB := preload("res://core/db.gd")
const GameRun := preload("res://tests/fallback_run.gd")

var _fails: int = 0


func _check(ok: bool, what: String) -> void:
	print(("PASS" if ok else "FAIL") + " fallback_parity: " + what)
	if not ok:
		_fails += 1


func run() -> int:
	var st_all: Variant = _DB.load_json(_DB.DATA_DIR + "/stages.json")
	var native: bool = TrafficBridge.native_available()
	# 1-5 soft-lock
	var st5: Dictionary = _DB.find_stage(st_all, 5)
	for sd: int in [1, 2, 3, 4, 5]:
		var r: Dictionary = GameRun.approach(st5, sd, true, 120.0, true)
		_check(float(r["lock"]) > 0.0 and float(r["lock"]) <= 90.0, "1-5 seed %d: fallback jam → lock %.1f s ≤ 90 s (jam→boss %.1f s, honks %s)" % [
			sd, float(r["lock"]), float(r["jam"]), JSON.stringify(r["honks"])])
	# jam time ±35 % of native
	if native:
		var worst: float = 0.0
		for sid: int in range(1, 11):
			var stage: Dictionary = _DB.find_stage(st_all, sid)
			for sd: int in [1, 2, 3]:
				var f: Dictionary = GameRun.approach(stage, sd, true, 150.0)
				var n: Dictionary = GameRun.approach(stage, sd, false, 150.0)
				var rel: float = (float(f["jam"]) - float(n["jam"])) / maxf(0.1, float(n["jam"]))
				worst = maxf(worst, absf(rel))
				_check(float(f["jam"]) > 0.0 and float(n["jam"]) > 0.0 and absf(rel) <= 0.35,
					"1-%d seed %d: jam→boss fallback %.1f s vs native %.1f s (%+.0f %%)" % [sid, sd, float(f["jam"]), float(n["jam"]), 100.0 * rel])
		print("INFO fallback_parity: worst |fallback − native| / native jam time = %.0f %%" % (100.0 * worst))
	else:
		print("SKIP fallback_parity: C++ Traffic not loaded (jam-time ±35 % gate)")
	# 1-1 tacks hit minis, frontRage bubbles
	var st1: Dictionary = _DB.find_stage(st_all, 1)
	var hits: int = 0
	var fr: int = 1 << 30
	for sd: int in [1, 2, 3]:
		var r1: Dictionary = GameRun.approach(st1, sd, true, 120.0, true)
		hits += int(r1["mini_hits"])
		fr = mini(fr, int(r1["front_rage"]))
	_check(hits >= 1, "1-1 fallback jam: tacks hit minis (%d mini hits over 3 seeds)" % hits)
	_check(fr >= 10, "1-1 fallback: ≥ 10 frontRage bubbles from intro to the front lock on every seed (min %d)" % fr)
	return _fails
