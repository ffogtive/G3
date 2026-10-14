class_name ScrTitle
extends ScrScreen
## Title / dashboard (ui.js showTitle, NATIVE_PARITY A2–A12, A21):
##   top    : 포상금 · 구독자 chips (A3, count-up on change) · settings gear (A11 → A20)
##   scroll : logo sign "고속도로 빌런 헌터 / ↑ 1차선 참교육" + VMS · 오늘의 빌런 strip (A21) · chapter tabs (A5) ·
##            chapter head (A6) · 2-column stage tiles (A7: shield, highway, n-k, kind, case chip, ★, BEST, lock, NEXT)
##   bottom : START = next unlocked stage (A8) · 제보 앨범 got/100 · 차고 owned/18 + buyable badge (A9) · help (A10)
## Locked tiles shake; open tiles emit stage_picked (the app shows the StageCard).

signal stage_picked(id: int)
signal album_requested
signal garage_requested
signal settings_requested

var groups: Array = []
var active_chapter: int = -1
var _tabs: ScrChapTabs
var _head: PanelContainer
var _grid: GridContainer
var _scroll: ScrollContainer
var _wallet_l: Label
var _subs_l: Label
var _start: ScrKit.Pill
var _album_cnt: Label
var _garage_cnt: Label
var _badge: PanelContainer
var _badge_l: Label
var _help: Label
var _daily: Control
var _shown_wallet: int = -1
var _shown_subs: int = -1
var tiles: Dictionary = {}   # stage id → tile Control


func build() -> void:
	var root: VBoxContainer = ScrKit.vbox(0)
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	safe.add_child(root)
	root.add_child(_top_bar())
	_scroll = ScrollContainer.new()
	_scroll.name = "Scroll"
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	root.add_child(_scroll)
	var pad: MarginContainer = ScrKit.margin(16, 4, 16, 12)
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(pad)
	var col: VBoxContainer = ScrKit.vbox(10)
	pad.add_child(col)
	col.add_child(_logo())
	_daily = ScrKit.margin(0, 0, 0, 0)
	_daily.name = "Daily"
	col.add_child(_daily)
	groups = ScrChapTabs.group_chapters(meta.stages(), meta.chapters())
	_tabs = ScrChapTabs.new()
	_tabs.name = "ChapTabs"
	col.add_child(_tabs)
	_head = ScrKit.panel(ScrKit.sb(Color(0.08, 0.1, 0.14, 0.86), 20, 4, 0, Lane1Pal.INK, Vector4(14, 8, 14, 8)))
	_head.name = "ChapHead"
	col.add_child(_head)
	_grid = GridContainer.new()
	_grid.name = "Grid"
	_grid.columns = 2
	_grid.add_theme_constant_override(&"h_separation", 10)
	_grid.add_theme_constant_override(&"v_separation", 10)
	_grid.mouse_filter = Control.MOUSE_FILTER_PASS
	col.add_child(_grid)
	root.add_child(_bottom_bar())


## START breathes (web .ui-title__start ui-breathe 1.7 s) unless held.
var _breath: float = 0.0


func _process(delta: float) -> void:
	if _start == null or _start.down:
		return
	_breath += delta
	_start.pivot_offset = _start.size * 0.5
	_start.scale = Vector2.ONE * (1.0 + 0.022 * sin(_breath * TAU / 1.7))


func _top_bar() -> Control:
	var m: MarginContainer = ScrKit.margin(16, 14, 16, 8)
	var row: HBoxContainer = ScrKit.hbox(10)
	m.add_child(row)
	var w: Array = _purse_chip("coin", "포상금", Lane1Pal.GOLD_TXT)
	_wallet_l = w[1]
	_wallet_l.name = "Wallet"
	row.add_child(w[0])
	var s: Array = _purse_chip("chan", "구독자", Lane1Pal.PINK_TXT)
	_subs_l = s[1]
	_subs_l.name = "Subs"
	row.add_child(s[0])
	row.add_child(ScrKit.spacer())
	var gear: ScrKit.Pill = ScrKit.round_btn("gear", Lane1Pal.BTN_GREY, 62)
	gear.name = "Settings"
	ScrKit.tap(gear, func() -> void: settings_requested.emit())
	row.add_child(gear)
	return m


