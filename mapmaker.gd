extends Node2D

# ── Constants ─────────────────────────────────────────────────────────────────
const G               := 80.0 * 2.0 * 100.0   # scaled for Godot world units (orbits ~2400-9200 wu)
const SUBSTEPS        := 4
const TRAJ_STEPS      := 300
const TRAJ_DT         := 1.0    # 1s per step = 300s total preview
const SIM_STEP        := 0.016   # fixed physics timestep for live sim
const VELOCITY_SCALE  := 1.5    # world-units of drag per wu/s of velocity

var _sim_duration: float = 60.0
var _sim_speed: float = 1.0

@export var planet_scene: PackedScene

# ── State ─────────────────────────────────────────────────────────────────────
enum Mode { IDLE, DRAGGING, SELECTED }
var _mode: Mode = Mode.IDLE

var _cam: Camera2D
var _is_panning: bool = false

var _selected: Node = null
var _drag_start: Vector2

# Per-planet velocity storage (instance_id → Vector2)
# We freeze all RigidBody2D planets and drive them manually
var _velocities: Dictionary = {}
var _init_positions: Dictionary = {}   # instance_id → initial Vector2 position
var _init_velocities: Dictionary = {}  # instance_id → initial Vector2 velocity

# Full planet snapshots for reset — stores all planet data so destroyed ones can be re-created
# Array of {pos, vel, mass, current_size, color_idx, is_sun}
var _planet_snapshots: Array = []

var _sim_accumulator: float = 0.0

# Explosion rings: [{pos, radius, max_radius, alpha}]
var _explosions: Array = []

# Trajectory preview
var _traj_points: Array = []
var _traj_dirty: bool = true
var _traj_planet_id: int = -1   # which planet the trajectory is for
var _hovered: Node = null       # planet under mouse

# Timebar
var _sim_time: float = 0.0
var _running: bool = false
var _timebar: ColorRect = null
var _timebar_fill: ColorRect = null
var _time_label: Label = null
var _play_btn: Button = null
var _manual_editing: bool = false
var _hint_label: Label = null

# Inspector refs
var _inspector: Control
var _size_slider: HSlider
var _mass_slider: HSlider
var _color_option: OptionButton

# ── Ready ─────────────────────────────────────────────────────────────────────
func _ready() -> void:
	_cam = Camera2D.new()
	_cam.enabled = true
	_cam.zoom = Vector2(0.5, 0.5)
	add_child(_cam)
	_build_ui()
	_spawn_default_system()

# ── Default solar system ──────────────────────────────────────────────────────
func _spawn_default_system() -> void:
	if not planet_scene:
		return
	# Sun — static anchor
	var sun := planet_scene.instantiate()
	sun.is_sun = true
	add_child(sun)
	sun.position = Vector2.ZERO
	sun.mass = 18000.0
	_register_planet(sun, Vector2.ZERO)

	# [color_idx, orbit_r, angle_rad, cells, mass]
	var bodies := [
		[3,  4800.0,  0.7,  5,   30.0],
		[4,  7600.0,  2.1,  8,   80.0],
		[2,  10400.0, 4.0,  9,  100.0],
		[6,  13600.0, 1.3,  7,   60.0],
		[0,  18400.0, 5.5, 18, 2000.0],
	]
	for b in bodies:
		var col_idx: int   = b[0]
		var orbit_r: float = b[1]
		var angle_r: float = b[2]
		var cells: int     = b[3]
		var mass_v: float  = b[4]
		var speed: float   = sqrt(G * 18000.0 / orbit_r)
		var p := planet_scene.instantiate()
		p.editing_mode = true
		p.current_size = cells
		p.mass = mass_v
		p.planet_color_index = col_idx
		p.freeze = true
		p.freeze_mode = RigidBody2D.FREEZE_MODE_STATIC
		add_child(p)
		p.position = Vector2(cos(angle_r) * orbit_r, sin(angle_r) * orbit_r)
		p.apply_appearance()
		var vel := Vector2(-sin(angle_r), cos(angle_r)) * speed
		_register_planet(p, vel)

# ── Seed generation ───────────────────────────────────────────────────────────
# Color index → [multiplier_weight, base_cells_range]
# Higher weight = rarer. Cells inversely scaled with value.
const _COLOR_TABLE := [
	# [color_idx, weight, min_cells, max_cells]
	[0, 1, 4,  10],   # Sapphire  ×7 — rare, small
	[1, 2, 5,  14],   # Green     ×6
	[2, 3, 6,  18],   # Bluegreen ×5
	[3, 4, 8,  22],   # Grey      ×4
	[4, 5, 10, 28],   # Gold      ×3
	[5, 6, 12, 35],   # Pink      ×2
	[6, 7, 15, 45],   # Red       ×1 — common, large
]

