extends Node2D

@export var player_scene: PackedScene
@export var player_count: int = 6

# ── Multiplayer test configuration ────────────────────────────────────────────
var _mp_test_teams: int = 3   # number of teams
var _mp_test_ppt:   int = 2   # players per team (base; round-robin handles extras)
var _mp_test_total_lbl: Label = null
var _mp_pregame_btn: Button = null

# ── N-body constants (must match mapmaker.gd) ─────────────────────────────────
const G         := 80.0 * 2.0 * 100.0
const SUBSTEPS  := 4
const SIM_STEP  := 0.016

# ── Session state ─────────────────────────────────────────────────────────────
var _session_duration: float = 120.0   # seconds
var _session_time:     float = 0.0
var _session_end_wall: float = 0.0    # Unix timestamp when session ends (multiplayer only)
var _is_mp:            bool  = false  # true when running in a Colyseus room
var _running:          bool  = false
var _sim_accumulator:  float = 0.0
var _start_btn:        Button = null

# Per-planet velocity store (instance_id → Vector2)
# Planets are frozen; we drive them manually like the mapmaker
var _velocities: Dictionary = {}

# planet_idx → planet Node — populated in _load_map_from_dict for O(1) lookup
var _planet_by_idx: Dictionary = {}

# ── Planet-sim clock (wall-clock-based for cross-client sync) ─────────────────
var _sim_start_wall:  float = 0.0  # Unix time when the sim "started" (same on all clients)
var _total_sim_steps: int   = 0    # Steps taken so far on this client
var _planet_broadcast_timer: float = 0.0

# Explosion rings [{pos, radius, max_radius, alpha}]
var _explosions: Array = []

# UI refs
var _timebar_sprite:   Sprite2D = null
var _time_label:       Label    = null
var _session_cl:       CanvasLayer = null

func _ready() -> void:
	add_to_group("main")
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_physics_priority = -1
	DisplayServer.window_set_title("Centauri")
	_is_mp = OS.get_name() == "Web" and not ColyseusSync.room_id.is_empty()
	_build_session_ui()
	GameConfig.game_started.connect(_on_game_started)
	GameConfig.settings_changed.connect(_on_settings_changed_main)
	_build_free_cam()
	if _is_mp:
		ColyseusSync.game_event_received.connect(_on_remote_game_event)
	if not _is_mp:
		spawn_players()
		call_deferred("_bake_traj")
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
		if is_instance_valid(ship) and bool(ship.get("is_local")):
			_free_cam.global_position = ship.global_position
			return
	var sun: Node = get_tree().get_nodes_in_group("sun_planet").front()
	_free_cam.global_position = sun.global_position if (sun and is_instance_valid(sun)) else Vector2.ZERO

var _last_loaded_map_key: int = 0  # hash of last successfully queued map load
var _map_load_gen: int = 0         # bumped each load; lets concurrent coroutines self-abort

func _on_settings_changed_main() -> void:
	if _running or _countdown_active:
		return
	_session_duration = GameConfig.session_duration
	_update_timebar()
	if GameConfig.map_json.is_empty():
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
	_user_panned = false
	_panning = false
	if is_instance_valid(_free_cam):
		_free_cam.enabled = false
	# GameConfig.apply_settings already ran with the inner config dict before
	# game_started fired, so session_duration is authoritative here.
	_session_duration = GameConfig.session_duration
	_update_timebar()
	var start_at_ms: float = float(cfg.get("startAt", 0))
	if start_at_ms > 0:
		_start_at_wall   = start_at_ms / 1000.0
		_sim_start_wall  = _start_at_wall
		_session_end_wall = _start_at_wall + _session_duration
	if not _countdown_active and not _running:
		_on_start_pressed()

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
		panel.visible = false

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

	vbox.add_child(HSeparator.new())

	# Simulate multiplayer pre-game lobby
	_mp_pregame_btn = Button.new()
	_mp_pregame_btn.text = "Simulate Pre-game"
	_mp_pregame_btn.pressed.connect(_toggle_mp_pregame)
	vbox.add_child(_mp_pregame_btn)

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
	_map_load_gen += 1
	var my_gen := _map_load_gen

	var planets_data: Array = data.get("planets", []) as Array

	# Clear existing non-sun planets
	_planet_by_idx.clear()
	for planet in get_tree().get_nodes_in_group("planets"):
		if is_instance_valid(planet) and not planet.get("is_sun"):
			_velocities.erase(planet.get_instance_id())
			planet.queue_free()
	await get_tree().process_frame

	if my_gen != _map_load_gen:
		return  # a newer load was started while we awaited; abort

	var sun: Node = get_tree().get_nodes_in_group("sun_planet").front()
	if not sun:
		push_error("No sun found")
		return

	for i in range(planets_data.size()):
		var pd = planets_data[i]
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
		planet.planet_idx            = i  # must be set before add_child so _ready() seeds name correctly
		add_child(planet)
		_planet_by_idx[i] = planet
		planet.position = Vector2(float(pd.get("pos_x", 0.0)), float(pd.get("pos_y", 0.0)))
		planet.apply_appearance()
		var vel := Vector2(float(pd.get("vel_x", 0.0)), float(pd.get("vel_y", 0.0)))
		_velocities[planet.get_instance_id()] = vel

	_session_time = 0.0
	if not _is_mp:
		_session_end_wall = 0.0
	_running = false
	GameConfig.game_running = false
	_update_timebar()
	if _start_btn:
		_start_btn.text = "▶ Start"
	_bake_traj()

