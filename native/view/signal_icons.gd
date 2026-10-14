class_name SignalIcons
extends Node3D
## N5 signal icons over cars (NATIVE_PORT M1d N5, user request): blinker ◀ / ▶ (blinks with the lamp, same phase
## function as the lamp shader input), brake STOP, high-beam flash, hazard ◀▶, horn wave, and 'no-blinker cut-in'
## (blinker crossed out). Only for the villain, cars within 25 m of the player and cars that just reacted to an event;
## at most 4 at once; colour AND shape differ per signal (colour-blind safe). Billboards drawn on top of the scene,
## size eased by distance. Placement is greedy by priority in screen space, so two icons never overlap
## (last_overlaps() is the T2 'icon overlap 0' check).
## Review fixes (art review 2026-10-13): BRAKE is event-driven (1.2 s when the brake bit turns on or the car
## decelerates > 2 m/s²; never in a steady crawl, where 85–95 % of jam cars are lit); blink icons swap an on / off
## texture instead of dimming the whole badge; no-blinker cut-in = full arrow + red ⊘ corner badge (the old X read
## as a close button); a honk reply shows no icon (the reply bubble carries it) and ids in `suppress` get none;
## icons stay inside `bounds` and off `reserved` (HUD) rects; textures are baked at 2× (192 px).

const MAX_ICONS: int = 4
const NEAR_M: float = 25.0
const EVENT_HOLD: float = 2.6
const BRAKE_HOLD: float = 1.2
const BRAKE_DECEL: float = 2.0               # m/s² that counts as a braking event even if the bit was already on
const ICON_PX: int = 192
const BIT_BRAKE: int = 1
const BIT_BLINK_L: int = 2
const BIT_BLINK_R: int = 4
const BIT_HIGHBEAM: int = 8
const BIT_HAZARD: int = 16
const BIT_VILLAIN: int = 64

enum Icon { BLINK_L, BLINK_R, BRAKE, HIGHBEAM, HAZARD, HONK, CUTIN_L, CUTIN_R }

## SVGs drawn as shapes only (ThorVG drops <text>, NATIVE_PORT 3-8): dark badge + coloured symbol.
const BADGE: String = "<rect x='4' y='4' width='88' height='88' rx='22' fill='#14161c' fill-opacity='0.82' stroke='#ffffff' stroke-width='5'/>"
const SVG: Dictionary = {
	Icon.BLINK_L: "<path d='M18 48 L56 20 L56 36 L80 36 L80 60 L56 60 L56 76 Z' fill='#ffb21e' stroke='#4a2a00' stroke-width='3'/>",
	Icon.BLINK_R: "<path d='M78 48 L40 20 L40 36 L16 36 L16 60 L40 60 L40 76 Z' fill='#ffb21e' stroke='#4a2a00' stroke-width='3'/>",
	Icon.BRAKE: "<path d='M33 12 L63 12 L84 33 L84 63 L63 84 L33 84 L12 63 L12 33 Z' fill='#e8242a' stroke='#ffffff' stroke-width='4'/>" +
		"<g fill='none' stroke='#ffffff' stroke-width='5' stroke-linecap='square'>" +
		"<path d='M33 38 L22 38 L22 48 L33 48 L33 58 L22 58'/><path d='M37 38 L49 38 M43 38 L43 59'/>" +
		"<rect x='52' y='38' width='9' height='20'/><path d='M66 59 L66 38 L75 38 L75 48 L66 48'/></g>",
	Icon.HIGHBEAM: "<path d='M46 22 C24 22 20 74 46 74 Z' fill='#5ab4ff' stroke='#ffffff' stroke-width='3'/>" +
		"<g stroke='#5ab4ff' stroke-width='7' stroke-linecap='round'><path d='M56 28 L82 28'/><path d='M56 41 L82 41'/>" +
		"<path d='M56 54 L82 54'/><path d='M56 67 L82 67'/></g>",
	Icon.HAZARD: "<path d='M48 12 L86 80 L10 80 Z' fill='none' stroke='#ff3b30' stroke-width='9' stroke-linejoin='round'/>" +
		"<path d='M48 38 L66 70 L30 70 Z' fill='none' stroke='#ff3b30' stroke-width='6' stroke-linejoin='round'/>",
	Icon.HONK: "<path d='M14 38 L30 38 L50 20 L50 76 L30 58 L14 58 Z' fill='#ffd21e' stroke='#4a3a00' stroke-width='3'/>" +
		"<g fill='none' stroke='#ffd21e' stroke-width='6' stroke-linecap='round'><path d='M60 34 Q68 48 60 62'/>" +
		"<path d='M70 26 Q82 48 70 70'/></g>",
	Icon.CUTIN_L: "<path d='M12 42 L46 16 L46 30 L72 30 L72 54 L46 54 L46 68 Z' fill='#ffb21e' stroke='#4a2a00' stroke-width='3'/>" + NO_SIGN,
	Icon.CUTIN_R: "<path d='M84 42 L50 16 L50 30 L24 30 L24 54 L50 54 L50 68 Z' fill='#ffb21e' stroke='#4a2a00' stroke-width='3'/>" + NO_SIGN,
}
## "no signal" corner badge for the cut-in icons (lower right): ⊘ in red on the dark badge colour.
const NO_SIGN: String = "<circle cx='70' cy='70' r='19' fill='#14161c' stroke='#ff2a2a' stroke-width='7'/>" + \
	"<path d='M57 83 L83 57' stroke='#ff2a2a' stroke-width='7' stroke-linecap='round'/>"
