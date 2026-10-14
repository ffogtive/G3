class_name Hud
extends CanvasLayer
## In-game HUD (NATIVE_PORT 3-8 / M1c, M1d N1 N4; DESIGN_REVIEW P0 #2 #4 #6), portrait 540-wide canvas_items layout
## anchored to the edges, every widget under `safe` (notch / Dynamic Island / home indicator insets):
##  - top: N1 progress bar + "원흉까지 N m" pill (jam), villain plate = name + HP bar with white damage lag + tires +
##    "약점!" tag (boss), combo, release counter sign (release), pause.
##  - bottom: ◀ ▶ lanes, 경적, big 압정 (fire, hold) with the P0#2 range ring (green in range, grey out), 분노 with a
##    charge ring (rage bomb / rage horn), bumper HP + rage rows, speedometer, one-line hint chip (P0#4, ≤ 16 chars).
##  - overlays on root: N4 lock-on reticle, pops (hit numbers, "빗나감!"), banners, flash / vignette / kill letterbox,
##    result card, fail card.
## Driving it (view/game.gd): apply_state(GameSim.state()) every frame, on_event(e) for each drained sim event,
## bind_world(camera, road) once; show_result(result, record) / show_fail(info) on those phases; card choices come
## back as card_choice(&"next" | &"retry" | &"menu"). set_state() is the M1a N1 path (jam slice, tests).
## Buttons are drawn here; touches are read by LaneInput from the rects registered via bind_input() (multi-touch).
## All animation runs on real time: _process(delta), or advance(dt) when `manual` (deterministic shots).

signal card_choice(choice: StringName)

const FONT_PATH: String = "res://ui/fonts/BlackHanSans-Regular.ttf"
const C_PANEL := Color(0.07, 0.08, 0.11, 0.78)
const C_EDGE := Color(1, 1, 1, 0.16)
const C_HP := Color8(0x3d, 0xd6, 0x5a)
const C_RAGE := Color8(0xff, 0x7a, 0x1a)
const C_OFF := Color(0.22, 0.24, 0.28, 0.9)
const C_RANGE := Color8(0x3c, 0xe0, 0x8e)
const C_NORANGE := Color8(0x9a, 0xa3, 0xae)
const INK := UiDraw.INK
const BTN_BLUE: Array = [Color8(0x6a, 0xa6, 0xff), Color8(0x2f, 0x6f, 0xd6), Color8(0x1f, 0x4f, 0xa3)]
const BTN_RED: Array = [Color8(0xff, 0x8a, 0x80), Color8(0xff, 0x3b, 0x30), Color8(0xc8, 0x24, 0x1a)]
const BTN_HORN: Array = [Color8(0xff, 0xc0, 0x6a), Color8(0xf0, 0x8a, 0x1a), Color8(0xb8, 0x5a, 0x08)]
const BTN_RAGE: Array = [Color8(0xff, 0xb0, 0x5a), Color8(0xff, 0x6a, 0x1a), Color8(0xc8, 0x3a, 0x08)]
const BTN_RAGE_OFF: Array = [Color8(0x8a, 0x93, 0x9e), Color8(0x5c, 0x66, 0x72), Color8(0x3c, 0x44, 0x50)]
const IDLE_ALPHA: float = 0.45
## Touch targets (canvas units; 64 pt = 88.6 u): lanes 96, horn 92, 압정 140, 분노 104.
const SZ_LANE: float = 96.0
const SZ_HORN: float = 92.0
const SZ_FIRE: float = 140.0
const SZ_RAGE: float = 104.0

var font: Font
var player_s: float = 0.0
var villain_s: float = 200.0
var start_s: float = 0.0
var speed_ms: float = 0.0
## 5-segment values (M1a contract); apply_state derives them from hp / hp_max and rage.
var hp: int = 5
var rage: int = 0
var horn_down: bool = false
## N1 values (bar fraction 0..1, metres to the villain). The bar fill, the player marker and the "원흉까지 N m" label
## all read this one Vector2 (tests/test_hud_progress.gd checks it every tick). apply_state takes GameSim's
## progress / distance_m, which come from the same position pair.
var shown := Vector2.ZERO
var root: Control
## Full-screen minus the safe-area insets; parent of every HUD widget.
var safe: Control
## (top, bottom) insets in points of a 390-pt-wide phone, applied when not on a mobile OS (tests / T2 shots).
var debug_safe_pt := Vector2.ZERO
## Applied insets in canvas units (left, top, right, bottom).
var insets := Vector4.ZERO
var paused: bool = false
## true: the caller advances UI time with advance(dt) (shots); false: _process(delta).
var manual: bool = false
var now: float = 0.0

# ── fight state (apply_state)
var phase: StringName = &"jam"
var hp_value: float = 100.0
var hp_max: float = 100.0
var rage_frac: float = 0.0
var rage_cost: float = 0.2
var fire_down: bool = false
var lock_active: bool = false
var lock_in_range: bool = false
var boss_name: String = ""
var boss_hp: float = 1.0
var boss_lag: float = 1.0
var boss_tires: int = 4
var boss_vuln: bool = false
var boss_count: int = 0
var combo: int = 0
var released: int = 0
var hint_text: String = ""
var reticle: Reticle
var banner: Banner
var pops: Bubbles
var result_card: ResultCard
var fail_card: FailCard
var camera: Camera3D
var road: RoadGraph
## Stage row (stages.json): villain defeat line on the kill banner.
var stage: Dictionary = {}

var _bar: Control
var _pill: Control
var _boss: Control
var _combo_w: Control
var _release_w: Control
var _chip: Control
var _btn_pause: Control
var _btn_alpha: Dictionary = {}   # Control → current alpha (idle-ghosted buttons)
var _dist: Label
var _speed: Label
var _unit: Label
var _hp_row: Control
var _rage_row: Control
var _btn_left: Control
var _btn_right: Control
var _btn_horn: Control
var _btn_fire: Control
var _btn_rage: Control
var _fire_ring: Control
var _gauge: Control
var _fx: Control
var _input: LaneInput
var _zones_size := Vector2.ZERO
var _top_jam: Array[Control] = []
var _controls: Array[Control] = []
var _group_alpha: Dictionary = {}   # Control → alpha target multiplier (phase visibility)
var _vis: Dictionary = {}           # Control → current phase alpha
var _boss_hit_t: float = -99.0
var _hp_hit_t: float = -99.0
var _hp_prev: float = -1.0
var _fire_kick: float = -99.0
var _miss_t: float = -99.0
var _rage_ready_t: float = -99.0
var _rage_was_ready: bool = false
var _hint_shown: String = ""
var _hint_t: float = -99.0
var _rel_bump: float = -99.0
var _combo_t: float = -99.0
var _flash_col := Color(1, 1, 1, 0)
var _flash_t: float = -99.0
var _flash_dur: float = 0.12
var _vig_dmg_t: float = -99.0
var _letterbox: float = 0.0
var _letterbox_want: float = 0.0
var _kill_t: float = -99.0
var _last_damage: Dictionary = {}
var _fails: int = 0
var _pay_mul: float = 1.0
var _villain_name: String = ""
var _state: Dictionary = {}
var _was_in_range: bool = false


