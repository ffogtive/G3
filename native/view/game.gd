class_name Game
extends Node3D
## M1a composition root (NATIVE_PORT 3-1 view/game.gd, 3-2 fixed tick): stage 1-1 jam scene.
##  sim  (_physics_process, 120 Hz): input edges → player driver → TrafficBridge.step → event fan-out
##  view (_process): NPC MultiMesh interpolation, hero views, camera (real-dt smoothing), N5 icons, HUD
## TrafficBridge (res://sim/traffic_bridge.gd: C++ Traffic when the ext loads, else its GDScript creep model) is used
## when present, else the view's TrafficStub with the same interface. Honk (web main.js:1076): honkCool gate, horn SFX +
## haptic + "빵!" pop + ring, TrafficBridge.honk → reply bubble over the replying car (lines.json tables).
## Command-line (after `--`): --stage=N --seed=N --traffic=auto|stub --no-debug-panel --manual --safe-pt=TOP,BOTTOM
## (fake notch / home-indicator insets in points on desktop). Live runs write the boot line to user://boot.txt
## (Documents/ on iOS) so tools/mac/ios_run.sh can report native=true|false after launch.

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
var bubbles: Bubbles
var honk_cool: float = 1.0
var last_honk: float = -INF
var last_honk_reply: Dictionary = {}
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
var _pprev_s: float = 0.0
var _lines: Dictionary = {}
var _pick := RandomNumberGenerator.new()   # presentation-only picks (bubble lines); never touches the sim RNG
var _built: bool = false
var _safe_pt := Vector2.ZERO


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
		elif a.begins_with("--safe-pt="):
			var p: PackedStringArray = a.trim_prefix("--safe-pt=").split(",")
			_safe_pt = Vector2(p[0].to_float(), p[1].to_float() if p.size() > 1 else 0.0)
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
	var start_lane: int = int(setup.get("startLane", 3))
	if traffic.has_method(&"setup_info"):  # main.js setupStage as resolved by the sim: one source for start / front
		var si: Dictionary = traffic.call(&"setup_info")
		start_s = float(si.get("start_s", start_s))
		front_s = float(si.get("front_s", front_s))
		start_lane = int(si.get("start_lane", start_lane))
	var tune: Dictionary = cfg.get("tune", {}) if cfg.get("tune") is Dictionary else {}
	honk_cool = float(tune.get("honkCool", 1.0))
	var lt: Variant = ViewData.table("lines")
	_lines = (lt as Dictionary).get("tables", {}) if lt is Dictionary else {}
	_pick.seed = seed
	player = PlayerDriver.new()
	player.reset(start_lane, start_s)
	_pprev_s = player.s
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
	player_view.enable_beacon()
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
	honk_fx.manual = manual
	add_child(honk_fx)
	input = LaneInput.new()
	input.name = "Input"
	add_child(input)
	hud = Hud.new()
	hud.name = "Hud"
	add_child(hud)
	hud.bind_input(input)
	if _safe_pt != Vector2.ZERO:
		hud.debug_safe_pt = _safe_pt
		hud.apply_safe_area()
	hud.process_mode = Node.PROCESS_MODE_ALWAYS    # draws the pause state
	input.process_mode = Node.PROCESS_MODE_ALWAYS  # the pause button must work while paused
	input.pause_requested.connect(func() -> void: set_paused(not get_tree().paused))
	bubbles = Bubbles.new()
	bubbles.name = "Bubbles"
	bubbles.camera = camera
	hud.root.add_child(bubbles)
	hud.root.move_child(bubbles, 0)  # under the HUD widgets
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
	for hv: HeroVehicleView in _heroes():
		hv.manual = manual
	var native: bool = traffic.has_method(&"is_native") and bool(traffic.call(&"is_native"))
	var boot: String = "INFO game: stage %d seed %d traffic=%s native=%s cars=%d haptics=%s" % [stage_id, seed,
		traffic.get_script().resource_path, native, _cur.size() / 8, haptics.get_script().resource_path if haptics != null else "none"]
	print(boot)
	if not manual:
		_write_boot(boot)


## user://boot.txt = the boot line + unix time; ios_run.sh pulls it (devicectl copy from) to record native=… and
## that this launch really reached the main scene. Best effort: never fails the game.
func _write_boot(line: String) -> void:
	var f := FileAccess.open("user://boot.txt", FileAccess.WRITE)
	if f != null:
		f.store_line("%s boot_unix=%d" % [line, int(Time.get_unix_time_from_system())])
		f.close()


## Pause button / app sent to background: freezes sim and view (HUD + input keep running to resume).
func set_paused(on: bool) -> void:
	if manual or not is_inside_tree():
		return
	get_tree().paused = on
	hud.paused = on
	input.release_all()
	while input.consume_lane() != 0:
		pass


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED and _built:
		set_paused(true)


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
	_pprev_s = player.s
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


## web main.js:1076: one honk per honkCool (sim time here, so replays are deterministic); jam/boss only (M1a: jam).
func honk() -> bool:
	if sim_time - last_honk < honk_cool:
		return false
	last_honk = sim_time
	haptic("horn")
	sfx.play("horn")
	honk_fx.emit_at(road.position(player.s + 2.6, player.x))
	var roof: float = float(player_view.template.get(&"height")) if player_view.template != null else 1.6
	bubbles.pop(road.position(player.s, player.x) + Vector3(0, roof + 1.2, 0), "빵!", "warn")  # clears the yellow roof
	var r: Dictionary = traffic.call(&"honk", player.lane, player.s)
	last_honk_reply = r
	_reply_bubble(r)
	_log({"type": "honk", "reply": r})
	return true


