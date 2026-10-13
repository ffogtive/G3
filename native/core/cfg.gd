class_name Cfg
extends RefCounted
## Engine-wide constants (stub, M1-0). Sim tick and road coordinates per NATIVE_PORT 3-2 / 3-4.
## Tunable numbers do not belong here: they live in data/src/*.json and are read through DB.

const SIM_HZ: int = 120
const TICK: float = 1.0 / SIM_HZ
const LANE_W: float = 3.6
## Lanes 0..3 are driving lanes (0 = 1차로, leftmost), 4 is the shoulder.
const SHOULDER_LANE: int = 4


## laneX(i) = (i - 1.5) * 3.6: lane 0 -> -5.4 ... lane 3 -> +5.4, shoulder (4) -> 9.0.
static func lane_x(lane: int) -> float:
	return (float(lane) - 1.5) * LANE_W
