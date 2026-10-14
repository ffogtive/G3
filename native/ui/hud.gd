class_name Hud
extends CanvasLayer
## In-game HUD (NATIVE_PORT 3-8 / M1c, M1d N1 N4; DESIGN_REVIEW P0 #2 #4 #6), portrait 540-wide canvas_items layout
## anchored to the edges, every widget under `safe` (notch / Dynamic Island / home indicator insets):
##  - top: N1 progress bar + "원흉까지 N m" pill (jam), villain plate = name + HP bar with white damage lag + tires +
##    "약점!" tag (boss), combo, release counter sign (release), pause.
##  - bottom: ◀ ▶ lanes, 경적, big 압정 (fire, hold) with the P0#2 range ring (green in range, grey out), 분노 with a
##    segmented charge ring (one segment per rage cost, "MAX" glow when full; the only rage gauge — device feedback
##    2026-10-14 #2 dropped the duplicate rage bar), bumper HP row, speedometer, one-line hint chip (P0#4, ≤ 16 chars).
##  - overlays on root: N4 lock-on reticle, pops (hit numbers, "빗나감!"), banners, flash / vignette / kill letterbox,
##    result card, fail card.
## Driving it (view/game.gd): apply_state(GameSim.state()) every frame, on_event(e) for each drained sim event,
## bind_world(camera, road) once; show_result(result, record) / show_fail(info) on those phases; card choices come
## back as card_choice(&"next" | &"retry" | &"menu"). set_state() is the M1a N1 path (jam slice, tests).
## Buttons are drawn here; touches are read by LaneInput from the rects registered via bind_input() (multi-touch).
## All animation runs on real time: _process(delta), or advance(dt) when `manual` (deterministic shots).
## Skills (docs/SKILLS.md 2-4, 3-3, interface §6 ui/hud.gd): the 분노 ring is the only rage gauge — 5 segments, long
## ticks + labels at 1 · 3 · MAX (locked in the jam: only t1 there), fill colour by level (orange → red-orange → gold
## with a sparkle running round), the face shows state.skills.next_tier (경적 / 폭격 / 참교육 + the equipped finish).
## Item buttons item1 (left thumb, above ▶) / item2 (above 경적) appear when the loadout has items: cooldown pie +
## seconds, charge pips, grey + reason when unusable. Boss bar: gold 처형선 at execute_frac. Events: skill_start →
## banner (stamp for t5) + focus lines (t5), skill_hit → per-hit ticks and one summed number + recipe flash,
## "한 번 더!" for a t5 that did not finish, skill_denied → wobble + reason, tier_ready / item_ready → ring / button
## pop. Cinematics (t5, finisher) dim the controls; "탭: 건너뛰기" shows once skipping is allowed.

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
const RAGE_LIFT: float = 44.0
const SZ_ITEM: float = 90.0  # ≥ 64 pt (88.6 u)
const BTN_T3: Array = [Color8(0xff, 0x8a, 0x5a), Color8(0xf0, 0x40, 0x1a), Color8(0xa8, 0x22, 0x0a)]
const BTN_T5: Array = [Color8(0xff, 0xf0, 0x8a), Color8(0xff, 0xc8, 0x1f), Color8(0xc8, 0x84, 0x08)]
const BTN_JUMP: Array = [Color8(0x8a, 0xf0, 0xa8), Color8(0x2c, 0xc0, 0x5e), Color8(0x17, 0x84, 0x3c)]
const BTN_DRONE: Array = [Color8(0x8a, 0xe4, 0xff), Color8(0x14, 0xa8, 0xd8), Color8(0x0c, 0x6a, 0x94)]
const BTN_TOW: Array = [Color8(0xff, 0xd8, 0x8a), Color8(0xe8, 0xa0, 0x1a), Color8(0xa0, 0x66, 0x08)]
const C_T3 := Color8(0xff, 0x4a, 0x1a)
const C_GOLD := Color8(0xff, 0xd2, 0x3f)
## t1 "경적" → "충격파" (rvB / feedback ③): the 분노 dial showed the same horn face and word as the 경적 button 80 px
## away, right above 압정, so a high 압정 press read as "a honk". The t1 face is a shockwave glyph now.
const TIER_FACE: Dictionary = {0: "분노", 1: "충격파", 3: "폭격", 5: "참교육"}
## Damage numbers are shown ×10 (view only; no HP number is shown anywhere): "-3" ticks read as a weak skill (rvB).
const DMG_SHOW_MUL: int = 10
const ITEM_LABEL: Dictionary = {"mv_jump": "점프", "mv_drone": "드론", "mv_tow": "레커"}
const DENY_TEXT: Dictionary = {"rage": "분노 부족!", "cool": "쿨타임!", "charges": "다 썼다!", "target": "대상 없음",
	"phase": "지금은 못 써!", "busy": "시전 중!", "blocked": "원흉은 못 넘는다!", "room": "착지 공간 없음"}
## Skill banner placement: higher and smaller than the phase banners so the framed cars stay readable.
const SKILL_BANNER_Y: float = 0.20  # 0.26 → 0.20 (rvB): the text sat on the player's car in the boss framing

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
var _btn_left: Control
var _btn_right: Control
var _btn_horn: Control
var _btn_fire: Control
var _btn_rage: Control
var _fire_ring: Control
var _rage_ring: Control
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
var _rage_max_t: float = -99.0
var _dry_pop_t: float = -99.0
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

