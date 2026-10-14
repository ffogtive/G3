extends RefCounted
## One touch-driven 1-1 on the real game.tscn (view/game.gd wiring), shared by test_e2e_touch_skills (headless checks)
## and shot_game_skills (Xvfb frames of each skill moment). The autopilot drives the approach; a "human" takes over
## with InputEventScreenTouch on the HUD button rects (Viewport.push_input, canvas coordinates):
##   jam: 분노 tap → t1_horn (+ rage_horn) · fight (압정 held by finger 0 the whole time): 분노 → t1_wave, item1 → mv_jump,
##   분노 → t3_carpet, item2 → mv_drone, 분노 → t5_finish (execute) → finisher → open-screen tap → skip → release → result.
## Rage is topped up to the tier's segment count when the run has not earned it yet (the economy is test_e2e_skills'
## job; this run proves the wiring), and the villain HP is capped under the execute line for the t5 when needed.
## Steering is by touch too (◀ ▶ taps, dodging the telegraphed lanes like Autopilot._fight).
##
## 가설: ❓ every tier and item is reachable by touch in one 1-1, each cast reaches Hud / FightFx (SkillFx + SkillCues) /
##       CameraRig, 압정 never honks, and holding 압정 never blocks a 분노 / item tap (multi-touch).

const FRAME: int = 4

var g: Game
var vp: Viewport
## Optional coroutine (name: String) -> void, awaited at each skill moment (shots capture a frame there).
var moment: Callable = Callable()
var events: Array[Dictionary] = []
var notes: Dictionary = {}           # step → {ok, ...} for the checks
var topped: PackedStringArray = []   # what had to be forced (rage / hp)
var horn_down_seen: bool = false
var fire_drop_seen: bool = false     # 압정 not held at a moment it should have been
var hint_mismatch: int = 0           # frames where the HUD "탭: 건너뛰기" hint and the sim's skip_ready disagreed
var errors: PackedStringArray = []
var _human: bool = false
var _hold_fire: bool = false
var _next_steer: float = 0.0
var _pilot: Autopilot


func _init(p_game: Game, p_vp: Viewport) -> void:
	g = p_game
	vp = p_vp
	g.event_tap = func(e: Dictionary) -> void:
		var c: Dictionary = e.duplicate()
		c["_rt"] = g.sim.real_time
		c["_ph"] = "%s%s%s" % [g.sim.phase, "+lock" if g.sim.front_locked else "", "" if _human else "/pilot"]
		events.append(c)


# ── touches ───────────────────────────────────────────────────────────────────────────────────────

func touch(idx: int, pos: Vector2, pressed: bool) -> void:
	var t := InputEventScreenTouch.new()
	t.index = idx
	t.position = pos
	t.pressed = pressed
	vp.push_input(t, true)
	if idx == 0:  # the OS's emulated-mouse twin of finger 0 (LaneInput must ignore it)
		var mb := InputEventMouseButton.new()
		mb.button_index = MOUSE_BUTTON_LEFT
		mb.pressed = pressed
		mb.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		mb.device = InputEvent.DEVICE_ID_EMULATION
		mb.position = pos
		mb.global_position = pos
		vp.push_input(mb, true)


func zone(name: String) -> Rect2:
	g.hud._process(0.0)  # (re)registers the zones when the layout changed (item slots appear with the loadout)
	return g.input._zones.get(name, Rect2()) as Rect2


## Finger down on the zone's centre, `hold` ticks, finger up (a 분노 hold must still be one tap).
func tap(idx: int, name: String, hold: int = 1) -> bool:
	var r: Rect2 = zone(name)
	if not r.has_area():
		errors.append("no zone %s" % name)
		return false
	touch(idx, r.get_center(), true)
	if hold <= 1:
		g.advance_ticks(1)
	else:
		for i: int in hold / FRAME:
			adv()
	touch(idx, r.get_center(), false)
	return true


## Pairs of registered LaneInput zones that overlap (must be none: a 압정 / item / 분노 touch can never be the horn).
func zone_overlaps() -> PackedStringArray:
	zone("fire")
	var out: PackedStringArray = []
	var zs: Dictionary = g.input._zones
	for a: String in zs:
		for b: String in zs:
			if a < b and (zs[a] as Rect2).has_area() and (zs[b] as Rect2).has_area() and (zs[a] as Rect2).intersects(zs[b] as Rect2):
				out.append("%s×%s" % [a, b])
	return out


