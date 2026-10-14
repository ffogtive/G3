extends SceneTree
## Deterministic M1a jam screenshot (NATIVE_PORT 4-2 T2, M1a 합격 "jam 샷 · draw ≤ 250 / ≤ 400 · 웹 동일 카메라 ΔE").
##   xvfb-run -a -s "-screen 0 1280x1024x24" godot47 --path native --rendering-method mobile --audio-driver Dummy \
##       -s res://tests/shot_jam.gd -- --out=/abs/dir [--ff-to=6] [--size=585x1266] [--seed=1007]
##       [--state=/abs/web_state.json] [--web=/abs/web_jam.png] [--web-ui=/abs/web_jam_ui.png]
##       [--ambient=sky|hemi|flat] [--tonemap=linear|agx|filmic] [--no-shadows] [--no-glow] [--ao=0..1] [--tag=name]
##       [--stub] [--honk-at=seconds] [--demo-signals] [--player-s=m] [--debug-panel] [--shadow-q=0..5 --shadow-blur= --bias= --nbias= --glow-int= --glow-levels=a,b,..]
##       [--wave-strip=/abs.png [--wave-lane=2 --wave-ahead=50 --wave-strength=2.5 --wave-frames=5 --wave-dt=1.0]]
##       [--neck-shots [--fallback] [--neck-extra=2,9]]
## r3 U3 --neck-shots: the bottleneck plug forced on (GameSim options.neck), autopilot "naive" (it never plays the verb):
##   neck_1-1 / neck_1-3 / neck_1-10.png = the bottleneck frame (plug + verb chip + a plug bubble), then one frame mid-exit
##   each: exit_cutin (1-1 verb), exit_zip (1-3 verb), exit_tow (1-10 verb), exit_fly (1-1 rage). RESULT lines carry the
##   plug pose vs the sim (view s error), whether it is on screen, the chip text and the bubbles; exit 1 when a frame is
##   missing its plug / chip / bubble, the plug is off screen or the view s is > 0.1 m off.
## Renders game.tscn (manual ticks: --ff-to seconds of 120 Hz sim, camera smoothed with the same fixed dt) into a
## SubViewport of the phone-equivalent size (1170×2532 / 2), saves
##   <out>/native_jam<tag>.png (3D only), <out>/native_jam_ui<tag>.png (HUD + N5 icons),
##   <out>/sbs_jam<tag>.png (web | native, when --web is given) and prints RESULT lines:
##   draws with / without the shadow pass, primitives, frame ms (lavapipe wall time), lum sd, icon overlaps, ΔE76.
## With --state the cars, player, villain, opposite traffic and camera are set from the web frame dumped by
## native/view/dev/web_shot.mjs, so the side-by-side compares the look at the same moment from the same camera.
## Exit 0 ok · 1 blank image / draw budget exceeded / icon overlap · 2 cannot render.

const GameScene: PackedScene = preload("res://view/game.tscn")
const VIS_BUDGET: int = 250
const ALL_BUDGET: int = 400

var _out: String = ""
var _ff: float = 6.0
var _size := Vector2i(585, 1266)
var _seed: int = 1007
var _state_path: String = ""
var _web: String = ""
var _web_ui: String = ""
var _tag: String = ""
var _opts: Dictionary = {}
var _vp: SubViewport
var _game: Game
var _lens: Dictionary = {}


func _initialize() -> void:
	for a: String in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.trim_prefix("--").split("=", true, 1)
		var k: String = kv[0]
		var v: String = kv[1] if kv.size() > 1 else "1"
		match k:
			"out":
				_out = v
			"ff-to":
				_ff = v.to_float()
			"size":
				var p: PackedStringArray = v.split("x")
				_size = Vector2i(p[0].to_int(), p[1].to_int())
			"seed":
				_seed = v.to_int()
			"state":
				_state_path = v
			"web":
				_web = v
			"web-ui":
				_web_ui = v
			"tag":
				_tag = "_" + v
			_:
				_opts[k] = v
	_main.call_deferred()


