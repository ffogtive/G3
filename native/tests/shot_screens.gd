extends SceneTree
## Meta screen screenshots (NATIVE_PARITY 8-9: 390×844 Xvfb shots of title · card · garage · album · result next to
## the web Playwright shots).
##   xvfb-run -a -s "-screen 0 1280x1024x24" godot47 --path native --rendering-method mobile --audio-driver Dummy \
##       -s res://tests/shot_screens.gd -- --out=/abs/dir [--screens=title,card,garage,album,reward,pause,settings,fresh,flow]
##       (card_<id> / reward_<id> pick another stage, e.g. card_36 rescue, reward_18 crime; reward_1_end = scrolled to the end)
##       [--size=585x1266] [--safe-pt=59,34] [--web=/abs/web_dir]
## Each screen is built on a ScrProgressStub seeded like the web shot (unlocked 4, ★ 3/2/1, ₩250,000, 1.2만 구독자,
## 마름쇠 owned) in a SubViewport of the phone-equivalent size (1170×2532 / 2, canvas 540 wide) and saved as
## <out>/native_<screen>.png; with --web, <out>/sbs_<screen>.png puts web_<screen>.png on the left.
## "flow" drives ScrApp: title → card → fake game → reward timeline (shots at 0.5 / 1.3 / 2.3 / 5.0 s) → dashboard.

const SEED_PROGRESS: Dictionary = {"ver": 3, "unlocked": 4, "stars": {"1": 3, "2": 2, "3": 1}, "best": {"1": 18450, "2": 12000, "3": 9000},
	"wallet": 250000, "subs": 12340, "album": {"1": {"stars": 3, "fine": 40000, "photo": null, "at": 1, "count": 2},
	"2": {"stars": 2, "fine": 40000, "photo": null, "at": 1, "count": 1}, "3": {"stars": 1, "fine": 40000, "photo": null, "at": 1, "count": 1}},
	"owned": ["wpn_caltrop"], "equip": {"car": "car_hatch", "weapon": "wpn_caltrop", "finish": "fin_rocket"}}

var _out: String = ""
var _web: String = ""
var _size := Vector2i(585, 1266)
var _safe := Vector2(59, 34)
var _which: PackedStringArray = ["title", "card", "garage", "album", "reward", "pause", "settings", "fresh", "flow"]
var _vp: SubViewport
var _ui: Control


func _initialize() -> void:
	for a: String in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.trim_prefix("--").split("=", true, 1)
		var v: String = kv[1] if kv.size() > 1 else ""
		match kv[0]:
			"out":
				_out = v
			"web":
				_web = v
			"screens":
				_which = v.split(",")
			"size":
				var p: PackedStringArray = v.split("x")
				_size = Vector2i(p[0].to_int(), p[1].to_int())
			"safe-pt":
				var q: PackedStringArray = v.split(",")
				_safe = Vector2(q[0].to_float(), q[1].to_float())
	_main.call_deferred()


func _main() -> void:
	if _out.is_empty() or DisplayServer.get_name() == "headless":
		print("FAIL shot_screens: need --out=<dir> and a real display (xvfb-run, no --headless)")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	ScrKit.feedback_enabled = false
	_vp = SubViewport.new()
	_vp.size = _size
	_vp.size_2d_override = Vector2i(540, roundi(540.0 * float(_size.y) / float(_size.x)))
	_vp.size_2d_override_stretch = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.transparent_bg = false
	root.add_child(_vp)
	var fails: int = 0
	for w: String in _which:
		fails += await _shoot(w)
	print("RESULT shots=%d fails=%d out=%s" % [_which.size(), fails, _out])
	quit(1 if fails > 0 else 0)




func _host() -> Control:
	for c: Node in _vp.get_children():
		c.queue_free()
	await process_frame
	_ui = Control.new()
	_ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ui.theme = load("res://ui/theme/lane1_theme.tres") as Theme
	_vp.add_child(_ui)
	var bd := ScrBackdrop.new()
	bd.animate = false
	_ui.add_child(bd)
	return _ui


