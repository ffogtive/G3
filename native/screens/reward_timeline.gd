class_name ScrReward
extends ScrScreen
## Result reward timeline (ui.js showRewardResult · TL · popMissions · countScore · resultButtons · mileTier,
## main.js showResult; NATIVE_PARITY A17). Web timings (ms after open):
##   stamp 280 · mission i 700 + 380·i (+ star sfx pitch 1 / 1.25 / 1.5) · SCORE count 450→1600 · money 1750
##   (payout count 1900→2700) · wallet 2150→3050 · channel 2250 (views/subs count 2370→3370) · comment k 2450 + 150·k
##   · milestone 2600 (auto close +4200) · unlock toast 3100 (native).
## Every value is a pure function of `t`, so advance(dt) in tests reproduces the timeline exactly; `events` logs
## [name, t_ms] in firing order. Buttons: 다음 빌런 ▶ (처음부터 on the last stage) / 다시하기 / 메뉴.

signal next_requested(id: int)
signal retry_requested(id: int)
signal menu_requested

const TL: Dictionary = {"stamp": 280, "money": 1750, "wallet": 2150, "chan": 2250, "cmt": 2450, "mile": 2600, "unlock": 3100}
const NICKS: PackedStringArray = ["고속도로지킴이", "1차선은추월차선", "경부선출퇴근러", "비상등깜빡깜빡", "블박장인", "사이다중독자",
	"정체혐오자", "졸음쉼터단골", "톨게이트요정", "화물차기사24년", "서해안안개맨", "대관령눈길러", "귀성길생존자", "깜빡이켜는사람",
	"도로위평화주의자", "휴게소호두과자"]
const CASE_NOTE: Dictionary = {"crime": "벌금은 국고로 · 포상금은 제보 기준액 × ★", "rescue": "범칙금 대신 구조 포상금 × ★",
	"warn": "계도라 범칙금 0원 · 기본 포상금 × ★"}

var stage_id: int = 1
var result: Dictionary = {}
## Progress.record_result() return value.
var reward: Dictionary = {}
var manual: bool = false
var t: float = 0.0
var events: Array = []
## Override the dash-cam clock (tests / shots); empty = system time.
var clock: Dictionary = {}
var _due: Array = []
var _st: Dictionary = {}
var _sections: Array = []   # [Control, appear_ms]
var _score_l: Label
var _pay_l: Label
var _total_l: Label
var _views_l: Label
var _gain_l: Label
var _stamp: Control
var _mis_items: Array = []
var _mile: Control
var _toast: Control
var _scroll: ScrollContainer
var _fx: Control


func build() -> void:
	_st = meta.stage(stage_id)
	var ck: String = str(reward["case"]) if reward.has("case") else ScrKit.case_kind(reward.get("card", _st.get("card")))
	var cases: Dictionary = (ScrProgressStub._json("res://data/cards.json") as Dictionary).get("cases", {})
	var CK: Dictionary = cases.get(ck, {})
	var stars_n: int = int(reward.get("stars", 0))
	var payout: int = int(reward.get("payout", 0))
	var fine: int = int(reward.get("fine", _st.get("fine", 0)))
	var views: int = int(reward.get("views", 0))
	var sid: int = stage_id
	var seed: int = absi(sid) * 7 + (views % 13)
	add_child(ScrKit.dim(0.35))
	move_child(get_child(get_child_count() - 1), 0)
	var m: MarginContainer = ScrKit.margin(14, 12, 14, 12)
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	safe.add_child(m)
	var panel: PanelContainer = ScrKit.panel(ScrKit.sb(Lane1Pal.CREAM, 30, 5, 10, Lane1Pal.INK, Vector4(0, 0, 0, 0)))
	panel.name = "ResultPanel"
	m.add_child(panel)
	var v: VBoxContainer = ScrKit.vbox(0)
	panel.add_child(v)
	v.add_child(ScrStageCard.road_sign(_st, 40, 32, true))
	_scroll = ScrollContainer.new()
	_scroll.name = "Scroll"
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	v.add_child(_scroll)
	var sm: MarginContainer = ScrKit.margin(14, 14, 14, 14)
	sm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(sm)
	var col: VBoxContainer = ScrKit.vbox(14)
	sm.add_child(col)
	col.add_child(_dash(ck, CK, fine))
	var stats: Array = reward.get("stats", []) if reward.get("stats") is Array and not (reward["stats"] as Array).is_empty() \
		else (result.get("stats", []) if result.get("stats") is Array else [])
	var hero: Dictionary = {}
	var rest: Array = []
	for i: int in stats.size():
		var s: Dictionary = stats[i]
		if i == 0 and str(s.get("value", "")).ends_with("%"):
			hero = s
		else:
			rest.append(s)
	col.add_child(_rate(hero))
	var money: Control = _money(ck, CK, fine, payout)
	col.add_child(money)
	_sections.append([money, TL["money"]])
	var chan: Control = _channel(ck, views, seed)
	col.add_child(chan)
	_sections.append([chan, TL["chan"]])
	if not rest.is_empty():
		col.add_child(_stats(rest))   # phone layout (style.css ≤640px): .ui-stats--mini is order 5, after the channel
	v.add_child(_buttons())
	_fx = Control.new()
	_fx.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fx.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_fx)
	# schedule
	_at(0, "open", func() -> void: ScrKit.sfx("stageClear"))
	_at(TL["stamp"], "stamp", _show_stamp)
	for i: int in _mis_items.size():
		var k: int = i
		_at(700 + 380 * i, "mission%d" % i, func() -> void: _pop_mission(k))
	_at(1600, "score_done", func() -> void: ScrKit.bump(_score_l, 1.12, 260.0))
	_at(TL["money"], "money", func() -> void: pass)
	_at(2700, "payout_done", func() -> void: ScrKit.bump(_pay_l, 1.12, 240.0))
	_at(TL["wallet"], "wallet", func() -> void: pass)
	_at(3050, "wallet_done", func() -> void: ScrKit.bump(_total_l, 1.12, 260.0))
	_at(TL["chan"], "chan", _peek_channel)
	var cmts: int = (reward.get("comments", []) as Array).size() if reward.get("comments") is Array or reward.get("comments") is PackedStringArray else 0
	for k: int in mini(3, cmts):
		_at(TL["cmt"] + 150 * k, "cmt%d" % k, func() -> void: pass)
	if not str(reward.get("milestone", "")).is_empty():
		_at(TL["mile"], "mile", _show_mile)
		_at(TL["mile"] + 4200, "mile_close", _close_mile)
	if not _unlocks().is_empty():
		_at(TL["unlock"], "unlock", _show_unlock)
	_due.sort_custom(func(a: Array, b: Array) -> bool: return int(a[0]) < int(b[0]))
	_update()


