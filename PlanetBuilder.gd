extends RigidBody2D

@export var max_grid_size: int = 12
@export var current_size: int = 0
@export var base_cell_size: float = 70.0
@export var sprite_scene: PackedScene
@export var claim_stamp_scene: PackedScene
@export var cultivate_stamp_scene: PackedScene

enum CellState { UNCLAIMED, CLAIMED, CULTIVATED }
#This code is an autoload, with global variables for easy reference

# Optimization: Use custom resource for cell data to reduce dictionary overhead
class CellData extends Resource:
	var cell: Node2D
	var stamp: Node2D
	var state: int
	var q: int
	var r: int
	var pos: Vector2
	var animation_start_time: float  # Add this to track individual animation times

var grid: Dictionary = {}
var center_position: Vector2
var hex_order: Array = []
var outline_sprite: Sprite2D
var collision_shape: CollisionPolygon2D
var claimed_nodes: Array = []
var triangles: Array = []
var grid_offset: Vector2 = Vector2.ZERO
var current_action: int = CellState.CLAIMED
var adjacency_cache: Dictionary = {}

# Animation properties
var animation_timer: Timer
@export var animation_speed: float = 1.0
@export var animation_scale_min: float = 0.9
@export var animation_scale_max: float = 1.1
@export var animation_duration: float = 1.0  # Duration of each animation cycle

var min_scale_factor: float = 1.5
var max_scale_factor: float = 1

@export var starting_position: Vector2 = Vector2(0, 0)
@export var moves_remaining: int = 999
@export var editing_mode: bool = false
@export var is_sun: bool = false
@export var gravity_strength: float = 160.0   # G constant, matches mapmaker N-body (G_BASE * G_MULT)

var planet_name: String = ""

# ── Appearance ────────────────────────────────────────────────────────────────
# Color index matches PLANET_COLORS order; texture index: 0=bluegreen, 1=sapphire
var planet_color_index: int = 0
var planet_texture_index: int = 0

# Colors are hue-shift modulates applied to the base texture.
# The textures are already tinted (bluegreen ≈ cyan-green, sapphire ≈ blue).
# We modulate to shift toward the target hue.
const PLANET_COLORS: Array = [
	# name,           shader color,                contrast, brightness
	["Sapphire",   Color(0.20, 0.40, 0.85),  2.0,  1.8],   # 0
	["Green",      Color(0.10, 0.45, 0.12),  2.5,  2.0],   # 1
	["Bluegreen",  Color(1.00, 1.00, 1.00),  1.0,  1.0],   # 2 — no shader
	["Grey",       Color(0.72, 0.72, 0.72),  6.5,  1.0],   # 3 — mid grey, extreme contrast
	["Gold",       Color(1.00, 0.95, 0.75),  1.2,  1.8],   # 4
	["Pink",       Color(1.00, 0.47, 0.42),  1.3,  1.8],   # 5 — original pink, trace orange
	["Red",        Color(0.50, 0.10, 0.15),  2.0,  1.8],   # 6 — slightly cooler, duller
]

const _TEX_SETS: Array = [
	["res://planet/bluegreen.svg", "res://planet/bluegreen-open.svg"],
]

func apply_appearance() -> void:
	if not outline_sprite:
		return
	# Always bluegreen texture
	_TEX_DEFAULT = load("res://planet/bluegreen.svg")
	_TEX_HOVER   = load("res://planet/bluegreen-open.svg")
	var any_landed := _has_landed_player()
	outline_sprite.texture = _TEX_HOVER if any_landed else _TEX_DEFAULT
	outline_sprite.modulate = Color.WHITE

	var entry: Array = PLANET_COLORS[planet_color_index % PLANET_COLORS.size()]
	var col: Color  = entry[1]
	var cont: float = entry[2]
	var brit: float = entry[3]
	# White = bluegreen native, no shader needed
	if col == Color(1.00, 1.00, 1.00):
		outline_sprite.material = null
	else:
		if not (outline_sprite.material is ShaderMaterial):
			var mat := ShaderMaterial.new()
			mat.shader = load("res://planet_color.gdshader")
			outline_sprite.material = mat
		outline_sprite.material.set_shader_parameter("planet_color", col)
		outline_sprite.material.set_shader_parameter("contrast", cont)
		outline_sprite.material.set_shader_parameter("brightness", brit)

signal moves_updated(remaining)
signal yield_updated(count)
signal team_yield_updated(team_id: int, count: int)
signal tax_updated
signal planet_hovered(planet: Node)
signal planet_unhovered


func _ready():
	if not sprite_scene:
		set_process(false)
		set_physics_process(false)
		set_process_input(false)
		return
	add_to_group("planets")
	planet_name = _generate_planet_name()
	input_pickable = true
	mouse_entered.connect(func():
		emit_signal("planet_hovered", self)
		if not is_sun:
			outline_sprite.texture = _TEX_HOVER)
	mouse_exited.connect(func():
		emit_signal("planet_unhovered")
		if not is_sun and not _has_landed_player():
			outline_sprite.texture = _TEX_DEFAULT)
	position = starting_position
	setup_collision_and_outline()
	set_team_color(team_id)
	setup_animation_timer()
	center_position = Vector2.ZERO
	calculate_hex_order()
	generate_grid()
	collision_layer = 2
	collision_mask = 2
	if is_sun:
		_setup_as_sun()

func _setup_as_sun() -> void:
	add_to_group("sun_planet")
	editing_mode = true
	freeze_mode = RigidBody2D.FREEZE_MODE_STATIC
	freeze = true
	if current_size != 100:
		current_size = 100
		generate_grid()
	var white_mat := ShaderMaterial.new()
	white_mat.shader = load("res://cyanwhite.gdshader")
	white_mat.set_shader_parameter("team_color", Color.WHITE)
	outline_sprite.material = white_mat
	if glow_sprite.material is ShaderMaterial:
		glow_sprite.material.set_shader_parameter("team_color", Color.WHITE)
	glow_sprite.modulate = Color.WHITE
	glow_sprite.visible = true

