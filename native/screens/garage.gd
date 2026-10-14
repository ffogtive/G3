class_name ScrGarage
extends ScrScreen
## 참교육 차고 (ui.js showShop · renderShopTabs · renderLoadout · itemCardHTML · itemSpecs · onShopClick · celebrate;
## main.js onBuy/onEquip; NATIVE_PARITY A15/A16): wallet, ✕, 5 tabs (차/무기/날아가는 것/피니시/패시브, owned/total,
## buyable dot), loadout row (3 slots + 보유 능력, tap → that tab), item cards (art, 장착 중/보유 ribbon, price/기본,
## desc, spec chips, 구매 / 장착 / "₩X 더 모으면!"). Buy: wallet − price, owned + id, slot items auto-equip;
## poor → shake + "₩X 부족!" + warn; bought → coin burst + '구매 완료!' stamp + stageClear; equip → pop + ui.

signal bought(id: String)
signal equipped_item(id: String)

const CATS: Array = [
	{"id": "car", "label": "차", "ico": "car", "slot": true},
	{"id": "weapon", "label": "무기", "ico": "tackTab", "slot": true},
	{"id": "move", "label": "날아가는 것", "ico": "jump", "slot": false},
	{"id": "finish", "label": "피니시", "ico": "rocket", "slot": true},
	{"id": "passive", "label": "패시브", "ico": "shieldOk", "slot": false},
]

var tab: String = "car"
var _wallet_l: Label
var _wallet_chip: Control
var _tabs_row: HBoxContainer
var _load_row: HBoxContainer
var _grid: GridContainer
var _shelf: ScrollContainer
var _fx_layer: Control
var _shown_wallet: int = -1
var cards: Dictionary = {}   # item id → card Control


func build() -> void:
	add_child(ScrKit.dim(0.6))
	move_child(get_child(get_child_count() - 1), 0)
	var m: MarginContainer = ScrKit.margin(14, 14, 14, 14)
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	safe.add_child(m)
	var panel: PanelContainer = ScrKit.panel(ScrKit.sb(Color("#2a3442"), 30, 5, 10, Lane1Pal.INK, Vector4(0, 0, 0, 14)))
	panel.name = "ShopPanel"
	m.add_child(panel)
	var v: VBoxContainer = ScrKit.vbox(0)
	panel.add_child(v)
	v.add_child(_head())
	v.add_child(_awning())
	var tm: MarginContainer = ScrKit.margin(14, 12, 14, 6)
	_tabs_row = ScrKit.hbox(8)
	_tabs_row.name = "Tabs"
	tm.add_child(_tabs_row)
	v.add_child(tm)
	var lm: MarginContainer = ScrKit.margin(14, 6, 14, 10)
	var lp: PanelContainer = ScrKit.panel(ScrKit.sb(Color(0, 0, 0, 0.18), 20, 3, 0, Color("#5a6372"), Vector4(8, 8, 8, 8)))
	_load_row = ScrKit.hbox(8)
	_load_row.name = "Loadout"
	lp.add_child(_load_row)
	lm.add_child(lp)
	v.add_child(lm)
	_shelf = ScrollContainer.new()
	_shelf.name = "Shelf"
	_shelf.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_shelf.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_shelf.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_shelf.mouse_filter = Control.MOUSE_FILTER_PASS
	var sm: MarginContainer = ScrKit.margin(14, 4, 14, 4)
	sm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_shelf.add_child(sm)
	_grid = GridContainer.new()
	_grid.name = "Grid"
	_grid.columns = 2
	_grid.add_theme_constant_override(&"h_separation", 12)
	_grid.add_theme_constant_override(&"v_separation", 14)
	_grid.mouse_filter = Control.MOUSE_FILTER_PASS
	sm.add_child(_grid)
	v.add_child(_shelf)
	_fx_layer = Control.new()
	_fx_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fx_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_fx_layer)


