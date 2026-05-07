extends Control

const WIDTH        = 200.0
const HEADER_H     = 26.0
const MID_H        = 68.0
const BOTTOM_H_PER_TEAM = 36.0   # height per cultivate row
const MOUSE_OFFSET = Vector2(14.0, 14.0)

const GRAD_LEFT  = Color(0.133, 0.655, 0.875)
const GRAD_RIGHT = Color(0.043, 0.365, 0.592)

const MID_COLOR    = Color(0.216, 0.216, 0.216)  # #373737
const BOTTOM_COLOR = Color(0.133, 0.133, 0.133)  # #222222

const CLAIM_ICON     = preload("res://UI/claim2.svg")
const CULTIVATE_ICON = preload("res://UI/cultivatesmall.svg")

var _planet: Node = null
var _team_color: Color = Color.WHITE

var _header_mat: ShaderMaterial
var _name_label: Label

var _claims_label:       Label
var _claims_icon:        TextureRect
var _claims_badge_style: StyleBoxFlat = null

# Container for the dynamic per-team cultivate badges
var _bot_box: VBoxContainer = null
var _bot_panel: Panel = null
var _mid_margin: MarginContainer = null

func _ready() -> void:
	custom_minimum_size = Vector2(WIDTH, HEADER_H + MID_H + BOTTOM_H_PER_TEAM)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	hide()
	set_process(false)
	_build_ui()
	_connect_existing_planets()
	get_tree().node_added.connect(_on_node_added)

# ── UI BUILD ──────────────────────────────────────────────────────────────────

func _build_ui() -> void:
	# Header
	var header = ColorRect.new()
	header.size = Vector2(WIDTH, HEADER_H)
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_header_mat = _make_gradient_material(GRAD_LEFT, GRAD_RIGHT)
	header.material = _header_mat
	add_child(header)

	_name_label = Label.new()
	_name_label.text = "Planet"
	_name_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_name_label.offset_left = 8.0
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_name_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_name_label.add_theme_font_size_override("font_size", 17)
	_name_label.add_theme_color_override("font_color", Color.WHITE)
	_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(_name_label)

	# Mid panel — MarginContainer drives height from content, no fixed MID_H needed
	var mid_margin = MarginContainer.new()
	mid_margin.add_theme_constant_override("margin_left", 0)
	mid_margin.add_theme_constant_override("margin_right", 0)
	mid_margin.add_theme_constant_override("margin_top", 0)
	mid_margin.add_theme_constant_override("margin_bottom", 0)
	mid_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mid_margin.position = Vector2(0.0, HEADER_H)
	mid_margin.size = Vector2(WIDTH, 0)   # width fixed, height auto
	mid_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# Backing colour rect that resizes with the MarginContainer
	var mid_bg = ColorRect.new()
	mid_bg.color = MID_COLOR
	mid_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mid_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mid_bg.z_index = -1
	mid_margin.add_child(mid_bg)
	add_child(mid_margin)

	var mid_vbox = VBoxContainer.new()
	mid_vbox.add_theme_constant_override("separation", 2)
	mid_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mid_margin.add_child(mid_vbox)

	# Top padding spacer inside the grey box
	var top_spacer = Control.new()
	top_spacer.custom_minimum_size = Vector2(0, 4)
	top_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mid_vbox.add_child(top_spacer)

	var badges_row = HBoxContainer.new()
	badges_row.add_theme_constant_override("separation", 6)
	badges_row.alignment = BoxContainer.ALIGNMENT_BEGIN
	badges_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mid_vbox.add_child(badges_row)

	# Left margin spacer (outside the badge box)
	var left_pad = Control.new()
	left_pad.custom_minimum_size = Vector2(3, 0)
	left_pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badges_row.add_child(left_pad)

	_make_tax_badge(badges_row)
	_make_claims_badge(badges_row)

	# UNCOLLECTED — centered, thin font, real bottom margin only
	var uncol_margin = MarginContainer.new()
	uncol_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	uncol_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	uncol_margin.add_theme_constant_override("margin_left", 0)
	uncol_margin.add_theme_constant_override("margin_right", 0)
	uncol_margin.add_theme_constant_override("margin_top", 0)
	uncol_margin.add_theme_constant_override("margin_bottom", 2)
	mid_vbox.add_child(uncol_margin)

	var uncol = Label.new()
	uncol.text = "UNCOLLECTED"
	uncol.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	uncol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	uncol.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	uncol.mouse_filter = Control.MOUSE_FILTER_IGNORE
	uncol.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	var ls = LabelSettings.new()
	ls.font_size = 15
	ls.font_color = Color(0.5, 0.5, 0.5)
	var vf = SystemFont.new()
	vf.font_names = PackedStringArray(["Arial", "Helvetica Neue", "Helvetica", "sans-serif"])
	vf.font_weight = 100
	ls.font = vf
	uncol.label_settings = ls
	uncol_margin.add_child(uncol)

	# Position bottom panel after mid — use notification to get mid's final height,
	# but we store mid_margin so _rebuild can reposition _bot_panel if needed.
	# For initial layout we use a deferred call.
	_mid_margin = mid_margin
	mid_margin.resized.connect(_on_mid_resized)

	# Bottom panel
	_bot_panel = _make_panel(BOTTOM_COLOR, Vector2(0.0, HEADER_H + MID_H), Vector2(WIDTH, BOTTOM_H_PER_TEAM))
	add_child(_bot_panel)

	_bot_box = VBoxContainer.new()
	_bot_box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_bot_box.offset_top = 4.0   # small top inset, no extra bottom
	_bot_box.offset_bottom = 0.0
	_bot_box.alignment = BoxContainer.ALIGNMENT_BEGIN
	_bot_box.add_theme_constant_override("separation", 4)
	_bot_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bot_panel.add_child(_bot_box)

