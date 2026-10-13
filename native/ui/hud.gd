class_name Hud
extends CanvasLayer
## M1a HUD (NATIVE_PORT 3-8 / M1d N1), portrait 540-wide canvas_items layout anchored to the edges:
##  - N1 progress bar and the "원흉까지 N m" distance come from ONE value pair: progress_values(player_s,
##    villain_s_live, start_s) → (fraction, metres); the bar never disagrees with the number.
##  - speed (km/h), HP bumper 5 segments, rage 5 segments (static values in M1a), ◀ ▶ lane buttons, 경적 horn button.
## Buttons are drawn here but input is read by LaneInput from the rects registered via bind_input() (multi-touch).
## Font: Black Han Sans (OFL, res://ui/fonts/OFL.txt).
## Safe area (NATIVE_PORT 3-8): every widget lives under `safe`, whose offsets are the notch / Dynamic Island /
## home-indicator insets from DisplayServer.get_display_safe_area() (mobile) converted to canvas units, so nothing
## sits under the island or in the home-indicator band. Desktop / shots can fake insets with debug_safe_pt
## (points of a 390-pt-wide phone; `--safe-pt=59,34`). root (full screen) still hosts the 3D-anchored bubbles.

const FONT_PATH: String = "res://ui/fonts/BlackHanSans-Regular.ttf"
const C_PANEL := Color(0.07, 0.08, 0.11, 0.78)
const C_EDGE := Color(1, 1, 1, 0.16)
const C_HP := Color8(0x3d, 0xd6, 0x5a)
const C_RAGE := Color8(0xff, 0x7a, 0x1a)
const C_OFF := Color(0.22, 0.24, 0.28, 0.9)

var font: Font
var player_s: float = 0.0
var villain_s: float = 200.0
var start_s: float = 0.0
var speed_ms: float = 0.0
var hp: int = 5
var rage: int = 0
var horn_down: bool = false
## N1 values last pushed by set_state(): (bar fraction 0..1, metres to the villain). The bar fill, the player marker
## and the "원흉까지 N m" label all read this one Vector2 (tests/test_hud_progress.gd checks it every tick).
var shown := Vector2.ZERO
var root: Control
## Full-screen minus the safe-area insets; parent of every HUD widget.
var safe: Control
## (top, bottom) insets in points of a 390-pt-wide phone, applied when not on a mobile OS (tests / T2 shots).
var debug_safe_pt := Vector2.ZERO
## Applied insets in canvas units (left, top, right, bottom).
var insets := Vector4.ZERO
var paused: bool = false
var _bar: Control
var _pill: Control
var _btn_pause: Control
var _btn_alpha: Dictionary = {}   # Control → current alpha (idle-ghosted buttons)
var _dist: Label
var _speed: Label
var _hp_row: Control
var _rage_row: Control
var _btn_left: Control
var _btn_right: Control
var _btn_horn: Control
var _gauge: Control
var _input: LaneInput
var _zones_size := Vector2.ZERO


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
	var pill: Control = _custom(_draw_pill)
	_pill = pill
	pill.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	pill.offset_top = 52
	pill.offset_bottom = 88
	pill.offset_left = -110
	pill.offset_right = 110
	_dist = _label("원흉까지 200 m", 22, Color.WHITE, 4)
	_dist.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_dist.offset_top = 52
	_dist.offset_bottom = 88
	_dist.offset_left = -110
	_dist.offset_right = 110
	_dist.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_dist.visible = false  # the pill draws the same text with '200' emphasised; the Label keeps the N1 string for tests
	# ── bottom centre: bumper HP + rage
	_hp_row = _custom(_draw_hp)
	_anchor_bottom_center(_hp_row, 150, 186, 150)
	_rage_row = _custom(_draw_rage)
	_anchor_bottom_center(_rage_row, 150, 142, 106)
	# ── bottom left: speed + lane buttons, bottom right: horn
	var gauge: Control = _custom(_draw_gauge)
	_gauge = gauge
	gauge.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	gauge.offset_left = 20
	gauge.offset_right = 104
	gauge.offset_top = -196
	gauge.offset_bottom = -112
	_speed = _label("0", 32, Color.WHITE, 5)
	_speed.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_speed.offset_left = 20
	_speed.offset_right = 104
	_speed.offset_top = -184
	_speed.offset_bottom = -146
	_speed.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var unit: Label = _label("km/h", 14, Color(1, 1, 1, 0.8), 3)
	unit.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	unit.offset_left = 20
	unit.offset_right = 104
	unit.offset_top = -148
	unit.offset_bottom = -128
	unit.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_btn_left = _custom(_draw_left)
	_corner(_btn_left, true, 14, 84)
	_btn_right = _custom(_draw_right)
	_corner(_btn_right, true, 104, 84)
	_btn_horn = _custom(_draw_horn)
	_corner(_btn_horn, false, 16, 112)
	_btn_pause = _custom(_draw_pause)
	_btn_pause.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_btn_pause.offset_left = -60
	_btn_pause.offset_right = -14
	_btn_pause.offset_top = 52
	_btn_pause.offset_bottom = 98
	for b: Control in [_btn_left, _btn_right, _btn_horn]:
		_btn_alpha[b] = IDLE_ALPHA
		b.modulate.a = IDLE_ALPHA
	get_viewport().size_changed.connect(apply_safe_area)
	apply_safe_area()