## Blink icons, dark half: same arrow in the web beacon's off colour (badge stays opaque, only the arrow goes dark).
const BLINK_OFF_FILL: String = "#5a3a00"
## priority within one car (higher wins)
const ICON_PRI: Dictionary = {Icon.CUTIN_L: 9, Icon.CUTIN_R: 9, Icon.HONK: 8, Icon.HAZARD: 6, Icon.BLINK_L: 5,
	Icon.BLINK_R: 5, Icon.HIGHBEAM: 4, Icon.BRAKE: 2}

var road: RoadGraph
var camera: Camera3D
var lamp_time: float = 0.0
var size_px: float = 42.0                   # on-screen icon size at 20 m (scaled by viewport height / 960) ≈ 36 pt
## Screen rect icons must stay inside (game sets the HUD safe rect, shrunk by 8); empty = whole viewport − 8.
var bounds := Rect2()
## Screen rects icons must not cover (HUD bar, pill, rows, buttons); seeded into the overlap check.
var reserved: Array[Rect2] = []
## car id → true: no icon this frame (e.g. a car whose honk-reply bubble is up).
var suppress: Dictionary = {}
var _tex: Dictionary = {}
var _tex_off: Dictionary = {}                # blink icons: dark-half texture
var _last_bits: Dictionary = {}              # car id → lamp bits at the previous update_icons()
var _last_v: Dictionary = {}                 # car id → speed at the previous update_icons()
var _last_now: float = NAN
var _brake_until: Dictionary = {}            # car id → time the BRAKE icon expires
var _sprites: Array[Sprite3D] = []
var _events: Dictionary = {}                 # car id → {icon, until, side}
var _shown: Array[Dictionary] = []
var _overlaps: int = 0
var heights: Dictionary = {}                 # car id → roof height (m)


func _ready() -> void:
	for icon: int in SVG:
		_tex[icon] = _bake(str(SVG[icon]))
		if icon == Icon.BLINK_L or icon == Icon.BLINK_R:
			_tex_off[icon] = _bake(str(SVG[icon]).replace("#ffb21e", BLINK_OFF_FILL))
		elif icon == Icon.HAZARD:
			_tex_off[icon] = _bake(str(SVG[icon]).replace("#ff3b30", "#5a1a14"))
	for i: int in MAX_ICONS:
		var sp := Sprite3D.new()
		sp.name = "Icon%d" % i
		sp.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		sp.no_depth_test = true
		sp.fixed_size = true
		sp.shaded = false
		sp.double_sided = true
		sp.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		sp.alpha_cut = SpriteBase3D.ALPHA_CUT_DISABLED
		sp.render_priority = 10
		sp.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		sp.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		sp.visible = false
		add_child(sp)
		_sprites.append(sp)


