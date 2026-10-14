extends RefCounted
## T0: one rage gauge — the circle on the 분노 button. Device feedback 2026-10-14 #2 ("분노버튼의 게이지랑(동그라미),
## 막대게이지 중복이라. 막대게이지는 없애도 될듯?").
## 가설: ✅ the bottom-left "분노" segment bar repeated the 분노 button's charge ring; dropping the bar loses nothing if
## the ring itself reads as levels (one tick-separated segment per rage cost) and full rage glows "MAX".
## r3 U2 (device feedback 2 "분노 스킬도 너무 얌전해", rvB "분노가 경적처럼 보임"):
## 가설: ✅ the 분노 button read as a second horn because both were orange (#ff6a1a vs #f08a1a, 8° apart) and the t1 face
##       said 경적; a crimson 분노 (≥ 30° from the horn), the face from state.skills.face (청소 in the jam, 충격파 in the
##       boss phase — before the lock too) and an orange '분노' tag on the villain bracket tell the player "this hits it".

var _fails: int = 0


## Hue (degrees) of the average of a button's gradient colours.
static func _hue_of(cols: Array) -> float:
	var s := Color(0, 0, 0)
	for c: Variant in cols:
		s += c as Color
	s /= float(cols.size())
	return s.h * 360.0


static func _hue_diff(a: float, b: float) -> float:
	var d: float = absf(a - b)
	return minf(d, 360.0 - d)


func _skills_state(base: Dictionary, mode: String, face: String, tier: int, prelock: bool) -> Dictionary:
	var st: Dictionary = base.duplicate(true)
	st["skills"] = {"segs": tier, "rage_tiers_ready": [tier] if tier > 0 else [], "next_tier": tier, "mode": mode, "execute_frac": 0.0,
		"active": {}, "items": [], "skip_ready": false, "enabled": true, "face": face, "prelock": prelock, "chase": false,
		"combo": {"n": 0, "left": 0.0, "next_n": 5, "next_id": "c5", "next_name": "따닥", "best": 0, "timeout": 1.5, "cycle": 20, "marks": [5, 10, 15, 20]}}
	(st["player"] as Dictionary)["rage"] = float(tier) / 5.0 + 0.01
	if prelock:
		(st["lock"] as Dictionary)["active"] = false
	return st


func _r3_rage(hud: Hud) -> void:
	var h_rage: float = _hue_of(Hud.BTN_RAGE)
	var h_horn: float = _hue_of(Hud.BTN_HORN)
	var h_fill: float = Hud.C_RAGE.h * 360.0
	_check(_hue_diff(h_rage, h_horn) >= 30.0 and _hue_diff(h_fill, h_horn) >= 30.0,
		"U2: 분노 button hue %.0f° vs 경적 %.0f° (Δ %.0f° ≥ 30), ring fill 1–2 칸 %.0f° (Δ %.0f°)" % [h_rage, h_horn,
		_hue_diff(h_rage, h_horn), h_fill, _hue_diff(h_fill, h_horn)])
	var fills: Array = []
	for lvl: int in [1, 2, 3, 4, 5]:
		fills.append(hud.rage_fill_color(lvl))
	_check((fills[0] as Color).is_equal_approx(Hud.C_RAGE) and (fills[1] as Color).is_equal_approx(Hud.C_RAGE)
		and (fills[2] as Color).is_equal_approx(Hud.C_T3) and (fills[3] as Color).is_equal_approx(Hud.C_T3) and (fills[4] as Color).is_equal_approx(Hud.C_GOLD),
		"U2: ring fill 1–2 crimson → 3–4 red-orange → MAX gold")
	# faces: jam t1 = 청소, boss before the lock (state.skills.face wave) = 충격파, t3 폭격, t5 참교육, nothing = 분노
	var labels: Array[String] = []
	var cases: Array = [[UiStubState.jam(0.4), "jam", "clear", 1, false], [UiStubState.boss(true), "fight", "wave", 1, true],
		[UiStubState.boss(true), "fight", "wave", 1, false], [UiStubState.boss(true), "fight", "carpet", 3, false],
		[UiStubState.boss(true), "fight", "finish", 5, false], [UiStubState.boss(true), "fight", "wave", 0, false]]
	for cs: Array in cases:
		hud.apply_state(_skills_state(cs[0], cs[1], cs[2], cs[3], cs[4]))
		labels.append(hud.rage_face_label())
	_check(labels == ["청소", "충격파", "충격파", "폭격", "참교육", "분노"],
		"U2: 분노 face jam '청소' · boss before the lock '충격파' · t1 / t3 / t5 / none %s" % str(labels))
	# reticle '분노' tag: fight with a tier ready (before the lock too), never in the jam or with nothing ready
	var tags: Array[bool] = []
	for cs: Array in [[UiStubState.boss(true), "fight", "wave", 1, true], [UiStubState.boss(true), "fight", "carpet", 3, false],
			[UiStubState.boss(true), "fight", "wave", 0, false], [UiStubState.jam(0.4), "jam", "clear", 1, false]]:
		hud.apply_state(_skills_state(cs[0], cs[1], cs[2], cs[3], cs[4]))
		tags.append(hud.reticle.rage_tag)
	_check(tags == [true, true, false, false], "U2: reticle '분노' tag when a rage tier can hit the villain %s" % str(tags))


