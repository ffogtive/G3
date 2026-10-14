class_name CameraRig
extends Camera3D
## Chase camera = web main.js updateCamera / chaseTarget, plus the DESIGN_REVIEW P0#4 boss framing. Jam values 1:1:
##   portrait (h > 1.05 w): pos (0.45 x + 1.0, 21, −s + 17), look (0.6 x, 0.4, −s − 9), vertical FOV 56
##   landscape:              pos (0.45 x + 2.4, 12.5, −s + 16), look (0.6 x, 0.4, −s − 11), FOV 42
##   cruise uses H 10.5 / D 15 / L 14 and FOV 52 (+ 0.15 v, ≤ 8) landscape, 62 portrait
## boss (P0#4, replaces the web's "midpoint + fixed height 27"): the chase direction is kept, and the look point and
##   the distance scale k are solved so the player, every `focus` point (villains, attack markers) and their car
##   lengths project inside 70 % of the width and inside the band between the top HUD and the bottom controls
##   (FRAME_Y: 20 %..74 % of the height). Smallest k that fits, smoothed (k = 4 like the web boss camera).
## kill: finisher shot of the equipped finish (docs/SKILLS.md 4, device feedback "위아래 짤림"): the boss framing
##   holds 0.2 s on the kill tick, then blends to a per-finish shot that obeys the kill-cam rules — look-at y ≤ 4.5 m,
##   tilt follows the rising car by ≤ 12°, the road fills ≥ 35 % of the screen from the bottom, orbit sweep ≤ 30°,
##   portrait FOV 56–62, no letterbox: rocket = low side shot following the climb, balloon = fixed medium, heli = fixed
##   wide (room above for the helicopter), ufo = low angle, pullover = short orbit. The car leaves the frame upward.
## skills (on_event): t3 lifts the boss framing (k + 0.25 over 0.3 s, back after 0.6 s) so the 3-lane carpet shows;
##   t5 pushes in (FOV −6 over its 0.35 s telegraph), punches on the impact and blends back 1.0 s after the cast
##   (0.25 s); every skill impact = recipe punch + shake (config.skills.fx.<key>.camera, SkillCues.recipe).
## release: high over the kill point looking back over the jam (web pos 13 + 1.2 t, 44 + 2.2 t, s + 26 + 13 t).
## Juice: add_shake(trauma) = deterministic sum-of-sines shake with roll (trauma², decays 1.8/s), punch(deg) = FOV kick.
## Smoothing is real-dt exponential (a = 1 − e^(−k·dt); FOV k = 3) in _process, physics interpolation OFF
## (NATIVE_PORT 3-2): game.gd sets the interpolated player target and calls step(real_dt) once per frame.

const FRAME_X: float = 0.70           # P0#4: points inside 70 % of the width (NDC |x| ≤ 0.70)
const FRAME_Y := Vector2(0.20, 0.74)  # screen fraction from the top: below the boss plate, above the controls
const K_MIN: float = 0.85
const K_MAX: float = 2.2

var target_x: float = 0.0
var target_s: float = 0.0
var target_v: float = 0.0
var phase: String = "jam"
var smoothing: float = 6.0
var shake_offset := Vector3.ZERO
var road: RoadGraph
## Boss framing: extra world points to keep on screen (villains, markers); front lock flag.
var focus: Array[Vector3] = []
var locked: bool = false
## Kill orbit centre (dying villain, world) and the release anchor s (kill point).
var kill_target := Vector3(INF, INF, INF)
var kill_side: float = -1.0
var release_s: float = NAN
## Solved boss distance scale (tests / debug).
var frame_k: float = 1.0
## Equipped finish of the current kill ("" = rocket rules); set by the finisher / kill event.
var finish_id: String = ""
## Kill-cam rule limits (SKILLS.md 4; tests read them).
const KILL_LOOK_Y_MAX: float = 4.5
const KILL_TILT_MAX_DEG: float = 12.0
const KILL_ORBIT_MAX_DEG: float = 30.0
const KILL_HOLD_S: float = 0.2
## Per finish: [yaw0 deg (0 = square side, + = toward behind the car), sweep deg, radius, height, look y base, follow]
const FINISH_SHOT: Dictionary = {
	"rocket": [40.0, -18.0, 15.0, 10.5, 1.3, 1.0],
	"balloon": [36.0, 0.0, 16.0, 10.0, 1.8, 0.0],
	"heli": [30.0, 0.0, 20.0, 10.5, 3.2, 0.0],
	"ufo": [40.0, -8.0, 15.0, 8.0, 4.0, 0.0],
	"pullover": [42.0, -24.0, 16.0, 10.0, 0.8, 0.0],
}
var _clock: float = 0.0
var _lift_cur: float = 0.0
var _lift_target: float = 0.0
var _lift_until: float = -1.0
var _push_cur: float = 0.0
var _push_target: float = 0.0
var _push_rate: float = 30.0
var _push_until: float = -1.0
var _fast_until: float = -1.0
var _kill_pose0: Array[Vector3] = []
var _pos := Vector3(0, 30, 40)
var _look := Vector3.ZERO
var _fov_cur: float = 56.0
var _snapped: bool = false
var _phase_t: float = 0.0
var _last_phase: String = ""
var _trauma: float = 0.0
var _shake_t: float = 0.0
var _punch: float = 0.0
var _roll: float = 0.0
## true after set_pose(): step() no longer moves the camera.
var frozen: bool = false


