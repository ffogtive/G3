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
##
## r3 combat (device feedback 2026-10-14 #2 "압정 콤보 5·10개마다 큰 스킬 / 분노가 범위에 안 닿고 얌전함"):
##   가설: ✅ (r3design/combat/combo_proto.gd) the fight is long and tame because 압정 streaks pay nothing, 1-2..1-10 have
##         no window and the boss-phase t1 either cannot hit the villain (before the lock it was the shoulder horn) or
##         misses it (30 m, ±1 lane). Combo milestones + the generic window + HP-fraction damage + a t1 that always
##         connects in the boss phase bring 1-1..1-4 to 10–20 s (tests/test_e2e_skills.gd).
##   C1 combo channel "combo" (config.skills.combo; never busy(), no invuln, no boss hold): on_tack_hit(sim, v, r) counts
##      a 압정 hit on an alive villain in the boss phase (before and after the lock); skill / combo hits never count.
##      tick() breaks it after combo.timeout sim s without a counted hit (combo_break {reason: "timeout", n} when
##      n ≥ breakEventMin); on_player_hit(sim) breaks it (combo_break {reason: "hit", n}). milestones[n mod cycle]
##      (5 / 10 / 15 / 20 = c5 따닥 / c10 따다닥 / c5 / c20 타이어 저격) → combo_milestone {n, id, target_id, skill,
##      label, name} + skill_start / skill_hit / skill_end {chan: "combo", tier 0, id: c5_double | c10_burst |
##      c20_snipe, n (hits), combo (count)} on the villain the milestone tack hit: frac × max HP per hit (window decided
##      at the first hit), minKillT floor, c20 force_pop + cancel_attack + apply_stun 0.8 (stunCap / stunImmune) + hitstop.
##   C2 _hit_wave / _hit_carpet use dmgInFrac / dmgOutFrac × the target's max HP (flat dmgIn / dmgOut without them).
##   C3 mode(): phase boss with a villain alive = fight / rescue whether or not the front is locked (prelock: the
##      ladder is preLockLadder [1]); items keep the jam rules before the lock (_imode). t1 hits every alive villain
##      within t1.reach m in every lane (laneRange 99), hit delay = delay + max(0, |ds| − delayFrom) × delayPerM per
##      target; before the lock it also fires sim._rage_horn_effect (rage_horn tagged via "t1_wave") and stuns
##      stunPreLock s. Out of reach in the boss phase: the segment is spent, skill_chase {dur} + chase s of boost, the
##      wave fires on the first tick a villain is in reach, else the segment is refunded: skill_denied {reason "far",
##      refunded true} + bubble "너무 멀다!" (has_target(t1) stays true: the button never greys out for range).
##   state(): + combo {n, left, next_n, next_id, next_name, best, timeout, cycle, marks}, face (clear | wave | carpet |
##      finish), prelock, chase.

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
## r3 C3: tiers castable in the boss phase before the front lock (config skills.preLockLadder).
var pre_ladder: Array[int] = [1]
## r3 C3: a t1 waiting for a villain to come into reach {until (sim s), tier, prelock_at_tap} ({} = none).
var _chase: Dictionary = {}
## r3 C1: 압정 combo count, sim time of the last counted hit, best this run, combo casts in flight.
var combo_n: int = 0
var combo_best: int = 0
var _combo_last: float = -99.0
var _combo_recs: Array[Dictionary] = []


func setup(skills_cfg: Dictionary, tune: Dictionary, loadout: Dictionary) -> void:
	cfg = skills_cfg
	enabled = not cfg.is_empty()
	segs_n = maxi(1, int(tune.get("rageSegs", 5)))
	ladder.clear()
	for t: Variant in cfg.get("ladder", [1, 3, 5]):
		ladder.append(int(t))
	jam_tier = int(cfg.get("jamTier", 1))
	pre_ladder.clear()
	for t: Variant in cfg.get("preLockLadder", [1]):
		pre_ladder.append(int(t))
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
	for rec: Dictionary in _combo_recs:
		rec["ended"] = true
	_combo_recs.clear()
	queue.clear()
	_chase = {}
	combo_n = 0
	combo_best = 0
	_combo_last = -99.0
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
	else:  # Progress.loadout() today: the owned move items as the jump / drone flags
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