# Orbital ring definitions: [radius, max_planets_in_ring]
# Max planets = floor(2π*r / min_safe_gap) where min_safe_gap ≈ 1800wu
const _RINGS := [
	[4800.0,  8],
	[7600.0,  13],
	[10400.0, 18],
	[13600.0, 23],
	[18400.0, 32],
	[24000.0, 41],
	[30000.0, 52],
	[38000.0, 66],
]

func generate_from_seed(seed_val: int) -> void:
	# ── Phase 1: Pure RNG — generate all planet data deterministically ────────
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val

	var planet_count: int = _weighted_int(rng, 5, 30, 8, 16)

	var ring_counts: Array = []
	for _r in _RINGS:
		ring_counts.append(0)
	var ring_assignments: Array = []
	for _i in range(planet_count):
		var ring_idx: int = _pick_ring(rng, ring_counts)
		ring_assignments.append(ring_idx)
		ring_counts[ring_idx] += 1
	ring_assignments.sort()

	var ecc_types: Array = []
	for _i in range(planet_count):
		var roll: float = rng.randf()
		if roll < 0.70:
			ecc_types.append(0)
		elif roll < 0.90:
			ecc_types.append(1)
		else:
			ecc_types.append(2)

	var ring_angles: Array = []
	for _r in _RINGS:
		ring_angles.append([])

	var placed_positions: Array = [Vector2.ZERO]
	var planet_data: Array = []   # fully computed, no RNG after this

	for i in range(planet_count):
		var ring_idx: int = ring_assignments[i]
		var base_r: float = _RINGS[ring_idx][0]
		var ecc_type: int = ecc_types[i]

		var angle: float = _safe_angle(rng, ring_angles[ring_idx], ring_idx)
		ring_angles[ring_idx].append(angle)

		# Always consume same RNG calls regardless of ecc_type (determinism)
		var r_off_a: float = rng.randf_range(-base_r * 0.10, base_r * 0.10)
		var r_off_b: float = rng.randf_range(-base_r * 0.20, base_r * 0.20)
		var r_offset: float = 0.0
		match ecc_type:
			1: r_offset = r_off_a
			2: r_offset = r_off_b
		var orbit_r: float = base_r + r_offset

		var ring_factor: float = 1.0 + float(ring_idx) * 0.25
		var circ_speed: float = sqrt(G * 18000.0 / orbit_r)
		var sm_a: float = rng.randf_range(0.94, 1.0 + 0.15 * ring_factor)
		var sm_b: float = rng.randf_range(0.80, 1.0 + 0.45 * ring_factor)
		var speed_mult: float = 1.0
		match ecc_type:
			1: speed_mult = sm_a
			2: speed_mult = sm_b
		var speed: float = circ_speed * speed_mult

		var color_entry: Array = _pick_color(rng)
		var col_idx: int = color_entry[0]
		var cells: int = rng.randi_range(color_entry[2], color_entry[3])
		var mass_v: float = rng.randf_range(20.0, 30.0) + cells * rng.randf_range(3.0, 8.0)

		# Resonance — consume RNG regardless of whether we use it (keeps sequence stable)
		var res_roll: float = rng.randf()
		var res_r: float = _resonant_radius(rng, base_r)
		if res_roll < 0.2:
			var res_pos := Vector2(cos(angle) * res_r, sin(angle) * res_r)
			if _position_is_safe(res_pos, placed_positions, 1200.0):
				orbit_r = res_r
				speed = sqrt(G * 18000.0 / orbit_r)

		var spawn_pos := Vector2(cos(angle) * orbit_r, sin(angle) * orbit_r)
		if spawn_pos.length() < 2500.0:
			continue
		if not _position_is_safe(spawn_pos, placed_positions.slice(1), 1000.0):
			continue

		placed_positions.append(spawn_pos)
		planet_data.append({
			"pos":       spawn_pos,
			"vel":       Vector2(-sin(angle), cos(angle)) * speed,
			"cells":     cells,
			"mass":      mass_v,
			"color_idx": col_idx,
		})

	# ── Phase 2: Scene operations — no more RNG calls ─────────────────────────
	for planet in get_tree().get_nodes_in_group("planets"):
		if is_instance_valid(planet) and not planet.get("is_sun"):
			_velocities.erase(planet.get_instance_id())
			_init_positions.erase(planet.get_instance_id())
			_init_velocities.erase(planet.get_instance_id())
			planet.queue_free()
	await get_tree().process_frame

	for d in planet_data:
		if not planet_scene:
			continue
		var p := planet_scene.instantiate()
		p.editing_mode = true
		p.current_size = d.cells
		p.mass = d.mass
		p.planet_color_index = d.color_idx
		p.freeze = true
		p.freeze_mode = RigidBody2D.FREEZE_MODE_STATIC
		add_child(p)
		p.position = d.pos
		p.apply_appearance()
		_register_planet(p, d.vel)

	_rebuild_snapshots()
	_reset_positions()

