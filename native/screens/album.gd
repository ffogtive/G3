class_name ScrAlbum
extends ScrScreen
## 블박 제보 앨범 (ui.js showAlbum · albumCardHTML · renderAlbumPage · albumGot · dashArt; NATIVE_PARITY A14):
## head (누적 범칙금 = Σ fine of collected stages, got/100 bar, ✕), chapter tabs, page head (CHAPTER n, n/10 수집,
## 챕터 완성!), cards: No.001 + kind badge + ★, dash-cam photo (user:// file) or procedural dashArt, REC; uncollected
## = silhouette + '?' + '제보 대기 중'; title, villain, case amount (₩ / 만원 / 구조 표창 / 계도), ×count.
## Rarity frame r1 bronze / r2 silver / r3 gold (+ holo sheen).

const RARITY: Array[Color] = [Color("#e9ecef"), Color("#e8a26a"), Color("#c9d0d8"), Color("#ffcf33")]

var groups: Array = []
var active_chapter: int = -1
var _tabs: ScrChapTabs
var _page_head: HBoxContainer
var _grid: GridContainer
var _page_scroll: ScrollContainer
var _fines_l: Label
var _got_l: Label
var _bar: ScrKit.Bar
var cards: Dictionary = {}


func build() -> void:
	add_child(ScrKit.dim(0.6))
	move_child(get_child(get_child_count() - 1), 0)
	var m: MarginContainer = ScrKit.margin(14, 14, 14, 14)
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	safe.add_child(m)
	var book: PanelContainer = ScrKit.panel(ScrKit.sb(Lane1Pal.BLUE_HI, 30, 5, 10, Lane1Pal.INK, Vector4(10, 10, 10, 10)))
	book.name = "Book"
	m.add_child(book)
	var v: VBoxContainer = ScrKit.vbox(10)
	book.add_child(v)
	var head: HBoxContainer = ScrKit.hbox(10)
	var hm: MarginContainer = ScrKit.margin(10, 6, 4, 0)
	hm.add_child(head)
	v.add_child(hm)
	head.add_child(ScrKit.icon("album", 48))
	var tv: VBoxContainer = ScrKit.vbox(0)
	tv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tv.add_child(ScrKit.lbl("블박 제보 앨범", 32, Color.WHITE, true, 5, 4))
	_fines_l = ScrKit.ellipsis(ScrKit.lbl("", 16, Color("#d6e4ff"), false))
	_fines_l.name = "Fines"
	tv.add_child(_fines_l)
	head.add_child(tv)
	var cv: VBoxContainer = ScrKit.vbox(4)
	_got_l = ScrKit.lbl("0/100", 32, Lane1Pal.GOLD_TXT, true, 5, 3)
	_got_l.name = "Got"
	_got_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	cv.add_child(_got_l)
	_bar = ScrKit.bar(0.0, Lane1Pal.YELLOW, 14)
	_bar.custom_minimum_size.x = 110
	_bar.track = Color("#17202b")
	cv.add_child(_bar)
	head.add_child(cv)
	var x: ScrKit.Pill = ScrKit.round_btn("close", Lane1Pal.BTN_RED, 54)
	x.name = "Close"
	x.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	ScrKit.tap(x, close)
	head.add_child(x)
	groups = ScrChapTabs.group_chapters(meta.stages(), meta.chapters())
	_tabs = ScrChapTabs.new()
	_tabs.name = "ChapTabs"
	v.add_child(_tabs)
	var page: PanelContainer = ScrKit.panel(ScrKit.sb(Lane1Pal.CREAM, 24, 4, 0, Lane1Pal.INK, Vector4(12, 12, 12, 0)))
	page.name = "Page"
	page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(page)
	var pv: VBoxContainer = ScrKit.vbox(10)
	page.add_child(pv)
	_page_head = ScrKit.hbox(10)
	pv.add_child(_page_head)
	_page_scroll = ScrollContainer.new()
	_page_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_page_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_page_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_page_scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	pv.add_child(_page_scroll)
	_grid = GridContainer.new()
	_grid.name = "Grid"
	_grid.columns = 2
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_theme_constant_override(&"h_separation", 12)
	_grid.add_theme_constant_override(&"v_separation", 12)
	var gm: MarginContainer = ScrKit.margin(2, 4, 2, 14)
	gm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gm.add_child(_grid)
	_page_scroll.add_child(gm)


