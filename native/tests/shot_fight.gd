extends SceneTree
## Xvfb shots of the 1-1 fight UI / FX against the real GameSim (autopilot), NATIVE_PORT 4-2 T2 + DESIGN_REVIEW P0#2 #4 #6:
##   xvfb-run -a -s "-screen 0 1280x1024x24" godot47 --path native --rendering-method mobile --audio-driver Dummy \
##       -s res://tests/shot_fight.gd -- --out=/abs/dir [--seed=3] [--size=585x1266] [--safe-pt=59,34] [--only=a,b]
## Builds a minimal view of GameSim (world, NPC MultiMesh from sim.traffic(), hero cars, CameraRig with the P0#4 boss
## framing, FightFx, Hud) — the same wiring view/game.gd will use — runs the autopilot at the fixed 1/120 tick and
## saves, each at its moment:
##   fight_jam.png        jam with the new bottom bar (압정 · 분노 · 경적 · lanes)
##   fight_out_range.png  front lock, player outside villain lane ±1: grey ring / reticle / band + "◀ 원흉 차로로"
##   fight_in_range.png   locked on: green reticle, range band, tacks in flight, hit sparks, villain HP bar
##   fight_kill.png       kill slow-mo: explosion, letterbox, "참교육 완료!" banner, orbit camera
##   fight_release.png    release wave sweeping the jam, ✓ pops, counter sign, confetti
##   fight_result.png     result card (timeline at its end); fight_result_tow.png = the same after one tow (P0#6)
##   fight_fail.png       fail card (forced wreck in the fight, second run)
## Prints RESULT lines (phase times, reticle-on-target distance, HUD rect overlaps with the framed cars).
## Exit 0 ok · 1 a moment was never reached / reticle off target · 2 cannot render.

const _DB := preload("res://core/db.gd")
const TICK: float = 1.0 / 120.0
const FRAME_TICKS: int = 4          # view sync every 4 ticks (30 fps of real time)

var _out: String = ""
var _seed: int = 3
var _size := Vector2i(585, 1266)
var _safe_pt := Vector2(59, 34)
var _only: PackedStringArray = []
var _vp: SubViewport
var _root: Node3D
var _sim: GameSim
var _stage: Dictionary
var _tables: Dictionary
var _road: RoadGraph
var _factory: VehicleFactory
var _world: WorldView
var _npc: NpcMultiMesh
var _player_view: HeroVehicleView
var _villain_views: Array[HeroVehicleView] = []
var _cam: CameraRig
var _fx: FightFx
var _hud: Hud
var _prev := PackedFloat32Array()
var _cur := PackedFloat32Array()
var _ok: bool = true
var _st: Dictionary = {}
var _ev_log: Dictionary = {}       # type → first real time


func _initialize() -> void:
	for a: String in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.trim_prefix("--").split("=", true, 1)
		var v: String = kv[1] if kv.size() > 1 else "1"
		match kv[0]:
			"out":
				_out = v
			"seed":
				_seed = v.to_int()
			"size":
				var p: PackedStringArray = v.split("x")
				_size = Vector2i(p[0].to_int(), p[1].to_int())
			"safe-pt":
				var q: PackedStringArray = v.split(",")
				_safe_pt = Vector2(q[0].to_float(), q[1].to_float())
			"only":
				_only = v.split(",")
	_main.call_deferred()


func _want(n: String) -> bool:
	return _only.is_empty() or _only.has(n)


func _main() -> void:
	if _out.is_empty() or DisplayServer.get_name() == "headless":
		print("FAIL shot_fight: need --out=<dir> and a real display (xvfb-run, no --headless)")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	_stage = _DB.find_stage(_DB.load_json("res://data/stages.json"), 1)
	_tables = _DB.load_traffic_tables()
	_vp = SubViewport.new()
	_vp.size = _size
	_vp.size_2d_override = Vector2i(540, roundi(540.0 * float(_size.y) / float(_size.x)))
	_vp.size_2d_override_stretch = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.msaa_3d = Viewport.MSAA_4X
	_vp.use_debanding = true
	_vp.audio_listener_enable_3d = false
	root.add_child(_vp)

	await _run_main()
	if _want("fail"):
		await _run_fail()
	print("RESULT events_first_real_t=%s" % JSON.stringify(_ev_log))
	print("RESULT ok=%s" % _ok)
	quit(0 if _ok else 1)


