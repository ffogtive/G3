class_name Banner
extends Control
## Phase banners (web ui.js banner() / .ui-banner): one big outlined line that slams in (2.3× → 1× back-out, −4° tilt),
## holds, and leaves (1× → 1.12×, fade). Kinds set colour + extras: boss (red), lock (yellow), phase (orange),
## kill / release (gold with a turning sunburst behind), warn (red), go (green). A sub line (villain's defeat line,
## counter) sits under it in the body font. Long text shrinks to fit 92 % of the width (no Korean mid-word wraps).
## Real time via advance(); a new banner replaces the current one.

const KIND: Dictionary = {
	"boss": [Color8(0xff, 0x5a, 0x4a), Color8(0xff, 0xd0, 0xc8)],
	"lock": [Color8(0xff, 0xd2, 0x3f), Color8(0xff, 0xf3, 0xb8)],
	"phase": [Color8(0xff, 0x9a, 0x2e), Color8(0xff, 0xe0, 0xb0)],
	"kill": [Color8(0xff, 0xd2, 0x3f), Color8(0xff, 0xf6, 0xc8)],
	"release": [Color8(0xff, 0xd2, 0x3f), Color8(0xff, 0xf6, 0xc8)],
	"warn": [Color8(0xff, 0x3b, 0x30), Color8(0xff, 0xc0, 0xb8)],
	"go": [Color8(0x3c, 0xe0, 0x8e), Color8(0xc8, 0xff, 0xdc)],
}
const IN_S: float = 0.24
const OUT_S: float = 0.26

var now: float = 0.0
## Vertical centre as a fraction of the control height.
var y_frac: float = 0.36
var _text: String = ""
var _sub: String = ""
var _kind: String = "phase"
var _born: float = -99.0
var _until: float = -99.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func show_banner(text: String, kind: String = "phase", dur: float = 1.5, sub: String = "") -> void:
	_text = text
	_sub = sub
	_kind = kind if KIND.has(kind) else "phase"
	_born = now
	_until = now + dur
	queue_redraw()


func current() -> String:
	return _text if now < _until + OUT_S else ""


func clear() -> void:
	_until = -99.0
	_text = ""


func advance(dt: float) -> void:
	now += dt
	if not _text.is_empty() or now < _until + OUT_S:
		queue_redraw()


func _draw() -> void:
	if _text.is_empty() or now > _until + OUT_S:
		return
	var t: float = now - _born
	var out_t: float = clampf((now - _until) / OUT_S, 0.0, 1.0)
	var sc: float = lerpf(2.3, 1.0, UiDraw.back_out(t / IN_S, 2.0))
	sc *= 1.0 + 0.12 * out_t
	var a: float = clampf(t / 0.08, 0.0, 1.0) * (1.0 - out_t)
	var c := Vector2(size.x * 0.5, size.y * y_frac)
	var cols: Array = KIND[_kind]
	if _kind == "kill" or _kind == "release":
		_rays(c, a, t)
	var fs: int = 76
	while fs > 34 and UiDraw.rich_w(_text, fs) > size.x * 0.92:
		fs -= 4
	var tilt: float = deg_to_rad(-4.0) * (1.0 - clampf(t / 0.5, 0.0, 1.0) * 0.5)
	draw_set_transform(c, tilt, Vector2(sc, sc))
	UiDraw.rich_c(self, Vector2.ZERO + Vector2(0, 6), _text, fs, Color(UiDraw.INK, a * 0.9), 14, true, 0.0)
	UiDraw.rich_c(self, Vector2.ZERO, _text, fs, Color(cols[0] as Color, a), 12, true, 0.0)
	# inner highlight: the same text, lighter, clipped visually by drawing slightly smaller on top
	UiDraw.rich_c(self, Vector2(0, -fs * 0.04), _text, fs, Color(cols[1] as Color, a * 0.35), 0, true, 0.0)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if not _sub.is_empty():
		var st: float = clampf((t - 0.18) / 0.2, 0.0, 1.0)
		var ss: int = 30
		while ss > 18 and UiDraw.rich_w(_sub, ss, false) > size.x * 0.9:
			ss -= 2
		UiDraw.rich_c(self, c + Vector2(0, fs * 0.72 + 8.0 + (1.0 - st) * 14.0), _sub, ss, Color(1, 1, 1, a * st), 7, false, 3.0)


## Turning sunburst (web .ui-rays) behind kill / release banners.
func _rays(c: Vector2, a: float, t: float) -> void:
	var n: int = 14
	var r: float = size.x * 0.75
	var rot: float = t * 0.6
	for i: int in n:
		var a0: float = rot + TAU * float(i) / float(n)
		var a1: float = a0 + TAU / float(n) * 0.45
		var pts := PackedVector2Array([c, c + Vector2(cos(a0), sin(a0)) * r, c + Vector2(cos(a1), sin(a1)) * r])
		draw_colored_polygon(pts, Color(1.0, 0.86, 0.3, 0.13 * a))
	draw_circle(c, size.x * 0.22, Color(1.0, 0.92, 0.55, 0.1 * a))