# ── Seed helpers ──────────────────────────────────────────────────────────────

func _export_json() -> void:
	var planets_data: Array = []
	for snap in _planet_snapshots:
		if snap.is_sun:
			continue
		planets_data.append({
			"pos_x":     snap.pos.x,
			"pos_y":     snap.pos.y,
			"vel_x":     snap.vel.x,
			"vel_y":     snap.vel.y,
			"mass":      snap.mass,
			"size":      snap.size,
			"color_idx": snap.color_idx,
		})
	var json_str: String = JSON.stringify({"planets": planets_data}, "\t")
	DisplayServer.clipboard_set(json_str)
	print("Map copied to clipboard (%d planets)" % planets_data.size())
	if OS.get_name() == "Web":
		var js_safe := json_str.replace("\\", "\\\\").replace("`", "\\`")
		JavaScriptBridge.eval("window.parent.postMessage({type:'mapExport',json:`" + js_safe + "`},'*')")

func _reset_positions() -> void:
	# Lightweight reset — restores positions/velocities without destroying planets
	_running = false
	_sim_time = 0.0
	_sim_accumulator = 0.0
	_explosions.clear()
	if _play_btn:
		_play_btn.text = "▶ Play"
	for planet in get_tree().get_nodes_in_group("planets"):
		if not is_instance_valid(planet):
			continue
		var id: int = planet.get_instance_id()
		if _init_positions.has(id):
			planet.position = _init_positions[id]
		if _init_velocities.has(id):
			_velocities[id] = _init_velocities[id]
	_update_timebar()
	_traj_dirty = true

func _position_is_safe(pos: Vector2, placed: Array, min_dist: float) -> bool:
	for p in placed:
		if pos.distance_to(p) < min_dist:
			return false
	return true

func _weighted_int(rng: RandomNumberGenerator, lo: int, hi: int, sweet_lo: int, sweet_hi: int) -> int:
	# 70% chance of landing in sweet spot, 30% anywhere in full range
	if rng.randf() < 0.70:
		return rng.randi_range(sweet_lo, sweet_hi)
	return rng.randi_range(lo, hi)

func _pick_ring(rng: RandomNumberGenerator, counts: Array) -> int:
	# Weight: inner rings slightly preferred, but cap at max_planets
	var weights: Array = []
	for i in range(_RINGS.size()):
		var max_p: int = _RINGS[i][1]
		if counts[i] >= max_p:
			weights.append(0.0)
		else:
			# Prefer inner rings but allow outer — weight decays with index
			var base_w: float = 1.0 / (1.0 + i * 0.3)
			weights.append(base_w)
	var total: float = 0.0
	for w in weights:
		total += w
	var roll: float = rng.randf() * total
	var acc: float = 0.0
	for i in range(weights.size()):
		acc += weights[i]
		if roll <= acc:
			return i
	return 0

func _safe_angle(rng: RandomNumberGenerator, used_angles: Array, ring_idx: int) -> float:
	# Minimum angular separation based on ring circumference and max planets
	var min_sep: float = TAU / float(_RINGS[ring_idx][1]) * 0.8
	var attempts := 0
	while attempts < 50:
		var angle: float = rng.randf() * TAU
		var safe := true
		for a in used_angles:
			var diff: float = abs(fmod(angle - a + TAU * 1.5, TAU) - TAU * 0.5)
			if diff < min_sep:
				safe = false
				break
		if safe:
			return angle
		attempts += 1
	# Fallback: evenly space
	return used_angles.size() * (TAU / float(_RINGS[ring_idx][1]))

func _pick_color(rng: RandomNumberGenerator) -> Array:
	var total_weight: float = 0.0
	for entry in _COLOR_TABLE:
		total_weight += entry[1]
	var roll: float = rng.randf() * total_weight
	var acc: float = 0.0
	for entry in _COLOR_TABLE:
		acc += entry[1]
		if roll <= acc:
			return entry
	return _COLOR_TABLE[_COLOR_TABLE.size() - 1]

func _resonant_radius(rng: RandomNumberGenerator, base_r: float) -> float:
	# Snap to a radius that creates a simple orbital resonance with base_r
	# T ∝ r^1.5, so resonance ratio k means r_new = base_r * k^(2/3)
	var ratios := [1.333, 1.587, 0.794, 0.630, 2.0, 0.5]
	var ratio: float = ratios[rng.randi() % ratios.size()]
	return base_r * ratio

