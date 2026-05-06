extends Node2D

const VELOCITY_SCALE := 3.0
const PREVIEW_STEPS := 60
const PREVIEW_STEP_DT := 10.0 / 60.0

@export var planet_scene: PackedScene

enum State { IDLE, DRAGGING, SELECTED }
var _state: State = State.IDLE

var _drag_start: Vector2
var _selected: Node = null

var _cam: Camera2D
var _is_panning: bool = false

var _inspector: Control
var _size_slider: HSlider
var _mass_slider: HSlider


func _ready() -> void:
	_cam = Camera2D.new()
	_cam.enabled = true
	_cam.zoom = Vector2(0.5, 0.5)
	add_child(_cam)
	_build_ui()


func _build_ui() -> void:
	var cl := CanvasLayer.new()
	add_child(cl)

	_inspector = PanelContainer.new()
	_inspector.position = Vector2(16, 16)
	_inspector.custom_minimum_size = Vector2(250, 0)
	_inspector.mouse_filter = Control.MOUSE_FILTER_STOP
	_inspector.visible = false
	cl.add_child(_inspector)

	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 10)
	_inspector.add_child(margin)

	var vbox := VBoxContainer.new()
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "Planet"
	title.add_theme_font_size_override("font_size", 18)
	vbox.add_child(title)
	vbox.add_child(HSeparator.new())

	vbox.add_child(_label("Cells"))
	_size_slider = HSlider.new()
	_size_slider.min_value = 1
	_size_slider.max_value = 150
	_size_slider.step = 1
	_size_slider.value = 7
	_size_slider.value_changed.connect(_on_size_changed)
	vbox.add_child(_size_slider)

	vbox.add_child(_label("Mass"))
	_mass_slider = HSlider.new()
	_mass_slider.min_value = 0.5
	_mass_slider.max_value = 200.0
	_mass_slider.step = 0.5
	_mass_slider.value = 1.0
	_mass_slider.value_changed.connect(_on_mass_changed)
	vbox.add_child(_mass_slider)

	var row := HBoxContainer.new()
	vbox.add_child(row)

	var del_btn := Button.new()
	del_btn.text = "Delete  [Del]"
	del_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	del_btn.pressed.connect(_on_delete)
	row.add_child(del_btn)

	var desel_btn := Button.new()
	desel_btn.text = "Deselect  [Esc]"
	desel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desel_btn.pressed.connect(_deselect)
	row.add_child(desel_btn)

	var hint_cl := CanvasLayer.new()
	add_child(hint_cl)
	var hint := Label.new()
	hint.text = (
		"Click: place planet\n"
		+ "Drag: set velocity\n"
		+ "Right-drag / MMB: pan\n"
		+ "Scroll: zoom\n"
		+ "Click planet: select\n"
		+ "Esc: deselect   Del: delete"
	)
	hint.add_theme_font_size_override("font_size", 13)
	hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, 12)
	hint.offset_top -= 130
	hint_cl.add_child(hint)


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _process(_delta: float) -> void:
	queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				_cam.zoom = (_cam.zoom * 1.12).clamp(Vector2(0.04, 0.04), Vector2(12.0, 12.0))
			MOUSE_BUTTON_WHEEL_DOWN:
				_cam.zoom = (_cam.zoom * 0.88).clamp(Vector2(0.04, 0.04), Vector2(12.0, 12.0))
			MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE:
				_is_panning = mb.pressed
			MOUSE_BUTTON_LEFT:
				if mb.pressed:
					_on_left_press()
				else:
					_on_left_release()

	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _is_panning:
			_cam.position -= mm.relative / _cam.zoom

	elif event is InputEventKey and event.pressed:
		var ke := event as InputEventKey
		if ke.keycode == KEY_ESCAPE:
			_deselect()
		elif ke.keycode == KEY_DELETE and _selected:
			_on_delete()


func _on_left_press() -> void:
	var world := get_global_mouse_position()
	var hit := _planet_at(world)
	if hit:
		_select(hit)
	else:
		_deselect()
		_drag_start = world
		_state = State.DRAGGING


func _on_left_release() -> void:
	if _state != State.DRAGGING:
		return
	var world := get_global_mouse_position()
	var velocity := (world - _drag_start) * VELOCITY_SCALE
	_spawn_planet(_drag_start, velocity)
	_state = State.IDLE


func _spawn_planet(pos: Vector2, vel: Vector2) -> void:
	if not planet_scene:
		push_error("MapMaker: planet_scene export not set")
		return
	var p: Node = planet_scene.instantiate()
	add_child(p)
	p.position = pos
	p.linear_velocity = vel
	p.editing_mode = true


func _planet_at(world_pos: Vector2) -> Node:
	var space := get_world_2d().direct_space_state
	var params := PhysicsPointQueryParameters2D.new()
	params.position = world_pos
	params.collision_mask = 0xFFFFFFFF
	for r in space.intersect_point(params, 8):
		var col = r["collider"]
		if col.is_in_group("planets"):
			return col
	return null


func _select(planet: Node) -> void:
	_selected = planet
	_state = State.SELECTED
	_inspector.visible = true
	_size_slider.value = planet.current_size
	_mass_slider.value = planet.mass


func _deselect() -> void:
	_selected = null
	_state = State.IDLE
	_inspector.visible = false


func _on_size_changed(value: float) -> void:
	if _selected and is_instance_valid(_selected):
		_selected.on_slider_value_changed(value)


func _on_mass_changed(value: float) -> void:
	if _selected and is_instance_valid(_selected):
		_selected.mass = value


func _on_delete() -> void:
	if _selected and is_instance_valid(_selected):
		_selected.queue_free()
	_deselect()


func _draw() -> void:
	var inv_z := 1.0 / _cam.zoom.x

	if _selected and is_instance_valid(_selected):
		draw_arc(_selected.position, 90.0 * inv_z, 0.0, TAU, 48,
				Color(1.0, 0.9, 0.1, 0.9), 3.0 * inv_z)

	if _state != State.DRAGGING:
		return

	var mouse_world := get_global_mouse_position()
	var velocity := (mouse_world - _drag_start) * VELOCITY_SCALE
	var speed := velocity.length()

	draw_circle(_drag_start, 50.0 * inv_z, Color(1, 1, 1, 0.18))
	draw_arc(_drag_start, 50.0 * inv_z, 0.0, TAU, 32, Color(1, 1, 1, 0.75), 2.0 * inv_z)

	if speed > 0.5:
		draw_line(_drag_start, mouse_world, Color(1.0, 0.55, 0.1, 0.7), 2.0 * inv_z)
		var dir := (mouse_world - _drag_start).normalized()
		var perp := dir.rotated(PI * 0.5)
		var tip := mouse_world
		var ah := 16.0 * inv_z
		draw_colored_polygon(PackedVector2Array([
			tip,
			tip - dir * ah + perp * ah * 0.5,
			tip - dir * ah - perp * ah * 0.5,
		]), Color(1.0, 0.55, 0.1, 0.85))

	for i in range(PREVIEW_STEPS):
		var t := i * PREVIEW_STEP_DT
		var pt := _drag_start + velocity * t
		var alpha := (1.0 - float(i) / PREVIEW_STEPS) * 0.9
		var radius: float = lerp(5.0, 2.0, float(i) / PREVIEW_STEPS) * inv_z
		draw_circle(pt, radius, Color(0.25, 0.8, 1.0, alpha))
