extends RefCounted
## docs/SKILLS.md §7-1 unit: the rage ladder, item skills, finisher id, skip and safety rules on GameSim + SkillsSim,
## run on both traffic paths (C++ ext when it loads, and force_fallback = the iPhone build).
##   가설: the fight skills only touch BossSim / PlayerSim / WeaponsSim, so every check gives the same answer with the
##         GDScript fallback; the jam side (t1 rage horn, jam drone) works there through the fallback rage_horn /
##         obstacles.
## A test fight: GameSim on the stage, phase forced to boss with the front lock, the player 11 m ahead in the next
## lane, natural attacks and the occupy high-beam relay parked (attack_t / relay_t 99) so windows are only the ones a
## check makes (B.sig.stun = the occupy window).
## r3 (combat C1–C4): 압정 콤보 milestones (×5 따닥 / ×10 따다닥 / ×20 타이어 저격, cycle 20, timeout 1.5 s, break on a
## hit), HP-fraction skill damage (t1 4/5 %, t3 14/18 % of max HP), rage t1 that always connects in the boss phase
## (60 m, every lane, also before the lock: + rage_horn, stun 0.4; chase 0.8 s then refund) and the fx recipe data.
##   가설: ✅ the combo / wave / frac rules only touch BossSim + GameSim state, so both traffic paths answer the same.

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
		_combo(fb)
		_combo_break(fb)
		_combo_duo(fb)
		_combo_floor(fb)
		_combo_det(fb)
		_frac(fb)
		_prelock(fb)
		_wave_reach(fb)
		_chase(fb)
	_contract()
	_contract_r3()
	return _fails


# --- helpers -------------------------------------------------------------------------------------------

func _sim(fb: bool, stage_id: int = 1, loadout: Dictionary = {"finish": "rocket"}, sd: int = 1007, opts: Dictionary = {}) -> GameSim:
	var tables: Dictionary = _DB.load_traffic_tables()
	tables["options"] = {"loadout": loadout}
	tables["options"].merge(opts, true)
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


## r3 C2: a tier's damage per cast (frac × max HP when the config has it, else the flat dmgIn / dmgOut).
func _tier_dmg(sim: GameSim, tier: int, inside: bool, v: Dictionary) -> float:
	var c: Dictionary = sim.skills.cfg.get("t%d" % tier, {})
	var fk: String = "dmgInFrac" if inside else "dmgOutFrac"
	if c.has(fk):
		return float(c[fk]) * float(v["max_hp"])
	return float(c.get("dmgIn" if inside else "dmgOut", 0.0))


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
	var t1_out: float = _tier_dmg(sim, 1, false, v)
	_check(hit.size() == 1 and is_equal_approx(float(hit[0]["dmg"]), t1_out) and not bool(hit[0]["window"])
		and is_equal_approx(float(hit[0]["stun"]), 0.6), "t1: one hit, dmgOut %.1f outside the window, stun 0.6 (%s)" % [t1_out, str(hit)])
	_check((v["lunge"] as Dictionary).is_empty() and _of(ev, "damage").is_empty() and _of(ev, "player_hit").is_empty(),
		"t1: the running lunge is cancelled, no damage to the player")
	_check(stunned and still and not after, "t1: the stun is a window (vulnerable) for 0.6 s sim, then closed")
	_check(_of(ev, "skill_end", "t1_wave").size() == 1, "t1: skill_end")
	var w: GameSim = _fight(fb)
	w.boss.sig["stun"] = 1.5
	w.rage = 0.2
	w.input(&"rage")
	var wh: Array[Dictionary] = _of(_run(w, 0.3), "skill_hit")
	var t1_in: float = _tier_dmg(w, 1, true, w.boss.villains[0])
	_check(wh.size() == 1 and is_equal_approx(float(wh[0]["dmg"]), t1_in) and bool(wh[0]["window"]), "t1 inside the window: dmgIn %.1f" % t1_in)
	# r3 C3: 40 m ahead used to be denied{target} (range 30 m, ±1 lane); now the wave reaches 60 m in every lane
	var far: GameSim = _fight(fb)
	far.player.s += 40.0
	far.rage = 0.2
	far.input(&"rage")
	var fev: Array[Dictionary] = []
	_until(far, func() -> bool: return not _of(fev, "skill_hit", "t1_wave").is_empty(), 0.8, fev)
	_check(_of(fev, "skill_denied").is_empty() and _of(fev, "skill_hit", "t1_wave").size() == 1,
		"t1 with the villain 51 m away (was denied{target} at 30 m) → hit, no denial (%s)" % str(_of(fev, "skill_denied")))


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
		var want: float = _tier_dmg(sim, 3, inside, v)
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