# ── skills (apply_state: state.skills, or derived from rage / phase / lock while the sim has no skills block)
var skill_segs: int = 0
var next_tier: int = 0
var tiers_ready: Array[int] = []
var skill_mode: String = "off"
var execute_frac: float = 0.0
var items: Array[Dictionary] = []
var skill_active: Dictionary = {}
## Equipped finish (loadout.finish) for the t5 face; view/game.gd sets it, default rocket.
var finish_id: String = "rocket"
var _sim_skip: int = -1   # state.skills.skip_ready: 1 / 0, -1 = not published (derive from the kill clock)
var skip_after: float = 0.6
var _btn_items: Array[Control] = []
var _item_pop_t: Array[float] = [-99.0, -99.0]
var _item_deny_t: Array[float] = [-99.0, -99.0]
var _items_layout: bool = false
var _tier_flash: Dictionary = {}       # tier → time
var _deny_t: float = -99.0
var _focus_t: float = -99.0
var _focus_dur: float = 0.35
var _cine_until: float = -99.0
var _cine_mul: float = 1.0
var _kill_real: float = -99.0
var _skill_sum: Dictionary = {}        # "<id>:<target>" → summed damage of the current cast


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
	_bottom_left(_hp_row, 112, 330, 198, 158)  # centred on the speedometer (the rage bar under it is gone)
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
	_corner(_btn_rage, false, 32, 16 + SZ_FIRE + RAGE_LIFT, SZ_RAGE)  # RAGE_LIFT 22 → 44: a thumb-wide gap over 압정
	_rage_ring = _custom(_draw_rage_ring)
	_corner(_rage_ring, false, 32 - 22, 16 + SZ_FIRE + RAGE_LIFT - 22, SZ_RAGE + 44)  # room for the 1 · 3 · MAX labels
	for i: int in 2:
		var slot: int = i + 1
		var b: Control = _custom(func(c: Control) -> void: _draw_item(c, slot))
		b.visible = false
		_btn_items.append(b)
	_corner(_btn_items[0], true, 14 + SZ_LANE + 16, 16 + SZ_LANE + 16, SZ_ITEM)      # left thumb: above ▶
	_corner(_btn_items[1], false, 14 + SZ_FIRE + 16 + 2, 16 + SZ_HORN + 12, SZ_ITEM) # right thumb: above 경적
	_btn_horn = _custom(_draw_horn)
	_corner(_btn_horn, false, 14 + SZ_FIRE + 16, 16, SZ_HORN)
	_btn_pause = _custom(_draw_pause)
	_btn_pause.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_btn_pause.offset_left = -60
	_btn_pause.offset_right = -14
	_btn_pause.offset_top = 52
	_btn_pause.offset_bottom = 98
	for b: Control in [_btn_left, _btn_right, _btn_horn, _btn_fire, _btn_rage, _btn_items[0], _btn_items[1]]:
		_btn_alpha[b] = IDLE_ALPHA
		b.modulate.a = IDLE_ALPHA
	_controls = [_btn_left, _btn_right, _btn_horn, _btn_fire, _btn_rage, _fire_ring, _rage_ring, _hp_row, _gauge, _speed, _unit,
		_btn_items[0], _btn_items[1]]
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
	for c: Control in [_bar, _pill, _boss, _chip, _hp_row, _gauge, _btn_left, _btn_right, _btn_horn, _btn_fire,
			_btn_rage, _btn_pause, _btn_items[0], _btn_items[1]]:
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


## Item button sizes in points (shown slots only; ≥ 64 pt like every control).
func item_sizes_pt() -> Dictionary:
	var out: Dictionary = {}
	for i: int in 2:
		if _item_of(i + 1).is_empty():
			continue
		out["item%d" % (i + 1)] = minf(_btn_items[i].size.x, _btn_items[i].size.y) * 390.0 / 540.0
	return out


## Fill (0..1) of each 분노 ring segment: one segment per rage cost (5 at the default 0.2).
static func rage_segments(frac: float, cost: float) -> PackedFloat32Array:
	var n: int = clampi(roundi(1.0 / maxf(0.05, cost)), 1, 10)
	var out := PackedFloat32Array()
	out.resize(n)
	for i: int in n:
		out[i] = clampf(clampf(frac, 0.0, 1.0) * float(n) - float(i), 0.0, 1.0)
	return out


## Full 분노 segments (= charges ready at the current cost).
func rage_level() -> int:
	var n: int = Hud.rage_segments(rage_frac, rage_cost).size()
	return clampi(floori(rage_frac * float(n) + 1e-4), 0, n)


## Full rage: the 분노 ring glows "MAX".
func rage_max() -> bool:
	return rage_frac >= 1.0 - 1e-4


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
	if rage_max() and _rage_max_t < 0.0:
		_rage_max_t = now
	elif not rage_max():
		_rage_max_t = -99.0
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
	_apply_skills(st)


