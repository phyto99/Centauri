extends Node2D

@export var player_scene: PackedScene
@export var player_count: int = 5

# ── N-body constants (must match mapmaker.gd) ─────────────────────────────────
const G         := 80.0 * 2.0 * 100.0
const SUBSTEPS  := 4
const SIM_STEP  := 0.016

# ── Session state ─────────────────────────────────────────────────────────────
var _session_duration: float = 120.0   # seconds
var _session_time:     float = 0.0
var _running:          bool  = false
var _sim_accumulator:  float = 0.0
var _start_btn:        Button = null

# Per-planet velocity store (instance_id → Vector2)
# Planets are frozen; we drive them manually like the mapmaker
var _velocities: Dictionary = {}

# Explosion rings [{pos, radius, max_radius, alpha}]
var _explosions: Array = []

# UI refs
var _timebar_sprite:   Sprite2D = null
var _time_label:       Label    = null
var _session_cl:       CanvasLayer = null

func _ready() -> void:
	# Set this node to ALWAYS so _process/_unhandled_input work while paused
	# but explicitly mark gameplay children as PAUSABLE so they freeze
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_session_ui()
	spawn_players()
	# Mark all gameplay nodes as PAUSABLE so get_tree().paused actually freezes them
	_set_gameplay_pausable()
	get_tree().paused = true

func _set_gameplay_pausable() -> void:
	# Explicitly set ships and planets to PAUSABLE so they freeze
	for ship in get_tree().get_nodes_in_group("players"):
		if is_instance_valid(ship):
			ship.process_mode = Node.PROCESS_MODE_PAUSABLE
	for planet in get_tree().get_nodes_in_group("planets"):
		if is_instance_valid(planet):
			planet.process_mode = Node.PROCESS_MODE_PAUSABLE
	# Also freeze the UI control node (buttons, etc.)
	var ui := get_node_or_null("UI")
	if ui:
		ui.process_mode = Node.PROCESS_MODE_PAUSABLE
		# Exempt the crops label so it still reads food_amount while paused
		var crops := ui.get_node_or_null("CanvasLayer/playercrops")
		if crops:
			crops.process_mode = Node.PROCESS_MODE_ALWAYS

# ── Session UI ────────────────────────────────────────────────────────────────
func _build_session_ui() -> void:
	_session_cl = CanvasLayer.new()
	_session_cl.layer = 20
	_session_cl.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_session_cl)

	# Find the existing timebar sprite from the scene and drive it from here
	# It's at UI/CanvasLayer/Timebar — look it up after ready
	call_deferred("_init_timebar_sprite")

	# Settings panel — anchored top-right, grows leftward
	var panel := PanelContainer.new()
	panel.anchor_left   = 1.0
	panel.anchor_right  = 1.0
	panel.anchor_top    = 0.0
	panel.anchor_bottom = 0.0
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	panel.offset_right  = -8.0
	panel.offset_top    = 30.0   # below timebar
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_session_cl.add_child(panel)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_session_cl.add_child(panel)

	var margin := MarginContainer.new()
	for side in ["margin_left","margin_right","margin_top","margin_bottom"]:
		margin.add_theme_constant_override(side, 8)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)

	# Import Map
	var import_btn := Button.new()
	import_btn.text = "Import Map"
	import_btn.pressed.connect(_on_import_pressed)
	vbox.add_child(import_btn)

	vbox.add_child(HSeparator.new())

	# Session duration
	var dur_row := HBoxContainer.new()
	dur_row.add_theme_constant_override("separation", 4)
	vbox.add_child(dur_row)
	var dur_lbl := Label.new()
	dur_lbl.text = "Duration"
	dur_lbl.add_theme_font_size_override("font_size", 12)
	dur_row.add_child(dur_lbl)
	var dur_input := LineEdit.new()
	dur_input.text = "120"
	dur_input.custom_minimum_size = Vector2(52, 0)
	dur_input.placeholder_text = "s"
	dur_row.add_child(dur_input)
	var dur_s := Label.new()
	dur_s.text = "s"
	dur_s.add_theme_font_size_override("font_size", 12)
	dur_row.add_child(dur_s)
	dur_input.text_submitted.connect(func(t: String):
		if t.is_valid_float():
			_session_duration = maxf(10.0, float(t))
			_update_timebar())
	dur_input.focus_exited.connect(func():
		if dur_input.text.is_valid_float():
			_session_duration = maxf(10.0, float(dur_input.text))
			_update_timebar())

	# Time label
	_time_label = Label.new()
	_time_label.text = "0.0 / 120 s"
	_time_label.add_theme_font_size_override("font_size", 12)
	_time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_time_label)

	vbox.add_child(HSeparator.new())

	# Start button
	_start_btn = Button.new()
	_start_btn.text = "▶ Start"
	_start_btn.pressed.connect(_on_start_pressed)
	vbox.add_child(_start_btn)

