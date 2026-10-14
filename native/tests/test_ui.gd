extends RefCounted
## T0 UI / input / FX contract (M1b–M1d, DESIGN_REVIEW P0 #1 #2 #4 #6), against the IFACE-shaped UiStubState fixtures:
##  - input: 압정 zone hold = fire level + one edge per press, swipe down = brake held until the finger lifts, keys
##    Space/J fire, ↓/S brake, release_all clears, three fingers = debug_requested; old swipe / horn contract intact.
##  - HUD: 압정 / 분노 / 경적 / lanes ≥ 64 pt and inside the safe rect (59 / 34 pt notch + home bar), fire ring + reticle
##    follow lock.in_range, out of range points the player to the villain lane, hint chip one line ≤ 16 chars,
##    N1 bar = GameSim progress / distance, no debug badge in the HUD, phase visibility (kill hides the controls).
##  - reticle: on screen it sits exactly on Camera3D.unproject_position of the target car.
##  - camera P0#4: player + villain 30 m apart both land inside 70 % width and the band above the controls.
##  - result card P0#6: time / min HP / tows straight from the result, ★2 fails with a tow, "포상금 ×1.5" wording.
##  - FX: deterministic under a seed, kill explosion spawns and fully expires, release wave runs front → tail.
##  - world: gantry fade uses a depth pre-pass and dissolves completely near the camera (no lattice).

const GameScene: PackedScene = preload("res://view/game.tscn")

var _fails: int = 0
var _tree: SceneTree


func _check(ok: bool, what: String) -> void:
	print(("PASS" if ok else "FAIL") + " ui: " + what)
	if not ok:
		_fails += 1


func run() -> int:
	_tree = Engine.get_main_loop() as SceneTree
	_input_contract()
	await _hud_contract()
	_result_model()
	await _fx_determinism()
	await _camera_and_reticle()
	await _gantry()
	return _fails


func _touch(inp: LaneInput, idx: int, pos: Vector2, pressed: bool) -> void:
	var t := InputEventScreenTouch.new()
	t.index = idx
	t.position = pos
	t.pressed = pressed
	inp.inject(t)


func _drag(inp: LaneInput, idx: int, pos: Vector2) -> void:
	var d := InputEventScreenDrag.new()
	d.index = idx
	d.position = pos
	inp.inject(d)


func _input_contract() -> void:
	var inp := LaneInput.new()
	_tree.root.add_child(inp)
	inp.pt_override = 1.0
	inp.set_zone("fire", Rect2(400, 900, 140, 140))
	_touch(inp, 0, Vector2(470, 970), true)
	var held: bool = inp.is_fire_down()
	var edge: bool = inp.consume_fire() and not inp.consume_fire()
	# swipe lanes with another finger while 압정 is held (multi-touch)
	_touch(inp, 1, Vector2(200, 600), true)
	_drag(inp, 1, Vector2(160, 602))
	var lane: int = inp.consume_lane()
	_touch(inp, 1, Vector2(160, 602), false)
	var still: bool = inp.is_fire_down()
	_touch(inp, 0, Vector2(470, 970), false)
	_check(held and edge and lane == -1 and still and not inp.is_fire_down(),
		"압정 zone: hold = fire level, one edge per press, lanes swipe while held, release = up")
	# swipe down = brake until the finger lifts
	_touch(inp, 2, Vector2(250, 500), true)
	_drag(inp, 2, Vector2(253, 530))
	var early: bool = inp.is_brake_down()
	_drag(inp, 2, Vector2(255, 548))
	var on: bool = inp.is_brake_down()
	_drag(inp, 2, Vector2(255, 640))
	var hold: bool = inp.is_brake_down()
	_touch(inp, 2, Vector2(255, 640), false)
	_check(not early and on and hold and not inp.is_brake_down() and inp.consume_lane() == 0 and not inp.consume_rage(),
		"swipe down ≥ 40 pt = brake held until the finger lifts (no lane / rage edge)")
	var k := InputEventKey.new()
	k.keycode = KEY_SPACE
	k.pressed = true
	inp.inject(k)
	var kf: bool = inp.is_fire_down()
	k.keycode = KEY_S
	inp.inject(k)
	var kb: bool = inp.is_brake_down()
	inp.release_all()
	_check(kf and kb and not inp.is_fire_down() and not inp.is_brake_down(), "keys Space = fire, S = brake; release_all clears both")
	var dbg: Array[int] = [0]
	inp.debug_requested.connect(func() -> void: dbg[0] += 1)
	for i: int in 3:
		_touch(inp, 10 + i, Vector2(100 + 50 * i, 400), true)
	for i: int in 3:
		_touch(inp, 10 + i, Vector2(100 + 50 * i, 400), false)
	_check(dbg[0] == 1, "three fingers down = debug_requested once (dev panel without an on-screen DBG tab)")
	inp.inject("fire:down")
	var injf: bool = inp.is_fire_down()
	inp.inject("fire:up")
	inp.inject("brake:down")
	var injb: bool = inp.is_brake_down()
	inp.inject("brake:up")
	_check(injf and injb and not inp.is_fire_down() and not inp.is_brake_down(), "inject fire:/brake: down/up")
	inp.queue_free()


