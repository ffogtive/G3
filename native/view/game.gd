class_name Game
extends Node3D
## M1b composition root (NATIVE_PORT 3-1 view/game.gd, 3-2 fixed tick 1/120, 3-8 UI / audio / input): the playable
## 1-1 loop on GameSim (res://sim/game_sim.gd: phase machine + player + boss + weapons over TrafficBridge, C++ Traffic
## when the ext loads, else its GDScript fallback).
##
## 가설: driving GameSim at the fixed tick and rendering only from state() / events() gives a 1-1 the player can finish
##       on the phone: jam (BGM + engine) → villain appears and locks → 압정 / 분노 hit with feedback → kill → release
##       wave → result card → retry / next (test_e2e_1_1, test_phase_audio, shots in docs/NATIVE_PORT.md M1 진행 기록).
##
##  sim  (_physics_process, 120 Hz): LaneInput edges/levels → GameSim.input → GameSim.step → NPC buffer → event fan-out
##        (HUD pops/banners, FightFx, camera, icons, bubbles, Audio SFX, Haptics) → hero transforms (engine-interpolated)
##  view (_process): NPC MultiMesh lerp (prev/cur buffer, physics fraction), lamps, hazards, HUD apply_state, camera
##        (real-dt smoothing + P0#4 boss framing), engine sound.
## Phase audio = Audio.phase(p) (web enterPhase: music, ambience, go / warn / superHit / explosion / cheer, ducking);
## per-event SFX are the remaining web audio.play calls (main.js / boss.js / weapons.js), never the phase ones twice.
## Command line (after `--`): --stage=N --seed=N --autoplay --traffic=auto|fallback --no-debug-panel --manual --neck=0|1
## --safe-pt=TOP,BOTTOM (fake notch / home-indicator insets in points). Live runs write the boot line to user://boot.txt
## (Documents/ on iOS) so tools/mac/ios_run.sh can report native=true|false after launch.
## Hosting (screens/app.gd, NATIVE_PARITY 8): hosted → stage_finished(result) at the result phase (fail-card menu =
## {aborted: true}); intro_hold + begin(); loadout (Progress.loadout(); standalone live runs read Progress itself) goes
## to GameSim as tables.options.loadout (finish, items / jump / drone → item1 / item2, rage_start_segs) and the HUD
## t5 face (hud.finish_id).
## r3 (device feedback 1·3·4, docs r3 U1 / U3): every frame Hud.guard_bubbles(bubbles) hands the bubble layer the top
## HUD guard (bubbles flip under / dock below the bar, pill, villain plate, combo badge, chips); state.neck drives the
## bottleneck plug car (_sync_neck: role look — cutter left blinker, 1-4 straddle at an angle, 1-6 victim hazards, 1-10
## parked dark — and the 1.2 s exits cutin / zip / tow / fly on the sim's s / x), who "neck" bubbles anchor on it; the
## rage_horn's startled cars shake in the view on both traffic backends; a rage_horn of a 충격파 (via t1_wave, or
## SkillCues.owns_rage_horn()) plays no horn. sim_options (tests / shots, --neck=1) go to GameSim as tables.options.
##
## 가설(r3 U3): ❓ the plug only reads as "막힌 원인" when the car itself shows its intent (blinker / hazards / angle) and
##       leaves visibly (nose in → pull out, tow, fly) on the same s the sim blocks with (view s error 0).
## Skills (docs/SKILLS.md §6 뷰 훅): LaneInput 분노 tap → &"rage", item1 / item2 taps → &"item1" / &"item2", an open-screen
## tap while state.skills.skip_ready (or the HUD skip hint) → &"skip". Skill events reach Hud / FightFx (SkillFx 3D +
## SkillCues audio / haptics) / CameraRig through the fan-out below; this file plays no audio or haptics for skill_*,
## tier_ready, item_ready or finisher (SkillCues owns them), only the shared kill / rage{full} / rage_horn cues.

signal stage_finished(result: Dictionary)
signal paused_changed(on: bool)

const TICK: float = 1.0 / 120.0
const HAPTICS_PATH: String = "res://autoload/haptics.gd"
const _DB := preload("res://core/db.gd")
const TABLE_OF: Dictionary = {"frontRage": "FRONT_RAGE_LINES", "blocked": "NOWAY_LINES", "bump": "BUMP_LINES",
	"thanks": "THANKS_LINES", "cutin": "CUTIN_LINES"}
const BUBBLE_KINDS: Array[String] = ["thanks", "angry", "taunt"]

## Stage picked by the result card's "next" (survives the scene reload; standalone runs only).
static var next_stage: int = -1

var stage_id: int = 1
## < 0 → the stage's traffic seed (id * 1000 + 7), like the web.
var seed: int = -1
## true: no _physics_process stepping; the caller drives advance_ticks() / render_step() (shots, tests).
var manual: bool = false
var with_debug_panel: bool = true
## "auto" = C++ Traffic when it loads, "fallback" = force the GDScript creep model.
var traffic_mode: String = "auto"
var autoplay: bool = false
var hosted: bool = false
var intro_hold: bool = false
var loadout: Dictionary = {}
## Extra GameSim tables.options (tests / shots: {"neck": true} forces the bottleneck plug; --neck=1 on the command line).
var sim_options: Dictionary = {}

