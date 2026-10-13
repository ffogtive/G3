extends RefCounted
## Determinism (NATIVE_PORT 3-2 fixed tick / 3-3 RNG): two runs with the same seed and the same scripted input give
## bit-identical traffic buffers at t = 30 s; a different seed does not.
##  1. Game level: game.tscn (TrafficBridge + player driver + input path), lane changes and honks at fixed ticks.
##  2. Bridge level, both backends (C++ Traffic when loaded, GDScript creep fallback), synthetic player state.

const GameScene: PackedScene = preload("res://view/game.tscn")
const TICKS: int = 3600  # 30 s at 120 Hz
const SCHEDULE: Dictionary = {240: "lane:-1", 600: "horn", 1100: "lane:1", 1700: "horn", 2300: "lane:-1", 3000: "horn"}

var _fails: int = 0


func _check(ok: bool, what: String) -> void:
	print(("PASS" if ok else "FAIL") + " determinism: " + what)
	if not ok:
		_fails += 1


func run() -> int:
	var tree := Engine.get_main_loop() as SceneTree
	var a: Dictionary = await _game_run(tree, 1007)
	var b: Dictionary = await _game_run(tree, 1007)
	var c: Dictionary = await _game_run(tree, 1008)
	print("INFO determinism: traffic=%s, %d records, %d events, player s %.2f" % [a["traffic"], (a["buf"] as PackedFloat32Array).size() / 8,
		(a["log"] as Array).size(), float(a["player_s"])])
	_check((a["buf"] as PackedFloat32Array).size() > 8 * 100, "buffer holds the jam (%d records)" % ((a["buf"] as PackedFloat32Array).size() / 8))
	_check(a["buf"] == b["buf"], "game: same seed → identical traffic buffer at t=30 s (%s)" % _diff(a["buf"], b["buf"]))
	_check(a["log"] == b["log"] and a["player"] == b["player"], "game: same seed → identical event log and player state")
	_check(a["buf"] != c["buf"], "game: seed 1008 → a different buffer (the check is live)")
	for force_fallback: bool in [false, true]:
		if not force_fallback and not TrafficBridge.native_available():
			print("SKIP determinism: C++ Traffic not loaded (bridge-level native run)")
			continue
		var name: String = "fallback" if force_fallback else "native"
		var x: PackedFloat32Array = _bridge_run(1007, force_fallback)
		var y: PackedFloat32Array = _bridge_run(1007, force_fallback)
		var z: PackedFloat32Array = _bridge_run(1008, force_fallback)
		_check(x.size() > 0 and x == y, "bridge/%s: same seed → identical buffer at t=30 s (%s)" % [name, _diff(x, y)])
		_check(x != z, "bridge/%s: different seed → different buffer" % name)
	return _fails


func _game_run(tree: SceneTree, seed: int) -> Dictionary:
	var g: Game = GameScene.instantiate() as Game
	g.manual = true
	g.seed = seed
	g.with_debug_panel = false
	tree.root.add_child(g)
	var done: int = 0
	var keys: Array = SCHEDULE.keys()
	keys.sort()
	for k: int in keys:
		g.advance_ticks(k - done)
		done = k
		var cmd: String = SCHEDULE[k]
		if cmd == "horn":
			g.input.inject("horn:down")
			g.input.inject("horn:up")
		else:
			g.input.inject(cmd)
	g.advance_ticks(TICKS - done)
	var log: Array = []
	for e: Dictionary in g.log_events:
		log.append(JSON.stringify(e, "", true, true))
	var out: Dictionary = {"buf": g.buffer().duplicate(), "log": log, "player_s": g.player.s,
		"player": [g.player.s, g.player.v, g.player.x, g.player.lane], "traffic": g.traffic.get_script().resource_path}
	g.queue_free()
	await tree.process_frame
	return out


## Pure sim: the bridge with a scripted player (creeps at 1.5 m/s, lane 3 → 2 at 10 s).
func _bridge_run(seed: int, force_fallback: bool) -> PackedFloat32Array:
	var stage: Dictionary = ViewData.stage(1)
	var br := TrafficBridge.new()
	br.setup(stage, ViewData.table("config") as Dictionary, seed, force_fallback)
	var si: Dictionary = br.setup_info()
	var p: Dictionary = {"lane": float(si["start_lane"]), "s": float(si["start_s"]), "v": 1.5, "x": Cfg.lane_x(int(si["start_lane"]))}
	for i: int in TICKS:
		if i == 1200:
			p["lane"] = 2.0
			p["x"] = Cfg.lane_x(2)
		p["s"] = float(p["s"]) + float(p["v"]) * Cfg.TICK
		br.step(Cfg.TICK, p)
		if i == 600:
			br.honk(int(p["lane"]), float(p["s"]))
		br.events()
	var buf := PackedFloat32Array()
	buf.resize(br.count() * 8)
	br.read_into(buf)
	return buf


func _diff(x: PackedFloat32Array, y: PackedFloat32Array) -> String:
	if x.size() != y.size():
		return "size %d vs %d" % [x.size(), y.size()]
	var d: int = 0
	for i: int in x.size():
		if x[i] != y[i]:
			d += 1
	return "%d of %d floats differ" % [d, x.size()]
