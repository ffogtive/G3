class_name ScrStageCard
extends ScrScreen
## Stage card (ui.js showStageCard · roadHTML · missionsHTML, main.js roadInfo / stageMissions; NATIVE_PARITY A13):
## green sign (shield · highway · direction ▶), STAGE n + kind badge + case tag, title, villain line, blurb,
## 정체 km + 원흉 speed, rescue strip (honkOnly), 도로 상황 tiles (갓길 / 경적 / 특수) + VMS hint, ★ 미션 ×3,
## "탭하여 바로 시작", timer bar. Tap anywhere (after a 280 ms arm) or the timer (2.6 s + 0.8 s missions + 1 s road)
## emits start_requested exactly once. Native extra: a ✕ (back to the dashboard) — the web had no way back.

signal start_requested(id: int)

const ARM_S: float = 0.28

var stage_id: int = 1
var auto_start: bool = true
var duration: float = 0.0
var elapsed: float = 0.0
var started: bool = false
var _timer_bar: ScrKit.Bar
var _tap: Label
var _panel: PanelContainer


func build() -> void:
	var st: Dictionary = meta.stage(stage_id)
	var ms: Array = meta.missions_for(stage_id)
	var road: Dictionary = road_info(st)
	duration = (3.4 if not ms.is_empty() else 2.6) + (1.0 if not road.is_empty() else 0.0)
	var dim: ColorRect = ScrKit.dim(0.5)
	dim.mouse_filter = Control.MOUSE_FILTER_PASS   # a tap on the backdrop starts too (web: pointerdown on the card layer)
	add_child(dim)
	move_child(dim, 0)
	var m: MarginContainer = ScrKit.margin(20, 18, 20, 18)
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	safe.add_child(m)
	var cc := CenterContainer.new()
	cc.mouse_filter = Control.MOUSE_FILTER_PASS
	m.add_child(cc)
	_panel = ScrKit.panel(ScrKit.sb(Lane1Pal.CREAM, 30, 5, 10, Lane1Pal.INK, Vector4(0, 0, 0, 0)))
	_panel.name = "CardPanel"
	_panel.custom_minimum_size.x = 500
	cc.add_child(_panel)
	var v: VBoxContainer = ScrKit.vbox(0)
	_panel.add_child(v)
	v.add_child(road_sign(st, 50, 38))
	var body: MarginContainer = ScrKit.margin(22, 16, 22, 4)
	v.add_child(body)
	var bv: VBoxContainer = ScrKit.vbox(10)
	body.add_child(bv)
	var kd: String = ScrKit.stage_kind(st)
	var ck: String = ScrKit.case_kind(st.get("card"))
	var no: HBoxContainer = ScrKit.hbox(10)
	no.alignment = BoxContainer.ALIGNMENT_CENTER
	no.add_child(ScrKit.lbl("STAGE %d" % stage_id, 22, Lane1Pal.MUTED, true))
	var kb: Control = ScrKit.kind_badge(kd, 17)
	if kb != null:
		no.add_child(kb)
	var tagp: PanelContainer = ScrKit.panel(ScrKit.sb(Color(str(Lane1Pal.CASE_COLOR[ck])), 12, 3, 0, Lane1Pal.INK, Vector4(4, 1, 12, 1)))
	tagp.name = "CaseTag"
	var th: HBoxContainer = ScrKit.hbox(4)
	th.add_child(ScrKit.icon("horn" if ck == "rescue" else "angry", 26))
	th.add_child(ScrKit.lbl(str(_case(ck).get("tag", "오늘의 빌런")), 20, Color.WHITE, false))
	tagp.add_child(th)
	no.add_child(tagp)
	bv.add_child(no)
	var title: Label = ScrKit.para(ScrKit.stage_title(st), 50, Lane1Pal.INK, true)
	title.name = "Title"
	bv.add_child(title)
	var line_txt: String = str(st.get("villainLine", "")).trim_prefix("\"").trim_suffix("\"")
	if not line_txt.is_empty():
		var lp: PanelContainer = ScrKit.panel(ScrKit.sb(Color.WHITE, 26, 4, 6, Lane1Pal.INK, Vector4(26, 10, 26, 12)))
		lp.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		var lh: HBoxContainer = ScrKit.hbox(4)
		lh.add_child(ScrKit.lbl("“", 34, Lane1Pal.RED, true))
		var ll: Label = ScrKit.lbl(line_txt, 26, Lane1Pal.INK, false)
		ll.name = "Line"
		lh.add_child(ll)
		lh.add_child(ScrKit.lbl("”", 34, Lane1Pal.RED, true))
		lp.add_child(lh)
		bv.add_child(lp)
	var blurb: Label = ScrKit.para(str(st.get("blurb", "")), 21, Color("#4a5360"))
	bv.add_child(blurb)
	bv.add_child(_jam_row(st))
	if st.get("honkOnly") == true:
		var hp: PanelContainer = ScrKit.panel(ScrKit.sb(Color("#fff0b8"), 14, 3, 0, Lane1Pal.INK, Vector4(12, 6, 12, 6)))
		var hh: HBoxContainer = ScrKit.hbox(8)
		hh.alignment = BoxContainer.ALIGNMENT_CENTER
		hh.add_child(ScrKit.icon("horn", 26))
		hh.add_child(ScrKit.lbl("구조 상황 · 압정 금지 · 경적으로 깨우기", 20, Lane1Pal.INK, true))
		hp.add_child(hh)
		bv.add_child(hp)
	if not road.is_empty():
		var rm: MarginContainer = ScrKit.margin(14, 10, 14, 0)
		rm.add_child(_road(road))
		v.add_child(rm)
	if not ms.is_empty():
		var mm: MarginContainer = ScrKit.margin(14, 12, 14, 0)
		mm.add_child(missions_box(ms, false, []))
		v.add_child(mm)
	_tap = ScrKit.lbl("탭하여 바로 시작", 19, Color("#8a8f98"), false)
	_tap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var tm: MarginContainer = ScrKit.margin(0, 10, 0, 12)
	tm.add_child(_tap)
	v.add_child(tm)
	_timer_bar = ScrKit.bar(0.0, Lane1Pal.AMBER, 12)
	_timer_bar.name = "Timer"
	_timer_bar.track = Color("#eadfc4")
	v.add_child(_timer_bar)
	# ✕ back (native extra)
	var x: ScrKit.Pill = ScrKit.round_btn("close", Lane1Pal.BTN_GREY, 56)
	x.name = "Close"
	x.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	ScrKit.tap(x, func() -> void:
		if not started:
			started = true
			close())
	x.mouse_filter = Control.MOUSE_FILTER_STOP   # keep the press from reaching the card (which would start)
	safe.add_child(x)
	x.offset_left = -76
	x.offset_right = -20
	x.offset_top = 8
	x.offset_bottom = 64


