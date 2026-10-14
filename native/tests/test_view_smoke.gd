extends RefCounted
## T0 view smoke test (M1a): the jam scene builds headless, the fixed-tick loop runs, input → lane change / horn,
## N1 single truth, N5 icon rules (≤ 4, no overlap, blink phase = lamp phase), RoadGraph straight mapping,
## swipe thresholds in points, bundled font / horn SFX present.
## Rendering checks (draw budget, ΔE, look) live in tests/shot_jam.gd (needs Xvfb).

const GameScene: PackedScene = preload("res://view/game.tscn")

var _fails: int = 0


func _check(ok: bool, what: String) -> void:
	if ok:
		print("PASS view_smoke: " + what)
	else:
		print("FAIL view_smoke: " + what)
		_fails += 1


func run() -> int:
	var tree := Engine.get_main_loop() as SceneTree
	_road()
	_progress()
	_blink_phase()
	_swipe(tree)
	_touch_emulation(tree)
	_assets()
	await _scene(tree)
	return _fails


func _road() -> void:
	var r := RoadGraph.new([{"type": "straight"}])
	var xf: Transform3D = r.world(123.5, -5.4)
	_check(xf.origin.is_equal_approx(Vector3(-5.4, 0, -123.5)) and xf.basis.is_equal_approx(Basis.IDENTITY),
		"RoadGraph straight: world(s, x) = (x, 0, −s)")
	_check(is_equal_approx(RoadGraph.lane_x(0), -5.4) and is_equal_approx(RoadGraph.lane_x(3), 5.4) \
		and is_equal_approx(RoadGraph.lane_x(4), 9.0) and is_equal_approx(RoadGraph.opp_lane_x(0), -11.1),
		"laneX(0..4) = −5.4 … 5.4, shoulder 9.0, opposite j0 −11.1")
	_check(r.to_road(r.position(42.0, 1.8)).is_equal_approx(Vector2(42.0, 1.8)), "RoadGraph to_road inverts position")


func _progress() -> void:
	var worst: float = 0.0
	for i: int in 50:
		var s0: float = float(i % 3) * 5.0
		var v: float = 150.0 + float(i) * 3.7
		var p: float = s0 + (v - s0) * float(i) / 49.0
		var pv: Vector2 = Hud.progress_values(p, v, s0)
		worst = maxf(worst, absf(pv.x * (v - s0) + pv.y - (v - s0)))
	_check(worst < 1e-3, "N1: bar fraction and distance come from one value pair (max err %.5f m)" % worst)
	_check(Hud.progress_values(300.0, 200.0, 0.0) == Vector2(1.0, 0.0), "N1: past the villain clamps to 100 % / 0 m")


func _blink_phase() -> void:
	# web setBlinker: on while ((t + (id%7)·0.09) mod 2/3) < 1/3
	var ok: bool = NpcMultiMesh.blink_lit(0.0, 0) and not NpcMultiMesh.blink_lit(0.4, 0) \
		and NpcMultiMesh.blink_lit(0.4 - 0.09, 1) == (fposmod(0.4, 2.0 / 3.0) < 1.0 / 3.0)
	_check(ok, "blink phase matches vehicles.js BLINK_PERIOD 2/3 with per-car offset")
	_check(NpcMultiMesh.drawn_bits(2 | 1, 0.4, 0) == 1 and NpcMultiMesh.drawn_bits(4 | 1, 0.0, 0) == 5,
		"drawn_bits clears the blinker during the dark half only")


func _swipe(tree: SceneTree) -> void:
	var inp := LaneInput.new()
	tree.root.add_child(inp)
	inp.pt_override = 1.0
	var press := InputEventScreenTouch.new()
	press.index = 0
	press.pressed = true
	press.position = Vector2(200, 600)
	inp.inject(press)
	var drag := InputEventScreenDrag.new()
	drag.index = 0
	drag.position = Vector2(225, 604)  # 25 pt: below 34 pt
	inp.inject(drag)
	var none: int = inp.peek_lane()
	drag.position = Vector2(240, 606)  # 40 pt right, |dx| > 1.2|dy|
	inp.inject(drag)
	var got: int = inp.consume_lane()
	var rel := InputEventScreenTouch.new()
	rel.index = 0
	rel.pressed = false
	inp.inject(rel)
	press.position = Vector2(200, 600)
	inp.inject(press)
	drag.position = Vector2(205, 535)  # 65 pt up → rage
	inp.inject(drag)
	inp.inject(rel)
	_check(none == 0 and got == 1 and inp.consume_rage(), "swipe: 25 pt ignored, 40 pt right = lane +1, 65 pt up = rage")
	inp.set_zone("horn", Rect2(400, 800, 100, 100))
	var t2 := InputEventScreenTouch.new()
	t2.index = 1
	t2.pressed = true
	t2.position = Vector2(450, 850)
	inp.inject(t2)
	var down: bool = inp.is_horn_down() and inp.consume_horn()
	t2.pressed = false
	inp.inject(t2)
	_check(down and not inp.is_horn_down(), "horn zone: finger 1 press/release = horn down/up (multi-touch path)")
	inp.queue_free()