## r3 final (device review major): 분노 tapped > 60 m from the villain → chase 0.8 s → refund with
## skill_denied {reason far, refunded, text '너무 멀다!'}. DENY_TEXT had no "far", so the HUD popped "분노 부족!" over the
## player's car while the ring still held the segment (feedback 2 "범위에 안 닿아" made worse). Also the chase itself
## (skill_chase) had no consumer: 0.8 s of nothing after the tap (minor).
func _far_refund(hud: Hud, tree: SceneTree) -> void:
	var cam := Camera3D.new()
	tree.root.add_child(cam)
	hud.bind_world(cam, RoadGraph.new())
	hud.apply_state(_skills_state(UiStubState.boss(true), "fight", "wave", 1, true))
	hud.pops.clear_pops()
	hud.on_event({"type": "skill_chase", "chan": "rage", "tier": 1, "id": "t1_wave", "dur": 0.8})
	hud.advance(0.05)
	var chase_txt: PackedStringArray = hud.pops.texts_pops()
	var chasing: float = hud.rage_chase_t() if hud.has_method(&"rage_chase_t") else -1.0
	hud.on_event({"type": "skill_denied", "chan": "rage", "tier": 1, "id": "t1_wave", "reason": "far", "refunded": true, "text": "너무 멀다!"})
	hud.advance(0.05)
	var txt: PackedStringArray = hud.pops.texts_pops()
	_check(txt.has("너무 멀다!") and not txt.has("분노 부족!"), "far refund pops '너무 멀다!', never '분노 부족!' %s" % str(txt))
	_check(chase_txt.size() == 1 and chasing >= 0.0 and hud.rage_chase_t() < 0.0, "skill_chase answers at once: one pop %s + 분노 ring chase dashes (%.2f s), cleared by the refund" % [str(chase_txt), chasing])
	cam.queue_free()
	await tree.process_frame


func _check(ok: bool, what: String) -> void:
	print(("PASS" if ok else "FAIL") + " hud_rage: " + what)
	if not ok:
		_fails += 1


func _state(rage: float) -> Dictionary:
	var st: Dictionary = UiStubState.boss(true)
	(st["player"] as Dictionary)["rage"] = rage
	return st


func run() -> int:
	var tree := Engine.get_main_loop() as SceneTree
	var inp := LaneInput.new()
	tree.root.add_child(inp)
	var hud := Hud.new()
	hud.manual = true
	tree.root.add_child(hud)
	hud.bind_input(inp)
	hud.apply_state(_state(0.0))
	hud.advance(0.5)
	await tree.process_frame
	hud._process(0.0)
	# 1. no rage bar widget any more; the HP row and the 분노 button stay
	var bars: PackedStringArray = []
	for c: Node in hud.safe.get_children():
		if c is Control and (c as Control).visible and c.get_meta(&"widget", "") == "rage_bar":
			bars.append(str(c.name))
	_check(hud.get("_rage_row") == null and bars.is_empty(), "no rage bar in the HUD (only the 분노 button ring)")
	_check(hud._hp_row.visible and hud._btn_rage.visible, "범퍼 HP row and the 분노 button still shown in the fight")
	var hp_r: Rect2 = hud._hp_row.get_global_rect()
	var overl: int = 0
	for r: Rect2 in hud.reserved_rects():
		if r.grow(-4.0).intersects(hp_r) and not r.grow(-4.0).is_equal_approx(hp_r):
			overl += 1
	_check(overl == 0, "the HP row overlaps no other widget (%d)" % overl)
	# 2. the ring reads as levels: one segment per rage cost, ticks between them, partial fill on the current one
	hud.rage_cost = 0.2
	var seg: PackedFloat32Array = Hud.rage_segments(0.5, 0.2)
	_check(seg.size() == 5 and is_equal_approx(seg[0], 1.0) and is_equal_approx(seg[1], 1.0) and is_equal_approx(seg[2], 0.5)
		and seg[3] == 0.0 and seg[4] == 0.0, "rage 0.5 / cost 0.2 → segments %s" % str(seg))
	_check(Hud.rage_segments(1.0, 0.25).size() == 4 and Hud.rage_segments(0.0, 0.2)[0] == 0.0, "segment count follows the cost; empty at 0")
	var levels: Array[int] = []
	for r: float in [0.0, 0.19, 0.2, 0.61, 1.0]:
		hud.apply_state(_state(r))
		levels.append(hud.rage_level())
	_check(levels == [0, 0, 1, 3, 5], "rage_level() = full segments %s" % str(levels))
	# 3. MAX glow at full rage only
	hud.apply_state(_state(0.99))
	var below: bool = hud.rage_max()
	hud.apply_state(_state(1.0))
	hud.advance(0.1)
	_check(not below and hud.rage_max(), "MAX glow only at full rage (0.99 → %s, 1.0 → %s)" % [below, hud.rage_max()])
	_r3_rage(hud)
	await _far_refund(hud, tree)
	hud.queue_free()
	inp.queue_free()
	await tree.process_frame
	return _fails
