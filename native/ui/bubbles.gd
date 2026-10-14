class_name Bubbles
extends Control
## Speech bubbles and pop text over cars (web main.js:96 bubble() / hud.popAt + ui.js .ui-bubble, css 409-430).
## key → {text, kind, until, born, pos: Callable() -> Vector3 (world, projected through the 3D camera every frame,
## hidden when behind it) | Vector2 (screen anchor)}. Kinds: thanks (green), angry (red, tilted −2°), taunt (white),
## player (yellow); pops are plain outlined text that rises and fades (warn / score). The web caps live bubbles at 8,
## so does this. Sizes: the web's 16 CSS px on a ~390 pt phone ≈ 22 units on the 540-wide canvas.
##
## r3 U1 (device feedback 4 "말풍선이 위에 빌런까지 거리 게이지바에 겹치는 경우가 있음"):
##   가설: ✅ the body knew only the N5 icon rects (avoid_rects, slid sideways) and the safe top, never the top HUD, so a
##         villain 190–235 m ahead put its taunt on the "원흉까지" bar. With the HUD's top guard (Hud.guard_bubbles:
##         top_guard + top_rects) a body that would meet the top HUD flips under its anchor (anchor under the guard) or
##         docks under the HUD (anchor above the guard / off the top): overlap 0 by construction.
##   layout() / layout_bubble() → [{key, text, kind, mode: up | flip | dock, body (Rect2, canvas), tip, anchor, villain,
##   border}] — the same entries _draw paints (tests and the Xvfb probe read them). One docked bubble per frame (the
##   newest); the villain's docked taunt gets a red border.
## r3 U4 (손맛 리뷰 "숫자가 원흉 위에 기둥처럼 쌓이고 큰 숫자가 잘림"):
##   pop(pos, text, kind, merge_key, value, target, prio): the same merge_key within MERGE_S adds `value` into the
##   live pop ("-40" → "-80", punch 1.15, gold once a window hit joins); ≤ PER_TARGET live pops per target (target =
##   explicit, or from the key: t / c / p / s / k / i / x + id → "v<id>", m + id → "m<id>"), priority kill 5 > skill
##   sum 4 > puncture 3 > combo 2 > tack stack 1 — overflow fades the lowest (oldest on a tie) in FADE_S; the pop rect
##   (punch + outline + tilt) is clamped inside safe_rect (margin 8); clear_pops(max_age) drops the older pops.

const MAX_BUBBLES: int = 8
const FONT_BODY_PATH: String = "res://ui/fonts/Jua-Regular.ttf"
const FONT_DISPLAY_PATH: String = "res://ui/fonts/BlackHanSans-Regular.ttf"
const INK := Color8(0x17, 0x20, 0x2b)
const BG: Dictionary = {
	"thanks": Color8(0x2f, 0xd1, 0x7e), "angry": Color8(0xff, 0x5a, 0x3c),
	"taunt": Color(1, 1, 1), "player": Color8(0xff, 0xd2, 0x3f),
}
## Border of a docked villain taunt (the bubble is far from its car: the colour says who is talking).
const VILLAIN_RED := Color8(0xe8, 0x24, 0x2a)
const TAIL: float = 12.0
const DOCK_TAIL: float = 10.0
const DOCK_GAP: float = 4.0
const EDGE: float = 6.0
## warn pops are white with a dark outline: the old yellow vanished on the yellow hero roof (art review).
const POP_COLOR: Dictionary = {"warn": Color.WHITE, "score": Color8(0x8d, 0xff, 0xbb), "hit": Color8(0xff, 0xd2, 0x3f),
	"crit": Color8(0xff, 0x9a, 0x2e), "miss": Color8(0xc9, 0xd3, 0xdf), "dmg": Color8(0xff, 0x5a, 0x4a),
	"big": Color8(0xff, 0xe1, 0x4d), "tick": Color8(0xff, 0xf3, 0xb8), "again": Color8(0x7a, 0xe8, 0xff)}