var sim: GameSim
var st: Dictionary = {}
var phase: StringName = &""
var stage: Dictionary = {}
var tables: Dictionary = {}
var cfg: Dictionary = {}
var tune: Dictionary = {}
var road: RoadGraph
var factory: VehicleFactory
var traffic: RefCounted                 # = sim.traffic() (TrafficBridge)
var player: RefCounted                  # = sim.player (PlayerSim: s, x, v, lane, lc_t, yaw …)
var world: WorldView
var npc: NpcMultiMesh
var player_view: HeroVehicleView
var villain_views: Array[HeroVehicleView] = []
var camera: CameraRig
var icons: SignalIcons
var honk_fx: HonkWave
var fx: FightFx
var hazards: HazardView
var input: LaneInput
var hud: Hud
var haptics: Node
var audio: Node
var debug_panel: DebugPanel
var bubbles: Bubbles
var last_honk_reply: Dictionary = {}
var start_s: float = 0.0
var front_s: float = 200.0
var sim_time: float = 0.0
var real_time: float = 0.0
var _prev_hop: float = 0.0
var _land_squash_t: float = -99.0
## villain index → real_time of its last hit / skill_hit (a taunt bubble over fresh damage pops was clutter, rvB).
var _vhit_t: Dictionary = {}
var ticks: int = 0
var log_events: Array[Dictionary] = []
var phase_log: Array[StringName] = []
var sfx_played: int = 0
## Names asked of sfx() (last 128, played or not; tests: the 충격파 rage_horn asks no hornTruck).
var sfx_log: Array[StringName] = []
var haptic_calls: int = 0
var event_counts: Dictionary = {}       # event type → count over the whole run (log_events keeps only the last 256)
## Tests / shots: called with every drained GameSim event after the fan-out (touch-driven runs wait on skill events).
var event_tap: Callable = Callable()
var result_shown: bool = false
var _prev := PackedFloat32Array()
var _cur := PackedFloat32Array()
var _kind_names := PackedStringArray()
var _heights: Dictionary = {}
var _hazard_cars: Dictionary = {}       # obstacle id → HeroVehicleView (shoulder breakdown car)
var _lines: Dictionary = {}
var _pick := RandomNumberGenerator.new()   # presentation-only picks (bubble lines, SFX jitter); never the sim RNG
var _built: bool = false
var _safe_pt := Vector2.ZERO
var _fail_shown: bool = false
# ── r3 U3 bottleneck plug view
var neck_view: HeroVehicleView
var _neck_car: String = ""
var _neck_beacon: bool = false
var _neck_last := Vector3(NAN, NAN, 0.0)   # (sim time, x, lateral speed) at the last plug x change
var _neck_yaw: float = 0.0
## Last placed plug pose (tests / shots: view s vs sim s, the exit pose): {s, x, y, yaw, roll, scale, phase, exit, lamps}.
var neck_pose: Dictionary = {}
## r3 U3: rage_horn startled car id → real_time (view-only shake; neither traffic backend draws its jolt).
var _jolt: Dictionary = {}
const JOLT_S: float = 0.45


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
		elif a == "--autoplay":
			autoplay = true
		elif a.begins_with("--traffic="):
			traffic_mode = a.trim_prefix("--traffic=")
		elif a.begins_with("--neck="):
			sim_options["neck"] = a.trim_prefix("--neck=") in ["1", "true", "on"]
		elif a.begins_with("--safe-pt="):
			var p: PackedStringArray = a.trim_prefix("--safe-pt=").split(",")
			_safe_pt = Vector2(p[0].to_float(), p[1].to_float() if p.size() > 1 else 0.0)
	if next_stage > 0 and not hosted:
		stage_id = next_stage
		next_stage = -1
	build()


func build() -> void:
	if _built:
		return
	_built = true
	stage = ViewData.stage(stage_id)
	if stage.is_empty():
		stage_id = 1
		stage = ViewData.stage(1)
	tables = _DB.load_traffic_tables()
	if loadout.is_empty() and not manual and not hosted:  # standalone live run: the saved garage
		var prog: Node = get_tree().root.get_node_or_null(^"Progress") if is_inside_tree() else null
		if prog != null and prog.has_method(&"loadout"):
			loadout = prog.call(&"loadout")
	var opts: Dictionary = {"loadout": loadout}
	if intro_hold:
		opts["intro_hold"] = true
	opts.merge(sim_options, true)
	tables["options"] = opts
	cfg = tables.get("config", {}) if tables.get("config") is Dictionary else {}
	tune = cfg.get("tune", {}) if cfg.get("tune") is Dictionary else {}
	var lt: Variant = ViewData.table("lines")
	_lines = (lt as Dictionary).get("tables", {}) if lt is Dictionary else {}
	sim = GameSim.new()
	sim.force_fallback = traffic_mode == "fallback"
	sim.setup(stage, tables, seed)
	seed = sim.seed
	if autoplay:
		sim.autopilot = Autopilot.new(seed * 13 + 1)
	_pick.seed = seed
	traffic = sim.traffic()
	player = sim.player
	start_s = sim.start_s
	front_s = sim.front_s
	road = RoadGraph.new(stage.get("road", []) if stage.get("road") is Array else [])
	factory = VehicleFactory.new()
	_kind_names = sim.traffic().kind_names()
	if manual:
		physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF  # the caller owns time: no engine lerp

	world = WorldView.new()
	world.name = "World"
	add_child(world)
	world.build(stage, factory, road, {"startS": start_s, "frontS": front_s}, sim.traffic().obstacles())
	_breakdown_cars(sim.traffic().obstacles())
	sim.traffic().read_into(_cur)
	_prev = _cur.duplicate()
	npc = NpcMultiMesh.new()
	npc.name = "Npc"
	add_child(npc)
	npc.setup(factory, road, _specs())

	player_view = HeroVehicleView.new()
	player_view.name = "Player"
	add_child(player_view)
	player_view.setup(factory, "player", 0)
	player_view.enable_beacon()
	st = sim.state()
	for v: Dictionary in st["villains"]:
		var hv := HeroVehicleView.new()
		hv.name = "Villain%d" % int(v["id"])
		add_child(hv)
		hv.setup(factory, str(v.get("kind", "villainSedan")), 0, v.get("color"))
		villain_views.append(hv)
	_place_heroes()

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
	hazards = HazardView.new()
	hazards.name = "Hazards"
	add_child(hazards)
	hazards.setup(road)
	fx = FightFx.new()
	fx.name = "FightFx"
	fx.manual = manual
	add_child(fx)
	fx.setup(road, seed, tune, sim.front_s, sim.tail_s)
	fx.camera_rig = camera
	input = LaneInput.new()
	input.name = "Input"
	add_child(input)
	hud = Hud.new()
	hud.name = "Hud"
	hud.manual = manual
	add_child(hud)
	hud.bind_input(input)
	hud.bind_world(camera, road)
	hud.stage = stage
	hud.rage_cost = float(tune.get("superCost", 0.2))
	hud.finish_id = str(loadout.get("finish", "")) if str(loadout.get("finish", "")) != "" else str(sim.bc.get("finish", "rocket"))
	hud.card_choice.connect(_on_card)
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
	haptics = _haptics()
	audio = get_tree().root.get_node_or_null(^"Audio")
	if with_debug_panel and OS.is_debug_build():
		debug_panel = DebugPanel.new()
		debug_panel.name = "DebugPanel"
		debug_panel.world = world
		debug_panel.factory = factory
		debug_panel.icons = icons
		add_child(debug_panel)
		input.debug_requested.connect(debug_panel.toggle)
	var vp: Viewport = get_viewport()
	if "use_debanding" in vp:
		vp.set(&"use_debanding", true)
	vp.msaa_3d = Viewport.MSAA_4X
	_update_view(1.0)
	camera.snap()
	for hv: HeroVehicleView in _heroes():
		hv.manual = manual
	var boot: String = "INFO game: stage %d seed %d traffic=%s native=%s cars=%d haptics=%s audio=%s autoplay=%s" % [stage_id, seed,
		traffic.get_script().resource_path, sim.traffic().is_native(), _cur.size() / 8,
		haptics.get_script().resource_path if haptics != null else "none", audio != null, autoplay]
	print(boot)
	if not manual:
		_write_boot(boot)


