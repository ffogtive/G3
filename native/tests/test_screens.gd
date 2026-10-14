extends RefCounted
## T0 meta screens (NATIVE_PARITY A2–A21, 8-7/8-9 "--filter=screens"): the app loop on the dev fake game.
##   title → (START) card → start_stage(id, loadout) once → fake game → stage_finished → Progress.record_result →
##   reward timeline (web TL order and times) → 다음 빌런 (1-2 card) → ✕ → dashboard (wallet, ★, NEXT moved);
##   abort = no reward; pause → resume / quit; card timer starts exactly once; locked tile does nothing;
##   garage buy (auto-equip, wallet, tab counts, badge) / poor (no change, "₩X 부족!") / equip; settings persist;
##   album shows the cleared stage; G2 game held behind the card (begin() on start, freed on ✕); a game that pauses the
##   tree itself gets the app pause menu; a raw GameSim 1-1 autopilot result (no `cleared`) is paid and recorded.
##   Every model is a private Progress on user://test_screens/ (never the player save).
##
## 가설: ✅ the screens only talk to ScrMeta, so the same flow runs on the real Progress autoload API.

const DIR: String = "user://test_screens"
const _DB := preload("res://core/db.gd")

var _fails: int = 0
var _tree: SceneTree


func _check(ok: bool, what: String) -> void:
	print(("PASS" if ok else "FAIL") + " screens: " + what)
	if not ok:
		_fails += 1


func run() -> int:
	_tree = Engine.get_main_loop() as SceneTree
	ScrKit.feedback_enabled = false
	await _flow()
	await _sim_contract()
	await _garage()
	await _settings()
	await _card_timer()
	await _stub_parity()
	ScrKit.feedback_enabled = true
	ScrKit.clear_caches()
	_tree.paused = false
	return _fails


func _frames(n: int = 2) -> void:
	for i: int in n:
		await _tree.process_frame


func _app() -> ScrApp:
	var app := ScrApp.new()
	app.private_save = DIR.path_join("flow.json")
	app.game_scene_path = ScrApp.FAKE_GAME   # the shipped default is REAL_GAME (FI 8-2); this loop test drives the fake
	_tree.root.add_child(app)
	return app