func refresh() -> void:
	var stages: Array = meta.stages()
	var got: int = 0
	var fines: int = 0
	var last_g: int = 1
	for st: Dictionary in stages:
		var id: int = int(st["id"])
		if meta.album_got(id):
			got += 1
			fines += maxi(0, int(meta.album_entry(id).get("fine", st.get("fine", 0)) if meta.album_entry(id).get("fine") != null else st.get("fine", 0)))
			last_g = int(st.get("chapter", last_g))
	_fines_l.text = "빌런 도감 · 누적 범칙금 %s" % ScrKit.won(fines)
	_got_l.text = "%d/%d" % [got, stages.size()]
	_bar.frac = float(got) / float(maxi(1, stages.size()))
	_bar.queue_redraw()
	var start: int = active_chapter if active_chapter > 0 else last_g
	_tabs.build(groups, func(g: Dictionary) -> Dictionary:
		var c: int = 0
		for id: int in g["ids"]:
			c += 1 if meta.album_got(id) else 0
		return {"done": c, "total": (g["ids"] as Array).size(), "locked": false, "complete": c > 0 and c == (g["ids"] as Array).size()}, start)
	if not _tabs.picked.is_connected(render_page):
		_tabs.picked.connect(render_page)
	render_page(start)


func render_page(no: int) -> void:
	active_chapter = no
	_tabs.set_active(no)
	var g: Dictionary = groups[0]
	for x: Dictionary in groups:
		if int(x["no"]) == no:
			g = x
	ScrKit.clear(_page_head)
	var ids: Array = g["ids"]
	var c: int = 0
	for id: int in ids:
		c += 1 if meta.album_got(id) else 0
	var tag: PanelContainer = ScrKit.chip("CHAPTER %d" % no, Color.WHITE, ScrKit.accent(g["meta"]), 18, 3, 12)
	tag.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_page_head.add_child(tag)
	var tv: VBoxContainer = ScrKit.vbox(0)
	tv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tv.add_child(ScrKit.ellipsis(ScrKit.lbl(str(g["meta"].get("name", "")), 30, Lane1Pal.INK, true)))
	tv.add_child(ScrKit.ellipsis(ScrKit.lbl(str(g["meta"].get("setting", "")), 17, Lane1Pal.MUTED, false)))
	_page_head.add_child(tv)
	var cnt: HBoxContainer = ScrKit.hbox(2)
	cnt.add_child(ScrKit.lbl(str(c), 34, Lane1Pal.RED, true))
	cnt.add_child(ScrKit.lbl("/%d 수집" % ids.size(), 20, Lane1Pal.MUTED, false))
	if c > 0 and c == ids.size():
		cnt.add_child(ScrKit.lbl("  챕터 완성!", 20, Lane1Pal.GREEN_HI, true))
	_page_head.add_child(cnt)
	ScrKit.clear(_grid)
	cards.clear()
	var stages: Array = meta.stages()
	for id: int in ids:
		var idx: int = 0
		for i: int in stages.size():
			if int((stages[i] as Dictionary)["id"]) == id:
				idx = i
		var card: Control = _card(meta.stage(id), "No.%03d" % (idx + 1))
		_grid.add_child(card)
		cards[id] = card
	_page_scroll.scroll_vertical = 0