const IDLE_ALPHA: float = 0.45


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


## Screen rects N5 icons must not cover.
func reserved_rects() -> Array[Rect2]:
	var out: Array[Rect2] = []
	if not visible:
		return out
	for c: Control in [_bar, _pill, _hp_row, _rage_row, _gauge, _btn_left, _btn_right, _btn_horn, _btn_pause]:
		out.append(c.get_global_rect().grow(4.0))
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


func _anchor_bottom_center(c: Control, half_w: float, top_from_bottom: float, bottom_from_bottom: float) -> void:
	c.anchor_left = 0.5
	c.anchor_right = 0.5
	c.anchor_top = 1.0
	c.anchor_bottom = 1.0
	c.offset_left = -half_w * 0.5 - 30
	c.offset_right = half_w * 0.5 + 30
	c.offset_top = -top_from_bottom
	c.offset_bottom = -bottom_from_bottom


func _corner(c: Control, left: bool, inset: float, size: float) -> void:
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
	c.offset_top = -16 - size
	c.offset_bottom = -16


func bind_input(input: LaneInput) -> void:
	_input = input


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


func _process(delta: float) -> void:
	_dist.text = distance_text(shown.y)
	_speed.text = str(roundi(speed_ms * 3.6))
	_bar.queue_redraw()
	_pill.queue_redraw()
	_btn_pause.queue_redraw()
	if _input != null:
		_ghost(_btn_left, _input.is_zone_down("left"), delta)
		_ghost(_btn_right, _input.is_zone_down("right"), delta)
	_ghost(_btn_horn, horn_down, delta)
	_hp_row.queue_redraw()
	_rage_row.queue_redraw()
	_btn_horn.queue_redraw()
	_gauge.queue_redraw()
	if _input != null and safe.size != _zones_size:
		_zones_size = safe.size
		_input.set_zone("left", _btn_left.get_global_rect())
		_input.set_zone("right", _btn_right.get_global_rect())
		_input.set_zone("horn", _btn_horn.get_global_rect())
		_input.set_zone("pause", _btn_pause.get_global_rect().grow(6.0))


