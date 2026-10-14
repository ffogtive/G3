class_name GameSim
extends RefCounted
## The 1-1 game loop (NATIVE_PORT M1b): phase machine intro → jam → boss → kill → release → cruise → result,
## wreck → fail → retry, player + boss + weapons + HP/rage/score on top of TrafficBridge. Fixed tick (Cfg.TICK);
## time scale (hitstop / slow-mo) is applied to the sim dt here, never through Engine.time_scale (3-2).
## Ported from game/js/main.js (enterPhase, setupStage, onPlayerHit, applyDamage, wreck/retry, lock, release).
##
## 가설:
##   ✅ S1: the villain is now driven by BossSim and handed to the traffic core every tick (set_villains), so it
##      paces the jam front and can no longer pass through the player; 1-1 completes end to end (autoplay test).
##   ✅ S2: DESIGN_REVIEW P0 #1 (leash + brake), #2 (lock-on range band + miss events), #5 (jam floor 60, boost =
##      push), #6 (time / min HP / tows across retries), #7 (×boss.vulnMul in the signature window) + R1 + R2.
##
## Interface (sim ↔ view/UI):
##   setup(stage, tables, seed); step(dt); input(cmd, value); state() -> Dictionary; events(); traffic().
##   input: &"lane" ±1, &"honk", &"fire" (bool held), &"rage" [tier 1|3|5], &"brake" (bool held), &"retry", &"continue",
##          &"jump" (legacy jam hop), &"item1" / &"item2" (loadout item slots), &"skip" (tap: skip the t5 / kill cinematic).
##   Contract (docs/SKILLS.md §6, device feedback #3): &"fire" never makes a honk or a skill; only &"honk" honks.
##   events (drained by events()): {type: ...}
##     phase {phase, from} · boss_phase {boss_phase, label} · lock {} · lane {dir, lane} · hit {target_id, dmg, window, immune, kind: tack|bomb|mini, popped, hp_frac, s, x}
##     miss {s, x, reason} · fire {target_id, from_s, from_x, to_s, to_x, dur, lob} · fire_dry {s, x} (압정 in the jam, no
##     target — never a honk) · bomb {target_id, dur}
##     damage {amount, hp, hp_max, reason, cause, floor} · stun {id, dur} · kill {id, finish} · pullover {id, lanes}
##     release {open_lane} · honk {lane} · honk_reply {id, data} (+ the other TrafficBridge events: brake_wave,
##     cutin, mini_act, released, auto_tow) · wreck {reason, fails} · retry {fails, pay_mul}
##     bubble {who: villain|car|player, id, text | table, kind, dur} · attack {kind, id} · bump {rel_v, push, dmg}
##     smash {id} · tow {id} · rage {full} · rage_horn {smashed, towed, cheaters, startled} · gone {id}
##   SKILLS (config.skills, sim/skills_sim.gd, docs/SKILLS.md §6): skill_start {chan, tier, id, target_id, lanes, dur, cine, s, x}
##     · skill_hit {chan, tier, id, target_id, idx, n, dmg, window, immune, stun, popped, killed, hp_frac, s, x [, execute,
##     mini_id, obstacle_id]} · skill_end {chan, tier, id, skipped} · skill_denied {chan, tier, id, reason} · tier_ready
##     {tier, segs} · item_ready {id, slot} · finisher {id, target_id, execute, s, x} (after the last kill) · skip {what}
##     · finish_beat {id, finish, beat} (BossSim timeline beats). With config.skills the fight's &"rage" is the ladder
##     (no bomb event); without it the old rage horn / bomb run.
##   r3 (data/neck.json, sim/neck_sim.gd): checkpoint {i (0-based index into state().checkpoints), ord (1-based), d
##     (threshold m), dist, fast, score, rage, n} · neck_active / neck_chip / neck_yield / neck_block / neck_open / neck_gone
##     (NeckSim) · honk_reply {.., neck: true} for a honk the bottleneck answered (TrafficBridge.honk not called).
##   state(): + "neck" (NeckSim.state) and "checkpoints" [{d, done, fast}].
##   Combat hooks (r3 W; logic in skills_sim.gd / behaviors/generic_window.gd, has_method-guarded here):
##     skills.on_tack_hit(sim, villain, damage_result) after every 압정 hit on a villain (not minis, not bombs);
##     skills.on_player_hit(sim) after a hit that got through invuln and dealt damage; a stage whose sig has no
##     module in BEHAVIORS gets res://sim/behaviors/generic_window.gd (config.boss.genericWindow.on != false).

const _DB := preload("res://core/db.gd")
const CAUSE_TIER: Dictionary = {"lunge": "fatal", "highbeam": "light", "horn": "light", "smoke": "light", "swerve": "heavy", "selfie": "light"}
const BEHAVIORS: Dictionary = {"occupy": preload("res://sim/behaviors/occupy.gd")}
## r3 W/C2: generic signature window for stages whose sig is not ported yet (loaded at runtime, combat group's file).
const GENERIC_WINDOW_PATH: String = "res://sim/behaviors/generic_window.gd"

var stage: Dictionary = {}
var tables: Dictionary = {}
var tune: Dictionary = {}
var bc: Dictionary = {}
var wc: Dictionary = {}
var hpc: Dictionary = {}
var seed: int = 0
var player := PlayerSim.new()
var boss := BossSim.new()
var weapons := WeaponsSim.new()
var skills := SkillsSim.new()
## Progress.loadout() from tables.options.loadout ({} = defaults): finish, items, rage_start_segs.
var loadout: Dictionary = {}
var bridge := TrafficBridge.new()
var autopilot: Autopilot = null
var force_fallback: bool = false
## r3 A2 bottleneck plug + valve, and the A1 pace / A3 checkpoint data (data/neck.json).
var neck := NeckSim.new()

var phase: StringName = &"intro"
var phase_t: float = 0.0
var phase_real: float = 0.0
var time: float = 0.0
var real_time: float = 0.0
var traffic_time: float = 0.0
var hitstop: float = 0.0
var slow_until: float = 0.0
var slow_scale: float = 1.0
var start_s: float = 0.0
var front_s: float = 200.0
var tail_s: float = -45.0
var fight: Dictionary = {}
var front_locked: bool = false
var hp: int = 100
var hp_max: int = 100
var min_hp: int = 100
var rage: float = 0.0
var score: int = 0
var combo: int = 0
var max_combo: int = 0
var bumps: int = 0
var supers: int = 0
var hits: int = 0
var hits_taken: int = 0
var minis_done: int = 0
var minis_total: int = 0
var mini_fines: int = 0
var rage_horns: int = 0
var cheaters: int = 0
var dmg_mul: float = 1.0
var wrecked: bool = false
var fails: int = 0
var pay_retry_mul: float = 1.0
var wreck_snap: Dictionary = {}
var boss_rage: float = 0.0
var stage_clock: float = 0.0
var boss_clock: float = 0.0
var kill_time: float = 0.0
var kill_s: float = 0.0
var release_at: float = 0.0
var last_horn: float = -99.0
var last_damage_reason: String = ""
var stuck_t: float = 0.0
var stuck_hint_until: float = 0.0
var stuck_hinted: bool = false
var display_cars: int = 0
var mult: float = 1.0
var intro_hold: bool = false
var wreck_spin: float = 0.0

var _events: Array[Dictionary] = []
var _in_lane: int = 0
var _in_honk: bool = false
var _in_rage: bool = false
var _in_retry: bool = false
var _in_continue: bool = false
var _in_jump: bool = false
var _in_rage_tier: int = 0
var _in_item: int = 0
var _in_skip: bool = false
var _ts: float = 1.0
var _kill_finish: String = ""
var _fire_held: bool = false
var _fire_prev: bool = false
var _brake_held: bool = false
var _miss_t: float = -99.0
var _dry_t: float = -99.0
var _result: Dictionary = {}
var _lock_target: Dictionary = {}
var _intro_go: bool = true
var _next_front_rage: float = 0.0
var _fx_rng := RandomNumberGenerator.new()
var _leader_cb: Callable
var _shots_total: int = 0
var _night: bool = false
## Jam hop landing (jam_hop): {id: NPC car the hop clears (0 = a fixed s), off: landing s relative to it}.
var _glide: Dictionary = {}
var _car_len: Dictionary = {}
## r3 A3: [{d, done, fast, t}] (per 판: kept across retries), stage_clock of the last one, rage per checkpoint.
var _cps: Array[Dictionary] = []
var _cp_last: float = 0.0
var _cp_rage: float = 0.0
## r3 A1: approach pace multiplier (NeckSim.pace_mul or tables.options.pace) and the front glue on top of it.
var _pace: float = 1.0
var _glue_on: bool = true
var _glue: float = 1.0
var _glue_target: float = 1.0
var _glue_n: int = 0