const POP_GOLD := Color8(0xff, 0xc4, 0x1f)
## Fight pops (HUD on_event): hit numbers, crits in the signature window, "빗나감!" (wobbles), player damage.
const POP_SIZES: Dictionary = {"hit": 36, "crit": 46, "miss": 30, "dmg": 36, "big": 76, "tick": 26, "again": 34}
## Skill pops (docs/SKILLS.md 1-5): "big" = the summed skill damage (one large number), "tick" = a multi-hit tick,
## "again" = the t5 "한 번 더!" chip; they live longer than the plain hit pops.
## big 1.25 → 0.85 s (rvB): the jump's "쿵!" sat under the next skill banner.
const POP_LIFE_KIND: Dictionary = {"big": 0.85, "again": 1.3, "tick": 0.55}
const POP_OUTLINE := Color8(0x1b, 0x1c, 0x1f)
## 0.6 → 1.6 m (rvB): 0.6 m was ~10 px at the boss camera, so tack hits, skill ticks, "펑크!" and the taunt bubble
## all landed in the same ~80 px over the villain. Pops also step up out of each other on screen (_draw, ≤ 3 slots).
const POP_RISE_M: float = 1.6
const POP_RISE_PX: float = 40.0
const POP_STACK_MAX: int = 3
const POP_PUNCH_S: float = 0.25
const FONT_SIZE: int = 22
const POP_SIZE: int = 30
const POP_LIFE: float = 0.9
const MERGE_S: float = 0.4
const MERGE_PUNCH: float = 0.15
const PER_TARGET: int = 2
const FADE_S: float = 0.1
const POP_MARGIN: float = 8.0
const PRIO_OF_PREFIX: Dictionary = {"k": 5, "s": 4, "x": 4, "p": 3, "c": 2, "t": 1, "i": 1, "m": 1}

var camera: Camera3D
var font_body: Font
var font_display: Font
var now: float = 0.0
## Screen rects of the N5 icons shown this frame (SignalIcons.shown()[i].rect): a bubble body that would cover one
## slides sideways and its tail still ends on the anchor car (art review: lifting it made the tail point at the car
## ahead). The honk target itself gets no icon while its bubble is up (Game feeds anchored_ids() to SignalIcons).
var avoid_rects: Array[Rect2] = []
## Bubble bodies are kept inside this rect (HUD safe area); empty = whole control.
var safe_rect := Rect2()
## r3 U1: y under the top HUD (Hud.top_guard_y(), 0 = none) and the top HUD widget rects (Hud.top_rects()); set every
## frame by Hud.guard_bubbles(self).
var top_guard: float = 0.0
var top_rects: Array[Rect2] = []
var _items: Dictionary = {}        # key → {text, kind, until, born, pos}
var _order: Array[String] = []     # insertion order (oldest first) for the cap
var _pops: Array[Dictionary] = []  # {text, kind, born, upd, pos: Vector3 | sp: Vector2, key, value, target, prio, win, fade_at, punch_t}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_fonts()


func _fonts() -> void:
	if font_body == null:
		font_body = _font(FONT_BODY_PATH)
	if font_display == null:
		font_display = _font(FONT_DISPLAY_PATH)


func _font(path: String) -> Font:
	if ResourceLoader.exists(path):
		var f: Variant = load(path)
		if f is Font:
			return f as Font
	return ThemeDB.fallback_font


## web bubble(key, text, kind, dur, posFn): same key replaces the old bubble. pos_fn → Vector3 (world) or Vector2
## (screen anchor).
func show_bubble(key: String, text: String, kind: String, dur: float, pos_fn: Callable) -> void:
	if not _items.has(key):
		_order.append(key)
	var born: float = now
	if _items.has(key) and str(_items[key]["text"]) == text:
		born = float(_items[key]["born"])
	_items[key] = {"text": text, "kind": kind, "until": now + dur, "pos": pos_fn, "born": born}
	while _order.size() > MAX_BUBBLES:
		_items.erase(_order.pop_front())
	queue_redraw()