# ── UI ────────────────────────────────────────────────────────────────────────
func _build_ui() -> void:
	var cl := CanvasLayer.new()
	add_child(cl)

	# Timebar
	var tb_bg := ColorRect.new()
	tb_bg.color = Color(0.13, 0.14, 0.16)
	tb_bg.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	tb_bg.custom_minimum_size = Vector2(0, 6)
	tb_bg.mouse_filter = Control.MOUSE_FILTER_STOP
	cl.add_child(tb_bg)
	_timebar = tb_bg

	_timebar_fill = ColorRect.new()
	_timebar_fill.color = Color(0.29, 0.50, 1.0)
	_timebar_fill.set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	_timebar_fill.size.x = 0
	tb_bg.add_child(_timebar_fill)
	tb_bg.gui_input.connect(_on_timebar_input)

	# Topbar
	var topbar := HBoxContainer.new()
	topbar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	topbar.offset_top = 6
	topbar.custom_minimum_size = Vector2(0, 36)
	topbar.add_theme_constant_override("separation", 8)
	cl.add_child(topbar)

	var pad := Control.new()
	pad.custom_minimum_size = Vector2(8, 0)
	topbar.add_child(pad)

	_play_btn = Button.new()
	_play_btn.text = "▶ Play"
	_play_btn.custom_minimum_size = Vector2(70, 0)
	_play_btn.pressed.connect(_on_play_pressed)
	topbar.add_child(_play_btn)

	var reset_btn := Button.new()
	reset_btn.text = "↺"
	reset_btn.pressed.connect(_on_reset_pressed)
	topbar.add_child(reset_btn)

	# Seed input + generate button
	var seed_lbl := Label.new()
	seed_lbl.text = "Seed"
	seed_lbl.add_theme_font_size_override("font_size", 12)
	topbar.add_child(seed_lbl)

	var seed_input := LineEdit.new()
	seed_input.text = "1337"
	seed_input.custom_minimum_size = Vector2(80, 0)
	seed_input.placeholder_text = "seed"
	topbar.add_child(seed_input)

	var gen_btn := Button.new()
	gen_btn.text = "Generate"
	gen_btn.pressed.connect(func():
		var val: int = int(seed_input.text) if seed_input.text.is_valid_int() else 0
		generate_from_seed(val))
	topbar.add_child(gen_btn)

	var rand_btn := Button.new()
	rand_btn.text = "🎲"
	rand_btn.tooltip_text = "Random seed"
	rand_btn.pressed.connect(func():
		var val: int = randi()
		seed_input.text = str(val)
		generate_from_seed(val))
	topbar.add_child(rand_btn)

	# copy_btn hidden per design
	# var copy_btn := Button.new() ...

	# Export JSON button
	var export_btn := Button.new()
	export_btn.text = "Export JSON"
	export_btn.pressed.connect(_export_json)
	topbar.add_child(export_btn)

	# Manual editing toggle — bottom left
	var edit_cl := CanvasLayer.new()
	add_child(edit_cl)
	var edit_btn := Button.new()
	edit_btn.text = "Manual Edit (Beta)"
	edit_btn.toggle_mode = true
	edit_btn.button_pressed = false
	edit_btn.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, 12)
	edit_btn.toggled.connect(func(on: bool):
		_manual_editing = on
		if _hint_label:
			_hint_label.visible = on
		if not on:
			_deselect()
			_traj_points.clear())
	edit_cl.add_child(edit_btn)

	_time_label = Label.new()
	_time_label.text = "0.0 / 60 s"
	_time_label.add_theme_font_size_override("font_size", 12)
	_time_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	topbar.add_child(_time_label)

	# Speed multiplier
	var spd_lbl := Label.new()
	spd_lbl.text = "Speed"
	spd_lbl.add_theme_font_size_override("font_size", 12)
	topbar.add_child(spd_lbl)

	var spd_slider := HSlider.new()
	spd_slider.min_value = 0.1
	spd_slider.max_value = 10.0
	spd_slider.step = 0.1
	spd_slider.value = 1.0
	spd_slider.custom_minimum_size = Vector2(80, 0)
	topbar.add_child(spd_slider)

	var spd_val_lbl := Label.new()
	spd_val_lbl.text = "1.0×"
	spd_val_lbl.add_theme_font_size_override("font_size", 12)
	spd_val_lbl.custom_minimum_size = Vector2(36, 0)
	topbar.add_child(spd_val_lbl)

	spd_slider.value_changed.connect(func(v: float):
		_sim_speed = v
		spd_val_lbl.text = "%.1f×" % v)

	# Total duration
	var dur_lbl := Label.new()
	dur_lbl.text = "Dur"
	dur_lbl.add_theme_font_size_override("font_size", 12)
	topbar.add_child(dur_lbl)

	var dur_input := LineEdit.new()
	dur_input.text = "60"
	dur_input.custom_minimum_size = Vector2(52, 0)
	dur_input.placeholder_text = "s"
	topbar.add_child(dur_input)

	var dur_s_lbl := Label.new()
	dur_s_lbl.text = "s"
	dur_s_lbl.add_theme_font_size_override("font_size", 12)
	topbar.add_child(dur_s_lbl)

	dur_input.text_submitted.connect(func(t: String):
		if t.is_valid_float():
			_sim_duration = maxf(5.0, float(t))
			_update_timebar())
	dur_input.focus_exited.connect(func():
		if dur_input.text.is_valid_float():
			_sim_duration = maxf(5.0, float(dur_input.text))
			_update_timebar())

	var pad2 := Control.new()
	pad2.custom_minimum_size = Vector2(8, 0)
	topbar.add_child(pad2)

	# Inspector
	_inspector = PanelContainer.new()
	_inspector.position = Vector2(16, 56)
	_inspector.custom_minimum_size = Vector2(250, 0)
	_inspector.mouse_filter = Control.MOUSE_FILTER_STOP
	_inspector.visible = false
	cl.add_child(_inspector)

	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 10)
	_inspector.add_child(margin)

	var vbox := VBoxContainer.new()
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "Planet"
	title.add_theme_font_size_override("font_size", 18)
	vbox.add_child(title)
	vbox.add_child(HSeparator.new())

	vbox.add_child(_label("Cells"))
	_size_slider = HSlider.new()
	_size_slider.min_value = 1
	_size_slider.max_value = 301
	_size_slider.step = 1
	_size_slider.value = 7
	_size_slider.value_changed.connect(_on_size_changed)
	vbox.add_child(_size_slider)

	vbox.add_child(_label("Mass"))
	_mass_slider = HSlider.new()
	_mass_slider.min_value = 0.5
	_mass_slider.max_value = 200.0
	_mass_slider.step = 0.5
	_mass_slider.value = 50.0
	_mass_slider.value_changed.connect(_on_mass_changed)
	vbox.add_child(_mass_slider)

	vbox.add_child(_label("Color"))
	_color_option = OptionButton.new()
	for entry in [["Sapphire", 7], ["Green", 6], ["Bluegreen", 5], ["Grey", 4], ["Gold", 3], ["Pink", 2], ["Red", 1]]:
		_color_option.add_item("%s  ×%d" % [entry[0], entry[1]])
	_color_option.item_selected.connect(_on_color_changed)
	vbox.add_child(_color_option)

	var row := HBoxContainer.new()
	vbox.add_child(row)

	var del_btn := Button.new()
	del_btn.text = "Delete  [Del]"
	del_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	del_btn.pressed.connect(_on_delete)
	row.add_child(del_btn)

	var desel_btn := Button.new()
	desel_btn.text = "Deselect  [Esc]"
	desel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desel_btn.pressed.connect(_deselect)
	row.add_child(desel_btn)

	# Hint text
	var hint_cl := CanvasLayer.new()
	add_child(hint_cl)
	var hint := Label.new()
	hint.text = (
		"Click: place planet\n"
		+ "Click planet: select\n"
		+ "Drag: set velocity\n"
		+ "Right-drag / MMB: pan\n"
		+ "Scroll: zoom\n"
		+ "Esc: deselect   Del: delete"
	)
	hint.add_theme_font_size_override("font_size", 13)
	hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, 12)
	hint.offset_top -= 130
	hint_cl.add_child(hint)
	_hint_label = hint
	hint.visible = false   # hidden until manual editing enabled


