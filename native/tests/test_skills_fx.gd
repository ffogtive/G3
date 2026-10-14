extends RefCounted
## T0: skill presentation contracts (docs/SKILLS.md 2-3, 2-4, 3-3, 4, 7-1 "계약", 7-2 kill-cam rules) + r3 F1 (§7).
## 가설(r3 F1): ❓ the fight t1 read as a horn because its fx key was "t1" (hornTruck stack, random shake). Key
##       t1_wave (sk_wave → superHit → explosion, no hornTruck) + a camera kick toward the villain + combo keys
##       c5 / c10 / c20 (gold caltrops that stick, a 2.2× tyre snipe, one tack sound per sim hit, combo haptics) make
##       the 충격파 and the combo readable; every flash stays α ≤ 0.45, ≤ 120 ms, never white.
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
	await _f1(tree)
	for fb: bool in modes:
		await _real_f1(tree, fb)
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
	# t3: config tacks + strip, 4 hits, one pop → tack-strip + skid decals
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
	var want_tacks: int = int(((SkillCues.cfg().get("t3", {}) as Dictionary) if SkillCues.cfg().get("t3") is Dictionary else {}).get("tacks", 12))
	_check(shapes.get("tacks") == want_tacks and int(shapes.get("decals_t3", 0)) >= 2 and shapes.get("drone") == true,
		"t3 throws config.skills.t3.tacks (%d) caltrops + leaves the tack strip / skid decals, the drone shows (%s)"
		% [want_tacks, JSON.stringify(shapes)])
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
	var m: int = Hud.DMG_SHOW_MUL
	_check(stamp and kinds == ["tick", "tick", "tick", "big"] and texts.has("-%d" % (12 * m)) and texts.has("치명! -%d" % (42 * m))
		and texts.has("한 번 더!") and denied,
		"t5 → stamp '참교육!!'; t3 → 3 ticks + 1 summed '-%d' (×%d view); t5 no kill in the window → '치명! -%d' + '한 번 더!'; denied → '분노 부족!' (%s %s)"
		% [12 * m, m, 42 * m, kinds, texts])
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


# ───────────────────────────── 7. r3 F1: t1_wave key, combo cues / shapes, camera kick, hitstop, flash contract

## The config C4 values (config.skills.fx / t1 / t3) as a fixture: the code paths must give the same result with this,
## with no config at all (SkillCues defaults) and with data/config.json.
const C4: Dictionary = {
	"t1": {"delay": 0.12, "hitstop": 0.07}, "t3": {"delay": 0.4, "hitGap": 0.05, "hits": 4, "hitstop": 0.11},
	"t5": {"delay": 0.45, "hitstop": 0.14},
	"fx": {
		"t1": {"banner": "갓길 청소!!", "sfx": [["hornTruck", 0, 1.0, 1.0], ["superHit", 0.12, 0.5, 1.15]], "flash": ["ffd23a", 0.3, 90]},
		"t1_wave": {"banner": "충격파!!", "sfx": [["sk_wave", 0, 1.0, 1.0], ["superHit", 0.12, 0.7, 1.0], ["explosion", 0.12, 0.35, 1.6]],
			"camera": {"punch": -5, "shake": 0.5, "kick": 0.6}, "flash": ["ffd23a", 0.25, 80]},
		"c10": {"sfx": [["tack", 0.15, 1, 1.1], ["tack", 0.21, 1, 1.25], ["tack", 0.27, 1, 1.4], ["crit", 0.27, 0.8, 1.0]]},
		"c20": {"sfx": [["whoosh", 0, 0.8, 1.6], ["pop", 0.25, 1, 1], ["crit", 0.25, 0.9, 1], ["explosion", 0.25, 0.3, 1.5]], "hitstop": 0.04,
			"camera": {"punch": -2, "shake": 0.3}, "flash": ["ffd23a", 0.15, 60]},
		"t3": {"camera": {"lift": 0.25, "punch": -7, "shake": 0.65}, "flash": ["ff7a1a", 0.25, 120]},
	},
}


static func _names(c: SkillCues, from: int = 0) -> PackedStringArray:
	var out: PackedStringArray = []
	for r: Dictionary in c.sfx_log.slice(from):
		out.append(str(r["name"]))
	return out