var _countdown_active: bool = false
var _start_at_wall:    float = 0.0   # wall-clock Unix time when game should start

func _on_start_pressed(countdown_seconds: int = 10) -> void:
	if _countdown_active:
		return
	if not _running:
		if _start_btn:
			_start_btn.text = "..."
			_start_btn.disabled = true
		if _start_at_wall == 0.0:
			_start_at_wall = Time.get_unix_time_from_system() + countdown_seconds
		_run_countdown()
	else:
		_running = false
		GameConfig.game_running = false
		if _start_btn:
			_start_btn.text = "▶ Resume"
			_start_btn.disabled = false

# Cosmetic only — game state is driven by _process watching _start_at_wall.
func _run_countdown() -> void:
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

	var last_n:    int   = -1
	var n_born_at: float = 0.0
	var rise_px:   float = 80.0

	while true:
		var now:       float = Time.get_unix_time_from_system()
		var remaining: float = _start_at_wall - now
		if remaining <= 0.0 or _running:
			break
		var n: int = int(ceil(remaining))
		if n != last_n:
			last_n    = n
			n_born_at = now
			lbl.text  = str(n)
		var age:    float = now - n_born_at
		var ease_t: float = 1.0 - pow(1.0 - minf(age / 0.6, 1.0), 2.0)
		lbl.modulate.a    = ease_t
		lbl.offset_top    = rise_px * (1.0 - ease_t)
		lbl.offset_bottom = lbl.offset_top
		await get_tree().process_frame

	cl.queue_free()
	_countdown_active = false

func _do_game_start() -> void:
	if _session_end_wall == 0.0:
		_session_end_wall = Time.get_unix_time_from_system() + _session_duration
	if _sim_start_wall == 0.0:
		_sim_start_wall = _session_end_wall - _session_duration
	# Init step counter to already-elapsed steps so planets jump to correct
	# position instantly rather than lurching from step 0.
	var elapsed: float = maxf(0.0, Time.get_unix_time_from_system() - _sim_start_wall)
	_total_sim_steps = int(elapsed / SIM_STEP)
	_start_at_wall = 0.0
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
	# In multiplayer, only the host runs collision detection and broadcasts results.
	# Non-hosts apply collisions via the "planet_collision" game event.
	if _is_mp and not NetManager.is_host:
		return
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
				var impulses: Array = []
				for k in range(bodies.size()):
					var c: Dictionary = bodies[k]
					if c.anchor or c.node == a.node or c.node == b.node:
						continue
					var to_c: Vector2 = c.pos - mid
					var d: float = to_c.length()
					if d < blast_r and d > 1.0:
						var falloff: float = 1.0 - (d / blast_r)
						var impulse: Vector2 = to_c.normalized() * blast_str * falloff / (c.mass + 1.0)
						_velocities[c.id] = _velocities.get(c.id, Vector2.ZERO) + impulse
						var pidx_c: int = int(c.node.get("planet_idx") if c.node.get("planet_idx") != null else -1)
						if pidx_c >= 0:
							impulses.append({"i": pidx_c, "vx": impulse.x, "vy": impulse.y})
				if not bool(a.node.get("is_sun")):
					to_remove.append(a.node)
				if not bool(b.node.get("is_sun")):
					to_remove.append(b.node)
				if _is_mp:
					var pidx_a: int = int(a.node.get("planet_idx") if a.node.get("planet_idx") != null else -1)
					var pidx_b: int = int(b.node.get("planet_idx") if b.node.get("planet_idx") != null else -1)
					var destroyed: Array = []
					if not bool(a.node.get("is_sun")) and pidx_a >= 0:
						destroyed.append(pidx_a)
					if not bool(b.node.get("is_sun")) and pidx_b >= 0:
						destroyed.append(pidx_b)
					ColyseusSync.send_game_event("planet_collision", {
						"destroyed": destroyed,
						"mid_x":     mid.x,
						"mid_y":     mid.y,
						"max_radius": blast_r,
						"impulses":  impulses,
					})
	for node in to_remove:
		if is_instance_valid(node):
			_velocities.erase(node.get_instance_id())
			var pidx: int = int(node.get("planet_idx") if node.get("planet_idx") != null else -1)
			if pidx >= 0:
				_planet_by_idx.erase(pidx)
			var tyc: Variant = node.get("team_yield_counts")
			if tyc is Dictionary:
				for tid: int in (tyc as Dictionary).keys():
					if node.has_signal("team_yield_updated"):
						node.emit_signal("team_yield_updated", tid, 0)
				node.set("team_yield_counts", {})
				node.set("yield_count", 0)
				if node.has_signal("yield_updated"):
					node.emit_signal("yield_updated", 0)
				if node.has_signal("tax_updated"):
					node.emit_signal("tax_updated")
			node.queue_free()