## stage: stages.json record. tables: DB.traffic_tables() ({config, vehicle_kinds, mini_types, approach});
## {} loads them from res://data. Optional tables.options: {intro_hold: bool (wait for &"continue"), finish: String,
## loadout: Progress.loadout() (finish, items → item1/item2, rage_start_segs)}.
## seed < 0 → the stage's traffic seed (id*1000+7); boss / weapon / cosmetic RNGs derive from it.
func setup(p_stage: Dictionary, p_tables: Dictionary, p_seed: int) -> void:
	stage = p_stage
	tables = p_tables if p_tables.has("config") else _DB.load_traffic_tables()
	if not tables.has("vehicle_kinds") or tables["vehicle_kinds"] == null:
		tables["vehicle_kinds"] = _DB.load_json(_DB.DATA_DIR + "/vehicle_kinds.json")
	if not (tables.get("neck") is Dictionary):
		tables["neck"] = _DB.load_neck()
	var config: Dictionary = tables["config"]
	tune = config.get("tune", {})
	bc = config.get("boss", {})
	wc = config.get("weapons", {})
	hpc = (tune.get("hp", {}) as Dictionary).duplicate(true)
	for k: Variant in (config.get("hp", {}) as Dictionary).keys():
		hpc[k] = config["hp"][k]
	var opts: Dictionary = tables.get("options", {}) if tables.get("options") is Dictionary else {}
	intro_hold = bool(opts.get("intro_hold", false))
	loadout = opts.get("loadout", {}) if opts.get("loadout") is Dictionary else {}
	bc = bc.duplicate()
	if opts.has("finish"):
		bc["finish"] = str(opts["finish"])
	elif str(loadout.get("finish", "")) != "":
		bc["finish"] = str(loadout["finish"])
	var skc: Dictionary = config.get("skills", {}) if config.get("skills") is Dictionary else {}
	if not skc.is_empty():
		bc["hpMul"] = float(skc.get("hpMul", 1.0)) * float(p_stage.get("skillHpMul", 1.0))
		bc["finishTimeline"] = skc.get("finish", {})
		bc["stunCap"] = skc.get("stunCap", 2.0)
		bc["stunImmune"] = skc.get("stunImmune", 1.5)
	skills.setup(skc, tune, loadout)
	seed = p_seed if p_seed >= 0 else Mulberry32.traffic_seed(int(stage.get("id", 1)))
	_fx_rng.seed = seed * 31 + 5
	# r3: options.neck (bool) forces the plug on/off (data default.enabled otherwise); options.pace (float) overrides the
	# approach pace; options.checkpoints == false turns A3 off (baselines in tests).
	neck.setup(tables.get("neck", {}) as Dictionary, stage, seed, opts.get("neck"))
	_pace = float(opts["pace"]) if opts.get("pace") is float or opts.get("pace") is int else neck.pace_mul()
	_glue_on = not (opts.get("pace") is float or opts.get("pace") is int) and opts.get("glue") != false and not neck.glue_cfg().is_empty()
	_leader_cb = _leader
	time = 0.0
	real_time = 0.0
	fails = 0
	pay_retry_mul = 1.0
	wreck_snap = {}
	stage_clock = 0.0
	boss_clock = 0.0
	score = 0
	combo = 0
	max_combo = 0
	bumps = 0
	supers = 0
	hits = 0
	hits_taken = 0
	mini_fines = 0
	rage_horns = 0
	cheaters = 0
	_shots_total = 0
	_night = TrafficBridge.is_night(stage, tables)
	_events.clear()
	_result = {}
	_setup_stage()
	_setup_checkpoints(opts.get("checkpoints") != false)
	rage = minf(1.0, float(int(loadout.get("rage_start_segs", 0))) / float(tune.get("rageSegs", 5)))
	min_hp = hp
	phase = &""
	_enter(&"intro")


func _setup_stage() -> void:
	bridge.setup(stage, tables, seed, force_fallback)
	_car_len = {}
	_glide = {}
	var info: Dictionary = bridge.setup_info()
	start_s = float(info["start_s"])
	front_s = float(info["front_s"])
	tail_s = float(bridge.info().get("s_tail", start_s - 45.0))
	var beh: Object = null
	var sig: String = str(stage.get("sig", "")) if stage.get("sig") != null else ""
	if BEHAVIORS.has(sig):
		beh = (BEHAVIORS[sig] as GDScript).new()
	elif _generic_window_on() and ResourceLoader.exists(GENERIC_WINDOW_PATH):
		var gw: Resource = load(GENERIC_WINDOW_PATH)
		if gw is GDScript and (gw as GDScript).can_instantiate():
			beh = (gw as GDScript).new()
	boss.spawn(stage, info["villains"], beh, seed * 7 + 1, bc)
	boss.set_pace(_pace)  # r3 A1: setup and every retry start before the front lock
	_glue = 1.0
	_glue_target = 1.0
	_glue_n = 0
	neck.reset_attempt()
	fight = {}
	var bf: Variant = beh.get("fight") if beh != null else null
	if bf is Dictionary and not (bf as Dictionary).is_empty():
		fight = bf
	elif stage.get("fight") is Dictionary:
		fight = stage["fight"]
	var kinds: Dictionary = (tables["vehicle_kinds"] as Dictionary).get("kinds", {})
	player.setup(tune, TrafficBridge.kind_dims(kinds.get("player", {}), -1, 0, true))
	player.reset(start_s, int(info["start_lane"]))
	player.shoulder_closed = bool(bridge.info().get("shoulder_closed", false))
	weapons.setup(wc.get("tack", {}), wc.get("bomb", {}), seed * 7 + 2)
	traffic_time = 0.0
	front_locked = false
	wrecked = false
	hp_max = int(hpc.get("max", 100))
	hp = hp_max
	rage = 0.0
	dmg_mul = GameSim.stage_damage_mul(stage)
	kill_s = 0.0
	release_at = 0.0
	stuck_t = 0.0
	stuck_hinted = false
	hitstop = 0.0
	slow_until = 0.0
	minis_done = 0
	display_cars = roundi(float(stage.get("displayKm", 2.4)) * Cfg.NUM_LANES * float(tune.get("jamDensity", 125)))
	mult = float(display_cars) / maxf(1.0, float(bridge.count_npc()))
	var buf := PackedFloat32Array()
	bridge.read_into(buf)
	minis_total = 0
	for k: int in bridge.count_npc():
		if int(buf[k * TrafficBridge.STRIDE + 7]) & TrafficBridge.LAMP_MINI:
			minis_total += 1
	bridge.set_villains(_villain_records())
	skills.reset_run()
	_kill_finish = ""


## r3 A1 front glue: before the lock the villain runs at _pace × glue, glue easing (tau) from 1 down to glue.floor while
## the widest first-bumper gap behind the front row (lanes 0-3) grows from gapIn to gapOut. Packed lanes
## breathe ±2.7 m at the 0.42 rad/s low-frequency wave, so a constant ×0.78 alone left 2.9-8.3 m behind the villain.
## Pure sim side (TrafficBridge.cars_in_lane, both backends), no RNG; sampled every glue.every ticks.
func _update_pace(sdt: float) -> void:
	if not _glue_on or front_locked or not (phase in [&"intro", &"jam", &"boss"]):
		return
	var gc: Dictionary = neck.glue_cfg()
	_glue_n += 1
	if _glue_n % maxi(1, int(gc.get("every", 4))) == 1 or int(gc.get("every", 4)) <= 1:
		var g: float = front_gap_max()
		var gi: float = float(gc.get("gapIn", 3.0))
		var fl: float = float(gc.get("floor", 0.35))
		var k: float = clampf((g - gi) / maxf(0.1, float(gc.get("gapOut", 5.0)) - gi), 0.0, 1.0)
		_glue_target = 1.0 - k * (1.0 - fl)
	_glue += (_glue_target - _glue) * (1.0 - exp(-sdt / maxf(0.01, float(gc.get("tau", 0.4)))))
	boss.set_pace(_pace * _glue)


