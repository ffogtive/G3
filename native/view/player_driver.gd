class_name PlayerDriver
extends RefCounted
## View-side player stand-in until res://sim/player.gd lands (M1b): jam creep behind the car ahead in the player's
## lane (IDM, same constants as the stub traffic), lane change = smoothstep over 0.36 s once TrafficBridge
## .request_lane() agrees, blinker on while moving, brake light under −0.25 m/s² or below 1.6 m/s (web rule).
## State is the fixed player Dictionary {lane, s, v, x} the bridge expects, plus yaw / lamp bits for the view.

const V0: float = 7.0
const A: float = 1.6
const B: float = 2.4
const GAP0: float = 1.8
const HEADWAY: float = 0.8
const LC_DUR: float = 0.36
const LEN: float = 4.2

var lane: int = 3
var lane_from: int = 3
var s: float = 0.0
var v: float = 0.0
var x: float = 5.4
var yaw: float = 0.0
var acc: float = 0.0
var lc_t: float = 1.0
var blink_dir: int = 0
var lamp_bits: int = 0
var time: float = 0.0


func reset(p_lane: int, p_s: float) -> void:
	lane = p_lane
	lane_from = p_lane
	s = p_s
	v = 0.0
	x = RoadGraph.lane_x(float(p_lane))
	lc_t = 1.0
	blink_dir = 0


func state() -> Dictionary:
	var fl: float = float(lane) if lc_t >= 1.0 else lerpf(float(lane_from), float(lane), lc_t)
	return {"lane": fl, "s": s, "v": v, "x": x}


func start_lane_change(to: int) -> void:
	lane_from = lane
	lane = to
	lc_t = 0.0
	blink_dir = signi(to - lane_from)


## buf: last sim buffer (stride 8) for the gap ahead in the player's lane(s).
func step(dt: float, buf: PackedFloat32Array) -> void:
	time += dt
	var gap: float = INF
	var lead_v: float = V0
	var n: int = buf.size() / 8
	for k: int in n:
		var o: int = k * 8
		var cs: float = buf[o + 4]
		if cs <= s or buf[o + 2] < 0.0:
			continue
		if absf(buf[o + 3] - x) < 2.0:  # lateral overlap (car half widths + margin)
			var half: float = 2.3 if int(buf[o + 1]) < 6 else 5.0
			var g: float = cs - half - (s + LEN * 0.5)
			if g < gap:
				gap = g
				lead_v = buf[o + 6]
	var sstar: float = GAP0 + maxf(0.0, v * HEADWAY + v * (v - lead_v) / (2.0 * sqrt(A * B)))
	acc = A * (1.0 - pow(v / V0, 4.0))
	if gap < INF:
		acc -= A * pow(sstar / maxf(0.3, gap), 2.0)
	acc = clampf(acc, -7.0, A)
	v = maxf(0.0, v + acc * dt)
	if gap < 0.2:
		v = minf(v, maxf(0.0, lead_v))
	s += v * dt
	if lc_t < 1.0:
		lc_t = minf(1.0, lc_t + dt / LC_DUR)
		var e: float = lc_t * lc_t * (3.0 - 2.0 * lc_t)
		var nx: float = lerpf(RoadGraph.lane_x(float(lane_from)), RoadGraph.lane_x(float(lane)), e)
		yaw = -atan2((nx - x) / maxf(dt, 1e-4), maxf(3.0, v)) * 0.6
		x = nx
		if lc_t >= 1.0:
			yaw = 0.0
			blink_dir = 0
	lamp_bits = 0
	if acc < -0.25 or v < 1.6:
		lamp_bits |= 1
	if blink_dir < 0:
		lamp_bits |= 2
	elif blink_dir > 0:
		lamp_bits |= 4
