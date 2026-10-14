class_name ResultCard
extends Control
## Stage result card (web ui.js showRewardResult, simplified for M1c; DESIGN_REVIEW P0#6 honest numbers).
##   header  green road sign: route shield + "경부고속도로 · 부산 방향", stage title under it
##   고지서   cream ticket: dash-cam still of the villain car, 위반 차량 (name struck through), 위반 내용, 범칙금,
##           red "참교육 완료" seal that slams in
##   facts   걸린 시간 (whole stage incl. retries) · 최저 내구도 · 견인 N회 · 원흉전 N초 — straight from GameSim.result
##   stars   the three missions, each star pops in turn; a failed one stays grey with its reason ("견인 1회")
##   money   범칙금 → "포상금 ×1.5" → 포상금 counting up, 보유 포상금; retry multiplier shown when < 1
##   buttons 다음 빌런 ▶ · 다시하기 · 메뉴 → choice(&"next" | &"retry" | &"menu")
## Laid out in a fixed 500 × 1000 design box scaled into the viewport (minus the HUD safe insets of the parent Hud).
## Timeline on real time (advance / seek): a tap before the end fast-forwards; buttons arm at 0.8 s.

signal choice(choice: StringName)

const INK := UiDraw.INK
const W: float = 500.0
const H: float = 1000.0
const T_SLIDE: float = 0.35
const T_STAMP: float = 0.5
const T_FACTS: float = 0.7
const T_STARS: Array[float] = [1.15, 1.45, 1.75]
const T_MONEY: float = 2.05
const T_MONEY_DUR: float = 0.9
const T_END: float = 3.1
const T_ARM: float = 0.8
const CREAM := Color8(0xff, 0xf7, 0xe3)
const SIGN := Color8(0x0b, 0x7a, 0x4b)
const RED := Color8(0xe8, 0x24, 0x2a)
const GOLD := Color8(0xff, 0xd2, 0x3f)
const BTN_YELLOW: Array = [Color8(0xff, 0xe6, 0x80), Color8(0xff, 0xcf, 0x33), Color8(0xf0, 0x9a, 0x00)]
const BTN_BLUE: Array = [Color8(0x6a, 0xa6, 0xff), Color8(0x2f, 0x6f, 0xd6), Color8(0x1f, 0x4f, 0xa3)]
const BTN_GREY: Array = [Color8(0xcf, 0xd5, 0xdc), Color8(0x9a, 0xa3, 0xae), Color8(0x6d, 0x76, 0x82)]
const CASE_STAMP: Dictionary = {"fine": "과태료 고지서", "crime": "형사 입건 통지서", "rescue": "구조 표창장", "warn": "계도 통지서"}

var data: Dictionary = {}
var t: float = 0.0
var _open: bool = false
var _xf := Transform2D.IDENTITY
var _btns: Dictionary = {}   # name → Button
var _played: Dictionary = {}


