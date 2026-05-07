extends Label

func _process(_delta):
	var total := 0.0
	for ship in get_tree().get_nodes_in_group("players"):
		total += ship.get("food_amount") if ship.get("food_amount") != null else 0.0
	text = str(int(total))