## state.skills (interface §6) → ring / face / items / execute line; derived from rage + phase + lock when the sim has
## no skills block yet (ladder 1·3·5, jam and before the lock = t1 only).
func _apply_skills(st: Dictionary) -> void:
	var sk: Dictionary = st.get("skills", {}) if st.get("skills") is Dictionary else {}
	var ladder: Array = [1, 3, 5]
	if sk.is_empty():
		skill_segs = rage_level()
		skill_mode = "fight" if phase == &"boss" and lock_active else ("jam" if phase in [&"intro", &"jam", &"boss"] else "off")
		tiers_ready.clear()
		for t: int in ladder:
			if skill_segs >= t and (skill_mode == "fight" or (skill_mode == "jam" and t == 1)):
				tiers_ready.append(t)
		next_tier = tiers_ready.max() if not tiers_ready.is_empty() else 0
		execute_frac = 0.4 if skill_mode == "fight" and tiers_ready.has(5) else 0.0
		skill_active = {}
		_sim_skip = -1
		items = []
	else:
		skill_segs = int(sk.get("segs", rage_level()))
		skill_mode = str(sk.get("mode", "off"))
		tiers_ready.clear()
		for t: Variant in sk.get("rage_tiers_ready", []):
			tiers_ready.append(int(t))
		next_tier = int(sk.get("next_tier", 0))
		execute_frac = float(sk.get("execute_frac", 0.0))
		skill_active = sk.get("active", {}) if sk.get("active") is Dictionary else {}
		_sim_skip = int(sk.get("skip_ready", false)) if sk.has("skip_ready") else -1
		items.clear()
		for it: Variant in sk.get("items", []):
			if it is Dictionary:
				items.append(it)
	var want_items: bool = not items.is_empty()
	if want_items != _items_layout:
		_items_layout = want_items
		if want_items:  # the bumper row moves above the speedometer, the item buttons take its place
			_bottom_left(_hp_row, 16, 250, 268, 230)
		else:
			_bottom_left(_hp_row, 112, 330, 198, 158)
		_zones_size = Vector2.ZERO
	for i: int in 2:
		var used: bool = not _item_of(i + 1).is_empty()
		if used != bool(_btn_items[i].get_meta(&"slot_used", false)):
			_zones_size = Vector2.ZERO
		_btn_items[i].set_meta(&"slot_used", used)


func _slot_of(id: String) -> int:
	for it: Dictionary in items:
		if str(it.get("id", "")) == id:
			return clampi(int(it.get("slot", 1)), 1, 2)
	return 1 if id == "mv_jump" else 2


func _item_of(slot: int) -> Dictionary:
	for it: Dictionary in items:
		if int(it.get("slot", 0)) == slot:
			return it
	return {}


## One drained GameSim event (UI side: pops, banners, flashes, counters).
func on_event(e: Dictionary) -> void:
	match str(e.get("type", "")):
		"skill_start", "skill_hit", "skill_end", "skill_denied", "tier_ready", "item_ready", "finisher":
			_on_skill_event(e)
		"fire":
			if not bool(e.get("drone", false)):  # the passive drone's shots are not the player's 압정 (no button recoil)
				_fire_kick = now
		"hit":
			var big: bool = bool(e.get("window", false)) or str(e.get("kind", "")) == "bomb"
			var dmg: float = float(e.get("dmg", 0.0))
			if road != null and e.has("s"):
				var wp: Vector3 = road.position(float(e["s"]), float(e.get("x", 0.0))) + Vector3(0, 2.2, 0)
				if str(e.get("kind", "")) == "mini":
					pops.pop(wp, "-%d" % (roundi(dmg) * DMG_SHOW_MUL), "hit")
				elif bool(e.get("immune", false)):
					pops.pop(wp, "막힘!", "miss")
				elif not _under_skill(int(e.get("target_id", -2))):  # the skill sum shows that damage
					pops.pop(wp, ("-%d!" if big else "-%d") % (maxi(1, roundi(dmg)) * DMG_SHOW_MUL), "crit" if big else "hit")
				if int(e.get("popped", 0)) > 0:
					pops.pop(wp + Vector3(0, 1.2, 0), "펑크!", "crit")
			if big:
				flash(Color(1, 0.95, 0.7, 0.35), 0.1)
		"fire_dry":  # 압정 in the jam with nothing to aim at (never a honk): dull wobble + a short pop
			_miss_t = now
			_haptic("miss")
			if now - _dry_pop_t > 1.2 and road != null:
				_dry_pop_t = now
				pops.pop(road.position(float(e.get("s", player_s)) + 3.0, float(e.get("x", 0.0))) + Vector3(0, 2.0, 0), "조준 대상 없음", "miss")
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
			flash(Color(1, 0.96, 0.85, 0.4), 0.1)  # was white 0.85 / 0.22 s: with the t5 flash it bleached the kill frame
			pops.clear_pops()  # the killing blow shows no sum; stale tack / item pops must not ride into the finisher
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


