class_name ScrKit
extends RefCounted
## Builders shared by every meta screen (web look: ink outlines, hard drop shadows, glossy pills, road-sign panels).
## Canvas units: the project canvas is 540 wide (stretch canvas_items/expand), i.e. 1 web px (390-pt phone) ≈ 1.385 u.
## Everything clickable goes through tap(): mouse_filter PASS (so ScrollContainer drag-scrolls over it), a press
## that moves < TAP_SLOP is a tap, press feedback = sink 4 u, every tap plays Haptics "uiLight" + Audio "ui".

const K: float = 540.0 / 390.0
const TAP_SLOP: float = 14.0
const INK := Lane1Pal.INK

static var _fonts: Dictionary = {}
static var _tex: Dictionary = {}
static var _ls: Dictionary = {}
## Tests / shots: count taps and silence feedback.
static var taps: int = 0
static var feedback_enabled: bool = true


## Drops the texture / LabelSettings / font caches (tests call it so nothing static outlives the run).
static func clear_caches() -> void:
	_tex.clear()
	_ls.clear()
	_fonts.clear()


# ───────────────────────────── fonts · labels
static func font(display: bool) -> Font:
	var path: String = Lane1Pal.FONT_DISPLAY if display else Lane1Pal.FONT_BODY
	if _fonts.has(path):
		return _fonts[path]
	var f: Font = null
	if ResourceLoader.exists(path):
		f = load(path) as Font
	if f == null and FileAccess.file_exists(path):
		var ff := FontFile.new()
		if ff.load_dynamic_font(path) == OK:
			f = ff
	if f == null:
		f = ThemeDB.fallback_font
	_fonts[path] = f
	return f


## LabelSettings cache. outline = ink outline width (u), shadow = ink drop (u, straight down).
static func lset(size: int, color: Color, display: bool = true, outline: int = 0, shadow: int = 0, outline_col: Color = INK) -> LabelSettings:
	var key: String = "%d|%s|%s|%d|%d|%s" % [size, color.to_html(), display, outline, shadow, outline_col.to_html()]
	if _ls.has(key):
		return _ls[key]
	var s := LabelSettings.new()
	s.font = font(display)
	s.font_size = size
	s.font_color = color
	s.outline_size = outline
	s.outline_color = outline_col
	if shadow > 0:
		s.shadow_color = outline_col
		s.shadow_offset = Vector2(0, shadow)
		s.shadow_size = maxi(1, outline)
	_ls[key] = s
	return s


static func lbl(text: String, size: int, color: Color = Color.WHITE, display: bool = true, outline: int = 0, shadow: int = 0) -> Label:
	var l := Label.new()
	l.text = text
	l.label_settings = lset(size, color, display, outline, shadow)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l


## Wrapped paragraph (Korean keep-all approximation: autowrap by word, so syllables of one word stay together).
static func para(text: String, size: int, color: Color, display: bool = false, align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_CENTER) -> Label:
	var l: Label = lbl(text, size, color, display)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.horizontal_alignment = align
	l.custom_minimum_size.x = 10
	return l


static func ellipsis(l: Label) -> Label:
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.clip_text = true
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.custom_minimum_size.x = 8
	return l


# ───────────────────────────── boxes
static func sb(bg: Color, radius: int = 16, border: int = 4, shadow: int = 0, border_col: Color = INK, pad: Vector4 = Vector4(12, 10, 12, 10)) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(radius)
	s.set_border_width_all(border)
	s.border_color = border_col
	if shadow > 0:
		s.shadow_color = INK
		s.shadow_size = 1
		s.shadow_offset = Vector2(0, shadow)
	s.content_margin_left = pad.x
	s.content_margin_top = pad.y
	s.content_margin_right = pad.z
	s.content_margin_bottom = pad.w
	s.anti_aliasing = true
	return s


static func panel(style: StyleBox) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override(&"panel", style)
	p.mouse_filter = Control.MOUSE_FILTER_PASS
	return p


static func vbox(sep: int = 8) -> VBoxContainer:
	var b := VBoxContainer.new()
	b.add_theme_constant_override(&"separation", sep)
	b.mouse_filter = Control.MOUSE_FILTER_PASS
	return b