static func _haps(c: SkillCues) -> PackedStringArray:
	var out: PackedStringArray = []
	for l: String in c.cue_log:
		if l.begins_with("haptic:"):
			out.append(l.trim_prefix("haptic:"))
	return out


## Flash rows of every recipe the view can use (config.skills.fx + SkillCues.RECIPE_DEFAULT): [key, hex, alpha, ms].
static func _flashes() -> Array:
	var out: Array = []
	var keys: Dictionary = {}
	var fx: Variant = SkillCues.cfg().get("fx", {})
	if fx is Dictionary:
		for k: String in fx:
			keys[k] = true
	for k: String in SkillCues.RECIPE_DEFAULT:
		keys[k] = true
	for k: String in keys:
		var fl: Variant = SkillCues.recipe(k).get("flash")
		if fl is Array and (fl as Array).size() >= 3:
			out.append([k, str(fl[0]), float(fl[1]), float(fl[2])])
	return out


func _f1(tree: SceneTree) -> void:
	var keep: Variant = SkillCues.override_cfg
	# A. fx keys
	var keys: PackedStringArray = []
	for e: Dictionary in [{"chan": "rage", "tier": 1, "id": "t1_wave"}, {"chan": "rage", "tier": 1, "id": "t1_horn"},
			{"chan": "combo", "id": "c10_burst"}, {"chan": "combo", "id": "c20_snipe"}, {"chan": "combo", "id": "c5_double"},
			{"type": "combo_milestone", "id": "c10", "n": 10}, {"chan": "item", "id": "mv_jump"}, {"chan": "rage", "tier": 3, "id": "t3_carpet"}]:
		keys.append(SkillCues.fx_key(e))
	_check(keys == PackedStringArray(["t1_wave", "t1", "c10", "c20", "c5", "c10", "mv_jump", "t3"]),
		"F1 fx_key: fight t1 → t1_wave, jam → t1, combo chan → c5/c10/c20 by id prefix %s" % keys)
	# B. cues: same results with no config, the C4 fixture and data/config.json
	for row: Array in [["no config", {}], ["C4 fixture", C4], ["data/config.json", null]]:
		SkillCues.override_cfg = row[1]
		await _f1_cues(tree, str(row[0]))
	# C. hitstop table (code with C4 values / defaults; data/config.json when C4 has landed)
	for row: Array in [["no config", {}], ["C4 fixture", C4]]:
		SkillCues.override_cfg = row[1]
		var hs: Array = [SkillCues.hitstop("t1_wave"), SkillCues.hitstop("t1"), SkillCues.hitstop("t3"), SkillCues.hitstop("c20"),
			SkillCues.hitstop("c10"), SkillCues.hitstop("c5")]
		_check(_near(hs, [0.07, 0.07, 0.11, 0.04, 0.0, 0.0]), "F1 hitstop table %s: t1 0.07 · t3 0.11 · c20 0.04 · c10/c5 0 %s" % [row[0], hs])
	SkillCues.override_cfg = null
	var real_fx: Dictionary = SkillCues.cfg().get("fx", {}) if SkillCues.cfg().get("fx") is Dictionary else {}
	if real_fx.has("t1_wave"):
		var hs2: Array = [SkillCues.hitstop("t1_wave"), SkillCues.hitstop("t3"), SkillCues.hitstop("c20")]
		var wave_sfx: PackedStringArray = []
		for r: Variant in (real_fx["t1_wave"] as Dictionary).get("sfx", []):
			wave_sfx.append(str((r as Array)[0]))
		_check(_near(hs2, [0.07, 0.11, 0.04]) and not wave_sfx.has("hornTruck") and str(SkillCues.recipe("t1_wave").get("banner")) == "충격파!!"
			and str(SkillCues.recipe("t1").get("banner")) == "갓길 청소!!",
			"F1×C4 data/config.json: hitstop %s, t1_wave sfx %s (no hornTruck), banners 충격파!! / 갓길 청소!!" % [hs2, wave_sfx])
	else:
		print("PEND skills_fx: C4 (combat) has not put skills.fx.t1_wave into data/config.json yet — the view uses SkillCues.RECIPE_DEFAULT")
	# D. flash contract on every recipe
	var bad: Array = []
	for f: Array in _flashes():
		var c: Color = Color.html(str(f[1]))
		var white: bool = c.r >= 0.92 and c.g >= 0.92 and c.b >= 0.92
		if float(f[2]) > 0.45 + 1e-6 or float(f[3]) > 120.0 + 1e-6 or white:
			bad.append(f)
	_check(bad.is_empty() and _flashes().size() >= 4, "F1 flash contract: every recipe flash α ≤ 0.45, ≤ 120 ms, not white (%d flashes, bad %s)" % [_flashes().size(), bad])
	SkillCues.override_cfg = keep
	await _f1_camera(tree)
	await _f1_shapes(tree)
	await _f1_hud(tree)