## N1 single truth: (fraction 0..1, distance m) from the same two positions.
static func progress_values(p_s: float, v_s: float, s0: float) -> Vector2:
	var span: float = maxf(1.0, v_s - s0)
	var dist: float = maxf(0.0, v_s - p_s)
	return Vector2(clampf((p_s - s0) / span, 0.0, 1.0), dist)


func _ready() -> void:
	layer = 5
	font = _load_font()
	root = Control.new()
	root.name = "HudRoot"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	reticle = Reticle.new()
	reticle.name = "Reticle"
	root.add_child(reticle)
	pops = Bubbles.new()
	pops.name = "Pops"
	root.add_child(pops)
	safe = Control.new()
	safe.name = "Safe"
	safe.set_anchors_preset(Control.PRESET_FULL_RECT)
	safe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(safe)
	# ── top: progress (N1)
	_bar = _custom(_draw_bar)
	_bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_bar.offset_left = 12
	_bar.offset_right = -12
	_bar.offset_top = 10
	_bar.offset_bottom = 46
	_pill = _custom(_draw_pill)
	_pill.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_pill.offset_top = 52
	_pill.offset_bottom = 88
	_pill.offset_left = -110
	_pill.offset_right = 110
	_dist = _label("원흉까지 200 m", 22, Color.WHITE, 4)
	_dist.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_dist.offset_top = 52
	_dist.offset_bottom = 88
	_dist.offset_left = -110
	_dist.offset_right = 110
	_dist.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_dist.visible = false  # the pill draws the same text with '200' emphasised; the Label keeps the N1 string for tests
	# ── top: villain plate (boss), combo, release counter
	_boss = _custom(_draw_boss)
	_boss.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_boss.offset_left = 12
	_boss.offset_right = -70
	_boss.offset_top = 54
	_boss.offset_bottom = 132
	_combo_w = _custom(_draw_combo)
	_combo_w.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_combo_w.offset_left = -190
	_combo_w.offset_right = -14
	_combo_w.offset_top = 138
	_combo_w.offset_bottom = 184
	_release_w = _custom(_draw_release)
	_release_w.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_release_w.offset_left = -124
	_release_w.offset_right = 124
	_release_w.offset_top = 60
	_release_w.offset_bottom = 176
	# ── bottom: hint chip, bumper HP + rage rows, speedometer
	_chip = _custom(_draw_chip)
	_chip.anchor_left = 0.0
	_chip.anchor_right = 1.0
	_chip.anchor_top = 1.0
	_chip.anchor_bottom = 1.0
	_chip.offset_left = 96
	_chip.offset_right = -144
	_chip.offset_top = -334
	_chip.offset_bottom = -288
	_hp_row = _custom(_draw_hp)
	_bottom_left(_hp_row, 112, 330, 222, 182)
	_rage_row = _custom(_draw_rage)
	_bottom_left(_rage_row, 112, 330, 176, 136)
	_gauge = _custom(_draw_gauge)
	_bottom_left(_gauge, 16, 98, 220, 132)
	_speed = _label("0", 30, Color.WHITE, 5)
	_bottom_left(_speed, 16, 98, 206, 170)
	_speed.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_unit = _label("km/h", 13, Color(1, 1, 1, 0.8), 3)
	_bottom_left(_unit, 16, 98, 172, 152)
	_unit.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# ── bottom: buttons (≥ 64 pt), thumb arcs: lanes bottom-left, 압정 bottom-right, 분노 above it, 경적 inside
	_btn_left = _custom(_draw_left)
	_corner(_btn_left, true, 14, 16, SZ_LANE)
	_btn_right = _custom(_draw_right)
	_corner(_btn_right, true, 14 + SZ_LANE + 12, 16, SZ_LANE)
	_fire_ring = _custom(_draw_fire_ring)
	_corner(_fire_ring, false, 4, 6, SZ_FIRE + 20)
	_btn_fire = _custom(_draw_fire)
	_corner(_btn_fire, false, 14, 16, SZ_FIRE)
	_btn_rage = _custom(_draw_rage_btn)
	_corner(_btn_rage, false, 32, 16 + SZ_FIRE + 22, SZ_RAGE)
	_btn_horn = _custom(_draw_horn)
	_corner(_btn_horn, false, 14 + SZ_FIRE + 16, 16, SZ_HORN)
	_btn_pause = _custom(_draw_pause)
	_btn_pause.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_btn_pause.offset_left = -60
	_btn_pause.offset_right = -14
	_btn_pause.offset_top = 52
	_btn_pause.offset_bottom = 98
	for b: Control in [_btn_left, _btn_right, _btn_horn, _btn_fire, _btn_rage]:
		_btn_alpha[b] = IDLE_ALPHA
		b.modulate.a = IDLE_ALPHA
	_controls = [_btn_left, _btn_right, _btn_horn, _btn_fire, _btn_rage, _fire_ring, _hp_row, _rage_row, _gauge, _speed, _unit]
	for c: Control in safe.get_children():
		_vis[c] = 1.0
	# ── overlays (above the widgets)
	_fx = Control.new()
	_fx.name = "ScreenFx"
	_fx.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fx.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fx.draw.connect(_draw_screen_fx)
	root.add_child(_fx)
	banner = Banner.new()
	banner.name = "Banner"
	root.add_child(banner)
	get_viewport().size_changed.connect(apply_safe_area)
	apply_safe_area()
	_apply_phase_vis(true)


## Safe-area insets → `safe` offsets (canvas units). Mobile: DisplayServer.get_display_safe_area() is in window
## pixels (full-screen app), scaled by visible-rect / window size. Elsewhere the screen's usable rect has nothing to do
## with the window, so only debug_safe_pt applies.
func apply_safe_area() -> void:
	var vis: Vector2 = get_viewport().get_visible_rect().size
	var ins := Vector4.ZERO
	if OS.has_feature("mobile"):
		var win := Vector2(DisplayServer.window_get_size())
		if win.x > 0.0 and win.y > 0.0:
			var sa := Rect2(DisplayServer.get_display_safe_area())
			var k: Vector2 = vis / win
			ins = Vector4(sa.position.x * k.x, sa.position.y * k.y, (win.x - sa.end.x) * k.x, (win.y - sa.end.y) * k.y)
	elif debug_safe_pt != Vector2.ZERO:
		var u: float = vis.x / 390.0
		ins = Vector4(0.0, debug_safe_pt.x * u, 0.0, debug_safe_pt.y * u)
	insets = Vector4(maxf(0.0, ins.x), maxf(0.0, ins.y), maxf(0.0, ins.z), maxf(0.0, ins.w))
	safe.offset_left = insets.x
	safe.offset_top = insets.y
	safe.offset_right = -insets.z
	safe.offset_bottom = -insets.w
	_zones_size = Vector2.ZERO  # re-register the touch zones next frame


## The rect HUD widgets, bubbles and N5 icons must stay inside (viewport units).
func safe_rect() -> Rect2:
	var vis: Vector2 = get_viewport().get_visible_rect().size
	return Rect2(Vector2(insets.x, insets.y), vis - Vector2(insets.x + insets.z, insets.y + insets.w))


## Screen rects N5 icons / bubbles must not cover (visible widgets only).
func reserved_rects() -> Array[Rect2]:
	var out: Array[Rect2] = []
	if not visible:
		return out
	for c: Control in [_bar, _pill, _boss, _chip, _hp_row, _rage_row, _gauge, _btn_left, _btn_right, _btn_horn, _btn_fire,
			_btn_rage, _btn_pause]:
		if c.visible:
			out.append(c.get_global_rect().grow(4.0))
	return out