## Rage mode: "jam" (jam phase) | "fight" | "rescue" (honkOnly fight) | "off". r3 C3: the boss phase with a villain
## alive is a fight before the front lock too (prelock(); ladder = preLockLadder).
func mode(sim: GameSim) -> String:
	if not enabled:
		return "off"
	if sim.phase == &"boss" and sim.boss.any_alive():
		return "rescue" if sim.stage.get("honkOnly") == true else "fight"
	if sim.phase == &"jam" or sim.phase == &"boss":
		return "jam"
	return "off"


## Item / jam-side mode (the pre-r3 rule): "jam" = jam or boss before the front lock (jam hop, jam drone / tow, no
## cast invuln), then fight / rescue / off like mode().
func _imode(sim: GameSim) -> String:
	if not enabled:
		return "off"
	if sim.phase == &"jam" or (sim.phase == &"boss" and not sim.front_locked):
		return "jam"
	return mode(sim)


## r3 C3: boss phase before the front lock (the rage ladder is preLockLadder, t1 also clears the shoulder).
func prelock(sim: GameSim) -> bool:
	return sim.phase == &"boss" and not sim.front_locked and mode(sim) in ["fight", "rescue"]


func _ladder_now(sim: GameSim) -> Array[int]:
	return pre_ladder if prelock(sim) else ladder


func tiers_ready(sim: GameSim) -> Array[int]:
	var out: Array[int] = []
	var m: String = mode(sim)
	var sg: int = segs(sim)
	if m == "jam":
		if sg >= cost(jam_tier):
			out.append(jam_tier)
	elif m == "fight" or m == "rescue":
		for t: int in _ladder_now(sim):
			if sg >= cost(t):
				out.append(t)
	return out


func next_tier(sim: GameSim) -> int:
	var r: Array[int] = tiers_ready(sim)
	return r.max() if not r.is_empty() else 0


## A cast of this tier would find a target now. r3 C3 t1: a villain within reach in the lane band, or (chase > 0) any
## alive villain in the boss phase (the chase closes in or refunds; the button never greys out for range).
func has_target(sim: GameSim, tier: int) -> bool:
	var m: String = mode(sim)
	if m == "jam":
		return true
	if m == "off":
		return false
	if tier != 1:
		return not _primary(sim).is_empty()
	if float(_tc(1).get("chase", 0.0)) > 0.0 and sim.phase == &"boss" and sim.boss.any_alive():
		return true
	return not _wave_targets(sim).is_empty()


func busy(chan: String) -> bool:
	if active.has(chan):
		return true
	if chan == "rage" and not _chase.is_empty():
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
	var m: String = _imode(sim)
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
	var nt: int = ready.max() if not ready.is_empty() else 0
	return {"segs": segs(sim), "rage_tiers_ready": ready, "next_tier": nt, "mode": m,
		"execute_frac": float(_tc(5).get("execute", 0.4)) if m == "fight" and ready.has(5) else 0.0, "active": act, "items": items,
		"time_scale": time_scale, "skip_ready": skip_ready(sim), "enabled": enabled,
		"face": _face(m, nt), "prelock": prelock(sim), "chase": not _chase.is_empty(), "combo": combo_state(sim)}


## r3 C3 (U2): the 분노 button glyph: "clear" (jam t1_horn), "wave" (t1 / no tier yet in a fight), "carpet", "finish".
func _face(m: String, nt: int) -> String:
	if m == "jam":
		return "clear"
	if m == "fight" or m == "rescue":
		return "finish" if nt == 5 else ("carpet" if nt == 3 else "wave")
	return ""


func _combo_cfg() -> Dictionary:
	return cfg.get("combo", {}) if cfg.get("combo") is Dictionary else {}