## app.gd G2: the card's start releases a held intro.
func begin() -> void:
	intro_hold = false
	if sim != null:
		sim.input(&"continue")


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
	paused_changed.emit(on)


## Leaving the game (reload for retry / next, back to the host's menu, test teardown): the game's music, ambience and
## engine stop with it (the next scene / screen requests its own).
func _exit_tree() -> void:
	if audio != null and audio.has_method(&"stop_all"):
		audio.call(&"stop_all")


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED and _built:
		set_paused(true)


## shoulder.js breakdown: the car sits 2.4 m ahead of the obstacle centre, yawed by detail.rotY, hazards blinking
## (traffic.js:469 floor(2t) % 2); not part of the traffic buffer, so it is a static hero view (hidden on smash / tow).
func _breakdown_cars(obstacles: Array) -> void:
	for hv: HeroVehicleView in _hazard_cars.values():
		hv.queue_free()
	_hazard_cars.clear()
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
		hv.manual = manual
		_hazard_cars[int((o as Dictionary).get("id", -1))] = hv


func _haptics() -> Node:
	var n: Node = get_tree().root.get_node_or_null(^"Haptics")
	if n != null:
		return n
	if ResourceLoader.exists(HAPTICS_PATH):  # not registered as an autoload (stripped builds): host it here
		var h: Node = (load(HAPTICS_PATH) as Script).new()
		h.name = "Haptics"
		add_child(h)
		return h
	return null


func haptic(event_name: String) -> void:
	haptic_calls += 1
	if haptics != null and haptics.has_method(&"haptic"):
		haptics.call(&"haptic", event_name)


## One web audio.play: Audio autoload (pan / volume / pitch opts). Counted for tests.
func sfx(name: StringName, opts: Dictionary = {}) -> void:
	sfx_log.append(name)
	if sfx_log.size() > 128:
		sfx_log.pop_front()
	if audio != null and bool(audio.call(&"sfx", name, opts)):
		sfx_played += 1


## id → {kind, variant, color} for every car in the NPC buffer (TrafficBridge.car_specs(), else a variant from the id).
func _specs() -> Dictionary:
	var by_id: Dictionary = {}
	for d: Dictionary in sim.traffic().car_specs():
		by_id[int(d["id"])] = d
	var out: Dictionary = {}
	for k: int in _cur.size() / 8:
		var id: int = int(_cur[k * 8])
		var ki: int = int(_cur[k * 8 + 1])
		var kind: String = _kind_names[ki] if ki >= 0 and ki < _kind_names.size() else "sedan"
		var sp: Dictionary = {}
		if by_id.has(id):
			var d: Dictionary = by_id[id]
			sp = {"kind": str(d.get("kind_name", kind)), "variant": int(d.get("variant", 0)), "color": int(d.get("color", 0xf4f4f2))}
		else:
			sp = {"kind": kind, "variant": factory.variant_for_seed(kind, id * 7919), "color": 0xf4f4f2}
		var tpl: Resource = factory.template(str(sp["kind"]), int(sp.get("variant", 0)))
		_heights[id] = float(tpl.get(&"height"))
		out[id] = sp
	return out


# ───────────────────────────── sim side (fixed tick)

func _physics_process(_delta: float) -> void:
	if manual or not _built:
		return
	sim_tick(TICK)


