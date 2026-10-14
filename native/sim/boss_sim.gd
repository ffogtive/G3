class_name BossSim
extends RefCounted
## boss.js BossManager without meshes: villains (Dictionaries, so R1 snapshots are a deep copy), attack schedule,
## beams / horn+smoke waves / thrown + rolled items, lunge, tire pops, HP phases, rocket / pullover finishes.
## Signature module (behaviors/*.gd) plugs in like behaviors/index.js. Randomness: one seeded RandomNumberGenerator.
## Native changes vs the oracle:
##   - the villain never drives through the player: its base speed drops when the player sits right in front of
##     it in its lane (the oracle's villain ignored the player, M1a feedback "원흉 차가 뒤에서 앞으로 통과");
##   - P0#7 damage: outside the signature window `dmg_out`, inside (vulnerable() > 1) `dmg_in` (GameSim passes both);
##   - R1: snapshot()/restore() carry the phase-applied state (attacks, intervalMul, stopped/slow/zig, lane pos).
##   - docs/SKILLS.md (config.skills, GameSim + SkillsSim): skill_damage() = damage() + a generic skill stun
##     (v.stun_skill: a window in vuln(), attacks blocked, capped at skills.stunCap per chain, then skills.stunImmune s
##     of stun immunity), cancel_attack(), force_pop(), execute(); hold pauses the attack clock while a skill is cast;
##     the death timeline reads skills.finish.<id> (real s via ctx.real_dt) and skip_death() jumps it to `done`.
##
## 가설: ✅ boss.js is ~600 lines of logic + ~250 of mesh/fx; the logic part ports 1:1 when every mesh write
##       becomes a state field the view reads (tell, headlights, nose, tilt, popped, y, hazards()).

const POP_ORDER: Array[int] = [0, 1, 2, 3]
const POP_ORDER_REAR: Array[int] = [2, 3, 0, 1]
const LAND_Y: Dictionary = {"hay": 0.37, "box": 0.28, "tire": 0.43, "cone": 0.4, "tack": 0.2}

var villains: Array[Dictionary] = []
var beams: Array[Dictionary] = []
var waves: Array[Dictionary] = []
var items: Array[Dictionary] = []
var pending: Array[Dictionary] = []
var attack_t: float = 3.0
var time: float = 0.0
var attacks: Dictionary = {}
var interval_mul: float = 1.0
var phases: Array = []
var phase_idx: int = 0
var parked: int = 0
var total_max_hp: float = 1.0
var finish_style: String = "rocket"
var stage: Dictionary = {}
var beh: Object = null
var sig: Dictionary = {}
var rng := RandomNumberGenerator.new()
var vuln_mul: float = 4.0
var immune_below: float = 0.3
var _vuln_pop_t: float = -9.0
## SKILLS: attack clock paused while > 0 (sim s; GameSim sets it while a skill is cast).
var hold: float = 0.0
var stun_cap: float = 2.0
var stun_immune_s: float = 1.5
## config.skills.finish ({} = the old constants: rocket 0.85 / 2.15 s, balloon·heli·ufo 0.8 + 3.0 / 2.4 s, sim time).
var finish_tl: Dictionary = {}


func spawn(p_stage: Dictionary, specs: Array, p_beh: Object, seed: int, cfg: Dictionary) -> void:
	stage = p_stage
	beh = p_beh
	rng.seed = seed
	vuln_mul = float(cfg.get("vulnMul", 4.0))
	immune_below = float(cfg.get("immuneBelow", 0.3))
	finish_style = str(cfg.get("finish", "rocket"))
	var hp_mul: float = float(cfg.get("hpMul", 1.0))
	finish_tl = cfg.get("finishTimeline", {}) if cfg.get("finishTimeline") is Dictionary else {}
	stun_cap = float(cfg.get("stunCap", 2.0))
	stun_immune_s = float(cfg.get("stunImmune", 1.5))
	hold = 0.0
	villains.clear()
	beams.clear()
	waves.clear()
	items.clear()
	pending.clear()
	var jam_v: float = float(stage.get("jamSpeed", 2.4))
	var stage_v: Array = stage.get("villains", [])
	for i: int in specs.size():
		var sp: Dictionary = specs[i]
		var st: Dictionary = stage_v[i] if i < stage_v.size() else {}
		var lane: float = float(sp.get("lane", 0.0))
		var stopped: bool = st.get("stopped") == true
		var zig: bool = bool(st.get("zig")) if st.get("zig") != null else str(sp.get("kind", "")) == "villainPhone"
		var hp: float = float(st.get("hp", 100.0)) * hp_mul
		villains.append({
			"index": i, "kind": str(sp.get("kind", "villainSedan")), "name": str(st.get("name", "원흉")),
			"color": int(st.get("color")) if st.get("color") != null else -1,
			"len": float(sp.get("len", 4.8)), "w": float(sp.get("w", 2.0)), "h": 1.7,
			"lane_pos": lane, "home_lane": lane, "target_lane_pos": lane, "x": Cfg.lane_xf(lane),
			"base_s": float(sp["s"]), "s": float(sp["s"]), "lunge_off": 0.0, "stopped": stopped,
			"v_nominal": 0.0 if stopped else jam_v, "v": 0.0 if stopped else jam_v,
			"hp": hp, "max_hp": hp, "tires": 4, "popped": [], "alive": true, "dying": false, "gone": false,
			"flash": 0.0, "tilt_x": 0.0, "tilt_z": 0.0, "nose": 0.0, "yaw": 0.0,
			"zig_t": rng.randf() * 10.0, "zig_boost": 0.0, "zig": zig, "zig_c": clampi(roundi(lane), 1, 2),
			"taunt": "", "taunt_until": 0.0, "next_taunt": 1.5 + i * 1.7, "lunge": {}, "lunge_at": 0.0, "return_at": 0.0,
			"finish": "", "death_t": 0.0, "launched": false, "y": 0.0, "vel_y": 0.0, "vel_s": 0.0, "vel_x": 0.0,
			"spin": Vector3.ZERO, "rot": Vector3.ZERO, "is_last": false, "hit_from_rear": false,
			"pull_x": 0.0, "pull_s0": 0.0, "pull_dist": 0.0, "parked": false, "headlights": false, "blinker": 0,
			"force_finish": "", "stun_skill": 0.0, "stun_chain": 0.0, "stun_immune": 0.0, "recoil": 0.0,
		})
	attack_t = 2.2
	total_max_hp = 0.0
	for v: Dictionary in villains:
		total_max_hp += float(v["max_hp"])
	total_max_hp = maxf(1.0, total_max_hp)
	attacks = BossSim.attack_table(stage.get("attacks"))
	interval_mul = 1.0
	phases = []
	if stage.get("phases") is Array:
		phases = (stage["phases"] as Array).duplicate(true)
		phases.sort_custom(func(a: Variant, b: Variant) -> bool: return float((a as Dictionary).get("hp", 0)) > float((b as Dictionary).get("hp", 0)))
	phase_idx = 0
	parked = 0
	sig = {}
	if beh != null:
		if "attacks" in beh and beh.get("attacks") is Dictionary:
			attacks = (beh.get("attacks") as Dictionary).duplicate()
		beh.call(&"init", self, stage)


