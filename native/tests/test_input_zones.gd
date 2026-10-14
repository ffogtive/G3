extends RefCounted
## T0: 압정 (fire) never honks, 경적 still honks — sim level and through real touches on the HUD button rects, in the
## jam, the boss approach (unlocked) and the front-locked fight, native traffic and the GDScript fallback.
## 가설: ✅ device feedback 2026-10-14 #3 ("압정버튼을 눌렀는데 경적이 됨") = GameSim turned a 압정 press in the jam
## without a mini target into a honk (web main.js:1055 wantHorn parity), not a touch-zone overlap: the zones are
## disjoint (checked here too) and LaneInput routes the fire rect to fire only.

const GameScene: PackedScene = preload("res://view/game.tscn")
const _DB := preload("res://core/db.gd")

var _fails: int = 0
var _tree: SceneTree


func _check(ok: bool, what: String) -> void:
	print(("PASS" if ok else "FAIL") + " input_zones: " + what)
	if not ok:
		_fails += 1


func run() -> int:
	_tree = Engine.get_main_loop() as SceneTree
	var modes: Array[bool] = [true]
	if TrafficBridge.native_available():
		modes.push_front(false)
	for fb: bool in modes:
		_sim_level(fb)
	for fb: bool in modes:
		await _touch_level(fb)
	return _fails


# ── sim level ──────────────────────────────────────────────────────────────────────────────────────

func _count(sim: GameSim, ticks: int, fire: Variant, tally: Dictionary) -> void:
	for i: int in ticks:
		if fire != null:
			sim.input(&"fire", bool(fire))
		sim.step(Cfg.TICK)
		for e: Dictionary in sim.events():
			var t: String = str(e.get("type", ""))
			tally[t] = int(tally.get(t, 0)) + 1


## Puts the player into the requested situation: &"jam" (as spawned), &"boss" (20 m behind the villain one lane over,
## not locked) or &"locked" (front lock taken).
func _place(sim: GameSim, where: StringName) -> void:
	if where == &"jam":
		return
	var v0: Dictionary = sim.boss.alive()[0]
	var vl: int = BossSim.lanes_of(v0)[0]
	var side: int = vl + 1 if vl < 3 else vl - 1
	sim.player.lane = side
	sim.player.x = Cfg.lane_x(side)
	sim.player.lc_t = 1.0
	sim.player.s = sim.boss.ref_s() + (6.0 if where == &"locked" else -20.0)
	sim.player.v = sim.boss.ref_v()


func _sim_level(fb: bool) -> void:
	var tag: String = "fallback" if fb else "native"
	var stage: Dictionary = _DB.find_stage(_DB.load_json(_DB.DATA_DIR + "/stages.json"), 1)
	for where: StringName in [&"jam", &"boss", &"locked"]:
		var sim := GameSim.new()
		sim.force_fallback = fb
		sim.setup(stage, _DB.load_traffic_tables(), 31)
		sim.input(&"continue")
		var pre: Dictionary = {}
		_count(sim, 400, null, pre)
		_place(sim, where)
		_count(sim, 6, false, pre)
		var ph: String = "%s%s" % [sim.phase, " locked" if sim.front_locked else ""]
		var t: Dictionary = {}
		_count(sim, 90, true, t)      # hold 0.75 s
		_count(sim, 30, false, t)
		for k: int in 3:              # three one-tick taps
			_count(sim, 1, true, t)
			_count(sim, 40, false, t)
		var honks: int = int(t.get("honk", 0))
		var fires: int = int(t.get("fire", 0))
		var dry: int = int(t.get("fire_dry", 0))
		var want_fire: bool = where != &"jam" or sim.bridge.mini_target() != 0
		_check(honks == 0 and (fires > 0 if want_fire else dry > 0),
			"%s %s (%s): 압정 hold + taps → honk %d, fire %d, dry %d" % [tag, where, ph, honks, fires, dry])
		var h: Dictionary = {}
		sim.input(&"honk")
		_count(sim, 2, false, h)
		_check(int(h.get("honk", 0)) == 1, "%s %s: 경적 input still honks (%d)" % [tag, where, int(h.get("honk", 0))])


# ── touch level (HUD rects → LaneInput → Game → GameSim) ──────────────────────────────────────────

func _send(ev: InputEvent) -> void:
	# headless: no OS touch → mouse emulation, so push the twin the OS would add (LaneInput must ignore it)
	_tree.root.push_input(ev, true)  # viewport (canvas) coordinates, like the HUD rects
	if ev is InputEventScreenTouch and (ev as InputEventScreenTouch).index == 0:
		var mb := InputEventMouseButton.new()
		mb.button_index = MOUSE_BUTTON_LEFT
		mb.pressed = (ev as InputEventScreenTouch).pressed
		mb.button_mask = MOUSE_BUTTON_MASK_LEFT if mb.pressed else 0
		mb.device = InputEvent.DEVICE_ID_EMULATION
		mb.position = (ev as InputEventScreenTouch).position
		mb.global_position = mb.position
		_tree.root.push_input(mb, true)