# ── Physics process — planet positions updated here so ships read fresh pos same tick ──
func _physics_process(delta: float) -> void:
	if not _running:
		return

	# Wall-clock-based stepping keeps all clients at the same simulation step.
	# _sim_start_wall is derived from the server-dictated startAt, so it's identical
	# on every client regardless of frame rate or countdown timing jitter.
	var steps_this_frame: int
	if _sim_start_wall > 0.0:
		var elapsed: float = Time.get_unix_time_from_system() - _sim_start_wall
		var target: int = int(elapsed / SIM_STEP)
		steps_this_frame = clampi(target - _total_sim_steps, 0, 8)
	else:
		# Fallback for local/dev mode (no server startAt)
		_sim_accumulator += delta
		steps_this_frame = 0
		while _sim_accumulator >= SIM_STEP:
			_sim_accumulator -= SIM_STEP
			steps_this_frame += 1
		steps_this_frame = min(steps_this_frame, 8)

	for _s in range(steps_this_frame):
		_total_sim_steps += 1
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
	# Pre-game: keep free cam locked on local ship unless user has panned
	if _pre_game and not _user_panned and is_instance_valid(_free_cam) and _free_cam.enabled:
		for ship in get_tree().get_nodes_in_group("players"):
			if is_instance_valid(ship) and bool(ship.get("is_local")):
				_free_cam.global_position = ship.global_position
				break

	if _start_at_wall > 0.0 and not _running and Time.get_unix_time_from_system() >= _start_at_wall:
		_do_game_start()

	if not _running:
		return

	if _is_mp and NetManager.is_host:
		_planet_broadcast_timer += delta
		if _planet_broadcast_timer >= 1.0:
			_planet_broadcast_timer = 0.0
			_broadcast_planet_positions()

	# Update explosions
	for exp in _explosions:
		exp.radius += exp.max_radius * 2.2 * delta
		exp.alpha = max(0.0, 1.0 - (exp.radius / exp.max_radius))
	_explosions = _explosions.filter(func(e): return e.alpha > 0.0 and e.radius < e.max_radius)

	var remaining: float = _session_end_wall - Time.get_unix_time_from_system()
	_session_time = clampf(_session_duration - remaining, 0.0, _session_duration)
	_update_timebar()
	if remaining <= 0.0:
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

	# Transparent hit zone over timebar for hover preview
	var tb_hit := ColorRect.new()
	tb_hit.color = Color.TRANSPARENT
	tb_hit.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	tb_hit.custom_minimum_size = Vector2(0, 16)
	tb_hit.mouse_filter = Control.MOUSE_FILTER_STOP
	_session_cl.add_child(tb_hit)
	tb_hit.mouse_exited.connect(func(): _set_ghosts_visible(false))
	tb_hit.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseMotion and not _running and not GameConfig.game_running:
			_timebar_hover_pct = clamp(ev.position.x / tb_hit.size.x, 0.0, 1.0)
			_update_ghost_preview())

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

