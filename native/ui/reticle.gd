class_name Reticle
extends Control
## N4 lock-on reticle (NATIVE_PORT M1d N4, DESIGN_REVIEW P0#2): follows the target car on screen (world → screen via
## Camera3D.unproject_position of RoadGraph.position(s, x)). In range: four green brackets snap in from 2× and turn
## slowly, a "LOCK" tag above; inside the signature window they go gold with "약점!" and pulse faster. Out of range:
## a grey dashed ring with chevrons pointing to the lane the player has to move to (dir −1 = ◀, +1 = ▶). Off screen
## or behind the camera: an edge arrow at the screen border. Time is real time fed by advance() (deterministic shots).

const GREEN := Color8(0x3c, 0xe0, 0x8e)
const GOLD := Color8(0xff, 0xc4, 0x1f)
const GREY := Color8(0xb8, 0xc0, 0xcc)
const INK := UiDraw.INK

var camera: Camera3D
var road: RoadGraph
## {s, x, len, active, in_range, dir, vulnerable}; empty = hidden.
var target: Dictionary = {}
## Screen rect the reticle must stay in (HUD safe rect); empty = whole control.
var bounds := Rect2()
var now: float = 0.0
var _lock_at: float = -99.0
var _was_in: bool = false
var _alpha: float = 0.0
## Last drawn centre / radius (tests: the reticle sits on the target car).
var screen_pos := Vector2(-1, -1)
var screen_r: float = 0.0
var on_screen: bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func set_target(t: Dictionary) -> void:
	var was_active: bool = not target.is_empty() and bool(target.get("active", false))
	target = t
	var inr: bool = not t.is_empty() and bool(t.get("in_range", false))
	if inr and not _was_in:
		_lock_at = now
	if t.is_empty() or not bool(t.get("active", false)):
		inr = false
	if not was_active and t.is_empty():
		_alpha = 0.0
	_was_in = inr


## Seconds since the reticle last acquired (in range); large when not locked.
func locked_for() -> float:
	return now - _lock_at if _was_in else -1.0


func advance(dt: float) -> void:
	now += dt
	var want: float = 1.0 if not target.is_empty() and bool(target.get("active", false)) else 0.0
	_alpha = move_toward(_alpha, want, dt / 0.18)
	_project()
	queue_redraw()


func _project() -> void:
	on_screen = false
	if camera == null or road == null or target.is_empty() or not camera.is_inside_tree():
		return
	var s: float = float(target.get("s", 0.0))
	var x: float = float(target.get("x", 0.0))
	var wp: Vector3 = road.position(s, x) + Vector3(0, 0.9, 0)
	if camera.is_position_behind(wp):
		screen_pos = Vector2(size.x * 0.5, size.y + 40.0)
		return
	screen_pos = camera.unproject_position(wp)
	var half: float = float(target.get("len", 4.6)) * 0.5
	var a: Vector2 = camera.unproject_position(road.position(s - half, x))
	var b: Vector2 = camera.unproject_position(road.position(s + half, x))
	var c: Vector2 = camera.unproject_position(road.position(s, x - 1.0))
	var d: Vector2 = camera.unproject_position(road.position(s, x + 1.0))
	screen_r = clampf(maxf(a.distance_to(b), c.distance_to(d) * 1.0) * 0.62 + 10.0, 34.0, 96.0)
	var keep: Rect2 = bounds if bounds.has_area() else Rect2(Vector2.ZERO, size)
	on_screen = keep.grow(-8.0).has_point(screen_pos)