func _touch(idx: int, pos: Vector2, pressed: bool) -> void:
	var t := InputEventScreenTouch.new()
	t.index = idx
	t.position = pos
	t.pressed = pressed
	_send(t)


func _drag(idx: int, pos: Vector2, rel: Vector2) -> void:
	var d := InputEventScreenDrag.new()
	d.index = idx
	d.position = pos
	d.relative = rel
	_send(d)


func _honks(g: Game) -> int:
	return int(g.event_counts.get("honk", 0))


func _fires(g: Game) -> int:
	return int(g.event_counts.get("fire", 0))


func _touch_level(fb: bool) -> void:
	var tag: String = "fallback" if fb else "native"
	var g: Game = GameScene.instantiate() as Game
	g.manual = true
	g.with_debug_panel = false
	g.traffic_mode = "fallback" if fb else "auto"
	_tree.root.add_child(g)
	await _tree.process_frame
	await _tree.process_frame
	g.hud._process(0.0)  # registers the touch zones from the laid-out buttons
	_check(g.sim.bridge.is_native() != fb, "%s: game scene runs the %s traffic" % [tag, tag])
	var fire_r: Rect2 = g.hud._btn_fire.get_global_rect()
	var horn_r: Rect2 = g.hud._btn_horn.get_global_rect()
	var zones: Dictionary = g.input._zones
	var overlap: PackedStringArray = []
	for a: String in zones:
		for b: String in zones:
			if a < b and (zones[a] as Rect2).intersects(zones[b] as Rect2):
				overlap.append("%s×%s" % [a, b])
	_check(overlap.is_empty() and zones.has("fire") and zones.has("horn"), "%s: touch zones are disjoint %s" % [tag, ",".join(overlap)])
	g.sim.input(&"continue")
	g.advance_ticks(400)
	var spots: Array[Vector2] = [fire_r.get_center(), fire_r.position + Vector2(3, fire_r.size.y * 0.5),
		fire_r.position + Vector2(fire_r.size.x * 0.5, 3), fire_r.end - Vector2(3, 3)]
	for where: StringName in [&"jam", &"boss", &"locked"]:
		_place(g.sim, where)
		g.advance_ticks(6)
		var ph: String = "%s%s" % [g.sim.phase, " locked" if g.sim.front_locked else ""]
		var h0: int = _honks(g)
		var f0: int = _fires(g)
		var horn_seen: bool = false
		# hold 압정 at the centre for 0.75 s
		_touch(0, spots[0], true)
		for i: int in 90:
			g.advance_ticks(1)
			horn_seen = horn_seen or g.input.is_horn_down()
		var held: bool = g.input.is_fire_down()
		_touch(0, spots[0], false)
		g.advance_ticks(20)
		# taps on the centre and near the rect edges
		for p: Vector2 in spots:
			_touch(0, p, true)
			g.advance_ticks(1)
			horn_seen = horn_seen or g.input.is_horn_down()
			_touch(0, p, false)
			g.advance_ticks(40)
		# multitouch: 압정 held (finger 0) + lane swipe with finger 1 on the road
		_touch(0, spots[0], true)
		g.advance_ticks(4)
		var road_p := Vector2(200, 520)
		_touch(1, road_p, true)
		_drag(1, road_p + Vector2(-30, 1), Vector2(-30, 1))
		_drag(1, road_p + Vector2(-70, 2), Vector2(-40, 1))
		var lane_edge: bool = g.input.peek_lane() == -1
		g.advance_ticks(2)
		_touch(1, road_p + Vector2(-70, 2), false)
		var still: bool = g.input.is_fire_down()
		g.advance_ticks(30)
		_touch(0, spots[0], false)
		g.advance_ticks(10)
		var dh: int = _honks(g) - h0
		var df: int = _fires(g) - f0
		var want_fire: bool = where != &"jam" or g.sim.bridge.mini_target() != 0
		_check(dh == 0 and not horn_seen and held and still and lane_edge and (df > 0 or not want_fire),
			"%s %s (%s): touches on the 압정 rect → honk %d (horn down %s), fire %d, held %s, swipe while held %s/%s" % [
				tag, where, ph, dh, horn_seen, df, held, lane_edge, still])
		# the 경적 button still honks
		var h1: int = _honks(g)
		g.advance_ticks(130)  # honkCool
		_touch(0, horn_r.get_center(), true)
		g.advance_ticks(2)
		_touch(0, horn_r.get_center(), false)
		g.advance_ticks(2)
		_check(_honks(g) - h1 == 1 and not g.input.is_fire_down(), "%s %s: tap on 경적 → one honk (%d), no fire" % [tag, where, _honks(g) - h1])
	g.queue_free()
	await _tree.process_frame