## Milestone key of combo count n ("" = none): milestones[str(n mod cycle)], 0 → cycle.
func milestone_of(n: int) -> String:
	var cc: Dictionary = _combo_cfg()
	var ms: Dictionary = cc.get("milestones", {}) if cc.get("milestones") is Dictionary else {}
	if n <= 0 or ms.is_empty():
		return ""
	var cyc: int = maxi(1, int(cc.get("cycle", 20)))
	var m: int = n % cyc
	return str(ms.get(str(m if m != 0 else cyc), ""))


## r3 C1 state.skills.combo: {n, left (sim s to the timeout, 0 when n = 0), next_n / next_id / next_name (the next
## milestone; 0 / "" without one), best, timeout, cycle, marks (milestone counts inside one cycle, sorted)}.
func combo_state(sim: GameSim) -> Dictionary:
	var cc: Dictionary = _combo_cfg()
	var to: float = float(cc.get("timeout", 1.5))
	var cyc: int = maxi(1, int(cc.get("cycle", 20)))
	var next_n: int = 0
	var next_id: String = ""
	for k: int in range(combo_n + 1, combo_n + cyc + 1):
		var id: String = milestone_of(k)
		if id != "":
			next_n = k
			next_id = id
			break
	var marks: Array[int] = []
	var ms: Dictionary = cc.get("milestones", {}) if cc.get("milestones") is Dictionary else {}
	for k: Variant in ms.keys():
		marks.append(int(str(k)))
	marks.sort()
	var left: float = maxf(0.0, to - (sim.time - _combo_last)) if combo_n > 0 else 0.0
	var nc: Dictionary = cc.get(next_id, {}) if cc.get(next_id) is Dictionary else {}
	return {"n": combo_n, "left": left, "next_n": next_n, "next_id": next_id, "next_name": str(nc.get("name", "")),
		"best": combo_best, "timeout": to, "cycle": cyc, "marks": marks}


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
		if req > 0 and m != "jam" and not _ladder_now(sim).has(req):
			reason = "phase"  # r3 C3: t3 / t5 before the front lock
		var t2: int = tier if tier > 0 else (jam_tier if m == "jam" else _ladder_now(sim)[0])
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
	var m: String = _imode(sim)
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


## r3 C3: gives back a spent tier (chase out of reach). Exact inverse of _spend (no add_rage low-HP doubling).
func _refund(sim: GameSim, tier: int) -> void:
	sim.rage = minf(1.0, sim.rage + float(cost(tier)) / float(segs_n))
	sim.supers = maxi(0, sim.supers - 1)


func _start(sim: GameSim, chan: String, tier: int, id: String, target: Dictionary, lanes: PackedInt32Array, dur: float,
		cine: bool) -> Dictionary:
	var s: float = float(target["s"]) if not target.is_empty() else sim.player.s
	var x: float = float(target["x"]) if not target.is_empty() else sim.player.x
	var rec: Dictionary = {"chan": chan, "tier": tier, "id": id, "t": 0.0, "dur": dur, "cine": cine, "skippable": false,
		"target_id": int(target.get("index", -1)), "lanes": lanes, "pending": 0, "ended": false, "targets": [], "win": {},
		"popped": {}, "s": s, "x": x}
	active[chan] = rec
	counts[id] = int(counts.get(id, 0)) + 1
	if (mode(sim) if chan == "rage" else _imode(sim)) != "jam":
		sim.player.invuln = maxf(sim.player.invuln, dur + float(cfg.get("invulnPad", 0.2)))
		sim.boss.hold = maxf(sim.boss.hold, dur)
	sim._emit({"type": "skill_start", "chan": chan, "tier": tier, "id": id, "target_id": rec["target_id"], "lanes": lanes,
		"dur": dur, "cine": cine, "s": s, "x": x})
	return rec


## vi >= 0: the hit belongs to that villain (t1 per-target delays, combo hits).
func _queue(sim: GameSim, rec: Dictionary, delay: float, idx: int, n: int, vi: int = -1) -> void:
	queue.append({"at": sim.time + delay, "rec": rec, "idx": idx, "n": n, "vi": vi})
	rec["pending"] = int(rec["pending"]) + 1


