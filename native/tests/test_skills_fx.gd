extends RefCounted
## T0: skill presentation contracts (docs/SKILLS.md 2-3, 2-4, 3-3, 4, 7-1 "계약", 7-2 kill-cam rules).
## 가설: ❓ the skill juice stays readable and cheap if every cue is data the tests can see — each haptic / SFX name a
##       recipe uses exists, every event shape of §6 drives FightFx / HUD / camera / cues without a script error and
##       inside the particle (700 / 700 / 220) and decal (8) caps, the kill cam keeps the road on screen (≥ 35 %, look y
##       ≤ 4.5, tilt ≤ 12°, orbit ≤ 30°), FX run on sim time (hit-stop freezes them), and the real SkillsSim events —
##       on the C++ traffic and on the iPhone's GDScript fallback — play end to end into a finisher.

const _DB := preload("res://core/db.gd")
const TICK: float = 1.0 / 120.0

var _fails: int = 0


func _check(ok: bool, what: String) -> void:
	print(("PASS" if ok else "FAIL") + " skills_fx: " + what)
	if not ok:
		_fails += 1


func run() -> int:
	var tree := Engine.get_main_loop() as SceneTree
	_contracts()
	await _fx_events(tree)
	await _hud(tree)
	_killcam()
	await _cues(tree)
	var modes: Array[bool] = [true]
	if TrafficBridge.native_available():
		modes.push_front(false)
	else:
		print("SKIP skills_fx: native traffic ext not loaded (fallback path only)")
	for fb: bool in modes:
		await _real_sim(tree, fb)
	return _fails


# ───────────────────────────── 1. data contracts

func _contracts() -> void:
	var hap: Dictionary = (_DB.load_json("res://data/haptics.json") as Dictionary).get("events", {})
	var names: Dictionary = {"skillT5Charge": true, "laneChange": true, "skillDenied": true, "tierReady1": true,
		"tierReady3": true, "tirePop": true, "rageHit": true}
	for v: Variant in SkillCues.HAPTIC_HIT.values():
		names[str(v)] = true
	for rows: Variant in SkillCues.FINISH.values():
		for r: Array in rows:
			if str(r[1]) == "haptic":
				names[str(r[2])] = true
	for n: String in ["skillT1", "skillT3Hit", "skillT5Charge", "skillT5Impact", "tierReady1", "tierReady3", "skillDenied",
			"itemJumpLand", "itemDrone", "itemTow", "finishRocket", "finishBalloon", "finishHeli", "finishUfo"]:
		names[n] = true
	var missing: PackedStringArray = []
	var bad: PackedStringArray = []
	var hs: GDScript = load("res://autoload/haptics.gd")
	for n: String in names:
		if not hap.has(n):
			missing.append(n)
			continue
		var spec: Dictionary = hap[n]
		var ahap: Dictionary = hs.call(&"build_ahap", spec.get("ios", []))
		var generator: bool = (spec.get("ios", []) as Array).size() > 0 and str(((spec["ios"] as Array)[0] as Dictionary).get("type", "")) in ["selection", "impactLight", "impactMedium", "impactHeavy", "impactSoft", "impactRigid"]
		if ((ahap.get("Pattern", []) as Array).is_empty() and not generator) or not (spec.get("android") is Array) or (spec["android"] as Array).is_empty():
			bad.append(n)
	_check(missing.is_empty() and bad.is_empty(), "every skill haptic is in data/haptics.json with ios (AHAP) + android (%d names; missing %s, empty %s)" % [names.size(), missing, bad])
	var man: Dictionary = (_DB.load_json("res://audio/audio_bake.json") as Dictionary).get("sfx", {})
	var sfx: Dictionary = {}
	for st: Variant in SkillCues.DEFAULT.values():
		for r: Array in st:
			sfx[str(r[0])] = true
	for lay: Variant in SkillCues.LAYERS.values():
		for k: String in lay:
			for r: Array in (lay as Dictionary)[k]:
				sfx[str(r[0])] = true
	for rows: Variant in SkillCues.FINISH.values():
		for r: Array in rows:
			if str(r[1]) == "sfx":
				sfx[str(r[2])] = true
	var fxc: Variant = SkillCues.cfg().get("fx", {})
	if fxc is Dictionary:
		for key: String in fxc:
			if (fxc as Dictionary)[key] is Dictionary and ((fxc as Dictionary)[key] as Dictionary).get("sfx") is Array:
				for r: Array in ((fxc as Dictionary)[key] as Dictionary)["sfx"]:
					sfx[str(r[0])] = true
	for n: String in ["sk_charge", "sk_carpet", "sk_drone", "sk_land", "sk_wave", "sk_tier1", "sk_tier3", "sk_tierMax",
			"fin_rocket", "fin_balloon", "fin_heli", "fin_ufo", "bump", "twinkle"]:
		sfx[n] = true
	var nos: PackedStringArray = []
	for n: String in sfx:
		var aliased: String = n
		if not man.has(aliased):
			nos.append(n)
		elif not FileAccess.file_exists("res://audio/" + str(((man[aliased] as Dictionary).get("files", [""]) as Array)[0])):
			nos.append(n + "(file)")
	_check(nos.is_empty(), "every skill SFX name is baked (audio_bake.json + file; %d names, missing %s)" % [sfx.size(), nos])
	var dur_ok: bool = true
	for n: String in ["fin_rocket", "fin_balloon", "fin_heli", "fin_ufo"]:
		dur_ok = dur_ok and man.has(n) and float((man[n] as Dictionary).get("seconds", 9.0)) <= 2.0
	_check(dur_ok, "finisher stingers ≤ 2 s (SKILLS.md 2-6)")