func _main() -> void:
	if _out.is_empty() or DisplayServer.get_name() == "headless":
		print("FAIL shot_jam: need --out=<dir> and a real display (xvfb-run, no --headless)")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	_vp = SubViewport.new()
	_vp.size = _size
	_vp.size_2d_override = Vector2i(540, roundi(540.0 * float(_size.y) / float(_size.x)))
	_vp.size_2d_override_stretch = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.msaa_3d = Viewport.MSAA_4X
	_vp.use_debanding = true
	_vp.audio_listener_enable_3d = false
	root.add_child(_vp)
	if _opts.has("neck-shots"):
		quit(await _neck_shots())
		return
	_game = GameScene.instantiate() as Game
	_game.manual = true
	_game.seed = _seed
	_game.with_debug_panel = false
	if not _state_path.is_empty() or _opts.has("stub"):
		# M1b: game.tscn always runs GameSim (TrafficBridge); the view TrafficStub replay is gone, --state pins the camera
		print("INFO shot_jam: --stub / --state car pinning needs the M1a TrafficStub path (removed in M1b); camera only")
	var t_build: int = Time.get_ticks_msec()
	_vp.add_child(_game)
	var build_ms: int = Time.get_ticks_msec() - t_build
	_apply_opts()
	var t_sim: int = Time.get_ticks_usec()
	var n_ticks: int = roundi(_ff * 120.0)
	if _state_path.is_empty():
		var honk_tick: int = roundi(float(_opts.get("honk-at", "-1")) * 120.0)
		if honk_tick > 0 and honk_tick < n_ticks:
			_game.advance_ticks(honk_tick)
			_game.input.inject("horn:down")
			_game.advance_ticks(1)
			_game.input.inject("horn:up")
			_game.advance_ticks(n_ticks - honk_tick - 1)
		elif _opts.has("demo-signals") and _game.traffic is TrafficStub:
			_game.advance_ticks(maxi(0, n_ticks - 50))
			(_game.traffic as TrafficStub).demo_signals(_game.player.s, _game.player.lane)
			_game.advance_ticks(mini(50, n_ticks))
		else:
			_game.advance_ticks(n_ticks)
	else:
		_game.advance_ticks(n_ticks)  # warm the sim to the same time, then pin every car to the web frame
		_apply_web_state(_state_path)
	if _opts.has("player-s"):  # look-dev: teleport the player (and camera) to view e.g. the shoulder obstacles
		_game.player.s = float(_opts["player-s"])
		_game.player.x = RoadGraph.lane_x(float(_game.player.lane))
		_game.player_view.transform = _game.road.world(_game.player.s, _game.player.x)
		_game.render_step(0.0)
		_game.camera.snap()
	if _opts.has("debug-panel"):
		var dp := DebugPanel.new()
		dp.world = _game.world
		dp.factory = _game.factory
		dp.icons = _game.icons
		_game.add_child(dp)
		dp._panel.visible = true
	var sim_us: int = Time.get_ticks_usec() - t_sim
	print("RESULT build_ms=%d sim_ticks=%d sim_ms_per_tick=%.3f traffic=%s world=%s" % [build_ms, n_ticks,
		float(sim_us) / 1000.0 / maxf(1.0, float(n_ticks)), _traffic_source(), JSON.stringify(_game.world.stats)])
	if _opts.has("wave-strip"):
		quit(await _wave_strip(str(_opts["wave-strip"])))
		return

	# 3D-only frame (HUD + icons hidden) for ΔE vs the web canvas
	_set_overlay(false)
	await _frames(6)
	var img3d: Image = _vp.get_texture().get_image()
	var draws_all: int = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var prims: int = int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	var objects: int = int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	img3d.save_png(_out.path_join("native_jam%s.png" % _tag))
	# frame time under lavapipe (wall clock, CPU rasteriser: not a device number)
	var t0: int = Time.get_ticks_usec()
	await _frames(10)
	var frame_ms: float = float(Time.get_ticks_usec() - t0) / 10000.0
	# visible-only draws: same frame without the shadow pass
	var had_shadow: bool = _game.world.sun.shadow_enabled
	_game.world.sun.shadow_enabled = false
	await _frames(3)
	var draws_vis: int = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	_game.world.sun.shadow_enabled = had_shadow
	# full frame with HUD + N5 icons
	_set_overlay(true)
	_game.render_step(0.0)
	await _frames(4)
	var img_ui: Image = _vp.get_texture().get_image()
	img_ui.save_png(_out.path_join("native_jam_ui%s.png" % _tag))
	var shown: Array[Dictionary] = _game.icons.shown()
	var overlaps: int = _game.icons.last_overlaps()
	var icon_desc: PackedStringArray = []
	for c: Dictionary in shown:
		icon_desc.append("%s@%d" % [SignalIcons.Icon.keys()[int(c["icon"])] if int(c["icon"]) >= 0 else "HAZARD", int(c["id"])])

	var st: Vector2 = _lum_mean_sd(img3d)
	var ok: bool = st.y > 0.05
	print("RESULT draws_total=%d draws_visible=%d (budget %d / %d) prims=%d objects=%d frame_ms_lavapipe=%.1f lum_mean=%.3f lum_sd=%.3f" % [
		draws_all, draws_vis, VIS_BUDGET, ALL_BUDGET, prims, objects, frame_ms, st.x, st.y])
	print("RESULT icons=%d overlaps=%d [%s] npc_groups=%d cars_drawn=%d" % [shown.size(), overlaps, ", ".join(icon_desc),
		_game.npc.group_count(), _game.npc.car_count()])
	print("RESULT honk_reply=%s bubbles=%d [%s] honk_rings=%d" % [JSON.stringify(_game.last_honk_reply), _game.bubbles.count(),
		", ".join(_game.bubbles.texts()), _game.honk_fx.active()])
	var hud_rects: Array[Rect2] = _game.hud.reserved_rects()
	print("RESULT hud_safe insets=%s safe_rect=%s bar=%s (--safe-pt=TOP,BOTTOM fakes a notch / home indicator)" % [
		_game.hud.insets, _game.hud.safe_rect(), hud_rects[0] if not hud_rects.is_empty() else Rect2()])
	if draws_vis > VIS_BUDGET or draws_all > ALL_BUDGET:
		print("FAIL shot_jam: draw budget exceeded")
		ok = false
	if overlaps > 0:
		print("FAIL shot_jam: N5 icons overlap")
		ok = false
	if not _web.is_empty() and FileAccess.file_exists(_web):
		var web := Image.load_from_file(_web)
		print("RESULT deltaE76_mean=%.2f (web canvas vs native 3D, same camera%s)" % [_delta_e(web, img3d),
			"" if not _state_path.is_empty() else " NOT pinned: no --state"])
		var web_ui: Image = Image.load_from_file(_web_ui) if not _web_ui.is_empty() and FileAccess.file_exists(_web_ui) else web
		_side_by_side(web_ui, img_ui).save_png(_out.path_join("sbs_jam%s.png" % _tag))
		_side_by_side(web, img3d).save_png(_out.path_join("sbs_jam3d%s.png" % _tag))
	print("RESULT ok=%s" % ok)
	quit(0 if ok else 1)


