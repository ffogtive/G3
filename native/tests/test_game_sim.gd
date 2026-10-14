extends RefCounted
## GameSim contract + determinism (NATIVE_PORT 3-2/3-3): two autopilot runs of 1-1 with the same seed produce the
## same event log and final state bit for bit; another seed differs. Also checks the fixed state() shape the
## view/UI read, the event types, and the T0 perf budget (GameSim ≤ 2 ms/tick in the container).
##
## 가설: ✅ every random draw in sim/ comes from a seeded RandomNumberGenerator (boss, weapons, cosmetic, autopilot)
##       or the C++ mulberry32, so a seed fixes the whole run.
## r3 W (combat hooks, both backends): a stub SkillsSim subclass counts the calls — every 압정 hit on a villain → exactly
## one skills.on_tack_hit(sim, v, r), mini hits / bombs → none; a hit through invuln → one on_player_hit, none while
## invulnerable; sig without a ported module → behaviors/generic_window.gd (config.boss.genericWindow.on), 1-1 occupy.

const _DB := preload("res://core/db.gd")
const PHASES: Array[StringName] = [&"intro", &"jam", &"boss", &"kill", &"release", &"cruise", &"result", &"wreck", &"fail"]

var _fails: int = 0


func _check(ok: bool, what: String) -> void:
	print(("PASS" if ok else "FAIL") + " game_sim: " + what)
	if not ok:
		_fails += 1


func run() -> int:
	var stage: Dictionary = _DB.find_stage(_DB.load_json("res://data/stages.json"), 1)
	var tables: Dictionary = _DB.load_traffic_tables()
	var a: Dictionary = _play(stage, tables, 4242)
	var b: Dictionary = _play(stage, tables, 4242)
	var c: Dictionary = _play(stage, tables, 4243)
	print("INFO game_sim: %d events, end %s at %.2f s, %.0f µs/tick" % [int(a["n"]), a["phase"], float(a["t"]), float(a["us"])])
	_check(a["hash"] == b["hash"] and a["final"] == b["final"], "same seed → identical event log + final state (%s)" % str(a["hash"]).substr(0, 12))
	_check(a["hash"] != c["hash"], "seed 4243 → a different run (the check is live)")
	_check(a["phase"] == &"result", "the run reaches the result card")
	_check(float(a["us"]) < 2000.0, "T0 perf: GameSim %.0f µs/tick ≤ 2000" % float(a["us"]))
	var types: Dictionary = a["types"]
	for t: String in ["phase", "lock", "fire", "hit", "stun", "damage", "kill", "release", "honk", "honk_reply", "bubble"]:
		_check(types.has(t), "event type '%s' raised (%d)" % [t, int(types.get(t, 0))])
	_shape(stage, tables)
	_hooks(tables)
	return _fails


func _play(stage: Dictionary, tables: Dictionary, seed: int) -> Dictionary:
	var sim := GameSim.new()
	sim.setup(stage, tables, seed)
	sim.autopilot = Autopilot.new(seed)
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var n: int = 0
	var types: Dictionary = {}
	var ticks: int = 0
	var t0: int = Time.get_ticks_usec()
	while sim.time < 150.0 and sim.phase != &"result":
		sim.step(Cfg.TICK)
		ticks += 1
		for e: Dictionary in sim.events():
			n += 1
			types[str(e["type"])] = int(types.get(str(e["type"]), 0)) + 1
			ctx.update(var_to_bytes(e))
	var us: float = (Time.get_ticks_usec() - t0) / float(maxi(1, ticks))
	var st: Dictionary = sim.state()
	var final: PackedByteArray = var_to_bytes([st["player"], st["villains"], st.get("result", {}), sim.time])
	return {"hash": ctx.finish().hex_encode(), "final": final, "n": n, "types": types, "phase": sim.phase, "t": sim.time, "us": us}


func _shape(stage: Dictionary, tables: Dictionary) -> void:
	var sim := GameSim.new()
	sim.setup(stage, tables, -1)
	for i: int in 600:
		sim.step(Cfg.TICK)
	var st: Dictionary = sim.state()
	var ok: bool = PHASES.has(st["phase"]) and st.has("t") and st["hint"] is String and st["distance_m"] is float and st["progress"] is float
	for k: String in ["s", "x", "lane", "v", "hp", "hp_max", "rage", "boost"]:
		ok = ok and (st["player"] as Dictionary).has(k)
	for k: String in ["id", "kind", "s", "x", "lane", "hp", "hp_max", "alive", "dying", "tell", "vulnerable"]:
		ok = ok and ((st["villains"] as Array)[0] as Dictionary).has(k)
	for k: String in ["active", "in_range", "target_id", "reason"]:
		ok = ok and (st["lock"] as Dictionary).has(k)
	_check(ok and ((st["villains"] as Array)[0] as Dictionary)["tell"] is StringName, "state() carries the fixed interface keys (phase %s)" % st["phase"])
	_check(sim.traffic() is TrafficBridge and sim.traffic().count() > 100, "traffic() hands out the bridge for the NPC buffer")
	var prog: float = float(st["progress"])
	var dist: float = float(st["distance_m"])
	var ref: float = sim.boss.ref_s()
	_check(is_equal_approx(prog, clampf((sim.player.s - sim.start_s) / (ref - sim.start_s), 0.0, 1.0)) and is_equal_approx(dist, ref - sim.player.s),
		"N1: progress %.3f and distance %.1f m come from the same live villain s" % [prog, dist])