# ───────────────────────────── 2. FightFx on the §6 event shapes

func _state(ps: float, vs: float, vy: float = 0.0, death_t: float = 0.0, dying: bool = false, gone: bool = false,
		skills: Dictionary = {}) -> Dictionary:
	var st: Dictionary = {"phase": "boss", "t": 0.0, "real_t": 0.0,
		"player": {"s": ps, "x": RoadGraph.lane_x(1.0), "lane": 1, "v": 8.0, "hop": 0.0, "rage": 1.0, "hp": 80, "hp_max": 100},
		"villains": [{"id": 0, "s": vs, "x": RoadGraph.lane_x(0.0), "y": vy, "lane": 0, "lane_pos": 0.0, "len": 4.6, "w": 1.9,
			"hp": 60.0, "hp_max": 140.0, "alive": not dying and not gone, "dying": dying, "gone": gone, "death_t": death_t,
			"color": 0xd9c9a3, "tires": 4, "vulnerable": false, "finish": "rocket", "rot": Vector3.ZERO}],
		"lock": {"active": true, "in_range": true, "target_id": 0}, "projectiles": [], "hazards": {}}
	if not skills.is_empty():
		st["skills"] = skills
	return st


func _caps(fx: FightFx) -> bool:
	var c: Dictionary = fx.counts()
	return int(c["lit"]) <= FightFx.MAX_LIT and int(c["glow"]) <= FightFx.MAX_GLOW and int(c["smoke"]) <= FightFx.MAX_SMOKE \
		and int(c.get("decals", 0)) <= SkillFx.DECALS