func _bake(body: String) -> ImageTexture:
	var img := Image.new()
	var svg: String = "<svg xmlns='http://www.w3.org/2000/svg' width='96' height='96' viewBox='0 0 96 96'>%s%s</svg>" % [BADGE, body]
	if img.load_svg_from_string(svg, float(ICON_PX) / 96.0) != OK:
		img = Image.create(ICON_PX, ICON_PX, false, Image.FORMAT_RGBA8)
		img.fill(Color.MAGENTA)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


## Sim events → short-lived icons: cutin (blinker false → crossed-out blinker). honk_reply only makes the car
## event-eligible (no icon): the reply bubble says it, and a horn icon over the replier read as "this car honked".
func on_event(ev: Dictionary, now: float) -> void:
	var id: int = int(ev.get("id", -1))
	if id < 0:
		return
	var data: Dictionary = ev.get("data", {}) if ev.get("data") is Dictionary else {}
	match str(ev.get("type", "")):
		"cutin":
			if not bool(data.get("blinker", true)):
				var right: bool = int(data.get("to", 0)) > int(data.get("from", 0))
				_events[id] = {"icon": Icon.CUTIN_R if right else Icon.CUTIN_L, "until": now + EVENT_HOLD}
			else:
				_events[id] = {"icon": -1, "until": now + EVENT_HOLD}  # event car: eligible beyond 25 m
		"honk_reply":
			_events[id] = {"icon": -1, "until": now + 1.4}


## cur: sim buffer (stride 8); player {s, x, lane}; now: real time for event expiry. Returns the shown icons.
func update_icons(cur: PackedFloat32Array, player: Dictionary, now: float) -> Array[Dictionary]:
	for id: int in _events.keys():
		if float(_events[id]["until"]) < now:
			_events.erase(id)
	_track_brakes(cur, now)
	var ps: float = float(player.get("s", 0.0))
	var plane: int = int(roundf(float(player.get("lane", 3.0))))
	var cands: Array[Dictionary] = []
	var ahead_id: int = -1
	var ahead_ds: float = NEAR_M
	var n: int = cur.size() / 8
	for k: int in n:
		var o: int = k * 8
		if int(cur[o + 2]) == plane and cur[o + 4] > ps and cur[o + 4] - ps < ahead_ds:
			ahead_ds = cur[o + 4] - ps
			ahead_id = int(cur[o])
	for k: int in n:
		var o: int = k * 8
		var id: int = int(cur[o])
		var bits: int = int(cur[o + 7])
		var ds: float = cur[o + 4] - ps
		var villain: bool = (bits & BIT_VILLAIN) != 0
		var ev: Dictionary = _events.get(id, {})
		var near: bool = absf(ds) <= NEAR_M and cur[o + 2] >= 0.0
		if suppress.has(id) or not (villain or near or not ev.is_empty()):
			continue
		var icon: int = -1
		if not ev.is_empty() and int(ev["icon"]) >= 0:
			icon = int(ev["icon"])
		elif bits & BIT_HAZARD or _hazard_active(id, bits):
			icon = Icon.HAZARD if bits & BIT_HAZARD else -2  # -2: hazard active but dark half → hold the slot
		elif bits & BIT_BLINK_L:
			icon = Icon.BLINK_L
		elif bits & BIT_BLINK_R:
			icon = Icon.BLINK_R
		elif bits & BIT_HIGHBEAM:
			icon = Icon.HIGHBEAM
		elif bits & BIT_BRAKE and (villain or id == ahead_id) and float(_brake_until.get(id, -INF)) >= now:
			icon = Icon.BRAKE
		if icon == -1:
			continue
		var pri: float = float(ICON_PRI.get(icon, 5)) + (20.0 if villain else 0.0) + (10.0 if not ev.is_empty() else 0.0) \
			- absf(ds) * 0.05
		cands.append({"id": id, "icon": icon, "pri": pri, "x": cur[o + 3], "s": cur[o + 4], "bits": bits, "villain": villain})
	cands.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["pri"]) > float(b["pri"]))
	_shown.clear()
	_overlaps = 0
	var rects: Array[Rect2] = reserved.duplicate()
	var vis: Rect2 = get_viewport().get_visible_rect() if is_inside_tree() else Rect2(0, 0, 540, 960)
	var vp_h: float = vis.size.y
	var inside: Rect2 = bounds if bounds.has_area() else vis.grow(-8.0)
	for c: Dictionary in cands:
		if _shown.size() >= MAX_ICONS:
			break
		var h: float = float(heights.get(int(c["id"]), 1.6)) + 1.5
		var wp: Vector3 = road.position(float(c["s"]), float(c["x"])) + Vector3(0, h, 0)
		if camera == null or camera.is_position_behind(wp):
			continue
		var sp: Vector2 = camera.unproject_position(wp)
		var dist: float = camera.global_position.distance_to(wp)
		var px: float = size_px * (vp_h / 960.0) * clampf(1.25 - dist / 120.0, 0.7, 1.15)
		var r := Rect2(sp - Vector2(px, px) * 0.5, Vector2(px, px)).grow(2.0)
		if not inside.encloses(r):  # off screen or under the notch: must not take one of the 4 slots
			continue
		var clash: bool = false
		for q: Rect2 in rects:
			if q.intersects(r):
				clash = true
				break
		if clash:
			continue
		rects.append(r)
		c["rect"] = r
		c["world"] = wp
		c["px"] = px
		_shown.append(c)
	for i: int in _sprites.size():
		var spr: Sprite3D = _sprites[i]
		if i >= _shown.size():
			spr.visible = false
			continue
		var c: Dictionary = _shown[i]
		var icon: int = int(c["icon"])
		var tex: Texture2D = null
		if icon == Icon.BLINK_L or icon == Icon.BLINK_R:
			# same phase as the lamp; the dark half swaps to the dark-arrow texture (badge stays opaque)
			tex = _tex[icon] if NpcMultiMesh.blink_lit(lamp_time, int(c["id"])) else _tex_off[icon]
		elif icon == -2:
			tex = _tex_off[Icon.HAZARD]  # hazard active, dark half: hold the slot with the dark texture
		else:
			tex = _tex[icon]
		spr.texture = tex
		spr.global_position = c["world"]
		# fixed_size: pixel_size is relative to the viewport height at 1 m → px / vp_h / texture px
		spr.pixel_size = float(c["px"]) / vp_h / float(ICON_PX) * 2.0 * tan(deg_to_rad(camera.fov) * 0.5)
		spr.modulate = Color.WHITE
		spr.visible = true
	return _shown