## r3 A1: the widest gap between the frontmost body and the next one behind it in lanes 0-3 (jamShape spaced / pass
## lanes are spaced by design and left out). All four: lane 3 next to the shoulder is the one the player wants back into. A zig stage keeps every lane's followers
## behind a virtual wall at front_line - villainWall.back - zigExtra (8 m: the weave buffer, both cores), so it has
## nothing to glue: 0. Bodies: NPC cars (cars_in_lane), alive villains, the player. 0 when nothing to measure.
func front_gap_max() -> float:
	if stage.get("zig") == true:
		return 0.0
	var f: float = -INF
	var vl: Dictionary = {}
	for v: Dictionary in boss.alive():
		f = maxf(f, float(v["base_s"]))
		for l: int in BossSim.lanes_of(v):
			vl[l] = true
	if not is_finite(f):
		return 0.0
	var excl: Dictionary = {}
	var shape: Variant = stage.get("jamShape")
	if shape is Dictionary and (shape as Dictionary).get("lanes") is Array:
		var kinds: Array = (shape as Dictionary)["lanes"]
		for l: int in kinds.size():
			if str(kinds[l]) in ["spaced", "pass"]:
				excl[l] = true
	var worst: float = 0.0
	for l: int in Cfg.NUM_LANES:
		if excl.has(l):
			continue
		var b0f: float = -INF
		var b0r: float = -INF
		var b1f: float = -INF
		var bodies: Array = []
		for id: int in bridge.cars_in_lane(l, f - 40.0, f + 8.0):
			var cs: float = float(bridge.car_info(id).get("s", 0.0))
			var hl: float = _car_len_of(id) / 2.0
			bodies.append([cs + hl, cs - hl])
		for v: Dictionary in boss.alive():
			if BossSim.lanes_of(v).has(l):
				bodies.append([float(v["s"]) + float(v["len"]) / 2.0, float(v["s"]) - float(v["len"]) / 2.0])
		if player.occupies(l):
			bodies.append([player.s + player.len / 2.0, player.s - player.len / 2.0])
		for b: Array in bodies:
			if float(b[0]) > b0f:
				b1f = b0f
				b0f = float(b[0])
				b0r = float(b[1])
			elif float(b[0]) > b1f:
				b1f = float(b[0])
		if is_finite(b1f):
			worst = maxf(worst, b0r - b1f)
	return worst


func _car_len_of(id: int) -> float:
	if _car_len.is_empty():
		for sp: Dictionary in bridge.car_specs():
			_car_len[int(sp["id"])] = float(sp["len"])
	return float(_car_len.get(id, 4.4))


## r3 W: config.boss.genericWindow.on != false (missing block = on).
func _generic_window_on() -> bool:
	var gw: Variant = bc.get("genericWindow")
	return not (gw is Dictionary) or (gw as Dictionary).get("on", true) != false


## r3 A3 (neck.json checkpoints): thresholds on d = ref_s - player.s below d0 - minLead; atLong when the jam is ≥ longJam.
func _setup_checkpoints(on: bool) -> void:
	_cps = []
	_cp_last = 0.0
	var cc: Dictionary = neck.cfg.get("checkpoints", {})
	if not on or cc.get("on", true) == false:
		return
	var d0: float = boss.ref_s() - player.s
	var jl: float = float(bridge.setup_info().get("jam_len", stage.get("jamLength", 170.0)))
	var long: bool = jl >= float(cc.get("longJam", 200.0))
	_cp_rage = float(cc.get("rageLong", cc.get("rage", 0.04))) if long else float(cc.get("rage", 0.04))
	for d: Variant in (cc.get("atLong", []) if long else cc.get("at", [])):
		if float(d) < d0 - float(cc.get("minLead", 15.0)):
			_cps.append({"d": float(d), "done": false, "fast": false, "t": -1.0})


## r3 A3: once per 판 each (kept across retries), in order, only in jam-like ticks.
func _tick_checkpoints() -> void:
	if _cps.is_empty():
		return
	var cc: Dictionary = neck.cfg.get("checkpoints", {})
	var d: float = boss.ref_s() - player.s
	for i: int in _cps.size():
		var c: Dictionary = _cps[i]
		if bool(c["done"]) or d >= float(c["d"]):
			continue
		var fast: bool = stage_clock - _cp_last <= float(cc.get("fastWindow", 8.0))
		_cp_last = stage_clock
		c["done"] = true
		c["fast"] = fast
		c["t"] = stage_clock
		var pts: int = roundi(float(cc.get("score", 100)) * float(i + 1) * (float(cc.get("fastMul", 1.5)) if fast else 1.0))
		score += pts
		add_rage(_cp_rage)
		_emit({"type": "checkpoint", "i": i, "ord": i + 1, "d": float(c["d"]), "dist": d, "fast": fast, "score": pts, "rage": _cp_rage,
			"n": _cps.size()})


## main.js stageDamageMul: 1-1~1-3 ×0.5, 1-4~1-6 ×0.8, then ×1.0 → ×1.3 by chapter 10.
static func stage_damage_mul(st: Dictionary) -> float:
	if st.get("dmgMul") != null:
		return float(st["dmgMul"])
	var ch: int = int(st.get("chapter", 1))
	var id: int = int(st.get("id", 1))
	if ch <= 1:
		return 0.5 if id <= 3 else (0.8 if id <= 6 else 1.0)
	return minf(1.3, 1.0 + (ch - 2) * 0.0375)


func input(cmd: StringName, value: Variant = null) -> void:
	match cmd:
		&"lane":
			_in_lane = signi(int(value)) if value != null else 0
		&"honk":
			_in_honk = true
		&"fire":
			_fire_held = true if value == null else bool(value)
		&"rage":
			_in_rage = true
			_in_rage_tier = int(value) if value != null else 0
		&"item1":
			_in_item = 1
		&"item2":
			_in_item = 2
		&"skip":
			_in_skip = true
		&"brake":
			_brake_held = true if value == null else bool(value)
		&"retry":
			_in_retry = true
		&"continue":
			_in_continue = true
		&"jump":
			_in_jump = true


func events() -> Array[Dictionary]:
	var out: Array[Dictionary] = _events
	_events = []
	return out


func traffic() -> TrafficBridge:
	return bridge


func is_jam_like() -> bool:
	return phase == &"jam" or (phase == &"boss" and not front_locked)


func _emit(e: Dictionary) -> void:
	_events.append(e)


func _bubble_player(text: String, kind: String = "warn", dur: float = 1.0) -> void:
	_emit({"type": "bubble", "who": "player", "id": -1, "text": text, "kind": kind, "dur": dur})


func _enter(name: StringName) -> void:
	var from: StringName = phase
	phase = name
	phase_t = 0.0
	phase_real = 0.0
	_emit({"type": "phase", "phase": name, "from": from})
	match name:
		&"intro":
			_intro_go = not intro_hold
		&"jam":
			neck.start(self)
		&"boss":
			boss_rage = rage
			boss.attack_t = float(bc.get("firstAttack", 2.0))
			front_locked = false
		&"wreck":
			slow_until = real_time + float((bc.get("wreck", {}) as Dictionary).get("slowFor", 1.4))
			slow_scale = float((bc.get("wreck", {}) as Dictionary).get("slow", 0.3))
			wreck_spin = 0.0
		&"kill":
			var kc: Dictionary = bc.get("kill", {})
			kill_time = time
			hitstop = float(kc.get("hitstop", 0.16))
			slow_until = real_time + float(kc.get("slowFor", 1.25))
			slow_scale = float(kc.get("slow", 0.28))
			if skills.enabled:  # SKILLS §4: impact hitstop, slow-mo until the finish's settle beat, then normal speed
				var fc: Dictionary = skills.cfg.get("finish", {})
				var tl: Dictionary = fc.get(_kill_finish, {}) if fc.get(_kill_finish) is Dictionary else {}
				hitstop = float(fc.get("hitstop", 0.14))
				slow_until = real_time + maxf(hitstop, float(tl.get("settle", 0.5)))
				slow_scale = float(fc.get("slow", 0.3))
		&"release":
			boss.set_pace(1.0)
			neck.clear()
			_set_extras()
			var ol: int = _open_lane()
			bridge.release(traffic_time, ol)
			player.ghost = true
			_emit({"type": "release", "open_lane": ol})
		&"result":
			_result = _make_result()


func _open_lane() -> int:
	var beh: Object = boss.beh
	if beh != null and "release_open_lane" in beh and int(beh.get("release_open_lane")) >= 0:
		return int(beh.get("release_open_lane"))
	if stage.get("zig") == true:
		return int(stage.get("zigCenter", 1)) if stage.get("zigCenter") != null else 1
	var lo: int = 99
	for sp: Variant in stage.get("villains", []):
		lo = mini(lo, floori(float((sp as Dictionary).get("lane", 0))))
	return 0 if lo == 99 else lo


# --- tick -----------------------------------------------------------------------------------------