static func _near(a: Array, b: Array, eps: float = 1e-4) -> bool:
	if a.size() != b.size():
		return false
	for i: int in a.size():
		if absf(float(a[i]) - float(b[i])) > eps:
			return false
	return true


func _f1_cues(tree: SceneTree, tag: String) -> void:
	var c := SkillCues.new()
	tree.root.add_child(c)
	# t1_wave: sk_wave (cast) → superHit → explosion (impact), no hornTruck, skillT1 on the hit
	c.on_event({"type": "skill_start", "chan": "rage", "tier": 1, "id": "t1_wave", "target_id": 0, "s": 320.0, "x": 0.0})
	var owns: bool = c.owns_rage_horn()
	c.on_event({"type": "skill_hit", "chan": "rage", "tier": 1, "id": "t1_wave", "target_id": 0, "idx": 0, "n": 1, "killed": false, "popped": 0})
	var w: PackedStringArray = _names(c)
	var order_ok: bool = w.find("sk_wave") >= 0 and w.find("sk_wave") < w.find("superHit") and w.find("superHit") < w.find("explosion")
	_check(order_ok and not w.has("hornTruck") and _haps(c).has("skillT1") and owns,
		"F1 cues (%s): t1_wave = sk_wave → superHit → explosion, hornTruck 0, skillT1, owns_rage_horn on the cast frame %s" % [tag, w])
	await tree.process_frame
	var released: bool = not c.owns_rage_horn()
	c.on_event({"type": "skill_start", "chan": "rage", "tier": 1, "id": "t1_horn"})
	_check(released and not c.owns_rage_horn(), "F1 cues (%s): owns_rage_horn only on the t1_wave frame, never for the jam t1_horn" % tag)
	# c10: tack ×3 at pitch 1.1 / 1.25 / 1.4, one per sim hit, + crit on the last; combo10 once
	c.sfx_log.clear()
	c.cue_log.clear()
	c.on_event({"type": "skill_start", "chan": "combo", "tier": 0, "id": "c10_burst", "target_id": 0, "n": 3, "s": 320.0, "x": 0.0})
	var start_n: int = c.sfx_log.size()
	var per_hit: Array = []
	for i: int in 3:
		var k0: int = c.sfx_log.size()
		c.on_event({"type": "skill_hit", "chan": "combo", "tier": 0, "id": "c10_burst", "target_id": 0, "idx": i, "n": 3, "killed": false, "popped": 0})
		per_hit.append(_names(c, k0))
	var pitches: Array = []
	for r: Dictionary in c.sfx_log:
		if str(r["name"]) == "tack":
			pitches.append(float(r["pitch"]))
	_check(start_n == 0 and per_hit == [PackedStringArray(["tack"]), PackedStringArray(["tack"]), PackedStringArray(["tack", "crit"])]
		and _near(pitches, [1.1, 1.25, 1.4]) and _haps(c) == PackedStringArray(["combo10"]),
		"F1 cues (%s): c10 = tack per hit (pitch %s) + crit on the 3rd, combo10 once %s %s" % [tag, pitches, per_hit, _haps(c)])
	# c20: whoosh on the cast → pop + crit + explosion on the snipe hit; combo20 (no extra tirePop)
	c.sfx_log.clear()
	c.cue_log.clear()
	c.on_event({"type": "skill_start", "chan": "combo", "tier": 0, "id": "c20_snipe", "target_id": 0, "n": 1, "s": 320.0, "x": 0.0})
	var c20_start: PackedStringArray = _names(c)
	c.on_event({"type": "skill_hit", "chan": "combo", "tier": 0, "id": "c20_snipe", "target_id": 0, "idx": 0, "n": 1, "killed": false, "popped": 1})
	var c20_hit: PackedStringArray = _names(c, c20_start.size())
	_check(c20_start == PackedStringArray(["whoosh"]) and c20_hit == PackedStringArray(["pop", "crit", "explosion"]) and _haps(c) == PackedStringArray(["combo20"]),
		"F1 cues (%s): c20 = whoosh → pop + crit + explosion, combo20 only %s %s %s" % [tag, c20_start, c20_hit, _haps(c)])
	# c5: two tacks, combo5
	c.sfx_log.clear()
	c.cue_log.clear()
	c.on_event({"type": "skill_start", "chan": "combo", "tier": 0, "id": "c5_double", "target_id": 0, "n": 2})
	for i: int in 2:
		c.on_event({"type": "skill_hit", "chan": "combo", "tier": 0, "id": "c5_double", "target_id": 0, "idx": i, "n": 2, "killed": false, "popped": 0})
	_check(_names(c) == PackedStringArray(["tack", "tack"]) and _haps(c) == PackedStringArray(["combo5"]),
		"F1 cues (%s): c5 = tack ×2, combo5 once %s %s" % [tag, _names(c), _haps(c)])
	# a 2nd target of the same hit (1-3 duo t1_wave) does not stack the sounds again
	c.sfx_log.clear()
	c.on_event({"type": "skill_start", "chan": "rage", "tier": 1, "id": "t1_wave", "target_id": 0})
	for tid: int in 2:
		c.on_event({"type": "skill_hit", "chan": "rage", "tier": 1, "id": "t1_wave", "target_id": tid, "idx": 0, "n": 1, "killed": false, "popped": 0})
	var n_hit: int = _names(c).count("superHit")
	_check(n_hit == 1, "F1 cues (%s): a t1_wave hitting 2 villains plays its impact stack once (superHit ×%d)" % [tag, n_hit])
	# combo_break: event (n ≥ 5) and the state fallback, once per break
	c.cue_log.clear()
	c.on_event({"type": "combo_break", "reason": "hit", "n": 12})
	c.on_event({"type": "combo_break", "reason": "timeout", "n": 3})
	var ev_haps: PackedStringArray = _haps(c)
	c.advance(1.0)
	c.cue_log.clear()
	c.sync({"phase": "boss", "skills": {"combo": {"n": 8}}, "villains": []})
	c.sync({"phase": "boss", "skills": {"combo": {"n": 9}}, "villains": []})
	c.sync({"phase": "boss", "skills": {"combo": {"n": 0}}, "villains": []})
	var st_haps: PackedStringArray = _haps(c)
	c.cue_log.clear()
	c.sync({"phase": "boss", "skills": {"combo": {"n": 3}}, "villains": []})
	c.sync({"phase": "boss", "skills": {"combo": {"n": 0}}, "villains": []})
	c.sync({"phase": "boss", "skills": {"combo": {"n": 7}}, "villains": []})
	c.sync({"phase": "kill", "skills": {"combo": {"n": 0}}, "villains": []})
	_check(ev_haps == PackedStringArray(["comboBreak"]) and st_haps == PackedStringArray(["comboBreak"]) and _haps(c).is_empty(),
		"F1 cues (%s): comboBreak on combo_break n ≥ 5 / on a state drop from ≥ 5 in the boss phase only %s %s %s" % [tag, ev_haps, st_haps, _haps(c)])
	c.queue_free()
	await tree.process_frame


