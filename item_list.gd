extends ItemList

# ── Column mapping (matches header in scoreboard.tscn, 8 cols × 1 header row = 8 items) ──
# col 0 = cultivate icon  → yield grown (crops growing)
# col 1 = collect icon    → crops in all same-team players' inventories (live)
# col 2 = claim icon      → crops delivered to sun (accumulated)
# col 3 = "food"          → 0 (not yet defined)
# col 4 = "diversity"     → 0 (not yet defined)
# col 5 = "dominion"      → planets owned (dominant team)
# col 6 = "efficiency"    → efficiency % (delivered / grown * 100)
# col 7 = "Total"         → 0 (not yet defined)

const _HEADER_ITEMS = 8
const _MAX_COLUMNS  = 8

# ── Per-team accumulators ─────────────────────────────────────────────────────

var _team_yield:     Dictionary = {}   # team_id → crops grown by own cells (live on planets)
var _team_tax_float: Dictionary = {}   # team_id → tax crops earned (float accumulator)
var _team_delivered: Dictionary = {}   # team_id → crops delivered to sun (accumulated)

# ── Remote peer state (populated via ColyseusSync game events) ────────────────
var _remote_food:      Dictionary = {}  # peer_id → food_amount (int)
var _remote_diversity: Dictionary = {}  # peer_id → diversity team count (int)

var _rebuild_dirty: bool = false

# ── Helpers ───────────────────────────────────────────────────────────────────

func _team_color(tid: int) -> Color:
	return GameConfig.color_for(tid)

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
		if ship.get("team_id") != tid:
			continue
		if ship.get("is_local"):
			total += int(ship.get("food_amount") if ship.get("food_amount") != null else 0)
		else:
			var pid = ship.get("peer_id")
			total += _remote_food.get(pid if pid != null else -1, 0)
	return total

# Number of distinct foreign teams whose taxed crops this team has delivered.
func _get_team_diversity(tid: int) -> int:
	var total := 0
	for ship in get_tree().get_nodes_in_group("players"):
		if ship.get("team_id") != tid:
			continue
		if ship.get("is_local"):
			var dt = ship.get("diversity_teams")
			if dt != null:
				total += (dt as Array).size()
		else:
			var pid2 = ship.get("peer_id")
			total += _remote_diversity.get(pid2 if pid2 != null else -1, 0)
	return total

# Sum of total_food_delivered across all players on this team.
func _get_team_delivered(tid: int) -> int:
	var total := 0
	for ship in get_tree().get_nodes_in_group("players"):
		if ship.get("team_id") == tid:
			total += int(ship.get("total_food_delivered") if ship.get("total_food_delivered") != null else 0)
	return total

# leader = 100, others proportional. Returns 0 when no one has scored.
func _relative(value: int, max_value: int) -> int:
	if max_value <= 0:
		return 0
	return clampi(int(float(value) / float(max_value) * 100.0), 0, 100)

# food delivered / yield grown × 100, clamped 0-100 (absolute, used as raw input).
# grown = own crops (live on planets) + tax crops earned (cumulative float → int).
func _get_efficiency(tid: int) -> int:
	var grown: int = _team_yield.get(tid, 0) + int(_team_tax_float.get(tid, 0.0))
	var delivered: int = _team_delivered.get(tid, 0)
	if grown <= 0:
		return 100 if delivered > 0 else 0
	return clampi(int(float(delivered) / float(grown) * 100.0), 0, 100)

# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	focus_mode = Control.FOCUS_NONE
	get_tree().node_added.connect(_on_node_added)
	ColyseusSync.game_event_received.connect(_on_remote_game_event)
	for planet in get_tree().get_nodes_in_group("planets"):
		_connect_planet(planet)
	for ship in get_tree().get_nodes_in_group("players"):
		_connect_ship(ship)
	_rebuild_team_rows()
	for i in range(_HEADER_ITEMS):
		set_item_selectable(i, false)
		set_item_tooltip_enabled(i, false)

func _on_node_added(node: Node) -> void:
	_connect_deferred.call_deferred(node)

func _connect_deferred(node: Node) -> void:
	if node.is_in_group("planets"):
		_connect_planet(node)
		_schedule_rebuild()
	elif node.is_in_group("players"):
		_connect_ship(node)
		_schedule_rebuild()

# ── Signal connections ────────────────────────────────────────────────────────

func _connect_planet(planet: Node) -> void:
	if planet.has_signal("team_yield_updated") and \
			not planet.team_yield_updated.is_connected(_on_team_yield_updated):
		planet.team_yield_updated.connect(_on_team_yield_updated)
	if planet.has_signal("team_tax_earned_updated") and \
			not planet.team_tax_earned_updated.is_connected(_on_team_tax_earned_updated):
		planet.team_tax_earned_updated.connect(_on_team_tax_earned_updated)
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
	if not ship.tree_exiting.is_connected(_on_ship_exiting):
		ship.tree_exiting.connect(_on_ship_exiting)

func _on_ship_exiting() -> void:
	_schedule_rebuild()

func _schedule_rebuild() -> void:
	if _rebuild_dirty:
		return
	_rebuild_dirty = true
	call_deferred("_do_rebuild")

func _do_rebuild() -> void:
	_rebuild_dirty = false
	_rebuild_team_rows()

