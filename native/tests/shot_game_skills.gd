extends SceneTree
## Xvfb shots of every skill moment on the integrated game.tscn (view/game.gd wiring, not the shot_skills rig), driven
## by real touches on the HUD rects (tests/skills_touch_run.gd — the same run as test_e2e_touch_skills):
##   xvfb-run -a -s "-screen 0 1280x1024x24" godot47 --path native --rendering-method mobile --audio-driver Dummy \
##       -s res://tests/shot_game_skills.gd -- --out=/abs/dir [--seed=1007] [--size=585x1266] [--fallback]
## Saves <n>_<moment>.png (jam_t1_cast … result) and skills_sheet.png (all frames, half size, labelled order in the
## RESULT lines). Exit 0 = the run reached the result with every cast · 1 = a step failed · 2 = cannot render.

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