func _hud_contract() -> void:
	var inp := LaneInput.new()
	_tree.root.add_child(inp)
	var hud := Hud.new()
	hud.manual = true
	_tree.root.add_child(hud)
	hud.bind_input(inp)
	hud.debug_safe_pt = Vector2(59, 34)
	hud.apply_safe_area()
	hud.apply_state(UiStubState.boss(true))
	hud.advance(0.5)
	await _tree.process_frame
	await _tree.process_frame
	hud._process(0.0)
	var sz: Dictionary = hud.button_sizes_pt()
	var small: PackedStringArray = []
	for n: String in sz:
		if float(sz[n]) < 64.0 - 0.01:
			small.append("%s=%.1f" % [n, float(sz[n])])
	_check(small.is_empty() and sz.size() == 5, "압정 / 분노 / 경적 / ◀ / ▶ all ≥ 64 pt %s %s" % [JSON.stringify(sz), " ".join(small)])
	var sr: Rect2 = hud.safe_rect().grow(4.5)
	var rects: Array[Rect2] = hud.reserved_rects()
	var inside: int = 0
	for r: Rect2 in rects:
		inside += 1 if sr.encloses(r) else 0
	_check(inside == rects.size() and rects.size() >= 10, "boss HUD widgets inside the safe rect (%d/%d)" % [inside, rects.size()])
	var fire_r: Rect2 = hud._btn_fire.get_global_rect()
	var rage_r: Rect2 = hud._btn_rage.get_global_rect()
	var horn_r: Rect2 = hud._btn_horn.get_global_rect()
	var right_r: Rect2 = hud._btn_right.get_global_rect()
	_check(not fire_r.intersects(rage_r) and not fire_r.intersects(horn_r) and not horn_r.intersects(right_r)
		and fire_r.position.x > hud.safe_rect().get_center().x and fire_r.end.y >= hud.safe_rect().end.y - 40.0,
		"압정 bottom-right thumb corner, no control overlaps another")
	_check(hud.lock_in_range and hud.reticle.target.get("in_range") == true and hud._chip.visible,
		"in range: fire ring + reticle green, hint chip shown")
	var chip: String = hud.hint_text
	_check(chip.length() <= 16 and not chip.contains("\n") and chip == "발사 꾹 · 경직 노려", "hint chip one line ≤ 16 chars ('%s')" % chip)
	hud.apply_state(UiStubState.boss(false))
	var t: Dictionary = hud.reticle.target
	_check(not hud.lock_in_range and t.get("in_range") == false and int(t.get("dir", 0)) == -1 and hud.hint_text == "◀ 원흉 차로로",
		"out of range (lane 4 vs villain lane 0): grey reticle, chevrons ◀, chip '◀ 원흉 차로로'")
	# N1 from GameSim's single progress value
	hud.apply_state(UiStubState.jam(0.4))
	_check(is_equal_approx(hud.shown.x, 0.4) and is_equal_approx(hud.shown.y, 102.0) and hud.distance_label() == "원흉까지 102 m",
		"N1: bar and '원흉까지 N m' come from state.progress / distance_m (%s)" % hud.distance_label())
	# events → pops / banners / flash
	var cam := Camera3D.new()
	hud.add_child(cam)
	hud.bind_world(cam, RoadGraph.new())
	for e: Dictionary in UiStubState.events_fight():
		hud.on_event(e)
	_check(hud.pops._pops.size() >= 3 and hud._last_damage.get("amount") == 12, "hit / miss / damage events → pops ('-4', '빗나감!', '-12')")
	hud.apply_state(UiStubState.boss(true))
	hud.apply_state(UiStubState.kill())
	hud.advance(0.6)
	_check(not hud._btn_fire.visible and not hud._chip.visible and hud._boss.visible and hud.banner.current() == "참교육 완료!",
		"kill: controls + chip fade out, villain plate stays, '참교육 완료!' banner")
	var dbg_named: bool = false
	for n: Node in hud.find_children("*", "", true, false):
		if n is Button and (n as Button).text == "DBG":
			dbg_named = true
	_check(not dbg_named, "no DBG badge in the HUD (dev panel: F1 / three-finger tap)")
	# fail card defaults from the last damage event (honest: reason, last hit, tows)
	hud.show_fail({})
	var fd: Dictionary = hud.fail_card.data
	_check(hud.card_open() and str(fd["reason"]) == "원흉 상향등" and int(fd["hp_lost"]) == 12 and int(fd["tows"]) >= 1 and not inp.enabled,
		"fail card: reason / last hit from the damage event, input disabled while open")
	var got: Array[StringName] = []
	hud.card_choice.connect(func(c: StringName) -> void: got.append(c))
	(hud.fail_card._btns["retry"] as Button).pressed.emit()
	hud.fail_card.seek(1.0)
	(hud.fail_card._btns["retry"] as Button).pressed.emit()
	_check(got == [&"retry"], "fail card: retry ignored before 0.45 s (anti mis-tap), then card_choice(&\"retry\")")
	hud.hide_cards()
	_check(not hud.card_open() and inp.enabled, "hide_cards re-enables input")
	hud.queue_free()
	inp.queue_free()
	await _tree.process_frame