func _card(st: Dictionary, label: String) -> Control:
	var id: int = int(st["id"])
	var a: Dictionary = meta.album_entry(id)
	var has: bool = meta.album_got(id)
	var stars_n: int = clampi(maxi(int(a.get("stars", 0)), meta.stars_of(id)), 0, 3) if has else 0
	var fine: int = maxi(0, int(a.get("fine")) if a.get("fine") != null else int(st.get("fine", 0)))
	var count: int = maxi(1 if has else 0, int(a.get("count", 0)))
	var rar: int = maxi(1, stars_n) if has else 0
	var ck: String = ScrKit.case_kind(st.get("card"))
	var s: StyleBoxFlat = ScrKit.sb(RARITY[rar] if has else Color("#dfe3e8"), 20, 4, 6, Lane1Pal.INK, Vector4(10, 8, 10, 10))
	if not has:
		s.border_color = Color("#9aa3ae")
		s.shadow_size = 0
	var p: PanelContainer = ScrKit.panel(s)
	p.name = "Card%d" % id
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.set_meta(&"got", has)
	p.set_meta(&"rarity", rar)
	var v: VBoxContainer = ScrKit.vbox(6)
	p.add_child(v)
	var top: HBoxContainer = ScrKit.hbox(4)
	top.add_child(ScrKit.lbl(label, 20, Color(Lane1Pal.INK, 0.75) if has else Lane1Pal.MUTED, true))
	var kb: Control = ScrKit.kind_badge(ScrKit.stage_kind(st), 13)
	if kb != null:
		top.add_child(kb)
	top.add_child(ScrKit.spacer())
	top.add_child(ScrKit.stars(stars_n, 22, 0))
	v.add_child(top)
	var pic := Control.new()
	pic.name = "Pic"
	pic.custom_minimum_size = Vector2(0, 104)
	pic.clip_contents = true
	pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var frame: PanelContainer = ScrKit.panel(ScrKit.sb(Color("#11161e"), 14, 4, 0, Lane1Pal.INK, Vector4(0, 0, 0, 0)))
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
	pic.add_child(frame)
	var photo: Texture2D = photo_tex(a.get("photo")) if has else null
	var art: TextureRect
	if photo != null:
		art = ScrKit.tex_rect(photo, Vector2(10, 10))
		art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	else:
		art = ScrKit.svg_rect(ScrKit.dash_svg(ScrKit.villain_hex(st), id, not has), Vector2(220, 124), true)
	art.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.add_child(art)
	if has:
		var rec: HBoxContainer = ScrKit.hbox(4)
		var dot := Control.new()
		dot.custom_minimum_size = Vector2(14, 14)
		dot.draw.connect(func() -> void: dot.draw_circle(Vector2(7, 7), 6, Lane1Pal.RED))
		rec.add_child(dot)
		rec.add_child(ScrKit.lbl("REC", 18, Color.WHITE, true, 3, 0))
		rec.position = Vector2(12, 6)
		pic.add_child(rec)
	else:
		var q: Label = ScrKit.lbl("?", 48, Color("#5a6372"), true, 4, 0)
		q.set_anchors_preset(Control.PRESET_FULL_RECT)
		q.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		q.offset_bottom = -26
		pic.add_child(q)
		var w: Label = ScrKit.lbl("제보 대기 중", 20, Lane1Pal.AMBER, true, 4, 0)
		w.set_anchors_preset(Control.PRESET_FULL_RECT)
		w.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		w.offset_top = 58
		pic.add_child(w)
	v.add_child(pic)
	var np: PanelContainer = ScrKit.panel(ScrKit.sb(Color.WHITE if has else Color("#eef0f3"), 12, 3, 0, Lane1Pal.INK if has else Color("#b6bdc6"), Vector4(10, 4, 10, 4)))
	np.add_child(ScrKit.ellipsis(ScrKit.lbl(ScrKit.stage_title(st), 19, Lane1Pal.INK if has else Lane1Pal.MUTED, true)))
	v.add_child(np)
	var who: String = _all_names(st) if has else str(st.get("highway", ""))
	v.add_child(ScrKit.ellipsis(ScrKit.lbl(who, 16, Color("#6b5a3a") if has else Lane1Pal.MUTED, false)))
	var mr: HBoxContainer = ScrKit.hbox(4)
	var amt: String = "구조 표창" if ck == "rescue" else ("계도" if ck == "warn" else (ScrKit.big_won(fine) if ck == "crime" else ScrKit.won(fine)))
	var fl: Label = ScrKit.lbl(amt if has else "₩ ?", 21, Lane1Pal.RED_LO if has else Lane1Pal.MUTED, true)
	fl.name = "Amount"
	mr.add_child(fl)
	mr.add_child(ScrKit.spacer())
	var cnt_txt: String = ("×%s %s" % [ScrKit.fmt(count), "구조" if ck == "rescue" else "참교육"]) if has else ("구조 대기" if ck == "rescue" else "미검거")
	var cc: PanelContainer = ScrKit.chip(cnt_txt, Lane1Pal.INK if has else Color("#b6bdc6"), Color.WHITE, 15, 0, 14)
	cc.name = "Count"
	mr.add_child(cc)
	v.add_child(mr)
	if rar >= 3:
		var holo := Control.new()
		holo.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holo.draw.connect(func() -> void:
			var w2: float = holo.size.x
			holo.draw_colored_polygon(PackedVector2Array([Vector2(w2 * 0.55, 0), Vector2(w2 * 0.75, 0), Vector2(w2 * 0.35, holo.size.y), Vector2(w2 * 0.15, holo.size.y)]), Color(1, 1, 1, 0.18)))
		p.add_child(holo)
	return p


## Album photo: a user:// (or res://) image path written by the game's dash-cam capture (C24), or an Image.
static func photo_tex(photo: Variant) -> Texture2D:
	if photo is Image:
		return ImageTexture.create_from_image(photo as Image)
	if photo is String and not str(photo).is_empty() and FileAccess.file_exists(str(photo)):
		var img: Image = Image.load_from_file(str(photo))
		if img != null and not img.is_empty():
			return ImageTexture.create_from_image(img)
	return null


## ui.js albumCardHTML vname: every villain's full name joined by ' & ' (not the 'OO 2대' short form of villainNames).
static func _all_names(st: Dictionary) -> String:
	var names: PackedStringArray = []
	for v: Variant in st.get("villains", []):
		if v is Dictionary and not str((v as Dictionary).get("name", "")).is_empty():
			names.append(str((v as Dictionary)["name"]))
	return " & ".join(names) if not names.is_empty() else str(st.get("highway", ""))
