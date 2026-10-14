extends Node3D
## Spike scene: highway strip + 20 procedural voxel cars, shadows, sky/fog/SSAO/glow, 3/4 camera.
## User args (after `--`):  --shot=<png path>  --frames=<N>  (defaults: no shot, 60 frames)
## Prints RESULT lines and exits with 0 on success, 1 on failure (blank image / missing nodes).

const VoxelCar := preload("res://voxel_car.gd")

const LANE_W := 3.5
const LANES := [-3.5, 0.0, 3.5]   # x of lane centres; lane 0 (x=-3.5) = 1차선 (passing lane)
const PALETTE := [
	Color(0.90, 0.22, 0.20), Color(0.98, 0.78, 0.18), Color(0.20, 0.50, 0.90),
	Color(0.95, 0.95, 0.95), Color(0.30, 0.72, 0.38), Color(0.98, 0.52, 0.16),
	Color(0.55, 0.35, 0.80), Color(0.30, 0.80, 0.85),
]

var shot_path := ""
var total_frames := 60
var frame := 0
var t_start := 0
var done := false
var cars: Array[Node3D] = []
var car_speed: Array[float] = []
var headless := false
var opt := {"fog": 0.0015, "ambient": 0.45, "sun": 1.5, "ssao": 1.0, "glow": 1.0}


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shot="):
			shot_path = a.substr(7)
		elif a.begins_with("--frames="):
			total_frames = int(a.substr(9))
		else:
			for k in opt.keys():
				if a.begins_with("--%s=" % k):
					opt[k] = float(a.split("=")[1])
	headless = DisplayServer.get_name() == "headless"
	_build_world()
	var method := "?"
	if RenderingServer.has_method("get_current_rendering_method"):
		method = RenderingServer.call("get_current_rendering_method")
	print("RESULT display=%s method=%s driver=%s adapter=%s api=%s" % [
		DisplayServer.get_name(), method,
		RenderingServer.call("get_current_rendering_driver_name") if RenderingServer.has_method("get_current_rendering_driver_name") else "?",
		RenderingServer.get_video_adapter_name(), RenderingServer.get_video_adapter_api_version()])