# --- 10. r3 C1: 압정 콤보 milestones -----------------------------------------------------------------------------

## One 압정 landing on villain vi through GameSim._on_landing (the W hook calls skills.on_tack_hit from there).
func _land(sim: GameSim, vi: int, out: Array[Dictionary]) -> void:
	var v: Dictionary = sim.boss.villains[vi]
	sim._on_landing({"kind": "tack", "mini_id": 0, "hit": true, "vi": vi, "from_rear": float(v["s"]) > sim.player.s,
		"s": float(v["s"]), "x": float(v["x"])})
	out.append_array(sim.events())


## n landings `gap` sim s apart on villain vi, events into out.
func _tacks(sim: GameSim, vi: int, n: int, gap: float, out: Array[Dictionary]) -> void:
	for i: int in n:
		_land(sim, vi, out)
		_run(sim, gap, out)


func _quiet(sim: GameSim) -> void:
	_park(sim)
	for v: Dictionary in sim.boss.villains:
		v["next_taunt"] = 1e9


func _combo_hits(ev: Array[Dictionary], id: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e: Dictionary in _of(ev, "skill_hit", id):
		if str(e.get("chan", "")) == "combo":
			out.append(e)
	return out


func _combo(fb: bool) -> void:
	var sim: GameSim = _fight(fb)
	_quiet(sim)
	var v: Dictionary = sim.boss.villains[0]
	var mx: float = float(v["max_hp"])
	var ev: Array[Dictionary] = []
	_tacks(sim, 0, 4, 0.2, ev)
	var st4: Dictionary = (sim.state()["skills"] as Dictionary).get("combo", {})
	_tacks(sim, 0, 1, 0.3, ev)
	var c5: Array[Dictionary] = _combo_hits(ev, "c5_double")
	var m5: Array[Dictionary] = _of(ev, "combo_milestone")
	_check(int(st4.get("n", -1)) == 4 and int(st4.get("next_n", 0)) == 5 and str(st4.get("next_id", "")) == "c5"
		and float(st4.get("left", 0.0)) > 1.2 and float(st4.get("left", 0.0)) <= 1.5,
		"combo state after 4 tacks: n 4, next ×5 c5, left %.2f s of 1.5 (%s)" % [float(st4.get("left", 0.0)), str(st4)])
	_check(m5.size() == 1 and int(m5[0]["n"]) == 5 and str(m5[0]["id"]) == "c5" and int(m5[0]["target_id"]) == 0
		and c5.size() == 2 and int(c5[0]["n"]) == 2 and absf(_sum(c5, "dmg") - 2.0 * 0.005 * mx) < 1e-3,
		"×5 → combo_milestone{n 5, c5} + c5_double 2 hits = 2 × 0.5 %% max HP (%.2f of %.0f)" % [_sum(c5, "dmg"), mx])
	_tacks(sim, 0, 5, 0.2, ev)
	_run(sim, 0.3, ev)
	var c10: Array[Dictionary] = _combo_hits(ev, "c10_burst")
	var s10: Array[Dictionary] = _of(ev, "skill_start", "c10_burst")
	var n_after: int = int(((sim.state()["skills"] as Dictionary).get("combo", {}) as Dictionary).get("n", -1))
	_check(s10.size() == 1 and str(s10[0]["chan"]) == "combo" and c10.size() == 3 and int(c10[0]["n"]) == 3
		and absf(_sum(c10, "dmg") - 3.0 * 0.01 * mx) < 1e-3 and not bool(c10[0]["window"]),
		"×10 → skill_start/skill_hit{chan combo, c10_burst, n 3}, outside the window 3 × 1 %% max HP = %.2f" % _sum(c10, "dmg"))
	_check(n_after == 10, "skill hits do not count: combo n stays 10 after the 3 burst hits (got %d)" % n_after)
	var tires0: int = int(v["tires"])
	_tacks(sim, 0, 10, 0.2, ev)
	_run(sim, 0.3, ev)
	var c20: Array[Dictionary] = _combo_hits(ev, "c20_snipe")
	var m20: Array[Dictionary] = []
	for m: Dictionary in _of(ev, "combo_milestone"):
		if int(m["n"]) == 20:
			m20.append(m)
	var wl: float = sim.window_left()
	_check(m20.size() == 1 and str(m20[0]["id"]) == "c20" and c20.size() == 1 and int(c20[0]["popped"]) == 1
		and is_equal_approx(float(c20[0]["stun"]), 0.8) and wl > 0.0 and int(v["tires"]) == tires0 - 1
		and absf(float(c20[0]["dmg"]) - 0.05 * mx) < 1e-3,
		"×20 → c20_snipe: 5 %% max HP (%.2f), popped 1 (tires %d → %d), stun 0.8, window_left %.2f > 0" % [
		float(c20[0]["dmg"]) if not c20.is_empty() else -1.0, tires0, int(v["tires"]), wl])
	var m15: int = 0
	for m: Dictionary in _of(ev, "combo_milestone"):
		m15 += 1 if int(m["n"]) == 15 and str(m["id"]) == "c5" else 0
	_check(m15 == 1 and _of(ev, "combo_milestone").size() == 4, "milestones 5 / 10 / 15 / 20 = c5 / c10 / c5 / c20 (%d events)" % _of(ev, "combo_milestone").size())
	var hp_pre: int = sim.hp
	sim._on_player_hit({"cause": "highbeam", "text": "test"})
	_check(sim.hp < hp_pre, "combo casts give no invuln (a hit right after c20 still lands: hp %d → %d)" % [hp_pre, sim.hp])
	# timeout: 1.5 s sim without a counted hit
	var t: GameSim = _fight(fb)
	_quiet(t)
	var tev: Array[Dictionary] = []
	_tacks(t, 0, 6, 0.2, tev)
	_run(t, 1.6, tev)
	var br: Array[Dictionary] = _of(tev, "combo_break")
	_check(br.size() == 1 and str(br[0]["reason"]) == "timeout" and int(br[0]["n"]) == 6
		and int(((t.state()["skills"] as Dictionary).get("combo", {}) as Dictionary).get("n", -1)) == 0,
		"1.5 s sim with no tack hit → combo_break{timeout, n 6}, n back to 0 (%s)" % str(br))
	var t2: GameSim = _fight(fb)
	_quiet(t2)
	var t2ev: Array[Dictionary] = []
	_tacks(t2, 0, 3, 0.2, t2ev)
	_run(t2, 1.6, t2ev)
	_check(_of(t2ev, "combo_break").is_empty(), "timeout of a ×3 streak (< 5): no combo_break event")


func _combo_break(fb: bool) -> void:
	var sim: GameSim = _fight(fb)
	_quiet(sim)
	var ev: Array[Dictionary] = []
	_tacks(sim, 0, 7, 0.2, ev)
	sim._on_player_hit({"cause": "highbeam", "text": "test"})
	ev.append_array(sim.events())
	var br: Array[Dictionary] = _of(ev, "combo_break")
	var n1: int = int(((sim.state()["skills"] as Dictionary).get("combo", {}) as Dictionary).get("n", -1))
	_check(br.size() == 1 and str(br[0]["reason"]) == "hit" and int(br[0]["n"]) == 7 and n1 == 0,
		"player hit → combo_break{hit, n 7}, n 0 (%s)" % str(br))
	sim._on_player_hit({"cause": "highbeam", "text": "test"})  # invuln now: no second break
	ev.append_array(sim.events())
	_check(_of(ev, "combo_break").size() == 1, "a hit absorbed by invuln breaks nothing")
	# t1 / t3 hits (skill_hit) never count
	var sk: GameSim = _fight(fb)
	_quiet(sk)
	var sev: Array[Dictionary] = []
	_tacks(sk, 0, 3, 0.2, sev)
	sk.rage = 0.6
	sk.input(&"rage", 3)
	_until(sk, func() -> bool: return _of(sev, "skill_hit", "t3_carpet").size() >= 4, 2.0, sev)
	var n2: int = int(((sk.state()["skills"] as Dictionary).get("combo", {}) as Dictionary).get("n", -1))
	_check(n2 == 3 and _of(sev, "combo_break").is_empty(), "t3 hits neither count nor reset (n %d)" % n2)
	# jam: tacks before the boss phase never count
	var jam: GameSim = _sim(fb)
	jam._enter(&"jam")
	jam.skills.on_tack_hit(jam, jam.boss.villains[0], {"villain": jam.boss.villains[0], "dmg": 1.0})
	_check(int(((jam.state()["skills"] as Dictionary).get("combo", {}) as Dictionary).get("n", -1)) == 0, "jam phase: on_tack_hit does not count")


func _combo_duo(fb: bool) -> void:
	var sim: GameSim = _fight(fb, 3)
	_quiet(sim)
	var ev: Array[Dictionary] = []
	_tacks(sim, 0, 9, 0.15, ev)
	_land(sim, 1, ev)
	_run(sim, 0.4, ev)
	var m: Array[Dictionary] = []
	for e: Dictionary in _of(ev, "combo_milestone"):
		if int(e["n"]) == 10:
			m.append(e)
	var c10: Array[Dictionary] = _combo_hits(ev, "c10_burst")
	var ids: Dictionary = {}
	for h: Dictionary in c10:
		ids[int(h["target_id"])] = true
	_check(m.size() == 1 and int(m[0]["target_id"]) == 1 and c10.size() == 3 and ids.keys() == [1],
		"1-3 duo: the ×10 tack hit villain 1 → the burst goes to villain 1 (%s)" % str(ids.keys()))


func _combo_floor(fb: bool) -> void:
	var sim: GameSim = _fight(fb)
	_quiet(sim)
	sim.boss_clock = 1.0
	var v: Dictionary = sim.boss.villains[0]
	v["hp"] = 10.0 + 2.0 * 0.005 * float(v["max_hp"]) + 1.5  # 10 tacks (never floored) + the c5 leave 1.5; the c10 would kill
	var ev: Array[Dictionary] = []
	_tacks(sim, 0, 10, 0.05, ev)
	_run(sim, 0.4, ev)
	_check(bool(v["alive"]) and float(v["hp"]) >= 1.0 - 1e-6 and not _combo_hits(ev, "c10_burst").is_empty(),
		"before minKillT the c5 / c10 hits keep HP ≥ 1 (hp %.2f)" % float(v["hp"]))


func _combo_det(fb: bool) -> String:
	var hashes: Array[String] = []
	var c20: Array[int] = []
	for k: int in 2:
		var sim: GameSim = _fight(fb, 2, {"finish": "rocket"}, 4242)
		for v: Dictionary in sim.boss.villains:
			v["hp"] = 1e5
			v["max_hp"] = 1e5
		sim.input(&"fire", true)
		var ctx := HashingContext.new()
		ctx.start(HashingContext.HASH_SHA256)
		var n20: int = 0
		for i: int in 1440:
			sim.step(Cfg.TICK)
			for e: Dictionary in sim.events():
				ctx.update(var_to_bytes(e))
				n20 += 1 if str(e["type"]) == "combo_milestone" and str(e["id"]) == "c20" else 0
		hashes.append(ctx.finish().hex_encode())
		c20.append(n20)
	_check(hashes[0] == hashes[1] and c20[0] >= 1, "combo: same seed + fire held 12 s → same event hash (%s), c20 ×%d" % [hashes[0].substr(0, 12), c20[0]])
	return hashes[0]


# --- 11. r3 C2: HP-fraction damage -------------------------------------------------------------------------------

func _frac(fb: bool) -> void:
	var pct: Array[float] = []
	for sid: int in [1, 4]:
		var sim: GameSim = _fight(fb, sid)
		_quiet(sim)
		var v: Dictionary = sim.boss.villains[0]
		sim.rage = 0.6
		sim.input(&"rage", 3)
		var ev: Array[Dictionary] = []
		_until(sim, func() -> bool: return _of(ev, "skill_hit", "t3_carpet").size() >= 4, 2.0, ev)
		var hits: Array[Dictionary] = _of(ev, "skill_hit", "t3_carpet")
		var w: bool = not hits.is_empty() and bool(hits[0]["window"])
		pct.append(_sum(hits, "dmg") / float(v["max_hp"]) * 100.0 if not w else -1.0)
	_check(absf(pct[0] - 14.0) <= 0.5 and absf(pct[1] - 14.0) <= 0.5, "t3 outside the window: 1-1 %.2f %% / 1-4 %.2f %% of max HP (14 ± 0.5)" % [pct[0], pct[1]])
	var c: Dictionary = _fight(fb).skills.cfg
	var t1c: Dictionary = c.get("t1", {})
	var t3c: Dictionary = c.get("t3", {})
	var per_seg_out: Array[float] = [float(t1c.get("dmgOutFrac", 0.0)) / float(t1c.get("cost", 1)), float(t3c.get("dmgOutFrac", 0.0)) / float(t3c.get("cost", 3))]
	var per_seg_in: Array[float] = [float(t1c.get("dmgInFrac", 0.0)) / float(t1c.get("cost", 1)), float(t3c.get("dmgInFrac", 0.0)) / float(t3c.get("cost", 3))]
	_check(per_seg_out[1] >= per_seg_out[0] and per_seg_in[1] >= per_seg_in[0] and per_seg_out[0] > 0.0,
		"per rage segment t3 ≥ t1 (out %.3f ≥ %.3f, in %.3f ≥ %.3f)" % [per_seg_out[1], per_seg_out[0], per_seg_in[1], per_seg_in[0]])


# --- 12. r3 C3: rage t1 always connects in the boss phase ---------------------------------------------------------

## Boss phase before the front lock: the player ds m from the villain (negative = behind) in `lane`.
func _pre(fb: bool, stage_id: int = 1, ds: float = -20.0, lane: int = -1) -> GameSim:
	var sim: GameSim = _sim(fb, stage_id, {"finish": "rocket"}, 1007, {"checkpoints": false})  # teleporting would fire A3
	sim._enter(&"jam")
	sim._enter(&"boss")
	var v: Dictionary = sim.boss.villains[0]
	sim.player.s = float(v["s"]) + ds
	if lane >= 0:
		sim.player.lane = lane
		sim.player.x = Cfg.lane_x(lane)
		sim.player.lc_t = 1.0
	sim.player.v = sim.boss.ref_v()
	sim.sync_traffic_player()
	_quiet(sim)
	return sim


func _prelock(fb: bool) -> void:
	var sim: GameSim = _pre(fb, 1, -20.0, Cfg.SHOULDER_LANE)
	var v: Dictionary = sim.boss.villains[0]
	sim.rage = 1.0  # segs 5: before the lock the ladder is preLockLadder [1]
	var st: Dictionary = sim.state()["skills"]
	_check(not sim.front_locked and str(st["mode"]) == "fight" and bool(st.get("prelock", false)) and str(st.get("face", "")) == "wave"
		and st["rage_tiers_ready"] == [1] and int(st["next_tier"]) == 1,
		"boss before the lock: mode fight, prelock, face 'wave', tiers [1] at MAX (%s / %s / %s)" % [st["mode"], st.get("face", "?"), str(st["rage_tiers_ready"])])
	sim.rage = 0.2
	var hp0: float = float(v["hp"])
	sim.input(&"rage")
	var ev: Array[Dictionary] = []
	sim.step(Cfg.TICK)
	ev.append_array(sim.events())
	var rage_after_cast: float = sim.rage
	_until(sim, func() -> bool: return not _of(ev, "skill_hit", "t1_wave").is_empty(), 0.8, ev)
	var ss: Array[Dictionary] = _of(ev, "skill_start", "t1_wave")
	var sh: Array[Dictionary] = _of(ev, "skill_hit", "t1_wave")
	var rh: Array[Dictionary] = _of(ev, "rage_horn")
	_check(ss.size() == 1 and sh.size() == 1 and int(sh[0]["target_id"]) == 0 and bool(sh[0].get("from_rear", false))
		and float(v["hp"]) < hp0 and rh.size() == 1 and _of(ev, "skill_start", "t1_horn").is_empty(),
		"before the lock, segs 1 tap → skill_start t1_wave + villain skill_hit (from_rear %s, hp %.1f → %.1f) + rage_horn ×%d" % [
		str(sh[0].get("from_rear", "?")) if not sh.is_empty() else "?", hp0, float(v["hp"]), rh.size()])
	var stun_pre: float = float(sh[0]["stun"]) if not sh.is_empty() else -1.0
	var want_stun: float = float((sim.skills.cfg.get("t1", {}) as Dictionary).get("stunPreLock", 0.4))
	_check(is_equal_approx(stun_pre, want_stun) and rage_after_cast < 0.01, "pre-lock wave: stun %.2f (stunPreLock %.1f), 1 segment spent on the cast tick (rage 0.2 → %.3f)" % [stun_pre, want_stun, rage_after_cast])
	var rel: Dictionary = rh[0] if not rh.is_empty() else {}
	_check(str(rel.get("via", "")) == "t1_wave", "the pre-lock rage_horn is tagged via 't1_wave' (view: no horn sound)")
	# jam phase: still the shoulder-clearing horn only
	var jam: GameSim = _sim(fb)
	jam._enter(&"jam")
	jam.rage = 0.2
	var jst: Dictionary = jam.state()["skills"]
	jam.input(&"rage")
	var jev: Array[Dictionary] = _run(jam, 0.6)
	_check(str(jst.get("face", "")) == "clear" and not bool(jst.get("prelock", true)) and _of(jev, "skill_start", "t1_horn").size() == 1
		and _of(jev, "skill_start", "t1_wave").is_empty() and _of(jev, "skill_hit").is_empty(),
		"jam phase: face 'clear', t1_horn only (no wave, no skill_hit)")
	# items keep the jam rules before the lock: the jump is a jam hop (landing slot, never a fight landing shock wave)
	var it: GameSim = _pre(fb, 1, -20.0, Cfg.SHOULDER_LANE)
	it.skills.setup(it.skills.cfg, it.tune, {"finish": "rocket", "items": ["mv_jump", "mv_drone"]})
	it.input(&"item1")
	var iev: Array[Dictionary] = _run(it, 1.2)
	var idn: Array[Dictionary] = _of(iev, "skill_denied", "mv_jump")
	var jam_rules: bool = (_of(iev, "skill_start", "mv_jump").size() == 1 or (idn.size() == 1 and str(idn[0]["reason"]) in ["blocked", "room"]))
	_check(jam_rules and _of(iev, "skill_hit", "mv_jump").is_empty() and it.player.invuln < 0.5,
		"pre-lock item1 = jam hop (no fight landing hit, no fight invuln): %s" % str(_of(iev, "skill_start") + idn))


func _wave_reach(fb: bool) -> void:
	var c: Dictionary = _fight(fb).skills.cfg.get("t1", {})
	var dpm: float = float(c.get("delayPerM", 0.00833))
	var d0: float = float(c.get("delay", 0.12))
	var from: float = float(c.get("delayFrom", 15.0))
	var got: Array[String] = []
	var ok: bool = true
	for ds: float in [15.0, 20.0, 55.0]:
		var sim: GameSim = _fight(fb)
		_quiet(sim)
		var v: Dictionary = sim.boss.villains[0]
		sim.player.s = float(v["s"]) + ds
		sim.player.lane = 3
		sim.player.x = Cfg.lane_x(3)
		sim.player.lc_t = 1.0
		sim.rage = 0.2
		sim.input(&"rage")
		var t_cast: float = -1.0
		var t_hit: float = -1.0
		var end: float = sim.real_time + 1.0
		while sim.real_time < end and t_hit < 0.0:
			sim.step(Cfg.TICK)
			for e: Dictionary in sim.events():
				if str(e["type"]) == "skill_start" and str(e["id"]) == "t1_wave":
					t_cast = sim.time
				elif str(e["type"]) == "skill_hit" and str(e["id"]) == "t1_wave":
					t_hit = sim.time
		var want: float = d0 + maxf(0.0, ds - from) * dpm
		var meas: float = t_hit - t_cast if t_hit >= 0.0 and t_cast >= 0.0 else -1.0
		got.append("%.0f m → %.3f (want %.3f)" % [ds, meas, want])
		ok = ok and absf(meas - want) <= 0.01
	_check(ok, "player lane 3 / villain lane 0: wave hits at ds 15 / 20 / 55 m with delay 0.12 + (ds − 15) × %.5f: %s" % [dpm, ", ".join(got)])


func _chase(fb: bool) -> void:
	# out of reach and out-running it (ahead + boost): chase 0.8 s, then refund + skill_denied{far, refunded}
	var sim: GameSim = _fight(fb)
	_quiet(sim)
	var v: Dictionary = sim.boss.villains[0]
	sim.player.s = float(v["s"]) + 90.0
	sim.rage = 0.2
	var r0: float = sim.rage
	sim.input(&"rage")
	var ev: Array[Dictionary] = []
	_until(sim, func() -> bool: return not _of(ev, "skill_denied").is_empty() or not _of(ev, "skill_hit").is_empty(), 1.2, ev)
	var dn: Array[Dictionary] = _of(ev, "skill_denied")
	var bub: bool = false
	for b: Dictionary in _of(ev, "bubble"):
		bub = bub or str(b.get("text", "")) == "너무 멀다!"
	_check(dn.size() == 1 and str(dn[0]["reason"]) == "far" and bool(dn[0].get("refunded", false)) and is_equal_approx(sim.rage, r0)
		and _of(ev, "skill_hit").is_empty() and bub and not _of(ev, "skill_chase").is_empty(),
		"90 m ahead: chase then skill_denied{far, refunded} + '너무 멀다!', rage %.2f == %.2f (%s)" % [sim.rage, r0, str(dn)])
	# just out of reach behind: the chase boost closes it inside 0.8 s → hit (or a refund, never a lost segment)
	var c: GameSim = _fight(fb)
	_quiet(c)
	var cv: Dictionary = c.boss.villains[0]
	var reach: float = float((c.skills.cfg.get("t1", {}) as Dictionary).get("reach", 60.0))
	c.player.s = float(cv["s"]) - reach - 5.0
	c.player.v = c.boss.ref_v() + 9.0
	c.rage = 0.2
	c.input(&"rage")
	var cev: Array[Dictionary] = []
	var t0: float = c.time
	_until(c, func() -> bool: return not _of(cev, "skill_denied").is_empty() or not _of(cev, "skill_hit", "t1_wave").is_empty(), 1.2, cev)
	var hit: bool = not _of(cev, "skill_hit", "t1_wave").is_empty()
	var refunded: bool = not _of(cev, "skill_denied").is_empty() and bool(_of(cev, "skill_denied")[0].get("refunded", false)) and is_equal_approx(c.rage, 0.2)
	_check((hit and c.time - t0 <= float((c.skills.cfg.get("t1", {}) as Dictionary).get("chase", 0.8)) + 0.6) or refunded,
		"%.0f m behind: within the chase the wave hits (%s) or the segment comes back (%s)" % [reach + 5.0, hit, refunded])


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


## r3 C1–C4 data contract (config.skills / config.boss.genericWindow / stages 1-3).
func _contract_r3() -> void:
	_tag = "data r3"
	var cfg: Dictionary = _DB.load_json("res://data/config.json")
	var sk: Dictionary = cfg.get("skills", {})
	var cb: Dictionary = sk.get("combo", {})
	var ms: Dictionary = cb.get("milestones", {})
	var ok_combo: bool = is_equal_approx(float(cb.get("timeout", 0.0)), 1.5) and int(cb.get("cycle", 0)) == 20 \
		and ms == {"5": "c5", "10": "c10", "15": "c5", "20": "c20"}
	var want: Dictionary = {"c5": ["c5_double", 0.005, 0.012, 2], "c10": ["c10_burst", 0.01, 0.025, 3], "c20": ["c20_snipe", 0.05, 0.09, 1]}
	for k: String in want:
		var c: Dictionary = cb.get(k, {})
		var w: Array = want[k]
		ok_combo = ok_combo and str(c.get("id", "")) == w[0] and is_equal_approx(float(c.get("fracOut", 0.0)), w[1]) \
			and is_equal_approx(float(c.get("fracIn", 0.0)), w[2]) and (c.get("delays", []) as Array).size() == int(w[3])
	var c20: Dictionary = cb.get("c20", {})
	ok_combo = ok_combo and is_equal_approx(float(c20.get("stun", 0.0)), 0.8) and int(c20.get("pop", 0)) == 1 \
		and is_equal_approx(float((cb.get("c10", {}) as Dictionary).get("delays", [0, 0, 0])[2]), 0.27)
	_check(ok_combo, "skills.combo: timeout 1.5, cycle 20, milestones 5/10/15/20 = c5/c10/c5/c20, c5 0.5/1.2 % ×2, c10 1/2.5 % ×3, c20 5/9 % + pop 1 + stun 0.8")
	var t1: Dictionary = sk.get("t1", {})
	var t3: Dictionary = sk.get("t3", {})
	var lad: Array = sk.get("preLockLadder", [])
	_check(is_equal_approx(float(sk.get("hpMul", 0.0)), 1.7) and lad.size() == 1 and int(lad[0]) == 1
		and is_equal_approx(float(t1.get("reach", 0.0)), 60.0) and int(t1.get("laneRange", 0)) == 99
		and is_equal_approx(float(t1.get("delayPerM", 0.0)), 0.00833) and is_equal_approx(float(t1.get("stunPreLock", 0.0)), 0.4)
		and is_equal_approx(float(t1.get("chase", 0.0)), 0.8) and is_equal_approx(float(t1.get("dmgInFrac", 0.0)), 0.05)
		and is_equal_approx(float(t1.get("dmgOutFrac", 0.0)), 0.04) and is_equal_approx(float(t3.get("dmgInFrac", 0.0)), 0.18)
		and is_equal_approx(float(t3.get("dmgOutFrac", 0.0)), 0.14),
		"skills: hpMul 1.7, preLockLadder [1], t1 reach 60 / laneRange 99 / delayPerM 0.00833 / stunPreLock 0.4 / chase 0.8 / frac 5–4 %, t3 frac 18–14 %")
	_check(is_equal_approx(float(t1.get("hitstop", 0.0)), 0.07) and is_equal_approx(float(t3.get("hitstop", 0.0)), 0.11)
		and is_equal_approx(float(t3.get("slow", 0.0)), 0.4) and is_equal_approx(float(t3.get("slowFor", 0.0)), 0.45),
		"C4 numbers: t1 hitstop 0.07, t3 hitstop 0.11 / slow 0.4 / slowFor 0.45")
	var gw: Dictionary = (cfg.get("boss", {}) as Dictionary).get("genericWindow", {})
	_check(gw.get("on") == true and is_equal_approx(float(gw.get("period", 0.0)), 4.5) and is_equal_approx(float(gw.get("dur", 0.0)), 1.2),
		"boss.genericWindow {on true, period 4.5, dur 1.2}")
	var s3: Dictionary = _DB.find_stage(_DB.load_json("res://data/stages.json"), 3)
	_check(is_equal_approx(float(s3.get("skillHpMul", 1.0)), 0.75), "stages 1-3 (duo) skillHpMul 0.75")
	var fx: Dictionary = sk.get("fx", {})
	var wv: Dictionary = fx.get("t1_wave", {})
	var wnames: Array[String] = []
	for s: Variant in wv.get("sfx", []):
		wnames.append(str((s as Array)[0]))
	var cam: Dictionary = wv.get("camera", {})
	_check(str((fx.get("t1", {}) as Dictionary).get("banner", "")) == "갓길 청소!!" and str(wv.get("banner", "")) == "충격파!!"
		and wnames == ["sk_wave", "superHit", "explosion"] and not wnames.has("hornTruck")
		and is_equal_approx(float(cam.get("punch", 0.0)), -5.0) and is_equal_approx(float(cam.get("kick", 0.0)), 0.6),
		"fx: t1 '갓길 청소!!' (jam horn), t1_wave '충격파!!' sk_wave → superHit → explosion, no hornTruck, punch −5 kick 0.6 (%s)" % str(wnames))
	var c10s: Array[String] = []
	for s: Variant in (fx.get("c10", {}) as Dictionary).get("sfx", []):
		c10s.append("%s@%.2f×%.2f" % [str((s as Array)[0]), float((s as Array)[1]), float((s as Array)[3])])
	var c20s: Array[String] = []
	for s: Variant in (fx.get("c20", {}) as Dictionary).get("sfx", []):
		c20s.append(str((s as Array)[0]))
	var c5n: int = ((fx.get("c5", {}) as Dictionary).get("sfx", []) as Array).size()
	_check(c10s == ["tack@0.15×1.10", "tack@0.21×1.25", "tack@0.27×1.40", "crit@0.27×1.00"] and c20s == ["whoosh", "pop", "crit", "explosion"]
		and c5n == 2 and not (fx.get("c10", {}) as Dictionary).has("camera") and not (fx.get("c5", {}) as Dictionary).has("flash")
		and is_equal_approx(float((fx.get("c20", {}) as Dictionary).get("hitstop", 0.0)), 0.04),
		"fx: c5 2 tack sfx (no camera / flash), c10 %s, c20 %s + hitstop 0.04" % [str(c10s), str(c20s)])
	var t3cam: Dictionary = (fx.get("t3", {}) as Dictionary).get("camera", {})
	_check(is_equal_approx(float(t3cam.get("lift", 0.0)), 0.25) and is_equal_approx(float(t3cam.get("punch", 0.0)), -7.0)
		and is_equal_approx(float(t3cam.get("shake", 0.0)), 0.65), "fx: t3 camera lift 0.25 / punch −7 / shake 0.65")
	var bad: Array[String] = []
	for k: Variant in fx.keys():
		var fl: Variant = (fx[k] as Dictionary).get("flash") if fx[k] is Dictionary else null
		if fl is Array:
			var fa: Array = fl
			var col: String = str(fa[0]).to_lower()
			if float(fa[1]) > 0.45 + 1e-6 or float(fa[2]) > 120.0 + 1e-6 or col == "ffffff" or col == "fff":
				bad.append("%s %s" % [str(k), str(fa)])
	_check(bad.is_empty(), "fx: every flash α ≤ 0.45, ≤ 120 ms, never white (%s)" % str(bad))
