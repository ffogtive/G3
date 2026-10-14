## T0: the player never overlaps a blocking shoulder obstacle (breakdown car) — C++ core and GDScript fallback.
## 가설: ✅ device feedback 2026-10-14 ("차량, 장애물(갓길) 그냥 통과함") = the fallback had no shoulder leaders.
## (Smashable cones/debris are flung on contact and an auto-tow may remove the breakdown — web parity — so the check is
## "no overlap with an obstacle that is still there", not "stops at the first one".)
extends RefCounted

const _DB := preload("res://core/db.gd")


func run() -> int:
	var fails := 0
	var stage: Dictionary = _DB.find_stage(_DB.load_json(_DB.DATA_DIR + "/stages.json"), 1)
	var modes: Array[bool] = [true]
	if TrafficBridge.native_available():
		modes.push_front(false)
	for fb: bool in modes:
		var sim := GameSim.new()
		sim.force_fallback = fb
		sim.setup(stage, _DB.load_traffic_tables(), 1007)
		sim.input(&"continue")
		var overlap := 0
		var bumps := 0
		for i: int in 120 * 30:
			if i == 10:
				sim.player.lane = 4
				sim.player.x = 9.0
			sim.step(1.0 / 120.0)
			for e: Dictionary in sim.events():
				if str(e.get("type", "")) == "bump":
					bumps += 1
			if sim.player.lane != 4 or sim.player.changing_lane():
				continue
			var pf: float = sim.player.s + 2.1
			var pr: float = sim.player.s - 2.1
			for o: Variant in sim.bridge.obstacles():
				var od: Dictionary = o
				if bool(od.get("smash", false)):
					continue
				var half: float = float(od["len"]) / 2.0
				if pf > float(od["s"]) - half + 0.6 and pr < float(od["s"]) + half - 0.6:
					overlap += 1
		var ok: bool = overlap == 0 and bumps > 0
		print("%s %s shoulder: no overlap with a breakdown car (overlap ticks %d, bumps %d)"
			% ["PASS" if ok else "FAIL", "fallback" if fb else "native", overlap, bumps])
		if not ok:
			fails += 1
	return fails
