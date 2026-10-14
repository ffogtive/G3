extends RefCounted
## docs/SKILLS.md §7-1 unit: the rage ladder, item skills, finisher id, skip and safety rules on GameSim + SkillsSim,
## run on both traffic paths (C++ ext when it loads, and force_fallback = the iPhone build).
##   가설: the fight skills only touch BossSim / PlayerSim / WeaponsSim, so every check gives the same answer with the
##         GDScript fallback; the jam side (t1 rage horn, jam drone) works there through the fallback rage_horn /
##         obstacles.
## A test fight: GameSim on the stage, phase forced to boss with the front lock, the player 11 m ahead in the next
## lane, natural attacks and the occupy high-beam relay parked (attack_t / relay_t 99) so windows are only the ones a
## check makes (B.sig.stun = the occupy window).

const _DB := preload("res://core/db.gd")
const FINISHES: Array[String] = ["rocket", "balloon", "heli", "ufo"]

var _fails: int = 0
var _stages: Variant = null
var _tag: String = ""


func _check(ok: bool, what: String) -> void:
	print(("PASS" if ok else "FAIL") + " skills_sim[%s]: %s" % [_tag, what])
	if not ok:
		_fails += 1


func run() -> int:
	_stages = _DB.load_json("res://data/stages.json")
	for fb: bool in [false, true]:
		if not fb and not TrafficBridge.native_available():
			print("SKIP skills_sim: C++ Traffic not loaded (native path)")
			continue
		_tag = "fallback" if fb else "native"
		_ladder(fb)
		_t1(fb)
		_t3(fb)
		_t5(fb)
		_safety(fb)
		_items(fb)
		_skip(fb)
		_determinism(fb)
		_jam(fb)
	_contract()
	return _fails


# --- helpers -------------------------------------------------------------------------------------------

func _sim(fb: bool, stage_id: int = 1, loadout: Dictionary = {"finish": "rocket"}, sd: int = 1007) -> GameSim:
	var tables: Dictionary = _DB.load_traffic_tables()
	tables["options"] = {"loadout": loadout}
	var sim := GameSim.new()
	sim.force_fallback = fb
	sim.setup(_DB.find_stage(_stages, stage_id), tables, sd)
	return sim


func _fight(fb: bool, stage_id: int = 1, loadout: Dictionary = {"finish": "rocket"}, sd: int = 1007) -> GameSim:
	var sim: GameSim = _sim(fb, stage_id, loadout, sd)
	sim._enter(&"jam")
	sim._enter(&"boss")
	sim.front_locked = true
	var v: Dictionary = sim.boss.villains[0]
	sim.player.s = float(v["s"]) + 11.0
	sim.player.lane = clampi(roundi(float(v["lane_pos"])) + 1, 0, Cfg.SHOULDER_LANE)
	sim.player.x = Cfg.lane_x(sim.player.lane)
	sim.player.lc_t = 1.0
	sim.player.v = sim.boss.ref_v()
	sim.boss_clock = 10.0
	_park(sim)
	_run(sim, 0.05)
	return sim


func _park(sim: GameSim) -> void:
	sim.boss.attack_t = 99.0
	if sim.boss.sig.has("relay_t"):
		sim.boss.sig["relay_t"] = 99.0
		sim.boss.sig["stun"] = 0.0


func _run(sim: GameSim, secs: float, out: Array[Dictionary] = []) -> Array[Dictionary]:
	var end: float = sim.real_time + secs
	while sim.real_time < end - 1e-9:
		sim.step(Cfg.TICK)
		out.append_array(sim.events())
	return out


## Steps until cond() (or secs of real time); collects events into out.
func _until(sim: GameSim, cond: Callable, secs: float, out: Array[Dictionary]) -> bool:
	var end: float = sim.real_time + secs
	while sim.real_time < end:
		sim.step(Cfg.TICK)
		out.append_array(sim.events())
		if bool(cond.call()):
			return true
	return false


func _of(ev: Array[Dictionary], type: String, id: String = "") -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e: Dictionary in ev:
		if str(e["type"]) == type and (id == "" or str(e.get("id", "")) == id):
			out.append(e)
	return out


func _sum(ev: Array[Dictionary], key: String) -> float:
	var s: float = 0.0
	for e: Dictionary in ev:
		s += float(e.get(key, 0.0))
	return s


# --- 1. tier selection -------------------------------------------------------------------------------------------

