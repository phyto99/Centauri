extends Camera2D

@export var zoom_speed: float = 0.1

func _input(event):
	# Only process inputs if this camera is enabled
	if !enabled:
		return
		
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom_out()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom_in()
	elif event is InputEventKey:
		if event.pressed:
			if event.keycode == KEY_PLUS or event.keycode == KEY_EQUAL:
				zoom_out()
			elif event.keycode == KEY_MINUS:
				zoom_in()

func zoom_in():
	zoom *= (1 - zoom_speed)

func zoom_out():
	zoom *= (1 + zoom_speed)
