class_name LaneInput
extends Node
## Touch + keyboard input for the jam (NATIVE_PORT 3-8 입력, M1a): swipe left/right = lane change, swipe up = rage,
## on-screen ◀ ▶ buttons, horn button (tap or hold). All touches go through _input() here, one tracker per finger
## index, so holding the horn while swiping works (multi-touch); HUD controls are visual only and register their
## rects with set_zone(). Edges are latched until the sim tick consumes them (InputBuffer semantics: consume /
## peek / is_down), and inject() feeds the same path from tests. Keyboard: ← → lane, Space horn, ↑ rage.
##
## Thresholds are in points, not pixels (3-4 함정): 34 pt with |dx| > 1.2|dy| → lane; 60 pt up with |dy| > 1.5|dx| → rage.

signal lane_requested(dir: int)
signal horn_changed(down: bool)
signal rage_requested

const SWIPE_PT: float = 34.0
const RAGE_PT: float = 60.0

var enabled: bool = true
var _zones: Dictionary = {}          # name → Rect2 (viewport coordinates)
var _touch: Dictionary = {}          # finger index → {start: Vector2, zone: String, done: bool}
var _lane_edges: Array[int] = []
var _horn_edges: int = 0
var _rage_edges: int = 0
var _horn_fingers: Dictionary = {}
var _horn_key: bool = false
var pt_override: float = 0.0         # tests: force px-per-pt


func set_zone(zone_name: String, rect: Rect2) -> void:
	_zones[zone_name] = rect


## Viewport units per point. The canvas_items stretch maps the 540-wide base to the window; points = window pixels /
## screen scale (iOS 2–3, Android ≈ dpi / 160, desktop 1).
func units_per_pt() -> float:
	if pt_override > 0.0:
		return pt_override
	var vp: Viewport = get_viewport()
	if vp == null:
		return 1.0
	var win: Vector2 = Vector2(DisplayServer.window_get_size())
	var vis: Vector2 = vp.get_visible_rect().size
	if win.x <= 0.0 or vis.x <= 0.0:
		return 1.0
	var px_per_unit: float = win.x / vis.x
	var scale: float = DisplayServer.screen_get_scale()
	if OS.has_feature("android"):
		scale = maxf(1.0, float(DisplayServer.screen_get_dpi()) / 160.0)
	return maxf(1.0, scale) / px_per_unit


func _input(event: InputEvent) -> void:
	if not enabled:
		return
	if event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		_on_touch(t.index, t.position, t.pressed)
	elif event is InputEventScreenDrag:
		var d := event as InputEventScreenDrag
		_on_drag(d.index, d.position)
	elif event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var m := event as InputEventMouseButton
		_on_touch(-1, m.position, m.pressed)
	elif event is InputEventMouseMotion and _touch.has(-1):
		_on_drag(-1, (event as InputEventMouseMotion).position)
	elif event is InputEventKey:
		var k := event as InputEventKey
		if k.echo:
			return
		match k.keycode:
			KEY_LEFT, KEY_A:
				if k.pressed:
					_push_lane(-1)
			KEY_RIGHT, KEY_D:
				if k.pressed:
					_push_lane(1)
			KEY_UP, KEY_W:
				if k.pressed:
					_push_rage()
			KEY_SPACE, KEY_H:
				_set_horn_key(k.pressed)


func _zone_at(p: Vector2) -> String:
	for z: String in _zones:
		if (_zones[z] as Rect2).has_point(p):
			return z
	return ""


func _on_touch(index: int, pos: Vector2, pressed: bool) -> void:
	if pressed:
		var zone: String = _zone_at(pos)
		_touch[index] = {"start": pos, "zone": zone, "done": false}
		match zone:
			"horn":
				_horn_fingers[index] = true
				_horn_changed()
			"left":
				_push_lane(-1)
			"right":
				_push_lane(1)
			"rage":
				_push_rage()
	else:
		if _horn_fingers.erase(index):
			_horn_changed()
		_touch.erase(index)


func _on_drag(index: int, pos: Vector2) -> void:
	var t: Dictionary = _touch.get(index, {})
	if t.is_empty() or bool(t["done"]) or str(t["zone"]) != "":
		return
	var d: Vector2 = (pos - (t["start"] as Vector2)) / units_per_pt()
	if absf(d.x) > SWIPE_PT and absf(d.x) > 1.2 * absf(d.y):
		_push_lane(1 if d.x > 0.0 else -1)
		t["done"] = true
	elif -d.y > RAGE_PT and absf(d.y) > 1.5 * absf(d.x):
		_push_rage()
		t["done"] = true


func _push_lane(dir: int) -> void:
	_lane_edges.append(dir)
	lane_requested.emit(dir)


func _push_rage() -> void:
	_rage_edges += 1
	rage_requested.emit()


func _set_horn_key(down: bool) -> void:
	if down == _horn_key:
		return
	_horn_key = down
	_horn_changed()


var _horn_down: bool = false


func _horn_changed() -> void:
	var down: bool = _horn_key or not _horn_fingers.is_empty()
	if down == _horn_down:
		return
	_horn_down = down
	if down:
		_horn_edges += 1
	horn_changed.emit(down)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		release_all()


## Focus loss releases everything (3-8).
func release_all() -> void:
	_touch.clear()
	_horn_fingers.clear()
	_horn_key = false
	_horn_changed()


# ── InputBuffer-style consumption (sim tick side) ──

func consume_lane() -> int:
	return _lane_edges.pop_front() if not _lane_edges.is_empty() else 0


func consume_horn() -> bool:
	if _horn_edges > 0:
		_horn_edges -= 1
		return true
	return false


func consume_rage() -> bool:
	if _rage_edges > 0:
		_rage_edges -= 1
		return true
	return false


func peek_lane() -> int:
	return _lane_edges[0] if not _lane_edges.is_empty() else 0


func is_horn_down() -> bool:
	return _horn_down


## Tests: feed a synthetic event through the same path ("lane:-1", "lane:1", "horn:down", "horn:up", "rage", or an
## InputEvent).
func inject(what: Variant) -> void:
	if what is InputEvent:
		_input(what as InputEvent)
		return
	match str(what):
		"lane:-1":
			_push_lane(-1)
		"lane:1":
			_push_lane(1)
		"horn:down":
			_set_horn_key(true)
		"horn:up":
			_set_horn_key(false)
		"rage":
			_push_rage()