func disable_collision():
	# Disable collision to allow the ship to pass through
	collision_shape.set_deferred("disabled", true)
	
	# Use a timer to re-enable collision if the ship doesn't call enable_collision
	var timer = get_tree().create_timer(2.0)
	timer.timeout.connect(enable_collision)

func enable_collision():
	# Re-enable collision
	collision_shape.set_deferred("disabled", false)

var dominion: int = 0
var diversity: int = 0
var efficiency: float = 0.0
var food: int = 0
var total_yield_collected: int = 0  # Track total yield collected over time

signal food_updated(amount)
signal dominion_updated(amount)
signal diversity_updated(amount)
signal efficiency_updated(amount)

# Add this function to update the stats
func update_stats():
	# Update dominion based on glow sprite visibility
	dominion = 100 if glow_sprite.visible else 0
	emit_signal("dominion_updated", dominion)
	
	# Diversity is always 0 as per requirements
	diversity = 0
	emit_signal("diversity_updated", diversity)
	
	# Calculate efficiency (protect against division by zero)
	if total_yield_collected > 0:
		efficiency = float(yield_count) / total_yield_collected * 100
	else:
		efficiency = 0.0
	emit_signal("efficiency_updated", efficiency)

func _process(_delta):
	update_cell_positions()
	update_stats()

func _physics_process(_delta):
	if is_sun or freeze:
		return

	# N-body gravity: attract toward every other planet (including sun)
	for other in get_tree().get_nodes_in_group("planets"):
		if not is_instance_valid(other) or other == self:
			continue
		var to_other: Vector2 = other.global_position - global_position
		var dist_sq: float = to_other.length_squared()
		if dist_sq < 1.0:
			continue
		var dist: float = sqrt(dist_sq)
		# F = G * M / r²  (applied as acceleration, so mass of self cancels)
		var force: float = gravity_strength * other.mass / dist_sq
		apply_central_force(to_other.normalized() * force)

	# Gravity toward ships (existing behaviour)
	for ship in get_tree().get_nodes_in_group("players"):
		if not is_instance_valid(ship):
			continue
		if ship.get("landed_planet") != null:
			continue
		var to_planet: Vector2 = global_position - ship.global_position
		var dist_sq: float = to_planet.length_squared()
		if dist_sq < 1.0:
			continue
		ship.apply_central_force(to_planet.normalized() * gravity_strength * mass / dist_sq)

func update_cell_positions():
	# This keeps the grid aligned with the planet as it moves
	for cell_data in grid.values():
		if cell_data.has("cell") and is_instance_valid(cell_data["cell"]):
			# Use the stored relative position and update actual position
			cell_data["cell"].position = cell_data["pos"]
			
		if cell_data.has("stamp") and is_instance_valid(cell_data["stamp"]):
			cell_data["stamp"].position = cell_data["pos"]

var glow_sprite: Sprite2D
var surface_radius: float = 0.0

var _TEX_DEFAULT: Texture2D = preload("res://planet/bluegreen.svg")
var _TEX_HOVER:   Texture2D = preload("res://planet/bluegreen-open.svg")

func set_player_landed(landed: bool) -> void:
	if is_sun:
		return
	outline_sprite.texture = _TEX_HOVER if landed else _TEX_DEFAULT

func setup_collision_and_outline():
	collision_shape = CollisionPolygon2D.new()
	add_child(collision_shape)
	outline_sprite = Sprite2D.new()
	outline_sprite.texture = _TEX_DEFAULT
	# Random rotation so each planet looks unique
	outline_sprite.rotation = randf() * TAU
	add_child(outline_sprite)
	outline_sprite.z_index = 1

	glow_sprite = Sprite2D.new()
	var glow_texture = load("res://planet/glow.svg")
	if glow_texture:
		glow_sprite.texture = glow_texture
		add_child(glow_sprite)
		# Set z_index below the outline but above other elements
		glow_sprite.z_index = 0
		# Initially hide the glow
		glow_sprite.visible = false
		glow_sprite.offset = Vector2(2.5, 2.5)
		
		# Apply shader to glow sprite
		var shader_material = ShaderMaterial.new()
		var shader = load("res://cyanwhite.gdshader")  # Make sure to use the correct path
		shader_material.shader = shader
		shader_material.set_shader_parameter("team_color", GameConfig.color_for(team_id))
		glow_sprite.material = shader_material
		
		
func calculate_hex_order():
	# Create initial list of coordinates with their distances from center
	var coords = []
	# Generate coordinates within a hexagon-shaped area
	for q in range(-max_grid_size, max_grid_size + 1):
		for r in range(-max_grid_size, max_grid_size + 1):
			var s = -q - r
			# Ensure the coordinates are within the hexagon bounds
			if abs(q) <= max_grid_size and abs(r) <= max_grid_size and abs(s) <= max_grid_size:
				# Convert axial coordinates to pixel coordinates for flat-top hexagons
				var x = base_cell_size * (3.0/2.0 * q)
				var y = base_cell_size * (sqrt(3.0)/2.0 * q + sqrt(3.0) * r)
				# Calculate Euclidean distance from center
				var distance = Vector2(x, y).length()
				coords.append({
					"q": q,
					"r": r,
					"s": s,
					"distance": distance
				})
	# Sort coordinates by distance from center
	coords.sort_custom(func(a, b): return a.distance < b.distance)
	# Manually reorder the first 7 coordinates to match the desired order
	var first_seven = [
		{"q": 0, "r": 0, "s": 0, "distance": 0.0},
		{"q": 1, "r": 0, "s": -1, "distance": base_cell_size * 1.5},
		{"q": 0, "r": 1, "s": -1, "distance": base_cell_size * sqrt(3.0) / 2},
		{"q": -1, "r": 1, "s": 0, "distance": base_cell_size * sqrt(3.0) / 2},
		{"q": -1, "r": 0, "s": 1, "distance": base_cell_size * 1.5},
		{"q": 1, "r": -1, "s": 0, "distance": base_cell_size * sqrt(3.0) / 2},
		{"q": 0, "r": -1, "s": 1, "distance": base_cell_size * sqrt(3.0) / 2},
	]
	for i in range(7):
		coords[i] = first_seven[i]
	hex_order = coords
