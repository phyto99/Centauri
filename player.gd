extends RigidBody2D

enum { IDLE, MOVING }

@export var zoom_speed: float = 0.1
@export var engine_power: float = 1000.0
@export var spin_power: float = 40000.0
@export var team_id: int = 0

var is_local: bool = true
var peer_id:  int  = 0

var _trail: CPUParticles2D

@export var max_fuel: float = 100.0
@export var fuel_depletion_rate: float = 10.0
@export var base_fuel_regen_rate: float = 2.0
@export var food_fuel_regen_boost: float = 5.0
@export var food_to_fuel_ratio: float = 0.5

@onready var camera        = $Camera2D
@onready var ship_sprite   = $ShipSprite
@onready var thrust_sprite = $ThrustSprite
@onready var fuel_bar      = $CanvasLayer/FuelBar

var thrust       := Vector2.ZERO
var rotation_dir: float = 0.0
var state        := IDLE
var current_fuel: float = 0.0
var food_amount:  float = 0.0
var total_food_delivered: int = 0
var food_by_source: Dictionary = {}  # source_team_id → float
var diversity_teams: Array = []       # foreign team_ids whose crops we've delivered

# Landing state
var landed_planet: Node = null
var landing_offset: Vector2 = Vector2.ZERO
var planet_rotation_at_landing: float = 0.0
var _pulsing:     bool = false
var _pulse_time:  float = 0.0

var team_colors := [
	Color(0, 1, 1),
	Color(1, 0, 1),
	Color(0, 1, 0),
	Color(1, 1, 0),
	Color(0, 0, 1),
	Color(1, 0, 0),
	Color(0, 0.5, 0),
]

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	thrust_sprite.visible = false
	_apply_game_config()
	current_fuel  = max_fuel
	gravity_scale = 0.0
	collision_layer = 1
	collision_mask  = 0   # ships pass through everything; Area2D handles planet detection
	z_index = 10          # render above planets
	set_team_color(team_id)
	add_to_group("players")
	_setup_land_detector()
	if not is_instance_valid(fuel_bar):
		_create_fuel_bar()
	fuel_bar.color = GameConfig.color_for(team_id)
	fuel_bar.visible = is_local
	GameConfig.settings_changed.connect(_on_settings_changed)
	_setup_trail()
	# UI color update for local player
	if is_local:
		_update_ui_color()
	# In multiplayer, keep camera off until game starts (free cam handles pre-game)
	var _multiplayer := OS.get_name() == "Web" and not ColyseusSync.room_id.is_empty()
	camera.enabled = is_local and not _multiplayer
	if is_local and _multiplayer:
		_pulsing = true
		GameConfig.game_started.connect(_on_game_started_player)

static func _make_soft_circle() -> ImageTexture:
	var sz := 64
	var img := Image.create(sz, sz, false, Image.FORMAT_RGBA8)
	var c   := sz * 0.5
	for y in range(sz):
		for x in range(sz):
			var d := Vector2(x + 0.5, y + 0.5).distance_to(Vector2(c, c)) / c
			var a := clampf((1.0 - d) * 0.75, 0.0, 1.0)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	return ImageTexture.create_from_image(img)

func _setup_trail() -> void:
	_trail = CPUParticles2D.new()
	_trail.texture               = _make_soft_circle()
	_trail.z_index               = -1
	_trail.emitting              = false
	_trail.amount                = 120
	_trail.lifetime              = 0.675
	_trail.explosiveness         = 0.0
	_trail.randomness            = 0.0
	_trail.emission_shape        = CPUParticles2D.EMISSION_SHAPE_POINT
	_trail.direction             = Vector2(-1.0, 0.0)
	_trail.spread                = 0.0
	_trail.initial_velocity_min  = 22.0
	_trail.initial_velocity_max  = 22.0
	_trail.gravity               = Vector2.ZERO
	_trail.scale_amount_min      = 1.6
	_trail.scale_amount_max      = 1.6
	_trail.color                 = GameConfig.color_for(team_id)
	var grad := Gradient.new()
	grad.set_color(0, Color(1.0, 1.0, 1.0, 1.0))
	grad.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	_trail.color_ramp            = grad
	add_child(_trail)

func _update_trail_color() -> void:
	if not is_instance_valid(_trail):
		return
	_trail.color = GameConfig.color_for(team_id)

func _apply_game_config() -> void:
	engine_power        = GameConfig.thrust_power
	fuel_depletion_rate = GameConfig.thrust_depletion
	base_fuel_regen_rate = GameConfig.fuel_recovery
	food_to_fuel_ratio  = GameConfig.fuel_efficiency

func _on_settings_changed() -> void:
	_apply_game_config()
	set_team_color(team_id)
	if is_instance_valid(fuel_bar):
		fuel_bar.color = GameConfig.color_for(team_id)
	_update_trail_color()

signal food_delivered(team_id: int, amount: int)
signal food_inventory_changed(team_id: int)

func _setup_land_detector() -> void:
	var area := Area2D.new()
	area.collision_layer = 0
	area.collision_mask  = 2   # detect planet bodies (layer 2)
	var poly := CollisionPolygon2D.new()
	poly.polygon = $CollisionPolygon2D.polygon
	area.add_child(poly)
	add_child(area)
	area.body_entered.connect(_on_planet_contact)