# ── Import from clipboard ─────────────────────────────────────────────────────
func _on_import_pressed() -> void:
	var clip := DisplayServer.clipboard_get()
	if clip.is_empty():
		push_warning("Clipboard is empty")
		return
	var json := JSON.new()
	if json.parse(clip) != OK:
		push_warning("Clipboard does not contain valid JSON")
		return
	var raw = json.get_data()
	if not raw is Dictionary:
		push_warning("JSON root is not a Dictionary")
		return
	var data: Dictionary = raw as Dictionary
	var planets_data: Array = data.get("planets", []) as Array

	# Clear existing non-sun planets
	for planet in get_tree().get_nodes_in_group("planets"):
		if is_instance_valid(planet) and not planet.get("is_sun"):
			_velocities.erase(planet.get_instance_id())
			planet.queue_free()
	await get_tree().process_frame

	var sun: Node = get_tree().get_nodes_in_group("sun_planet").front()
	if not sun:
		push_error("No sun found")
		return

	for pd in planets_data:
		var planet := RigidBody2D.new()
		planet.set_script(load("res://PlanetBuilder.gd"))
		planet.sprite_scene          = sun.sprite_scene
		planet.claim_stamp_scene     = sun.claim_stamp_scene
		planet.cultivate_stamp_scene = sun.cultivate_stamp_scene
		planet.current_size          = int(pd.get("size", 7))
		planet.mass                  = float(pd.get("mass", 50.0))
		planet.planet_color_index    = int(pd.get("color_idx", 2))
		planet.freeze                = true
		planet.freeze_mode           = RigidBody2D.FREEZE_MODE_STATIC
		add_child(planet)
		planet.position = Vector2(float(pd.get("pos_x", 0.0)), float(pd.get("pos_y", 0.0)))
		planet.apply_appearance()
		var vel := Vector2(float(pd.get("vel_x", 0.0)), float(pd.get("vel_y", 0.0)))
		_velocities[planet.get_instance_id()] = vel

	_session_time = 0.0
	_running = false   # wait for Start button
	_update_timebar()
	if _start_btn:
		_start_btn.text = "▶ Start"
	# Re-freeze newly spawned planets
	_set_gameplay_pausable()

var _countdown_active: bool = false

func _on_start_pressed() -> void:
	if _countdown_active:
		return
	if not _running:
		# First press — run countdown then start
		if _start_btn:
			_start_btn.text = "..."
			_start_btn.disabled = true
		_run_countdown()
	else:
		_running = false
		if _start_btn:
			_start_btn.text = "▶ Resume"
			_start_btn.disabled = false