func calculate_current_scale() -> float:
	if current_size <= 1:
		return min_scale_factor
	elif current_size >= 300:
		return max_scale_factor
	return min_scale_factor - (current_size - 1) * (min_scale_factor - max_scale_factor) / (300 - 1)
func get_current_cell_size() -> float:
	return base_cell_size * calculate_current_scale()
func generate_grid():
	# Store old claimed node positions before clearing
	var old_claimed_positions = {}
	for key in claimed_nodes:
		if grid.has(key):
			old_claimed_positions[key] = grid[key]["pos"]
	# Clear existing grid and stamps
	for cell_data in grid.values():
		if cell_data.has("cell") and is_instance_valid(cell_data["cell"]):
			cell_data["cell"].queue_free()
		if cell_data.has("stamp") and is_instance_valid(cell_data["stamp"]):
			cell_data["stamp"].queue_free()
	grid.clear()
	var current_cell_size = get_current_cell_size()
	# Add hexagons up to current_size
	var cells_to_add = min(current_size, hex_order.size())
	for i in range(cells_to_add):
		var coord = hex_order[i]
		create_cell(coord.q, coord.r, current_cell_size)
	center_grid()
	update_outline_size()
	# Restore claimed nodes and stamps
	for key in claimed_nodes:
		if grid.has(key):
			place_sprite_and_fill(Vector2(
				float(key.split(",")[0]),
				float(key.split(",")[1])
			))
	check_for_triangles()
	queue_redraw()
func center_grid():
	if grid.is_empty():
		return
	var min_x = INF
	var max_x = -INF
	var min_y = INF
	var max_y = -INF
	for cell_data in grid.values():
		var pos = cell_data["cell"].position
		min_x = min(min_x, pos.x)
		max_x = max(max_x, pos.x)
		min_y = min(min_y, pos.y)
		max_y = max(max_y, pos.y)
	var grid_center = Vector2((min_x + max_x) / 2, (min_y + max_y) / 2)
	grid_offset = center_position - grid_center  # Store the offset
	for cell_data in grid.values():
		cell_data["cell"].position += grid_offset
		cell_data["pos"] = cell_data["cell"].position  # Store the position relative to the planet
		if cell_data.has("stamp"):
			cell_data["stamp"].position += grid_offset
func create_cell(q: int, r: int, current_cell_size: float):
	# Flat-top orientation conversion from axial to pixel coordinates
	var x = current_cell_size * (3.0/2.0 * q)
	var y = current_cell_size * (sqrt(3.0)/2.0 * q + sqrt(3.0) * r)
	var cell = sprite_scene.instantiate()
	add_child(cell)
	var scale_factor = current_cell_size / base_cell_size
	cell.scale = Vector2(scale_factor, scale_factor)
	cell.position = center_position + Vector2(x, y)
	var key = str(q) + "," + str(r)
	grid[key] = {
		"cell": cell,
		"q": q,
		"r": r,
		"pos": center_position + Vector2(x, y)  # Store the position relative to the planet
	}

func update_outline_size():
	var current_scale = calculate_current_scale()
	# Calculate the base extent
	var base_extent = 0.0
	if current_size == 0 or current_size == 1:
		# Use the size for one hexagon, same as size 2
		var coord = hex_order[1]
		var x = base_cell_size * (3.0/2.0 * coord.q)
		var y = base_cell_size * (sqrt(3.0)/2.0 * coord.q + sqrt(3.0) * coord.r)
		base_extent = Vector2(x, y).length() * 0.25
	else:
		# Calculate from actual grid
		for cell_data in grid.values():
			var pos = cell_data["cell"].position - center_position
			base_extent = max(base_extent, pos.length())
	# Apply the current scale to the extent
	var scaled_extent = base_extent * current_scale
	# Calculate margin based on early game (0-60)
	var base_margin = 0.745  # Base multiplier for the outline
	var extra_margin = 0
	if current_size <= 100:
		var margin_percent = pow(1.0 - (current_size / 100.0), 6)  # Quadratic falloff for smoother transition
		extra_margin = 1.5 * margin_percent  # Keeps the outline more visible in early sizes
	# Ensure `current_size == 1` gets an outline matching `current_size == 2`
	if current_size <= 1:
		extra_margin = max(extra_margin, 4)  # Prevent it from being too small
	# Boost extra_margin slightly for sizes in the 50s-60 range
	if current_size >= 50 and current_size <= 60:
		extra_margin *= 5  # Increase by 15% for better visibility
	# Calculate growth scale (continues as before)
	var growth_scale = 1.0 + (current_size / 300.0) * 0.5  # Scales from 1.0 to 1.5 as size increases
	
	var desired_radius = scaled_extent * (base_margin + extra_margin) * growth_scale
	var base_size = outline_sprite.texture.get_size()
	var outline_scale_factor = (desired_radius * 2) / min(base_size.x, base_size.y)
	
	outline_sprite.scale = Vector2(outline_scale_factor, outline_scale_factor)
	outline_sprite.position = center_position
	
	# Update collision shape
	update_collision_shape(desired_radius)
	
	# Add this: Update glow sprite scale and position to match outline
	glow_sprite.scale = outline_sprite.scale
	glow_sprite.position = center_position
	
	# Show glow only if we have claimed nodes
	glow_sprite.visible = claimed_nodes.size() > 0
	if is_sun:
		glow_sprite.visible = true
	