func _register_planet(planet: Node, vel: Vector2) -> void:
	var id: int = planet.get_instance_id()
	_velocities[id] = vel
	_init_positions[id] = Vector2(planet.position)
	_init_velocities[id] = Vector2(vel)
	# Note: _rebuild_snapshots() is called explicitly after all planets are registered

func _rebuild_snapshots() -> void:
	_planet_snapshots.clear()
	for planet in get_tree().get_nodes_in_group("planets"):
		if not is_instance_valid(planet):
			continue
		var id: int = planet.get_instance_id()
		_planet_snapshots.append({
			"pos":       Vector2(_init_positions.get(id, planet.position)),
			"vel":       Vector2(_init_velocities.get(id, Vector2.ZERO)),
			"mass":      float(planet.mass),
			"size":      int(planet.current_size),
			"color_idx": int(planet.get("planet_color_index") if planet.get("planet_color_index") != null else 0),
			"is_sun":    bool(planet.get("is_sun")),
			"freeze_mode": int(planet.freeze_mode),
		})


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l

# ── Physics ───────────────────────────────────────────────────────────────────
# Returns true if this planet is an anchor (zero velocity, never moves)
func _is_anchor(planet: Node) -> bool:
	if planet.get("is_sun"):
		return true
	var id: int = planet.get_instance_id()
	var vel: Vector2 = _velocities.get(id, Vector2.ZERO)
	return vel.length_squared() < 0.001

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