func _at(ms: int, name: String, fn: Callable) -> void:
	_due.append([ms, name, fn])


func _process(delta: float) -> void:
	if not manual:
		advance(delta)


## Moves the timeline forward by dt seconds (deterministic: fires due events in order, recomputes every value).
func advance(dt: float) -> void:
	t += maxf(0.0, dt)
	var now_ms: float = t * 1000.0
	while not _due.is_empty() and float(_due[0][0]) <= now_ms + 0.001:
		var e: Array = _due.pop_front()
		events.append([str(e[1]), int(e[0])])
		(e[2] as Callable).call()
	_update()


func event_names() -> PackedStringArray:
	var out: PackedStringArray = []
	for e: Array in events:
		out.append(str(e[0]))
	return out


static func _ease(k: float) -> float:
	var c: float = clampf(k, 0.0, 1.0)
	return 1.0 - pow(1.0 - c, 3.0)


func _update() -> void:
	var ms: float = t * 1000.0
	var score: int = int(reward.get("score", result.get("score", 0)))
	_score_l.text = ScrKit.fmt(score * _ease((ms - 450.0) / 1150.0))
	var payout: int = int(reward.get("payout", 0))
	_pay_l.text = "+" + ScrKit.won(payout * _ease((ms - 1900.0) / 800.0))
	var wallet: int = int(reward.get("wallet", payout))
	_total_l.text = ScrKit.won(wallet - payout + payout * _ease((ms - float(TL["wallet"])) / 900.0))
	var k: float = _ease((ms - 2370.0) / 1000.0)
	_views_l.text = ScrKit.kor(int(reward.get("views", 0)) * k)
	_gain_l.text = "+" + ScrKit.fmt(int(reward.get("subs_gained", reward.get("subs_gain", 0))) * k)
	for s: Array in _sections:
		var c: Control = s[0]
		var a: float = clampf((ms - float(s[1])) / 250.0, 0.0, 1.0)
		c.modulate.a = a
	var stg: Control = find("Stats")
	if stg != null:
		for i: int in stg.get_child_count():
			(stg.get_child(i) as Control).modulate.a = clampf((ms - 850.0 - 70.0 * i) / 350.0, 0.0, 1.0)
	var cm: Control = find("Comments")
	if cm != null:
		for i: int in cm.get_child_count():
			(cm.get_child(i) as Control).modulate.a = clampf((ms - float(TL["cmt"] + 150 * i)) / 220.0, 0.0, 1.0)


# ───────────────────────────── sections
func _section(bg: Color = Color.WHITE) -> PanelContainer:
	return ScrKit.panel(ScrKit.sb(bg, 24, 4, 6, Lane1Pal.INK, Vector4(16, 14, 16, 16)))


func _now() -> Dictionary:
	return clock if not clock.is_empty() else Time.get_datetime_dict_from_system()