func update_collision_shape(radius: float):
	surface_radius = radius
	var num_points = 32
	var points = PackedVector2Array()
	for i in range(num_points):
		var angle = i * PI * 2 / num_points
		points.append(Vector2(cos(angle), sin(angle)) * radius + center_position)
	points.append(points[0])
	collision_shape.polygon = points

func on_slider_value_changed(value: float):
	current_size = int(value)
	generate_grid()

@export var outline_color: Color = Color(1, 1, 1, 0.8)  # White with alpha

# Modified _draw function
func _draw():
	if grid.size() >= 2:
		var current_scale = calculate_current_scale()
		var line_width = 8.0 * current_scale
		
		# Draw triangles first so grid lines render on top
		for triangle in triangles:
			var points = PackedVector2Array([
				grid[triangle[0]]["cell"].position,
				grid[triangle[1]]["cell"].position,
				grid[triangle[2]]["cell"].position
			])
			var alpha = clamp(0.5 * current_scale, 0.2, 0.5)
			var tri_team = grid[triangle[0]].get("team_id", team_id)
			var tri_color = GameConfig.color_for(tri_team)
			draw_colored_polygon(points, Color(tri_color.r, tri_color.g, tri_color.b, alpha))

		# Draw grid lines on top of triangles
		for key1 in grid.keys():
			var pos1 = grid[key1]["cell"].position
			for key2 in grid.keys():
				if key1 != key2 and is_adjacent(grid[key1], grid[key2]):
					var pos2 = grid[key2]["cell"].position
					var direction = (pos2 - pos1).normalized()
					var distance = pos1.distance_to(pos2)
					var half_distance = distance * 0.30
					var start_point = pos1 + (direction * half_distance)
					var end_point = pos1 + (direction * (distance - half_distance))
					draw_line(start_point, end_point, Color.WHITE, line_width)

		# Black filled circles — same size as lattice1 sprite, above lines, below cell sprites
		var cell_radius := 0.0
		for k in grid.keys():
			var cn = grid[k]["cell"]
			if cn is Sprite2D and cn.texture:
				cell_radius = cn.texture.get_size().x * 0.5 * cn.scale.x
				break
		if cell_radius > 0.0:
			for k in grid.keys():
				draw_circle(grid[k]["cell"].position, cell_radius, Color.BLACK)


func is_adjacent(cell1: Dictionary, cell2: Dictionary) -> bool:
	# Defensive checks
	if not (cell1.has("q") and cell1.has("r") and cell2.has("q") and cell2.has("r")):
		return false
	
	var q1 = cell1["q"]
	var r1 = cell1["r"]
	var q2 = cell2["q"]
	var r2 = cell2["r"]
	
	# Calculate third coordinate (s) for both cells
	var s1 = -q1 - r1
	var s2 = -q2 - r2
	
	# Calculate the absolute differences
	var dq = abs(q1 - q2)
	var dr = abs(r1 - r2)
	var ds = abs(s1 - s2)
	
	# Two hexes are adjacent if the sum of differences is 2
	return (dq + dr + ds) == 2

# Fixed: This function is completely rewritten to properly handle local and global coordinates
func find_closest_hex(global_mouse_pos: Vector2) -> String:
	# Convert global mouse position to local position in planet's space
	var local_mouse_pos = to_local(global_mouse_pos)
	
	# Use axial coordinates for more efficient closest hex finding
	var current_cell_size = get_current_cell_size()
	var q_approx = (2.0/3.0 * local_mouse_pos.x) / current_cell_size
	var r_approx = (-1.0/3.0 * local_mouse_pos.x + sqrt(3.0)/3.0 * local_mouse_pos.y) / current_cell_size
	
	# Round to get the closest axial coordinates
	var q_rounded = round(q_approx)
	var r_rounded = round(r_approx)
	
	# Calculate the third coordinate
	var s_rounded = -q_rounded - r_rounded
	
	# Check if the rounded key exists in the grid
	var key = str(int(q_rounded)) + "," + str(int(r_rounded))
	if grid.has(key):
		# Calculate the actual distance to verify it's close enough
		var distance = local_mouse_pos.distance_to(grid[key]["cell"].position)
		if distance <= current_cell_size:
			return key
	
	# If we didn't find a match with the mathematical approach,
	# check the immediate neighbors
	var neighbors = [
		Vector2(q_rounded, r_rounded),
		Vector2(q_rounded+1, r_rounded),
		Vector2(q_rounded-1, r_rounded),
		Vector2(q_rounded, r_rounded+1),
		Vector2(q_rounded, r_rounded-1),
		Vector2(q_rounded+1, r_rounded-1),
		Vector2(q_rounded-1, r_rounded+1)
	]
	
	var closest_distance = INF
	var closest_key = ""
	
	for neighbor in neighbors:
		key = str(int(neighbor.x)) + "," + str(int(neighbor.y))
		if grid.has(key):
			var distance = local_mouse_pos.distance_to(grid[key]["cell"].position)
			if distance < closest_distance and distance <= current_cell_size:
				closest_distance = distance
				closest_key = key
	
	return closest_key

func _has_landed_player() -> bool:
	for ship in get_tree().get_nodes_in_group("players"):
		if is_instance_valid(ship) and ship.get("landed_planet") == self:
			return true
	return false