## main.js:1085-1098 reply → bubble over the replying car (carTop(car, 0.8)).
func _reply_bubble(r: Dictionary) -> void:
	var kind: String = str(r.get("kind", ""))
	if kind.is_empty():
		return
	var id: int = int(r.get("id", -1))
	var pos: Callable = _car_top(id, 0.8)
	if kind == "villain" or not pos.call().is_finite():
		if _bridge_villains.is_empty() and not villain_views.has(id):
			return
		var hv: HeroVehicleView = villain_views[id] if villain_views.has(id) else _bridge_villains[0]
		var h: float = float(hv.template.get(&"height")) + 0.8
		pos = func() -> Vector3: return hv.global_position + Vector3(0, h, 0)
	var key: String = "h%d" % id
	match kind:
		"cheater":
			bubbles.show_bubble(key, _line("CHEATER_LINES"), "thanks", 1.4, pos)
			bubbles.pop(pos.call() + Vector3(0, 1.0, 0), "얌체 참교육 +300", "score")
		"yield":
			bubbles.show_bubble(key, _line("YIELD_LINES"), "thanks", 1.2, pos)
		"letin":
			bubbles.show_bubble(key, _line("LETIN_LINES"), "thanks", 1.2, pos)
		"noway":
			bubbles.show_bubble(key, _line("NOWAY_LINES"), "angry", 1.1, pos)
		"tired":  # main.js:1098 inline (lines.json inline main.js:1098#1)
			bubbles.show_bubble(key, _pick_of(["또 빵?", "빵빵 그만!", "귀 아파요", "들었다고요"]), "angry", 1.2, pos)
		"villain":  # main.js:1083 inline: the villain never yields
			bubbles.show_bubble(key, _pick_of(["왜 빵빵거려?", "빵빵해도 안 비켜~", "내 차선인데?"]), "taunt", 1.4, pos)


func _line(table_name: String) -> String:
	var t: Variant = _lines.get(table_name)
	return _pick_of(t as Array) if t is Array and not (t as Array).is_empty() else "!"


func _pick_of(arr: Array) -> String:
	return str(arr[_pick.randi_range(0, arr.size() - 1)])


## Live roof-top position of a buffer car (INF when the id is not in the buffer any more).
func _car_top(id: int, above: float) -> Callable:
	return func() -> Vector3:
		var n: int = _cur.size() / 8
		for k: int in n:
			if int(_cur[k * 8]) == id:
				return road.position(_cur[k * 8 + 4], _cur[k * 8 + 3]) + Vector3(0, float(_heights.get(id, 1.5)) + above, 0)
		return Vector3(INF, INF, INF)


func _log(ev: Dictionary) -> void:
	ev["t"] = sim_time
	log_events.append(ev)
	if log_events.size() > 256:
		log_events.pop_front()


## Tests / shots: run n sim ticks synchronously (no rendering), then refresh the view once. The camera target follows
## the player every tick (review: it was only set once after the loop, so shots framed the start of the call).
func advance_ticks(n: int) -> void:
	for i: int in n:
		sim_tick(TICK)
		real_time += TICK
		_sync_camera_target(player_view.global_transform)
		camera.step(TICK)
		honk_fx.advance(TICK)
		for hv: HeroVehicleView in _heroes():
			hv.advance_wheels(TICK)
	_update_view(1.0)


# ───────────────────────────── view side (every frame)

func _process(delta: float) -> void:
	if not _built:
		return
	if manual:  # the caller owns time (advance_ticks / render_step): wall-clock frame time must not leak into shots
		_update_view(1.0)
		return
	real_time += delta
	_update_view(Engine.get_physics_interpolation_fraction())
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
	player_view.set_beacon(int(floorf(sim_time / 0.18)) % 2 == 0)  # urgent: M1a is always the jam phase
	_sync_camera_target(player_view.get_global_transform_interpolated() if not manual else player_view.global_transform)
	world.update_overheads(camera.global_position)
	bubbles.avoid_rects.clear()
	var safe: Rect2 = hud.safe_rect()
	bubbles.safe_rect = safe
	icons.bounds = safe.grow(-8.0)
	icons.reserved = hud.reserved_rects()
	icons.suppress = bubbles.anchored_ids()  # the honk target's reply bubble is the signal; no icon on top of it
	if icons.visible:
		for c: Dictionary in icons.update_icons(_cur, {"s": player.s, "x": player.x, "lane": player.state()["lane"]}, real_time):
			if c.has("rect"):
				bubbles.avoid_rects.append(c["rect"])
	hud.set_state(lerpf(_pprev_s, player.s, frac), _villain_s, start_s, player.v)  # same time base as the villain
	bubbles.step(real_time)
	hud.horn_down = input.is_horn_down()


func _sync_camera_target(pxf: Transform3D) -> void:
	var pr: Vector2 = road.to_road(pxf.origin)
	camera.target_s = pr.x
	camera.target_x = pr.y
	camera.target_v = player.v


func _heroes() -> Array[HeroVehicleView]:
	var out: Array[HeroVehicleView] = [player_view]
	for hv: HeroVehicleView in villain_views.values():
		out.append(hv)
	out.append_array(_bridge_villains)
	return out


func buffer() -> PackedFloat32Array:
	return _cur
