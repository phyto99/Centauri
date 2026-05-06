extends Node2D

@export var grid_size: int = 5
@export var cell_size: float = 64.0
@export var sprite_scene: PackedScene
@export var stamp_scene: PackedScene

var grid: Dictionary = {}
var center_position: Vector2

func _ready():
	center_position = get_viewport_rect().size / 2
	generate_grid()

func generate_grid():
	# Clear existing grid
	for cell in grid.values():
		cell.queue_free()
	grid.clear()
	
	# Calculate dimensions for roughly circular shape
	for q in range(-grid_size, grid_size + 1):
		for r in range(-grid_size, grid_size + 1):
			# Axial coordinates
			var s = -q - r
			
			# Check if within circular boundary
			if abs(q) + abs(r) + abs(s) <= 2 * grid_size:
				create_cell(q, r)

func create_cell(q: int, r: int):
	# Convert axial coordinates to pixel position
	var x = cell_size * (sqrt(3.0) * q + sqrt(3.0)/2.0 * r)
	var y = cell_size * (3.0/2.0 * r)
	
	var cell = sprite_scene.instantiate()
	add_child(cell)
	cell.position = center_position + Vector2(x, y)
	
	# Store in grid dictionary
	var key = str(q) + "," + str(r)
	grid[key] = cell

func stamp_at_position(global_pos: Vector2):
	var local_pos = global_pos - center_position
	
	# Convert pixel coordinates to axial coordinates
	var q = (sqrt(3.0)/3.0 * local_pos.x - 1.0/3.0 * local_pos.y) / cell_size
	var r = (2.0/3.0 * local_pos.y) / cell_size
	
	# Round to nearest hex cell
	var rounded = round_axial(q, r)
	var key = str(rounded.x) + "," + str(rounded.y)
	
	if grid.has(key):
		var stamp = stamp_scene.instantiate()
		add_child(stamp)
		stamp.global_position = grid[key].global_position

func round_axial(q: float, r: float) -> Vector2:
	var s = -q - r
	
	var q_round = round(q)
	var r_round = round(r)
	var s_round = round(s)
	
	var q_diff = abs(q_round - q)
	var r_diff = abs(r_round - r)
	var s_diff = abs(s_round - s)
	
	if q_diff > r_diff and q_diff > s_diff:
		q_round = -r_round - s_round
	elif r_diff > s_diff:
		r_round = -q_round - s_round
	
	return Vector2(q_round, r_round)