func _draw() -> void:
	if _alpha <= 0.01 or target.is_empty():
		return
	var keep: Rect2 = bounds if bounds.has_area() else Rect2(Vector2.ZERO, size)
	if not on_screen:
		_edge_arrow(keep)
		return
	var inr: bool = bool(target.get("in_range", false))
	var vul: bool = inr and bool(target.get("vulnerable", false))
	var c: Vector2 = screen_pos
	var r: float = screen_r
	if inr:
		var col: Color = GOLD if vul else GREEN
		col.a = _alpha
		var lt: float = now - _lock_at
		var snap: float = 1.0 + 1.0 * (1.0 - UiDraw.back_out(lt / 0.2, 2.2))
		var pulse: float = 1.0 + (0.08 if vul else 0.04) * sin(now * (16.0 if vul else 7.0))
		var rr: float = r * snap * pulse
		var rot: float = now * 0.9 + (1.0 - clampf(lt / 0.2, 0.0, 1.0)) * 1.2
		draw_arc(c, rr * 0.72, 0.0, TAU, 48, Color(col, 0.35 * _alpha), 3.0, true)
		for sg: Vector2 in [Vector2(1, 1), Vector2(-1, 1), Vector2(-1, -1), Vector2(1, -1)]:
			_bracket(c, rr, rot, sg, col)
		draw_circle(c, 5.0, Color(INK, _alpha))
		draw_circle(c, 3.0, col)
		var tag: String = "약점!" if vul else "LOCK"
		var ty: float = c.y + rr + 26.0  # below: hit numbers rise above the car
		var tw: float = UiDraw.text_w(tag, 20) + 22.0
		var tr := Rect2(Vector2(c.x - tw * 0.5, ty - 16.0), Vector2(tw, 30.0))
		draw_style_box(UiDraw.box(Color(INK, 0.85 * _alpha), 10.0), Rect2(tr.position + Vector2(0, 3), tr.size))
		draw_style_box(UiDraw.box(Color(col, _alpha), 10.0, 3.0, Color(INK, _alpha)), tr)
		UiDraw.text_c(self, tr.get_center(), tag, 20, Color(INK, _alpha), 0, true, 0.0)
	else:
		var gc := Color(GREY, 0.9 * _alpha)
		var n: int = 16
		for i: int in n:
			var a0: float = TAU * float(i) / float(n) + now * 0.25
			draw_arc(c, r * 0.9, a0, a0 + TAU / float(n) * 0.55, 6, Color(INK, 0.6 * _alpha), 7.0, true)
			draw_arc(c, r * 0.9, a0, a0 + TAU / float(n) * 0.55, 6, gc, 4.0, true)
		draw_circle(c, 4.0, gc)
		# chevrons on the player's side of the ring, flowing toward the villain: "move this way" (dir −1 = ◀)
		var dir: int = int(target.get("dir", 0))
		if dir != 0:
			for k: int in 3:
				var ph: float = fposmod(now * 1.8 + float(k) / 3.0, 1.0)
				var ox: float = -float(dir) * (r * 0.9 + 16.0 + (1.0 - ph) * 44.0)
				var col2 := Color(Color.WHITE, _alpha * sin(PI * ph))
				_chevron(c + Vector2(ox, 0), float(dir), 14.0, col2)


## L-shaped corner bracket of a square of half-diagonal r rotated by `rot`; sg = corner signs (±1, ±1).
func _bracket(c: Vector2, r: float, rot: float, sg: Vector2, col: Color) -> void:
	var ex := Vector2(cos(rot), sin(rot))
	var ey := Vector2(-ex.y, ex.x)
	var corner: Vector2 = c + (ex * sg.x + ey * sg.y) * (r * 0.72)
	var arm: float = r * 0.4
	var p1: Vector2 = corner - ex * sg.x * arm
	var p2: Vector2 = corner - ey * sg.y * arm
	var ink := Color(INK, col.a)
	draw_polyline(PackedVector2Array([p1, corner, p2]), ink, 10.0, true)
	draw_polyline(PackedVector2Array([p1, corner, p2]), col, 5.5, true)


func _chevron(c: Vector2, dir: float, h: float, col: Color) -> void:
	var pts := PackedVector2Array([c + Vector2(-dir * h * 0.5, -h), c + Vector2(dir * h * 0.5, 0), c + Vector2(-dir * h * 0.5, h)])
	draw_polyline(pts, Color(INK, col.a), 9.0, true)
	draw_polyline(pts, col, 5.0, true)


func _edge_arrow(keep: Rect2) -> void:
	var inner: Rect2 = keep.grow(-34.0)
	var ctr: Vector2 = inner.get_center()
	var d: Vector2 = screen_pos - ctr
	if d.length() < 1.0:
		return
	var t: float = INF
	if absf(d.x) > 0.001:
		t = minf(t, (inner.size.x * 0.5) / absf(d.x))
	if absf(d.y) > 0.001:
		t = minf(t, (inner.size.y * 0.5) / absf(d.y))
	var p: Vector2 = ctr + d * minf(t, 1.0)
	var ang: float = d.angle()
	var inr: bool = bool(target.get("in_range", false))
	var col := Color(GREEN if inr else GREY, _alpha)
	var tri := PackedVector2Array([Vector2(18, 0), Vector2(-10, -14), Vector2(-10, 14)])
	var ink := PackedVector2Array()
	var face := PackedVector2Array()
	for q: Vector2 in tri:
		ink.append(p + (q * 1.35).rotated(ang))
		face.append(p + q.rotated(ang))
	draw_colored_polygon(ink, Color(INK, _alpha))
	draw_colored_polygon(face, col)