# ───────────────────────────── rig (= what game.gd wires)

func _build(seed: int) -> void:
	if _root != null:
		_root.queue_free()
		await process_frame
	_villain_views.clear()
	_sim = GameSim.new()
	_sim.setup(_stage, _tables, seed)
	_sim.autopilot = Autopilot.new(seed * 13 + 1)
	_root = Node3D.new()
	_root.name = "FightRig"
	_vp.add_child(_root)
	_road = RoadGraph.new(_stage.get("road", []) if _stage.get("road") is Array else [])
	_factory = VehicleFactory.new()
	var br: TrafficBridge = _sim.traffic()
	_world = WorldView.new()
	_root.add_child(_world)
	_world.build(_stage, _factory, _road, {"startS": _sim.start_s, "frontS": _sim.front_s}, br.obstacles())
	_cur.clear()
	br.read_into(_cur)
	_prev = _cur.duplicate()
	_npc = NpcMultiMesh.new()
	_root.add_child(_npc)
	_npc.setup(_factory, _road, _specs(br))
	_player_view = HeroVehicleView.new()
	_root.add_child(_player_view)
	_player_view.setup(_factory, "player", 0)
	_player_view.enable_beacon()
	_player_view.manual = true
	for v: Dictionary in _sim.state()["villains"]:
		var hv := HeroVehicleView.new()
		_root.add_child(hv)
		hv.setup(_factory, str(v.get("kind", "villainSedan")), 0, v.get("color"))
		hv.manual = true
		_villain_views.append(hv)
	_cam = CameraRig.new()
	_cam.road = _road
	_root.add_child(_cam)
	_cam.current = true
	_fx = FightFx.new()
	_fx.manual = true
	_root.add_child(_fx)
	_fx.setup(_road, seed, _tables["config"].get("tune", {}), _sim.front_s, _sim.tail_s)
	_fx.camera_rig = _cam
	_hud = Hud.new()
	_hud.manual = true
	_root.add_child(_hud)
	_hud.debug_safe_pt = _safe_pt
	_hud.apply_safe_area()
	_hud.bind_world(_cam, _road)
	_hud.stage = _stage
	_hud.rage_cost = float((_tables["config"].get("tune", {}) as Dictionary).get("superCost", 0.2))
	_sync_view(0.0)
	_cam.snap()


func _specs(br: TrafficBridge) -> Dictionary:
	var names: PackedStringArray = br.kind_names()
	var by_id: Dictionary = {}
	for d: Dictionary in br.car_specs():
		by_id[int(d["id"])] = d
	var out: Dictionary = {}
	for k: int in _cur.size() / 8:
		var id: int = int(_cur[k * 8])
		var ki: int = int(_cur[k * 8 + 1])
		var kind: String = names[ki] if ki >= 0 and ki < names.size() else "sedan"
		if by_id.has(id):
			var d: Dictionary = by_id[id]
			out[id] = {"kind": str(d.get("kind_name", kind)), "variant": int(d.get("variant", 0)), "color": int(d.get("color", 0xf4f4f2))}
		else:
			out[id] = {"kind": kind, "variant": _factory.variant_for_seed(kind, id * 7919), "color": 0xf4f4f2}
	return out


## One sim tick + event fan-out (game.gd sim side).
func _tick() -> void:
	_sim.step(TICK)
	for e: Dictionary in _sim.events():
		var t: String = str(e["type"])
		if not _ev_log.has(t):
			_ev_log[t] = snappedf(_sim.real_time, 0.01)
		_hud.on_event(e)
		_fx.on_event(e, _st)
		_cam.on_event(e)