# --- r3 W: combat hooks ---------------------------------------------------------------------------------

## A SkillsSim subclass built at runtime so its overrides match whatever signature skills_sim.gd ends up with.
func _stub_skills() -> SkillsSim:
	var base: Script = load("res://sim/skills_sim.gd")
	var src: String = "extends SkillsSim\nvar n_tack: int = 0\nvar n_player: int = 0\nvar tack_ids: Array = []\n"
	src += _override(base, "on_tack_hit", 3, "n_tack += 1\n\ttack_ids.append(int((a1 as Dictionary).get(\"index\", -1)) if a1 is Dictionary else -1)")
	src += _override(base, "on_player_hit", 1, "n_player += 1")
	var gd := GDScript.new()
	gd.source_code = src
	if gd.reload() != OK:
		print("INFO game_sim: stub source\n" + src)
		return null
	return gd.new() as SkillsSim


func _override(base: Script, name: String, nargs: int, body: String) -> String:
	var ret: String = " -> void"
	var tail: String = ""
	for m: Dictionary in base.get_script_method_list():
		if str(m["name"]) == name:
			var r: Dictionary = m.get("return", {})
			var typ: int = int(r.get("type", TYPE_NIL))
			if typ == TYPE_NIL and int(r.get("usage", 0)) & PROPERTY_USAGE_NIL_IS_VARIANT:
				ret = ""
				tail = "\n\treturn null"
			elif typ != TYPE_NIL:
				ret = " -> " + type_string(typ)
				tail = "\n\treturn super.%s(%s)" % [name, ", ".join(PackedStringArray(range(nargs).map(func(i: int) -> String: return "a%d" % i)))]
	var args: PackedStringArray = []
	for i: int in nargs:
		args.append("a%d = null" % i)
	return "func %s(%s)%s:\n\t%s%s\n" % [name, ", ".join(args), ret, body, tail]


func _hooks(tables: Dictionary) -> void:
	var stages: Variant = _DB.load_json("res://data/stages.json")
	var s1: Dictionary = _DB.find_stage(stages, 1)
	var probe: SkillsSim = _stub_skills()
	_check(probe != null, "W: stub SkillsSim subclass compiles against skills_sim.gd")
	if probe == null:
		return
	for fb: bool in [false, true]:
		_hooks_tack(s1, tables, fb)
	_hooks_bomb(s1, tables)
	_hooks_player_hit(s1, tables)
	_hooks_generic_window(stages, tables)


## Autopilot 1-1 to the result: on_tack_hit count == villain 압정 hit events at every tick, minis never counted.
func _hooks_tack(stage: Dictionary, tables: Dictionary, fb: bool) -> void:
	var sim := GameSim.new()
	sim.force_fallback = fb
	var stub: SkillsSim = _stub_skills()
	sim.skills = stub
	sim.setup(stage, tables, 77)
	sim.autopilot = Autopilot.new(77)
	var tack: int = 0
	var minis: int = 0
	var mismatch: String = ""
	var first_ok: bool = false
	while sim.time < 150.0 and sim.phase != &"result":
		sim.step(Cfg.TICK)
		for e: Dictionary in sim.events():
			if str(e["type"]) == "hit":
				if str(e.get("kind", "")) == "tack" and int(e.get("target_id", -1)) >= 0:
					tack += 1
				elif str(e.get("kind", "")) == "mini":
					minis += 1
		if tack == 1 and not first_ok:
			first_ok = int(stub.get("n_tack")) == 1
		if mismatch == "" and int(stub.get("n_tack")) != tack:
			mismatch = "t=%.2f calls %d vs hits %d" % [sim.time, int(stub.get("n_tack")), tack]
	var tag: String = "fallback" if fb else "native"
	print("INFO game_sim: W %s 1-1 tack hits %d, mini hits %d, on_tack_hit %d" % [tag, tack, minis, int(stub.get("n_tack"))])
	_check(tack > 0 and first_ok, "W %s: the 1st villain 압정 hit → on_tack_hit ×1" % tag)
	_check(mismatch == "" and int(stub.get("n_tack")) == tack, "W %s: on_tack_hit %d == villain 압정 hits %d, mini hits %d not counted %s" % [tag,
		int(stub.get("n_tack")), tack, minis, mismatch])