func _ladder(fb: bool) -> void:
	var rages: Array[float] = [0.2, 0.4, 0.6, 0.8, 1.0]
	var want: Array[int] = [1, 1, 3, 3, 5]
	var left: Array[float] = [0.0, 0.2, 0.0, 0.2, 0.0]
	var got: Array[int] = []
	var ok: bool = true
	for i: int in rages.size():
		var sim: GameSim = _fight(fb)
		sim.rage = rages[i]
		var st: Dictionary = sim.state()["skills"]
		sim.input(&"rage")
		var ev: Array[Dictionary] = _run(sim, 0.02)
		var ss: Array[Dictionary] = _of(ev, "skill_start")
		got.append(int(ss[0]["tier"]) if not ss.is_empty() else 0)
		ok = ok and int(st["next_tier"]) == want[i] and absf(sim.rage - left[i]) < 1e-6 and st["mode"] == "fight"
	_check(ok and got == want, "fight: rage 0.2/0.4/0.6/0.8/1.0 → t%s, left 0/0.2/0/0.2/0" % str(got))
	var jam: GameSim = _sim(fb)
	jam._enter(&"jam")
	jam.rage = 1.0
	var jst: Dictionary = jam.state()["skills"]
	jam.input(&"rage")
	var jev: Array[Dictionary] = _run(jam, 0.02)
	var js: Array[Dictionary] = _of(jev, "skill_start")
	_check(jst["mode"] == "jam" and jst["rage_tiers_ready"] == [1] and js.size() == 1 and str(js[0]["id"]) == "t1_horn"
		and _of(jev, "rage_horn").size() == 1 and absf(jam.rage - 0.8) < 0.01, "jam: rage 1.0 → always t1 (분노 경적) + rage_horn, 1 segment spent")
	var lo: GameSim = _fight(fb)
	lo.rage = 0.1
	lo.input(&"rage")
	var dev: Array[Dictionary] = _run(lo, 0.02)
	var dn: Array[Dictionary] = _of(dev, "skill_denied")
	_check(dn.size() == 1 and str(dn[0]["reason"]) == "rage" and _of(dev, "skill_start").is_empty() and is_equal_approx(lo.rage, 0.1),
		"rage 0.1 → skill_denied{rage}, rage unchanged")
	var f5: GameSim = _fight(fb)
	f5.rage = 0.6
	f5.input(&"rage", 5)
	var d5: Array[Dictionary] = _of(_run(f5, 0.02), "skill_denied")
	var j3: GameSim = _sim(fb)
	j3._enter(&"jam")
	j3.rage = 1.0
	j3.input(&"rage", 3)
	var d3: Array[Dictionary] = _of(_run(j3, 0.02), "skill_denied")
	_check(d5.size() == 1 and str(d5[0]["reason"]) == "rage" and d3.size() == 1 and str(d3[0]["reason"]) == "phase",
		"forced tier above the ready one → denied{rage}; t3 in the jam → denied{phase}")


# --- 2. t1 shock wave --------------------------------------------------------------------------------------------

func _t1(fb: bool) -> void:
	var sim: GameSim = _fight(fb)
	var v: Dictionary = sim.boss.villains[0]
	v["lunge"] = {"t": 0.0, "phase": "tele", "reach": 0.0, "hit": false}
	sim.rage = 0.2
	sim.input(&"rage")
	var ev: Array[Dictionary] = []
	_until(sim, func() -> bool: return not _of(ev, "skill_hit").is_empty(), 0.5, ev)
	var hit: Array[Dictionary] = _of(ev, "skill_hit", "t1_wave")
	var stunned: bool = bool((sim.state()["villains"] as Array)[0]["vulnerable"]) and float(v["stun_skill"]) > 0.0
	_run(sim, 0.4, ev)
	var still: bool = bool((sim.state()["villains"] as Array)[0]["vulnerable"])
	_run(sim, 0.4, ev)
	var after: bool = bool((sim.state()["villains"] as Array)[0]["vulnerable"])
	_check(hit.size() == 1 and is_equal_approx(float(hit[0]["dmg"]), 8.0) and not bool(hit[0]["window"])
		and is_equal_approx(float(hit[0]["stun"]), 0.6), "t1: one hit, 8 outside the window, stun 0.6 (%s)" % str(hit))
	_check((v["lunge"] as Dictionary).is_empty() and _of(ev, "damage").is_empty() and _of(ev, "player_hit").is_empty(),
		"t1: the running lunge is cancelled, no damage to the player")
	_check(stunned and still and not after, "t1: the stun is a window (vulnerable) for 0.6 s sim, then closed")
	_check(_of(ev, "skill_end", "t1_wave").size() == 1, "t1: skill_end")
	var w: GameSim = _fight(fb)
	w.boss.sig["stun"] = 1.5
	w.rage = 0.2
	w.input(&"rage")
	var wh: Array[Dictionary] = _of(_run(w, 0.3), "skill_hit")
	_check(wh.size() == 1 and is_equal_approx(float(wh[0]["dmg"]), 16.0) and bool(wh[0]["window"]), "t1 inside the window: 16")
	var far: GameSim = _fight(fb)
	far.player.s += 40.0
	far.rage = 0.2
	far.input(&"rage")
	var fd: Array[Dictionary] = _of(_run(far, 0.05), "skill_denied")
	_check(fd.size() == 1 and str(fd[0]["reason"]) == "target" and is_equal_approx(far.rage, 0.2), "t1 with no villain in 30 m → denied{target}, no rage spent")