## Skill events (UI side): banners, focus lines, flashes, damage pops, denied wobble, ready pops.
func _on_skill_event(e: Dictionary) -> void:
	var key: String = SkillCues.fx_key(e)
	var rec: Dictionary = SkillCues.recipe(key)
	var id: String = str(e.get("id", ""))
	match str(e.get("type", "")):
		"skill_start":
			if str(e.get("chan", "rage")) == "item":
				_item_pop_t[_slot_of(id) - 1] = now
				# rvB: item casts had no banner, so a 드론 tap still showed the last "압정 폭격!!" banner
				var ib: String = str(rec.get("castBanner", rec.get("banner", "")))
				if ib != "":
					banner.show_banner(ib, "skill", 0.6, "", SKILL_BANNER_Y, 0.66)
			else:
				_rage_ready_t = now  # the button kicks on the cast
			match key:
				"t1":
					var t1b: String = str(rec.get("bannerWave", "경적 충격파!!")) if id == "t1_wave" else str(rec.get("banner", "분노 경적!!"))
					banner.show_banner(t1b, "skill", 0.75, "", SKILL_BANNER_Y, 0.78)  # fight t1 = the 충격파 face
					if id == "t1_horn":
						flash(Color(1.0, 0.82, 0.23, 0.3), 0.12)  # jam: the rage_horn tick is the impact
				"t3":
					banner.show_banner(str(rec.get("banner", "압정 폭격!!")), "skill3", 0.9, "", SKILL_BANNER_Y, 0.85)
				"t5":
					banner.show_banner(str(rec.get("banner", "참교육!!")), "stamp", 1.1, "", SKILL_BANNER_Y, 0.85)
					_focus_t = now
					_focus_dur = SkillCues.impact_delay("t5")
					_cine_until = now + 1.0
			_skill_sum.erase("%s:%d" % [id, int(e.get("target_id", -1))])
		"skill_hit":
			var sk: String = "%s:%d" % [id, int(e.get("target_id", -1))]
			var dmg: float = float(e.get("dmg", 0.0))
			var tot: float = float(_skill_sum.get(sk, 0.0)) + dmg
			_skill_sum[sk] = tot
			var idx: int = int(e.get("idx", 0))
			var n: int = int(e.get("n", 1))
			var wp: Vector3 = Vector3.INF
			if road != null and e.has("s"):
				wp = road.position(float(e["s"]), float(e.get("x", 0.0))) + Vector3(0, 2.4, 0)
			var killed: bool = bool(e.get("killed", false))
			if idx == 0:
				var fl: Variant = rec.get("flash")
				if killed:
					pass  # the "kill" flash alone owns the kill tick (two stacked whites bleached the t5 impact frame)
				elif fl is Array and (fl as Array).size() >= 3:
					flash(Color(Color.html(str(fl[0])), float(fl[1])), float(fl[2]) / 1000.0)
				else:
					var dflt: Dictionary = {"t1": [Color(1, 0.82, 0.23, 0.3), 0.09], "t3": [Color(1, 0.48, 0.1, 0.25), 0.12],
						"t5": [Color(1, 0.96, 0.85, 0.45), 0.07], "mv_jump": [Color(1, 0.95, 0.85, 0.18), 0.08]}
					if dflt.has(key):
						flash((dflt[key] as Array)[0] as Color, float((dflt[key] as Array)[1]))
				if key == "mv_jump" and road != null:  # at the landing (the hit s/x is the villain's)
					var pl: Dictionary = _state.get("player", {})
					pops.pop(road.position(float(pl.get("s", player_s)), float(pl.get("x", 0.0))) + Vector3(0, 3.4, 0),
						str(rec.get("banner", "쿵!")), "big")
				if key == "t5":
					_focus_t = -99.0
			if not wp.is_finite():
				return
			if bool(e.get("immune", false)):
				pops.pop(wp, "막힘!", "miss")
			elif n > 1 and idx < n - 1:
				if n <= 4:  # t3 ticks; the drone's 6 bomblets only show the sum (6 ticks were clutter)
					pops.pop(wp + Vector3(0.6 * float(idx % 2 * 2 - 1), -0.4, 0), "-%d" % (maxi(1, roundi(dmg)) * DMG_SHOW_MUL), "tick")
			elif not killed and tot > 0.0:  # "치명!" only here: on every window tack hit it meant nothing (rvB)
				pops.pop(wp + Vector3(0, 1.4, 0), ("치명! -%d" if bool(e.get("window", false)) else "-%d") % (maxi(1, roundi(tot)) * DMG_SHOW_MUL), "big")
			if int(e.get("popped", 0)) > 0:
				pops.pop(wp + Vector3(0, 1.9, 0), "펑크!", "crit")
			if key == "t5" and not killed and idx >= n - 1:
				pops.pop(wp + Vector3(0, -0.6, 0), "한 번 더!", "again")
		"skill_end":
			if key == "t5" or bool(e.get("skipped", false)):
				_cine_until = minf(_cine_until, now)
		"skill_denied":
			_deny_t = now
			if str(e.get("chan", "rage")) == "item":
				_item_deny_t[_slot_of(id) - 1] = now
			if road != null:
				var pp: Dictionary = _state.get("player", {})
				pops.pop(road.position(float(pp.get("s", player_s)), float(pp.get("x", 0.0))) + Vector3(0, 3.0, 0),
					str(DENY_TEXT.get(str(e.get("reason", "rage")), "분노 부족!")), "miss")
		"tier_ready":
			var tier: int = int(e.get("tier", 0))
			_tier_flash[tier] = now
			_rage_ready_t = now
			if tier >= 5 and phase == &"boss":
				banner.show_banner("분노 MAX!", "kill", 0.9, "", SKILL_BANNER_Y, 0.8)
		"item_ready":
			var sl3: int = int(e.get("slot", 0))
			if sl3 >= 1 and sl3 <= 2:
				_item_pop_t[sl3 - 1] = now
		"finisher":
			_kill_real = now


## A rage / item skill is landing on this villain right now (its own sum pop shows the damage; tack pops would pile on).
func _under_skill(target: int) -> bool:
	return target >= 0 and str(skill_active.get("id", "")) != "" and int(skill_active.get("target_id", -1)) == target