func _purse_chip(ico: String, cap: String, col: Color) -> Array:
	var p: PanelContainer = ScrKit.panel(ScrKit.sb(Color(0.08, 0.1, 0.14, 0.9), 40, 4, 5, Lane1Pal.INK, Vector4(12, 6, 20, 8)))
	var h: HBoxContainer = ScrKit.hbox(10)
	p.add_child(h)
	h.add_child(ScrKit.icon(ico, 42))
	var v: VBoxContainer = ScrKit.vbox(0)
	v.add_child(ScrKit.lbl(cap, 15, Lane1Pal.MUTED_LT, false))
	var b: Label = ScrKit.lbl("0", 27, col, true, 0, 3)
	v.add_child(b)
	h.add_child(v)
	return [p, b]


func _logo() -> Control:
	var v: VBoxContainer = ScrKit.vbox(0)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	# green highway sign: ink rim, green band, white inner keyline (.ui-sign--logo)
	var outer: PanelContainer = ScrKit.panel(ScrKit.sb(Lane1Pal.GREEN, 26, 5, 9, Lane1Pal.INK, Vector4(7, 7, 7, 7)))
	outer.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var inner: PanelContainer = ScrKit.panel(ScrKit.sb(Lane1Pal.GREEN, 20, 4, 0, Color.WHITE, Vector4(26, 4, 30, 8)))
	outer.add_child(inner)
	var col: VBoxContainer = ScrKit.vbox(0)
	inner.add_child(col)
	var kick: Label = ScrKit.lbl("고 속 도 로   빌 런   헌 터", 18, Color.WHITE, true, 0, 2)
	kick.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(kick)
	var row: HBoxContainer = ScrKit.hbox(12)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	var arrow: TextureRect = ScrKit.icon("arrowUp", 40)
	arrow.custom_minimum_size = Vector2(34, 50)
	row.add_child(arrow)
	row.add_child(ScrKit.lbl("1차선 참교육", 52, Color.WHITE, true, 6, 5))
	col.add_child(row)
	v.add_child(outer)
	var posts := Control.new()
	posts.custom_minimum_size = Vector2(0, 10)
	posts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	posts.draw.connect(func() -> void:
		for x: float in [posts.size.x * 0.36, posts.size.x * 0.64]:
			posts.draw_rect(Rect2(x - 6, 0, 12, posts.size.y), Color("#8a929d"))
			posts.draw_rect(Rect2(x - 6, 0, 12, posts.size.y), Lane1Pal.INK, false, 3.0))
	v.add_child(posts)
	v.add_child(ScrKit.center(vms("막히면, 원인을 제거한다.", 25)))
	return v


## Dot-matrix VMS strip (.ui-vms): amber display text on black with a dot screen.
static func vms(text: String, size: int, wrap: bool = false) -> PanelContainer:
	var p: PanelContainer = ScrKit.panel(ScrKit.sb(Color("#0b0d10"), 14, 5, 5, Color("#2a2f38"), Vector4(26, 10, 26, 10)))
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l: Label = ScrKit.lbl(text, size, Color("#ffb400"), true, 0, 0)
	l.label_settings = ScrKit.lset(size, Color("#ffb400"), true, 3, 0, Color("#5a2d00"))
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size.x = 10
	p.add_child(l)
	var dots := Control.new()
	dots.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dots.set_anchors_preset(Control.PRESET_FULL_RECT)
	dots.draw.connect(func() -> void:
		var y: float = 2.0
		while y < dots.size.y:
			dots.draw_line(Vector2(6, y), Vector2(dots.size.x - 6, y), Color(0, 0, 0, 0.28), 1.0)
			y += 4.0)
	p.add_child(dots)
	return p


func _bottom_bar() -> Control:
	var m: MarginContainer = ScrKit.margin(16, 6, 16, 6)
	var v: VBoxContainer = ScrKit.vbox(4)
	m.add_child(v)
	var row: HBoxContainer = ScrKit.hbox(10)
	v.add_child(row)
	_start = ScrKit.pill("START ▶", Lane1Pal.BTN_YELLOW, 48, "STAGE 1-1")
	_start.name = "Start"
	_start.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_start.custom_minimum_size.y = 112
	ScrKit.tap(_start, func() -> void: stage_picked.emit(meta.next_stage_id()), "uiConfirm")
	row.add_child(_start)
	var album: Array = _square_btn("album", "제보 앨범", Lane1Pal.BTN_BLUE)
	(album[0] as Control).name = "Album"
	_album_cnt = album[1]
	ScrKit.tap(album[0], func() -> void: album_requested.emit())
	row.add_child(album[0])
	var garage: Array = _square_btn("garage", "차고", Lane1Pal.BTN_GREEN)
	(garage[0] as Control).name = "Garage"
	_garage_cnt = garage[1]
	ScrKit.tap(garage[0], func() -> void: garage_requested.emit())
	var gw := Control.new()
	gw.custom_minimum_size = Vector2(100, 112)
	gw.mouse_filter = Control.MOUSE_FILTER_PASS
	(garage[0] as Control).set_anchors_preset(Control.PRESET_FULL_RECT)
	gw.add_child(garage[0])
	_badge = ScrKit.panel(ScrKit.sb(Lane1Pal.RED, 20, 3, 0, Color.WHITE, Vector4(9, 0, 9, 1)))
	_badge.name = "Badge"
	_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_badge_l = ScrKit.lbl("0", 22, Color.WHITE, true)
	_badge_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_badge.add_child(_badge_l)
	_badge.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_badge.position = Vector2(74, -10)
	gw.add_child(_badge)
	row.add_child(gw)
	_help = ScrKit.lbl("", 15, Lane1Pal.MUTED_LT, false, 3, 0)
	_help.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(_help)
	return m


