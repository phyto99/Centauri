extends Node2D

@export var player_scene: PackedScene
@export var player_count: int = 6

# ── Multiplayer test configuration ────────────────────────────────────────────
var _mp_test_teams: int = 3   # number of teams
var _mp_test_ppt:   int = 2   # players per team (base; round-robin handles extras)
var _mp_test_total_lbl: Label = null

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
	add_to_group("main")
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_session_ui()
	GameConfig.game_started.connect(_on_game_started)
	GameConfig.settings_changed.connect(_on_settings_changed_main)
	_build_free_cam()
	if OS.get_name() != "Web" or ColyseusSync.room_id.is_empty():
		spawn_players()
	else:
		# Multiplayer: start in free-cam pan mode until game begins
		_pre_game = true
		_free_cam.enabled = true
		call_deferred("_center_free_cam")
		# Re-center on local ship once PlayerSpawner redistributes it
		ColyseusSync.host_assigned.connect(func(_id, _h): call_deferred("_center_free_cam"))

func _build_free_cam() -> void:
	_free_cam = Camera2D.new()
	_free_cam.name = "FreeCam"
	_free_cam.process_mode = Node.PROCESS_MODE_ALWAYS
	_free_cam.enabled = false
	_free_cam.zoom = Vector2(0.6, 0.6)
	add_child(_free_cam)

func _center_free_cam() -> void:
	for ship in get_tree().get_nodes_in_group("players"):
		if is_instance_valid(ship) and ship.get("is_local"):
			_free_cam.global_position = ship.global_position
			return
	var sun: Node = get_tree().get_nodes_in_group("sun_planet").front()
	_free_cam.global_position = sun.global_position if (sun and is_instance_valid(sun)) else Vector2.ZERO

var _last_loaded_map_key: int = 0  # hash of last successfully queued map load

func _on_settings_changed_main() -> void:
	if _running or _countdown_active or GameConfig.map_json.is_empty():
		return
	var key := GameConfig.map_json.hash()
	if key == _last_loaded_map_key:
		return
	_last_loaded_map_key = key
	_load_map_from_dict(GameConfig.map_json)

func _on_game_started(cfg: Dictionary) -> void:
	PlayerSpawner._main_node = self
	# End pre-game pan — player.gd's _on_game_started_player re-enables ship camera
	_pre_game = false
	if is_instance_valid(_free_cam):
		_free_cam.enabled = false
	# Apply session duration if admin sent one
	if cfg.has("sessionDuration"):
		_session_duration = maxf(10.0, float(cfg["sessionDuration"]))
		_update_timebar()
	# Compute how many seconds remain until server's intended start time
	var start_at_ms: float = float(cfg.get("startAt", 0))
	var delay_sec: int = 10
	if start_at_ms > 0:
		var now_ms: float = Time.get_unix_time_from_system() * 1000.0
		delay_sec = max(1, int(ceil((start_at_ms - now_ms) / 1000.0)))
	if not _countdown_active and not _running:
		_on_start_pressed(delay_sec)

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

	var margin := MarginContainer.new()
	for side in ["margin_left","margin_right","margin_top","margin_bottom"]:
		margin.add_theme_constant_override(side, 8)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)

	var multiplayer_mode := OS.get_name() == "Web" and not ColyseusSync.room_id.is_empty()

	if not multiplayer_mode:
		# Import Map (local/dev only)
		var import_btn := Button.new()
		import_btn.text = "Import Map"
		import_btn.pressed.connect(_on_import_pressed)
		vbox.add_child(import_btn)

		vbox.add_child(HSeparator.new())

		# Session duration (local/dev only)
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

	# Time label (always shown)
	_time_label = Label.new()
	_time_label.text = "0.0 / 120 s"
	_time_label.add_theme_font_size_override("font_size", 12)
	_time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_time_label)

	if not multiplayer_mode:
		vbox.add_child(HSeparator.new())
		# Start button (local/dev only — admin panel controls start in multiplayer)
		_start_btn = Button.new()
		_start_btn.text = "▶ Start"
		_start_btn.pressed.connect(func(): _on_start_pressed())
		vbox.add_child(_start_btn)

		vbox.add_child(HSeparator.new())
		_build_mp_test_panel(vbox)
	else:
		vbox.add_child(HSeparator.new())
		var wait_lbl := Label.new()
		wait_lbl.text = "Waiting for host..."
		wait_lbl.add_theme_font_size_override("font_size", 11)
		wait_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vbox.add_child(wait_lbl)

