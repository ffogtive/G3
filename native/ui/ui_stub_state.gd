class_name UiStubState
extends RefCounted
## GameSim.state() / events() shaped fixtures for the HUD, cards, reticle and FX (tests/test_ui.gd, quick UI look-dev
## without running the sim). Shapes follow the fixed IFACE in sim/game_sim.gd state(); values are a 1-1 fight frame.

static func player(s: float = 257.0, lane: int = 1, hp: int = 80, rage: float = 0.47) -> Dictionary:
	return {"s": s, "x": RoadGraph.lane_x(float(lane)), "lane": lane, "v": 15.6, "hp": hp, "hp_max": 100, "rage": rage,
		"boost": 0.0, "yaw": 0.0, "hop": 0.0, "brake": false, "min_hp": hp}


static func villain(s: float = 254.9, lane: int = 0, hp: float = 101.0, alive: bool = true, vulnerable: bool = false) -> Dictionary:
	return {"id": 0, "kind": "villainSedan", "name": "정속주행 김사장", "color": 0xd9c9a3, "s": s, "x": RoadGraph.lane_x(float(lane)),
		"lane": lane, "lane_pos": float(lane), "hp": hp, "hp_max": 140.0, "alive": alive, "dying": not alive, "gone": false,
		"tell": &"", "vulnerable": vulnerable, "window_left": 1.0 if vulnerable else 0.0, "tires": 3, "len": 4.9, "w": 1.84,
		"yaw": 0.0, "y": 0.0, "flash": 0.0, "blinker": 0}


static func jam(progress: float = 0.4) -> Dictionary:
	var p: Dictionary = player(80.0, 4, 100, 0.1)
	return {"phase": &"jam", "t": 8.0, "player": p, "villains": [villain(250.0, 0, 140.0)],
		"lock": {"active": false, "in_range": false, "target_id": -1, "reason": ""}, "hint": "갓길로 ▶ 원인 찾기",
		"distance_m": 170.0 * (1.0 - progress), "progress": progress, "stats": {"combo": 0, "fails": 0, "pay_mul": 1.0}}


## Boss fight after the front lock; in_range = player inside the villain lane ±1.
static func boss(in_range: bool, vulnerable: bool = false) -> Dictionary:
	var lane: int = 1 if in_range else 4
	return {"phase": &"boss", "t": 24.0, "player": player(257.0, lane), "villains": [villain(254.9, 0, 101.0, true, vulnerable)],
		"lock": {"active": true, "in_range": in_range, "target_id": 0 if in_range else -1, "reason": "" if in_range else "lane"},
		"hint": ("지금! 분노 폭탄" if vulnerable else "발사 꾹 · 경직 노려") if in_range else "◀ 원흉 차로로",
		"distance_m": 0.0, "progress": 1.0, "projectiles": [], "hazards": {"beams": [], "waves": [], "items": []},
		"stats": {"combo": 6, "fails": 0, "pay_mul": 1.0}}


static func kill() -> Dictionary:
	var st: Dictionary = boss(true)
	st["phase"] = &"kill"
	st["villains"] = [villain(272.1, 0, 0.0, false)]
	st["hint"] = ""
	return st


## GameSim state().result after a run with `tows` retries (P0#6: time / min HP / tows accumulate over retries).
static func result(tows: int = 0) -> Dictionary:
	var star2: bool = tows == 0
	return {"stars": 2 + (1 if star2 else 0), "missions": [
			{"label": "원인 제거 (참교육 완료)", "done": true},
			{"label": "내구도 60 이상 · 견인 0회", "done": star2},
			{"label": "잔챙이 빌런 2명 전원 참교육", "done": true}],
		"score": 13477, "time_s": 28.0 + 41.5 * float(tows), "boss_time_s": 11.4, "hp": 80, "hp_max": 100, "min_hp": 80 if tows == 0 else 0,
		"tows": tows, "retries": tows, "pay_mul": 1.0 if tows == 0 else 0.8, "freed": 1200, "cath": 84.0, "cheaters": 2,
		"villain_name": "정속주행 김사장", "stage_id": 1}


static func events_fight() -> Array[Dictionary]:
	return [
		{"type": "fire", "target_id": 0, "from_s": 259.0, "from_x": -1.8, "to_s": 255.0, "to_x": -5.4, "dur": 0.32, "lob": false},
		{"type": "hit", "target_id": 0, "dmg": 4.0, "window": true, "immune": false, "kind": "tack", "popped": 1, "s": 255.0, "x": -5.4},
		{"type": "miss", "s": 248.6, "x": 8.9, "reason": "lane"},
		{"type": "damage", "amount": 12, "hp": 68, "hp_max": 100, "reason": "원흉 상향등", "cause": "highbeam", "floor": false},
	]