## Touch-target sizes in points (tests: every control ≥ 64 pt).
func button_sizes_pt() -> Dictionary:
	var k: float = 390.0 / 540.0
	var out: Dictionary = {}
	for n: String in ["left", "right", "horn", "fire", "rage"]:
		var c: Control = {"left": _btn_left, "right": _btn_right, "horn": _btn_horn, "fire": _btn_fire, "rage": _btn_rage}[n]
		out[n] = minf(c.size.x, c.size.y) * k
	return out


func _load_font() -> Font:
	if ResourceLoader.exists(FONT_PATH):
		var f: Font = load(FONT_PATH) as Font
		if f != null:
			return f
	if FileAccess.file_exists(FONT_PATH):
		var ff := FontFile.new()
		if ff.load_dynamic_font(FONT_PATH) == OK:
			return ff
	return ThemeDB.fallback_font


func _custom(draw_fn: Callable) -> Control:
	var c := Control.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.draw.connect(func() -> void: draw_fn.call(c))
	safe.add_child(c)
	return c


func _label(text: String, size: int, color: Color, outline: int) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ls := LabelSettings.new()
	ls.font = font
	ls.font_size = size
	ls.font_color = color
	ls.outline_size = outline
	ls.outline_color = Color(0.05, 0.06, 0.09, 0.95)
	l.label_settings = ls
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	safe.add_child(l)
	return l


## Left-anchored at the bottom: x from left .. right, y as distances above the safe bottom (top > bottom).
func _bottom_left(c: Control, left: float, right: float, top_from_bottom: float, bottom_from_bottom: float) -> void:
	c.anchor_left = 0.0
	c.anchor_right = 0.0
	c.anchor_top = 1.0
	c.anchor_bottom = 1.0
	c.offset_left = left
	c.offset_right = right
	c.offset_top = -top_from_bottom
	c.offset_bottom = -bottom_from_bottom


func _corner(c: Control, left: bool, inset: float, bottom: float, size: float) -> void:
	c.anchor_top = 1.0
	c.anchor_bottom = 1.0
	c.anchor_left = 0.0 if left else 1.0
	c.anchor_right = c.anchor_left
	if left:
		c.offset_left = inset
		c.offset_right = inset + size
	else:
		c.offset_left = -inset - size
		c.offset_right = -inset
	c.offset_top = -bottom - size
	c.offset_bottom = -bottom


func bind_input(input: LaneInput) -> void:
	_input = input


## Camera + road for the 3D-anchored overlays (reticle, pops).
func bind_world(cam: Camera3D, p_road: RoadGraph) -> void:
	camera = cam
	road = p_road
	reticle.camera = cam
	reticle.road = p_road
	pops.camera = cam


## M1a N1 path (jam slice): positions → shown.
func set_state(p_s: float, v_s: float, s0: float, v_ms: float) -> void:
	player_s = p_s
	villain_s = v_s
	start_s = s0
	speed_ms = v_ms
	shown = progress_values(p_s, v_s, s0)
	if _dist != null:
		_dist.text = distance_text(shown.y)


static func distance_text(metres: float) -> String:
	return "원흉까지 %d m" % roundi(metres)


func distance_label() -> String:
	return _dist.text if _dist != null else ""


# ───────────────────────────── GameSim state / events

## Every frame with GameSim.state() (the IFACE dictionary).
func apply_state(st: Dictionary) -> void:
	_state = st
	var ph: StringName = StringName(str(st.get("phase", "jam")))
	if ph != phase:
		var old: StringName = phase
		phase = ph
		_on_phase(ph, old)
	var p: Dictionary = st.get("player", {})
	player_s = float(p.get("s", player_s))
	speed_ms = float(p.get("v", speed_ms))
	hp_max = maxf(1.0, float(p.get("hp_max", hp_max)))
	var new_hp: float = float(p.get("hp", hp_value))
	if _hp_prev >= 0.0 and new_hp < _hp_prev - 0.5:
		_hp_hit_t = now
	_hp_prev = new_hp
	hp_value = new_hp
	hp = clampi(ceili(hp_value / hp_max * 5.0 - 1e-6), 0, 5)
	rage_frac = clampf(float(p.get("rage", rage_frac)), 0.0, 1.0)
	rage = clampi(floori(rage_frac * 5.0 + 1e-6), 0, 5)
	var ready: bool = rage_frac >= rage_cost - 1e-6
	if ready and not _rage_was_ready:
		_rage_ready_t = now
	_rage_was_ready = ready
	shown = Vector2(clampf(float(st.get("progress", shown.x)), 0.0, 1.0), maxf(0.0, float(st.get("distance_m", shown.y))))
	_dist.text = distance_text(shown.y)
	var stats: Dictionary = st.get("stats", {})
	var nc: int = int(stats.get("combo", 0))
	if nc > combo:
		_combo_t = now
	combo = nc
	_fails = int(stats.get("fails", _fails))
	_pay_mul = float(stats.get("pay_mul", _pay_mul))
	# villain plate: first alive (else the dying / last one)
	var vs: Array = st.get("villains", [])
	var ref: Dictionary = {}
	boss_count = 0
	for v: Variant in vs:
		var d: Dictionary = v
		if bool(d.get("alive", false)):
			boss_count += 1
			if ref.is_empty():
				ref = d
	if ref.is_empty() and not vs.is_empty():
		ref = vs[0]
	if not ref.is_empty():
		boss_name = str(ref.get("name", "원흉"))
		_villain_name = boss_name
		var f: float = clampf(float(ref.get("hp", 0.0)) / maxf(1.0, float(ref.get("hp_max", 1.0))), 0.0, 1.0)
		if f < boss_hp - 1e-4:
			_boss_hit_t = now
		boss_hp = f
		boss_tires = int(ref.get("tires", 4))
		boss_vuln = bool(ref.get("vulnerable", false))
	var lk: Dictionary = st.get("lock", {})
	lock_active = bool(lk.get("active", false)) and ph == &"boss"
	lock_in_range = bool(lk.get("in_range", false)) and ph == &"boss"
	var tgt: Dictionary = {}
	if ph == &"boss" and not ref.is_empty() and bool(ref.get("alive", false)):
		var tid: int = int(lk.get("target_id", -1))
		var tv: Dictionary = ref
		for v: Variant in vs:
			if int((v as Dictionary).get("id", -2)) == tid:
				tv = v
		var dir: int = 0
		if not lock_in_range:
			var vl: int = roundi(float(tv.get("lane_pos", tv.get("lane", 0))))
			var pl: int = int(p.get("lane", vl))
			dir = signi(vl - pl) if absi(vl - pl) > 1 else 0
		tgt = {"s": float(tv.get("s", 0.0)), "x": float(tv.get("x", 0.0)), "len": float(tv.get("len", 4.6)),
			"active": lock_active or float(tv.get("s", 0.0)) > player_s - 60.0, "in_range": lock_in_range, "dir": dir,
			"vulnerable": bool(tv.get("vulnerable", false))}
	if lock_in_range and not _was_in_range:
		_haptic("lock")  # N4: the reticle acquiring is UI feedback (double tick), not a sim event
	_was_in_range = lock_in_range
	reticle.set_target(tgt)
	reticle.bounds = safe_rect()
	hint_text = str(st.get("hint", ""))
	if ph != &"boss" and ph != &"jam":
		hint_text = ""