# ── Multiplayer test panel ────────────────────────────────────────────────────
func _build_mp_test_panel(vbox: VBoxContainer) -> void:
	var header := Label.new()
	header.text = "Multiplayer Test"
	header.add_theme_font_size_override("font_size", 11)
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(header)

	# Teams slider row
	var teams_row := HBoxContainer.new()
	teams_row.add_theme_constant_override("separation", 4)
	vbox.add_child(teams_row)
	var teams_lbl := Label.new()
	teams_lbl.text = "Teams"
	teams_lbl.add_theme_font_size_override("font_size", 11)
	teams_lbl.custom_minimum_size = Vector2(52, 0)
	teams_row.add_child(teams_lbl)
	var teams_slider := HSlider.new()
	teams_slider.min_value = 1
	teams_slider.max_value = 8
	teams_slider.step = 1
	teams_slider.value = _mp_test_teams
	teams_slider.custom_minimum_size = Vector2(80, 0)
	teams_row.add_child(teams_slider)
	var teams_val := Label.new()
	teams_val.text = str(_mp_test_teams)
	teams_val.add_theme_font_size_override("font_size", 11)
	teams_val.custom_minimum_size = Vector2(16, 0)
	teams_row.add_child(teams_val)
	teams_slider.value_changed.connect(func(v: float):
		_mp_test_teams = int(v)
		teams_val.text = str(_mp_test_teams)
		_update_mp_test_total_label())

	# Players per team slider row
	var ppt_row := HBoxContainer.new()
	ppt_row.add_theme_constant_override("separation", 4)
	vbox.add_child(ppt_row)
	var ppt_lbl := Label.new()
	ppt_lbl.text = "Per team"
	ppt_lbl.add_theme_font_size_override("font_size", 11)
	ppt_lbl.custom_minimum_size = Vector2(52, 0)
	ppt_row.add_child(ppt_lbl)
	var ppt_slider := HSlider.new()
	ppt_slider.min_value = 1
	ppt_slider.max_value = 6
	ppt_slider.step = 1
	ppt_slider.value = _mp_test_ppt
	ppt_slider.custom_minimum_size = Vector2(80, 0)
	ppt_row.add_child(ppt_slider)
	var ppt_val := Label.new()
	ppt_val.text = str(_mp_test_ppt)
	ppt_val.add_theme_font_size_override("font_size", 11)
	ppt_val.custom_minimum_size = Vector2(16, 0)
	ppt_row.add_child(ppt_val)
	ppt_slider.value_changed.connect(func(v: float):
		_mp_test_ppt = int(v)
		ppt_val.text = str(_mp_test_ppt)
		_update_mp_test_total_label())

	# Total players indicator
	_mp_test_total_lbl = Label.new()
	_mp_test_total_lbl.add_theme_font_size_override("font_size", 11)
	_mp_test_total_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_update_mp_test_total_label()
	vbox.add_child(_mp_test_total_lbl)

	# Respawn button
	var respawn_btn := Button.new()
	respawn_btn.text = "Respawn"
	respawn_btn.pressed.connect(_respawn_mp_test)
	vbox.add_child(respawn_btn)

func _update_mp_test_total_label() -> void:
	if _mp_test_total_lbl:
		_mp_test_total_lbl.text = "%d players" % (_mp_test_teams * _mp_test_ppt)

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
	await _load_map_from_dict(raw as Dictionary)

func _load_map_from_dict(data: Dictionary) -> void:
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
	_running = false
	GameConfig.game_running = false
	_update_timebar()
	if _start_btn:
		_start_btn.text = "▶ Start"

var _countdown_active: bool = false

func _on_start_pressed(countdown_seconds: int = 10) -> void:
	if _countdown_active:
		return
	if not _running:
		if _start_btn:
			_start_btn.text = "..."
			_start_btn.disabled = true
		_run_countdown(countdown_seconds)
	else:
		_running = false
		GameConfig.game_running = false
		if _start_btn:
			_start_btn.text = "▶ Resume"
			_start_btn.disabled = false

func _run_countdown(seconds: int = 10) -> void:
	_countdown_active = true

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

	for n in range(seconds, -1, -1):
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
	_running = true
	GameConfig.game_running = true
	for ship in get_tree().get_nodes_in_group("players"):
		if is_instance_valid(ship):
			ship.call("launch")
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

# ── Physics process — planet positions updated here so ships read fresh pos same tick ──
func _physics_process(delta: float) -> void:
	if not _running:
		return

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