func _fx_events(tree: SceneTree) -> void:
	var fx := FightFx.new()
	fx.manual = true
	tree.root.add_child(fx)
	var road := RoadGraph.new()
	fx.setup(road, 7)
	var st: Dictionary = _state(300.0, 288.0)
	fx.sync(st)
	var caps: bool = true
	var shapes: Dictionary = {}
	# t3: 12 tacks + strip, 4 hits, one pop → tack-strip + skid decals
	fx.on_event({"type": "skill_start", "chan": "rage", "tier": 3, "id": "t3_carpet", "target_id": 0, "lanes": PackedInt32Array([0, 1]),
		"dur": 1.2, "cine": false, "s": 288.0, "x": RoadGraph.lane_x(0.0)}, st)
	shapes["tacks"] = int(fx.counts()["tacks"])
	for i: int in 4:
		for k: int in 6:
			fx.advance(1.0 / 60.0)
			fx.sync(st)
		fx.on_event({"type": "skill_hit", "chan": "rage", "tier": 3, "id": "t3_carpet", "target_id": 0, "idx": i, "n": 4, "dmg": 3.0,
			"window": false, "immune": false, "stun": 1.2, "popped": 1 if i == 3 else 0, "killed": false, "hp_frac": 0.5, "s": 288.0,
			"x": RoadGraph.lane_x(0.0)}, st)
		caps = caps and _caps(fx)
	shapes["decals_t3"] = int(fx.counts()["decals"])
	# t1, t5 (no execute), jump, drone — each through start / hits / end
	for spec: Array in [["t1_wave", 1, "rage", 1], ["t5_finish", 5, "rage", 1], ["mv_jump", 0, "item", 1], ["mv_drone", 0, "item", 6]]:
		fx.on_event({"type": "skill_start", "chan": spec[2], "tier": spec[1], "id": spec[0], "target_id": 0, "lanes": PackedInt32Array([0]),
			"dur": 1.0, "cine": spec[0] == "t5_finish", "s": 288.0, "x": RoadGraph.lane_x(0.0)}, st)
		if spec[0] == "mv_drone":
			shapes["drone"] = bool(fx.counts()["drone"])
		for i: int in int(spec[3]):
			fx.advance(0.05)
			fx.sync(st)
			fx.on_event({"type": "skill_hit", "chan": spec[2], "tier": spec[1], "id": spec[0], "target_id": 0, "idx": i, "n": spec[3],
				"dmg": 4.0, "window": true, "immune": false, "stun": 0.6, "popped": 0, "killed": false, "hp_frac": 0.4, "s": 288.0,
				"x": RoadGraph.lane_x(0.0)}, st)
			caps = caps and _caps(fx)
		fx.on_event({"type": "skill_end", "chan": spec[2], "tier": spec[1], "id": spec[0], "skipped": false}, st)
	# a burst storm: 20 t5 impacts in a row must stay inside the caps (oldest particles are recycled)
	for i: int in 20:
		fx.on_event({"type": "skill_hit", "chan": "rage", "tier": 5, "id": "t5_finish", "target_id": 0, "idx": 0, "n": 1, "dmg": 40.0,
			"window": true, "immune": false, "stun": 2.0, "popped": 0, "killed": false, "hp_frac": 0.3, "s": 288.0, "x": 0.0}, st)
		fx.advance(0.016)
		caps = caps and _caps(fx)
	_check(shapes.get("tacks") == 12 and int(shapes.get("decals_t3", 0)) >= 2 and shapes.get("drone") == true,
		"t3 throws 12 caltrops + leaves the tack strip / skid decals, the drone shows (%s)" % JSON.stringify(shapes))
	_check(caps, "particles stay ≤ lit 700 · glow 700 · smoke 220 and decals ≤ 8 through every skill + 20 t5 impacts")
	# finishers: props follow death_t beats; ★ on gone
	var seen: Dictionary = {}
	for fin: String in ["rocket", "balloon", "heli", "ufo"]:
		var beats: Dictionary = SkillCues.finish_beats(fin)
		var done: float = float(beats.get("done", 2.0))
		fx.on_event({"type": "kill", "id": 0, "finish": fin, "last": true, "s": 288.0, "x": RoadGraph.lane_x(0.0)}, st)
		fx.on_event({"type": "finisher", "id": fin, "target_id": 0, "execute": true, "s": 288.0, "x": RoadGraph.lane_x(0.0)}, st)
		var t: float = 0.0
		var props: Array = [false, false, false]
		while t < done:
			t += 1.0 / 30.0
			var y: float = maxf(0.0, (t - float(beats.get("lift", 0.5))) * 4.0)
			var s2: Dictionary = _state(300.0, 288.0 + t * 8.0, y, t, true, false)
			fx.sync(s2)
			fx.advance(1.0 / 30.0)
			var pr: Array = fx.counts()["props"]
			for k: int in 3:
				props[k] = bool(props[k]) or bool(pr[k])
			caps = caps and _caps(fx)
		fx.sync(_state(300.0, 288.0 + t * 8.0, 12.0, t, false, true))
		fx.on_event({"type": "gone", "id": 0, "is_last": true, "finish": fin}, st)
		for k: int in 40:
			fx.advance(1.0 / 30.0)
			fx.sync(_state(300.0, 288.0 + t * 8.0, 12.0, t, false, true))
		seen[fin] = props
	_check(seen["balloon"][0] and seen["heli"][1] and seen["ufo"][2] and not (seen["rocket"] as Array).has(true),
		"finisher props: balloon bundle / police helicopter / UFO show on their beats, rocket has none (%s)" % JSON.stringify(seen))
	_check(str(fx.counts()["finish"]) == "" and fx.counts()["props"] == [false, false, false] and caps,
		"props are cleared after the car is gone; caps held through 4 finishers")
	# sim-scaled time: hit-stop (time_scale 0) freezes _process, slow-mo (t / real_t ratio) slows it
	fx.manual = false
	fx.sync(_state(300.0, 288.0, 0.0, 0.0, false, false, {"time_scale": 0.0}))
	var n0: float = fx.now
	fx._process(0.1)
	var frozen: bool = is_equal_approx(fx.now, n0)
	var a: Dictionary = _state(300.0, 288.0)
	a["t"] = 10.0
	a["real_t"] = 20.0
	fx.sync(a)
	var b: Dictionary = _state(300.0, 288.0)
	b["t"] = 10.03
	b["real_t"] = 20.1
	fx.sync(b)
	var n1: float = fx.now
	fx._process(0.1)
	fx.manual = true
	_check(frozen and absf(fx.time_scale - 0.3) < 1e-3 and absf(fx.now - n1 - 0.03) < 1e-4,
		"FX on sim time: time_scale 0 freezes (Δ %.3f), Δt/Δreal 0.3 slows _process to 0.03 s (%.3f)" % [fx.now - n1, fx.time_scale])
	fx.queue_free()
	await tree.process_frame


