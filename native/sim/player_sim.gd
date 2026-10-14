class_name PlayerSim
extends RefCounted
## player.js without the mesh: lane hops, auto accel, soft follow, jam collisions, boss/cruise/idle driving.
## Native rule P0#1 (DESIGN_REVIEW 2026-10-13): ctx.leash_v caps the jam-mode speed before the front lock so the
## player cannot run away past the villain (GameSim computes it).
##
## 가설: ✅ the web Player is a pure kinematic model once the mesh writes are dropped; GameSim feeds it the leader
##       (previous tick's buckets, like traffic.leaderOf) so the C++ core stays the single owner of the car buckets.

var tune: Dictionary = {}
var s: float = 0.0
var lane: int = 3
var x: float = 0.0
var v: float = 0.0
var a: float = 0.0
var len: float = 4.2
var w: float = 1.92
var lc_from: float = 0.0
var lc_t: float = 1.0
var lc_dir: int = 0
var wiggle_t: float = 1.0
var wiggle_dir: int = 0
var wig: float = 0.0
var invuln: float = 0.0
var bump_kick: float = 0.0
var land_grace: float = 0.0
var roll: float = 0.0
var yaw: float = 0.0
var hop: float = 0.0
var mode: StringName = &"jam"
var ghost: bool = false
var jump_t: float = 0.0
var jump_dur: float = 0.75
var boost_t: float = 0.0
var brake_on: bool = false
var slow_time: float = 0.0
var shoulder_closed: bool = false
var stats: Dictionary = {"speed": 1.0, "armor": 0, "tow": false}


func setup(p_tune: Dictionary, dims: Dictionary) -> void:
	tune = p_tune
	len = float(dims.get("L", 4.2))
	w = float(dims.get("W", 1.92))


func reset(p_s: float, p_lane: int) -> void:
	s = p_s
	lane = p_lane
	x = Cfg.lane_x(p_lane)
	v = 0.0
	a = 0.0
	lc_from = x
	lc_t = 1.0
	lc_dir = 0
	wiggle_t = 1.0
	wiggle_dir = 0
	invuln = 0.0
	bump_kick = 0.0
	land_grace = 0.0
	roll = 0.0
	yaw = 0.0
	hop = 0.0
	mode = &"jam"
	ghost = false
	jump_t = 0.0
	jump_dur = 0.75
	boost_t = 0.0
	brake_on = false
	slow_time = 0.0


func changing_lane() -> bool:
	return lc_t < 1.0


## player.js requestLane: "ok" | "edge" | "closed" | "busy" | "blocked" (out["blocker"] = id).
func request_lane(dir: int, traffic: TrafficBridge, out: Dictionary) -> String:
	var tl: int = lane + dir
	if tl < 0 or tl > Cfg.SHOULDER_LANE:
		_wiggle(dir)
		return "edge"
	if tl == Cfg.SHOULDER_LANE and shoulder_closed:
		_wiggle(dir)
		return "closed"
	if lc_t < 0.65:
		return "busy"
	if not ghost and traffic != null:
		var b: int = traffic.can_merge(tl, 0.35)
		if b != 0:
			_wiggle(dir)
			out["blocker"] = b
			return "blocked"
	lc_from = x
	lane = tl
	lc_t = 0.0
	lc_dir = dir
	return "ok"


func _wiggle(dir: int) -> void:
	wiggle_t = 0.0
	wiggle_dir = dir


## External knock (villain attack). back < 0 pushes forward (away from the villain behind).
func knock(back: float, kick: float) -> void:
	s -= back
	v = minf(v, 0.0) - 1.5
	bump_kick = kick
	invuln = float((tune.get("hp", {}) as Dictionary).get("invuln", 1.0))


## hop: air time (sim s). p_invuln > 0: invulnerable that long (SKILLS mv_jump in the fight). boost: the jam hop's
## forward kick (off in the fight, where the boss-mode follow controller owns the speed). GameSim owns cool / ownership.
func jump(hop_s: float = 0.75, p_invuln: float = 0.0, boost: bool = true) -> bool:
	if jump_t > 0.0:
		return false
	jump_dur = maxf(0.05, hop_s)
	jump_t = jump_dur
	invuln = maxf(invuln, p_invuln)
	if boost:
		v = maxf(v, 10.0)
	return true