## View sync (game.gd _process side), dt = real seconds since the last sync.
func _sync_view(dt: float) -> void:
	_st = _sim.state()
	_prev = _cur.duplicate()
	_sim.traffic().read_into(_cur)
	_npc.lamp_time = _sim.time
	_npc.sync(_prev, _cur, 1.0)
	var p: Dictionary = _st["player"]
	var pxf: Transform3D = _road.world(float(p["s"]), float(p["x"]), float(p.get("yaw", 0.0)))
	pxf.origin.y += float(p.get("hop", 0.0))
	_player_view.transform = pxf
	_player_view.speed = float(p["v"])
	_player_view.set_lamps(8 if false else (1 if bool(p.get("brake", false)) else 0))
	_player_view.set_beacon(int(floorf(_sim.time / 0.18)) % 2 == 0)
	_player_view.advance_wheels(dt)
	var vs: Array = _st["villains"]
	for i: int in mini(vs.size(), _villain_views.size()):
		var v: Dictionary = vs[i]
		var hv: HeroVehicleView = _villain_views[i]
		hv.visible = not bool(v.get("gone", false))
		var xf: Transform3D = _road.world(float(v["s"]), float(v["x"]), float(v.get("yaw", 0.0)))
		xf.origin.y += float(v.get("y", 0.0))
		var rot: Variant = v.get("rot")
		if rot is Vector3 and (rot as Vector3) != Vector3.ZERO:
			xf.basis = xf.basis * Basis.from_euler(rot as Vector3)
		else:
			xf.basis = xf.basis * Basis.from_euler(Vector3(float(v.get("tilt_x", 0.0)), 0.0, float(v.get("tilt_z", 0.0))))
		hv.transform = xf
		hv.speed = float(v.get("v", 10.0)) if v.has("v") else 10.0
		var bits: int = (1 if float(v.get("hp", 1.0)) > 0.0 else 0) | (16 if int(v.get("blinker", 0)) != 0 else 0)
		hv.set_lamps(bits)
		hv.set_flash(float(v.get("flash", 0.0)))
		hv.advance_wheels(dt)
	_cam.target_s = float(p["s"])
	_cam.target_x = float(p["x"])
	_cam.target_v = float(p["v"])
	_cam.apply_state(_st)
	_cam.step(dt)
	_world.update_overheads(_cam.global_position)
	_fx.sync(_st, _cur)
	_fx.advance(dt)
	_hud.apply_state(_st)
	_hud.advance(dt)


func _advance_ticks(n: int) -> void:
	for i: int in n:
		_tick()
		if (i + 1) % FRAME_TICKS == 0:
			_sync_view(TICK * FRAME_TICKS)


## Runs until cond(sim, state) is true (checked every view frame) or the real-time limit passes.
func _until(cond: Callable, limit_real: float) -> bool:
	var t_end: float = _sim.real_time + limit_real
	while _sim.real_time < t_end:
		_advance_ticks(FRAME_TICKS)
		if bool(cond.call()):
			return true
	return false


func _shot(name: String) -> void:
	for i: int in 3:
		await process_frame
	await RenderingServer.frame_post_draw
	var img: Image = _vp.get_texture().get_image()
	img.save_png(_out.path_join(name + ".png"))
	var lum: float = 0.0
	var n: int = 0
	for y: int in range(0, img.get_height(), 37):
		for x: int in range(0, img.get_width(), 37):
			lum += img.get_pixel(x, y).get_luminance()
			n += 1
	print("RESULT shot %s phase=%s t=%.2f real=%.2f hint='%s' lock=%s lum=%.3f fx=%s" % [name, _sim.phase, _sim.time,
		_sim.real_time, str(_st.get("hint", "")), JSON.stringify(_st.get("lock", {})), lum / maxf(1.0, float(n)),
		JSON.stringify(_fx.counts())])


func _check_reticle(name: String) -> void:
	var r: Reticle = _hud.reticle
	var tid: int = int((_st["lock"] as Dictionary).get("target_id", -1))
	var v: Dictionary = (_st["villains"] as Array)[0]
	for q: Variant in _st["villains"]:
		if int((q as Dictionary)["id"]) == tid:
			v = q
	var want: Vector2 = _cam.unproject_position(_road.position(float(v["s"]), float(v["x"])) + Vector3(0, 0.9, 0))
	var err: float = r.screen_pos.distance_to(want)
	var on_car: bool = r.on_screen and err < 2.0
	print("RESULT reticle %s on_screen=%s err_px=%.2f r=%.1f in_range=%s frame_k=%.2f" % [name, r.on_screen, err, r.screen_r,
		bool((_st["lock"] as Dictionary).get("in_range", false)), _cam.frame_k])
	if not on_car:
		print("FAIL shot_fight: %s reticle not on the target car" % name)
		_ok = false
	# P0#4: the framed cars stay out of the HUD widgets (bottom controls, top plate)
	var hits: PackedStringArray = []
	var p: Dictionary = _st["player"]
	var pts: Array[Vector2] = [_cam.unproject_position(_road.position(float(p["s"]), float(p["x"])) + Vector3(0, 1.0, 0)), want]
	for rr: Rect2 in _hud.reserved_rects():
		for sp: Vector2 in pts:
			if rr.has_point(sp):
				hits.append("%s@%s" % [rr, sp])
	print("RESULT hud_cover %s cars_under_hud=%d %s" % [name, hits.size(), " ".join(hits)])
	if not hits.is_empty():
		print("FAIL shot_fight: %s HUD covers a framed car (P0#4)" % name)
		_ok = false