func _ready() -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	near = 0.5
	far = 1400.0
	keep_aspect = Camera3D.KEEP_HEIGHT  # Three PerspectiveCamera.fov is vertical
	fov = _fov_cur


func is_portrait() -> bool:
	if not is_inside_tree():
		return true  # the phone (tests drive finish_pose without a viewport)
	var sz: Vector2 = get_viewport().get_visible_rect().size
	return sz.y > sz.x * 1.05


func _road_pos(s: float, x: float, y: float = 0.0) -> Vector3:
	var p: Vector3 = road.position(s, x) if road != null else Vector3(x, 0.0, -s)
	p.y += y
	return p


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
		"kill":
			return 58.0 if por else 44.0  # SKILLS.md 4: portrait kill cam 56–62°
		"cruise":
			return (62.0 if por else 52.0) + minf(8.0, target_v * 0.15)
		"release":
			return 60.0 if por else 50.0
	return 56.0 if por else 42.0


## GameSim.state() → phase, focus points, lock, kill orbit centre (the player target stays the interpolated view's).
func apply_state(st: Dictionary) -> void:
	phase = str(st.get("phase", phase))
	locked = bool((st.get("lock", {}) as Dictionary).get("active", false))
	focus.clear()
	for v: Variant in st.get("villains", []):
		var d: Dictionary = v
		if bool(d.get("alive", false)) and not bool(d.get("gone", false)):
			var s: float = float(d.get("s", 0.0))
			var x: float = float(d.get("x", 0.0))
			var half: float = float(d.get("len", 4.6)) * 0.5 + 1.0
			focus.append(_road_pos(s + half, x, 1.2))
			focus.append(_road_pos(s - half, x, 0.0))
		elif bool(d.get("dying", false)) and phase == "kill":
			kill_target = _road_pos(float(d.get("s", 0.0)), float(d.get("x", 0.0)), float(d.get("y", 0.0)) + 0.6)
			kill_side = shot_side(float(d.get("x", 0.0)))
	var hz: Dictionary = st.get("hazards", {}) if st.get("hazards") is Dictionary else {}
	for it: Variant in hz.get("items", []):
		if it is Dictionary and (it as Dictionary).has("s"):
			focus.append(_road_pos(float((it as Dictionary)["s"]), float((it as Dictionary).get("x", 0.0)), 0.5))


## Sim events the camera reacts to (kill orbit anchor + release anchor, shakes come from FightFx).
func on_event(e: Dictionary) -> void:
	match str(e.get("type", "")):
		"kill":
			release_s = float(e.get("s", target_s))
			kill_target = _road_pos(release_s, float(e.get("x", 0.0)), 0.6)
			kill_side = shot_side(float(e.get("x", 0.0)))
			punch(-6.0)
			if bool(e.get("last", true)):
				finish_id = str(e.get("finish", finish_id))
				_kill_pose0 = [_pos, _look]
		"finisher":
			finish_id = str(e.get("id", "rocket"))
		"skill_start":
			var key: String = SkillCues.fx_key(e)
			var cam: Dictionary = _recipe_cam(key)
			if float(cam.get("lift", 0.0)) > 0.0:
				lift(float(cam["lift"]), 0.3, 0.6)
			if float(cam.get("push", 0.0)) != 0.0:
				push(float(cam["push"]), SkillCues.impact_delay(key), 1.0)
		"skill_hit":
			if int(e.get("idx", 0)) == 0:
				var cam2: Dictionary = _recipe_cam(SkillCues.fx_key(e))
				punch(float(cam2.get("punch", 0.0)))
				add_shake(float(cam2.get("shake", 0.0)))
		"skill_end":
			if bool(e.get("cine", false)) or str(e.get("id", "")) == "t5_finish" or bool(e.get("skipped", false)):
				end_shot(0.25)
		"skip":
			end_shot(0.25)