func _dash(ck: String, CK: Dictionary, fine: int) -> Control:
	var p: PanelContainer = _section()
	p.name = "Dash"
	var v: VBoxContainer = ScrKit.vbox(10)
	p.add_child(v)
	var d: Dictionary = _now()
	var no: String = "%04d%02d%02d-%03d" % [int(d["year"]), int(d["month"]), int(d["day"]), absi(stage_id)]
	var head: HBoxContainer = ScrKit.hbox(8)
	head.add_child(ScrKit.icon("cam", 30))
	head.add_child(ScrKit.lbl("블박 구조 기록" if ck == "rescue" else "블박 제보 접수", 24, Lane1Pal.INK, true))
	head.add_child(ScrKit.spacer())
	head.add_child(ScrKit.lbl("No." + no, 17, Lane1Pal.MUTED, false))
	v.add_child(head)
	# camera screen
	var cam := Control.new()
	cam.name = "Cam"
	cam.custom_minimum_size = Vector2(0, 250)
	cam.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var frame: PanelContainer = ScrKit.panel(ScrKit.sb(Color("#11161e"), 16, 5, 0, Lane1Pal.INK, Vector4(0, 0, 0, 0)))
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
	cam.add_child(frame)
	var photo: Texture2D = ScrAlbum.photo_tex(result.get("photo"))
	var art: TextureRect = ScrKit.tex_rect(photo, Vector2(10, 10)) if photo != null else ScrKit.svg_rect(ScrKit.dash_svg(ScrKit.villain_hex(_st), stage_id, false), Vector2(460, 250), true)
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	art.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.add_child(art)
	var scan := Control.new()
	scan.set_anchors_preset(Control.PRESET_FULL_RECT)
	scan.mouse_filter = Control.MOUSE_FILTER_IGNORE
	scan.draw.connect(func() -> void:
		var y: float = 0.0
		while y < scan.size.y:
			scan.draw_line(Vector2(0, y), Vector2(scan.size.x, y), Color(0, 0, 0, 0.12), 1.0)
			y += 3.0)
	frame.add_child(scan)
	var tl: HBoxContainer = ScrKit.hbox(6)
	var dot := Control.new()
	dot.custom_minimum_size = Vector2(14, 14)
	dot.draw.connect(func() -> void: dot.draw_circle(Vector2(7, 7), 6, Lane1Pal.RED))
	tl.add_child(dot)
	tl.add_child(ScrKit.lbl("REC  %04d.%02d.%02d %02d:%02d:%02d" % [int(d["year"]), int(d["month"]), int(d["day"]), int(d["hour"]), int(d["minute"]), int(d["second"])], 17, Color.WHITE, true, 3, 0))
	tl.position = Vector2(14, 10)
	cam.add_child(tl)
	var tr: Label = ScrKit.lbl("FRONT  충격감지", 17, Lane1Pal.GOLD_TXT, true, 3, 0)
	tr.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	tr.offset_left = -170
	tr.offset_right = -14
	tr.offset_top = 10
	tr.offset_bottom = 34
	tr.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	cam.add_child(tr)
	var vs: Array = _st.get("villains", [])
	var lane: int = clampi(int((vs[0] as Dictionary).get("lane", 0)) + 1, 1, 4) if not vs.is_empty() else 1
	var m: RegExMatch = RegEx.create_from_string("(\\d+)\\s*km").search(str(_st.get("villainSpeedLabel", "")))
	var vspd: int = m.get_string(1).to_int() if m != null else 0
	var spd: int = int(result.get("speed_kmh", vspd + 9 + absi(stage_id) % 5 if vspd > 0 else 92 + (absi(stage_id) * 7) % 30))
	var bl: HBoxContainer = ScrKit.hbox(8)
	bl.add_child(ScrKit.lbl("%d" % spd, 34, Lane1Pal.GOLD_TXT, true, 4, 0))
	bl.add_child(ScrKit.lbl("km/h", 18, Color.WHITE, true, 3, 0))
	bl.add_child(ScrKit.chip("%d차로" % lane, Color(0, 0, 0, 0.5), Color.WHITE, 17, 2, 8))
	bl.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	bl.offset_left = 14
	bl.offset_top = -52
	bl.offset_bottom = -10
	bl.offset_right = 300
	cam.add_child(bl)
	v.add_child(cam)
	# foot + stamp
	var foot := HBoxContainer.new()
	foot.add_theme_constant_override(&"separation", 8)
	var fv: VBoxContainer = ScrKit.vbox(4)
	fv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fv.add_child(ScrKit.lbl("구조 차량" if ck == "rescue" else "위반 차량", 18, Color("#9a7b2a"), false))
	var vn: Label = ScrKit.lbl(str(reward.get("villain_name", ScrKit.villain_names(_st))), 27, Lane1Pal.INK, true)
	vn.name = "Villain"
	vn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vn.custom_minimum_size.x = 10
	if ck != "rescue":
		vn.draw.connect(func() -> void: vn.draw_line(Vector2(0, vn.size.y * 0.55), Vector2(vn.size.x, vn.size.y * 0.5), Color(Lane1Pal.RED, 0.85), 5.0))
	fv.add_child(vn)
	var cause: String = str(reward.get("cause", _st.get("cause", "")))
	if not cause.is_empty():
		fv.add_child(ScrKit.lbl(("구조 사유 · " if ck == "rescue" else "제보 사유 · ") + cause, 17, Lane1Pal.MUTED, false))
	var done: HBoxContainer = ScrKit.hbox(6)
	done.add_child(ScrKit.icon("check", 26))
	done.add_child(ScrKit.lbl("처리 결과: " + str(CK.get("done", "참교육 완료")), 20, Lane1Pal.GREEN, true))
	fv.add_child(done)
	foot.add_child(fv)
	_stamp = _fine_stamp(ck, CK, fine)
	foot.add_child(_stamp)
	v.add_child(foot)
	return p