# ── BADGE BUILDERS ────────────────────────────────────────────────────────────

func _make_tax_badge(parent: Node) -> void:
	var c = PanelContainer.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var style = StyleBoxFlat.new()
	style.bg_color            = Color(0, 0, 0, 0)
	style.border_color        = Color.WHITE
	style.border_width_left   = 2
	style.border_width_right  = 2
	style.border_width_top    = 2
	style.border_width_bottom = 2
	style.corner_radius_top_left     = 3
	style.corner_radius_top_right    = 3
	style.corner_radius_bottom_left  = 3
	style.corner_radius_bottom_right = 3
	style.content_margin_left   = 10
	style.content_margin_right  = 10
	style.content_margin_top    = 4
	style.content_margin_bottom = 4
	c.add_theme_stylebox_override("panel", style)
	parent.add_child(c)

	var lbl = Label.new()
	lbl.text = "1:1 tax"
	lbl.add_theme_font_size_override("font_size", 20)
	lbl.add_theme_color_override("font_color", Color.WHITE)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.add_child(lbl)

func _make_claims_badge(parent: Node) -> void:
	var c = PanelContainer.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE

	_claims_badge_style = StyleBoxFlat.new()
	_claims_badge_style.bg_color            = Color(0, 0, 0, 0)
	_claims_badge_style.border_color        = Color.WHITE
	_claims_badge_style.border_width_left   = 2
	_claims_badge_style.border_width_right  = 2
	_claims_badge_style.border_width_top    = 2
	_claims_badge_style.border_width_bottom = 2
	_claims_badge_style.corner_radius_top_left     = 3
	_claims_badge_style.corner_radius_top_right    = 3
	_claims_badge_style.corner_radius_bottom_left  = 3
	_claims_badge_style.corner_radius_bottom_right = 3
	_claims_badge_style.content_margin_left   = 10
	_claims_badge_style.content_margin_right  = 10
	_claims_badge_style.content_margin_top    = 4
	_claims_badge_style.content_margin_bottom = 4
	c.add_theme_stylebox_override("panel", _claims_badge_style)
	parent.add_child(c)

	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 3)
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.add_child(hbox)

	_claims_icon = TextureRect.new()
	_claims_icon.texture = CLAIM_ICON
	_claims_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_claims_icon.custom_minimum_size = Vector2(18, 18)
	_claims_icon.modulate = Color.WHITE
	_claims_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(_claims_icon)

	_claims_label = Label.new()
	_claims_label.text = "x 0"
	_claims_label.add_theme_font_size_override("font_size", 20)
	_claims_label.add_theme_color_override("font_color", Color.WHITE)
	_claims_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_claims_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(_claims_label)

