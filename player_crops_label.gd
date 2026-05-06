extends Label

func _process(_delta):
	var total = 0
	for planet in get_tree().get_nodes_in_group("planets"):
		total += planet.food
	text = str(total)
