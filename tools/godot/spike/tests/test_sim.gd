extends SceneTree
## Headless test:  godot --headless --path <proj> -s res://tests/test_sim.gd
## Exit code 0 = all pass, 1 = any failure.

const VoxelCar := preload("res://voxel_car.gd")
const JamSim := preload("res://jam_sim.gd")

var fails := 0


func check(cond: bool, msg: String) -> void:
	if cond:
		print("PASS ", msg)
	else:
		fails += 1
		printerr("FAIL ", msg)


func _initialize() -> void:
	# 1) Voxel mesh builder: counts + clockwise (Godot front-face) winding on every triangle.
	var d: Dictionary = VoxelCar.build_car_arrays(Color(0.9, 0.2, 0.2), false)
	var body: Array = d["body"]
	var verts: PackedVector3Array = body[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = body[Mesh.ARRAY_NORMAL]
	var cols: PackedColorArray = body[Mesh.ARRAY_COLOR]
	var lamp_verts: PackedVector3Array = (d["lamps"] as Array)[Mesh.ARRAY_VERTEX]
	var total_boxes: int = d["boxes"]
	check(verts.size() + lamp_verts.size() == total_boxes * 36, "36 verts per box (%d boxes)" % total_boxes)
	check(cols.size() == verts.size() and norms.size() == verts.size(), "colour+normal per vertex")
	var bad := 0
	for i in range(0, verts.size(), 3):
		var a := verts[i]
		var b := verts[i + 1]
		var c := verts[i + 2]
		if (b - a).cross(c - a).dot(norms[i]) >= 0.0:
			bad += 1
	check(bad == 0, "all %d triangles clockwise wrt outward normal (bad=%d)" % [verts.size() / 3, bad])
	var aabb_min := Vector3.INF
	var aabb_max := -Vector3.INF
	for v in verts:
		aabb_min = aabb_min.min(v)
		aabb_max = aabb_max.max(v)
	var size := aabb_max - aabb_min
	check(size.z > 4.0 and size.z < 4.8 and size.x > 1.7 and size.x < 2.2, "car AABB sane %s" % str(size))
	var mesh: ArrayMesh = VoxelCar.build_car_mesh(Color.BLUE, true)
	check(mesh.get_surface_count() == 2, "car mesh has body+lamp surfaces")

	# 2) Jam sim: villain compresses lane 1, release produces a backward-propagating wave.
	var sim = JamSim.new(20)
	var dt := 0.05
	var jam_speed := 0.0
	while sim.t < 90.0:
		sim.step(dt)
		if absf(sim.t - 39.0) < dt * 0.5:
			jam_speed = sim.mean_follower_speed()
	check(sim.min_gap > 0.0, "no collisions (min gap %.2f m)" % sim.min_gap)
	check(jam_speed < 10.0, "platoon jammed to villain speed before release (%.1f m/s)" % jam_speed)
	var rt: PackedFloat64Array = sim.release_time
	var mono := true
	var all_released := true
	for i in range(1, 20):
		if rt[i] < 0.0:
			all_released = false
		elif i > 1 and rt[i] < rt[i - 1]:
			mono = false
	check(all_released, "every follower back above 72 km/h within 50 s of release")
	check(mono, "release wave propagates front->back (monotonic release times)")
	if all_released:
		print("INFO release wave: car1 %.1fs .. car19 %.1fs after release" % [rt[1] - sim.release_t, rt[19] - sim.release_t])

	print("SUMMARY fails=%d" % fails)
	quit(1 if fails > 0 else 0)
