extends SceneTree
## Xvfb render smoke shot (NATIVE_PORT 4-2 T2 precursor, M1-0 gate: "Mobile shot passes the blank guard").
##   xvfb-run -a -s "-screen 0 1280x1024x24" godot47 --path native --rendering-method mobile \
##       --audio-driver Dummy -s res://tests/shot.gd -- --shot=/abs/path/smoke.png [--frames=8]
##       [--min-sd=0.05] [--expect-method=mobile]
## Builds a tiny lit voxel-road scene (sun + shadows, fog, 12 boxes), renders N frames, saves the
## viewport PNG and fails (exit 1) when the image is blank (luminance sd <= min-sd) or the renderer is
## not the expected one. Exit 2 = cannot render (headless display / bad args).

const CfgScript := preload("res://core/cfg.gd")

var _shot_path: String = ""
var _frames: int = 8
var _min_sd: float = 0.05
var _expect_method: String = "mobile"


func _initialize() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--shot="):
			_shot_path = arg.trim_prefix("--shot=")
		elif arg.begins_with("--frames="):
			_frames = maxi(1, arg.trim_prefix("--frames=").to_int())
		elif arg.begins_with("--min-sd="):
			_min_sd = arg.trim_prefix("--min-sd=").to_float()
		elif arg.begins_with("--expect-method="):
			_expect_method = arg.trim_prefix("--expect-method=")
	_main.call_deferred()


func _main() -> void:
	if _shot_path.is_empty():
		print("FAIL shot: missing --shot=<png path>")
		quit(2)
		return
	if DisplayServer.get_name() == "headless":
		print("FAIL shot: headless display server cannot render; run under xvfb-run without --headless")
		quit(2)
		return
	if _shot_path.is_relative_path() and not _shot_path.contains("://"):
		_shot_path = OS.get_environment("PWD").path_join(_shot_path)
	_build_scene()
	var method: String = RenderingServer.get_current_rendering_method()
	print("RESULT display=%s method=%s driver=%s adapter=%s api=%s godot=%s" % [
		DisplayServer.get_name(), method, RenderingServer.get_current_rendering_driver_name(),
		RenderingServer.get_video_adapter_name(), RenderingServer.get_video_adapter_api_version(),
		Engine.get_version_info().string])
	print("INFO shot: Traffic ext %s" % ("loaded" if ClassDB.class_exists(&"Traffic") else "absent"))

	var t0: int = Time.get_ticks_msec()
	for i: int in _frames:
		await process_frame
	await RenderingServer.frame_post_draw
	var ms_per_frame: float = float(Time.get_ticks_msec() - t0) / float(_frames + 1)
	var draws: int = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var prims: int = int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))

	var img: Image = root.get_texture().get_image()
	if img == null or img.is_empty():
		print("FAIL shot: viewport returned no image")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_shot_path.get_base_dir())
	var err: Error = img.save_png(_shot_path)
	var stats: Vector2 = _luminance_mean_sd(img)
	var ok: bool = err == OK and stats.y > _min_sd
	if not _expect_method.is_empty() and method != _expect_method:
		print("FAIL shot: renderer %s, expected %s" % [method, _expect_method])
		ok = false
	print("RESULT shot=%s err=%d size=%s lum_mean=%.3f lum_sd=%.3f min_sd=%.3f draws=%d prims=%d ms_per_frame=%.0f" % [
		_shot_path, err, str(img.get_size()), stats.x, stats.y, _min_sd, draws, prims, ms_per_frame])
	print("RESULT ok=%s" % ok)
	quit(0 if ok else 1)


func _build_scene() -> void:
	var world := Node3D.new()
	world.name = "SmokeWorld"
	root.add_child(world)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color8(0xbf, 0xe4, 0xff)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color8(0xbf, 0xe4, 0xff)
	env.ambient_light_energy = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.fog_enabled = true
	env.fog_light_color = Color8(0xbf, 0xe4, 0xff)
	env.fog_density = 0.004
	var we := WorldEnvironment.new()
	we.environment = env
	world.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, -30.0, 0.0)
	sun.light_energy = 1.4
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = 80.0
	world.add_child(sun)

	var road := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(18.0, 240.0)
	road.mesh = plane
	road.material_override = _mat(Color8(0x55, 0x58, 0x60))
	road.position = Vector3(0.0, 0.0, -100.0)
	world.add_child(road)

	var palette: Array[Color] = [Color8(0xe6, 0x3a, 0x33), Color8(0xf5, 0xc7, 0x2e), Color8(0x33, 0x80, 0xe6),
		Color8(0xf2, 0xf2, 0xf2), Color8(0x4d, 0xb8, 0x61), Color8(0xf5, 0x85, 0x29)]
	for i: int in 12:
		var lane: int = i % 4
		var car := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(1.9, 1.4, 4.4)
		car.mesh = box
		car.material_override = _mat(palette[i % palette.size()])
		var row: float = floorf(float(i) / 4.0)
		car.position = Vector3(CfgScript.lane_x(lane), 0.7, -8.0 - 9.0 * row - 2.0 * float(lane))
		world.add_child(car)

	var cam := Camera3D.new()
	cam.fov = 55.0
	cam.position = Vector3(6.0, 14.0, 14.0)
	world.add_child(cam)
	cam.look_at(Vector3(0.0, 0.0, -14.0), Vector3.UP)
	cam.make_current()


func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.9
	return m


## x = mean, y = standard deviation of Rec.709 luminance over a 4-px grid.
func _luminance_mean_sd(img: Image) -> Vector2:
	var n: int = 0
	var sum: float = 0.0
	var sum_sq: float = 0.0
	for y: int in range(0, img.get_height(), 4):
		for x: int in range(0, img.get_width(), 4):
			var c: Color = img.get_pixel(x, y)
			var l: float = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			sum += l
			sum_sq += l * l
			n += 1
	var mean: float = sum / float(maxi(n, 1))
	return Vector2(mean, sqrt(maxf(sum_sq / float(maxi(n, 1)) - mean * mean, 0.0)))