func _head() -> Control:
	var s: StyleBoxFlat = ScrKit.sb(Lane1Pal.GREEN, 0, 0, 0, Lane1Pal.INK, Vector4(8, 8, 8, 8))
	s.corner_radius_top_left = 25
	s.corner_radius_top_right = 25
	var p: PanelContainer = ScrKit.panel(s)
	var inner: PanelContainer = ScrKit.panel(ScrKit.sb(Color(0, 0, 0, 0), 14, 4, 0, Color.WHITE, Vector4(10, 6, 8, 6)))
	p.add_child(inner)
	var h: HBoxContainer = ScrKit.hbox(8)
	inner.add_child(h)
	h.add_child(ScrKit.icon("garage", 50))
	var tv: VBoxContainer = ScrKit.vbox(0)
	var sub: HBoxContainer = ScrKit.hbox(4)
	for ic: String in ["fuel", "cup", "wrench"]:
		sub.add_child(ScrKit.icon(ic, 20))
	sub.add_child(ScrKit.lbl("휴게소 정비소", 16, Color.WHITE, false))
	tv.add_child(sub)
	tv.add_child(ScrKit.lbl("참교육 차고", 33, Color.WHITE, true, 5, 4))
	h.add_child(tv)
	h.add_child(ScrKit.spacer())
	var wc: PanelContainer = ScrKit.panel(ScrKit.sb(Color("#17202b"), 30, 0, 0, Lane1Pal.INK, Vector4(8, 4, 14, 6)))
	wc.name = "WalletChip"
	_wallet_chip = wc
	var wh: HBoxContainer = ScrKit.hbox(8)
	wh.add_child(ScrKit.icon("coin", 30))
	var wv: VBoxContainer = ScrKit.vbox(0)
	wv.add_child(ScrKit.lbl("포상금", 13, Lane1Pal.MUTED_LT, false))
	_wallet_l = ScrKit.lbl("₩0", 25, Lane1Pal.GOLD_TXT, true, 0, 3)
	_wallet_l.name = "Wallet"
	wv.add_child(_wallet_l)
	wh.add_child(wv)
	wc.add_child(wh)
	h.add_child(wc)
	var x: ScrKit.Pill = ScrKit.round_btn("close", Lane1Pal.BTN_RED, 52)
	x.name = "Close"
	x.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	ScrKit.tap(x, close)
	h.add_child(x)
	return p


## Red/white scalloped awning (.ui-shop__awning).
func _awning() -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, 40)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.draw.connect(func() -> void:
		var n: int = 11
		var w: float = c.size.x / n
		c.draw_rect(Rect2(0, 0, c.size.x, 16), Lane1Pal.RED)
		for i: int in n:
			var col: Color = Lane1Pal.RED if i % 2 == 0 else Color("#fff7e3")
			c.draw_rect(Rect2(i * w, 0, w, 18), col)
			c.draw_circle(Vector2(i * w + w * 0.5, 18), w * 0.5, col)
		c.draw_line(Vector2(0, 1), Vector2(c.size.x, 1), Lane1Pal.INK, 3.0))
	return c


# ───────────────────────────── data
func refresh() -> void:
	var w: int = meta.wallet()
	if _shown_wallet >= 0 and w != _shown_wallet:
		ScrTitle.count_to(_wallet_l, _shown_wallet, w, 0.7, true)
		if w < _shown_wallet:
			float_text(_wallet_chip, "−" + ScrKit.won(_shown_wallet - w), Color("#ffb3ab"), 46.0)
	else:
		_wallet_l.text = ScrKit.won(w)
	_shown_wallet = w
	_render_tabs()
	_render_loadout()
	_render_grid()


func _items_of(cat: String) -> Array:
	var out: Array = []
	for it: Dictionary in meta.shop_items():
		if str(it.get("cat", "")) == cat:
			out.append(it)
	return out


