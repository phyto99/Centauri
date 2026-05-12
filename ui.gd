extends Control

const BTN_W  := 186.0
const BTN_H  := 37.0
const BAR_H  := 14.0

var _game_over := false

@export var planet_builder: NodePath
@onready var size_slider = $SizeSlider
@onready var size_label = $SizeLabel  # Reference to the label node
@onready var builder = $"../PlanetBuilder"

var _action_bar: ColorRect

func _ready():
	add_to_group("ui_controller")
	claim_button.pressed.connect(_on_claim_pressed)
	cultivate_button.pressed.connect(_on_cultivate_pressed)
	collect_button.pressed.connect(_on_collect_pressed)
	_update_button_states("none")
	_setup_action_bar()
	_reposition_buttons()
	get_viewport().size_changed.connect(_reposition_buttons)

func _setup_action_bar() -> void:
	var cl := get_node("CanvasLayer")
	# Hide the old SVG sprite underneath buttons
	var old_sprite := cl.get_node_or_null("movesleft")
	if old_sprite:
		old_sprite.visible = false

	_action_bar = ColorRect.new()
	_action_bar.color   = GameConfig.color_for(0)
	_action_bar.z_index = -1   # render behind the label
	cl.add_child(_action_bar)

	# Center the moves label — font color stays black (set in movesleft_2.gd)
	var moves_lbl := cl.get_node_or_null("movesleft2")
	if moves_lbl:
		moves_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		moves_lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER

func _reposition_buttons() -> void:
	var vp  := get_viewport().get_visible_rect().size
	var bx  := vp.x - BTN_W
	var top := vp.y - BTN_H * 3.0 - BAR_H

	claim_button.position    = Vector2(bx, top)
	claim_button.size        = Vector2(BTN_W, BTN_H)
	cultivate_button.position = Vector2(bx, top + BTN_H)
	cultivate_button.size     = Vector2(BTN_W, BTN_H)
	collect_button.position   = Vector2(bx, top + BTN_H * 2.0)
	collect_button.size       = Vector2(BTN_W, BTN_H)

	var bar_y := top + BTN_H * 3.0
	if _action_bar:
		_action_bar.position = Vector2(bx, bar_y)
		_action_bar.size     = Vector2(BTN_W, BAR_H)

	var cl := get_node("CanvasLayer")
	var moves_lbl := cl.get_node_or_null("movesleft2")
	if moves_lbl:
		moves_lbl.position = Vector2(bx, bar_y - 5.0)
		moves_lbl.size     = Vector2(BTN_W, BAR_H)
# Called by camera_manager when the active player changes
func set_team_color(color: Color) -> void:
	for btn in [claim_button, cultivate_button, collect_button]:
		btn.add_theme_color_override("icon_normal_color", color)
		btn.add_theme_color_override("icon_hover_color", color)
		btn.add_theme_color_override("icon_pressed_color", color)
		btn.add_theme_color_override("icon_focus_color", color)
	if _action_bar:
		_action_bar.color = color

func _on_size_changed(value: float):
	builder.current_size = int(value)
	size_label.text = str(int(value))  # Update label text
	builder.generate_grid()


signal mode_changed(mode: String)

@export var claim_button: Button
@export var cultivate_button: Button
@export var collect_button: Button

# Reference to the different sprite scenes
@export var claim_sprite_scene: PackedScene
@export var cultivate_sprite_scene: PackedScene

var current_mode: String = "none"


func _get_landed_planet() -> Node:
	for ship in get_tree().get_nodes_in_group("players"):
		if not is_instance_valid(ship):
			continue
		var cam = ship.get_node_or_null("Camera2D")
		if not (cam and cam.enabled):
			continue
		var p = ship.get("landed_planet")
		if p != null and is_instance_valid(p):
			return p
		return null  # active player exists but isn't landed
	return null

func set_game_over() -> void:
	_game_over = true
	_update_button_states("none")

func _on_claim_pressed():
	if _game_over: return
	if current_mode == "claim":
		_update_button_states("none")
	else:
		_update_button_states("claim")
		var p = _get_landed_planet()
		if p:
			p._on_claim_pressed()

func _on_cultivate_pressed():
	if _game_over: return
	if current_mode == "cultivate":
		_update_button_states("none")
	else:
		_update_button_states("cultivate")
		var p = _get_landed_planet()
		if p:
			p._on_cultivate_pressed()

func _on_collect_pressed():
	if _game_over: return
	if current_mode == "collect":
		_update_button_states("none")
	else:
		_update_button_states("collect")
		var p = _get_landed_planet()
		if p:
			p._on_collect_pressed()

func _update_button_states(new_mode: String):
	# Reset all buttons to normal state
	claim_button.button_pressed = false
	cultivate_button.button_pressed = false

	
	# Set the pressed state for the active mode
	match new_mode:
		"claim":
			claim_button.button_pressed = true
		"cultivate":
			cultivate_button.button_pressed = true
		"collect":
			collect_button.button_pressed = true
	
	current_mode = new_mode
	emit_signal("mode_changed", current_mode)

func get_current_sprite_scene() -> PackedScene:
	match current_mode:
		"claim":
			return claim_sprite_scene
		"cultivate":
			return cultivate_sprite_scene
		_:
			return null

func get_current_mode() -> String:
	return current_mode
