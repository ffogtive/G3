extends SceneTree
## Xvfb shots of the skill presentation (docs/SKILLS.md 7-2) against the real GameSim: its SkillsSim when config.skills
## is there (&"rage" tier / &"item1|2" inputs, the sim's own events), else — or with --stub — SkillsStub (the §6 events):
##   xvfb-run -a -s "-screen 0 1280x1024x24" godot47 --path native --rendering-method mobile --audio-driver Dummy \
##       -s res://tests/shot_skills.gd -- --out=/abs/dir [--seed=3] [--size=585x1266] [--only=t1,t3,...] [--fallback] [--stub]
## Runs: t1 t3 t5 (no execute: "한 번 더!") t5x (execute → rocket) jump drone · finishers rocket balloon heli ufo ·
## ring (분노 0/1/3/5 칸 × jam / fight) · items (cool 0 / 50 / 100 %, unusable).
## Each run saves frames at cast, impact, +0.3 s, +1.0 s, end (finishers: kill +0.05 … +2.4 s) as <run>_<n>.png and a
## contact sheet <run>_sheet.png (half size, frames side by side).
## Auto checks (RESULT / FAIL lines): impact point inside FRAME_Y 20–74 % and not under a HUD rect; kill cam: road
## ≥ 35 % of the screen from the bottom (CameraRig.road_bottom_frac + a pixel probe: no sky-blue in the bottom 35 %),
## look-at y ≤ 4.5, no letterbox (no near-black full-width rows at the top / bottom); particle caps respected.
## Exit 0 ok · 1 a check failed · 2 cannot render.

const _DB := preload("res://core/db.gd")
const TICK: float = 1.0 / 120.0
const FRAME_TICKS: int = 4

var _out: String = ""
var _seed: int = 3
var _size := Vector2i(585, 1266)
var _safe_pt := Vector2(59, 34)
var _only: PackedStringArray = []
var _fallback: bool = false
var _force_stub: bool = false
var _real: bool = false
var _vp: SubViewport
var _root: Node3D
var _sim: GameSim
var _stub: SkillsStub
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
var _last_sim_t: float = 0.0
var _impact_pos := Vector3.INF
var _impact_seen: bool = false
var _frames: Array[Image] = []
var _labels: PackedStringArray = []


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
			"only":
				_only = v.split(",")
			"fallback":
				_fallback = true
			"stub":
				_force_stub = true
	_main.call_deferred()


func _want(n: String) -> bool:
	return _only.is_empty() or _only.has(n)


func _main() -> void:
	if _out.is_empty() or DisplayServer.get_name() == "headless":
		print("FAIL shot_skills: need --out=<dir> and a real display (xvfb-run, no --headless)")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	_stage = _DB.find_stage(_DB.load_json("res://data/stages.json"), 1)
	_vp = SubViewport.new()
	_vp.size = _size
	_vp.size_2d_override = Vector2i(540, roundi(540.0 * float(_size.y) / float(_size.x)))
	_vp.size_2d_override_stretch = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.msaa_3d = Viewport.MSAA_4X
	_vp.use_debanding = true
	_vp.audio_listener_enable_3d = false
	root.add_child(_vp)
	for run: String in ["t1jam", "t1", "t3", "t5", "t5x", "jump", "drone"]:
		if _want(run):
			await _run_skill(run)
	for fin: String in ["rocket", "balloon", "heli", "ufo"]:
		if _want(fin):
			await _run_finish(fin)
	if _want("ring"):
		await _run_ring()
	if _want("items"):
		await _run_items()
	print("RESULT ok=%s" % _ok)
	quit(0 if _ok else 1)


# ───────────────────────────── rig (= view/game.gd wiring + the stub)

func _build(seed: int, finish: String = "rocket") -> void:
	if _root != null:
		_root.queue_free()
		await process_frame
	_villain_views.clear()
	_tables = _DB.load_traffic_tables()
	_tables["options"] = {"finish": finish, "loadout": {"finish": finish, "items": ["mv_jump", "mv_drone"]}}
	_sim = GameSim.new()
	_sim.force_fallback = _fallback
	_sim.setup(_stage, _tables, seed)
	_sim.autopilot = Autopilot.new(seed * 13 + 1)
	_stub = SkillsStub.new(_sim)
	_stub.finish = finish
	_real = not _force_stub and _sim.get(&"skills") != null and bool((_sim.get(&"skills") as Object).get(&"enabled"))
	print("INFO shot_skills: %s skills, traffic %s" % ["sim" if _real else "stub", "fallback" if _fallback else "auto"])
	_root = Node3D.new()
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
	_hud.finish_id = finish
	_hud.rage_cost = float((_tables["config"].get("tune", {}) as Dictionary).get("superCost", 0.2))
	_last_sim_t = _sim.time
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