## Idle buttons are ghosted (0.45) so the cars behind the player stay visible; 1.0 while pressed (≈0.08 s fade).
func _ghost(b: Control, down: bool, delta: float) -> void:
	var a: float = move_toward(float(_btn_alpha.get(b, IDLE_ALPHA)), 1.0 if down else IDLE_ALPHA,
		(1.0 - IDLE_ALPHA) * delta / 0.08)
	_btn_alpha[b] = a
	b.modulate.a = a


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
	var tl := track.position
	c.draw_polygon(PackedVector2Array([tl, tl + Vector2(fw, 0), tl + Vector2(fw, track.size.y), tl + Vector2(0, track.size.y)]),
		PackedColorArray([c0, c1, c1, c0]))
	# player marker: top-view hero car (yellow body, 2 black stripes) at the same fraction
	var px: float = track.position.x + track.size.x * pv.x
	var car := Rect2(Vector2(px - 13, track.get_center().y - 7), Vector2(26, 14))
	c.draw_rect(car.grow(2.0), Color8(0x1c, 0x1c, 0x1c))
	c.draw_rect(car, Color8(0xff, 0xcc, 0x28))
	c.draw_rect(Rect2(car.position + Vector2(8, 0), Vector2(3, 14)), Color8(0x1c, 0x1c, 0x1c))
	c.draw_rect(Rect2(car.position + Vector2(15, 0), Vector2(3, 14)), Color8(0x1c, 0x1c, 0x1c))
	c.draw_rect(Rect2(car.position + Vector2(20, 2), Vector2(4, 10)), Color8(0x25, 0x3a, 0x5c))  # windscreen (front)
	# villain at the end of the bar (the bar's 100 % IS the villain's live position)
	var vc := Vector2(r.end.x - 20, r.get_center().y)
	c.draw_circle(vc, 14, Color8(0x1c, 0x1c, 0x1c))
	c.draw_circle(vc, 11.5, Color8(0xe8, 0x24, 0x2a))
	c.draw_line(vc + Vector2(-6, -4), vc + Vector2(-2, -2), Color.WHITE, 2.5)
	c.draw_line(vc + Vector2(6, -4), vc + Vector2(2, -2), Color.WHITE, 2.5)
	c.draw_line(vc + Vector2(-5, 5), vc + Vector2(5, 5), Color.WHITE, 2.5)


func _segments(c: Control, title: String, n_on: int, col: Color) -> void:
	var r := Rect2(Vector2.ZERO, c.size)
	_panel(c, r, 16)
	c.draw_string(font, Vector2(14, r.size.y * 0.5 + 8), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 19, Color.WHITE)
	var x0: float = 62.0
	var w: float = (r.size.x - x0 - 14.0) / 5.0
	for i: int in 5:
		var seg := Rect2(Vector2(x0 + w * float(i) + 2, 9), Vector2(w - 4, r.size.y - 18))
		var sb := StyleBoxFlat.new()
		sb.bg_color = col if i < n_on else C_OFF
		sb.set_corner_radius_all(5)
		c.draw_style_box(sb, seg)


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
	_segments(c, "범퍼", hp, C_HP)


func _draw_rage(c: Control) -> void:
	_segments(c, "분노", rage, C_RAGE)


func _round_button(c: Control, col: Color, pressed: bool) -> Vector2:
	var ctr: Vector2 = c.size * 0.5
	var rad: float = minf(c.size.x, c.size.y) * 0.5
	c.draw_circle(ctr + Vector2(0, 4), rad, Color(0, 0, 0, 0.35))
	c.draw_circle(ctr, rad, Color(1, 1, 1, 0.92))
	c.draw_circle(ctr, rad - 5, col.darkened(0.25) if pressed else col)
	c.draw_circle(ctr - Vector2(0, rad * 0.35), rad * 0.45, Color(1, 1, 1, 0.12))
	return ctr


func _draw_left(c: Control) -> void:
	var o: Vector2 = _round_button(c, Color8(0x2a, 0x7c, 0xe8), false)
	c.draw_colored_polygon(PackedVector2Array([o + Vector2(-14, 0), o + Vector2(10, -16), o + Vector2(10, 16)]), Color.WHITE)


func _draw_right(c: Control) -> void:
	var o: Vector2 = _round_button(c, Color8(0x2a, 0x7c, 0xe8), false)
	c.draw_colored_polygon(PackedVector2Array([o + Vector2(14, 0), o + Vector2(-10, -16), o + Vector2(-10, 16)]), Color.WHITE)


func _draw_horn(c: Control) -> void:
	var o: Vector2 = _round_button(c, Color8(0xe8, 0x24, 0x2a), horn_down)
	c.draw_colored_polygon(PackedVector2Array([o + Vector2(-20, -24), o + Vector2(-8, -24), o + Vector2(6, -34),
		o + Vector2(6, -6), o + Vector2(-8, -16), o + Vector2(-20, -16)]), Color.WHITE)
	c.draw_arc(o + Vector2(8, -20), 9, -0.9, 0.9, 10, Color.WHITE, 3)
	c.draw_arc(o + Vector2(8, -20), 16, -0.9, 0.9, 12, Color.WHITE, 3)
	c.draw_string(font, o + Vector2(-26, 26), "경적", HORIZONTAL_ALIGNMENT_CENTER, 52, 24, Color.WHITE)