## stages.json `attacks` ([[kind, weight], ...] or {kind: weight}) → ordered {kind: weight}.
static func attack_table(src: Variant) -> Dictionary:
	var out: Dictionary = {}
	if src is Array:
		for e: Variant in src:
			if e is Array and (e as Array).size() >= 2:
				out[str((e as Array)[0])] = float((e as Array)[1])
	elif src is Dictionary:
		for k: Variant in (src as Dictionary).keys():
			out[str(k)] = float((src as Dictionary)[k])
	return out


func alive() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for v: Dictionary in villains:
		if bool(v["alive"]):
			out.append(v)
	return out


func any_alive() -> bool:
	for v: Dictionary in villains:
		if bool(v["alive"]):
			return true
	return false


func hp_frac() -> float:
	var hp: float = 0.0
	for v: Dictionary in villains:
		hp += maxf(0.0, float(v["hp"]))
	return hp / total_max_hp


func _ref_set() -> Array[Dictionary]:
	var a: Array[Dictionary] = alive()
	if not a.is_empty():
		return a
	var d: Array[Dictionary] = []
	for v: Dictionary in villains:
		if bool(v["dying"]):
			d.append(v)
	return d if not d.is_empty() else villains


func ref_s() -> float:
	var src: Array[Dictionary] = _ref_set()
	if src.is_empty():
		return 0.0
	var acc: float = 0.0
	for v: Dictionary in src:
		acc += float(v["base_s"])
	return acc / src.size()


func ref_v() -> float:
	var src: Array[Dictionary] = _ref_set()
	return float(src[0]["v_nominal"]) if not src.is_empty() else 0.0


static func occupies_x(x: float, w: float, lane: int) -> bool:
	return absf(x - Cfg.lane_x(lane)) < w / 2.0 + Cfg.LANE_W / 2.0 - 0.6


static func lanes_of(v: Dictionary) -> Array[int]:
	var out: Array[int] = []
	for i: int in Cfg.NUM_LANES:
		if BossSim.occupies_x(float(v["x"]), float(v["w"]), i):
			out.append(i)
	return out


func player_in_lanes(p: PlayerSim, lanes: Array) -> bool:
	for ln: Variant in lanes:
		if p.occupies(int(ln)):
			return true
	return false


## boss.js targetFor + lock-on (N2/N4): behind = nearest within behind_range; front = the villain whose lanes are
## within lane_range of the player's lane. Returns {} when nothing is in range.
func target_for(p: PlayerSim, lane_range: int = 1, behind_range: float = 42.0) -> Dictionary:
	var best: Dictionary = {}
	var bd: float = INF
	var pl: int = roundi((p.x + Cfg.LANE_W * 1.5) / Cfg.LANE_W)
	for v: Dictionary in villains:
		if not bool(v["alive"]):
			continue
		var ds: float = float(v["s"]) - p.s
		if ds > 0.0:
			if ds < behind_range and ds < bd:
				bd = ds
				best = v
			continue
		var near: bool = false
		for l: int in BossSim.lanes_of(v):
			if absi(l - pl) <= lane_range:
				near = true
		if not near:
			continue
		var dx: float = absf(float(v["x"]) - p.x)
		if dx < bd:
			bd = dx
			best = v
	return best


## Signature window state: {window: bool, immune: bool, mul: float (web value)}.
func vuln(v: Dictionary) -> Dictionary:
	var m: float = float(beh.call(&"vulnerable", self, v)) if beh != null and beh.has_method(&"vulnerable") else 1.0
	if float(v.get("stun_skill", 0.0)) > 0.0:
		m = maxf(m, 1.5)  # SKILLS: a skill stun is a window (×vulnMul tacks), whatever the signature says
	return {"window": m > 1.001, "immune": m < immune_below, "mul": m}


## boss.js damage with P0#7 scaling. Returns {killed, popped: int, window, immune, dmg, villain}.
func damage(v: Dictionary, dmg_out: float, dmg_in: float, from_rear: bool) -> Dictionary:
	if v.is_empty() or not bool(v["alive"]):
		return {"killed": false, "popped": 0, "window": false, "immune": false, "dmg": 0.0}
	var vu: Dictionary = vuln(v)
	var amount: float = dmg_in if bool(vu["window"]) else dmg_out * (float(vu["mul"]) if bool(vu["immune"]) else 1.0)
	if bool(vu["immune"]) and time - _vuln_pop_t > 1.4:
		_vuln_pop_t = time
		var it: String = str(beh.get("immune_text")) if beh != null and "immune_text" in beh else ""
		pending.append({"type": "bubble", "who": "villain", "id": int(v["index"]), "text": it if it != "" else "안 맞아!", "kind": "warn", "dur": 1.0})
	var r: Dictionary = _apply(v, amount, from_rear)
	r["window"] = vu["window"]
	r["immune"] = vu["immune"]
	return r


## HP loss + tire pops at 75/50/25 % + kill flag (shared by damage() and skill_damage()).
func _apply(v: Dictionary, amount: float, from_rear: bool) -> Dictionary:
	v["hit_from_rear"] = from_rear
	var before: float = float(v["hp"]) / float(v["max_hp"])
	v["hp"] = float(v["hp"]) - amount
	v["flash"] = 1.0
	var after: float = maxf(0.0, float(v["hp"])) / float(v["max_hp"])
	var popped: int = 0
	if stage.get("honkOnly") != true:
		for k: int in [1, 2, 3]:
			var th: float = 1.0 - k * 0.25
			if before > th and after <= th and int(v["tires"]) > 1:
				pop_tire(v)
				popped += 1
	var killed: bool = float(v["hp"]) <= 0.0
	if killed:
		v["alive"] = false
	return {"killed": killed, "popped": popped, "dmg": amount, "villain": v}