func _result_model() -> void:
	var st: Dictionary = {"id": 1, "title": "1차선 정속주행러", "highway": "경부고속도로", "direction": "부산 방향", "route": 1,
		"fine": 40000, "payout": 40000, "violation": "고속도로 지정차로 위반(제60조) 범칙금 승용 4만원", "villains": [{"color": 0xd9c9a3, "name": "정속주행 김사장"}]}
	var m0: Dictionary = ResultCard.model(UiStubState.result(0), {}, st)
	var m1: Dictionary = ResultCard.model(UiStubState.result(1), {}, st)
	_check(int(m0["stars"]) == 3 and int(m1["stars"]) == 2 and not bool((m1["missions"] as Array)[1]["done"]),
		"P0#6: a tow fails ★2 (3★ clean run vs 2★ with 1 tow)")
	_check(is_equal_approx(float(m1["time_s"]), 69.5) and int(m1["min_hp"]) == 0 and int(m1["tows"]) == 1,
		"P0#6: card time / min HP / tows are the stage totals from the result (not reset by the retry)")
	_check(float(m1["payout"]) < float(m0["payout"]) and float(m0["payout"]) > 0.0,
		"payout from Rewards: retry multiplier + fewer stars pay less (%d vs %d)" % [int(m1["payout"]), int(m0["payout"])])
	var rec: Dictionary = {"stars": 1, "payout": 12345, "missions": [{"label": "a", "done": true}, {"label": "b", "done": false},
		{"label": "c", "done": false}], "wallet": 52345, "wallet_before": 40000, "stage_name": "X", "tows": 2}
	var m2: Dictionary = ResultCard.model(UiStubState.result(0), rec, st)
	_check(int(m2["stars"]) == 1 and int(m2["payout"]) == 12345 and int(m2["tows"]) == 2 and float(m2["wallet"]) == 52345.0,
		"Progress.record_result() wins over the sim's own numbers (single evaluator, NATIVE_PARITY G4)")
	var src: String = FileAccess.get_file_as_string("res://ui/result_card.gd")
	_check(src.contains("\"포상금 ×%s\"") and not src.contains("★×"), "multiplier wording '포상금 ×1.5', not '★×1.5' (P0#6)")


