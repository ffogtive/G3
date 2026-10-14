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
			fails += _villain_behind(fb, sid, false, &"item1")
			fails += _villain_behind(fb, sid, false, &"jump")
		fails += _villain_merge(fb)
		fails += _jam_hop(fb)
		fails += _zig_side(fb)
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
## hop = &"item1" (the mv_jump item, owned) / &"jump" (legacy hop): tapped every 0.5 s (rvA: the jam hop used to fly
## through the villain at >= 10 m/s with every leader dropped).
func _villain_behind(fb: bool, sid: int, boost: bool, hop: StringName = &"") -> int:
	var stage: Dictionary = _DB.find_stage(_DB.load_json(_DB.DATA_DIR + "/stages.json"), sid)
	if stage.is_empty() or (stage.get("villains", []) as Array).is_empty():
		return 0
	var sim := GameSim.new()
	sim.force_fallback = fb
	var tables: Dictionary = _DB.load_traffic_tables()
	tables["options"] = {"loadout": {"items": ["mv_jump"]}}
	sim.setup(stage, tables, 2024 + sid)
	sim.input(&"continue")
	var placed: bool = false
	var worst: float = -INF
	var passed: int = 0
	var bumps: int = 0
	var ticks: int = 0
	var vlane: int = -1
	var blocked: int = 0
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
		if hop != &"" and placed and i % 60 == 0:
			sim.input(hop)
		sim.step(1.0 / 120.0)
		for e: Dictionary in sim.events():
			if str(e.get("type", "")) == "bump":
				bumps += 1
			elif str(e.get("type", "")) == "skill_denied" and str(e.get("reason", "")) == "blocked":
				blocked += 1
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
	var ok: bool = placed and ticks > 120 * 4 and worst < 0.25 and passed == 0 and (hop != &"item1" or blocked > 0)
	print("%s %s stage %d%s: behind the villain in its lane, no pass-through (ticks %d, worst overlap %.2f m, passed %d, bumps %d, '원흉은 못 넘는다' %d)"
		% ["PASS" if ok else "FAIL", "fallback" if fb else "native", sid, (" boost" if boost else "") + (" + " + str(hop) if hop != &"" else ""),
		ticks, worst, passed, bumps, blocked])
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


## rvA: the jam hop (item1) on 1-1 over 6 seeds. Hops land without snapping back (no tick moves the player back
## > 0.5 m while airborne or in the 0.3 s after landing) and 0.3 s after landing no car sits > 0.1 m inside the player.
## The fallback lands in short slots too (it backs the cleared car off), so it must actually hop.
func _jam_hop(fb: bool) -> int:
	var stage: Dictionary = _DB.find_stage(_DB.load_json(_DB.DATA_DIR + "/stages.json"), 1)
	var hops: int = 0
	var snaps: int = 0
	var worst_back: float = 0.0
	var rear: int = 0
	var worst_rear: float = 0.0
	var reasons: Dictionary = {}
	for sd: int in [1007, 3, 11, 42, 77, 5]:
		var tables: Dictionary = _DB.load_traffic_tables()
		tables["options"] = {"loadout": {"items": ["mv_jump"]}}
		var sim := GameSim.new()
		sim.force_fallback = fb
		sim.setup(stage, tables, sd)
		sim.input(&"continue")
		var watch_until: int = -1
		var check_at: int = -1
		var prev_s: float = 0.0
		for i: int in 120 * 45:
			if sim.phase == &"jam" and i % 60 == 0:
				sim.input(&"item1")
			prev_s = sim.player.s
			sim.step(1.0 / 120.0)
			for e: Dictionary in sim.events():
				var ty: String = str(e.get("type", ""))
				if ty == "skill_start" and str(e.get("id", "")) == "mv_jump":
					hops += 1
					watch_until = i + roundi((sim.player.jump_dur + 0.3) * 120.0)
					check_at = watch_until
				elif ty == "skill_denied" and str(e.get("id", "")) == "mv_jump":
					reasons[str(e.get("reason", ""))] = int(reasons.get(str(e.get("reason", "")), 0)) + 1
			if i <= watch_until and prev_s - sim.player.s > 0.5:
				snaps += 1
				worst_back = maxf(worst_back, prev_s - sim.player.s)
			if i == check_at and sim.phase == &"jam":
				var pr: float = sim.player.s - sim.player.len / 2.0
				var pf: float = sim.player.s + sim.player.len / 2.0
				for b: Array in sim._lane_bodies(sim.player.lane, sim.player.s - 10.0, sim.player.s + 10.0):
					if str(b[2]) != "car":
						continue
					var ov: float = minf(pf, float(b[1])) - maxf(pr, float(b[0]))
					if ov > 0.1:
						rear += 1
						worst_rear = maxf(worst_rear, ov)
			if sim.phase != &"jam" and sim.phase != &"intro":
				break
	var ok: bool = snaps == 0 and rear == 0 and (hops >= 12 if fb else true)
	print("%s %s jam hop: lands without snap-back or a car inside the player (hops %d, snap-backs %d max %.2f m, overlaps @+0.3 s %d max %.2f m, denied %s)"
		% ["PASS" if ok else "FAIL", "fallback" if fb else "native", hops, snaps, worst_back, rear, worst_rear, str(reasons)])
	return 0 if ok else 1