func _square_btn(ico: String, text: String, cols: Array[Color]) -> Array:
	var p: ScrKit.Pill = ScrKit.Pill.new()
	p.cols = cols
	p.radius = 34
	var e := StyleBoxEmpty.new()
	e.content_margin_left = 6
	e.content_margin_right = 6
	e.content_margin_top = 8
	e.content_margin_bottom = 14
	p.add_theme_stylebox_override(&"panel", e)
	p.custom_minimum_size = Vector2(100, 112)
	var v: VBoxContainer = ScrKit.vbox(0)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	var ic: TextureRect = ScrKit.icon(ico, 38)
	ic.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	v.add_child(ic)
	var l: Label = ScrKit.lbl(text, 20, Color.WHITE, true, 4, 2)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(l)
	var c: Label = ScrKit.lbl("0/0", 20, Lane1Pal.GOLD_TXT, true, 4, 2)
	c.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(c)
	p.add_child(v)
	return [p, c]


# ───────────────────────────── data
func refresh() -> void:
	var stages: Array = meta.stages()
	var start_id: int = meta.next_stage_id()
	var start_g: int = 1
	for g: Dictionary in groups:
		if (g["ids"] as Array).has(start_id):
			start_g = int(g["no"])
	_set_money(meta.wallet(), meta.subs(), _shown_wallet >= 0)
	var st0: Dictionary = meta.stage(start_id)
	(_start.find_child("Sub", true, false) as Label).text = "STAGE %s · %s" % [label_of(start_id), ScrKit.stage_title(st0)]
	var got: int = 0
	for st: Dictionary in stages:
		got += 1 if meta.album_got(int(st["id"])) else 0
	_album_cnt.text = "%d/%d" % [got, stages.size()]
	var items: Array = meta.shop_items()
	var owned: int = 0
	var can: int = 0
	for it: Dictionary in items:
		if meta.owns(str(it["id"])):
			owned += 1
		elif int(it.get("price", 0)) <= meta.wallet():
			can += 1
	_garage_cnt.text = "%d/%d" % [owned, items.size()]
	_badge.visible = can > 0
	_badge_l.text = "9+" if can > 9 else str(can)
	_help.text = "모바일  ◀ ▶ 버튼 · 좌우 스와이프 = 차선 · 위로 스와이프 = 분노" + ("  · 점프 버튼" if meta.owns("mv_jump") else "")
	_build_daily()
	_tabs.build(groups, _chapter_stat, start_g if active_chapter < 0 else active_chapter)
	if not _tabs.picked.is_connected(render_chapter):
		_tabs.picked.connect(render_chapter)
	render_chapter(start_g if active_chapter < 0 else active_chapter)


func _chapter_stat(g: Dictionary) -> Dictionary:
	var ids: Array = g["ids"]
	var cleared: int = 0
	for id: int in ids:
		cleared += 1 if meta.stars_of(id) > 0 else 0
	return {"done": cleared, "total": ids.size(), "locked": ids.is_empty() or not meta.is_unlocked(int(ids[0])),
		"complete": not ids.is_empty() and cleared == ids.size()}


## "n-k" chapter label for a stage id (web TS.grid && TS.multi).
func label_of(id: int) -> String:
	for g: Dictionary in groups:
		var k: int = (g["ids"] as Array).find(id)
		if k >= 0:
			return "%d-%d" % [int(g["no"]), k + 1]
	return str(id)


func _set_money(w: int, s: int, animate: bool) -> void:
	if animate and w != _shown_wallet:
		count_to(_wallet_l, _shown_wallet, w, 0.6, true)
	else:
		_wallet_l.text = ScrKit.won(w)
	_subs_l.text = ScrKit.kor(s)
	_shown_wallet = w
	_shown_subs = s


