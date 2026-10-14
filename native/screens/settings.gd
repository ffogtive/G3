class_name ScrSettings
extends ScrScreen
## Settings (native-new, NATIVE_PARITY A20): 음악 / 효과음 / 진동 / 배터리 절약 60fps / 왼손 모드, stored through
## Progress (persist across launches); the app applies them (bus mute, Haptics.enabled, Engine.max_fps, HUD mirror via
## loadout.left_hand). Credits: bundled fonts + OFL-1.1 text (res://ui/fonts/OFL.txt).

signal setting_changed(key: String, value: bool)

const ROWS: Array = [
	["music", "음악", "타이틀·판 배경음"],
	["sfx", "효과음", "경적·타격·보상 효과음"],
	["haptics", "진동", "버튼·피격·분노 햅틱"],
	["battery60", "배터리 절약 (60fps)", "120Hz 화면에서도 60fps로 고정"],
	["left_hand", "왼손 모드", "경적·분노 버튼을 왼쪽으로"],
]

var switches: Dictionary = {}
var _credits: Control


func _init() -> void:
	super()
	process_mode = Node.PROCESS_MODE_ALWAYS


func build() -> void:
	add_child(ScrKit.dim(0.62))
	move_child(get_child(get_child_count() - 1), 0)
	var m: MarginContainer = ScrKit.margin(18, 18, 18, 18)
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	safe.add_child(m)
	var cc := CenterContainer.new()
	cc.mouse_filter = Control.MOUSE_FILTER_PASS
	m.add_child(cc)
	var p: PanelContainer = ScrKit.panel(ScrKit.sb(Lane1Pal.CREAM, 30, 5, 10, Lane1Pal.INK, Vector4(0, 0, 0, 18)))
	p.name = "SettingsPanel"
	p.custom_minimum_size.x = 490
	cc.add_child(p)
	var v: VBoxContainer = ScrKit.vbox(10)
	p.add_child(v)
	var s: StyleBoxFlat = ScrKit.sb(Lane1Pal.GREEN, 0, 0, 0, Lane1Pal.INK, Vector4(8, 8, 8, 8))
	s.corner_radius_top_left = 25
	s.corner_radius_top_right = 25
	s.border_width_bottom = 5
	var head: PanelContainer = ScrKit.panel(s)
	var inner: PanelContainer = ScrKit.panel(ScrKit.sb(Color(0, 0, 0, 0), 14, 4, 0, Color.WHITE, Vector4(16, 8, 10, 8)))
	var hh: HBoxContainer = ScrKit.hbox(12)
	hh.add_child(ScrKit.icon("gear", 44))
	hh.add_child(ScrKit.lbl("설정", 42, Color.WHITE, true, 5, 4))
	hh.add_child(ScrKit.spacer())
	var x: ScrKit.Pill = ScrKit.round_btn("close", Lane1Pal.BTN_RED, 58)
	x.name = "Close"
	ScrKit.tap(x, close)
	hh.add_child(x)
	inner.add_child(hh)
	head.add_child(inner)
	v.add_child(head)
	var rm: MarginContainer = ScrKit.margin(18, 4, 18, 0)
	var rv: VBoxContainer = ScrKit.vbox(10)
	rm.add_child(rv)
	v.add_child(rm)
	for row: Array in ROWS:
		rv.add_child(_row(str(row[0]), str(row[1]), str(row[2])))
	var cm: MarginContainer = ScrKit.margin(18, 8, 18, 0)
	var cv: VBoxContainer = ScrKit.vbox(6)
	cm.add_child(cv)
	v.add_child(cm)
	var ver: String = str(ProjectSettings.get_setting("application/config/version", "0.1.0"))
	cv.add_child(ScrKit.lbl("1차선 참교육  v%s" % ver, 22, Lane1Pal.INK, true))
	cv.add_child(ScrKit.para("글꼴: Black Han Sans (The Black Han Sans Project Authors), Jua (The BM JUA Project Authors) — SIL Open Font License 1.1", 17, Lane1Pal.MUTED, false, HORIZONTAL_ALIGNMENT_LEFT))
	var lic: ScrKit.Pill = ScrKit.pill("라이선스 (OFL) 보기", Lane1Pal.BTN_GREY, 22)
	lic.name = "Licenses"
	ScrKit.tap(lic, _toggle_credits)
	cv.add_child(lic)
	_credits = ScrollContainer.new()
	_credits.name = "Credits"
	_credits.custom_minimum_size = Vector2(0, 260)
	_credits.visible = false
	(_credits as ScrollContainer).horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var txt: Label = ScrKit.para(_ofl_text(), 14, Color("#4a5360"), false, HORIZONTAL_ALIGNMENT_LEFT)
	txt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_credits.add_child(txt)
	cv.add_child(_credits)


static func _ofl_text() -> String:
	var out: String = ""
	for f: String in ["res://ui/fonts/OFL.txt", "res://ui/fonts/OFL-Jua.txt"]:
		if FileAccess.file_exists(f):
			out += FileAccess.get_file_as_string(f).strip_edges() + "\n\n"
	return out if not out.is_empty() else "SIL Open Font License 1.1"


func _toggle_credits() -> void:
	_credits.visible = not _credits.visible


func _row(key: String, label: String, sub: String) -> Control:
	var p: PanelContainer = ScrKit.panel(ScrKit.sb(Color.WHITE, 20, 4, 5, Lane1Pal.INK, Vector4(16, 10, 14, 10)))
	p.name = "Row_" + key
	var h: HBoxContainer = ScrKit.hbox(10)
	p.add_child(h)
	var v: VBoxContainer = ScrKit.vbox(0)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(ScrKit.lbl(label, 25, Lane1Pal.INK, true))
	v.add_child(ScrKit.lbl(sub, 16, Lane1Pal.MUTED, false))
	h.add_child(v)
	var sw := Switch.new()
	sw.name = "Switch"
	sw.on = bool(meta.get_setting(key))
	h.add_child(sw)
	switches[key] = sw
	ScrKit.tap(p, func() -> void: toggle(key))
	return p


func toggle(key: String) -> void:
	var sw: Switch = switches[key]
	sw.on = not sw.on
	sw.queue_redraw()
	meta.set_setting(key, sw.on)
	setting_changed.emit(key, sw.on)


class Switch extends Control:
	var on: bool = false

	func _init() -> void:
		custom_minimum_size = Vector2(92, 50)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		size_flags_vertical = Control.SIZE_SHRINK_CENTER

	func _draw() -> void:
		var s := StyleBoxFlat.new()
		s.bg_color = Lane1Pal.GREEN_HI if on else Color("#c9d0d8")
		s.set_corner_radius_all(25)
		s.set_border_width_all(4)
		s.border_color = Lane1Pal.INK
		s.anti_aliasing = true
		draw_style_box(s, Rect2(Vector2.ZERO, size))
		var r: float = size.y * 0.5 - 7.0
		var cx: float = size.x - size.y * 0.5 if on else size.y * 0.5
		draw_circle(Vector2(cx, size.y * 0.5 + 2.0), r, Lane1Pal.INK)
		draw_circle(Vector2(cx, size.y * 0.5), r, Color.WHITE)
		draw_circle(Vector2(cx, size.y * 0.5), r, Lane1Pal.INK, false, 3.0)
