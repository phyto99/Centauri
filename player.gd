extends RigidBody2D

enum {IDLE, MOVING, STUNNED, ATTACHED}

@export var zoom_speed: float = 0.1
@export var engine_power: float = 1000
@export var spin_power: float = 40000
@export var surface_movement_speed: float = 500
@export var planet_gravity_multiplier: float = 1000.0
@export var team_id: int = 0

# Fuel system variables
@export var max_fuel: float = 100.0
@export var fuel_depletion_rate: float = 10.0  # How quickly fuel depletes when thrusting (units per second)
@export var base_fuel_regen_rate: float = 2.0  # Base regeneration rate without food (units per second)
@export var food_fuel_regen_boost: float = 5.0  # Additional regeneration from food (units per second)
@export var food_to_fuel_ratio: float = 0.5  # How efficiently food converts to fuel (1.0 = 100% efficient)

@onready var camera = $Camera2D
@onready var ship_sprite = $ShipSprite
@onready var thrust_sprite = $ThrustSprite
@onready var fuel_bar = $CanvasLayer/FuelBar  # Reference to the fuel indicator UI

var thrust = Vector2.ZERO
var rotation_dir = 0
var state = IDLE
var attached_planet = null
var surface_normal = Vector2.ZERO
var original_gravity_scale = 1.0
var current_fuel: float = 0.0
var food_amount: float = 0.0  # Food storage for conversion to fuel

var team_colors = [
	Color(0, 1, 1, 1),  # Cyan
	Color(1, 0, 1, 1),  # Magenta
	Color(0, 1, 0, 1),  # Lime
	Color(1, 1, 0, 1),  # Lime
	Color(0, 0, 1, 1),  # Lime
	Color(1, 0, 0, 1),  # Lime
	Color(0, 0.5, 0, 1)  # Lime
]

func _ready():
	thrust_sprite.visible = false
	original_gravity_scale = gravity_scale
	current_fuel = max_fuel  # Start with full fuel
	
	# Set team color based on team_id
	set_team_color(team_id)
	add_to_group("players")
	
	# Create fuel bar UI if it doesn't exist
	if !is_instance_valid(fuel_bar):
		var canvas_layer = CanvasLayer.new()
		canvas_layer.name = "CanvasLayer"
		add_child(canvas_layer)
		
		var fuel_bar_rect = ColorRect.new()
		fuel_bar_rect.name = "FuelBar"
		fuel_bar_rect.color = Color(0, 0.8, 0, 1)  # Green fuel bar
		fuel_bar_rect.size = Vector2(366, 14)
		fuel_bar_rect.position = Vector2(0, get_viewport_rect().size.y - 14)
		canvas_layer.add_child(fuel_bar_rect)
		
		fuel_bar = fuel_bar_rect
		
		print("Fuel bar created")

func set_team_color(id):
	var material = ship_sprite.material
	if material:
		# Create a unique material instance for each ship
		material = material.duplicate()
		ship_sprite.material = material
		
		# Use modulo to handle cases where team_id is greater than the number of colors
		var color_index = id % team_colors.size()
		material.set_shader_parameter("team_color", team_colors[color_index])

func change_state(new_state):
	if state == new_state:
		return
	match new_state:
		IDLE:
			$CollisionPolygon2D.set_deferred("disabled", false)
			thrust_sprite.visible = false
		MOVING:
			$CollisionPolygon2D.set_deferred("disabled", false)
			thrust_sprite.visible = true
		STUNNED:
			$CollisionPolygon2D.set_deferred("disabled", false)
			thrust_sprite.visible = false
		ATTACHED:
			# Keep collision enabled when attached to planet surface
			$CollisionPolygon2D.set_deferred("disabled", false)
			thrust_sprite.visible = false
	state = new_state

func _unhandled_input(event):
	if event is InputEventMouseButton:
		if event.pressed:
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				camera.zoom *= (1 + zoom_speed)
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				camera.zoom *= (1 - zoom_speed)

