class_name NpcMultiMesh
extends Node3D
## NPC traffic draw path (NATIVE_PORT 3-7 "드로우 경로: M1부터 MultiMesh"): one MultiMeshInstance3D per
## (kind, variant) template; body + lamps share one material (shaders/voxel.gdshader, source = NPC), so a template
## costs 2 draws (+ 2 per shadow split). INSTANCE_CUSTOM = (sRGB paint.rgb | r = −1 for livery, lamp bits).
## Positions come from the TrafficBridge stride-8 buffer [id, kind_index, lane, x, s, yaw, v, lamp_bits] of the last
## two sim ticks and are interpolated here with Engine.get_physics_interpolation_fraction() (3-2), then mapped through
## RoadGraph.world(). Villain cars (bit 64) are skipped: they are hero views.

const STRIDE: int = 8
const BLINK_PERIOD: float = 2.0 / 3.0        # vehicles.js BLINK_PERIOD
const BIT_BLINK: int = 2 | 4
const BIT_VILLAIN: int = 64
const FLOATS: int = 16                       # 12 transform + 4 custom

var road: RoadGraph
var factory: VehicleFactory
var blob: MultiMeshInstance3D
var _groups: Dictionary = {}                 # template key → {mmi, ids: Array[int], buf: PackedFloat32Array, len, w}
var _slot: Dictionary = {}                   # car id → [template key, index]
var _blob_buf := PackedFloat32Array()
var _row_of: Dictionary = {}               # car id → row in the sim buffer
var _visible_cars: int = 0
var lamp_time: float = 0.0
## false: the buffer's blinker bits are already the lit state (web frame replay).
var blink_phase: bool = true


func setup(p_factory: VehicleFactory, p_road: RoadGraph, specs: Dictionary) -> void:
	factory = p_factory
	road = p_road
	for c: Node in get_children():
		c.queue_free()
	_groups.clear()
	_slot.clear()
	var by_key: Dictionary = {}
	for id: int in specs:
		var sp: Dictionary = specs[id]
		var key: String = "%s_v%d" % [sp["kind"], int(sp["variant"])]
		if not by_key.has(key):
			by_key[key] = []
		(by_key[key] as Array).append(id)
	var keys: Array = by_key.keys()
	keys.sort()
	for key: String in keys:
		var ids: Array = by_key[key]
		var sp0: Dictionary = specs[ids[0]]
		var tpl: Resource = factory.template(str(sp0["kind"]), int(sp0["variant"]))
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = tpl.get(&"mesh")
		mm.instance_count = ids.size()
		var mmi := MultiMeshInstance3D.new()
		mmi.name = key
		mmi.multimesh = mm
		mmi.material_override = factory.mat_npc
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		mmi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		add_child(mmi)
		var buf := PackedFloat32Array()
		buf.resize(ids.size() * FLOATS)
		var paints := PackedColorArray()
		var pids := PackedInt32Array()
		for i: int in ids.size():
			var sp: Dictionary = specs[ids[i]]
			paints.append(factory.paint_for(tpl, int(sp.get("color", 0xffffff))))
			pids.append(int(ids[i]))
			_slot[ids[i]] = [key, i]
		_groups[key] = {"mmi": mmi, "ids": pids, "buf": buf, "paints": paints,
			"len": float(tpl.get(&"length")), "w": float(tpl.get(&"width"))}
	_make_blob(specs.size())


func _make_blob(n: int) -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2(1, 1)
	quad.orientation = PlaneMesh.FACE_Y
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://shaders/blob_shadow.gdshader")
	quad.material = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = quad
	mm.instance_count = n
	blob = MultiMeshInstance3D.new()
	blob.name = "BlobShadows"
	blob.multimesh = mm
	blob.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	blob.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(blob)
	_blob_buf.resize(n * 12)


## web setBlinker phase: on during the first half of each period, per-car offset (id % 7)·0.09 s (traffic.js:437).
static func blink_lit(t: float, id: int) -> bool:
	return fposmod(t + float(id % 7) * 0.09, BLINK_PERIOD) < BLINK_PERIOD * 0.5


## Lamp bits as drawn: blinker bits mean "blinker active" in the sim buffer; here they become "lit now".
static func drawn_bits(bits: int, t: float, id: int) -> int:
	if bits & BIT_BLINK and not blink_lit(t, id):
		bits &= ~BIT_BLINK
	return bits