func _fine_stamp(ck: String, CK: Dictionary, fine: int) -> Control:
	var col: Color = Color(str(Lane1Pal.CASE_COLOR.get(ck, "#ff3b30")))
	var holder := Control.new()
	holder.name = "Stamp"
	holder.custom_minimum_size = Vector2(250, 150)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var p: PanelContainer = ScrKit.panel(ScrKit.sb(Color(1, 1, 1, 0.95), 10, 5, 0, col, Vector4(14, 8, 14, 10)))
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var v: VBoxContainer = ScrKit.vbox(3)
	p.add_child(v)
	var title: Label = ScrKit.lbl(str(CK.get("stamp", "과태료 고지서")), 30, col, true)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(title)
	var line := ColorRect.new()
	line.color = col
	line.custom_minimum_size = Vector2(0, 3)
	v.add_child(line)
	var viol: String = "잠든·고장난 운전자를 경적으로 깨워 안전 유도" if ck == "rescue" else str(reward.get("violation", _st.get("violation", "도로교통법 위반")))
	var vl: Label = ScrKit.para(viol, 16, col.darkened(0.15), false)
	vl.custom_minimum_size.x = 210
	v.add_child(vl)
	var amt: String = "시민 구조 유공" if ck == "rescue" else ("범칙금 없음 · 계도" if ck == "warn" else "%s %s" % [str(CK.get("amt", "범칙금")), ScrKit.big_won(fine) if ck == "crime" else ScrKit.won(fine)])
	var al: Label = ScrKit.lbl(amt, 24, col, true)
	al.name = "Amount"
	al.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(al)
	p.position = Vector2(4, 4)
	p.rotation = -0.09
	holder.add_child(p)
	var seal: Array = CK.get("seal", ["참교", "육청"])
	var sp: PanelContainer = ScrKit.panel(ScrKit.sb(col, 10, 3, 0, Color.WHITE, Vector4(4, 2, 4, 2)))
	sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sv: VBoxContainer = ScrKit.vbox(-4)
	for s: Variant in seal:
		var sl: Label = ScrKit.lbl(str(s), 14, Color.WHITE, true)
		sl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		sv.add_child(sl)
	sp.add_child(sv)
	sp.position = Vector2(206, -14)
	sp.rotation = 0.2
	holder.add_child(sp)
	holder.modulate.a = 0.0
	return holder


