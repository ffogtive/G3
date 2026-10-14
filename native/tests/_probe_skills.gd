extends SceneTree
const _DB := preload("res://core/db.gd")
func _initialize() -> void:
	var stage: Dictionary = _DB.find_stage(_DB.load_json("res://data/stages.json"), 1)
	for fb: bool in [false, true]:
		for sd: int in [1007, 3, 11, 42, 77]:
			var tables: Dictionary = _DB.load_traffic_tables()
			tables["options"] = {"loadout": {"finish": "rocket", "items": ["mv_jump", "mv_drone"]}}
			var sim := GameSim.new()
			sim.force_fallback = fb
			sim.setup(stage, tables, sd)
			sim.autopilot = Autopilot.new(sd * 13 + 1)
			var types: Dictionary = {}
			var boss_real0: float = -1.0
			var kill_real: float = -1.0
			var lock_rage: float = -1.0
			var denied: Dictionary = {}
			var rel_real: float = -1.0
			while sim.time < 150.0 and sim.phase != &"result":
				sim.step(Cfg.TICK)
				for e: Dictionary in sim.events():
					var ty: String = str(e["type"])
					types[ty] = int(types.get(ty, 0)) + 1
					if ty == "skill_denied":
						denied[str(e["reason"]) + ":" + str(e["id"])] = int(denied.get(str(e["reason"]) + ":" + str(e["id"]), 0)) + 1
					if ty == "phase" and e["phase"] == &"boss": boss_real0 = sim.real_time
					if ty == "phase" and e["phase"] == &"kill": kill_real = sim.real_time
					if ty == "phase" and e["phase"] == &"release": rel_real = sim.real_time
					if ty == "lock": lock_rage = sim.rage
			var r: Dictionary = sim.state().get("result", {})
			print("PROBE fb=%s seed=%d %s boss_sim=%.1f boss_real=%.1f kill→rel=%.2f lock_rage=%.2f skills=%s denied=%s hp=%s fin=%d" % [fb, sd, sim.phase,
				float(r.get("boss_time_s", -1)), kill_real - boss_real0, rel_real - kill_real, lock_rage, str(r.get("skills", {})), str(denied), r.get("hp"), int(types.get("finisher", 0))])
	quit(0)