## Card model from GameSim result + Progress.record_result() (record may be {}) + stage row.
static func model(result: Dictionary, record: Dictionary = {}, stage: Dictionary = {}) -> Dictionary:
	var stars: int = clampi(int(record.get("stars", result.get("stars", 0))), 0, 3)
	var ms: Array = record.get("missions", result.get("missions", [])) if record.get("missions") is Array or result.get("missions") is Array else []
	var missions: Array[Dictionary] = []
	for m: Variant in ms:
		if m is Dictionary:
			missions.append({"label": str((m as Dictionary).get("label", "")), "done": bool((m as Dictionary).get("done", false))})
	while missions.size() < 3:
		missions.append({"label": "", "done": false})
	var tows: int = int(record.get("tows", result.get("tows", result.get("retries", 0))))
	var pay_mul: float = float(record.get("retry_mul", result.get("pay_mul", 1.0)))
	var fine: float = float(record.get("fine", stage.get("fine", 30000) if stage.get("fine") != null else 30000))
	var star_mult: float = float(record.get("star_mult", [1.0, 1.0, 1.5, 2.0][stars]))
	var payout: float = float(record.get("payout", -1.0))
	var bonus: float = float(record.get("bonus", -1.0))
	if payout < 0.0:
		var rw: Dictionary = _compute_reward(stage, result, stars, pay_mul)
		payout = float(rw.get("payout", 0.0))
		bonus = float(rw.get("bonus", 0.0))
		fine = float(rw.get("base", fine))
	var vcol: int = 0xd9c9a3
	if stage.get("villains") is Array and not (stage["villains"] as Array).is_empty():
		vcol = int(((stage["villains"] as Array)[0] as Dictionary).get("color", vcol))
	var wallet: float = float(record.get("wallet", -1.0))
	return {
		"highway": str(stage.get("highway", "고속도로")), "direction": str(stage.get("direction", "")),
		"route": int(stage.get("route", 1)) if stage.get("route") != null else 1,
		"stage_name": str(record.get("stage_name", stage.get("title", "1차선 참교육"))),
		"stage_id": int(record.get("stage_id", result.get("stage_id", stage.get("id", 1)))),
		"villain_name": str(record.get("villain_name", result.get("villain_name", "원흉"))),
		"violation": str(record.get("violation", stage.get("violation", "도로교통법 위반") if stage.get("violation") != null else "도로교통법 위반")),
		"cause": str(stage.get("cause", "")) if stage.get("cause") != null else "",
		"case": str(record.get("case", "fine")),
		"fine": fine, "star_mult": star_mult, "payout": payout, "bonus": maxf(0.0, bonus), "pay_mul": pay_mul,
		"wallet": wallet, "wallet_before": float(record.get("wallet_before", wallet - payout if wallet >= 0.0 else -1.0)),
		"time_s": float(result.get("time_s", 0.0)), "boss_time_s": float(result.get("boss_time_s", 0.0)),
		"min_hp": int(result.get("min_hp", result.get("hp", 0))), "hp_max": int(result.get("hp_max", 100)), "tows": tows,
		"stars": stars, "missions": missions, "score": int(record.get("score", result.get("score", 0))),
		"is_last": bool(record.get("is_last", false)), "villain_color": vcol,
	}


## Rewards.compute_reward (pure, no save) when no Progress record was passed: {payout, bonus, base, ...}.
static func _compute_reward(stage: Dictionary, result: Dictionary, stars: int, pay_mul: float) -> Dictionary:
	const PATH := "res://meta/rewards.gd"
	if not ResourceLoader.exists(PATH):
		return {}
	var R: Script = load(PATH) as Script
	if R == null:
		return {}
	var r: Dictionary = {"stars": stars, "cath": result.get("cath", 0), "freed": result.get("freed", 0),
		"cheaters": result.get("cheaters", 0), "mini_fines": 0, "pay_mul": pay_mul}
	var rw: Variant = R.call(&"compute_reward", stage, r, int(result.get("seed", 1)))
	return rw if rw is Dictionary else {}


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	for n: String in ["next", "retry", "menu"]:
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
	_played.clear()
	visible = true
	_layout()
	queue_redraw()


func close() -> void:
	_open = false
	visible = false


func is_open() -> bool:
	return _open


func advance(dt: float) -> void:
	if not _open:
		return
	seek(t + dt)


func seek(time_s: float) -> void:
	t = time_s
	_cues()
	_layout()
	queue_redraw()


func _gui_input(e: InputEvent) -> void:
	if not _open:
		return
	var tap: bool = (e is InputEventMouseButton and (e as InputEventMouseButton).pressed) or (e is InputEventScreenTouch and (e as InputEventScreenTouch).pressed)
	if tap and t < T_END:
		seek(T_END)
		accept_event()


func _on_btn(n: String) -> void:
	if t < T_ARM:
		return
	_feedback(&"uiConfirm" if n == "next" else &"ui")
	choice.emit(StringName(n))


func _feedback(sfx: StringName, opts: Dictionary = {}) -> void:
	var au: Node = get_node_or_null(^"/root/Audio")
	if au != null and au.has_method(&"sfx"):
		au.call(&"sfx", sfx, opts)
	var hp: Node = get_node_or_null(^"/root/Haptics")
	if hp != null and hp.has_method(&"haptic"):
		hp.call(&"haptic", "uiLight")


