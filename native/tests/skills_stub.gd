class_name SkillsStub
extends RefCounted
## Stub of the GameSim skills interface (docs/SKILLS.md §6) for the presentation layer: shots and FX tests drive the
## real GameSim (world, traffic, villain, phases) and this stub adds what the sim side will publish — the
## state()["skills"] block and the skill_start / skill_hit / skill_end / skill_denied / tier_ready / item_ready /
## finisher events with the §2-2 / §3-1 timings from config.skills — so HUD, FightFx, CameraRig, SkillCues can be
## built and judged before (and independently of) the sim implementation.
## Effects are applied through the public sim pieces only: BossSim.damage / pop_tire / start_death (+ GameSim._enter
## kill like a tack kill), PlayerSim.jump, GameSim.hitstop / slow_until / slow_scale. Deterministic (no RNG).
## Use: stub.cast(tier) / stub.use_item(slot) / stub.deny(...); after every sim.step(dt) call stub.tick() and fan out
## stub.drain() after sim.events(); stub.decorate(sim.state()) adds the skills block.

var sim: GameSim
var cfg: Dictionary = {}
var items: Array[String] = ["mv_jump", "mv_drone"]
var finish: String = "rocket"
var time_scale: float = 1.0
var _q: Array[Dictionary] = []          # {at: sim time, fn: Callable}
var _out: Array[Dictionary] = []
var _active: Dictionary = {}
var _cool: Dictionary = {}              # item id → remaining sim s
var _last_t: float = 0.0
var _cine_at: float = -99.0


func _init(p_sim: GameSim, p_cfg: Dictionary = {}) -> void:
	sim = p_sim
	cfg = p_cfg if not p_cfg.is_empty() else SkillCues.cfg()
	_last_t = sim.time


func _c(key: String) -> Dictionary:
	return cfg.get(key, {}) if cfg.get(key) is Dictionary else {}


func _item_cfg(id: String) -> Dictionary:
	var it: Dictionary = _c("items")
	return it.get(id, {}) if it.get(id) is Dictionary else {}


func _at(dt: float, fn: Callable) -> void:
	_q.append({"at": sim.time + dt, "fn": fn})


func _emit(e: Dictionary) -> void:
	_out.append(e)


func drain() -> Array[Dictionary]:
	var o: Array[Dictionary] = _out
	_out = []
	return o


func target() -> Dictionary:
	var best: Dictionary = {}
	for v: Dictionary in sim.boss.alive():
		if best.is_empty() or absf(float(v["x"]) - sim.player.x) < absf(float(best["x"]) - sim.player.x):
			best = v
	return best


func segs() -> int:
	return clampi(floori(sim.rage * 5.0 + 1e-6), 0, 5)


func mode() -> String:
	if sim.phase == &"boss" and sim.front_locked:
		return "fight"
	if sim.phase in [&"intro", &"jam", &"boss"]:
		return "jam"
	return "off"


