class_name UiDraw
extends RefCounted
## Shared immediate-mode drawing for the in-game HUD, cards and banners (web look: ink outline, hard drop shadow,
## glossy face). Canvas units: the 540-wide canvas (1 pt of a 390-pt phone = 540 / 390 = 1.385 u).
## Icons are the frozen web's SVGs (res://screens/svg_art.gd, generated from ui.js) rasterised once at 3× and cached;
## loaded by path so the HUD still runs (with polygon fallbacks) if that generated file is absent.

const PT: float = 540.0 / 390.0
const INK := Color8(0x17, 0x20, 0x2b)
const FONT_DISPLAY: String = "res://ui/fonts/BlackHanSans-Regular.ttf"
const FONT_BODY: String = "res://ui/fonts/Jua-Regular.ttf"
const SVG_ART: String = "res://screens/svg_art.gd"

static var _fonts: Dictionary = {}
static var _icons: Dictionary = {}
static var _svg: Dictionary = {}


static func font(display: bool = true) -> Font:
	var path: String = FONT_DISPLAY if display else FONT_BODY
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


static func _svg_map() -> Dictionary:
	if _svg.is_empty() and ResourceLoader.exists(SVG_ART):
		var scr: Script = load(SVG_ART) as Script
		if scr != null:
			var m: Dictionary = scr.get_script_constant_map()
			if m.get("ICONS") is Dictionary:
				_svg = m["ICONS"]
	return _svg


## Web icon `name` rasterised for `px` canvas units (3× texels); null when the SVG table is missing.
static func icon(name: String, px: float) -> Texture2D:
	var texels: int = clampi(roundi(px * 3.0), 8, 1024)
	var key: String = "%s@%d" % [name, texels]
	if _icons.has(key):
		return _icons[key]
	var tex: Texture2D = null
	var svg: String = str(_svg_map().get(name, ""))
	if not svg.is_empty():
		var vb: PackedStringArray = svg.get_slice("viewBox=\"", 1).get_slice("\"", 0).split(" ")
		var vw: float = vb[2].to_float() if vb.size() == 4 else 24.0
		var img := Image.new()
		if img.load_svg_from_string(svg, float(texels) / maxf(1.0, vw)) == OK:
			img.generate_mipmaps()
			tex = ImageTexture.create_from_image(img)
	_icons[key] = tex
	return tex


## Draws icon `name` centred at `c` with width `w` (height from the aspect). False when unavailable.
static func draw_icon(ci: CanvasItem, name: String, c: Vector2, w: float, mod: Color = Color.WHITE) -> bool:
	var t: Texture2D = icon(name, w)
	if t == null:
		return false
	var h: float = w * float(t.get_height()) / maxf(1.0, float(t.get_width()))
	ci.draw_texture_rect(t, Rect2(c - Vector2(w, h) * 0.5, Vector2(w, h)), false, mod)
	return true


static func box(bg: Color, radius: float, border: float = 0.0, border_col: Color = INK) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(int(radius))
	sb.border_color = border_col
	sb.set_border_width_all(int(border))
	sb.anti_aliasing = true
	return sb


## Ink-outlined panel with a hard drop shadow (.ui-panel: 4 u ink border, 6 u shadow straight down).
static func panel(ci: CanvasItem, r: Rect2, bg: Color, radius: float = 16.0, border: float = 4.0, shadow: float = 6.0) -> void:
	if shadow > 0.0:
		ci.draw_style_box(box(Color(INK, 0.9 * bg.a), radius), Rect2(r.position + Vector2(0, shadow), r.size))
	ci.draw_style_box(box(bg, radius, border), r)


