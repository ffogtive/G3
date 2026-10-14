class_name HazardView
extends Node3D
## Boss attack telegraphs drawn from GameSim.state().hazards (boss.js visuals, simplified):
##  - beams  (high beam, occupy relay): additive light cone from the villain's nose forward over the player; flickers
##           at 12 Hz during the 0.75 s telegraph (opacity 0.12 / 0), solid 0.55 while on, then fades (boss.js:735).
##  - waves  (horn / smoke): one arch per lane rolling forward with the wave; horn arches grow with age (boss.js:544).
##  - items  (thrown cup / butt / phone, rolling watermelon / hay): the object on its arc and a red landing ring that
##           fills while the item flies; rolling items warn under the player instead (boss.js _throw marker).
## Pools of MeshInstance3D grow on demand and are hidden when unused; nothing here is random.

const BEAM_LEN: float = 30.0
const ITEM_COL: Dictionary = {"cup": Color8(0xf4, 0xe1, 0xc1), "butt": Color8(0xff, 0x7a, 0x1a), "phone": Color8(0x22, 0x24, 0x2a),
	"watermelon": Color8(0x2f, 0x9e, 0x3a), "hay": Color8(0xe8, 0xc0, 0x4a)}

var road: RoadGraph
var _beams: Array[MeshInstance3D] = []
var _waves: Array[MeshInstance3D] = []
var _items: Array[MeshInstance3D] = []
var _marks: Array[MeshInstance3D] = []
var _beam_mesh: CylinderMesh
var _arch_mesh: TorusMesh
var _puff_mesh: SphereMesh
var _item_mesh: SphereMesh
var _ring_mesh: TorusMesh
var _item_mats: Dictionary = {}
var shown: Dictionary = {"beams": 0, "waves": 0, "items": 0, "markers": 0}


func setup(p_road: RoadGraph) -> void:
	road = p_road
	_beam_mesh = CylinderMesh.new()
	_beam_mesh.top_radius = 3.2
	_beam_mesh.bottom_radius = 0.6
	_beam_mesh.height = BEAM_LEN
	_beam_mesh.cap_top = false
	_beam_mesh.cap_bottom = false
	_beam_mesh.radial_segments = 12
	_beam_mesh.rings = 1
	_arch_mesh = TorusMesh.new()
	_arch_mesh.inner_radius = 1.28
	_arch_mesh.outer_radius = 1.72
	_arch_mesh.rings = 18
	_arch_mesh.ring_segments = 6
	_puff_mesh = SphereMesh.new()
	_puff_mesh.radius = 1.3
	_puff_mesh.height = 1.8
	_puff_mesh.radial_segments = 10
	_puff_mesh.rings = 5
	_item_mesh = SphereMesh.new()
	_item_mesh.radius = 0.28
	_item_mesh.height = 0.56
	_item_mesh.radial_segments = 8
	_item_mesh.rings = 4
	_ring_mesh = TorusMesh.new()
	_ring_mesh.inner_radius = 0.75
	_ring_mesh.outer_radius = 1.05
	_ring_mesh.rings = 20
	_ring_mesh.ring_segments = 4