## ui.js countTo: ease-out count, bump at the end.
static func count_to(l: Label, from: int, to: int, secs: float, money: bool) -> void:
	if not l.is_inside_tree():
		l.text = ScrKit.won(to) if money else ScrKit.fmt(to)
		return
	var tw: Tween = l.create_tween()
	tw.tween_method(func(x: float) -> void: l.text = ScrKit.won(x) if money else ScrKit.fmt(x), float(from), float(to), secs).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tw.tween_callback(func() -> void: ScrKit.bump(l, 1.12, 240.0))


func _build_daily() -> void:
	ScrKit.clear(_daily)
	var id: int = meta.daily_villain()
	var st: Dictionary = meta.stage(id)
	if st.is_empty():
		return
	var p: ScrKit.Pill = ScrKit.Pill.new()
	p.name = "DailyBtn"
	p.cols = Lane1Pal.BTN_RED
	p.radius = 24
	p.drop = 5
	var e := StyleBoxEmpty.new()
	e.content_margin_left = 12
	e.content_margin_right = 12
	e.content_margin_top = 6
	e.content_margin_bottom = 10
	p.add_theme_stylebox_override(&"panel", e)
	var h: HBoxContainer = ScrKit.hbox(8)
	h.add_child(ScrKit.icon("angry", 28))
	h.add_child(ScrKit.chip("오늘의 빌런 %s" % label_of(id), Color("#9e1209"), Color.WHITE, 16, 0, 10))
	h.add_child(ScrKit.ellipsis(ScrKit.lbl(ScrKit.stage_title(st), 21, Color.WHITE, true, 4, 2)))
	var stars_on: int = meta.stars_of(id)
	h.add_child(ScrKit.stars(stars_on, 20))
	h.add_child(ScrKit.icon("right", 26))
	p.add_child(h)
	p.set_meta(&"stage_id", id)
	ScrKit.tap(p, func() -> void: stage_picked.emit(id), "uiConfirm")
	_daily.add_child(p)


func render_chapter(no: int) -> void:
	active_chapter = no
	var g: Dictionary = groups[0] if not groups.is_empty() else {"no": 1, "meta": {}, "ids": []}
	for x: Dictionary in groups:
		if int(x["no"]) == no:
			g = x
	_tabs.set_active(int(g["no"]))
	# head
	ScrKit.clear(_head)
	var ids: Array = g["ids"]
	var got: int = 0
	var cleared: int = 0
	for id: int in ids:
		got += meta.stars_of(id)
		cleared += 1 if meta.stars_of(id) > 0 else 0
	var h: HBoxContainer = ScrKit.hbox(12)
	_head.add_child(h)
	var tag: PanelContainer = ScrKit.chip("CHAPTER %d" % int(g["no"]), ScrKit.accent(g["meta"]), Color.WHITE, 19, 3, 12)
	tag.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(tag)
	var tv: VBoxContainer = ScrKit.vbox(0)
	tv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tv.add_child(ScrKit.ellipsis(ScrKit.lbl(str(g["meta"].get("name", "CHAPTER %d" % int(g["no"]))), 25, Color.WHITE, true, 0, 3)))
	tv.add_child(ScrKit.ellipsis(ScrKit.lbl(str(g["meta"].get("setting", "")), 17, Lane1Pal.MUTED_LT, false)))
	h.add_child(tv)
	var sv: VBoxContainer = ScrKit.vbox(2)
	var s1: HBoxContainer = ScrKit.hbox(4)
	s1.alignment = BoxContainer.ALIGNMENT_END
	s1.add_child(ScrKit.icon("star_on", 24))
	var sl: Label = ScrKit.lbl("%d" % got, 24, Lane1Pal.GOLD_TXT, true)
	sl.name = "StarSum"
	s1.add_child(sl)
	s1.add_child(ScrKit.lbl("/%d" % (ids.size() * 3), 19, Lane1Pal.MUTED_LT, false))
	sv.add_child(s1)
	var s2: HBoxContainer = ScrKit.hbox(4)
	s2.alignment = BoxContainer.ALIGNMENT_END
	s2.add_child(ScrKit.lbl("%d" % cleared, 24, Lane1Pal.MINT_TXT, true))
	s2.add_child(ScrKit.lbl("/%d 클리어" % ids.size(), 19, Lane1Pal.MUTED_LT, false))
	sv.add_child(s2)
	h.add_child(sv)
	# tiles
	ScrKit.clear(_grid)
	tiles.clear()
	var start_id: int = meta.next_stage_id()
	for k: int in ids.size():
		var id: int = ids[k]
		var t: Control = _tile(meta.stage(id), "%d-%d" % [int(g["no"]), k + 1], id == start_id)
		_grid.add_child(t)
		tiles[id] = t