static func _case(ck: String) -> Dictionary:
	var cards: Dictionary = (ScrProgressStub._json("res://data/cards.json") as Dictionary).get("cases", {})
	return cards.get(ck, {})


## Green highway sign header (.ui-sign--card / --result): shield + highway + direction ▶.
static func road_sign(st: Dictionary, shield_w: int, size: int, one_line: bool = false) -> PanelContainer:
	var s: StyleBoxFlat = ScrKit.sb(Lane1Pal.GREEN, 0, 0, 0, Lane1Pal.INK, Vector4(8, 8, 8, 8))
	s.corner_radius_top_left = 25
	s.corner_radius_top_right = 25
	s.border_width_bottom = 5
	var p: PanelContainer = ScrKit.panel(s)
	p.name = "Sign"
	var inner: PanelContainer = ScrKit.panel(ScrKit.sb(Color(0, 0, 0, 0), 14, 4, 0, Color.WHITE, Vector4(18, 10, 18, 10)))
	p.add_child(inner)
	var h: HBoxContainer = ScrKit.hbox(14)
	if one_line:
		h.alignment = BoxContainer.ALIGNMENT_CENTER
	inner.add_child(h)
	h.add_child(ScrKit.shield(st.get("route"), shield_w))
	if one_line:
		h.add_child(ScrKit.lbl("%s · %s" % [str(st.get("highway", "")), str(st.get("direction", ""))], size, Color.WHITE, true, 0, 3))
	else:
		var v: VBoxContainer = ScrKit.vbox(0)
		v.alignment = BoxContainer.ALIGNMENT_CENTER
		v.add_child(ScrKit.lbl(str(st.get("highway", "")), size, Color.WHITE, true, 0, 3))
		v.add_child(ScrKit.lbl(str(st.get("direction", "")) + "  ▶", roundi(size * 0.64), Color.WHITE, true, 0, 2))
		h.add_child(v)
	return p