func _cues() -> void:
	for i: int in 3:
		var k: String = "star%d" % i
		if t >= T_STARS[i] and not _played.has(k):
			_played[k] = true
			if i < int(data.get("stars", 0)):
				_feedback(&"star", {"pitch": 1.0 + 0.12 * float(i)})
	if t >= T_MONEY and not _played.has("money"):
		_played["money"] = true
		_feedback(&"twinkle")


## Design box → screen: centred in the parent's safe rect, uniform scale.
func _layout() -> void:
	var vis: Vector2 = size if size.x > 0.0 else get_viewport_rect().size
	var area := Rect2(Vector2.ZERO, vis)
	var hud: Node = get_parent()
	while hud != null and not (hud is Hud):
		hud = hud.get_parent()
	if hud is Hud:
		area = (hud as Hud).safe_rect()
	var sc: float = minf((area.size.x - 24.0) / W, (area.size.y - 24.0) / H)
	var slide: float = (1.0 - UiDraw.back_out(t / T_SLIDE, 1.3)) * 520.0
	var origin := Vector2(area.get_center().x - W * sc * 0.5, area.get_center().y - H * sc * 0.5 + slide)
	_xf = Transform2D(0.0, Vector2(sc, sc), 0.0, origin)
	var rects: Dictionary = _btn_rects()
	for n: String in _btns:
		var b: Button = _btns[n]
		var r: Rect2 = rects[n]
		b.position = _xf * r.position
		b.size = r.size * sc
		b.disabled = t < T_ARM
		b.visible = n != "next" or not bool(data.get("is_last", false))


func _btn_rects() -> Dictionary:
	var y: float = H - 84.0
	if bool(data.get("is_last", false)):
		return {"next": Rect2(0, 0, 0, 0), "retry": Rect2(14, y, 300, 72), "menu": Rect2(328, y, 158, 72)}
	return {"next": Rect2(14, y, 250, 72), "retry": Rect2(274, y, 122, 72), "menu": Rect2(406, y, 80, 72)}


func _draw() -> void:
	if not _open:
		return
	var vis: Vector2 = size if size.x > 0.0 else get_viewport_rect().size
	var dim: float = clampf(t / 0.25, 0.0, 1.0)
	draw_rect(Rect2(Vector2.ZERO, vis), Color(0.03, 0.04, 0.06, 0.62 * dim))
	_rays(vis, dim)
	draw_set_transform_matrix(_xf)
	UiDraw.panel(self, Rect2(0, 0, W, H), Color8(0x1d, 0x25, 0x32), 26, 5, 8)
	_header()
	_ticket()
	_facts()
	_stars()
	_money()
	_buttons()
	draw_set_transform_matrix(Transform2D.IDENTITY)


func _rays(vis: Vector2, a: float) -> void:
	var c := Vector2(vis.x * 0.5, vis.y * 0.42)
	var n: int = 16
	var r: float = vis.length()
	for i: int in n:
		var a0: float = t * 0.15 + TAU * float(i) / float(n)
		var a1: float = a0 + TAU / float(n) * 0.5
		draw_colored_polygon(PackedVector2Array([c, c + Vector2(cos(a0), sin(a0)) * r, c + Vector2(cos(a1), sin(a1)) * r]),
			Color(1.0, 0.85, 0.3, 0.07 * a))