## One drained GameSim event (UI side: pops, banners, flashes, counters).
func on_event(e: Dictionary) -> void:
	match str(e.get("type", "")):
		"fire":
			_fire_kick = now
		"hit":
			var big: bool = bool(e.get("window", false)) or str(e.get("kind", "")) == "bomb"
			var dmg: float = float(e.get("dmg", 0.0))
			if road != null and e.has("s"):
				var wp: Vector3 = road.position(float(e["s"]), float(e.get("x", 0.0))) + Vector3(0, 2.2, 0)
				if str(e.get("kind", "")) == "mini":
					pops.pop(wp, "-%d" % roundi(dmg), "hit")
				elif bool(e.get("immune", false)):
					pops.pop(wp, "막힘!", "miss")
				else:
					pops.pop(wp, ("치명! -%d" if big else "-%d") % maxi(1, roundi(dmg)), "crit" if big else "hit")
				if int(e.get("popped", 0)) > 0:
					pops.pop(wp + Vector3(0, 1.2, 0), "펑크!", "crit")
			if big:
				flash(Color(1, 0.95, 0.7, 0.35), 0.1)
		"miss":
			_miss_t = now
			if road != null:
				pops.pop(road.position(float(e.get("s", player_s)), float(e.get("x", 0.0))) + Vector3(0, 1.6, 0), "빗나감!", "miss")
		"bomb":
			flash(Color(1, 0.6, 0.2, 0.18), 0.12)
		"damage":
			_last_damage = e
			_vig_dmg_t = now
			if road != null:
				var pp: Dictionary = _state.get("player", {})
				var wp2: Vector3 = road.position(float(pp.get("s", player_s)), float(pp.get("x", 0.0))) + Vector3(0, 2.6, 0)
				pops.pop(wp2, "-%d" % int(e.get("amount", 0)), "dmg")
		"phase":
			pass
		"lock":
			banner.show_banner("정면 잠금!", "lock", 1.1, "원흉 옆 차로에서 압정 꾹!")
		"boss_phase":
			banner.show_banner(str(e.get("label", "원흉이 화났다!")), "phase", 1.3)
			flash(Color(1, 0.3, 0.2, 0.25), 0.15)
		"kill":
			_kill_t = now
			flash(Color(1, 1, 1, 0.85), 0.22)
		"pullover":
			pass
		"release":
			released = 0
			banner.show_banner("뻥 뚫렸다!!", "release", 1.5)
			flash(Color(0.6, 1, 0.7, 0.4), 0.3)
		"released":
			released += 1
			_rel_bump = now
		"wreck":
			banner.show_banner("견인!", "warn", 1.2)
			flash(Color(1, 0.2, 0.15, 0.5), 0.3)
			_fails = int(e.get("fails", _fails))
		"retry":
			_fails = int(e.get("fails", _fails))
			_pay_mul = float(e.get("pay_mul", _pay_mul))
			hide_cards()
		"stun":
			if int(e.get("id", -1)) >= 0 and phase == &"boss":
				pops.pop(_villain_pos(int(e["id"])) + Vector3(0, 2.8, 0), "경직!", "crit")


func _haptic(event_name: String) -> void:
	var h: Node = get_node_or_null(^"/root/Haptics")
	if h != null and h.has_method(&"haptic"):
		h.call(&"haptic", event_name)


func _villain_pos(id: int) -> Vector3:
	for v: Variant in _state.get("villains", []):
		var d: Dictionary = v
		if int(d.get("id", -1)) == id and road != null:
			return road.position(float(d.get("s", 0.0)), float(d.get("x", 0.0)))
	return Vector3(INF, INF, INF)


func _on_phase(ph: StringName, old: StringName) -> void:
	match ph:
		&"boss":
			if old == &"jam":
				banner.show_banner("원흉 발견!", "boss", 1.4, boss_name if not boss_name.is_empty() else "")
			boss_lag = boss_hp
		&"kill":
			var line: String = str(stage.get("defeatLine", "")) if stage.get("defeatLine") != null else ""
			banner.show_banner("참교육 완료!", "kill", 2.0, line)
			_letterbox_want = 1.0
		&"release":
			_letterbox_want = 0.0
		&"cruise", &"result":
			_letterbox_want = 0.0
		&"intro", &"jam":
			_letterbox_want = 0.0
			released = 0
	_apply_phase_vis(false)


## Which widgets show in which phase (alpha targets; the fade itself runs in advance()).
func _apply_phase_vis(instant: bool) -> void:
	var fight: bool = phase == &"boss"
	var driving: bool = phase in [&"intro", &"jam", &"boss"]
	var want: Dictionary = {}
	for c: Control in _vis:
		want[c] = 0.0
	want[_bar] = 1.0 if phase in [&"intro", &"jam", &"boss", &"kill", &"release", &"cruise"] else 0.0
	want[_pill] = 1.0 if phase in [&"intro", &"jam"] else 0.0
	want[_boss] = 1.0 if phase in [&"boss", &"kill"] else 0.0
	want[_combo_w] = 1.0 if fight else 0.0
	want[_release_w] = 1.0 if phase in [&"release", &"cruise"] else 0.0
	want[_chip] = 1.0 if driving else 0.0
	want[_btn_pause] = 1.0 if driving or phase in [&"kill", &"release", &"cruise"] else 0.0
	for c: Control in _controls:
		want[c] = 1.0 if driving else 0.0
	for c: Control in [_btn_left, _btn_right, _gauge, _speed, _unit]:
		if phase in [&"release", &"cruise"]:
			want[c] = 1.0
	_group_alpha = want
	if instant:
		for c: Control in want:
			_vis[c] = float(want[c])
			c.visible = float(want[c]) > 0.0


func advance(dt: float) -> void:
	now += dt
	reticle.advance(dt)
	banner.advance(dt)
	pops.step(now)
	if result_card != null:
		result_card.advance(dt)
	if fail_card != null:
		fail_card.advance(dt)
	for c: Control in _group_alpha:
		var a: float = move_toward(float(_vis.get(c, 1.0)), float(_group_alpha[c]), dt / 0.22)
		_vis[c] = a
		c.visible = a > 0.01
		if not _btn_alpha.has(c):
			c.modulate.a = a
	# white damage lag on the villain bar (web: holds while hits keep coming, then drains)
	if boss_lag > boss_hp:
		var drain: float = 0.04 if now - _boss_hit_t < 0.42 else 0.25 + (boss_lag - boss_hp) * 4.0
		boss_lag = maxf(boss_hp, boss_lag - dt * drain)
	else:
		boss_lag = boss_hp
	_letterbox = move_toward(_letterbox, _letterbox_want, dt / 0.3)
	if _input != null:
		_ghost(_btn_left, _input.is_zone_down("left"), dt)
		_ghost(_btn_right, _input.is_zone_down("right"), dt)
		fire_down = _input.is_fire_down()
	_ghost(_btn_horn, horn_down, dt)
	_ghost(_btn_fire, fire_down, dt)
	_ghost(_btn_rage, _input != null and _input.is_zone_down("rage"), dt)
	if hint_text != _hint_shown:
		_hint_shown = hint_text
		_hint_t = now
	for c: Control in safe.get_children():
		c.queue_redraw()
	_fx.queue_redraw()