func _route_input() -> void:
	if autoplay:  # the autopilot feeds GameSim itself; touches would fight it
		while input.consume_lane() != 0:
			pass
		input.consume_horn()
		input.consume_rage()
		input.consume_fire()
		input.consume_item(1)
		input.consume_item(2)
		input.consume_skip()
		return
	var d: int = input.consume_lane()
	if d != 0:
		sim.input(&"lane", d)
	if input.consume_horn():
		sim.input(&"honk")
	if input.consume_rage():
		sim.input(&"rage")
	if input.consume_item(1):
		sim.input(&"item1")
	if input.consume_item(2):
		sim.input(&"item2")
	if input.consume_skip():
		sim.input(&"skip")
	var edge: bool = input.consume_fire()
	sim.input(&"fire", input.is_fire_down() or edge)  # the edge catches taps shorter than one tick
	sim.input(&"brake", input.is_brake_down())


func sim_tick(dt: float) -> void:
	_route_input()
	var tmp: PackedFloat32Array = _prev
	_prev = _cur
	_cur = tmp
	sim.step(dt)
	sim.traffic().read_into(_cur)
	if _prev.size() != _cur.size():
		_prev = _cur.duplicate()
	sim_time = sim.time
	ticks += 1
	st = sim.state()
	for e: Dictionary in sim.events():
		_on_event(e)
	_place_heroes()


## Player + villains from state() (set on the tick; the engine interpolates them between ticks when not manual).
func _place_heroes() -> void:
	var p: Dictionary = st["player"]
	var yaw: float = float(p.get("yaw", 0.0)) + float(p.get("spin", 0.0))
	var pxf: Transform3D = road.world(float(p["s"]), float(p["x"]), yaw)
	pxf.basis = pxf.basis * Basis(Vector3.FORWARD, float(p.get("roll", 0.0)))
	var hop: float = float(p.get("hop", 0.0))
	pxf.origin.y += hop
	# mv_jump air (rvB, view only): from the high boss camera a 3.4 m hop barely changed the car, so the jump read only
	# as a landing burst. Grow it toward the camera (1.25× at the apex), nose up while rising, squash on landing.
	var k: float = clampf((hop - 0.5) / 2.9, 0.0, 1.0)
	if k > 0.0:
		var rising: float = 1.0 if hop > _prev_hop else 0.0
		pxf.basis = pxf.basis * Basis(Vector3.RIGHT, deg_to_rad(10.0) * k * rising) * Basis.from_scale(Vector3.ONE * (1.0 + 0.25 * k))
	elif _prev_hop >= 0.5:
		_land_squash_t = real_time
	if real_time - _land_squash_t < 0.08:
		pxf.basis = pxf.basis * Basis.from_scale(Vector3(1.06, 0.85, 1.06))
	_prev_hop = hop
	player_view.transform = pxf
	player_view.speed = float(p["v"])
	var vs: Array = st["villains"]
	for i: int in mini(vs.size(), villain_views.size()):
		var v: Dictionary = vs[i]
		var hv: HeroVehicleView = villain_views[i]
		var xf: Transform3D = road.world(float(v["s"]), float(v["x"]), float(v.get("yaw", 0.0)))
		xf.origin.y += float(v.get("y", 0.0))
		var rot: Variant = v.get("rot")
		if rot is Vector3 and (rot as Vector3) != Vector3.ZERO:
			xf.basis = xf.basis * Basis.from_euler(rot as Vector3)
		else:
			xf.basis = xf.basis * Basis.from_euler(Vector3(float(v.get("tilt_x", 0.0)), 0.0, float(v.get("tilt_z", 0.0))))
		hv.transform = xf
		var bv: Dictionary = sim.boss.villains[i] if i < sim.boss.villains.size() else {}
		hv.speed = 0.0 if bool(v.get("parked", false)) else maxf(0.0, float(bv.get("v", 0.0)))


func _snap_heroes() -> void:
	for hv: HeroVehicleView in _heroes():
		hv.reset_physics_interpolation()


# ───────────────────────────── event fan-out (one drained GameSim event)

