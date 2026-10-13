class_name Hud
extends CanvasLayer
## M1a HUD (NATIVE_PORT 3-8 / M1d N1), portrait 540-wide canvas_items layout anchored to the edges:
##  - N1 progress bar and the "원흉까지 N m" distance come from ONE value pair: progress_values(player_s,
##    villain_s_live, start_s) → (fraction, metres); the bar never disagrees with the number.
##  - speed (km/h), HP bumper 5 segments, rage 5 segments (static values in M1a), ◀ ▶ lane buttons, 경적 horn button.
## Buttons are drawn here but input is read by LaneInput from the rects registered via bind_input() (multi-touch).
## Font: Black Han Sans (OFL, res://ui/fonts/OFL.txt).

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
var root: Control
var _bar: Control
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
	# ── top: progress (N1)
	_bar = _custom(_draw_bar)
	_bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_bar.offset_left = 12
	_bar.offset_right = -12
	_bar.offset_top = 10
	_bar.offset_bottom = 46
	var pill: Control = _custom(func(c: Control) -> void: _panel(c, Rect2(Vector2.ZERO, c.size), 17))
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
	root.add_child(c)
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
	root.add_child(l)
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


func _process(_delta: float) -> void:
	var pv: Vector2 = progress_values(player_s, villain_s, start_s)
	_dist.text = "원흉까지 %d m" % roundi(pv.y)
	_speed.text = str(roundi(speed_ms * 3.6))
	_bar.queue_redraw()
	_hp_row.queue_redraw()
	_rage_row.queue_redraw()
	_btn_horn.queue_redraw()
	_gauge.queue_redraw()
	if _input != null and root.size != _zones_size:
		_zones_size = root.size
		_input.set_zone("left", _btn_left.get_global_rect())
		_input.set_zone("right", _btn_right.get_global_rect())
		_input.set_zone("horn", _btn_horn.get_global_rect())


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
	var pv: Vector2 = progress_values(player_s, villain_s, start_s)
	var track := Rect2(r.position + Vector2(22, 12), Vector2(r.size.x - 60, r.size.y - 24))
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color8(0xb8, 0x2a, 0x22)
	sb.set_corner_radius_all(6)
	c.draw_style_box(sb, track)
	var fill := track
	fill.size.x = maxf(12.0, track.size.x * pv.x)
	var sf := StyleBoxFlat.new()
	sf.bg_color = Color8(0xff, 0xc4, 0x2e)
	sf.set_corner_radius_all(6)
	c.draw_style_box(sf, fill)
	# player marker (yellow car) at the same fraction
	var px: float = track.position.x + track.size.x * pv.x
	c.draw_rect(Rect2(Vector2(px - 9, track.position.y - 5), Vector2(18, track.size.y + 10)), Color8(0x1c, 0x1c, 0x1c))
	c.draw_rect(Rect2(Vector2(px - 7, track.position.y - 3), Vector2(14, track.size.y + 6)), Color8(0xff, 0xcc, 0x28))
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
	c.draw_circle(ctr, rad, C_PANEL)
	c.draw_arc(ctr, rad - 4, PI * 0.75, PI * 2.25, 32, C_OFF, 5)
	var k: float = clampf(speed_ms * 3.6 / 120.0, 0.0, 1.0)
	c.draw_arc(ctr, rad - 4, PI * 0.75, PI * 0.75 + PI * 1.5 * maxf(0.02, k), 32, C_HP.lerp(Color8(0xff, 0x4a, 0x2a), k), 5)


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