## Glossy pill / button face (.ui-btn): hi→mid gradient top half, lo rim, white gloss streak.
static func gloss(ci: CanvasItem, r: Rect2, cols: Array, radius: float = 18.0, pressed: bool = false) -> void:
	var sink: float = 4.0 if pressed else 0.0
	var rr := Rect2(r.position + Vector2(0, sink), r.size)
	ci.draw_style_box(box(INK, radius), Rect2(r.position + Vector2(0, 6), r.size))
	ci.draw_style_box(box(cols[2] as Color, radius, 4.0), rr)
	var face := Rect2(rr.position + Vector2(4, 4), rr.size - Vector2(8, 11))
	ci.draw_style_box(box(cols[1] as Color, maxf(2.0, radius - 4.0)), face)
	var top := Rect2(face.position, Vector2(face.size.x, face.size.y * 0.5))
	var sb := box(cols[0] as Color, maxf(2.0, radius - 4.0))
	sb.corner_radius_bottom_left = 2
	sb.corner_radius_bottom_right = 2
	ci.draw_style_box(sb, top)
	var streak := Rect2(face.position + Vector2(face.size.x * 0.12, 3), Vector2(face.size.x * 0.4, maxf(3.0, face.size.y * 0.13)))
	ci.draw_style_box(box(Color(1, 1, 1, 0.45), streak.size.y * 0.5), streak)


## Round glossy button (HUD controls): ink ring + drop, coloured face, top highlight. Returns the face centre.
static func round_button(ci: CanvasItem, ctr: Vector2, rad: float, cols: Array, pressed: bool = false) -> Vector2:
	var sink: float = 4.0 if pressed else 0.0
	ci.draw_circle(ctr + Vector2(0, 6), rad, Color(INK, 0.85))
	var c: Vector2 = ctr + Vector2(0, sink)
	ci.draw_circle(c, rad, INK)
	ci.draw_circle(c, rad - 4.0, cols[2] as Color)
	ci.draw_circle(c - Vector2(0, 2.5), rad - 7.0, (cols[1] as Color).darkened(0.18) if pressed else cols[1] as Color)
	# upper gloss lens
	var pts := PackedVector2Array()
	var rg: float = rad - 11.0
	for i: int in 25:
		var a: float = PI + PI * float(i) / 24.0
		pts.append(c + Vector2(cos(a) * rg, sin(a) * rg * 0.78 - rad * 0.08))
	ci.draw_colored_polygon(pts, Color(cols[0] as Color, 0.55))
	ci.draw_circle(c + Vector2(-rad * 0.36, -rad * 0.46), rad * 0.11, Color(1, 1, 1, 0.55))
	return c


