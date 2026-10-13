extends RefCounted
## N1 (NATIVE_PORT N1 "진행 바 단일 진실"): over a 60 s run of the real game scene (TrafficBridge, C++ when the ext
## loads; player driver; scripted lane changes and honks), EVERY tick the HUD bar fraction and the "원흉까지 N m"
## label equal the values derived from the live distance player → villain:
##   bar  = clamp((p − s0) / (v − s0), 0, 1) = 1 − dist / span     label = "원흉까지 round(v − p) m"
## with p = player s, v = the villain's live s from the sim (TrafficBridge.villains()), s0 = setup_info start_s.

const GameScene: PackedScene = preload("res://view/game.tscn")
const SECONDS: float = 60.0
const EPS: float = 1e-4

var _fails: int = 0


func _check(ok: bool, what: String) -> void:
	print(("PASS" if ok else "FAIL") + " hud_progress: " + what)
	if not ok:
		_fails += 1


func run() -> int:
	var tree := Engine.get_main_loop() as SceneTree
	var g: Game = GameScene.instantiate() as Game
	g.manual = true
	g.with_debug_panel = false
	tree.root.add_child(g)
	var bridge: bool = g.traffic is TrafficBridge
	var native: bool = bridge and bool(g.traffic.call(&"is_native"))
	print("INFO hud_progress: traffic=%s native=%s" % [g.traffic.get_script().resource_path, native])
	if bridge:
		var si: Dictionary = g.traffic.call(&"setup_info")
		_check(is_equal_approx(g.start_s, float(si["start_s"])), "start_s is the sim's setup_info start_s (%.2f)" % g.start_s)
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
	print("INFO hud_progress: %d ticks, player %.1f → %.1f m, villain %.1f → %.1f m, honks %d, lane changes %d" % [n, p_first,
		g.player.s, v_first, v_last, _count(g, "honk"), _count(g, "lane_change")])
	_check(worst_villain < EPS, "HUD villain_s is the sim's live villain s every tick (max err %.6f m)" % worst_villain)
	_check(bad_player == 0, "HUD player_s is the driver's s every tick (%d bad)" % bad_player)
	_check(worst_bar < EPS, "bar fraction == 1 − dist/span every tick for %.0f s (max err %.6f)%s" % [SECONDS, worst_bar,
		"" if first_bad.is_empty() else " first: " + first_bad])
	_check(bad_label == 0, "label == '원흉까지 round(dist) m' every tick (%d bad)" % bad_label)
	_check(v_last > v_first + 1.0 and g.player.s > p_first + 1.0, "both ends moved (the check is not a static frame)")
	_check(_count(g, "honk") >= 2, "scripted honks went through the input path")
	var answered: int = replies.size() - replies.count("-")
	_check(answered > 0 and bubbled == answered, "every answered honk shows a reply bubble (replies %s, bubbles %d)" % [
		",".join(replies), bubbled])
	g.queue_free()
	await tree.process_frame
	return _fails


func _villain_s(g: Game) -> float:
	if g.traffic.has_method(&"villains"):
		var vs: Array = g.traffic.call(&"villains")
		if not vs.is_empty():
			return float((vs[0] as Dictionary)["s"])
	return g._villain_s


func _count(g: Game, type: String) -> int:
	var c: int = 0
	for e: Dictionary in g.log_events:
		if str(e.get("type", "")) == type:
			c += 1
	return c
