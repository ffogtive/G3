## Autopilot runner shared by the r3 fallback e2e tests (test_fallback_progress.gd, test_fallback_parity.gd).
## Not a test itself (no test_ prefix).
extends RefCounted

const _DB := preload("res://core/db.gd")

## Shared autopilot runner for the fallback e2e tests.
## Plays until the boss phase (or `limit` sim s; until the lock when `to_lock`). Returns {jam (s, -1 = never),
## lock (s since jam start, -1 = never), stop (fraction of jam-phase ticks with v < 1), none, honks, assists, tows,
## front_rage, mini_hits, phase}.
static func approach(stage: Dictionary, sd: int, fb: bool, limit: float, to_lock: bool = false) -> Dictionary:
	var sim := GameSim.new()
	sim.force_fallback = fb
	sim.setup(stage, _DB.load_traffic_tables(), sd)
	sim.autopilot = Autopilot.new(sd * 13 + 1)
	var t_jam: float = -1.0
	var t_boss: float = -1.0
	var t_lock: float = -1.0
	var jam_t: float = 0.0
	var stop_t: float = 0.0
	var honks: Dictionary = {}
	var tows: int = 0
	var front_rage: int = 0
	var mini_hits: int = 0
	while sim.time < limit:
		sim.step(Cfg.TICK)
		for e: Dictionary in sim.events():
			match str(e.get("type", "")):
				"phase":
					if str(e["phase"]) == "jam" and t_jam < 0.0:
						t_jam = sim.time
					elif str(e["phase"]) == "boss" and t_boss < 0.0:
						t_boss = sim.time
				"lock":
					if t_lock < 0.0:
						t_lock = sim.time
				"honk_reply":
					var k: String = str(e.get("data", ""))
					honks[k] = int(honks.get(k, 0)) + 1
				"auto_tow":
					tows += 1
				"bubble":
					if str(e.get("table", "")) == "frontRage":
						front_rage += 1
				"hit":
					if str(e.get("kind", "")) == "mini":
						mini_hits += 1
		if sim.phase == &"jam":
			jam_t += Cfg.TICK
			if sim.player.v < 1.0:
				stop_t += Cfg.TICK
		if (t_boss >= 0.0 and not to_lock) or t_lock >= 0.0 or not (sim.phase in [&"intro", &"jam", &"boss", &"wreck", &"fail"]):
			break
	return {"jam": t_boss - t_jam if t_boss >= 0.0 else -1.0, "lock": t_lock - t_jam if t_lock >= 0.0 else -1.0,
		"stop": stop_t / maxf(Cfg.TICK, jam_t), "none": int(honks.get("", 0)), "honks": honks,
		"assists": int(sim.bridge.info().get("assists", 0)), "tows": tows, "front_rage": front_rage, "mini_hits": mini_hits,
		"phase": str(sim.phase)}