var _game_over:   bool = false
var _pre_game:    bool = false
var _pan_last:    Vector2 = Vector2.ZERO
var _panning:     bool = false
var _user_panned: bool = false
var _free_cam:    Camera2D = null

# ── Trajectory preview ────────────────────────────────────────────────────────
const _BAKE_DT          := 1.0   # seconds per keyframe — matches mapmaker TRAJ_DT
const _BAKE_STEPS_PER_FRAME := 16  # keyframes computed per deferred frame

var _bake_gen:          int   = 0    # incremented on each new bake; aborts stale ones
var _traj_table:        Array = []   # [{time, positions: {pid→Vector2}}]
var _ghost_sprites:     Array = []   # Sprite2D ghost nodes, one per non-sun planet
var _timebar_hover_pct: float = 0.0

func _bake_traj() -> void:
	_bake_gen += 1
	var my_gen := _bake_gen
	_traj_table.clear()
	_set_ghosts_visible(false)

	var bodies: Array = []
	for planet in get_tree().get_nodes_in_group("planets"):
		if not is_instance_valid(planet):
			continue
		var pid := planet.get_instance_id()
		bodies.append({
			"id":     pid,
			"pos":    Vector2(planet.position),
			"vel":    Vector2(_velocities.get(pid, Vector2.ZERO)),
			"mass":   float(planet.mass),
			"anchor": _is_anchor(planet),
			"acc":    Vector2.ZERO,
		})

	var total_steps := int(ceil(_session_duration / _BAKE_DT)) + 1
	for step in range(total_steps):
		var positions: Dictionary = {}
		for b in bodies:
			positions[b.id] = Vector2(b.pos)
		_traj_table.append({"time": step * _BAKE_DT, "positions": positions})
		_nbody_step(bodies, _BAKE_DT)
		if step % _BAKE_STEPS_PER_FRAME == 0:
			await get_tree().process_frame
			if _bake_gen != my_gen:
				return
	if _bake_gen == my_gen:
		_build_ghost_sprites()

func _build_ghost_sprites() -> void:
	for g in _ghost_sprites:
		if is_instance_valid(g):
			g.queue_free()
	_ghost_sprites.clear()
	for planet in get_tree().get_nodes_in_group("planets"):
		if not is_instance_valid(planet) or planet.get("is_sun"):
			continue
		var outline = planet.get("outline_sprite")
		if not outline or not is_instance_valid(outline):
			continue
		var ghost := Sprite2D.new()
		ghost.texture  = (outline as Sprite2D).texture
		ghost.scale    = (outline as Sprite2D).scale
		ghost.rotation = (outline as Sprite2D).rotation
		if (outline as Sprite2D).material:
			ghost.material = (outline as Sprite2D).material.duplicate()
		ghost.modulate = Color(1.0, 1.0, 1.0, 0.5)
		ghost.z_index  = -1
		ghost.visible  = false
		ghost.set_meta("planet_id", planet.get_instance_id())
		add_child(ghost)
		_ghost_sprites.append(ghost)

func _set_ghosts_visible(v: bool) -> void:
	for g in _ghost_sprites:
		if is_instance_valid(g):
			g.visible = v

func _update_ghost_preview() -> void:
	if _traj_table.size() < 2 or _ghost_sprites.is_empty():
		return
	if _running or GameConfig.game_running:
		_set_ghosts_visible(false)
		return
	var t    := (1.0 - _timebar_hover_pct) * _session_duration
	var idx  := clampi(int(t / _BAKE_DT), 0, _traj_table.size() - 2)
	var kf0: Dictionary = _traj_table[idx]
	var kf1: Dictionary = _traj_table[idx + 1]
	var f    := (t - float(kf0.time)) / _BAKE_DT
	for ghost in _ghost_sprites:
		if not is_instance_valid(ghost):
			continue
		var pid: int = ghost.get_meta("planet_id", -1)
		if not kf0.positions.has(pid) or not kf1.positions.has(pid):
			ghost.visible = false
			continue
		ghost.position = (kf0.positions[pid] as Vector2).lerp(kf1.positions[pid] as Vector2, f)
		ghost.visible  = true

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
			var f: float = minf(event.factor if event.factor > 0.0 else 1.0, 2.0)
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				cam.zoom = (cam.zoom * (1.0 + 0.04 * f)).clamp(Vector2(0.01, 0.01), Vector2(16.0, 16.0))
				get_viewport().set_input_as_handled()
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				cam.zoom = (cam.zoom * (1.0 - 0.04 * f)).clamp(Vector2(0.01, 0.01), Vector2(16.0, 16.0))
				get_viewport().set_input_as_handled()

	if event is InputEventKey and event.pressed and not event.echo:
		var cam := _get_active_cam()
		if cam:
			if event.physical_keycode == KEY_EQUAL:
				cam.zoom *= 1.1
				get_viewport().set_input_as_handled()
			elif event.physical_keycode == KEY_MINUS:
				cam.zoom *= 0.9
				get_viewport().set_input_as_handled()

	# Panning: pre-game uses free cam; game-over uses ship cam
	if _pre_game:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			_panning = event.pressed
		elif event is InputEventMouseMotion and _panning and is_instance_valid(_free_cam):
			_free_cam.global_position -= event.relative / _free_cam.zoom.x
			_user_panned = true
		return

	# Gameplay + game-over: left-drag pans via camera offset (ship still tracked)
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_panning = event.pressed
	elif event is InputEventMouseMotion and _panning:
		var cam: Camera2D = _get_active_cam()
		if cam:
			cam.offset -= event.relative / cam.zoom.x

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