## A point on the open screen (inside the safe rect, in no zone): the skip tap.
func open_point() -> Vector2:
	var sr: Rect2 = g.hud.safe_rect()
	for fy: float in [0.42, 0.5, 0.35, 0.6]:
		var p := Vector2(sr.get_center().x, sr.position.y + sr.size.y * fy)
		if g.input._zone_at(p) == "":
			return p
	return sr.get_center()


# ── time ──────────────────────────────────────────────────────────────────────────────────────────

func adv(ticks: int = FRAME) -> void:
	g.advance_ticks(ticks)
	var au: Node = g.audio
	if au != null and au.has_method(&"advance"):
		au.call(&"advance", ticks / 120.0)
	horn_down_seen = horn_down_seen or (_human and g.input.is_horn_down())
	if g.hud.skip_hint_visible() != g.sim.skills.skip_ready(g.sim):
		hint_mismatch += 1
	if _human:
		_steer()


func until(cond: Callable, limit_s: float) -> bool:
	var end: float = g.sim.real_time + limit_s
	while g.sim.real_time < end:
		adv()
		if bool(cond.call()):
			return true
	return false


func at(name: String) -> void:
	if moment.is_valid():
		await moment.call(name)


func ev_since(i0: int, type: String, key: String = "", val: Variant = null) -> Dictionary:
	for i: int in range(i0, events.size()):
		var e: Dictionary = events[i]
		if str(e.get("type", "")) == type and (key.is_empty() or e.get(key) == val):
			return e
	return {}


func count(type: String, key: String = "", val: Variant = null) -> int:
	var n: int = 0
	for e: Dictionary in events:
		if str(e.get("type", "")) == type and (key.is_empty() or e.get(key) == val):
			n += 1
	return n


# ── the human ─────────────────────────────────────────────────────────────────────────────────────

func hand_over() -> void:
	_pilot = g.sim.autopilot
	g.sim.autopilot = null
	g.autoplay = false
	g.sim.input(&"fire", false)
	_human = true


func give_back() -> void:
	_human = false
	if _hold_fire:
		hold_fire(false)
	g.sim.input(&"fire", false)
	if _pilot != null:
		_pilot.fire = false
		_pilot.next_t = 0.0
		g.sim.autopilot = _pilot
	g.autoplay = true


func hold_fire(on: bool) -> void:
	if on == _hold_fire:
		return
	_hold_fire = on
	touch(0, zone("fire").get_center(), on)


## Autopilot._fight's lane choice, sent as ◀ ▶ taps (finger 2): stay beside the villain, out of telegraphed lanes.
func _steer() -> void:
	var sim: GameSim = g.sim
	if sim.phase != &"boss" or not sim.front_locked or sim.real_time < _next_steer or sim.player.lc_t < 1.0:
		return
	var al: Array[Dictionary] = sim.boss.alive()
	if al.is_empty():
		return
	var p: PlayerSim = sim.player
	var danger: Dictionary = sim.boss.danger_lanes(p)
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
		_next_steer = sim.real_time + 0.25
		tap(2, "left" if want < p.lane else "right")


## Rage to exactly the tier's segments when the run has fewer (or would cast a higher tier than asked).
func want_tier(tier: int) -> void:
	var sk: SkillsSim = g.sim.skills
	var sg: int = sk.segs(g.sim)
	var nxt: int = 5 if sg >= 5 else (3 if sg >= 3 else (1 if sg >= 1 else 0))
	if g.sim.is_jam_like():
		nxt = 1 if sg >= 1 else 0
	if nxt != tier:
		topped.append("rage %d→%d segs (t%d)" % [sg, tier, tier])
		g.sim.rage = float(tier) / float(g.sim.tune.get("rageSegs", 5)) + 0.001
	adv(1)