func _show_stamp() -> void:
	_stamp.modulate.a = 1.0
	_stamp.pivot_offset = _stamp.size * 0.5
	_stamp.scale = Vector2.ONE * 1.6
	var tw: Tween = _stamp.create_tween()
	tw.tween_property(_stamp, "scale", Vector2.ONE, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	ScrKit.sfx("pop")


## .ui-stats--mini: 3-column grid of white tiles (label 11.5px over value 15px), each fading in at 850 + 70·i ms.
func _stats(rows: Array) -> Control:
	var g := GridContainer.new()
	g.name = "Stats"
	g.columns = 3
	g.add_theme_constant_override(&"h_separation", 8)
	g.add_theme_constant_override(&"v_separation", 8)
	for s: Dictionary in rows:
		var tile: PanelContainer = ScrKit.panel(ScrKit.sb(Color.WHITE, 15, 3, 4, Lane1Pal.INK, Vector4(12, 6, 12, 7)))
		tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var tv: VBoxContainer = ScrKit.vbox(1)
		tv.alignment = BoxContainer.ALIGNMENT_CENTER
		var l: Label = ScrKit.lbl(str(s.get("label", "")), 16, Color("#5a6270"), false)
		var v: Label = ScrKit.lbl(str(s.get("value", "")), 21, Lane1Pal.INK, true)
		v.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
		v.custom_minimum_size.x = 10
		tv.add_child(l)
		tv.add_child(v)
		tile.add_child(tv)
		g.add_child(tile)
	return g


func _rate(hero: Dictionary) -> Control:
	var p: PanelContainer = _section()
	p.name = "Rate"
	var v: VBoxContainer = ScrKit.vbox(10)
	p.add_child(v)
	var ms: Array = reward.get("missions", []) if reward.get("missions") is Array and not (reward["missions"] as Array).is_empty() else meta.missions_for(stage_id)
	var done: Array = reward.get("missions_done", result.get("missions_done", []))
	var box: PanelContainer = ScrStageCard.missions_box(ms, true, done)
	box.add_theme_stylebox_override(&"panel", StyleBoxEmpty.new())
	v.add_child(box)
	_mis_items.clear()
	for i: int in 3:
		var it: Node = box.find_child("Mission%d" % i, true, false)
		if it != null:
			_mis_items.append(it)
	var row: HBoxContainer = ScrKit.hbox(10)
	row.add_child(ScrKit.lbl("SCORE", 26, Color("#9a7b2a"), true))
	row.add_child(ScrKit.spacer())
	_score_l = ScrKit.lbl("0", 52, Color.WHITE, true, 7, 4)
	_score_l.name = "Score"
	row.add_child(_score_l)
	v.add_child(row)
	if not hero.is_empty():
		var hr: HBoxContainer = ScrKit.hbox(10)
		hr.add_child(ScrKit.lbl(str(hero.get("label", "")), 19, Lane1Pal.MUTED, false))
		hr.add_child(ScrKit.lbl(str(hero.get("value", "")), 26, Lane1Pal.GREEN_HI, true))
		var b: ScrKit.Bar = ScrKit.bar(str(hero.get("value", "0")).to_float() / 100.0, Lane1Pal.GREEN_HI, 14)
		b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		hr.add_child(b)
		v.add_child(hr)
	if bool(reward.get("is_last", false)):
		v.add_child(ScrKit.para("전 구간 소통 원활! 모든 빌런 참교육 완료", 22, Lane1Pal.GREEN, true))
	return p


func _pop_mission(i: int) -> void:
	var it: Control = _mis_items[i]
	var d: bool = bool(it.get_meta(&"done", false))
	var st: Node = it.find_child("Star", true, false)
	if st != null:
		(st as Control).visible = true
	var mk: Node = it.find_child("Mark", true, false)
	if mk != null:
		(mk as Control).visible = true
	var sb: StyleBoxFlat = ScrKit.sb(Color("#e6f8ee") if d else Color("#eef0f3"), 18, 4, 5, Lane1Pal.INK, Vector4(6, 8, 6, 10))
	(it as PanelContainer).add_theme_stylebox_override(&"panel", sb)
	if d:
		ScrKit.bump(it, 1.12, 300.0)
		ScrKit.sfx("star", {"pitch": 1.0 + i * 0.25})
	else:
		ScrKit.shake(it, 360.0)
		(it.find_child("Label", true, false) as Label).modulate.a = 0.55


func _money(ck: String, CK: Dictionary, fine: int, payout: int) -> Control:
	var p: PanelContainer = _section()
	p.name = "Money"
	var v: VBoxContainer = ScrKit.vbox(10)
	p.add_child(v)
	var flow: HBoxContainer = ScrKit.hbox(6)
	var fbox: PanelContainer = ScrKit.panel(ScrKit.sb(Color("#ffe9e6"), 16, 4, 4, Lane1Pal.INK, Vector4(10, 8, 10, 10)))
	fbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var fv: VBoxContainer = ScrKit.vbox(2)
	var cap: String = "구조 표창 · 시민 유공" if ck == "rescue" else ("계도 · 범칙금 없음" if ck == "warn" else "%s (실제) · 빌런 부담" % str(CK.get("amt", "범칙금")))
	fv.add_child(ScrKit.ellipsis(ScrKit.lbl(cap, 15, Lane1Pal.RED_LO, false)))
	fv.add_child(ScrKit.lbl("표창장" if ck == "rescue" else (ScrKit.won(0) if ck == "warn" else (ScrKit.big_won(fine) if ck == "crime" else ScrKit.won(fine))), 30, Lane1Pal.RED_LO, true, 0, 2))
	fbox.add_child(fv)
	flow.add_child(fbox)
	var av: VBoxContainer = ScrKit.vbox(0)
	av.alignment = BoxContainer.ALIGNMENT_CENTER
	av.add_child(ScrKit.svg_rect("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 44 24\"><path d=\"M3 8.5h24V3l14 9-14 9v-5.5H3z\" fill=\"#fff\" stroke=\"#17202b\" stroke-width=\"2.6\" stroke-linejoin=\"round\"/></svg>", Vector2(52, 28)))
	var mult: float = float(reward.get("star_mult", [1.0, 1.0, 1.5, 2.0][clampi(int(reward.get("stars", 0)), 0, 3)]))
	var ml: Label = ScrKit.lbl("★×%s" % (str(int(mult)) if is_equal_approx(mult, roundf(mult)) else str(mult)), 18, Color("#d99a00"), true)
	ml.name = "Mult"
	ml.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	av.add_child(ml)
	flow.add_child(av)
	var pbox: PanelContainer = ScrKit.panel(ScrKit.sb(Lane1Pal.GREEN_HI, 16, 4, 4, Lane1Pal.INK, Vector4(10, 8, 10, 10)))
	pbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var pv: VBoxContainer = ScrKit.vbox(2)
	pv.add_child(ScrKit.lbl("포상금 · 내가 받는 돈", 15, Color("#dcffe9"), false))
	_pay_l = ScrKit.lbl("+₩0", 32, Lane1Pal.GOLD_TXT, true, 5, 3)
	_pay_l.name = "Payout"
	pv.add_child(_pay_l)
	pbox.add_child(pv)
	flow.add_child(pbox)
	v.add_child(flow)
	if CASE_NOTE.has(ck):
		v.add_child(ScrKit.para(str(CASE_NOTE[ck]), 17, Lane1Pal.MUTED))
	var bonus: int = int(reward.get("bonus", 0))
	var base: float = float(reward.get("base", _st.get("payout", _st.get("fine", 0))))
	var extra: float = float(payout) / maxf(1.0, base * mult + float(bonus)) if base > 0.0 else 1.0
	var extra_pct: int = roundi((extra - 1.0) * 100.0) if extra > 1.08 else 0
	if bonus > 0 or extra_pct > 0:
		var txt: String = ""
		if bonus > 0:
			txt += "+ 잔챙이·얌체 신고 보너스 %s" % ScrKit.won(bonus)
		if extra_pct > 0:
			txt += (" · " if bonus > 0 else "") + "블박 4K +%d%%" % extra_pct
		var bl: Label = ScrKit.para(txt + " 포함", 17, Lane1Pal.GREEN, false)
		bl.name = "Bonus"
		v.add_child(bl)
	var wp: PanelContainer = ScrKit.panel(ScrKit.sb(Lane1Pal.INK, 20, 0, 0, Lane1Pal.INK, Vector4(14, 10, 18, 10)))
	var wh: HBoxContainer = ScrKit.hbox(10)
	wh.add_child(ScrKit.icon("coin", 42))
	wh.add_child(ScrKit.lbl("보유 포상금", 22, Lane1Pal.GOLD_TXT, false))
	wh.add_child(ScrKit.spacer())
	_total_l = ScrKit.lbl("₩0", 36, Lane1Pal.GOLD_TXT, true, 0, 3)
	_total_l.name = "WalletTotal"
	wh.add_child(_total_l)
	wp.add_child(wh)
	v.add_child(wp)
	return p


func _channel(ck: String, views: int, seed: int) -> Control:
	var p: PanelContainer = _section()
	p.name = "Channel"
	var v: VBoxContainer = ScrKit.vbox(10)
	p.add_child(v)
	var head: HBoxContainer = ScrKit.hbox(10)
	var av: PanelContainer = ScrKit.panel(ScrKit.sb(Lane1Pal.YELLOW, 30, 3, 0, Lane1Pal.INK, Vector4(8, 14, 8, 14)))
	av.add_child(ScrKit.icon("car", 40))
	head.add_child(av)
	var nv: VBoxContainer = ScrKit.vbox(0)
	nv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nv.add_child(ScrKit.lbl("참교육 채널", 28, Lane1Pal.INK, true))
	nv.add_child(ScrKit.lbl("새 블박 영상 업로드 완료", 17, Lane1Pal.MUTED, false))
	head.add_child(nv)
	var sp: PanelContainer = ScrKit.panel(ScrKit.sb(Color("#ffe9e6"), 20, 3, 0, Lane1Pal.INK, Vector4(10, 4, 14, 4)))
	var sh: HBoxContainer = ScrKit.hbox(6)
	sh.add_child(ScrKit.icon("chan", 30))
	var subs_l: Label = ScrKit.lbl(ScrKit.kor(int(reward.get("subs", 0))), 24, Lane1Pal.RED, true)
	subs_l.name = "SubsTotal"
	sh.add_child(subs_l)
	sp.add_child(sh)
	head.add_child(sp)
	v.add_child(head)
	var vid: HBoxContainer = ScrKit.hbox(12)
	var thumb := Control.new()
	thumb.custom_minimum_size = Vector2(170, 100)
	thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tf: PanelContainer = ScrKit.panel(ScrKit.sb(Color("#11161e"), 12, 4, 0, Lane1Pal.INK, Vector4(0, 0, 0, 0)))
	tf.set_anchors_preset(Control.PRESET_FULL_RECT)
	tf.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
	var photo: Texture2D = ScrAlbum.photo_tex(result.get("photo"))
	var art: TextureRect = ScrKit.tex_rect(photo, Vector2(10, 10)) if photo != null else ScrKit.svg_rect(ScrKit.dash_svg(ScrKit.villain_hex(_st), stage_id, false), Vector2(170, 100), true)
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	art.set_anchors_preset(Control.PRESET_FULL_RECT)
	tf.add_child(art)
	thumb.add_child(tf)
	var dur: PanelContainer = ScrKit.chip("0:%02d" % (30 + absi(seed) % 29), Color(0, 0, 0, 0.75), Color.WHITE, 16, 0, 6)
	dur.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	dur.offset_left = -64
	dur.offset_top = -32
	dur.offset_right = -6
	dur.offset_bottom = -6
	thumb.add_child(dur)
	vid.add_child(thumb)
	var tv: VBoxContainer = ScrKit.vbox(4)
	tv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var vname: String = str(reward.get("villain_name", ScrKit.villain_names(_st)))
	var title: String = "[블박] %s %s" % [vname if not vname.is_empty() else "빌런", "구조 현장 (경적 주의)" if ck == "rescue" else ("형사 입건 현장 (사이다 주의)" if ck == "crime" else "참교육 현장 (사이다 주의)")]
	tv.add_child(ScrKit.para(title, 21, Lane1Pal.INK, true, HORIZONTAL_ALIGNMENT_LEFT))
	var stat: HBoxContainer = ScrKit.hbox(6)
	stat.add_child(ScrKit.lbl("조회수", 17, Lane1Pal.MUTED, false))
	_views_l = ScrKit.lbl("0", 24, Lane1Pal.INK, true)
	_views_l.name = "Views"
	stat.add_child(_views_l)
	stat.add_child(ScrKit.lbl("· 구독자", 17, Lane1Pal.MUTED, false))
	_gain_l = ScrKit.lbl("+0", 24, Lane1Pal.GREEN_HI, true)
	_gain_l.name = "SubsGain"
	stat.add_child(_gain_l)
	tv.add_child(stat)
	vid.add_child(tv)
	v.add_child(vid)
	var cm: VBoxContainer = ScrKit.vbox(8)
	cm.name = "Comments"
	var comments: Array = Array(reward.get("comments", []))
	for k: int in mini(3, comments.size()):
		var nick: String = NICKS[(seed + k * 5) % NICKS.size()]
		var likes: int = roundi(views * [0.012, 0.0042, 0.0016][k] * (0.8 + float((seed * (k + 3)) % 40) / 100.0)) + 3 + k
		var row: HBoxContainer = ScrKit.hbox(10)
		var avp: PanelContainer = ScrKit.panel(ScrKit.sb(Color(Lane1Pal.AV_COLORS[(seed + k * 3) % Lane1Pal.AV_COLORS.size()]), 24, 3, 0, Lane1Pal.INK, Vector4(12, 6, 12, 8)))
		avp.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		avp.add_child(ScrKit.lbl(nick.substr(0, 1), 22, Color.WHITE, true, 3, 0))
		row.add_child(avp)
		var cv: VBoxContainer = ScrKit.vbox(2)
		cv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var mh: HBoxContainer = ScrKit.hbox(8)
		mh.add_child(ScrKit.lbl("@" + nick, 17, Lane1Pal.INK, false))
		mh.add_child(ScrKit.lbl(["방금 전", "1분 전", "2분 전"][k], 15, Lane1Pal.MUTED, false))
		mh.add_child(ScrKit.spacer())
		if k == 0:
			mh.add_child(ScrKit.icon("heart", 22))
		mh.add_child(ScrKit.icon("thumb", 20))
		mh.add_child(ScrKit.lbl(ScrKit.kor(likes), 16, Lane1Pal.MUTED, false))
		cv.add_child(mh)
		cv.add_child(ScrKit.para(str(comments[k]), 20, Lane1Pal.INK, false, HORIZONTAL_ALIGNMENT_LEFT))
		row.add_child(cv)
		row.modulate.a = 0.0
		cm.add_child(row)
	v.add_child(cm)
	return p


func _peek_channel() -> void:
	# web: on a one-column phone the channel panel peeks into view when it appears (unless the user scrolled)
	if _scroll != null and _scroll.scroll_vertical == 0:
		var ch: Control = find("Channel")
		if ch != null:
			var over: float = ch.get_global_rect().position.y + minf(ch.size.y, 150.0) - _scroll.get_global_rect().end.y
			if over > 4.0:
				var tw: Tween = _scroll.create_tween()
				tw.tween_property(_scroll, "scroll_vertical", int(over + 8.0), 0.35).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)


