extends Sprite2D

@onready var timer = $Timer
var total_time = 10.0
var elapsed_time = 0.0

func _ready():
	timer.wait_time = total_time
	timer.start()
	set_timebar_progress(1.0)  # Start full

func _process(delta):
	if timer.time_left > 0:
		elapsed_time = total_time - timer.time_left
		var progress = 1.0 - (elapsed_time / total_time)
		set_timebar_progress(progress)

func set_timebar_progress(value: float):
	if material:
		material.set_shader_parameter("progress", value)

func _on_timer_timeout() -> void:
	pass # Replace with function body.