# ───────────────────────────── r3 U3 bottleneck plug shots

func _neck_game(stage: int) -> Game:
	var g: Game = GameScene.instantiate() as Game
	g.manual = true
	g.with_debug_panel = false
	g.autoplay = true
	g.stage_id = stage
	g.traffic_mode = "fallback" if _opts.has("fallback") else "auto"
	g.sim_options = {"neck": true}
	_vp.add_child(g)
	if _opts.has("safe-pt"):
		var sp: PackedStringArray = str(_opts["safe-pt"]).split(",")
		g.hud.debug_safe_pt = Vector2(sp[0].to_float(), sp[1].to_float() if sp.size() > 1 else 0.0)
		g.hud.apply_safe_area()
	g.sim.autopilot.neck_mode = "naive"
	return g


## Runs g until the bottleneck is active and its verb chip is up; false when it never comes.
func _to_neck(g: Game) -> bool:
	var ticks: int = 0
	while ticks < 120 * 70 and not g.sim.neck.is_active(g.sim):
		g.advance_ticks(12)
		ticks += 12
	if not g.sim.neck.is_active(g.sim):
		return false
	while ticks < 120 * 80 and str(g.st["neck"].get("chip", "")) == "" and g.sim.neck.is_active(g.sim):
		g.advance_ticks(6)
		ticks += 6
	g.advance_ticks(24)  # the chip has faded in
	return g.sim.neck.is_active(g.sim)