## BRAKE as an event: the brake bit turning on, or a deceleration above BRAKE_DECEL, holds the icon BRAKE_HOLD s.
## A car seen for the first time with the bit on counts as turning on.
func _track_brakes(cur: PackedFloat32Array, now: float) -> void:
	var dt: float = now - _last_now if is_finite(_last_now) else 0.0
	var bits_now: Dictionary = {}
	var v_now: Dictionary = {}
	var n: int = cur.size() / 8
	for k: int in n:
		var o: int = k * 8
		var id: int = int(cur[o])
		var bits: int = int(cur[o + 7])
		var v: float = cur[o + 6]
		var was: int = int(_last_bits.get(id, 0))
		var decel: float = (float(_last_v[id]) - v) / dt if dt > 1e-4 and _last_v.has(id) else 0.0
		if (bits & BIT_BRAKE) and (not (was & BIT_BRAKE) or decel > BRAKE_DECEL):
			_brake_until[id] = now + BRAKE_HOLD
		bits_now[id] = bits
		v_now[id] = v
	for id: int in _brake_until.keys():
		if float(_brake_until[id]) < now:
			_brake_until.erase(id)
	_last_bits = bits_now
	_last_v = v_now
	_last_now = now


func _hazard_active(_id: int, _bits: int) -> bool:
	return false


func last_overlaps() -> int:
	var n: int = 0
	for i: int in _shown.size():
		for j: int in range(i + 1, _shown.size()):
			if (_shown[i]["rect"] as Rect2).intersects(_shown[j]["rect"] as Rect2):
				n += 1
	return n


func shown() -> Array[Dictionary]:
	return _shown
