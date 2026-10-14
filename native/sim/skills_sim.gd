class_name SkillsSim
extends RefCounted
## docs/SKILLS.md sim side: the rage ladder (t1 경적 충격파 / t3 압정 폭격 / t5 참교육), the item skills (mv_jump 점프 쿵,
## mv_drone 드론 폭격, mv_tow 레커 호출), tap-to-skip and the state()["skills"] block. GameSim owns one and calls
## rage / item / skip from its input edges and tick() once per step (after BossSim.update). Pure GDScript on top of
## BossSim / PlayerSim / WeaponsSim, so the fight side is identical on the C++ traffic and the GDScript fallback; the
## jam side uses only TrafficBridge.rage_horn / mini_target / mini_hit / smash / remove_obstacle / obstacles (§2-5).
## Data: config.skills (no key → enabled = false and GameSim keeps the old rage horn / bomb).
## Clocks: delay / hitGap / bombGap / hop / cool / stun run on sim time (queued hits are resolved on the tick whose sim
## time reaches them, so hitstop / slow-mo stretch a multi-hit); dur / skipAfter / hitstop / slowFor are real s (the §1
## budget: skill_end comes `dur` real s after the cast, never before its last queued hit). No RNG of its own.
##
## 가설: ✅ the §6 contract (events skill_start / skill_hit / skill_end / skill_denied / tier_ready / item_ready / finisher,
##       state.skills) fits on the existing damage path once BossSim has a generic stun (= a window) and an execute;
##       ❓ skills.hpMul 1.25 keeps the 1-1 boss at 10–20 s with skills (tests/test_e2e_skills.gd measures it).

const RAGE_IDS: Dictionary = {1: "t1_wave", 3: "t3_carpet", 5: "t5_finish"}

var cfg: Dictionary = {}
var enabled: bool = false
var segs_n: int = 5
var ladder: Array[int] = [1, 3, 5]
var jam_tier: int = 1
## [{id, slot: 1|2, charges (-1 = ∞), cool (sim s left), cool_max}] sorted by slot.
var slots: Array[Dictionary] = []
## chan ("rage" | "item") -> cast record {chan, tier, id, t (real s), dur, target_id, cine, skippable, lanes, pending, ...}.
var active: Dictionary = {}
## [{at: sim time, rec, idx, n}] queued hits.
var queue: Array[Dictionary] = []
var counts: Dictionary = {}
var time_scale: float = 1.0
var _last_slow: float = -99.0
var _tiers_prev: Array[int] = []
var _fight_gain: float = 0.0
var _passive_t: float = 0.0
var _loadout: Dictionary = {}


func setup(skills_cfg: Dictionary, tune: Dictionary, loadout: Dictionary) -> void:
	cfg = skills_cfg
	enabled = not cfg.is_empty()
	segs_n = maxi(1, int(tune.get("rageSegs", 5)))
	ladder.clear()
	for t: Variant in cfg.get("ladder", [1, 3, 5]):
		ladder.append(int(t))
	jam_tier = int(cfg.get("jamTier", 1))
	_loadout = loadout
	counts = {}
	_build_slots()
	reset_run()


## Fresh fight state (setup and every retry): no casts in flight, cooldowns ready, slow-mo gap reset. Charges stay
## (they are per 판).
func reset_run() -> void:
	for rec: Dictionary in active.values():
		rec["ended"] = true
	active.clear()
	queue.clear()
	_last_slow = -99.0
	_tiers_prev = []
	_fight_gain = 0.0
	_passive_t = 0.0
	time_scale = 1.0
	for sl: Dictionary in slots:
		sl["cool"] = 0.0


func _build_slots() -> void:
	slots.clear()
	if not enabled:
		return
	var icfg: Dictionary = cfg.get("items", {})
	var ids: Array = []
	if _loadout.get("items") is Array:
		ids = (_loadout["items"] as Array).duplicate()
	else:  # older loadouts: the jump / drone flags
		if bool(_loadout.get("jump", false)):
			ids.append("mv_jump")
		if bool(_loadout.get("drone", false)):
			ids.append("mv_drone")
	var taken: Dictionary = {}
	for idv: Variant in ids:
		var id: String = str(idv)
		if not (icfg.get(id) is Dictionary):
			continue
		var ic: Dictionary = icfg[id]
		var want: int = int(ic.get("slot", slots.size() + 1))
		if taken.has(want):
			want = 3 - want
		if want < 1 or want > 2 or taken.has(want):
			continue
		taken[want] = true
		var ch: int = int(ic.get("charges", -1))
		if ch > 0 and str(_loadout.get("car", "")) == "car_wrecker":
			ch += int(ic.get("wreckerBonus", 0))
		slots.append({"id": id, "slot": want, "charges": ch, "cool": 0.0, "cool_max": 0.0})
	slots.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["slot"]) < int(b["slot"]))