# ── Trajectory ────────────────────────────────────────────────────────────────
func _compute_trajectory_with_vel(for_planet: Node, preview_vel: Vector2) -> void:
	if not for_planet or not is_instance_valid(for_planet):
		_traj_points.clear()
		return

	var sel_id: int = for_planet.get_instance_id()
	var bodies: Array = []
	for planet in get_tree().get_nodes_in_group("planets"):
		if not is_instance_valid(planet):
			continue
		var pid: int = planet.get_instance_id()
		# Use preview velocity for the dragged planet, stored velocity for others
		var vel: Vector2 = preview_vel if pid == sel_id else Vector2(_velocities.get(pid, Vector2.ZERO))
		var anchor: bool = planet.get("is_sun") == true or (pid != sel_id and vel.length_squared() < 0.001)
		bodies.append({
			"id":     pid,
			"pos":    Vector2(planet.position),
			"vel":    vel,
			"mass":   float(planet.mass),
			"anchor": anchor,
			"acc":    Vector2.ZERO,
		})

	_traj_points.clear()
	for i in range(TRAJ_STEPS):
		_nbody_step(bodies, TRAJ_DT)
		for b in bodies:
			if b.id == sel_id:
				_traj_points.append(Vector2(b.pos))
				break

func _compute_trajectory(for_planet: Node) -> void:
	if not for_planet or not is_instance_valid(for_planet) or _running:
		_traj_points.clear()
		_traj_planet_id = -1
		return

	var sel_id: int = for_planet.get_instance_id()
	# Don't show trajectory for anchors with no velocity
	if _is_anchor(for_planet):
		_traj_points.clear()
		_traj_planet_id = -1
		return

	var bodies: Array = []
	for planet in get_tree().get_nodes_in_group("planets"):
		if not is_instance_valid(planet):
			continue
		var pid: int = planet.get_instance_id()
		bodies.append({
			"id":     pid,
			"pos":    Vector2(planet.position),
			"vel":    Vector2(_velocities.get(pid, Vector2.ZERO)),
			"mass":   float(planet.mass),
			"anchor": _is_anchor(planet),
			"acc":    Vector2.ZERO,
		})

	_traj_points.clear()
	for i in range(TRAJ_STEPS):
		_nbody_step(bodies, TRAJ_DT)
		for b in bodies:
			if b.id == sel_id:
				_traj_points.append(Vector2(b.pos))
				break

	_traj_dirty = false
	_traj_planet_id = sel_id

# ── Process ───────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	if _running:
		_sim_accumulator += delta * _sim_speed
		_update_explosions(delta)
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

		_sim_time = min(_sim_time + delta * _sim_speed, _sim_duration)
		_update_timebar()
		if _sim_time >= _sim_duration:
			_running = false
			if _play_btn:
				_play_btn.text = "▶ Play"
	else:
		# Track hovered planet and show its trajectory (only in manual editing mode)
		var mouse_world := get_global_mouse_position()
		var new_hovered := _planet_at(mouse_world) if _manual_editing else null
		if new_hovered != _hovered:
			_hovered = new_hovered
			_traj_dirty = true

		if _manual_editing:
			if _mode == Mode.DRAGGING and _selected and is_instance_valid(_selected):
				var drag_vel: Vector2 = (mouse_world - _drag_start) / VELOCITY_SCALE
				_compute_trajectory_with_vel(_selected, drag_vel)
			else:
				var traj_target := _hovered if _hovered else _selected
				if _traj_dirty and traj_target != null:
					_compute_trajectory(traj_target)
		else:
			_traj_points.clear()

	queue_redraw()


func _update_timebar() -> void:
	if _timebar_fill and _timebar:
		_timebar_fill.size.x = (_sim_time / _sim_duration) * _timebar.size.x
	if _time_label:
		_time_label.text = "%.1f / %d s" % [_sim_time, int(_sim_duration)]

# ── Input ─────────────────────────────────────────────────────────────────────
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				_cam.zoom = (_cam.zoom * 1.12).clamp(Vector2(0.005, 0.005), Vector2(12.0, 12.0))
			MOUSE_BUTTON_WHEEL_DOWN:
				_cam.zoom = (_cam.zoom * 0.88).clamp(Vector2(0.005, 0.005), Vector2(12.0, 12.0))
			MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE:
				_is_panning = mb.pressed
			MOUSE_BUTTON_LEFT:
				if mb.pressed:
					_on_left_press()
				else:
					_on_left_release()

	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _is_panning:
			_cam.position -= mm.relative / _cam.zoom

	elif event is InputEventKey and event.pressed:
		var ke := event as InputEventKey
		if ke.keycode == KEY_ESCAPE:
			_deselect()
		elif ke.keycode == KEY_DELETE and _selected and _manual_editing:
			_on_delete()


