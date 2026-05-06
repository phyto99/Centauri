extends Control

@export var planet_builder: NodePath
@onready var size_slider = $SizeSlider
@onready var builder = get_node(planet_builder)

func _ready():
	size_slider.value = builder.grid_size
	size_slider.connect("value_changed", _on_size_changed)

func _on_size_changed(value: float):
	builder.grid_size = int(value)
	builder.generate_grid()