func _neck_frame(g: Game, file: String, need_chip: bool) -> bool:
	for i: int in 3:
		g.render_step(0.0)
		await process_frame
	await RenderingServer.frame_post_draw
	var img: Image = _vp.get_texture().get_image()
	img.save_png(_out.path_join(file))
	var n: Dictionary = g.st.get("neck", {})
	var on: bool = g.neck_view != null and g.neck_view.visible
	var sp := Vector2(-1, -1)
	var vis: bool = false
	if on:
		var wp: Vector3 = g.neck_view.global_position + Vector3(0, 0.8, 0)
		if not g.camera.is_position_behind(wp):
			sp = g.camera.unproject_position(wp)
			vis = Rect2(Vector2.ZERO, g.hud.root.size).grow(-4.0).has_point(sp)
	var err: float = absf(float(g.neck_pose.get("s", INF)) - float(n.get("s", NAN))) if on else INF
	var chip: String = g.hud.neck_chip_text()
	var bub: PackedStringArray = g.bubbles.texts()
	var plug_b: bool = g.bubbles._items.has("h-1000")
	var ok: bool = on and vis and err <= 0.1 and (not need_chip or (chip != "" and g.hud._neck_chip.visible and plug_b))
	print("RESULT neck_shot %s stage 1-%d phase=%s neck_phase=%s exit=%s t=%.2f plug=%s on_screen=%s at %s view_s_err=%.4f role=%s car=%s lamps=%d y=%.2f yaw=%.2f roll=%.2f scale=%.2f chip='%s' bubbles=[%s] plug_bubble=%s ok=%s" % [
		file, g.stage_id, g.phase, n.get("phase", ""), n.get("exit", ""), float(g.neck_pose.get("t", 0.0)), on, vis, sp, err,
		g.neck_pose.get("role", ""), g.neck_pose.get("car", ""), int(g.neck_pose.get("lamps", 0)), float(g.neck_pose.get("y", 0.0)),
		float(g.neck_pose.get("yaw", 0.0)), float(g.neck_pose.get("roll", 0.0)), float(g.neck_pose.get("scale", 1.0)), chip,
		", ".join(bub), plug_b, ok])
	return ok


func _neck_shots() -> int:
	var bad: int = 0
	var exits: Dictionary = {1: "cutin", 3: "zip", 10: "tow"}
	for stage: int in [1, 3, 10]:
		var g: Game = _neck_game(stage)
		if not await _to_neck(g):
			print("FAIL shot_jam: 1-%d bottleneck never active (phase %s)" % [stage, g.phase])
			bad += 1
			g.queue_free()
			await process_frame
			continue
		g.sim.neck.say(g.sim, "block", "taunt", 2.0)  # a plug line on screen with the chip (naive never honks it open)
		g.advance_ticks(12)
		if not await _neck_frame(g, "neck_1-%d.png" % stage, true):
			bad += 1
		# its own exit, one frame mid-way
		g.sim.neck.pc["exit"] = str(exits[stage])
		g.sim.neck.open(g.sim, "verb")
		g.advance_ticks(roundi(120.0 * 1.2 * 0.62))
		if not await _neck_frame(g, "exit_%s.png" % exits[stage], false):
			bad += 1
		g.queue_free()
		await process_frame
	# r3 final: --neck-extra=2,9 adds the bottleneck frame of more stages (1-2 / 1-9 straddle plugs since the final round)
	for xs: String in str(_opts.get("neck-extra", "")).split(",", false):
		var gx: Game = _neck_game(xs.to_int())
		if await _to_neck(gx):
			gx.sim.neck.say(gx.sim, "block", "taunt", 2.0)
			gx.advance_ticks(12)
			if not await _neck_frame(gx, "neck_1-%d.png" % xs.to_int(), true):
				bad += 1
		else:
			print("FAIL shot_jam: 1-%s bottleneck never active" % xs)
			bad += 1
		gx.queue_free()
		await process_frame
	var gf: Game = _neck_game(1)
	if await _to_neck(gf):
		gf.sim.neck.open(gf.sim, "rage")
		gf.advance_ticks(roundi(120.0 * 1.2 * 0.4))
		if not await _neck_frame(gf, "exit_fly.png", false):
			bad += 1
	else:
		bad += 1
	gf.queue_free()
	await process_frame
	print("RESULT neck_shots ok=%s (%d bad)" % [bad == 0, bad])
	return 0 if bad == 0 else 1


func _traffic_source() -> String:
	var t: Object = _game.traffic
	return str(t.get(&"source")) if t is TrafficStub else t.get_script().resource_path