## web hud.popAt(pos, text, kind) + r3 U4 merge / cap (see the header).
func pop(pos: Vector3, text: String, kind: String = "warn", merge_key: String = "", value: float = 0.0, target: String = "",
		prio: int = -1) -> void:
	_add_pop({"pos": pos}, text, kind, merge_key, value, target, prio)


## A pop anchored on the screen (canvas units) instead of a world point; rises POP_RISE_PX.
func pop_screen(sp: Vector2, text: String, kind: String = "warn", merge_key: String = "", value: float = 0.0, target: String = "",
		prio: int = -1) -> void:
	_add_pop({"sp": sp}, text, kind, merge_key, value, target, prio)


func _add_pop(anchor: Dictionary, text: String, kind: String, mk: String, value: float, target: String, prio: int) -> void:
	if target.is_empty() and not mk.is_empty():
		target = Bubbles.target_of(mk)
	if prio < 0:
		prio = Bubbles.prio_of(mk, kind)
	var win: bool = text.begins_with("-") and text.ends_with("!")  # a window / bomb number ("-40!")
	if not mk.is_empty():
		for i: int in range(_pops.size() - 1, -1, -1):
			var p: Dictionary = _pops[i]
			if str(p["key"]) != mk or float(p["fade_at"]) >= 0.0 or now - float(p["upd"]) > MERGE_S:
				continue
			var total: float = float(p["value"]) + value
			p["value"] = total
			p["win"] = bool(p["win"]) or win
			var mt: String = Bubbles.merged_text(text, value, total)
			p["text"] = mt + "!" if bool(p["win"]) and mt.begins_with("-") and not mt.ends_with("!") else mt
			p["upd"] = now
			p["punch_t"] = now
			var life: float = _life(str(p["kind"]))
			p["born"] = maxf(float(p["born"]), now - life * 0.2)  # stays low and restarts its fade
			if anchor.has("pos"):
				p["pos"] = anchor["pos"]
			queue_redraw()
			return
	var np: Dictionary = {"text": text, "kind": kind, "born": now, "upd": now, "key": mk, "value": value, "target": target,
		"prio": prio, "win": win, "fade_at": -1.0, "punch_t": -99.0}
	np.merge(anchor)
	if not target.is_empty() and not _cap(target, np):
		return
	_pops.append(np)
	queue_redraw()


## "t3" / "c0" / "p12" … → "v<id>" (a villain), "m<id>" → "m<id>" (a mini); "" when the key carries no id.
static func target_of(mk: String) -> String:
	if mk.length() < 2 or not mk.substr(1).is_valid_int():
		return ""
	return ("m" if mk[0] == "m" else "v") + mk.substr(1)


static func prio_of(mk: String, kind: String) -> int:
	if not mk.is_empty() and PRIO_OF_PREFIX.has(mk[0]):
		return int(PRIO_OF_PREFIX[mk[0]])
	match kind:
		"big", "tick", "again":
			return 4
		"crit":
			return 2
	return 1


## The newest pop's text with its own number replaced by the running total ("-40!" + 40 → "-80!").
static func merged_text(text: String, value: float, total: float) -> String:
	var v: String = str(roundi(value))
	var at: int = text.rfind(v)
	if at < 0:
		return text
	return text.substr(0, at) + str(roundi(total)) + text.substr(at + v.length())


## ≤ PER_TARGET live pops of one target: the lowest priority (oldest on a tie) fades out; false = the new one is the
## lowest and is dropped.
func _cap(target: String, np: Dictionary) -> bool:
	var live: Array[Dictionary] = []
	for p: Dictionary in _pops:
		if str(p["target"]) == target and float(p["fade_at"]) < 0.0:
			live.append(p)
	while live.size() + 1 > PER_TARGET:
		var li: int = -1  # -1 = the new pop
		var low: Dictionary = np
		for i: int in live.size():
			var p: Dictionary = live[i]
			if int(p["prio"]) < int(low["prio"]) or (int(p["prio"]) == int(low["prio"]) and float(p["born"]) <= float(low["born"])):
				low = p
				li = i
		if li < 0:
			return false
		low["fade_at"] = now
		live.remove_at(li)
	return true