func _on_event(e: Dictionary) -> void:
	_log(e)
	event_counts[str(e.get("type", ""))] = int(event_counts.get(str(e.get("type", "")), 0)) + 1
	hud.on_event(e)
	fx.on_event(e, st)
	camera.on_event(e)
	icons.on_event(e, real_time)
	var p: Dictionary = st.get("player", {})
	if str(e.get("type", "")) in ["hit", "skill_hit"] and int(e.get("target_id", -1)) >= 0:
		_vhit_t[int(e["target_id"])] = real_time
	match str(e.get("type", "")):
		"phase":
			_enter_phase(StringName(str(e.get("phase", ""))))
		"lane":
			haptic("laneChange")
			sfx(&"laneChange", {"volume": 0.5})
		"honk":
			_honk_fx()
		"honk_reply":
			last_honk_reply = {"kind": str(e.get("data", "")), "id": int(e.get("id", 0))}
			if not bool(e.get("neck", false)):  # the bottleneck answers with its own bubble event (anchored on the plug)
				_reply_bubble(last_honk_reply)
		"fire":
			if bool(e.get("drone", false)):  # the passive drone's shots: a light tick, no thumb buzz (that is the player's 압정)
				sfx(&"tack", {"volume": 0.3, "pitch": 1.25 + _pick.randf() * 0.15})
			else:
				haptic("fire")
				sfx(&"tack", {"volume": 0.6, "pitch": 0.9 + _pick.randf() * 0.25})
		"bomb":
			haptic("rageFire")
			sfx(&"super")
		"hit":
			_on_hit(e)
		"miss":
			haptic("miss")
			sfx(&"bump", {"volume": 0.25, "pitch": 0.7})
		"damage":
			var cause: String = str(e.get("cause", ""))
			haptic("playerHitBoss" if cause in ["lunge", "highbeam", "horn", "smoke", "swerve"] else
				"playerBump" if cause in ["bump", "cone"] else "playerHitThrow" if not cause.is_empty() else "damage")
			sfx(&"bump")
		"bump":
			if int(e.get("dmg", 0)) <= 0:  # damage already played the thud
				haptic("playerBump")
				sfx(&"bump", {"volume": 0.6})
		"attack":
			match str(e.get("kind", "")):
				"highbeam":
					sfx(&"warn")
				"horn":
					sfx(&"hornAngry")
				"lunge":
					sfx(&"warn")
					sfx(&"brakeScreech", {"volume": 0.5, "delay": 0.4})
				"throw":
					sfx(&"throw")
		"stun":
			haptic("crit")
			sfx(&"crit")
		"boss_phase":
			haptic("bossPhase")
			sfx(&"hornAngry", {"volume": 0.8})
		"kill":
			haptic("villainKill" if bool(e.get("last", true)) else "villainDownOne")
			sfx(&"explosion")
		"gone":
			sfx(&"twinkle")
		"smash", "tow", "auto_tow":
			var id: int = int(e.get("id", -1))
			if _hazard_cars.has(id):
				(_hazard_cars[id] as HeroVehicleView).visible = false
			haptic("shoulderSmash")
			sfx(&"pop" if str(e["type"]) == "smash" else &"whoosh")
		"rage":
			if bool(e.get("full", false)):
				haptic("rageFull")
				sfx(&"rageFull", {"volume": 0.7})
		"rage_horn":
			haptic("rageFire")
			# r3 F1/C3: the pre-lock 충격파 also clears the shoulder (rage_horn via t1_wave); SkillCues plays the wave, so the
			# horn must not sound here (device feedback 2: "분노가 경적처럼 보임")
			var wave: bool = str(e.get("via", "")) == "t1_wave" or (fx.cues != null and fx.cues.has_method(&"owns_rage_horn")
				and bool(fx.cues.call(&"owns_rage_horn")))
			if not wave:
				sfx(&"hornTruck")
				sfx(&"superHit", {"volume": 0.55})
			var stl: Variant = e.get("startled")
			if stl is PackedInt32Array or stl is Array:
				for id: Variant in stl:
					_jolt[int(id)] = real_time
		"cutin":
			sfx(&"cutin")
		"release":
			haptic("release")
		"wreck":
			haptic("wreck")
		"retry":
			_on_retry()
		"bubble":
			_bubble(e, p)
	if event_tap.is_valid():
		event_tap.call(e)


func _on_hit(e: Dictionary) -> void:
	var kind: String = str(e.get("kind", "tack"))
	if kind == "mini":
		haptic("miniCaught")
		sfx(&"pop")
		return
	if int(e.get("popped", 0)) > 0:
		haptic("tirePop")
		sfx(&"pop")
	elif kind == "bomb":
		haptic("rageHit")
		sfx(&"superHit")
	elif bool(e.get("window", false)):
		haptic("crit")
		sfx(&"crit", {"volume": 0.8})
	else:
		haptic("tackHit")
		if sim.hits % 2 == 0:  # main.js:613
			sfx(&"hit", {"volume": 0.55, "pitch": 0.9 + _pick.randf() * 0.3})


func _enter_phase(p: StringName) -> void:
	phase = p
	phase_log.append(p)
	if audio != null:
		audio.call(&"phase", p)
	match p:
		&"result":
			sfx(&"stageClear")
			_show_result()
		&"fail":
			_fail_shown = true
			hud.show_fail({})
		&"jam", &"boss":
			_fail_shown = false


func _show_result() -> void:
	if result_shown:
		return
	result_shown = true
	var res: Dictionary = st.get("result", {})
	if hosted:
		stage_finished.emit(res)
		return
	var rec: Dictionary = {}
	var prog: Node = get_tree().root.get_node_or_null(^"Progress") if not manual else null
	if prog != null and prog.has_method(&"record_result"):
		rec = prog.call(&"record_result", stage_id, res)
	hud.show_result(res, rec, stage)


## Result / fail card buttons (Hud.card_choice).
func _on_card(c: StringName) -> void:
	match c:
		&"retry":
			if phase == &"fail":
				sim.input(&"retry")
				hud.hide_cards()
			else:
				_restart(stage_id)
		&"next":
			var nxt: Dictionary = ViewData.stage(stage_id + 1)
			_restart(stage_id + 1 if not nxt.is_empty() else 1)
		&"menu":
			if hosted:
				stage_finished.emit({"aborted": true} if phase == &"fail" else st.get("result", {}))
			else:
				_restart(stage_id)


func _restart(id: int) -> void:
	_log({"type": "restart", "stage": id})
	if manual or hosted or not is_inside_tree():
		return
	next_stage = id
	get_tree().paused = false
	get_tree().reload_current_scene()


## R1 retry: the jam was re-spawned inside GameSim (same ids / specs, obstacles back): rebuild what the view cached.
func _on_retry() -> void:
	_cur.clear()
	sim.traffic().read_into(_cur)
	_prev = _cur.duplicate()
	npc.setup(factory, road, _specs())
	_breakdown_cars(sim.traffic().obstacles())
	_place_heroes()
	_snap_heroes()
	camera.snap()
	_fail_shown = false


## web main.js:1076 honk feedback (the sim already applied honkCool and the reply).
func _honk_fx() -> void:
	haptic("horn")
	sfx(&"horn", {"volume": 0.7})
	var p: Dictionary = st["player"]
	honk_fx.emit_at(road.position(float(p["s"]) + 2.6, float(p["x"])))
	var roof: float = float(player_view.template.get(&"height")) if player_view.template != null else 1.6
	bubbles.pop(road.position(float(p["s"]), float(p["x"])) + Vector3(0, roof + 1.2, 0), "빵!", "warn")  # clears the yellow roof