static func hbox(sep: int = 8) -> HBoxContainer:
	var b := HBoxContainer.new()
	b.add_theme_constant_override(&"separation", sep)
	b.mouse_filter = Control.MOUSE_FILTER_PASS
	return b


static func margin(l: int, t: int, r: int, b: int) -> MarginContainer:
	var m := MarginContainer.new()
	m.add_theme_constant_override(&"margin_left", l)
	m.add_theme_constant_override(&"margin_top", t)
	m.add_theme_constant_override(&"margin_right", r)
	m.add_theme_constant_override(&"margin_bottom", b)
	m.mouse_filter = Control.MOUSE_FILTER_PASS
	return m


## Remove and free every child now (so a re-render never lays out old + new children in the same frame).
static func clear(n: Node) -> void:
	for c: Node in n.get_children():
		n.remove_child(c)
		c.queue_free()


static func spacer(h: float = 0.0, expand: bool = true) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if expand:
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return c


static func center(c: Control) -> CenterContainer:
	var cc := CenterContainer.new()
	cc.mouse_filter = Control.MOUSE_FILTER_PASS
	cc.add_child(c)
	return cc


## Full-rect dimmer that swallows input (modal backdrop).
static func dim(alpha: float = 0.55) -> ColorRect:
	var r := ColorRect.new()
	r.color = Color(0.03, 0.05, 0.08, alpha)
	r.set_anchors_preset(Control.PRESET_FULL_RECT)
	r.mouse_filter = Control.MOUSE_FILTER_STOP
	return r


# ───────────────────────────── glossy pill (.ui-btn): ink outline, hi/mid/lo body, gloss, 5 u hard shadow
class Pill extends PanelContainer:
	var cols: Array[Color] = Lane1Pal.BTN_YELLOW
	var radius: int = 999
	var border: int = 4
	var drop: int = 7
	var down: bool = false
	var disabled: bool = false

	func _init() -> void:
		var e := StyleBoxEmpty.new()
		e.content_margin_left = 22
		e.content_margin_right = 22
		e.content_margin_top = 10
		e.content_margin_bottom = 14
		add_theme_stylebox_override(&"panel", e)
		mouse_filter = Control.MOUSE_FILTER_PASS

	## Held: the body sinks onto its shadow and the content moves with it (web .ui-btn:active translateY).
	func set_down(on: bool) -> void:
		if on == down:
			return
		down = on
		var sb: StyleBox = get_theme_stylebox(&"panel")
		var d: float = float(drop - 2)
		sb.content_margin_top += d if on else -d
		sb.content_margin_bottom -= d if on else -d
		queue_redraw()

	func _draw() -> void:
		var r: float = minf(float(radius), size.y * 0.5)
		var sink: float = float(drop - 2) if down else 0.0
		var rect := Rect2(Vector2(0, sink), size)
		var c: Array[Color] = Lane1Pal.BTN_GREY if disabled else cols
		_rbox(Rect2(rect.position + Vector2(0, float(drop) - sink), rect.size), r, INK)       # hard drop shadow
		_rbox(rect, r, INK)                                                                    # outline
		var inner: Rect2 = rect.grow(-float(border))
		_rbox(inner, r - border, c[2])                                                         # lo (bottom band)
		_rbox(Rect2(inner.position, inner.size - Vector2(0, 6)), r - border, c[1])            # mid body
		var gl := Rect2(inner.position + Vector2(inner.size.x * 0.12, 2), Vector2(inner.size.x * 0.76, inner.size.y * 0.36))
		_rbox(gl, gl.size.y * 0.5, Color(c[0], 0.75))                                          # gloss
		var hi := Rect2(gl.position + Vector2(gl.size.x * 0.08, 1), Vector2(gl.size.x * 0.84, gl.size.y * 0.45))
		_rbox(hi, hi.size.y * 0.5, Color(1, 1, 1, 0.35))

	func _rbox(r: Rect2, rad: float, col: Color) -> void:
		var s := StyleBoxFlat.new()
		s.bg_color = col
		s.set_corner_radius_all(int(maxf(0.0, rad)))
		s.anti_aliasing = true
		draw_style_box(s, r)