func _buttons() -> Control:
	var m: MarginContainer = ScrKit.margin(14, 8, 14, 14)
	var s: StyleBoxFlat = ScrKit.sb(Color("#f3e7c6"), 0, 0, 0, Lane1Pal.INK, Vector4(0, 0, 0, 0))
	s.border_width_top = 4
	s.corner_radius_bottom_left = 25
	s.corner_radius_bottom_right = 25
	var p: PanelContainer = ScrKit.panel(s)
	p.add_child(m)
	var h: HBoxContainer = ScrKit.hbox(10)
	m.add_child(h)
	var last: bool = bool(reward.get("is_last", false))
	var next: ScrKit.Pill = ScrKit.pill("처음부터" if last else "다음 빌런 ▶", Lane1Pal.BTN_YELLOW, 32)
	next.name = "Next"
	next.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ScrKit.tap(next, func() -> void:
		if last:
			menu_requested.emit()
		else:
			next_requested.emit(_next_id()), "uiConfirm")
	h.add_child(next)
	var retry: ScrKit.Pill = ScrKit.pill("다시하기", Lane1Pal.BTN_BLUE, 26)
	retry.name = "Retry"
	ScrKit.tap(retry, func() -> void: retry_requested.emit(stage_id))
	h.add_child(retry)
	var menu: ScrKit.Pill = ScrKit.pill("메뉴", Lane1Pal.BTN_GREY, 26)
	menu.name = "Menu"
	ScrKit.tap(menu, func() -> void: menu_requested.emit())
	h.add_child(menu)
	return p