func _process(delta: float) -> void:
	if not manual:
		advance(delta)
	_dist.text = distance_text(shown.y)
	_speed.text = str(roundi(speed_ms * 3.6))
	if _input != null and safe.size != _zones_size:
		_zones_size = safe.size
		_input.set_zone("left", _btn_left.get_global_rect())
		_input.set_zone("right", _btn_right.get_global_rect())
		_input.set_zone("horn", _btn_horn.get_global_rect())
		_input.set_zone("fire", _btn_fire.get_global_rect().grow(8.0))
		_input.set_zone("rage", _btn_rage.get_global_rect().grow(4.0))
		_input.set_zone("pause", _btn_pause.get_global_rect().grow(6.0))


## Idle buttons are ghosted (0.45) so the cars behind the player stay visible; 1.0 while pressed (≈0.08 s fade),
## times the phase visibility.
func _ghost(b: Control, down: bool, delta: float) -> void:
	var a: float = move_toward(float(_btn_alpha.get(b, IDLE_ALPHA)), 1.0 if down else IDLE_ALPHA,
		(1.0 - IDLE_ALPHA) * delta / 0.08)
	_btn_alpha[b] = a
	b.modulate.a = a * float(_vis.get(b, 1.0))


## Full-screen flash (hit / kill / release), real time.
func flash(col: Color, dur: float) -> void:
	_flash_col = col
	_flash_t = now
	_flash_dur = maxf(0.02, dur)


# ───────────────────────────── cards

## Result card. result = GameSim state().result; record = Progress.record_result(id, result) (stars, payout, wallet,
## missions, fine …; may be {} → the card shows the sim's own missions and Rewards.compute_reward numbers).
func show_result(result: Dictionary, record: Dictionary = {}, stage: Dictionary = {}) -> void:
	if fail_card != null:
		fail_card.close()
	if result_card == null:
		result_card = ResultCard.new()
		result_card.name = "ResultCard"
		root.add_child(result_card)
		result_card.choice.connect(func(c: StringName) -> void: card_choice.emit(c))
	if _input != null:
		_input.enabled = false
		_input.release_all()
	result_card.open(ResultCard.model(result, record, stage))


## Fail card (견인). info keys (all optional): reason, villain_name, hp_lost, tows, pay_mul, retry_label; missing keys
## come from the last damage / wreck / retry events and the state this HUD has seen.
func show_fail(info: Dictionary = {}) -> void:
	if fail_card == null:
		fail_card = FailCard.new()
		fail_card.name = "FailCard"
		root.add_child(fail_card)
		fail_card.choice.connect(func(c: StringName) -> void: card_choice.emit(c))
	var d: Dictionary = {
		"reason": str(_last_damage.get("reason", "차가 더는 못 버텼다")), "villain_name": _villain_name,
		"hp_lost": int(_last_damage.get("amount", 0)), "tows": maxi(1, _fails), "pay_mul": _pay_mul,
	}
	d.merge(info, true)
	if _input != null:
		_input.enabled = false
		_input.release_all()
	fail_card.open(d)


func hide_cards() -> void:
	if result_card != null:
		result_card.close()
	if fail_card != null:
		fail_card.close()
	if _input != null:
		_input.enabled = true


func card_open() -> bool:
	return (result_card != null and result_card.is_open()) or (fail_card != null and fail_card.is_open())


# ───────────────────────────── drawing

func _panel(c: Control, r: Rect2, radius: int = 14) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_PANEL
	sb.set_corner_radius_all(radius)
	sb.border_color = C_EDGE
	sb.set_border_width_all(2)
	c.draw_style_box(sb, r)


func _draw_bar(c: Control) -> void:
	var r := Rect2(Vector2.ZERO, c.size)
	_panel(c, r, 18)
	var pv: Vector2 = shown
	var track := Rect2(r.position + Vector2(22, 13), Vector2(r.size.x - 60, r.size.y - 26))
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.13, 0.14, 0.18, 0.9)  # empty track: not a red "danger / boss HP" bar
	sb.set_corner_radius_all(5)
	c.draw_style_box(sb, track)
	c.draw_circle(Vector2(track.position.x + 2, track.get_center().y), 4.0, Color.WHITE)  # start dot
	var fw: float = maxf(8.0, track.size.x * pv.x)
	var c0 := Color8(0xff, 0xd2, 0x3f)
	var c1: Color = c0.lerp(Color8(0xff, 0x7a, 0x1a), pv.x)
	if phase in [&"kill", &"release", &"cruise"]:
		fw = track.size.x
		c0 = Color8(0x3c, 0xe0, 0x8e)
		c1 = Color8(0x17, 0xa4, 0x66)
	var tl := track.position
	c.draw_polygon(PackedVector2Array([tl, tl + Vector2(fw, 0), tl + Vector2(fw, track.size.y), tl + Vector2(0, track.size.y)]),
		PackedColorArray([c0, c1, c1, c0]))
	# player marker: top-view hero car (yellow body, 2 black stripes) at the same fraction
	var px: float = track.position.x + track.size.x * (pv.x if not phase in [&"kill", &"release", &"cruise"] else 1.0)
	var car := Rect2(Vector2(px - 13, track.get_center().y - 7), Vector2(26, 14))
	c.draw_rect(car.grow(2.0), Color8(0x1c, 0x1c, 0x1c))
	c.draw_rect(car, Color8(0xff, 0xcc, 0x28))
	c.draw_rect(Rect2(car.position + Vector2(8, 0), Vector2(3, 14)), Color8(0x1c, 0x1c, 0x1c))
	c.draw_rect(Rect2(car.position + Vector2(15, 0), Vector2(3, 14)), Color8(0x1c, 0x1c, 0x1c))
	c.draw_rect(Rect2(car.position + Vector2(20, 2), Vector2(4, 10)), Color8(0x25, 0x3a, 0x5c))  # windscreen (front)
	# villain at the end of the bar (the bar's 100 % IS the villain's live position); a green check once cleared
	var vc := Vector2(r.end.x - 20, r.get_center().y)
	c.draw_circle(vc, 14, Color8(0x1c, 0x1c, 0x1c))
	if phase in [&"kill", &"release", &"cruise", &"result"]:
		c.draw_circle(vc, 11.5, Color8(0x22, 0xc5, 0x5e))
		c.draw_polyline(PackedVector2Array([vc + Vector2(-6, 0), vc + Vector2(-1.5, 5), vc + Vector2(6.5, -5)]), Color.WHITE, 3.0, true)
		return
	c.draw_circle(vc, 11.5, Color8(0xe8, 0x24, 0x2a))
	c.draw_line(vc + Vector2(-6, -4), vc + Vector2(-2, -2), Color.WHITE, 2.5)
	c.draw_line(vc + Vector2(6, -4), vc + Vector2(2, -2), Color.WHITE, 2.5)
	c.draw_line(vc + Vector2(-5, 5), vc + Vector2(5, 5), Color.WHITE, 2.5)