## Glossy pill with a display-font label (+ optional sub line). cols = Lane1Pal.BTN_*.
static func pill(text: String, cols: Array[Color], size: int = 28, sub: String = "") -> Pill:
	var p := Pill.new()
	p.cols = cols
	var v: VBoxContainer = vbox(2)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	var l: Label = lbl(text, size, Color.WHITE, true, maxi(4, size / 5), 3)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.name = "Text"
	v.add_child(l)
	if not sub.is_empty():
		var s: Label = lbl(sub, maxi(14, size / 2), Color.WHITE, true, 4, 2)
		s.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		s.name = "Sub"
		ellipsis(s)
		v.add_child(s)
	p.add_child(v)
	return p


## Round glossy icon button (.ui-btn--round), e.g. the red ✕.
static func round_btn(icon_name: String, cols: Array[Color], d: int = 60) -> Pill:
	var p := Pill.new()
	p.cols = cols
	p.drop = 5
	var e := StyleBoxEmpty.new()
	p.add_theme_stylebox_override(&"panel", e)
	p.custom_minimum_size = Vector2(d, d)
	var ic: TextureRect = icon(icon_name, int(d * 0.55))
	ic.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	p.add_child(ic)
	return p


# ───────────────────────────── SVG art (generated SvgArt tables, rasterised once per size)
static func svg_tex(svg: String, px_w: int) -> Texture2D:
	var key: String = "%d:%d" % [svg.hash(), px_w]
	if _tex.has(key):
		return _tex[key]
	var vb_w: float = 24.0
	var at: int = svg.find("viewBox=\"")
	if at >= 0:
		var parts: PackedStringArray = svg.substr(at + 9, 60).split("\"")[0].split(" ")
		if parts.size() >= 4:
			vb_w = maxf(1.0, parts[2].to_float())
	var img := Image.new()
	var err: Error = img.load_svg_from_string(svg, float(px_w) / vb_w)
	var tex: Texture2D = null
	if err == OK and not img.is_empty():
		tex = ImageTexture.create_from_image(img)
	else:
		push_warning("ScrKit: svg raster failed (%s)" % error_string(err))
		var ph := Image.create(maxi(1, px_w), maxi(1, px_w), false, Image.FORMAT_RGBA8)
		tex = ImageTexture.create_from_image(ph)
	_tex[key] = tex
	return tex


static func tex_rect(tex: Texture2D, size: Vector2) -> TextureRect:
	var t := TextureRect.new()
	t.texture = tex
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	t.custom_minimum_size = size
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return t


## Native-only icons (no web equivalent): settings gear, grey (locked) route shield.
const EXTRA_ICONS: Dictionary = {
	"gear": "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\"><path d=\"M10.2 1.8h3.6l.6 3a7.6 7.6 0 0 1 2 .9l2.6-1.7 2.5 2.5-1.7 2.6a7.6 7.6 0 0 1 .9 2l3 .6v3.6l-3 .6a7.6 7.6 0 0 1-.9 2l1.7 2.6-2.5 2.5-2.6-1.7a7.6 7.6 0 0 1-2 .9l-.6 3h-3.6l-.6-3a7.6 7.6 0 0 1-2-.9l-2.6 1.7-2.5-2.5 1.7-2.6a7.6 7.6 0 0 1-.9-2l-3-.6v-3.6l3-.6a7.6 7.6 0 0 1 .9-2L4.7 6.5l2.5-2.5 2.6 1.7a7.6 7.6 0 0 1 2-.9z\" fill=\"#fff\" stroke=\"#17202b\" stroke-width=\"1.6\" stroke-linejoin=\"round\"/><circle cx=\"12\" cy=\"12\" r=\"3.4\" fill=\"#9aa3ae\" stroke=\"#17202b\" stroke-width=\"1.6\"/></svg>",
}


static func icon_svg(name: String) -> String:
	if EXTRA_ICONS.has(name):
		return str(EXTRA_ICONS[name])
	if name == "shield_grey":
		return str(SvgArt.ICONS["shield"]).replace("#1f4fa3", "#6d7682").replace("#e2231a", "#9aa3ae")
	return str(SvgArt.ICONS.get(name, SvgArt.ICONS["info"]))


## Icon from the web SVG table (ui.js SVG.*), drawn at 2× for crisp edges.
static func icon(name: String, size: int) -> TextureRect:
	var svg: String = icon_svg(name)
	return tex_rect(svg_tex(svg, size * 2), Vector2(size, size))


