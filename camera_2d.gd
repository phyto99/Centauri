extends Camera2D

@export var zoom_speed: float = 0.04

func _input(event):
	# Only process inputs if this camera is enabled
	if !enabled:
		return

	if event is InputEventMouseButton:
		var f: float = minf(event.factor if event.factor > 0.0 else 1.0, 2.0)
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom_out(f)
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom_in(f)
			get_viewport().set_input_as_handled()
	elif event is InputEventKey:
		if event.pressed:
			if event.keycode == KEY_PLUS or event.keycode == KEY_EQUAL:
				zoom_out()
				get_viewport().set_input_as_handled()
			elif event.keycode == KEY_MINUS:
				zoom_in()
				get_viewport().set_input_as_handled()

func zoom_in(factor: float = 1.0):
	zoom = (zoom * (1 - zoom_speed * factor)).clamp(Vector2(0.01, 0.01), Vector2(16.0, 16.0))

func zoom_out(factor: float = 1.0):
	zoom = (zoom * (1 + zoom_speed * factor)).clamp(Vector2(0.01, 0.01), Vector2(16.0, 16.0))