func _end(sim: GameSim, chan: String, skipped: bool) -> void:
	var rec: Dictionary = active.get(chan, {})
	if rec.is_empty():
		return
	rec["ended"] = true
	active.erase(chan)
	sim._emit({"type": "skill_end", "chan": chan, "tier": rec["tier"], "id": rec["id"], "skipped": skipped})


## Kill of the last villain: every cast ends (skill_end after the finisher), queued hits are dropped, a pending t1
## chase is refunded and the combo resets (no break event: the fight is won).
func end_all(sim: GameSim) -> void:
	for chan: String in ["rage", "item"]:
		_end(sim, chan, false)
	for rec: Dictionary in _combo_recs:
		_end_combo(sim, rec)
	_combo_recs.clear()
	queue.clear()
	if not _chase.is_empty():
		_refund(sim, int(_chase.get("tier", 1)))
		_chase = {}
		sim._emit({"type": "skill_denied", "chan": "rage", "tier": 1, "id": "t1_wave", "reason": "phase", "refunded": true})
	combo_n = 0


func _end_combo(sim: GameSim, rec: Dictionary) -> void:
	if bool(rec["ended"]):
		return
	rec["ended"] = true
	sim._emit({"type": "skill_end", "chan": "combo", "tier": 0, "id": rec["id"], "skipped": false})


func _lanes_around(center: int, r: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for l: int in range(maxi(0, center - r), mini(Cfg.SHOULDER_LANE, center + r) + 1):
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


## r3 C3: alive villains within t1.reach (legacy range) of the player in the lane band (laneRange 99 = every lane),
## nearest first.
func _wave_targets(sim: GameSim) -> Array:
	var c: Dictionary = _tc(1)
	var reach: float = float(c.get("reach", c.get("range", 30.0)))
	var lr: int = int(c.get("laneRange", 1))
	var vs: Array[Dictionary] = []
	for v: Dictionary in sim.boss.alive():
		if absf(float(v["s"]) - sim.player.s) <= reach + 1e-6 and _near_lane(v, sim.player.lane, lr):
			vs.append(v)
	var ps: float = sim.player.s
	vs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return absf(float(a["s"]) - ps) < absf(float(b["s"]) - ps))
	var out: Array = []
	for v: Dictionary in vs:
		out.append(int(v["index"]))
	return out


## Sim delay of the wave's hit on a villain ds m away (r3 C3: 0.12 + max(0, |ds| − 15) × 0.00833, 60 m → 0.5 s).
func wave_delay(ds: float) -> float:
	var c: Dictionary = _tc(1)
	return float(c.get("delay", 0.12)) + maxf(0.0, absf(ds) - float(c.get("delayFrom", 15.0))) * float(c.get("delayPerM", 0.0))


func _cast_wave(sim: GameSim) -> void:
	var c: Dictionary = _tc(1)
	var targets: Array = _wave_targets(sim)
	if targets.is_empty():
		if float(c.get("chase", 0.0)) > 0.0 and sim.phase == &"boss" and sim.boss.any_alive():
			_spend(sim, 1)  # spent at the tap; refunded if the chase never brings a villain into reach
			var ch: float = float(c.get("chase", 0.8))
			_chase = {"until": sim.time + ch, "tier": 1}
			sim.player.boost_t = maxf(sim.player.boost_t, ch)
			sim._emit({"type": "skill_chase", "chan": "rage", "tier": 1, "id": "t1_wave", "dur": ch,
				"reach": float(c.get("reach", 60.0))})
			return
		_deny(sim, "rage", 1, "t1_wave", "target")
		return
	_spend(sim, 1)
	_fire_wave(sim, targets)


