class_name VehicleFactory
extends RefCounted
## Loads the baked vehicle templates (res://assets/vehicles/<kind>_v<variant>.tres, bake contract in
## res://assets/README.md) and owns the shared voxel materials. Every lit voxel draw in the game uses one of the
## four ShaderMaterials below so the debug panel can retune them all at once (set_param).

const TemplateScript: Script = preload("res://assets/vehicles/vehicle_template.gd")
const VOXEL_SHADER: Shader = preload("res://shaders/voxel.gdshader")
const VEHICLE_DIR: String = "res://assets/vehicles/"

enum Source { STATIC = 0, NPC = 1, HERO = 2 }

var mat_static: ShaderMaterial
var mat_npc: ShaderMaterial
var mat_hero: ShaderMaterial
var mat_hidden: ShaderMaterial
var _templates: Dictionary = {}       # "kind_vN" → template Resource
var _kinds: Dictionary = {}           # vehicle_kinds.json kinds


func _init() -> void:
	mat_static = _voxel(Source.STATIC)
	mat_npc = _voxel(Source.NPC)
	mat_hero = _voxel(Source.HERO)
	mat_hidden = ShaderMaterial.new()
	var hidden := Shader.new()
	hidden.code = "shader_type spatial;\nrender_mode unshaded;\nvoid vertex() { VERTEX = vec3(0.0); }\n"
	mat_hidden.shader = hidden
	var vk: Variant = ViewData.table("vehicle_kinds")
	if vk is Dictionary and (vk as Dictionary).get("kinds") is Dictionary:
		_kinds = (vk as Dictionary)["kinds"]


func _voxel(src: int) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = VOXEL_SHADER
	m.set_shader_parameter(&"source", src)
	return m


func materials() -> Array[ShaderMaterial]:
	return [mat_static, mat_npc, mat_hero]


## Push one shader uniform to every voxel material (debug panel, sky preset).
func set_param(param: StringName, value: Variant) -> void:
	for m: ShaderMaterial in materials():
		m.set_shader_parameter(param, value)


## vehicles.js buildVehicle variant rule: canon[seed % variants] (vehicle_kinds.json).
func variant_for_seed(kind: String, seed: int) -> int:
	var k: Dictionary = _kinds.get(kind, {})
	var n: int = maxi(1, int(k.get("variants", 1)))
	var canon: Array = k.get("canon", [])
	var raw: int = absi(seed) % n
	return int(canon[raw]) if raw < canon.size() else 0


func has_template(kind: String, variant: int) -> bool:
	return ResourceLoader.exists("%s%s_v%d.tres" % [VEHICLE_DIR, kind, variant])


## Template for (kind, canonical variant); falls back to variant 0, then to sedan_v0 so a bad spec never crashes.
func template(kind: String, variant: int) -> Resource:
	var key: String = "%s_v%d" % [kind, variant]
	if _templates.has(key):
		return _templates[key]
	var path: String = VEHICLE_DIR + key + ".tres"
	if not ResourceLoader.exists(path):
		path = "%s%s_v0.tres" % [VEHICLE_DIR, kind]
	if not ResourceLoader.exists(path):
		push_warning("VehicleFactory: no template for %s, using sedan_v0" % key)
		path = VEHICLE_DIR + "sedan_v0.tres"
	var t: Resource = load(path)
	_templates[key] = t
	return t


## sRGB paint for the shader tint (INSTANCE_CUSTOM / hero_paint): rgb + a = 1 when the template is tintable and the
## kind does not force a livery, else a = 0 (keep the baked colour).
func paint_for(tpl: Resource, color: int) -> Color:
	if not bool(tpl.get(&"tintable")) or bool(tpl.get(&"livery")):
		return Color(0, 0, 0, 0)
	var c := Color.hex((color << 8) | 0xff)
	return Color(c.r, c.g, c.b, 1.0)