static func svg_rect(svg: String, size: Vector2, cover: bool = false) -> TextureRect:
	var t: TextureRect = tex_rect(svg_tex(svg, int(size.x * 2.0)), size)
	if cover:
		t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	return t


## Shop item art (ui.js itemArt, viewBox 120×84).
static func item_art(id: String, w: int) -> TextureRect:
	var svg: String = str(SvgArt.ITEMS.get(id, SvgArt.ITEMS.get("car_hatch", "")))
	return svg_rect(svg, Vector2(w, roundi(w * 84.0 / 120.0)))


## ui.js dashArt: procedural dash-cam frame (villain car colour, sky by seed) or the unknown silhouette.
static func dash_svg(color_hex: String, seed: int, silhouette: bool) -> String:
	if silhouette:
		return str(SvgArt.DASH["silhouette"])
	var s: String = str(SvgArt.DASH["photo"]).replace("#COLOR#", color_hex)
	var skies: Array = SvgArt.DASH["skies"]
	return s.replace("fill=\"%s\"" % str(skies[0]), "fill=\"%s\"" % str(skies[absi(seed) % 4]))


## ui.js villainColor(s)
static func villain_hex(st: Dictionary) -> String:
	var vs: Array = st.get("villains", [])
	if not vs.is_empty() and vs[0] is Dictionary and (vs[0] as Dictionary).get("color") != null:
		return "#%06x" % (int((vs[0] as Dictionary)["color"]) & 0xffffff)
	return ["#d9c9a3", "#2f6fd6", "#3a3f47", "#f4f4f2", "#7a8a4a"][absi(int(st.get("id", 1))) % 5]


## Route shield (ui.js shieldHTML): the SVG + route number on top. grey = locked tile look.
static func shield(route: Variant, w: int, grey: bool = false) -> Control:
	var h: int = roundi(w * 46.0 / 40.0)
	var root := Control.new()
	root.custom_minimum_size = Vector2(w, h)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var t: TextureRect = tex_rect(svg_tex(icon_svg("shield_grey" if grey else "shield"), w * 2), Vector2(w, h))
	t.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(t)
	var txt: String = str(int(route)) if (route is float or route is int) else str(route) if route != null else ""
	var fs: int = roundi(w * (0.5 if txt.length() <= 1 else 0.42 if txt.length() == 2 else 0.33))
	var n: Label = lbl(txt, fs, Color.WHITE, true, 3, 0)
	n.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	n.set_anchors_preset(Control.PRESET_FULL_RECT)
	n.offset_top = h * 0.2
	root.add_child(n)
	return root


static func stars(n: int, size: int, sep: int = 2, total: int = 3) -> HBoxContainer:
	var b: HBoxContainer = hbox(sep)
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for i: int in total:
		b.add_child(icon("star_on" if i < n else "star_off", size))
	return b


## Small rounded tag (.ui-casechip, .ui-kindb, spec chips).
static func chip(text: String, bg: Color, fg: Color = Color.WHITE, size: int = 16, border: int = 3, radius: int = 9) -> PanelContainer:
	var p: PanelContainer = panel(sb(bg, radius, border, 0, INK, Vector4(8, 2, 8, 2)))
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l: Label = lbl(text, size, fg, true)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	p.add_child(l)
	return p


## Horizontal progress bar (chapter tab / album count).
class Bar extends Control:
	var frac: float = 0.0
	var fill: Color = Lane1Pal.GREEN_HI
	var track: Color = Lane1Pal.LINE
	var edge: Color = INK

	func _draw() -> void:
		var r: float = size.y * 0.5
		var s := StyleBoxFlat.new()
		s.bg_color = track
		s.set_corner_radius_all(int(r))
		s.set_border_width_all(2)
		s.border_color = edge
		s.anti_aliasing = true
		draw_style_box(s, Rect2(Vector2.ZERO, size))
		if frac > 0.0:
			var f := StyleBoxFlat.new()
			f.bg_color = fill
			f.set_corner_radius_all(int(r))
			f.anti_aliasing = true
			draw_style_box(f, Rect2(Vector2(2, 2), Vector2(maxf(size.y - 4.0, (size.x - 4.0) * clampf(frac, 0.0, 1.0)), size.y - 4.0)))


