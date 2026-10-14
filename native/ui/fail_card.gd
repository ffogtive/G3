class_name FailCard
extends Control
## Fail card (web ui.js showFail / .ui-fail): "참교육 실패" ribbon, the tow-truck art with a "견인!" stamp slamming
## in, 사유 (the last damage reason), the villain chip and "마지막 한 방 −N", and — P0#6 honest — what the tow costs
## ("견인 N회 · 포상금 ×0.8 · ★2 실패"). Buttons: 발견 지점부터 다시 (retry) · 메뉴 → choice(&"retry" | &"menu"),
## armed after 0.45 s so the tap that was steering at the moment of the crash cannot skip it (web FS.armT).

signal choice(choice: StringName)

const INK := UiDraw.INK
const W: float = 460.0
const H: float = 720.0
const T_ARM: float = 0.45
const BTN_YELLOW: Array = [Color8(0xff, 0xe6, 0x80), Color8(0xff, 0xcf, 0x33), Color8(0xf0, 0x9a, 0x00)]
const BTN_GREY: Array = [Color8(0xcf, 0xd5, 0xdc), Color8(0x9a, 0xa3, 0xae), Color8(0x6d, 0x76, 0x82)]
const RED := Color8(0xe8, 0x24, 0x2a)

var data: Dictionary = {}
var t: float = 0.0
var _open: bool = false
var _xf := Transform2D.IDENTITY
var _btns: Dictionary = {}


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	for n: String in ["retry", "menu"]:
		var b := Button.new()
		b.flat = true
		b.focus_mode = Control.FOCUS_NONE
		var empty := StyleBoxEmpty.new()
		for st: String in ["normal", "hover", "pressed", "disabled", "focus"]:
			b.add_theme_stylebox_override(st, empty)
		b.pressed.connect(_on_btn.bind(n))
		b.button_down.connect(queue_redraw)
		b.button_up.connect(queue_redraw)
		add_child(b)
		_btns[n] = b


func open(d: Dictionary) -> void:
	data = d
	t = 0.0
	_open = true
	visible = true
	_layout()
	queue_redraw()


func close() -> void:
	_open = false
	visible = false


func is_open() -> bool:
	return _open


func advance(dt: float) -> void:
	if _open:
		seek(t + dt)


func seek(time_s: float) -> void:
	t = time_s
	_layout()
	queue_redraw()


func _on_btn(n: String) -> void:
	if t < T_ARM:
		return
	var au: Node = get_node_or_null(^"/root/Audio")
	if au != null and au.has_method(&"sfx"):
		au.call(&"sfx", &"uiConfirm" if n == "retry" else &"ui", {})
	choice.emit(StringName(n))


func _layout() -> void:
	var vis: Vector2 = size if size.x > 0.0 else get_viewport_rect().size
	var area := Rect2(Vector2.ZERO, vis)
	var hud: Node = get_parent()
	while hud != null and not (hud is Hud):
		hud = hud.get_parent()
	if hud is Hud:
		area = (hud as Hud).safe_rect()
	var sc: float = minf((area.size.x - 40.0) / W, (area.size.y - 40.0) / H)
	var k: float = UiDraw.back_out(t / 0.3, 1.6)
	var s2: float = sc * lerpf(0.7, 1.0, k)
	var origin := Vector2(area.get_center().x - W * s2 * 0.5, area.get_center().y - H * s2 * 0.5)
	_xf = Transform2D(0.0, Vector2(s2, s2), 0.0, origin)
	var rects: Dictionary = _btn_rects()
	for n: String in _btns:
		var b: Button = _btns[n]
		var r: Rect2 = rects[n]
		b.position = _xf * r.position
		b.size = r.size * s2
		b.disabled = t < T_ARM


func _btn_rects() -> Dictionary:
	return {"retry": Rect2(24, H - 182, W - 48, 84), "menu": Rect2(W * 0.5 - 90, H - 86, 180, 62)}