## ctx: {mode, brake, cruise_v, boss_ref_s, boss_ref_v, fight_gap, leash_v, leader: Callable() -> Dictionary}.
## leader dict: {id, gap, type, v, smash}. Returns [{type: bump|smash|tow, id, type_of, rel_v}].
func update(dt: float, ctx: Dictionary) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	mode = ctx.get("mode", &"jam")
	invuln = maxf(0.0, invuln - dt)
	var prev_v: float = v
	var leader: Callable = ctx.get("leader", Callable())
	var spd: float = float(stats.get("speed", 1.0))
	var tow: bool = bool(stats.get("tow", false))
	var boosting: bool = boost_t > 0.0
	if mode == &"jam":
		var braking: bool = bool(ctx.get("brake", false))
		var brake_a: float = float(tune.get("playerBrake", 22.0))
		if braking:
			v = maxf(0.0, v - brake_a * dt)
		else:
			var vmax: float = float(tune.get("shoulderMaxV" if lane == Cfg.SHOULDER_LANE else "playerMaxV", 18.0)) * spd * (1.4 if boosting else 1.0)
			v = minf(vmax, v + float(tune.get("playerAccel", 9.0)) * (2.0 if boosting else 1.0) * dt * (2.2 if v < 0.0 else 1.0))
		var auto: bool = false
		var L0: Dictionary = leader.call() if leader.is_valid() else {}
		if PlayerSim.has_leader(L0):
			var obstacle: bool = str(L0.get("type", "")) == "obstacle"
			if not bool(L0.get("smash", false)) and not (jump_t > 0.0) and not (tow and obstacle):
				var v_safe: float = maxf(0.0, float(L0.get("v", 0.0)) + maxf(0.0, float(L0["gap"]) - 0.9) * 2.4)
				if v > v_safe:
					v = maxf(v_safe, v - brake_a * dt)
					auto = true
		# P0#1 leash (native): no running away from the villain before the front lock
		var leash_v: float = float(ctx.get("leash_v", INF))
		if v > leash_v:
			v = maxf(leash_v, v - brake_a * dt)
			auto = true
		brake_on = braking or auto
	elif mode == &"boss":
		var target: float = float(ctx.get("boss_ref_s", s)) + float(ctx.get("fight_gap", 11.0))
		var v_cmd: float = float(ctx.get("boss_ref_v", 0.0)) + clampf((target - s) * 1.6, -7.0, 9.0)
		var dv: float = v_cmd - v
		v += clampf(dv, -14.0 * dt, 12.0 * dt)
		brake_on = dv < -0.5
	elif mode == &"cruise":
		var vt: float = float(ctx.get("cruise_v", 0.0))
		var L: Dictionary = leader.call() if leader.is_valid() else {}
		if PlayerSim.has_leader(L) and float(L["gap"]) < 12.0:
			vt = minf(vt, float(L.get("v", 0.0)) + maxf(-3.0, (float(L["gap"]) - 5.0) * 0.6))
		var dvc: float = vt - v
		v += clampf(dvc, -14.0 * dt, 7.0 * dt)
		brake_on = dvc < -1.0
	else:
		var dvi: float = float(ctx.get("cruise_v", 0.0)) - v
		v += clampf(dvi, -8.0 * dt, 6.0 * dt)
		brake_on = v < 0.5
	a = (v - prev_v) / maxf(dt, 1e-4)
	s += v * dt

	# collisions (jam only)
	if mode == &"jam" and not ghost and leader.is_valid():
		var L2: Dictionary = {} if jump_t > 0.0 else leader.call()
		if PlayerSim.has_leader(L2) and float(L2["gap"]) < 0.0:
			var gap: float = float(L2["gap"])
			var other_v: float = float(L2.get("v", 0.0))
			var kind: String = str(L2.get("type", ""))
			if bool(L2.get("smash", false)):
				events.append({"type": "smash", "id": int(L2["id"])})
				if not boosting:
					v *= 0.62
			elif kind == "obstacle" and tow:
				events.append({"type": "tow", "id": int(L2["id"])})
			else:
				s = s + gap - 0.35
				if land_grace > 0.0:
					v = minf(v, other_v)
				elif invuln <= 0.0:
					var rel_v: float = v - other_v
					v = minf(v, other_v) * 0.2 - 2.6
					bump_kick = 1.0
					invuln = 0.45
					events.append({"type": "bump", "id": int(L2["id"]), "type_of": kind, "rel_v": rel_v, "push": boosting})
				else:
					v = minf(v, other_v)
	if mode == &"jam" and v < 5.0:
		slow_time += dt

	# lateral hop
	if lc_t < 1.0:
		lc_t = minf(1.0, lc_t + dt / float(tune.get("laneChangeTime", 0.18)))
		var e: float = 1.0 - pow(1.0 - lc_t, 3.0)
		x = lc_from + (Cfg.lane_x(lane) - lc_from) * e
		var arc: float = sin(PI * lc_t)
		hop = 0.28 * arc
		roll = -lc_dir * 0.16 * arc
		yaw = -lc_dir * 0.16 * arc
	else:
		x = Cfg.lane_x(lane)
		hop *= exp(-dt * 20.0)
		roll *= exp(-dt * 14.0)
		yaw *= exp(-dt * 14.0)
	wig = 0.0
	if wiggle_t < 1.0:
		wiggle_t = minf(1.0, wiggle_t + dt / 0.22)
		wig = sin(PI * wiggle_t) * 0.55 * wiggle_dir
	land_grace = maxf(0.0, land_grace - dt)
	if jump_t > 0.0:
		jump_t = maxf(0.0, jump_t - dt)
		hop = maxf(hop, sin(PI * (1.0 - jump_t / jump_dur)) * 3.4)
		if jump_t == 0.0:
			land_grace = 0.35
	bump_kick = maxf(0.0, bump_kick - dt * 3.2)
	return events


static func has_leader(L: Dictionary) -> bool:
	return not L.is_empty() and str(L.get("type", "")) != "" and is_finite(float(L.get("gap", INF)))


## Record for TrafficBridge.step / sync_player.
func traffic_state(time: float) -> Dictionary:
	return {"lane": float(lane), "s": s, "v": v, "x": x, "len": len, "w": w,
		"mode": "jam" if mode == &"jam" else str(mode), "time": time}


## traffic.js occupies(e, lane): |x - laneX(lane)| < w/2 + LANE_W/2 - 0.6
func occupies(p_lane: int) -> bool:
	return absf(x - Cfg.lane_x(p_lane)) < w / 2.0 + Cfg.LANE_W / 2.0 - 0.6