func _render_tabs() -> void:
	ScrKit.clear(_tabs_row)
	for cat: Dictionary in CATS:
		var its: Array = _items_of(str(cat["id"]))
		var own: int = 0
		var can: bool = false
		for it: Dictionary in its:
			if meta.owns(str(it["id"])):
				own += 1
			elif int(it.get("price", 0)) <= meta.wallet():
				can = true
		var on: bool = str(cat["id"]) == tab
		var wrap := Control.new()
		wrap.name = "Tab_" + str(cat["id"])
		wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		wrap.custom_minimum_size = Vector2(80, 100)
		var p: PanelContainer = ScrKit.panel(ScrKit.sb(Lane1Pal.YELLOW if on else Color.WHITE, 16, 4, 6, Lane1Pal.INK, Vector4(2, 8, 2, 8)))
		p.set_anchors_preset(Control.PRESET_FULL_RECT)
		p.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var v: VBoxContainer = ScrKit.vbox(2)
		v.alignment = BoxContainer.ALIGNMENT_CENTER
		var ic: TextureRect = ScrKit.icon(str(cat["ico"]), 32)
		ic.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		v.add_child(ic)
		var l: Label = ScrKit.lbl(str(cat["label"]), 20 if str(cat["label"]).length() < 4 else 17, Lane1Pal.INK, true)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(l)
		var n: Label = ScrKit.lbl("%d/%d" % [own, its.size()], 18, Lane1Pal.INK if on else Lane1Pal.MUTED, false)
		n.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(n)
		p.add_child(v)
		wrap.add_child(p)
		if can:
			var dot := Control.new()
			dot.name = "Dot"
			dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
			dot.set_anchors_preset(Control.PRESET_TOP_RIGHT)
			dot.draw.connect(func() -> void:
				dot.draw_circle(Vector2.ZERO, 11, Lane1Pal.INK)
				dot.draw_circle(Vector2.ZERO, 8, Lane1Pal.RED))
			wrap.add_child(dot)
			dot.offset_left = -4
			dot.offset_top = 4
		var cid: String = str(cat["id"])
		ScrKit.tap(wrap, func() -> void: go_tab(cid))
		_tabs_row.add_child(wrap)


func go_tab(cat: String) -> void:
	if cat == tab:
		return
	tab = cat
	_render_tabs()
	_render_grid()
	_shelf.scroll_vertical = 0


func _render_loadout() -> void:
	ScrKit.clear(_load_row)
	for cat: Dictionary in CATS:
		if not bool(cat["slot"]):
			continue
		var id: String = meta.equipped(str(cat["id"]))
		var it: Dictionary = meta.item(id)
		var slot: PanelContainer = ScrKit.panel(ScrKit.sb(Color.WHITE, 14, 3, 0, Lane1Pal.INK, Vector4(5, 4, 6, 4)))
		slot.name = "Slot_" + str(cat["id"])
		slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var h: HBoxContainer = ScrKit.hbox(3)
		h.add_child(ScrKit.item_art(id, 42))
		var v: VBoxContainer = ScrKit.vbox(0)
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		v.add_child(ScrKit.lbl(str(cat["label"]), 14, Lane1Pal.MUTED, false))
		var nl: Label = ScrKit.ellipsis(ScrKit.lbl(str(it.get("name", "—")), 17, Lane1Pal.INK, true))
		nl.name = "Name"
		v.add_child(nl)
		h.add_child(v)
		slot.add_child(h)
		var cid: String = str(cat["id"])
		ScrKit.tap(slot, func() -> void: go_tab(cid))
		_load_row.add_child(slot)
	var extras: PackedStringArray = []
	for it: Dictionary in meta.shop_items():
		var c2: String = str(it.get("cat", ""))
		if (c2 == "move" or c2 == "passive") and meta.owns(str(it["id"])):
			extras.append(str(it.get("name", "")))
	_load_row.set_meta(&"extras", extras)


func _render_grid() -> void:
	ScrKit.clear(_grid)
	cards.clear()
	for it: Dictionary in _items_of(tab):
		var card: Control = _card(it)
		_grid.add_child(card)
		cards[str(it["id"])] = card


## ui.js itemStatus
func status(it: Dictionary) -> String:
	var id: String = str(it["id"])
	var slot: bool = ["car", "weapon", "finish"].has(str(it.get("cat", "")))
	if meta.owns(id):
		return ("equipped" if meta.equipped(str(it["cat"])) == id else "owned") if slot else "active"
	return "buy" if int(it.get("price", 0)) <= meta.wallet() else "poor"