# ── Signal handlers ───────────────────────────────────────────────────────────

func _on_team_yield_updated(team_id: int, _count: int) -> void:
	var total := 0
	for planet in get_tree().get_nodes_in_group("planets"):
		total += planet.team_yield_counts.get(team_id, 0)
	_team_yield[team_id] = total
	_schedule_rebuild()

func _on_team_tax_earned_updated(team_id: int, amount: float) -> void:
	_team_tax_float[team_id] = _team_tax_float.get(team_id, 0.0) + amount
	_schedule_rebuild()

func _on_food_delivered(team_id: int, amount: int) -> void:
	_team_delivered[team_id] = _team_delivered.get(team_id, 0) + amount
	_schedule_rebuild()

func _on_inventory_changed(_team_id: int) -> void:
	_schedule_rebuild()

func _on_state_changed() -> void:
	_schedule_rebuild()

func _on_remote_game_event(etype: String, data: Dictionary) -> void:
	var pid: int = int(data.get("peer_id", 0))
	match etype:
		"food_delivered":
			var tid: int = int(data.get("team_id", 0))
			var amount: int = int(data.get("amount", 0))
			_team_delivered[tid] = _team_delivered.get(tid, 0) + amount
			_remote_food[pid] = 0
			_remote_diversity[pid] = int(data.get("diversity_count", 0))
			_schedule_rebuild()
		"food_inventory_changed":
			_remote_food[pid] = int(data.get("food_amount", 0))
			_schedule_rebuild()

# Widths derived from header placeholder texts in scoreboard.tscn (max of both header rows).
# Cols 0-2 are variable (large numbers truncated with ellipsis); cols 3-7 are bounded.
const _COL_WIDTHS = [6, 6, 6, 7, 11, 11, 11, 7]

const _FS := " "  # figure space — same width as a digit in any font

func _center_text(text: String, width: int) -> String:
	if text.length() >= width:
		return text
	var total_pad := width - text.length()
	var left_pad  := total_pad / 2
	return _FS.repeat(left_pad) + text + _FS.repeat(total_pad - left_pad)

func _format_millions(n: int) -> String:
	if n >= 1_000_000:
		var m := float(n) / 1_000_000.0
		if m >= 100.0:
			return "%dM" % int(m)       # 3 digits + M = 4 chars
		elif m >= 10.0:
			return "%.1fM" % m          # 2 digits + dot + 1 + M = 5 chars
		else:
			return "%.2fM" % m          # 1 digit + dot + 2 + M = 5 chars
	return str(n)

func _fit_col_text(text: String, col: int) -> String:
	var width: int = _COL_WIDTHS[col]
	if text.length() > width:
		return text.substr(0, width - 1) + "…"
	return _center_text(text, width)

# ── Row builder ───────────────────────────────────────────────────────────────

func _rebuild_team_rows() -> void:
	while item_count > _HEADER_ITEMS:
		remove_item(item_count - 1)

	var team_count := _get_active_team_count()
	if team_count <= 0:
		team_count = 1

	# Gather raw values across all teams so we can score relative to the leader.
	var raw_delivered: Array = []
	var raw_diversity: Array = []
	var raw_dominion:  Array = []
	var raw_efficiency: Array = []
	for t in range(team_count):
		raw_delivered.append(_team_delivered.get(t, 0))
		raw_diversity.append(_get_team_diversity(t))
		raw_dominion.append(_get_dominion(t))
		raw_efficiency.append(_get_efficiency(t))

	var max_delivered: int  = int(raw_delivered.max())  if not raw_delivered.is_empty()  else 0
	var max_diversity: int  = int(raw_diversity.max())  if not raw_diversity.is_empty()  else 0
	var max_dominion:  int  = int(raw_dominion.max())   if not raw_dominion.is_empty()   else 0

	var rows: Array = []
	for t in range(team_count):
		var food_score:      int = _relative(raw_delivered[t],  max_delivered)
		var diversity_score: int = _relative(raw_diversity[t],  max_diversity)
		var dominion_score:  int = _relative(raw_dominion[t],   max_dominion)
		var efficiency:      int = raw_efficiency[t]   # absolute %, not relative
		var total:           int = food_score + diversity_score + dominion_score + efficiency
		rows.append({
			"values": [
				_format_millions(_team_yield.get(t, 0) + int(_team_tax_float.get(t, 0.0))),
				_format_millions(_get_team_inventory(t)),
				_format_millions(raw_delivered[t]),
				str(food_score),
				str(diversity_score),
				str(dominion_score),
				str(efficiency),
				str(total),
			],
			"color": _team_color(t),
			"total": total,
		})
	rows.sort_custom(func(a, b): return a["total"] > b["total"])

	for row in rows:
		var color: Color = row["color"]
		var bg: Color    = Color(color.r, color.g, color.b, 0.25)
		for col_idx in range(_MAX_COLUMNS):
			var text := _fit_col_text(row["values"][col_idx], col_idx)
			add_item(text)
			var idx := item_count - 1
			set_item_selectable(idx, false)
			set_item_tooltip_enabled(idx, false)
			set_item_custom_bg_color(idx, bg)
			set_item_custom_fg_color(idx, Color(1, 1, 1, 1))