## Drops the live pops older than max_age (0 = all) except those of except_kind (HUD "kill": the stale "-40" tack
## stacks must not ride into the finisher frames; the kill tick's own pops stay).
func clear_pops(max_age: float = 0.0, except_kind: String = "") -> void:
	var keep: Array[Dictionary] = []
	for p: Dictionary in _pops:
		if (not except_kind.is_empty() and str(p["kind"]) == except_kind) or (max_age > 0.0 and now - float(p["born"]) <= max_age):
			keep.append(p)
	_pops = keep
	queue_redraw()


func pop_count() -> int:
	return _pops.size()


## Live (not fading) pops of one target ("v0", "m3").
func live_count(target: String) -> int:
	var n: int = 0
	for p: Dictionary in _pops:
		if str(p["target"]) == target and float(p["fade_at"]) < 0.0:
			n += 1
	return n


## Pop texts, oldest first (live_only: without the fading ones).
func texts_pops(live_only: bool = false) -> PackedStringArray:
	var out := PackedStringArray()
	for p: Dictionary in _pops:
		if not live_only or float(p["fade_at"]) < 0.0:
			out.append(str(p["text"]))
	return out


## Car ids that currently have a reply bubble (keys "h<id>").
func anchored_ids() -> Dictionary:
	var out: Dictionary = {}
	for k: String in _order:
		if k.begins_with("h") and k.substr(1).is_valid_int():
			out[k.substr(1).to_int()] = true
	return out


func count() -> int:
	return _items.size()


func texts() -> PackedStringArray:
	var out := PackedStringArray()
	for k: String in _order:
		out.append(str(_items[k]["text"]))
	return out


func step(t: float) -> void:
	now = t
	for k: String in _order.duplicate():
		if float(_items[k]["until"]) < now:
			_items.erase(k)
			_order.erase(k)
	var keep: Array[Dictionary] = []
	for p: Dictionary in _pops:
		var fa: float = float(p["fade_at"])
		if fa >= 0.0 and now - fa >= FADE_S:
			continue
		if now - float(p["born"]) < _life(str(p["kind"])):
			keep.append(p)
	_pops = keep
	queue_redraw()


func _life(kind: String) -> float:
	return float(POP_LIFE_KIND.get(kind, POP_LIFE))


func size_or_viewport() -> Vector2:
	return size if size.x > 0.0 else get_viewport_rect().size


func _keep() -> Rect2:
	return safe_rect if safe_rect.has_area() else Rect2(Vector2.ZERO, size_or_viewport())


# ───────────────────────────── bubble layout (r3 U1)

## Every live bubble this frame, as _draw paints it: anchors projected (world) or taken as is (screen); behind the
## camera / under the screen bottom = not drawn; one docked bubble per frame (the newest born).
func layout() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var dock_i: int = -1
	var vh: float = size_or_viewport().y
	for k: String in _order:
		var b: Dictionary = _items[k]
		var a: Variant = (b["pos"] as Callable).call()
		var anchor := Vector2.INF
		if a is Vector2:
			anchor = a
		elif a is Vector3:
			var wp: Vector3 = a
			if not wp.is_finite() or camera == null or not camera.is_inside_tree() or camera.is_position_behind(wp):
				continue
			anchor = camera.unproject_position(wp)
		if not anchor.is_finite() or anchor.y > vh + 40.0:
			continue
		var e: Dictionary = layout_bubble(anchor, str(b["text"]), str(b["kind"]))
		e["key"] = k
		e["born"] = float(b["born"])
		e["villain"] = k.begins_with("v")
		if str(e["mode"]) == "dock":
			if e["villain"] and str(b["kind"]) == "taunt":
				e["border"] = VILLAIN_RED
			if dock_i >= 0 and float(out[dock_i]["born"]) > float(e["born"]):
				continue
			if dock_i >= 0:
				out.remove_at(dock_i)
			dock_i = out.size()
		out.append(e)
	return out


