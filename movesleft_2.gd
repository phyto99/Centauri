extends Label

func _process(_delta):
	var planets = get_tree().get_nodes_in_group("planets")
	if not planets.is_empty():
		text = str(planets[0].moves_remaining)
