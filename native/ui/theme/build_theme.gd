extends SceneTree
## Builds res://ui/theme/lane1_theme.tres from Lane1Pal (deterministic, re-run after palette changes):
##   godot47 --headless --path native -s res://ui/theme/build_theme.gd
## The theme covers the defaults (Jua body font, ink-outlined white text, scroll bars, plain Buttons/Panels).
## The chunky glossy pills, signs and cards are drawn by screens/kit.gd on top of these defaults.

const OUT: String = "res://ui/theme/lane1_theme.tres"


static func make() -> Theme:
	var t := Theme.new()
	var fb: Font = load(Lane1Pal.FONT_BODY) as Font
	var fd: Font = load(Lane1Pal.FONT_DISPLAY) as Font
	t.default_font = fb
	t.default_font_size = 22
	t.set_font(&"font", &"Label", fb)
	t.set_color(&"font_color", &"Label", Lane1Pal.WHITE)
	t.set_color(&"font_outline_color", &"Label", Lane1Pal.INK)
	t.set_font(&"font", &"Button", fd)
	t.set_font_size(&"font_size", &"Button", 26)
	for st: StringName in [&"font_color", &"font_hover_color", &"font_pressed_color", &"font_focus_color"]:
		t.set_color(st, &"Button", Lane1Pal.WHITE)
	t.set_color(&"font_outline_color", &"Button", Lane1Pal.INK)
	t.set_constant(&"outline_size", &"Button", 6)
	var normal: StyleBoxFlat = _box(Lane1Pal.BTN_YELLOW[1], 40, 4, 6)
	t.set_stylebox(&"normal", &"Button", normal)
	t.set_stylebox(&"hover", &"Button", normal)
	var pressed: StyleBoxFlat = _box(Lane1Pal.BTN_YELLOW[2], 40, 4, 2)
	t.set_stylebox(&"pressed", &"Button", pressed)
	t.set_stylebox(&"focus", &"Button", StyleBoxEmpty.new())
	t.set_stylebox(&"panel", &"PanelContainer", _box(Lane1Pal.PANEL, 18, 4, 7))
	t.set_stylebox(&"panel", &"Panel", _box(Lane1Pal.PANEL, 18, 4, 7))
	# thin scroll bars (touch scrolling does the work; the bar is only a position hint)
	var grab := StyleBoxFlat.new()
	grab.bg_color = Color(1, 1, 1, 0.35)
	grab.set_corner_radius_all(4)
	grab.content_margin_left = 3
	grab.content_margin_right = 3
	for bar: StringName in [&"VScrollBar", &"HScrollBar"]:
		t.set_stylebox(&"scroll", bar, StyleBoxEmpty.new())
		t.set_stylebox(&"grabber", bar, grab)
		t.set_stylebox(&"grabber_highlight", bar, grab)
		t.set_stylebox(&"grabber_pressed", bar, grab)
	t.set_stylebox(&"panel", &"ScrollContainer", StyleBoxEmpty.new())
	return t


static func _box(bg: Color, radius: int, border: int, shadow: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(radius)
	s.set_border_width_all(border)
	s.border_color = Lane1Pal.INK
	s.shadow_color = Lane1Pal.INK
	s.shadow_size = 1 if shadow > 0 else 0
	s.shadow_offset = Vector2(0, shadow)
	s.content_margin_left = 18
	s.content_margin_right = 18
	s.content_margin_top = 10
	s.content_margin_bottom = 12
	return s


func _initialize() -> void:
	var err: Error = ResourceSaver.save(make(), OUT)
	print("build_theme: %s -> %s" % [OUT, error_string(err)])
	quit(0 if err == OK else 1)
