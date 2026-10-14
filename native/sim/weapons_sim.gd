class_name WeaponsSim
extends RefCounted
## weapons.js without meshes: tack lobs (lock-on lead, end point tracks the target) and the rage bomb (0.62 s
## Bezier homing). GameSim picks the target (N2/N4 lock-on, P0#2 range band) and applies damage on landing.
##
## 가설: ✅ a tack resolves only at landing (|target.x − to.x| < w/2 + hitPad), so the hit/miss call and the
##       visual arc share one clock; the view draws state() projectiles, the sim never needs mesh positions.

var tacks: Array[Dictionary] = []
var missiles: Array[Dictionary] = []
var cool: float = 0.0
var super_cool: float = 0.0
var shots: int = 0
var hits: int = 0
var rate: float = 7.0
var spread: int = 1
var tack_cfg: Dictionary = {}
var bomb_cfg: Dictionary = {}
var rng := RandomNumberGenerator.new()


func setup(p_tack: Dictionary, p_bomb: Dictionary, seed: int) -> void:
	tack_cfg = p_tack
	bomb_cfg = p_bomb
	rate = float(tack_cfg.get("rate", 7.0))
	rng.seed = seed
	reset()


func reset() -> void:
	tacks.clear()
	missiles.clear()
	cool = 0.0
	super_cool = 0.0
	shots = 0
	hits = 0


static func muzzle(p: PlayerSim) -> Vector3:
	return Vector3(p.x, 1.95 + p.hop, p.s - 0.6)  # (x, y, s)


## target: villain dict {index, s, x, v, len, w} or a mini car {mini_id, s, x, v, len, w}; {} = thrown blind
## behind the car (the P0#2 miss). Returns the "fire" event.
func fire_at(p: PlayerSim, target: Dictionary) -> Dictionary:
	var from: Vector3 = WeaponsSim.muzzle(p)
	var has_t: bool = not target.is_empty()
	var ahead: bool = has_t and float(target["s"]) > p.s
	var lob: bool = has_t and absf(float(target["x"]) - p.x) > 4.0
	var dur: float = float(tack_cfg.get("lobDur", 0.46)) if lob else float(tack_cfg.get("dur", 0.32))
	var tk: Dictionary = {"t": 0.0, "dur": dur, "from": from, "arc": 5.5 if lob else (2.2 if has_t else 3.0),
		"vi": int(target.get("index", -1)), "mini_id": int(target.get("mini_id", 0)), "from_rear": ahead, "dx": 0.0, "aim": 0.0}
	if has_t:
		var aim: float = -0.36 if ahead else 0.38
		tk["aim"] = aim
		tk["to"] = Vector3(float(target["x"]) + (rng.randf() - 0.5) * minf(1.2, float(target["w"]) * 0.5), 0.25 + rng.randf() * 0.4,
			float(target["s"]) + float(target.get("v", 0.0)) * dur + float(target["len"]) * aim)
	else:
		tk["to"] = Vector3(p.x + (rng.randf() - 0.5) * 0.6, 0.05, p.s - float(tack_cfg.get("missBack", 9.0)))
	tacks.append(tk)
	shots += 1
	var to: Vector3 = tk["to"]
	return {"type": "fire", "target_id": int(tk["vi"]), "mini_id": int(tk["mini_id"]), "from_s": from.z, "from_x": from.x,
		"to_s": to.z, "to_x": to.x, "dur": dur, "lob": lob}


func fire_missile(p: PlayerSim, target: Dictionary) -> Dictionary:
	if target.is_empty() or super_cool > 0.0:
		return {}
	super_cool = float(bomb_cfg.get("cool", 0.45))
	var from: Vector3 = WeaponsSim.muzzle(p)
	missiles.append({"t": 0.0, "dur": float(bomb_cfg.get("dur", 0.62)), "from": from, "vi": int(target["index"]),
		"side": -1.0 if rng.randf() < 0.5 else 1.0, "from_rear": float(target["s"]) > p.s})
	return {"type": "bomb", "target_id": int(target["index"]), "dur": float(bomb_cfg.get("dur", 0.62)), "from_s": from.z, "from_x": from.x}