func _run_countdown() -> void:
	_countdown_active = true
	# Game is already paused from _ready — countdown runs as ALWAYS

	var cl := CanvasLayer.new()
	cl.layer = 50
	cl.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(cl)

	var lbl := Label.new()
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 180)
	lbl.add_theme_color_override("font_color", Color.WHITE)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.anchor_left   = 0.75
	lbl.anchor_right  = 0.75
	lbl.anchor_top    = 0.5
	lbl.anchor_bottom = 0.5
	lbl.grow_horizontal = Control.GROW_DIRECTION_BOTH
	lbl.grow_vertical   = Control.GROW_DIRECTION_BOTH
	cl.add_child(lbl)

	for n in range(10, -1, -1):
		lbl.text = str(n)
		lbl.modulate = Color(1, 1, 1, 0.0)

		var steps := 20
		var rise_px := 80.0
		var step_time := 0.03

		for step in range(steps):
			var t: float = float(step) / float(steps - 1)
			var ease_t: float = 1.0 - pow(1.0 - t, 2.0)
			lbl.modulate.a = ease_t
			lbl.offset_top    = rise_px * (1.0 - ease_t)
			lbl.offset_bottom = lbl.offset_top
			await get_tree().create_timer(step_time, true).timeout

		await get_tree().create_timer(0.15, true).timeout
		lbl.modulate.a = 0.0

	cl.queue_free()
	_countdown_active = false
	# Unfreeze and start
	get_tree().paused = false
	_running = true
	if _start_btn:
		_start_btn.text = "⏸ Pause"
		_start_btn.disabled = false

# ── N-body physics ────────────────────────────────────────────────────────────
func _is_anchor(planet: Node) -> bool:
	if planet.get("is_sun"):
		return true
	return _velocities.get(planet.get_instance_id(), Vector2.ZERO).length_squared() < 0.001

func _nbody_step(bodies: Array, dt: float) -> void:
	var sub_dt: float = dt / SUBSTEPS
	for _s in range(SUBSTEPS):
		for i in range(bodies.size()):
			var a: Dictionary = bodies[i]
			if a.anchor:
				continue
			var ax: float = 0.0
			var ay: float = 0.0
			for j in range(bodies.size()):
				if i == j:
					continue
				var b: Dictionary = bodies[j]
				var dx: float = b.pos.x - a.pos.x
				var dy: float = b.pos.y - a.pos.y
				var r2: float = dx * dx + dy * dy + 1.0
				var r: float  = sqrt(r2)
				var f: float  = G * b.mass / r2
				ax += f * dx / r
				ay += f * dy / r
			a.acc = Vector2(ax, ay)
		for i in range(bodies.size()):
			var a: Dictionary = bodies[i]
			if a.anchor:
				continue
			a.vel += a.acc * sub_dt
			a.pos += a.vel * sub_dt

func _check_collisions(bodies: Array) -> void:
	var to_remove: Array = []
	for i in range(bodies.size()):
		for j in range(i + 1, bodies.size()):
			var a: Dictionary = bodies[i]
			var b: Dictionary = bodies[j]
			if not is_instance_valid(a.node) or not is_instance_valid(b.node):
				continue
			if a.node in to_remove or b.node in to_remove:
				continue
			var dist: float = a.pos.distance_to(b.pos)
			var sum_r: float = (a.node.get("surface_radius") if a.node.get("surface_radius") else 80.0) \
							 + (b.node.get("surface_radius") if b.node.get("surface_radius") else 80.0)
			if dist < sum_r:
				var mid: Vector2 = (a.pos + b.pos) * 0.5
				var blast_r: float = max(sum_r * 4.0, 400.0)
				var blast_str: float = sqrt(a.mass + b.mass) * 400.0
				_explosions.append({"pos": mid, "radius": 0.0, "max_radius": blast_r, "alpha": 1.0})
				for k in range(bodies.size()):
					var c: Dictionary = bodies[k]
					if c.anchor or c.node == a.node or c.node == b.node:
						continue
					var to_c: Vector2 = c.pos - mid
					var d: float = to_c.length()
					if d < blast_r and d > 1.0:
						var falloff: float = 1.0 - (d / blast_r)
						_velocities[c.id] = _velocities.get(c.id, Vector2.ZERO) \
							+ to_c.normalized() * blast_str * falloff / (c.mass + 1.0)
				if not a.node.get("is_sun"):
					to_remove.append(a.node)
				if not b.node.get("is_sun"):
					to_remove.append(b.node)
	for node in to_remove:
		if is_instance_valid(node):
			_velocities.erase(node.get_instance_id())
			node.queue_free()

