class_name Game
extends Node3D
## M1a composition root (NATIVE_PORT 3-1 view/game.gd, 3-2 fixed tick): stage 1-1 jam scene.
##  sim  (_physics_process, 120 Hz): input edges → player driver → TrafficBridge.step → event fan-out
##  view (_process): NPC MultiMesh interpolation, hero views, camera (real-dt smoothing), N5 icons, HUD
## TrafficBridge (res://sim/traffic_bridge.gd, sim agent) is used when present, else the view's TrafficStub with the
## same interface. Command-line (after `--`): --stage=N --seed=N --traffic=auto|stub --no-debug-panel --manual.

const TICK: float = 1.0 / 120.0
const BRIDGE_PATH: String = "res://sim/traffic_bridge.gd"
const HAPTICS_PATH: String = "res://autoload/haptics.gd"

var stage_id: int = 1
var seed: int = 1007
## true: no _physics_process stepping; the caller drives advance_ticks()/render_step() (shot_jam, tests).
var manual: bool = false
var with_debug_panel: bool = true
## "auto" = TrafficBridge when it loads, else TrafficStub; "stub" forces the view stub (web-frame replays).
var traffic_mode: String = "auto"

var stage: Dictionary = {}
var cfg: Dictionary = {}
var road: RoadGraph
var factory: VehicleFactory
var traffic: RefCounted
var world: WorldView
var npc: NpcMultiMesh
var player: PlayerDriver
var player_view: HeroVehicleView
var villain_views: Dictionary = {}       # car id → HeroVehicleView
var camera: CameraRig
var icons: SignalIcons
var honk_fx: HonkWave
var input: LaneInput
var hud: Hud
var sfx: Sfx
var haptics: Node
var debug_panel: DebugPanel
var start_s: float = 0.0
var front_s: float = 200.0
var sim_time: float = 0.0
var real_time: float = 0.0
var ticks: int = 0
var log_events: Array[Dictionary] = []
var _prev := PackedFloat32Array()
var _cur := PackedFloat32Array()
var _kind_names := PackedStringArray()
var _heights: Dictionary = {}
var _villain_s: float = 200.0
var _hazard_cars: Array[HeroVehicleView] = []
var _bridge_villains: Array[HeroVehicleView] = []   # villains the bridge keeps outside the buffer (villains())
var _vprev := PackedFloat32Array()
var _built: bool = false


func _ready() -> void:
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--stage="):
			stage_id = a.trim_prefix("--stage=").to_int()
		elif a.begins_with("--seed="):
			seed = a.trim_prefix("--seed=").to_int()
		elif a == "--no-debug-panel":
			with_debug_panel = false
		elif a == "--manual":
			manual = true
		elif a.begins_with("--traffic="):
			traffic_mode = a.trim_prefix("--traffic=")
	build()


func build() -> void:
	if _built:
		return
	_built = true
	stage = ViewData.stage(stage_id)
	var c: Variant = ViewData.table("config")
	cfg = c if c is Dictionary else {}
	road = RoadGraph.new(stage.get("road", []) if stage.get("road") is Array else [])
	factory = VehicleFactory.new()
	traffic = _make_traffic()
	traffic.call(&"setup", stage, cfg, seed)
	_kind_names = traffic.call(&"kind_names")
	var setup: Dictionary = cfg.get("setup", {}) if cfg.get("setup") is Dictionary else {}
	start_s = float(setup.get("startS", 0.0))
	front_s = start_s + float(stage.get("jamLength", 170.0)) + float(setup.get("frontGap", 30.0))
	player = PlayerDriver.new()
	player.reset(int(setup.get("startLane", 3)), start_s)
	var obstacles: Array = traffic.call(&"obstacles") if traffic.has_method(&"obstacles") else []

	world = WorldView.new()
	world.name = "World"
	add_child(world)
	world.build(stage, factory, road, {"startS": start_s, "frontS": front_s}, obstacles)

	_breakdown_cars(obstacles)
	_cur.resize(int(traffic.call(&"count")) * 8)
	traffic.call(&"read_into", _cur)
	_prev = _cur.duplicate()
	npc = NpcMultiMesh.new()
	npc.name = "Npc"
	add_child(npc)
	npc.setup(factory, road, _specs())
	if villain_views.is_empty() and traffic.has_method(&"villains"):
		for v: Dictionary in traffic.call(&"villains"):
			var hv := HeroVehicleView.new()
			add_child(hv)
			hv.setup(factory, str(v.get("kind", "villainSedan")), 0, v.get("color"))
			hv.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
			_bridge_villains.append(hv)

	player_view = HeroVehicleView.new()
	add_child(player_view)
	player_view.setup(factory, "player", 0)
	player_view.transform = road.world(player.s, player.x)
	player_view.reset_physics_interpolation()

	camera = CameraRig.new()
	camera.name = "Camera"
	camera.road = road
	add_child(camera)
	camera.current = true
	icons = SignalIcons.new()
	icons.name = "SignalIcons"
	icons.road = road
	icons.camera = camera
	icons.heights = _heights
	add_child(icons)
	honk_fx = HonkWave.new()
	honk_fx.name = "HonkWave"
	add_child(honk_fx)
	input = LaneInput.new()
	input.name = "Input"
	add_child(input)
	hud = Hud.new()
	hud.name = "Hud"
	add_child(hud)
	hud.bind_input(input)
	sfx = Sfx.new()
	sfx.name = "Sfx"
	add_child(sfx)
	haptics = _haptics()
	if with_debug_panel and OS.is_debug_build():
		debug_panel = DebugPanel.new()
		debug_panel.name = "DebugPanel"
		debug_panel.world = world
		debug_panel.factory = factory
		debug_panel.icons = icons
		add_child(debug_panel)
	var vp: Viewport = get_viewport()
	if "use_debanding" in vp:
		vp.set(&"use_debanding", true)
	vp.msaa_3d = Viewport.MSAA_4X
	_update_view(1.0)
	camera.snap()