func _tile(st: Dictionary, label: String, is_next: bool) -> Control:
	var id: int = int(st["id"])
	var locked: bool = not meta.is_unlocked(id)
	var stars_n: int = meta.stars_of(id)
	var kd: String = ScrKit.stage_kind(st)
	var ck: String = ScrKit.case_kind(st.get("card"))
	var ring: PanelContainer = ScrKit.panel(ScrKit.sb(Lane1Pal.YELLOW if is_next and not locked else Color(0, 0, 0, 0), 24, 0, 0, Lane1Pal.INK, Vector4(5, 5, 5, 5)))
	ring.name = "Tile%d" % id
	ring.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var card: PanelContainer = ScrKit.panel(ScrKit.sb(Lane1Pal.LOCKED if locked else Color.WHITE, 18, 4, 6, Lane1Pal.INK, Vector4(0, 0, 0, 0)))
	ring.add_child(card)
	var v: VBoxContainer = ScrKit.vbox(0)
	card.add_child(v)
	var head_sb: StyleBoxFlat = ScrKit.sb(Color("#8a929d") if locked else (Color("#0d6b45") if kd == "final" else Lane1Pal.GREEN), 0, 0, 0, Lane1Pal.INK, Vector4(7, 4, 9, 4))
	head_sb.corner_radius_top_left = 14
	head_sb.corner_radius_top_right = 14
	head_sb.border_width_bottom = 3
	head_sb.border_color = Lane1Pal.INK
	var head: PanelContainer = ScrKit.panel(head_sb)
	v.add_child(head)
	var hh: HBoxContainer = ScrKit.hbox(6)
	head.add_child(hh)
	hh.add_child(ScrKit.shield(st.get("route"), 27, locked))
	var num: PanelContainer = ScrKit.chip(label, Color.WHITE, Lane1Pal.INK, 19, 3, 11)
	num.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hh.add_child(num)
	if not kd.is_empty():
		var kb: Control = ScrKit.kind_badge(kd, 14)
		kb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		hh.add_child(kb)
	hh.add_child(ScrKit.spacer())
	var sr: HBoxContainer = ScrKit.stars(stars_n, 20, 0)
	sr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hh.add_child(sr)
	var body: MarginContainer = ScrKit.margin(12, 4, 10, 6)
	v.add_child(body)
	var bv: VBoxContainer = ScrKit.vbox(4)
	body.add_child(bv)
	var tr: HBoxContainer = ScrKit.hbox(6)
	if ScrKit.CASE_CHIP.has(ck):
		var cc: PanelContainer = ScrKit.chip(str(ScrKit.CASE_CHIP[ck]), Color(str(Lane1Pal.CASE_COLOR[ck])), Color.WHITE, 15, 2, 6)
		cc.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		tr.add_child(cc)
	var title: Label = ScrKit.lbl(ScrKit.stage_title(st), 22, Lane1Pal.INK if not locked else Color(Lane1Pal.INK, 0.45), true)
	title.name = "Title"
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title.clip_text = true
	title.custom_minimum_size = Vector2(40, 36)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	tr.add_child(title)
	if locked:
		var lk: PanelContainer = ScrKit.panel(ScrKit.sb(Lane1Pal.INK, 16, 0, 0, Lane1Pal.INK, Vector4(8, 1, 10, 1)))
		lk.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var lh: HBoxContainer = ScrKit.hbox(3)
		lh.add_child(ScrKit.icon("lock", 18))
		lh.add_child(ScrKit.lbl("잠김", 17, Color.WHITE, true))
		lk.add_child(lh)
		tr.add_child(lk)
	bv.add_child(tr)
	ring.set_meta(&"best", int(meta.best(id).get("score", 0)))
	ring.set_meta(&"stage_id", id)
	ring.set_meta(&"locked", locked)
	if is_next and not locked:
		var tag: PanelContainer = ScrKit.chip("NEXT", Lane1Pal.YELLOW, Lane1Pal.INK, 20, 3, 12)
		tag.name = "Next"
		var holder := Control.new()
		holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.add_child(tag)
		tag.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		tag.offset_left = -96
		tag.offset_right = -10
		tag.offset_top = -20
		tag.offset_bottom = 12
		ring.add_child(holder)
	ScrKit.tap(ring, func() -> void:
		if locked:
			ScrKit.shake(ring)
			ScrKit.sfx("warn")
		else:
			stage_picked.emit(id))
	return ring