func step(dt: float) -> void:
	real_time += dt
	var ts: float = 1.0
	if hitstop > 0.0:
		hitstop -= dt
		ts = 0.0
	elif real_time < slow_until:
		ts = slow_scale
	var sdt: float = dt * ts
	_ts = ts
	skills.time_scale = ts
	time += sdt
	phase_t += sdt
	phase_real += dt
	if phase in [&"jam", &"boss", &"wreck"]:
		stage_clock += sdt
	if phase == &"boss":
		boss_clock += sdt
	if autopilot != null:
		autopilot.drive(self)
	var ph: StringName = phase
	var jam_like: bool = is_jam_like()
	var lane_dir: int = _in_lane
	var want_honk: bool = _in_honk
	var want_rage: bool = _in_rage
	var want_retry: bool = _in_retry
	var want_continue: bool = _in_continue
	var want_jump: bool = _in_jump
	var want_tier: int = _in_rage_tier
	var want_item: int = _in_item
	var want_skip: bool = _in_skip
	var fire_edge: bool = _fire_held and not _fire_prev
	_fire_prev = _fire_held
	_in_lane = 0
	_in_honk = false
	_in_rage = false
	_in_retry = false
	_in_continue = false
	_in_jump = false
	_in_rage_tier = 0
	_in_item = 0
	_in_skip = false

	if ph == &"fail":
		if want_retry or want_continue:
			_retry()
		return
	if ph == &"intro" and want_continue:
		_intro_go = true
		phase_real = maxf(phase_real, float(bc.get("introTime", 2.05)) + 1.0)
	if ph == &"result" and want_continue:
		_result["acknowledged"] = true

	var mini_id: int = bridge.mini_target() if jam_like else 0
	var boss_behind: Dictionary = _target() if ph == &"boss" and not front_locked else {}
	# Device feedback 2026-10-14 #3 ("압정버튼을 눌렀는데 경적이 됨"): a 압정 press in the jam without a mini target
	# used to honk (web main.js:1055 wantHorn parity). 압정 is never the horn now; an idle press gets a dry feedback.
	if ph == &"jam" and fire_edge and mini_id == 0 and real_time - _dry_t > 0.35:
		_dry_t = real_time
		_emit({"type": "fire_dry", "s": player.s, "x": player.x})

	if ph in [&"jam", &"boss", &"cruise"] and lane_dir != 0:
		sync_traffic_player()
		var out: Dictionary = {}
		var r: String = ""
		var tl: int = player.lane + lane_dir
		# r3 A2: the plug is a lane blocker on both backends even without TrafficBridge.set_extras
		if not player.ghost and tl >= 0 and tl <= Cfg.SHOULDER_LANE and player.lc_t >= 0.65 \
				and neck.blocks(tl, player.s - player.len / 2.0 - 0.35, player.s + player.len / 2.0 + 0.35):
			player._wiggle(lane_dir)
			r = "blocked"
			out["blocker"] = NeckSim.PLUG_ID
		else:
			r = player.request_lane(lane_dir, bridge, out)
		if r == "ok":
			_emit({"type": "lane", "dir": lane_dir, "lane": player.lane})
		elif r == "closed":
			_bubble_player("갓길 폐쇄!", "warn", 1.2)
		elif r == "blocked" and int(out.get("blocker", 0)) > 0:
			_emit({"type": "bubble", "who": "car", "id": int(out["blocker"]), "table": "blocked", "text": "어딜 끼어들어!", "kind": "angry", "dur": 1.1})
		elif r == "blocked" and int(out.get("blocker", 0)) == NeckSim.PLUG_ID:
			neck.say(self, "noway", "warn", 1.0)

	if want_honk and real_time - last_horn > float(tune.get("honkCool", 1.0)) and ph in [&"jam", &"boss"]:
		last_horn = real_time
		_emit({"type": "honk", "lane": player.lane})
		if jam_like and neck.is_active(self):
			sync_traffic_player()
			neck.on_honk(self)  # r3 A2: the bottleneck answers; TrafficBridge.honk is not called
		elif jam_like:
			sync_traffic_player()
			var hr: Dictionary = bridge.honk(player.lane, player.s)
			match str(hr.get("kind", "")):
				"cheater":
					score += 300
					cheaters += 1
				"noway":
					add_rage(float(tune.get("nowayRage", 0.015)))
		elif boss.any_alive() and _fx_rng.randf() < 0.7:
			var lines: Array[String] = ["왜 빵빵거려?", "빵빵해도 안 비켜~", "내 차선인데?"]
			_emit({"type": "bubble", "who": "villain", "id": int(boss.alive()[0]["index"]), "text": lines[_fx_rng.randi_range(0, 2)], "kind": "taunt", "dur": 1.6})

	if want_jump and jam_like and jam_hop(0.75) == "":
		_emit({"type": "bubble", "who": "player", "id": -1, "text": "참교육 점프!", "kind": "score", "dur": 1.0})
	if want_skip and skills.enabled:
		skills.skip(self)
	if want_rage:
		if skills.enabled:
			skills.rage(self, want_tier)
		elif jam_like:
			_rage_horn()
		elif ph == &"boss":
			_bomb()
	if want_item != 0 and skills.enabled:
		skills.item(self, want_item)
	if jam_like and _fire_held and mini_id != 0 and boss_behind.is_empty() and weapons.cool <= 0.0:
		var ci: Dictionary = bridge.car_info(mini_id)
		if not ci.is_empty():
			weapons.cool = 1.0 / weapons.rate
			_emit(weapons.fire_at(player, {"mini_id": mini_id, "s": ci["s"], "x": ci["x"], "v": ci["v"], "len": 4.4, "w": 1.9}))

	# player
	var pmode: StringName = &"idle"
	var cruise_v: float = 0.0
	var rc: Dictionary = bc.get("release", {})
	match ph:
		&"jam":
			pmode = &"jam"
		&"boss":
			pmode = &"boss" if front_locked else &"jam"
		&"kill":
			cruise_v = boss.ref_v()
		&"release":
			pmode = &"cruise"
			cruise_v = float(rc.get("cruiseV", 27.0)) if phase_t > float(rc.get("cruiseAfter", 0.8)) else boss.ref_v()
		&"cruise":
			pmode = &"cruise"
			cruise_v = float(tune.get("cruiseSpeed", 30.5))
		&"result":
			pmode = &"cruise"
			cruise_v = maxf(0.0, 22.0 - phase_real * 6.0)
	var pctx: Dictionary = {"mode": pmode, "brake": _brake_held, "cruise_v": cruise_v,
		"boss_ref_s": boss.ref_s(), "boss_ref_v": boss.ref_v(), "fight_gap": float(fight.get("gap", bc.get("fightGap", 11.0))),
		"leash_v": leash_v(), "leader": _leader_cb}
	if player.glide and player.jump_t > 0.0:
		pctx["glide_to"] = _glide_to()
	var pev: Array[Dictionary] = player.update(sdt, pctx)
	for e: Dictionary in pev:
		_on_player_event(e)
	player.boost_t = maxf(0.0, player.boost_t - sdt)

	# traffic (r3 A1: approach pace + front glue; A2: the plug moves with the villain and goes to both cores as an extra body)
	_update_pace(sdt)
	neck.tick(self, sdt)
	_set_extras()
	bridge.set_villains(_villain_records())
	bridge.set_phase(str(ph), ph == &"jam", jam_like, kill_s if ph == &"release" else NAN)
	traffic_time += sdt
	bridge.step(sdt, _traffic_player())
	for e: Dictionary in bridge.events():
		_on_traffic_event(e, ph)
		_emit(e)

	# boss
	var bev: Array[Dictionary] = boss.update(sdt, {"time": time, "phase": ph, "player": player,
		"player_behind": ph == &"boss" and not front_locked, "lane_free": _lane_free, "traffic": bridge,
		"night": _night, "real_dt": dt})
	for e: Dictionary in bev:
		match str(e["type"]):
			"player_hit":
				_on_player_hit(e)
			"dodge":
				skills.on_dodge(self)
				_emit(e)
			"boss_phase":
				_heal(int(hpc.get("healPhase", 10)), "숨 돌리기 +")
				hitstop = maxf(hitstop, 0.12)
				_emit(e)
			"gone":
				_emit(e)
				if bool(e["is_last"]):
					var rd: float = float((bc.get("kill", {}) as Dictionary).get("releaseDelay", 0.95))
					if skills.enabled:
						rd = float((skills.cfg.get("finish", {}) as Dictionary).get("releaseDelay", rd))
					release_at = real_time + rd
			"bubble":
				if bool(e.get("taunt", false)) and ph in [&"jam", &"boss"]:
					var tv: Dictionary = boss.villains[int(e["id"])]
					if absf(float(tv["s"]) - player.s) < 70.0:
						add_rage(float(tune.get("tauntRage", 0.015)))
				_emit(e)
			_:
				_emit(e)

	# skills: queued hits (sim time), cast timers, cooldowns, tier / item ready edges
	skills.tick(self, sdt, dt)

	# weapons
	_lock_target = _target() if ph == &"boss" else {}
	if ph == &"boss" and boss.any_alive() and stage.get("honkOnly") != true and _fire_held and weapons.cool <= 0.0:
		weapons.cool = 1.0 / weapons.rate
		_emit(weapons.fire_at(player, _lock_target))
	for ld: Dictionary in weapons.update(sdt, boss.villains):
		_on_landing(ld)

	if jam_like and not stuck_hinted:
		stuck_t = stuck_t + sdt if player.v < 2.0 else 0.0
		if stuck_t > float(bc.get("stuckHint", 2.2)):
			stuck_hinted = true
			stuck_hint_until = real_time + 2.8
	if jam_like:
		add_rage((float(tune.get("baseRage", 0.005)) + (float(tune.get("timeRage", 0.016)) if player.v < 5.0 else 0.0)) * sdt)
		_tick_checkpoints()

	if ph == &"wreck":
		var fa: float = float((bc.get("wreck", {}) as Dictionary).get("failAfter", 1.6))
		wreck_spin += sdt * 7.0 * maxf(0.0, 1.0 - phase_real / fa)
		if phase_real > fa:
			_enter(&"fail")

	# progression
	if ph == &"jam" and player.s > boss.ref_s() - float(bc.get("discoverDist", 35.0)):
		_enter(&"boss")
	elif ph == &"boss" and not front_locked and _can_lock():
		front_locked = true
		boss.set_pace(1.0)  # r3 A1: the fight runs at the phase's own speed
		neck.on_lock(self)
		if boss.beh != null and boss.beh.has_method(&"on_lock"):
			boss.beh.call(&"on_lock", boss)
		_emit({"type": "lock"})
		skills.on_lock(self)
	elif ph == &"release":
		var wave_done: bool = phase_t > (front_s - tail_s) / float(tune.get("releaseWaveSpeed", 70.0)) + float(rc.get("waveExtra", 1.4))
		if wave_done and phase_t > float(rc.get("minTime", 4.2)):
			_enter(&"cruise")
	elif ph == &"cruise" and phase_t > float(tune.get("cruiseTime", 4.2)):
		_enter(&"result")
	elif ph == &"kill" and release_at > 0.0 and real_time > release_at:
		release_at = 0.0
		_enter(&"release")
	elif ph == &"intro" and _intro_go and phase_real > float(bc.get("introTime", 2.05)):
		_enter(&"jam")

	if ph in [&"intro", &"jam", &"boss"] and real_time > _next_front_rage:
		_next_front_rage = real_time + 1.1 + _fx_rng.randf() * 0.9
		var cs: PackedInt32Array = bridge.cars_behind_front(8, 30.0)
		if not cs.is_empty():
			_emit({"type": "bubble", "who": "car", "id": cs[_fx_rng.randi_range(0, cs.size() - 1)], "table": "frontRage", "text": "",
				"kind": "angry", "dur": 1.5})