func _fan(e: Dictionary) -> void:
	if str(e.get("type", "")) == "skill_denied":
		print("INFO shot_skills: denied %s" % JSON.stringify(e))
	_hud.on_event(e)
	_fx.on_event(e, _st)
	_cam.on_event(e)
	if str(e.get("type", "")) == "skill_hit" and int(e.get("idx", 0)) == 0 and not _impact_seen:
		_impact_seen = true
		_impact_pos = _road.position(float(e.get("s", 0.0)), float(e.get("x", 0.0))) + Vector3(0, 1.0, 0)


func _tick() -> void:
	_sim.step(TICK)
	if not _real:
		_stub.tick()
	for e: Dictionary in _sim.events():
		_fan(e)
	if not _real:
		for e: Dictionary in _stub.drain():
			_fan(e)


## Cast through the sim's inputs (real skills) or the stub.
func _cast(what: String) -> void:
	if _real:
		match what:
			"item1":
				_sim.input(&"item1")
			"item2":
				_sim.input(&"item2")
			_:
				_sim.input(&"rage", what.to_int())
		return
	match what:
		"item1":
			_stub.use_item(1)
		"item2":
			_stub.use_item(2)
		_:
			_stub.cast(what.to_int())


func _ts() -> float:
	var sk: Variant = _st.get("skills")
	return float((sk as Dictionary).get("time_scale", 1.0)) if sk is Dictionary else 1.0


func _sync_view(dt: float) -> void:
	_st = _sim.state() if _real else _stub.decorate(_sim.state())
	_prev = _cur.duplicate()
	_sim.traffic().read_into(_cur)
	_npc.lamp_time = _sim.time
	_npc.sync(_prev, _cur, 1.0)
	var p: Dictionary = _st["player"]
	var pxf: Transform3D = _road.world(float(p["s"]), float(p["x"]), float(p.get("yaw", 0.0)))
	pxf.origin.y += float(p.get("hop", 0.0))
	_player_view.transform = pxf
	_player_view.speed = float(p["v"])
	_player_view.set_lamps(1 if bool(p.get("brake", false)) else 0)
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
		hv.speed = 10.0
		hv.set_lamps(1 if bool(v.get("alive", false)) else 0)
		hv.set_flash(float(v.get("flash", 0.0)))
		hv.set_flat(v.get("popped", []) if v.get("popped") is Array else [])
		hv.advance_wheels(dt)
	_cam.target_s = float(p["s"])
	_cam.target_x = float(p["x"])
	_cam.target_v = float(p["v"])
	_cam.apply_state(_st)
	_cam.step(dt)
	_world.update_overheads(_cam.global_position)
	_fx.sync(_st, _cur)
	_fx.advance(_sim.time - _last_sim_t)   # FX on sim time: hit-stop freezes, slow-mo slows
	_fx.cues.advance(dt)
	_last_sim_t = _sim.time
	_hud.apply_state(_st)
	_hud.advance(dt)


func _advance_ticks(n: int) -> void:
	for i: int in n:
		_tick()
		if (i + 1) % FRAME_TICKS == 0:
			_sync_view(TICK * FRAME_TICKS)


func _until(cond: Callable, limit_real: float) -> bool:
	var t_end: float = _sim.real_time + limit_real
	while _sim.real_time < t_end:
		_advance_ticks(FRAME_TICKS)
		if bool(cond.call()):
			return true
	return false


func _real_s(sec: float) -> void:
	_advance_ticks(maxi(FRAME_TICKS, roundi(sec / TICK / FRAME_TICKS) * FRAME_TICKS))