## main.js:1085-1098 reply → bubble over the replying car (carTop(car, 0.8)).
func _reply_bubble(r: Dictionary) -> void:
	var kind: String = str(r.get("kind", ""))
	if kind.is_empty():
		return
	var id: int = int(r.get("id", -1))
	var pos: Callable = _car_top(id, 0.8)
	if not (pos.call() as Vector3).is_finite():
		return
	var key: String = "h%d" % id
	match kind:
		"cheater":
			bubbles.show_bubble(key, _line("CHEATER_LINES"), "thanks", 1.4, pos)
			bubbles.pop((pos.call() as Vector3) + Vector3(0, 1.0, 0), "얌체 참교육 +300", "score")
			sfx(&"star", {"pitch": 1.3})
		"yield":
			bubbles.show_bubble(key, _line("YIELD_LINES"), "thanks", 1.2, pos)
		"letin":
			bubbles.show_bubble(key, _line("LETIN_LINES"), "thanks", 1.2, pos)
		"noway":
			bubbles.show_bubble(key, _line("NOWAY_LINES"), "angry", 1.1, pos)
		"tired":  # main.js:1098 inline
			bubbles.show_bubble(key, _pick_of(["또 빵?", "빵빵 그만!", "귀 아파요", "들었다고요"]), "angry", 1.2, pos)


## GameSim bubble {who: villain|car|player, id, text | table, kind, dur}: speech bubbles anchored over cars,
## floating pops over the player (and for non-speech kinds).
func _bubble(e: Dictionary, p: Dictionary) -> void:
	var text: String = str(e.get("text", ""))
	if text.is_empty():
		text = _line(str(TABLE_OF.get(str(e.get("table", "")), "")))
	if text.is_empty() or text == "!":
		return
	var kind: String = str(e.get("kind", "taunt"))
	var dur: float = float(e.get("dur", 1.2))
	var who: String = str(e.get("who", "player"))
	var id: int = int(e.get("id", -1))
	var pos: Callable
	match who:
		"villain":
			if sim.phase == &"kill" and not str(stage.get("defeatLine", "")).is_empty():
				return  # the "참교육 완료!" banner already carries the defeat line (two copies overlapped)
			if kind == "taunt" and (real_time - float(_vhit_t.get(id, -99.0)) < 0.8 or hud._under_skill(id)):
				return  # a taunt over fresh damage pops on the same ~80 px was clutter (rvB)
			var hv: HeroVehicleView = _villain_view(id)
			if hv == null:
				return
			var h: float = float(hv.template.get(&"height")) + 0.8
			pos = func() -> Vector3: return hv.global_position + Vector3(0, h, 0)
			if kind == "taunt":
				sfx(&"tauntBlip")
		"car":
			pos = _car_top(id, 0.8)
			if str(e.get("table", "")) == "blocked":
				sfx(&"hornShort", {"volume": 0.5})
		"neck":  # r3 U3: over the plug car (its live view, else its sim s / x)
			pos = _neck_top(0.8)
		_:
			var roof: float = float(player_view.template.get(&"height")) + 1.4
			var pv: HeroVehicleView = player_view
			pos = func() -> Vector3: return pv.global_position + Vector3(0, roof, 0)
	if not (pos.call() as Vector3).is_finite():
		return
	if who != "player" and kind in BUBBLE_KINDS:
		bubbles.show_bubble("%s%d" % ["v" if who == "villain" else "h", id], text, kind, dur, pos)
	else:
		bubbles.pop(pos.call() as Vector3, text, "dmg" if kind == "bump" else "score" if kind == "score" else "warn")


func _villain_view(id: int) -> HeroVehicleView:
	var vs: Array = st.get("villains", [])
	for i: int in mini(vs.size(), villain_views.size()):
		if int((vs[i] as Dictionary).get("id", -2)) == id:
			return villain_views[i]
	return villain_views[0] if not villain_views.is_empty() else null


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


## Tests / shots: run n sim ticks synchronously, the camera / FX / HUD on the same fixed dt, then refresh the view once.
## FightFx runs on sim time (hit-stop freezes it, slow-mo slows it: Σ TICK × the tick's time scale), like its _process.
func advance_ticks(n: int) -> void:
	var fx_dt: float = 0.0
	for i: int in n:
		sim_tick(TICK)
		real_time += TICK
		fx_dt += TICK * (sim.time_scale() if fx.use_sim_time else 1.0)
		honk_fx.advance(TICK)
		for hv: HeroVehicleView in _heroes():
			hv.advance_wheels(TICK)
	if manual:
		fx.advance(fx_dt)
		fx.cues.advance(TICK * n)  # haptic beats are real time (process is off when manual)
		hud.advance(TICK * n)
	_update_view(1.0)
	camera.step(TICK * n)


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
	if audio != null and not get_tree().paused:
		var p: Dictionary = st.get("player", {})
		audio.call(&"engine", maxf(0.0, float(p.get("v", 0.0))), phase == &"jam" and not bool(p.get("brake", false)))


func render_step(real_dt: float) -> void:
	st = sim.state()
	_update_view(1.0)
	camera.step(real_dt)