func _jam_row(st: Dictionary) -> Control:
	var p: PanelContainer = ScrKit.panel(ScrKit.sb(Color("#262d38"), 26, 4, 6, Lane1Pal.INK, Vector4(18, 8, 22, 10)))
	p.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var h: HBoxContainer = ScrKit.hbox(14)
	p.add_child(h)
	var tag: PanelContainer = ScrKit.chip("정체", Lane1Pal.RED, Color.WHITE, 21, 3, 10)
	tag.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(tag)
	var km: Label = ScrKit.lbl("%skm" % str(st.get("displayKm", "?")), 44, Lane1Pal.AMBER, true, 0, 3)
	km.name = "JamKm"
	h.add_child(km)
	if st.get("villainSpeedLabel") != null:
		h.add_child(ScrKit.lbl("원흉 %s" % str(st["villainSpeedLabel"]), 19, Color(1, 1, 1, 0.88), false))
	return p


## main.js roadInfo + ui.js normRoad: {sh, hk, sp, hint} or {} when nothing to show.
static func road_info(st: Dictionary) -> Dictionary:
	var a: Dictionary = st.get("approach", {}) if st.get("approach") is Dictionary else {}
	var sh: String = str(a.get("shoulder", "")) if SvgArt.ROAD["sh"].has(str(a.get("shoulder", ""))) else ""
	var hk: String = str(a.get("honk", "")) if SvgArt.ROAD["hk"].has(str(a.get("honk", ""))) else ""
	var sp: String = "구조 상황 · 압정 금지" if st.get("honkOnly") == true else ("보스" if st.get("boss") == true else ("엘리트" if st.get("elite") == true else ""))
	var hint: String = str(a.get("hint", "")).strip_edges().substr(0, 60)
	if hint.is_empty():
		hint = ("이번 판 경적 = " + str(SvgArt.ROAD["hk"][hk]["short"])) if not hk.is_empty() else (("이번 판 갓길 = " + str(SvgArt.ROAD["sh"][sh]["short"])) if not sh.is_empty() else "")
	if sh.is_empty() and hk.is_empty() and sp.is_empty() and hint.is_empty():
		return {}
	return {"sh": sh, "hk": hk, "sp": sp, "hint": hint}


func _road(rd: Dictionary) -> Control:
	var p: PanelContainer = ScrKit.panel(ScrKit.sb(Color("#dfe6ee"), 24, 4, 6, Lane1Pal.INK, Vector4(14, 12, 14, 14)))
	p.name = "Road"
	var v: VBoxContainer = ScrKit.vbox(10)
	p.add_child(v)
	var head: HBoxContainer = ScrKit.hbox(8)
	var tag: PanelContainer = ScrKit.panel(ScrKit.sb(Lane1Pal.INK, 16, 0, 0, Lane1Pal.INK, Vector4(8, 3, 14, 3)))
	var th: HBoxContainer = ScrKit.hbox(6)
	th.add_child(ScrKit.icon("road", 26))
	th.add_child(ScrKit.lbl("도로 상황", 22, Color.WHITE, true))
	tag.add_child(th)
	head.add_child(tag)
	head.add_child(ScrKit.spacer())
	head.add_child(ScrKit.lbl("판마다 규칙이 달라요", 18, Color("#5a6372"), false))
	v.add_child(head)
	var tiles: HBoxContainer = ScrKit.hbox(10)
	if not str(rd["sh"]).is_empty():
		var m: Dictionary = SvgArt.ROAD["sh"][rd["sh"]]
		tiles.add_child(_road_tile("갓길", str(m["label"]), str(m["tone"]), str(m["svg"])))
	if not str(rd["hk"]).is_empty():
		var m2: Dictionary = SvgArt.ROAD["hk"][rd["hk"]]
		tiles.add_child(_road_tile("경적", str(m2["label"]), str(m2["tone"]), str(m2["svg"])))
	if not str(rd["sp"]).is_empty():
		tiles.add_child(_road_tile("특수", str(rd["sp"]), "warn", str(SvgArt.ROAD["sp"].get(rd["sp"], SvgArt.ROAD["sp"]["보스"]))))
	if tiles.get_child_count() > 0:
		v.add_child(tiles)
	if not str(rd["hint"]).is_empty():
		v.add_child(ScrTitle.vms(str(rd["hint"]), 21, true))
	return p


func _road_tile(kind: String, label: String, tone: String, svg: String) -> Control:
	var p: PanelContainer = ScrKit.panel(ScrKit.sb(Color.WHITE, 18, 4, 5, Lane1Pal.INK, Vector4(8, 10, 8, 10)))
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var v: VBoxContainer = ScrKit.vbox(4)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	p.add_child(v)
	var ic: TextureRect = ScrKit.svg_rect(svg, Vector2(60, 60))
	ic.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	v.add_child(ic)
	var col: Color = Lane1Pal.GREEN_HI if tone == "ok" else (Lane1Pal.RED if tone == "bad" else Color("#f09a00"))
	var c: PanelContainer = ScrKit.chip(kind, col, Color.WHITE, 16, 0, 8)
	c.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	v.add_child(c)
	var l: Label = ScrKit.para(label, 20, Lane1Pal.INK, true)
	v.add_child(l)
	return p


