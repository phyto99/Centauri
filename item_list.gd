extends ItemList

# ── Column mapping (matches header in scoreboard.tscn, 8 cols × 2 header rows = 16 items) ──
# col 0 = cultivate icon  → yield grown (crops growing)
# col 1 = collect icon    → crops in all same-team players' inventories (live)
# col 2 = claim icon      → crops delivered to sun (accumulated)
# col 3 = "food"          → 0 (not yet defined)
# col 4 = "diversity"     → 0 (not yet defined)
# col 5 = "dominion"      → planets owned (dominant team)
# col 6 = "efficiency"    → efficiency % (delivered / grown * 100)
# col 7 = "Total"         → 0 (not yet defined)

const _HEADER_ITEMS = 16
const _MAX_COLUMNS  = 8

# ── Per-team accumulators ─────────────────────────────────────────────────────

var _team_yield:     Dictionary = {}   # team_id → total yield grown
var _team_delivered: Dictionary = {}   # team_id → crops delivered to sun (accumulated)

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

# Sum of food_amount across all players on this team (live inventory).
func _get_team_inventory(tid: int) -> int:
	var total := 0
	for ship in get_tree().get_nodes_in_group("players"):
		if ship.get("team_id") == tid:
			total += int(ship.get("food_amount") if ship.get("food_amount") != null else 0)
	return total

# Number of distinct foreign teams whose taxed crops this team has delivered.
func _get_team_diversity(tid: int) -> int:
	for ship in get_tree().get_nodes_in_group("players"):
		if ship.get("team_id") == tid:
			var dt = ship.get("diversity_teams")
			if dt != null:
				return (dt as Array).size()
	return 0

# Sum of total_food_delivered across all players on this team.
func _get_team_delivered(tid: int) -> int:
	var total := 0
	for ship in get_tree().get_nodes_in_group("players"):
		if ship.get("team_id") == tid:
			total += int(ship.get("total_food_delivered") if ship.get("total_food_delivered") != null else 0)
	return total

# Relative food score: leader = 100, others = their_delivered / leader * 100.
func _get_food_score(tid: int, team_count: int) -> int:
	var max_delivered := 0
	for t in range(team_count):
		var d: int = _team_delivered.get(t, 0)
		if d > max_delivered:
			max_delivered = d
	if max_delivered <= 0:
		return 0
	return clampi(int(float(_team_delivered.get(tid, 0)) / float(max_delivered) * 100.0), 0, 100)

# food delivered / yield grown × 100, clamped 0-100.
func _get_efficiency(tid: int) -> int:
	var grown: int = _team_yield.get(tid, 0)
	var delivered: int = _team_delivered.get(tid, 0)
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
	if ship.has_signal("food_inventory_changed") and \
			not ship.food_inventory_changed.is_connected(_on_inventory_changed):
		ship.food_inventory_changed.connect(_on_inventory_changed)

# ── Signal handlers ───────────────────────────────────────────────────────────

func _on_team_yield_updated(team_id: int, _count: int) -> void:
	var total := 0
	for planet in get_tree().get_nodes_in_group("planets"):
		total += planet.team_yield_counts.get(team_id, 0)
	_team_yield[team_id] = total
	_rebuild_team_rows()

func _on_food_delivered(team_id: int, amount: int) -> void:
	_team_delivered[team_id] = _team_delivered.get(team_id, 0) + amount
	_rebuild_team_rows()

func _on_inventory_changed(_team_id: int) -> void:
	_rebuild_team_rows()

func _on_state_changed() -> void:
	_rebuild_team_rows()

# Column widths derived from header row 2 padding in scoreboard.tscn
# Each width = length of the header item text (e.g. "0          " = 11 chars total)
const _COL_WIDTHS = [11, 10, 13, 19, 23, 24, 19, 1]

# Centers a string within a given width by padding with spaces.
func _center_text(text: String, width: int) -> String:
	var text_len := text.length()
	if text_len >= width:
		return text
	var total_pad := width - text_len
	var left_pad := int(total_pad / 2.0)
	var right_pad := total_pad - left_pad
	return " ".repeat(left_pad) + text + " ".repeat(right_pad)

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

		var food_score:  int = _get_food_score(t, team_count)
		var diversity:   int = _get_team_diversity(t)
		var dominion:    int = _get_dominion(t)
		var efficiency:  int = _get_efficiency(t)
		var total:       int = food_score + diversity + dominion + efficiency

		var values: Array = [
			str(_team_yield.get(t, 0)),   # col 0: crops growing (yield)
			str(_get_team_inventory(t)),  # col 1: crops in inventory (live)
			str(_team_delivered.get(t, 0)), # col 2: crops delivered to sun
			str(food_score),              # col 3: relative food score (leader=100)
			str(diversity),               # col 4: diversity
			str(dominion),                # col 5: dominion (planets owned)
			str(efficiency),              # col 6: efficiency %
			str(total),                   # col 7: Total (sum of cols 3-6)
		]

		for col_idx in range(_MAX_COLUMNS):
			var text: String = _center_text(values[col_idx], _COL_WIDTHS[col_idx])
			add_item(text)
			var idx := item_count - 1
			set_item_selectable(idx, false)
			set_item_custom_bg_color(idx, bg)
			set_item_custom_fg_color(idx, Color(1, 1, 1, 1))