# --- 3. t3 carpet ------------------------------------------------------------------------------------------------

func _t3(fb: bool) -> void:
	for inside: bool in [false, true]:
		var sim: GameSim = _fight(fb)
		var v: Dictionary = sim.boss.villains[0]
		if inside:
			sim.boss.sig["stun"] = 1.5
		sim.rage = 0.6
		var tires0: int = int(v["tires"])
		sim.input(&"rage")
		var ev: Array[Dictionary] = []
		_until(sim, func() -> bool: return _of(ev, "skill_hit").size() >= 4, 2.0, ev)
		var hits: Array[Dictionary] = _of(ev, "skill_hit", "t3_carpet")
		var idx: Array[int] = []
		for h: Dictionary in hits:
			idx.append(int(h["idx"]))
		var want: float = 30.0 if inside else 12.0
		_check(hits.size() == 4 and idx == [0, 1, 2, 3] and int(hits[0]["n"]) == 4 and absf(_sum(hits, "dmg") - want) < 1e-3,
			"t3 %s: 4 hits idx 0..3, sum %.1f == %.0f" % ["inside" if inside else "outside", _sum(hits, "dmg"), want])
		_check(int(v["tires"]) < tires0 and _sum(hits, "popped") >= 1.0, "t3: at least one tire popped (%d → %d)" % [tires0, int(v["tires"])])
		if not inside:
			sim.boss.sig["stun"] = 0.0
			var win: bool = bool(sim.boss.vuln(v)["window"]) and sim.window_left() > 0.0
			var d: float = float(sim.boss.damage(v, 1.0, 4.0, false)["dmg"])
			_check(win and is_equal_approx(d, 4.0) and float(hits[0]["stun"]) > 1.19, "t3: 1.2 s stun = window, tacks ×4 inside it (%.0f)" % d)
	var duo: GameSim = _fight(fb, 3)
	duo.rage = 0.6
	duo.input(&"rage")
	var dev: Array[Dictionary] = []
	_until(duo, func() -> bool: return _of(dev, "skill_hit").size() >= 8, 2.0, dev)
	var ids: Dictionary = {}
	for h: Dictionary in _of(dev, "skill_hit"):
		ids[int(h["target_id"])] = true
	_check(ids.has(0) and ids.has(1), "t3 on the 1-3 duo: both villains in the strip are hit (%s)" % str(ids.keys()))


# --- 4. t5 execute / big hit -------------------------------------------------------------------------------------