func _font_of(kind: String) -> Font:
	_fonts()
	return font_display if kind == "angry" or kind == "taunt" else font_body


func _body_size(f: Font, text: String) -> Vector2:
	var ts: Vector2 = f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE)
	return Vector2(ts.x + 36.0, f.get_height(FONT_SIZE) + 18.0)


## One bubble at a screen anchor: mode up (web look: body above the anchor, tail down), flip (the body would meet the top
## HUD and the anchor is under the guard: body under the anchor, tail up, tip on the anchor) or dock (anchor above the
## guard / off the top: body at guard + DOCK_GAP, x clamped into the safe rect, tail up toward the anchor). legacy =
## the pre-r3 rule (side slide + notch only), for the before/after numbers in tests and the probe.
func layout_bubble(anchor: Vector2, text: String, kind: String, legacy: bool = false) -> Dictionary:
	var f: Font = _font_of(kind)
	var bs: Vector2 = _body_size(f, text)
	var keep: Rect2 = _keep()
	anchor.x = clampf(anchor.x, keep.position.x + EDGE, keep.end.x - EDGE)
	var e: Dictionary = {"key": "", "text": text, "kind": kind, "anchor": anchor, "villain": false, "border": INK, "born": now}
	var up: Rect2 = _slide(Rect2(Vector2(anchor.x - bs.x / 2.0, anchor.y - TAIL - bs.y), bs), keep)
	if legacy:
		if up.position.y < keep.position.y:  # pre-r3: under the notch it moved the whole bubble down to the safe top
			var dy: float = keep.position.y - up.position.y
			up.position.y += dy
			anchor.y += dy
		e.merge({"mode": "up", "body": up, "tip": anchor}, true)
		return e
	if _clear(up, keep):
		e.merge({"mode": "up", "body": up, "tip": anchor}, true)
		return e
	var guard: float = maxf(top_guard, keep.position.y)
	if anchor.y >= guard:
		var dn: Rect2 = _slide(Rect2(Vector2(anchor.x - bs.x / 2.0, anchor.y + TAIL), bs), keep)
		e.merge({"mode": "flip", "body": dn, "tip": anchor}, true)
		return e
	var x0: float = clampf(anchor.x - bs.x / 2.0, keep.position.x + EDGE, maxf(keep.position.x + EDGE, keep.end.x - EDGE - bs.x))
	var dock := Rect2(Vector2(x0, guard + DOCK_GAP), bs)
	var tip := Vector2(clampf(anchor.x, dock.position.x + 16.0, dock.end.x - 16.0), dock.position.y - DOCK_TAIL)
	e.merge({"mode": "dock", "body": dock, "tip": tip}, true)
	return e


## Side slide off the N5 icons (smaller move wins; the tail tip stays on the anchor), then x kept inside the safe rect.
func _slide(body: Rect2, keep: Rect2) -> Rect2:
	for q: Rect2 in avoid_rects:
		var g: Rect2 = body.grow(3.0)
		if g.intersects(q):
			var right: float = q.end.x + 3.0 - g.position.x
			var left: float = q.position.x - 3.0 - g.end.x
			body.position.x += right if absf(right) < absf(left) else left
	if body.position.x < keep.position.x + EDGE:
		body.position.x = keep.position.x + EDGE
	elif body.end.x > keep.end.x - EDGE:
		body.position.x = keep.end.x - EDGE - body.size.x
	return body


## Body clear of the notch / safe top and of every top HUD rect (top_guard alone when no rects are given).
func _clear(body: Rect2, keep: Rect2) -> bool:
	if body.position.y < keep.position.y + 2.0:
		return false
	if top_rects.is_empty():
		return top_guard <= 0.0 or body.position.y >= top_guard
	var g: Rect2 = body.grow(2.0)
	for r: Rect2 in top_rects:
		if g.intersects(r):
			return false
	return true