func _frames(n: int) -> void:
	for i: int in n:
		_game.render_step(0.0)
		await process_frame
	await RenderingServer.frame_post_draw


func _set_overlay(on: bool) -> void:
	_game.hud.visible = on
	_game.icons.visible = on


func _apply_opts() -> void:
	var w: WorldView = _game.world
	match str(_opts.get("ambient", "")):
		"hemi":
			w.set_ambient_mode(WorldView.Ambient.SHADER_HEMI)
		"flat":
			w.set_ambient_mode(WorldView.Ambient.FLAT)
		"sky":
			w.set_ambient_mode(WorldView.Ambient.SKY)
	match str(_opts.get("tonemap", "")):
		"agx":
			w.env.tonemap_mode = Environment.TONE_MAPPER_AGX
		"filmic":
			w.env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	if _opts.has("no-shadows"):
		w.sun.shadow_enabled = false
	if _opts.has("no-glow"):
		w.env.glow_enabled = false
	if _opts.has("ao"):
		_game.factory.set_param(&"ao_strength", float(_opts["ao"]))
	# look-dev overrides (A/B shots)
	if _opts.has("shadow-q"):
		RenderingServer.directional_soft_shadow_filter_set_quality(int(_opts["shadow-q"]) as RenderingServer.ShadowQuality)
	if _opts.has("shadow-blur"):
		w.sun.shadow_blur = float(_opts["shadow-blur"])
	if _opts.has("bias"):
		w.sun.shadow_bias = float(_opts["bias"])
	if _opts.has("nbias"):
		w.sun.shadow_normal_bias = float(_opts["nbias"])
	if _opts.has("glow-blend"):  # additive | screen | softlight | replace | mix
		w.env.glow_blend_mode = {"additive": Environment.GLOW_BLEND_MODE_ADDITIVE, "screen": Environment.GLOW_BLEND_MODE_SCREEN,
			"softlight": Environment.GLOW_BLEND_MODE_SOFTLIGHT, "replace": Environment.GLOW_BLEND_MODE_REPLACE,
			"mix": Environment.GLOW_BLEND_MODE_MIX}.get(str(_opts["glow-blend"]), w.env.glow_blend_mode)
	if _opts.has("glow-int"):
		w.env.glow_intensity = float(_opts["glow-int"])
	if _opts.has("glow-levels"):
		var lv: PackedStringArray = str(_opts["glow-levels"]).split(",")
		for i: int in 7:
			w.env.set_glow_level(i, float(lv[i]) if i < lv.size() else 0.0)
	if _opts.has("ao-light"):
		_game.factory.set_param(&"ao_light_affect", float(_opts["ao-light"]))


## Pin cars / player / villain / opposite traffic / camera to a web frame (web_shot.mjs dump).
func _apply_web_state(path: String) -> void:
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	var stub := _game.traffic as TrafficStub
	if stub == null:
		print("INFO shot_jam: --state needs the view TrafficStub (bridge has no set_car_state); camera only")
	else:
		for c: Dictionary in d["cars"]:
			var bl: int = (2 if bool(c.get("blinkL", false)) else 0) | (4 if bool(c.get("blinkR", false)) else 0)
			stub.set_car_state(int(c["id"]), {"x": float(c["x"]), "s": float(c["s"]), "yaw": float(c["yaw"]),
				"lane": int(c["lane"]), "lane_to": int(c["lane"]), "lc_t": 1.0, "v": float(c["v"]),
				"brake": bool(c.get("brake", false)), "blink": bl})
		var opp: Array = d.get("opp", [])
		for i: int in opp.size():
			stub.set_opp_state(i, float((opp[i] as Dictionary)["s"]))
		for v: Dictionary in d.get("villains", []):
			stub.set_car_state(1000, {"x": float(v["px"]), "s": -float(v["pz"])})
		_game.npc.blink_phase = false  # web blinker visibility is already the lit state
	var p: Dictionary = d["player"]
	_game.player.s = float(p["s"])
	_game.player.x = float(p["x"])
	_game.player.v = float(p.get("v", _game.player.v))
	_game.player.lane = int(p["lane"])
	_game.player.lc_t = 1.0
	_game.player.yaw = float(p.get("yaw", 0.0))
	if "lamp_bits" in _game.player:
		_game.player.set(&"lamp_bits", 1 if bool(p.get("brake", false)) else 0)
	_game.sim_time = float(d.get("t", _game.sim_time))
	_game.traffic.call(&"read_into", _game._cur)
	_game._prev = _game._cur.duplicate()
	_game.player_view.transform = _game.road.world(_game.player.s, _game.player.x, _game.player.yaw)
	var cam: Dictionary = d["camera"]
	var pos := Vector3(float(cam["pos"][0]), float(cam["pos"][1]), float(cam["pos"][2]))
	var fwd := Vector3(float(cam["fwd"][0]), float(cam["fwd"][1]), float(cam["fwd"][2]))
	_game.camera.set_pose(pos, pos + fwd * 20.0, float(cam["fov"]))
	_game.render_step(0.0)