## SKILLS (docs/SKILLS.md §6): damage() for a skill hit. window: -1 = ask vuln() now, 0/1 = decided at the first hit of
## a multi-hit (so a stun from hit 1 does not turn hits 2..n into window hits). hp_floor > 0 keeps HP ≥ floor
## (skills.minKillT). stun (sim s) goes through apply_stun(). Returns {killed, popped, window, immune, dmg, stun}.
func skill_damage(v: Dictionary, dmg_in: float, dmg_out: float, stun: float, from_rear: bool, window: int = -1,
		hp_floor: float = 0.0) -> Dictionary:
	if v.is_empty() or not bool(v["alive"]):
		return {"killed": false, "popped": 0, "window": false, "immune": false, "dmg": 0.0, "stun": 0.0}
	var vu: Dictionary = vuln(v)
	var win: bool = bool(vu["window"]) if window < 0 else window == 1
	var immune: bool = bool(vu["immune"]) and not win
	var amount: float = dmg_in if win else dmg_out * (float(vu["mul"]) if immune else 1.0)
	if hp_floor > 0.0:
		amount = minf(amount, maxf(0.0, float(v["hp"]) - hp_floor))
	var r: Dictionary = _apply(v, amount, from_rear)
	r["window"] = win
	r["immune"] = immune
	r["stun"] = apply_stun(v, stun) if not bool(r["killed"]) and stun > 0.0 else 0.0
	return r


## Generic skill stun: adds up to stun_cap per chain; when it runs out the villain is stun-immune for stun_immune_s.
## Returns the stun actually granted (0 while immune or capped).
func apply_stun(v: Dictionary, dur: float) -> float:
	if float(v.get("stun_immune", 0.0)) > 0.0 or not bool(v["alive"]):
		return 0.0
	var grant: float = minf(dur, maxf(0.0, stun_cap - float(v["stun_chain"])))
	if grant <= 0.0:
		return 0.0
	v["stun_skill"] = float(v["stun_skill"]) + grant
	v["stun_chain"] = float(v["stun_chain"]) + grant
	cancel_attack(v)
	return grant


## Cancels the villain's running telegraphs: lunge (tele/go/hold) + a queued swerve lunge + its high beams.
func cancel_attack(v: Dictionary) -> void:
	v["lunge"] = {}
	v["lunge_off"] = 0.0
	v["lunge_at"] = 0.0
	v["nose"] = 0.0
	for b: Dictionary in beams:
		if int(b["vi"]) == int(v["index"]):
			b["life"] = 0.0
			b["t"] = float(b["tele"]) + float(b["on"])  # no hit window left this tick
			b["res"] = true  # cancelled, not dodged


## Pops one more tire (skills.t3.pop) while more than one is left. Returns 1 when it popped.
func force_pop(v: Dictionary) -> int:
	if stage.get("honkOnly") == true or int(v["tires"]) <= 1:
		return 0
	pop_tire(v)
	return 1


## t5 execute: HP to 0 (GameSim then runs the usual kill → start_death path).
func execute(v: Dictionary) -> Dictionary:
	if v.is_empty() or not bool(v["alive"]):
		return {"killed": false, "popped": 0, "window": false, "immune": false, "dmg": 0.0, "stun": 0.0}
	var amount: float = maxf(0.0, float(v["hp"]))
	var r: Dictionary = _apply(v, amount + 1.0, false)
	r["dmg"] = amount
	r["killed"] = true
	v["alive"] = false
	r["window"] = bool(vuln(v)["window"])
	r["immune"] = false
	r["stun"] = 0.0
	return r


## Tap-to-skip: jumps every dying villain's timeline to its finish `done` (skills.finish.<id>.done) so it is gone on
## the next update. HP / kill results are already final. Returns how many were skipped.
func skip_death() -> int:
	var n: int = 0
	for v: Dictionary in villains:
		if bool(v["dying"]) and not bool(v["gone"]):
			var fin: String = str(v["finish"]) if str(v["finish"]) != "" else "rocket"
			var tl: Dictionary = finish_tl.get(fin, {}) if finish_tl.get(fin) is Dictionary else {}
			v["death_t"] = maxf(float(v["death_t"]), float(tl.get("done", 1.9)))
			if fin == "rocket" or fin == "":
				v["launched"] = true
			n += 1
	return n


func pop_tire(v: Dictionary) -> void:
	var order: Array[int] = POP_ORDER_REAR if bool(v["hit_from_rear"]) else POP_ORDER
	var popped: Array = v["popped"]
	var idx: int = 0
	for i: int in order:
		if not popped.has(i):
			idx = i
			break
	popped.append(idx)
	v["tires"] = int(v["tires"]) - 1
	v["tilt_z"] = float(v["tilt_z"]) + (1.0 if idx % 2 == 0 else -1.0) * 0.07
	v["tilt_x"] = float(v["tilt_x"]) + (-1.0 if idx < 2 else 1.0) * 0.05


## boss.js startDeath. Returns lanes right of the villain when it pulls over (GameSim drops those walls).
func start_death(v: Dictionary, is_last: bool) -> PackedInt32Array:
	v["alive"] = false
	v["dying"] = true
	v["death_t"] = 0.0
	v["is_last"] = is_last
	v["lunge"] = {}
	v["vel_y"] = 8.0
	v["vel_s"] = float(v["v"]) + 3.0
	v["spin"] = Vector3(3.5 + rng.randf() * 2.0, 7.0 + rng.randf() * 3.0, 2.5)
	v["launched"] = false
	if beh != null and beh.has_method(&"on_death"):
		beh.call(&"on_death", self, v)
	var ff: String = str(v["force_finish"])
	v["finish"] = ff if ff != "" else ("pullover" if stage.get("honkOnly") == true else finish_style)
	for b: Dictionary in beams:
		if int(b["vi"]) == int(v["index"]):
			b["life"] = 0.0
	var right := PackedInt32Array()
	if str(v["finish"]) == "pullover":
		v["base_s"] = float(v["s"])
		v["lunge_off"] = 0.0
		v["lunge_at"] = 0.0
		v["pull_x"] = float(v["x"])
		v["pull_s0"] = float(v["base_s"])
		v["pull_dist"] = 5.0 + parked * (float(v["len"]) + 2.5)
		parked += 1
		var own: Array[int] = BossSim.lanes_of(v)
		var mx: int = own.max() if not own.is_empty() else roundi(float(v["lane_pos"]))
		for l: int in range(mx + 1, Cfg.NUM_LANES):
			right.append(l)
		return right
	while int(v["tires"]) > 0:
		pop_tire(v)
	return right