## Camera part of a skill recipe (config.skills.fx.<key>.camera; spec defaults without config).
static func _recipe_cam(key: String) -> Dictionary:
	var r: Dictionary = SkillCues.recipe(key)
	if r.get("camera") is Dictionary:
		return r["camera"]
	return {"t1": {"punch": -3.0, "shake": 0.35}, "t3": {"lift": 0.25, "punch": -5.0, "shake": 0.5},
		"t5": {"push": -6.0, "punch": -8.0, "shake": 0.9}, "mv_jump": {"punch": -4.0, "shake": 0.45},
		"mv_drone": {"shake": 0.15}}.get(key, {})


## Boss framing lift: distance scale k + amount, eased in over `ramp` s, released `hold` s after the call.
func lift(amount: float, ramp: float = 0.3, hold: float = 0.6) -> void:
	_lift_target = amount
	_lift_until = _clock + hold
	_push_rate = maxf(_push_rate, 0.0)
	set_meta(&"lift_rate", amount / maxf(0.05, ramp))


## FOV push-in (deg, negative = in) over `ramp` s, held until `hold` s after the call, then end_shot blends it back.
func push(deg: float, ramp: float = 0.35, hold: float = 1.0) -> void:
	_push_target = deg
	_push_rate = absf(deg) / maxf(0.05, ramp)
	_push_until = _clock + hold


## Ends a skill shot: push / lift go back and the framing catches up within `blend` s.
func end_shot(blend: float = 0.25) -> void:
	_push_target = 0.0
	_push_rate = absf(_push_cur) / maxf(0.05, blend)
	_lift_target = 0.0
	set_meta(&"lift_rate", absf(_lift_cur) / maxf(0.05, blend))
	_fast_until = _clock + blend


## Side the kill camera stands on: the villain's outer side (median for the left lanes, shoulder for the right), so
## the jam is the backdrop, not a wall of buses between the lens and the car (shots: from the road side a bus filled
## the lower half). Heights ≥ 8 m keep the median fence a thin strip at the bottom.
static func shot_side(villain_x: float) -> float:
	return -1.0 if villain_x < RoadGraph.lane_x(1.5) else 1.0


## Shake trauma 0..1 (adds, capped). Felt amplitude = trauma².
func add_shake(amount: float) -> void:
	_trauma = clampf(_trauma + amount, 0.0, 1.0)


## FOV kick in degrees (negative = zoom in), decays in ≈ 0.35 s.
func punch(deg: float) -> void:
	_punch += deg


## Jump straight to the target (stage start, deterministic shots).
func snap() -> void:
	var t: Array[Vector3] = _target_pose()
	_pos = t[0]
	_look = t[1]
	_fov_cur = fov_target()
	_apply()
	_snapped = true


func _target_pose() -> Array[Vector3]:
	match phase:
		"boss":
			return _boss_pose()
		"kill":
			if kill_target.is_finite():
				if _phase_t < KILL_HOLD_S and _kill_pose0.size() == 2:
					return _kill_pose0  # impact tick: both cars stay in the boss framing for 0.2 s
				return finish_pose(_phase_t)
		"release":
			if is_finite(release_s):
				var t: float = _phase_t
				var por2: bool = is_portrait()
				var p2: Vector3 = _road_pos(release_s + 26.0 + t * 13.0, 13.0 + t * 1.2, (44.0 if por2 else 30.0) + t * 2.2)
				var l2: Vector3 = _road_pos(release_s - 85.0 + t * 12.0, -2.0, 0.0)
				return [p2, l2]
	return chase_target(phase == "cruise" or phase == "result")


