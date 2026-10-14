class_name ScrApp
extends Node
## Future main scene (screens/app.tscn; final integration sets run/main_scene, NATIVE_PARITY 8-1):
##   TITLE (dashboard) → CARD (stage card) → GAME (GAME_SCENE child of GameHost; start_stage(id, loadout) emitted)
##   → stage_finished(result) → Progress.record_result → REWARD (timeline over the still-running scene)
##   → 다음 빌런 (next card) / 다시하기 (same card) / 메뉴 (dashboard).
## Overlays on the dashboard: garage, album, settings. In GAME: pause menu (game's pause_requested / paused_changed,
## the game pausing the tree itself, app backgrounded) → resume / retry / settings / quit (abort = no reward).
## G2 (NATIVE_PARITY 7): a game scene with `intro_hold` (+ `begin()`) is loaded behind the stage card with its intro
## held, like the web card over the live intro; the card's start calls begin(). Without it the game loads on start.
## The game gets `hosted = true` when it has that property (its own result / fail menu then emit stage_finished).
## Settings are applied here
## (Music/SFX bus mute, Haptics.enabled, Engine.max_fps) and passed to the game as loadout.left_hand.
## Progress: /root/Progress when registered, else ScrProgressStub (screens/meta.gd).
## CLI (after --): --game=fake|real  --stage=N (open that card)  --safe-pt=TOP,BOTTOM  --fake-auto=S

signal start_stage(id: int, loadout: Dictionary)
signal state_changed(state: int)

enum State { TITLE, CARD, GAME, PAUSED, REWARD }

const FAKE_GAME: String = "res://screens/dev_fake_game.tscn"
const REAL_GAME: String = "res://view/game.tscn"
## The one line final integration flips (NATIVE_PARITY 8-2).
const GAME_SCENE: String = REAL_GAME
const THEME_PATH: String = "res://ui/theme/lane1_theme.tres"

var game_scene_path: String = GAME_SCENE
## Non-empty = run on a private, wiped save file (tests / shots) instead of the Progress autoload.
var private_save: String = ""
var debug_safe_pt := Vector2.ZERO
var fake_auto_s: float = -1.0
var meta: ScrMeta
var state: State = State.TITLE
var stage_id: int = 1
var game: Node
var title: ScrTitle
var card: ScrStageCard
var reward_screen: ScrReward
var pause_menu: ScrPause
var overlay: ScrScreen
var ui: Control
var layer: CanvasLayer
var game_host: Node
var backdrop: ScrBackdrop
var last_result: Dictionary = {}
var last_reward: Dictionary = {}
var history: Array[String] = []
var _wallet_seen: int = -1
var _boot_stage: int = -1
## G2: preload the game behind the card when the scene supports intro_hold.
var hold_under_card: bool = true
var _held: bool = false
var _pause_settings: ScrSettings


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--game="):
			game_scene_path = REAL_GAME if a.ends_with("real") else FAKE_GAME
		elif a.begins_with("--stage="):
			_boot_stage = a.trim_prefix("--stage=").to_int()
		elif a.begins_with("--safe-pt="):
			var q: PackedStringArray = a.trim_prefix("--safe-pt=").split(",")
			debug_safe_pt = Vector2(q[0].to_float(), q[1].to_float() if q.size() > 1 else 0.0)
		elif a.begins_with("--fake-auto="):
			fake_auto_s = a.trim_prefix("--fake-auto=").to_float()
	game_host = Node.new()
	game_host.name = "GameHost"
	game_host.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(game_host)
	layer = CanvasLayer.new()
	layer.name = "Menus"
	layer.layer = 20
	add_child(layer)
	ui = Control.new()
	ui.name = "UI"
	ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if ResourceLoader.exists(THEME_PATH):
		ui.theme = load(THEME_PATH) as Theme
	layer.add_child(ui)
	backdrop = ScrBackdrop.new()
	ui.add_child(backdrop)
	meta = ScrMeta.private(self, private_save, {}, true) if not private_save.is_empty() else ScrMeta.resolve(self)
	apply_settings()
	if _boot_stage > 0 and meta.is_unlocked(_boot_stage):
		show_card(_boot_stage)
	else:
		show_title()
	_music(&"menu")


func _set_state(s: State) -> void:
	state = s
	history.append(State.keys()[s])
	state_changed.emit(s)


func _screen(s: ScrScreen) -> ScrScreen:
	s.debug_safe_pt = debug_safe_pt
	s.setup(meta)
	ui.add_child(s)
	return s


func _free(s: Node) -> void:
	if s != null and is_instance_valid(s):
		if s.get_parent() != null:
			s.get_parent().remove_child(s)
		s.queue_free()