func _get_active_landed_player() -> Node:
	# Prefer the player whose camera is active
	for ship in get_tree().get_nodes_in_group("players"):
		if not is_instance_valid(ship):
			continue
		if ship.get("landed_planet") != self:
			continue
		var cam = ship.get_node_or_null("Camera2D")
		if cam and cam.enabled:
			return ship
	# Fallback: any landed player
	for ship in get_tree().get_nodes_in_group("players"):
		if is_instance_valid(ship) and ship.get("landed_planet") == self:
			return ship
	return null

func _input(event):
	if editing_mode:
		return
	# Only the camera-active player landing on THIS planet may act
	var acting_player: Node = null
	for ship in get_tree().get_nodes_in_group("players"):
		if not is_instance_valid(ship):
			continue
		if ship.get("landed_planet") != self:
			continue
		var cam = ship.get_node_or_null("Camera2D")
		if cam and cam.enabled:
			acting_player = ship
			break
	if acting_player == null:
		return

	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var global_mouse_pos = get_global_mouse_position()
		var local_mouse_pos = to_local(global_mouse_pos)

		var rect = Rect2(collision_shape.polygon[0], Vector2.ZERO)
		for point in collision_shape.polygon:
			rect = rect.expand(point)
		if not rect.has_point(local_mouse_pos):
			return

		var closest_hex = find_closest_hex(global_mouse_pos)
		if closest_hex == "":
			return

		var current_cell_state = grid[closest_hex].get("state", CellState.UNCLAIMED)
		var current_cell_team: int = grid[closest_hex].get("team_id", -1)

		# Snapshot action now — before any state mutation
		# Read from UI so last-pressed button always wins, even after landing on a new planet
		var action_to_apply: int = current_action
		var ui_nodes := get_tree().get_nodes_in_group("ui_controller")
		if ui_nodes.size() > 0:
			var ui_mode: String = ui_nodes[0].get_current_mode()
			if ui_mode == "cultivate":
				action_to_apply = CellState.CULTIVATED
			elif ui_mode == "claim":
				action_to_apply = CellState.CLAIMED

		if action_to_apply == CellState.CULTIVATED:
			# Cultivate only lands on empty cells
			if current_cell_state != CellState.UNCLAIMED:
				return
		elif action_to_apply == CellState.CLAIMED:
			# Can't re-claim your own cell
			if current_cell_state == CellState.CLAIMED and current_cell_team == acting_player.team_id:
				return
			# Can't claim over a cultivate that's locked in a triangle
			if current_cell_state == CellState.CULTIVATED and _is_in_triangle(closest_hex):
				return

		if moves_remaining <= 0:
			return

		# Lock in team and action from the active player before any mutation
		team_id = acting_player.team_id

		moves_remaining -= 1
		emit_signal("moves_updated", moves_remaining)

		if not closest_hex in claimed_nodes:
			claimed_nodes.append(closest_hex)

		place_sprite_and_fill(Vector2(
			float(closest_hex.split(",")[0]),
			float(closest_hex.split(",")[1])
		), action_to_apply)

		if action_to_apply == CellState.CULTIVATED:
			check_for_triangles()
		elif action_to_apply == CellState.CLAIMED:
			var new_dominant := _get_dominant_team_id()
			if new_dominant != dominant_team_id:
				dominant_team_id = new_dominant
				tax_rate = 5
				var popup := _get_or_create_tax_popup()
				if popup:
					popup.open(self)

		queue_redraw()

# Add point in polygon test function
func is_point_in_polygon(point: Vector2, polygon: PackedVector2Array) -> bool:
	var inside = false
	var j = polygon.size() - 1
	
	for i in range(polygon.size()):
		if ((polygon[i].y > point.y) != (polygon[j].y > point.y) and 
			point.x < (polygon[j].x - polygon[i].x) * (point.y - polygon[i].y) / 
			(polygon[j].y - polygon[i].y) + polygon[i].x):
			inside = not inside
		j = i
	
	return inside

func is_valid_triangle(node1: String, node2: String, node3: String) -> bool:
	# First check if all nodes exist in the grid
	if not (grid.has(node1) and grid.has(node2) and grid.has(node3)):
		return false
		
	# Then check if all three pairs of nodes are adjacent and the nodes exist in grid
	return (grid.has(node1) and grid.has(node2) and is_adjacent(grid[node1], grid[node2])) and \
		   (grid.has(node2) and grid.has(node3) and is_adjacent(grid[node2], grid[node3])) and \
		   (grid.has(node3) and grid.has(node1) and is_adjacent(grid[node3], grid[node1]))

func setup_animation_timer():
	animation_timer = Timer.new()
	animation_timer.wait_time = 0.016  # ~60 FPS
	animation_timer.connect("timeout", _on_animation_timer_timeout)
	add_child(animation_timer)
	animation_timer.start()

var yield_count: int = 0
var team_yield_counts: Dictionary = {}
var dominant_team_id: int = -1
var tax_rate: int = 5
var team_tax_paid: Dictionary = {}
var team_tax_earned: Dictionary = {}
var team_tax_earned_per_source: Dictionary = {}  # dominant_tid → {source_tid → float}

