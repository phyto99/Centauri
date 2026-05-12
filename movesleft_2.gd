extends Label

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var ls := LabelSettings.new()
	ls.font_size = 16
	ls.font_color = Color(0, 0, 0, 1)
	var vf := SystemFont.new()
	vf.font_names = PackedStringArray(["Segoe UI", "Helvetica Neue", "SF Pro Display", "Arial", "sans-serif"])
	vf.font_weight = 100
	vf.font_stretch = 75   # condensed helps appear thinner visually
	ls.font = vf
	label_settings = ls

func _process(_delta: float) -> void:
	# If the active player is landed, show that planet's moves.
	for ship in get_tree().get_nodes_in_group("players"):
		if not is_instance_valid(ship):
			continue
		var cam = ship.get_node_or_null("Camera2D")
		if not (cam and cam.enabled):
			continue
		var planet = ship.get("landed_planet")
		if planet != null and is_instance_valid(planet):
			text = "%d MOVES REMAINING" % planet.moves_remaining
			return
		break  # active player found but not landed — fall through to planet scan

	# Show from first non-sun planet regardless of landing state.
	for planet in get_tree().get_nodes_in_group("planets"):
		if is_instance_valid(planet) and not planet.get("is_sun"):
			text = "%d MOVES REMAINING" % planet.moves_remaining
			return
