class_name OccupyBehavior
extends RefCounted
## behaviors/index.js `occupy` (1-1 정속주행 김사장): lane 0 at a fixed 80, metronome attacks
## highbeam → throw → horn → lunge every 3.0 s; every 4 s the cars behind it relay their high beams (far to near,
## 0.15 s apart) and the villain is dazzled for 1.5 s = the signature window (vulnerable, attacks blocked).
##
## 가설: ✅ the stun window is the only "read the tell, then burst" beat 1-1 needs; P0#7 turns it into the place
##       where the damage happens (GameSim/BossSim scale damage ×boss.vulnMul when vulnerable() > 1).

const SEQ: Array[String] = ["highbeam", "throw", "horn", "lunge"]

var fight: Dictionary = {}
var release_open_lane: int = 0
var interval: Array = [3.0, 3.0]
var hint: String = "발사 꾹 · 경직 노려"
var has_behind_attack: bool = false
var behind_attack: String = "throw"
var immune_text: String = ""


func init(B: BossSim, _stage: Dictionary) -> void:
	B.sig = {"seq": 0, "relay_t": 4.0, "relay": {}, "stun": 0.0, "cruise_t": 4.0, "relays": 0}


func motion(B: BossSim, v: Dictionary, dt: float, ctx: Dictionary) -> void:
	var S: Dictionary = B.sig
	S["stun"] = maxf(0.0, float(S["stun"]) - dt)
	S["cruise_t"] = float(S["cruise_t"]) - dt
	if float(S["cruise_t"]) <= 0.0:
		S["cruise_t"] = 6.0 + B.rng.randf() * 2.0
		B.pending.append({"type": "bubble", "who": "villain", "id": int(v["index"]), "text": "정속 80 딱", "kind": "warn", "dur": 1.2})
	S["relay_t"] = float(S["relay_t"]) - dt
	var R: Dictionary = S["relay"]
	if float(S["relay_t"]) <= 0.0 and R.is_empty():
		S["relay_t"] = 4.0
		var traffic: TrafficBridge = ctx.get("traffic")
		if traffic != null:
			var ids: PackedInt32Array = traffic.cars_in_lane(int(v["home_lane"]), float(v["s"]) - 45.0, float(v["s"]))
			if not ids.is_empty():
				S["relay"] = {"t": 0.0, "ids": ids}
				R = S["relay"]
	if not R.is_empty():
		R["t"] = float(R["t"]) + dt
		if float(R["t"]) > (R["ids"] as PackedInt32Array).size() * 0.15 + 0.3:
			S["relay"] = {}
			S["stun"] = 1.5
			S["relays"] = int(S["relays"]) + 1
			B.pending.append({"type": "stun", "id": int(v["index"]), "dur": 1.5})
			B.pending.append({"type": "bubble", "who": "villain", "id": int(v["index"]), "text": "눈부셔! (경직)", "kind": "score", "dur": 1.2})
	v["target_lane_pos"] = float(v["home_lane"])


func choose(B: BossSim, _v: Dictionary) -> String:
	var k: String = SEQ[int(B.sig["seq"]) % SEQ.size()]
	B.sig["seq"] = int(B.sig["seq"]) + 1
	return k


func blocked(B: BossSim, _v: Dictionary) -> bool:
	return float(B.sig["stun"]) > 0.0


## Web multiplier (1.5 in the stun); BossSim maps > 1 to the P0#7 window.
func vulnerable(B: BossSim, _v: Dictionary) -> float:
	return 1.5 if float(B.sig["stun"]) > 0.0 else 1.0


## Seconds left in the current window (0 = closed) for the HUD / autopilot.
func window_left(B: BossSim) -> float:
	return float(B.sig["stun"])


## View helper: car ids whose high beams flash now (relay order far to near, 0.25 s each).
func relay_lit(B: BossSim) -> PackedInt32Array:
	var out := PackedInt32Array()
	var R: Dictionary = B.sig.get("relay", {})
	if R.is_empty():
		return out
	var ids: PackedInt32Array = R["ids"]
	for i: int in ids.size():
		var k: float = float(R["t"]) - i * 0.15
		if k > 0.0 and k < 0.25:
			out.append(ids[i])
	return out


func on_death(B: BossSim, v: Dictionary) -> void:
	v["blinker"] = 1
	B.pending.append({"type": "bubble", "who": "villain", "id": int(v["index"]), "text": "어…? 2차선으로 갈게요… (깜빡이 사용 ✔)",
		"kind": "crit", "dur": 1.8, "final": true})


func stats(B: BossSim) -> Array:
	return [{"label": "차로 변경", "value": "0회 → 마지막에 1회 (깜빡이 ✔) · 상향등 릴레이 %d번" % int(B.sig.get("relays", 0))}]