## Tap 분노 (finger 1, 압정 still held) and wait for the cast. Returns its skill_start ({} = none).
func cast_rage(tier: int, label: String, hold: int = 1) -> Dictionary:
	var i0: int = events.size()
	var face: int = g.hud.next_tier
	if not tap(1, "rage", hold):
		return {}
	var started: bool = until(func() -> bool: return not ev_since(i0, "skill_start", "chan", "rage").is_empty(), 0.5)
	var e: Dictionary = ev_since(i0, "skill_start", "chan", "rage")
	notes[label] = {"ok": started and int(e.get("tier", 0)) == tier, "tier": int(e.get("tier", 0)), "id": str(e.get("id", "")),
		"face": face, "fire_held": g.input.is_fire_down() or not _hold_fire, "i0": i0}
	if _hold_fire and not g.input.is_fire_down():
		fire_drop_seen = true
	return e


func cast_item(slot: int, label: String) -> Dictionary:
	var i0: int = events.size()
	if not tap(2 if slot == 1 else 1, "item%d" % slot):
		return {}
	var started: bool = until(func() -> bool: return not ev_since(i0, "skill_start", "chan", "item").is_empty(), 0.5)
	var e: Dictionary = ev_since(i0, "skill_start", "chan", "item")
	notes[label] = {"ok": started, "id": str(e.get("id", "")), "fire_held": g.input.is_fire_down() or not _hold_fire, "i0": i0}
	if _hold_fire and not g.input.is_fire_down():
		fire_drop_seen = true
	return e


func wait_hit(i0: int, id: String, limit_s: float = 2.0) -> Dictionary:
	until(func() -> bool: return not ev_since(i0, "skill_hit", "id", id).is_empty(), limit_s)
	return ev_since(i0, "skill_hit", "id", id)


func free_rage() -> void:
	until(func() -> bool: return not g.sim.skills.busy("rage"), 3.0)


# ── the run ───────────────────────────────────────────────────────────────────────────────────────