## Rage tier cast (1 | 3 | 5); false + skill_denied when not ready / busy.
func cast(tier: int) -> bool:
	if not _active.is_empty():
		deny("rage", tier, "busy")
		return false
	if segs() < tier:
		deny("rage", tier, "rage")
		return false
	var v: Dictionary = target()
	var m: String = mode()
	var tc: Dictionary = _c("t%d" % tier)
	sim.rage = maxf(0.0, sim.rage - 0.2 * float(tier))
	var dur: float = float(tc.get("dur", {1: 0.5, 3: 1.2, 5: 2.5}[tier]))
	if m != "fight":
		_start("rage", 1, "t1_horn", v, dur, false)
		_emit({"type": "rage_horn", "smashed": [], "towed": [], "s": sim.player.s, "x": sim.player.x})
		_at(dur, func() -> void: _end())
		return true
	var id: String = {1: "t1_wave", 3: "t3_carpet", 5: "t5_finish"}[tier]
	_start("rage", tier, id, v, dur, tier == 5)
	var delay: float = float(tc.get("delay", {1: 0.12, 3: 0.4, 5: 0.35}[tier]))
	match tier:
		1:
			_at(delay, func() -> void: _hit(v, 0, 1, float(tc.get("dmgIn", 16)), float(tc.get("dmgOut", 8)), float(tc.get("stun", 0.6)), false,
				float(tc.get("hitstop", 0.06)), 1.0, 0.0))
		3:
			var hits: int = int(tc.get("hits", 4))
			for i: int in hits:
				var idx: int = i
				_at(delay + float(tc.get("hitGap", 0.05)) * float(i), func() -> void:
					_hit(v, idx, hits, float(tc.get("dmgIn", 30)) / float(hits), float(tc.get("dmgOut", 12)) / float(hits),
						float(tc.get("stun", 1.2)) if idx == 0 else 0.0, idx == hits - 1, float(tc.get("hitstop", 0.09)) if idx == 0 else 0.0,
						float(tc.get("slow", 0.35)), float(tc.get("slowFor", 0.6)) if idx == 0 else 0.0))
		5:
			_at(delay, func() -> void: _t5(v, tc))
	_at(dur, func() -> void: _end())
	return true


func use_item(slot: int) -> bool:
	if slot < 1 or slot > items.size():
		deny("item", 0, "phase", "")
		return false
	var id: String = items[slot - 1]
	if float(_cool.get(id, 0.0)) > 0.0:
		deny("item", 0, "cool", id)
		return false
	if not _active.is_empty() and int(_active.get("tier", 0)) == 5:
		deny("item", 0, "busy", id)
		return false
	var ic: Dictionary = _item_cfg(id)
	var fight: bool = mode() == "fight"
	_cool[id] = float(ic.get("cool" if fight else "coolJam", 6.0))
	var v: Dictionary = target()
	var dur: float = float(ic.get("dur", 1.0))
	_start("item", 0, id, v, dur, false)
	match id:
		"mv_jump":
			var hop: float = float(ic.get("hop", 0.75))
			sim.player.jump(hop, float(ic.get("invuln", 0.85)), false)
			_at(hop, func() -> void:
				var near: bool = fight and not v.is_empty() and absf(float(v["s"]) - sim.player.s) < float(ic.get("landRange", 14))
				_hit(v if near else {}, 0, 1, float(ic.get("dmgIn", 8)) if near else 0.0, float(ic.get("dmgOut", 3)) if near else 0.0,
					float(ic.get("stun", 0.6)) if near else 0.0, false, 0.05, 1.0, 0.0, sim.player.s + 1.5, sim.player.x))
		"mv_drone":
			var n: int = int(ic.get("bomblets", 6))
			for i: int in n:
				var idx: int = i
				_at(float(ic.get("delay", 0.7)) + float(ic.get("bombGap", 0.05)) * float(i), func() -> void:
					_hit(v, idx, n, float(ic.get("dmgIn", 15)) / float(n), float(ic.get("dmgOut", 5)) / float(n), 0.0, false,
						0.03 if idx == 0 else 0.0, 1.0, 0.0, float(v.get("s", 0.0)) + (float(idx) / float(maxi(1, n - 1)) - 0.5) * 3.4,
						float(v.get("x", 0.0))))
	_at(dur, func() -> void: _end())
	return true


func deny(chan: String, tier: int, reason: String, id: String = "") -> void:
	_emit({"type": "skill_denied", "chan": chan, "tier": tier, "id": id, "reason": reason})


func _start(chan: String, tier: int, id: String, v: Dictionary, dur: float, cine: bool) -> void:
	var vl: int = roundi(float(v.get("lane_pos", 1))) if not v.is_empty() else sim.player.lane
	var lanes := PackedInt32Array()
	for l: int in [vl - 1, vl, vl + 1]:
		if l >= 0 and l <= 3:
			lanes.append(l)
	_active = {"chan": chan, "tier": tier, "id": id, "t": 0.0, "dur": dur, "target_id": int(v.get("index", -1)), "cine": cine,
		"skippable": false, "t0": sim.real_time}
	if cine:
		_cine_at = sim.real_time
	_emit({"type": "skill_start", "chan": chan, "tier": tier, "id": id, "target_id": int(v.get("index", -1)), "lanes": lanes,
		"dur": dur, "cine": cine, "s": float(v.get("s", sim.player.s)), "x": float(v.get("x", sim.player.x))})


