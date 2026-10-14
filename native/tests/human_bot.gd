extends Autopilot
## r3 final (feel review): a sloppy human on top of the Autopilot helpers, for the human-like gates
## (test_seed_variety 1-4 cone re-entry, test_neck arrival honks). Not an Autopilot replacement: tests preload it.
##   가설: ❓ the pilot plays the verb perfectly, so the gates it passes say nothing about a person who reacts late, takes
##         every let-in, honks on arrival and presses rage whenever it glows; this bot does, and the stalls the review
##         found (1-4 n2 110 s, 12 s plug waits) reproduce with it.
##   - every decision is executed 0.3–0.6 s after it is taken (thumb reaction), then a 0.05–0.2 s "look" before the next
##   - fire: held only while a target is visible (boss phase target / jam mini), on/off duty 0.7–1.5 s / 0.25–0.7 s (~70 %)
##   - approach: shoulder rider like the web route (shoulder, honk when blocked, slip into lane 3, back to the shoulder);
##     a lane counts as free by GameSim.lane_blocker (what the ▶ button does: cones on the shoulder do not stop it)
##   - plug: does NOT know the verb — reflex honk 0–0.3 s after being stuck behind it, a 2nd one 1.2–2.0 s later, then
##     reads the chip 0.6–1.4 s after it appears and follows it (빵 → honk again every 2 s; 조용히 → stop honking)
##   - rage pol "natural": in the jam presses when stuck behind a shoulder obstacle (50 %), in the boss phase before the
##     lock presses as soon as ≥ 1 segment (villain in sight), after the lock presses at a rolled goal (1/3/5 segs);
##     "save": no rage before the lock; "seeker": no honk / rage before the lock, takes the lane with most room;
##     "rightspam": in the approach presses ▶ whenever it is off the shoulder
##   - fight: dodges telegraphed lanes late (reaction), keeps within ±1 lane of the villain, no clever window play
## Origin: the r3 review probe (scratchpad review-playtest/native/tests/review_human_bot.gd), unchanged except _free and
## _shoulder_room (cones it has been smashing all along are not "no room").

var hr := RandomNumberGenerator.new()
var q: Array = []
var decide_at: float = 0.0
var rage_pol: String = "natural"
var f_want: bool = false
var f_eff: bool = false
var f_eff_at: float = -1.0
var f_eff_to: bool = false
var duty_on: bool = false
var duty_t: float = 0.0
var f_sent: bool = false
var rage_since: float = -1.0
var rage_goal: int = 1
var rage_wait: float = 0.8
var nk_behind_since: float = -1.0
var nk_pre_honks: int = 0
var nk_last_honk: float = -99.0
var nk_chip_at: float = -1.0
var nk_read_delay: float = 1.0
var jam_obst_id: int = 0
## logs
var presses: Array = []
var honk_log: Array = []
var lane_cmds: int = 0
var fire_ticks: int = 0
var fire_on_ticks: int = 0


func _init(seed: int = 1, pol: String = "natural") -> void:
	super(seed)
	hr.seed = seed * 7919 + 17
	rage_pol = pol
	_roll_goal()


func _roll_goal() -> void:
	var r: float = hr.randf()
	rage_goal = 1 if r < 0.3 else (3 if r < 0.6 else 5)


func _rt() -> float:
	return hr.randf_range(0.3, 0.6)


func _act(sim: GameSim, cmd: StringName, val: Variant = null, d: float = -1.0) -> void:
	q.append([sim.real_time + (_rt() if d < 0.0 else d), cmd, val])


func _busy(sim: GameSim, extra: float = 0.0) -> void:
	decide_at = sim.real_time + _rt() + hr.randf_range(0.05, 0.2) + extra


func _send(sim: GameSim, cmd: StringName, val: Variant) -> void:
	var p: PlayerSim = sim.player
	if cmd == &"rage":
		var ds: float = INF
		var vl: int = -1
		for v: Dictionary in sim.boss.alive():
			if absf(float(v["s"]) - p.s) < absf(ds):
				ds = float(v["s"]) - p.s
				vl = roundi(float(v["lane_pos"]))
		presses.append({"t": sim.real_time, "phase": str(sim.phase), "locked": sim.front_locked, "ds": ds, "dl": p.lane - vl,
			"segs": sim.skills.segs(sim), "mode": sim.skills.mode(sim), "neck": sim.neck.is_active(sim)})
	elif cmd == &"honk":
		honk_log.append({"t": sim.real_time, "phase": str(sim.phase), "neck": sim.neck.is_active(sim), "lane": p.lane})
	elif cmd == &"lane":
		lane_cmds += 1
	sim.input(cmd, val)