func _sm(x: float) -> float:
	var c: float = clampf(x, 0.0, 1.0)
	return c * c * (3.0 - 2.0 * c)


## Returns true when the villain just finished its exit (boss.onGone). rdt = real dt (timeline clock with finish_tl).
func _update_death(v: Dictionary, dt: float, rdt: float = -1.0) -> bool:
	if not finish_tl.is_empty():
		return _update_death_tl(v, dt, rdt if rdt >= 0.0 else dt)
	v["death_t"] = float(v["death_t"]) + dt
	var t: float = float(v["death_t"])
	var fin: String = str(v["finish"])
	if fin == "pullover":
		v["base_s"] = float(v["pull_s0"]) + float(v["pull_dist"]) * _sm(t / 1.9)
		v["s"] = v["base_s"]
		var k: float = _sm((t - 0.45) / 1.5)
		v["x"] = float(v["pull_x"]) + (Cfg.lane_x(Cfg.SHOULDER_LANE) - float(v["pull_x"])) * k
		v["yaw"] = -sin(k * PI) * 0.25
		if t > 2.2 and not bool(v["gone"]):
			v["gone"] = true
			v["dying"] = false
			v["parked"] = true
			return true
		return false
	v["base_s"] = float(v["base_s"]) + float(v["v_nominal"]) * dt
	if fin == "rocket" or fin == "":
		if not bool(v["launched"]) and t > 0.85:
			v["launched"] = true
			v["vel_x"] = (rng.randf() - 0.5) * 4.0
			v["vel_y"] = 36.0
			v["vel_s"] = float(v["v"]) + 6.0
			v["spin"] = (v["spin"] as Vector3) * 1.8
		var g: float = -5.0 if bool(v["launched"]) else -26.0
		v["vel_y"] = float(v["vel_y"]) + g * dt
		v["y"] = float(v["y"]) + float(v["vel_y"]) * dt
		v["x"] = float(v["x"]) + float(v["vel_x"]) * dt
		if not bool(v["launched"]) and float(v["y"]) < 0.0:
			v["y"] = 0.0
			v["vel_y"] = absf(float(v["vel_y"])) * 0.45
		v["s"] = float(v["s"]) + float(v["vel_s"]) * dt
		v["rot"] = (v["rot"] as Vector3) + (v["spin"] as Vector3) * dt
		if bool(v["launched"]) and t > 2.15 and not bool(v["gone"]):
			v["gone"] = true
			v["dying"] = false
			return true
		return false
	# balloon / heli / ufo: settle 0.8 s, then lift (the view draws the prop)
	v["s"] = float(v["s"]) + float(v["v_nominal"]) * dt
	if t > 0.8:
		v["y"] = float(v["y"]) + (2.0 + (t - 0.8) * 4.5) * dt
	var done: float = 2.4 if fin == "ufo" else 3.0
	if t - 0.8 > done and not bool(v["gone"]):
		v["gone"] = true
		v["dying"] = false
		return true
	return false


const _BEATS: Array[String] = ["settle", "lift", "hook", "beam", "twinkle"]


## SKILLS §4 finish timeline (skills.finish.<id>, real s from the kill): motion integrates sim dt (so hitstop / slow-mo
## still freeze / slow it), the beats and `done` run on the real clock. Emits finish_beat {id, finish, beat} once per beat.
func _update_death_tl(v: Dictionary, dt: float, rdt: float) -> bool:
	var t0: float = float(v["death_t"])
	v["death_t"] = t0 + rdt
	var t: float = float(v["death_t"])
	var fin: String = str(v["finish"]) if str(v["finish"]) != "" else "rocket"
	var tl: Dictionary = finish_tl.get(fin, {}) if finish_tl.get(fin) is Dictionary else {}
	var done: float = float(tl.get("done", 2.0))
	for b: String in _BEATS:
		if tl.has(b) and t0 < float(tl[b]) and t >= float(tl[b]):
			pending.append({"type": "finish_beat", "id": int(v["index"]), "finish": fin, "beat": b})
	if bool(v["gone"]):
		return false
	if fin == "pullover":
		var kd: float = done / 2.2
		v["base_s"] = float(v["pull_s0"]) + float(v["pull_dist"]) * _sm(t / (1.9 * kd))
		v["s"] = v["base_s"]
		var k: float = _sm((t - 0.45 * kd) / (1.5 * kd))
		v["x"] = float(v["pull_x"]) + (Cfg.lane_x(Cfg.SHOULDER_LANE) - float(v["pull_x"])) * k
		v["yaw"] = -sin(k * PI) * 0.25
	else:
		v["base_s"] = float(v["base_s"]) + float(v["v_nominal"]) * dt
		if fin == "rocket":
			if not bool(v["launched"]) and t > float(tl.get("lift", 0.6)):
				v["launched"] = true
				v["vel_x"] = (rng.randf() - 0.5) * 4.0
				v["vel_y"] = 36.0
				v["vel_s"] = float(v["v"]) + 6.0
				v["spin"] = (v["spin"] as Vector3) * 1.8
			var g: float = -5.0 if bool(v["launched"]) else -26.0
			v["vel_y"] = float(v["vel_y"]) + g * dt
			v["y"] = float(v["y"]) + float(v["vel_y"]) * dt
			v["x"] = float(v["x"]) + float(v["vel_x"]) * dt
			if not bool(v["launched"]) and float(v["y"]) < 0.0:
				v["y"] = 0.0
				v["vel_y"] = absf(float(v["vel_y"])) * 0.45
			v["s"] = float(v["s"]) + float(v["vel_s"]) * dt
			v["rot"] = (v["rot"] as Vector3) + (v["spin"] as Vector3) * dt
		else:
			# balloon (lift) / heli (hook, then away forward) / ufo (beam, spinning): the view draws the prop
			var up: float = float(tl.get("lift", tl.get("hook", tl.get("beam", tl.get("settle", 0.5)))))
			v["s"] = float(v["s"]) + float(v["v_nominal"]) * dt + (6.0 * dt if fin == "heli" and t > up else 0.0)
			if t > up:
				v["y"] = float(v["y"]) + (2.0 + (t - up) * 4.5) * dt
				if fin == "ufo":
					v["rot"] = (v["rot"] as Vector3) + Vector3(0.0, 6.0 * dt, 0.0)
	if t >= done:
		v["gone"] = true
		v["dying"] = false
		v["parked"] = fin == "pullover"
		return true
	return false


