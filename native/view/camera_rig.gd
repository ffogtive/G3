class_name CameraRig
extends Camera3D
## Chase camera = web main.js updateCamera / chaseTarget (jam phase, M1a). Values copied 1:1:
##   portrait (h > 1.05 w): pos (0.45 x + 1.0, 21, −s + 17), look (0.6 x, 0.4, −s − 9), vertical FOV 56
##   landscape:              pos (0.45 x + 2.4, 12.5, −s + 16), look (0.6 x, 0.4, −s − 11), FOV 42
##   cruise uses H 10.5 / D 15 / L 14 and FOV 52 (+ 0.15 v, ≤ 8) landscape, 62 portrait
## Smoothing is real-dt exponential (a = 1 − e^(−k·dt), k = 6; FOV k = 3) in _process, physics interpolation OFF
## (NATIVE_PORT 3-2): game.gd sets the interpolated player target and calls step(real_dt) once per frame.

var target_x: float = 0.0
var target_s: float = 0.0
var target_v: float = 0.0
var phase: String = "jam"
var smoothing: float = 6.0
var shake_offset := Vector3.ZERO
var road: RoadGraph
var _pos := Vector3(0, 30, 40)
var _look := Vector3.ZERO
var _fov_cur: float = 56.0
var _snapped: bool = false
## true after set_pose(): step() no longer moves the camera.
var frozen: bool = false


func _ready() -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	near = 0.5
	far = 1400.0
	keep_aspect = Camera3D.KEEP_HEIGHT  # Three PerspectiveCamera.fov is vertical
	fov = _fov_cur


func is_portrait() -> bool:
	var sz: Vector2 = get_viewport().get_visible_rect().size
	return sz.y > sz.x * 1.05


## Web chaseTarget(outPos, outLook, cruise).
func chase_target(cruise: bool = false) -> Array[Vector3]:
	var por: bool = is_portrait()
	var h: float = 21.0 if por else (10.5 if cruise else 12.5)
	var d: float = 17.0 if por else (15.0 if cruise else 16.0)
	var l: float = 9.0 if por else (14.0 if cruise else 11.0)
	var p := Vector3(target_x * 0.45 + (1.0 if por else 2.4), h, 0.0)
	var k := Vector3(target_x * 0.6, 0.4, 0.0)
	# along the road: straight → z = −s (+D behind, −L ahead) via RoadGraph
	var base_p: Vector3 = road.position(target_s - d, 0.0) if road != null else Vector3(0, 0, -(target_s - d))
	var base_l: Vector3 = road.position(target_s + l, 0.0) if road != null else Vector3(0, 0, -(target_s + l))
	return [Vector3(p.x, p.y, base_p.z), Vector3(k.x, k.y, base_l.z)]


func fov_target() -> float:
	var por: bool = is_portrait()
	match phase:
		"boss":
			return 58.0 if por else 46.0
		"cruise":
			return (62.0 if por else 52.0) + minf(8.0, target_v * 0.15)
		"release":
			return 60.0 if por else 50.0
	return 56.0 if por else 42.0


## Jump straight to the target (stage start, deterministic shots).
func snap() -> void:
	var t: Array[Vector3] = chase_target(phase == "cruise")
	_pos = t[0]
	_look = t[1]
	_fov_cur = fov_target()
	_apply()
	_snapped = true


func step(real_dt: float) -> void:
	if frozen:
		return
	if not _snapped:
		snap()
	var t: Array[Vector3] = chase_target(phase == "cruise" or phase == "result")
	var a: float = 1.0 - exp(-smoothing * real_dt)
	_pos = _pos.lerp(t[0], a)
	_look = _look.lerp(t[1], a)
	_fov_cur += (fov_target() - _fov_cur) * (1.0 - exp(-3.0 * real_dt))
	_apply()


func _apply() -> void:
	fov = _fov_cur
	look_at_from_position(_pos + shake_offset, _look, Vector3.UP)


## Exact pose override (shot_jam --state= replays the web camera).
func set_pose(pos: Vector3, look: Vector3, fov_deg: float) -> void:
	frozen = true
	_pos = pos
	_look = look
	_fov_cur = fov_deg
	_apply()