func _lum_mean_sd(img: Image) -> Vector2:
	var s := 0.0
	var s2 := 0.0
	var n := 0
	var step: int = 4
	for y: int in range(0, img.get_height(), step):
		for x: int in range(0, img.get_width(), step):
			var c: Color = img.get_pixel(x, y)
			var l: float = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			s += l
			s2 += l * l
			n += 1
	var m: float = s / float(n)
	return Vector2(m, sqrt(maxf(0.0, s2 / float(n) - m * m)))


static func _lab(c: Color) -> Vector3:
	var l: Color = c.srgb_to_linear()
	var x: float = (0.4124 * l.r + 0.3576 * l.g + 0.1805 * l.b) / 0.95047
	var y: float = 0.2126 * l.r + 0.7152 * l.g + 0.0722 * l.b
	var z: float = (0.0193 * l.r + 0.1192 * l.g + 0.9505 * l.b) / 1.08883
	var f := func(t: float) -> float: return pow(t, 1.0 / 3.0) if t > 0.008856 else 7.787 * t + 16.0 / 116.0
	var fx: float = f.call(x)
	var fy: float = f.call(y)
	var fz: float = f.call(z)
	return Vector3(116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz))


func _delta_e(a: Image, b: Image) -> float:
	var bb: Image = b.duplicate()
	if bb.get_size() != a.get_size():
		bb.resize(a.get_width(), a.get_height(), Image.INTERPOLATE_BILINEAR)
	var s := 0.0
	var n := 0
	for y: int in range(0, a.get_height(), 3):
		for x: int in range(0, a.get_width(), 3):
			s += _lab(a.get_pixel(x, y)).distance_to(_lab(bb.get_pixel(x, y)))
			n += 1
	return s / float(maxi(1, n))


func _side_by_side(web: Image, nat: Image) -> Image:
	var h: int = nat.get_height()
	var w2: Image = web.duplicate()
	w2.convert(Image.FORMAT_RGBA8)
	if w2.get_height() != h:
		w2.resize(roundi(float(w2.get_width()) * float(h) / float(w2.get_height())), h, Image.INTERPOLATE_BILINEAR)
	var n2: Image = nat.duplicate()
	n2.convert(Image.FORMAT_RGBA8)
	var gap: int = 12
	var out := Image.create(w2.get_width() + gap + n2.get_width(), h, false, Image.FORMAT_RGBA8)
	out.fill(Color(0.1, 0.1, 0.12))
	out.blit_rect(w2, Rect2i(Vector2i.ZERO, w2.get_size()), Vector2i.ZERO)
	out.blit_rect(n2, Rect2i(Vector2i.ZERO, n2.get_size()), Vector2i(w2.get_width() + gap, 0))
	return out


