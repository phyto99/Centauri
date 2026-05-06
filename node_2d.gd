extends Node2D

@export var max_grid_size: int = 5
@export var current_size: int = 0  # Controlled by the slider
@export var cell_size: float = 70.0
@export var sprite_scene: PackedScene
@export var stamp_scene: PackedScene

var grid: Dictionary = {}
var center_position: Vector2
var rotation_angle: float = deg_to_rad(30)
var hex_order: Array = []  # Stores hexagons in order for circular growth

func _ready():
	center_position = get_viewport_rect().size / 2
	calculate_hex_order()
	generate_grid()
	queue_redraw()

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
				var x = cell_size * (3.0/2.0 * q)
				var y = cell_size * (sqrt(3.0)/2.0 * q + sqrt(3.0) * r)
				
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
		{"q": 1, "r": 0, "s": -1, "distance": cell_size * 1.5},
		{"q": 0, "r": 1, "s": -1, "distance": cell_size * sqrt(3.0) / 2},
		{"q": -1, "r": 1, "s": 0, "distance": cell_size * sqrt(3.0) / 2},
		{"q": -1, "r": 0, "s": 1, "distance": cell_size * 1.5},
		{"q": 0, "r": -1, "s": 1, "distance": cell_size * sqrt(3.0) / 2},
		{"q": 1, "r": -1, "s": 0, "distance": cell_size * sqrt(3.0) / 2}
	]
	
	# Replace the first 7 coordinates with the manually ordered ones
	for i in range(7):
		coords[i] = first_seven[i]
	
	hex_order = coords

func generate_grid():
	# Clear existing grid
	for cell_data in grid.values():
		cell_data["cell"].queue_free()
	grid.clear()
	
	# Add hexagons up to current_size
	var cells_to_add = min(current_size, hex_order.size())
	for i in range(cells_to_add):
		var coord = hex_order[i]
		create_cell(coord.q, coord.r)
	
	queue_redraw()

func create_cell(q: int, r: int):
	# Pointy-top orientation conversion from axial to pixel coordinates
	var x = cell_size * (sqrt(3.0) * q + sqrt(3.0)/2.0 * r)
	var y = cell_size * (3.0/2.0 * r)
	
	# Apply rotation transformation
	var rotated_pos = rotate_vector(Vector2(x, y), rotation_angle)
	
	var cell = sprite_scene.instantiate()
	add_child(cell)
	cell.position = center_position + rotated_pos
	
	var key = str(q) + "," + str(r)
	grid[key] = {
		"cell": cell,
		"q": q,
		"r": r,
		"pos": center_position + rotated_pos
	}

func _on_slider_value_changed(value: float):
	var new_size = int(value)
	if new_size != current_size:
		current_size = new_size
		generate_grid()

func rotate_vector(v: Vector2, angle: float) -> Vector2:
	var cos_theta = cos(angle)
	var sin_theta = sin(angle)
	return Vector2(
		v.x * cos_theta - v.y * sin_theta,
		v.x * sin_theta + v.y * cos_theta
	)

func _draw():
	for key in grid.keys():
		var data = grid[key]
		var text_pos = data["pos"]
		var font = ThemeDB.fallback_font
		draw_string(font, text_pos, key, HORIZONTAL_ALIGNMENT_CENTER, -1, 16, Color(1,1,1))