# ───────────────────────────── navigation loop
func _flow() -> void:
	var app: ScrApp = _app()
	await _frames(3)
	var starts: Array = []
	app.start_stage.connect(func(id: int, lo: Dictionary) -> void: starts.append([id, lo]))
	_check(app.state == ScrApp.State.TITLE and app.title != null, "app opens on the dashboard (A2)")
	_check(app.meta.p.name == "PrivateProgress" or app.meta.is_stub, "app runs on a private progress model in tests")
	var t: ScrTitle = app.title
	_check((t.find("Wallet") as Label).text == "₩0" and (t.find("Subs") as Label).text == "0", "fresh wallet chip ₩0 / 구독자 0 (A3)")
	_check(t.tiles.size() == 10 and bool((t.tiles[2] as Control).get_meta(&"locked")) and not bool((t.tiles[1] as Control).get_meta(&"locked")), "chapter 1 shows 10 tiles, 1-1 open, 1-2 locked (A7)")
	_check(t.find("Next") != null and (t.tiles[1] as Control).find_child("Next", true, false) != null, "NEXT tag on 1-1 (A8)")
	var sub0: String = ((t.find("Start") as Control).find_child("Sub", true, false) as Label).text
	_check(sub0.begins_with("STAGE 1-1"), "START points at 1-1 (%s)" % sub0)
	# locked tile: shake only
	ScrKit.press(t.tiles[2])
	await _frames()
	_check(app.state == ScrApp.State.TITLE, "tapping a locked tile keeps the dashboard (A7)")
	# START → card
	ScrKit.press(t.find("Start"))
	await _frames()
	_check(app.state == ScrApp.State.CARD and app.card != null and app.card.stage_id == 1, "START → stage card 1-1 (A13)")
	var held: ScrFakeGame = app.game as ScrFakeGame
	_check(held != null and held.is_inside_tree() and held.intro_hold and held.began == 0 and starts.is_empty(),
		"G2: the game is loaded behind the card with its intro held, start_stage not yet sent")
	var card: ScrStageCard = app.card
	_check(card.find("Road") != null and card.find("Missions") != null, "card shows 도로 상황 + ★ 미션")
	var ml: Array = app.meta.missions_for(1)
	var lbl0: Label = card.find("Mission0").find_child("Label", true, false)
	_check(lbl0.text == str(ml[0]["label"]) and (card.find("JamKm") as Label).text == "2.4km", "card mission 1 = '%s', 정체 2.4km" % lbl0.text)
	# tap before the 280 ms arm is ignored, after it starts
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	card._gui_input(ev)
	_check(app.state == ScrApp.State.CARD, "a tap inside the 280 ms arm does not start")
	card.elapsed = 0.5
	card._gui_input(ev)
	card._gui_input(ev)
	await _frames()
	_check(app.state == ScrApp.State.GAME and starts.size() == 1 and int(starts[0][0]) == 1, "tap → start_stage(1, loadout) exactly once")
	var lo: Dictionary = starts[0][1] if not starts.is_empty() else {}
	_check(lo.has("hp_max") and lo.has("weapon") and lo.has("left_hand") and str(lo.get("car", "")) == "car_hatch", "loadout dict reaches the game (D8)")
	var game: ScrFakeGame = app.game as ScrFakeGame
	_check(game != null and game.stage_id == 1 and game.is_inside_tree() and game == held and game.began == 1 and not game.intro_hold
		and game.hosted, "start releases the held game (begin() once, same instance, hosted) under GameHost")
	# pause → resume
	game.pause_requested.emit()
	await _frames()
	_check(app.state == ScrApp.State.PAUSED and _tree.paused and app.pause_menu != null, "pause_requested → pause menu, tree paused (A19)")
	ScrKit.press(app.pause_menu.find("Resume"))
	await _frames()
	_check(app.state == ScrApp.State.GAME and not _tree.paused, "계속하기 → back in the game, unpaused")
	# clear
	game.finish(ScrFakeGame.make_result(1, true, 82))
	await _frames(3)
	_check(app.state == ScrApp.State.REWARD and app.reward_screen != null, "stage_finished → reward timeline (A17)")
	var rw: Dictionary = app.last_reward
	_check(int(rw.get("payout", -1)) == 190000 and int(rw.get("stars", 0)) == 3, "D3 1-1 ★3 + 얌체 1 + 잔챙이 2 = ₩190,000 (got %s)" % rw.get("payout"))
	_check(app.meta.wallet() == 190000 and app.meta.is_unlocked(2) and not app.meta.is_unlocked(3), "wallet ₩190,000, 1-2 unlocked only (A12)")
	var r: ScrReward = app.reward_screen
	r.manual = true
	r.advance(4.0)
	var want: Array = [["open", 0], ["stamp", 280], ["mission0", 700], ["mission1", 1080], ["mission2", 1460], ["score_done", 1600],
		["money", 1750], ["wallet", 2150], ["chan", 2250], ["cmt0", 2450], ["cmt1", 2600], ["payout_done", 2700], ["cmt2", 2750],
		["wallet_done", 3050], ["unlock", 3100]]
	if not str(rw.get("milestone", "")).is_empty():
		want.insert(11, ["mile", 2600])   # first clear crosses 구독자 1천 → milestone toast at TL.mile
	_check(str(r.events) == str(want), "timeline order + web ms: %s" % str(r.events))
	_check(str(rw.get("milestone", "")) == "구독자 1천 돌파!" and r.find("Milestone") != null, "milestone 구독자 1천 돌파! shown at 2600 ms (D4)")
	r.advance(4.3)
	await _frames()
	_check(r.find("Milestone") == null and r.event_names().has("mile_close"), "milestone closes itself 4.2 s later")
	_check((r.find("Payout") as Label).text == "+₩190,000" and (r.find("WalletTotal") as Label).text == "₩190,000", "payout / wallet count-ups end on the record_result values")
	_check((r.find("Score") as Label).text == ScrKit.fmt(int(rw.get("score", 0))), "SCORE count-up ends on the result score")
	_check((r.find("Views") as Label).text == ScrKit.kor(int(rw.get("views", 0))) and (r.find("SubsGain") as Label).text == "+" + ScrKit.fmt(int(rw.get("subs_gained", 0))), "views / +subs counts end on record_result (D4)")
	_check(r.find("UnlockToast") != null, "unlock toast for 1-2")
	# 다음 빌런 → 1-2 card
	ScrKit.press(r.find("Next"))
	await _frames()
	var held2: ScrFakeGame = app.game as ScrFakeGame
	_check(app.state == ScrApp.State.CARD and app.card != null and app.card.stage_id == 2 and not is_instance_valid(game)
		and held2 != null and held2.stage_id == 2 and held2.intro_hold, "다음 빌런 → 1-2 card, old game freed, 1-2 held behind the card")
	ScrKit.press(app.card.find("Close"))
	await _frames(3)
	_check(app.state == ScrApp.State.TITLE and app.title != null and app.game == null and app.game_host.get_child_count() == 0,
		"card ✕ → dashboard, held game freed")
	t = app.title
	await _tree.create_timer(0.75).timeout
	_check((t.find("Wallet") as Label).text == "₩190,000", "dashboard wallet ₩190,000 (A3 count-up)")
	_check(((t.find("Start") as Control).find_child("Sub", true, false) as Label).text.begins_with("STAGE 1-2"), "START → 1-2 after clearing 1-1 (A8)")
	_check((t.tiles[1] as Control).find_child("Next", true, false) == null and (t.tiles[2] as Control).find_child("Next", true, false) != null, "NEXT moved to 1-2")
	_check((t.find("StarSum") as Label).text == "3", "chapter ★ sum 3 (A6)")
	# album shows 1-1
	t.album_requested.emit()
	await _frames(2)
	var al: ScrAlbum = app.overlay as ScrAlbum
	_check(al != null and bool((al.cards[1] as Control).get_meta(&"got")) and not bool((al.cards[2] as Control).get_meta(&"got")), "album: 1-1 collected, 1-2 silhouette (A14)")
	_check(al != null and (al.find("Got") as Label).text == "1/100" and (al.cards[1] as Control).find_child("Count", true, false) != null, "album count 1/100")
	ScrKit.press(al.find("Close"))
	await _frames(2)
	_check(app.overlay == null and app.state == ScrApp.State.TITLE, "album ✕ → dashboard")
	# abort: no reward
	app.pick_stage(2)
	app.start_from_card()
	await _frames()
	(app.game as ScrFakeGame).finish(ScrFakeGame.make_result(2, false, 30, true))
	await _frames(2)
	_check(app.state == ScrApp.State.TITLE and app.meta.wallet() == 190000 and app.meta.stars_of(2) == 0, "aborted run → dashboard, no reward / ★")
	# pause → quit
	app.pick_stage(2)
	app.start_from_card()
	await _frames()
	(app.game as ScrFakeGame).pause_requested.emit()
	await _frames()
	ScrKit.press(app.pause_menu.find("Quit"))
	await _frames(2)
	_check(app.state == ScrApp.State.TITLE and not _tree.paused and app.game == null, "pause → 메뉴로 → dashboard, game freed, unpaused")
	# retry from pause restarts the same stage
	app.pick_stage(1)
	app.start_from_card()
	await _frames()
	(app.game as ScrFakeGame).pause_requested.emit()
	await _frames()
	ScrKit.press(app.pause_menu.find("Retry"))
	await _frames(2)
	_check(app.state == ScrApp.State.GAME and (app.game as ScrFakeGame).stage_id == 1 and not _tree.paused, "pause → 다시하기 restarts 1-1")
	app.reward_menu()
	app.queue_free()
	await _frames(2)


