class_name Autopilot
extends RefCounted
## main.js autopilot as a GameSim input driver (tests, attract mode): plays like a decent human, not a bot that
## reads hidden state — it reacts to visible tells (danger lanes = telegraphed beams / waves / thrown items /
## lunges), keeps the lock-on band (villain lane ±1), and spends rage bombs inside the signature window.
## Decisions are throttled like the web (`autoNext`, real time); its own seeded RNG keeps runs deterministic.
##
## 가설: ✅ the web route (shoulder → honk when blocked → slip into lane 4 → shoulder again; in the fight: stay
##       beside the villain, dodge telegraphed lanes) completes 1-1; ❓ its boss time is a fair proxy for a
##       careful human (naive-bot gate is DESIGN_REVIEW P1 #10, not this file).

var rng := RandomNumberGenerator.new()
var next_t: float = 0.0
var fire: bool = false


func _init(seed: int = 1) -> void:
	rng.seed = seed


func drive(sim: GameSim) -> void:
	var ph: StringName = sim.phase
	if ph == &"fail":
		sim.input(&"retry")
		return
	var p: PlayerSim = sim.player
	var locked: bool = ph == &"boss" and sim.front_locked
	var want_fire: bool = locked
	if sim.is_jam_like():
		want_fire = sim.bridge.mini_target() != 0 or (ph == &"boss" and not sim._target().is_empty())
	if want_fire != fire:
		fire = want_fire
		sim.input(&"fire", fire)
	if sim.real_time < next_t:
		return
	if locked:
		_fight(sim, p)
	elif sim.is_jam_like():
		_approach(sim, p)
	elif ph == &"cruise" or ph == &"release":
		_cruise(sim, p)


func _free(sim: GameSim, l: int) -> bool:
	return l >= 0 and l <= Cfg.SHOULDER_LANE and sim.bridge.can_merge(l, 0.5) == 0


func _go(sim: GameSim, dir: int, wait: float) -> void:
	sim.input(&"lane", dir)
	next_t = sim.real_time + wait


func _approach(sim: GameSim, p: PlayerSim) -> void:
	sim.sync_traffic_player()
	var b: TrafficBridge = sim.bridge
	var cost: float = float(sim.tune.get("superCost", 0.2))
	var SL: int = Cfg.SHOULDER_LANE
	var front: float = p.s + p.len / 2.0
	if sim.rage >= cost * 2.0 and float(b.gap_ahead(SL, p.s).get("gap", INF)) < 20.0 and rng.randf() < 0.05:
		sim.input(&"rage")
	if p.shoulder_closed:
		var cur: float = float(b.gap_ahead(p.lane, front)["gap"])
		var best: int = p.lane
		var bg: float = cur
		for d: int in [-1, 1]:
			var l: int = p.lane + d
			if l < 0 or l > Cfg.NUM_LANES - 1 or b.can_merge(l, 0.5) != 0:
				continue
			var g: float = float(b.gap_ahead(l, front - p.len - 0.8)["gap"])
			if g > bg + 1.0:
				bg = g
				best = l
		if cur < 18.0 and best != p.lane:
			_go(sim, signi(best - p.lane), 0.25)
		elif cur < 6.0:
			sim.input(&"honk")
			next_t = sim.real_time + 0.5
		return
	var dir: int = 0
	if p.lane < SL:
		if _free(sim, p.lane + 1):
			dir = 1
			next_t = sim.real_time + 0.22
		else:
			sim.input(&"honk")
			next_t = sim.real_time + 0.3
	else:
		var g: Dictionary = b.gap_ahead(SL, front)
		var who: int = int(g["id"])
		if who != 0 and float(g["gap"]) < 16.0 and not _smash(b, g):
			sim.input(&"honk")
			var cheater: bool = str(g["type"]) == "car"  # a car on the shoulder is a cheater (honk sends it back)
			if float(g["gap"]) < 7.0 and not cheater and _free(sim, SL - 1):
				dir = -1
				next_t = sim.real_time + 0.3
	if p.lane == SL - 1 and _free(sim, SL):
		if float(b.gap_ahead(SL, p.s - p.len / 2.0 - 1.0)["gap"]) > 8.0:
			dir = 1
			next_t = sim.real_time + 0.25
	if dir != 0:
		sim.input(&"lane", dir)


func _smash(b: TrafficBridge, g: Dictionary) -> bool:
	if str(g["type"]) != "obstacle":
		return false
	for o: Variant in b.obstacles():
		if int((o as Dictionary)["id"]) == int(g["id"]):
			return bool((o as Dictionary).get("smash", false))
	return false


func _fight(sim: GameSim, p: PlayerSim) -> void:
	var boss: BossSim = sim.boss
	var al: Array[Dictionary] = boss.alive()
	if al.is_empty():
		return
	var cost: float = float(sim.tune.get("superCost", 0.2))
	# decent human: bombs go in when the villain is dazzled (P0#7), or when the bar is full anyway
	if sim.rage >= cost - 1e-6 and (sim.window_left() > 0.45 or (sim.rage >= 0.999 and rng.randf() < 0.01)):
		sim.input(&"rage")
	var danger: Dictionary = boss.danger_lanes(p)
	var vl: int = roundi(float(al[0]["lane_pos"]))
	var want: int = p.lane
	for l: int in [vl + 1, vl - 1, vl, vl + 2, vl - 2]:
		if l >= 0 and l <= Cfg.SHOULDER_LANE and not danger.has(l):
			want = l
			break
	if danger.has(p.lane):
		for l: int in [p.lane - 1, p.lane + 1]:
			if l >= 0 and l <= Cfg.SHOULDER_LANE and not danger.has(l):
				want = l
				break
	if want != p.lane:
		_go(sim, signi(want - p.lane), 0.25)


func _cruise(sim: GameSim, p: PlayerSim) -> void:
	sim.sync_traffic_player()
	var L: Dictionary = sim.bridge.leader_of_player()
	if not PlayerSim.has_leader(L) or float(L["gap"]) >= 14.0:
		return
	for d: int in [-1, 1]:
		var l: int = p.lane + d
		if l < 0 or l >= Cfg.NUM_LANES:
			continue
		if sim.bridge.lane_blocked(l, p.s - p.len / 2.0 - 1.0, p.s + p.len / 2.0 + 6.0) == 0:
			_go(sim, d, 0.4)
			return
