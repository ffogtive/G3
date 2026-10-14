extends RefCounted
## Single-lane IDM (Intelligent Driver Model). Car 0 = villain (slow 1st-lane driver).
## Until release_t the villain crawls at villain_v; after release it leaves the lane and the
## platoon should un-jam front-to-back (backward-propagating release wave = catharsis).

const CAR_LEN := 4.6
const V0 := 27.8        # desired speed (100 km/h)
const T_HEAD := 1.2     # time headway
const A_MAX := 1.5
const B_COMF := 2.0
const S0 := 2.0

var n: int
var pos := PackedFloat64Array()
var vel := PackedFloat64Array()
var villain_v := 8.3    # 30 km/h
var release_t := 40.0
var t := 0.0
var villain_active := true
var min_gap := 1.0e9
var release_time := PackedFloat64Array()   # first time each follower exceeds 20 m/s after release


func _init(count: int) -> void:
	n = count
	pos.resize(n)
	vel.resize(n)
	release_time.resize(n)
	for i in n:
		pos[i] = -i * 40.0
		vel[i] = villain_v if i == 0 else 25.0
		release_time[i] = -1.0


func step(dt: float) -> void:
	t += dt
	if villain_active and t >= release_t:
		villain_active = false
	var acc := PackedFloat64Array()
	acc.resize(n)
	for i in n:
		if i == 0:
			acc[i] = 0.0
			continue
		var lead := i - 1
		var free_road := (lead == 0 and not villain_active)
		var v: float = vel[i]
		var a_free: float = A_MAX * (1.0 - pow(v / V0, 4.0))
		if free_road:
			acc[i] = a_free
			continue
		var gap: float = pos[lead] - pos[i] - CAR_LEN
		min_gap = minf(min_gap, gap)
		var dv: float = v - vel[lead]
		var s_star: float = S0 + maxf(0.0, v * T_HEAD + v * dv / (2.0 * sqrt(A_MAX * B_COMF)))
		acc[i] = a_free - A_MAX * pow(s_star / maxf(gap, 0.1), 2.0)
	for i in n:
		if i == 0:
			if villain_active:
				vel[0] = villain_v
			else:
				vel[0] = 0.0
				pos[0] = 1.0e6   # left the lane
			pos[0] += vel[0] * dt
			continue
		vel[i] = maxf(0.0, vel[i] + acc[i] * dt)
		pos[i] += vel[i] * dt
		if not villain_active and release_time[i] < 0.0 and vel[i] > 20.0:
			release_time[i] = t


func mean_follower_speed() -> float:
	var s := 0.0
	for i in range(1, n):
		s += vel[i]
	return s / float(n - 1)