func _update_view(frac: float) -> void:
	npc.lamp_time = sim_time
	icons.lamp_time = sim_time
	var relay: Variant = st.get("relay_lit", PackedInt32Array())
	if relay is PackedInt32Array and not (relay as PackedInt32Array).is_empty():  # occupy relay: NPC high beams
		var lit: Dictionary = {}
		for id: int in relay as PackedInt32Array:
			lit[id] = true
		for k: int in _cur.size() / 8:
			if lit.has(int(_cur[k * 8])):
				_cur[k * 8 + 7] = float(int(_cur[k * 8 + 7]) | HeroVehicleView.BIT_HIGHBEAM)
	if _jolt.is_empty():
		npc.sync(_prev, _cur, frac)
	else:  # rage_horn startled cars shake (view only: copies, the sim buffer stays as read)
		var jp: PackedFloat32Array = _prev.duplicate()
		var jc: PackedFloat32Array = _cur.duplicate()
		_apply_jolt(jp)
		_apply_jolt(jc)
		npc.sync(jp, jc, frac)
	var p: Dictionary = st["player"]
	var ph: StringName = StringName(str(st.get("phase", "jam")))
	var jam_like: bool = ph in [&"intro", &"jam"] or (ph == &"boss" and not bool((st.get("lock", {}) as Dictionary).get("active", false)))
	# villains: lamps (brake while blocking, high-beam telegraph, right blinker on the pull-over), flash, burst tyres
	var vs: Array = st["villains"]
	for i: int in mini(vs.size(), villain_views.size()):
		var v: Dictionary = vs[i]
		var hv: HeroVehicleView = villain_views[i]
		hv.visible = not bool(v.get("gone", false))
		var bits: int = (1 if bool(v.get("alive", false)) else 0) | (HeroVehicleView.BIT_HIGHBEAM if bool(v.get("headlights", false)) else 0) \
			| (4 if int(v.get("blinker", 0)) != 0 else 0)
		hv.set_lamps(NpcMultiMesh.drawn_bits(bits, sim_time, 999 + i))
		hv.set_flash(float(v.get("flash", 0.0)))
		hv.set_flat(v.get("popped", []) if v.get("popped") is Array else [])
	var hz: int = 16 if int(floorf(sim_time * 2.0)) % 2 == 0 else 0
	for hv: HeroVehicleView in _hazard_cars.values():
		hv.set_lamps(hz)
	_sync_neck()
	# player: brake light (held / creeping), blinker while changing lanes, hazards when wrecked, beacon when urgent
	var pl: PlayerSim = sim.player
	var pbits: int = 1 if bool(p.get("brake", false)) or (jam_like and float(p["v"]) < 1.6) else 0
	if pl.lc_t < 1.0:
		pbits |= 2 if pl.lc_dir < 0 else 4
	if ph in [&"wreck", &"fail"]:
		pbits |= 16
	player_view.set_lamps(NpcMultiMesh.drawn_bits(pbits, sim_time, 0))
	player_view.set_beacon(ph in [&"intro", &"jam", &"boss"] and int(floorf(sim_time / 0.18)) % 2 == 0)
	camera.apply_state(st)
	_sync_camera_target(player_view.get_global_transform_interpolated() if not manual else player_view.global_transform)
	world.update_overheads(camera.global_position)
	fx.sync(st, _cur)
	hazards.sync(st)
	hud.apply_state(st)
	var sk: Dictionary = st.get("skills", {}) if st.get("skills") is Dictionary else {}
	input.skip_armed = bool(sk.get("skip_ready", false)) or hud.skip_hint_visible()
	hud.villain_s = sim.boss.ref_s()
	hud.start_s = start_s
	hud.horn_down = input.is_horn_down()
	bubbles.avoid_rects.clear()
	var safe: Rect2 = hud.safe_rect()
	bubbles.safe_rect = safe
	hud.guard_bubbles(bubbles)  # r3 U1: top guard + top HUD rects (flip / dock instead of covering the bar)
	icons.bounds = safe.grow(-8.0)
	icons.reserved = hud.reserved_rects()
	icons.suppress = bubbles.anchored_ids()  # the honk target's reply bubble is the signal; no icon on top of it
	if icons.visible:
		var buf: PackedFloat32Array = _cur if jam_like else PackedFloat32Array()  # N5 signals are jam reading aids
		for c: Dictionary in icons.update_icons(buf, {"s": float(p["s"]), "x": float(p["x"]), "lane": int(p["lane"])}, real_time):
			if c.has("rect"):
				bubbles.avoid_rects.append(c["rect"])
	bubbles.step(real_time)


## Startled cars (rage_horn) wobble sideways and yaw for JOLT_S after the horn (web car.bumpJolt look).
func _apply_jolt(buf: PackedFloat32Array) -> void:
	var done: Array = []
	for id: int in _jolt:
		var age: float = real_time - float(_jolt[id])
		if age >= JOLT_S:
			done.append(id)
			continue
		var k: float = 1.0 - age / JOLT_S
		for r: int in buf.size() / 8:
			if int(buf[r * 8]) == id:
				buf[r * 8 + 3] += 0.16 * sin(age * 55.0) * k
				buf[r * 8 + 5] += 0.07 * sin(age * 47.0 + 1.3) * k
				break
	for id: Variant in done:
		_jolt.erase(id)


## Live roof position of the bottleneck plug (its view when built, else the sim s / x); INF when there is none.
func _neck_top(above: float) -> Callable:
	return func() -> Vector3:
		var n: Dictionary = st.get("neck", {}) if st.get("neck") is Dictionary else {}
		if not n.has("s") or str(n.get("phase", "gone")) == "gone":
			return Vector3(INF, INF, INF)
		if neck_view != null and neck_view.visible:
			return neck_view.global_position + Vector3(0, float(neck_view.template.get(&"height")) + above, 0)
		return road.position(float(n["s"]), float(n["x"])) + Vector3(0, 1.5 + above, 0)