# ── Remote game events ────────────────────────────────────────────────────────
func _on_remote_game_event(etype: String, data: Dictionary) -> void:
	match etype:
		"cell_placed":
			_handle_remote_cell_placed(data)
		"crops_collected":
			_handle_remote_crops_collected(data)
		"tax_rate_set":
			_handle_remote_tax_rate_set(data)
		"planet_positions":
			if not NetManager.is_host:
				_handle_remote_planet_positions(data)
		"planet_collision":
			if not NetManager.is_host:
				_handle_remote_planet_collision(data)

func _handle_remote_cell_placed(data: Dictionary) -> void:
	var pidx: int       = int(data.get("planet_idx", -1))
	var hex_key: String = str(data.get("hex_key", ""))
	var action: int     = int(data.get("action", 0))
	var team: int       = int(data.get("team_id", 0))
	if pidx < 0 or hex_key.is_empty():
		return
	if not _planet_by_idx.has(pidx):
		return
	var planet: Node = _planet_by_idx[pidx]
	if not is_instance_valid(planet):
		_planet_by_idx.erase(pidx)
		return
	GameConfig.use_team_move(team)
	planet.team_id = team
	if not hex_key in planet.claimed_nodes:
		planet.claimed_nodes.append(hex_key)
	var parts := hex_key.split(",")
	planet.place_sprite_and_fill(
		Vector2(int(parts[0]), int(parts[1])),
		action
	)
	if data.has("placed_at_sim_time") and planet.grid.has(hex_key):
		planet.grid[hex_key]["animation_start_time"] = _sim_start_wall + float(data.get("placed_at_sim_time", 0.0))
	if action == 2:  # CULTIVATED
		planet.check_for_triangles()
	elif action == 1:  # CLAIMED
		var new_dominant: int = planet._get_dominant_team_id()
		if new_dominant != planet.dominant_team_id:
			planet.dominant_team_id = new_dominant
			planet.tax_rate = 5
	planet.queue_redraw()
	planet.emit_signal("moves_updated", GameConfig.get_team_moves(team))

func _handle_remote_crops_collected(data: Dictionary) -> void:
	var pidx: int = int(data.get("planet_idx", -1))
	var tid: int  = int(data.get("team_id", 0))
	if pidx < 0 or not _planet_by_idx.has(pidx):
		return
	var planet: Node = _planet_by_idx[pidx]
	if not is_instance_valid(planet):
		return
	planet.team_yield_counts.erase(tid)
	planet.team_tax_paid.erase(tid)
	planet.team_tax_earned.erase(tid)
	planet.team_tax_earned_per_source.erase(tid)
	planet.yield_count = 0
	for t in planet.team_yield_counts:
		planet.yield_count += planet.team_yield_counts[t]
	planet.emit_signal("yield_updated", planet.yield_count)
	planet.emit_signal("team_yield_updated", tid, 0)
	planet.emit_signal("tax_updated")

func _handle_remote_tax_rate_set(data: Dictionary) -> void:
	var pidx: int = int(data.get("planet_idx", -1))
	var rate: int = int(data.get("tax_rate", 5))
	if pidx < 0 or not _planet_by_idx.has(pidx):
		return
	var planet: Node = _planet_by_idx[pidx]
	if not is_instance_valid(planet):
		return
	planet.tax_rate = rate
	planet.emit_signal("tax_updated")