## rvA (#1 family): 1-2's zig villain weaves out of its lane and back. A player following it in its lane (placed 1.2 m
## behind, holding forward for 8 s) must never have its body overlapped sideways (> 0.25 m in s and in x at once)
## before the front lock. The weave holds while the step would go into the player.
func _zig_side(fb: bool) -> int:
	var stage: Dictionary = _DB.find_stage(_DB.load_json(_DB.DATA_DIR + "/stages.json"), 2)
	if stage.is_empty() or (stage.get("villains", []) as Array).is_empty():
		return 0
	var worst: float = 0.0
	var ticks_bad: int = 0
	var ticks: int = 0
	for sd: int in [11, 1007, 4242]:
		var sim := GameSim.new()
		sim.force_fallback = fb
		sim.setup(stage, _DB.load_traffic_tables(), sd)
		sim.input(&"continue")
		var placed: bool = false
		for i: int in 120 * 12:
			if not placed and sim.phase == &"jam":
				var v0: Dictionary = sim.boss.alive()[0]
				var vl: int = roundi(float(v0["lane_pos"]))
				sim.player.lane = vl
				sim.player.x = Cfg.lane_x(vl)
				sim.player.lc_t = 1.0
				sim.player.s = float(v0["s"]) - float(v0["len"]) / 2.0 - sim.player.len / 2.0 - 1.2
				sim.player.v = float(v0["v"])
				placed = true
			sim.step(1.0 / 120.0)
			sim.events()
			if not placed:
				continue
			if sim.front_locked or not (sim.phase in [&"jam", &"boss"]) or not sim.boss.any_alive():
				break
			ticks += 1
			for v: Dictionary in sim.boss.alive():
				var os: float = (float(v["len"]) + sim.player.len) / 2.0 - absf(float(v["s"]) - sim.player.s)
				var ox: float = (float(v["w"]) + sim.player.w) / 2.0 - absf(float(v["x"]) - sim.player.x)
				if os > 0.25 and ox > 0.25:
					ticks_bad += 1
					worst = maxf(worst, minf(os, ox))
	var ok: bool = ticks > 120 * 4 and ticks_bad == 0
	print("%s %s stage 2 zig: the weave never drives into the player beside / behind it (ticks %d, overlap ticks %d, worst %.2f m)"
		% ["PASS" if ok else "FAIL", "fallback" if fb else "native", ticks, ticks_bad, worst])
	return 0 if ok else 1