## ui.js itemSpecs: [[text, "up"|"down"|""], …]
static func specs(it: Dictionary) -> Array:
	var out: Array = []
	var st: Dictionary = it.get("stats", {}) if it.get("stats") is Dictionary else {}
	if str(it.get("cat", "")) == "car" and not st.is_empty():
		var sp: float = float(st.get("speed", 1.0))
		if absf(sp - 1.0) < 0.005:
			out.append(["속도 기본", ""])
		else:
			out.append(["최고속 %s%d%%" % ["+" if sp > 1.0 else "−", roundi(absf(sp - 1.0) * 100.0)], "up" if sp > 1.0 else "down"])
		if int(st.get("armor", 0)) > 0:
			out.append(["추돌 무시 %d회" % int(st["armor"]), "up"])
		if bool(st.get("tow", false)):
			out.append(["고장차 견인", "up"])
		if bool(st.get("siren", false)):
			out.append(["사이렌", "up"])
	elif str(it.get("cat", "")) == "weapon" and it.get("dmg") != null:
		var dps: float = float(it["dmg"]) * float(it.get("rate", 1)) * maxf(1.0, float(it.get("spread", 1)))
		out.append(["초당 피해 %d" % roundi(dps), ""])
		if float(it.get("spread", 1)) > 1.0:
			out.append(["%d발 동시" % roundi(float(it["spread"])), "up"])
		if it.get("slow") != null and float(it["slow"]) > 0.0:
			out.append(["공격 느려짐", "up"])
	return out


func _card(it: Dictionary) -> Control:
	var id: String = str(it["id"])
	var s: String = status(it)
	var price: int = int(it.get("price", 0))
	var ring: PanelContainer = ScrKit.panel(ScrKit.sb(Lane1Pal.YELLOW if s == "equipped" else Color(0, 0, 0, 0), 26, 0, 0, Lane1Pal.INK, Vector4(5, 5, 5, 5)))
	ring.name = "Item_" + id
	ring.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ring.set_meta(&"status", s)
	var card: PanelContainer = ScrKit.panel(ScrKit.sb(Color.WHITE, 22, 4, 6, Lane1Pal.INK, Vector4(0, 0, 0, 0)))
	ring.add_child(card)
	var v: VBoxContainer = ScrKit.vbox(0)
	card.add_child(v)
	var show_sb: StyleBoxFlat = ScrKit.sb(Color("#bfe3ff"), 0, 0, 0, Lane1Pal.INK, Vector4(0, 8, 0, 0))
	show_sb.corner_radius_top_left = 18
	show_sb.corner_radius_top_right = 18
	show_sb.border_width_bottom = 4
	var showp: PanelContainer = ScrKit.panel(show_sb)
	showp.name = "Show"
	showp.custom_minimum_size.y = 124
	var road := Control.new()
	road.mouse_filter = Control.MOUSE_FILTER_IGNORE
	road.draw.connect(func() -> void:
		var y: float = road.size.y - 30.0
		road.draw_rect(Rect2(0, y, road.size.x, 30), Color("#8a929d"))
		var x: float = 10.0
		while x < road.size.x:
			road.draw_rect(Rect2(x, y + 13, 26, 4), Color.WHITE)
			x += 48.0)
	showp.add_child(road)
	var art: TextureRect = ScrKit.item_art(id, 164)
	art.size_flags_vertical = Control.SIZE_SHRINK_END
	showp.add_child(art)
	if s == "equipped" or s == "owned" or s == "active":
		var rib := Control.new()
		rib.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var rp: PanelContainer = ScrKit.chip("장착 중" if s == "equipped" else "보유", Lane1Pal.YELLOW if s == "equipped" else Color("#d8f5e4"), Lane1Pal.INK, 18, 3, 10)
		rib.add_child(rp)
		rp.position = Vector2(8, -4)
		showp.add_child(rib)
	v.add_child(showp)
	var tagrow: HBoxContainer = ScrKit.hbox(0)
	tagrow.alignment = BoxContainer.ALIGNMENT_END
	var tag_txt: String = "기본" if price <= 0 else (ScrKit.won(price) if s == "buy" or s == "poor" else "")
	if not tag_txt.is_empty():
		var tg: PanelContainer = ScrKit.chip(tag_txt, Lane1Pal.YELLOW if s == "buy" else Color.WHITE, Lane1Pal.INK, 22 if price > 0 else 18, 4, 16)
		tg.name = "Price"
		if price > 0:
			_coin_prefix(tg.get_child(0) as Label, 22)   # ui.js itemCardHTML: SVG.coin before the price
		tagrow.add_child(tg)
	var tm: MarginContainer = ScrKit.margin(10, -20 if not tag_txt.is_empty() else 0, 10, 0)
	tm.add_child(tagrow)
	v.add_child(tm)
	var bm: MarginContainer = ScrKit.margin(12, 2, 12, 12)
	v.add_child(bm)
	var bv: VBoxContainer = ScrKit.vbox(6)
	bm.add_child(bv)
	bv.add_child(ScrKit.ellipsis(ScrKit.lbl(str(it.get("name", id)), 25, Lane1Pal.INK, true)))
	var d: Label = ScrKit.para(str(it.get("desc", "")), 17, Color("#4a5360"), false, HORIZONTAL_ALIGNMENT_LEFT)
	d.custom_minimum_size.y = 46
	bv.add_child(d)
	var sp: Array = specs(it)
	if not sp.is_empty():
		var flow := HFlowContainer.new()
		flow.add_theme_constant_override(&"h_separation", 6)
		flow.add_theme_constant_override(&"v_separation", 6)
		flow.mouse_filter = Control.MOUSE_FILTER_IGNORE
		for pair: Array in sp:
			var up: bool = str(pair[1]) == "up"
			var dn: bool = str(pair[1]) == "down"
			var bg: Color = Color("#dcf7e6") if up else (Color("#ffe1dc") if dn else Color("#eef0f3"))
			var fg: Color = Color("#0b7a4b") if up else (Color("#c8241a") if dn else Color("#4a5360"))
			var c: PanelContainer = ScrKit.panel(ScrKit.sb(bg, 14, 2, 0, fg.lerp(Color.WHITE, 0.4), Vector4(8, 0, 8, 1)))
			c.mouse_filter = Control.MOUSE_FILTER_IGNORE
			c.add_child(ScrKit.lbl(str(pair[0]), 15, fg, false))
			flow.add_child(c)
		bv.add_child(flow)
	bv.add_child(ScrKit.spacer(2))
	bv.add_child(_action(it, s))
	return ring