# ───────────────────────────── real GameSim result · self-pausing game
## view/game.gd pauses the tree itself (HUD button / background) without a signal, and GameSim's state().result has
## no `cleared`: the app must still show its pause menu and pay the clear.
func _sim_contract() -> void:
	var app := ScrApp.new()
	app.private_save = DIR.path_join("sim.json")
	app.game_scene_path = ScrApp.FAKE_GAME
	_tree.root.add_child(app)
	await _frames(3)
	app.pick_stage(1)
	app.start_from_card()
	await _frames()
	var game: ScrFakeGame = app.game as ScrFakeGame
	_tree.paused = true   # the game's own set_paused(true)
	await _frames()
	_check(app.state == ScrApp.State.PAUSED and app.pause_menu != null, "game pausing the tree itself → app pause menu (A19)")
	_tree.paused = false  # the game's own pause button again
	await _frames()
	_check(app.state == ScrApp.State.GAME and app.pause_menu == null, "game resuming itself → pause menu closes")
	var stage: Dictionary = _DB.find_stage(_DB.load_json("res://data/stages.json"), 1)
	var sim := GameSim.new()
	sim.setup(stage, _DB.load_traffic_tables(), 3)
	sim.autopilot = Autopilot.new(3 * 13 + 1)
	while sim.time < 150.0 and sim.phase != &"result":
		sim.step(Cfg.TICK)
		sim.events()
	var raw: Dictionary = sim.state().get("result", {})
	_check(sim.phase == &"result" and not raw.has("cleared"), "GameSim 1-1 autopilot reaches result (no `cleared` key: %s)" % sim.phase)
	game.stage_finished.emit(raw)
	await _frames(3)
	var rw: Dictionary = app.last_reward
	_check(app.state == ScrApp.State.REWARD and int(rw.get("payout", 0)) > 0 and app.meta.wallet() == int(rw["payout"])
		and app.meta.is_unlocked(2), "raw GameSim result → cleared, record_result pays ₩%s, 1-2 unlocked" % rw.get("payout"))
	_check(int(raw.get("tows", 0)) > 0 or int(rw.get("stars", -1)) == int(raw.get("stars", -2)),
		"Progress ★%s == GameSim ★%s when there was no tow" % [rw.get("stars"), raw.get("stars")])
	_check(int(rw.get("score", -1)) == int(raw.get("score", -2)) and app.meta.best(1)["score"] == int(raw["score"]), "BEST = GameSim final score")
	app.reward_menu()
	await _frames(2)
	app.queue_free()
	await _frames()


