class_name ScrScreen
extends Control
## Base for the meta screens: full-rect, owns a `safe` child inset by the notch / home-indicator safe area
## (same conversion as the HUD, NATIVE_PARITY G5), builds itself in build(), redraws data in refresh().

signal closed

var meta: ScrMeta
var insets := Vector4.ZERO
## Points of a 390-pt phone (top, bottom) to fake insets on desktop / in shots (like Hud.debug_safe_pt).
var debug_safe_pt := Vector2.ZERO
var safe: Control


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP


func setup(m: ScrMeta) -> ScrScreen:
	meta = m
	return self


func _ready() -> void:
	safe = Control.new()
	safe.name = "Safe"
	safe.set_anchors_preset(Control.PRESET_FULL_RECT)
	safe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(safe)
	apply_safe_area()
	get_viewport().size_changed.connect(apply_safe_area)
	build()
	refresh()


func apply_safe_area() -> void:
	insets = ScrKit.safe_insets(get_viewport(), debug_safe_pt)
	if safe != null:
		safe.offset_left = insets.x
		safe.offset_top = insets.y
		safe.offset_right = -insets.z
		safe.offset_bottom = -insets.w


func build() -> void:
	pass


func refresh() -> void:
	pass


func close() -> void:
	closed.emit()
	queue_free()


## First descendant whose name matches (tests and shots find widgets by name).
func find(n: String) -> Node:
	return find_child(n, true, false)
