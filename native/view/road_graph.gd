class_name RoadGraph
extends RefCounted
## Road model (NATIVE_PORT 3-4b, N6 structure only): the sim lives in (s, lateral) space, the view maps every
## position through world(). M1 implements the `straight` segment type only, which reproduces the web 1:1:
## x = lateral, y = 0, z = −s, forward = −Z (3-4). Curves, ramps and lane drops plug in here later without touching
## the sim or the views.

const LANE_W: float = 3.6
const NUM_LANES: int = 4
const SHOULDER_LANE: int = 4
const SHOULDER_X: float = 9.0
const MEDIAN_X: float = -8.25

## [{type, s0, len, params}] resolved from stage.road ([{type:'straight'}] for all 100 web stages).
var segments: Array[Dictionary] = []


func _init(road: Array = []) -> void:
	var s0: float = 0.0
	for seg: Variant in road:
		if seg is Dictionary:
			var d: Dictionary = seg
			var len_m: float = float(d.get("len", INF)) if d.get("len") != null else INF
			segments.append({"type": str(d.get("type", "straight")), "s0": s0, "len": len_m, "params": d.get("params", {})})
			s0 += len_m
	if segments.is_empty():
		segments.append({"type": "straight", "s0": -INF, "len": INF, "params": {}})


## Web laneX for lanes 0..3, 9.0 for the shoulder; fractional lanes interpolate (lane changes in progress).
static func lane_x(lane: float) -> float:
	if lane <= 3.0:
		return (lane - 1.5) * LANE_W
	return lerpf(5.4, SHOULDER_X, clampf(lane - 3.0, 0.0, 1.0))


## Opposite carriageway lane j (0 = nearest the median): −11.1 − 3.6 j, driving +Z (rotation.y = π).
static func opp_lane_x(j: int) -> float:
	return -11.1 - LANE_W * float(j)


func segment_at(s: float) -> Dictionary:
	for seg: Dictionary in segments:
		if s < float(seg["s0"]) + float(seg["len"]):
			return seg
	return segments[-1]


## Road frame at distance s and lateral offset (m): origin on the road surface, basis −Z = travel direction, +Y up.
func world(s: float, lateral: float, yaw: float = 0.0) -> Transform3D:
	# straight (the only M1 type): identity frame translated to (lateral, 0, −s)
	var b := Basis(Vector3.UP, yaw) if yaw != 0.0 else Basis.IDENTITY
	return Transform3D(b, Vector3(lateral, 0.0, -s))


func position(s: float, lateral: float) -> Vector3:
	return Vector3(lateral, 0.0, -s)


func tangent(_s: float) -> Vector3:
	return Vector3(0.0, 0.0, -1.0)


## Inverse of world() for the straight road: (s, lateral) of a world point.
func to_road(p: Vector3) -> Vector2:
	return Vector2(-p.z, p.x)


## [{id, width, kind}] at s: 4 driving lanes + shoulder (lane_drop / merge_ramp change this in M2+).
func lanes_at(_s: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i: int in NUM_LANES:
		out.append({"id": i, "width": LANE_W, "kind": "lane"})
	out.append({"id": SHOULDER_LANE, "width": 3.0, "kind": "shoulder"})
	return out