func _miss(what: String) -> void:
	print("FAIL shot_fight: never reached %s (phase %s t=%.1f)" % [what, _sim.phase, _sim.time])
	_ok = false


# ───────────────────────────── main run

func _run_main() -> void:
	await _build(_seed)
	# jam: new bottom bar
	if not _until(func() -> bool: return _sim.phase == &"jam" and _sim.phase_real > 3.0, 30.0):
		_miss("jam")
	if _want("jam"):
		await _shot("fight_jam")
	# out of range: locked, target not in lane ±1
	if not _until(func() -> bool: return _sim.phase == &"boss" and _sim.front_locked and not bool(_st["lock"]["in_range"]) \
			and _hud.reticle.on_screen, 60.0):
		_miss("boss out of range")
	else:
		_advance_ticks(FRAME_TICKS * 6)
		if _want("out_range"):
			await _shot("fight_out_range")
			_check_reticle("out_range")
	# in range: locked on for 0.8 s, a tack just hit
	var locked_on: Callable = func() -> bool:
		return _sim.phase == &"boss" and bool(_st["lock"]["in_range"]) and _hud.reticle.locked_for() > 0.8 \
			and int(_fx.counts()["glow"]) > 6
	if not _until(locked_on, 40.0):
		_miss("boss in range")
	elif _want("in_range"):
		await _shot("fight_in_range")
		_check_reticle("in_range")
	# kill: 0.35 s real after the kill event (slow-mo)
	if not _until(func() -> bool: return _sim.phase == &"kill" and _sim.phase_real > 0.35, 60.0):
		_miss("kill")
	elif _want("kill"):
		await _shot("fight_kill")
	# release: wave mid-jam
	if not _until(func() -> bool: return _sim.phase == &"release" and _sim.phase_real > 1.75, 30.0):
		_miss("release")
	elif _want("release"):
		await _shot("fight_release")
	# result card
	if not _until(func() -> bool: return _sim.phase == &"result" and _sim.phase_real > 0.3, 40.0):
		_miss("result")
	elif _want("result"):
		var res: Dictionary = _st.get("result", {})
		_hud.show_result(res, {}, _stage)
		_hud.result_card.seek(ResultCard.T_END)
		await _shot("fight_result")
		var m: Dictionary = _hud.result_card.data
		print("RESULT result_card time=%s min_hp=%d tows=%d stars=%d payout=%d missions=%s" % [UiDraw.clock(float(m["time_s"])),
			int(m["min_hp"]), int(m["tows"]), int(m["stars"]), int(m["payout"]), JSON.stringify(m["missions"])])
		# P0#6: the same card after a tow (stub result: totals over the retry, ★2 failed, ×0.8)
		_hud.show_result(UiStubState.result(1), {}, _stage)
		_hud.result_card.seek(ResultCard.T_END)
		await _shot("fight_result_tow")


# ───────────────────────────── fail run (forced wreck in the fight)

func _run_fail() -> void:
	await _build(_seed)
	if not _until(func() -> bool: return _sim.phase == &"boss" and _sim.front_locked and _sim.phase_real > 4.0, 90.0):
		_miss("fail run: boss lock")
		return
	_sim.autopilot = null  # it would press retry on the fail card at once
	_sim.input(&"fire", false)
	_sim.apply_damage(9999.0, "원흉 컵 투척 직격", "throw")
	if not _until(func() -> bool: return _sim.phase == &"fail", 10.0):
		_miss("fail")
		return
	_advance_ticks(FRAME_TICKS * 3)
	_hud.show_fail({})
	_hud.fail_card.seek(1.2)
	_sync_view(0.0)
	await _shot("fight_fail")
	print("RESULT fail_card %s" % JSON.stringify(_hud.fail_card.data))