func _on_left_press() -> void:
	var world := get_global_mouse_position()
	var hit := _planet_at(world)
	if hit:
		if _manual_editing:
			_select(hit)
	else:
		if _manual_editing:
			_drag_start = world
			_mode = Mode.DRAGGING


func _on_left_release() -> void:
	if _mode != Mode.DRAGGING:
		return
	var world := get_global_mouse_position()
	var vel: Vector2 = (world - _drag_start) / VELOCITY_SCALE

	if _selected and is_instance_valid(_selected):
		_velocities[_selected.get_instance_id()] = vel
		# Update initial velocity so reset restores the new setting
		_init_velocities[_selected.get_instance_id()] = Vector2(vel)
		_rebuild_snapshots()
		_reset_sim()
		_mode = Mode.SELECTED
	else:
		if world.distance_to(_drag_start) < 8.0:
			_spawn_planet(_drag_start, Vector2.ZERO)
		else:
			_spawn_planet(_drag_start, vel)
		_mode = Mode.IDLE


func _on_timebar_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if _timebar:
			var pct: float = clamp(event.position.x / _timebar.size.x, 0.0, 1.0)
			_sim_time = pct * _sim_duration
			_update_timebar()


func _on_play_pressed() -> void:
	_running = not _running
	if _play_btn:
		_play_btn.text = "⏸ Pause" if _running else "▶ Play"
	if not _running:
		_traj_dirty = true


func _on_reset_pressed() -> void:
	_reset_sim()


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
			var sum_r: float = (a.node.surface_radius if a.node.get("surface_radius") else 80.0) \
							 + (b.node.surface_radius if b.node.get("surface_radius") else 80.0)
			if dist < sum_r:
				var mid: Vector2 = (a.pos + b.pos) * 0.5
				var blast_r: float = max(sum_r * 4.0, 400.0)
				var blast_str: float = sqrt((a.mass + b.mass)) * 400.0
				_explosions.append({
					"pos": mid,
					"radius": 0.0,
					"max_radius": blast_r,
					"alpha": 1.0,
					"blast_str": blast_str,
				})
				# Apply blast force to all other bodies
				for k in range(bodies.size()):
					var c: Dictionary = bodies[k]
					if c.anchor or c.node == a.node or c.node == b.node:
						continue
					var to_c: Vector2 = c.pos - mid
					var d: float = to_c.length()
					if d < blast_r and d > 1.0:
						var falloff: float = 1.0 - (d / blast_r)
						var force: float = blast_str * falloff / (c.mass + 1.0)
						_velocities[c.id] = _velocities.get(c.id, Vector2.ZERO) + to_c.normalized() * force
				# Sun survives — only remove the non-sun planet(s)
				if not a.node.get("is_sun"):
					to_remove.append(a.node)
				if not b.node.get("is_sun"):
					to_remove.append(b.node)
	for node in to_remove:
		if is_instance_valid(node):
			var id: int = node.get_instance_id()
			_velocities.erase(id)
			_init_positions.erase(id)
			_init_velocities.erase(id)
			node.queue_free()
	if not to_remove.is_empty():
		_traj_dirty = true

func _update_explosions(delta: float) -> void:
	for exp in _explosions:
		# Linear expansion — constant speed throughout
		var speed: float = exp.max_radius * 2.2
		exp.radius += speed * delta
		exp.alpha = max(0.0, 1.0 - (exp.radius / exp.max_radius))
	_explosions = _explosions.filter(func(e): return e.alpha > 0.0 and e.radius < e.max_radius)

func _reset_sim() -> void:
	_running = false
	_sim_time = 0.0
	_sim_accumulator = 0.0
	_explosions.clear()
	if _play_btn:
		_play_btn.text = "▶ Play"

	# Destroy all current planets
	for planet in get_tree().get_nodes_in_group("planets"):
		if is_instance_valid(planet):
			planet.queue_free()
	_velocities.clear()
	_init_positions.clear()
	_init_velocities.clear()
	_selected = null
	_inspector.visible = false
	_traj_points.clear()

	# Re-create from snapshots
	await get_tree().process_frame   # wait for queue_free to process
	for snap in _planet_snapshots:
		if not planet_scene:
			continue
		var p: Node = planet_scene.instantiate()
		if snap.is_sun:
			p.is_sun = true
		p.editing_mode = true
		p.mass = snap.mass
		p.current_size = snap.size
		p.planet_color_index = snap.color_idx
		p.freeze = true
		p.freeze_mode = snap.freeze_mode
		add_child(p)
		p.position = snap.pos
		if not snap.is_sun:
			p.apply_appearance()
		var id: int = p.get_instance_id()
		_velocities[id] = snap.vel
		_init_positions[id] = Vector2(snap.pos)
		_init_velocities[id] = Vector2(snap.vel)

	_update_timebar()
	_traj_dirty = true