func _header() -> void:
	var r := Rect2(14, 14, W - 28, 100)
	UiDraw.panel(self, r, SIGN, 16, 4, 5)
	draw_style_box(UiDraw.box(Color(0, 0, 0, 0), 11, 3, Color(1, 1, 1, 0.95)), r.grow(-7))
	# route shield
	var sc := Vector2(r.position.x + 52, r.get_center().y)
	if not UiDraw.draw_icon(self, "shield", sc, 56):
		draw_circle(sc, 26, Color8(0x1f, 0x4f, 0xa3))
	UiDraw.text_c(self, sc + Vector2(0, 5), str(data.get("route", 1)), 22, Color.WHITE, 4, true, 0.0)
	var hw: String = str(data.get("highway", ""))
	var dirn: String = str(data.get("direction", ""))
	var line1: String = hw + ("  " + dirn if not dirn.is_empty() else "")
	var fs: int = 30
	while fs > 18 and UiDraw.text_w(line1, fs) > r.size.x - 120.0:
		fs -= 2
	UiDraw.text(self, Vector2(r.position.x + 92, r.position.y + 46), line1, fs, Color.WHITE, 0, true, 0.0)
	var sid: int = int(data.get("stage_id", 1))
	var line2: String = "%d-%d  %s" % [(sid - 1) / 10 + 1, (sid - 1) % 10 + 1, str(data.get("stage_name", ""))]
	UiDraw.text(self, Vector2(r.position.x + 92, r.position.y + 80), line2, 22, Color8(0x8d, 0xff, 0xbb), 0, false, 0.0)


func _ticket() -> void:
	var r := Rect2(22, 132, W - 44, 300)
	var tilt: float = deg_to_rad(-1.2)
	var c: Vector2 = r.get_center()
	draw_set_transform_matrix(_xf * Transform2D(tilt, c))
	var rr := Rect2(-r.size * 0.5, r.size)
	UiDraw.panel(self, rr, CREAM, 14, 4, 7)
	# perforated top strip
	var strip := Rect2(rr.position + Vector2(4, 4), Vector2(rr.size.x - 8, 44))
	var sb := UiDraw.box(RED, 10)
	sb.corner_radius_bottom_left = 0
	sb.corner_radius_bottom_right = 0
	draw_style_box(sb, strip)
	var title: String = str(CASE_STAMP.get(str(data.get("case", "fine")), "과태료 고지서"))
	UiDraw.text_c(self, strip.get_center(), title, 26, Color.WHITE, 0, true, 0.0)
	for i: int in 22:
		draw_circle(Vector2(strip.position.x + 10.0 + float(i) * (strip.size.x - 20.0) / 21.0, strip.end.y + 4.0), 3.0, Color(INK, 0.18))
	# dash-cam still
	var cam := Rect2(rr.position + Vector2(16, 62), Vector2(176, 150))
	_dashcam(cam)
	# fields
	var fx: float = cam.end.x + 18.0
	var fw: float = rr.end.x - 16.0 - fx
	UiDraw.text(self, Vector2(fx, cam.position.y + 18), "위반 차량", 17, Color(INK, 0.6), 0, false, 0.0)
	var vn: String = str(data.get("villain_name", ""))
	var vs: int = 30
	while vs > 18 and UiDraw.text_w(vn, vs) > fw:
		vs -= 2
	var vy: float = cam.position.y + 56
	UiDraw.text(self, Vector2(fx, vy), vn, vs, INK, 0, true, 0.0)
	var strike: float = clampf((t - T_STAMP - 0.1) / 0.25, 0.0, 1.0)
	if strike > 0.0:
		var sw: float = UiDraw.text_w(vn, vs) * strike
		draw_line(Vector2(fx - 4, vy - vs * 0.32), Vector2(fx - 4 + sw + 8, vy - vs * 0.38), Color(RED, 0.9), 5.0, true)
	UiDraw.text(self, Vector2(fx, vy + 34), "위반 내용", 17, Color(INK, 0.6), 0, false, 0.0)
	_wrap(str(data.get("violation", "")), Vector2(fx, vy + 60), fw, 18, INK, 3)
	var amt_y: float = rr.end.y - 26.0
	UiDraw.text(self, Vector2(rr.position.x + 18, amt_y), "범칙금", 22, Color(INK, 0.75), 0, false, 0.0)
	var amt: String = UiDraw.won(float(data.get("fine", 0)))
	UiDraw.text(self, Vector2(rr.position.x + 18 + UiDraw.text_w("범칙금 ", 22, false), amt_y + 2), amt, 34, RED, 0, true, 0.0)
	# seal
	var st: float = t - T_STAMP
	if st > 0.0:
		var k: float = UiDraw.back_out(st / 0.18, 1.2)
		var ssc: float = lerpf(2.6, 1.0, k)
		var sa: float = clampf(st / 0.08, 0.0, 1.0)
		var sc := Vector2(cam.end.x - 50, cam.end.y - 48)
		draw_set_transform_matrix(_xf * Transform2D(tilt, c) * Transform2D(deg_to_rad(-14.0), Vector2(ssc, ssc), 0.0, sc))
		var seal := Color(RED, 0.88 * sa)
		draw_circle(Vector2.ZERO, 52, Color(1, 1, 1, 0.35 * sa))
		draw_arc(Vector2.ZERO, 54, 0.0, TAU, 48, seal, 6.0, true)
		draw_arc(Vector2.ZERO, 45, 0.0, TAU, 48, seal, 2.5, true)
		UiDraw.text_c(self, Vector2(0, -12), "참교육", 24, seal, 0, true, 0.0)
		UiDraw.text_c(self, Vector2(0, 17), "완료", 28, seal, 0, true, 0.0)
	draw_set_transform_matrix(_xf)