static func _add_mat(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	m.albedo_color = col
	return m


func _take(pool: Array[MeshInstance3D], i: int, mesh: Mesh, col: Color, additive: bool) -> MeshInstance3D:
	while pool.size() <= i:
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if additive:
			mi.material_override = _add_mat(col)
		add_child(mi)
		pool.append(mi)
	var out: MeshInstance3D = pool[i]
	out.visible = true
	return out


static func _hide_from(pool: Array[MeshInstance3D], n: int) -> void:
	for k: int in range(n, pool.size()):
		pool[k].visible = false


func _alpha(mi: MeshInstance3D, col: Color, a: float) -> void:
	(mi.material_override as StandardMaterial3D).albedo_color = Color(col.r, col.g, col.b, clampf(a, 0.0, 1.0))


func sync(st: Dictionary) -> void:
	if road == null:
		return
	var hz: Dictionary = st.get("hazards", {}) if st.get("hazards") is Dictionary else {}
	var vby: Dictionary = {}
	for v: Variant in st.get("villains", []):
		vby[int((v as Dictionary).get("id", -1))] = v
	var p: Dictionary = st.get("player", {})
	# beams
	var nb: int = 0
	var beam_col := Color8(0xff, 0xf6, 0xc8)
	for b: Variant in hz.get("beams", []):
		var d: Dictionary = b
		var v: Dictionary = vby.get(int(d.get("vi", -1)), {})
		if v.is_empty() or not bool(v.get("alive", false)):
			continue
		var t: float = float(d.get("t", 0.0))
		var tele: float = float(d.get("tele", 0.75))
		var a: float = 0.0
		if t < tele:
			a = 0.12 if int(floorf(t * 12.0)) % 2 == 0 else 0.0
		elif t < tele + float(d.get("on", 0.5)):
			a = 0.55
		else:
			a = maxf(0.0, 0.55 - (t - tele - float(d.get("on", 0.5))) * 2.0)
		var mi: MeshInstance3D = _take(_beams, nb, _beam_mesh, beam_col, true)
		var nose: float = float(v.get("s", 0.0)) + float(v.get("len", 4.6)) * 0.5
		var xf: Transform3D = road.world(nose + BEAM_LEN * 0.5, float(v.get("x", 0.0)))
		xf.basis = xf.basis * Basis(Vector3.RIGHT, -PI * 0.5)  # cylinder +Y (wide top) → road forward
		xf.origin.y += 1.0
		mi.transform = xf
		_alpha(mi, beam_col, a)
		nb += 1
	_hide_from(_beams, nb)
	# waves
	var nw: int = 0
	var horn_col := Color8(0xff, 0xb3, 0x47)
	var smoke_col := Color(0.55, 0.56, 0.6)
	for w: Variant in hz.get("waves", []):
		var d: Dictionary = w
		var smoke: bool = str(d.get("kind", "horn")) == "smoke"
		var age: float = float(d.get("age", 0.0))
		for ln: Variant in d.get("lanes", []):
			var col: Color = smoke_col if smoke else horn_col
			var mi: MeshInstance3D = _take(_waves, nw, _arch_mesh, col, true)
			if mi.mesh != (_puff_mesh if smoke else _arch_mesh):
				mi.mesh = _puff_mesh if smoke else _arch_mesh
			var xf: Transform3D = road.world(float(d.get("s", 0.0)), RoadGraph.lane_x(float(ln)))
			var sc: float = 1.0 + age * 0.8 if not smoke else 1.0 + sin(age * 6.0) * 0.06
			xf.basis = xf.basis * Basis(Vector3.RIGHT, PI * 0.5).scaled(Vector3.ONE * sc) if not smoke else xf.basis.scaled(Vector3.ONE * sc)
			xf.origin.y += 0.0 if not smoke else 0.9
			mi.transform = xf
			_alpha(mi, col, (0.7 if not smoke else 0.45) * clampf(1.0 - age / 3.2, 0.0, 1.0))
			nw += 1
	_hide_from(_waves, nw)
	# items + landing markers
	var ni: int = 0
	var nm: int = 0
	var mark_col := Color8(0xff, 0x3b, 0x30)
	for it: Variant in hz.get("items", []):
		var d: Dictionary = it
		var kind: String = str(d.get("kind", "cup"))
		var dur: float = maxf(0.05, float(d.get("dur", 0.85)))
		var k: float = clampf(float(d.get("t", 0.0)) / dur, 0.0, 1.0)
		var pos: Vector3
		if bool(d.get("landed", false)):
			pos = road.position(float(d.get("s", 0.0)), RoadGraph.lane_x(float(d.get("lane", 0)))) + Vector3(0, float(d.get("to_y", 0.45)), 0)
		else:
			var a3: Vector3 = road.position(float(d.get("from_s", 0.0)), float(d.get("from_x", 0.0))) + Vector3(0, float(d.get("from_y", 1.5)), 0)
			var b3: Vector3 = road.position(float(d.get("to_s", 0.0)), float(d.get("to_x", 0.0))) + Vector3(0, float(d.get("to_y", 0.45)), 0)
			pos = a3.lerp(b3, k) + Vector3(0, sin(k * PI) * 2.4, 0)
		var mi: MeshInstance3D = _take(_items, ni, _item_mesh, Color.WHITE, false)
		if not _item_mats.has(kind):
			var m := StandardMaterial3D.new()
			m.albedo_color = ITEM_COL.get(kind, Color.WHITE)
			_item_mats[kind] = m
		mi.material_override = _item_mats[kind]
		var big: float = 1.6 if kind == "watermelon" or kind == "hay" else 1.0
		mi.transform = Transform3D(Basis(Vector3.RIGHT, k * 9.0 + float(d.get("roll_t", 0.0)) * 8.0).scaled(Vector3.ONE * big), pos)
		ni += 1
		if bool(d.get("marker", false)):
			var ms: float = float(d.get("to_s", 0.0)) if not bool(d.get("rolling", false)) else float(p.get("s", 0.0))
			var mx: float = float(d.get("to_x", 0.0))
			var mk: MeshInstance3D = _take(_marks, nm, _ring_mesh, mark_col, true)
			var mxf: Transform3D = road.world(ms, mx)
			mxf.basis = mxf.basis.scaled(Vector3.ONE * (0.55 + 0.45 * k))
			mxf.origin.y += 0.05
			mk.transform = mxf
			_alpha(mk, mark_col, 0.45 + 0.4 * (0.5 + 0.5 * sin(float(d.get("t", 0.0)) * 22.0)))
			nm += 1
	_hide_from(_items, ni)
	_hide_from(_marks, nm)
	shown = {"beams": nb, "waves": nw, "items": ni, "markers": nm}