func has_item(id: String) -> bool:
	for sl: Dictionary in slots:
		if str(sl["id"]) == id:
			return true
	return false


func slot_of(slot: int) -> Dictionary:
	for sl: Dictionary in slots:
		if int(sl["slot"]) == slot:
			return sl
	return {}


func _tc(tier: int) -> Dictionary:
	return cfg.get("t%d" % tier, {}) if cfg.get("t%d" % tier) is Dictionary else {}


func _ic(id: String) -> Dictionary:
	var icfg: Dictionary = cfg.get("items", {})
	return icfg.get(id, {}) if icfg.get(id) is Dictionary else {}


func cost(tier: int) -> int:
	return int(_tc(tier).get("cost", tier))


# --- read side --------------------------------------------------------------------------------------

func segs(sim: GameSim) -> int:
	return floori(sim.rage * segs_n + 1e-6)


## "jam" (jam or boss before the front lock) | "fight" | "rescue" (honkOnly fight) | "off".
func mode(sim: GameSim) -> String:
	if not enabled:
		return "off"
	if sim.phase == &"jam" or (sim.phase == &"boss" and not sim.front_locked):
		return "jam"
	if sim.phase == &"boss" and sim.boss.any_alive():
		return "rescue" if sim.stage.get("honkOnly") == true else "fight"
	return "off"


func tiers_ready(sim: GameSim) -> Array[int]:
	var out: Array[int] = []
	var m: String = mode(sim)
	var sg: int = segs(sim)
	if m == "jam":
		if sg >= cost(jam_tier):
			out.append(jam_tier)
	elif m == "fight" or m == "rescue":
		for t: int in ladder:
			if sg >= cost(t):
				out.append(t)
	return out


func next_tier(sim: GameSim) -> int:
	var r: Array[int] = tiers_ready(sim)
	return r.max() if not r.is_empty() else 0


func busy(chan: String) -> bool:
	if active.has(chan):
		return true
	return chan == "item" and active.has("rage") and int((active["rage"] as Dictionary)["tier"]) == 5


## The cinematic can be skipped now (t5 after skipAfter with its impact done, or the kill finish after finish.skipAfter).
func skip_ready(sim: GameSim) -> bool:
	var rec: Dictionary = active.get("rage", {})
	if not rec.is_empty() and bool(rec["skippable"]):
		return true
	if enabled and sim.phase == &"kill" and sim.phase_real >= float((cfg.get("finish", {}) as Dictionary).get("skipAfter", 0.6)):
		for v: Dictionary in sim.boss.villains:
			if bool(v["dying"]) and not bool(v["gone"]):
				return true
	return false


func _item_reason(sim: GameSim, sl: Dictionary) -> String:
	var id: String = str(sl["id"])
	var m: String = mode(sim)
	if m == "off" or (id == "mv_jump" and m == "rescue"):
		return "phase"
	if busy("item"):
		return "busy"
	if id == "mv_drone" or id == "mv_tow":
		if m == "jam":
			if id == "mv_drone" and sim.bridge.mini_target() != 0:
				return ""
			return "" if not _jam_obstacle(sim, float(_ic(id).get("jamRange", 40.0)), id == "mv_tow").is_empty() else "target"
		return "" if not _primary(sim, float(_ic(id).get("range", 45.0))).is_empty() else "target"
	return ""


func item_ready(sim: GameSim, slot: int) -> bool:
	var sl: Dictionary = slot_of(slot)
	return not sl.is_empty() and float(sl["cool"]) <= 0.0 and int(sl["charges"]) != 0 and _item_reason(sim, sl) == ""


func state(sim: GameSim) -> Dictionary:
	var ready: Array[int] = tiers_ready(sim)
	var m: String = mode(sim)
	var a: Dictionary = active.get("rage", active.get("item", {}))
	var act: Dictionary = {}
	if not a.is_empty():
		act = {"chan": a["chan"], "tier": a["tier"], "id": a["id"], "t": a["t"], "dur": a["dur"], "target_id": a["target_id"],
			"cine": a["cine"], "skippable": a["skippable"]}
	var items: Array[Dictionary] = []
	for sl: Dictionary in slots:
		var reason: String = _item_reason(sim, sl)
		items.append({"id": sl["id"], "slot": sl["slot"], "charges": sl["charges"], "cool": maxf(0.0, float(sl["cool"])),
			"cool_max": sl["cool_max"], "ready": float(sl["cool"]) <= 0.0 and int(sl["charges"]) != 0, "usable": reason == "",
			"reason": reason})
	return {"segs": segs(sim), "rage_tiers_ready": ready, "next_tier": ready.max() if not ready.is_empty() else 0, "mode": m,
		"execute_frac": float(_tc(5).get("execute", 0.4)) if m == "fight" and ready.has(5) else 0.0, "active": act, "items": items,
		"time_scale": time_scale, "skip_ready": skip_ready(sim), "enabled": enabled}