# ───────────────────────────── dashboard
func show_title() -> void:
	_close_overlay()
	_free(card)
	card = null
	_free(title)
	backdrop.visible = game == null
	title = ScrTitle.new()
	title.name = "Title"
	title._shown_wallet = _wallet_seen
	_screen(title)
	_wallet_seen = meta.wallet()
	title.stage_picked.connect(pick_stage)
	title.album_requested.connect(func() -> void: open_overlay(ScrAlbum.new()))
	title.garage_requested.connect(func() -> void: open_overlay(ScrGarage.new()))
	title.settings_requested.connect(open_settings)
	_set_state(State.TITLE)


func open_overlay(s: ScrScreen) -> ScrScreen:
	_close_overlay()
	overlay = _screen(s)
	overlay.closed.connect(func() -> void:
		overlay = null
		if title != null and is_instance_valid(title):
			title.refresh()
			_wallet_seen = meta.wallet())
	return overlay


func open_settings() -> ScrSettings:
	var s := ScrSettings.new()
	s.name = "Settings"
	s.setting_changed.connect(func(_k: String, _v: bool) -> void: apply_settings())
	if state == State.PAUSED:
		_free(_pause_settings)
		_pause_settings = s
		_screen(s)
		s.closed.connect(func() -> void: _pause_settings = null)
		return s
	return open_overlay(s) as ScrSettings


func _close_overlay() -> void:
	if overlay != null and is_instance_valid(overlay):
		_free(overlay)
	overlay = null


# ───────────────────────────── card → game
func pick_stage(id: int) -> void:
	if not meta.is_unlocked(id) or overlay != null:
		return
	show_card(id)


func show_card(id: int) -> void:
	_close_overlay()
	_free(title)
	title = null
	_free(card)
	stage_id = id
	_free_game()
	_hold_game(id)
	backdrop.visible = game == null
	card = ScrStageCard.new()
	card.name = "StageCard"
	card.stage_id = id
	_screen(card)
	card.start_requested.connect(_start_game)
	card.closed.connect(func() -> void:
		card = null
		_free_game()
		show_title())
	_set_state(State.CARD)


func start_from_card() -> void:
	if card != null and is_instance_valid(card):
		card.start()


func _start_game(id: int) -> void:
	_free(card)
	card = null
	stage_id = id
	var lo: Dictionary = _loadout()
	start_stage.emit(id, lo)
	if game != null and _held and int(game.get(&"stage_id")) == id:
		_held = false
		game.set(&"intro_hold", false)
		if game.has_method(&"begin"):
			game.call(&"begin")
	else:
		_free_game()
		_attach(_instance_game(id, lo))
	backdrop.visible = false
	_set_state(State.GAME)


func _loadout() -> Dictionary:
	var lo: Dictionary = meta.loadout()
	lo["left_hand"] = bool(meta.get_setting("left_hand"))
	return lo


## GAME_SCENE instance with stage_id / loadout / hosted set before _ready (build), not yet in the tree.
func _instance_game(id: int, lo: Dictionary) -> Node:
	if not ResourceLoader.exists(game_scene_path):
		game_scene_path = REAL_GAME
	var ps: PackedScene = load(game_scene_path) as PackedScene
	var g: Node = ps.instantiate()
	g.name = "Game"
	for kv: Array in [[&"stage_id", id], [&"loadout", lo], [&"hosted", true]]:
		if kv[0] in g:
			g.set(kv[0], kv[1])
	if &"auto_s" in g:   # dev fake game only (no class reference: screens/dev_fake_game.* may be left out of the export)
		g.set(&"auto_s", fake_auto_s)
	return g


func _attach(g: Node) -> void:
	game = g
	if g.has_signal(&"stage_finished"):
		g.connect(&"stage_finished", _on_stage_finished)
	if g.has_signal(&"pause_requested"):
		g.connect(&"pause_requested", show_pause)
	if g.has_signal(&"paused_changed"):
		g.connect(&"paused_changed", func(on: bool) -> void:
			if on:
				show_pause()
			elif state == State.PAUSED:
				hide_pause())
	backdrop.visible = false
	game_host.add_child(g)


## G2: load the game behind the card with its intro held (only when the scene has `intro_hold`).
func _hold_game(id: int) -> void:
	_held = false
	if not hold_under_card:
		return
	var g: Node = _instance_game(id, _loadout())
	if not (&"intro_hold" in g):
		g.free()
		return
	g.set(&"intro_hold", true)
	_attach(g)
	_held = true


func _free_game() -> void:
	if game != null and is_instance_valid(game):
		_free(game)
	game = null
	_held = false


## The contract result from what the game sent. GameSim's state().result has no `cleared` (it only exists in phase
## result), so a result without `cleared` counts as cleared when it carries the sim's missions / stars and is not
## aborted (same rule as Progress.record_result).
static func contract_result(result: Dictionary, id: int) -> Dictionary:
	var r: Dictionary = result.duplicate()
	var aborted: bool = bool(r.get("aborted", false))
	if not r.has("cleared"):
		r["cleared"] = not aborted and (r.has("missions") or r.has("stars"))
	r["aborted"] = aborted
	if not r.has("stage_id"):
		r["stage_id"] = id
	return r