## ★ 미션 box (card preview and result checklist share it). done[i] → ✔ / ✖ marks when `result`.
static func missions_box(ms: Array, result: bool, done: Array) -> PanelContainer:
	var p: PanelContainer = ScrKit.panel(ScrKit.sb(Color("#fff0c2") if not result else Color.WHITE, 24, 4, 6, Lane1Pal.INK, Vector4(14, 12, 14, 14)))
	p.name = "Missions"
	var v: VBoxContainer = ScrKit.vbox(10)
	p.add_child(v)
	if not result:
		var head: HBoxContainer = ScrKit.hbox(8)
		var tag: PanelContainer = ScrKit.panel(ScrKit.sb(Lane1Pal.INK, 16, 0, 0, Lane1Pal.INK, Vector4(8, 3, 14, 3)))
		var th: HBoxContainer = ScrKit.hbox(6)
		th.add_child(ScrKit.icon("star_on", 26))
		th.add_child(ScrKit.lbl("별 미션", 22, Color.WHITE, true))
		tag.add_child(th)
		head.add_child(tag)
		head.add_child(ScrKit.spacer())
		head.add_child(ScrKit.lbl("하나 달성할 때마다 ★ 1개", 18, Color("#9a7b2a"), false))
		v.add_child(head)
	var row: HBoxContainer = ScrKit.hbox(10)
	v.add_child(row)
	for i: int in mini(3, ms.size()):
		var d: bool = i < done.size() and bool(done[i])
		var item: PanelContainer = ScrKit.panel(ScrKit.sb(Color.WHITE, 18, 4, 5, Lane1Pal.INK, Vector4(6, 8, 6, 10)))
		item.name = "Mission%d" % i
		item.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var iv: VBoxContainer = ScrKit.vbox(2)
		iv.alignment = BoxContainer.ALIGNMENT_CENTER
		item.add_child(iv)
		var star := Control.new()
		star.custom_minimum_size = Vector2(54, 54)
		star.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		star.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var si: TextureRect = ScrKit.icon("star_on" if not result or d else "star_off", 54)
		si.name = "Star"
		si.set_anchors_preset(Control.PRESET_FULL_RECT)
		star.add_child(si)
		var n: Label = ScrKit.lbl(str(i + 1), 22, Color.WHITE, true, 4, 0)
		n.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		n.set_anchors_preset(Control.PRESET_FULL_RECT)
		n.offset_top = 4
		star.add_child(n)
		iv.add_child(star)
		var l: Label = ScrKit.para(str((ms[i] as Dictionary).get("label", "")), 20, Lane1Pal.INK)
		l.name = "Label"
		iv.add_child(l)
		if result:
			item.set_meta(&"done", d)
			var mark: TextureRect = ScrKit.icon("check" if d else "cross", 38)
			mark.name = "Mark"
			mark.visible = false
			mark.set_anchors_preset(Control.PRESET_TOP_RIGHT)
			var holder := Control.new()
			holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
			holder.add_child(mark)
			mark.offset_left = -26
			mark.offset_right = 12
			mark.offset_top = -18
			mark.offset_bottom = 20
			item.add_child(holder)
			si.visible = false
		row.add_child(item)
	return p


## Shrinks the panel to fit short screens (long rescue / boss cards on a 16:9 phone) instead of clipping its top.
func _fit() -> void:
	if _panel == null or safe == null:
		return
	var avail: float = safe.size.y - 36.0
	var k: float = minf(1.0, avail / maxf(1.0, _panel.size.y))
	_panel.pivot_offset = _panel.size * 0.5
	_panel.scale = Vector2.ONE * k


func _process(delta: float) -> void:
	_fit()
	if started:
		return
	elapsed += delta
	if _timer_bar != null:
		_timer_bar.frac = clampf(elapsed / maxf(0.01, duration), 0.0, 1.0)
		_timer_bar.queue_redraw()
	if _tap != null:
		_tap.modulate.a = 0.55 + 0.45 * absf(sin(elapsed * 2.6))
	if auto_start and elapsed >= duration:
		start()


func _gui_input(ev: InputEvent) -> void:
	var mb := ev as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and elapsed >= ARM_S:
		ScrKit.feedback("uiConfirm")
		start()


## Emits start_requested once (tap, timer or the app).
func start() -> void:
	if started:
		return
	started = true
	start_requested.emit(stage_id)