## Villain plate (web .ui-boss): red name pill with the angry face, HP bar (white damage lag, 3 notches, gloss) and the
## four tyre icons; shakes on a hit, "약점!" pulses while the signature window is open.
func _draw_boss(c: Control) -> void:
	var r := Rect2(Vector2.ZERO, c.size)
	var sh: float = 0.0
	var ht: float = now - _boss_hit_t
	if ht < 0.18:
		sh = sin(ht * 90.0) * 5.0 * (1.0 - ht / 0.18)
	c.draw_set_transform(Vector2(sh, 0), 0.0, Vector2.ONE)
	var name_s: String = boss_name if not boss_name.is_empty() else "원흉"
	if boss_count > 1:
		name_s += " ×%d" % boss_count
	var nw: float = clampf(UiDraw.text_w(name_s, 22) + 66.0, 150.0, r.size.x - 150.0)
	var plate := Rect2(Vector2(0, 0), Vector2(nw, 38))
	UiDraw.panel(c, plate, Color8(0xe8, 0x24, 0x2a), 12, 3, 4)
	c.draw_style_box(UiDraw.box(Color(1, 1, 1, 0.18), 8), Rect2(plate.position + Vector2(6, 4), Vector2(plate.size.x - 12, 12)))
	if not UiDraw.draw_icon(c, "angry", Vector2(22, 19), 28):
		c.draw_circle(Vector2(22, 19), 13, Color8(0xff, 0x3b, 0x30))
	UiDraw.text(c, Vector2(42, 28), name_s, 22, Color.WHITE, 5, true, 2.0)
	# tyres on the right of the plate row
	for i: int in 4:
		var tc := Vector2(r.size.x - 16 - float(3 - i) * 32.0, 19)
		var popped: bool = i >= boss_tires
		if not UiDraw.draw_icon(c, "tireFlat" if popped else "tire", tc, 28, Color(1, 1, 1, 0.75 if popped else 1.0)):
			c.draw_circle(tc, 12, INK)
	# HP bar
	var bar := Rect2(Vector2(0, 46), Vector2(r.size.x, 26))
	UiDraw.panel(c, bar, INK, 10, 0, 4)
	var inner := Rect2(bar.position + Vector2(4, 4), bar.size - Vector2(8, 8))
	c.draw_style_box(UiDraw.box(Color8(0x3a, 0x10, 0x12), 6), inner)
	if boss_lag > boss_hp:
		c.draw_style_box(UiDraw.box(Color(1, 1, 1, 0.95), 6), Rect2(inner.position, Vector2(inner.size.x * boss_lag, inner.size.y)))
	var low: bool = boss_hp <= 0.25
	var fill_c: Color = Color8(0xff, 0x3b, 0x30) if not boss_vuln else Color8(0xff, 0xb4, 0x00)
	if low and int(now * 6.0) % 2 == 0:
		fill_c = fill_c.lightened(0.25)
	if boss_hp > 0.0:
		var fr := Rect2(inner.position, Vector2(maxf(8.0, inner.size.x * boss_hp), inner.size.y))
		c.draw_style_box(UiDraw.box(fill_c, 6), fr)
		c.draw_style_box(UiDraw.box(Color(1, 1, 1, 0.3), 4), Rect2(fr.position + Vector2(3, 2), Vector2(fr.size.x - 6, 5)))
	for q: float in [0.25, 0.5, 0.75]:
		var x: float = inner.position.x + inner.size.x * q
		c.draw_line(Vector2(x, inner.position.y), Vector2(x, inner.end.y), Color(INK, 0.7), 2.0)
	if boss_vuln and phase == &"boss":
		var pul: float = 1.0 + 0.08 * sin(now * 14.0)
		var tag := Rect2(Vector2(r.size.x - 92, 40), Vector2(86, 36))
		c.draw_set_transform(Vector2(sh, 0) + tag.get_center(), deg_to_rad(4.0), Vector2(pul, pul))
		UiDraw.panel(c, Rect2(-tag.size * 0.5, tag.size), Color8(0xff, 0xd2, 0x3f), 10, 3, 3)
		UiDraw.text_c(c, Vector2(0, 0), "약점!", 22, INK, 0, true, 0.0)
	c.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_combo(c: Control) -> void:
	if combo < 3:
		return
	var t: float = now - _combo_t
	var sc: float = 1.0 + 0.3 * (1.0 - UiDraw.back_out(t / 0.18, 3.0)) if t < 0.18 else 1.0
	var txt: String = "×%d" % combo
	c.draw_set_transform(Vector2(c.size.x - 8, c.size.y * 0.5), deg_to_rad(-6.0), Vector2(sc, sc))
	var w: float = UiDraw.text_w(txt, 38) + UiDraw.text_w(" COMBO", 18)
	UiDraw.text(c, Vector2(-w, 14), txt, 38, Color8(0xff, 0xd2, 0x3f), 7, true, 3.0)
	UiDraw.text(c, Vector2(-w + UiDraw.text_w(txt, 38) + 4, 12), "COMBO", 18, Color.WHITE, 5, true, 2.0)
	c.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## Release counter (web .ui-rel): green road sign "해방된 차량 / N대", bumps on every released car.
func _draw_release(c: Control) -> void:
	var r := Rect2(Vector2.ZERO, c.size)
	var bt: float = now - _rel_bump
	var sc: float = 1.0 + (0.06 * (1.0 - bt / 0.12) if bt < 0.12 else 0.0)
	c.draw_set_transform(r.get_center(), 0.0, Vector2(sc, sc))
	var rr := Rect2(-r.size * 0.5, r.size)
	UiDraw.panel(c, rr, Color8(0x0b, 0x7a, 0x4b), 16, 4, 6)
	c.draw_style_box(UiDraw.box(Color(0, 0, 0, 0), 11, 3, Color(1, 1, 1, 0.95)), rr.grow(-7))
	UiDraw.text_c(c, Vector2(0, rr.position.y + 30), "해방된 차량", 22, Color.WHITE, 0, false, 0.0)
	var num: String = str(released)
	var nw: float = UiDraw.text_w(num, 58)
	var uw: float = UiDraw.text_w("대", 30)
	var x0: float = -(nw + uw + 6.0) * 0.5
	UiDraw.text(c, Vector2(x0, rr.end.y - 18), num, 58, Color8(0xff, 0xe1, 0x4d), 7, true, 4.0)
	UiDraw.text(c, Vector2(x0 + nw + 6.0, rr.end.y - 20), "대", 30, Color.WHITE, 5, true, 2.0)
	c.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## P0#4 hint chip: one line (≤ 16 chars from GameSim.hint()), above the controls. Pops in on change; colour by intent:
## "지금!" gold, "피해!" / "지나쳤다!" red, otherwise white.
func _draw_chip(c: Control) -> void:
	if _hint_shown.is_empty():
		return
	var t: float = now - _hint_t
	var sc: float = lerpf(0.6, 1.0, UiDraw.back_out(t / 0.2, 2.6))
	var bg := Color.WHITE
	var fg: Color = INK
	if _hint_shown.begins_with("지금!"):
		bg = Color8(0xff, 0xd2, 0x3f)
		sc *= 1.0 + 0.05 * sin(now * 12.0)
	elif _hint_shown.begins_with("피해!") or _hint_shown.begins_with("지나쳤다!"):
		bg = Color8(0xff, 0x3b, 0x30)
		fg = Color.WHITE
	var fs: int = 25
	var tw: float = UiDraw.rich_w(_hint_shown, fs, false)
	var w: float = minf(c.size.x, tw + 70.0)
	var ctr := Vector2(c.size.x * 0.5, c.size.y * 0.5)
	c.draw_set_transform(ctr, 0.0, Vector2(sc, sc))
	var box := Rect2(Vector2(-w * 0.5, -c.size.y * 0.5), Vector2(w, c.size.y))
	UiDraw.panel(c, box, bg, 20, 4, 5)
	var ic := Vector2(box.position.x + 24, 0)
	c.draw_circle(ic, 12, Color8(0xff, 0xd2, 0x3f) if bg != Color8(0xff, 0xd2, 0x3f) else Color.WHITE)
	c.draw_circle(ic, 12, INK, false, 2.5, true)
	UiDraw.text_c(c, ic, "!", 18, INK, 0, true, 0.0)
	UiDraw.rich(c, Vector2(box.position.x + 44, fs * 0.36), _hint_shown, fs, fg, 0 if fg == INK else 5, false, 0.0)
	c.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _segments(c: Control, title: String, value: float, col: Color, hit_t: float, show_num: bool) -> void:
	var r := Rect2(Vector2.ZERO, c.size)
	var ht: float = now - hit_t
	var sh: float = sin(ht * 80.0) * 4.0 * (1.0 - ht / 0.25) if ht < 0.25 else 0.0
	c.draw_set_transform(Vector2(sh, 0), 0.0, Vector2.ONE)
	_panel(c, r, 14)
	if ht < 0.3:
		c.draw_style_box(UiDraw.box(Color(1, 0.2, 0.15, 0.45 * (1.0 - ht / 0.3)), 14), r)
	c.draw_string(font, Vector2(12, r.size.y * 0.5 + 8), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 19, Color.WHITE)
	var x0: float = 60.0
	var x1: float = r.size.x - (44.0 if show_num else 10.0)
	var w: float = (x1 - x0) / 5.0
	for i: int in 5:
		var seg := Rect2(Vector2(x0 + w * float(i) + 2, 9), Vector2(w - 4, r.size.y - 18))
		c.draw_style_box(UiDraw.box(C_OFF, 5), seg)
		var part: float = clampf(value * 5.0 - float(i), 0.0, 1.0)
		if part > 0.0:
			var fr := Rect2(seg.position, Vector2(seg.size.x * part, seg.size.y))
			c.draw_style_box(UiDraw.box(col, 5), fr)
			c.draw_style_box(UiDraw.box(Color(1, 1, 1, 0.28), 3), Rect2(fr.position + Vector2(2, 2), Vector2(maxf(0.0, fr.size.x - 4), 5)))
	if show_num:
		var ns: String = str(roundi(hp_value))
		UiDraw.text(c, Vector2(r.size.x - 8 - UiDraw.text_w(ns, 20), r.size.y * 0.5 + 8), ns, 20, Color.WHITE, 4, true, 0.0)
	c.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_gauge(c: Control) -> void:
	var ctr: Vector2 = c.size * 0.5
	var rad: float = minf(c.size.x, c.size.y) * 0.5
	c.draw_circle(ctr, rad, Color(C_PANEL, 0.92))
	var a0: float = PI * 5.0 / 6.0     # 240° sweep like the web gauge
	var sweep: float = PI * 4.0 / 3.0
	c.draw_arc(ctr, rad - 5, a0, a0 + sweep, 40, Color(1, 1, 1, 0.18), 6)
	var k: float = clampf(speed_ms * 3.6 / 120.0, 0.0, 1.0)
	var col: Color = C_HP.lerp(Color8(0xff, 0xb2, 0x1e), k * 2.0) if k < 0.5 else Color8(0xff, 0xb2, 0x1e).lerp(Color8(0xff, 0x3b, 0x30), k * 2.0 - 1.0)
	c.draw_arc(ctr, rad - 5, a0, a0 + sweep * maxf(0.03, k), 40, col, 6)


