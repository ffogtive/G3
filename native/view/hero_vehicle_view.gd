class_name HeroVehicleView
extends Node3D
## Few-of-a-kind vehicles (player, villains, boss) as MeshInstance3D (NATIVE_PORT 3-7): main mesh with the shared
## hero voxel material (lamps / paint / hit flash as instance uniforms), detailed sub-meshes (wheels spin with
## speed, driver, cannon), stock glass material, and the beam quad shown only on high beam.
## The player also gets the web's roof beacon (player.js:28-36, created at runtime so the bake never saw it):
## 0.5 × 0.28 × 0.32 box at points.beaconPos, dark amber 0x5a3a00 off, 0xffa000 + HDR emission on (blooms).

const BIT_HIGHBEAM: int = 8

var template: Resource
var body: MeshInstance3D
var wheels: Array[MeshInstance3D] = []
var _wheel_base: Array[Transform3D] = []
var _wheel_r: float = 0.4
var _spin: float = 0.0
var _fx_surface: int = -1
var _fx_material: Material
var _hidden: Material
var lamp_bits: int = -1
var speed: float = 0.0
var beacon: MeshInstance3D
var _beacon_on_mat: StandardMaterial3D
var _beacon_off_mat: StandardMaterial3D
var _beacon_lit: int = -1


func setup(factory: VehicleFactory, kind: String, variant: int, color: Variant = null) -> void:
	template = factory.template(kind, variant)
	_hidden = factory.mat_hidden
	name = "%s_v%d" % [kind, variant]
	body = MeshInstance3D.new()
	body.name = "Body"
	var mesh: ArrayMesh = template.get(&"mesh")
	body.mesh = mesh
	for s: int in mesh.get_surface_count():
		var sname: String = mesh.surface_get_name(s)
		if sname == "body" or sname == "lamps":
			body.set_surface_override_material(s, factory.mat_hero)
		elif sname == "fx":
			_fx_surface = s
			_fx_material = mesh.surface_get_material(s)
			body.set_surface_override_material(s, _hidden)
		# glass keeps its stock transparent material
	add_child(body)
	var paint := Color(0, 0, 0, 0)
	if color != null:
		paint = factory.paint_for(template, int(color))
	body.set_instance_shader_parameter(&"hero_paint", Vector4(paint.r, paint.g, paint.b, paint.a))
	_wheel_r = maxf(0.2, float(template.get(&"wheel_radius")))
	var subs: Dictionary = template.get(&"sub_meshes")
	for node_name: String in subs:
		var e: Dictionary = subs[node_name]
		for xf: Transform3D in e["transforms"]:
			var mi := MeshInstance3D.new()
			mi.name = node_name
			mi.mesh = e["mesh"]
			mi.material_override = factory.mat_hero
			mi.transform = xf
			mi.set_instance_shader_parameter(&"hero_paint", Vector4(paint.r, paint.g, paint.b, paint.a))
			add_child(mi)
			if node_name == "wheel":
				wheels.append(mi)
				_wheel_base.append(xf)
	set_lamps(0)


## Lamp bits (TrafficBridge contract; blinker bits = lit now).
func set_lamps(bits: int) -> void:
	if bits == lamp_bits:
		return
	lamp_bits = bits
	body.set_instance_shader_parameter(&"hero_lamps", bits)
	if _fx_surface >= 0:
		body.set_surface_override_material(_fx_surface, _fx_material if bits & BIT_HIGHBEAM else _hidden)


## Adds the roof beacon (player.js beacon). Falls back to (-0.55, height − 0.05, 0.55) like the web.
func enable_beacon() -> void:
	if beacon != null:
		return
	var pts: Dictionary = template.get(&"points") if template.get(&"points") is Dictionary else {}
	var h: float = float(template.get(&"height")) if template.get(&"height") != null else 1.7
	var pos: Vector3 = pts.get("beaconPos", Vector3(-0.55, h - 0.05, 0.55))
	var box := BoxMesh.new()
	box.size = Vector3(0.5, 0.28, 0.32)
	_beacon_off_mat = StandardMaterial3D.new()
	_beacon_off_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED  # MeshBasicMaterial on the web
	_beacon_off_mat.albedo_color = Color8(0x5a, 0x3a, 0x00)
	_beacon_on_mat = StandardMaterial3D.new()
	_beacon_on_mat.albedo_color = Color8(0xff, 0xa0, 0x00)
	_beacon_on_mat.emission_enabled = true
	_beacon_on_mat.emission = Color8(0xff, 0xa0, 0x00)
	_beacon_on_mat.emission_energy_multiplier = 2.5  # > glow_hdr_threshold 1.0
	beacon = MeshInstance3D.new()
	beacon.name = "Beacon"
	beacon.mesh = box
	beacon.position = pos
	beacon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(beacon)
	set_beacon(false)


## web: beaconOn when urgent (jam / boss) and floor(t / 0.18 s) is even.
func set_beacon(on: bool) -> void:
	if beacon == null or int(on) == _beacon_lit:
		return
	_beacon_lit = int(on)
	beacon.material_override = _beacon_on_mat if on else _beacon_off_mat


func set_flash(amount: float) -> void:
	body.set_instance_shader_parameter(&"hero_flash", clampf(amount, 0.0, 1.0))


## true: the owner spins the wheels with advance_wheels() on sim time (Game.manual shots/tests stay reproducible).
var manual: bool = false


func _process(delta: float) -> void:
	if not manual:
		advance_wheels(delta)


func advance_wheels(delta: float) -> void:
	if wheels.is_empty():
		return
	_spin = fmod(_spin + speed * delta / _wheel_r, TAU)
	for i: int in wheels.size():
		var b: Transform3D = _wheel_base[i]
		wheels[i].transform = Transform3D(b.basis * Basis(Vector3.RIGHT, -_spin), b.origin)