func drive(sim: GameSim) -> void:
	var now: float = sim.real_time
	if not q.is_empty():
		var keep: Array = []
		for a: Array in q:
			if float(a[0]) <= now:
				_send(sim, a[1], a[2])
			else:
				keep.append(a)
		q = keep
	if sim.phase == &"fail":
		sim.input(&"retry")
		return
	_fire(sim, now)
	if not (sim.phase in [&"jam", &"boss", &"cruise", &"release"]):
		return
	if now < decide_at:
		return
	var p: PlayerSim = sim.player
	var locked: bool = sim.phase == &"boss" and sim.front_locked
	if locked:
		_hfight(sim, p)
	elif rage_pol == "seeker" and sim.phase == &"boss":
		_seek(sim, p)
	elif sim.neck.is_active(sim):
		_hneck(sim, p)
	elif sim.is_jam_like():
		_happroach(sim, p)
	else:
		_cruise(sim, p)


func _fire(sim: GameSim, now: float) -> void:
	var want: bool = false
	if sim.phase == &"boss" and sim.boss.any_alive() and not sim._target().is_empty():
		want = true
	elif sim.is_jam_like() and sim.bridge.mini_target() != 0:
		want = true
	if want != f_want:
		f_want = want
		f_eff_at = now + _rt()
		f_eff_to = want
	if f_eff_at >= 0.0 and now >= f_eff_at:
		f_eff = f_eff_to
		f_eff_at = -1.0
	if now >= duty_t:
		duty_on = not duty_on
		duty_t = now + (hr.randf_range(0.7, 1.5) if duty_on else hr.randf_range(0.25, 0.7))
	var out: bool = f_eff and duty_on
	if f_eff:
		fire_ticks += 1
		fire_on_ticks += 1 if out else 0
	if out != f_sent:
		f_sent = out
		sim.input(&"fire", out)


func _rage_check(sim: GameSim) -> bool:
	var sk: SkillsSim = sim.skills
	if not sk.enabled or sk.busy("rage"):
		return false
	var segs: int = sk.segs(sim)
	var ph: StringName = sim.phase
	var locked: bool = ph == &"boss" and sim.front_locked
	if (rage_pol == "save" or rage_pol == "seeker" or rage_pol == "rightspam") and not locked:
		return false
	if segs < 1:
		rage_since = -1.0
		return false
	var want: bool = false
	if locked:
		want = segs >= rage_goal
	elif ph == &"boss":
		want = true
	elif ph == &"jam":
		var g: Dictionary = sim.bridge.gap_ahead(Cfg.SHOULDER_LANE, sim.player.s + sim.player.len / 2.0)
		if sim.player.lane == Cfg.SHOULDER_LANE and str(g.get("type", "")) == "obstacle" and float(g["gap"]) < 18.0 \
				and int(g["id"]) != jam_obst_id:
			jam_obst_id = int(g["id"])
			want = hr.randf() < 0.5
	if not want:
		rage_since = -1.0
		return false
	if rage_since < 0.0:
		rage_since = sim.real_time
		rage_wait = hr.randf_range(0.2, 1.0)
	if sim.real_time - rage_since < rage_wait and ph != &"jam":
		return false
	_act(sim, &"rage")
	rage_since = -1.0
	_roll_goal()
	_busy(sim, 0.2)
	return true


func _happroach(sim: GameSim, p: PlayerSim) -> void:
	sim.sync_traffic_player()
	var b: TrafficBridge = sim.bridge
	var SL: int = Cfg.SHOULDER_LANE
	var front: float = p.s + p.len / 2.0
	if _rage_check(sim):
		return
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
			_act(sim, &"lane", signi(best - p.lane))
		elif cur < 6.0 and hr.randf() < 0.6:
			_act(sim, &"honk")
		_busy(sim)
		return
	if p.lane < SL:
		if rage_pol == "rightspam":
			_act(sim, &"lane", 1)
		elif _free(sim, p.lane + 1) and _shoulder_room(b, p) > 6.0:
			_act(sim, &"lane", 1)
		elif p.v < 2.0 and hr.randf() < 0.5:
			_act(sim, &"honk")
		_busy(sim)
		return
	var g2: Dictionary = b.gap_ahead(SL, front)
	if int(g2["id"]) != 0 and float(g2["gap"]) < 16.0 and not _smash(b, g2):
		var cheater: bool = str(g2["type"]) == "car"
		_act(sim, &"honk")
		if float(g2["gap"]) < 7.0 and not cheater and _free(sim, SL - 1):
			_act(sim, &"lane", -1, _rt() + 0.2)
		_busy(sim, 0.2)
		return
	_busy(sim)


