class_name ScrBackdrop
extends Control
## Static stand-in for the web title flyover (NATIVE_PARITY A4 → M2): dusk sky, hills, a 4-lane highway in
## perspective with a jammed column of tail lights, lane dashes scrolling at 4.5 m/s. Drawn, no assets.

const SPEED_MS: float = 4.5
var t: float = 0.0
var animate: bool = true


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(delta: float) -> void:
	if animate and is_visible_in_tree():
		t += delta
		queue_redraw()


func _draw() -> void:
	var w: float = size.x
	var h: float = size.y
	var hz: float = h * 0.30
	# sky: 6 bands from deep blue to warm haze
	var sky: Array[Color] = [Color("#16233d"), Color("#1d3354"), Color("#29466a"), Color("#3d5b7c"), Color("#64708a"), Color("#8b7f8c")]
	var bh: float = hz / sky.size()
	for i: int in sky.size():
		draw_rect(Rect2(0, i * bh, w, bh + 1), sky[i])
	# hills
	var hills := PackedVector2Array([Vector2(0, hz), Vector2(0, hz - 40)])
	for k: int in 9:
		var x: float = w * (k + 0.5) / 8.0
		hills.append(Vector2(x, hz - 30.0 - 26.0 * sin(k * 1.7 + 0.6) - 10.0 * float(k % 2)))
	hills.append(Vector2(w, hz - 36))
	hills.append(Vector2(w, hz))
	draw_colored_polygon(hills, Color("#2f4a3e"))
	draw_rect(Rect2(0, hz, w, h - hz), Color("#355a3f"))
	# road trapezoid
	var cx: float = w * 0.5
	var top_w: float = w * 0.10
	var bot_w: float = w * 1.6
	var road := PackedVector2Array([Vector2(cx - top_w, hz), Vector2(cx + top_w, hz), Vector2(cx + bot_w * 0.5, h), Vector2(cx - bot_w * 0.5, h)])
	draw_colored_polygon(road, Color("#3b3f46"))
	# lane lines (4 lanes + shoulder): x(u, y) for u in [-1, 1]
	var lx := func(u: float, y: float) -> float:
		var k: float = (y - hz) / (h - hz)
		return cx + u * lerpf(top_w, bot_w * 0.5, k)
	draw_line(Vector2(lx.call(-0.98, hz), hz), Vector2(lx.call(-0.98, h), h), Color("#ffcf33"), 4.0)
	draw_line(Vector2(lx.call(0.62, hz), hz), Vector2(lx.call(0.62, h), h), Color("#e8e8e0"), 3.0)
	var phase: float = fmod(t * SPEED_MS * 0.12, 1.0)
	for u: float in [-0.58, -0.18, 0.22]:
		for j: int in 14:
			var a: float = (float(j) + phase) / 14.0
			var b: float = (float(j) + phase + 0.45) / 14.0
			var ya: float = hz + (h - hz) * a * a
			var yb: float = hz + (h - hz) * b * b
			draw_line(Vector2(lx.call(u, ya), ya), Vector2(lx.call(u, yb), yb), Color(0.91, 0.91, 0.88, 0.8), maxf(1.0, 5.0 * b))
	# jammed traffic: tail-light pairs receding to the horizon
	for lane: int in 4:
		var u0: float = -0.78 + lane * 0.4
		for j: int in 9:
			var a: float = 0.08 + j * 0.105
			var y: float = hz + (h - hz) * a * a
			var s: float = lerpf(0.06, 1.0, a)
			var x: float = lx.call(u0, y)
			var cw: float = 70.0 * s
			var ch: float = 44.0 * s
			var body := Color("#c9ccd2") if (lane + j) % 3 == 0 else Color("#2f6fd6") if (lane + j) % 3 == 1 else Color("#d9c9a3")
			draw_rect(Rect2(x - cw * 0.5, y - ch, cw, ch), body)
			draw_rect(Rect2(x - cw * 0.5, y - ch, cw, ch), Color("#17202b"), false, maxf(1.0, 3.0 * s))
			draw_rect(Rect2(x - cw * 0.42, y - ch * 0.62, cw * 0.18, ch * 0.16), Color("#ff2a1a"))
			draw_rect(Rect2(x + cw * 0.24, y - ch * 0.62, cw * 0.18, ch * 0.16), Color("#ff2a1a"))
	# darken so the UI reads on top
	draw_rect(Rect2(0, 0, w, h), Color(0.04, 0.06, 0.09, 0.42))