func _on_animation_timer_timeout():
	var main_node: Node = get_tree().get_first_node_in_group("main")
	var game_running: bool = main_node != null and bool(main_node.get("_running"))
	var current_time = Time.get_ticks_msec() / 1000.0

	for cell_data in grid.values():
		if cell_data.has("stamp") and cell_data["stamp"] and cell_data.has("state"):
			var stamp = cell_data["stamp"]
			
			# Get the main sprite and overlay sprite
			if stamp.get_child_count() >= 2:
				var main_sprite = stamp.get_child(0)
				var overlay_sprite = stamp.get_child(1)
				
				if cell_data["state"] == CellState.CULTIVATED:
					# Calculate progress based on individual start time
					var elapsed_time = current_time - cell_data.get("animation_start_time", 0.0)
					var progress = fmod(elapsed_time, animation_duration) / animation_duration
					
					# Check if animation completed a cycle
					if cell_data.has("last_progress") and cell_data["last_progress"] > progress:
						if game_running:
							yield_count += 1
							emit_signal("yield_updated", yield_count)
							var cell_team = cell_data.get("team_id", team_id)
							team_yield_counts[cell_team] = team_yield_counts.get(cell_team, 0) + 1
							emit_signal("team_yield_updated", cell_team, team_yield_counts[cell_team])
							if dominant_team_id >= 0 and cell_team != dominant_team_id:
								var tax := tax_rate / 10.0
								team_tax_paid[cell_team] = team_tax_paid.get(cell_team, 0.0) + tax
								team_tax_earned[dominant_team_id] = team_tax_earned.get(dominant_team_id, 0.0) + tax
								if not team_tax_earned_per_source.has(dominant_team_id):
									team_tax_earned_per_source[dominant_team_id] = {}
								var tes: Dictionary = team_tax_earned_per_source[dominant_team_id]
								tes[cell_team] = tes.get(cell_team, 0.0) + tax
								emit_signal("tax_updated")
					
					# Store current progress for next frame comparison
					cell_data["last_progress"] = progress
					
					# Shader handles color; update param each frame in case team changed
					var cell_team_id = cell_data.get("team_id", team_id)
					var cell_team_color = GameConfig.color_for(cell_team_id)
					if overlay_sprite.material is ShaderMaterial:
						overlay_sprite.material.set_shader_parameter("team_color", cell_team_color)
					overlay_sprite.visible = true
					overlay_sprite.scale = Vector2.ONE
					overlay_sprite.modulate = Color(1, 1, 1, 0.7)
					
					# Animate main sprite (scale from 0% to 100% and reset)
					var scale_factor = lerp(0.01, 1.0, progress)
					main_sprite.scale = Vector2.ONE * scale_factor
				elif cell_data["state"] == CellState.CLAIMED:
					# For claimed state, keep both sprites at normal scale
					main_sprite.scale = Vector2.ONE
					overlay_sprite.visible = false
					
#var team_color = get_node("CameraController").team_color
var team_id = 0  # Default team ID
func set_team_color(id):
	team_id = id
	# When we change team, update all existing stamps
	update_all_stamps()

func place_sprite_and_fill(grid_coords: Vector2, action: int = current_action):
	var key = str(grid_coords.x) + "," + str(grid_coords.y)
	if not grid.has(key):
		push_warning("Attempted to access invalid grid key: " + key)
		return

	var cell_data = grid[key]
	var current_scale = calculate_current_scale()
	
	# Check if we're changing from cultivated to claimed
	var was_cultivated = cell_data.has("state") and cell_data["state"] == CellState.CULTIVATED
	var changing_to_claimed = was_cultivated and action == CellState.CLAIMED
	
	# Remove existing stamp if present
	if cell_data.has("stamp") and is_instance_valid(cell_data["stamp"]):
		cell_data["stamp"].queue_free()
	
	# Create new stamp based on action
	var stamp_scene = cultivate_stamp_scene if action == CellState.CULTIVATED else claim_stamp_scene
	var stamp = stamp_scene.instantiate()
	
	# Use the cell's current position
	stamp.position = cell_data["pos"]
	stamp.scale = Vector2.ONE * current_scale
	stamp.z_index = 0
	add_child(stamp)
	
	# Apply team color to the stamp
	apply_team_color_to_stamp(stamp)
	
	if action == CellState.CULTIVATED:
		var main_sprite = stamp.get_child(0)
		var overlay_sprite = stamp.get_child(1)
		# Shader handles RGB — modulate controls alpha only
		main_sprite.modulate = Color(1, 1, 1, 0.5)
		main_sprite.scale = Vector2.ONE * 0.01
		overlay_sprite.visible = true
		overlay_sprite.modulate = Color(1, 1, 1, 0.7)
		overlay_sprite.scale = Vector2.ONE
		
		cell_data["animation_start_time"] = Time.get_ticks_msec() / 1000.0
	
	cell_data["stamp"] = stamp
	cell_data["state"] = action
	cell_data["team_id"] = team_id  # Store the team ID with the cell data
	
	# If we're changing from cultivated to claimed, clear and recheck triangles
	if changing_to_claimed:
		triangles.clear()
		check_for_triangles()
	
	# MODIFY THIS PART: Check if any cell has CLAIMED state instead of just checking claimed_nodes size
	# Count how many cells have CLAIMED state
	var has_claimed_cells = false
	for node_key in claimed_nodes:
		if grid.has(node_key) and grid[node_key].has("state") and grid[node_key]["state"] == CellState.CLAIMED:
			has_claimed_cells = true
			break
	
	# Only show glow if there are claimed (not cultivated) cells
	glow_sprite.visible = has_claimed_cells

	if glow_sprite.visible:
		_set_glow_color(_get_dominant_claim_color())

func _set_glow_color(color: Color) -> void:
	glow_sprite.modulate = color
	if glow_sprite.material is ShaderMaterial:
		glow_sprite.material.set_shader_parameter("team_color", color)

func _get_dominant_team_id() -> int:
	var counts: Dictionary = {}
	for key in claimed_nodes:
		if not grid.has(key):
			continue
		var cell = grid[key]
		if cell.get("state", 0) != CellState.CLAIMED:
			continue
		var tid: int = cell.get("team_id", 0)
		counts[tid] = counts.get(tid, 0) + 1
	if counts.is_empty():
		return -1
	var best_tid := -1
	var best_count := -1
	for tid in counts:
		if counts[tid] > best_count:
			best_count = counts[tid]
			best_tid = tid
	return best_tid

func _get_dominant_claim_color() -> Color:
	var tid := _get_dominant_team_id()
	return GameConfig.color_for(tid if tid >= 0 else team_id)

