class_name DebugPanel
extends CanvasLayer
## Dev-build render A/B panel (NATIVE_PORT M1a 중단·분기 기준: tonemap, ambient, shadows, glow, MSAA, AO) + live
## fps / frame ms / draw calls / primitives. Created by game.gd only when OS.is_debug_build(); toggled with F1 or
## the small DBG tab. Every switch is also reachable from code (apply()) so shot_jam.gd can render A/B variants.

const TONEMAPS: Array[String] = ["Linear", "AgX", "Filmic"]
const AMBIENTS: Array[String] = ["Sky", "Hemi", "Flat"]
const MSAAS: Array[String] = ["Off", "2x", "4x"]
const AO_ON: float = 0.6  # voxel.gdshader default ao_strength

var world: WorldView
var factory: VehicleFactory
var icons: SignalIcons
var state: Dictionary = {"tonemap": 0, "ambient": 0, "shadows": true, "glow": true, "msaa": 2, "ao": true, "icons": true}
var _panel: PanelContainer
var _stats: Label
var _buttons: Dictionary = {}
var _acc: float = 0.0
var _frames: int = 0


func _ready() -> void:
	layer = 20
	var tab := Button.new()
	tab.text = "DBG"
	tab.position = Vector2(8, 96)
	tab.focus_mode = Control.FOCUS_NONE
	tab.pressed.connect(func() -> void: _panel.visible = not _panel.visible)
	add_child(tab)
	_panel = PanelContainer.new()
	_panel.position = Vector2(8, 132)
	_panel.visible = false
	add_child(_panel)
	var box := VBoxContainer.new()
	_panel.add_child(box)
	_stats = Label.new()
	_stats.add_theme_font_size_override(&"font_size", 13)
	box.add_child(_stats)
	_add(box, "tonemap", func() -> String: return "Tonemap: " + TONEMAPS[int(state["tonemap"])],
		func() -> void: state["tonemap"] = (int(state["tonemap"]) + 1) % TONEMAPS.size())
	_add(box, "ambient", func() -> String: return "Ambient: " + AMBIENTS[int(state["ambient"])],
		func() -> void: state["ambient"] = (int(state["ambient"]) + 1) % AMBIENTS.size())
	_add(box, "shadows", func() -> String: return "Shadows: " + ("on" if state["shadows"] else "off"),
		func() -> void: state["shadows"] = not bool(state["shadows"]))
	_add(box, "glow", func() -> String: return "Glow: " + ("on" if state["glow"] else "off"),
		func() -> void: state["glow"] = not bool(state["glow"]))
	_add(box, "msaa", func() -> String: return "MSAA: " + MSAAS[int(state["msaa"])],
		func() -> void: state["msaa"] = (int(state["msaa"]) + 1) % MSAAS.size())
	_add(box, "ao", func() -> String: return "Vertex AO: " + ("on" if state["ao"] else "off"),
		func() -> void: state["ao"] = not bool(state["ao"]))
	_add(box, "icons", func() -> String: return "N5 icons: " + ("on" if state["icons"] else "off"),
		func() -> void: state["icons"] = not bool(state["icons"]))


func _add(box: VBoxContainer, key: String, label_fn: Callable, toggle_fn: Callable) -> void:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.text = label_fn.call()
	b.pressed.connect(func() -> void:
		toggle_fn.call()
		apply()
		b.text = label_fn.call())
	box.add_child(b)
	_buttons[key] = b


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k != null and k.pressed and not k.echo and k.keycode == KEY_F1:
		_panel.visible = not _panel.visible


## Push `state` into the environment / light / materials / viewport.
func apply() -> void:
	if world == null or world.env == null:
		return
	var env: Environment = world.env
	match int(state["tonemap"]):
		0:
			env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
		1:
			env.tonemap_mode = Environment.TONE_MAPPER_AGX
		2:
			env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	world.set_ambient_mode(int(state["ambient"]))
	world.sun.shadow_enabled = bool(state["shadows"])
	env.glow_enabled = bool(state["glow"])
	var vp: Viewport = get_viewport()
	vp.msaa_3d = [Viewport.MSAA_DISABLED, Viewport.MSAA_2X, Viewport.MSAA_4X][int(state["msaa"])]
	if factory != null:
		factory.set_param(&"ao_strength", AO_ON if state["ao"] else 0.0)
	if icons != null:
		icons.visible = bool(state["icons"])


func _process(delta: float) -> void:
	_acc += delta
	_frames += 1
	if _acc < 0.25 or not _panel.visible:
		return
	_stats.text = stats_text(float(_frames) / _acc)
	_acc = 0.0
	_frames = 0


static func stats_text(fps: float) -> String:
	return "fps %.0f  frame %.1f ms (cpu proc %.2f ms)\ndraws %d  prims %d  objects %d\nvideo mem %.0f MB" % [
		fps, 1000.0 / maxf(1.0, fps), Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0]
