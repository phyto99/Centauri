extends ItemList

# ── Column mapping (matches header in scoreboard.tscn, 8 cols × 2 header rows = 16 items) ──
# col 0 = cultivate icon  → yield grown (team_yield_counts)
# col 1 = collect icon    → food delivered to sun
# col 2 = claim icon      → claimed planets count (dominion)
# col 3 = "food"          → food (same as col 1 for now, or 0 until defined)
# col 4 = "diversity"     → 0 (not yet defined)
# col 5 = "dominion"      → planets owned (dominant team)
# col 6 = "efficiency"    → efficiency % (food delivered / yield grown * 100)
# col 7 = "Total"         → 0 (not yet defined)

const _HEADER_ITEMS = 16
const _MAX_COLUMNS  = 8

# ── Per-team accumulators ─────────────────────────────────────────────────────

var _team_yield: Dictionary = {}   # team_id → total yield grown
var _team_food:  Dictionary = {}   # team_id → food delivered to sun

# ── Helpers ───────────────────────────────────────────────────────────────────

func _team_color(tid: int) -> Color:
	for planet in get_tree().get_nodes_in_group("planets"):
		var colors = planet.get("team_colors")
		if colors and colors.size() > 0:
			return colors[tid % colors.size()]
	return Color(1, 1, 1)

func _get_active_team_count() -> int:
	var max_id := -1
	for ship in get_tree().get_nodes_in_group("players"):
		var tid = ship.get("team_id")
		if tid != null and tid > max_id:
			max_id = tid
	for planet in get_tree().get_nodes_in_group("planets"):
		if planet.get("is_sun"):
			continue
		for cell in planet.grid.values():
			var tid: int = cell.get("team_id", -1)
			if tid > max_id:
				max_id = tid
	return max_id + 1

# Number of non-sun planets where this team has the most claimed cells.
func _get_dominion(tid: int) -> int:
	var count := 0
	for planet in get_tree().get_nodes_in_group("planets"):
		if planet.get("is_sun"):
			continue
		var team_claims: Dictionary = {}
		for cell in planet.grid.values():
			if cell.get("state", 0) == 1:   # CLAIMED
				var ctid: int = cell.get("team_id", -1)
				if ctid >= 0:
					team_claims[ctid] = team_claims.get(ctid, 0) + 1
		if team_claims.is_empty():
			continue
		var best_tid := -1
		var best_count := 0
		for t in team_claims:
			if team_claims[t] > best_count:
				best_count = team_claims[t]
				best_tid = t
		if best_tid == tid:
			count += 1
	return count

# food delivered / yield grown × 100, clamped 0-100.
func _get_efficiency(tid: int) -> int:
	var grown: int = _team_yield.get(tid, 0)
	var delivered: int = _team_food.get(tid, 0)
	if grown <= 0:
		return 0
	return clampi(int(float(delivered) / float(grown) * 100.0), 0, 100)

# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	get_tree().node_added.connect(_on_node_added)
	for planet in get_tree().get_nodes_in_group("planets"):
		_connect_planet(planet)
	for ship in get_tree().get_nodes_in_group("players"):
		_connect_ship(ship)
	_rebuild_team_rows()

func _on_node_added(node: Node) -> void:
	_connect_deferred.call_deferred(node)

func _connect_deferred(node: Node) -> void:
	if node.is_in_group("planets"):
		_connect_planet(node)
		_rebuild_team_rows()
	elif node.is_in_group("players"):
		_connect_ship(node)

# ── Signal connections ────────────────────────────────────────────────────────

func _connect_planet(planet: Node) -> void:
	if planet.has_signal("team_yield_updated") and \
			not planet.team_yield_updated.is_connected(_on_team_yield_updated):
		planet.team_yield_updated.connect(_on_team_yield_updated)
	if planet.has_signal("moves_updated") and \
			not planet.moves_updated.is_connected(_on_state_changed.unbind(1)):
		planet.moves_updated.connect(_on_state_changed.unbind(1))

func _connect_ship(ship: Node) -> void:
	if ship.has_signal("food_delivered") and \
			not ship.food_delivered.is_connected(_on_food_delivered):
		ship.food_delivered.connect(_on_food_delivered)

# ── Signal handlers ───────────────────────────────────────────────────────────

func _on_team_yield_updated(team_id: int, _count: int) -> void:
	var total := 0
	for planet in get_tree().get_nodes_in_group("planets"):
		total += planet.team_yield_counts.get(team_id, 0)
	_team_yield[team_id] = total
	_rebuild_team_rows()

func _on_food_delivered(team_id: int, amount: int) -> void:
	_team_food[team_id] = _team_food.get(team_id, 0) + amount
	_rebuild_team_rows()

func _on_state_changed() -> void:
	_rebuild_team_rows()

# ── Row builder ───────────────────────────────────────────────────────────────

func _rebuild_team_rows() -> void:
	while item_count > _HEADER_ITEMS:
		remove_item(item_count - 1)

	var team_count := _get_active_team_count()
	if team_count <= 0:
		team_count = 1

	for t in range(team_count):
		var color: Color = _team_color(t)
		var bg: Color    = Color(color.r, color.g, color.b, 0.25)

		# One value per column, matching the header exactly
		var cols: Array = [
			str(_team_yield.get(t, 0)),   # col 0: yield (cultivate)
			str(_team_food.get(t, 0)),    # col 1: food delivered (collect)
			str(_get_dominion(t)),        # col 2: claimed planets (claim)
			str(_team_food.get(t, 0)),    # col 3: food (same source, header says "food")
			"0",                          # col 4: diversity (not yet defined)
			str(_get_dominion(t)),        # col 5: dominion (planets owned)
			str(_get_efficiency(t)),      # col 6: efficiency %
			"0",                          # col 7: Total (not yet defined)
		]

		for col_idx in range(_MAX_COLUMNS):
			add_item(cols[col_idx])
			var idx := item_count - 1
			set_item_selectable(idx, false)
			set_item_custom_bg_color(idx, bg)
			set_item_custom_fg_color(idx, Color(1, 1, 1, 1))