## Dash-cam still: night-blue frame, road, the villain car from behind in its paint, REC + speed OSD.
func _dashcam(r: Rect2) -> void:
	draw_style_box(UiDraw.box(INK, 10), r.grow(4))
	draw_rect(r, Color8(0x5e, 0x8f, 0xc2))
	var hor: float = r.position.y + r.size.y * 0.42
	draw_rect(Rect2(r.position, Vector2(r.size.x, hor - r.position.y)), Color8(0x9d, 0xc8, 0xe8))
	var road := PackedVector2Array([Vector2(r.position.x + r.size.x * 0.42, hor), Vector2(r.position.x + r.size.x * 0.58, hor),
		Vector2(r.end.x, r.end.y), Vector2(r.position.x, r.end.y)])
	draw_colored_polygon(road, Color8(0x4a, 0x50, 0x58))
	draw_rect(Rect2(Vector2(r.position.x, hor), Vector2(r.size.x * 0.2, r.end.y - hor)), Color8(0x6b, 0xa8, 0x4a))
	for i: int in 4:
		var y0: float = hor + 6.0 + float(i) * 22.0
		draw_line(Vector2(r.get_center().x, y0), Vector2(r.get_center().x, y0 + 10.0 + float(i) * 3.0), Color(1, 1, 1, 0.8), 2.0 + float(i))
	var col := Color.hex(int(data.get("villain_color", 0xd9c9a3)) << 8 | 0xff)
	var cw: float = r.size.x * 0.56
	var ch: float = r.size.y * 0.42
	var cb := Rect2(Vector2(r.get_center().x - cw * 0.5 - 14.0, r.end.y - ch - 16.0), Vector2(cw, ch))
	draw_style_box(UiDraw.box(Color(0, 0, 0, 0.35), 8), Rect2(cb.position + Vector2(-4, ch - 8), Vector2(cw + 8, 16)))
	draw_style_box(UiDraw.box(col, 9, 3), cb)
	draw_style_box(UiDraw.box(Color8(0x24, 0x36, 0x6b), 5), Rect2(cb.position + Vector2(cw * 0.16, 6), Vector2(cw * 0.68, ch * 0.34)))
	draw_rect(Rect2(cb.position + Vector2(6, ch * 0.52), Vector2(cw * 0.2, ch * 0.16)), Color8(0xff, 0x2a, 0x2a))
	draw_rect(Rect2(cb.position + Vector2(cw * 0.8 - 6, ch * 0.52), Vector2(cw * 0.2, ch * 0.16)), Color8(0xff, 0x2a, 0x2a))
	draw_rect(Rect2(cb.position + Vector2(cw * 0.32, ch * 0.62), Vector2(cw * 0.36, ch * 0.2)), Color.WHITE)
	draw_rect(Rect2(cb.position + Vector2(cw * 0.32, ch * 0.62), Vector2(cw * 0.36, ch * 0.2)), INK, false, 1.5)
	# OSD
	draw_circle(r.position + Vector2(14, 14), 5, Color8(0xff, 0x3b, 0x30) if int(t * 2.0) % 2 == 0 else Color(1, 0.3, 0.2, 0.3))
	UiDraw.text(self, r.position + Vector2(24, 20), "REC", 15, Color.WHITE, 3, true, 0.0)
	UiDraw.text(self, Vector2(r.position.x + 8, r.end.y - 8), "1차로", 15, Color.WHITE, 3, true, 0.0)
	UiDraw.text(self, Vector2(r.end.x - 70, r.position.y + 20), "FRONT", 14, Color.WHITE, 3, true, 0.0)