## villains: BossSim.villains (index = position). Returns landings:
## [{kind: tack|bomb, vi, mini_id, hit: bool, s, x, from_rear}].
func update(dt: float, villains: Array[Dictionary]) -> Array[Dictionary]:
	cool -= dt
	super_cool -= dt
	var out: Array[Dictionary] = []
	var pad: float = float(tack_cfg.get("hitPad", 0.9))
	for i: int in range(tacks.size() - 1, -1, -1):
		var tk: Dictionary = tacks[i]
		tk["t"] = float(tk["t"]) + dt
		var vi: int = int(tk["vi"])
		var tv: Dictionary = villains[vi] if vi >= 0 and vi < villains.size() else {}
		var to: Vector3 = tk["to"]
		if not tv.is_empty() and bool(tv["alive"]):
			to.z = float(tv["s"]) + float(tv["len"]) * float(tk["aim"])
			to.x += (float(tv["x"]) + float(tk["dx"]) - to.x) * minf(1.0, dt * 10.0)
			tk["to"] = to
		if float(tk["t"]) >= float(tk["dur"]):
			var hit: bool = false
			if not tv.is_empty() and bool(tv["alive"]) and absf(float(tv["x"]) - to.x) < float(tv["w"]) / 2.0 + pad:
				hit = true
			elif int(tk["mini_id"]) != 0:
				hit = true  # GameSim re-checks the car position
			if hit:
				hits += 1
			out.append({"kind": "tack", "vi": vi, "mini_id": int(tk["mini_id"]), "hit": hit, "s": to.z, "x": to.x,
				"from_rear": bool(tk["from_rear"])})
			tacks.remove_at(i)
	for i: int in range(missiles.size() - 1, -1, -1):
		var m: Dictionary = missiles[i]
		m["t"] = float(m["t"]) + dt
		if float(m["t"]) >= float(m["dur"]):
			var mv: Dictionary = villains[int(m["vi"])] if int(m["vi"]) < villains.size() else {}
			out.append({"kind": "bomb", "vi": int(m["vi"]), "mini_id": 0, "hit": not mv.is_empty() and bool(mv["alive"]),
				"s": float(mv.get("s", 0.0)), "x": float(mv.get("x", 0.0)), "from_rear": bool(m["from_rear"])})
			missiles.remove_at(i)
	return out


## View records: [{kind, s, x, y, p}] for tacks and bombs in flight.
func projectiles(villains: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for tk: Dictionary in tacks:
		var p: float = minf(1.0, float(tk["t"]) / float(tk["dur"]))
		var a: Vector3 = tk["from"]
		var b: Vector3 = tk["to"]
		var q: Vector3 = a.lerp(b, p)
		out.append({"kind": "tack", "s": q.z, "x": q.x, "y": q.y + sin(PI * p) * float(tk["arc"]), "p": p})
	for m: Dictionary in missiles:
		var p2: float = minf(1.0, float(m["t"]) / float(m["dur"]))
		var a2: Vector3 = m["from"]
		var tv: Dictionary = villains[int(m["vi"])] if int(m["vi"]) < villains.size() else {}
		var b2 := Vector3(float(tv.get("x", a2.x)), 1.0, float(tv.get("s", a2.z)))
		var c := Vector3((a2.x + b2.x) / 2.0 + float(m["side"]) * 4.0, 8.0, (a2.z + b2.z) / 2.0)
		var u: float = 1.0 - p2
		var q2: Vector3 = a2 * (u * u) + c * (2.0 * u * p2) + b2 * (p2 * p2)
		out.append({"kind": "bomb", "s": q2.z, "x": q2.x, "y": q2.y, "p": p2})
	return out