func _t5(fb: bool) -> void:
	var ok_ids: bool = true
	var seen: Array[String] = []
	for fin: String in FINISHES:
		var sim: GameSim = _fight(fb, 1, {"finish": fin})
		var v: Dictionary = sim.boss.villains[0]
		v["hp"] = 0.39 * float(v["max_hp"])
		sim.rage = 1.0
		sim.input(&"rage")
		var ev: Array[Dictionary] = []
		_until(sim, func() -> bool: return not _of(ev, "finisher").is_empty(), 1.0, ev)
		var f: Array[Dictionary] = _of(ev, "finisher")
		var k: Array[Dictionary] = _of(ev, "kill")
		var order_ok: bool = not f.is_empty() and not k.is_empty() and ev.find(k[0]) < ev.find(f[0])
		seen.append(str(f[0]["id"]) if not f.is_empty() else "")
		ok_ids = ok_ids and order_ok and str(f[0]["id"]) == fin and bool(f[0]["execute"]) and sim.phase == &"kill"
	_check(ok_ids, "t5 at hp 0.39 → execute: kill then finisher{id = equipped} for %s (got %s)" % [str(FINISHES), str(seen)])
	var big: GameSim = _fight(fb)
	var bv: Dictionary = big.boss.villains[0]
	bv["hp"] = 0.6 * float(bv["max_hp"])
	big.boss.sig["stun"] = 1.5
	big.rage = 1.0
	big.input(&"rage")
	var bev: Array[Dictionary] = []
	_until(big, func() -> bool: return not _of(bev, "skill_hit").is_empty(), 1.0, bev)
	var bh: Array[Dictionary] = _of(bev, "skill_hit", "t5_finish")
	_check(bh.size() == 1 and not bool(bh[0]["killed"]) and is_equal_approx(float(bh[0]["dmg"]), 0.3 * float(bv["max_hp"]))
		and is_equal_approx(float(bh[0]["stun"]), 2.0) and bool(bv["alive"]) and _of(bev, "finisher").is_empty(),
		"t5 at hp 0.6 (window): no kill, 30 %% of max HP (%.1f), stun 2.0" % (float(bh[0]["dmg"]) if not bh.is_empty() else -1.0))
	var cine: bool = not big.skills.active.is_empty() and bool((big.skills.active["rage"] as Dictionary)["cine"])
	_check(cine and float(big.state()["skills"]["execute_frac"]) == 0.0, "t5 is a cinematic cast; execute line off once the rage is spent")
	var ready: GameSim = _fight(fb)
	ready.rage = 1.0
	_check(is_equal_approx(float(ready.state()["skills"]["execute_frac"]), 0.4), "MAX ready in the fight → execute_frac 0.4 (HP bar line)")


# --- 5. safety: minKillT, stun cap / immunity, invulnerable while casting ------------------------------------------------

func _safety(fb: bool) -> void:
	var early: GameSim = _fight(fb)
	early.boss_clock = 2.0
	var ev0: Dictionary = early.boss.villains[0]
	ev0["hp"] = 5.0
	early.rage = 0.6
	early.input(&"rage")
	var e1: Array[Dictionary] = []
	_until(early, func() -> bool: return _of(e1, "skill_hit").size() >= 4, 2.0, e1)
	var e5: GameSim = _fight(fb)
	e5.boss_clock = 2.0
	var e5v: Dictionary = e5.boss.villains[0]
	e5v["hp"] = 0.39 * float(e5v["max_hp"])
	e5.rage = 1.0
	e5.input(&"rage")
	var e2: Array[Dictionary] = []
	_until(e5, func() -> bool: return not _of(e2, "skill_hit").is_empty(), 1.0, e2)
	_check(bool(ev0["alive"]) and float(ev0["hp"]) >= 1.0 and bool(e5v["alive"]) and _of(e1 + e2, "kill").is_empty(),
		"before minKillT skills never take HP below 1 (t3 → hp %.1f, t5 at 0.39 → no execute)" % float(ev0["hp"]))
	var sim: GameSim = _fight(fb)
	var v: Dictionary = sim.boss.villains[0]
	sim.rage = 1.0
	sim.input(&"rage", 3)
	var ev: Array[Dictionary] = []
	_run(sim, 0.05, ev)
	var hp0: int = sim.hp
	sim._on_player_hit({"cause": "lunge", "text": "test"})
	var invuln_ok: bool = sim.player.invuln > 0.0 and sim.hp == hp0
	_until(sim, func() -> bool: return not _of(ev, "skill_end").is_empty(), 2.0, ev)
	for k: int in 2:
		sim.input(&"rage", 1)
		var n0: int = _of(ev, "skill_end").size()
		_until(sim, func() -> bool: return _of(ev, "skill_end").size() > n0, 1.0, ev)
	var stuns: float = _sum(_of(ev, "skill_hit"), "stun")
	var chain_ok: bool = float(v["stun_chain"]) <= 2.0 + 1e-6 and stuns <= 2.0 + 1e-6 and stuns > 1.9
	_until(sim, func() -> bool: return float(v["stun_skill"]) <= 0.0, 3.0, ev)
	var immune: bool = float(v["stun_immune"]) > 0.0
	sim.rage = 0.2
	sim.input(&"rage", 1)
	var ev2: Array[Dictionary] = []
	_until(sim, func() -> bool: return not _of(ev2, "skill_hit").is_empty(), 0.5, ev2)
	var h2: Array[Dictionary] = _of(ev2, "skill_hit")
	_check(chain_ok and immune and h2.size() == 1 and float(h2[0]["stun"]) == 0.0,
		"stun chain t3 + t1 + t1 = %.2f s ≤ stunCap 2.0, then 1.5 s stun immunity (next t1 stun %s)" % [stuns, str(h2[0]["stun"]) if not h2.is_empty() else "?"])
	_check(invuln_ok, "invulnerable while casting: a forced lunge hit takes no HP")


