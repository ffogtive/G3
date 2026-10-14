extends Resource
## Baked vehicle (NATIVE_PORT 3-7): one main ArrayMesh + pivoted sub-meshes + the part → range map the view needs to
## drive lamps, tint and wheels. Written by res://tools/import_meshes.gd from tools/bake-meshes.mjs output; never edit
## by hand. Contract (channels, part ids, lamp groups): res://assets/README.md.
##
## Load with `preload("res://assets/vehicles/vehicle_template.gd")` (no class_name, so headless scripts work before the
## global class cache exists).

## vehicles.js kind ("sedan", "player" …) and canonical geometry variant (vehicle_kinds.json canon[]).
@export var kind: StringName = &""
@export var variant: int = 0
## true for vehicles.js "detailed" builds (separate spinning wheels, driver, glass); NPCs are false.
@export var detailed: bool = false
## true for the NPC_KINDS pool (rendered through MultiMesh); npc_weight = NPC_KINDS spawn weight.
@export var npc: bool = false
@export var npc_weight: float = 0.0

## Nominal collision size from vehicles.js userData (m). The sim reads vehicle_kinds.json, these are for the view.
@export var length: float = 0.0
@export var width: float = 0.0
@export var height: float = 0.0
@export var wheel_radius: float = 0.0

## Main mesh, model space = vehicle root (y = 0 road, −Z forward). Surfaces in this order when present:
## body (lit, vertex colour), lamps (unlit emissive, collapsed by the lamp shader when off), glass, fx (beam).
@export var mesh: ArrayMesh
@export var surface_names: PackedStringArray = PackedStringArray()
## part name → {surface:int, id:int, first_index:int, index_count:int, first_vertex:int, vertex_count:int, aabb:AABB}
## (ranges are into that surface of `mesh`; ids are custom0.y).
@export var parts: Dictionary = {}
## lamp group → PackedStringArray of the part names this vehicle has (brake, head, hazard, blink_L, blink_R …).
@export var lamp_groups: Dictionary = {}
## web "off" look of a lit lamp mesh (MeshBasic colour multiplier, sRGB): brake = night tail light.
@export var lamp_off_multiplier: Dictionary = {}

## node name (wheel, driver, cannon …) → {mesh: ArrayMesh, transforms: Array[Transform3D]} (vehicle root space).
@export var sub_meshes: Dictionary = {}
## Wheels merged into a non-detailed body (static in the web): [{part, id, center: Vector3, radius, width}].
@export var merged_wheels: Array = []
## Named points in vehicle root space: exhaust, smokePoint, muzzle … (Vector3) and blink_halo_L/R (PackedVector3Array).
@export var points: Dictionary = {}
## Point → {node, pos: Vector3} for points that ride a sub-mesh (muzzle on the cannon).
@export var points_local: Dictionary = {}

## Paint: COLOR was baked with paint_default (sRGB). tintable = custom0.z holds shade factors so a shader can repaint
## with any colour: srgb = shade(paint, k) (k < 1 → paint·k, k > 1 → paint + (1 − paint)(k − 1)), then × custom0.w.
## livery = vehicles.js forces this colour whatever the spawn colour (taxi, pickup1t).
@export var paint_default: Color = Color.WHITE
@export var tintable: bool = false
@export var livery: bool = false

## JS reference recorded at bake time (for tests): bbox: AABB, tris: int (web triangles, wheels counted per wheel),
## welded_vertices: int, source: Dictionary (the buildVehicle call), web_frozen_sha: String.
@export var js_ref: Dictionary = {}