# ───────────────────────────── pop layout (r3 U4)

## Screen rects (punch + outline + tilt) of the pops drawn now, oldest first (tests: ⊂ safe_rect).
func pop_rects() -> Array[Rect2]:
	var out: Array[Rect2] = []
	for d: Dictionary in _pop_layout():
		out.append(d["rect"])
	return out


## [{p, sp, rect, rot, punch, fs, col, w, ow}] youngest first, stacked, clamped (what _draw paints).
func _pop_layout() -> Array[Dictionary]:
	_fonts()
	var out: Array[Dictionary] = []
	var keep: Rect2 = _keep()
	var taken: Array[Rect2] = []  # pop rects drawn this frame, youngest first: a newer pop never hides under an older one
	for pi: int in range(_pops.size() - 1, -1, -1):
		var p: Dictionary = _pops[pi]
		var kind: String = str(p["kind"])
		var t: float = now - float(p["born"])
		var age: float = clampf(t / _life(kind), 0.0, 1.0)
		var sp: Vector2
		if p.has("sp"):
			sp = (p["sp"] as Vector2) - Vector2(0, POP_RISE_PX * age)
		else:
			if camera == null or not camera.is_inside_tree():
				continue
			var wp: Vector3 = p["pos"]
			var lifted: Vector3 = wp + Vector3(0, POP_RISE_M * age, 0)  # rises in the world, so it clears the roof
			if not wp.is_finite() or camera.is_position_behind(wp) or camera.is_position_behind(lifted):
				continue
			sp = camera.unproject_position(lifted)
		var col: Color = POP_GOLD if bool(p["win"]) else POP_COLOR.get(kind, Color.WHITE)
		col.a = 1.0 - age * age
		var fa: float = float(p["fade_at"])
		if fa >= 0.0:
			col.a *= clampf(1.0 - (now - fa) / FADE_S, 0.0, 1.0)
		var fs: int = int(POP_SIZES.get(kind, POP_SIZE))
		var amp: float = 0.55 if kind in ["crit", "big", "again"] else 0.25
		var punch: float = 1.0 + amp * sin(PI * clampf(t / POP_PUNCH_S, 0.0, 1.0))  # 1.0 → 1.25 → 1.0
		var mt: float = now - float(p["punch_t"])
		if mt >= 0.0 and mt < 0.2:  # every merge punches 1.15 again
			punch = maxf(punch, 1.0 + MERGE_PUNCH * sin(PI * mt / 0.2))
		var rot: float = sin(t * 40.0) * 0.12 * (1.0 - age) if kind == "miss" else (deg_to_rad(-6.0) if kind in ["crit", "big"] else 0.0)
		var text: String = str(p["text"])
		var w: float = font_display.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var ow: float = 8.0 if fs > 32 else 6.0
		var asc: float = font_display.get_ascent(fs)
		var desc: float = font_display.get_descent(fs) + 3.0  # + the drop shadow
		var tilt: float = absf(sin(rot))
		var fit: float = (keep.size.x - 2.0 * (POP_MARGIN + ow)) / maxf(1.0, w + tilt * (asc + desc))
		punch = minf(punch, maxf(0.5, fit))  # the punch never makes a big number wider than the safe width
		var half: float = w * 0.5 * punch + ow + tilt * (asc + desc) * punch * 0.5
		var up_h: float = asc * punch + ow + tilt * w * 0.5 * punch
		var dn_h: float = desc * punch + ow + tilt * w * 0.5 * punch
		var lo: float = keep.position.x + POP_MARGIN + half
		var hi: float = keep.end.x - POP_MARGIN - half
		sp.x = clampf(sp.x, lo, maxf(lo, hi))  # a pop near the edge stays whole ('치명! -150' was cut to '명! -150')
		if sp.y - up_h < keep.position.y + POP_MARGIN:
			sp.y = keep.position.y + POP_MARGIN + up_h
		var r := Rect2(sp.x - half, sp.y - up_h, half * 2.0, up_h + dn_h)
		for _k: int in POP_STACK_MAX:
			var hit: bool = false
			for q: Rect2 in taken:
				if r.intersects(q):
					hit = true
					break
			if not hit or r.position.y - float(fs) * 1.2 < keep.position.y + POP_MARGIN:
				break
			sp.y -= float(fs) * 1.2
			r.position.y -= float(fs) * 1.2
		taken.append(r)
		out.append({"p": p, "sp": sp, "rect": r, "rot": rot, "punch": punch, "fs": fs, "col": col, "w": w, "ow": int(ow)})
	return out


