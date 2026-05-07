extends ItemList

const TEAM_NAMES = ["Cyan", "Magenta", "Lime", "Yellow", "Blue", "Red", "DkGreen"]

# Read team color from PlanetBuilder (single source of truth — add colors there)
func _team_color(tid: int) -> Color:
	for planet in get_tree().get_nodes_in_group("planets"):
		var colors = planet.get("team_colors")
		if colors and colors.size() > 0:
			return colors[tid % colors.size()]
	return Color(1, 1, 1)

# Per-team yield accumulated from planet signals
var _team_yields: Dictionary = {}

# Items 0–15 are the static header defined in the scene; team rows start here
const _TEAM_ROW_START = 16

func _ready() -> void:
	get_tree().node_added.connect(_on_node_added)
	for planet in get_tree().get_nodes_in_group("planets"):
		_connect_planet(planet)
	_update_yield_total()
	_update_food_total()
	_update_claimed_planets()
	_rebuild_team_rows()

func _connect_planet(planet: Node) -> void:
	if not planet.has_signal("yield_updated"):
		return
	if not planet.yield_updated.is_connected(_update_yield_total):
		planet.yield_updated.connect(_update_yield_total.unbind(1))
	if planet.has_signal("food_updated") and not planet.food_updated.is_connected(_update_food_total):
		planet.food_updated.connect(_update_food_total.unbind(1))
	if planet.has_signal("moves_updated") and not planet.moves_updated.is_connected(_on_moves_updated):
		planet.moves_updated.connect(_on_moves_updated.unbind(1))
	if planet.has_signal("team_yield_updated") and not planet.team_yield_updated.is_connected(_on_team_yield_updated):
		planet.team_yield_updated.connect(_on_team_yield_updated)

func _on_node_added(node: Node) -> void:
	_connect_deferred.call_deferred(node)

func _connect_deferred(node: Node) -> void:
	if node.is_in_group("planets"):
		_connect_planet(node)
		_update_yield_total()
		_update_food_total()
		_update_claimed_planets()
		_rebuild_team_rows()

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

func _on_moves_updated() -> void:
	_update_claimed_planets()
	_rebuild_team_rows()

func _update_claimed_planets() -> void:
	var count = 0
	for planet in get_tree().get_nodes_in_group("planets"):
		if planet.get("is_sun"):
			continue
		for cell in planet.grid.values():
			if cell.get("state", 0) > 0:
				count += 1
				break
	set_item_text(10, str(count))

func _on_team_yield_updated(team_id: int, _count: int) -> void:
	var total = 0
	for planet in get_tree().get_nodes_in_group("planets"):
		total += planet.team_yield_counts.get(team_id, 0)
	_team_yields[team_id] = total
	_rebuild_team_rows()

func _get_active_team_count() -> int:
	var max_id = -1
	for ship in get_tree().get_nodes_in_group("players"):
		var tid = ship.get("team_id")
		if tid != null and tid > max_id:
			max_id = tid
	for planet in get_tree().get_nodes_in_group("planets"):
		if planet.get("is_sun"):
			continue
		for cell in planet.grid.values():
			var tid = cell.get("team_id", -1)
			if tid > max_id:
				max_id = tid
	return max_id + 1

func _get_team_stats(tid: int) -> Dictionary:
	var claimed = 0
	var cultivated = 0
	for planet in get_tree().get_nodes_in_group("planets"):
		if planet.get("is_sun"):
			continue
		for cell in planet.grid.values():
			if cell.get("team_id", -1) == tid:
				var state = cell.get("state", 0)
				if state == 1:
					claimed += 1
				elif state == 2:
					cultivated += 1
	return {"claimed": claimed, "cultivated": cultivated}

func _rebuild_team_rows() -> void:
	# Remove previous team rows from the end (items 16+)
	while item_count > _TEAM_ROW_START:
		remove_item(item_count - 1)

	var team_count = _get_active_team_count()
	if team_count <= 0:
		team_count = 1

	for t in range(team_count):
		var color: Color = _team_color(t)
		var name: String = TEAM_NAMES[t % TEAM_NAMES.size()]
		var stats = _get_team_stats(t)
		var yield_val = _team_yields.get(t, 0)

		var text = "%s  C:%d  V:%d  Y:%d" % [name, stats["claimed"], stats["cultivated"], yield_val]
		add_item(text)
		var row_start = item_count - 1
		set_item_selectable(row_start, false)
		set_item_custom_bg_color(row_start, Color(color.r, color.g, color.b, 0.25))
		set_item_custom_fg_color(row_start, Color(1, 1, 1, 1))

		# Fill the remaining 7 columns so the row spans the full width (max_columns = 8)
		for _i in range(7):
			add_item("")
			var fill_idx = item_count - 1
			set_item_selectable(fill_idx, false)
			set_item_custom_bg_color(fill_idx, Color(color.r, color.g, color.b, 0.25))