func _wrap(s: String, pos: Vector2, w: float, size: int, col: Color, max_lines: int) -> void:
	var words: PackedStringArray = s.split(" ")
	var line: String = ""
	var y: float = pos.y
	var n: int = 0
	for wd: String in words:
		var cand: String = wd if line.is_empty() else line + " " + wd
		if UiDraw.rich_w(cand, size, false) > w and not line.is_empty():
			UiDraw.rich(self, Vector2(pos.x, y), line, size, col, 0, false, 0.0)
			y += size * 1.25
			n += 1
			line = wd
			if n >= max_lines:
				return
		else:
			line = cand
	if not line.is_empty() and n < max_lines:
		UiDraw.rich(self, Vector2(pos.x, y), line, size, col, 0, false, 0.0)


func _facts() -> void:
	var y: float = 452.0
	var items: Array = [
		["걸린 시간", UiDraw.clock(float(data.get("time_s", 0.0))), Color.WHITE],
		["최저 내구도", "%d" % int(data.get("min_hp", 0)), Color8(0x8d, 0xff, 0xbb) if int(data.get("min_hp", 0)) >= 60 else Color8(0xff, 0xb3, 0xab)],
		["견인", "%d회" % int(data.get("tows", 0)), Color.WHITE if int(data.get("tows", 0)) == 0 else Color8(0xff, 0x6a, 0x5a)],
		["원흉전", "%.1f초" % float(data.get("boss_time_s", 0.0)), Color.WHITE],
	]
	var tw: float = (W - 28.0 - 3.0 * 8.0) / 4.0
	for i: int in 4:
		var at: float = t - T_FACTS - 0.08 * float(i)
		if at <= 0.0:
			continue
		var k: float = UiDraw.back_out(at / 0.22, 2.0)
		var r := Rect2(14.0 + float(i) * (tw + 8.0), y, tw, 92)
		var c: Vector2 = r.get_center()
		draw_set_transform_matrix(_xf * Transform2D(0.0, Vector2(k, k), 0.0, c))
		var rr := Rect2(-r.size * 0.5, r.size)
		UiDraw.panel(self, rr, Color8(0x2a, 0x34, 0x42), 14, 3, 4)
		UiDraw.text_c(self, Vector2(0, -22), str(items[i][0]), 16, Color8(0xc9, 0xd3, 0xdf), 0, false, 0.0)
		var vs: int = 32
		while vs > 18 and UiDraw.text_w(str(items[i][1]), vs) > tw - 12.0:
			vs -= 2
		UiDraw.text_c(self, Vector2(0, 14), str(items[i][1]), vs, items[i][2] as Color, 5, true, 2.0)
	draw_set_transform_matrix(_xf)