## Skippable cinematic right now: the sim's state.skills.skip_ready when it publishes one (the hint and the tap
## must agree: the HUD's own kill clock ran ~30 ms ahead of the sim's and a tap in that gap was lost), else
## active.skippable or the kill phase past finish.skipAfter.
func skip_hint_visible() -> bool:
	if _sim_skip >= 0:
		return _sim_skip == 1
	if bool(skill_active.get("skippable", false)):
		return true
	var after: float = skip_after
	var fc: Variant = SkillCues.cfg().get("finish")
	if fc is Dictionary:
		after = float((fc as Dictionary).get("skipAfter", skip_after))
	return phase == &"kill" and _kill_t > -90.0 and now - _kill_t >= after


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
			banner.show_banner("참교육 완료!", "kill", 2.0, line, 0.68, 0.85)  # low: the finisher plays in the upper band
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
	for i: int in 2:
		if not bool(_btn_items[i].get_meta(&"slot_used", false)):
			want[_btn_items[i]] = 0.0
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
	# cinematics (t5 cast until 1.0 s, kill) dim the controls; they come back within 0.25 s
	var cine: bool = now < _cine_until or bool(skill_active.get("cine", false))
	_cine_mul = move_toward(_cine_mul, 0.3 if cine else 1.0, dt / (0.12 if cine else 0.25))
	for i: int in 2:  # a slot that just got an item fades in with the controls
		if bool(_btn_items[i].get_meta(&"slot_used", false)) and phase in [&"intro", &"jam", &"boss"]:
			_group_alpha[_btn_items[i]] = 1.0
		elif not bool(_btn_items[i].get_meta(&"slot_used", false)):
			_group_alpha[_btn_items[i]] = 0.0
	for c: Control in _group_alpha:
		var a: float = move_toward(float(_vis.get(c, 1.0)), float(_group_alpha[c]), dt / 0.22)
		_vis[c] = a
		c.visible = a > 0.01
		if not _btn_alpha.has(c):
			c.modulate.a = a * (_cine_mul if _controls.has(c) else 1.0)
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
	_ghost(_btn_items[0], _input != null and _input.is_zone_down("item1"), dt)
	_ghost(_btn_items[1], _input != null and _input.is_zone_down("item2"), dt)
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
		_input.set_zone("rage", _btn_rage.get_global_rect())
		for i: int in 2:  # item zones only while the slot holds an item (an empty slot must not eat a lane swipe)
			_input.set_zone("item%d" % (i + 1), _btn_items[i].get_global_rect().grow(4.0) if bool(_btn_items[i].get_meta(&"slot_used", false)) else Rect2())
		_input.set_zone("pause", _btn_pause.get_global_rect().grow(6.0))


## Idle buttons are ghosted (0.45) so the cars behind the player stay visible; 1.0 while pressed (≈0.08 s fade),
## times the phase visibility.
func _ghost(b: Control, down: bool, delta: float) -> void:
	var a: float = move_toward(float(_btn_alpha.get(b, IDLE_ALPHA)), 1.0 if down else IDLE_ALPHA,
		(1.0 - IDLE_ALPHA) * delta / 0.08)
	_btn_alpha[b] = a
	b.modulate.a = a * float(_vis.get(b, 1.0)) * _cine_mul


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
	if execute_frac > 0.0 and phase == &"boss":  # t5 처형선: under it a tap of MAX finishes the villain
		var ex: float = inner.position.x + inner.size.x * execute_frac
		var under: bool = boss_hp <= execute_frac
		if under:
			var gp: float = 0.5 + 0.5 * sin(now * 12.0)
			c.draw_style_box(UiDraw.box(Color(1.0, 0.86, 0.25, 0.35 + 0.35 * gp), 6),
				Rect2(inner.position, Vector2(maxf(8.0, inner.size.x * boss_hp), inner.size.y)))
		c.draw_line(Vector2(ex, bar.position.y - 2), Vector2(ex, bar.end.y + 2), INK, 6.0)
		c.draw_line(Vector2(ex, bar.position.y), Vector2(ex, bar.end.y), C_GOLD, 3.0)
		c.draw_colored_polygon(PackedVector2Array([Vector2(ex - 8, bar.end.y + 10), Vector2(ex + 8, bar.end.y + 10),
			Vector2(ex, bar.end.y + 1)]), C_GOLD)
		UiDraw.text_c(c, Vector2(ex, bar.end.y + 20), "참교육", 15, C_GOLD if not under else Color.WHITE, 4, true, 0.0)
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


## 분노 button: the face is the tier a tap casts now (state.skills.next_tier): 경적 (t1, orange), 폭격 (t3, red-orange,
## a tack rain), 참교육 (t5, gold, the equipped finish's icon); grey 분노 when nothing is ready. Kicks on ready / cast,
## wobbles on a denied tap.
func _rage_pop() -> float:
	var rt: float = now - _rage_ready_t
	return 1.0 + 0.18 * (1.0 - UiDraw.back_out(rt / 0.25, 3.0)) if rt < 0.25 else 1.0


func _draw_rage_btn(c: Control) -> void:
	var tier: int = next_tier
	var pop: float = _rage_pop()
	var dt_: float = now - _deny_t
	var wob: float = sin(dt_ * 50.0) * 0.1 * (1.0 - dt_ / 0.3) if dt_ < 0.3 else 0.0
	var ctr: Vector2 = c.size * 0.5
	c.draw_set_transform(ctr, wob, Vector2(pop, pop))
	var rad: float = c.size.x * 0.5
	var cols: Array = BTN_RAGE_OFF if tier <= 0 else (BTN_RAGE if tier == 1 else BTN_T3 if tier == 3 else BTN_T5)
	var o: Vector2 = UiDraw.round_button(c, Vector2.ZERO, rad - 6.0, cols, _input != null and _input.is_zone_down("rage"))
	var wig: float = sin(now * 9.0) * 0.1 if tier > 0 else 0.0
	c.draw_set_transform(ctr + (o - Vector2(0, 11)) * pop, wig, Vector2(pop, pop))
	var ink: Color = Color.WHITE if tier > 0 else Color(1, 1, 1, 0.55)
	match tier:
		1:  # 충격파: a burst dot and three wave arcs (not the 경적 button's horn)
			c.draw_circle(Vector2(-14, 0), 6.0, ink)
			for k: int in 3:
				var rr: float = 9.0 + 8.0 * float(k)
				c.draw_arc(Vector2(-14, 0), rr, -0.85, 0.85, 12, Color(ink, 1.0 - 0.22 * float(k)), 4.0 - 0.6 * float(k), true)
		3:
			for k: int in 3:
				var off := Vector2(-14.0 + 14.0 * float(k), -6.0 + (6.0 if k == 1 else 0.0))
				if not UiDraw.draw_icon(c, "tack", off, 26, ink):
					c.draw_circle(off, 7, ink)
			for k: int in 3:
				var x: float = -16.0 + 16.0 * float(k)
				c.draw_line(Vector2(x + 4, -24), Vector2(x - 2, -14), Color(1, 1, 1, 0.8), 2.5, true)
		5:
			_finish_icon(c, finish_id, Vector2.ZERO, 40.0)
		_:
			if not UiDraw.draw_icon(c, "flame", Vector2.ZERO, 40, ink):
				c.draw_circle(Vector2.ZERO, 14, Color8(0xff, 0x5a, 0x1f))
	c.draw_set_transform(ctr, wob, Vector2(pop, pop))
	var fs: int = 20 if tier == 5 else 21
	UiDraw.text_c(c, o + Vector2(0, 23), str(TIER_FACE.get(tier, "분노")), fs, INK if tier == 5 else ink, 5 if tier != 5 else 0, true, 0.0)
	c.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## Small finisher glyphs (rocket = the svg icon; balloon / heli / ufo drawn).