## Finisher shot at real time t since the kill (SKILLS.md 4 rules; device feedback 2026-10-14: following the launched
## car pointed the camera at empty sky — the look-at stays near the road and the car flies OUT of the frame).
func finish_pose(t: float) -> Array[Vector3]:
	var row: Array = FINISH_SHOT.get(finish_id, FINISH_SHOT["rocket"])
	var por: bool = is_portrait()
	var dur: float = float(SkillCues.finish_beats(finish_id if not finish_id.is_empty() else "rocket").get("done", 2.0))
	var k: float = clampf(t / maxf(0.5, dur), 0.0, 1.0)
	var yaw: float = deg_to_rad(float(row[0]) + clampf(float(row[1]), -KILL_ORBIT_MAX_DEG, KILL_ORBIT_MAX_DEG) * UiDraw.smooth(k))
	var r: float = float(row[2]) * (1.0 if por else 0.85)
	var h: float = float(row[3])
	var base_y: float = float(row[4])
	var ground := Vector3(kill_target.x, 0.0, kill_target.z)
	# tilt follow: the look point rises with the car only as far as the 12° tilt budget and the 4.5 m cap allow
	var y0: float = base_y
	var pitch0: float = atan2(h - y0, r)
	var y_max: float = minf(KILL_LOOK_Y_MAX, h - r * tan(maxf(pitch0 - deg_to_rad(KILL_TILT_MAX_DEG), deg_to_rad(-20.0))))
	var ly: float = clampf(y0 + float(row[5]) * maxf(0.0, kill_target.y - 0.6) * 0.45, minf(y0, KILL_LOOK_Y_MAX), maxf(y0, minf(y_max, KILL_LOOK_Y_MAX)))
	var look := Vector3(ground.x * 0.92, minf(ly, KILL_LOOK_Y_MAX), ground.z)
	var p: Vector3 = ground + Vector3(kill_side * cos(yaw) * r, h, sin(yaw) * r)
	return [p, look]


## Fraction of the screen height, from the bottom, that shows the road plane (y = 0 within 400 m) for a pose: the
## kill-cam rule wants ≥ 0.35. Analytic for a pinhole camera with vertical FOV fov_v.
static func road_bottom_frac(pos: Vector3, look: Vector3, fov_v: float) -> float:
	var d: Vector3 = (look - pos).normalized()
	var pitch: float = asin(clampf(d.y, -1.0, 1.0))          # < 0 looking down
	var half: float = deg_to_rad(fov_v) * 0.5
	var far_dep: float = atan2(pos.y, 400.0)                 # the road ends at 400 m: depression of its far edge
	# screen row (0 = bottom, 1 = top) of a ray with depression δ below horizontal: ndc = tan(−δ − pitch) / tan(half)
	var ndc: float = tan(-far_dep - pitch) / tan(half)
	return clampf((ndc + 1.0) * 0.5, 0.0, 1.0)


## P0#4: keep the chase direction, solve look point + distance scale so every point fits the frame.
func _boss_pose() -> Array[Vector3]:
	var base: Array[Vector3] = chase_target(false)
	if focus.is_empty():
		return base
	var pts: Array[Vector3] = [_road_pos(target_s + 2.6, target_x, 1.4), _road_pos(target_s - 2.6, target_x, 0.0)]
	pts.append_array(focus)
	var off: Vector3 = base[0] - base[1]
	var lo := Vector3(INF, 0, INF)
	var hi := Vector3(-INF, 0, -INF)
	for p: Vector3 in pts:
		lo = Vector3(minf(lo.x, p.x), 0, minf(lo.z, p.z))
		hi = Vector3(maxf(hi.x, p.x), 0, maxf(hi.z, p.z))
	var look := Vector3((lo.x + hi.x) * 0.5 * 0.85, base[1].y, (lo.z + hi.z) * 0.5)
	var fov_v: float = fov_target()
	var best_k: float = K_MAX
	var best_look: Vector3 = look
	var k: float = K_MIN
	while k <= K_MAX + 1e-4:
		var lk: Vector3 = _centre_vertically(look, off * k, pts, fov_v)
		var ext: Vector4 = _extent(lk + off * k, lk, pts, fov_v)
		if ext.x >= -FRAME_X and ext.y <= FRAME_X and ext.z >= _ndc_y(FRAME_Y.y) and ext.w <= _ndc_y(FRAME_Y.x):
			best_k = k
			best_look = lk
			break
		best_look = lk
		k += 0.05
	frame_k = best_k
	var kk: float = best_k + _lift_cur
	return [best_look + off * kk, best_look]


func _ndc_y(frac_from_top: float) -> float:
	return 1.0 - 2.0 * frac_from_top