func _build_world() -> void:
	# --- Environment -------------------------------------------------------------
	var env := Environment.new()
	var sky := Sky.new()
	var psm := ProceduralSkyMaterial.new()
	psm.sky_top_color = Color(0.32, 0.55, 0.88)
	psm.sky_horizon_color = Color(0.78, 0.85, 0.93)
	psm.ground_horizon_color = Color(0.78, 0.85, 0.93)
	psm.ground_bottom_color = Color(0.35, 0.45, 0.35)
	sky.sky_material = psm
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = opt["ambient"]
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_white = 6.0
	env.ssao_enabled = opt["ssao"] > 0.0          # Forward+ only (ignored elsewhere)
	env.ssao_radius = 1.5
	env.ssao_intensity = 2.5
	env.glow_enabled = opt["glow"] > 0.0          # Forward+/Mobile (Compatibility 4.4: ignored)
	env.glow_intensity = 0.7
	env.glow_bloom = 0.05
	env.glow_hdr_threshold = 1.0
	env.fog_enabled = opt["fog"] > 0.0
	env.fog_light_color = Color(0.78, 0.85, 0.93)
	env.fog_density = opt["fog"]
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	# --- Sun --------------------------------------------------------------------
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-48, 140, 0)   # shadows fall toward camera-left
	sun.light_color = Color(1.0, 0.95, 0.86)
	sun.light_energy = opt["sun"]
	sun.shadow_enabled = true
	sun.shadow_blur = 1.2
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = 70.0
	add_child(sun)

	# --- Road + verge (static voxel boxes in one mesh) ---------------------------
	var items := []
	var asphalt := Color(0.33, 0.34, 0.37)
	items.append([Vector3(0, -0.1, -40), Vector3(LANE_W * 3, 0.2, 140), asphalt])
	items.append([Vector3(7.0, -0.12, -40), Vector3(3.5, 0.2, 140), Color(0.40, 0.41, 0.43)])   # shoulder
	# Median barrier + yellow line on the left
	items.append([Vector3(-6.0, 0.4, -40), Vector3(0.6, 0.8, 140), Color(0.78, 0.78, 0.76)])
	items.append([Vector3(-5.05, 0.005, -40), Vector3(0.14, 0.02, 140), Color(0.98, 0.80, 0.15)])
	items.append([Vector3(5.25, 0.005, -40), Vector3(0.14, 0.02, 140), Color(0.95, 0.95, 0.95)])
	# Dashed lane lines
	for z in range(-110, 30, 9):
		for x in [-1.75, 1.75]:
			items.append([Vector3(x, 0.005, z), Vector3(0.14, 0.02, 3.0), Color(0.95, 0.95, 0.95)])
	# Crossy-style striped grass + voxel trees
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for z in range(-110, 30, 2):
		var g := Color(0.47, 0.76, 0.33) if (z / 2) % 2 == 0 else Color(0.43, 0.71, 0.30)
		items.append([Vector3(15.0, -0.15, z), Vector3(12.5, 0.3, 2.0), g])
		items.append([Vector3(-13.0, -0.15, z), Vector3(13.4, 0.3, 2.0), g])
	for i in 40:
		var side := 1.0 if i % 2 == 0 else -1.0
		var tx := side * rng.randf_range(10.0, 19.0)
		var tz := rng.randf_range(-105.0, 25.0)
		var hgt := rng.randf_range(1.0, 2.2)
		items.append([Vector3(tx, hgt * 0.5, tz), Vector3(0.5, hgt, 0.5), Color(0.45, 0.30, 0.18)])
		items.append([Vector3(tx, hgt + 0.7, tz), Vector3(1.6, 1.4, 1.6), Color(0.22, 0.55, 0.25)])
		items.append([Vector3(tx, hgt + 1.65, tz), Vector3(1.0, 0.6, 1.0), Color(0.28, 0.62, 0.30)])
	var road := MeshInstance3D.new()
	road.name = "Road"
	road.mesh = VoxelCar.build_boxes_mesh(items)
	add_child(road)

	# --- 20 cars: jam behind the villain in lane 0, lighter traffic in lanes 1-2 ----
	var mesh_cache := {}
	var lane_z := [-34.0, -30.0, -26.0]
	for i in 20:
		var villain := (i == 0)
		var lane: int = 0 if (i < 9) else (1 + (i % 2))
		var col: Color = Color(0.08, 0.08, 0.09) if villain else PALETTE[i % PALETTE.size()]
		var key := str(col) + str(villain)
		if not mesh_cache.has(key):
			mesh_cache[key] = VoxelCar.build_car_mesh(col, villain)
		var car := MeshInstance3D.new()
		car.name = "Villain" if villain else "Car%02d" % i
		car.mesh = mesh_cache[key]
		var gap := 5.6 if lane == 0 else rng.randf_range(8.0, 14.0)
		car.position = Vector3(LANES[lane] + rng.randf_range(-0.15, 0.15), 0, lane_z[lane])
		lane_z[lane] += gap
		add_child(car)
		cars.append(car)
		car_speed.append(1.2 if lane == 0 else rng.randf_range(4.0, 7.0))
	add_to_group("spike_main")

	# --- 3/4 top-down camera ----------------------------------------------------
	var cam := Camera3D.new()
	cam.name = "Cam"
	cam.fov = 38.0
	cam.position = Vector3(10.0, 26.0, 18.0)
	add_child(cam)
	cam.look_at(Vector3(0.5, 0.0, -14.0), Vector3.UP)
	cam.current = true


func _process(_delta: float) -> void:
	if done:
		return
	frame += 1
	# fixed-step crawl so every renderer produces the same picture regardless of speed
	for i in cars.size():
		cars[i].position.z -= car_speed[i] * (1.0 / 60.0)
	if frame == 10:
		t_start = Time.get_ticks_usec()
	if frame >= total_frames:
		done = true
		_finish()


func _finish() -> void:
	var ms := float(Time.get_ticks_usec() - t_start) / 1000.0 / float(max(1, total_frames - 10))
	print("RESULT frames=%d ms_per_frame=%.2f fps=%.1f" % [total_frames, ms, 1000.0 / maxf(ms, 0.001)])
	var ok := cars.size() == 20 and get_node_or_null("Sun") != null and (get_node("Sun") as DirectionalLight3D).shadow_enabled
	if not headless and shot_path != "":
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var err := img.save_png(shot_path)
		# blank-frame guard: luminance mean / stddev on a 32x32 sample grid
		var s := 0.0
		var s2 := 0.0
		var cnt := 0
		for yy in 32:
			for xx in 32:
				var c := img.get_pixel(int(xx * img.get_width() / 32.0), int(yy * img.get_height() / 32.0))
				var l := c.get_luminance()
				s += l
				s2 += l * l
				cnt += 1
		var mean := s / cnt
		var sd := sqrt(maxf(0.0, s2 / cnt - mean * mean))
		print("RESULT shot=%s err=%d size=%s lum_mean=%.3f lum_sd=%.3f" % [shot_path, err, str(img.get_size()), mean, sd])
		ok = ok and err == OK and sd > 0.05 and mean > 0.05
	print("RESULT ok=%s" % ok)
	get_tree().quit(0 if ok else 1)