# Builds one cultivate badge (icon + count) for a given team color.
func _make_cultivate_badge(team_color: Color, count: int) -> void:
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 3)
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bot_box.add_child(hbox)

	# Left margin spacer
	var pad = Control.new()
	pad.custom_minimum_size = Vector2(6, 0)
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(pad)

	var tex = TextureRect.new()
	tex.texture = CULTIVATE_ICON
	tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tex.custom_minimum_size = Vector2(22, 22)
	tex.modulate = team_color
	tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(tex)

	var lbl = Label.new()
	lbl.text = "x%d" % count
	lbl.add_theme_font_size_override("font_size", 20)
	lbl.add_theme_color_override("font_color", team_color)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(lbl)

# Clears and rebuilds all cultivate badges from current planet data.
func _rebuild_cultivate_badges(planet: Node) -> void:
	# Clear all previous badges
	for child in _bot_box.get_children():
		child.queue_free()

	# Read accumulated yield per team (same source as scoreboard)
	var team_counts: Dictionary = {}
	var team_yield_counts = planet.get("team_yield_counts")
	if team_yield_counts:
		for tid in team_yield_counts:
			var val: int = team_yield_counts[tid]
			if val > 0:
				team_counts[tid] = val

	var row_count: int = max(1, team_counts.size())
	var bot_h: float = BOTTOM_H_PER_TEAM * row_count

	# Resize bottom panel and reposition below the dynamic mid section
	_bot_panel.size = Vector2(WIDTH, bot_h)
	var mid_bottom: float = HEADER_H + (_mid_margin.size.y if _mid_margin else MID_H)
	_bot_panel.position.y = mid_bottom
	custom_minimum_size = Vector2(WIDTH, mid_bottom + bot_h)

	if team_counts.is_empty():
		# Placeholder row when no yield yet
		_make_cultivate_badge(Color.WHITE, 0)
		return

	var colors = planet.get("team_colors")
	var sorted_tids: Array = team_counts.keys()
	sorted_tids.sort()

	for tid in sorted_tids:
		var col: Color = Color.WHITE
		if colors and colors.size() > 0:
			col = colors[tid % colors.size()]
		_make_cultivate_badge(col, team_counts[tid])

# ── PANEL / SHADER HELPERS ────────────────────────────────────────────────────

func _on_mid_resized() -> void:
	if _bot_panel and _mid_margin:
		var mid_bottom := HEADER_H + _mid_margin.size.y
		_bot_panel.position.y = mid_bottom
		custom_minimum_size = Vector2(WIDTH, mid_bottom + _bot_panel.size.y)

func _make_panel(color: Color, pos: Vector2, sz: Vector2) -> Panel:
	var p = Panel.new()
	p.position = pos
	p.size = sz
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style = StyleBoxFlat.new()
	style.bg_color = color
	# Zero all content margins so children aren't inset by theme defaults
	style.content_margin_left   = 0
	style.content_margin_right  = 0
	style.content_margin_top    = 0
	style.content_margin_bottom = 0
	p.add_theme_stylebox_override("panel", style)
	return p

