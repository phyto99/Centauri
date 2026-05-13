extends RigidBody2D

enum { IDLE, MOVING }

@export var zoom_speed: float = 0.1
@export var engine_power: float = 1000.0
@export var spin_power: float = 40000.0
@export var team_id: int = 0

var is_local: bool = true
var peer_id:  int  = 0
var player_name: String = ""

var _trail:           CPUParticles2D
var _hud_cl:          CanvasLayer
var _hud_bg:          ColorRect
var _name_input:      LineEdit
var _cultivate_icon:  TextureRect
var _crops_hud_label: Label

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
	if is_local:
		if not is_instance_valid(fuel_bar):
			_create_fuel_bar()
		fuel_bar.color = GameConfig.color_for(team_id)
	elif is_instance_valid(fuel_bar):
		fuel_bar.get_parent().visible = false
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

static func _make_soft_circle() -> GradientTexture2D:
	var grad := Gradient.new()
	grad.set_color(0, Color(1.0, 1.0, 1.0, 0.75))
	grad.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 64
	tex.height = 64
	return tex

func _setup_trail() -> void:
	_trail = CPUParticles2D.new()
	_trail.texture               = _make_soft_circle()
	_trail.z_index               = -1
	_trail.emitting              = false
	_trail.amount                = 300
	_trail.lifetime              = 2.0
	_trail.explosiveness         = 0.0
	_trail.randomness            = 0.0
	_trail.local_coords          = false
	_trail.emission_shape        = CPUParticles2D.EMISSION_SHAPE_POINT
	_trail.direction             = Vector2.ZERO
	_trail.spread                = 0.0
	_trail.initial_velocity_min  = 0.0
	_trail.initial_velocity_max  = 0.0
	_trail.gravity               = Vector2.ZERO
	_trail.scale_amount_min      = 1.5
	_trail.scale_amount_max      = 1.5
	_trail.color                 = GameConfig.color_for(team_id)
	# Fade in for first 20% of lifetime (25 frames), fade out for remaining 80% (100 frames)
	var grad := Gradient.new()
	grad.interpolation_mode = Gradient.GRADIENT_INTERPOLATE_LINEAR
	grad.set_color(0, Color(1.0, 1.0, 1.0, 0.5))
	grad.add_point(0.2, Color(1.0, 1.0, 1.0, 1.0))
	grad.set_color(grad.get_point_count() - 1, Color(1.0, 1.0, 1.0, 0.0))
	_trail.color_ramp            = grad
	# Scale mirrors alpha: grows slightly during fade-in, shrinks to 0 during fade-out
	var scale_curve := Curve.new()
	scale_curve.add_point(Vector2(0.0,  1.0),  0.0, 0.0, Curve.TANGENT_LINEAR, Curve.TANGENT_LINEAR)
	scale_curve.add_point(Vector2(0.2,  1.167), 0.0, 0.0, Curve.TANGENT_LINEAR, Curve.TANGENT_LINEAR)
	scale_curve.add_point(Vector2(1.0,  0.0),  0.0, 0.0, Curve.TANGENT_LINEAR, Curve.TANGENT_LINEAR)
	_trail.scale_amount_curve    = scale_curve
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
	var col := GameConfig.color_for(team_id)
	if is_instance_valid(fuel_bar):
		fuel_bar.color = col
	_update_trail_color()
	_update_hud_colors(col)

func _update_hud_colors(col: Color) -> void:
	if is_instance_valid(_name_input):
		_name_input.add_theme_color_override("font_color",             col)
		_name_input.add_theme_color_override("font_placeholder_color", col)
		_name_input.add_theme_color_override("caret_color",            col)
		var _sbox := StyleBoxEmpty.new()
		_name_input.add_theme_stylebox_override("normal",    _sbox)
		_name_input.add_theme_stylebox_override("focus",     _sbox)
		_name_input.add_theme_stylebox_override("hover",     _sbox)
		_name_input.add_theme_stylebox_override("read_only", _sbox)
	if is_instance_valid(_cultivate_icon):
		_cultivate_icon.modulate = col
	if is_instance_valid(_crops_hud_label):
		_crops_hud_label.add_theme_color_override("font_color", col)

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
	if is_instance_valid(_name_input):
		_name_input.release_focus()
		_name_input.focus_mode = Control.FOCUS_NONE

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
	if is_instance_valid(_crops_hud_label):
		_crops_hud_label.text = "x %d" % int(food_amount)

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
	var col := GameConfig.color_for(id)
	if is_instance_valid(fuel_bar):
		fuel_bar.color = col
	_update_hud_colors(col)
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

