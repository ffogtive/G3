class_name ScrChapTabs
extends HBoxContainer
## ui.js chapTabs: ◀ [CH.n · lock/crown · done/total · name · progress] ×N ▶ (dashboard and album share it).
## stat_fn(group) → {done, total, locked, complete}. Tabs scroll horizontally; the active tab is centred.

signal picked(no: int)

const TAB_W: int = 178
const TAB_H: int = 86
## web hides ◀ ▶ on phones (style.css @media .ui-chap__nav { display: none })
var show_arrows: bool = false

var groups: Array = []
var active: int = -1
var on_dark: bool = true
var _scroll: ScrollContainer
var _row: HBoxContainer
var _tabs: Dictionary = {}
var _prev: Control
var _next: Control


## stages[].chapter → [{no, meta, ids}] (ui.js groupChapters; a missing chapter inherits the previous one).
static func group_chapters(stages: Array, chapters: Array) -> Array:
	var meta: Dictionary = {}
	for k: int in chapters.size():
		var c: Dictionary = chapters[k]
		meta[int(c.get("no", k + 1))] = c
	var by: Dictionary = {}
	var order: Array[int] = []
	var prev: int = 1
	for st: Dictionary in stages:
		var ch: int = int(st.get("chapter", prev)) if st.get("chapter") != null else prev
		prev = ch
		if not by.has(ch):
			by[ch] = {"no": ch, "meta": meta.get(ch, {}), "ids": []}
			order.append(ch)
		(by[ch]["ids"] as Array).append(int(st["id"]))
	order.sort()
	var out: Array = []
	for no: int in order:
		out.append(by[no])
	return out


func build(gs: Array, stat_fn: Callable, active_no: int) -> void:
	for c: Node in get_children():
		remove_child(c)
		c.queue_free()
	_tabs.clear()
	groups = gs
	add_theme_constant_override(&"separation", 6)
	mouse_filter = Control.MOUSE_FILTER_PASS
	_prev = ScrKit.round_btn("left", Lane1Pal.BTN_BLUE, 46)
	_prev.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_prev.visible = show_arrows
	ScrKit.tap(_prev, func() -> void: step(-1))
	add_child(_prev)
	_scroll = ScrollContainer.new()
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.custom_minimum_size.y = TAB_H + 14
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_scroll)
	_row = ScrKit.hbox(10)
	_scroll.add_child(_row)
	_next = ScrKit.round_btn("right", Lane1Pal.BTN_BLUE, 46)
	_next.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_next.visible = show_arrows
	ScrKit.tap(_next, func() -> void: step(1))
	add_child(_next)
	for g: Dictionary in groups:
		var t: Control = _tab(g, stat_fn.call(g))
		_row.add_child(t)
		_tabs[int(g["no"])] = t
	set_active(active_no)


func _tab(g: Dictionary, st: Dictionary) -> Control:
	var no: int = int(g["no"])
	var acc: Color = ScrKit.accent(g.get("meta", {}))
	var wrap := ScrKit.margin(4, 4, 4, 8)
	wrap.name = "Tab%d" % no
	wrap.custom_minimum_size = Vector2(TAB_W, TAB_H)
	var p: PanelContainer = ScrKit.panel(ScrKit.sb(Color.WHITE, 18, 4, 6, Lane1Pal.INK, Vector4(12, 6, 12, 8)))
	p.name = "Panel"
	wrap.add_child(p)
	var v: VBoxContainer = ScrKit.vbox(4)
	p.add_child(v)
	var top: HBoxContainer = ScrKit.hbox(4)
	var chl: Label = ScrKit.lbl("CH.%d" % no, 18, acc, true)
	chl.name = "No"
	top.add_child(chl)
	if bool(st.get("locked", false)):
		top.add_child(ScrKit.icon("lock", 22))
	elif bool(st.get("complete", false)):
		top.add_child(ScrKit.icon("medal", 22))
	top.add_child(ScrKit.spacer())
	var cnt: Label = ScrKit.lbl("%d/%d" % [int(st.get("done", 0)), int(st.get("total", 0))], 21, Lane1Pal.INK, true)
	cnt.name = "Cnt"
	top.add_child(cnt)
	v.add_child(top)
	var name_l: Label = ScrKit.ellipsis(ScrKit.lbl(str(g.get("meta", {}).get("name", "CHAPTER %d" % no)), 20, Lane1Pal.INK, true))
	name_l.name = "Name"
	v.add_child(name_l)
	var total: int = maxi(1, int(st.get("total", 1)))
	var b: ScrKit.Bar = ScrKit.bar(float(st.get("done", 0)) / float(total), acc, 11)
	b.name = "Prog"
	v.add_child(b)
	wrap.set_meta(&"state", st)
	wrap.set_meta(&"accent", acc)
	ScrKit.tap(wrap, func() -> void:
		if no != active:
			picked.emit(no))
	return wrap


func step(d: int) -> void:
	var k: int = -1
	for i: int in groups.size():
		if int(groups[i]["no"]) == active:
			k = i
	var j: int = clampi(k + d, 0, groups.size() - 1)
	if j != k and j >= 0:
		picked.emit(int(groups[j]["no"]))


func set_active(no: int) -> void:
	active = no
	for k: int in _tabs:
		var wrap: Control = _tabs[k]
		var st: Dictionary = wrap.get_meta(&"state")
		var acc: Color = wrap.get_meta(&"accent")
		var on: bool = k == no
		var bg: Color = acc if on else (Color("#dde1e6") if bool(st.get("locked", false)) else Color("#fff3c4") if bool(st.get("complete", false)) else Color.WHITE)
		var s: StyleBoxFlat = ScrKit.sb(bg, 18, 4, 6, Lane1Pal.INK, Vector4(12, 6, 12, 8))
		if on:
			s.expand_margin_left = 4
			s.expand_margin_right = 4
			s.expand_margin_top = 4
			s.expand_margin_bottom = 4
			s.border_color = Lane1Pal.YELLOW
			s.set_border_width_all(5)
		(wrap.get_node(^"Panel") as PanelContainer).add_theme_stylebox_override(&"panel", s)
		var fg: Color = Color.WHITE if on else (Lane1Pal.MUTED if bool(st.get("locked", false)) else Lane1Pal.INK)
		var no_l: Label = wrap.find_child("No", true, false)
		no_l.label_settings = ScrKit.lset(18, Color.WHITE if on else (Lane1Pal.MUTED if bool(st.get("locked", false)) else acc), true)
		(wrap.find_child("Cnt", true, false) as Label).label_settings = ScrKit.lset(21, fg, true)
		(wrap.find_child("Name", true, false) as Label).label_settings = ScrKit.lset(20, fg, true, 0, 2 if on else 0)
		var b: ScrKit.Bar = wrap.find_child("Prog", true, false)
		b.fill = Lane1Pal.GOLD_TXT if on else acc
		b.track = Color(0, 0, 0, 0.28) if on else Lane1Pal.LINE
		b.queue_redraw()
	var idx: int = 0
	for i: int in groups.size():
		if int(groups[i]["no"]) == no:
			idx = i
	_prev.modulate.a = 0.4 if idx <= 0 else 1.0
	_next.modulate.a = 0.4 if idx >= groups.size() - 1 else 1.0
	_center.call_deferred(no)


func _center(no: int) -> void:
	if not _tabs.has(no) or _scroll == null:
		return
	var t: Control = _tabs[no]
	_scroll.scroll_horizontal = int(maxf(0.0, t.position.x - (_scroll.size.x - t.size.x) * 0.5))