static func bar(frac: float, fill: Color, h: int = 10) -> Bar:
	var b := Bar.new()
	b.frac = frac
	b.fill = fill
	b.custom_minimum_size = Vector2(20, h)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return b


# ───────────────────────────── input
## Tap = press + release within TAP_SLOP (drags scroll the parent ScrollContainer instead). Pills sink while held.
static func tap(c: Control, cb: Callable, sfx_name: String = "ui") -> void:
	# Mouse events only: touches reach the GUI as emulated mouse events (input_devices/pointing/emulate_mouse_from_touch),
	# so handling ScreenTouch too would fire twice on device.
	c.mouse_filter = Control.MOUSE_FILTER_PASS
	c.set_meta(&"tap_from", Vector2.INF)
	c.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseMotion:
			var from: Vector2 = c.get_meta(&"tap_from", Vector2.INF)
			if from != Vector2.INF and from.distance_to((ev as InputEventMouseMotion).global_position) > TAP_SLOP:
				c.set_meta(&"tap_from", Vector2.INF)
				if c is Pill:
					(c as Pill).set_down(false)
			return
		var mb := ev as InputEventMouseButton
		if mb == null or mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			c.set_meta(&"tap_from", mb.global_position)
			if c is Pill:
				(c as Pill).set_down(true)
			return
		var from2: Vector2 = c.get_meta(&"tap_from", Vector2.INF)
		c.set_meta(&"tap_from", Vector2.INF)
		if c is Pill:
			(c as Pill).set_down(false)
		if from2 != Vector2.INF and from2.distance_to(mb.global_position) <= TAP_SLOP:
			feedback(sfx_name)
			cb.call())


## Programmatic tap (tests): same path as a touch, without the event plumbing.
static func press(c: Control) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.global_position = c.get_global_rect().get_center()
	c.gui_input.emit(ev)
	var up := ev.duplicate() as InputEventMouseButton
	up.pressed = false
	c.gui_input.emit(up)


static func feedback(sfx_name: String = "ui", opts: Dictionary = {}) -> void:
	taps += 1
	if not feedback_enabled:
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	var h: Node = tree.root.get_node_or_null(^"Haptics")
	if h != null and h.has_method(&"haptic"):
		h.call(&"haptic", "uiLight")
	sfx(sfx_name, opts)


static func sfx(name: String, opts: Dictionary = {}) -> void:
	if name.is_empty() or not feedback_enabled:
		return
	var tree := Engine.get_main_loop() as SceneTree
	var a: Node = tree.root.get_node_or_null(^"Audio") if tree != null else null
	if a != null and a.has_method(&"sfx"):
		a.call(&"sfx", StringName(name), opts)


# ───────────────────────────── motion (Tween; KF.bump / bigBump / shake)
static func bump(c: Control, amount: float = 1.15, ms: float = 220.0) -> void:
	if not c.is_inside_tree():
		return
	c.pivot_offset = c.size * 0.5
	var tw: Tween = c.create_tween()
	tw.tween_property(c, "scale", Vector2.ONE * amount, ms * 0.0004)
	tw.tween_property(c, "scale", Vector2.ONE, ms * 0.0006)


static func shake(c: Control, ms: float = 320.0) -> void:
	if not c.is_inside_tree():
		return
	var x0: float = c.position.x
	var tw: Tween = c.create_tween()
	for dx: float in [-7.0, 7.0, -4.0, 0.0]:
		tw.tween_property(c, "position:x", x0 + dx, ms * 0.00025)


# ───────────────────────────── numbers (rewards.js won / ui.js kor / fmt)
static func fmt(n: float) -> String:
	var v: int = roundi(n)
	var neg: bool = v < 0
	var s: String = str(absi(v))
	var out: String = ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if neg else "") + s + out


static func won(n: float) -> String:
	return "₩" + fmt(maxf(0.0, n))


static func kor(n: float) -> String:
	var v: int = maxi(0, roundi(n))
	var d1 := func(x: float) -> String:
		var s: String = "%.1f" % (roundf(x * 10.0) / 10.0)
		return s.substr(0, s.length() - 2) if s.ends_with(".0") else s
	if v < 1000:
		return str(v)
	if v < 9950:
		return d1.call(v / 1000.0) + "천"
	if v < 999500:
		return d1.call(v / 1e4) + "만"
	if v < 100000000:
		return fmt(roundf(v / 1e4)) + "만"
	return d1.call(v / 1e8) + "억"