func _grab(run: String, label: String) -> Image:
	for i: int in 3:
		await process_frame
	await RenderingServer.frame_post_draw
	var img: Image = _vp.get_texture().get_image()
	img.save_png(_out.path_join("%s_%d.png" % [run, _frames.size()]))
	_frames.append(img)
	_labels.append(label)
	var c: Dictionary = _fx.counts()
	var caps_ok: bool = int(c["lit"]) <= FightFx.MAX_LIT and int(c["glow"]) <= FightFx.MAX_GLOW and int(c["smoke"]) <= FightFx.MAX_SMOKE \
		and int(c.get("decals", 0)) <= SkillFx.DECALS
	print("RESULT frame %s %s phase=%s real=%.2f ts=%.2f fx=%s" % [run, label, _sim.phase, _sim.real_time, _ts(), JSON.stringify(c)])
	if not caps_ok:
		print("FAIL shot_skills: %s %s particle / decal caps exceeded" % [run, label])
		_ok = false
	return img


func _sheet(run: String) -> void:
	if _frames.is_empty():
		return
	var w: int = _size.x / 2
	var h: int = _size.y / 2
	var sheet := Image.create(w * _frames.size() + 6 * (_frames.size() - 1), h, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.1, 0.1, 0.12))
	for i: int in _frames.size():
		var f: Image = _frames[i].duplicate()
		f.convert(Image.FORMAT_RGBA8)
		f.resize(w, h, Image.INTERPOLATE_BILINEAR)
		sheet.blit_rect(f, Rect2i(0, 0, w, h), Vector2i(i * (w + 6), 0))
	sheet.save_png(_out.path_join("%s_sheet.png" % run))
	print("RESULT sheet %s frames=%s" % [run, ",".join(_labels)])
	_frames.clear()
	_labels.clear()


func _fail(what: String) -> void:
	print("FAIL shot_skills: %s (phase %s t=%.1f)" % [what, _sim.phase, _sim.time])
	_ok = false


## Into the locked fight with the target in range, autopilot off (the stub casts), rage set.
func _to_fight(rage: float) -> bool:
	if not _until(func() -> bool: return _sim.phase == &"boss" and _sim.front_locked and bool(_st["lock"]["in_range"]) \
			and _sim.phase_real > 2.0, 90.0):
		_fail("never reached the locked fight")
		return false
	_sim.autopilot = null
	_sim.input(&"fire", false)
	_sim.rage = rage
	if _real:  # the autopilot may have used an item on the way: every slot ready for the shot
		for sl: Variant in _sim.get(&"skills").get(&"slots"):
			(sl as Dictionary)["cool"] = 0.0
	_real_s(0.4)
	return true


# ───────────────────────────── checks

func _check_impact(run: String) -> void:
	if not _impact_pos.is_finite():
		_fail("%s: no impact" % run)
		return
	var vp: Vector2 = _hud.safe_rect().size + _hud.safe_rect().position
	var sp: Vector2 = _cam.unproject_position(_impact_pos)
	var fy: float = sp.y / vp.y
	var under: PackedStringArray = []
	for rr: Rect2 in _hud.reserved_rects():
		if rr.has_point(sp):
			under.append(str(rr))
	print("RESULT impact %s screen=(%.0f,%.0f) frame_y=%.2f hud_cover=%d" % [run, sp.x, sp.y, fy, under.size()])
	if fy < CameraRig.FRAME_Y.x - 0.02 or fy > CameraRig.FRAME_Y.y + 0.02:
		_fail("%s: impact point outside FRAME_Y 20–74 %% (%.2f)" % [run, fy])
	if not under.is_empty():
		_fail("%s: a HUD widget covers the impact point %s" % [run, " ".join(under)])


## Kill-cam rules on the current frame: road ≥ 35 % from the bottom (analytic + pixels), look y ≤ 4.5, no letterbox.
func _check_killcam(run: String, img: Image) -> void:
	var pos: Vector3 = _cam.global_position
	var fwd: Vector3 = -_cam.global_transform.basis.z
	var look_y: float = _cam._look.y
	var frac: float = CameraRig.road_bottom_frac(pos, pos + fwd * 10.0, _cam.fov)
	var sky: int = 0
	var probes: int = 0
	var h: int = img.get_height()
	var w: int = img.get_width()
	for y: int in range(int(h * 0.66), h, 9):
		for x: int in range(4, w - 4, 23):
			var c: Color = img.get_pixel(x, y)
			probes += 1
			if c.b > c.r + 0.12 and c.b > 0.55 and c.g > 0.45:  # sky blue
				sky += 1
	var dark_rows: int = 0
	for y: int in [1, 3, h - 2, h - 4]:
		var lum: float = 0.0
		for x: int in range(0, w, 13):
			lum += img.get_pixel(x, y).get_luminance()
		if lum / float(w / 13 + 1) < 0.03:
			dark_rows += 1
	print("RESULT killcam %s road_frac=%.2f look_y=%.2f sky_in_bottom=%d/%d letterbox_rows=%d fov=%.1f" % [run, frac, look_y,
		sky, probes, dark_rows, _cam.fov])
	if frac < 0.35:
		_fail("%s: road below 35 %% of the screen (%.2f)" % [run, frac])
	if look_y > CameraRig.KILL_LOOK_Y_MAX + 0.05:
		_fail("%s: look-at y %.2f > 4.5" % [run, look_y])
	if sky > probes / 10:
		_fail("%s: sky in the bottom third (%d/%d)" % [run, sky, probes])
	if dark_rows > 0:
		_fail("%s: letterbox-like dark rows (%d)" % [run, dark_rows])