## shoulder.js breakdown: the car sits 2.4 m ahead of the obstacle centre, yawed by detail.rotY, hazards blinking
## (traffic.js:469 floor(2t) % 2); not part of the traffic buffer, so it is a static hero view.
func _breakdown_cars(obstacles: Array) -> void:
	for o: Variant in obstacles:
		if not (o is Dictionary) or str((o as Dictionary).get("kind", "")) != "breakdown":
			continue
		var det: Dictionary = (o as Dictionary).get("detail", {}) if (o as Dictionary).get("detail") is Dictionary else {}
		if not det.has("carKind"):
			continue
		var hv := HeroVehicleView.new()
		add_child(hv)
		hv.setup(factory, str(det["carKind"]), int(det.get("variant", 0)), int(det.get("color", 0xf4f4f2)))
		hv.transform = road.world(float(o["s"]) + 2.4, float(o["x"]), float(det.get("rotY", 0.0)))
		hv.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		_hazard_cars.append(hv)


func _make_traffic() -> RefCounted:
	if traffic_mode != "stub" and ResourceLoader.exists(BRIDGE_PATH):
		var scr: Script = load(BRIDGE_PATH)
		if scr != null and scr.can_instantiate():
			var t: Object = scr.new()
			if t is RefCounted and t.has_method(&"read_into"):
				return t as RefCounted
	return TrafficStub.new()


func _haptics() -> Node:
	var n: Node = get_tree().root.get_node_or_null(^"Haptics")
	if n != null:
		return n
	if ResourceLoader.exists(HAPTICS_PATH):  # not registered as an autoload yet (gate owner): host it here
		var h: Node = (load(HAPTICS_PATH) as Script).new()
		h.name = "Haptics"
		add_child(h)
		return h
	return null


func haptic(event_name: String) -> void:
	if haptics != null and haptics.has_method(&"haptic"):
		haptics.call(&"haptic", event_name)


## id → {kind, variant, color} for every car in the buffer: TrafficBridge.car_specs() (array) or TrafficStub
## .car_spec(id); without either, kind from the buffer and a variant derived from the id.
func _specs() -> Dictionary:
	var by_id: Dictionary = {}
	if traffic.has_method(&"car_specs"):
		for d: Dictionary in traffic.call(&"car_specs"):
			by_id[int(d["id"])] = d
	var out: Dictionary = {}
	var n: int = _cur.size() / 8
	for k: int in n:
		var id: int = int(_cur[k * 8])
		var ki: int = int(_cur[k * 8 + 1])
		var kind: String = _kind_names[ki] if ki >= 0 and ki < _kind_names.size() else "sedan"
		var sp: Dictionary = {}
		if by_id.has(id):
			var d: Dictionary = by_id[id]
			sp = {"kind": str(d.get("kind_name", kind)), "variant": int(d.get("variant", 0)), "color": int(d.get("color", 0xf4f4f2))}
		elif traffic.has_method(&"car_spec"):
			sp = traffic.call(&"car_spec", id)
		if sp.is_empty():
			sp = {"kind": kind, "variant": factory.variant_for_seed(kind, id * 7919), "color": 0xf4f4f2}
		if int(_cur[k * 8 + 7]) & 64:
			var hv := HeroVehicleView.new()
			add_child(hv)
			hv.setup(factory, str(sp["kind"]), int(sp.get("variant", 0)))
			hv.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
			villain_views[id] = hv
			_heights[id] = float(hv.template.get(&"height"))
			continue
		var tpl: Resource = factory.template(str(sp["kind"]), int(sp.get("variant", 0)))
		_heights[id] = float(tpl.get(&"height"))
		out[id] = sp
	return out