## Touch → one edge, even though emulate_mouse_from_touch (kept on for debug_panel Buttons) also delivers every touch
## as an emulated mouse event (device == DEVICE_ID_EMULATION). Review: one tap / one swipe gave 2 lane edges.
## Events go through Input.parse_input_event + flush (the real emulation path) when this display server dispatches
## them (Xvfb), and through Viewport.push_input with hand-made emulated mouse twins otherwise (headless drops them).
func _touch_emulation(tree: SceneTree) -> void:
	var inp := LaneInput.new()
	tree.root.add_child(inp)
	inp.pt_override = 1.0
	var real_path: bool = DisplayServer.get_name() != "headless"
	var send := func(ev: InputEvent) -> void:
		if real_path:
			Input.parse_input_event(ev)
			Input.flush_buffered_events()
			return
		tree.root.push_input(ev)
		var twin: InputEventMouse = null
		if ev is InputEventScreenTouch:
			var mb := InputEventMouseButton.new()
			mb.button_index = MOUSE_BUTTON_LEFT
			mb.pressed = (ev as InputEventScreenTouch).pressed
			mb.button_mask = MOUSE_BUTTON_MASK_LEFT if mb.pressed else 0
			twin = mb
		elif ev is InputEventScreenDrag:
			var mm := InputEventMouseMotion.new()
			mm.button_mask = MOUSE_BUTTON_MASK_LEFT
			mm.relative = (ev as InputEventScreenDrag).relative
			twin = mm
		if twin != null:
			twin.device = InputEvent.DEVICE_ID_EMULATION
			twin.position = (ev as Variant).position
			twin.global_position = twin.position
			tree.root.push_input(twin)
	var touch := func(pos: Vector2, pressed: bool) -> InputEventScreenTouch:
		var t := InputEventScreenTouch.new()
		t.index = 0
		t.position = pos
		t.pressed = pressed
		return t
	inp.set_zone("left", Rect2(-1.0e5, -1.0e5, 2.0e5, 2.0e5))
	send.call(touch.call(Vector2(100, 800), true))
	send.call(touch.call(Vector2(100, 800), false))
	var tap: Array[int] = []
	while inp.peek_lane() != 0:
		tap.append(inp.consume_lane())
	inp.set_zone("left", Rect2())
	send.call(touch.call(Vector2(100, 600), true))
	var d := InputEventScreenDrag.new()
	d.index = 0
	d.position = Vector2(300, 604)
	d.relative = Vector2(200, 4)
	send.call(d)
	send.call(touch.call(Vector2(300, 604), false))
	var swipe: Array[int] = []
	while inp.peek_lane() != 0:
		swipe.append(inp.consume_lane())
	_check(ProjectSettings.get_setting("input_devices/pointing/emulate_mouse_from_touch", false) == true,
		"emulate_mouse_from_touch is on (debug_panel Buttons rely on it)")
	_check(tap == [-1] and swipe == [1], "touch + emulated mouse (%s): 1 tap on ◀ = 1 edge (got %s), 1 swipe = 1 edge (got %s)" \
		% ["Input.parse_input_event" if real_path else "push_input twins", tap, swipe])
	inp.queue_free()


func _assets() -> void:
	var f: Font = load("res://ui/fonts/BlackHanSans-Regular.ttf") if ResourceLoader.exists("res://ui/fonts/BlackHanSans-Regular.ttf") else null
	if f == null:
		var ff := FontFile.new()
		if ff.load_dynamic_font("res://ui/fonts/BlackHanSans-Regular.ttf") == OK:
			f = ff
	var all_ok: bool = f != null
	if f != null:
		for ch: String in "원흉까지경적범퍼분노참교육1차선km/h0123456789":
			all_ok = all_ok and f.has_char(ch.unicode_at(0))
	_check(all_ok, "Black Han Sans bundled and covers the HUD strings")
	_check(FileAccess.file_exists("res://ui/fonts/OFL.txt"), "OFL.txt next to the font")
	var horn: AudioStream = load("res://audio/horn.wav") if ResourceLoader.exists("res://audio/horn.wav") \
		else AudioStreamWAV.load_from_file("res://audio/horn.wav")
	_check(horn != null and absf(horn.get_length() - 0.515) < 0.05, "horn.wav baked (%.3f s)" % (horn.get_length() if horn else -1.0))