## "원흉까지 200 m" with the number emphasised (28 px yellow) and the words at 18 px; text from the same `shown`.
func _draw_pill(c: Control) -> void:
	_panel(c, Rect2(Vector2.ZERO, c.size), 17)
	var parts: Array = [["원흉까지 ", 18, Color.WHITE], [str(roundi(shown.y)), 28, Color8(0xff, 0xd2, 0x3f)], [" m", 18, Color.WHITE]]
	var w: float = 0.0
	for p: Array in parts:
		w += font.get_string_size(str(p[0]), HORIZONTAL_ALIGNMENT_LEFT, -1, int(p[1])).x
	var x: float = (c.size.x - w) * 0.5
	var base: float = c.size.y * 0.5 + 10.0
	for p: Array in parts:
		var fs: int = int(p[1])
		c.draw_string_outline(font, Vector2(x, base), str(p[0]), HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 4, Color(0.05, 0.06, 0.09, 0.95))
		c.draw_string(font, Vector2(x, base), str(p[0]), HORIZONTAL_ALIGNMENT_LEFT, -1, fs, p[2] as Color)
		x += font.get_string_size(str(p[0]), HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x


func _draw_pause(c: Control) -> void:
	var r := Rect2(Vector2.ZERO, c.size)
	_panel(c, r, 14)
	var ctr: Vector2 = r.get_center()
	if paused:
		c.draw_colored_polygon(PackedVector2Array([ctr + Vector2(-7, -11), ctr + Vector2(11, 0), ctr + Vector2(-7, 11)]), Color.WHITE)
	else:
		c.draw_rect(Rect2(ctr + Vector2(-9, -11), Vector2(6, 22)), Color.WHITE)
		c.draw_rect(Rect2(ctr + Vector2(3, -11), Vector2(6, 22)), Color.WHITE)


func _draw_hp(c: Control) -> void:
	_segments(c, "범퍼", hp_value / hp_max, C_HP if hp_value / hp_max > 0.3 else Color8(0xff, 0x5a, 0x3c), _hp_hit_t, true)


func _draw_rage(c: Control) -> void:
	var rt: float = now - _rage_ready_t
	_segments(c, "분노", rage_frac, C_RAGE.lightened(0.25 * maxf(0.0, 1.0 - rt / 0.3)) if rt < 0.3 else C_RAGE, -99.0, false)


func _draw_left(c: Control) -> void:
	var o: Vector2 = UiDraw.round_button(c, c.size * 0.5, c.size.x * 0.5, BTN_BLUE, _input != null and _input.is_zone_down("left"))
	if not UiDraw.draw_icon(c, "left", o, 54):
		c.draw_colored_polygon(PackedVector2Array([o + Vector2(-14, 0), o + Vector2(10, -16), o + Vector2(10, 16)]), Color.WHITE)


func _draw_right(c: Control) -> void:
	var o: Vector2 = UiDraw.round_button(c, c.size * 0.5, c.size.x * 0.5, BTN_BLUE, _input != null and _input.is_zone_down("right"))
	if not UiDraw.draw_icon(c, "right", o, 54):
		c.draw_colored_polygon(PackedVector2Array([o + Vector2(14, 0), o + Vector2(-10, -16), o + Vector2(-10, 16)]), Color.WHITE)


func _draw_horn(c: Control) -> void:
	var o: Vector2 = UiDraw.round_button(c, c.size * 0.5, c.size.x * 0.5, BTN_HORN, horn_down)
	if not UiDraw.draw_icon(c, "horn", o - Vector2(0, 12), 44):
		c.draw_colored_polygon(PackedVector2Array([o + Vector2(-18, -22), o + Vector2(-6, -22), o + Vector2(8, -32),
			o + Vector2(8, -4), o + Vector2(-6, -14), o + Vector2(-18, -14)]), Color.WHITE)
	UiDraw.text_c(c, o + Vector2(0, 22), "경적", 21, Color.WHITE, 5, true, 0.0)


## 압정 (fire, hold): the big primary button. Recoil squash on every shot; a dull wobble + grey flash on a miss.
func _draw_fire(c: Control) -> void:
	var kt: float = now - _fire_kick
	var sq: float = 1.0 - 0.07 * (1.0 - kt / 0.09) if kt < 0.09 else 1.0
	var mt: float = now - _miss_t
	var wob: float = sin(mt * 50.0) * 0.08 * (1.0 - mt / 0.3) if mt < 0.3 else 0.0
	var ctr: Vector2 = c.size * 0.5
	c.draw_set_transform(ctr, wob, Vector2(sq, sq))
	var o: Vector2 = UiDraw.round_button(c, Vector2.ZERO, c.size.x * 0.5, BTN_RED, fire_down)
	if not UiDraw.draw_icon(c, "tack", o - Vector2(0, 16), 64):
		c.draw_colored_polygon(PackedVector2Array([o + Vector2(0, -44), o + Vector2(14, -14), o + Vector2(-14, -14)]), Color.WHITE)
	UiDraw.text_c(c, o + Vector2(0, 32), "압정", 30, Color.WHITE, 6, true, 2.0)
	c.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## P0#2 range ring around 압정 (not ghosted): green and turning while the lock target is in range, grey dashes when
## out; hidden outside the fight.
func _draw_fire_ring(c: Control) -> void:
	if phase != &"boss":
		return
	var ctr: Vector2 = c.size * 0.5 + Vector2(0, 0)
	var rad: float = c.size.x * 0.5 - 2.0
	if lock_in_range:
		var pul: float = 0.5 + 0.5 * sin(now * 8.0)
		c.draw_arc(ctr, rad, 0.0, TAU, 64, Color(INK, 0.85), 11.0, true)
		c.draw_arc(ctr, rad, 0.0, TAU, 64, Color(C_RANGE, 0.75 + 0.25 * pul), 6.0, true)
		for i: int in 3:
			var a0: float = now * 2.4 + TAU * float(i) / 3.0
			c.draw_arc(ctr, rad + 1.0, a0, a0 + 0.6, 12, Color.WHITE, 3.0, true)
	else:
		var n: int = 18
		for i: int in n:
			var a1: float = TAU * float(i) / float(n)
			c.draw_arc(ctr, rad, a1, a1 + TAU / float(n) * 0.55, 6, Color(INK, 0.7), 9.0, true)
			c.draw_arc(ctr, rad, a1, a1 + TAU / float(n) * 0.55, 6, C_NORANGE, 5.0, true)


## 분노: charge ring = rage fraction (cost notches); ready → orange face + flame wiggle; "지금!" badge in the window.
func _draw_rage_btn(c: Control) -> void:
	var ready: bool = rage_frac >= rage_cost - 1e-6
	var rt: float = now - _rage_ready_t
	var pop: float = 1.0 + 0.18 * (1.0 - UiDraw.back_out(rt / 0.25, 3.0)) if ready and rt < 0.25 else 1.0
	var ctr: Vector2 = c.size * 0.5
	c.draw_set_transform(ctr, 0.0, Vector2(pop, pop))
	var rad: float = c.size.x * 0.5
	var o: Vector2 = UiDraw.round_button(c, Vector2.ZERO, rad - 6.0, BTN_RAGE if ready else BTN_RAGE_OFF, false)
	var wig: float = sin(now * 9.0) * 0.12 if ready else 0.0
	c.draw_set_transform(ctr + o - Vector2(0, 10), wig, Vector2(pop, pop))
	if not UiDraw.draw_icon(c, "flame", Vector2.ZERO, 40, Color.WHITE if ready else Color(1, 1, 1, 0.55)):
		c.draw_circle(Vector2.ZERO, 14, Color8(0xff, 0x5a, 0x1f))
	c.draw_set_transform(ctr, 0.0, Vector2(pop, pop))
	UiDraw.text_c(c, o + Vector2(0, 22), "분노", 21, Color.WHITE if ready else Color(1, 1, 1, 0.7), 5, true, 0.0)
	# charge ring
	var a0: float = -PI / 2.0
	c.draw_arc(Vector2.ZERO, rad - 2.0, 0.0, TAU, 48, Color(INK, 0.8), 8.0, true)
	if rage_frac > 0.0:
		c.draw_arc(Vector2.ZERO, rad - 2.0, a0, a0 + TAU * rage_frac, 48, Color8(0xff, 0xd2, 0x3f) if ready else C_RAGE, 5.0, true)
	var notches: int = maxi(1, roundi(1.0 / maxf(0.05, rage_cost)))
	for i: int in notches:
		var a: float = a0 + TAU * float(i) / float(notches)
		c.draw_line(Vector2(cos(a), sin(a)) * (rad - 7.0), Vector2(cos(a), sin(a)) * (rad + 3.0), INK, 2.5)
	if ready and boss_vuln and phase == &"boss":
		var pul: float = 1.0 + 0.1 * sin(now * 14.0)
		c.draw_set_transform(ctr + Vector2(-rad * 0.62, -rad * 0.78), deg_to_rad(-8.0), Vector2(pul, pul) * pop)
		UiDraw.panel(c, Rect2(Vector2(-36, -16), Vector2(72, 32)), Color8(0xff, 0xd2, 0x3f), 10, 3, 3)
		UiDraw.text_c(c, Vector2.ZERO, "지금!", 20, INK, 0, true, 0.0)
	c.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## Full-screen layer: flash, damage vignette, kill letterbox + slow-mo vignette.
func _draw_screen_fx(c: Control = null) -> void:
	var r := Rect2(Vector2.ZERO, _fx.size)
	var vt: float = now - _vig_dmg_t
	if vt < 0.45:
		_vignette(r, Color(1, 0.1, 0.05, 0.55 * (1.0 - vt / 0.45)))
	# Device feedback 2026-10-14 ("동영상 나올 때 위아래 짤림"): the kill letterbox bars read as a cropped screen on
	# a tall phone, and the stepped side vignette showed up as vertical bands. Keep only a faint warm tint.
	if _letterbox > 0.0:
		_fx.draw_rect(r, Color(0.08, 0.04, 0.0, 0.10 * UiDraw.smooth(_letterbox)))
	var ft: float = now - _flash_t
	if ft < _flash_dur:
		_fx.draw_rect(r, Color(_flash_col, _flash_col.a * (1.0 - ft / _flash_dur)))


func _vignette(r: Rect2, col: Color) -> void:
	var steps: int = 10
	for i: int in steps:
		var k: float = float(i) / float(steps)
		var w: float = r.size.x * 0.16 * (1.0 - k)
		var a: float = col.a * (1.0 - k) * 0.22
		var cc := Color(col, a)
		_fx.draw_rect(Rect2(r.position, Vector2(w, r.size.y)), cc)
		_fx.draw_rect(Rect2(Vector2(r.end.x - w, 0), Vector2(w, r.size.y)), cc)
		_fx.draw_rect(Rect2(r.position, Vector2(r.size.x, w)), cc)
		_fx.draw_rect(Rect2(Vector2(0, r.end.y - w), Vector2(r.size.x, w)), cc)