func _f1_camera(tree: SceneTree) -> void:
	var cam := CameraRig.new()
	tree.root.add_child(cam)
	cam.road = RoadGraph.new()
	cam.phase = "boss"
	cam.target_s = 300.0
	cam.target_x = RoadGraph.lane_x(1.0)
	cam.step(1.0 / 60.0)
	var rows: PackedStringArray = []
	var ok: bool = true
	for vs: float in [318.0, 284.0, 300.0 + 55.0]:
		for i: int in 60:
			cam.step(1.0 / 60.0)
		var tr0: float = cam._trauma
		var to: Vector3 = cam.road.position(vs, RoadGraph.lane_x(0.0)) - cam.road.position(cam.target_s, cam.target_x)
		to.y = 0.0
		cam.on_event({"type": "skill_start", "chan": "rage", "tier": 1, "id": "t1_wave", "target_id": 0, "s": vs, "x": RoadGraph.lane_x(0.0)})
		var tr_cast: float = cam._trauma
		var peak: float = 0.0
		var sign_ok: bool = true
		var t: float = 0.0
		var at_dur: float = 0.0
		while t < 0.6:
			cam.step(0.01)
			t += 0.01
			var along: float = cam.kick_offset.dot(to.normalized())
			sign_ok = sign_ok and along >= -1e-4 and cam.kick_offset.cross(to.normalized()).length() < 1e-3
			peak = maxf(peak, cam.kick_offset.length())
			if absf(t - 0.12) < 0.005:
				at_dur = along
		var settled: float = cam.kick_offset.length()
		rows.append("vs %.0f: peak %.2f @0.12 %.2f end %.3f trauma cast +%.2f" % [vs, peak, at_dur, settled, tr_cast - tr0])
		ok = ok and sign_ok and absf(peak - 0.6) < 0.02 and at_dur > 0.58 and settled < 1e-3 and absf(tr_cast - tr0) < 1e-6
	_check(ok, "F1 camera: t1_wave cast kicks 0.6 m / 0.12 s toward the villain (ahead or behind), back to 0, no random shake on the cast: %s" % "; ".join(rows))
	# impact: recipe punch + shake; t3 cast: no kick
	var tr1: float = cam._trauma
	cam.on_event({"type": "skill_hit", "chan": "rage", "tier": 1, "id": "t1_wave", "target_id": 0, "idx": 0, "n": 1})
	var shake_add: float = cam._trauma - tr1
	cam.on_event({"type": "skill_start", "chan": "rage", "tier": 3, "id": "t3_carpet", "target_id": 0, "s": 330.0, "x": 0.0})
	cam.step(0.1)
	var want_shake: float = float(CameraRig._recipe_cam("t1_wave").get("shake", 0.0))
	_check(absf(shake_add - minf(want_shake, 1.0 - tr1)) < 1e-4 and cam.kick_offset.length() < 1e-4,
		"F1 camera: the t1_wave impact adds the recipe shake (%.2f), a t3 cast does not kick (%.3f)" % [shake_add, cam.kick_offset.length()])
	cam.queue_free()
	await tree.process_frame