func _choose_attack() -> String:
	var tot: float = 0.0
	for k: String in attacks.keys():
		tot += float(attacks[k])
	if tot <= 0.0:
		return ""
	var r: float = rng.randf() * tot
	for k: String in attacks.keys():
		r -= float(attacks[k])
		if r <= 0.0:
			return k
	return ""


func _check_phase(ctx: Dictionary) -> Dictionary:
	if phase_idx >= phases.size():
		return {}
	var ph: Dictionary = phases[phase_idx]
	if hp_frac() > float(ph.get("hp", 0.0)):
		return {}
	phase_idx += 1
	var atk: Dictionary = BossSim.attack_table(ph.get("attacks"))
	if not atk.is_empty():
		attacks = atk
	interval_mul *= 0.85
	var lane_free: Callable = ctx.get("lane_free", Callable())
	for v: Dictionary in villains:
		if not bool(v["alive"]):
			continue
		v["stopped"] = ph.get("stopped") == true
		if bool(v["stopped"]):
			v["v_nominal"] = 0.0
			v["lunge"] = {}
			v["lunge_off"] = 0.0
			v["lunge_at"] = 0.0
			v["return_at"] = 0.0
			v["target_lane_pos"] = v["lane_pos"]
		else:
			v["v_nominal"] = float(stage.get("jamSpeed", 2.4)) * (0.7 if ph.get("slow") == true else 1.0)
		var zc: int = clampi(roundi(float(v["lane_pos"])), 1, 2)
		var sweep_free: bool = true
		for l: int in [zc - 1, zc, zc + 1]:
			if lane_free.is_valid() and not bool(lane_free.call(l)):
				sweep_free = false
			for o: Dictionary in villains:
				if o != v and (bool(o["alive"]) or bool(o["dying"])) and absf(float(o["lane_pos"]) - l) < 0.9:
					sweep_free = false
		if ph.get("zig") == true and not bool(v["stopped"]) and sweep_free:
			v["zig"] = true
			v["zig_c"] = zc
		elif bool(v["zig"]):
			v["zig"] = false
			v["target_lane_pos"] = v["home_lane"]
		v["flash"] = 1.0
	attack_t = 1.2
	return {"type": "boss_phase", "boss_phase": phase_idx, "label": str(ph.get("label", "2페이즈!"))}


func _say(v: Dictionary, text: String, dur: float = 2.0) -> void:
	v["taunt"] = text
	v["taunt_until"] = time + dur
	pending.append({"type": "bubble", "who": "villain", "id": int(v["index"]), "text": text, "kind": "taunt", "dur": dur, "taunt": true})


func _pop(v: Dictionary, text: String, kind: String = "warn") -> void:
	pending.append({"type": "bubble", "who": "villain", "id": int(v["index"]), "text": text, "kind": kind, "dur": 1.0})


func _attack(kind: String, v: Dictionary, ctx: Dictionary) -> void:
	if beh != null and beh.has_method(&"attack") and bool(beh.call(&"attack", self, kind, v, ctx)):
		return
	var p: PlayerSim = ctx["player"]
	pending.append({"type": "attack", "kind": kind, "id": int(v["index"])})
	match kind:
		"highbeam":
			_pop(v, "상향등!")
			beams.append({"vi": int(v["index"]), "t": 0.0, "tele": 0.75, "on": 0.5, "life": 1.4, "hit": false, "lanes": BossSim.lanes_of(v)})
		"horn":
			_pop(v, "빵!!!")
			_wave(v, "horn")
		"lunge":
			if (v["lunge"] as Dictionary).is_empty():
				_pop(v, "부릉부릉!")
				v["lunge"] = {"t": 0.0, "phase": "tele", "reach": 0.0, "hit": false}
		"throw", "roll":
			var rolling: bool = kind == "roll"
			var n: int = 1 if (stage.get("villains", []) as Array).size() > 1 else (2 if rolling or rng.randf() < 0.35 else 1)
			var lanes: Array[int] = [p.lane]
			var hi: int = Cfg.NUM_LANES - 1 if rolling else Cfg.SHOULDER_LANE
			var guard: int = 0
			while lanes.size() < n and guard < 8:
				guard += 1
				var l2: int = clampi(p.lane + (-1 if rng.randf() < 0.5 else 1), 0, hi)
				if not lanes.has(l2):
					lanes.append(l2)
			for ln: int in lanes:
				_throw(v, ln, p, rolling)
			if rng.randf() < 0.6:
				var ti: String = str(stage.get("throwItem", "cup"))
				_say(v, ("수박 서비스~" if ti == "watermelon" else "거름이여~" if ti == "hay" else "굴러간다~") if rolling else "옛다!")
		"swerve":
			var tgt: float = float(mini(Cfg.NUM_LANES - 1, p.lane))
			if float(v["w"]) > 2.2 or str(v["kind"]) == "villainSuv":
				tgt = clampf(tgt + (-0.5 if tgt > float(v["lane_pos"]) else 0.5), 0.5, 2.5)
			var lane_free: Callable = ctx.get("lane_free", Callable())
			if lane_free.is_valid():
				for i: int in Cfg.NUM_LANES:
					if BossSim.occupies_x(Cfg.lane_xf(tgt), float(v["w"]), i) and not bool(lane_free.call(i)):
						return
			v["target_lane_pos"] = tgt
			v["return_at"] = time + 3.2
			_say(v, "비켜 비켜~")
			v["lunge_at"] = time + 0.65
		"zigzag":
			v["zig_boost"] = 2.6
			_say(v, "ㅋㅋㅋㅋㅋ")
		"smoke":
			_wave(v, "smoke")
			_say(v, "탈탈탈탈~")


func _wave(v: Dictionary, kind: String) -> void:
	var lanes: Array[int] = BossSim.lanes_of(v)
	if kind == "smoke" and not lanes.is_empty():
		var l0: int = lanes.min()
		var l1: int = lanes.max()
		if l0 > 0:
			lanes.append(l0 - 1)
		if l1 < Cfg.NUM_LANES - 1:
			lanes.append(l1 + 1)
	var front: float = float(v["s"]) + float(v["len"]) / 2.0
	waves.append({"lanes": lanes, "s": front, "speed": 8.0 if kind == "smoke" else 20.0, "kind": kind, "hit": false, "life": 3.2, "age": 0.0})