static func big_won(n: float) -> String:
	return kor(n) + "원" if n >= 1e6 else won(n)


# ───────────────────────────── stage helpers (ui.js stageKind / stageTitle / caseKind)
const KIND_OF: Dictionary = {"최종보스": "final", "보스": "boss", "엘리트": "elite", "보너스": "bonus"}
const KIND_LABEL: Dictionary = {"final": "최종보스", "boss": "보스", "elite": "엘리트", "bonus": "보너스"}
const CASE_OF: Dictionary = {"고지서": "fine", "형사": "crime", "표창": "rescue", "계도": "warn"}
const CASE_CHIP: Dictionary = {"crime": "형사", "rescue": "구조", "warn": "계도"}


static func stage_kind(st: Dictionary) -> String:
	var t: String = str(st.get("title", "")).strip_edges()
	if t.begins_with("["):
		var close: int = t.find("]")
		if close > 0 and KIND_OF.has(t.substr(1, close - 1)):
			return KIND_OF[t.substr(1, close - 1)]
	if bool(st.get("elite", false)):
		return "elite"
	if bool(st.get("boss", false)):
		return "boss"
	if t.contains("최종보스"):
		return "final"
	return ""


static func stage_title(st: Dictionary) -> String:
	var t: String = str(st.get("title", "")).strip_edges()
	if t.begins_with("["):
		var close: int = t.find("]")
		if close > 0 and KIND_OF.has(t.substr(1, close - 1)):
			t = t.substr(close + 1)
	return t.replace("(최종보스)", "").strip_edges()


static func case_kind(card: Variant) -> String:
	return str(CASE_OF.get(str(card if card != null else "").strip_edges(), "fine"))


static func kind_badge(kind: String, size: int = 14) -> Control:
	if kind.is_empty():
		return null
	return chip(str(KIND_LABEL[kind]), Color(str(Lane1Pal.KIND_COLOR.get(kind, "#ff3b30"))), Color.WHITE, size, 2, 6)


## 'OO 1호 & OO 2호' → 'OO 2대' (rewards.js villainNames)
static func villain_names(st: Dictionary) -> String:
	var names: PackedStringArray = []
	for v: Variant in st.get("villains", []):
		if v is Dictionary:
			names.append(str((v as Dictionary).get("name", "")))
	if names.size() > 1:
		var all_no: bool = true
		for n: String in names:
			if not (n.ends_with(" 1호") or n.ends_with(" 2호") or n.ends_with(" 3호")):
				all_no = false
		if all_no:
			return "%s %d대" % [names[0].substr(0, names[0].length() - 3), names.size()]
	return " & ".join(names)


static func accent(meta: Dictionary) -> Color:
	var t: String = str(meta.get("theme", "")).to_lower()
	for k: String in Lane1Pal.THEME_ACCENT:
		if t.contains(k):
			return Color(str(Lane1Pal.THEME_ACCENT[k]))
	return Lane1Pal.GREEN_HI


# ───────────────────────────── safe area (same conversion as ui/hud.gd apply_safe_area)
static func safe_insets(vp: Viewport, debug_pt: Vector2 = Vector2.ZERO) -> Vector4:
	var vis: Vector2 = vp.get_visible_rect().size
	var ins := Vector4.ZERO
	if OS.has_feature("mobile"):
		var win := Vector2(DisplayServer.window_get_size())
		if win.x > 0.0 and win.y > 0.0:
			var sa := Rect2(DisplayServer.get_display_safe_area())
			var k: Vector2 = vis / win
			ins = Vector4(sa.position.x * k.x, sa.position.y * k.y, (win.x - sa.end.x) * k.x, (win.y - sa.end.y) * k.y)
	elif debug_pt != Vector2.ZERO:
		var u: float = vis.x / 390.0
		ins = Vector4(0.0, debug_pt.x * u, 0.0, debug_pt.y * u)
	return Vector4(maxf(0.0, ins.x), maxf(0.0, ins.y), maxf(0.0, ins.z), maxf(0.0, ins.w))