## P0#1: before the front lock the player's jam-mode speed is capped once it is ahead of the villain.
## r3 A2: also capped on the way in to the plug (v ≤ plug v + sqrt(2·9·(gap - 1))): PlayerSim's jam auto-brake nets
## ~13 m/s² (accel and brake in one tick), so at 18 m/s it rammed a crawling plug every time.
func leash_v() -> float:
	var cap: float = INF
	var P: Dictionary = neck.leader_for(player) if phase in [&"jam", &"boss"] else {}
	if not P.is_empty():
		cap = float(P["v"]) + sqrt(2.0 * 9.0 * maxf(0.0, float(P["gap"]) - 1.0))
	if phase != &"boss" or front_locked:
		return cap
	var ahead: float = player.s - boss.ref_s()
	if ahead <= 0.0:
		return cap
	var lc: Dictionary = bc.get("leash", {})
	var far: float = float(lc.get("far", 14.0))
	return minf(cap, boss.ref_v() + float(lc.get("dv", 4.0)) * clampf((far - ahead) / far, 0.0, 1.0))


func _can_lock() -> bool:
	if player.s <= boss.ref_s() + float(fight.get("lockAt", bc.get("lockAt", 2.5))):
		return false
	var same: bool = bool(fight.get("sameLane", false))
	var ok: bool = not same
	for v: Dictionary in boss.alive():
		var has: bool = BossSim.lanes_of(v).has(player.lane)
		if same and has:
			ok = true
		elif not same and has:
			ok = false
	if boss.beh != null and boss.beh.has_method(&"can_lock") and not bool(boss.beh.call(&"can_lock", boss, player)):
		return false
	return ok


func _target() -> Dictionary:
	var tc: Dictionary = wc.get("tack", {})
	return boss.target_for(player, int(tc.get("laneRange", 1)), float(tc.get("behindRange", 42.0)))


func _lane_free(lane: int) -> bool:
	var fr: Variant = stage.get("frontRow")
	if not (fr is Array) or lane < 0 or lane >= (fr as Array).size():
		return true
	return (fr as Array)[lane] == null


func _villain_records() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for v: Dictionary in boss.villains:
		out.append({"s": v["s"], "baseS": v["base_s"], "x": v["x"], "w": v["w"], "len": v["len"], "v": v["v"],
			"vNominal": boss.nominal(v), "alive": v["alive"], "kind": v["kind"], "lane": v["lane_pos"]})
	return out


## Jam hop (legacy &"jump" and the mv_jump item before the lock). Device feedback 2026-10-14 #1 / rvA: the old hop
## dropped every leader for 0.75 s at >= 10 m/s, so from behind the villain it flew through the villain, and on the
## fallback it landed inside the next car and snapped back ~8 m into the car it had just cleared. Now the landing slot
## is picked here: walk the bodies ahead in the player's lane (NPC cars, shoulder obstacles, villains), clear at least
## one, and land in the first gap that fits the car (len + jamSlotPad) within jamReach m. A villain ends the walk: it
## is never hopped. "" = hop started; "blocked" = a villain is in the way; "room" = no slot in reach. Nothing to clear
## (open road) = a plain hop in place, collisions on.
func jam_hop(hop_s: float) -> String:
	if player.jump_t > 0.0:
		return "busy"
	var ic: Dictionary = ((skills.cfg.get("items", {}) as Dictionary).get("mv_jump", {}) as Dictionary) if skills != null else {}
	var reach: float = float(ic.get("jamReach", 19.0))
	var need: float = player.len + float(ic.get("jamSlotPad", 0.7))
	var min_slot: float = float(ic.get("jamMinSlot", 2.0)) if bridge.makes_room() else need
	var p_front: float = player.s + player.len / 2.0
	var ahead: Array = []
	for b: Array in _lane_bodies(player.lane, player.s - player.len, player.s + reach + 15.0):
		if float(b[1]) > p_front + 0.01:
			ahead.append(b)
	if ahead.is_empty() or float(ahead[0][0]) - p_front >= need:
		return _plain_hop(hop_s)
	if str(ahead[0][2]) in ["villain", "plug"]:
		return "blocked"
	var cur: float = p_front
	var land: Array = []  # [front of the cleared run, the body it is measured from]
	var why: String = "room"
	for k: int in ahead.size():
		var b: Array = ahead[k]
		cur = maxf(cur, float(b[1]))
		if cur + 0.45 + player.len / 2.0 - player.s > reach:
			break
		var nxt: Array = ahead[k + 1] if k + 1 < ahead.size() else []
		var gap: float = float(nxt[0]) - cur if not nxt.is_empty() else INF
		if gap >= need:
			land = [cur, b]
			break
		if gap >= min_slot and land.is_empty():
			land = [cur, b]
		if not nxt.is_empty() and str(nxt[2]) in ["villain", "plug"]:
			why = "blocked"
			break
	if land.is_empty():
		return why
	var over: Array = land[1]
	var to: float = float(land[0]) + 0.45 + player.len / 2.0
	var oid: int = int(over[3]) if str(over[2]) == "car" else 0
	_glide = {"id": oid, "off": to - (float(over[4]) if oid != 0 else 0.0)}
	player.jump(hop_s, 0.0, false, true)
	return ""


func _plain_hop(hop_s: float) -> String:
	_glide = {}
	player.jump(hop_s, 0.0, false, false)
	return ""


func _glide_to() -> float:
	var oid: int = int(_glide.get("id", 0))
	if oid != 0:
		var ci: Dictionary = bridge.car_info(oid)
		if not ci.is_empty():
			return float(ci["s"]) + float(_glide["off"])
		_glide = {"id": 0, "off": player.glide_from + 6.0}
	return float(_glide.get("off", player.s))


