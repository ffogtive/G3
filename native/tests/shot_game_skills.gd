extends SceneTree
## Xvfb shots of every skill moment on the integrated game.tscn (view/game.gd wiring, not the shot_skills rig), driven
## by real touches on the HUD rects (tests/skills_touch_run.gd — the same run as test_e2e_touch_skills):
##   xvfb-run -a -s "-screen 0 1280x1024x24" godot47 --path native --rendering-method mobile --audio-driver Dummy \
##       -s res://tests/shot_game_skills.gd -- --out=/abs/dir [--seed=1007] [--size=585x1266] [--fallback]
## Saves <n>_<moment>.png (jam_t1_cast … result) and skills_sheet.png (all frames, half size, labelled order in the
## RESULT lines). Exit 0 = the run reached the result with every cast · 1 = a step failed · 2 = cannot render.
## r3 U2 / U4: a second autopilot run on the same seed adds prelock_ready / prelock_t1 (the boss-phase 충격파 before the
## front lock: face 충격파, the orange 분노 tag on the reticle, then the cast with banner '충격파!!'), combo_c10 (badge ×10 + '따다닥!' beside it) and combo_c20
## (badge ×20, 펑크, the stun window 약점) frames. Every frame also checks the damage pops: all inside the safe rect (no
## cut glyph) and ≤ 2 live per villain (RESULT pops …; a violation fails the shot).

const Run := preload("res://tests/skills_touch_run.gd")
const E2E := preload("res://tests/test_e2e_touch_skills.gd")

var _out: String = ""
var _seed: int = 1007
var _size := Vector2i(585, 1266)
var _fallback: bool = false
var _vp: SubViewport
var _g: Game
var _frames: Array[Image] = []
var _n: int = 0
var _pop_bad: PackedStringArray = []


func _initialize() -> void:
	for a: String in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.trim_prefix("--").split("=", true, 1)
		var v: String = kv[1] if kv.size() > 1 else "1"
		match kv[0]:
			"out":
				_out = v
			"seed":
				_seed = v.to_int()
			"fallback":
				_fallback = true
			"size":
				var p: PackedStringArray = v.split("x")
				_size = Vector2i(p[0].to_int(), p[1].to_int())
	_main.call_deferred()


func _main() -> void:
	if _out.is_empty() or DisplayServer.get_name() == "headless":
		print("FAIL shot_game_skills: need --out=<dir> and a real display (xvfb-run, no --headless)")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	_vp = SubViewport.new()
	_vp.size = _size
	_vp.size_2d_override = Vector2i(540, roundi(540.0 * float(_size.y) / float(_size.x)))
	_vp.size_2d_override_stretch = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.audio_listener_enable_3d = false
	root.add_child(_vp)
	_g = E2E.make(self, _vp, _fallback, _seed)
	await process_frame
	await process_frame
	var r = Run.new(_g, _vp)
	r.moment = _shot
	await r.run()
	var casts: PackedStringArray = []
	for k: String in ["jam_t1", "t1", "jump", "t3", "drone", "t5", "finisher", "skip"]:
		var d: Dictionary = r.notes.get(k, {})
		casts.append("%s=%s" % [k, bool(d.get("ok", false))])
	var ok: bool = r.errors.is_empty() and not ",".join(casts).contains("=false")
	_g.queue_free()  # its HUD (result card) would sit over the next run's frames
	await process_frame
	var cerr: PackedStringArray = await _combo_segment()
	ok = ok and cerr.is_empty() and _pop_bad.is_empty()
	print("RESULT r3 frames: errors [%s] pop violations [%s]" % [", ".join(cerr), "; ".join(_pop_bad)])
	_sheet()
	print("RESULT traffic=%s casts %s topped [%s] errors [%s]" % ["fallback" if _fallback else "native", " ".join(casts),
		"; ".join(r.topped), ", ".join(r.errors)])
	print("RESULT ok=%s" % ok)
	quit(0 if ok else 1)