func _draw() -> void:
	if not _open:
		return
	var vis: Vector2 = size if size.x > 0.0 else get_viewport_rect().size
	var a: float = clampf(t / 0.2, 0.0, 1.0)
	draw_rect(Rect2(Vector2.ZERO, vis), Color(0.12, 0.02, 0.02, 0.66 * a))
	draw_set_transform_matrix(_xf)
	var mod: float = clampf(t / 0.12, 0.0, 1.0)
	UiDraw.panel(self, Rect2(0, 0, W, H), Color(Color8(0x1d, 0x25, 0x32), mod), 26, 5, 8)
	# ribbon
	var rb := Rect2(-12, 22, W + 24, 70)
	UiDraw.panel(self, rb, RED, 12, 4, 6)
	draw_style_box(UiDraw.box(Color(1, 1, 1, 0.16), 8), Rect2(rb.position + Vector2(8, 6), Vector2(rb.size.x - 16, 18)))
	UiDraw.text_c(self, rb.get_center(), str(data.get("title", "참교육 실패")), 40, Color.WHITE, 7, true, 3.0)
	# tow-truck art
	var art := Rect2(30, 110, W - 60, 200)
	draw_style_box(UiDraw.box(Color8(0x9d, 0xc8, 0xe8), 16, 4), art)
	draw_rect(Rect2(art.position + Vector2(4, art.size.y * 0.66), Vector2(art.size.x - 8, art.size.y * 0.34 - 4)), Color8(0x4a, 0x50, 0x58))
	var bob: float = sin(t * 5.0) * 2.0
	if not UiDraw.draw_icon(self, "wrecker", art.get_center() + Vector2(0, 6 + bob), art.size.x * 0.92):
		draw_rect(Rect2(art.get_center() - Vector2(80, 20), Vector2(160, 50)), Color8(0xff, 0xb4, 0x00))
	var st: float = t - 0.3
	if st > 0.0:
		var k: float = UiDraw.back_out(st / 0.16, 1.2)
		var ss: float = lerpf(2.4, 1.0, k)
		draw_set_transform_matrix(_xf * Transform2D(deg_to_rad(-12.0), Vector2(ss, ss), 0.0, art.position + Vector2(art.size.x - 88, 56)))
		var sr := Rect2(-74, -32, 148, 64)
		draw_style_box(UiDraw.box(Color(1, 1, 1, 0.9), 12, 5, RED), sr)
		UiDraw.text_c(self, Vector2(0, 2), "견인!", 38, RED, 0, true, 0.0)
		draw_set_transform_matrix(_xf)
	# reason
	var y: float = 344.0
	UiDraw.text(self, Vector2(34, y), "사유", 18, Color8(0xc9, 0xd3, 0xdf), 0, false, 0.0)
	var reason: String = str(data.get("reason", "차가 더는 못 버텼다"))
	var rs: int = 30
	while rs > 18 and UiDraw.rich_w(reason, rs) > W - 110.0:
		rs -= 2
	UiDraw.rich(self, Vector2(82, y + 4), reason, rs, Color.WHITE, 5, true, 2.0)
	# villain chip + last hit
	var who: String = str(data.get("villain_name", ""))
	var lost: int = int(data.get("hp_lost", 0))
	var cy: float = y + 30.0
	if not who.is_empty():
		var cw: float = UiDraw.text_w(who, 20) + 56.0
		var chip := Rect2(34, cy, cw, 40)
		UiDraw.panel(self, chip, Color8(0x3a, 0x14, 0x16), 12, 3, 3)
		UiDraw.draw_icon(self, "angry", Vector2(chip.position.x + 22, chip.get_center().y), 26)
		UiDraw.text(self, Vector2(chip.position.x + 40, chip.get_center().y + 8), who, 20, Color.WHITE, 0, true, 0.0)
	if lost > 0:
		var ls: String = "마지막 한 방 −%d" % lost
		UiDraw.text(self, Vector2(W - 34 - UiDraw.text_w(ls, 22), cy + 29), ls, 22, Color8(0xff, 0x6a, 0x5a), 4, true, 0.0)
	# honest consequence (P0#6)
	var tows: int = maxi(1, int(data.get("tows", 1)))
	var pm: float = float(data.get("pay_mul", 1.0))
	var cons: String = "견인 %d회" % tows
	if pm < 0.999:
		cons += " · 포상금 ×%s" % str(snappedf(pm, 0.01)).trim_suffix(".0")
	cons += " · ★2 실패"
	var nb := Rect2(34, cy + 56, W - 68, 44)
	UiDraw.panel(self, nb, Color8(0x15, 0x1b, 0x24), 12, 2, 0)
	UiDraw.text_c(self, nb.get_center(), cons, 20, Color8(0xff, 0xb3, 0xab), 0, false, 0.0)
	# buttons
	var rects: Dictionary = _btn_rects()
	var armed: bool = t >= T_ARM
	for n: String in ["retry", "menu"]:
		var r: Rect2 = rects[n]
		var b: Button = _btns[n]
		var cols: Array = BTN_YELLOW if n == "retry" else BTN_GREY
		if not armed:
			cols = [Color(cols[0] as Color, 0.55), Color(cols[1] as Color, 0.55), Color(cols[2] as Color, 0.55)]
		var pressed: bool = b.button_pressed
		UiDraw.gloss(self, r, cols, 24, pressed)
		var off := Vector2(0, (4.0 if pressed else 0.0) - 2.0)
		if n == "retry":
			var label: String = str(data.get("retry_label", "발견 지점부터 다시"))
			var lw: float = UiDraw.text_w(label, 30) + 44.0
			var ic := Vector2(r.get_center().x - lw * 0.5 + 16, r.get_center().y) + off
			if not UiDraw.draw_icon(self, "retry", ic, 34):
				draw_arc(ic, 12, 0.5, TAU - 0.3, 16, INK, 4.0, true)
			UiDraw.text(self, Vector2(ic.x + 26, r.get_center().y + 11 + off.y), label, 30, INK, 0, true, 0.0)
		else:
			UiDraw.text_c(self, r.get_center() + off, "메뉴", 24, INK, 0, true, 0.0)
	draw_set_transform_matrix(Transform2D.IDENTITY)