## [rear, front, type car|obstacle|villain|plug, id, s] in a lane with s in (s_min, s_max), sorted by rear. The r3 plug is
## never hopped (like a villain).
func _lane_bodies(lane: int, s_min: float, s_max: float) -> Array:
	if _car_len.is_empty():
		for sp: Dictionary in bridge.car_specs():
			_car_len[int(sp["id"])] = float(sp["len"])
	var out: Array = []
	for id: int in bridge.cars_in_lane(lane, s_min, s_max):
		var cs: float = float(bridge.car_info(id).get("s", 0.0))
		var hl: float = float(_car_len.get(id, 4.4)) / 2.0
		out.append([cs - hl, cs + hl, "car", id, cs])
	if lane == Cfg.SHOULDER_LANE:
		for o: Variant in bridge.obstacles():
			var od: Dictionary = o
			var os: float = float(od["s"])
			if os > s_min and os < s_max:
				out.append([os - float(od["len"]) / 2.0, os + float(od["len"]) / 2.0, "obstacle", int(od["id"]), os])
	for v: Dictionary in boss.villains:
		if (bool(v["alive"]) or bool(v["dying"])) and not bool(v.get("gone", false)) and boss.player_in_lanes(player, BossSim.lanes_of(v)):
			var vs: float = float(v["s"])
			out.append([vs - float(v["len"]) / 2.0, vs + float(v["len"]) / 2.0, "villain", int(v["index"]), vs])
	if neck.occupies(lane) and float(neck.plug["s"]) > s_min and float(neck.plug["s"]) < s_max:
		out.append([neck.rear(), neck.front(), "plug", NeckSim.PLUG_ID, float(neck.plug["s"])])
	out.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	return out


## Pushes the current player record to the traffic core (lane-change checks, leader queries, autopilot).
func sync_traffic_player() -> void:
	bridge.sync_player(_traffic_player())


## player.traffic_state + r3 A2: mode "neck" while the bottleneck is on, so neither core runs its stuck assist (C++
## mode_jam / fallback _player.mode == "jam").
func _traffic_player() -> Dictionary:
	var ps: Dictionary = player.traffic_state(traffic_time)
	if neck.is_active(self):
		ps["mode"] = "neck"
	return ps


var _extras_n: int = 0


## r3 A2: hands the plug to the traffic core (TrafficBridge.set_extras, T1; guarded so this runs without it).
func _set_extras() -> void:
	var ex: Array[Dictionary] = neck.extras()
	if (ex.is_empty() and _extras_n == 0) or not bridge.has_method(&"set_extras"):
		return
	bridge.call(&"set_extras", ex)
	_extras_n = ex.size()


func _leader() -> Dictionary:
	sync_traffic_player()
	var L: Dictionary = bridge.leader_of_player()
	if str(L["type"]) == "villain":
		for v: Dictionary in boss.villains:
			if bool(v["alive"]) or bool(v["dying"]):
				if boss.player_in_lanes(player, BossSim.lanes_of(v)) and float(v["s"]) > player.s:
					L["v"] = float(v["v"])
					break
	# r3 A2: the plug leads on both backends (with or without the bridge's extras), whichever is nearer
	var P: Dictionary = neck.leader_for(player)
	if not P.is_empty() and (not PlayerSim.has_leader(L) or float(P["gap"]) <= float(L["gap"]) + 0.01):
		return P
	return L


func _on_player_event(e: Dictionary) -> void:
	match str(e["type"]):
		"bump":
			var push: bool = bool(e.get("push", false)) and bool(hpc.get("boostPush", true))
			var dmg: int = 0
			if not push and float(e.get("rel_v", 0.0)) >= float(hpc.get("bumpRelV", 6.0)):
				var ob: bool = str(e.get("type_of", "")) == "obstacle"
				dmg = apply_damage(float(hpc.get("obstacleDmg" if ob else "bumpDmg", 10)), "갓길 고장차 충돌" if ob else "고속 추돌", "bump")
			bumps += 1
			combo = 0
			add_rage(float(tune.get("bumpRage", 0.06)))
			if int(e.get("id", 0)) > 0:
				bridge.jolt(int(e["id"]))
			_emit({"type": "bump", "id": int(e.get("id", 0)), "rel_v": float(e.get("rel_v", 0.0)), "push": push, "dmg": dmg})
		"smash":
			var kind: String = ""
			for o: Variant in bridge.obstacles():
				if int((o as Dictionary)["id"]) == int(e["id"]):
					kind = str((o as Dictionary).get("kind", ""))
			if bridge.smash(int(e["id"])):
				if kind == "cones" and player.boost_t <= 0.0:
					apply_damage(float(hpc.get("coneDmg", 5)), "공사 콘", "cone")
				score += 50
				add_rage(float(tune.get("smashRage", 0.012)))
				_emit({"type": "smash", "id": int(e["id"])})
		"tow":
			bridge.remove_obstacle(int(e["id"]))
			_emit({"type": "tow", "id": int(e["id"])})


## traffic.onMiniAct / onCheater (main.js): mini villains throw at the player's lane or cut in (rage), shoulder
## cheaters cut in (rage). Lines come from mini_types.json in the bubble.
func _on_traffic_event(e: Dictionary, ph: StringName) -> void:
	match str(e.get("type", "")):
		"mini_act":
			if not (ph in [&"jam", &"boss"]):
				return
			var T: Dictionary = {}
			for t: Variant in ((tables.get("mini_types", {}) as Dictionary).get("types", []) as Array):
				if str((t as Dictionary).get("id", "")) == str(e.get("data", "")):
					T = t
			var lines: Array = T.get("lines", [])
			if not lines.is_empty():
				_emit({"type": "bubble", "who": "car", "id": int(e["id"]), "text": str(lines[_fx_rng.randi_range(0, lines.size() - 1)]),
					"kind": "taunt", "dur": 1.4})
			var ci: Dictionary = bridge.car_info(int(e["id"]))
			if T.get("item") != null and not ci.is_empty():
				boss.throw_from(float(ci["s"]), float(ci["x"]), player.lane, player, str(T["item"]))
			else:
				add_rage(float(tune.get("cutinRage", 0.05)))
		"cutin":
			if ph == &"jam" and str(e.get("data", "")) == "cheater":
				add_rage(float(tune.get("cutinRage", 0.05)))
				_emit({"type": "bubble", "who": "car", "id": int(e["id"]), "text": "갓길 얌체 끼어들기!", "kind": "angry", "dur": 1.6})


func _on_player_hit(e: Dictionary) -> void:
	if player.invuln > 0.0:
		return
	hits_taken += 1
	var mini: bool = bool(e.get("mini", false))
	var tiers: Dictionary = hpc.get("tier", {})
	var tier: String = str(e.get("tier", CAUSE_TIER.get(str(e.get("cause", "")), "mid")))
	var raw: float = float(hpc.get("miniDmg", 5)) if mini else float(e.get("dmg", tiers.get(tier, 20)))
	# r3 W: the hit got through invuln and deals damage (apply_damage's own gate; the jam floor may still clamp it)
	var landed: bool = phase in [&"jam", &"boss"] and not wrecked and roundi(raw * dmg_mul) > 0
	apply_damage(raw, str(e.get("text", "피격")), str(e.get("cause", "")))
	if landed and skills.has_method(&"on_player_hit"):
		skills.call(&"on_player_hit", self)
	if wrecked:
		return
	_emit({"type": "bubble", "who": "player", "id": -1, "text": str(e.get("text", "으악!")), "kind": "bump", "dur": 1.0, "flash": bool(e.get("flash", false))})
	if mini or not front_locked:
		player.invuln = float(hpc.get("invuln", 1.0))
		player.bump_kick = 1.0
		player.v *= 0.5
		combo = 0
		add_rage(float(tune.get("miniRage", 0.04)))
		return
	player.knock(-float(e.get("push", 2.5)), 1.0)
	player.v = boss.ref_v() + 5.0
	combo = 0
	add_rage(float(tune.get("hitRage", 0.08)))
	score = maxi(0, score - 50)


## main.js applyDamage with P0#5's jam floor (config.hp.jamFloor). Returns the HP actually lost.
func apply_damage(raw: float, reason: String, cause: String = "") -> int:
	if not (phase in [&"jam", &"boss"]) or wrecked:
		return 0
	var dmg: int = roundi(raw * dmg_mul)
	if dmg <= 0:
		return 0
	var nhp: int = hp - dmg
	var floored: bool = false
	if is_jam_like():
		var f: int = mini(hp, int(hpc.get("jamFloor", 60)))
		if nhp < f:
			nhp = f
			floored = true
	var lost: int = hp - maxi(0, nhp)
	hp = maxi(0, nhp)
	min_hp = mini(min_hp, hp)
	last_damage_reason = reason
	_emit({"type": "damage", "amount": lost, "raw": dmg, "hp": hp, "hp_max": hp_max, "reason": reason, "cause": cause, "floor": floored})
	if hp <= 0:
		_wreck(reason)
	return lost


func _heal(n: int, label: String) -> void:
	if hp >= hp_max or wrecked:
		return
	hp = mini(hp_max, hp + n)
	_emit({"type": "bubble", "who": "player", "id": -1, "text": "%s%d" % [label, n], "kind": "score", "dur": 1.0})


