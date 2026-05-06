extends Control

const WIDTH        = 200.0
const HEADER_H     = 26.0
const MID_H        = 42.0
const BOTTOM_H     = 34.0
const MOUSE_OFFSET = Vector2(14.0, 14.0)

const GRAD_LEFT  = Color(0.133, 0.655, 0.875)   # #22a7df
const GRAD_RIGHT = Color(0.043, 0.365, 0.592)   # #0b5d97

const CLAIM_ICON    = preload("res://UI/claim2.svg")
const CULTIVATE_ICON = preload("res://UI/cultivatesmall.svg")
const COLLECT_ICON  = preload("res://UI/collect.svg")

var _planet: Node = null
var _team_color: Color = Color.CYAN

var _header_mat: ShaderMaterial
var _name_label: Label

var _claims_label: Label
var _yield_label: Label

var _badge_styles: Array[StyleBoxFlat] = []
var _badge_icons:  Array[TextureRect]  = []
var _badge_labels: Array[Label]        = []

func _ready() -> void:
	custom_minimum_size = Vector2(WIDTH, HEADER_H + MID_H + BOTTOM_H)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	hide()
	set_process(false)
	_build_ui()
	_connect_existing_planets()
	get_tree().node_added.connect(_on_node_added)

# ── UI BUILD ──────────────────────────────────────────────────────────────────

func _build_ui() -> void:
	# Header — horizontal gradient, fixed blues
	var header = ColorRect.new()
	header.size = Vector2(WIDTH, HEADER_H)
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_header_mat = _make_gradient_material(GRAD_LEFT, GRAD_RIGHT)
	header.material = _header_mat
	add_child(header)

	_name_label = Label.new()
	_name_label.text = "Planet"
	_name_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_name_label.add_theme_font_size_override("font_size", 11)
	_name_label.add_theme_color_override("font_color", Color.WHITE)
	_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(_name_label)

	# Mid panel — light grey
	var mid = _make_panel(Color(0.82, 0.82, 0.85), Vector2(0.0, HEADER_H), Vector2(WIDTH, MID_H))
	add_child(mid)

	var mid_box = HBoxContainer.new()
	mid_box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mid_box.add_theme_constant_override("separation", 6)
	mid_box.alignment = BoxContainer.ALIGNMENT_CENTER
	mid_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mid.add_child(mid_box)

	_make_icon_badge(COLLECT_ICON, "1:1 tax", mid_box)

	var claims_badge = _make_icon_badge(CLAIM_ICON, "x0", mid_box)
	_claims_label = claims_badge

	var uncol = Label.new()
	uncol.text = "UNCOLLECTED"
	uncol.add_theme_font_size_override("font_size", 8)
	uncol.add_theme_color_override("font_color", Color(0.35, 0.35, 0.40))
	uncol.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	uncol.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mid_box.add_child(uncol)

	# Bottom panel — dark grey
	var bot = _make_panel(Color(0.14, 0.14, 0.16), Vector2(0.0, HEADER_H + MID_H), Vector2(WIDTH, BOTTOM_H))
	add_child(bot)

	var bot_box = HBoxContainer.new()
	bot_box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bot_box.alignment = BoxContainer.ALIGNMENT_CENTER
	bot_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bot.add_child(bot_box)

	var yield_badge = _make_icon_badge(CULTIVATE_ICON, "x0", bot_box)
	_yield_label = yield_badge

# Returns the Label inside the badge so callers can update text
func _make_icon_badge(icon: Texture2D, text: String, parent: Node) -> Label:
	var c = PanelContainer.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var style = StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0)
	style.border_color = _team_color
	style.border_width_left   = 1
	style.border_width_right  = 1
	style.border_width_top    = 1
	style.border_width_bottom = 1
	style.corner_radius_top_left     = 3
	style.corner_radius_top_right    = 3
	style.corner_radius_bottom_left  = 3
	style.corner_radius_bottom_right = 3
	style.content_margin_left   = 5
	style.content_margin_right  = 5
	style.content_margin_top    = 3
	style.content_margin_bottom = 3
	c.add_theme_stylebox_override("panel", style)
	_badge_styles.append(style)
	parent.add_child(c)

	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 3)
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.add_child(hbox)

	var tex = TextureRect.new()
	tex.texture = icon
	tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tex.custom_minimum_size = Vector2(14, 14)
	tex.modulate = _team_color
	tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_badge_icons.append(tex)
	hbox.add_child(tex)

	var lbl = Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.add_theme_color_override("font_color", _team_color)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_badge_labels.append(lbl)
	hbox.add_child(lbl)

	return lbl

func _make_panel(color: Color, pos: Vector2, sz: Vector2) -> Panel:
	var p = Panel.new()
	p.position = pos
	p.size = sz
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style = StyleBoxFlat.new()
	style.bg_color = color
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

# ── HOVER HANDLERS ────────────────────────────────────────────────────────────

func _on_planet_hovered(planet: Node) -> void:
	if _planet and _planet != planet and _planet.has_signal("yield_updated"):
		if _planet.yield_updated.is_connected(_on_yield_updated):
			_planet.yield_updated.disconnect(_on_yield_updated)

	_planet = planet

	var team_colors = [
		Color(0, 1, 1),
		Color(1, 0, 1),
		Color(1, 1, 0),
		Color(1, 0, 0),
	]
	_team_color = team_colors[planet.team_id % team_colors.size()]
	_refresh_team_color()

	_name_label.text = "Planet " + planet.planet_name if planet.get("planet_name") else "Planet"

	var claimed = 0
	for cell in planet.grid.values():
		if cell.get("state", -1) == planet.CellState.CLAIMED:
			claimed += 1
	_claims_label.text = "x%d" % claimed
	_yield_label.text  = "x%d" % (planet.yield_count if planet.get("yield_count") != null else 0)

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

func _on_yield_updated(count: int) -> void:
	_yield_label.text = "x%d" % count

# ── PROCESS ───────────────────────────────────────────────────────────────────

func _process(_delta: float) -> void:
	global_position = get_global_mouse_position() + MOUSE_OFFSET

# ── HELPERS ───────────────────────────────────────────────────────────────────

func _refresh_team_color() -> void:
	for style in _badge_styles:
		style.border_color = _team_color
	for tex in _badge_icons:
		tex.modulate = _team_color
	for lbl in _badge_labels:
		lbl.add_theme_color_override("font_color", _team_color)