func _end(skipped: bool = false) -> void:
	if _active.is_empty():
		return
	_emit({"type": "skill_end", "chan": _active["chan"], "tier": _active["tier"], "id": _active["id"], "skipped": skipped,
		"cine": _active["cine"]})
	_active = {}


func _hit(v: Dictionary, idx: int, n: int, din: float, dout: float, stun: float, pop: bool, hitstop: float, slow: float,
		slow_for: float, s: float = NAN, x: float = NAN) -> void:
	var r: Dictionary = {"killed": false, "popped": 0, "window": false, "immune": false, "dmg": 0.0}
	if not v.is_empty() and bool(v.get("alive", false)) and (din > 0.0 or dout > 0.0):
		r = sim.boss.damage(v, dout, din, true)
		if pop and int(v.get("tires", 0)) > 0:
			sim.boss.pop_tire(v)
			r["popped"] = 1
	if hitstop > 0.0:
		sim.hitstop = maxf(sim.hitstop, hitstop)
	if slow_for > 0.0:
		sim.slow_until = sim.real_time + hitstop + slow_for
		sim.slow_scale = slow
	var a: Dictionary = _active
	_emit({"type": "skill_hit", "chan": a.get("chan", "rage"), "tier": a.get("tier", 0), "id": a.get("id", ""),
		"target_id": int(v.get("index", -1)), "idx": idx, "n": n, "dmg": float(r.get("dmg", 0.0)), "window": bool(r.get("window", false)),
		"immune": bool(r.get("immune", false)), "stun": stun, "popped": int(r.get("popped", 0)), "killed": bool(r.get("killed", false)),
		"hp_frac": sim.boss.hp_frac(), "s": s if is_finite(s) else float(v.get("s", sim.player.s)),
		"x": x if is_finite(x) else float(v.get("x", sim.player.x))})
	if bool(r.get("killed", false)):
		_kill(v, false)


func _t5(v: Dictionary, tc: Dictionary) -> void:
	if v.is_empty():
		return
	var frac: float = float(v["hp"]) / maxf(1.0, float(v["max_hp"]))
	var execute: bool = frac <= float(tc.get("execute", 0.4))
	sim.hitstop = maxf(sim.hitstop, float(tc.get("hitstop", 0.14)))
	var a: Dictionary = _active
	if execute:
		v["hp"] = 0.0
		_emit({"type": "skill_hit", "chan": "rage", "tier": 5, "id": "t5_finish", "target_id": int(v["index"]), "idx": 0, "n": 1,
			"dmg": frac * float(v["max_hp"]), "window": true, "immune": false, "stun": 0.0, "popped": 0, "killed": true, "hp_frac": 0.0,
			"s": float(v["s"]), "x": float(v["x"])})
		_kill(v, true)
	else:
		var d: float = float(v["max_hp"]) * float(tc.get("dmgInFrac", 0.3))
		var r: Dictionary = sim.boss.damage(v, d * 0.5, d, true)
		sim.slow_until = sim.real_time + float(tc.get("hitstop", 0.14)) + float(tc.get("slowFor", 0.8))
		sim.slow_scale = float(tc.get("slow", 0.3))
		_emit({"type": "skill_hit", "chan": "rage", "tier": 5, "id": "t5_finish", "target_id": int(v["index"]), "idx": 0, "n": 1,
			"dmg": float(r["dmg"]), "window": bool(r["window"]), "immune": false, "stun": float(tc.get("stun", 2.0)), "popped": 0,
			"killed": bool(r["killed"]), "hp_frac": sim.boss.hp_frac(), "s": float(v["s"]), "x": float(v["x"])})
		if bool(r["killed"]):
			_kill(v, false)
	if a.get("cine", false):
		_active["skippable"] = true