# ── Process ───────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	if not _running:
		return

	# Update explosions
	for exp in _explosions:
		exp.radius += exp.max_radius * 2.2 * delta
		exp.alpha = max(0.0, 1.0 - (exp.radius / exp.max_radius))
	_explosions = _explosions.filter(func(e): return e.alpha > 0.0 and e.radius < e.max_radius)

	# N-body sim
	_sim_accumulator += delta
	while _sim_accumulator >= SIM_STEP:
		_sim_accumulator -= SIM_STEP
		var bodies: Array = []
		for planet in get_tree().get_nodes_in_group("planets"):
			if not is_instance_valid(planet):
				continue
			var pid: int = planet.get_instance_id()
			bodies.append({
				"node":   planet,
				"id":     pid,
				"pos":    Vector2(planet.position),
				"vel":    Vector2(_velocities.get(pid, Vector2.ZERO)),
				"mass":   float(planet.mass),
				"anchor": _is_anchor(planet),
				"acc":    Vector2.ZERO,
			})
		_nbody_step(bodies, SIM_STEP)
		for b in bodies:
			if b.anchor:
				continue
			b.node.position = b.pos
			_velocities[b.id] = b.vel
		_check_collisions(bodies)

	_session_time = min(_session_time + delta, _session_duration)
	_update_timebar()
	if _session_time >= _session_duration:
		_running = false
		_show_game_over()

	queue_redraw()

func _init_timebar_sprite() -> void:
	# Find the Timebar sprite in the scene and stretch it to viewport width
	var tb: Node = get_node_or_null("UI/CanvasLayer/Timebar")
	if tb and tb is Sprite2D:
		_timebar_sprite = tb as Sprite2D
		# Scale to fill viewport width
		var vp_w: float = get_viewport().get_visible_rect().size.x
		var tex_w: float = _timebar_sprite.texture.get_width() if _timebar_sprite.texture else 240.0
		_timebar_sprite.scale.x = vp_w / tex_w
		_timebar_sprite.position.x = vp_w * 0.5
		# Start at full (progress=1 means fully visible, we'll count down)
		_set_timebar_progress(1.0)

func _set_timebar_progress(value: float) -> void:
	if _timebar_sprite and _timebar_sprite.material is ShaderMaterial:
		_timebar_sprite.material.set_shader_parameter("progress", value)

var _game_over: bool = false
var _pan_last: Vector2 = Vector2.ZERO
var _panning: bool = false

func _show_game_over() -> void:
	_game_over = true
	get_tree().paused = true

	var cl := CanvasLayer.new()
	cl.layer = 60
	cl.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(cl)

	# Full-screen dismiss overlay
	var overlay := ColorRect.new()
	overlay.color = Color(0, 0, 0, 0.55)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed:
			cl.visible = false)
	cl.add_child(overlay)

	# Centered panel — fixed width, auto height
	var panel := PanelContainer.new()
	panel.anchor_left   = 0.5
	panel.anchor_right  = 0.5
	panel.anchor_top    = 0.5
	panel.anchor_bottom = 0.5
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical   = Control.GROW_DIRECTION_BOTH
	panel.custom_minimum_size = Vector2(700, 0)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.gui_input.connect(func(ev: InputEvent): get_viewport().set_input_as_handled())
	cl.add_child(panel)

	var margin := MarginContainer.new()
	for side in ["margin_left","margin_right","margin_top","margin_bottom"]:
		margin.add_theme_constant_override(side, 28)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 24)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(vbox)

	# GAME OVER title — above scoreboard
	var title := Label.new()
	title.text = "GAME OVER"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 64)
	title.add_theme_color_override("font_color", Color.WHITE)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(title)

	vbox.add_child(HSeparator.new())

	# Embed the live scoreboard node directly (reparent temporarily)
	var scoreboard := get_node_or_null("UI/CanvasLayer/Scoreboard")
	if scoreboard and is_instance_valid(scoreboard):
		# Wrap in a Control so the Node2D scoreboard sits inside the vbox
		var wrapper := Control.new()
		wrapper.custom_minimum_size = Vector2(640, 120)
		wrapper.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vbox.add_child(wrapper)
		var sb_copy := scoreboard.duplicate(DUPLICATE_USE_INSTANTIATION)
		sb_copy.position = Vector2.ZERO
		sb_copy.scale = Vector2(1.5, 1.5)
		wrapper.custom_minimum_size = Vector2(640, 120 * 1.5)
		wrapper.add_child(sb_copy)

	# Wire scoreboard HUD button to re-show overlay
	var sb_node := get_node_or_null("UI/CanvasLayer/Scoreboard")
	if sb_node and not sb_node.has_node("_GameOverBtn"):
		var sb_btn := Button.new()
		sb_btn.name = "_GameOverBtn"
		sb_btn.flat = true
		sb_btn.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		sb_btn.mouse_filter = Control.MOUSE_FILTER_STOP
		sb_btn.pressed.connect(func(): cl.visible = true)
		sb_node.add_child(sb_btn)