## config.skills off → the fight's &"rage" is the legacy bomb: bomb hits never call on_tack_hit.
func _hooks_bomb(stage: Dictionary, tables: Dictionary) -> void:
	var t: Dictionary = tables.duplicate()
	var cfg: Dictionary = (tables["config"] as Dictionary).duplicate()
	cfg.erase("skills")
	t["config"] = cfg
	var sim := GameSim.new()
	var stub: SkillsSim = _stub_skills()
	sim.skills = stub
	sim.setup(stage, t, 31)
	sim.autopilot = Autopilot.new(31)
	var tack: int = 0
	var bombs: int = 0
	while sim.time < 150.0 and sim.phase != &"result":
		if sim.front_locked and sim.rage < 0.5:
			sim.rage = 1.0
		sim.step(Cfg.TICK)
		for e: Dictionary in sim.events():
			if str(e["type"]) == "hit":
				if str(e.get("kind", "")) == "tack" and int(e.get("target_id", -1)) >= 0:
					tack += 1
				elif str(e.get("kind", "")) == "bomb":
					bombs += 1
	_check(bombs > 0 and int(stub.get("n_tack")) == tack, "W: legacy bombs %d hit → on_tack_hit %d == 압정 hits %d (bombs not counted)" % [bombs,
		int(stub.get("n_tack")), tack])


func _hooks_player_hit(stage: Dictionary, tables: Dictionary) -> void:
	var sim := GameSim.new()
	var stub: SkillsSim = _stub_skills()
	sim.skills = stub
	sim.setup(stage, tables, 41)
	sim.autopilot = Autopilot.new(41)
	while sim.time < 150.0 and not sim.front_locked:
		sim.step(Cfg.TICK)
		sim.events()
	sim.autopilot = null
	var n0: int = int(stub.get("n_player"))
	sim.player.invuln = 0.0
	var hp0: int = sim.hp
	sim._on_player_hit({"cause": "swerve", "text": "테스트", "push": 2.5})
	var n1: int = int(stub.get("n_player"))
	_check(sim.front_locked and sim.hp < hp0 and n1 == n0 + 1, "W: fight hit through invuln (hp %d → %d) → on_player_hit ×1 (%d → %d)" % [hp0, sim.hp, n0, n1])
	_check(sim.player.invuln > 0.0, "W: the hit left the player invulnerable (%.2f s)" % sim.player.invuln)
	sim._on_player_hit({"cause": "swerve", "text": "테스트", "push": 2.5})
	_check(int(stub.get("n_player")) == n1, "W: a hit while invulnerable → no on_player_hit (%d)" % int(stub.get("n_player")))
	# real attack paths: player_hit damage events vs calls over whole fights (seeds until a few hits landed)
	var calls: int = 0
	var dmg_events: int = 0
	for seed: int in range(43, 63):
		var sim2 := GameSim.new()
		var stub2: SkillsSim = _stub_skills()
		sim2.skills = stub2
		sim2.setup(stage, tables, seed)
		sim2.autopilot = Autopilot.new(seed)
		while sim2.time < 150.0 and sim2.phase != &"result":
			sim2.step(Cfg.TICK)
			for e: Dictionary in sim2.events():
				if str(e["type"]) == "damage" and not (str(e.get("cause", "")) in ["bump", "cone", "neck"]) and int(e.get("raw", 0)) > 0:
					dmg_events += 1
		calls += int(stub2.get("n_player"))
		if dmg_events >= 3:
			break
	_check(dmg_events >= 3 and calls == dmg_events, "W: autopilot 1-1 fights — on_player_hit %d == attack damage events %d" % [calls, dmg_events])


## sig without a module → GenericWindow (config.boss.genericWindow.on != false); 1-1 keeps occupy.
func _hooks_generic_window(stages: Variant, tables: Dictionary) -> void:
	var s1 := GameSim.new()
	s1.setup(_DB.find_stage(stages, 1), tables, 5)
	_check(s1.boss.beh != null and s1.boss.beh.get_script() == load("res://sim/behaviors/occupy.gd"), "W: 1-1 (sig occupy) keeps OccupyBehavior")
	var gw_path: String = "res://sim/behaviors/generic_window.gd"
	var landed: bool = ResourceLoader.exists(gw_path)
	var s2 := GameSim.new()
	s2.setup(_DB.find_stage(stages, 2), tables, 5)
	var path2: String = (s2.boss.beh.get_script() as Script).resource_path if s2.boss.beh != null else ""
	if landed:
		_check(path2 == gw_path, "W: 1-2 (sig cutin_snap, not ported) → beh = generic_window.gd (%s)" % path2)
	else:
		print("INFO game_sim: res://sim/behaviors/generic_window.gd not in the tree yet (combat C2) → beh %s" % path2)
		_check(s2.boss.beh == null, "W: 1-2 without generic_window.gd → no behaviour (guarded), runs as before")
	var t: Dictionary = tables.duplicate()
	var cfg: Dictionary = (tables["config"] as Dictionary).duplicate(true)
	var boss_cfg: Dictionary = cfg.get("boss", {})
	boss_cfg["genericWindow"] = {"on": false}
	cfg["boss"] = boss_cfg
	t["config"] = cfg
	var s3 := GameSim.new()
	s3.setup(_DB.find_stage(stages, 2), t, 5)
	_check(s3.boss.beh == null, "W: config.boss.genericWindow.on = false → 1-2 has no behaviour")