## Brake-wave ripple strip (M1a "브레이크 파동"): N frames of one lane every wave-dt seconds of sim time, scaled 50 %
## side by side, plus a space-time panel on the right: x = sim time (one column per 0.05 s), y = absolute s
## (far ahead = up, like the view), one bar per car of that lane, red = brake lamp bit lit, grey = off; white lines
## mark the frames. A wave reads as a diagonal band. Natural stop&go by default; --wave-emit adds
## Traffic.emit_brake_wave (traffic.js:521, the JamShaper / behaviour API) at player.s + wave-ahead.
## Also prints the lit pattern per frame (nearest first) so the ripple is checkable in text.
func _wave_strip(path: String) -> int:
	var lane: int = int(_opts.get("wave-lane", "1"))
	var ahead: float = float(_opts.get("wave-ahead", "50"))
	var strength: float = float(_opts.get("wave-strength", "2.5"))
	var nf: int = int(_opts.get("wave-frames", "6"))
	var dt: float = float(_opts.get("wave-dt", "0.5"))
	if not (_game.traffic is TrafficBridge and bool(_game.traffic.call(&"is_native"))):
		print("FAIL shot_jam: --wave-strip needs the C++ Traffic")
		return 1
	_game.hud.visible = false
	if _opts.has("wave-emit"):
		_game.traffic.call(&"native").call(&"emit_brake_wave", lane, _game.player.s + ahead, strength)
		print("RESULT wave_emit: lane=%d s=%.1f strength=%.1f" % [lane, _game.player.s + ahead, strength])
	for d: Dictionary in _game.traffic.call(&"car_specs"):
		_lens[int(d["id"])] = float(d.get("len", 4.6))
	var s_ref: float = _game.player.s
	var cols: Array[Array] = []        # per 0.05 s: [[s, len, lit], ...]
	var marks: PackedInt32Array = []   # column index of each frame
	var tiles: Array[Image] = []
	for f: int in nf:
		var steps: int = roundi(dt * 20.0)
		for k: int in steps:
			_game.advance_ticks(6)
			cols.append(_lane_cars(lane))
		marks.append(cols.size() - 1)
		await _frames(3)
		var img: Image = _vp.get_texture().get_image()
		img.resize(img.get_width() / 2, img.get_height() / 2, Image.INTERPOLATE_BILINEAR)
		img.convert(Image.FORMAT_RGBA8)
		tiles.append(img)
		var lit: PackedStringArray = []
		for c: Array in cols[cols.size() - 1]:
			var ds: float = float(c[0]) - _game.player.s
			if ds > 0.0 and ds < 90.0:
				lit.append(("%.0f*" if bool(c[2]) else "%.0f") % ds)
		print("RESULT wave_frame=%d t=%.2f lane%d ds (*=brake lit): %s" % [f, _game.sim_time, lane, " ".join(lit)])
	var w: int = tiles[0].get_width()
	var h: int = tiles[0].get_height()
	var cw: int = 5
	var dw: int = cols.size() * cw
	var out := Image.create(nf * (w + 8) + dw, h, false, Image.FORMAT_RGBA8)
	out.fill(Color(0.08, 0.09, 0.11))
	for f: int in nf:
		out.blit_rect(tiles[f], Rect2i(Vector2i.ZERO, tiles[f].get_size()), Vector2i(f * (w + 8), 0))
	var x0: int = nf * (w + 8)
	var s_lo: float = s_ref - 5.0
	var s_hi: float = s_ref + 95.0
	var px_m: float = float(h) / (s_hi - s_lo)
	for ci: int in cols.size():
		for c: Array in cols[ci]:
			var top: float = float(h) - (float(c[0]) + float(c[1]) * 0.5 - s_lo) * px_m
			var bot: float = float(h) - (float(c[0]) - float(c[1]) * 0.5 - s_lo) * px_m
			var r := Rect2i(x0 + ci * cw, int(top), cw - 1, maxi(1, int(bot - top) - 1)).intersection(Rect2i(0, 0, out.get_width(), h))
			if r.has_area():
				out.fill_rect(r, Color8(0xff, 0x2a, 0x2a) if bool(c[2]) else Color8(0x4a, 0x50, 0x5a))
	for m: int in marks:
		out.fill_rect(Rect2i(x0 + m * cw + cw - 1, 0, 1, h), Color(1, 1, 1, 0.6))
	out.save_png(path)
	print("RESULT wave_strip=%s frames=%d columns=%d (%.2f s) lane=%d s=[%.0f, %.0f]" % [path, nf, cols.size(),
		float(cols.size()) * 0.05, lane, s_lo, s_hi])
	return 0


func _lane_cars(lane: int) -> Array:
	var buf: PackedFloat32Array = _game.buffer()
	var rows: Array = []
	for k: int in buf.size() / 8:
		if int(buf[k * 8 + 2]) != lane:
			continue
		var ds: float = buf[k * 8 + 4] - _game.player.s
		if ds < -10.0 or ds > 110.0:
			continue
		rows.append([buf[k * 8 + 4], float(_lens.get(int(buf[k * 8]), 4.6)), (int(buf[k * 8 + 7]) & 1) != 0])
	rows.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	return rows