func _finish_icon(c: Control, id: String, o: Vector2, w: float) -> void:
	var k: float = w / 40.0
	match id:
		"balloon":
			for b: Array in [[Vector2(-9, -6), Color8(0xff, 0x3b, 0x30)], [Vector2(8, -9), Color8(0x2f, 0x6f, 0xd6)], [Vector2(0, -16), Color8(0x3c, 0xe0, 0x8e)]]:
				var p: Vector2 = o + (b[0] as Vector2) * k
				c.draw_line(p + Vector2(0, 8) * k, o + Vector2(0, 16) * k, INK, 2.0, true)
				c.draw_circle(p, 9.5 * k, INK)
				c.draw_circle(p, 7.5 * k, b[1] as Color)
				c.draw_circle(p + Vector2(-2.5, -2.5) * k, 2.0 * k, Color(1, 1, 1, 0.8))
		"heli":
			c.draw_rect(Rect2(o + Vector2(-12, -6) * k, Vector2(20, 13) * k), INK)
			c.draw_rect(Rect2(o + Vector2(-10, -4) * k, Vector2(16, 9) * k), Color.WHITE)
			c.draw_rect(Rect2(o + Vector2(6, -2) * k, Vector2(12, 4) * k), INK)
			c.draw_line(o + Vector2(-17, -11) * k, o + Vector2(15, -11) * k, INK, 3.0 * k, true)
			c.draw_line(o + Vector2(-1, -11) * k, o + Vector2(-1, -6) * k, INK, 2.5 * k, true)
			c.draw_line(o + Vector2(-1, 7) * k, o + Vector2(-1, 16) * k, INK, 1.5 * k, true)
		"ufo":
			c.draw_circle(o + Vector2(0, -5) * k, 8.0 * k, Color8(0x7a, 0xff, 0xd8))
			c.draw_colored_polygon(PackedVector2Array([o + Vector2(-18, 2) * k, o + Vector2(-8, -4) * k, o + Vector2(8, -4) * k,
				o + Vector2(18, 2) * k, o + Vector2(8, 7) * k, o + Vector2(-8, 7) * k]), Color(0.85, 0.88, 0.93))
			c.draw_colored_polygon(PackedVector2Array([o + Vector2(-7, 7) * k, o + Vector2(7, 7) * k, o + Vector2(12, 19) * k,
				o + Vector2(-12, 19) * k]), Color(0.5, 1.0, 0.8, 0.6))
		_:
			if not UiDraw.draw_icon(c, "rocket", o, w, Color.WHITE):
				c.draw_colored_polygon(PackedVector2Array([o + Vector2(0, -16) * k, o + Vector2(8, 8) * k, o + Vector2(-8, 8) * k]), Color.WHITE)