func get_input():
	thrust = Vector2.ZERO
	rotation_dir = 0
	
	# If attached to a planet
	if state == ATTACHED and attached_planet:
		# Allow rotation on the planet surface
		rotation_dir = Input.get_axis("rotate_left", "rotate_right")
		
		# Surface movement perpendicular to surface normal
		var surface_movement = Vector2.ZERO
		if Input.is_action_pressed("move_left"):
			surface_movement = -surface_normal.rotated(PI/2) * surface_movement_speed
		elif Input.is_action_pressed("move_right"):
			surface_movement = surface_normal.rotated(PI/2) * surface_movement_speed
		
		# When thrusting while attached to planet, disable planet collision
		if Input.is_action_pressed("thrust") and has_fuel():
			# Disable the planet's collision shape
			if attached_planet.has_method("disable_collision"):
				attached_planet.disable_collision()
			else:
				# Fallback if the planet doesn't have the method
				var collision_shapes = attached_planet.get_children()
				for shape in collision_shapes:
					if shape is CollisionShape2D or shape is CollisionPolygon2D:
						shape.set_deferred("disabled", true)
			
			# Start thrusting to pass through the planet
			thrust = transform.x * engine_power
			change_state(MOVING)
			return
		
		# Apply surface movement
		linear_velocity = surface_movement
		return
	
	# Regular ship controls when not attached
	if Input.is_action_pressed("thrust") and has_fuel():
		thrust = transform.x * engine_power
		change_state(MOVING)
	else:
		change_state(IDLE)
	
	rotation_dir = Input.get_axis("rotate_left", "rotate_right")

func has_fuel() -> bool:
	return current_fuel > 0

func update_fuel(delta):
	# Deplete fuel when thrusting
	if thrust.length() > 0:
		current_fuel -= fuel_depletion_rate * delta
		current_fuel = max(0, current_fuel)  # Ensure fuel doesn't go negative
	else:
		# Always regenerate fuel at base rate when not thrusting
		var regen_amount = base_fuel_regen_rate * delta
		
		# Add boost from food if available
		if food_amount > 0:
			# Calculate how much food to use this frame
			var food_used = min(food_amount, delta)
			food_amount -= food_used
			
			# Add boosted regeneration from food
			regen_amount += food_used * food_to_fuel_ratio * food_fuel_regen_boost
			
			# Debug output
			# print("Food used: ", food_used, " Food left: ", food_amount)
		
		# Apply regeneration
		current_fuel += regen_amount
		current_fuel = min(current_fuel, max_fuel)  # Cap at maximum
		
		# Debug output for regeneration
		# print("Regenerated: ", regen_amount, " Current fuel: ", current_fuel)
	
	# Update fuel bar visual
	update_fuel_bar()

func update_fuel_bar():
	if is_instance_valid(fuel_bar):
		var fuel_percent = current_fuel / max_fuel
		fuel_bar.size.x = 366 * fuel_percent  # Base width is 200
		fuel_bar.color = Color(0, 1, 1, 1) 
	else:
		# If fuel bar somehow got deleted, recreate it
		print("Fuel bar not found, recreating")
		_ready()

func collect_food(amount):
	food_amount += amount
	print("Food collected: ", amount, " Total: ", food_amount)

func _process(delta):
	get_input()
	update_fuel(delta)

func _physics_process(_delta):
	if state == ATTACHED and attached_planet:
		# Align ship to planet surface
		global_rotation = surface_normal.angle() + PI/2
	
	constant_force = thrust
	constant_torque = rotation_dir * spin_power

func attach_to_planet(planet):
	# Store reference to the planet
	attached_planet = planet
	
	# Calculate surface normal pointing away from planet center
	surface_normal = (global_position - planet.global_position).normalized()
	
	# Change to attached state
	change_state(ATTACHED)
	
	# Increase gravity scale by multiplier
	gravity_scale = original_gravity_scale * planet_gravity_multiplier
	
	# Align ship to planet surface
	global_rotation = surface_normal.angle() + PI/2

func detach_from_planet():
	# Reset gravity scale
	gravity_scale = original_gravity_scale
	# Reset to moving state
	change_state(MOVING)
	# Re-enable planet collision if it was disabled
	if attached_planet:
		if attached_planet.has_method("enable_collision"):
			attached_planet.enable_collision()
		else:
			# Fallback if the planet doesn't have the method
			var collision_shapes = attached_planet.get_children()
			for shape in collision_shapes:
				if shape is CollisionShape2D or shape is CollisionPolygon2D:
					shape.set_deferred("disabled", false)
	# Clear planet references
	attached_planet = null
	surface_normal = Vector2.ZERO

func _on_body_entered(body):
	if body.is_in_group("planets") and state != ATTACHED:
		attach_to_planet(body)
		
	# Food collection
	if body.is_in_group("food"):
		collect_food(body.food_value if "food_value" in body else 10.0)  # Default to 10 if no food_value
		body.queue_free()  # Remove the food object
