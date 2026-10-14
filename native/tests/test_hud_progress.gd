extends RefCounted
## N1 (NATIVE_PORT N1 "진행 바 단일 진실"): over a 60 s run of the real game scene (GameSim on TrafficBridge, C++ when
## the ext loads; scripted lane changes and honks through LaneInput), EVERY tick until the front lock the HUD bar
## fraction and the "원흉까지 N m" label equal the values derived from the live distance player → villain:
##   bar  = clamp((p − s0) / (v − s0), 0, 1) = 1 − dist / span     label = "원흉까지 round(v − p) m"
## with p = player s, v = the villain reference s from the boss sim (BossSim.ref_s()), s0 = setup_info start_s.
## r3 U2 (A3 checkpoints 150 / 100 / 60 m, feedback 1·3 "가는 동안 할 게 없음"): every tick the bar's checkpoint ticks
## sit at the threshold's bar position (1 − d / span) ±2 px, and on each checkpoint event the player marker is on its
## tick (±2 px), the tick pulses and the "N m 돌파!" toast shows for 0.8 s — on the C++ traffic and the GDScript fallback.
## 가설: ✅ the ticks only read as "3 steps to the villain" if the tick the marker crosses is where the event fires.

const GameScene: PackedScene = preload("res://view/game.tscn")
const SECONDS: float = 60.0
const EPS: float = 1e-4
const PX: float = 2.0

var _fails: int = 0


func _check(ok: bool, what: String) -> void:
	print(("PASS" if ok else "FAIL") + " hud_progress: " + what)
	if not ok:
		_fails += 1


func run() -> int:
	var tree := Engine.get_main_loop() as SceneTree
	await _run_one(tree, "auto")
	await _run_one(tree, "fallback")
	await _toast_stub(tree)
	return _fails


func _run_one(tree: SceneTree, mode: String) -> void:
	var g: Game = GameScene.instantiate() as Game
	g.manual = true
	g.with_debug_panel = false
	g.traffic_mode = mode
	tree.root.add_child(g)
	var bridge: bool = g.traffic is TrafficBridge
	var native: bool = bridge and bool(g.traffic.call(&"is_native"))
	var tag: String = "native" if native else "fallback"
	print("INFO hud_progress: traffic=%s native=%s (mode %s)" % [g.traffic.get_script().resource_path, native, mode])
	if mode == "fallback" and native:
		_check(false, "traffic_mode fallback still runs the C++ core")
	if bridge:
		var si: Dictionary = g.traffic.call(&"setup_info")
		_check(is_equal_approx(g.start_s, float(si["start_s"])), "%s: start_s is the sim's setup_info start_s (%.2f)" % [tag, g.start_s])
	var n: int = roundi(SECONDS * 120.0)
	var schedule: Dictionary = {240: "lane:-1", 900: "horn", 1500: "lane:1", 2400: "horn", 3600: "lane:-1", 5000: "horn"}
	var worst_bar: float = 0.0
	var worst_villain: float = 0.0
	var bad_label: int = 0
	var bad_player: int = 0
	var first_bad: String = ""
	var v_first: float = NAN
	var v_last: float = NAN
	var p_first: float = g.player.s
	var replies: PackedStringArray = []
	var bubbled: int = 0
	var worst_tick: float = 0.0
	var tick_frames: int = 0
	var cp_events: Array[Dictionary] = []
	var cp_bad: PackedStringArray = []
	var pending: Array[Dictionary] = []
	g.event_tap = func(e: Dictionary) -> void:
		if str(e.get("type", "")) == "checkpoint":
			pending.append(e)
	for i: int in n:
		if schedule.has(i):
			var cmd: String = schedule[i]
			if cmd == "horn":
				g.input.inject("horn:down")
				g.input.inject("horn:up")
			else:
				g.input.inject(cmd)
		g.advance_ticks(1)
		if schedule.get(i, "") == "horn":
			var kind: String = str(g.last_honk_reply.get("kind", ""))
			replies.append(kind if not kind.is_empty() else "-")
			if not kind.is_empty() and g.bubbles.count() > 0:
				bubbled += 1
		# checkpoint events of this tick: the marker is on that checkpoint's tick, the tick pulses, the toast shows
		for e: Dictionary in pending:
			var ci: int = int(e.get("i", -1))
			var xs: PackedFloat32Array = g.hud.checkpoint_xs()
			var mx: float = g.hud.bar_marker_x()
			var dx: float = absf(xs[ci] - mx) if ci >= 0 and ci < xs.size() else INF
			var toast: String = g.hud.cp_toast_text()
			cp_events.append({"i": ci, "d": float(e.get("d", 0.0)), "dx": dx, "toast": toast, "pulse": g.hud.checkpoint_pulsing(ci)})
			if dx > PX or not toast.begins_with("%dm 돌파!" % roundi(float(e.get("d", 0.0)))) or not g.hud.checkpoint_pulsing(ci):
				cp_bad.append("cp%d d=%.0f dx=%.2f px toast '%s'" % [ci, float(e.get("d", 0.0)), dx, toast])
		pending.clear()
		if g.sim.front_locked or not (g.phase in [&"intro", &"jam", &"boss"]):
			break  # N1 is the approach bar; after the lock the HUD shows the villain plate
		var p: float = g.player.s
		var v_live: float = _villain_s(g)
		if is_nan(v_first):
			v_first = v_live
		v_last = v_live
		var span: float = maxf(1.0, v_live - g.start_s)
		var dist: float = maxf(0.0, v_live - p)
		var want: float = clampf(1.0 - dist / span, 0.0, 1.0) if v_live >= p else 1.0
		var e_bar: float = absf(g.hud.shown.x - want)
		worst_bar = maxf(worst_bar, e_bar)
		worst_villain = maxf(worst_villain, absf(g.hud.villain_s - v_live))
		if absf(g.hud.player_s - p) > EPS:
			bad_player += 1
		var label: String = g.hud.distance_label()
		if label != Hud.distance_text(dist) or absf(g.hud.shown.y - dist) > EPS:
			bad_label += 1
		if first_bad.is_empty() and (e_bar > EPS or label != Hud.distance_text(dist)):
			first_bad = "tick %d: bar %.6f want %.6f, label '%s' want '%s'" % [i, g.hud.shown.x, want, label, Hud.distance_text(dist)]
		# checkpoint ticks at 1 − d / span of the live span
		var cps: Array = g.st.get("checkpoints", []) if g.st.get("checkpoints") is Array else []
		var xs2: PackedFloat32Array = g.hud.checkpoint_xs()
		if xs2.size() == cps.size() and not cps.is_empty():
			tick_frames += 1
			for ci: int in cps.size():
				var fw: float = clampf(1.0 - float((cps[ci] as Dictionary)["d"]) / span, 0.0, 1.0)
				worst_tick = maxf(worst_tick, absf(xs2[ci] - g.hud.bar_x(fw)))
		elif not cps.is_empty():
			worst_tick = INF
	print("INFO hud_progress: %s %d ticks, player %.1f → %.1f m, villain %.1f → %.1f m, honks %d, lane changes %d, checkpoints %s" % [tag, n, p_first,
		g.player.s, v_first, v_last, _count(g, "honk"), _count(g, "lane"), JSON.stringify(cp_events)])
	_check(worst_villain < EPS, "%s: HUD villain_s is the sim's live villain s every tick (max err %.6f m)" % [tag, worst_villain])
	_check(bad_player == 0, "%s: HUD player_s is the driver's s every tick (%d bad)" % [tag, bad_player])
	_check(worst_bar < EPS, "%s: bar fraction == 1 − dist/span every tick for %.0f s (max err %.6f)%s" % [tag, SECONDS, worst_bar,
		"" if first_bad.is_empty() else " first: " + first_bad])
	_check(bad_label == 0, "%s: label == '원흉까지 round(dist) m' every tick (%d bad)" % [tag, bad_label])
	_check(v_last > v_first + 1.0 and g.player.s > p_first + 1.0, "%s: both ends moved (the check is not a static frame)" % tag)
	_check(_count(g, "honk") >= 2, "%s: scripted honks went through the input path" % tag)
	var answered: int = replies.size() - replies.count("-")
	if mode == "auto":
		_check(answered > 0 and bubbled == answered, "every answered honk shows a reply bubble (replies %s, bubbles %d)" % [
			",".join(replies), bubbled])
	else:
		_check(bubbled == answered, "%s: every answered honk shows a reply bubble (replies %s, bubbles %d)" % [tag, ",".join(replies), bubbled])
	_check(tick_frames > 100 and worst_tick <= PX, "U2 %s: checkpoint ticks at 1 − d/span every tick ±%.0f px (%d frames, worst %.3f px)" % [
		tag, PX, tick_frames, worst_tick])
	_check(cp_events.size() >= 2 and cp_bad.is_empty(),
		"U2 %s: %d checkpoint events, the marker sits on that tick ±%.0f px + pulse + 'N m 돌파!' toast %s" % [tag, cp_events.size(), PX,
		"" if cp_bad.is_empty() else str(cp_bad)])
	g.queue_free()
	await tree.process_frame


