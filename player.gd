extends RigidBody2D

enum {IDLE, MOVING, STUNNED, ATTACHED}

@export var zoom_speed: float = 0.1
@export var engine_power: float = 1000
@export var spin_power: float = 40000
@export var orbital_speed: float = 1.5  # rad/s when moving along surface
@export var team_id: int = 0

@export var max_fuel: float = 100.0
@export var fuel_depletion_rate: float = 10.0
@export var base_fuel_regen_rate: float = 2.0
@export var food_fuel_regen_boost: float = 5.0
@export var food_to_fuel_ratio: float = 0.5

@onready var camera = $Camera2D
@onready var ship_sprite = $ShipSprite
@onready var thrust_sprite = $ThrustSprite
@onready var fuel_bar = $CanvasLayer/FuelBar

var thrust := Vector2.ZERO
var rotation_dir := 0
var state := IDLE
var attached_planet: Node = null
var surface_normal := Vector2.ZERO
var current_fuel: float = 0.0
var food_amount: float = 0.0

var team_colors = [
	Color(0, 1, 1, 1),
	Color(1, 0, 1, 1),
	Color(0, 1, 0, 1),
	Color(1, 1, 0, 1),
	Color(0, 0, 1, 1),
	Color(1, 0, 0, 1),
	Color(0, 0.5, 0, 1),
]

func _ready():
	thrust_sprite.visible = false
	current_fuel = max_fuel
	gravity_scale = 0.0         # ships float freely in space
	collision_layer = 1         # ships are on layer 1
	collision_mask = 1          # ships only collide with other ships / food
	set_team_color(team_id)
	add_to_group("players")
	if not is_instance_valid(fuel_bar):
		_create_fuel_bar()

func set_team_color(id):
	var material = ship_sprite.material
	if material:
		material = material.duplicate()
		ship_sprite.material = material
		material.set_shader_parameter("team_color", team_colors[id % team_colors.size()])

func land_on_planet(planet: Node) -> void:
	if state == ATTACHED:
		return
	attached_planet = planet
	surface_normal = (global_position - planet.global_position).normalized()
	if surface_normal == Vector2.ZERO:
		surface_normal = Vector2.UP
	global_position = planet.global_position + surface_normal * planet.surface_radius
	global_rotation = surface_normal.angle() + PI / 2
	linear_velocity = planet.linear_velocity
	change_state(ATTACHED)

func detach_from_planet() -> void:
	var planet_vel = attached_planet.linear_velocity if attached_planet else Vector2.ZERO
	attached_planet = null
	surface_normal = Vector2.ZERO
	linear_velocity = planet_vel
	change_state(MOVING)

func change_state(new_state):
	if state == new_state:
		return
	match new_state:
		IDLE:
			thrust_sprite.visible = false
		MOVING:
			thrust_sprite.visible = true
		STUNNED:
			thrust_sprite.visible = false
		ATTACHED:
			thrust_sprite.visible = false
	state = new_state

func _unhandled_input(event):
	if event is InputEventMouseButton:
		if event.pressed:
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				camera.zoom *= (1 + zoom_speed)
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				camera.zoom *= (1 - zoom_speed)

func get_input(delta: float):
	thrust = Vector2.ZERO
	rotation_dir = 0

	if state == ATTACHED and attached_planet:
		# Orbital movement: left/right slides along planet surface
		var orbit = Input.get_axis("move_left", "move_right")
		if orbit != 0.0:
			var angle = surface_normal.angle() + orbit * orbital_speed * delta
			surface_normal = Vector2.from_angle(angle)

		# Rotate ship sprite independently
		rotation_dir = Input.get_axis("rotate_left", "rotate_right")

		# Launch
		if Input.is_action_pressed("thrust") and has_fuel():
			detach_from_planet()
			thrust = transform.x * engine_power
			return

		# No constant force while attached
		return

	if Input.is_action_pressed("thrust") and has_fuel():
		thrust = transform.x * engine_power
		change_state(MOVING)
	else:
		change_state(IDLE)
	rotation_dir = Input.get_axis("rotate_left", "rotate_right")

func has_fuel() -> bool:
	return current_fuel > 0

func update_fuel(delta):
	if thrust.length() > 0:
		current_fuel -= fuel_depletion_rate * delta
		current_fuel = max(0, current_fuel)
	else:
		var regen = base_fuel_regen_rate * delta
		if food_amount > 0:
			var food_used = min(food_amount, delta)
			food_amount -= food_used
			regen += food_used * food_to_fuel_ratio * food_fuel_regen_boost
		current_fuel = min(current_fuel + regen, max_fuel)
	update_fuel_bar()

func update_fuel_bar():
	if is_instance_valid(fuel_bar):
		fuel_bar.size.x = 366 * (current_fuel / max_fuel)
		fuel_bar.color = Color(0, 1, 1, 1)

func collect_food(amount):
	food_amount += amount

func _process(delta):
	get_input(delta)
	update_fuel(delta)

func _physics_process(delta):
	if state == ATTACHED and attached_planet:
		# Keep ship locked to planet surface
		global_position = attached_planet.global_position + surface_normal * attached_planet.surface_radius
		linear_velocity = attached_planet.linear_velocity
		global_rotation = surface_normal.angle() + PI / 2
		constant_force = Vector2.ZERO
		constant_torque = 0.0
		return

	constant_force = thrust
	constant_torque = rotation_dir * spin_power

func _on_body_entered(body):
	if body.is_in_group("food"):
		collect_food(body.food_value if "food_value" in body else 10.0)
		body.queue_free()

func _create_fuel_bar():
	var cl = CanvasLayer.new()
	cl.name = "CanvasLayer"
	add_child(cl)
	var bar = ColorRect.new()
	bar.name = "FuelBar"
	bar.color = Color(0, 1, 1, 1)
	bar.size = Vector2(366, 14)
	bar.position = Vector2(0, get_viewport_rect().size.y - 14)
	cl.add_child(bar)
	fuel_bar = bar