# --- 6. items --------------------------------------------------------------------------------------------------

func _items(fb: bool) -> void:
	var lo: Dictionary = {"finish": "rocket", "items": ["mv_jump", "mv_drone"]}
	var sim: GameSim = _fight(fb, 1, lo)
	var items: Array = sim.state()["skills"]["items"]
	_check(items.size() == 2 and str(items[0]["id"]) == "mv_jump" and int(items[0]["slot"]) == 1 and str(items[1]["id"]) == "mv_drone"
		and int(items[1]["slot"]) == 2 and bool(items[0]["ready"]) and bool(items[0]["usable"]), "loadout items → slot 1 jump, slot 2 drone, ready")
	sim.input(&"item1")
	var ev: Array[Dictionary] = _run(sim, 0.02)
	var air: bool = sim.player.jump_t > 0.0 and sim.player.invuln >= 0.8
	var hp0: int = sim.hp
	sim._on_player_hit({"cause": "highbeam", "text": "test"})
	var dodge: bool = sim.hp == hp0
	_until(sim, func() -> bool: return not _of(ev, "skill_hit", "mv_jump").is_empty(), 1.0, ev)
	sim.input(&"item1")
	_run(sim, 0.02, ev)
	var cd: Array[Dictionary] = _of(ev, "skill_denied", "mv_jump")
	_check(_of(ev, "skill_start", "mv_jump").size() == 1 and air and dodge and _of(ev, "skill_hit", "mv_jump").size() == 1,
		"item1 jump: in the air + invulnerable (a hit takes no HP), landing shock wave skill_hit")
	_check(cd.size() == 1 and str(cd[0]["reason"]) == "cool", "item1 again during the 6 s cooldown → denied{cool}")
	_until(sim, func() -> bool: return not _of(ev, "item_ready", "mv_jump").is_empty(), 7.0, ev)
	_check(not _of(ev, "item_ready", "mv_jump").is_empty() and bool((sim.state()["skills"]["items"] as Array)[0]["ready"]),
		"cooldown runs on sim time → item_ready, ready again")
	_park(sim)
	sim.input(&"item2")
	var dev: Array[Dictionary] = []
	_until(sim, func() -> bool: return _of(dev, "skill_hit", "mv_drone").size() >= 6, 2.0, dev)
	var dh: Array[Dictionary] = _of(dev, "skill_hit", "mv_drone")
	_check(dh.size() == 6 and int(dh[0]["n"]) == 6 and absf(_sum(dh, "dmg") - 5.0) < 1e-3, "item2 drone: 6 bomblets, 5 outside the window (%.2f)" % _sum(dh, "dmg"))
	var none: GameSim = _fight(fb, 1, {"finish": "rocket", "items": []})
	none.input(&"item1")
	var nev: Array[Dictionary] = _run(none, 0.05)
	var nd: Array[Dictionary] = _of(nev, "skill_denied")
	_check((none.state()["skills"]["items"] as Array).is_empty() and nd.size() == 1 and str(nd[0]["reason"]) == "phase"
		and _of(nev, "skill_start").is_empty() and none.player.jump_t == 0.0, "not owned: no item slots, item1 → denied{phase}, no jump")
	# jam drone: a mini is caught, else a shoulder obstacle ahead goes (fallback: remove_obstacle)
	var jam: GameSim = _sim(fb, 1, lo)
	jam._enter(&"jam")
	var obs: Array = jam.bridge.obstacles()
	if obs.is_empty():
		print("SKIP skills_sim[%s]: no shoulder obstacle for the jam drone" % _tag)
		return
	var od: Dictionary = obs[0]
	jam.player.lane = Cfg.SHOULDER_LANE
	jam.player.x = Cfg.lane_x(Cfg.SHOULDER_LANE)
	jam.player.s = float(od["s"]) - float(od["len"]) / 2.0 - 12.0
	jam.sync_traffic_player()
	var n0: int = obs.size()
	jam.input(&"item2")
	var jev: Array[Dictionary] = _run(jam, 0.05)
	var mini: bool = not _of(jev, "hit").is_empty()
	var cleared: bool = jam.bridge.obstacles().size() < n0 or not (_of(jev, "smash") + _of(jev, "tow")).is_empty()
	_check(_of(jev, "skill_start", "mv_drone").size() == 1 and (cleared or (mini and not fb)),
		"jam drone: shoulder obstacle 12 m ahead cleared (%d → %d obstacles%s)" % [n0, jam.bridge.obstacles().size(), ", mini caught" if mini else ""])