func _unhandled_input(event: InputEvent) -> void:
	if not _game_over:
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_panning = event.pressed
	elif event is InputEventMouseMotion and _panning:
		for ship in get_tree().get_nodes_in_group("players"):
			if not is_instance_valid(ship):
				continue
			var cam := ship.get_node_or_null("Camera2D")
			if cam and cam.enabled:
				# Move camera opposite to drag direction, scaled by zoom
				cam.global_position -= event.relative / cam.zoom.x
				break

func _update_timebar() -> void:
	var progress: float = 1.0 - (_session_time / _session_duration) if _session_duration > 0 else 1.0
	_set_timebar_progress(progress)
	if _time_label:
		_time_label.text = "%.0f / %d s" % [_session_time, int(_session_duration)]

# ── Draw explosions ───────────────────────────────────────────────────────────
func _draw() -> void:
	if _explosions.is_empty():
		return
	# Get current camera zoom for screen-space thickness
	var inv_z: float = 1.0
	for ship in get_tree().get_nodes_in_group("players"):
		if not is_instance_valid(ship):
			continue
		var cam := ship.get_node_or_null("Camera2D")
		if cam and cam.enabled:
			inv_z = 1.0 / cam.zoom.x
			break
	for exp in _explosions:
		var thickness: float = (2.0 + 18.0 * (1.0 - exp.alpha)) * inv_z
		draw_arc(exp.pos, exp.radius, 0.0, TAU, 64,
				Color(1.0, 1.0, 1.0, exp.alpha * 0.9), thickness)

# ── Spawn helpers ─────────────────────────────────────────────────────────────
func spawn_players() -> void:
	var sun: Node = get_tree().get_nodes_in_group("sun_planet").front()
	if not sun or not player_scene:
		return

	var back_dist := 95.0
	var probe := player_scene.instantiate()
	var cpoly := probe.get_node_or_null("CollisionPolygon2D")
	if cpoly:
		var min_x := INF
		for pt: Vector2 in cpoly.polygon:
			min_x = min(min_x, pt.x)
		back_dist = -(min_x + cpoly.position.x)
	probe.free()

	var existing := get_tree().get_nodes_in_group("players")
	var total    := existing.size() + player_count
	var spawn_r: float = sun.surface_radius + back_dist

	for i in range(existing.size()):
		var angle := i * TAU / total - PI / 2.0
		existing[i].global_position = sun.global_position + Vector2.from_angle(angle) * spawn_r
		existing[i].rotation = angle

	for i in range(player_count):
		var angle := (existing.size() + i) * TAU / total - PI / 2.0
		var p := player_scene.instantiate()
		p.team_id = i
		add_child(p)
		p.global_position = sun.global_position + Vector2.from_angle(angle) * spawn_r
		p.rotation = angle

func spawn_random_planets() -> void:
	var sun: Node = get_tree().get_nodes_in_group("sun_planet").front()
	if not sun:
		return
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	for i in range(6):
		var angle := i * TAU / 6.0 + rng.randf_range(-0.4, 0.4)
		var dist  := rng.randf_range(500.0, 1000.0)
		var planet := RigidBody2D.new()
		planet.set_script(load("res://PlanetBuilder.gd"))
		planet.sprite_scene          = sun.sprite_scene
		planet.claim_stamp_scene     = sun.claim_stamp_scene
		planet.cultivate_stamp_scene = sun.cultivate_stamp_scene
		planet.current_size = rng.randi_range(7, 60)
		planet.position     = Vector2.from_angle(angle) * dist
		add_child(planet)