func _throw(v: Dictionary, lane: int, p: PlayerSim, rolling: bool) -> void:
	var kind: String = str(stage.get("throwItem", "cup")) if stage.get("throwItem") != null else "cup"
	var dur: float = 0.45 if rolling else 0.85
	var front: float = float(v["s"]) + float(v["len"]) / 2.0
	var land_s: float = front + 2.2 if rolling else p.s + maxf(0.0, p.v) * dur + 0.3
	items.append({"kind": kind, "lane": lane, "from_s": front - 0.6, "from_x": float(v["x"]), "from_y": float(v["h"]) + 0.4,
		"to_s": land_s, "to_x": Cfg.lane_x(lane), "to_y": float(LAND_Y.get(kind, 0.45)), "t": 0.0, "dur": dur, "landed": false,
		"rolling": rolling, "roll": 7.5 if kind == "watermelon" else 6.0, "s": land_s, "len": 1.5 if kind == "hay" else 1.1,
		"roll_t": 0.0, "from_mini": false, "marker": true})


## Mini villains' throws in the jam (boss.js throwFrom).
func throw_from(src_s: float, src_x: float, lane: int, p: PlayerSim, kind: String) -> void:
	var land_s: float = p.s + maxf(0.0, p.v) * 0.8 + 0.4
	items.append({"kind": kind, "lane": lane, "from_s": src_s, "from_x": src_x, "from_y": 1.9, "to_s": land_s,
		"to_x": Cfg.lane_x(lane), "to_y": 0.45, "t": 0.0, "dur": 0.8, "landed": false, "rolling": false, "roll": 0.0,
		"s": land_s, "len": 1.1, "roll_t": 0.0, "from_mini": true, "marker": true})