func _action(it: Dictionary, s: String) -> Control:
	var id: String = str(it["id"])
	match s:
		"equipped", "active":
			var p: PanelContainer = ScrKit.panel(ScrKit.sb(Color("#fff3c4") if s == "equipped" else Color("#e6f8ee"), 30, 4, 0, Lane1Pal.INK, Vector4(10, 10, 10, 10)))
			p.name = "State"
			var h: HBoxContainer = ScrKit.hbox(8)
			h.alignment = BoxContainer.ALIGNMENT_CENTER
			h.add_child(ScrKit.icon("check", 26))
			h.add_child(ScrKit.lbl("장착 중" if s == "equipped" else ("보유 · 사용 가능" if str(it.get("cat")) == "move" else "보유 · 항상 적용"), 19, Lane1Pal.INK, true))
			p.add_child(h)
			return p
		"owned":
			var b: ScrKit.Pill = ScrKit.pill("장착", Lane1Pal.BTN_BLUE, 26)
			b.name = "Equip"
			ScrKit.tap(b, func() -> void: do_equip(id))
			return b
		"buy":
			var b2: ScrKit.Pill = ScrKit.pill("구매", Lane1Pal.BTN_YELLOW, 26)
			b2.name = "Buy"
			_coin_prefix(b2.find_child("Text", true, false) as Label, 30)   # web: coin icon + 구매
			ScrKit.tap(b2, func() -> void: do_buy(id), "")
			return b2
	var v: VBoxContainer = ScrKit.vbox(6)
	var need: Label = ScrKit.lbl("%s 더 모으면!" % ScrKit.won(int(it.get("price", 0)) - meta.wallet()), 18, Lane1Pal.RED, true)
	need.name = "Need"
	need.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(need)
	var b3: ScrKit.Pill = ScrKit.pill("포상금 부족", Lane1Pal.BTN_GREY, 22)
	b3.name = "Poor"
	ScrKit.tap(b3, func() -> void: do_buy(id), "")
	v.add_child(b3)
	return v


