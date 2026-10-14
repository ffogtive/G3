extends RefCounted
## T0: one rage gauge — the circle on the 분노 button. Device feedback 2026-10-14 #2 ("분노버튼의 게이지랑(동그라미),
## 막대게이지 중복이라. 막대게이지는 없애도 될듯?").
## 가설: ✅ the bottom-left "분노" segment bar repeated the 분노 button's charge ring; dropping the bar loses nothing if
## the ring itself reads as levels (one tick-separated segment per rage cost) and full rage glows "MAX".

var _fails: int = 0


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
	hud.queue_free()
	inp.queue_free()
	await tree.process_frame
	return _fails