## ctx: {time, phase: StringName, player: PlayerSim, player_behind: bool, lane_free: Callable(int)->bool,
## traffic: TrafficBridge, night: bool, real_dt: float}. Returns events: player_hit {cause, tier, text, push, flash, mini},
## boss_phase (HP phase), bubble, attack, stun, gone {id, is_last}, dodge {kind, id} (an attack aimed at the player's lane
## when it started — beam / wave / thrown cup / lunge — ended without a hit and with the player out of it; SKILLS
## rageGain.dodge), finish_beat {id, finish, beat}.
func update(dt: float, ctx: Dictionary) -> Array[Dictionary]:
	time = float(ctx.get("time", time + dt))
	var rdt: float = float(ctx.get("real_dt", dt))
	hold = maxf(0.0, hold - dt)
	var events: Array[Dictionary] = []
	var p: PlayerSim = ctx["player"]
	var fighting: bool = ctx.get("phase", &"") == &"boss"
	for v: Dictionary in villains:
		if bool(v["dying"]):
			if _update_death(v, dt, rdt):
				events.append({"type": "gone", "id": int(v["index"]), "is_last": bool(v["is_last"]), "finish": str(v["finish"])})
			continue
		if not bool(v["alive"]):
			continue
		if float(v["stun_skill"]) > 0.0:
			v["stun_skill"] = maxf(0.0, float(v["stun_skill"]) - dt)
			if float(v["stun_skill"]) <= 0.0:
				v["stun_chain"] = 0.0
				v["stun_immune"] = stun_immune_s
		elif float(v["stun_immune"]) > 0.0:
			v["stun_immune"] = maxf(0.0, float(v["stun_immune"]) - dt)
		v["v"] = v["v_nominal"]
		# native: never drive through the player sitting right in front in our lane
		if player_in_lanes(p, BossSim.lanes_of(v)) and p.s > float(v["base_s"]):
			var gap: float = (p.s - p.len / 2.0) - (float(v["base_s"]) + float(v["len"]) / 2.0)
			if gap < 3.0:
				v["v"] = minf(float(v["v"]), maxf(0.0, p.v + (gap - 1.0) * 2.0))
		v["base_s"] = float(v["base_s"]) + float(v["v"]) * dt
		if float(v["lunge_at"]) > 0.0 and time > float(v["lunge_at"]):
			v["lunge_at"] = 0.0
			if (v["lunge"] as Dictionary).is_empty():
				v["lunge"] = {"t": 0.0, "phase": "tele", "reach": 0.0, "hit": false}
		var L: Dictionary = v["lunge"]
		if not L.is_empty():
			L["t"] = float(L["t"]) + dt
			if not L.has("aimed"):
				L["aimed"] = player_in_lanes(p, BossSim.lanes_of(v))
			match str(L["phase"]):
				"tele":
					v["nose"] = minf(1.0, float(L["t"]) / 0.55) * 0.6
					if float(L["t"]) > 0.55:
						L["phase"] = "go"
						L["t"] = 0.0
						L["reach"] = maxf(4.0, (p.s - p.len / 2.0) - (float(v["s"]) + float(v["len"]) / 2.0) + 1.6)
				"go":
					v["lunge_off"] = float(L["reach"]) * minf(1.0, float(L["t"]) / 0.3)
					if float(L["t"]) > 0.3:
						L["phase"] = "hold"
						L["t"] = 0.0
				"hold":
					if float(L["t"]) > 0.25:
						L["phase"] = "back"
						L["t"] = 0.0
						if bool(L["aimed"]) and not bool(L["hit"]) and fighting and not player_in_lanes(p, BossSim.lanes_of(v)):
							events.append({"type": "dodge", "kind": "lunge", "id": int(v["index"])})
				_:
					v["lunge_off"] = float(L["reach"]) * maxf(0.0, 1.0 - float(L["t"]) / 0.8)
					if float(L["t"]) > 0.8:
						v["lunge"] = {}
						v["lunge_off"] = 0.0
			if not (v["lunge"] as Dictionary).is_empty() and not bool(L["hit"]) and str(L["phase"]) in ["go", "hold"] and fighting \
					and p.invuln <= 0.0 and player_in_lanes(p, BossSim.lanes_of(v)) \
					and float(v["s"]) + float(v["lunge_off"]) + float(v["len"]) / 2.0 >= p.s - p.len / 2.0:
				L["hit"] = true
				events.append({"type": "player_hit", "cause": "lunge", "text": "들이받기!", "push": 4.0})
		else:
			v["nose"] = float(v["nose"]) * exp(-dt * 6.0)
			if float(v["recoil"]) > 0.0:  # SKILLS t1: knocked 1.5 m back, back in 0.3 s
				v["recoil"] = maxf(0.0, float(v["recoil"]) - dt)
				v["lunge_off"] = -1.5 * float(v["recoil"]) / 0.3
		v["s"] = float(v["base_s"]) + float(v["lunge_off"])
		if beh != null and beh.has_method(&"motion"):
			beh.call(&"motion", self, v, dt, ctx)
		if bool(v["zig"]) and not bool(v["stopped"]):
			v["zig_boost"] = maxf(0.0, float(v["zig_boost"]) - dt)
			v["zig_t"] = float(v["zig_t"]) + dt * (2.4 if float(v["zig_boost"]) > 0.0 else 1.0)
			v["target_lane_pos"] = float(v["zig_c"]) + sin(float(v["zig_t"]) * 0.9) + sin(float(v["zig_t"]) * 2.3) * 0.15
		elif float(v["return_at"]) > 0.0 and time > float(v["return_at"]):
			v["return_at"] = 0.0
			v["target_lane_pos"] = v["home_lane"]
		var prev_x: float = float(v["x"])
		var k: float = 3.0 if bool(v["zig"]) else 5.0
		var nlp: float = float(v["lane_pos"]) + (float(v["target_lane_pos"]) - float(v["lane_pos"])) * (1.0 - exp(-dt * k))
		# rvA (#1 family, 1-2 zig): the weave never checked the player, so a player following it in its lane was
		# driven through sideways. A lateral step into the player's body while they overlap in s is held.
		var nx: float = Cfg.lane_xf(nlp)
		var side_gap: float = (float(v["w"]) + p.w) / 2.0 + 0.15
		if not p.ghost and absf(float(v["s"]) - p.s) < (float(v["len"]) + p.len) / 2.0 + 0.3 \
				and absf(nx - p.x) < side_gap and absf(nx - p.x) < absf(prev_x - p.x):
			nlp = float(v["lane_pos"])
		v["lane_pos"] = nlp
		v["x"] = Cfg.lane_xf(float(v["lane_pos"]))
		var vx: float = (float(v["x"]) - prev_x) / maxf(dt, 1e-4)
		v["yaw"] = -atan2(vx, maxf(3.0, float(v["v"]))) * 0.7
		if v["taunt"] != "" and time > float(v["taunt_until"]):
			v["taunt"] = ""
		if time > float(v["next_taunt"]):
			v["next_taunt"] = time + 3.2 + rng.randf() * 2.4
			var lines: Array = stage.get("taunts", []) if stage.get("taunts") is Array else []
			if not lines.is_empty():
				_say(v, str(lines[rng.randi_range(0, lines.size() - 1)]), 2.2)
		v["flash"] = maxf(0.0, float(v["flash"]) - dt * 9.0)
		v["headlights"] = bool(ctx.get("night", false))

	if fighting and any_alive() and not phases.is_empty():
		var pe: Dictionary = _check_phase(ctx)
		if not pe.is_empty():
			events.append(pe)

	if fighting and any_alive() and hold <= 0.0:
		attack_t -= dt
		if attack_t <= 0.0:
			var iv: Array = stage.get("attackInterval") if stage.get("attackInterval") is Array else [2.5, 3.5]
			if beh != null and "interval" in beh and (beh.get("interval") as Array).size() == 2:
				iv = beh.get("interval")
			attack_t = (float(iv[0]) + rng.randf() * (float(iv[1]) - float(iv[0]))) * interval_mul
			var al: Array[Dictionary] = alive()
			var v: Dictionary = al[rng.randi_range(0, al.size() - 1)]
			if float(v["stun_skill"]) <= 0.0 and not (beh != null and beh.has_method(&"blocked") and bool(beh.call(&"blocked", self, v))):
				var peaceful: bool = stage.get("honkOnly") == true or attacks.is_empty()
				var behind: String = "throw"
				if beh != null and "has_behind_attack" in beh and bool(beh.get("has_behind_attack")):
					behind = str(beh.get("behind_attack"))
				var kind: String = ""
				if bool(ctx.get("player_behind", false)):
					kind = "" if peaceful else behind
				elif beh != null and beh.has_method(&"choose"):
					kind = str(beh.call(&"choose", self, v))
					if kind == "":
						kind = _choose_attack()
				else:
					kind = _choose_attack()
				if kind != "":
					_attack(kind, v, ctx)

	# beams
	for i: int in range(beams.size() - 1, -1, -1):
		var b: Dictionary = beams[i]
		if not b.has("aimed"):
			b["aimed"] = player_in_lanes(p, b["lanes"])
		b["t"] = float(b["t"]) + dt
		b["life"] = float(b["life"]) - dt
		var bv: Dictionary = villains[int(b["vi"])]
		if float(b["t"]) < float(b["tele"]):
			bv["headlights"] = int(float(b["t"]) * 12.0) % 2 == 0
		elif float(b["t"]) < float(b["tele"]) + float(b["on"]):
			bv["headlights"] = true
			if not bool(b["hit"]) and fighting and p.invuln <= 0.0 and player_in_lanes(p, b["lanes"]) \
					and p.s > float(bv["s"]) and p.s - float(bv["s"]) < 32.0:
				b["hit"] = true
				events.append({"type": "player_hit", "cause": "highbeam", "text": "눈부셔!!", "flash": true})
		elif not b.has("res"):
			b["res"] = true
			if bool(b["aimed"]) and not bool(b["hit"]) and fighting and not player_in_lanes(p, b["lanes"]):
				events.append({"type": "dodge", "kind": "highbeam", "id": int(b["vi"])})
		if float(b["life"]) <= 0.0:
			beams.remove_at(i)

	# waves
	var rv: float = ref_v()
	for i: int in range(waves.size() - 1, -1, -1):
		var wv: Dictionary = waves[i]
		if not wv.has("aimed"):
			wv["aimed"] = player_in_lanes(p, wv["lanes"])
		var prev_s: float = float(wv["s"])
		wv["s"] = prev_s + (rv + float(wv["speed"])) * dt
		wv["life"] = float(wv["life"]) - dt
		wv["age"] = float(wv["age"]) + dt
		if not bool(wv["hit"]) and p.invuln <= 0.0 and fighting:
			if prev_s <= p.s + p.len / 2.0 and float(wv["s"]) >= p.s - p.len / 2.0 and player_in_lanes(p, wv["lanes"]):
				wv["hit"] = true
				events.append({"type": "player_hit", "cause": str(wv["kind"]), "text": "콜록콜록!" if wv["kind"] == "smoke" else "고막 테러!"})
		if not wv.has("res") and prev_s <= p.s + p.len / 2.0 and float(wv["s"]) >= p.s - p.len / 2.0:
			wv["res"] = true
			if bool(wv["aimed"]) and not bool(wv["hit"]) and fighting and not player_in_lanes(p, wv["lanes"]):
				events.append({"type": "dodge", "kind": str(wv["kind"]), "id": -1})
		if float(wv["life"]) <= 0.0 or float(wv["s"]) > p.s + 30.0:
			waves.remove_at(i)

	# items
	for i: int in range(items.size() - 1, -1, -1):
		var it: Dictionary = items[i]
		if not it.has("aimed"):
			it["aimed"] = p.occupies(int(it["lane"]))
		if not bool(it["landed"]):
			it["t"] = float(it["t"]) + dt
			if float(it["t"]) >= float(it["dur"]):
				it["landed"] = true
				if not bool(it["rolling"]):
					if p.invuln <= 0.0 and (fighting or bool(it["from_mini"])) and p.occupies(int(it["lane"])) \
							and absf(float(it["s"]) - p.s) < p.len / 2.0 + 1.6:
						var ik: String = str(it["kind"])
						events.append({"type": "player_hit", "cause": ik, "mini": bool(it["from_mini"]),
							"text": "커피 테러!" if ik == "cup" else "앗 뜨거!" if ik == "butt" else "폰 투척?!" if ik == "phone" else "으악!"})
					elif bool(it["aimed"]) and fighting and not bool(it["from_mini"]) and not p.occupies(int(it["lane"])):
						events.append({"type": "dodge", "kind": str(it["kind"]), "id": -1})
					items.remove_at(i)
					continue
		else:
			it["roll_t"] = float(it["roll_t"]) + dt
			it["s"] = float(it["s"]) + (rv + float(it["roll"])) * dt
			if p.invuln <= 0.0 and fighting and p.occupies(int(it["lane"])) and absf(float(it["s"]) - p.s) < p.len / 2.0 + float(it["len"]) / 2.0:
				var rk: String = str(it["kind"])
				events.append({"type": "player_hit", "cause": rk, "text": "수박 볼링!" if rk == "watermelon" else "건초 직격!" if rk == "hay" else "으악!"})
				items.remove_at(i)
				continue
			if float(it["s"]) > p.s + 6.0:
				it["marker"] = false
			if float(it["s"]) > p.s + 30.0 or (not fighting and not bool(it["from_mini"])):
				items.remove_at(i)
	var out: Array[Dictionary] = pending
	pending = []
	out.append_array(events)
	return out