func _next_id() -> int:
	if int(reward.get("next_id", -1)) > 0:
		return int(reward["next_id"])
	var stages: Array = meta.stages()
	for i: int in stages.size():
		if int((stages[i] as Dictionary)["id"]) == stage_id:
			return int((stages[mini(i + 1, stages.size() - 1)] as Dictionary)["id"])
	return stage_id


# ───────────────────────────── milestone · unlock
func _show_mile() -> void:
	var label: String = str(reward.get("milestone", ""))
	var tier: String = "gold" if label.contains("골드") else ("silver" if label.contains("실버") else "bronze")
	_mile = Control.new()
	_mile.name = "Milestone"
	_mile.set_anchors_preset(Control.PRESET_FULL_RECT)
	_mile.mouse_filter = Control.MOUSE_FILTER_STOP
	var rays := Control.new()
	rays.set_anchors_preset(Control.PRESET_FULL_RECT)
	rays.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rays.draw.connect(func() -> void:
		var c: Vector2 = rays.size * 0.5
		rays.draw_rect(Rect2(Vector2.ZERO, rays.size), Color(0, 0, 0, 0.45))
		for i: int in 12:
			var a: float = TAU * i / 12.0
			rays.draw_colored_polygon(PackedVector2Array([c, c + Vector2(cos(a - 0.12), sin(a - 0.12)) * 900.0, c + Vector2(cos(a + 0.12), sin(a + 0.12)) * 900.0]), Color(1, 0.86, 0.3, 0.16)))
	_mile.add_child(rays)
	var card: PanelContainer = ScrKit.panel(ScrKit.sb(Color("#fff3c4") if tier != "silver" else Color("#eef0f3"), 26, 5, 8, Lane1Pal.INK, Vector4(22, 18, 22, 18)))
	var h: HBoxContainer = ScrKit.hbox(14)
	h.add_child(ScrKit.icon("medal" if tier == "bronze" else "hazard", 80))
	var v: VBoxContainer = ScrKit.vbox(2)
	v.add_child(ScrKit.lbl("구독자 %s 달성" % ScrKit.kor(int(reward.get("subs", 0))), 18, Lane1Pal.MUTED, false))
	v.add_child(ScrKit.lbl(label, 32, Lane1Pal.INK, true))
	v.add_child(ScrKit.lbl("탭해서 닫기", 16, Lane1Pal.MUTED, false))
	h.add_child(v)
	card.add_child(h)
	var cc := CenterContainer.new()
	cc.set_anchors_preset(Control.PRESET_FULL_RECT)
	cc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cc.add_child(card)
	_mile.add_child(cc)
	_mile.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed:
			_close_mile())
	add_child(_mile)
	ScrKit.sfx("stageClear")