# ───────────────────────────── 3. HUD: ring, face, items, pops, skip hint

func _hud(tree: SceneTree) -> void:
	var inp := LaneInput.new()
	tree.root.add_child(inp)
	var hud := Hud.new()
	hud.manual = true
	tree.root.add_child(hud)
	hud.bind_input(inp)
	hud.debug_safe_pt = Vector2(59, 34)
	hud.apply_safe_area()
	var cam := Camera3D.new()
	hud.add_child(cam)
	hud.bind_world(cam, RoadGraph.new())
	var base: Dictionary = UiStubState.boss(true)
	var items: Array = [{"id": "mv_jump", "slot": 1, "charges": -1, "cool": 0.0, "cool_max": 6.0, "ready": true, "usable": true, "reason": ""},
		{"id": "mv_drone", "slot": 2, "charges": -1, "cool": 6.0, "cool_max": 12.0, "ready": false, "usable": true, "reason": ""}]
	var faces: Array[int] = []
	for row: Array in [["jam", 5, [1], 1], ["fight", 2, [1], 1], ["fight", 4, [1, 3], 3], ["fight", 5, [1, 3, 5], 5], ["fight", 0, [], 0]]:
		var st: Dictionary = base.duplicate(true)
		st["skills"] = {"segs": row[1], "rage_tiers_ready": row[2], "next_tier": row[3], "mode": row[0],
			"execute_frac": 0.4 if (row[2] as Array).has(5) else 0.0, "active": {}, "items": items, "time_scale": 1.0}
		(st["player"] as Dictionary)["rage"] = float(row[1]) / 5.0
		hud.apply_state(st)
		faces.append(hud.next_tier)
	_check(faces == [1, 1, 3, 5, 0] and hud.execute_frac == 0.0, "분노 face = state.skills.next_tier (jam MAX → 경적) %s" % str(faces))
	var st5: Dictionary = base.duplicate(true)
	st5["skills"] = {"segs": 5, "rage_tiers_ready": [1, 3, 5], "next_tier": 5, "mode": "fight", "execute_frac": 0.4, "active": {},
		"items": items, "time_scale": 1.0}
	(st5["player"] as Dictionary)["rage"] = 1.0
	hud.apply_state(st5)
	for i: int in 30:
		hud.advance(1.0 / 30.0)
	await tree.process_frame
	hud._process(0.0)
	var sz: Dictionary = hud.item_sizes_pt()
	var z1: Rect2 = inp._zones.get("item1", Rect2())
	var z2: Rect2 = inp._zones.get("item2", Rect2())
	_check(hud._btn_items[0].visible and hud._btn_items[1].visible and sz.size() == 2 and float(sz["item1"]) >= 64.0
		and z1.has_area() and z2.has_area(), "item buttons shown ≥ 64 pt with touch zones (%s)" % JSON.stringify(sz))
	var rects: Array[Control] = [hud._btn_left, hud._btn_right, hud._btn_horn, hud._btn_fire, hud._btn_rage, hud._hp_row, hud._gauge,
		hud._chip, hud._btn_items[0], hud._btn_items[1]]
	var overl: PackedStringArray = []
	for i: int in rects.size():
		for j: int in range(i + 1, rects.size()):
			if rects[i].get_global_rect().intersects(rects[j].get_global_rect()):
				overl.append("%d×%d" % [i, j])
	var sr: Rect2 = hud.safe_rect().grow(4.5)
	var inside: bool = true
	for r: Rect2 in hud.reserved_rects():
		inside = inside and sr.encloses(r)
	_check(overl.is_empty() and inside, "with items: no bottom widget overlaps another, all inside the safe rect (%s)" % " ".join(overl))
	_check(hud.execute_frac == 0.4, "t5 ready in the fight → 처형선 at 0.4 on the boss bar")
	# events: t5 stamp banner + focus lines, t3 4 ticks → 3 ticks + 1 summed pop, 한 번 더!, denied reason, skip hint
	hud.on_event({"type": "skill_start", "chan": "rage", "tier": 5, "id": "t5_finish", "target_id": 0, "dur": 2.5, "cine": true, "s": 254.9, "x": -6.45})
	var stamp: bool = hud.banner.current() == "참교육!!" and hud.banner.kind() == "stamp"
	var p0: int = hud.pops._pops.size()
	for i: int in 4:
		hud.on_event({"type": "skill_hit", "chan": "rage", "tier": 3, "id": "t3_carpet", "target_id": 0, "idx": i, "n": 4, "dmg": 3.0,
			"window": false, "immune": false, "popped": 0, "killed": false, "s": 254.9, "x": -6.45})
	var kinds: Array = []
	for p: Dictionary in hud.pops._pops.slice(p0):
		kinds.append(str(p["kind"]))
	hud.on_event({"type": "skill_hit", "chan": "rage", "tier": 5, "id": "t5_finish", "target_id": 0, "idx": 0, "n": 1, "dmg": 42.0,
		"window": true, "immune": false, "popped": 0, "killed": false, "s": 254.9, "x": -6.45})
	var texts: PackedStringArray = []
	for p: Dictionary in hud.pops._pops:
		texts.append(str(p["text"]))
	hud.on_event({"type": "skill_denied", "chan": "rage", "tier": 5, "id": "", "reason": "rage"})
	var denied: bool = hud.pops._pops.back()["text"] == "분노 부족!"
	_check(stamp and kinds == ["tick", "tick", "tick", "big"] and texts.has("-42!") and texts.has("한 번 더!") and denied,
		"t5 → stamp '참교육!!'; t3 → 3 ticks + 1 summed '-12'; t5 no kill → '-42!' + '한 번 더!'; denied → '분노 부족!' (%s %s)" % [kinds, texts])
	hud.apply_state(UiStubState.kill())
	hud.on_event({"type": "kill", "id": 0, "last": true, "s": 254.9, "x": -6.45})
	var early: bool = hud.skip_hint_visible()
	hud.advance(0.7)
	_check(not early and hud.skip_hint_visible(), "'탭: 건너뛰기' only after finish.skipAfter in the kill")
	hud.queue_free()
	inp.queue_free()
	await tree.process_frame


