extends RefCounted
## Procedural Crossy-Road-style voxel geometry: boxes with per-vertex colors -> ArrayMesh.
## Two surfaces per car: 0 = lit body (vertex colour albedo), 1 = lamps (vertex colour * emission, glows).

# Face table: outward normal n, tangents u, v with u.cross(v) == n.
const FACES := [
	[Vector3.RIGHT, Vector3.UP, Vector3.BACK],
	[Vector3.LEFT, Vector3.BACK, Vector3.UP],
	[Vector3.UP, Vector3.BACK, Vector3.RIGHT],
	[Vector3.DOWN, Vector3.RIGHT, Vector3.BACK],
	[Vector3.BACK, Vector3.RIGHT, Vector3.UP],
	[Vector3.FORWARD, Vector3.UP, Vector3.RIGHT],
]

static var _body_mat: StandardMaterial3D
static var _lamp_mat: ShaderMaterial

## Appends one axis-aligned box. Godot front faces are CLOCKWISE seen from outside,
## so each quad q0..q3 (CCW around n) is emitted as (q0,q2,q1) + (q0,q3,q2).
static func add_box(st: SurfaceTool, center: Vector3, size: Vector3, color: Color) -> void:
	var h := size * 0.5
	for f in FACES:
		var n: Vector3 = f[0]
		var u: Vector3 = f[1]
		var v: Vector3 = f[2]
		var hn: float = absf(n.dot(h))
		var hu: float = absf(u.dot(h))
		var hv: float = absf(v.dot(h))
		var c := center + n * hn
		var q0 := c - u * hu - v * hv
		var q1 := c + u * hu - v * hv
		var q2 := c + u * hu + v * hv
		var q3 := c - u * hu + v * hv
		# Cheap baked "voxel AO": bottom faces darker, top faces slightly brighter.
		var shade := 1.0
		if n == Vector3.DOWN:
			shade = 0.55
		elif n == Vector3.UP:
			shade = 1.06
		var col := Color(color.r * shade, color.g * shade, color.b * shade, color.a)
		for p in [q0, q2, q1, q0, q3, q2]:
			st.set_color(col)
			st.set_normal(n)
			st.add_vertex(p)


## Returns {"body": Array(arrays), "lamps": Array(arrays), "boxes": int}. Car faces -Z.
static func build_car_arrays(body_color: Color, villain: bool = false) -> Dictionary:
	var body := SurfaceTool.new()
	body.begin(Mesh.PRIMITIVE_TRIANGLES)
	var lamps := SurfaceTool.new()
	lamps.begin(Mesh.PRIMITIVE_TRIANGLES)
	var boxes := 0

	var glass := Color(0.16, 0.22, 0.30)
	var tyre := Color(0.10, 0.10, 0.11)
	var hub := Color(0.75, 0.75, 0.78)
	var trim := Color(0.22, 0.22, 0.24)

	var length := 4.2
	var width := 1.8
	var body_h := 0.7
	var cabin_h := 0.42
	if villain:
		length = 4.6
		width = 1.95
		body_h = 0.85
		cabin_h = 0.55

	var body_y := 0.2 + body_h * 0.5
	var top := 0.2 + body_h
	# Main hull
	add_box(body, Vector3(0, body_y, 0), Vector3(width, body_h, length), body_color); boxes += 1
	# Glass band + roof (the floating-roof Crossy look)
	var cab_len := length * 0.5
	var cab_z := length * 0.06
	add_box(body, Vector3(0, top + cabin_h * 0.5, cab_z), Vector3(width * 0.88, cabin_h, cab_len), glass); boxes += 1
	add_box(body, Vector3(0, top + cabin_h + 0.08, cab_z), Vector3(width * 0.92, 0.16, cab_len * 1.06), body_color.lightened(0.08)); boxes += 1
	# Bumpers
	add_box(body, Vector3(0, 0.32, -length * 0.5 - 0.06), Vector3(width * 1.02, 0.2, 0.14), trim); boxes += 1
	add_box(body, Vector3(0, 0.32, length * 0.5 + 0.06), Vector3(width * 1.02, 0.2, 0.14), trim); boxes += 1
	# Wheels + hubs
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var wc := Vector3(sx * (width * 0.5 - 0.02), 0.3, sz * length * 0.31)
			add_box(body, wc, Vector3(0.32, 0.6, 0.6), tyre); boxes += 1
			add_box(body, wc + Vector3(sx * 0.03, 0, 0), Vector3(0.32, 0.24, 0.24), hub); boxes += 1
	# Plate
	add_box(body, Vector3(0, 0.5, length * 0.5 + 0.01), Vector3(0.5, 0.14, 0.04), Color(0.95, 0.95, 0.92)); boxes += 1
	# Lamps (emissive surface): head (front, -Z) and tail (rear, +Z)
	for sx in [-1.0, 1.0]:
		add_box(lamps, Vector3(sx * width * 0.33, top - 0.16, -length * 0.5 - 0.02), Vector3(0.38, 0.16, 0.06), Color(1.0, 0.95, 0.75)); boxes += 1
		var tail := Color(1.0, 0.12, 0.08)
		add_box(lamps, Vector3(sx * width * 0.36, top - 0.16, length * 0.5 + 0.02), Vector3(0.34, 0.16, 0.06), tail); boxes += 1
	if villain:
		# Hazard bar on the roof -> reads as "the villain" from the top-down camera
		add_box(lamps, Vector3(0, top + cabin_h + 0.22, cab_z), Vector3(width * 0.6, 0.12, 0.3), Color(1.0, 0.55, 0.0)); boxes += 1

	return {"body": body.commit_to_arrays(), "lamps": lamps.commit_to_arrays(), "boxes": boxes}


static func materials() -> Array:
	if _body_mat == null:
		_body_mat = StandardMaterial3D.new()
		_body_mat.vertex_color_use_as_albedo = true
		_body_mat.vertex_color_is_srgb = true
		_body_mat.roughness = 0.75
		_body_mat.metallic_specular = 0.35
		_lamp_mat = ShaderMaterial.new()
		var sh := Shader.new()
		sh.code = "shader_type spatial;\nrender_mode unshaded;\nuniform float energy = 3.0;\nvoid fragment() {\n\tALBEDO = COLOR.rgb * energy;\n}\n"
		_lamp_mat.shader = sh
	return [_body_mat, _lamp_mat]


static func build_car_mesh(body_color: Color, villain: bool = false) -> ArrayMesh:
	var d: Dictionary = build_car_arrays(body_color, villain)
	var mesh := ArrayMesh.new()
	var mats := materials()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, d["body"])
	mesh.surface_set_material(0, mats[0])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, d["lamps"])
	mesh.surface_set_material(1, mats[1])
	return mesh


## Generic static voxel prop (road tiles, trees...) as a single-surface mesh.
static func build_boxes_mesh(items: Array) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for it in items:
		add_box(st, it[0], it[1], it[2])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st.commit_to_arrays())
	mesh.surface_set_material(0, materials()[0])
	return mesh