func _fx_determinism() -> void:
	var a: Array = []
	for run_i: int in 2:
		var fx := FightFx.new()
		fx.manual = true
		_tree.root.add_child(fx)
		fx.setup(RoadGraph.new(), 42, {}, 200.0, -45.0)
		fx.on_event({"type": "kill", "id": 0, "s": 272.0, "x": -5.4}, UiStubState.kill())
		for i: int in 30:
			fx.advance(1.0 / 30.0)
		var p: Dictionary = (fx._parts[0] as Array)[0] if not (fx._parts[0] as Array).is_empty() else {}
		a.append([fx.counts(), p.get("p", Vector3.ZERO)])
		if run_i == 1:
			for i: int in 150:
				fx.advance(1.0 / 30.0)
			var c: Dictionary = fx.counts()
			_check(int(c["lit"]) + int(c["glow"]) + int(c["smoke"]) == 0, "kill explosion + confetti fully expire within 6 s (%s)" % JSON.stringify(c))
			fx.on_event({"type": "release", "open_lane": 0}, UiStubState.kill())
			var s0: float = fx.wave_s
			fx.advance(0.5)
			_check(is_equal_approx(s0, 200.0) and fx.wave_s < s0 - 30.0, "release wave starts at the jam front (200) and runs to the tail")
		fx.queue_free()
	_check(JSON.stringify(a[0]) == JSON.stringify(a[1]) and int((a[0][0] as Dictionary)["lit"]) > 20,
		"FX deterministic under a seed (same particle state twice: %s)" % JSON.stringify(a[0][0]))
	await _tree.process_frame


func _camera_and_reticle() -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(540, 1168)
	_tree.root.add_child(vp)
	var road := RoadGraph.new()
	var cam := CameraRig.new()
	cam.road = road
	vp.add_child(cam)
	cam.current = true
	# P0#4: villain 30 m behind in lane 0, player in lane 1 → both framed
	var st: Dictionary = UiStubState.boss(true)
	(st["villains"] as Array)[0]["s"] = 227.0
	cam.target_s = 257.0
	cam.target_x = RoadGraph.lane_x(1.0)
	cam.apply_state(st)
	cam.snap()
	var ok: bool = true
	var worst: String = ""
	var pts: Array[Vector3] = [road.position(257.0, RoadGraph.lane_x(1.0)), road.position(227.0, RoadGraph.lane_x(0.0))]
	for p: Vector3 in pts:
		var sp: Vector2 = cam.unproject_position(p)
		var fx: float = sp.x / 540.0
		var fy: float = sp.y / 1168.0
		if fx < 0.15 or fx > 0.85 or fy < CameraRig.FRAME_Y.x - 0.02 or fy > CameraRig.FRAME_Y.y + 0.02:
			ok = false
		worst += " (%.2f, %.2f)" % [fx, fy]
	_check(ok, "P0#4 boss framing: player and villain 30 m apart inside 70 %% width and the band above the controls k=%.2f%s" % [cam.frame_k, worst])
	var r := Reticle.new()
	vp.add_child(r)
	r.camera = cam
	r.road = road
	r.set_target({"s": 227.0, "x": RoadGraph.lane_x(0.0), "len": 4.9, "active": true, "in_range": true, "dir": 0})
	r.advance(0.1)
	var want: Vector2 = cam.unproject_position(road.position(227.0, RoadGraph.lane_x(0.0)) + Vector3(0, 0.9, 0))
	_check(r.on_screen and r.screen_pos.distance_to(want) < 0.01 and r.screen_r >= 34.0, "reticle sits on the unprojected target car (%s vs %s)" % [r.screen_pos, want])
	vp.queue_free()
	await _tree.process_frame


func _gantry() -> void:
	var g: Game = GameScene.instantiate() as Game
	g.manual = true
	g.with_debug_panel = false
	_tree.root.add_child(g)
	var o: Dictionary = g.world.overheads[0]
	var gs: float = float(o["s"])
	var mi: MeshInstance3D = o["node"]
	g.world.update_overheads(g.road.position(gs - 40.0, 0.0) + Vector3(0, 21, 0))
	var far_vis: bool = mi.visible and float(o["f"]) > 0.99
	g.world.update_overheads(g.road.position(gs - 22.0, 0.0) + Vector3(0, 21, 0))
	var mid_f: float = float(o["f"])
	g.world.update_overheads(g.road.position(gs - 8.0, 0.0) + Vector3(0, 21, 0))
	var near_hidden: bool = not mi.visible
	var pre: bool = (o["frame_fade"] as StandardMaterial3D).transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
	_check(far_vis and mid_f > 0.05 and mid_f < 0.95 and near_hidden and pre,
		"gantry: opaque far, depth-prepass fade mid (%.2f), fully hidden under the camera (no translucent lattice)" % mid_f)
	g.queue_free()
	await _tree.process_frame