func _shoot(which: String) -> int:
	if which == "flow":
		return await _flow()
	var host: Control = await _host()
	var m: ScrMeta = ScrMeta.private(host, "user://shot_meta/progress.json", SEED_PROGRESS if which != "fresh" else {}, true)
	var scr: ScrScreen = null
	var parts: PackedStringArray = which.split("_")   # e.g. card_36, reward_18
	var sid: int = parts[1].to_int() if parts.size() > 1 else 1
	match parts[0]:
		"title", "fresh":
			scr = ScrTitle.new()
		"card":
			var c := ScrStageCard.new()
			c.stage_id = sid
			c.auto_start = false
			scr = c
		"garage":
			scr = ScrGarage.new()
		"album":
			scr = ScrAlbum.new()
		"reward":
			var rw := ScrReward.new()
			rw.stage_id = sid
			rw.result = ScrFakeGame.make_result(sid, true, 82)
			rw.reward = m.record_result(sid, rw.result)
			rw.clock = {"year": 2026, "month": 10, "day": 14, "hour": 8, "minute": 52, "second": 7}
			rw.manual = true
			scr = rw
		"pause":
			scr = ScrPause.new()
		"settings":
			scr = ScrSettings.new()
		_:
			print("FAIL shot_screens: unknown screen %s" % which)
			return 1
	scr.debug_safe_pt = _safe
	scr.setup(m)
	host.add_child(scr)
	await _frames(4)
	if scr is ScrReward:
		(scr as ScrReward).advance(6.0)
		await _frames(30)
		if parts.size() > 2 and parts[2] == "end":
			var sc: ScrollContainer = scr.find("Scroll") as ScrollContainer
			sc.scroll_vertical = int(sc.get_v_scroll_bar().max_value)
			await _frames(4)
	return await _save(which)


func _flow() -> int:
	var host: Control = await _host()
	var app := ScrApp.new()
	app.private_save = "user://shot_meta/flow_progress.json"
	app.debug_safe_pt = _safe
	app.fake_auto_s = 0.4
	host.add_child(app)
	await _frames(4)
	var fails: int = await _save("flow_0_title")
	app.pick_stage(1)
	await _frames(4)
	fails += await _save("flow_1_card")
	app.start_from_card()
	await _frames(10)
	fails += await _save("flow_2_game")
	var t0: int = Time.get_ticks_msec()
	while app.state != ScrApp.State.REWARD and Time.get_ticks_msec() - t0 < 5000:
		await process_frame
	var rw: ScrReward = app.reward_screen
	if rw == null:
		print("FAIL shot_screens: flow did not reach the reward timeline")
		return fails + 1
	rw.manual = true
	for at: float in [0.5, 1.3, 2.3, 5.0]:
		rw.advance(at - rw.t)
		await _frames(3)
		fails += await _save("flow_3_reward_%d" % roundi(at * 1000.0))
	app.reward_menu()
	await _frames(6)
	fails += await _save("flow_4_title_after")
	return fails


func _frames(n: int) -> void:
	for i: int in n:
		await process_frame
	await RenderingServer.frame_post_draw


func _save(name: String) -> int:
	await RenderingServer.frame_post_draw
	var img: Image = _vp.get_texture().get_image()
	var p: String = _out.path_join("native_%s.png" % name)
	img.save_png(p)
	print("RESULT shot=%s size=%s" % [p, img.get_size()])
	if not _web.is_empty():
		var wp: String = _web.path_join("web_%s.png" % name)
		if FileAccess.file_exists(wp):
			_sbs(Image.load_from_file(wp), img).save_png(_out.path_join("sbs_%s.png" % name))
	return 0 if not img.is_empty() else 1


func _sbs(web: Image, nat: Image) -> Image:
	var h: int = nat.get_height()
	var w2: Image = web.duplicate()
	w2.convert(Image.FORMAT_RGBA8)
	w2.resize(roundi(float(w2.get_width()) * float(h) / float(w2.get_height())), h, Image.INTERPOLATE_BILINEAR)
	var n2: Image = nat.duplicate()
	n2.convert(Image.FORMAT_RGBA8)
	var out := Image.create(w2.get_width() + 12 + n2.get_width(), h, false, Image.FORMAT_RGBA8)
	out.fill(Color(0.1, 0.1, 0.12))
	out.blit_rect(w2, Rect2i(Vector2i.ZERO, w2.get_size()), Vector2i.ZERO)
	out.blit_rect(n2, Rect2i(Vector2i.ZERO, n2.get_size()), Vector2i(w2.get_width() + 12, 0))
	return out
