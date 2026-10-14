class_name LaneInput
extends Node
## Touch + keyboard input (NATIVE_PORT 3-8 입력, M1b): swipe left/right = lane change, swipe up = rage, swipe down and
## hold = brake (DESIGN_REVIEW P0#1), on-screen ◀ ▶, 경적 (tap or hold), 압정 = fire (hold), 분노 = rage (tap; a hold is
## the same single tap at touch-down, docs/SKILLS.md 2-1), item1 / item2 = the loadout item slots (tap, one edge per
## touch-down), skip = a tap (no swipe) outside every zone while `skip_armed` (t5 / finisher cinematic, SKILLS §6).
## All touches go through _input() here, one tracker per finger index, so holding 압정 while swiping lanes works
## (multi-touch); HUD controls are visual only and register their rects with set_zone(). Edges are latched until the
## sim tick consumes them (InputBuffer semantics: consume / peek / is_down), and inject() feeds the same path from
## tests. Keyboard: ← → lane, Space / J fire (hold), H horn, ↑ / R rage, ↓ / S brake (hold), Q / 1 item1, E / 2 item2,
## Enter / K skip (while armed). Three fingers down at
## once = debug_requested (the dev panel has no on-screen tab over the HUD any more).
##
## Thresholds are in points, not pixels (3-4 함정): 34 pt with |dx| > 1.2|dy| → lane; 60 pt up with |dy| > 1.5|dx| → rage;
## 40 pt down with |dy| > 1.5|dx| → brake until that finger lifts.
## GameSim wiring (game.gd): consume_lane() → input(&"lane", d); consume_horn() → &"honk"; consume_rage() → &"rage";
## is_fire_down() → input(&"fire", held); is_brake_down() → input(&"brake", held), every tick; consume_item(1|2) →
## &"item1" | &"item2"; consume_skip() → &"skip". Zones never share an edge type: 압정 / items / 분노 can't honk (피드백 #3).

signal lane_requested(dir: int)
signal horn_changed(down: bool)
signal rage_requested
signal pause_requested
signal fire_changed(down: bool)
signal brake_changed(down: bool)
signal debug_requested
signal item_requested(slot: int)
signal skip_requested

const SWIPE_PT: float = 34.0
const RAGE_PT: float = 60.0
const BRAKE_PT: float = 40.0

var enabled: bool = true
var _zones: Dictionary = {}          # name → Rect2 (viewport coordinates)
var _touch: Dictionary = {}          # finger index → {start: Vector2, zone: String, done: bool}
var _lane_edges: Array[int] = []
var _horn_edges: int = 0
var _rage_edges: int = 0
var _horn_fingers: Dictionary = {}
var _horn_key: bool = false
var _fire_fingers: Dictionary = {}
var _fire_key: bool = false
var _fire_down: bool = false
var _fire_edges: int = 0
var _brake_fingers: Dictionary = {}
var _brake_key: bool = false
var _brake_down: bool = false
var _item_edges: PackedInt32Array = PackedInt32Array([0, 0])
var _skip_edges: int = 0
## game.gd sets it every frame: a skippable cinematic is on (state.skills.skip_ready or Hud.skip_hint_visible()).
var skip_armed: bool = false
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
	# input_devices/pointing/emulate_mouse_from_touch stays on (debug_panel Buttons need it), so every touch also
	# arrives as an emulated mouse event with device == DEVICE_ID_EMULATION. Handle the touch only, or each tap /
	# swipe would produce two lane edges (review: tap_left lane_edges=2).
	if event is InputEventMouse and event.device == InputEvent.DEVICE_ID_EMULATION:
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
			KEY_UP, KEY_W, KEY_R:
				if k.pressed:
					_push_rage()
			KEY_H:
				_set_horn_key(k.pressed)
			KEY_SPACE, KEY_J:
				_fire_key = k.pressed
				_fire_changed()
			KEY_DOWN, KEY_S:
				_brake_key = k.pressed
				_brake_changed()
			KEY_Q, KEY_1:
				if k.pressed:
					_push_item(1)
			KEY_E, KEY_2:
				if k.pressed:
					_push_item(2)
			KEY_ENTER, KEY_KP_ENTER, KEY_K:
				if k.pressed and skip_armed:
					_push_skip()


func _zone_at(p: Vector2) -> String:
	for z: String in _zones:
		var r: Rect2 = _zones[z]
		if r.has_area() and r.has_point(p):  # an empty item slot registers Rect2(): never a zone
			return z
	return ""