func _on_planet_contact(body: Node) -> void:
	if not body.is_in_group("planets"):
		return
	if not GameConfig.game_running:
		return
	if landed_planet != null:
		return
	if Input.is_action_pressed("thrust"):
		return
	# Refuel and deliver food when touching the sun
	if body.is_in_group("sun_planet"):
		current_fuel = max_fuel
		update_fuel_bar()
		if food_amount > 0.0:
			var delivered := roundi(food_amount)
			for source in food_by_source:
				if source != team_id and food_by_source[source] > 0.0:
					if not diversity_teams.has(source):
						diversity_teams.append(source)
			food_by_source.clear()
			food_amount = 0.0
			total_food_delivered += delivered
			emit_signal("food_delivered", team_id, delivered)
			emit_signal("food_inventory_changed", team_id)
	landed_planet = body
	landing_offset = global_position - body.global_position
	planet_rotation_at_landing = body.rotation
	_notify_camera_manager()

func _detach() -> void:
	if landed_planet == null:
		return
	var rot_delta: float = landed_planet.rotation - planet_rotation_at_landing
	var r: float = landing_offset.length()
	var current_angle: float = landing_offset.angle() + rot_delta
	var tangential: Vector2 = Vector2.from_angle(current_angle + PI / 2.0) * landed_planet.angular_velocity * r
	linear_velocity = landed_planet.linear_velocity + tangential
	if landed_planet.has_method("set_player_landed"):
		landed_planet.set_player_landed(false)
	landed_planet = null
	_notify_camera_manager()

func set_team_color(id: int) -> void:
	var mat = ship_sprite.material
	if mat:
		mat = mat.duplicate()
		ship_sprite.material = mat
		mat.set_shader_parameter("team_color", GameConfig.color_for(id))

func change_state(new_state: int) -> void:
	if state == new_state:
		return
	state = new_state
	thrust_sprite.visible = (state == MOVING)

func _on_game_started_player(_cfg: Dictionary) -> void:
	_pulsing = false
	ship_sprite.modulate.a = 1.0
	if is_instance_valid(_trail):
		_trail.modulate.a = 1.0
	camera.enabled = true

func get_input() -> void:
	thrust = Vector2.ZERO
	rotation_dir = 0.0
	if not GameConfig.game_running:
		change_state(IDLE)
		return
	rotation_dir = Input.get_axis("rotate_left", "rotate_right")

	if Input.is_action_pressed("thrust") and has_fuel():
		if landed_planet != null:
			_detach()
		thrust = transform.x * engine_power
		change_state(MOVING)
	else:
		change_state(IDLE)

func has_fuel() -> bool:
	return current_fuel > 0.0

func update_fuel(delta: float) -> void:
	if thrust.length() > 0.0:
		current_fuel = max(0.0, current_fuel - fuel_depletion_rate * delta)
	else:
		current_fuel = min(max_fuel, current_fuel + base_fuel_regen_rate * delta)
	update_fuel_bar()

func update_fuel_bar() -> void:
	if is_instance_valid(fuel_bar):
		fuel_bar.size.x = 366.0 * (current_fuel / max_fuel)

func set_fuel_bar_color(color: Color) -> void:
	if is_instance_valid(fuel_bar):
		fuel_bar.color = color

func add_food_from_source(amount: float, source_team: int) -> void:
	if amount <= 0.0:
		return
	food_by_source[source_team] = food_by_source.get(source_team, 0.0) + amount
	food_amount += amount
	emit_signal("food_inventory_changed", team_id)

func _notify_camera_manager() -> void:
	var cm := get_tree().get_first_node_in_group("camera_manager")
	if cm and cm.has_method("_refresh_planet_sprites"):
		cm._refresh_planet_sprites()

func launch() -> void:
	landed_planet = null
	_notify_camera_manager()

func collect_food(amount: float) -> void:
	add_food_from_source(amount, team_id)

func set_thrusting(v: bool) -> void:
	change_state(MOVING if v else IDLE)

func is_thrusting() -> bool:
	return state == MOVING

func _update_ui_color() -> void:
	var ui := get_tree().get_first_node_in_group("ui_controller")
	if ui and ui.has_method("set_team_color"):
		ui.set_team_color(GameConfig.color_for(team_id))

func set_team(id: int) -> void:
	team_id = id
	set_team_color(id)
	if is_instance_valid(fuel_bar):
		fuel_bar.color = GameConfig.color_for(id)
	if is_local:
		_update_ui_color()

func _process(delta: float) -> void:
	if is_local:
		get_input()
	if _pulsing:
		_pulse_time += delta
		var a := 0.4 + 0.6 * (0.5 + 0.5 * sin(_pulse_time * TAU * 0.7))
		ship_sprite.modulate.a = a
		if is_instance_valid(_trail):
			_trail.modulate.a = a
	update_fuel(delta)

func _physics_process(_delta: float) -> void:
	if is_instance_valid(_trail):
		_trail.emitting = (state == MOVING)
	if not is_local:
		constant_force  = Vector2.ZERO
		constant_torque = 0.0
		return
	# Auto-release from any planet while game isn't running (pre-game / countdown)
	if not GameConfig.game_running and landed_planet != null:
		landed_planet = null
		_notify_camera_manager()
	if landed_planet != null and is_instance_valid(landed_planet):
		var rot_delta: float = landed_planet.rotation - planet_rotation_at_landing
		global_position = landed_planet.global_position + landing_offset.rotated(rot_delta)
		linear_velocity  = landed_planet.linear_velocity
		constant_force   = Vector2.ZERO
		constant_torque  = rotation_dir * spin_power
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