## The wave itself (rage already spent): one queued hit per target at its own distance delay; before the front lock
## the same tick also clears the shoulder (GameSim._rage_horn_effect: smash / tow / cheaters / boost / neck open).
func _fire_wave(sim: GameSim, targets: Array) -> void:
	var c: Dictionary = _tc(1)
	var pre: bool = prelock(sim)
	var first: Dictionary = sim.boss.villains[int(targets[0])]
	var d0: float = wave_delay(float(first["s"]) - sim.player.s)
	var dmax: float = d0
	for vi: Variant in targets:
		dmax = maxf(dmax, wave_delay(float(sim.boss.villains[int(vi)]["s"]) - sim.player.s))
	var lanes: PackedInt32Array = _lanes_around(sim.player.lane, int(c.get("laneRange", 1)))
	var rec: Dictionary = _start(sim, "rage", 1, "t1_wave", first, lanes, maxf(float(c.get("dur", 0.5)), dmax + 0.15), false)
	rec["targets"] = targets
	rec["prelock"] = pre
	rec["impacted"] = false
	var e: Dictionary = sim._events[sim._events.size() - 1] if not sim._events.is_empty() else {}
	if str(e.get("type", "")) == "skill_start" and str(e.get("id", "")) == "t1_wave":
		e["delay"] = d0
		e["prelock"] = pre
		e["targets"] = targets.duplicate()
	for i: int in targets.size():
		var v: Dictionary = sim.boss.villains[int(targets[i])]
		_queue(sim, rec, wave_delay(float(v["s"]) - sim.player.s), 0, 1, int(targets[i]))
	if pre:
		var n0: int = sim._events.size()
		sim._rage_horn_effect(float((c.get("jam", {}) as Dictionary).get("boost", sim.tune.get("boostTime", 2.2))))
		for k: int in range(n0, sim._events.size()):
			if str(sim._events[k].get("type", "")) == "rage_horn":
				sim._events[k]["via"] = "t1_wave"  # the view plays the 충격파, not the horn


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
	if not fight:  # jam / before the lock: GameSim.jam_hop picks the landing slot (never past a villain)
		var why: String = sim.jam_hop(hop)
		if why != "":
			_deny(sim, "item", 0, "mv_jump", why)
			return false
	elif not sim.player.jump(hop, float(ic.get("invuln", 0.85)), false):
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
				_emit_hit(sim, rec, {}, 0, 1, {}, {"mini_id": mid, "caught": r == "down", "s": float(ci.get("s", sim.player.s)),
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
	_tick_chase(sim)
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
				_resolve(sim, rec, int(q["idx"]), int(q["n"]), int(q.get("vi", -1)))
	_tick_combo(sim, dt)
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


## SKILLS rageGain: a tack hit inside the window (windowHit) or a dodged attack (dodge, BossSim "dodge" event) refills
## rage in the fight, ≤ fightCap per fight in total.
func on_window_hit(sim: GameSim) -> void:
	_gain(sim, "windowHit")


func on_dodge(sim: GameSim) -> void:
	_gain(sim, "dodge")


## rageGain.lock: once at the front lock (GameSim "lock"), outside the fightCap budget.
func on_lock(sim: GameSim) -> void:
	if enabled:
		sim.add_rage(float((cfg.get("rageGain", {}) as Dictionary).get("lock", 0.0)))


func _gain(sim: GameSim, key: String) -> void:
	if not enabled or mode(sim) != "fight" or not sim.front_locked:  # r3: the pre-lock boss phase earns nothing (as before)
		return
	var g: Dictionary = cfg.get("rageGain", {})
	var a: float = minf(float(g.get(key, 0.0)), float(g.get("fightCap", 1.0)) - _fight_gain)
	if a > 0.0:
		_fight_gain += a
		sim.add_rage(a)


func _resolve(sim: GameSim, rec: Dictionary, idx: int, n: int, vi: int = -1) -> void:
	if str(rec["chan"]) == "combo":
		_hit_combo(sim, rec, idx, n)
		return
	match str(rec["id"]):
		"t1_wave":
			_hit_wave(sim, rec, vi)
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


## r3 C2: a tier's damage inside / outside the window on v: frac × max HP when the config has it, else flat.
func _dmg(c: Dictionary, inside: bool, v: Dictionary, flat: float) -> float:
	var fk: String = "dmgInFrac" if inside else "dmgOutFrac"
	if c.has(fk):
		return float(c[fk]) * float(v["max_hp"])
	return float(c.get("dmgIn" if inside else "dmgOut", flat))


## One target of the wave (vi; −1 = every target, the pre-r3 single queued hit). Impact (hitstop, score) once per cast.
func _hit_wave(sim: GameSim, rec: Dictionary, vi_only: int = -1) -> void:
	var c: Dictionary = _tc(1)
	if not bool(rec.get("impacted", false)):
		rec["impacted"] = true
		_impact(sim, c)
		sim.score += int(c.get("score", 0))
	var pre: bool = bool(rec.get("prelock", false))
	for vi: Variant in ([vi_only] if vi_only >= 0 else rec["targets"]):
		var v: Dictionary = sim.boss.villains[int(vi)]
		if not bool(v["alive"]):
			continue
		if bool(c.get("cancel", true)):
			sim.boss.cancel_attack(v)
		var rear: bool = float(v["s"]) > sim.player.s
		var stun: float = float(c.get("stunPreLock", c.get("stun", 0.6))) if pre else float(c.get("stun", 0.6))
		var r: Dictionary = sim.boss.skill_damage(v, _dmg(c, true, v, 16.0), _dmg(c, false, v, 8.0), stun, rear, -1, _hp_floor(sim))
		v["recoil"] = 0.3
		_emit_hit(sim, rec, v, 0, 1, r, {"from_rear": rear, "prelock": pre, "ds": float(v["s"]) - sim.player.s})
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
		var r: Dictionary = sim.boss.skill_damage(v, _dmg(c, true, v, 30.0) / n, _dmg(c, false, v, 12.0) / n,
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


# --- r3 C3: t1 chase -------------------------------------------------------------------------------------------

## A pending t1 (spent at the tap): fires on the first tick a villain is in reach, else refunds at the deadline.
func _tick_chase(sim: GameSim) -> void:
	if _chase.is_empty():
		return
	if sim.phase != &"boss" or not sim.boss.any_alive():
		return  # end_all (kill) / reset_run (retry) settle it
	var targets: Array = _wave_targets(sim)
	if not targets.is_empty():
		_chase = {}
		_fire_wave(sim, targets)
		return
	if sim.time + 1e-9 >= float(_chase["until"]):
		var tier: int = int(_chase.get("tier", 1))
		_chase = {}
		_refund(sim, tier)
		sim._emit({"type": "skill_denied", "chan": "rage", "tier": tier, "id": "t1_wave", "reason": "far", "refunded": true,
			"text": "너무 멀다!"})
		sim._emit({"type": "bubble", "who": "player", "id": -1, "text": "너무 멀다!", "kind": "warn", "dur": 1.0})


# --- r3 C1: 압정 combo --------------------------------------------------------------------------------------------

## GameSim._on_landing (r3 W hook): a 압정 tack hit on a villain (minis and bombs never get here). r = BossSim.damage()
## result: it carries "villain" only when the villain was alive (the hit landed).
func on_tack_hit(sim: GameSim, v: Dictionary, r: Dictionary) -> void:
	if not enabled or sim.phase != &"boss" or not r.has("villain") or v.is_empty():
		return
	combo_n += 1
	combo_best = maxi(combo_best, combo_n)
	_combo_last = sim.time
	var mid: String = milestone_of(combo_n)
	if mid != "":
		_combo_fire(sim, mid, v)


## GameSim._on_player_hit (r3 W hook): a hit that got through invuln and dealt damage breaks the combo.
func on_player_hit(sim: GameSim) -> void:
	if not enabled or combo_n <= 0:
		return
	sim._emit({"type": "combo_break", "reason": "hit", "n": combo_n})
	combo_n = 0


func _tick_combo(sim: GameSim, dt: float) -> void:
	if combo_n > 0:
		if sim.phase != &"boss":
			combo_n = 0
		elif sim.time - _combo_last > float(_combo_cfg().get("timeout", 1.5)) + 1e-9:
			if combo_n >= int(_combo_cfg().get("breakEventMin", 5)):
				sim._emit({"type": "combo_break", "reason": "timeout", "n": combo_n})
			combo_n = 0
	for i: int in range(_combo_recs.size() - 1, -1, -1):
		var rec: Dictionary = _combo_recs[i]
		rec["t"] = float(rec["t"]) + dt
		if bool(rec["ended"]):
			_combo_recs.remove_at(i)
		elif float(rec["t"]) >= float(rec["dur"]) and int(rec["pending"]) == 0:
			_end_combo(sim, rec)
			_combo_recs.remove_at(i)


func _combo_fire(sim: GameSim, mid: String, v: Dictionary) -> void:
	var cc: Dictionary = _combo_cfg().get(mid, {}) if _combo_cfg().get(mid) is Dictionary else {}
	var id: String = str(cc.get("id", mid))
	var delays: Array = cc.get("delays", []) if cc.get("delays") is Array else []
	if delays.is_empty():
		delays = [float(cc.get("delay", 0.15))]
	var n: int = delays.size()
	var vi: int = int(v["index"])
	sim._emit({"type": "combo_milestone", "n": combo_n, "id": mid, "target_id": vi, "skill": id, "label": str(cc.get("label", "")),
		"name": str(cc.get("name", ""))})
	var rec: Dictionary = {"chan": "combo", "tier": 0, "id": id, "key": mid, "t": 0.0, "dur": float(cc.get("dur", 0.4)), "cine": false,
		"skippable": false, "target_id": vi, "lanes": PackedInt32Array(BossSim.lanes_of(v)), "pending": 0, "ended": false,
		"targets": [vi], "win": {}, "popped": {}, "s": float(v["s"]), "x": float(v["x"]), "combo": combo_n, "cc": cc}
	_combo_recs.append(rec)
	counts[id] = int(counts.get(id, 0)) + 1
	sim.score += int(cc.get("score", 0))
	sim._emit({"type": "skill_start", "chan": "combo", "tier": 0, "id": id, "key": mid, "target_id": vi, "lanes": rec["lanes"],
		"dur": rec["dur"], "cine": false, "s": rec["s"], "x": rec["x"], "n": n, "combo": combo_n})
	for i: int in n:
		_queue(sim, rec, float(delays[i]), i, n, vi)


## One combo hit: frac × max HP of the target (the milestone tack's villain; another alive one if it died), window
## decided at the first hit; c20: force_pop + cancel_attack + stun (= a window) + hitstop.
func _hit_combo(sim: GameSim, rec: Dictionary, idx: int, n: int) -> void:
	var cc: Dictionary = rec["cc"]
	var v: Dictionary = sim.boss.villains[int(rec["target_id"])]
	if not bool(v["alive"]):
		var al: Array[Dictionary] = sim.boss.alive()
		if al.is_empty():
			return
		v = al[0]
		rec["target_id"] = int(v["index"])
	var vi: int = int(v["index"])
	var wd: Dictionary = rec["win"]
	if not wd.has(vi):
		wd[vi] = 1 if bool(sim.boss.vuln(v)["window"]) else 0
	if idx == 0 and float(cc.get("hitstop", 0.0)) > 0.0:
		sim.hitstop = maxf(sim.hitstop, float(cc["hitstop"]))
	if bool(cc.get("cancel", false)):
		sim.boss.cancel_attack(v)
	var mx: float = float(v["max_hp"])
	var r: Dictionary = sim.boss.skill_damage(v, float(cc.get("fracIn", 0.0)) * mx, float(cc.get("fracOut", 0.0)) * mx,
		float(cc.get("stun", 0.0)), float(v["s"]) > sim.player.s, int(wd[vi]), _hp_floor(sim))
	if idx == n - 1 and not bool(r["killed"]):
		for k: int in int(cc.get("pop", 0)):
			r["popped"] = int(r["popped"]) + sim.boss.force_pop(v)
	_emit_hit(sim, rec, v, idx, n, r, {"key": str(rec.get("key", "")), "combo": int(rec.get("combo", 0))})