func _f1_shapes(tree: SceneTree) -> void:
	var fx := FightFx.new()
	fx.manual = true
	tree.root.add_child(fx)
	fx.setup(RoadGraph.new(), 11)
	var cam := CameraRig.new()
	fx.camera_rig = cam
	var st: Dictionary = _state(300.0, 312.0)
	fx.sync(st)
	var caps: bool = true
	# c10: 3 gold caltrops on the carpet pool, one lands per sim hit, stuck on the villain's roof
	fx.on_event({"type": "skill_start", "chan": "combo", "tier": 0, "id": "c10_burst", "target_id": 0, "n": 3, "s": 312.0, "x": RoadGraph.lane_x(0.0)}, st)
	var c10: Array[Dictionary] = fx.skill.combo_tacks()
	var gold: bool = c10.size() == 3
	for tk: Dictionary in c10:
		gold = gold and (tk["col"] as Color).is_equal_approx(SkillFx.COMBO_GOLD) and absf(float(tk["sc"]) - SkillFx.TACK_SC) < 1e-4
	var hits_at: Array = SkillCues.combo_delays("c10")
	var t: float = 0.0
	var landed: Array[bool] = []
	for i: int in 3:
		while t + 1e-6 < float(hits_at[i]):
			fx.advance(0.01)
			fx.sync(st)
			t += 0.01
		fx.on_event({"type": "skill_hit", "chan": "combo", "tier": 0, "id": "c10_burst", "target_id": 0, "idx": i, "n": 3, "dmg": 1.4,
			"window": false, "immune": false, "stun": 0.0, "popped": 0, "killed": false, "hp_frac": 0.5, "s": 312.0, "x": RoadGraph.lane_x(0.0)}, st)
		fx.advance(0.001)
		landed.append(bool(fx.skill.combo_tacks()[i]["landed"]))
		caps = caps and _caps(fx)
	# the villain drives on: the stuck caltrops follow it
	var st2: Dictionary = _state(300.0, 316.0)
	fx.sync(st2)
	fx.advance(0.02)
	var near: bool = true
	var offs: Array = []
	for tk: Dictionary in fx.skill.combo_tacks():
		var o2: Array = (tk["follow"] as Dictionary)["o"]
		offs.append(o2)
		var want: Vector3 = fx._w(316.0 + float(o2[0]), RoadGraph.lane_x(0.0) + float(o2[1]), float(o2[2]))
		near = near and (tk["p1"] as Vector3).distance_to(want) < 0.01 and absf(float(o2[0])) <= 2.3 and absf(float(o2[1])) <= 0.95 \
			and float(o2[2]) >= SkillFx.kind_height("") - 0.01
	_check(gold and landed == [true, true, true] and near and cam._trauma == 0.0,
		"F1 shapes: c10 = 3 gold caltrops (carpet pool), each lands on its sim hit and sticks on the villain's roof as it drives on, no camera shake from the shape (landed %s, offsets %s, trauma %.2f)" % [landed, offs, cam._trauma])
	# c20: one 2.2× caltrop into the front wheel on the player side + the tyre burst (debris, skid decal)
	for i: int in 80:
		fx.advance(0.02)
		fx.sync(st2)
	var lit0: int = int(fx.counts()["lit"])
	var dec0: int = int(fx.counts()["decals"])
	fx.on_event({"type": "skill_start", "chan": "combo", "tier": 0, "id": "c20_snipe", "target_id": 0, "n": 1, "s": 316.0, "x": RoadGraph.lane_x(0.0)}, st2)
	var c20: Array[Dictionary] = fx.skill.combo_tacks()
	var big: bool = c20.size() == 1 and absf(float(c20[0]["sc"]) - SkillFx.TACK_SC * SkillFx.SNIPE_MUL) < 1e-4
	var o: Array = (c20[0]["follow"] as Dictionary)["o"] if big else [0, 0, 0]
	var front_side: bool = float(o[0]) > 0.5 and float(o[1]) > 0.5  # player in lane 1 is to the +x side of lane 0
	t = 0.0
	while t + 1e-6 < float(SkillCues.combo_delays("c20")[0]):
		fx.advance(0.01)
		fx.sync(st2)
		t += 0.01
	fx.on_event({"type": "skill_hit", "chan": "combo", "tier": 0, "id": "c20_snipe", "target_id": 0, "idx": 0, "n": 1, "dmg": 7.0,
		"window": false, "immune": false, "stun": 0.8, "popped": 1, "killed": false, "hp_frac": 0.45, "s": 316.0, "x": RoadGraph.lane_x(0.0)}, st2)
	fx.advance(0.001)
	var burst_ok: bool = int(fx.counts()["lit"]) >= lit0 + 16 and int(fx.counts()["decals"]) >= dec0 + 1 and bool(fx.skill.combo_tacks()[0]["landed"])
	caps = caps and _caps(fx)
	_check(big and front_side and burst_ok and int(fx.counts()["big_tacks"]) == 1 and cam._trauma == 0.0,
		"F1 shapes: c20 = one %.1f× caltrop into the front wheel on the player side (o %s), tyre burst debris + skid decal, no shape shake (%s)"
		% [SkillFx.SNIPE_MUL, o, JSON.stringify(fx.counts())])
	# a combo volley does not wipe a t3 carpet in flight (separate channels can overlap)
	fx.on_event({"type": "skill_start", "chan": "rage", "tier": 3, "id": "t3_carpet", "target_id": 0, "lanes": PackedInt32Array([0, 1]),
		"dur": 1.2, "cine": false, "s": 316.0, "x": RoadGraph.lane_x(0.0)}, st2)
	var n3: int = int(fx.counts()["tacks"])
	fx.on_event({"type": "skill_start", "chan": "combo", "tier": 0, "id": "c5_double", "target_id": 0, "n": 2, "s": 316.0, "x": RoadGraph.lane_x(0.0)}, st2)
	var both: int = int(fx.counts()["tacks"])
	for i: int in 60:
		fx.advance(1.0 / 60.0)
		fx.sync(st2)
		caps = caps and _caps(fx)
	var want3: int = int(((SkillCues.cfg().get("t3", {}) as Dictionary) if SkillCues.cfg().get("t3") is Dictionary else {}).get("tacks", 12))
	_check(both - n3 == 2 and n3 >= want3 and caps, "F1 shapes: c5 adds 2 caltrops next to a t3 carpet in flight (%d + %d), caps held" % [n3, both - n3])
	fx.queue_free()
	cam.free()
	await tree.process_frame