func _draw() -> void:
	for e: Dictionary in layout():
		_draw_entry(e)
	for d: Dictionary in _pop_layout():
		var p: Dictionary = d["p"]
		var col: Color = d["col"]
		var fs: int = int(d["fs"])
		var punch: float = float(d["punch"])
		draw_set_transform(d["sp"] as Vector2, float(d["rot"]), Vector2(punch, punch))
		var at := Vector2(-float(d["w"]) / 2.0, 0)
		var ink := Color(POP_OUTLINE, col.a)
		var ow: int = int(d["ow"])
		var text: String = str(p["text"])
		draw_string_outline(font_display, at + Vector2(0, 3), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, ow, Color(ink, ink.a * 0.6))
		draw_string_outline(font_display, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, ow, ink)
		draw_string(font_display, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## .ui-bubble: 3 px ink border, radius 18, 5 px drop shadow, tail from the body to the tip (down for up, up for flip /
## dock). Drawn in tip-local coordinates (angry tilts −2° about the tip).
func _draw_entry(e: Dictionary) -> void:
	var kind: String = str(e["kind"])
	var text: String = str(e["text"])
	var f: Font = _font_of(kind)
	var tip: Vector2 = e["tip"]
	var body: Rect2 = e["body"]
	var rect := Rect2(body.position - tip, body.size)
	var below: bool = rect.position.y > 0.0  # body under the tip: the tail points up
	var base_y: float = rect.position.y + 4.0 if below else rect.end.y - 4.0
	var dx: float = clampf(rect.get_center().x, rect.position.x + 16.0, rect.end.x - 16.0)  # tail root under the body
	if str(e["mode"]) == "dock":
		dx = clampf(0.0, rect.position.x + 16.0, rect.end.x - 16.0)
	var tip_l := Vector2(-6.0 if str(e["mode"]) == "up" else 0.0, 0.0)
	var bg: Color = BG.get(kind, Color.WHITE)
	var tilt: float = deg_to_rad(-2.0) if kind == "angry" else 0.0
	var border: Color = e.get("border", INK)
	draw_set_transform(tip, tilt, Vector2.ONE)
	var sh := StyleBoxFlat.new()
	sh.bg_color = Color(INK, 0.85)
	sh.set_corner_radius_all(18)
	draw_style_box(sh, Rect2(rect.position + Vector2(0, 5), rect.size))
	draw_colored_polygon(PackedVector2Array([Vector2(dx - 11, base_y), Vector2(dx + 5, base_y), tip_l]), border)
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(5 if border != INK else 4)
	sb.set_corner_radius_all(18)
	draw_style_box(sb, rect)
	var tip2 := tip_l.lerp(Vector2(dx - 3, base_y), 0.4)
	draw_colored_polygon(PackedVector2Array([Vector2(dx - 7, base_y), Vector2(dx + 1, base_y), tip2]), bg)
	var pad := Vector2(18, 9)
	var base := Vector2(rect.position.x + pad.x, rect.position.y + pad.y + f.get_ascent(FONT_SIZE))
	var fg: Color = INK if kind == "taunt" or kind == "player" else Color.WHITE
	if fg == Color.WHITE:
		draw_string_outline(f, base, text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, 5, INK)
	draw_string(f, base, text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, fg)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