## Toast lifetime + chip placement on a stub jam frame (no sim): 0.8 s, under the pill, clear of the bar / pill.
func _toast_stub(tree: SceneTree) -> void:
	var inp := LaneInput.new()
	tree.root.add_child(inp)
	var hud := Hud.new()
	hud.manual = true
	tree.root.add_child(hud)
	hud.bind_input(inp)
	var st: Dictionary = UiStubState.jam(0.4)
	st["checkpoints"] = [{"d": 150.0, "done": true, "fast": false}, {"d": 100.0, "done": false, "fast": false}, {"d": 60.0, "done": false, "fast": false}]
	hud.apply_state(st)
	hud.advance(0.5)
	await tree.process_frame
	hud.on_event({"type": "checkpoint", "i": 0, "ord": 1, "d": 150.0, "dist": 149.8, "fast": true, "score": 150, "rage": 0.04, "n": 3})
	hud.advance(0.1)
	var t0: String = hud.cp_toast_text()
	var r: Rect2 = hud._cp_chip.get_global_rect()
	var clear: bool = hud._cp_chip.visible and not r.intersects(hud._bar.get_global_rect()) and not r.intersects(hud._pill.get_global_rect())
	var guard_ok: bool = hud.top_guard_y() >= r.end.y + 6.0 - 0.01
	hud.advance(0.8)
	var t1: String = hud.cp_toast_text()
	var xs: PackedFloat32Array = hud.checkpoint_xs()
	_check(t0.begins_with("150m 돌파!") and t0.contains("빠름") and t1.is_empty() and clear and guard_ok and xs.size() == 3 and xs[0] < xs[1] and xs[1] < xs[2],
		"U2 toast '%s' for 0.8 s (then '%s'), under the pill clear of bar / pill, in the top guard; ticks ordered %s" % [t0, t1, str(xs)])
	hud.queue_free()
	inp.queue_free()
	await tree.process_frame


func _villain_s(g: Game) -> float:
	return g.sim.boss.ref_s()


func _count(g: Game, type: String) -> int:
	var c: int = 0
	for e: Dictionary in g.log_events:
		if str(e.get("type", "")) == type:
			c += 1
	return c