# ───────────────────────────── actions
func do_buy(id: String) -> bool:
	var it: Dictionary = meta.item(id)
	var card: Control = cards.get(id)
	if not meta.can_buy(id):
		if card != null:
			ScrKit.shake(card)
			float_text(card, "%s 부족!" % ScrKit.won(int(it.get("price", 0)) - meta.wallet()), Lane1Pal.RED, card.size.y * 0.55)
		ScrKit.shake(_wallet_chip)
		ScrKit.sfx("warn")
		return false
	if not meta.buy(id):
		return false
	ScrKit.sfx("stageClear")
	if str(it.get("cat", "")) != tab:
		tab = str(it.get("cat", tab))
	refresh()
	_celebrate(id)
	bought.emit(id)
	return true


func do_equip(id: String) -> bool:
	if not meta.equip(id):
		return false
	refresh()
	var card: Control = cards.get(id)
	if card != null:
		ScrKit.bump.call_deferred(card, 1.06, 300.0)
		float_text(card, "장착!", Lane1Pal.BLUE_HI, card.size.y * 0.6)
	equipped_item.emit(id)
	return true


func _celebrate(id: String) -> void:
	var card: Control = cards.get(id)
	if card == null:
		return
	await get_tree().process_frame
	if not is_instance_valid(card):
		return
	ScrKit.bump(card, 1.1, 440.0)
	var stamp: PanelContainer = ScrKit.panel(ScrKit.sb(Color(1, 1, 1, 0.92), 12, 5, 0, Lane1Pal.RED, Vector4(14, 4, 14, 6)))
	stamp.name = "Stamp"
	stamp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stamp.add_child(ScrKit.lbl("구매 완료!", 30, Lane1Pal.RED, true))
	_fx_layer.add_child(stamp)
	var r: Rect2 = card.get_global_rect()
	stamp.global_position = r.position + Vector2(r.size.x * 0.5 - 90, 50)
	stamp.rotation = -0.14
	stamp.pivot_offset = Vector2(90, 24)
	stamp.scale = Vector2.ONE * 1.8
	var tw: Tween = stamp.create_tween()
	tw.tween_property(stamp, "scale", Vector2.ONE, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_interval(1.0)
	tw.tween_property(stamp, "modulate:a", 0.0, 0.3)
	tw.tween_callback(stamp.queue_free)
	# coin burst (14 coins, like ui.js celebrate)
	var c0: Vector2 = r.position + Vector2(r.size.x * 0.5, 90)
	for i: int in 14:
		var coin: TextureRect = ScrKit.icon("coin", 30)
		_fx_layer.add_child(coin)
		coin.global_position = c0 - Vector2(15, 15)
		var a: float = TAU * float(i) / 14.0
		var d: float = 90.0 + float((i * 37) % 60)
		var to: Vector2 = coin.position + Vector2(cos(a) * d, sin(a) * d * 0.75 - 50.0)
		var ct: Tween = coin.create_tween()
		ct.set_parallel(true)
		ct.tween_property(coin, "position", to, 0.7).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
		ct.tween_property(coin, "modulate:a", 0.0, 0.5).set_delay(0.5)
		ct.chain().tween_callback(coin.queue_free)


## Floating text over a control (ui.js shopFloat): rises and fades.
func float_text(anchor: Control, text: String, col: Color, dy: float) -> void:
	if anchor == null or not anchor.is_inside_tree():
		return
	var l: Label = ScrKit.lbl(text, 28, col, true, 5, 0)
	l.label_settings = ScrKit.lset(28, col, true, 5, 0, Color.WHITE)
	l.name = "Float"
	_fx_layer.add_child(l)
	var r: Rect2 = anchor.get_global_rect()
	l.global_position = r.position + Vector2(r.size.x * 0.5 - 80, dy)
	l.custom_minimum_size.x = 160
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var tw: Tween = l.create_tween()
	tw.set_parallel(true)
	tw.tween_property(l, "position:y", l.position.y - 46.0, 1.1)
	tw.tween_property(l, "modulate:a", 0.0, 0.5).set_delay(0.7)
	tw.chain().tween_callback(l.queue_free)


## Puts a coin icon in front of a label (same parent slot, centred row).
static func _coin_prefix(l: Label, px: int) -> void:
	if l == null or l.get_parent() == null:
		return
	var par: Node = l.get_parent()
	var idx: int = l.get_index()
	var row: HBoxContainer = ScrKit.hbox(4)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	par.remove_child(l)
	row.add_child(ScrKit.icon("coin", px))
	row.add_child(l)
	par.add_child(row)
	par.move_child(row, idx)