func _f1_hud(tree: SceneTree) -> void:
	var inp := LaneInput.new()
	tree.root.add_child(inp)
	var hud := Hud.new()
	hud.manual = true
	tree.root.add_child(hud)
	hud.bind_input(inp)
	var cam := Camera3D.new()
	hud.add_child(cam)
	hud.bind_world(cam, RoadGraph.new())
	hud.apply_state(UiStubState.boss(true))
	hud.on_event({"type": "skill_start", "chan": "rage", "tier": 1, "id": "t1_wave", "target_id": 0, "dur": 0.5, "cine": false, "s": 254.9, "x": -6.45})
	var wave: String = hud.banner.current()
	hud.on_event({"type": "skill_start", "chan": "rage", "tier": 1, "id": "t1_horn", "target_id": -1, "dur": 0.5, "cine": false})
	var horn: String = hud.banner.current()
	# hud.gd (ui group) must route key t1_wave to its t1 banner path (match SkillCues.base_key(key)) — see interface notes
	_check(wave == "충격파!!" and horn == str(SkillCues.recipe("t1").get("banner", "갓길 청소!!")),
		"F1×C4 HUD: fight t1 banner '충격파!!' (got '%s'), jam t1 banner = recipe t1 (got '%s') — needs hud.gd to match SkillCues.base_key(key)" % [wave, horn])
	hud.queue_free()
	inp.queue_free()
	await tree.process_frame