func _stars() -> void:
	var ms: Array = data.get("missions", [])
	var y0: float = 566.0
	var rh: float = 62.0
	var tows: int = int(data.get("tows", 0))
	for i: int in 3:
		var m: Dictionary = ms[i] if i < ms.size() else {"label": "", "done": false}
		var done: bool = bool(m.get("done", false))
		var r := Rect2(14, y0 + float(i) * (rh + 8.0), W - 28, rh)
		UiDraw.panel(self, r, Color8(0x2a, 0x34, 0x42), 14, 3, 4)
		var st: float = t - T_STARS[i]
		var sc := Vector2(r.position.x + 40, r.get_center().y)
		if st > 0.0:
			var k: float = UiDraw.elastic_out(st / 0.5) if done else UiDraw.back_out(st / 0.2)
			draw_set_transform_matrix(_xf * Transform2D(0.0 if done else 0.0, Vector2(k, k), 0.0, sc))
			UiDraw.star(self, Vector2.ZERO, 24, done)
			UiDraw.text_c(self, Vector2(0, 3), str(i + 1), 18, INK if done else Color8(0xc9, 0xd3, 0xdf), 0, true, 0.0)
			draw_set_transform_matrix(_xf)
			if done and st < 0.5:
				for j: int in 8:
					var a: float = TAU * float(j) / 8.0 + float(i)
					var d: float = 24.0 + st * 90.0
					draw_circle(sc + Vector2(cos(a), sin(a)) * d, 4.0 * (1.0 - st / 0.5), GOLD)
		else:
			UiDraw.star(self, sc, 24, false)
		var lab: String = str(m.get("label", ""))
		var lc: Color = Color.WHITE if done or st <= 0.0 else Color8(0x9a, 0xa3, 0xae)
		var ls: int = 22
		while ls > 15 and UiDraw.rich_w(lab, ls, false) > r.size.x - 130.0:
			ls -= 1
		UiDraw.rich(self, Vector2(r.position.x + 78, r.get_center().y + ls * 0.36 - (8.0 if not done and i == 1 and tows > 0 and st > 0.0 else 0.0)), lab, ls, lc, 0, false, 0.0)
		if not done and i == 1 and tows > 0 and st > 0.0:
			UiDraw.text(self, Vector2(r.position.x + 78, r.end.y - 8), "견인 %d회 → 실패" % tows, 15, Color8(0xff, 0x8a, 0x80), 0, false, 0.0)
		if st > 0.0:
			var mc := Vector2(r.end.x - 30, r.get_center().y)
			if done:
				if not UiDraw.draw_icon(self, "check", mc, 34):
					draw_circle(mc, 15, Color8(0x22, 0xc5, 0x5e))
			else:
				draw_circle(mc, 15, Color8(0x5c, 0x66, 0x72))
				draw_line(mc + Vector2(-6, -6), mc + Vector2(6, 6), Color.WHITE, 3.5, true)
				draw_line(mc + Vector2(6, -6), mc + Vector2(-6, 6), Color.WHITE, 3.5, true)