# ───────────────────────────── garage
func _garage() -> void:
	var host := Control.new()
	_tree.root.add_child(host)
	var seed: Dictionary = {"ver": 3, "unlocked": 2, "stars": {"1": 3}, "best": {}, "wallet": 250000, "subs": 0, "album": {},
		"owned": ["wpn_caltrop"], "equip": {"weapon": "wpn_caltrop"}}
	var m: ScrMeta = ScrMeta.private(host, DIR.path_join("garage.json"), seed, true)
	var g := ScrGarage.new()
	g.setup(m)
	host.add_child(g)
	await _frames(2)
	_check(g.tab == "car" and g.cards.size() == 4 and g.status(m.item("car_porter")) == "buy", "garage opens on 차, 포터 buyable (A15)")
	_check(g.status(m.item("car_hatch")) == "equipped" and g.status(m.item("car_wrecker")) == "poor", "해치 장착 중, 레커 포상금 부족")
	var specs: Array = ScrGarage.specs(m.item("wpn_caltrop"))
	_check(str(specs) == str([["초당 피해 40", ""], ["3발 동시", "up"]]), "spec chips = web itemSpecs (마름쇠 '초당 피해 40 · 3발 동시')")
	ScrKit.press((g.cards["car_porter"] as Control).find_child("Buy", true, false))
	await _frames(2)
	_check(m.wallet() == 70000 and m.owns("car_porter") and m.equipped("car") == "car_porter", "buy 포터: −₩180,000, owned, auto-equipped (A16)")
	_check(g.status(m.item("car_porter")) == "equipped" and str((g.cards["car_porter"] as Control).get_meta(&"status")) == "equipped", "card re-rendered as 장착 중")
	var slot: Label = g.find("Slot_car").find_child("Name", true, false)
	var tab_car: Control = g.find("Tab_car")
	_check(slot.text == "1톤 포터" and tab_car != null, "loadout slot shows 1톤 포터")
	await _tree.create_timer(0.8).timeout
	_check((g.find("Wallet") as Label).text == "₩70,000", "garage wallet counted down to ₩70,000")
	# poor
	var poor: Control = (g.cards["car_wrecker"] as Control).find_child("Poor", true, false)
	ScrKit.press(poor)
	await _frames()
	var floats: Array[String] = []
	for n: Node in g.find_children("*", "Label", true, false):
		if (n as Label).text.ends_with("부족!") or (n as Label).text.begins_with("−"):
			floats.append((n as Label).text)
	_check(m.wallet() == 70000 and not m.owns("car_wrecker") and floats.has("₩380,000 부족!"), "poor: no change, '₩380,000 부족!' (%s)" % ", ".join(floats))
	# equip
	g.go_tab("weapon")
	await _frames()
	_check(g.status(m.item("wpn_tack")) == "owned", "weapon tab: 압정 owned (not equipped)")
	ScrKit.press((g.cards["wpn_tack"] as Control).find_child("Equip", true, false))
	await _frames()
	_check(m.equipped("weapon") == "wpn_tack" and g.status(m.item("wpn_tack")) == "equipped" and g.status(m.item("wpn_caltrop")) == "owned", "equip 압정: slot swapped")
	_check(str((m.loadout().get("weapon", {}) as Dictionary).get("id", "")) == "wpn_tack" and int(m.loadout().get("hp_max", 0)) == 130, "loadout follows: 압정, 포터 HP 130 (D7/D8)")
	# dashboard badge
	var t := ScrTitle.new()
	t.setup(m)
	host.add_child(t)
	await _frames(2)
	var badge: Control = t.find("Badge")
	var can: int = 0
	for it: Dictionary in m.shop_items():
		can += 1 if (not m.owns(str(it["id"])) and int(it.get("price", 0)) <= m.wallet()) else 0
	_check(badge.visible == (can > 0) and (badge.find_child("*", true, false) as Label).text == str(can), "garage badge = affordable unowned items (%d) (A9)" % can)
	host.queue_free()
	await _frames()