## Real GameSim t1 (both traffic paths): the cast reaches cues / FightFx / camera with the t1_wave key — no hornTruck,
## sk_wave → superHit / explosion, the camera kicks toward the villain. Combo milestones once C1 (combat) is in.
func _real_f1(tree: SceneTree, fb: bool) -> void:
	var tag: String = "fallback" if fb else "native"
	var stage: Dictionary = _DB.find_stage(_DB.load_json("res://data/stages.json"), 1)
	var tables: Dictionary = _DB.load_traffic_tables()
	var sim := GameSim.new()
	sim.force_fallback = fb
	sim.setup(stage, tables, 5)
	if sim.get(&"skills") == null or not bool((sim.get(&"skills") as Object).get(&"enabled")):
		print("SKIP skills_fx: %s F1 — GameSim has no config.skills" % tag)
		return
	sim.autopilot = Autopilot.new(5 * 13 + 1)
	var fx := FightFx.new()
	fx.manual = true
	tree.root.add_child(fx)
	fx.setup(RoadGraph.new(), 5)
	var cam := CameraRig.new()
	tree.root.add_child(cam)
	cam.road = RoadGraph.new()
	fx.camera_rig = cam
	var kick_dot: Array[float] = [0.0]
	var cast_dir: Array[Vector3] = [Vector3.ZERO]
	var seen: Dictionary = {}
	var max_combo_tacks: Array[int] = [0]
	var hs_seen: Dictionary = {}  # fx key -> sim.hitstop right after its first impact tick
	var last_t: Array[float] = [sim.time]
	var step: Callable = func(n: int) -> void:
		for i: int in n:
			sim.step(TICK)
			var st: Dictionary = sim.state()
			var p: Dictionary = st["player"]
			cam.target_s = float(p["s"])
			cam.target_x = float(p["x"])
			for e: Dictionary in sim.events():
				var k: String = "%s:%s" % [str(e.get("type", "")), SkillCues.fx_key(e)] if str(e.get("type", "")).begins_with("skill") else str(e.get("type", ""))
				seen[k] = int(seen.get(k, 0)) + 1
				if str(e.get("type", "")) == "skill_hit" and int(e.get("idx", 0)) == 0 and not hs_seen.has(SkillCues.fx_key(e)):
					hs_seen[SkillCues.fx_key(e)] = float(sim.hitstop)
				if str(e.get("type", "")) == "skill_start" and str(e.get("id", "")) == "t1_wave":
					cast_dir[0] = cam.road.position(float(e["s"]), float(e["x"])) - cam.road.position(cam.target_s, cam.target_x)
					cast_dir[0].y = 0.0
				fx.on_event(e, st)
				cam.on_event(e)
			if i % 4 == 3:
				fx.sync(st)
				fx.advance(sim.time - last_t[0])
				fx.cues.advance(TICK * 4.0)
				last_t[0] = sim.time
				cam.apply_state(st)
				cam.step(TICK * 4.0)
				if cast_dir[0] != Vector3.ZERO:
					kick_dot[0] = maxf(kick_dot[0], cam.kick_offset.dot(cast_dir[0].normalized()))
				max_combo_tacks[0] = maxi(max_combo_tacks[0], int(fx.counts().get("combo_tacks", 0)))
	var locked: bool = false
	for k: int in 120 * 90 / 40:
		step.call(40)
		if sim.phase == &"boss" and sim.front_locked:
			locked = true
			break
	if not locked:
		_check(false, "%s F1: never reached the locked fight" % tag)
	else:
		sim.autopilot = null
		sim.input(&"fire", false)
		fx.cues.sfx_log.clear()
		fx.cues.cue_log.clear()
		sim.rage = 0.21
		sim.input(&"rage", 1)
		step.call(120)
		var names: PackedStringArray = _names(fx.cues)
		var hit: bool = int(seen.get("skill_hit:t1_wave", 0)) >= 1
		var order_ok: bool = names.find("sk_wave") >= 0 and (not hit or names.find("superHit") > names.find("sk_wave") or names.has("crit"))
		_check(int(seen.get("skill_start:t1_wave", 0)) == 1 and hit and order_ok and not names.has("hornTruck") and kick_dot[0] > 0.5,
			"%s F1: real t1 → key t1_wave, cues %s (no hornTruck), camera kick toward the villain %.2f m (%s)" % [tag, names, kick_dot[0],
			JSON.stringify(seen.keys().filter(func(x: String) -> bool: return x.begins_with("skill")))])
		var sk: Object = sim.get(&"skills")
		if sk.has_method(&"on_tack_hit") and SkillCues.cfg().get("combo") is Dictionary:
			# the autopilot fights again (steers + fires) for 10 s; every combo milestone of the window must reach the view
			seen.clear()
			max_combo_tacks[0] = 0
			var haps: PackedStringArray = []
			sim.autopilot = Autopilot.new(5 * 13 + 2)
			for k: int in 20:
				fx.cues.cue_log.clear()
				step.call(60)
				haps.append_array(_haps(fx.cues))
				if sim.phase != &"boss":
					break
			var want: Dictionary = {"c5": "combo5", "c10": "combo10", "c20": "combo20"}
			var ok: bool = false
			var miss: PackedStringArray = []
			for ck: String in want:
				var n_start: int = int(seen.get("skill_start:%s" % ck, 0))
				ok = ok or n_start > 0
				if n_start > 0 and haps.count(str(want[ck])) < 1:
					miss.append(ck)
			var hap0: int = haps.count("combo5") + haps.count("combo10") + haps.count("combo20")
			var hs_ok: bool = true
			var hs_rows: PackedStringArray = []
			for hk: String in ["t1_wave", "c5", "c10", "c20"]:
				if hs_seen.has(hk):
					hs_rows.append("%s %.3f/%.3f" % [hk, float(hs_seen[hk]), SkillCues.hitstop(hk)])
					hs_ok = hs_ok and absf(float(hs_seen[hk]) - SkillCues.hitstop(hk)) < 0.01
			_check(hs_ok and hs_seen.has("t1_wave") and hs_seen.has("c20"),
				"%s F1: sim hitstop on the impact tick = the table (seen/table: %s)" % [tag, ", ".join(hs_rows)])
			_check(ok and miss.is_empty() and max_combo_tacks[0] > 0,
				"%s F1×C1: real combo milestones in 10 s of autopilot fight reach cues + shapes (%s; combo haptics %d %s; max combo caltrops %d; missing %s)"
				% [tag, JSON.stringify(seen.keys().filter(func(x: String) -> bool: return x.contains(":c"))), hap0, haps, max_combo_tacks[0], miss])
		else:
			print("PEND skills_fx: %s — C1 (combat) combo chan not in SkillsSim yet (no on_tack_hit / config.skills.combo)" % tag)
	fx.queue_free()
	cam.queue_free()
	await tree.process_frame