# ───────────────────────────── 4. kill-cam rules per finish

func _killcam() -> void:
	var cam := CameraRig.new()
	var bad: PackedStringArray = []
	var info: PackedStringArray = []
	for fin: String in ["rocket", "balloon", "heli", "ufo", "pullover"]:
		cam.finish_id = fin
		cam.kill_side = CameraRig.shot_side(RoadGraph.lane_x(0.0))
		var beats: Dictionary = SkillCues.finish_beats(fin)
		var done: float = float(beats.get("done", 2.0))
		var p0: Array[Vector3] = []
		var pitch0: float = 0.0
		var yaw0: float = 0.0
		var max_tilt: float = 0.0
		var max_orbit: float = 0.0
		var min_road: float = 1.0
		var max_look: float = 0.0
		var t: float = 0.0
		while t <= done + 1e-4:
			var y: float = maxf(0.0, (t - float(beats.get("lift", 0.5))) * 12.0)  # a car climbing 12 m/s (rocket-like)
			cam.kill_target = Vector3(RoadGraph.lane_x(0.0), y + 0.6, -300.0 - t * 8.0)
			var pose: Array[Vector3] = cam.finish_pose(t)
			var d: Vector3 = (pose[1] - pose[0]).normalized()
			var pitch: float = rad_to_deg(asin(d.y))
			var yaw: float = rad_to_deg(atan2(d.x, -d.z))
			if p0.is_empty():
				p0 = pose
				pitch0 = pitch
				yaw0 = yaw
			max_tilt = maxf(max_tilt, pitch - pitch0)
			max_orbit = maxf(max_orbit, absf(yaw - yaw0))
			min_road = minf(min_road, CameraRig.road_bottom_frac(pose[0], pose[1], 58.0))
			max_look = maxf(max_look, pose[1].y)
			t += 0.05
		info.append("%s tilt %.1f° orbit %.1f° road %.2f look %.2f" % [fin, max_tilt, max_orbit, min_road, max_look])
		if max_tilt > CameraRig.KILL_TILT_MAX_DEG + 0.5 or max_orbit > CameraRig.KILL_ORBIT_MAX_DEG + 0.5 or min_road < 0.35 \
				or max_look > CameraRig.KILL_LOOK_Y_MAX + 1e-3:
			bad.append(fin)
	_check(bad.is_empty(), "kill cam rules (tilt ≤ 12°, orbit ≤ 30°, road ≥ 35 %%, look y ≤ 4.5) for every finish: %s" % "; ".join(info))
	_check(CameraRig.shot_side(RoadGraph.lane_x(0.0)) < 0.0 and CameraRig.shot_side(RoadGraph.lane_x(3.0)) > 0.0,
		"kill cam stands on the villain's outer side (median lane → median side), the jam is the backdrop")
	cam.free()