# --- input edges ------------------------------------------------------------------------------------

func _deny(sim: GameSim, chan: String, tier: int, id: String, reason: String) -> void:
	sim._emit({"type": "skill_denied", "chan": chan, "tier": tier, "id": id, "reason": reason})


## &"rage" tap. req 0 = the highest ready tier (jam / before the lock: always jamTier); 1|3|5 = that tier (tests, autopilot).
func rage(sim: GameSim, req: int) -> void:
	var m: String = mode(sim)
	if m == "off":
		_deny(sim, "rage", req, "", "phase")
		return
	var ready: Array[int] = tiers_ready(sim)
	var tier: int = req if req > 0 else (ready.max() if not ready.is_empty() else 0)
	if tier == 0 or not ready.has(tier):
		var reason: String = "rage"
		if req > 0 and (not ladder.has(req) or (m == "jam" and req != jam_tier)):
			reason = "phase"
		var t2: int = tier if tier > 0 else (jam_tier if m == "jam" else ladder[0])
		_deny(sim, "rage", t2, "t1_horn" if m == "jam" else str(RAGE_IDS.get(t2, "")), reason)
		return
	var id: String = "t1_horn" if m == "jam" else str(RAGE_IDS.get(tier, ""))
	if busy("rage"):
		_deny(sim, "rage", tier, id, "busy")
		return
	if m == "jam":
		_cast_horn(sim)
	elif tier == 1:
		_cast_wave(sim)
	elif tier == 3:
		_cast_carpet(sim)
	elif tier == 5:
		_cast_finish(sim)


## &"item1" / &"item2" tap.
func item(sim: GameSim, slot: int) -> void:
	var sl: Dictionary = slot_of(slot)
	if sl.is_empty():
		_deny(sim, "item", 0, "", "phase")
		return
	var id: String = str(sl["id"])
	var m: String = mode(sim)
	if m == "off" or (id == "mv_jump" and m == "rescue"):
		_deny(sim, "item", 0, id, "phase")
		return
	if int(sl["charges"]) == 0:
		_deny(sim, "item", 0, id, "charges")
		return
	if float(sl["cool"]) > 0.0:
		_deny(sim, "item", 0, id, "cool")
		return
	if busy("item"):
		_deny(sim, "item", 0, id, "busy")
		return
	var ok: bool = false
	match id:
		"mv_jump":
			ok = _cast_jump(sim, m)
		"mv_drone":
			ok = _cast_drone(sim, m)
		"mv_tow":
			ok = _cast_tow(sim, m)
	if not ok:
		return
	var ic: Dictionary = _ic(id)
	var cm: float = float(ic.get("coolJam", ic.get("cool", 0.0))) if m == "jam" else float(ic.get("cool", 0.0))
	sl["cool"] = cm
	sl["cool_max"] = cm
	if int(sl["charges"]) > 0:
		sl["charges"] = int(sl["charges"]) - 1


## &"skip" tap: ends a skippable t5 (slow-mo off; the impact is already resolved) or jumps the kill finish to `done`.
func skip(sim: GameSim) -> bool:
	var rec: Dictionary = active.get("rage", {})
	if not rec.is_empty() and bool(rec["skippable"]):
		sim.slow_until = minf(sim.slow_until, sim.real_time)
		sim.hitstop = 0.0
		_end(sim, "rage", true)
		sim._emit({"type": "skip", "what": str(rec["id"])})
		return true
	if skip_ready(sim) and sim.phase == &"kill" and sim.boss.skip_death() > 0:
		sim.slow_until = minf(sim.slow_until, sim.real_time)
		sim.hitstop = 0.0
		sim._emit({"type": "skip", "what": "finish"})
		return true
	return false


# --- casts --------------------------------------------------------------------------------------------

func _spend(sim: GameSim, tier: int) -> void:
	sim.rage = maxf(0.0, sim.rage - float(cost(tier)) / float(segs_n))
	if mode(sim) != "jam":
		sim.supers += 1