func run() -> void:
	var sim: GameSim = g.sim
	# 1. jam t1 (분노 경적) by touch
	if not until(func() -> bool: return g.phase == &"jam" and sim.phase_real > 2.5, 40.0):
		errors.append("never reached the jam")
		return
	hand_over()
	want_tier(1)
	var h0: int = count("honk")
	var e: Dictionary = cast_rage(1, "jam_t1")
	await at("jam_t1_cast")
	until(func() -> bool: return not ev_since(int((notes["jam_t1"] as Dictionary)["i0"]), "rage_horn").is_empty(), 0.5)
	(notes["jam_t1"] as Dictionary)["rage_horn"] = not ev_since(int((notes["jam_t1"] as Dictionary)["i0"]), "rage_horn").is_empty()
	adv(12)
	await at("jam_t1_wave")
	# 압정 in the jam (no mini in range usually): never a honk
	hold_fire(true)
	adv(60)
	hold_fire(false)
	notes["jam_fire_honks"] = count("honk") - h0
	give_back()
	# 2. autopilot to the locked fight, in range
	if not until(func() -> bool: return g.phase == &"boss" and sim.front_locked and bool((g.st["lock"] as Dictionary).get("in_range", false)), 100.0):
		errors.append("never locked in range")
		return
	hand_over()
	h0 = count("honk")
	notes["zones"] = {"overlaps": zone_overlaps(), "items": zone("item1").has_area() and zone("item2").has_area()}
	hold_fire(true)
	adv(30)
	await at("fight_lock")
	# t1 분노 경적 (fight: wave + stun window)
	free_rage()
	want_tier(1)
	e = cast_rage(1, "t1")
	await at("t1_cast")
	var hit: Dictionary = wait_hit(int((notes["t1"] as Dictionary)["i0"]), str(e.get("id", "t1_wave")), 1.0)
	(notes["t1"] as Dictionary)["hit"] = not hit.is_empty()
	await at("t1_hit")
	# item1 참교육 점프 (left thumb) while 압정 is held
	until(func() -> bool: return sim.skills.item_ready(sim, 1), 7.0)
	e = cast_item(1, "jump")
	adv(maxi(1, roundi(float(((sim.skills.cfg.get("items", {}) as Dictionary).get("mv_jump", {}) as Dictionary).get("hop", 0.75)) * 0.5 / Cfg.TICK) - 1))
	await at("jump_air")  # the apex (hop × 0.5 after the cast; rvB: +16 ticks was barely off the road)
	hit = wait_hit(int((notes["jump"] as Dictionary)["i0"]), "mv_jump", 1.5)
	(notes["jump"] as Dictionary)["hit"] = not hit.is_empty()
	await at("jump_land")
	# t3 압정 폭격
	free_rage()
	want_tier(3)
	e = cast_rage(3, "t3", 24)  # held 0.2 s: still one cast
	await at("t3_cast")
	hit = wait_hit(int((notes["t3"] as Dictionary)["i0"]), str(e.get("id", "t3_carpet")), 1.5)
	(notes["t3"] as Dictionary)["hit"] = not hit.is_empty()
	(notes["t3"] as Dictionary)["fx"] = g.fx.counts()
	await at("t3_hit")
	adv(36)
	await at("t3_after")
	# item2 드론 폭격 (right thumb) — finger 0 keeps 압정 down
	until(func() -> bool: return sim.skills.item_ready(sim, 2) and not sim.skills.busy("item"), 7.0)
	e = cast_item(2, "drone")
	await at("drone_cast")
	hit = wait_hit(int((notes["drone"] as Dictionary)["i0"]), "mv_drone", 2.5)
	(notes["drone"] as Dictionary)["hit"] = not hit.is_empty()
	await at("drone_hit")
	# t5 참교육 (execute): after minKillT, villain under the execute line, MAX rage
	var min_kill: float = float(sim.skills.cfg.get("minKillT", 6.0)) + 0.1
	var ex: float = float((sim.skills.cfg.get("t5", {}) as Dictionary).get("execute", 0.4))
	until(func() -> bool:
		if sim.boss.hp_frac() < ex + 0.05:
			hold_fire(false)  # don't let a tack take the kill before the MAX
		return sim.boss_clock >= min_kill and not sim.skills.busy("rage") and not sim.skills.busy("item"), 12.0)
	if not sim.boss.any_alive():
		errors.append("villain died before the t5")
		return
	if sim.boss.hp_frac() > ex - 0.02:
		topped.append("villain hp %.2f→%.2f (execute line %.2f)" % [sim.boss.hp_frac(), ex - 0.05, ex])
		for v: Dictionary in sim.boss.villains:
			if bool(v.get("alive", false)):
				v["hp"] = float(v["max_hp"]) * (ex - 0.05)
	want_tier(5)
	var face_ex: float = g.hud.execute_frac
	e = cast_rage(5, "t5")
	(notes["t5"] as Dictionary)["execute_line"] = face_ex
	await at("t5_cast")
	adv(maxi(1, roundi(SkillCues.impact_delay("t5") * 0.55 * 120.0) - 1))  # the charge, before the impact tick
	await at("t5_charge")
	hit = wait_hit(int((notes["t5"] as Dictionary)["i0"]), "t5_finish", 2.0)
	(notes["t5"] as Dictionary)["hit"] = not hit.is_empty()
	(notes["t5"] as Dictionary)["killed"] = bool(hit.get("killed", false))
	await at("t5_impact")
	var i5: int = int((notes["t5"] as Dictionary)["i0"])
	until(func() -> bool: return not ev_since(i5, "finisher").is_empty(), 1.5)
	var fin: Dictionary = ev_since(i5, "finisher")
	hold_fire(false)
	notes["finisher"] = {"ok": not fin.is_empty(), "id": str(fin.get("id", "")), "cam": g.camera.finish_id, "hud": g.hud.finish_id,
		"fx": g.fx.counts(), "cues": g.fx.cues.cue_log.duplicate()}
	adv(24)
	await at("finish_a")
	adv(36)
	await at("finish_b")
	# skip: one tap on the open screen once the HUD / sim allow it
	var armed: bool = until(func() -> bool: return g.input.skip_armed, 3.0)
	var is0: int = events.size()
	var p: Vector2 = open_point()
	touch(3, p, true)
	adv(1)
	touch(3, p, false)
	until(func() -> bool: return not ev_since(is0, "skip").is_empty(), 0.3)
	notes["skip"] = {"ok": armed and not ev_since(is0, "skip").is_empty(), "armed": armed, "what": str(ev_since(is0, "skip").get("what", ""))}
	await at("skip")
	notes["fight_honks"] = count("honk") - h0
	give_back()
	if not until(func() -> bool: return g.phase == &"release", 6.0):
		errors.append("no release after the kill")
	adv(30)
	await at("release")
	if not until(func() -> bool: return g.phase == &"result" and g.hud.card_open(), 90.0):
		errors.append("no result card")
	await at("result")