## The 분노 ring (its own control: never ghosted — it is the only rage gauge). 5 segments (6° gaps); long ticks with the
## labels 1 · 3 · MAX at the tier boundaries (lock glyph instead of 3 / MAX while only t1 can fire: jam, before the
## lock); fill colour by level (1–2 orange, 3–4 red-orange, 5 gold with a sparkle running round); a tier that just got
## ready flashes white; full rage = pulsing halo + MAX tag ("지금!" in the signature window).
func _draw_rage_ring(c: Control) -> void:
	var pop: float = _rage_pop()
	var ctr: Vector2 = c.size * 0.5
	var rad: float = SZ_RAGE * 0.5
	c.draw_set_transform(ctr, 0.0, Vector2(pop, pop))
	var a0: float = -PI / 2.0
	var segs: PackedFloat32Array = Hud.rage_segments(rage_frac, rage_cost)
	var n: int = segs.size()
	var span: float = TAU / float(n)
	var gap: float = deg_to_rad(6.0)
	var rr: float = rad - 2.0
	var full: bool = rage_max()
	var lvl: int = clampi(skill_segs, 0, n)
	var fill: Color = C_RAGE if lvl <= 2 else (C_T3 if lvl < n else C_GOLD)
	if full:
		var burst: float = maxf(0.0, 1.0 - (now - _rage_max_t) / 0.35)
		var pul: float = 0.5 + 0.5 * sin(now * 10.0)
		for k: int in 3:
			c.draw_arc(Vector2.ZERO, rr + 6.0 + 4.0 * float(k) + 8.0 * burst, 0.0, TAU, 56,
				Color(1.0, 0.86, 0.3, (0.42 - 0.12 * float(k)) * (0.55 + 0.45 * pul) + 0.3 * burst), 4.0, true)
	c.draw_arc(Vector2.ZERO, rr, 0.0, TAU, 64, Color(INK, 0.9), 13.0, true)
	for i: int in n:
		var s0: float = a0 + span * float(i) + gap * 0.5
		var s1: float = a0 + span * float(i + 1) - gap * 0.5
		c.draw_arc(Vector2.ZERO, rr, s0, s1, 12, C_OFF, 8.0, true)
		var part: float = segs[i]
		if part > 0.0:
			var col: Color = fill if part >= 1.0 else C_RAGE.lerp(Color.WHITE, 0.25)
			if full:
				col = Color.WHITE.lerp(C_GOLD, 0.55 + 0.45 * sin(now * 10.0 + float(i)))
			c.draw_arc(Vector2.ZERO, rr, s0, s0 + (s1 - s0) * part, 12, col, 8.0, true)
	# tier ticks + labels (tier t ends segment t: angle a0 + span·t)
	var only_t1: bool = skill_mode == "jam" or skill_mode == "off"
	for tier: int in [1, 3, 5]:
		if tier > n:
			continue
		var ang: float = a0 + span * float(tier)
		var dir := Vector2(cos(ang), sin(ang))
		var reached: bool = skill_segs >= tier
		var locked: bool = only_t1 and tier > 1
		var fl: float = maxf(0.0, 1.0 - (now - float(_tier_flash.get(tier, -99.0))) / 0.35)
		var tick_c: Color = (Color.WHITE if reached and not locked else Color(0.6, 0.64, 0.7, 0.9)).lerp(Color.WHITE, fl)
		c.draw_line(dir * (rr - 9.0), dir * (rr + 9.0 + 4.0 * fl), Color(INK, 0.95), 6.0, true)
		c.draw_line(dir * (rr - 8.0), dir * (rr + 8.0 + 4.0 * fl), tick_c, 3.0, true)
		var lp: Vector2 = dir * (rr + 19.0)
		if tier == 5:
			lp = Vector2(0, -(rr + 18.0))
		if locked:
			if not UiDraw.draw_icon(c, "lock", lp, 18, Color(1, 1, 1, 0.75)):
				c.draw_rect(Rect2(lp - Vector2(6, 5), Vector2(12, 10)), Color(1, 1, 1, 0.7))
		else:
			var lab: String = "MAX" if tier == 5 else str(tier)
			var ls: int = 15 if tier == 5 else 17
			var lc: Color = (C_GOLD if tier == 5 else Color.WHITE) if reached else Color(0.75, 0.78, 0.84, 0.9)
			c.draw_set_transform(ctr + lp * pop, 0.0, Vector2.ONE * pop * (1.0 + 0.4 * fl))
			UiDraw.text_c(c, Vector2.ZERO, lab, ls, lc, 4, true, 0.0)
			c.draw_set_transform(ctr, 0.0, Vector2(pop, pop))
	if full:  # a sparkle running round the gold ring
		var sa: float = now * 3.2
		var sp := Vector2(cos(sa), sin(sa)) * rr
		c.draw_colored_polygon(UiDraw.star_points(sp, 7.0, now * 4.0), Color(1, 1, 0.9, 0.95))
	var now_tag: bool = not tiers_ready.is_empty() and boss_vuln and phase == &"boss" and skill_mode == "fight"
	if now_tag or (full and not only_t1):  # in the jam a full ring still glows, but MAX cannot fire there: no tag
		var pul2: float = 1.0 + (0.1 * sin(now * 14.0) if now_tag else 0.07 * sin(now * 10.0))
		c.draw_set_transform(ctr + Vector2(-rad * 0.78, -rad * 0.86), deg_to_rad(-8.0), Vector2(pul2, pul2) * pop)
		UiDraw.panel(c, Rect2(Vector2(-36, -16), Vector2(72, 32)), C_GOLD, 10, 3, 3)
		UiDraw.text_c(c, Vector2.ZERO, "지금!" if now_tag else "MAX", 20, INK, 0, true, 0.0)
	c.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## Item button (88 u): colour + icon per item, cooldown pie unwinding clockwise with the seconds left, charge pips,