const _HUD_W   := 367.0
const _BAR_H   := 14.0
const _PANEL_H := _BAR_H * 4.0   # 56

func _create_fuel_bar() -> void:
	_hud_cl       = CanvasLayer.new()
	_hud_cl.name  = "CanvasLayer"
	_hud_cl.layer = 5
	add_child(_hud_cl)

	var team_col := GameConfig.color_for(team_id)

	_hud_bg         = ColorRect.new()
	_hud_bg.color   = Color(0x191a19ff)
	_hud_bg.size    = Vector2(_HUD_W, _PANEL_H)
	_hud_cl.add_child(_hud_bg)

	var row_h := _PANEL_H - _BAR_H   # 42

	var _condensed_font := load("res://fonts/MSYH.TTC")

	_name_input                  = LineEdit.new()
	_name_input.text_direction   = Control.TEXT_DIRECTION_LTR
	_name_input.language         = "en"
	_name_input.text             = ColyseusSync.local_name
	_name_input.placeholder_text = ""
	_name_input.max_length       = 14
	_name_input.size             = Vector2(160.0, 30.0)
	_name_input.add_theme_font_override("font", _condensed_font)
	_name_input.add_theme_font_size_override("font_size", 26)
	_name_input.add_theme_color_override("font_color",             team_col)
	_name_input.add_theme_color_override("font_placeholder_color", team_col)
	_name_input.add_theme_color_override("caret_color",            team_col)
	# Fully transparent, no border on any state
	var _sbox := StyleBoxEmpty.new()
	_name_input.add_theme_stylebox_override("normal",    _sbox)
	_name_input.add_theme_stylebox_override("focus",     _sbox)
	_name_input.add_theme_stylebox_override("hover",     _sbox)
	_name_input.add_theme_stylebox_override("read_only", _sbox)
	_name_input.text_changed.connect(_on_name_input_changed)
	_name_input.focus_entered.connect(func():
		_name_input.caret_column = _name_input.text.length())
	_hud_cl.add_child(_name_input)
	_name_input.caret_column = ColyseusSync.local_name.length()

	_cultivate_icon              = TextureRect.new()
	_cultivate_icon.texture      = load("res://UI/cultivatesmall.svg")
	_cultivate_icon.modulate     = team_col
	_cultivate_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_cultivate_icon.size         = Vector2(28.0, 30.0)
	_hud_cl.add_child(_cultivate_icon)


	_crops_hud_label             = Label.new()
	_crops_hud_label.text        = "x 0"
	_crops_hud_label.size        = Vector2(161.0, 30.0)
	_crops_hud_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_crops_hud_label.add_theme_font_override("font", _condensed_font)
	_crops_hud_label.add_theme_color_override("font_color", team_col)
	_crops_hud_label.add_theme_font_size_override("font_size", 26)
	_hud_cl.add_child(_crops_hud_label)

	var bar      = ColorRect.new()
	bar.name     = "FuelBar"
	bar.color    = team_col
	bar.size     = Vector2(366.0, _BAR_H)
	_hud_cl.add_child(bar)
	fuel_bar = bar

	_reposition_hud()
	get_viewport().size_changed.connect(_reposition_hud)

func _reposition_hud() -> void:
	if not is_instance_valid(_hud_bg):
		return
	var vp_h  := get_viewport().get_visible_rect().size.y
	var row_h := _PANEL_H - _BAR_H   # 42
	var row_y := vp_h - _PANEL_H + (row_h - 30.0) * 0.5

	_hud_bg.position          = Vector2(0.0, vp_h - _PANEL_H)
	_name_input.position      = Vector2(6.0,   row_y)
	_cultivate_icon.position  = Vector2(187.0, row_y)
	_crops_hud_label.position = Vector2(219.0, row_y)
	fuel_bar.position         = Vector2(0.0,   vp_h - _BAR_H)

func _on_name_input_changed(new_text: String) -> void:
	var clean := new_text.replace(" ", "")
	if clean != new_text:
		_name_input.text = clean
		_name_input.caret_column = clean.length()
	player_name = clean
	ColyseusSync.change_local_name(clean)

func set_player_name(pname: String) -> void:
	player_name = pname
	if is_instance_valid(_name_input):
		_name_input.text = pname
	queue_redraw()

func _draw() -> void:
	pass