## Text with an ink outline and a hard shadow (O4 preset), left-aligned at baseline `pos`.
static func text(ci: CanvasItem, pos: Vector2, s: String, size: int, col: Color, outline: int = 6, display: bool = true,
		shadow: float = 3.0) -> void:
	var f: Font = font(display)
	if shadow > 0.0:
		ci.draw_string_outline(f, pos + Vector2(0, shadow), s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, outline, Color(INK, col.a * 0.8))
	if outline > 0:
		ci.draw_string_outline(f, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, outline, Color(INK, col.a))
	ci.draw_string(f, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


## Same, centred horizontally on `cx`, vertically on `cy` (cap-height centred).
static func text_c(ci: CanvasItem, c: Vector2, s: String, size: int, col: Color, outline: int = 6, display: bool = true,
		shadow: float = 3.0) -> void:
	var f: Font = font(display)
	var w: float = f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	text(ci, Vector2(c.x - w * 0.5, c.y + (f.get_ascent(size) - f.get_descent(size)) * 0.5 - size * 0.06), s, size, col, outline, display, shadow)


static func text_w(s: String, size: int, display: bool = true) -> float:
	return font(display).get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x


## Five-point star polygon (outer r, inner 0.48 r), rotated `rot`.
static func star_points(c: Vector2, r: float, rot: float = 0.0) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i: int in 10:
		var a: float = -PI / 2.0 + rot + PI * float(i) / 5.0
		var rr: float = r if i % 2 == 0 else r * 0.48
		pts.append(c + Vector2(cos(a), sin(a)) * rr)
	return pts


## Gold (on) / slate (off) star with ink outline and gloss.
static func star(ci: CanvasItem, c: Vector2, r: float, on: bool, rot: float = 0.0) -> void:
	ci.draw_colored_polygon(star_points(c + Vector2(0, r * 0.12), r + 4.0, rot), INK)
	ci.draw_colored_polygon(star_points(c, r + 4.0, rot), INK)
	ci.draw_colored_polygon(star_points(c, r, rot), Color8(0xff, 0xc4, 0x1f) if on else Color8(0x3a, 0x44, 0x52))
	if on:
		ci.draw_colored_polygon(star_points(c - Vector2(0, r * 0.12), r * 0.62, rot), Color8(0xff, 0xe6, 0x80))
		ci.draw_circle(c + Vector2(-r * 0.22, -r * 0.3), r * 0.1, Color(1, 1, 1, 0.8))


## Ease helpers (UI timelines run on real time).
static func back_out(t: float, k: float = 1.70158) -> float:
	var u: float = clampf(t, 0.0, 1.0) - 1.0
	return 1.0 + (k + 1.0) * u * u * u + k * u * u


static func elastic_out(t: float) -> float:
	var x: float = clampf(t, 0.0, 1.0)
	if x <= 0.0 or x >= 1.0:
		return x
	return pow(2.0, -10.0 * x) * sin((x * 10.0 - 0.75) * TAU / 3.0) + 1.0


static func smooth(t: float) -> float:
	var x: float = clampf(t, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)


## "40,000원" (Black Han Sans / Jua have no ₩ glyph, and 원 reads naturally in Korean).
static func won(n: float) -> String:
	return ("-" if n < 0.0 else "") + group(absf(n)) + "원"


## "12,606"
static func group(n: float) -> String:
	var v: int = roundi(absf(n))
	var s: String = str(v)
	var out: String = ""
	while s.length() > 3:
		out = "," + s.right(3) + out
		s = s.left(s.length() - 3)
	return ("-" if n < 0.0 else "") + s + out


# ───────────────────────────── text with vector glyphs
## The bundled OFL fonts lack ◀ ▶ ↑ ↓ · ✔ ★ (Black Han Sans) — sim hints use them ("◀ 원흉 차로로"). rich() draws
## those as shapes on the same baseline so every platform renders them identically (no system-font fallback).
const GLYPHS: String = "◀▶↑↓·✔★"


static func _glyph_w(g: String, size: int) -> float:
	match g:
		"·":
			return size * 0.42
		"✔", "★":
			return size * 0.92
	return size * 0.78


static func _runs(s: String) -> Array[String]:
	var out: Array[String] = []
	var cur: String = ""
	for i: int in s.length():
		var ch: String = s[i]
		if GLYPHS.contains(ch):
			if not cur.is_empty():
				out.append(cur)
				cur = ""
			out.append(ch)
		else:
			cur += ch
	if not cur.is_empty():
		out.append(cur)
	return out


static func rich_w(s: String, size: int, display: bool = true) -> float:
	var w: float = 0.0
	for r: String in _runs(s):
		w += _glyph_w(r, size) if r.length() == 1 and GLYPHS.contains(r) else text_w(r, size, display)
	return w


static func _glyph_pts(g: String, o: Vector2, w: float, size: int) -> PackedVector2Array:
	var cy: float = o.y - size * 0.36
	var h: float = size * 0.62
	var cx: float = o.x + w * 0.5
	match g:
		"◀":
			return PackedVector2Array([Vector2(cx - h * 0.5, cy), Vector2(cx + h * 0.42, cy - h * 0.5), Vector2(cx + h * 0.42, cy + h * 0.5)])
		"▶":
			return PackedVector2Array([Vector2(cx + h * 0.5, cy), Vector2(cx - h * 0.42, cy - h * 0.5), Vector2(cx - h * 0.42, cy + h * 0.5)])
		"↓", "↑":
			var d: float = 1.0 if g == "↓" else -1.0
			var sw: float = h * 0.17
			return PackedVector2Array([Vector2(cx - sw, cy - d * h * 0.55), Vector2(cx + sw, cy - d * h * 0.55),
				Vector2(cx + sw, cy + d * h * 0.02), Vector2(cx + h * 0.42, cy + d * h * 0.02), Vector2(cx, cy + d * h * 0.55),
				Vector2(cx - h * 0.42, cy + d * h * 0.02), Vector2(cx - sw, cy + d * h * 0.02)])
		"★":
			return star_points(Vector2(cx, cy), h * 0.62)
	return PackedVector2Array()


static func _grow(pts: PackedVector2Array, by: float) -> PackedVector2Array:
	var c := Vector2.ZERO
	for p: Vector2 in pts:
		c += p
	c /= maxf(1.0, float(pts.size()))
	var out := PackedVector2Array()
	for p: Vector2 in pts:
		out.append(p + (p - c).normalized() * by)
	return out


static func _draw_glyph(ci: CanvasItem, g: String, o: Vector2, size: int, col: Color, outline: int, shadow: float) -> void:
	var w: float = _glyph_w(g, size)
	var ink := Color(INK, col.a)
	if g == "·":
		var c := Vector2(o.x + w * 0.5, o.y - size * 0.36)
		if shadow > 0.0:
			ci.draw_circle(c + Vector2(0, shadow), size * 0.09 + outline * 0.5, Color(INK, col.a * 0.8))
		ci.draw_circle(c, size * 0.09 + outline * 0.5, ink)
		ci.draw_circle(c, size * 0.09, col)
		return
	if g == "✔":
		var a := Vector2(o.x + w * 0.12, o.y - size * 0.38)
		var b := Vector2(o.x + w * 0.4, o.y - size * 0.12)
		var e := Vector2(o.x + w * 0.9, o.y - size * 0.72)
		var lw: float = size * 0.16
		for pass_i: int in 3:
			var off := Vector2(0, shadow) if pass_i == 0 else Vector2.ZERO
			var cc: Color = Color(INK, col.a * 0.8) if pass_i == 0 else (ink if pass_i == 1 else col)
			var ww: float = lw + (outline if pass_i < 2 else 0.0)
			if pass_i == 0 and shadow <= 0.0:
				continue
			ci.draw_polyline(PackedVector2Array([a + off, b + off, e + off]), cc, ww, true)
		return
	var pts: PackedVector2Array = _glyph_pts(g, o, w, size)
	if pts.is_empty():
		return
	if shadow > 0.0:
		var sp := PackedVector2Array()
		for p: Vector2 in _grow(pts, outline * 0.6):
			sp.append(p + Vector2(0, shadow))
		ci.draw_colored_polygon(sp, Color(INK, col.a * 0.8))
	if outline > 0:
		ci.draw_colored_polygon(_grow(pts, outline * 0.6), ink)
	ci.draw_colored_polygon(pts, col)


## text() that understands GLYPHS; left-aligned at baseline `pos`.
static func rich(ci: CanvasItem, pos: Vector2, s: String, size: int, col: Color, outline: int = 6, display: bool = true,
		shadow: float = 3.0) -> void:
	var x: float = pos.x
	for r: String in _runs(s):
		if r.length() == 1 and GLYPHS.contains(r):
			_draw_glyph(ci, r, Vector2(x, pos.y), size, col, outline, shadow)
			x += _glyph_w(r, size)
		else:
			text(ci, Vector2(x, pos.y), r, size, col, outline, display, shadow)
			x += text_w(r, size, display)


static func rich_c(ci: CanvasItem, c: Vector2, s: String, size: int, col: Color, outline: int = 6, display: bool = true,
		shadow: float = 3.0) -> void:
	var f: Font = font(display)
	var w: float = rich_w(s, size, display)
	rich(ci, Vector2(c.x - w * 0.5, c.y + (f.get_ascent(size) - f.get_descent(size)) * 0.5 - size * 0.06), s, size, col, outline, display, shadow)


## "1:07" from seconds.
static func clock(sec: float) -> String:
	var t: int = maxi(0, floori(sec))
	return "%d:%02d" % [t / 60, t % 60]