func _money() -> void:
	var y: float = 790.0
	var r := Rect2(14, y, W - 28, 112)
	UiDraw.panel(self, r, Color8(0x15, 0x1b, 0x24), 16, 3, 4)
	var k: float = clampf((t - T_MONEY) / T_MONEY_DUR, 0.0, 1.0)
	var e: float = 1.0 - pow(1.0 - k, 3.0)
	# 범칙금 box → arrow → 포상금 box
	var fb := Rect2(r.position + Vector2(10, 10), Vector2(150, 58))
	UiDraw.panel(self, fb, Color8(0x3a, 0x14, 0x16), 12, 2, 0)
	UiDraw.text_c(self, fb.get_center() - Vector2(0, 14), "범칙금 (빌런 부담)", 14, Color8(0xff, 0xb3, 0xab), 0, false, 0.0)
	UiDraw.text_c(self, fb.get_center() + Vector2(0, 12), UiDraw.won(float(data.get("fine", 0))), 22, Color.WHITE, 4, true, 0.0)
	var mult: float = float(data.get("star_mult", 1.0))
	var arrow_c := Vector2(fb.end.x + 46, fb.get_center().y)
	draw_colored_polygon(PackedVector2Array([arrow_c + Vector2(-30, -6), arrow_c + Vector2(14, -6), arrow_c + Vector2(14, -14),
		arrow_c + Vector2(32, 0), arrow_c + Vector2(14, 14), arrow_c + Vector2(14, 6), arrow_c + Vector2(-30, 6)]), GOLD)
	UiDraw.text_c(self, arrow_c + Vector2(0, -22), "포상금 ×%s" % _num(mult), 15, GOLD, 4, true, 0.0)

	var pb := Rect2(Vector2(arrow_c.x + 44, fb.position.y), Vector2(r.end.x - 10 - arrow_c.x - 44, 58))
	UiDraw.panel(self, pb, Color8(0x0b, 0x5c, 0x37), 12, 2, 0)
	UiDraw.text_c(self, pb.get_center() - Vector2(0, 14), "포상금 · 내가 받는 돈", 14, Color8(0x8d, 0xff, 0xbb), 0, false, 0.0)
	var pay: float = float(data.get("payout", 0.0)) * e
	var pop: float = 1.0 + 0.12 * sin(PI * clampf((t - T_MONEY - T_MONEY_DUR) / 0.2, 0.0, 1.0))
	draw_set_transform_matrix(_xf * Transform2D(0.0, Vector2(pop, pop), 0.0, pb.get_center() + Vector2(0, 12)))
	UiDraw.text_c(self, Vector2.ZERO, "+" + UiDraw.won(pay), 28, Color8(0xff, 0xe1, 0x4d), 5, true, 2.0)
	draw_set_transform_matrix(_xf)
	# wallet / retry multiplier line
	var ly: float = r.end.y - 16.0
	var pm: float = float(data.get("pay_mul", 1.0))
	var wl: float = float(data.get("wallet", -1.0))
	if not UiDraw.draw_icon(self, "coin", Vector2(r.position.x + 26, ly - 8), 26):
		draw_circle(Vector2(r.position.x + 26, ly - 8), 11, GOLD)
	var left: String = ("보유 포상금 " + UiDraw.won(float(data.get("wallet_before", 0.0)) + float(data.get("payout", 0.0)) * e)) if wl >= 0.0 \
		else ("점수 " + UiDraw.group(float(data.get("score", 0))))
	UiDraw.text(self, Vector2(r.position.x + 46, ly), left, 20, Color.WHITE, 0, false, 0.0)
	# what the payout is made of, on the right (honest: bonus and the tow multiplier are visible)
	var notes: PackedStringArray = []
	var bonus: float = float(data.get("bonus", 0.0))
	if bonus > 0.0:
		notes.append("보너스 +" + UiDraw.won(bonus))
	if pm < 0.999:
		notes.append("견인 %d회 ×%s" % [int(data.get("tows", 0)), _num(pm)])
	var note: String = " · ".join(notes)
	if not note.is_empty():
		var nc: Color = Color8(0xff, 0x8a, 0x80) if pm < 0.999 else Color8(0xc9, 0xd3, 0xdf)
		UiDraw.rich(self, Vector2(r.end.x - 12 - UiDraw.rich_w(note, 17, false), ly), note, 17, nc, 0, false, 0.0)


static func _num(x: float) -> String:
	return str(snappedf(x, 0.01)).trim_suffix(".0")


func _buttons() -> void:
	var rects: Dictionary = _btn_rects()
	var armed: bool = t >= T_ARM
	var a: float = clampf((t - 0.3) / 0.3, 0.0, 1.0)
	if a <= 0.0:
		return
	var defs: Array = [["next", "다음 빌런 ▶", BTN_YELLOW, INK, 28], ["retry", "다시하기", BTN_BLUE, Color.WHITE, 22],
		["menu", "메뉴", BTN_GREY, INK, 22]]
	for d: Array in defs:
		var n: String = d[0]
		if n == "next" and bool(data.get("is_last", false)):
			continue
		var r: Rect2 = rects[n]
		var b: Button = _btns[n]
		var pressed: bool = b.button_pressed if b != null else false
		var cols: Array = d[2]
		if not armed:
			cols = [Color(cols[0] as Color, 0.6), Color(cols[1] as Color, 0.6), Color(cols[2] as Color, 0.6)]
		UiDraw.gloss(self, r, cols, 22, pressed)
		var tc: Color = d[3]
		UiDraw.rich_c(self, r.get_center() + Vector2(0, (4.0 if pressed else 0.0) - 2.0), str(d[1]), int(d[4]), tc,
			0 if tc == INK else 5, true, 0.0)
