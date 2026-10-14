class_name Bubbles
extends Control
## Speech bubbles and pop text over cars (web main.js:96 bubble() / hud.popAt + ui.js .ui-bubble, css 409-430).
## key → {text, kind, until, pos: Callable() -> Vector3}; projected through the 3D camera every frame, hidden when
## behind the camera. Kinds: thanks (green), angry (red, tilted −2°), taunt (white), player (yellow); pops are plain
## outlined text that rises and fades (warn / score). The web caps live bubbles at 8, so does this.
## Sizes: the web's 16 CSS px on a ~390 pt phone ≈ 22 units on the 540-wide canvas.

const MAX_BUBBLES: int = 8
const FONT_BODY_PATH: String = "res://ui/fonts/Jua-Regular.ttf"
const FONT_DISPLAY_PATH: String = "res://ui/fonts/BlackHanSans-Regular.ttf"
const INK := Color8(0x17, 0x20, 0x2b)
const BG: Dictionary = {
	"thanks": Color8(0x2f, 0xd1, 0x7e), "angry": Color8(0xff, 0x5a, 0x3c),
	"taunt": Color(1, 1, 1), "player": Color8(0xff, 0xd2, 0x3f),
}
## warn pops are white with a dark outline: the old yellow vanished on the yellow hero roof (art review).
const POP_COLOR: Dictionary = {"warn": Color.WHITE, "score": Color8(0x8d, 0xff, 0xbb), "hit": Color8(0xff, 0xd2, 0x3f),
	"crit": Color8(0xff, 0x9a, 0x2e), "miss": Color8(0xc9, 0xd3, 0xdf), "dmg": Color8(0xff, 0x5a, 0x4a),
	"big": Color8(0xff, 0xe1, 0x4d), "tick": Color8(0xff, 0xf3, 0xb8), "again": Color8(0x7a, 0xe8, 0xff)}
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
const POP_STACK_MAX: int = 3
const POP_PUNCH_S: float = 0.25
const FONT_SIZE: int = 22
const POP_SIZE: int = 30
const POP_LIFE: float = 0.9

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
var _items: Dictionary = {}        # key → {text, kind, until, pos}
var _order: Array[String] = []     # insertion order (oldest first) for the cap
var _pops: Array[Dictionary] = []  # {text, kind, born, pos: Vector3}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	font_body = _font(FONT_BODY_PATH)
	font_display = _font(FONT_DISPLAY_PATH)


func _font(path: String) -> Font:
	if ResourceLoader.exists(path):
		var f: Variant = load(path)
		if f is Font:
			return f as Font
	return ThemeDB.fallback_font


## web bubble(key, text, kind, dur, posFn): same key replaces the old bubble.
func show_bubble(key: String, text: String, kind: String, dur: float, pos_fn: Callable) -> void:
	if not _items.has(key):
		_order.append(key)
	_items[key] = {"text": text, "kind": kind, "until": now + dur, "pos": pos_fn}
	while _order.size() > MAX_BUBBLES:
		_items.erase(_order.pop_front())
	queue_redraw()


## web hud.popAt(pos, text, kind)
func pop(pos: Vector3, text: String, kind: String = "warn") -> void:
	_pops.append({"text": text, "kind": kind, "born": now, "pos": pos})
	queue_redraw()


## Drops every live pop except those of except_kind (HUD "kill": the stale "-4!" tack pops must not ride into the
## finisher frames; the kill's own sum stays).
func clear_pops(except_kind: String = "") -> void:
	var keep: Array[Dictionary] = []
	for p: Dictionary in _pops:
		if str(p["kind"]) == except_kind:
			keep.append(p)
	_pops = keep
	queue_redraw()


func pop_count() -> int:
	return _pops.size()


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
		if now - float(p["born"]) < float(POP_LIFE_KIND.get(str(p["kind"]), POP_LIFE)):
			keep.append(p)
	_pops = keep
	queue_redraw()