# --- 7. skip -----------------------------------------------------------------------------------------------------

func _execute_run(fb: bool, skip: bool) -> Dictionary:
	var sim: GameSim = _fight(fb)
	var v: Dictionary = sim.boss.villains[0]
	v["hp"] = 0.39 * float(v["max_hp"])
	sim.rage = 1.0
	sim.input(&"rage")
	var ev: Array[Dictionary] = []
	_until(sim, func() -> bool: return sim.phase == &"kill", 1.0, ev)
	var kill: Dictionary = _of(ev, "kill")[0] if not _of(ev, "kill").is_empty() else {}
	var at: Array = [sim.time, kill.get("s"), kill.get("finish"), float(v["hp"])]
	var t_kill: float = sim.real_time
	var skipped: bool = false
	while sim.phase == &"kill" and sim.real_time - t_kill < 6.0:
		if skip and not skipped and bool(sim.state()["skills"]["skip_ready"]):
			sim.input(&"skip")
			skipped = true
		sim.step(Cfg.TICK)
		ev.append_array(sim.events())
	return {"kill": at, "release": sim.real_time - t_kill, "skip": _of(ev, "skip").size(), "phase": sim.phase}


func _skip(fb: bool) -> void:
	var a: Dictionary = _execute_run(fb, false)
	var b: Dictionary = _execute_run(fb, true)
	var done: float = 1.9 + 0.3
	_check(a["kill"] == b["kill"] and int(b["skip"]) == 1 and float(b["release"]) < float(a["release"]) - 0.5
		and float(a["release"]) <= done + 0.05 and a["phase"] == &"release" and b["phase"] == &"release",
		"skip: same kill tick result %s; release %.2f s → %.2f s with the tap (rocket done + 0.3 = %.1f s)" % [str(a["kill"]),
		float(a["release"]), float(b["release"]), done])
	var hp: Array[float] = []
	var skipped: Array[bool] = []
	for sk: bool in [false, true]:
		var sim: GameSim = _fight(fb)
		sim.rage = 1.0
		sim.input(&"rage")
		var ev: Array[Dictionary] = []
		var tapped: bool = false
		while _of(ev, "skill_end").is_empty() and sim.real_time < 5.0 + 3.0:
			if sk and not tapped and bool(sim.state()["skills"]["skip_ready"]):
				sim.input(&"skip")
				tapped = true
			sim.step(Cfg.TICK)
			ev.append_array(sim.events())
		var se: Array[Dictionary] = _of(ev, "skill_end")
		hp.append(float(sim.boss.villains[0]["hp"]) if not se.is_empty() else -1.0)
		skipped.append(not se.is_empty() and bool(se[0]["skipped"]))
	_check(hp[0] == hp[1] and hp[0] > 0.0 and skipped == [false, true], "t5 (no execute) skip: villain HP at skill_end %s, skipped %s" % [str(hp), str(skipped)])


# --- 8. determinism ----------------------------------------------------------------------------------------------

func _det_hash(fb: bool) -> String:
	var sim: GameSim = _fight(fb, 1, {"finish": "heli", "items": ["mv_jump", "mv_drone"]}, 4242)
	sim.boss.attack_t = 1.0
	sim.rage = 1.0
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var script: Dictionary = {10: [&"rage", 3], 200: [&"item1", null], 400: [&"rage", 1], 600: [&"item2", null], 900: [&"fire", true]}
	for k: int in 1800:
		if script.has(k):
			sim.input(script[k][0], script[k][1])
		sim.step(Cfg.TICK)
		for e: Dictionary in sim.events():
			ctx.update(var_to_bytes(e))
	ctx.update(var_to_bytes([sim.state()["villains"], sim.rage, sim.hp, sim.time]))
	return ctx.finish().hex_encode()


