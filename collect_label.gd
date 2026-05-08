extends Node2D

signal confirmed(food: int, fuel: int)

var _yield_count: int = 0

@onready var slider: HSlider      = $HSlider
@onready var fuel_label: Label    = $Label
@onready var food_label: Label    = $Label2
@onready var progress: ProgressBar = $ProgressBar

func _ready() -> void:
	slider.value_changed.connect(_on_slider_changed)
	$Button.pressed.connect(_confirm)
	visible = false

func open(yield_count: int) -> void:
	_yield_count = yield_count
	slider.min_value = 0
	slider.max_value = yield_count
	slider.value = 0
	progress.min_value = 0
	progress.max_value = yield_count
	progress.value = 0
	_refresh_labels()
	# Center on screen
	var vp := get_viewport().get_visible_rect().size
	position = (vp - Vector2(490, 238)) * 0.5
	visible = true

func _on_slider_changed(v: float) -> void:
	progress.value = v
	_refresh_labels()

func _refresh_labels() -> void:
	var fuel := int(slider.value)
	var food := _yield_count - fuel
	fuel_label.text = "%d Fuel" % fuel
	food_label.text = "%d Food" % food

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_E:
			_confirm()
		elif event.keycode == KEY_Q:
			visible = false

func _confirm() -> void:
	var fuel := int(slider.value)
	var food := _yield_count - fuel
	emit_signal("confirmed", food, fuel)
	visible = false