func _on_touch(index: int, pos: Vector2, pressed: bool) -> void:
	if pressed:
		var zone: String = _zone_at(pos)
		if zone != "pause" and is_inside_tree() and get_tree().paused:
			return  # while paused only the pause button works (no queued lane edges on resume)
		_touch[index] = {"start": pos, "zone": zone, "done": false}
		if index >= 0 and _touch.size() >= 3:
			debug_requested.emit()
		match zone:
			"horn":
				_horn_fingers[index] = true
				_horn_changed()
			"fire":
				_fire_fingers[index] = true
				_fire_changed()
			"left":
				_push_lane(-1)
			"right":
				_push_lane(1)
			"rage":
				_push_rage()
			"item1":
				_push_item(1)
			"item2":
				_push_item(2)
			"pause":
				pause_requested.emit()
	else:
		var t: Dictionary = _touch.get(index, {})
		if skip_armed and not t.is_empty() and str(t["zone"]) == "" and not bool(t["done"]) \
				and ((pos - (t["start"] as Vector2)) / units_per_pt()).length() < SWIPE_PT:
			_push_skip()  # a tap on the open screen (not a swipe, not a button) skips the cinematic
		if _horn_fingers.erase(index):
			_horn_changed()
		if _fire_fingers.erase(index):
			_fire_changed()
		if _brake_fingers.erase(index):
			_brake_changed()
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
	elif d.y > BRAKE_PT and absf(d.y) > 1.5 * absf(d.x):
		_brake_fingers[index] = true  # held until this finger lifts
		_brake_changed()
		t["done"] = true


func _push_lane(dir: int) -> void:
	_lane_edges.append(dir)
	lane_requested.emit(dir)


func _push_rage() -> void:
	_rage_edges += 1
	rage_requested.emit()


func _push_item(slot: int) -> void:
	_item_edges[slot - 1] += 1
	item_requested.emit(slot)


func _push_skip() -> void:
	_skip_edges += 1
	skip_requested.emit()


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


func _fire_changed() -> void:
	var down: bool = _fire_key or not _fire_fingers.is_empty()
	if down == _fire_down:
		return
	_fire_down = down
	if down:
		_fire_edges += 1
	fire_changed.emit(down)


func _brake_changed() -> void:
	var down: bool = _brake_key or not _brake_fingers.is_empty()
	if down == _brake_down:
		return
	_brake_down = down
	brake_changed.emit(down)


## Focus loss releases everything (3-8).
func release_all() -> void:
	_touch.clear()
	_horn_fingers.clear()
	_horn_key = false
	_horn_changed()
	_fire_fingers.clear()
	_fire_key = false
	_fire_changed()
	_brake_fingers.clear()
	_brake_key = false
	_brake_changed()


# ── InputBuffer-style consumption (sim tick side) ──

## True while any finger that started in `zone_name` is still down (HUD button feedback).
func is_zone_down(zone_name: String) -> bool:
	for t: Variant in _touch.values():
		if str((t as Dictionary).get("zone", "")) == zone_name:
			return true
	return false


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


## Taps on item slot 1 | 2 since the last call (one per touch-down).
func consume_item(slot: int) -> bool:
	if slot < 1 or slot > 2 or _item_edges[slot - 1] <= 0:
		return false
	_item_edges[slot - 1] -= 1
	return true


func consume_skip() -> bool:
	if _skip_edges > 0:
		_skip_edges -= 1
		return true
	return false


func peek_lane() -> int:
	return _lane_edges[0] if not _lane_edges.is_empty() else 0


func is_horn_down() -> bool:
	return _horn_down


## 압정 held (finger on the fire zone or Space / J). GameSim takes the level every tick: input(&"fire", held).
func is_fire_down() -> bool:
	return _fire_down


## Presses of 압정 since the last call (a tap shorter than one tick still fires once).
func consume_fire() -> bool:
	if _fire_edges > 0:
		_fire_edges -= 1
		return true
	return false


## Brake held (swipe down and keep the finger down, or ↓ / S).
func is_brake_down() -> bool:
	return _brake_down


## Tests: feed a synthetic event through the same path ("lane:-1", "lane:1", "horn:down", "horn:up", "rage",
## "fire:down", "fire:up", "brake:down", "brake:up", "item1", "item2", "skip", or an InputEvent).
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
		"item1":
			_push_item(1)
		"item2":
			_push_item(2)
		"skip":
			_push_skip()
		"fire:down", "fire:up":
			_fire_key = str(what) == "fire:down"
			_fire_changed()
		"brake:down", "brake:up":
			_brake_key = str(what) == "brake:down"
			_brake_changed()