func _determinism(fb: bool) -> void:
	var a: String = _det_hash(fb)
	var b: String = _det_hash(fb)
	_check(a == b, "same seed + same input log → same event hash (%s)" % a.substr(0, 12))


# --- 9. jam on the fallback: rage horn clears the shoulder, 압정 never honks ----------------------------------------------

func _jam(fb: bool) -> void:
	var sim: GameSim = _sim(fb)
	sim._enter(&"jam")
	var target: Dictionary = {}
	for o: Variant in sim.bridge.obstacles():
		if bool((o as Dictionary).get("smash", false)):
			target = o
	if target.is_empty():
		print("SKIP skills_sim[%s]: no smashable obstacle" % _tag)
	else:
		sim.player.lane = Cfg.SHOULDER_LANE
		sim.player.x = Cfg.lane_x(Cfg.SHOULDER_LANE)
		sim.player.s = float(target["s"]) - 12.0
		sim.sync_traffic_player()
		sim.rage = 0.2
		sim.input(&"rage")
		var ev: Array[Dictionary] = _run(sim, 0.02)
		var rh: Array[Dictionary] = _of(ev, "rage_horn")
		var sm: PackedInt32Array = rh[0]["smashed"] if not rh.is_empty() else PackedInt32Array()
		var tw: PackedInt32Array = rh[0]["towed"] if not rh.is_empty() else PackedInt32Array()
		_check(rh.size() == 1 and (sm.size() + tw.size()) > 0 and sm.has(int(target["id"])),
			"jam t1 next to the cones (12 m) → rage_horn smashed %s towed %s" % [str(sm), str(tw)])
	var j2: GameSim = _sim(fb)
	j2._enter(&"jam")
	var ev2: Array[Dictionary] = []
	for k: int in 6:
		j2.input(&"fire", true)
		_run(j2, 0.25, ev2)
		j2.input(&"fire", false)
		_run(j2, 0.25, ev2)
	_check(_of(ev2, "honk").is_empty() and _of(ev2, "skill_start").is_empty(), "jam: 압정 presses only → 0 honk, 0 skills (feedback #3)")


# --- contract ---------------------------------------------------------------------------------------------------

func _contract() -> void:
	_tag = "data"
	var cfg: Dictionary = _DB.load_json("res://data/config.json")
	var sk: Dictionary = cfg.get("skills", {})
	var lad: Array[int] = []
	for x: Variant in sk.get("ladder", []):
		lad.append(int(x))
	var ok: bool = lad == [1, 3, 5] and (sk.get("items", {}) as Dictionary).has("mv_jump") and (sk.get("items", {}) as Dictionary).has("mv_drone")
	for t: String in ["t1", "t3", "t5"]:
		ok = ok and (sk.get(t) is Dictionary) and float((sk[t] as Dictionary).get("dur", 0.0)) > 0.0
	for f: String in FINISHES:
		ok = ok and float(((sk.get("finish", {}) as Dictionary).get(f, {}) as Dictionary).get("done", 0.0)) <= 2.5
	_check(ok, "config.skills: ladder [1, 3, 5], t1/t3/t5, items mv_jump/mv_drone, finish done ≤ 2.5 s")
	# Progress.loadout() today carries the owned move items as the jump / drone flags (no "items" key): same slots
	var flags: GameSim = _sim(true, 1, {"finish": "ufo", "jump": true, "drone": true})
	var fi: Array = flags.state()["skills"]["items"]
	_check(ok and fi.size() == 2 and str(fi[0]["id"]) == "mv_jump" and str(fi[1]["id"]) == "mv_drone" and str(flags.boss.finish_style) == "ufo",
		"Progress.loadout() flags jump / drone (no items key) → slot 1 mv_jump, slot 2 mv_drone; finish from the loadout")
	var fresh := GameSim.new()
	var t2: Dictionary = _DB.load_traffic_tables()
	(t2["config"] as Dictionary).erase("skills")
	fresh.setup(_DB.find_stage(_stages, 1), t2, 1007)
	_check(not fresh.skills.enabled and float(fresh.boss.villains[0]["max_hp"]) == 140.0 and fresh.state()["skills"]["mode"] == "off",
		"without config.skills: skills off, HP unscaled (old rage horn / bomb path)")
