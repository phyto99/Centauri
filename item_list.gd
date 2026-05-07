extends ItemList

func _ready() -> void:
	get_tree().node_added.connect(_on_node_added)
	for planet in get_tree().get_nodes_in_group("planets"):
		_connect_planet(planet)
	_update_yield_total()
	_update_food_total()
	_update_claimed_planets()

func _connect_planet(planet: Node) -> void:
	if not planet.has_signal("yield_updated"):
		return
	if not planet.yield_updated.is_connected(_update_yield_total):
		planet.yield_updated.connect(_update_yield_total.unbind(1))
	if planet.has_signal("food_updated") and not planet.food_updated.is_connected(_update_food_total):
		planet.food_updated.connect(_update_food_total.unbind(1))
	if planet.has_signal("moves_updated") and not planet.moves_updated.is_connected(_update_claimed_planets):
		planet.moves_updated.connect(_update_claimed_planets.unbind(1))

func _on_node_added(node: Node) -> void:
	_connect_deferred.call_deferred(node)

func _connect_deferred(node: Node) -> void:
	if node.is_in_group("planets"):
		_connect_planet(node)
		_update_yield_total()
		_update_food_total()
		_update_claimed_planets()

func _update_yield_total() -> void:
	var total = 0
	for planet in get_tree().get_nodes_in_group("planets"):
		total += planet.yield_count
	set_item_text(8, str(total))

func _update_food_total() -> void:
	var total = 0
	for planet in get_tree().get_nodes_in_group("planets"):
		total += planet.food
	set_item_text(9, str(total))

func _update_claimed_planets() -> void:
	var count = 0
	for planet in get_tree().get_nodes_in_group("planets"):
		if planet.get("is_sun"):
			continue
		for cell in planet.grid.values():
			if cell.get("team_id", -1) == 0 and cell.get("state", 0) > 0:
				count += 1
				break
	set_item_text(10, str(count))