func _hneck(sim: GameSim, p: PlayerSim) -> void:
	var nk: NeckSim = sim.neck
	var SL: int = Cfg.SHOULDER_LANE
	if _rage_check(sim):
		return
	var ph: String = str(nk.plug.get("phase", "gone"))
	if p.lane < SL:
		if _free(sim, p.lane + 1):
			_act(sim, &"lane", 1)
		elif hr.randf() < 0.35:
			_act(sim, &"honk")
		_busy(sim, 0.3)
		return
	if ph != "block":
		_busy(sim)
		return
	var g: float = nk.gap(sim)
	var behind: bool = g <= 4.0 and g >= -0.5 and p.v - float(nk.plug.get("v", 0.0)) < 1.0
	if not behind:
		nk_behind_since = -1.0
		_busy(sim)
		return
	if nk_behind_since < 0.0:
		nk_behind_since = sim.real_time
	var chip: String = nk.chip()
	if chip == "":
		if nk_pre_honks == 0 and sim.real_time - nk_behind_since > hr.randf_range(0.0, 0.3):
			_act(sim, &"honk")
			nk_pre_honks = 1
			nk_last_honk = sim.real_time
			_busy(sim, 0.3)
			return
		if nk_pre_honks == 1 and sim.real_time - nk_last_honk > hr.randf_range(1.2, 2.0):
			_act(sim, &"honk")
			nk_pre_honks = 2
			nk_last_honk = sim.real_time
			_busy(sim, 0.3)
			return
		_busy(sim)
		return
	if nk_chip_at < 0.0:
		nk_chip_at = sim.real_time
		nk_read_delay = hr.randf_range(0.6, 1.4)
	if sim.real_time - nk_chip_at < nk_read_delay:
		_busy(sim)
		return
	if chip.contains("조용히"):
		_busy(sim)
		return
	if chip.contains("분노"):
		if sim.skills.segs(sim) >= 1:
			_act(sim, &"rage")
		_busy(sim, 0.5)
		return
	if chip.contains("빵"):
		var need: int = 2 if (chip.contains("2") or chip.contains("두")) else 1
		if sim.real_time - nk_last_honk > 2.0:
			_act(sim, &"honk")
			nk_last_honk = sim.real_time
			if need == 2:
				_act(sim, &"honk", null, _rt() + 0.5)
		_busy(sim, 0.3)
		return
	_busy(sim)


func _hfight(sim: GameSim, p: PlayerSim) -> void:
	var boss: BossSim = sim.boss
	var al: Array[Dictionary] = boss.alive()
	if al.is_empty():
		_busy(sim)
		return
	var SL: int = Cfg.SHOULDER_LANE
	var danger: Dictionary = boss.danger_lanes(p)
	if danger.has(p.lane):
		for l: int in [p.lane - 1, p.lane + 1]:
			if l >= 0 and l <= SL and not danger.has(l):
				_act(sim, &"lane", signi(l - p.lane))
				_busy(sim)
				return
		if sim.skills.item_ready(sim, 1) and hr.randf() < 0.5:
			_act(sim, &"item1")
			_busy(sim)
			return
	if _rage_check(sim):
		return
	if sim.skills.item_ready(sim, 2) and hr.randf() < 0.15:
		_act(sim, &"item2")
		_busy(sim)
		return
	var vl: int = roundi(float(al[0]["lane_pos"]))
	if absi(p.lane - vl) > 1:
		var dir: int = signi(vl - p.lane)
		if not danger.has(p.lane + dir):
			_act(sim, &"lane", dir)
	_busy(sim)


## "seeker": in the boss phase before the lock never honks / rages; greedily takes the adjacent lane with the most room
## ahead (a human looking for '들어갈 자리' behind the villain instead of solving the plug).
var seek_moves: int = 0
func _seek(sim: GameSim, p: PlayerSim) -> void:
	sim.sync_traffic_player()
	var b: TrafficBridge = sim.bridge
	var front: float = p.s + p.len / 2.0
	var cur: float = float(b.gap_ahead(p.lane, front)["gap"])
	if p.lane == Cfg.SHOULDER_LANE and sim.neck.blocking():
		cur = minf(cur, maxf(0.0, sim.neck.gap(sim)))
	var best: int = p.lane
	var bg: float = cur
	for d: int in [-1, 1]:
		var l: int = p.lane + d
		if l < 0 or l > Cfg.SHOULDER_LANE or b.can_merge(l, 0.35) != 0:
			continue
		var g: float = float(b.gap_ahead(l, front - p.len)["gap"])
		if l == Cfg.SHOULDER_LANE and sim.neck.blocking():
			g = minf(g, maxf(0.0, sim.neck.gap(sim)))
		if g > bg + 3.0:
			bg = g
			best = l
	if best != p.lane:
		seek_moves += 1
		_act(sim, &"lane", signi(best - p.lane))
	_busy(sim)


## What the ▶/◀ buttons would do now (GameSim.lane_blocker: the plug blocks, shoulder cones do not).
func _free(sim: GameSim, l: int) -> bool:
	if l < 0 or l > Cfg.SHOULDER_LANE:
		return false
	if sim.has_method(&"lane_blocker"):
		return int(sim.call(&"lane_blocker", l, 0.5)) == 0
	return sim.bridge.can_merge(l, 0.5) == 0


## Room on the shoulder ahead of the player's rear (a smashable obstacle there is driven through: no limit).
func _shoulder_room(b: TrafficBridge, p: PlayerSim) -> float:
	var g: Dictionary = b.gap_ahead(Cfg.SHOULDER_LANE, p.s - p.len / 2.0 - 1.0)
	return 99.0 if _smash(b, g) else float(g["gap"])
