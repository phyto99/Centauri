extends Label

func _ready() -> void:
	var ls := LabelSettings.new()
	ls.font_size = 17
	ls.font_color = Color(0, 0, 0, 1)
	var vf := SystemFont.new()
	vf.font_names = PackedStringArray(["Segoe UI", "Helvetica Neue", "SF Pro Display", "Arial", "sans-serif"])
	vf.font_weight = 100
	vf.font_stretch = 75   # condensed helps appear thinner visually
	ls.font = vf
	label_settings = ls

func _process(_delta: float) -> void:
	# Show moves for the planet the active (camera-enabled) player is landed on.
	for ship in get_tree().get_nodes_in_group("players"):
		if not is_instance_valid(ship):
			continue
		var cam = ship.get_node_or_null("Camera2D")
		if not (cam and cam.enabled):
			continue
		var planet = ship.get("landed_planet")
		if planet != null and is_instance_valid(planet):
			text = str(planet.moves_remaining)
			return
		return

	# Fallback: first non-sun planet
	for planet in get_tree().get_nodes_in_group("planets"):
		if not planet.get("is_sun"):
			text = str(planet.moves_remaining)
			return
