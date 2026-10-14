## T0: the player never overlaps a blocking shoulder obstacle (breakdown car) — C++ core and GDScript fallback.
## 가설: ✅ device feedback 2026-10-14 ("차량, 장애물(갓길) 그냥 통과함") = the fallback had no shoulder leaders.
## (Smashable cones/debris are flung on contact and an auto-tow may remove the breakdown — web parity — so the check is
## "no overlap with an obstacle that is still there", not "stops at the first one".)
## T0: the player behind a villain in its lane, holding forward (plain and boosted), never overlaps or passes it before
## the front lock — it bumps / follows instead.
## 가설: ✅ device feedback 2026-10-14 #1 ("빌런 차 뒤에섰을때 앞으로 통과되는 현상") = the fallback _Creep leader and
## lane checks only knew NPC cars and shoulder obstacles, never the villains the boss sim hands over.
extends RefCounted

const _DB := preload("res://core/db.gd")
const STAGES: Array[int] = [1, 3, 5, 6]  # straight-lane villains (a zig villain leaves the lane by design)


func run() -> int:
	var fails := 0
	var modes: Array[bool] = [true]
	if TrafficBridge.native_available():
		modes.push_front(false)
	for fb: bool in modes:
		fails += _shoulder(fb)
		for sid: int in STAGES:
			for boost: bool in [false, true]:
				fails += _villain_behind(fb, sid, boost)
		fails += _villain_merge(fb)
	return fails


func _shoulder(fb: bool) -> int:
	var stage: Dictionary = _DB.find_stage(_DB.load_json(_DB.DATA_DIR + "/stages.json"), 1)
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
	return 0 if ok else 1


## Puts the player 6 m behind the first villain in the villain's own lane once the jam starts, then holds forward
## (boost_t refreshed every tick for the boosted run) for 8 s. Fails on any tick where the player's nose is more than
## 0.25 m into the villain's tail, or the player's centre gets ahead of the villain's, before the front lock.
func _villain_behind(fb: bool, sid: int, boost: bool) -> int:
	var stage: Dictionary = _DB.find_stage(_DB.load_json(_DB.DATA_DIR + "/stages.json"), sid)
	if stage.is_empty() or (stage.get("villains", []) as Array).is_empty():
		return 0
	var sim := GameSim.new()
	sim.force_fallback = fb
	sim.setup(stage, _DB.load_traffic_tables(), 2024 + sid)
	sim.input(&"continue")
	var placed: bool = false
	var worst: float = -INF
	var passed: int = 0
	var bumps: int = 0
	var ticks: int = 0
	var vlane: int = -1
	for i: int in 120 * 14:
		if not placed and sim.phase == &"jam":
			var v0: Dictionary = sim.boss.alive()[0]
			var lanes: Array[int] = BossSim.lanes_of(v0)
			if lanes.is_empty():
				return 0
			vlane = lanes[0]
			sim.player.lane = vlane
			sim.player.x = Cfg.lane_x(vlane)
			sim.player.lc_t = 1.0
			sim.player.s = float(v0["s"]) - float(v0["len"]) / 2.0 - sim.player.len / 2.0 - 1.2
			sim.player.v = float(v0["v"])
			placed = true
		if boost and placed:
			sim.player.boost_t = 1.0
		sim.step(1.0 / 120.0)
		for e: Dictionary in sim.events():
			if str(e.get("type", "")) == "bump":
				bumps += 1
		if not placed:
			continue
		if sim.front_locked or not (sim.phase in [&"jam", &"boss"]) or not sim.boss.any_alive():
			break
		if sim.player.lane != vlane or sim.player.changing_lane():
			continue
		ticks += 1
		for v: Dictionary in sim.boss.alive():
			if not BossSim.lanes_of(v).has(vlane):
				continue
			var nose: float = sim.player.s + sim.player.len / 2.0
			var tail: float = float(v["s"]) - float(v["len"]) / 2.0
			if sim.player.s < float(v["s"]) + 0.01:
				worst = maxf(worst, nose - tail)
			if sim.player.s > float(v["s"]) - 0.01 and sim.player.s - float(v["s"]) < float(v["len"]):
				passed += 1
	var ok: bool = placed and ticks > 120 * 4 and worst < 0.25 and passed == 0
	print("%s %s stage %d%s: behind the villain in its lane, no pass-through (ticks %d, worst overlap %.2f m, passed %d, bumps %d)"
		% ["PASS" if ok else "FAIL", "fallback" if fb else "native", sid, " boost" if boost else "", ticks, worst, passed, bumps])
	return 0 if ok else 1


## A lane change into the villain's lane alongside it is refused (it is a car, not a hole); next to it is fine.
func _villain_merge(fb: bool) -> int:
	var stage: Dictionary = _DB.find_stage(_DB.load_json(_DB.DATA_DIR + "/stages.json"), 1)
	var sim := GameSim.new()
	sim.force_fallback = fb
	sim.setup(stage, _DB.load_traffic_tables(), 77)
	sim.input(&"continue")
	for i: int in 120 * 3:
		sim.step(1.0 / 120.0)
		if sim.phase == &"jam":
			break
	var v0: Dictionary = sim.boss.alive()[0]
	var vlane: int = BossSim.lanes_of(v0)[0]
	var side: int = vlane + 1 if vlane < 3 else vlane - 1
	sim.player.lane = side
	sim.player.x = Cfg.lane_x(side)
	sim.player.lc_t = 1.0
	sim.player.s = float(v0["s"])
	sim.sync_traffic_player()
	var blocked: int = sim.bridge.can_merge(vlane)
	var lead: Dictionary = sim.bridge.gap_ahead(vlane, float(v0["s"]) - float(v0["len"]) / 2.0 - 0.5)
	var ok: bool = blocked != 0 and str(lead.get("type", "")) == "villain"
	print("%s %s villain lane: merge alongside refused (blocker %d), gap_ahead sees it (%s, %.1f m)"
		% ["PASS" if ok else "FAIL", "fallback" if fb else "native", blocked, str(lead.get("type", "")), float(lead.get("gap", INF))])
	return 0 if ok else 1
