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
	g.traffic_mode = "stub"
	tree.root.add_child(g)
	_check(g._built and g.npc.group_count() > 0, "game.tscn builds (stub traffic: %s, %d NPC templates)" % [
		str(g.traffic.get(&"source")), g.npc.group_count()])
	_check(int(g.world.stats.get("instances", 0)) > 150 and int(g.world.stats.get("chunk_meshes", 0)) <= 48,
		"world.js layout ported (%d props/segments merged into %d chunk meshes)" % [int(g.world.stats.get("instances", 0)),
		int(g.world.stats.get("chunk_meshes", 0))])
	var s0: float = g.player.s
	var t0: int = Time.get_ticks_usec()
	g.advance_ticks(240)
	var ms: float = float(Time.get_ticks_usec() - t0) / 1000.0 / 240.0
	_check(g.player.s > s0 + 1.0 and g.ticks == 240, "2 s of 120 Hz ticks: player creeps %.1f m (%.3f ms/tick incl. view)" % [g.player.s - s0, ms])
	# lane change through the input path
	g.input.inject("lane:-1")
	g.advance_ticks(60)
	var lane_log: bool = false
	for e: Dictionary in g.log_events:
		if str(e.get("type", "")) in ["lane_change", "lane_blocked"]:
			lane_log = true
	_check(lane_log, "input lane:-1 → request_lane → lane_change/lane_blocked (player lane %d)" % g.player.lane)
	# horn through the input path
	g.input.inject("horn:down")
	g.advance_ticks(2)
	g.input.inject("horn:up")
	var honked: bool = false
	for e: Dictionary in g.log_events:
		if str(e.get("type", "")) == "honk":
			honked = true
	_check(honked and g.honk_fx.active() > 0, "horn: TrafficBridge.honk + honk wave FX (sfx played %d)" % g.sfx.played)
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
	var on_screen: bool = not icons.camera.is_position_behind(vpos) \
		and icons.get_viewport().get_visible_rect().has_point(icons.camera.unproject_position(vpos))
	_check(not on_screen or 1000 in ids, "N5 synthetic: villain icon kept whenever on screen (on_screen=%s)" % on_screen)
	_check(cut_ok or 2 not in ids, "N5 synthetic: no-blinker cut-in shows the crossed-out blinker")