func add_rage(a: float) -> void:
	if hp <= 0.2 * hp_max:
		a *= 2.0
	var before: float = rage
	rage = minf(1.0, rage + a)
	var segs: float = float(tune.get("rageSegs", 5))
	if floori(rage * segs + 1e-6) > floori(before * segs + 1e-6):
		_emit({"type": "rage", "full": rage >= 0.999, "rage": rage})


func _rage_horn() -> void:
	var cost: float = float(tune.get("superCost", 0.2))
	if rage < cost - 1e-6:
		_bubble_player("분노 부족!")
		return
	rage = maxf(0.0, rage - cost)
	_rage_horn_effect(float(tune.get("boostTime", 2.2)))


## The jam rage horn's effect (legacy &"rage" and SKILLS t1_horn): clear the shoulder ahead (smash / tow / cheaters back
## in line, startled cars; the GDScript fallback does it too) + boost.
func _rage_horn_effect(boost: float) -> void:
	rage_horns += 1
	sync_traffic_player()
	var rng_m: float = float(bridge.info().get("rage_horn", tune.get("rageHornRange", 48.0)))
	var r: Dictionary = bridge.rage_horn(rng_m)
	var ch: int = (r.get("cheaters", PackedInt32Array()) as PackedInt32Array).size()
	cheaters += ch
	score += 300 * ch
	player.boost_t = boost
	_emit({"type": "rage_horn", "smashed": r.get("smashed"), "towed": r.get("towed"), "cheaters": r.get("cheaters"), "startled": r.get("startled")})
	neck.open(self, "rage")  # r3 A2/W: rage t1 blows the plug away (exit fly; verb bonus only on the deaf valve)


func _bomb() -> void:
	var cost: float = float(tune.get("superCost", 0.2))
	if not front_locked or not boss.any_alive():
		return
	if rage < cost - 1e-6:
		_bubble_player("분노 부족!")
		return
	var best: Dictionary = {}
	for v: Dictionary in boss.alive():
		if best.is_empty() or absf(float(v["x"]) - player.x) < absf(float(best["x"]) - player.x):
			best = v
	var e: Dictionary = weapons.fire_missile(player, best)
	if not e.is_empty():
		rage = maxf(0.0, rage - cost)
		supers += 1
		_emit(e)


func _on_landing(ld: Dictionary) -> void:
	if str(ld["kind"]) == "tack" and int(ld["mini_id"]) != 0:
		var ci: Dictionary = bridge.car_info(int(ld["mini_id"]))
		if ci.is_empty() or absf(float(ci["x"]) - float(ld["x"])) > 1.9:
			return
		var r: String = bridge.mini_hit(int(ld["mini_id"]), float((wc.get("tack", {}) as Dictionary).get("dmg", 1)) * float(bc.get("vulnMul", 4)))
		if r == "":
			return
		_mini_result(int(ld["mini_id"]), r, float(ld["s"]), float(ld["x"]))
		return
	if not bool(ld["hit"]):
		if str(ld["kind"]) == "tack" and phase == &"boss" and boss.any_alive() and real_time - _miss_t > float((wc.get("tack", {}) as Dictionary).get("missEvery", 0.4)):
			_miss_t = real_time
			_emit({"type": "miss", "s": ld["s"], "x": ld["x"], "reason": "lane" if front_locked else "far"})
		return
	var v: Dictionary = boss.villains[int(ld["vi"])]
	var tc: Dictionary = wc.get("tack", {})
	var bm: Dictionary = wc.get("bomb", {})
	var vm: float = float(bc.get("vulnMul", 4.0))
	var bomb: bool = str(ld["kind"]) == "bomb"
	var d_out: float = float(bm.get("dmgOut", 8)) if bomb else float(tc.get("dmg", 1))
	var d_in: float = float(bm.get("dmg", 28)) if bomb else float(tc.get("dmg", 1)) * vm
	var r2: Dictionary = boss.damage(v, d_out, d_in, bool(ld["from_rear"]))
	hits += 1
	combo += 1
	max_combo = maxi(max_combo, combo)
	score += roundi(float(r2["dmg"]) * 10.0 * (1.0 + combo * 0.05))
	_emit({"type": "hit", "target_id": int(v["index"]), "dmg": r2["dmg"], "window": r2["window"], "immune": r2["immune"],
		"kind": "bomb" if bomb else "tack", "popped": r2["popped"], "hp_frac": boss.hp_frac(), "s": ld["s"], "x": ld["x"]})
	if bomb and not bool(r2["window"]):
		_bubble_player("지금 아냐!", "warn", 1.0)
	if bool(r2["window"]) and not bomb:
		skills.on_window_hit(self)
	if not bomb and skills.has_method(&"on_tack_hit"):  # r3 W: combo counter (skills_sim.gd); minis returned above
		skills.call(&"on_tack_hit", self, v, r2)
	if bool(r2["killed"]):
		_villain_killed(v, false)


## A mini villain hit by a tack or caught by the drone: "hit" {kind: mini}, and on "down" the catch reward.
func _mini_result(mini_id: int, r: String, s: float, x: float) -> void:
	combo += 1
	max_combo = maxi(max_combo, combo)
	_emit({"type": "hit", "target_id": -1, "mini_id": mini_id, "kind": "mini", "dmg": 4.0, "window": false, "popped": 0,
		"s": s, "x": x, "down": r == "down"})
	if r == "down":
		minis_done += 1
		score += 400
		_heal(int(hpc.get("healMini", 10)), "정비 쿠폰 +")


## Kill path for tacks, the legacy bomb and skills: start_death → kill (+ pullover walls); the last one → finisher
## (SKILLS) → kill phase. execute: the t5 execution did it.
func _villain_killed(v: Dictionary, execute: bool) -> void:
	var is_last: bool = not boss.any_alive()
	var lanes: PackedInt32Array = boss.start_death(v, is_last)
	_emit({"type": "kill", "id": int(v["index"]), "finish": str(v["finish"]), "last": is_last, "s": v["s"], "x": v["x"]})
	if not lanes.is_empty():
		bridge.drop_walls(lanes, 9.0)
		_emit({"type": "pullover", "id": int(v["index"]), "lanes": lanes})
	if is_last:
		kill_s = float(v["s"])
		_kill_finish = str(v["finish"])
		if skills.enabled:
			_emit({"type": "finisher", "id": _kill_finish, "target_id": int(v["index"]), "execute": execute, "s": v["s"], "x": v["x"]})
			skills.end_all(self)
		_enter(&"kill")


func _wreck(reason: String) -> void:
	if wrecked:
		return
	wrecked = true
	fails += 1
	wreck_snap = {"boss": boss.snapshot(), "rage": boss_rage, "locked": front_locked}
	_emit({"type": "wreck", "reason": reason, "fails": fails})
	_enter(&"wreck")


## R1 + P0#6: re-spawn the jam, restore the whole phase-applied boss state, put the player on the shoulder 33 m
## behind the villain. Stage clock, min HP, tows and counters carry over (honest result card).
func _retry() -> void:
	var snap: Dictionary = wreck_snap
	_shots_total += weapons.shots
	_setup_stage()
	var rt: Dictionary = bc.get("retry", {})
	pay_retry_mul = maxf(float(hpc.get("retryPayMin", 0.6)), 1.0 - float(hpc.get("retryPayStep", 0.2)) * fails)
	if not snap.is_empty():
		boss.restore(snap["boss"])
		rage = float(snap.get("rage", 0.0))
		bridge.set_villains(_villain_records())
	var s: float = boss.ref_s() - float(rt.get("back", 33.0))
	for o: Variant in bridge.obstacles():
		var od: Dictionary = o
		if absf(float(od["s"]) - s) < float(od["len"]) / 2.0 + float(rt.get("obstaclePad", 4.0)):
			s = float(od["s"]) - float(od["len"]) / 2.0 - 5.0
	player.s = s
	player.lane = Cfg.SHOULDER_LANE
	player.x = Cfg.lane_x(Cfg.SHOULDER_LANE)
	player.lc_from = player.x
	player.lc_t = 1.0
	player.v = float(rt.get("v", 10.0))
	sync_traffic_player()
	_emit({"type": "retry", "fails": fails, "pay_mul": pay_retry_mul})
	_enter(&"jam")


# --- read side --------------------------------------------------------------------------------------