# ───────────────────────────── runs

func _run_skill(run: String) -> void:
	await _build(_seed)
	var rage: float = {"t1jam": 0.2, "t1": 0.2, "t3": 0.6, "t5": 1.0, "t5x": 1.0, "jump": 0.2, "drone": 0.2}[run]
	if run == "t1jam":  # jam: t1 = 분노 경적 (shoulder clear + boost), the only tier there
		if not _until(func() -> bool: return _sim.phase == &"jam" and _sim.phase_real > 4.0, 40.0):
			_fail("t1jam: no jam")
			return
		_sim.autopilot = null
		_sim.rage = rage
		_real_s(0.3)
	elif not _to_fight(rage):
		return
	_impact_seen = false
	_impact_pos = Vector3.INF
	if run == "t5":  # big HP left: no execute → 30 % + "한 번 더!"
		var v: Dictionary = _stub.target()
		v["hp"] = float(v["max_hp"]) * 0.9
	elif run == "t5x":
		_wait_min_kill()
		var v2: Dictionary = _stub.target()
		v2["hp"] = float(v2["max_hp"]) * 0.32
	await _grab(run, "pre")
	_cast({"t1jam": "1", "t1": "1", "t3": "3", "t5": "5", "t5x": "5", "jump": "item1", "drone": "item2"}[run])
	_advance_ticks(FRAME_TICKS)
	await _grab(run, "cast")
	if run == "t1jam":  # no skill_hit in the jam: the rage_horn tick is the impact
		for lab: String in ["+0.1", "+0.25", "+0.5"]:
			_real_s(0.12 if lab == "+0.1" else 0.15 if lab == "+0.25" else 0.25)
			await _grab(run, lab)
		_sheet(run)
		return
	if not _until(func() -> bool: return _impact_seen, 3.0):
		_fail("%s: no skill_hit" % run)
		_sheet(run)
		return
	await _grab(run, "impact")
	_check_impact(run)
	_real_s(0.06)
	await _grab(run, "+0.06")
	_real_s(0.24)
	await _grab(run, "+0.3")
	_real_s(0.7)
	var img: Image = await _grab(run, "+1.0")
	if run == "t5x":
		_check_killcam(run, img)
		_real_s(1.0)
		img = await _grab(run, "+2.0")
		_check_killcam(run + "+2", img)
	else:
		_real_s(0.6)
		await _grab(run, "end")
	_sheet(run)


func _run_finish(fin: String) -> void:
	await _build(_seed, fin)
	if not _to_fight(1.0 if _real else 0.4):
		return
	if _real:  # the finisher path of the sim: a MAX cast under the 처형선
		_wait_min_kill()
		var v: Dictionary = _stub.target()
		v["hp"] = float(v["max_hp"]) * 0.3
		_sim.rage = 1.0
		_cast("5")
		if not _until(func() -> bool: return _sim.phase == &"kill", 3.0):
			_fail("%s: the t5 execute did not kill" % fin)
			return
	else:
		_stub.finish_now(true)
	var marks: Array[float] = [0.05, 0.35, 0.7, 1.2, 1.8, 2.5]
	var t0: float = _sim.real_time
	for m: float in marks:
		_real_s(maxf(0.0, t0 + m - _sim.real_time))
		var img: Image = await _grab(fin, "+%.2f" % m)
		if m > 0.3:
			_check_killcam("%s@%.2f" % [fin, m], img)
	_sheet(fin)


## Past skills.minKillT of boss time (before it a skill never takes the last HP point).
func _wait_min_kill() -> void:
	var need: float = float(SkillCues.cfg().get("minKillT", 6.0)) + 0.3
	_until(func() -> bool: return float(_sim.get(&"boss_clock")) >= need, 12.0)
	_sim.rage = maxf(_sim.rage, 1.0)