# ───────────────────────────── settings
func _settings() -> void:
	var host := Control.new()
	_tree.root.add_child(host)
	var path: String = DIR.path_join("settings.json")
	var m: ScrMeta = ScrMeta.private(host, path, {}, true)
	var s := ScrSettings.new()
	s.setup(m)
	host.add_child(s)
	await _frames(2)
	_check(bool(m.get_setting("music")) and not bool(m.get_setting("battery60")), "settings defaults music on, 60fps off (A20)")
	ScrKit.press(s.find("Row_battery60"))
	ScrKit.press(s.find("Row_haptics"))
	await _frames()
	var m2: ScrMeta = ScrMeta.private(host, path)
	_check(bool(m2.get_setting("battery60")) and not bool(m2.get_setting("haptics")), "toggles persist across a reload")
	var app := ScrApp.new()
	app.meta = m2
	var fps0: int = Engine.max_fps
	app.apply_settings()
	var h: Node = _tree.root.get_node_or_null(^"Haptics")
	_check(Engine.max_fps == 60 and (h == null or not bool(h.get(&"enabled"))), "apply_settings: max_fps 60, Haptics off")
	m2.set_setting("battery60", false)
	m2.set_setting("haptics", true)
	app.apply_settings()
	_check(Engine.max_fps == 0 and (h == null or bool(h.get(&"enabled"))), "apply_settings restores 0 fps cap / haptics on")
	Engine.max_fps = fps0
	app.free()
	host.queue_free()
	await _frames()


# ───────────────────────────── card timer
func _card_timer() -> void:
	var host := Control.new()
	_tree.root.add_child(host)
	var m: ScrMeta = ScrMeta.private(host, DIR.path_join("card.json"), {}, true)
	var c := ScrStageCard.new()
	c.stage_id = 1
	c.setup(m)
	var n: Array = [0]
	c.start_requested.connect(func(_id: int) -> void: n[0] += 1)
	host.add_child(c)
	await _frames()
	_check(is_equal_approx(c.duration, 4.4), "1-1 card timer 3.4 s + 1 s road = 4.4 s (A13)")
	c._process(4.3)
	_check(n[0] == 0, "no start before the timer")
	c._process(0.2)
	c._process(1.0)
	c.start()
	_check(n[0] == 1, "timer start fires once (then tap / app start are ignored)")
	host.queue_free()
	await _frames()