## Same kill path as a tack kill (GameSim._on_landing), then the finisher event on the same tick.
func _kill(v: Dictionary, execute: bool) -> void:
	var is_last: bool = true
	for o: Dictionary in sim.boss.alive():
		if o != v:
			is_last = false
	sim.boss.start_death(v, is_last)
	_emit({"type": "kill", "id": int(v["index"]), "finish": str(v["finish"]), "last": is_last, "s": v["s"], "x": v["x"]})
	if is_last:
		sim.kill_s = float(v["s"])
		sim._enter(&"kill")
		_emit({"type": "finisher", "id": str(v["finish"]), "target_id": int(v["index"]), "execute": execute, "s": v["s"], "x": v["x"]})


## Kill the target now through the finisher path (shots of each finish).
func finish_now(execute: bool = true) -> void:
	var v: Dictionary = target()
	if v.is_empty():
		return
	v["hp"] = 0.0
	_kill(v, execute)


## After every sim.step(): runs what came due in sim time, ticks the item cooldowns.
func tick() -> void:
	var dt: float = sim.time - _last_t
	_last_t = sim.time
	time_scale = 0.0 if sim.hitstop > 0.0 else (sim.slow_scale if sim.real_time < sim.slow_until else 1.0)
	for id: String in _cool.keys():
		var before: float = float(_cool[id])
		_cool[id] = maxf(0.0, before - dt)
		if before > 0.0 and float(_cool[id]) <= 0.0:
			_emit({"type": "item_ready", "id": id, "slot": items.find(id) + 1})
	if not _active.is_empty():
		_active["t"] = float(_active["t"]) + dt
		if bool(_active.get("cine", false)) and sim.real_time - float(_active["t0"]) > float(cfg.get("skipAfter", 0.5)):
			_active["skippable"] = true
	var due: Array[Dictionary] = []
	var keep: Array[Dictionary] = []
	for q: Dictionary in _q:
		if sim.time + 1e-6 >= float(q["at"]):
			due.append(q)
		else:
			keep.append(q)
	_q = keep
	due.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["at"]) < float(b["at"]))
	for q: Dictionary in due:
		(q["fn"] as Callable).call()


## state() + the §6 skills block (and villains[i].stun_skill).
func decorate(st: Dictionary) -> Dictionary:
	var sg: int = segs()
	var m: String = mode()
	var ready: Array[int] = []
	for t: int in [1, 3, 5]:
		if sg >= t and (m == "fight" or (m == "jam" and t == 1)):
			ready.append(t)
	var its: Array[Dictionary] = []
	for i: int in items.size():
		var id: String = items[i]
		var ic: Dictionary = _item_cfg(id)
		var cool: float = float(_cool.get(id, 0.0))
		var cmax: float = float(ic.get("cool" if m == "fight" else "coolJam", 6.0))
		var busy: bool = not _active.is_empty() and int(_active.get("tier", 0)) == 5
		its.append({"id": id, "slot": i + 1, "charges": int(ic.get("charges", -1)), "cool": cool, "cool_max": cmax, "ready": cool <= 0.0,
			"usable": not busy and m != "off", "reason": "busy" if busy else ("phase" if m == "off" else "")})
	var act: Dictionary = {}
	if not _active.is_empty():
		act = _active.duplicate()
		act.erase("t0")
	st["skills"] = {"segs": sg, "rage_tiers_ready": ready, "next_tier": ready.max() if not ready.is_empty() else 0, "mode": m,
		"execute_frac": float(_c("t5").get("execute", 0.4)) if m == "fight" and ready.has(5) else 0.0, "active": act, "items": its,
		"time_scale": time_scale}
	for v: Variant in st.get("villains", []):
		(v as Dictionary)["stun_skill"] = 0.0
	return st