func _start(sim: GameSim, chan: String, tier: int, id: String, target: Dictionary, lanes: PackedInt32Array, dur: float,
		cine: bool) -> Dictionary:
	var s: float = float(target["s"]) if not target.is_empty() else sim.player.s
	var x: float = float(target["x"]) if not target.is_empty() else sim.player.x
	var rec: Dictionary = {"chan": chan, "tier": tier, "id": id, "t": 0.0, "dur": dur, "cine": cine, "skippable": false,
		"target_id": int(target.get("index", -1)), "lanes": lanes, "pending": 0, "ended": false, "targets": [], "win": {},
		"popped": {}, "s": s, "x": x}
	active[chan] = rec
	counts[id] = int(counts.get(id, 0)) + 1
	if mode(sim) != "jam":
		sim.player.invuln = maxf(sim.player.invuln, dur + float(cfg.get("invulnPad", 0.2)))
		sim.boss.hold = maxf(sim.boss.hold, dur)
	sim._emit({"type": "skill_start", "chan": chan, "tier": tier, "id": id, "target_id": rec["target_id"], "lanes": lanes,
		"dur": dur, "cine": cine, "s": s, "x": x})
	return rec


func _queue(sim: GameSim, rec: Dictionary, delay: float, idx: int, n: int) -> void:
	queue.append({"at": sim.time + delay, "rec": rec, "idx": idx, "n": n})
	rec["pending"] = int(rec["pending"]) + 1


func _end(sim: GameSim, chan: String, skipped: bool) -> void:
	var rec: Dictionary = active.get(chan, {})
	if rec.is_empty():
		return
	rec["ended"] = true
	active.erase(chan)
	sim._emit({"type": "skill_end", "chan": chan, "tier": rec["tier"], "id": rec["id"], "skipped": skipped})


## Kill of the last villain: every cast ends (skill_end after the finisher), queued hits are dropped.
func end_all(sim: GameSim) -> void:
	for chan: String in ["rage", "item"]:
		_end(sim, chan, false)
	queue.clear()