## r3 U3: the plug car from state.neck {s, x, kind (role), car, phase, exit, exit_t, blinker, v}. s / x are the sim's
## every frame (view error 0); yaw follows its lateral speed (cutin / zip nose into lane 3, the race / push side step),
## 1-4 straddles at an angle; lamps by role (cutter / straddle left blinker while it waits, victim hazards, parked dark,
## phone brake light); exits over exitDur: cutin / zip blink left and pull out on the sim path, tow = hazards + an
## amber beacon and it shrinks away at the end, fly (rage t1) = flung up in an arc, rolling and spinning.
func _sync_neck() -> void:
	var n: Dictionary = st.get("neck", {}) if st.get("neck") is Dictionary else {}
	var ph: String = str(n.get("phase", "gone"))
	if not n.has("s") or ph == "gone":
		if neck_view != null:
			neck_view.visible = false
		neck_pose = {}
		return
	var car: String = str(n.get("car", "sedan"))
	var role: String = str(n.get("kind", "cutter"))
	if neck_view == null or car != _neck_car:
		if neck_view != null:
			neck_view.queue_free()
		_neck_car = car
		neck_view = HeroVehicleView.new()
		neck_view.name = "NeckPlug"
		add_child(neck_view)
		var col: int = {"victim": 0xeeeeea, "parked": 0x6b7280, "phone": 0x3a6ea5, "straddle": 0x2d3a4a}.get(role, 0xb8bcc2)
		neck_view.setup(factory, car, factory.variant_for_seed(car, 1000 + stage_id), col)
		neck_view.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF  # placed from the sim every frame
		neck_view.manual = manual
		_neck_beacon = false
		_neck_last = Vector3(NAN, NAN, 0.0)
		_neck_yaw = 0.0
	neck_view.visible = true
	var s: float = float(n["s"])
	var x: float = float(n["x"])
	var v: float = maxf(0.0, float(n.get("v", 0.0)))
	var ex: String = str(n.get("exit", "")) if ph == "open" else ""
	var dur: float = maxf(0.1, float(sim.neck.pc.get("exitDur", 1.2))) if sim.neck != null and "pc" in sim.neck else 1.2
	var t: float = clampf(float(n.get("exit_t", 0.0)) / dur, 0.0, 1.0) if ph == "open" else 0.0
	# lateral speed from the sim x (per sim time, so manual shots and live frames agree)
	if is_nan(_neck_last.x) or sim_time < _neck_last.x:
		_neck_last = Vector3(sim_time, x, 0.0)
	elif sim_time > _neck_last.x + 1e-6 and not is_equal_approx(x, _neck_last.y):
		_neck_last = Vector3(sim_time, x, (x - _neck_last.y) / (sim_time - _neck_last.x))
	elif sim_time > _neck_last.x + 0.1:
		_neck_last = Vector3(sim_time, x, 0.0)
	var yaw_t: float = clampf(atan2(-_neck_last.z, maxf(3.0, v)), -0.35, 0.35)  # + yaw = nose toward lane 3 (−x)
	if role == "straddle" and ph != "open":
		yaw_t += 0.2
	elif role == "cutter" and ph in ["block", "yield"]:
		yaw_t += 0.05  # angled at the gap it wants
	_neck_yaw = lerpf(_neck_yaw, yaw_t, 0.35)
	var yaw: float = _neck_yaw
	var y: float = 0.0
	var roll: float = 0.0
	var sc: float = 1.0
	match ex:
		"fly":  # flung up and away, rolling over (rage)
			y = 4.2 * sin(PI * minf(1.0, t * 1.15)) + 1.2 * t
			roll = t * TAU * 1.25
			yaw += t * 2.4
		"tow":
			if t > 0.7:
				sc = maxf(0.02, 1.0 - (t - 0.7) / 0.3)
	var bits: int = 0
	match role:
		"victim":
			bits |= 16
		"phone":
			bits |= 1
		"cutter", "straddle":
			if ph in ["block", "yield"]:
				bits |= 2
	if int(n.get("blinker", 0)) != 0:
		bits |= 2
	if ex in ["cutin", "zip"]:
		bits = (bits & ~16) | 2
	elif ex == "tow":
		bits |= 16
	elif ex == "fly":
		bits = 0
	if role != "parked" and v < 1.0 and ex != "fly":
		bits |= 1
	if role == "parked" and ex != "tow":
		bits = 0
	if ex == "tow" and not _neck_beacon:
		neck_view.enable_beacon()
		_neck_beacon = true
	if _neck_beacon:
		neck_view.set_beacon(ex == "tow" and int(floorf(sim_time / 0.18)) % 2 == 0)
	neck_view.set_lamps(NpcMultiMesh.drawn_bits(bits, sim_time, 1777))
	neck_view.speed = v
	var xf: Transform3D = road.world(s, x, yaw)
	xf.origin.y += y
	if roll != 0.0:
		xf.basis = xf.basis * Basis(Vector3.FORWARD, roll)
	if sc != 1.0:
		xf.basis = xf.basis * Basis.from_scale(Vector3.ONE * sc)
	neck_view.transform = xf
	neck_pose = {"s": s, "x": x, "y": y, "yaw": yaw, "roll": roll, "scale": sc, "phase": ph, "exit": ex, "t": t, "lamps": bits,
		"role": role, "car": car}


func _sync_camera_target(pxf: Transform3D) -> void:
	var pr: Vector2 = road.to_road(pxf.origin)
	camera.target_s = pr.x
	camera.target_x = pr.y
	camera.target_v = float((st.get("player", {}) as Dictionary).get("v", 0.0))


func _heroes() -> Array[HeroVehicleView]:
	var out: Array[HeroVehicleView] = [player_view]
	out.append_array(villain_views)
	return out


func buffer() -> PackedFloat32Array:
	return _cur
