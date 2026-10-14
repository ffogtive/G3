class_name ScrPause
extends ScrScreen
## In-stage pause overlay (ui.js buildPause / setPausedVisible; NATIVE_PARITY A19): 계속하기 / 다시하기 / 설정 / 메뉴로.
## Runs while the tree is paused (process_mode ALWAYS). 메뉴로 = abort (no reward, no penalty).

signal resume_requested
signal retry_requested
signal settings_requested
signal quit_requested


func _init() -> void:
	super()
	process_mode = Node.PROCESS_MODE_ALWAYS


func build() -> void:
	add_child(ScrKit.dim(0.62))
	move_child(get_child(get_child_count() - 1), 0)
	var cc := CenterContainer.new()
	cc.set_anchors_preset(Control.PRESET_FULL_RECT)
	cc.mouse_filter = Control.MOUSE_FILTER_PASS
	safe.add_child(cc)
	var p: PanelContainer = ScrKit.panel(ScrKit.sb(Lane1Pal.CREAM, 30, 5, 10, Lane1Pal.INK, Vector4(0, 0, 0, 26)))
	p.name = "PausePanel"
	p.custom_minimum_size.x = 400
	cc.add_child(p)
	var v: VBoxContainer = ScrKit.vbox(16)
	p.add_child(v)
	var s: StyleBoxFlat = ScrKit.sb(Lane1Pal.GREEN, 0, 0, 0, Lane1Pal.INK, Vector4(8, 8, 8, 8))
	s.corner_radius_top_left = 25
	s.corner_radius_top_right = 25
	s.border_width_bottom = 5
	var head: PanelContainer = ScrKit.panel(s)
	var inner: PanelContainer = ScrKit.panel(ScrKit.sb(Color(0, 0, 0, 0), 14, 4, 0, Color.WHITE, Vector4(16, 10, 16, 12)))
	var hh: HBoxContainer = ScrKit.hbox(12)
	hh.alignment = BoxContainer.ALIGNMENT_CENTER
	hh.add_child(ScrKit.icon("pause", 44))
	hh.add_child(ScrKit.lbl("일시정지", 44, Color.WHITE, true, 5, 4))
	inner.add_child(hh)
	head.add_child(inner)
	v.add_child(head)
	var bm: MarginContainer = ScrKit.margin(34, 4, 34, 0)
	var bv: VBoxContainer = ScrKit.vbox(18)
	bm.add_child(bv)
	v.add_child(bm)
	for row: Array in [["Resume", "계속하기 ▶", Lane1Pal.BTN_YELLOW, resume_requested], ["Retry", "다시하기", Lane1Pal.BTN_BLUE, retry_requested],
			["Settings", "설정", Lane1Pal.BTN_GREY, settings_requested], ["Quit", "메뉴로", Lane1Pal.BTN_RED, quit_requested]]:
		var b: ScrKit.Pill = ScrKit.pill(str(row[1]), row[2], 32 if row[0] == "Resume" else 28)
		b.name = str(row[0])
		var sig: Signal = row[3]
		ScrKit.tap(b, func() -> void: sig.emit(), "uiConfirm" if row[0] == "Resume" else "ui")
		bv.add_child(b)
	var note: Label = ScrKit.lbl("메뉴로 나가면 이번 판 보상은 없어요", 18, Lane1Pal.MUTED, false)
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(note)