func _handle_remote_planet_collision(data: Dictionary) -> void:
	var mid: Vector2 = Vector2(float(data.get("mid_x", 0.0)), float(data.get("mid_y", 0.0)))
	var blast_r: float = float(data.get("max_radius", 400.0))
	_explosions.append({"pos": mid, "radius": 0.0, "max_radius": blast_r, "alpha": 1.0})
	for imp in (data.get("impulses", []) as Array):
		var pidx: int = int(imp.get("i", -1))
		if pidx < 0 or not _planet_by_idx.has(pidx):
			continue
		var planet: Node = _planet_by_idx[pidx]
		if not is_instance_valid(planet):
			continue
		var impulse: Vector2 = Vector2(float(imp.get("vx", 0.0)), float(imp.get("vy", 0.0)))
		_velocities[planet.get_instance_id()] = _velocities.get(planet.get_instance_id(), Vector2.ZERO) + impulse
	for pidx_raw in (data.get("destroyed", []) as Array):
		var pidx: int = int(pidx_raw)
		if not _planet_by_idx.has(pidx):
			continue
		var planet: Node = _planet_by_idx[pidx]
		_planet_by_idx.erase(pidx)
		if not is_instance_valid(planet):
			continue
		_velocities.erase(planet.get_instance_id())
		var tyc: Variant = planet.get("team_yield_counts")
		if tyc is Dictionary:
			for tid: int in (tyc as Dictionary).keys():
				if planet.has_signal("team_yield_updated"):
					planet.emit_signal("team_yield_updated", tid, 0)
			planet.set("team_yield_counts", {})
			planet.set("yield_count", 0)
			if planet.has_signal("yield_updated"):
				planet.emit_signal("yield_updated", 0)
			if planet.has_signal("tax_updated"):
				planet.emit_signal("tax_updated")
		planet.queue_free()

func _handle_remote_planet_positions(data: Dictionary) -> void:
	var positions: Array = data.get("positions", [])
	for pdata in positions:
		var pidx: int = int(pdata.get("i", -1))
		if pidx < 0 or not _planet_by_idx.has(pidx):
			continue
		var planet: Node = _planet_by_idx[pidx]
		if not is_instance_valid(planet):
			continue
		_velocities[planet.get_instance_id()] = Vector2(float(pdata.get("vx", 0.0)), float(pdata.get("vy", 0.0)))

func _broadcast_planet_positions() -> void:
	var positions: Array = []
	for planet in get_tree().get_nodes_in_group("planets"):
		if not is_instance_valid(planet) or planet.get("is_sun"):
			continue
		var pidx: int = int(planet.get("planet_idx") if planet.get("planet_idx") != null else -1)
		if pidx < 0:
			continue
		var vel: Vector2 = _velocities.get(planet.get_instance_id(), Vector2.ZERO)
		positions.append({
			"i":  pidx,
			"x":  planet.position.x,
			"y":  planet.position.y,
			"vx": vel.x,
			"vy": vel.y,
		})
	if not positions.is_empty():
		ColyseusSync.send_game_event("planet_positions", {"positions": positions})

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
	var cm := get_tree().get_first_node_in_group("camera_manager")
	if cm and cm.has_method("refresh_players"):
		cm.call("refresh_players")

func _toggle_mp_pregame() -> void:
	if _running or _countdown_active:
		return
	_pre_game = not _pre_game
	_user_panned = false
	_panning = false
	if _pre_game:
		_free_cam.zoom = _get_active_cam().zoom if _get_active_cam() else Vector2(0.6, 0.6)
		_center_free_cam()
		_free_cam.enabled = true
		for ship in get_tree().get_nodes_in_group("players"):
			if is_instance_valid(ship):
				var cam: Camera2D = ship.get_node_or_null("Camera2D") as Camera2D
				if cam:
					cam.enabled = false
		if is_instance_valid(_mp_pregame_btn):
			_mp_pregame_btn.text = "← Exit Pre-game"
	else:
		_free_cam.enabled = false
		for ship in get_tree().get_nodes_in_group("players"):
			if is_instance_valid(ship) and bool(ship.get("is_local")):
				var cam: Camera2D = ship.get_node_or_null("Camera2D") as Camera2D
				if cam:
					cam.zoom = _free_cam.zoom
					cam.offset = Vector2.ZERO
					cam.enabled = true
		if is_instance_valid(_mp_pregame_btn):
			_mp_pregame_btn.text = "Simulate Pre-game"

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