# ───────────────────────────── sim side (fixed tick)

func _physics_process(_delta: float) -> void:
	if manual or not _built:
		return
	sim_tick(TICK)


func sim_tick(dt: float) -> void:
	var dir: int = input.consume_lane()
	if dir != 0 and player.lc_t >= 1.0:
		var to: int = player.lane + dir
		if bool(traffic.call(&"request_lane", player.lane, to, player.s)):
			player.start_lane_change(to)
			haptic("laneChange")
			_log({"type": "lane_change", "to": to})
		else:
			_log({"type": "lane_blocked", "to": to})
	if input.consume_horn():
		honk()
	player.step(dt, _cur)
	if not _bridge_villains.is_empty():
		_vprev.clear()
		for v: Dictionary in traffic.call(&"villains"):
			_vprev.append(float(v["s"]))
	traffic.call(&"step", dt, player.state())
	_prev = _cur.duplicate()
	traffic.call(&"read_into", _cur)
	sim_time += dt
	ticks += 1
	for ev: Dictionary in traffic.call(&"events"):
		icons.on_event(ev, real_time)
		_log(ev)
	player_view.transform = road.world(player.s, player.x, player.yaw)


func honk() -> void:
	haptic("horn")
	sfx.play("horn")
	honk_fx.emit_at(road.position(player.s + 2.6, player.x))
	var r: Dictionary = traffic.call(&"honk", player.lane, player.s)
	_log({"type": "honk", "reply": r})


func _log(ev: Dictionary) -> void:
	ev["t"] = sim_time
	log_events.append(ev)
	if log_events.size() > 256:
		log_events.pop_front()


## Tests / shots: run n sim ticks synchronously (no rendering), then refresh the view once.
func advance_ticks(n: int) -> void:
	for i: int in n:
		sim_tick(TICK)
		real_time += TICK
		camera.step(TICK)
	_update_view(1.0)


# ───────────────────────────── view side (every frame)

func _process(delta: float) -> void:
	if not _built:
		return
	real_time += delta
	var frac: float = 1.0 if manual else Engine.get_physics_interpolation_fraction()
	_update_view(frac)
	camera.step(delta)


func render_step(real_dt: float) -> void:
	_update_view(1.0)
	camera.step(real_dt)


func _update_view(frac: float) -> void:
	npc.lamp_time = sim_time
	icons.lamp_time = sim_time
	npc.sync(_prev, _cur, frac)
	var n: int = _cur.size() / 8
	for k: int in n:
		var o: int = k * 8
		var id: int = int(_cur[o])
		if villain_views.has(id):
			var hv: HeroVehicleView = villain_views[id]
			var s: float = lerpf(_prev[o + 4], _cur[o + 4], frac) if _prev.size() == _cur.size() else _cur[o + 4]
			var x: float = lerpf(_prev[o + 3], _cur[o + 3], frac) if _prev.size() == _cur.size() else _cur[o + 3]
			hv.transform = road.world(s, x, _cur[o + 5])
			hv.speed = _cur[o + 6]
			hv.set_lamps(NpcMultiMesh.drawn_bits(int(_cur[o + 7]) & 63, sim_time, id))
			_villain_s = s
	if not _bridge_villains.is_empty():
		var vs: Array = traffic.call(&"villains")
		for i: int in mini(vs.size(), _bridge_villains.size()):
			var v: Dictionary = vs[i]
			var sv: float = lerpf(_vprev[i], float(v["s"]), frac) if i < _vprev.size() else float(v["s"])
			_bridge_villains[i].transform = road.world(sv, float(v["x"]))
			_bridge_villains[i].speed = float(v.get("v", 0.0))
			_bridge_villains[i].set_lamps(1 if float(v.get("v", 0.0)) < 1.6 else 0)
			if i == 0:
				_villain_s = sv
	var hz: int = 16 if int(floorf(sim_time * 2.0)) % 2 == 0 else 0
	for hv: HeroVehicleView in _hazard_cars:
		hv.set_lamps(hz)
	player_view.speed = player.v
	player_view.set_lamps(NpcMultiMesh.drawn_bits(player.lamp_bits, sim_time, 0))
	var pxf: Transform3D = player_view.get_global_transform_interpolated() if not manual else player_view.global_transform
	var pr: Vector2 = road.to_road(pxf.origin)
	camera.target_s = pr.x
	camera.target_x = pr.y
	camera.target_v = player.v
	if icons.visible:
		icons.update_icons(_cur, {"s": player.s, "x": player.x, "lane": player.state()["lane"]}, real_time)
	hud.set_state(player.s, _villain_s, start_s, player.v)
	hud.horn_down = input.is_horn_down()


func buffer() -> PackedFloat32Array:
	return _cur