# ───────────────────────────── 5. cues (audio + haptics names on the right ticks)

func _cues(tree: SceneTree) -> void:
	var c := SkillCues.new()
	tree.root.add_child(c)
	c.on_event({"type": "skill_start", "chan": "rage", "tier": 1, "id": "t1_horn"})
	var jam_quiet: bool = c.cue_log.is_empty()
	c.on_event({"type": "skill_start", "chan": "rage", "tier": 5, "id": "t5_finish", "target_id": 0})
	var start: PackedStringArray = c.cue_log.duplicate()
	c.cue_log.clear()
	c.on_event({"type": "skill_hit", "chan": "rage", "tier": 5, "id": "t5_finish", "idx": 0, "n": 1, "killed": true, "popped": 0})
	var kill_hit: PackedStringArray = c.cue_log.duplicate()
	c.cue_log.clear()
	c.on_event({"type": "skill_hit", "chan": "rage", "tier": 3, "id": "t3_carpet", "idx": 3, "n": 4, "killed": false, "popped": 1})
	var pop_hit: PackedStringArray = c.cue_log.duplicate()
	_check(jam_quiet and "sfx:sk_charge@0.00" in start and "haptic:skillT5Charge" in start and not "sfx:superHit@0.00" in start,
		"jam t1 adds nothing to rage_horn; t5 cast = charge sound + skillT5Charge, the impact sounds wait for skill_hit %s" % start)
	var any_boom: bool = false
	for s: String in kill_hit:
		any_boom = any_boom or s.begins_with("sfx:superHit") or s.begins_with("sfx:explosion")
	_check(not any_boom and not kill_hit.has("haptic:skillT5Impact"), "a t5 execute leaves superHit / explosion / the kill haptic to the kill tick %s" % kill_hit)
	_check("haptic:tirePop" in pop_hit and "sfx:pop@0.00" in pop_hit, "a t3 tyre burst → pop + tirePop %s" % pop_hit)
	c.cue_log.clear()
	c.on_event({"type": "finisher", "id": "rocket", "target_id": 0})
	var lift: float = float(SkillCues.finish_beats("rocket")["lift"])
	for t: float in [0.1, lift - 0.01, lift + 0.01, lift + 0.2]:
		c.sync({"villains": [{"id": 0, "death_t": t, "gone": false}]})
	var n_fin: int = 0
	for s: String in c.cue_log:
		n_fin += 1 if s == "sfx:fin_rocket@0.00" or s == "haptic:finishRocket" else 0
	_check(n_fin == 2, "rocket finisher: fin_rocket + finishRocket once each, on the lift beat %s" % c.cue_log)
	c.queue_free()
	await tree.process_frame