func _lanes_around(center: int, r: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for l: int in range(center - r, center + r + 1):
		if l >= 0 and l <= Cfg.SHOULDER_LANE:
			out.append(l)
	return out


static func _near_lane(v: Dictionary, lane: int, r: int) -> bool:
	for l: int in BossSim.lanes_of(v):
		if absi(l - lane) <= r:
			return true
	return false


## Main target of a fight skill: the lock-on target, else the nearest alive villain within max_ds (INF = any).
func _primary(sim: GameSim, max_ds: float = INF) -> Dictionary:
	var lt: Dictionary = sim._lock_target
	if not lt.is_empty() and bool(lt.get("alive", false)) and absf(float(lt["s"]) - sim.player.s) <= max_ds:
		return lt
	var best: Dictionary = {}
	for v: Dictionary in sim.boss.alive():
		var d: float = absf(float(v["s"]) - sim.player.s)
		if d <= max_ds and (best.is_empty() or d < absf(float(best["s"]) - sim.player.s)):
			best = v
	return best


func _hp_floor(sim: GameSim) -> float:
	return 1.0 if sim.boss_clock < float(cfg.get("minKillT", 6.0)) else 0.0


## Hitstop + (unless another slow-mo ran < cineGap real s ago) slow-mo, from a tier / item config.
func _impact(sim: GameSim, c: Dictionary) -> void:
	sim.hitstop = maxf(sim.hitstop, float(c.get("hitstop", 0.0)))
	var sf: float = float(c.get("slowFor", 0.0))
	if sf > 0.0 and sim.real_time - _last_slow >= float(cfg.get("cineGap", 6.0)):
		_last_slow = sim.real_time
		sim.slow_until = maxf(sim.slow_until, sim.real_time + sim.hitstop + sf)
		sim.slow_scale = float(c.get("slow", 1.0))


func _emit_hit(sim: GameSim, rec: Dictionary, v: Dictionary, idx: int, n: int, r: Dictionary, extra: Dictionary = {}) -> void:
	var e: Dictionary = {"type": "skill_hit", "chan": rec["chan"], "tier": rec["tier"], "id": rec["id"],
		"target_id": int(v.get("index", -1)), "idx": idx, "n": n, "dmg": float(r.get("dmg", 0.0)), "window": bool(r.get("window", false)),
		"immune": bool(r.get("immune", false)), "stun": float(r.get("stun", 0.0)), "popped": int(r.get("popped", 0)),
		"killed": bool(r.get("killed", false)), "hp_frac": sim.boss.hp_frac(),
		"s": float(v["s"]) if not v.is_empty() else float(rec["s"]), "x": float(v["x"]) if not v.is_empty() else float(rec["x"])}
	e.merge(extra, true)
	sim._emit(e)
	if bool(r.get("killed", false)) and not v.is_empty():
		sim._villain_killed(v, bool(extra.get("execute", false)))


func _cast_horn(sim: GameSim) -> void:
	_spend(sim, jam_tier)
	var c: Dictionary = _tc(1)
	_start(sim, "rage", jam_tier, "t1_horn", {}, PackedInt32Array([Cfg.SHOULDER_LANE]), float(c.get("dur", 0.5)), false)
	sim.score += int(c.get("score", 0))
	sim._rage_horn_effect(float((c.get("jam", {}) as Dictionary).get("boost", sim.tune.get("boostTime", 2.2))))


func _cast_wave(sim: GameSim) -> void:
	var c: Dictionary = _tc(1)
	var targets: Array = []
	for v: Dictionary in sim.boss.alive():
		if absf(float(v["s"]) - sim.player.s) <= float(c.get("range", 30.0)) and _near_lane(v, sim.player.lane, int(c.get("laneRange", 1))):
			targets.append(int(v["index"]))
	if targets.is_empty():
		_deny(sim, "rage", 1, "t1_wave", "target")
		return
	_spend(sim, 1)
	var first: Dictionary = sim.boss.villains[int(targets[0])]
	var rec: Dictionary = _start(sim, "rage", 1, "t1_wave", first, _lanes_around(sim.player.lane, int(c.get("laneRange", 1))),
		float(c.get("dur", 0.5)), false)
	rec["targets"] = targets
	_queue(sim, rec, float(c.get("delay", 0.12)), 0, 1)


func _cast_carpet(sim: GameSim) -> void:
	var c: Dictionary = _tc(3)
	var tgt: Dictionary = _primary(sim)
	if tgt.is_empty():
		_deny(sim, "rage", 3, "t3_carpet", "target")
		return
	_spend(sim, 3)
	var rec: Dictionary = _start(sim, "rage", 3, "t3_carpet", tgt, _lanes_around(roundi(float(tgt["lane_pos"])), int(c.get("laneRange", 1))),
		float(c.get("dur", 1.2)), false)
	var n: int = maxi(1, int(c.get("hits", 4)))
	for i: int in n:
		_queue(sim, rec, float(c.get("delay", 0.4)) + i * float(c.get("hitGap", 0.05)), i, n)


func _cast_finish(sim: GameSim) -> void:
	var c: Dictionary = _tc(5)
	var tgt: Dictionary = _primary(sim)
	if tgt.is_empty():
		_deny(sim, "rage", 5, "t5_finish", "target")
		return
	_spend(sim, 5)
	var rec: Dictionary = _start(sim, "rage", 5, "t5_finish", tgt, _lanes_around(roundi(float(tgt["lane_pos"])), 0),
		float(c.get("dur", 2.5)), true)
	_queue(sim, rec, float(c.get("delay", 0.35)), 0, 1)


func _cast_jump(sim: GameSim, m: String) -> bool:
	var ic: Dictionary = _ic("mv_jump")
	var hop: float = float(ic.get("hop", 0.75))
	var fight: bool = m == "fight"
	if not sim.player.jump(hop, float(ic.get("invuln", 0.85)) if fight else 0.0, not fight):
		_deny(sim, "item", 0, "mv_jump", "busy")
		return false
	var rec: Dictionary = _start(sim, "item", 0, "mv_jump", {}, _lanes_around(sim.player.lane, int(ic.get("laneRange", 1))),
		float(ic.get("dur", 0.95)), false)
	if fight:
		_queue(sim, rec, hop, 0, 1)
	return true


## Nearest shoulder obstacle ahead within range (breakdown first for the tow).
func _jam_obstacle(sim: GameSim, range_m: float, tow_only: bool) -> Dictionary:
	var best: Dictionary = {}
	for o: Variant in sim.bridge.obstacles():
		var od: Dictionary = o
		var ds: float = float(od["s"]) - sim.player.s
		if ds < -2.0 or ds > range_m or (tow_only and bool(od.get("smash", false))):
			continue
		if best.is_empty() or ds < float(best["s"]) - sim.player.s:
			best = od
	return best


## Jam drone / tow: a mini is caught (drone), else a shoulder obstacle goes (smash or tow). Same tick as the cast.
func _jam_clear(sim: GameSim, id: String, rec: Dictionary, range_m: float) -> void:
	if id == "mv_drone":
		var mid: int = sim.bridge.mini_target()
		if mid != 0:
			var ci: Dictionary = sim.bridge.car_info(mid)
			var r: String = sim.bridge.mini_hit(mid, 999.0)
			if r != "":
				sim._mini_result(mid, r, float(ci.get("s", sim.player.s)), float(ci.get("x", sim.player.x)))
				_emit_hit(sim, rec, {}, 0, 1, {"dmg": 999.0}, {"mini_id": mid, "s": float(ci.get("s", sim.player.s)),
					"x": float(ci.get("x", sim.player.x))})
				return
	var od: Dictionary = _jam_obstacle(sim, range_m, id == "mv_tow")
	if od.is_empty():
		return
	var oid: int = int(od["id"])
	var smashed: bool = bool(od.get("smash", false)) and sim.bridge.smash(oid)
	if not smashed:
		sim.bridge.remove_obstacle(oid)
	sim._emit({"type": "smash" if smashed else "tow", "id": oid})
	_emit_hit(sim, rec, {}, 0, 1, {}, {"obstacle_id": oid, "s": float(od["s"]), "x": float(od["x"])})


func _cast_drone(sim: GameSim, m: String) -> bool:
	var ic: Dictionary = _ic("mv_drone")
	if m == "jam":
		if _item_reason(sim, {"id": "mv_drone"}) == "target":
			_deny(sim, "item", 0, "mv_drone", "target")
			return false
		var rj: Dictionary = _start(sim, "item", 0, "mv_drone", {}, PackedInt32Array([Cfg.SHOULDER_LANE]), float(ic.get("dur", 1.0)), false)
		_jam_clear(sim, "mv_drone", rj, float(ic.get("jamRange", 40.0)))
		return true
	var tgt: Dictionary = _primary(sim, float(ic.get("range", 45.0)))
	if tgt.is_empty():
		_deny(sim, "item", 0, "mv_drone", "target")
		return false
	var rec: Dictionary = _start(sim, "item", 0, "mv_drone", tgt, PackedInt32Array(BossSim.lanes_of(tgt)), float(ic.get("dur", 1.0)), false)
	var n: int = maxi(1, int(ic.get("bomblets", 6)))
	for i: int in n:
		_queue(sim, rec, float(ic.get("delay", 0.7)) + i * float(ic.get("bombGap", 0.05)), i, n)
	return true


func _cast_tow(sim: GameSim, m: String) -> bool:
	var ic: Dictionary = _ic("mv_tow")
	if m == "jam":
		if _jam_obstacle(sim, float(ic.get("jamRange", 60.0)), true).is_empty():
			_deny(sim, "item", 0, "mv_tow", "target")
			return false
		var rj: Dictionary = _start(sim, "item", 0, "mv_tow", {}, PackedInt32Array([Cfg.SHOULDER_LANE]), float(ic.get("dur", 1.0)), false)
		_jam_clear(sim, "mv_tow", rj, float(ic.get("jamRange", 60.0)))
		return true
	var tgt: Dictionary = _primary(sim, float(ic.get("range", 45.0)))
	if tgt.is_empty():
		_deny(sim, "item", 0, "mv_tow", "target")
		return false
	var rec: Dictionary = _start(sim, "item", 0, "mv_tow", tgt, PackedInt32Array(BossSim.lanes_of(tgt)), float(ic.get("dur", 1.0)), false)
	_queue(sim, rec, float(ic.get("delay", 0.8)), 0, 1)
	return true


# --- tick -------------------------------------------------------------------------------------------

## Once per GameSim.step after BossSim.update: queued hits (sim time), cast timers (real dt), cooldowns (sim dt),
## tier_ready / item_ready edges, the drone's passive shots at jam minis.
func tick(sim: GameSim, sdt: float, dt: float) -> void:
	if not enabled:
		return
	if not queue.is_empty():
		var due: Array[Dictionary] = []
		var keep: Array[Dictionary] = []
		for q: Dictionary in queue:
			if float(q["at"]) <= sim.time + 1e-9:
				due.append(q)
			else:
				keep.append(q)
		queue = keep
		for q: Dictionary in due:
			var rec: Dictionary = q["rec"]
			rec["pending"] = int(rec["pending"]) - 1
			if not bool(rec["ended"]):
				_resolve(sim, rec, int(q["idx"]), int(q["n"]))
	for chan: String in ["rage", "item"]:
		if not active.has(chan):
			continue
		var a: Dictionary = active[chan]
		a["t"] = float(a["t"]) + dt
		a["skippable"] = bool(a["cine"]) and float(a["t"]) >= float(cfg.get("skipAfter", 0.5)) and int(a["pending"]) == 0
		if float(a["t"]) >= float(a["dur"]) and int(a["pending"]) == 0:
			_end(sim, chan, false)
	for sl: Dictionary in slots:
		if float(sl["cool"]) > 0.0:
			sl["cool"] = float(sl["cool"]) - sdt
			if float(sl["cool"]) <= 0.0:
				sl["cool"] = 0.0
				sim._emit({"type": "item_ready", "id": sl["id"], "slot": sl["slot"]})
	var ready: Array[int] = tiers_ready(sim)
	for t: int in ready:
		if not _tiers_prev.has(t):
			sim._emit({"type": "tier_ready", "tier": t, "segs": segs(sim)})
	_tiers_prev = ready
	var dc: Dictionary = _ic("mv_drone")
	if has_item("mv_drone") and str(dc.get("passive", "")) == "minis" and mode(sim) == "jam":
		_passive_t -= sdt
		if _passive_t <= 0.0:
			_passive_t = float(dc.get("passiveEvery", 0.7))
			var mid: int = sim.bridge.mini_target()
			var ci: Dictionary = sim.bridge.car_info(mid) if mid != 0 else {}
			if not ci.is_empty():
				var e: Dictionary = sim.weapons.fire_at(sim.player, {"mini_id": mid, "s": ci["s"], "x": ci["x"], "v": ci["v"], "len": 4.4, "w": 1.9})
				e["drone"] = true
				sim._emit(e)


## SKILLS rageGain.windowHit: a tack hit inside the window refills rage (fight only, ≤ fightCap per fight).
func on_window_hit(sim: GameSim) -> void:
	if not enabled or mode(sim) != "fight":
		return
	var g: Dictionary = cfg.get("rageGain", {})
	var a: float = minf(float(g.get("windowHit", 0.0)), float(g.get("fightCap", 1.0)) - _fight_gain)
	if a > 0.0:
		_fight_gain += a
		sim.add_rage(a)


func _resolve(sim: GameSim, rec: Dictionary, idx: int, n: int) -> void:
	match str(rec["id"]):
		"t1_wave":
			_hit_wave(sim, rec)
		"t3_carpet":
			_hit_carpet(sim, rec, idx, n)
		"t5_finish":
			_hit_finish(sim, rec)
		"mv_jump":
			_hit_jump(sim, rec)
		"mv_drone":
			_hit_drone(sim, rec, idx, n)
		"mv_tow":
			_hit_tow(sim, rec)


func _hit_wave(sim: GameSim, rec: Dictionary) -> void:
	var c: Dictionary = _tc(1)
	_impact(sim, c)
	sim.score += int(c.get("score", 0))
	for vi: Variant in rec["targets"]:
		var v: Dictionary = sim.boss.villains[int(vi)]
		if not bool(v["alive"]):
			continue
		if bool(c.get("cancel", true)):
			sim.boss.cancel_attack(v)
		var r: Dictionary = sim.boss.skill_damage(v, float(c.get("dmgIn", 16)), float(c.get("dmgOut", 8)), float(c.get("stun", 0.6)),
			float(v["s"]) > sim.player.s, -1, _hp_floor(sim))
		v["recoil"] = 0.3
		_emit_hit(sim, rec, v, 0, 1, r)
		if sim.phase != &"boss":
			return


func _hit_carpet(sim: GameSim, rec: Dictionary, idx: int, n: int) -> void:
	var c: Dictionary = _tc(3)
	if idx == 0:
		var tgt: Dictionary = sim.boss.villains[int(rec["target_id"])]
		var ts: float = float(tgt["s"]) if bool(tgt["alive"]) else float(rec["s"])
		var lanes: PackedInt32Array = rec["lanes"]
		var targets: Array = []
		for v: Dictionary in sim.boss.alive():
			var inside: bool = false
			for l: int in BossSim.lanes_of(v):
				inside = inside or lanes.has(l)
			if inside and absf(float(v["s"]) - ts) <= float(c.get("strip", 12.0)):
				targets.append(int(v["index"]))
				(rec["win"] as Dictionary)[int(v["index"])] = 1 if bool(sim.boss.vuln(v)["window"]) else 0
		rec["targets"] = targets
		_impact(sim, c)
		sim.score += int(c.get("score", 0))
	for vi: Variant in rec["targets"]:
		var v: Dictionary = sim.boss.villains[int(vi)]
		if not bool(v["alive"]):
			continue
		var r: Dictionary = sim.boss.skill_damage(v, float(c.get("dmgIn", 30)) / n, float(c.get("dmgOut", 12)) / n,
			float(c.get("stun", 1.2)) if idx == 0 else 0.0, float(v["s"]) > sim.player.s, int((rec["win"] as Dictionary).get(int(vi), -1)),
			_hp_floor(sim))
		var pd: Dictionary = rec["popped"]
		pd[int(vi)] = int(pd.get(int(vi), 0)) + int(r["popped"])
		if idx == n - 1 and not bool(r["killed"]) and int(pd[int(vi)]) < int(c.get("pop", 1)):
			for k: int in int(c.get("pop", 1)) - int(pd[int(vi)]):
				r["popped"] = int(r["popped"]) + sim.boss.force_pop(v)
		_emit_hit(sim, rec, v, idx, n, r)
		if sim.phase != &"boss":
			return


func _hit_finish(sim: GameSim, rec: Dictionary) -> void:
	var c: Dictionary = _tc(5)
	var v: Dictionary = sim.boss.villains[int(rec["target_id"])]
	if not bool(v["alive"]):
		return
	var hf: float = maxf(0.0, float(v["hp"])) / float(v["max_hp"])
	sim.score += int(c.get("score", 0))
	if hf <= float(c.get("execute", 0.4)) + 1e-6 and _hp_floor(sim) == 0.0:
		sim.score += int(c.get("executeBonus", 0))
		sim.hitstop = maxf(sim.hitstop, float(c.get("hitstop", 0.14)))
		_emit_hit(sim, rec, v, 0, 1, sim.boss.execute(v), {"execute": true})
		return
	_impact(sim, c)
	var mx: float = float(v["max_hp"])
	var r: Dictionary = sim.boss.skill_damage(v, mx * float(c.get("dmgInFrac", 0.3)), mx * float(c.get("dmgOutFrac", 0.15)),
		float(c.get("stun", 2.0)), float(v["s"]) > sim.player.s, -1, _hp_floor(sim))
	_emit_hit(sim, rec, v, 0, 1, r, {"execute": false})


func _hit_jump(sim: GameSim, rec: Dictionary) -> void:
	var ic: Dictionary = _ic("mv_jump")
	sim.score += int(ic.get("score", 0))
	var any: bool = false
	for v: Dictionary in sim.boss.alive():
		if absf(float(v["s"]) - sim.player.s) > float(ic.get("landRange", 14.0)) or not _near_lane(v, sim.player.lane, int(ic.get("laneRange", 1))):
			continue
		any = true
		var r: Dictionary = sim.boss.skill_damage(v, float(ic.get("dmgIn", 8)), float(ic.get("dmgOut", 3)), float(ic.get("stun", 0.6)),
			float(v["s"]) > sim.player.s, -1, _hp_floor(sim))
		_emit_hit(sim, rec, v, 0, 1, r)
		if sim.phase != &"boss":
			return
	if not any:
		_emit_hit(sim, rec, {}, 0, 1, {}, {"s": sim.player.s, "x": sim.player.x})


func _hit_drone(sim: GameSim, rec: Dictionary, idx: int, n: int) -> void:
	var ic: Dictionary = _ic("mv_drone")
	var v: Dictionary = sim.boss.villains[int(rec["target_id"])]
	if not bool(v["alive"]):
		return
	if idx == 0:
		(rec["win"] as Dictionary)[int(v["index"])] = 1 if bool(sim.boss.vuln(v)["window"]) else 0
		sim.score += int(ic.get("score", 0))
	var r: Dictionary = sim.boss.skill_damage(v, float(ic.get("dmgIn", 15)) / n, float(ic.get("dmgOut", 5)) / n, 0.0,
		float(v["s"]) > sim.player.s, int((rec["win"] as Dictionary).get(int(v["index"]), -1)), _hp_floor(sim))
	_emit_hit(sim, rec, v, idx, n, r)


func _hit_tow(sim: GameSim, rec: Dictionary) -> void:
	var ic: Dictionary = _ic("mv_tow")
	var v: Dictionary = sim.boss.villains[int(rec["target_id"])]
	if not bool(v["alive"]):
		return
	sim.score += int(ic.get("score", 0))
	var granted: float = sim.boss.apply_stun(v, float(ic.get("pin", 1.5)))
	if granted > 0.0:
		v["target_lane_pos"] = v["lane_pos"]
		v["return_at"] = 0.0
	_emit_hit(sim, rec, v, 0, 1, {"dmg": 0.0, "window": bool(sim.boss.vuln(v)["window"]), "stun": granted})