func _draw() -> void:
	if camera == null or not camera.is_inside_tree():
		return
	for k: String in _order:
		var b: Dictionary = _items[k]
		var wp: Vector3 = (b["pos"] as Callable).call()
		if not wp.is_finite() or camera.is_position_behind(wp):
			continue
		_draw_bubble(camera.unproject_position(wp), str(b["text"]), str(b["kind"]))
	var taken: Array[Rect2] = []  # pop rects drawn this frame, youngest first: a newer pop never hides under an older one
	for pi: int in range(_pops.size() - 1, -1, -1):
		var p: Dictionary = _pops[pi]
		var wp: Vector3 = p["pos"]
		if camera.is_position_behind(wp):
			continue
		var t: float = now - float(p["born"])
		var age: float = clampf(t / float(POP_LIFE_KIND.get(str(p["kind"]), POP_LIFE)), 0.0, 1.0)
		var lifted: Vector3 = wp + Vector3(0, POP_RISE_M * age, 0)  # rises in the world, so it clears the roof
		if camera.is_position_behind(lifted):
			continue
		var sp: Vector2 = camera.unproject_position(lifted)
		var col: Color = POP_COLOR.get(str(p["kind"]), Color.WHITE)
		col.a = 1.0 - age * age
		var kind: String = str(p["kind"])
		var fs: int = int(POP_SIZES.get(kind, POP_SIZE))
		var amp: float = 0.55 if kind in ["crit", "big", "again"] else 0.25
		var punch: float = 1.0 + amp * sin(PI * clampf(t / POP_PUNCH_S, 0.0, 1.0))  # 1.0 → 1.25 → 1.0
		var rot: float = sin(t * 40.0) * 0.12 * (1.0 - age) if kind == "miss" else (deg_to_rad(-6.0) if kind in ["crit", "big"] else 0.0)
		var w: float = font_display.get_string_size(str(p["text"]), HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var vw: float = size_or_viewport().x
		sp.x = clampf(sp.x, w * 0.65 + 8.0, maxf(w * 0.65 + 8.0, vw - w * 0.65 - 8.0))  # a pop near the edge stays whole
		var r := Rect2(sp + Vector2(-w / 2.0, -float(fs)) * 1.2, Vector2(w, float(fs)) * 1.2)  # punch 1.25 + outline
		for _k: int in POP_STACK_MAX:
			var hit: bool = false
			for q: Rect2 in taken:
				if r.intersects(q):
					hit = true
					break
			if not hit:
				break
			sp.y -= float(fs) * 1.2
			r.position.y -= float(fs) * 1.2
		taken.append(r)
		draw_set_transform(sp, rot, Vector2(punch, punch))
		var at := Vector2(-w / 2.0, 0)
		var ink := Color(POP_OUTLINE, col.a)
		var ow: int = 8 if fs > 32 else 6
		draw_string_outline(font_display, at + Vector2(0, 3), str(p["text"]), HORIZONTAL_ALIGNMENT_LEFT, -1, fs, ow, Color(ink, ink.a * 0.6))
		draw_string_outline(font_display, at, str(p["text"]), HORIZONTAL_ALIGNMENT_LEFT, -1, fs, ow, ink)
		draw_string(font_display, at, str(p["text"]), HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func size_or_viewport() -> Vector2:
	return size if size.x > 0.0 else get_viewport_rect().size


## .ui-bubble: tail tip at the anchor, body 9 px above it, centred; 3 px ink border, radius 14, 4 px drop shadow.
func _draw_bubble(anchor: Vector2, text: String, kind: String) -> void:
	var f: Font = font_display if kind == "angry" or kind == "taunt" else font_body
	var ts: Vector2 = f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE)
	var pad := Vector2(18, 9)
	var size := Vector2(ts.x + pad.x * 2.0, f.get_height(FONT_SIZE) + pad.y * 2.0)
	var rect := Rect2(Vector2(-size.x / 2.0, -12.0 - size.y), size)
	# slide the body sideways off any icon (smaller move wins); the tail tip stays on the anchor
	for q: Rect2 in avoid_rects:
		var body := Rect2(anchor + rect.position, rect.size).grow(3.0)
		if body.intersects(q):
			var right: float = q.end.x + 3.0 - body.position.x
			var left: float = q.position.x - 3.0 - body.end.x
			rect.position.x += right if absf(right) < absf(left) else left
	var keep: Rect2 = safe_rect if safe_rect.has_area() else Rect2(Vector2.ZERO, size_or_viewport())
	var body_abs := Rect2(anchor + rect.position, rect.size)
	if body_abs.position.x < keep.position.x + 6.0:
		rect.position.x += keep.position.x + 6.0 - body_abs.position.x
	elif body_abs.end.x > keep.end.x - 6.0:
		rect.position.x -= body_abs.end.x - (keep.end.x - 6.0)
	if anchor.y + rect.position.y < keep.position.y:  # under the notch: show it below the anchor instead of hiding it
		anchor.y = keep.position.y - rect.position.y
	var dx: float = clampf(rect.get_center().x, rect.position.x + 16.0, rect.end.x - 16.0)  # tail root under the body
	var bg: Color = BG.get(kind, Color.WHITE)
	var tilt: float = deg_to_rad(-2.0) if kind == "angry" else 0.0
	draw_set_transform(anchor, tilt, Vector2.ONE)
	var sh := StyleBoxFlat.new()
	sh.bg_color = Color(INK, 0.85)
	sh.set_corner_radius_all(18)
	draw_style_box(sh, Rect2(rect.position + Vector2(0, 5), rect.size))
	var tail := PackedVector2Array([Vector2(dx - 11, -12.0 - 4.0), Vector2(dx + 5, -12.0 - 4.0), Vector2(-6, 0)])
	draw_colored_polygon(tail, INK)
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = INK
	sb.set_border_width_all(4)
	sb.set_corner_radius_all(18)
	draw_style_box(sb, rect)
	var tip := Vector2(-6, 0).lerp(Vector2(dx - 3, -16), 0.4)
	draw_colored_polygon(PackedVector2Array([Vector2(dx - 7, -16), Vector2(dx + 1, -16), tip]), bg)
	var base := Vector2(rect.position.x + pad.x, rect.position.y + pad.y + f.get_ascent(FONT_SIZE))
	var fg: Color = INK if kind == "taunt" or kind == "player" else Color.WHITE
	if fg == Color.WHITE:
		draw_string_outline(f, base, text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, 5, INK)
	draw_string(f, base, text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, fg)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