# ───────────────────────────── 6. the real SkillsSim events through the view (both traffic paths)

func _real_sim(tree: SceneTree, fb: bool) -> void:
	var tag: String = "fallback" if fb else "native"
	var stage: Dictionary = _DB.find_stage(_DB.load_json("res://data/stages.json"), 1)
	var tables: Dictionary = _DB.load_traffic_tables()
	tables["options"] = {"loadout": {"finish": "balloon", "items": ["mv_jump", "mv_drone"]}}
	var sim := GameSim.new()
	sim.force_fallback = fb
	sim.setup(stage, tables, 3)
	if sim.get(&"skills") == null or not bool((sim.get(&"skills") as Object).get(&"enabled")):
		print("SKIP skills_fx: %s — GameSim has no config.skills (stub-only build)" % tag)
		return
	sim.autopilot = Autopilot.new(3 * 13 + 1)
	var fx := FightFx.new()
	fx.manual = true
	tree.root.add_child(fx)
	fx.setup(RoadGraph.new(), 3)
	var hud := Hud.new()
	hud.manual = true
	tree.root.add_child(hud)
	var cam := CameraRig.new()
	tree.root.add_child(cam)
	cam.road = RoadGraph.new()
	hud.bind_world(cam, RoadGraph.new())
	var seen: Dictionary = {}
	var caps: bool = true
	var last_t: float = sim.time
	var step: Callable = func(n: int) -> void:
		for i: int in n:
			sim.step(TICK)
			var st: Dictionary = sim.state()
			for e: Dictionary in sim.events():
				var ty: String = str(e.get("type", ""))
				seen[ty] = int(seen.get(ty, 0)) + 1
				hud.on_event(e)
				fx.on_event(e, st)
				cam.on_event(e)
			if i % 4 == 3:
				fx.sync(st)
				fx.advance(sim.time - last_t)
				last_t = sim.time
				hud.apply_state(st)
				hud.advance(TICK * 4.0)
				cam.apply_state(st)
				cam.step(TICK * 4.0)
				caps = caps and _caps(fx)
	var locked: bool = false
	for k: int in 120 * 90 / 40:
		step.call(40)
		if sim.phase == &"boss" and sim.front_locked and float(sim.get(&"boss_clock")) > 6.5:
			locked = true
			break
	if not locked:
		_check(false, "%s: never reached the locked fight past minKillT" % tag)
	else:
		sim.autopilot = null
		sim.input(&"fire", false)
		sim.rage = 0.6
		sim.input(&"rage", 3)
		step.call(240)
		sim.input(&"item2")
		step.call(240)
		var v: Dictionary = sim.boss.alive()[0] if not sim.boss.alive().is_empty() else {}
		if not v.is_empty():
			v["hp"] = float(v["max_hp"]) * 0.3
		sim.rage = 1.0
		sim.input(&"rage", 5)
		step.call(120 * 4)
		_check(int(seen.get("skill_hit", 0)) >= 4 + 6 + 1 and int(seen.get("finisher", 0)) == 1 and caps,
			"%s: real t3 + drone + t5 execute play through HUD / FightFx / camera into the balloon finisher, caps held (%s)" % [tag,
			JSON.stringify(seen)])
	fx.queue_free()
	hud.queue_free()
	cam.queue_free()
	await tree.process_frame