const _TAX_POPUP_SCENE := preload("res://tax_popup.tscn")

func _get_or_create_tax_popup() -> Node:
	var existing := get_tree().get_root().find_child("TaxPopup", true, false)
	if existing:
		return existing
	var popup := _TAX_POPUP_SCENE.instantiate()
	get_tree().get_root().add_child(popup)
	return popup

func _tint_sprite(node: Node, color: Color) -> void:
	if not node is Sprite2D:
		return
	if node.material is ShaderMaterial:
		var mat: ShaderMaterial = node.material.duplicate()
		node.material = mat
		mat.set_shader_parameter("team_color", color)
	else:
		node.modulate = color

func apply_team_color_to_stamp(stamp: Node):
	var color = GameConfig.color_for(team_id)
	# The stamp root may itself be the Sprite2D (e.g. claim.tscn)
	_tint_sprite(stamp, color)
	for i in range(stamp.get_child_count()):
		_tint_sprite(stamp.get_child(i), color)

func update_stamp_appearance(stamp: Node, state: CellState):
	if stamp.get_child_count() < 2:
		return

	var main_sprite = stamp.get_child(0)
	var overlay_sprite = stamp.get_child(1)
	
	# Get the team color for this stamp
	var team_color = GameConfig.color_for(team_id)

	match state:
		CellState.CLAIMED:
			# Use the team color for claimed state
			apply_team_color_to_stamp(stamp)
			main_sprite.scale = Vector2.ONE
			
		CellState.CULTIVATED:
			main_sprite.modulate = Color(1, 1, 1, 0.5)
			main_sprite.scale = Vector2.ONE * 0.01
			overlay_sprite.visible = true
			overlay_sprite.modulate = Color(1, 1, 1, 0.7)
			overlay_sprite.scale = Vector2.ONE

func update_all_stamps():
	for cell_data in grid.values():
		if cell_data.has("stamp") and cell_data.has("state"):
			# If the cell has a team_id, use it, otherwise use the current team_id
			var stamp_team_id = cell_data.get("team_id", team_id)
			var temp_team_id = team_id
			
			# Temporarily set the team_id to the stamp's team_id
			team_id = stamp_team_id
			update_stamp_appearance(cell_data["stamp"], cell_data["state"])
			
			# Restore the original team_id
			team_id = temp_team_id
	
	# Also update glow_sprite color if visible
	if glow_sprite.visible:
		_set_glow_color(_get_dominant_claim_color())

# Remove unused coordinate conversion functions since we're using simple distance checks
func pixel_to_hex(pixel: Vector2) -> Vector2:
	push_warning("This function is deprecated and should not be called")
	return Vector2.ZERO

func hex_round(hex: Vector2) -> Vector2:
	push_warning("This function is deprecated and should not be called")
	return Vector2.ZERO