## boss.js dangerLanes (autopilot).
func danger_lanes(p: PlayerSim) -> Dictionary:
	var d: Dictionary = {}
	for wv: Dictionary in waves:
		if float(wv["s"]) < p.s + 3.0 and float(wv["s"]) > p.s - 26.0:
			for ln: Variant in wv["lanes"]:
				d[int(ln)] = true
	for b: Dictionary in beams:
		if float(b["t"]) < float(b["tele"]) + float(b["on"]):
			for ln: Variant in b["lanes"]:
				d[int(ln)] = true
	for it: Dictionary in items:
		if not bool(it["rolling"]) and not bool(it["landed"]):
			d[int(it["lane"])] = true
		if bool(it["rolling"]) and float(it["s"]) < p.s + 3.0 and float(it["s"]) > p.s - 22.0:
			d[int(it["lane"])] = true
	for v: Dictionary in villains:
		if bool(v["alive"]) and not (v["lunge"] as Dictionary).is_empty() and str((v["lunge"] as Dictionary)["phase"]) != "back":
			for ln: int in BossSim.lanes_of(v):
				d[ln] = true
	return d


## Current telegraph of a villain for the view/HUD: highbeam | lunge | horn | throw | "" (StringName).
func tell_of(v: Dictionary) -> StringName:
	var L: Dictionary = v["lunge"]
	if not L.is_empty() and str(L["phase"]) != "back":
		return &"lunge"
	for b: Dictionary in beams:
		if int(b["vi"]) == int(v["index"]) and float(b["t"]) < float(b["tele"]) + float(b["on"]):
			return &"highbeam"
	if not waves.is_empty():
		return &"horn"
	for it: Dictionary in items:
		if not bool(it["landed"]) and not bool(it["from_mini"]):
			return &"throw"
	return &""


## R1: the whole phase-applied boss state (attack table, intervalMul, phase index, per-villain hp/tires/movement
## personality and lane position, signature state). Hazards in flight are not kept.
func snapshot() -> Dictionary:
	return {"villains": villains.duplicate(true), "attacks": attacks.duplicate(), "interval_mul": interval_mul,
		"phase_idx": phase_idx, "parked": parked, "sig": sig.duplicate(true)}


## Restores snapshot() onto a freshly spawned boss. Longitudinal position stays anchored to the re-spawned jam
## front (the traffic is re-spawned around it); everything else comes from the snapshot.
const _KEEP_FRESH: Array[String] = ["base_s", "s", "lunge_off", "lunge", "lunge_at", "return_at", "v", "taunt", "taunt_until",
	"next_taunt", "flash", "death_t", "launched", "y", "vel_y", "vel_s", "vel_x", "rot", "headlights", "stun_skill", "stun_chain",
	"stun_immune", "recoil"]


func restore(snap: Dictionary) -> void:
	var sv: Array = snap.get("villains", [])
	for i: int in mini(sv.size(), villains.size()):
		var src: Dictionary = sv[i]
		var dst: Dictionary = villains[i]
		for k: Variant in src.keys():
			if not _KEEP_FRESH.has(str(k)):
				dst[k] = src[k] if not (src[k] is Array or src[k] is Dictionary) else (src[k] as Variant).duplicate(true)
		dst["x"] = Cfg.lane_xf(float(dst["lane_pos"]))
		dst["v"] = dst["v_nominal"]
		if not bool(src["alive"]):
			dst["alive"] = false
			dst["gone"] = true
			dst["dying"] = false
			dst["hp"] = 0.0
	attacks = (snap.get("attacks", attacks) as Dictionary).duplicate()
	interval_mul = float(snap.get("interval_mul", interval_mul))
	phase_idx = int(snap.get("phase_idx", phase_idx))
	parked = int(snap.get("parked", parked))
	var s2: Dictionary = (snap.get("sig", {}) as Dictionary).duplicate(true)
	if s2.has("relay"):
		s2["relay"] = {}
	if s2.has("stun"):
		s2["stun"] = 0.0
	if not s2.is_empty():
		sig = s2
	beams.clear()
	waves.clear()
	items.clear()