func _on_stage_finished(result: Dictionary) -> void:
	if state != State.GAME and state != State.PAUSED:
		return
	get_tree().paused = false
	_free(pause_menu)
	pause_menu = null
	_free(_pause_settings)
	_pause_settings = null
	result = contract_result(result, stage_id)
	last_result = result
	if bool(result.get("aborted", false)) or not bool(result.get("cleared", false)):
		last_reward = {}
		_end_game()
		show_title()
		_music(&"menu")
		return
	last_reward = meta.record_result(stage_id, result)
	show_reward()


func show_reward() -> void:
	_free(reward_screen)
	reward_screen = ScrReward.new()
	reward_screen.name = "Reward"
	reward_screen.stage_id = stage_id
	reward_screen.result = last_result
	reward_screen.reward = last_reward
	_screen(reward_screen)
	reward_screen.next_requested.connect(reward_next)
	reward_screen.retry_requested.connect(reward_retry)
	reward_screen.menu_requested.connect(reward_menu)
	_set_state(State.REWARD)


func reward_next(id: int = -1) -> void:
	_end_game()
	show_card(id if id > 0 else reward_screen_next())


func reward_screen_next() -> int:
	var stages: Array = meta.stages()
	for i: int in stages.size():
		if int((stages[i] as Dictionary)["id"]) == stage_id:
			return int((stages[mini(i + 1, stages.size() - 1)] as Dictionary)["id"])
	return stage_id


func reward_retry(id: int = -1) -> void:
	_end_game()
	show_card(id if id > 0 else stage_id)


func reward_menu() -> void:
	_end_game()
	show_title()
	_music(&"menu")


func _end_game() -> void:
	_free(reward_screen)
	reward_screen = null
	_free(pause_menu)
	pause_menu = null
	_free(_pause_settings)
	_pause_settings = null
	get_tree().paused = false
	_free_game()
	backdrop.visible = true


# ───────────────────────────── pause
func show_pause() -> void:
	if state != State.GAME or pause_menu != null:
		return
	get_tree().paused = true
	pause_menu = ScrPause.new()
	pause_menu.name = "Pause"
	_screen(pause_menu)
	pause_menu.resume_requested.connect(hide_pause)
	pause_menu.retry_requested.connect(func() -> void:
		_end_game()
		_start_game(stage_id))
	pause_menu.settings_requested.connect(open_settings)
	pause_menu.quit_requested.connect(func() -> void:
		_end_game()
		show_title()
		_music(&"menu"))
	_set_state(State.PAUSED)
	if game != null and game.has_method(&"set_paused"):
		game.call(&"set_paused", true)   # HUD pause state + released touches (view/game.gd)


func hide_pause() -> void:
	_free(pause_menu)
	pause_menu = null
	_free(_pause_settings)
	_pause_settings = null
	get_tree().paused = false
	_set_state(State.GAME)
	if game != null and game.has_method(&"set_paused"):
		game.call(&"set_paused", false)


## Pause sync for a game that pauses the tree itself (view/game.gd: HUD pause button / backgrounded → set_paused,
## no signal yet): tree paused in GAME → pause menu; the game resuming itself while the menu is up → close it.
func _process(_delta: float) -> void:
	var tp: bool = get_tree().paused
	if state == State.GAME and tp and game != null and pause_menu == null:
		show_pause()
	elif state == State.PAUSED and not tp and pause_menu != null:
		hide_pause()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED and state == State.GAME:
		show_pause()


func _unhandled_input(ev: InputEvent) -> void:
	if not ev.is_action_pressed(&"ui_cancel"):
		return
	if overlay != null:
		overlay.close()
	elif state == State.PAUSED:
		hide_pause()
	elif state == State.GAME:
		show_pause()
	elif state == State.CARD and card != null:
		card.close()


# ───────────────────────────── settings · audio
## Music → Music bus, 효과음 → SFX/SFX_L/SFX_R/Amb, 진동 → Haptics.enabled, 60fps → Engine.max_fps.
func apply_settings() -> void:
	var music: bool = bool(meta.get_setting("music"))
	var sfx: bool = bool(meta.get_setting("sfx"))
	_bus_mute(&"Music", not music)
	for b: StringName in [&"SFX", &"SFX_L", &"SFX_R", &"Amb"]:
		_bus_mute(b, not sfx)
	var tree := Engine.get_main_loop() as SceneTree
	var h: Node = tree.root.get_node_or_null(^"Haptics") if tree != null else null
	if h != null and &"enabled" in h:
		h.set(&"enabled", bool(meta.get_setting("haptics")))
	Engine.max_fps = 60 if bool(meta.get_setting("battery60")) else 0


static func _bus_mute(bus: StringName, on: bool) -> void:
	var i: int = AudioServer.get_bus_index(bus)
	if i >= 0:
		AudioServer.set_bus_mute(i, on)


func _music(name: StringName) -> void:
	var a: Node = get_tree().root.get_node_or_null(^"Audio") if is_inside_tree() else null
	if a != null and a.has_method(&"music"):
		a.call(&"music", name)