func create_circle_texture(radius: int, color: Color) -> ImageTexture:
	var image = Image.new()
	image.create(radius * 2, radius * 2, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	
	for x in range(radius * 2):
		for y in range(radius * 2):
			var dx = x - radius
			var dy = y - radius
			if dx * dx + dy * dy <= radius * radius:
				image.set_pixel(x, y, color)
	
	var texture = ImageTexture.new()
	texture.create_from_image(image)
	return texture

func cache_adjacent_cells():
	adjacency_cache.clear()
	
	# Define the six possible adjacent directions in axial coordinates
	var directions = [
		Vector2(1, 0), Vector2(1, -1), Vector2(0, -1),
		Vector2(-1, 0), Vector2(-1, 1), Vector2(0, 1)
	]
	
	for key in grid.keys():
		var q = int(key.split(",")[0])
		var r = int(key.split(",")[1])
		adjacency_cache[key] = []
		
		# Check each of the six possible adjacent cells
		for dir in directions:
			var adj_q = q + int(dir.x)
			var adj_r = r + int(dir.y)
			var adj_key = str(adj_q) + "," + str(adj_r)
			
			if grid.has(adj_key):
				adjacency_cache[key].append(adj_key)

func _is_in_triangle(hex_key: String) -> bool:
	for triangle in triangles:
		if hex_key in triangle:
			return true
	return false

func check_for_triangles():
	triangles.clear()
	var cultivated_cells = []
	
	# Only refresh adjacency cache every 5 clicks to save performance
	if adjacency_cache.is_empty() or claimed_nodes.size() % 5 == 0:
		cache_adjacent_cells()
	
	# Collect all cultivated cells grouped by team
	for key in claimed_nodes:
		if grid.has(key) and \
		   grid[key].has("state") and \
		   grid[key]["state"] == CellState.CULTIVATED:
			cultivated_cells.append(key)
	
	# Early exit if we don't have enough cells for a triangle
	if cultivated_cells.size() < 3:
		return
	
	# Use a dictionary to cache results of checking if a node is cultivated
	var cultivated_cache = {}
	for node in cultivated_cells:
		cultivated_cache[node] = true
		
	# Create a more efficient lookup of potential triangles
	var triangle_lookup = {}
	
	# First pass: find pairs of adjacent cultivated nodes
	for i in range(cultivated_cells.size()):
		var node1 = cultivated_cells[i]
		if not adjacency_cache.has(node1):
			continue
			
		for adj_node in adjacency_cache[node1]:
			if cultivated_cache.get(adj_node, false):
				# We found a pair of adjacent cultivated nodes
				var pair_key = node1 + ":" + adj_node if node1 < adj_node else adj_node + ":" + node1
				triangle_lookup[pair_key] = [node1, adj_node]
	
	# Second pass: find triangles by checking if any node is adjacent to both nodes in a pair
	for pair_key in triangle_lookup:
		var pair = triangle_lookup[pair_key]
		var node1 = pair[0]
		var node2 = pair[1]
		
		# Get the intersection of their adjacent nodes
		var common_adjacents = []
		for adj_node in adjacency_cache[node1]:
			if adj_node in adjacency_cache[node2] and cultivated_cache.get(adj_node, false):
				common_adjacents.append(adj_node)
		
		# Add triangles for any common adjacents — same team only
		for node3 in common_adjacents:
			var t1 = grid[node1].get("team_id", -1)
			var t2 = grid[node2].get("team_id", -1)
			var t3 = grid[node3].get("team_id", -1)
			if t1 != t2 or t2 != t3:
				continue
			var triangle = [node1, node2, node3]
			triangle.sort()
			triangles.append(triangle)

func _on_claim_pressed() -> void:
	current_action = CellState.CLAIMED

func _on_cultivate_pressed() -> void:
	current_action = CellState.CULTIVATED

func _on_collect_pressed() -> void:
	var player := _get_active_landed_player()
	if not player:
		return
	var tid: int = player.team_id
	var own_net: int = max(0, team_yield_counts.get(tid, 0) - int(team_tax_paid.get(tid, 0.0)))
	var tax_earned: int = int(team_tax_earned.get(tid, 0.0))
	var available: int = own_net + tax_earned
	if available <= 0:
		return
	var cl := get_tree().get_root().find_child("CollectLabel", true, false)
	if not cl:
		return
	if not cl.confirmed.is_connected(_on_collect_confirmed):
		cl.confirmed.connect(_on_collect_confirmed)
	cl.open(available)

func _on_collect_confirmed(food_amount: int, fuel_amount: int) -> void:
	var player := _get_active_landed_player()
	if not player:
		return
	var tid: int = player.team_id

	var own_net: int = max(0, team_yield_counts.get(tid, 0) - int(team_tax_paid.get(tid, 0.0)))
	var tax_earned: int = int(team_tax_earned.get(tid, 0.0))
	var total_available: int = own_net + tax_earned
	if total_available <= 0:
		return

	if fuel_amount > 0:
		player.current_fuel = min(player.max_fuel, player.current_fuel + float(fuel_amount))

	if food_amount > 0:
		var own_frac := float(own_net) / float(total_available)
		var food_own: int = int(float(food_amount) * own_frac)
		var food_tax: int = food_amount - food_own
		if food_own > 0:
			player.add_food_from_source(float(food_own), tid)
		if food_tax > 0:
			_distribute_tax_food(player, tid, float(food_tax))

	total_yield_collected += food_amount + fuel_amount

	# Clear only this team's data; other teams' crops stay on planet
	team_yield_counts.erase(tid)
	team_tax_paid.erase(tid)
	team_tax_earned.erase(tid)
	team_tax_earned_per_source.erase(tid)

	yield_count = 0
	for t in team_yield_counts:
		yield_count += team_yield_counts[t]

	moves_remaining -= 1
	emit_signal("moves_updated", moves_remaining)
	emit_signal("yield_updated", yield_count)
	emit_signal("team_yield_updated", tid, 0)
	emit_signal("tax_updated")
	update_stats()

func _distribute_tax_food(player: Node, dom_tid: int, amount: float) -> void:
	var per_source: Dictionary = team_tax_earned_per_source.get(dom_tid, {})
	var total_tax: float = team_tax_earned.get(dom_tid, 0.0)
	if per_source.is_empty() or total_tax <= 0.0:
		player.add_food_from_source(amount, dom_tid)
		return
	for source_team in per_source:
		var portion: float = amount * (float(per_source[source_team]) / total_tax)
		if portion > 0.0:
			player.add_food_from_source(portion, source_team)





# NOTICE Old code I'll use later NOTICE NOTICE
#func _on_collect_pressed() -> void:
	# Get the UI CanvasLayer from the scene tree
	#var canvas_layer = get_tree().get_root().get_node_or_null("Main/CanvasLayer")
	#if not canvas_layer:
		# Try to find the CanvasLayer with a different path if needed
		#canvas_layer = get_tree().get_root().find_node("CanvasLayer", true, false)
	
	# If we found the CanvasLayer, get the collect_label from there
	#if canvas_layer:
		#var collect_label = canvas_layer.get_node_or_null("collect_label")
		#if collect_label:
			# Make the collect label visible
			#collect_label.visible = true
			
			# Get the horizontal slider inside the collect_label
			#var horizontal_slider = collect_label.get_node_or_null("horizontal_slider")
			#if horizontal_slider:
				# Set the slider value based on current yield count
				#horizontal_slider.max_value = yield_count
				#horizontal_slider.value = yield_count
				
				# If there's a label to display the amount, update it
				#var amount_label = collect_label.get_node_or_null("amount_label")
				#if amount_label:
					#amount_label.text = str(yield_count)
#func _on_collect_confirm() -> void:
	# This would be connected to a confirmation button in the collect UI
	#var canvas_layer = get_tree().get_root().find_node("CanvasLayer", true, false)
	#if canvas_layer:
		#var collect_label = canvas_layer.get_node_or_null("collect_label")
		#if collect_label:
			# Get the slider value
			##if horizontal_slider:
				#var amount_to_collect = horizontal_slider.value
				
				# Do something with the collected amount (e.g., add to resources)
				# Example: add_resources(amount_to_collect)
				
				# Subtract the collected amount from the yield count
				#yield_count -= amount_to_collect
				#emit_signal("yield_updated", yield_count)
				
				# Hide the UI
				#collect_label.visible = false

func _generate_planet_name() -> String:
	var adj = ["penitent","silent","broken","amber","hollow","rusted",
		"verdant","ashen","gilded","sullen","crimson","frosted"]
	var noun = ["zebra","crane","jackal","lynx","ember","drifter",
		"herald","bastion","wraith","chorus","specter","anvil"]
	return adj[randi() % adj.size()] + "-" + noun[randi() % noun.size()]