func _scene(tree: SceneTree) -> void:
	var g: Game = GameScene.instantiate() as Game
	g.manual = true
	g.with_debug_panel = false
	tree.root.add_child(g)
	_check(g._built and g.npc.group_count() > 0 and g.sim != null, "game.tscn builds on GameSim (traffic %s native=%s, %d NPC templates)" % [
		g.traffic.get_script().resource_path, g.sim.traffic().is_native(), g.npc.group_count()])
	_check(int(g.world.stats.get("instances", 0)) > 150 and int(g.world.stats.get("chunk_meshes", 0)) <= 48,
		"world.js layout ported (%d props/segments merged into %d chunk meshes)" % [int(g.world.stats.get("instances", 0)),
		int(g.world.stats.get("chunk_meshes", 0))])
	var s0: float = g.player.s
	var t0: int = Time.get_ticks_usec()
	g.advance_ticks(480)  # intro 2.05 s, then the jam creep
	var ms: float = float(Time.get_ticks_usec() - t0) / 1000.0 / 480.0
	_check(g.player.s > s0 + 1.0 and g.ticks == 480 and g.phase == &"jam", "4 s of 120 Hz ticks: intro → jam, player creeps %.1f m (%.3f ms/tick incl. view)" % [
		g.player.s - s0, ms])
	# lane change through the input path: GameSim answers with a lane event or a blocked / closed bubble
	g.input.inject("lane:-1")
	g.advance_ticks(60)
	var lane_log: bool = false
	for e: Dictionary in g.log_events:
		if str(e.get("type", "")) == "lane" or (str(e.get("type", "")) == "bubble" and float(e.get("t", 0.0)) > 3.9):
			lane_log = true
	_check(lane_log, "input lane:-1 → GameSim.input(lane) → lane / blocked bubble (player lane %d)" % g.player.lane)
	# horn through the input path
	g.input.inject("horn:down")
	g.advance_ticks(2)
	g.input.inject("horn:up")
	var honked: bool = false
	for e: Dictionary in g.log_events:
		if str(e.get("type", "")) == "honk":
			honked = true
	_check(honked and g.honk_fx.active() > 0, "horn: GameSim honk event + honk wave FX (sfx played %d)" % g.sfx_played)
	_safe_area(g)
	_camera_follows(g)
	# N5 icon rules on the live buffer
	var cur: PackedFloat32Array = g.buffer()
	var shown: Array[Dictionary] = g.icons.update_icons(cur, {"s": g.player.s, "x": g.player.x, "lane": g.player.lane}, g.real_time)
	var rule_ok: bool = shown.size() <= SignalIcons.MAX_ICONS and g.icons.last_overlaps() == 0
	for c: Dictionary in shown:
		var near: bool = absf(float(c["s"]) - g.player.s) <= SignalIcons.NEAR_M
		rule_ok = rule_ok and (near or bool(c["villain"]) or g.icons._events.has(int(c["id"])))
	_check(rule_ok, "N5: %d icons ≤ 4, overlaps 0, only villain / ≤ 25 m / event cars" % shown.size())
	_n5_synthetic(g)
	g.queue_free()
	await tree.process_frame


## Safe area (NATIVE_PORT 3-8): with a fake 59 / 34 pt Dynamic Island / home-indicator inset every HUD widget (bar,
## pill, rows, gauge, buttons, pause) lies inside safe_rect(), and the pause zone emits pause_requested.
func _safe_area(g: Game) -> void:
	g.hud.debug_safe_pt = Vector2(59, 34)
	g.hud.apply_safe_area()
	g.hud.safe.size = g.hud.root.size - Vector2(g.hud.insets.x + g.hud.insets.z, g.hud.insets.y + g.hud.insets.w)
	g.hud.safe.position = Vector2(g.hud.insets.x, g.hud.insets.y)
	var sr: Rect2 = g.hud.safe_rect().grow(4.5)  # reserved_rects() are grown by 4
	var inside: int = 0
	var rects: Array[Rect2] = g.hud.reserved_rects()
	for r: Rect2 in rects:
		inside += 1 if sr.encloses(r) else 0
	_check(g.hud.insets.y > 70.0 and g.hud.insets.w > 40.0 and inside == rects.size(),
		"safe area: insets top %.0f / bottom %.0f units, %d/%d HUD widgets inside the safe rect" % [g.hud.insets.y,
		g.hud.insets.w, inside, rects.size()])
	g.hud.debug_safe_pt = Vector2.ZERO
	g.hud.apply_safe_area()
	var inp := LaneInput.new()
	g.add_child(inp)
	var n: Array[int] = [0]
	inp.pause_requested.connect(func() -> void: n[0] += 1)
	inp.set_zone("pause", Rect2(500, 60, 40, 40))
	var t := InputEventScreenTouch.new()
	t.position = Vector2(520, 80)
	t.pressed = true
	inp.inject(t)
	_check(n[0] == 1, "pause button zone → pause_requested")
	inp.queue_free()