# ───────────────────────────── stub ↔ real Progress
## The fallback stub must give the screens the same numbers and keys as meta/progress.gd (whose own tests pin it
## to the web oracle), so a build without meta/ still shows correct rewards.
func _stub_parity() -> void:
	if not ResourceLoader.exists(ScrMeta.PROGRESS_SCRIPT):
		print("SKIP screens: meta/progress.gd not in the build, no stub parity check")
		return
	var host := Node.new()
	_tree.root.add_child(host)
	var real: ScrMeta = ScrMeta.private(host, DIR.path_join("parity_real.json"), {}, true)
	var stub_path: String = DIR.path_join("parity_stub.json")
	var sg: Node = (load(ScrMeta.SAVE_SCRIPT) as GDScript).new()
	sg.set(&"path", stub_path)
	sg.call(&"wipe")
	sg.free()
	var stub_node := ScrProgressStub.new(stub_path)
	host.add_child(stub_node)
	var stub: ScrMeta = ScrMeta.bind_to(stub_node)
	var keys: Array[String] = ["payout", "stars", "views", "subs_gained", "milestone", "wallet", "subs", "fine", "base", "bonus", "card", "case",
		"villain_name", "unlocks", "next_id", "is_last", "missions_done", "score", "new_best"]
	for run: Array in [[1, true, 82], [2, false, 45], [18, true, 70], [36, true, 90], [1, true, 30]]:
		var res: Dictionary = ScrFakeGame.make_result(int(run[0]), bool(run[1]), int(run[2]))
		var a: Dictionary = real.record_result(int(run[0]), res)
		var b: Dictionary = stub.record_result(int(run[0]), res)
		var diff: PackedStringArray = []
		for k: String in keys:
			if str(a.get(k)) != str(b.get(k)):
				diff.append("%s real=%s stub=%s" % [k, a.get(k), b.get(k)])
		if str(a.get("comments")) != str(b.get("comments")):
			diff.append("comments")
		if str(a.get("stats")) != str(b.get("stats")):
			diff.append("stats real=%s stub=%s" % [a.get("stats"), b.get("stats")])
		_check(diff.is_empty(), "stub record_result == Progress for stage %d %s %s" % [int(run[0]), run, "; ".join(diff)])
	stub_node.data["wallet"] = 2000000
	stub_node.save()
	var seed2: Dictionary = {"unlocked": 1, "wallet": 2000000}
	var real2: ScrMeta = ScrMeta.private(host, DIR.path_join("parity_real2.json"), seed2, true)
	for id: String in ["car_patrol", "mv_jump", "pas_4k", "pas_coffee", "fin_ufo", "wpn_water"]:
		real2.buy(id)
		stub.buy(id)
	_check(str(real2.loadout()) == str(stub.loadout()), "stub loadout() == Progress loadout() after buys (%s | %s)" % [real2.loadout(), stub.loadout()])
	_check(real2.wallet() == stub.wallet() and stub.daily_villain() >= 1, "stub wallet after buys == Progress; daily_villain → id")
	# r3 S1 run index: ScrMeta forwards plays / next_play / begin_play; the stub counts runs too, so a build without
	# meta/ still varies the seed per run (it has no SEED_SKIP list: next_play == plays there)
	var seq_real: Array = []
	var seq_stub: Array = []
	for i: int in 3:
		seq_real.append(real.begin_play(2))
		seq_stub.append(stub.begin_play(2))
	var stub_re: ScrMeta = ScrMeta.bind_to(ScrProgressStub.new(stub_path))
	host.add_child(stub_re.p as Node)
	_check(ScrMeta.new().has_method(&"begin_play") and seq_real == [0, 1, 2] and seq_stub == seq_real and real.plays(2) == 3
		and stub.plays(2) == 3 and stub.next_play(2) == 3 and stub_re.plays(2) == 3 and real.plays(7) == 0,
		"ScrMeta run index: begin_play real %s stub %s, plays %d/%d, stub reload %d" % [seq_real, seq_stub, real.plays(2),
		stub.plays(2), stub_re.plays(2)])
	host.queue_free()
	await _frames()