## grey + reason glyph when unusable (⌀ no target, 🚫 phase / busy), pop + white ring when it comes back.
func _draw_item(c: Control, slot: int) -> void:
	var it: Dictionary = _item_of(slot)
	if it.is_empty():
		return
	var id: String = str(it.get("id", ""))
	var cool: float = float(it.get("cool", 0.0))
	var cool_max: float = maxf(0.01, float(it.get("cool_max", 1.0)))
	var ready: bool = bool(it.get("ready", cool <= 0.0))
	var usable: bool = bool(it.get("usable", true))
	var pt: float = now - _item_pop_t[slot - 1]
	var pop: float = 1.0 + 0.2 * (1.0 - UiDraw.back_out(pt / 0.25, 3.0)) if pt < 0.25 else 1.0
	var dt_: float = now - _item_deny_t[slot - 1]
	var wob: float = sin(dt_ * 50.0) * 0.1 * (1.0 - dt_ / 0.3) if dt_ < 0.3 else 0.0
	var ctr: Vector2 = c.size * 0.5
	var rad: float = c.size.x * 0.5
	c.draw_set_transform(ctr, wob, Vector2(pop, pop))
	var cols: Array = BTN_JUMP if id == "mv_jump" else (BTN_DRONE if id == "mv_drone" else BTN_TOW)
	if not usable or not ready:
		cols = BTN_RAGE_OFF
	var o: Vector2 = UiDraw.round_button(c, Vector2.ZERO, rad - 4.0, cols, _input != null and _input.is_zone_down("item%d" % slot))
	var ink: Color = Color.WHITE if usable and ready else Color(1, 1, 1, 0.6)
	var ic: Vector2 = o - Vector2(0, 9)
	match id:
		"mv_jump":
			if not UiDraw.draw_icon(c, "jump", ic, 40, ink):
				c.draw_colored_polygon(PackedVector2Array([ic + Vector2(0, -14), ic + Vector2(12, 4), ic + Vector2(-12, 4)]), ink)
		"mv_drone":
			_drone_icon(c, ic, ink)
		_:
			if not UiDraw.draw_icon(c, "wrecker", ic, 40, ink):
				c.draw_circle(ic, 12, ink)
	UiDraw.text_c(c, o + Vector2(0, 21), str(ITEM_LABEL.get(id, "아이템")), 18, ink, 5, true, 0.0)
	if not ready and cool > 0.0:  # cooldown pie: dark sector of the remaining fraction, clockwise from 12 o'clock
		var f: float = clampf(cool / cool_max, 0.0, 1.0)
		var pts := PackedVector2Array([o])
		var steps: int = maxi(2, ceili(40.0 * f))
		for i: int in steps + 1:
			var a: float = -PI / 2.0 + TAU * (1.0 - f) + TAU * f * float(i) / float(steps)
			pts.append(o + Vector2(cos(a), sin(a)) * (rad - 6.0))
		c.draw_colored_polygon(pts, Color(0.04, 0.05, 0.08, 0.62))
		c.draw_arc(o, rad - 3.0, -PI / 2.0, -PI / 2.0 + TAU * (1.0 - f), 40, Color(1, 1, 1, 0.9), 4.0, true)
		UiDraw.text_c(c, o + Vector2(0, -2), str(ceili(cool)), 34, Color.WHITE, 6, true, 0.0)
	var charges: int = int(it.get("charges", -1))
	if charges >= 0:
		for i: int in maxi(1, charges):
			var pc := o + Vector2((float(i) - (maxf(1.0, float(charges)) - 1.0) * 0.5) * 12.0, rad - 2.0)
			c.draw_circle(pc, 5.0, INK)
			c.draw_circle(pc, 3.5, C_GOLD if charges > 0 else C_OFF)
	if not usable:
		var rp := o + Vector2(rad * 0.55, -rad * 0.55)
		c.draw_circle(rp, 13, INK)
		c.draw_circle(rp, 10.5, Color8(0xff, 0x3b, 0x30) if str(it.get("reason", "")) != "target" else Color8(0x9a, 0xa3, 0xae))
		c.draw_arc(rp, 6.0, 0.0, TAU, 16, Color.WHITE, 2.2, true)
		c.draw_line(rp + Vector2(-5, 5), rp + Vector2(5, -5), Color.WHITE, 2.2, true)
	if pt < 0.4:  # ready again: white ring burst
		var k: float = pt / 0.4
		c.draw_arc(o, rad + 4.0 + 16.0 * k, 0.0, TAU, 40, Color(1, 1, 1, 0.8 * (1.0 - k)), 5.0 * (1.0 - k) + 1.0, true)
	c.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _drone_icon(c: Control, o: Vector2, ink: Color) -> void:
	for d: Vector2 in [Vector2(-13, -9), Vector2(13, -9), Vector2(-13, 9), Vector2(13, 9)]:
		c.draw_line(o, o + d * 0.8, INK, 5.0, true)
		c.draw_line(o, o + d * 0.8, ink, 2.5, true)
		c.draw_circle(o + d, 6.5, INK)
		c.draw_circle(o + d, 5.0, Color(ink, 0.55))
	c.draw_rect(Rect2(o - Vector2(8, 6), Vector2(16, 12)), INK)
	c.draw_rect(Rect2(o - Vector2(6, 4), Vector2(12, 8)), ink)
	c.draw_circle(o + Vector2(-3, -1), 1.8, Color8(0xff, 0x3b, 0x30))
	c.draw_circle(o + Vector2(3, -1), 1.8, Color8(0x3a, 0x8b, 0xff))


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
	var fo: float = now - _focus_t
	if fo >= 0.0 and fo < _focus_dur + 0.25:  # t5 telegraph: radial focus lines closing in + warm vignette
		var k: float = clampf(fo / maxf(0.05, _focus_dur), 0.0, 1.0)
		var fade: float = 1.0 if fo < _focus_dur else 1.0 - (fo - _focus_dur) / 0.25
		_vignette(r, Color(1.0, 0.55, 0.1, 0.5 * fade))
		var cc: Vector2 = r.get_center() + Vector2(0, -r.size.y * 0.04)
		var far: float = r.size.length() * 0.6
		for i: int in 36:
			var h: float = fmod(float(i) * 0.618034, 1.0)
			var ang: float = TAU * float(i) / 36.0 + h * 0.12
			var inner_r: float = lerpf(far * 0.9, far * (0.32 + 0.18 * h), UiDraw.smooth(k))
			var dir := Vector2(cos(ang), sin(ang))
			var wdt: float = 0.012 + 0.018 * h
			_fx.draw_colored_polygon(PackedVector2Array([cc + dir.rotated(wdt) * far, cc + dir * inner_r, cc + dir.rotated(-wdt) * far]),
				Color(1, 1, 1, (0.3 + 0.35 * h) * fade))
	if skip_hint_visible():  # 탭: 건너뛰기 (bottom centre, over the home indicator gap)
		var pa: float = 0.55 + 0.35 * sin(now * 5.0)
		var sr2: Rect2 = safe_rect()
		var hp: Vector2 = Vector2(sr2.get_center().x, sr2.end.y - 64.0)
		var tw: float = UiDraw.text_w("탭: 건너뛰기", 22) + 36.0
		_fx.draw_style_box(UiDraw.box(Color(0.05, 0.06, 0.09, 0.55 * pa + 0.2), 18), Rect2(hp - Vector2(tw * 0.5, 20), Vector2(tw, 40)))
		UiDraw.text_c(_fx, hp, "탭: 건너뛰기", 22, Color(1, 1, 1, 0.6 + 0.4 * pa), 4, true, 0.0)
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