func _make_gradient_material(left: Color, right: Color) -> ShaderMaterial:
	var shader = Shader.new()
	shader.code = """
shader_type canvas_item;
uniform vec4 color_left  : source_color;
uniform vec4 color_right : source_color;
void fragment() {
	COLOR = mix(color_left, color_right, UV.x);
}
"""
	var mat = ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("color_left",  left)
	mat.set_shader_parameter("color_right", right)
	return mat

# ── SIGNAL CONNECTIONS ────────────────────────────────────────────────────────

func _connect_existing_planets() -> void:
	for planet in get_tree().get_nodes_in_group("planets"):
		_connect_planet(planet)

func _on_node_added(node: Node) -> void:
	_connect_deferred.call_deferred(node)

func _connect_deferred(node: Node) -> void:
	if node.is_in_group("planets"):
		_connect_planet(node)

func _connect_planet(planet: Node) -> void:
	if planet.get("is_sun"):
		return
	if not planet.has_signal("planet_hovered"):
		return
	if not planet.planet_hovered.is_connected(_on_planet_hovered):
		planet.planet_hovered.connect(_on_planet_hovered)
		planet.planet_unhovered.connect(_on_planet_unhovered)
	if planet.has_signal("moves_updated") and not planet.moves_updated.is_connected(_on_moves_updated):
		planet.moves_updated.connect(_on_moves_updated)

# ── HOVER HANDLERS ────────────────────────────────────────────────────────────

func _on_planet_hovered(planet: Node) -> void:
	if _planet and _planet != planet and _planet.has_signal("yield_updated"):
		if _planet.yield_updated.is_connected(_on_yield_updated):
			_planet.yield_updated.disconnect(_on_yield_updated)

	_planet = planet

	_name_label.text = "Planet " + planet.planet_name if planet.get("planet_name") else "Planet"

	_refresh_claims(planet)
	_rebuild_cultivate_badges(planet)

	if planet.has_signal("yield_updated") and not planet.yield_updated.is_connected(_on_yield_updated):
		planet.yield_updated.connect(_on_yield_updated)

	show()
	set_process(true)

func _on_planet_unhovered() -> void:
	if _planet and _planet.has_signal("yield_updated"):
		if _planet.yield_updated.is_connected(_on_yield_updated):
			_planet.yield_updated.disconnect(_on_yield_updated)
	_planet = null
	hide()
	set_process(false)

func _on_yield_updated(_count: int) -> void:
	if _planet:
		_rebuild_cultivate_badges(_planet)

func _on_moves_updated(_remaining: int) -> void:
	if _planet:
		_refresh_claims(_planet)

# ── PROCESS ───────────────────────────────────────────────────────────────────

func _process(_delta: float) -> void:
	global_position = get_global_mouse_position() + MOUSE_OFFSET

# ── HELPERS ───────────────────────────────────────────────────────────────────

func _refresh_claims(planet: Node) -> void:
	var team_counts: Dictionary = {}
	var total_claimed := 0

	for cell in planet.grid.values():
		if cell.get("state", -1) == planet.CellState.CLAIMED:
			total_claimed += 1
			var tid: int = cell.get("team_id", -1)
			if tid >= 0:
				team_counts[tid] = team_counts.get(tid, 0) + 1

	var dominant_tid   := -1
	var dominant_count := 0
	for tid in team_counts:
		if team_counts[tid] > dominant_count:
			dominant_count = team_counts[tid]
			dominant_tid   = tid

	var colors = planet.get("team_colors")
	if dominant_tid >= 0 and colors and colors.size() > 0:
		_team_color = colors[dominant_tid % colors.size()]
	else:
		_team_color = Color.WHITE

	var display_count := dominant_count if dominant_tid >= 0 else total_claimed
	_claims_label.text = "x %d" % display_count
	_claims_badge_style.border_color = _team_color
	_claims_icon.modulate            = _team_color
	_claims_label.add_theme_color_override("font_color", _team_color)