# ── Process — UI/timebar/explosions only ──────────────────────────────────────
func _process(delta: float) -> void:
	if not _running:
		return

	# Update explosions
	for exp in _explosions:
		exp.radius += exp.max_radius * 2.2 * delta
		exp.alpha = max(0.0, 1.0 - (exp.radius / exp.max_radius))
	_explosions = _explosions.filter(func(e): return e.alpha > 0.0 and e.radius < e.max_radius)

	_session_time = min(_session_time + delta, _session_duration)
	_update_timebar()
	if _session_time >= _session_duration:
		_running = false
		GameConfig.game_running = false
		_show_game_over()

	queue_redraw()

const _TB_TRIM_LEFT  := 2
const _TB_TRIM_RIGHT := 1

func _init_timebar_sprite() -> void:
	var tb: Node = get_node_or_null("UI/CanvasLayer/Timebar")
	if tb and tb is Sprite2D:
		_timebar_sprite = tb as Sprite2D
		_fit_timebar()
		get_viewport().size_changed.connect(_fit_timebar)
		_set_timebar_progress(1.0)

func _fit_timebar() -> void:
	if not is_instance_valid(_timebar_sprite) or not _timebar_sprite.texture:
		return
	var tex_w := float(_timebar_sprite.texture.get_width())
	var tex_h := float(_timebar_sprite.texture.get_height())
	var content_w := tex_w - _TB_TRIM_LEFT - _TB_TRIM_RIGHT
	_timebar_sprite.region_enabled = true
	_timebar_sprite.region_rect = Rect2(_TB_TRIM_LEFT, 0.0, content_w, tex_h)
	var vp_w := get_viewport().get_visible_rect().size.x
	_timebar_sprite.scale.x = vp_w / content_w
	_timebar_sprite.position.x = vp_w * 0.5

func _set_timebar_progress(value: float) -> void:
	if _timebar_sprite and _timebar_sprite.material is ShaderMaterial:
		_timebar_sprite.material.set_shader_parameter("progress", value)

var _game_over: bool = false
var _pre_game:  bool = false
var _pan_last: Vector2 = Vector2.ZERO
var _panning: bool = false
var _free_cam: Camera2D = null

func _show_game_over() -> void:
	_game_over = true
	var ui := get_node_or_null("UI")
	if ui and ui.has_method("set_game_over"):
		ui.set_game_over()

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
	panel.custom_minimum_size = Vector2(900, 0)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.gui_input.connect(func(ev: InputEvent): get_viewport().set_input_as_handled())
	cl.add_child(panel)

	var margin := MarginContainer.new()
	for side in ["margin_left","margin_right","margin_top","margin_bottom"]:
		margin.add_theme_constant_override(side, 18)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
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

	var _gap := Control.new()
	_gap.custom_minimum_size.y = 12.0
	_gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(_gap)

	# Embed a centered duplicate of the scoreboard
	var scoreboard := get_node_or_null("UI/CanvasLayer/Scoreboard")
	if scoreboard and is_instance_valid(scoreboard):
		var sb_scale      := 1.5
		var il_local_h    := 267.0
		var panel_content := 900.0 - 56.0
		# effective visual width: ItemList(641) * its scale(0.8) * Node2D(1.2) * sb_scale(1.5)
		var sb_visual_w   := 641.0 * 0.8 * 1.2 * sb_scale
		var sb_visual_h   := il_local_h * 0.8 * 1.2 * sb_scale
		var center_x      := (panel_content - sb_visual_w) * 0.5
		var wrapper := Control.new()
		wrapper.custom_minimum_size = Vector2(panel_content, sb_visual_h)
		wrapper.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vbox.add_child(wrapper)
		var sb_copy := scoreboard.duplicate(DUPLICATE_USE_INSTANTIATION)
		sb_copy.position = Vector2(35.0, 0)
		sb_copy.scale    = Vector2(sb_scale, sb_scale)
		wrapper.add_child(sb_copy)
		# Remove scrollbar by forcing ItemList tall enough
		var copy_il := sb_copy.get_node_or_null("ItemList")
		if copy_il:
			copy_il.size.y = il_local_h
			copy_il.custom_minimum_size.y = il_local_h
			copy_il.add_theme_constant_override("v_separation", 0)
		# Copy final-game accumulators so cols 0 & 2 reflect end state
		var orig_il := scoreboard.get_node_or_null("ItemList")
		if orig_il and copy_il:
			copy_il.set("_team_yield",     orig_il.get("_team_yield").duplicate())
			copy_il.set("_team_delivered", orig_il.get("_team_delivered").duplicate())
			copy_il.call("_rebuild_team_rows")

	# Clicking the live scoreboard after game over reopens the overlay
	var hud_il := get_node_or_null("UI/CanvasLayer/Scoreboard/ItemList")
	if hud_il and not hud_il.get_meta("_go_wired", false):
		hud_il.set_meta("_go_wired", true)
		hud_il.gui_input.connect(func(ev: InputEvent):
			if ev is InputEventMouseButton and ev.pressed \
					and ev.button_index != MOUSE_BUTTON_WHEEL_UP \
					and ev.button_index != MOUSE_BUTTON_WHEEL_DOWN \
					and ev.button_index != MOUSE_BUTTON_WHEEL_LEFT \
					and ev.button_index != MOUSE_BUTTON_WHEEL_RIGHT:
				cl.visible = true
				get_viewport().set_input_as_handled())