func _shot(name: String) -> void:
	for i: int in 2:
		_g.render_step(0.0)
		await process_frame
	await RenderingServer.frame_post_draw
	var img: Image = _vp.get_texture().get_image()
	_n += 1
	var file: String = "%02d_%s.png" % [_n, name]
	img.save_png(_out.path_join(file))
	_frames.append(img)
	var sk: Dictionary = _g.st.get("skills", {}) if _g.st.get("skills") is Dictionary else {}
	print("RESULT shot %s phase=%s t=%.2f segs=%d next=%d active=%s fx=%s cam_fin=%s" % [file, _g.phase, _g.sim.real_time,
		int(sk.get("segs", 0)), int(sk.get("next_tier", 0)), str((sk.get("active", {}) as Dictionary).get("id", "")),
		JSON.stringify(_g.fx.counts()), _g.camera.finish_id])
	# r3 U4: no pop cut at the screen edge, ≤ 2 live pops per villain
	var sr: Rect2 = _g.hud.safe_rect()
	var out: int = 0
	var rects: Array[Rect2] = _g.hud.pops.pop_rects()
	for pr: Rect2 in rects:
		if not sr.encloses(pr):
			out += 1
	var per: Dictionary = {}
	for v: Variant in _g.st.get("villains", []):
		var vid: int = int((v as Dictionary).get("id", -1))
		per["v%d" % vid] = _g.hud.pops.live_count("v%d" % vid)
	var worst: int = 0
	for k: String in per:
		worst = maxi(worst, int(per[k]))
	print("RESULT pops %s: %d drawn, %d outside the safe rect, live per villain %s [%s] combo %s chip '%s' rage_face %s tag %s" % [file, rects.size(),
		out, JSON.stringify(per), ", ".join(_g.hud.pops.texts_pops(true)), JSON.stringify(_g.hud.combo_view()), _g.hud.neck_chip_text(),
		_g.hud.rage_face_label(), _g.hud.reticle.rage_tag])
	if out > 0 or worst > 2:
		_pop_bad.append("%s out=%d per=%s" % [file, out, JSON.stringify(per)])


## r3 U2 frames on a fresh autopilot run: the pre-lock 충격파, the ×10 and ×20 combo milestones.
func _combo_segment() -> PackedStringArray:
	var err: PackedStringArray = []
	var g: Game = E2E.make(self, _vp, _fallback, _seed)
	g.hud.debug_safe_pt = Vector2(59, 34)
	g.hud.apply_safe_area()
	await process_frame
	await process_frame
	_g = g
	var evs: Array[Dictionary] = []
	g.event_tap = func(e: Dictionary) -> void: evs.append(e)
	var ticks: int = 0
	while ticks < 120 * 90 and not (g.phase == &"boss" and not g.sim.front_locked and _near_villain(g, 55.0)):
		g.advance_ticks(6)
		ticks += 6
	if g.phase == &"boss" and not g.sim.front_locked:
		g.sim.add_rage(maxf(0.0, 0.21 - g.sim.rage))
		g.advance_ticks(48)  # the reticle (and its tag) has faded in
		g.sim.add_rage(maxf(0.0, 0.21 - g.sim.rage))
		await _shot("prelock_ready")  # face 충격파 + the orange 분노 tag on the villain before the lock
		evs.clear()
		g.sim.input(&"rage")
		var seen: bool = false
		for k: int in 60:
			g.advance_ticks(2)
			for e: Dictionary in evs:
				seen = seen or (str(e.get("type", "")) == "skill_start" and str(e.get("id", "")) == "t1_wave")
			if seen:
				break
		g.advance_ticks(18)
		await _shot("prelock_t1")
		if not seen:
			err.append("prelock t1_wave not cast")
	else:
		err.append("no pre-lock boss frame (phase %s, locked %s)" % [g.phase, g.sim.front_locked])
	for want: String in ["c10", "c20"]:
		evs.clear()
		var hit: bool = false
		ticks = 0
		while ticks < 120 * 60 and not hit and g.phase == &"boss":
			g.advance_ticks(2)
			ticks += 2
			for e: Dictionary in evs:
				hit = hit or (str(e.get("type", "")) == "combo_milestone" and str(e.get("id", "")) == want)
		if not hit:
			err.append("no %s milestone (phase %s)" % [want, g.phase])
			continue
		g.advance_ticks(30 if want == "c10" else 38)
		await _shot("combo_%s" % want)
	g.queue_free()
	await process_frame
	return err


static func _near_villain(g: Game, m: float) -> bool:
	for v: Variant in g.st.get("villains", []):
		var d: Dictionary = v
		if bool(d.get("alive", false)) and absf(float(d.get("s", 0.0)) - g.player.s) <= m:
			return true
	return false


## All frames side by side at third size, rows of 6.
func _sheet() -> void:
	if _frames.is_empty():
		return
	var w: int = _size.x / 3
	var h: int = _size.y / 3
	var cols: int = 6
	var rows: int = ceili(float(_frames.size()) / float(cols))
	var sheet := Image.create(w * cols, h * rows, false, Image.FORMAT_RGB8)
	sheet.fill(Color(0.1, 0.1, 0.12))
	for i: int in _frames.size():
		var im: Image = _frames[i].duplicate() as Image
		im.convert(Image.FORMAT_RGB8)
		im.resize(w, h, Image.INTERPOLATE_BILINEAR)
		sheet.blit_rect(im, Rect2i(0, 0, w, h), Vector2i((i % cols) * w, (i / cols) * h))
	sheet.save_png(_out.path_join("skills_sheet.png"))