func hint() -> String:
	match phase:
		&"jam":
			if real_time < stuck_hint_until:
				return "경적 → 4차로가 양보" if player.lane == Cfg.SHOULDER_LANE else "갓길로 빠져라 ▶"
			if phase_real < float(bc.get("hintJam", 3.4)):
				return "갓길로 ▶ 원인 찾기"
		&"boss":
			if not front_locked:
				var ahead: float = player.s - boss.ref_s()
				var same: bool = bool(fight.get("sameLane", false))
				if ahead > float((bc.get("leash", {}) as Dictionary).get("passedHint", 15.0)) - 3.0:
					return ("지나쳤다! ◀ %d차로" % (int(boss.alive()[0]["home_lane"]) + 1)) if same and boss.any_alive() else "지나쳤다! ↓ 브레이크"
				if ahead > float(fight.get("lockAt", bc.get("lockAt", 2.5))):
					return "원흉 차로로 ◀" if same else "옆 차로로 비켜 ▶"
				return "갓길로 앞질러 ▶" if not player.shoulder_closed else "원흉 앞으로 ▶"
			if _lock_target.is_empty() and boss.any_alive():
				var vl: int = roundi(float(boss.alive()[0]["lane_pos"]))
				return "◀ 원흉 차로로" if player.lane > vl else "원흉 차로로 ▶"
			if boss.danger_lanes(player).has(player.lane):
				return "피해! 차로 바꿔"
			if window_left() > 0.0:
				if skills.enabled:
					var nt: int = skills.next_tier(self)
					return "지금! 몰아쳐라" if nt == 0 else ("지금! 참교육" if nt == 5 else "지금! 압정 폭격" if nt == 3 else "지금! 경적 충격파")
				return "지금! 분노 폭탄" if rage >= float(tune.get("superCost", 0.2)) - 1e-6 else "지금! 몰아쳐라"
			var bh: String = str(boss.beh.get("hint")) if boss.beh != null and "hint" in boss.beh else ""
			return bh if bh.length() <= 16 and bh != "" else "발사 꾹 · 공격 피하기"
	return ""


## Seconds left in the signature window of the first alive villain (0 = closed).
func window_left() -> float:
	var stun: float = 0.0
	for v: Dictionary in boss.alive():
		stun = maxf(stun, float(v.get("stun_skill", 0.0)))  # SKILLS: a skill stun is a window too
	if boss.beh != null and boss.beh.has_method(&"window_left"):
		return maxf(stun, float(boss.beh.call(&"window_left", boss)))
	for v: Dictionary in boss.alive():
		if bool(boss.vuln(v)["window"]):
			return maxf(stun, 1.0)
	return stun


func state() -> Dictionary:
	var ref: float = boss.ref_s()
	var vs: Array[Dictionary] = []
	var wl: float = window_left()
	for v: Dictionary in boss.villains:
		vs.append({"id": v["index"], "kind": v["kind"], "name": v["name"], "color": v["color"], "s": v["s"], "x": v["x"],
			"lane": roundi(float(v["lane_pos"])), "lane_pos": v["lane_pos"], "hp": maxf(0.0, float(v["hp"])), "hp_max": v["max_hp"],
			"alive": v["alive"], "dying": v["dying"], "gone": v["gone"], "parked": v["parked"], "tell": boss.tell_of(v),
			"vulnerable": bool(v["alive"]) and wl > 0.0, "window_left": wl if bool(v["alive"]) else 0.0, "tires": v["tires"],
			"stun_skill": float(v.get("stun_skill", 0.0)),
			"popped": v["popped"], "yaw": v["yaw"], "nose": v["nose"], "tilt_x": v["tilt_x"], "tilt_z": v["tilt_z"], "y": v["y"],
			"rot": v["rot"], "flash": v["flash"], "headlights": v["headlights"], "blinker": v["blinker"], "finish": v["finish"],
			"death_t": v["death_t"], "len": v["len"], "w": v["w"], "lunge_off": v["lunge_off"], "taunt": v["taunt"]})
	var lock_reason: String = ""
	if phase == &"boss" and _lock_target.is_empty():
		lock_reason = "lane" if front_locked else "far"
	var dist: float = maxf(0.0, ref - player.s)
	var prog: float = 1.0
	if phase in [&"intro", &"jam", &"boss", &"wreck", &"fail"] and not front_locked:
		prog = clampf((player.s - start_s) / maxf(1.0, ref - start_s), 0.0, 1.0)
	var relay := PackedInt32Array()
	if boss.beh != null and boss.beh.has_method(&"relay_lit"):
		relay = boss.beh.call(&"relay_lit", boss)
	var out: Dictionary = {
		"phase": phase, "t": time, "real_t": real_time, "phase_t": phase_t,
		"player": {"s": player.s, "x": player.x + player.wig, "lane": player.lane, "v": player.v, "hp": hp, "hp_max": hp_max,
			"rage": rage, "boost": clampf(player.boost_t / float(tune.get("boostTime", 2.2)), 0.0, 1.0), "yaw": player.yaw,
			"roll": player.roll, "hop": player.hop, "brake": player.brake_on, "invuln": player.invuln, "ghost": player.ghost,
			"lc_t": player.lc_t, "bump_kick": player.bump_kick, "mode": player.mode, "spin": wreck_spin, "min_hp": min_hp},
		"villains": vs,
		"lock": {"active": front_locked, "in_range": not _lock_target.is_empty(), "target_id": int(_lock_target.get("index", -1)),
			"reason": lock_reason},
		"hint": hint(), "distance_m": dist, "progress": prog,
		"hazards": {"beams": boss.beams, "waves": boss.waves, "items": boss.items},
		"projectiles": weapons.projectiles(boss.villains), "relay_lit": relay,
		"stats": {"score": score, "combo": combo, "fails": fails, "minis_done": minis_done, "minis_total": minis_total,
			"pay_mul": pay_retry_mul, "stage_time": stage_clock, "boss_time": boss_clock},
	}
	out["skills"] = skills.state(self)
	out["neck"] = neck.state(self)
	var cps: Array[Dictionary] = []
	for c: Dictionary in _cps:
		cps.append({"d": c["d"], "done": c["done"], "fast": c["fast"]})
	out["checkpoints"] = cps
	if phase == &"result":
		out["result"] = _result
	return out


## Sim time scale of the last tick (0 in hitstop, slow_scale in slow-mo): the view advances FX by real dt × this.
func time_scale() -> float:
	return _ts


func _make_result() -> Dictionary:
	var freed: int = mini(display_cars, roundi(float(bridge.info().get("released_count", 0)) * mult))
	var total: float = stage_clock
	var cath: float = 70.0 + (12.0 if bumps == 0 else -minf(30.0, bumps * 5.0)) + (10.0 if boss_clock < 14.0 else 4.0 if boss_clock < 22.0 else -4.0) \
		+ (6.0 if supers > 0 else 0.0) + minf(8.0, max_combo / 5.0)
	cath = clampf(roundf(cath), 12.0, 100.0)
	var star2: int = int(hpc.get("star2", 60))
	var missions: Array[Dictionary] = [
		{"label": "원인 해결 (구조 완료 · 압정 금지)" if stage.get("honkOnly") == true else "원인 제거 (참교육 완료)", "done": true},
		{"label": "내구도 %d 이상 · 견인 0회" % star2, "done": hp >= star2 and fails == 0},
		{"label": ("잔챙이 빌런 %d명 전원 참교육" % minis_total) if minis_total > 0 else "잔챙이 빌런 없음 (자동 달성)", "done": minis_done >= minis_total},
	]
	var stars: int = 0
	for m: Dictionary in missions:
		stars += 1 if bool(m["done"]) else 0
	var km: float = float(stage.get("displayKm", 2.4))
	var saved_h: int = roundi((km / 9.0 - km / 100.0) * 60.0 * freed / 60.0)
	var names: PackedStringArray = []
	for sp: Variant in stage.get("villains", []):
		names.append(str((sp as Dictionary).get("name", "원흉")))
	var st: Array = boss.beh.call(&"stats", boss) if boss.beh != null and boss.beh.has_method(&"stats") else []
	return {"stars": stars, "missions": missions, "score": roundi(score + freed * 5 + cath * 40.0), "time_s": total,
		"boss_time_s": boss_clock, "hp": hp, "hp_max": hp_max, "min_hp": min_hp, "tows": fails, "retries": fails,
		"pay_mul": pay_retry_mul, "freed": freed, "saved_hours": saved_h, "cath": cath, "bumps": bumps, "hits": hits,
		"shots": _shots_total + weapons.shots, "hits_taken": hits_taken, "supers": supers, "minis_done": minis_done, "minis_total": minis_total,
		"cheaters": cheaters, "rage_horns": rage_horns, "villain_name": " · ".join(names), "stage_id": int(stage.get("id", 0)),
		"stats": st, "skills": skills.counts.duplicate(), "neck": neck.result.duplicate(), "checkpoints": _cps_done()}


func _cps_done() -> int:
	var n: int = 0
	for c: Dictionary in _cps:
		n += 1 if bool(c["done"]) else 0
	return n
