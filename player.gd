extends RigidBody2D

enum { IDLE, MOVING }

@export var zoom_speed: float = 0.1
@export var engine_power: float = 1000.0
@export var spin_power: float = 40000.0
@export var team_id: int = 0

@export var max_fuel: float = 100.0
@export var fuel_depletion_rate: float = 10.0
@export var base_fuel_regen_rate: float = 2.0
@export var food_fuel_regen_boost: float = 5.0
@export var food_to_fuel_ratio: float = 0.5

@onready var camera        = $Camera2D
@onready var ship_sprite   = $ShipSprite
@onready var thrust_sprite = $ThrustSprite
@onready var fuel_bar      = $CanvasLayer/FuelBar

var thrust        := Vector2.ZERO
var rotation_dir  := 0
var state         := IDLE
var current_fuel  : float = 0.0
var food_amount   : float = 0.0

# Landing state
var landed_planet             : Node    = null
var landing_offset            : Vector2 = Vector2.ZERO
var planet_rotation_at_landing: float   = 0.0

var team_colors := [
	Color(0, 1, 1),   Color(1, 0, 1),   Color(0, 1, 0),
	Color(1, 1, 0),   Color(0, 0, 1),   Color(1, 0, 0),
	Color(0, 0.5, 0),
]

func _ready() -> void:
	thrust_sprite.visible = false
	current_fuel  = max_fuel
	gravity_scale = 0.0
	collision_layer = 1
	collision_mask  = 3
	set_team_color(team_id)
	add_to_group("players")
	_setup_landing_area()
	if not is_instance_valid(fuel_bar):
		_create_fuel_bar()

func _setup_landing_area() -> void:
	var area  := Area2D.new()
	area.collision_layer = 0
	area.collision_mask  = 2
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 28.0
	shape.shape = circle
	area.add_child(shape)
	add_child(area)
	area.body_entered.connect(_on_landing_area_entered)
	area.body_exited.connect(_on_landing_area_exited)

func _on_landing_area_entered(body: Node) -> void:
	if body.is_in_group("planets") and landed_planet == null:
		_land_on(body)

func _on_landing_area_exited(body: Node) -> void:
	if body == landed_planet:
		landed_planet = null

func _land_on(planet: Node) -> void:
	landed_planet              = planet
	landing_offset             = global_position - planet.global_position
	planet_rotation_at_landing = planet.rotation

func _detach() -> void:
	if landed_planet == null:
		return
	var spin_vel: Vector2 = Vector2.from_angle(landing_offset.angle() + PI / 2.0) \
		* landed_planet.angular_velocity * landing_offset.length()
	linear_velocity = landed_planet.linear_velocity + spin_vel
	landed_planet = null

func set_team_color(id: int) -> void:
	var mat = ship_sprite.material
	if mat:
		mat = mat.duplicate()
		ship_sprite.material = mat
		mat.set_shader_parameter("team_color", team_colors[id % team_colors.size()])

func change_state(new_state: int) -> void:
	if state == new_state:
		return
	state = new_state
	thrust_sprite.visible = (state == MOVING)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			camera.zoom *= 1.0 + zoom_speed
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			camera.zoom *= 1.0 - zoom_speed

func get_input() -> void:
	thrust       = Vector2.ZERO
	rotation_dir = Input.get_axis("rotate_left", "rotate_right")

	if Input.is_action_pressed("thrust") and has_fuel():
		if landed_planet != null:
			_detach()
		thrust = transform.x * engine_power
		change_state(MOVING)
		set_collision_mask_value(2, false)
	else:
		change_state(IDLE)
		set_collision_mask_value(2, true)

func has_fuel() -> bool:
	return current_fuel > 0.0

func update_fuel(delta: float) -> void:
	if thrust.length() > 0.0:
		current_fuel = max(0.0, current_fuel - fuel_depletion_rate * delta)
	else:
		var regen := base_fuel_regen_rate * delta
		if food_amount > 0.0:
			var used: float = min(food_amount, delta)
			food_amount -= used
			regen += used * food_to_fuel_ratio * food_fuel_regen_boost
		current_fuel = min(max_fuel, current_fuel + regen)
	update_fuel_bar()

func update_fuel_bar() -> void:
	if is_instance_valid(fuel_bar):
		fuel_bar.size.x = 366.0 * (current_fuel / max_fuel)
		fuel_bar.color  = Color(0, 1, 1)

func collect_food(amount: float) -> void:
	food_amount += amount

func _process(delta: float) -> void:
	get_input()
	update_fuel(delta)

func _physics_process(_delta: float) -> void:
	if landed_planet != null and is_instance_valid(landed_planet):
		var delta_rot: float = landed_planet.rotation - planet_rotation_at_landing
		global_position = landed_planet.global_position + landing_offset.rotated(delta_rot)
		linear_velocity = Vector2.ZERO
		constant_force  = Vector2.ZERO
		constant_torque = rotation_dir * spin_power
		return

	constant_force  = thrust
	constant_torque = rotation_dir * spin_power

func _on_body_entered(body: Node) -> void:
	if body.is_in_group("food"):
		collect_food(body.get("food_value") if body.get("food_value") != null else 10.0)
		body.queue_free()

func _create_fuel_bar() -> void:
	var cl  := CanvasLayer.new()
	cl.name  = "CanvasLayer"
	add_child(cl)
	var bar := ColorRect.new()
	bar.name     = "FuelBar"
	bar.color    = Color(0, 1, 1)
	bar.size     = Vector2(366, 14)
	bar.position = Vector2(0, get_viewport_rect().size.y - 14)
	cl.add_child(bar)
	fuel_bar = bar