## prev / cur: the last two sim buffers (same car order); frac: physics interpolation fraction.
func sync(prev: PackedFloat32Array, cur: PackedFloat32Array, frac: float) -> void:
	var n: int = cur.size() / STRIDE
	if _row_of.size() != n or not _rows_valid(cur):
		_row_of.clear()
		for k: int in n:
			_row_of[int(cur[k * STRIDE])] = k
	var same_order: bool = prev.size() == cur.size()
	var straight: bool = road.is_straight()
	var bi: int = 0
	var blob_buf: PackedFloat32Array = _blob_buf
	var blob_cap: int = blob_buf.size() / 12
	for key: String in _groups:
		var g: Dictionary = _groups[key]
		var ids: PackedInt32Array = g["ids"]
		var paints: PackedColorArray = g["paints"]
		var buf: PackedFloat32Array = g["buf"]
		var bw: float = float(g["w"]) * 1.02   # was 1.15 / 1.06: read as a floor mat past the silhouette (art review)
		var bl: float = float(g["len"]) * 1.0
		for i: int in ids.size():
			var id: int = ids[i]
			var f: int = i * FLOATS
			var k: int = _row_of.get(id, -1)
			if k < 0:
				buf[f + 7] = -1000.0  # not in this tick: park far below the road
				continue
			var o: int = k * STRIDE
			var bits: int = int(cur[o + 7])
			var x: float = cur[o + 3]
			var s: float = cur[o + 4]
			var yaw: float = cur[o + 5]
			if same_order and int(prev[o]) == id:
				x = lerpf(prev[o + 3], x, frac)
				s = lerpf(prev[o + 4], s, frac)
				yaw = lerp_angle(prev[o + 5], yaw, frac)
			var villain: bool = (bits & BIT_VILLAIN) != 0
			var c: float
			var sn: float
			var ox: float
			var oy: float
			var oz: float
			if straight:  # closed form of RoadGraph.world(s, x, yaw) for the straight road
				c = cos(yaw)
				sn = sin(yaw)
				ox = x
				oy = 0.0
				oz = -s
				buf[f] = c
				buf[f + 1] = 0.0
				buf[f + 2] = sn
				buf[f + 4] = 0.0
				buf[f + 5] = 1.0
				buf[f + 6] = 0.0
				buf[f + 8] = -sn
				buf[f + 9] = 0.0
				buf[f + 10] = c
			else:
				var xf: Transform3D = road.world(s, x, yaw)
				_write_xf(buf, f, xf)
				c = xf.basis.x.x
				sn = xf.basis.z.x
				ox = xf.origin.x
				oy = xf.origin.y
				oz = xf.origin.z
			buf[f + 3] = ox
			buf[f + 7] = -1000.0 if villain else oy  # villains are hero views
			buf[f + 11] = oz
			var paint: Color = paints[i]
			buf[f + 12] = paint.r if paint.a > 0.5 else -1.0
			buf[f + 13] = paint.g
			buf[f + 14] = paint.b
			buf[f + 15] = float(drawn_bits(bits, lamp_time, id) if blink_phase else bits)
			if not villain and bi < blob_cap:
				var b: int = bi * 12
				blob_buf[b] = c * bw
				blob_buf[b + 1] = 0.0
				blob_buf[b + 2] = sn * bl
				blob_buf[b + 3] = ox
				blob_buf[b + 4] = 0.0
				blob_buf[b + 5] = 1.0
				blob_buf[b + 6] = 0.0
				blob_buf[b + 7] = oy + 0.03
				blob_buf[b + 8] = -sn * bw
				blob_buf[b + 9] = 0.0
				blob_buf[b + 10] = c * bl
				blob_buf[b + 11] = oz
				bi += 1
		g["buf"] = buf
		((g["mmi"] as MultiMeshInstance3D).multimesh as MultiMesh).buffer = buf
	_blob_buf = blob_buf
	if blob != null:
		var mm: MultiMesh = blob.multimesh
		mm.buffer = _blob_buf
		mm.visible_instance_count = bi
	_visible_cars = bi


func _rows_valid(cur: PackedFloat32Array) -> bool:
	for id: int in _row_of:
		var k: int = _row_of[id]
		if k * STRIDE >= cur.size() or int(cur[k * STRIDE]) != id:
			return false
	return true


func _write_xf(buf: PackedFloat32Array, f: int, xf: Transform3D) -> void:
	var b: Basis = xf.basis
	buf[f] = b.x.x
	buf[f + 1] = b.y.x
	buf[f + 2] = b.z.x
	buf[f + 3] = xf.origin.x
	buf[f + 4] = b.x.y
	buf[f + 5] = b.y.y
	buf[f + 6] = b.z.y
	buf[f + 7] = xf.origin.y
	buf[f + 8] = b.x.z
	buf[f + 9] = b.y.z
	buf[f + 10] = b.z.z
	buf[f + 11] = xf.origin.z


func group_count() -> int:
	return _groups.size()


func car_count() -> int:
	return _visible_cars