func _close_mile() -> void:
	if _mile != null and is_instance_valid(_mile):
		_mile.queue_free()
	_mile = null


func _unlocks() -> Array:
	var u: Variant = reward.get("unlocks", reward.get("unlocked", []))
	return Array(u) if u is Array else []


func _show_unlock() -> void:
	var ids: Array = _unlocks()
	if ids.is_empty():
		return
	var st: Dictionary = meta.stage(int(ids[0]))
	_toast = ScrKit.panel(ScrKit.sb(Lane1Pal.GREEN_HI, 22, 4, 6, Lane1Pal.INK, Vector4(16, 8, 18, 10)))
	_toast.name = "UnlockToast"
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var h: HBoxContainer = ScrKit.hbox(8)
	h.add_child(ScrKit.icon("lock", 28))
	h.add_child(ScrKit.lbl("새 빌런 해금! %s" % ScrKit.stage_title(st), 22, Color.WHITE, true, 4, 2))
	_toast.add_child(h)
	_fx.add_child(_toast)
	_toast.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_toast.position = Vector2((size.x - 420.0) * 0.5, insets.y + 92.0)
	var tw: Tween = _toast.create_tween()
	_toast.modulate.a = 0.0
	tw.tween_property(_toast, "modulate:a", 1.0, 0.2)
	tw.tween_interval(2.2)
	tw.tween_property(_toast, "modulate:a", 0.0, 0.4)
	ScrKit.sfx("uiConfirm")