func _spawn_planet(pos: Vector2, vel: Vector2) -> void:
	if not planet_scene:
		return
	var p: Node = planet_scene.instantiate()
	add_child(p)
	p.position = pos
	p.editing_mode = true
	p.mass = 50.0
	p.freeze = true
	p.freeze_mode = RigidBody2D.FREEZE_MODE_STATIC
	_register_planet(p, vel)
	_rebuild_snapshots()
	_reset_sim()
	_select(p)


func _planet_at(world_pos: Vector2) -> Node:
	var space := get_world_2d().direct_space_state
	var params := PhysicsPointQueryParameters2D.new()
	params.position = world_pos
	params.collision_mask = 0xFFFFFFFF
	for r in space.intersect_point(params, 8):
		var col = r["collider"]
		if col.is_in_group("planets"):
			return col
	return null


func _select(planet: Node) -> void:
	_selected = planet
	_mode = Mode.SELECTED
	_inspector.visible = true
	_size_slider.value = planet.current_size
	_mass_slider.value = planet.mass
	_color_option.selected = planet.get("planet_color_index") if planet.get("planet_color_index") != null else 0
	_traj_dirty = true


func _deselect() -> void:
	_selected = null
	_mode = Mode.IDLE
	_inspector.visible = false
	_traj_points.clear()


func _on_size_changed(value: float) -> void:
	if _selected and is_instance_valid(_selected) and not _selected.get("is_sun"):
		_selected.on_slider_value_changed(value)
		_reset_sim()


func _on_mass_changed(value: float) -> void:
	if _selected and is_instance_valid(_selected) and not _selected.get("is_sun"):
		_selected.mass = value
		_reset_sim()


func _on_color_changed(index: int) -> void:
	if _selected and is_instance_valid(_selected) and not _selected.get("is_sun"):
		_selected.planet_color_index = index
		_selected.apply_appearance()


func _on_delete() -> void:
	if _selected and is_instance_valid(_selected):
		if _selected.get("is_sun"):
			return
		_velocities.erase(_selected.get_instance_id())
		_init_positions.erase(_selected.get_instance_id())
		_init_velocities.erase(_selected.get_instance_id())
		_selected.queue_free()
	_deselect()


# ── Draw ──────────────────────────────────────────────────────────────────────
func _draw() -> void:
	var inv_z: float = 1.0 / _cam.zoom.x

	# Explosion rings
	for exp in _explosions:
		var thickness: float = 2.0 + 18.0 * (1.0 - exp.alpha)
		draw_arc(exp.pos, exp.radius, 0.0, TAU, 64,
				Color(1.0, 1.0, 1.0, exp.alpha * 0.9), thickness * inv_z)

	# Selection ring
	if _selected and is_instance_valid(_selected):
		draw_arc(_selected.position, 90.0 * inv_z, 0.0, TAU, 48,
				Color(1.0, 0.9, 0.1, 0.9), 3.0 * inv_z)

	# Trajectory preview
	if not _running and _traj_points.size() > 1:
		for i in range(1, _traj_points.size()):
			var alpha: float = (1.0 - float(i) / _traj_points.size()) * 0.55
			draw_line(_traj_points[i - 1], _traj_points[i],
					Color(0.25, 0.8, 1.0, alpha), 1.5 * inv_z)

	# Velocity arrow while dragging a selected planet
	if _mode == Mode.DRAGGING and _selected and is_instance_valid(_selected):
		var mouse_world: Vector2 = get_global_mouse_position()
		var origin: Vector2 = _selected.position
		var vel: Vector2 = (mouse_world - _drag_start) / VELOCITY_SCALE
		var speed: float = vel.length()

		draw_circle(origin, 50.0 * inv_z, Color(1, 1, 1, 0.12))
		draw_arc(origin, 50.0 * inv_z, 0.0, TAU, 32, Color(1, 1, 1, 0.6), 1.5 * inv_z)

		if speed > 0.5:
			var tip: Vector2 = origin + vel * VELOCITY_SCALE
			draw_line(origin, tip, Color(1.0, 0.55, 0.1, 0.75), 2.0 * inv_z)
			var dir: Vector2 = (tip - origin).normalized()
			var perp: Vector2 = dir.rotated(PI * 0.5)
			var ah: float = 14.0 * inv_z
			draw_colored_polygon(PackedVector2Array([
				tip,
				tip - dir * ah + perp * ah * 0.5,
				tip - dir * ah - perp * ah * 0.5,
			]), Color(1.0, 0.55, 0.1, 0.9))