## Slides the look point along the road so the points' vertical extent is centred in the FRAME_Y band (2 secant steps).
func _centre_vertically(look: Vector3, off: Vector3, pts: Array[Vector3], fov_v: float) -> Vector3:
	var want: float = (_ndc_y(FRAME_Y.x) + _ndc_y(FRAME_Y.y)) * 0.5
	var lk: Vector3 = look
	for i: int in 3:
		var e0: Vector4 = _extent(lk + off, lk, pts, fov_v)
		var m0: float = (e0.z + e0.w) * 0.5 - want
		if absf(m0) < 0.01:
			break
		var probe: Vector3 = lk + Vector3(0, 0, -1.0)
		var e1: Vector4 = _extent(probe + off, probe, pts, fov_v)
		var m1: float = (e1.z + e1.w) * 0.5 - want
		var slope: float = m1 - m0
		if absf(slope) < 1e-5:
			break
		lk.z += clampf(m0 / slope, -30.0, 30.0)  # slope is per metre along −Z (forward), so Δz = m0 / slope
	return lk


## NDC extent (min x, max x, min y, max y) of pts seen from pos looking at look with vertical FOV fov_v.
func _extent(pos: Vector3, look: Vector3, pts: Array[Vector3], fov_v: float) -> Vector4:
	var b := Basis.looking_at(look - pos, Vector3.UP)
	var sz: Vector2 = get_viewport().get_visible_rect().size if is_inside_tree() else Vector2(540, 1168)
	var aspect: float = sz.x / maxf(1.0, sz.y)
	var ty: float = tan(deg_to_rad(fov_v) * 0.5)
	var tx: float = ty * aspect
	var out := Vector4(INF, -INF, INF, -INF)
	for p: Vector3 in pts:
		var v: Vector3 = b.inverse() * (p - pos)
		var dz: float = maxf(0.1, -v.z)
		var nx: float = v.x / (dz * tx)
		var ny: float = v.y / (dz * ty)
		out = Vector4(minf(out.x, nx), maxf(out.y, nx), minf(out.z, ny), maxf(out.w, ny))
	return out


func step(real_dt: float) -> void:
	if frozen:
		return
	_clock += real_dt
	if phase != _last_phase:
		if phase == "kill" and _kill_pose0.size() != 2:
			_kill_pose0 = [_pos, _look]
		elif phase != "kill":
			_kill_pose0 = []
			if _last_phase == "kill":
				finish_id = ""
		_last_phase = phase
		_phase_t = 0.0
	_phase_t += real_dt
	if _push_until >= 0.0 and _clock > _push_until:
		_push_until = -1.0
		end_shot(0.25)
	if _lift_until >= 0.0 and _clock > _lift_until:
		_lift_until = -1.0
		_lift_target = 0.0
	_push_cur = move_toward(_push_cur, _push_target, _push_rate * real_dt)
	_lift_cur = move_toward(_lift_cur, _lift_target, float(get_meta(&"lift_rate", 1.0)) * real_dt)
	if not _snapped:
		snap()
	var t: Array[Vector3] = _target_pose()
	var k: float = smoothing
	match phase:
		"boss":
			k = 4.0
		"kill":
			k = 4.0 if _phase_t < KILL_HOLD_S + 0.6 else 6.0
		"release":
			k = 3.0 if _phase_t < 0.4 else 2.2
		"cruise":
			k = 2.2 if _phase_t < 1.2 else 5.0
	if _clock < _fast_until:
		k = maxf(k, 12.0)
	var a: float = 1.0 - exp(-k * real_dt)
	_pos = _pos.lerp(t[0], a)
	_look = _look.lerp(t[1], a)
	_fov_cur += (fov_target() - _fov_cur) * (1.0 - exp(-3.0 * real_dt))
	# shake (deterministic: sum of incommensurate sines) and FOV punch
	_shake_t += real_dt
	_trauma = maxf(0.0, _trauma - 1.8 * real_dt)
	var tr: float = _trauma * _trauma
	var st: float = _shake_t
	shake_offset = Vector3(sin(st * 37.3) + 0.5 * sin(st * 61.1 + 1.7), sin(st * 41.9 + 0.6) + 0.5 * sin(st * 71.3),
		sin(st * 29.7 + 2.1)) * 0.55 * tr
	_roll = (sin(st * 33.1 + 0.4) + 0.4 * sin(st * 57.7)) * 0.035 * tr
	_punch *= exp(-9.0 * real_dt)
	_apply()


func _apply() -> void:
	fov = clampf(_fov_cur + _punch + _push_cur, 20.0, 100.0)
	look_at_from_position(_pos + shake_offset, _look, Vector3.UP)
	if _roll != 0.0:
		rotate_object_local(Vector3.FORWARD, _roll)


## Exact pose override (shot_jam --state= replays the web camera).
func set_pose(pos: Vector3, look: Vector3, fov_deg: float) -> void:
	frozen = true
	_pos = pos
	_look = look
	_fov_cur = fov_deg
	_apply()
