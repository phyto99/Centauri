extends Control

@export var planet_builder: NodePath
@onready var size_slider = $SizeSlider
@onready var size_label = $SizeLabel  # Reference to the label node
@onready var builder = $"../PlanetBuilder"



func _ready():
	size_slider.value = builder.current_size
	size_label.text = str(builder.current_size)  # Set initial label text
	size_slider.connect("value_changed", _on_size_changed)
	size_label.add_theme_font_size_override("font_size", 240)
		# Connect button signals
	claim_button.pressed.connect(_on_claim_pressed)
	cultivate_button.pressed.connect(_on_cultivate_pressed)

	
	# Set initial button states
	_update_button_states("none")

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


func _on_claim_pressed():
	if current_mode == "claim":
		_update_button_states("none")
	else:
		_update_button_states("claim")

func _on_cultivate_pressed():
	if current_mode == "cultivate":
		_update_button_states("none")
	else:
		_update_button_states("cultivate")

func _on_collect_pressed():
	if current_mode == "collect":
		_update_button_states("none")
	else:
		_update_button_states("collect")

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