## 분노 ring states: 0 / 1 / 3 / 5 칸 in the jam (only t1, 3 / MAX locked) and in the fight; full frames, the ring is
## cropped into the sheet.
func _run_ring() -> void:
	await _build(_seed)
	if not _until(func() -> bool: return _sim.phase == &"jam" and _sim.phase_real > 2.0, 30.0):
		_fail("ring: no jam")
		return
	for r: float in [0.0, 0.2, 0.6, 1.0]:
		_sim.rage = r
		_real_s(0.3)
		await _grab_crop("ring", "jam_%d" % roundi(r * 5.0))
	if not _to_fight(0.0):
		return
	for r2: float in [0.0, 0.2, 0.6, 1.0]:
		_sim.rage = r2
		_real_s(0.3)
		await _grab_crop("ring", "fight_%d" % roundi(r2 * 5.0))
	_sheet_crops("ring")


var _crops: Array[Image] = []


func _grab_crop(run: String, label: String) -> void:
	var img: Image = await _grab(run, label)
	_frames.pop_back()
	_labels.remove_at(_labels.size() - 1)
	var k: float = float(_size.x) / 540.0
	var safe: Rect2 = _hud.safe_rect()
	var r := Rect2i(roundi((safe.end.x - 330.0) * k), roundi((safe.end.y - 330.0) * k), roundi(330.0 * k), roundi(330.0 * k))
	r = r.intersection(Rect2i(Vector2i.ZERO, img.get_size()))
	_crops.append(img.get_region(r))
	_labels.append(label)


func _sheet_crops(run: String) -> void:
	if _crops.is_empty():
		return
	var cw: int = _crops[0].get_width()
	var ch: int = _crops[0].get_height()
	var cols: int = 4
	var rows: int = ceili(float(_crops.size()) / float(cols))
	var sheet := Image.create(cols * (cw + 4), rows * (ch + 4), false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.1, 0.1, 0.12))
	for i: int in _crops.size():
		var f: Image = _crops[i]
		f.convert(Image.FORMAT_RGBA8)
		sheet.blit_rect(f, Rect2i(Vector2i.ZERO, f.get_size()), Vector2i((i % cols) * (cw + 4), (i / cols) * (ch + 4)))
	sheet.save_png(_out.path_join("%s_sheet.png" % run))
	print("RESULT sheet %s %s" % [run, ",".join(_labels)])
	_crops.clear()
	_labels.clear()


## Item buttons: ready, cooling 50 %, cooling 100 %, unusable (t5 cast = busy); bottom crops (both thumbs).
func _run_items() -> void:
	await _build(_seed)
	if not _to_fight(1.0):
		return
	await _grab_bottom("items", "ready")
	if _real:
		var slots: Array = _sim.get(&"skills").get(&"slots")
		for sl: Variant in slots:
			(sl as Dictionary)["cool"] = float((sl as Dictionary)["cool_max"]) * (0.5 if str((sl as Dictionary)["id"]) == "mv_jump" else 1.0)
	else:
		_stub._cool["mv_jump"] = 3.0
		_stub._cool["mv_drone"] = 12.0
	_real_s(0.1)
	await _grab_bottom("items", "cool")
	_cast("5")
	_real_s(0.15)
	await _grab_bottom("items", "busy")
	_sheet_crops("items")
	print("RESULT item_sizes_pt %s" % JSON.stringify(_hud.item_sizes_pt()))
	for n: String in _hud.item_sizes_pt():
		if float(_hud.item_sizes_pt()[n]) < 64.0 - 0.01:
			_fail("items: %s below 64 pt" % n)


func _grab_bottom(run: String, label: String) -> void:
	var img: Image = await _grab(run, label)
	_frames.pop_back()
	_labels.remove_at(_labels.size() - 1)
	var k: float = float(_size.x) / 540.0
	var safe: Rect2 = _hud.safe_rect()
	var r := Rect2i(0, roundi((safe.end.y - 330.0) * k), _size.x, roundi(330.0 * k))
	r = r.intersection(Rect2i(Vector2i.ZERO, img.get_size()))
	var c: Image = img.get_region(r)
	c.resize(c.get_width() / 2, c.get_height() / 2, Image.INTERPOLATE_BILINEAR)
	_crops.append(c)
	_labels.append(label)