func _get_active_cam() -> Camera2D:
	if is_instance_valid(_free_cam) and _free_cam.enabled:
		return _free_cam
	for ship in get_tree().get_nodes_in_group("players"):
		if not is_instance_valid(ship):
			continue
		var cam := ship.get_node_or_null("Camera2D")
		if cam and cam.enabled:
			return cam
	return null

func _unhandled_input(event: InputEvent) -> void:
	# Any click that reaches here wasn't consumed by UI — release focus
	if event is InputEventMouseButton and event.pressed:
		var focused := get_viewport().gui_get_focus_owner()
		if focused:
			focused.release_focus()

	# Zoom works in all states
	if event is InputEventMouseButton and event.pressed:
		var cam := _get_active_cam()
		if cam:
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				cam.zoom *= 1.1
				get_viewport().set_input_as_handled()
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				cam.zoom *= 0.9
				get_viewport().set_input_as_handled()

	# Panning: pre-game uses free cam; game-over uses ship cam
	if _pre_game:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			_panning = event.pressed
		elif event is InputEventMouseMotion and _panning and is_instance_valid(_free_cam):
			_free_cam.global_position -= event.relative / _free_cam.zoom.x
		return

	if not _game_over:
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_panning = event.pressed
	elif event is InputEventMouseMotion and _panning:
		var cam := _get_active_cam()
		if cam:
			cam.global_position -= event.relative / cam.zoom.x

func _update_timebar() -> void:
	var progress: float = 1.0 - (_session_time / _session_duration) if _session_duration > 0 else 1.0
	_set_timebar_progress(progress)
	if _time_label:
		_time_label.text = "%.0f / %d s" % [_session_time, int(_session_duration)]

# ── Draw explosions ───────────────────────────────────────────────────────────
func _draw() -> void:
	if _explosions.is_empty():
		return
	var inv_z: float = 1.0
	var cam := _get_active_cam()
	if cam:
		inv_z = 1.0 / cam.zoom.x
	for exp in _explosions:
		var thickness: float = (2.0 + 18.0 * (1.0 - exp.alpha)) * inv_z
		draw_arc(exp.pos, exp.radius, 0.0, TAU, 64,
				Color(1.0, 1.0, 1.0, exp.alpha * 0.9), thickness)

# ── Spawn helpers ─────────────────────────────────────────────────────────────

# Returns a slot-ordered list of team IDs so that teammates are maximally spread.
# With equal-sized teams this is exactly round-robin (slot i → team i % num_teams).
# For uneven totals, larger teams get extras distributed evenly via round-robin as well.
func _interleaved_team_ids(num_teams: int, total: int) -> Array:
	var ids: Array = []
	ids.resize(total)
	# Fill with round-robin: slot i gets team (i % num_teams)
	for i in total:
		ids[i] = i % num_teams
	return ids

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

	player_count = _mp_test_teams * _mp_test_ppt
	var total    := player_count
	var spawn_r: float = sun.surface_radius + back_dist
	var team_ids := _interleaved_team_ids(_mp_test_teams, total)

	for i in range(player_count):
		var angle := i * TAU / total - PI / 2.0
		var p := player_scene.instantiate()
		p.team_id = team_ids[i]
		add_child(p)
		p.global_position = sun.global_position + Vector2.from_angle(angle) * spawn_r
		p.rotation = angle

func _respawn_mp_test() -> void:
	if _running or _countdown_active:
		return
	for p in get_tree().get_nodes_in_group("players"):
		if is_instance_valid(p):
			p.queue_free()
	await get_tree().process_frame
	spawn_players()
	_update_mp_test_total_label()

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
