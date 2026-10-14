extends RefCounted
## Integration smoke (suite "integration"; --suite=all): ScrApp hosts the REAL res://view/game.tscn the way final
## integration will (NATIVE_PARITY 8-2/8-3): card → start → game.tscn under GameHost with stage_id + loadout →
## back to the dashboard frees it. Reports whether game.tscn already exposes the contract signals.
##   godot47 --headless --path native -s res://tests/run_tests.gd -- --suite=integration --filter=screens_host

const SUITE := "integration"

var _fails: int = 0


func _check(ok: bool, what: String) -> void:
	print(("PASS" if ok else "FAIL") + " screens_host: " + what)
	if not ok:
		_fails += 1


func run() -> int:
	var tree := Engine.get_main_loop() as SceneTree
	ScrKit.feedback_enabled = false
	var app := ScrApp.new()
	app.private_save = "user://test_screens/host.json"
	app.game_scene_path = ScrApp.REAL_GAME
	tree.root.add_child(app)
	await tree.process_frame
	var los: Array = []
	app.start_stage.connect(func(id: int, lo: Dictionary) -> void: los.append([id, lo]))
	app.pick_stage(1)
	app.start_from_card()
	for i: int in 20:
		await tree.process_frame
	var g: Node = app.game
	_check(g != null and g.is_inside_tree() and g.get_parent() == app.game_host, "real game.tscn loaded under GameHost")
	_check(g != null and int(g.get(&"stage_id")) == 1 and los.size() == 1, "stage_id 1 set before _ready, start_stage emitted once")
	var has_finish: bool = g != null and g.has_signal(&"stage_finished")
	var has_pause: bool = g != null and (g.has_signal(&"pause_requested") or g.has_signal(&"paused_changed"))
	var has_loadout: bool = g != null and &"loadout" in g
	var has_hold: bool = g != null and &"intro_hold" in g and g.has_method(&"begin")
	var has_hosted: bool = g != null and &"hosted" in g
	print("INFO screens_host: game.tscn contract — stage_finished=%s pause signal=%s loadout=%s intro_hold+begin=%s hosted=%s"
		% [has_finish, has_pause, has_loadout, has_hold, has_hosted])
	# the real game pauses the tree itself (HUD pause button → set_paused); the app must follow both ways
	if g != null and g.has_method(&"set_paused"):
		g.call(&"set_paused", true)
		for i: int in 3:
			await tree.process_frame
		_check(app.state == ScrApp.State.PAUSED and app.pause_menu != null, "game.set_paused(true) → app pause menu")
		app.hide_pause()
		await tree.process_frame
		_check(not tree.paused and app.state == ScrApp.State.GAME and not bool(g.get(&"hud").get(&"paused")), "계속하기 → tree and game HUD unpaused")
		g.call(&"set_paused", true)
		for i: int in 3:
			await tree.process_frame
		g.call(&"set_paused", false)
		for i: int in 3:
			await tree.process_frame
		_check(app.state == ScrApp.State.GAME and app.pause_menu == null, "game.set_paused(false) by itself → menu closes")
	app.reward_menu()
	for i: int in 3:
		await tree.process_frame
	_check(app.game == null and app.state == ScrApp.State.TITLE and app.game_host.get_child_count() == 0, "menu frees the game, back on the dashboard")
	app.queue_free()
	await tree.process_frame
	ScrKit.feedback_enabled = true
	ScrKit.clear_caches()
	return _fails