## advance_ticks keeps the camera target on the player every tick (review: shots framed the start of the call).
## Bug shape: the smoothing converged on the target from the start of the call, so the camera lagged by the whole
## displacement of the call; fixed, it lags by the smoothing only.
func _camera_follows(g: Game) -> void:
	var s0: float = g.player.s
	g.advance_ticks(600)
	var disp: float = g.player.s - s0
	var p0: Vector3 = g.camera.global_position
	g.camera.snap()
	var err: float = (g.camera.global_position - p0).length()
	_check(disp > 1.0 and err < 0.5 * disp,
		"advance_ticks: camera follows the player every tick (moved %.2f m, camera off its target by %.2f m)" % [disp, err])


## Synthetic buffer: 6 signalling cars around the player + a villain far ahead → 4 icons max, villain kept,
## no-blinker cut-in event wins over its blinker, blink icon dims in the dark half.
func _n5_synthetic(g: Game) -> void:
	var icons: SignalIcons = g.icons
	var ps: float = g.player.s
	var rows: Array = [
		[1, 0, 3, 5.4, ps + 8.0, 0.0, 2.0, 2],       # blink L, same lane ahead
		[2, 0, 2, 1.8, ps + 12.0, 0.0, 2.0, 4],      # blink R
		[3, 0, 3, 5.4, ps + 20.0, 0.0, 2.0, 1],      # brake (not directly ahead: car 1 is)
		[4, 0, 1, -1.8, ps + 5.0, 0.0, 2.0, 16],     # hazard lit
		[5, 0, 2, 1.8, ps - 10.0, 0.0, 2.0, 2],      # blink L behind
		[6, 0, 1, -1.8, ps + 60.0, 0.0, 2.0, 2],     # blink but 60 m away, no event → never
		[1000, 8, 0, -5.4, ps + 150.0, 0.0, 2.0, 64 | 1],  # villain braking far ahead → kept
	]
	var buf := PackedFloat32Array()
	for r: Array in rows:
		for v: Variant in r:
			buf.append(float(v))
	icons.on_event({"type": "cutin", "id": 2, "data": {"blinker": false, "from": 1, "to": 2}}, g.real_time)
	icons.lamp_time = 0.0
	var shown: Array[Dictionary] = icons.update_icons(buf, {"s": ps, "x": 5.4, "lane": 3}, g.real_time)
	var ids: Array[int] = []
	var cut_ok: bool = false
	for c: Dictionary in shown:
		ids.append(int(c["id"]))
		if int(c["id"]) == 2:
			cut_ok = int(c["icon"]) == SignalIcons.Icon.CUTIN_R
	_check(shown.size() <= 4 and 6 not in ids and icons.last_overlaps() == 0,
		"N5 synthetic: %d icons %s, far car 6 excluded, no overlap" % [shown.size(), str(ids)])
	var vpos := Vector3(-5.4, 3.3, -(ps + 150.0))
	var vsp: Vector2 = icons.camera.unproject_position(vpos)
	var on_screen: bool = not icons.camera.is_position_behind(vpos) \
		and icons.get_viewport().get_visible_rect().grow(-40.0).has_point(vsp)
	var under_hud: bool = false  # icons never sit under the HUD (bar / pill / buttons): review 'N5 slot budget'
	for q: Rect2 in icons.reserved:
		under_hud = under_hud or q.grow(40.0).has_point(vsp)
	_check(not on_screen or under_hud or 1000 in ids,
		"N5 synthetic: villain icon kept whenever on screen and clear of the HUD (on_screen=%s under_hud=%s)" % [on_screen, under_hud])
	var covers: int = 0
	for c: Dictionary in shown:
		for q: Rect2 in icons.reserved:
			covers += 1 if (c["rect"] as Rect2).intersects(q) else 0
	_check(not icons.reserved.is_empty() and covers == 0,
		"N5 synthetic: no icon covers a HUD rect (%d HUD rects, %d covered)" % [icons.reserved.size(), covers])
	_check(cut_ok or 2 not in ids, "N5 synthetic: no-blinker cut-in shows the crossed-out blinker")
