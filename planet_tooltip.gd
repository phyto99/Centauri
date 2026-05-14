extends Control

const WIDTH        = 200.0
const HEADER_H     = 26.0
const MID_H        = 68.0
const BOTTOM_H_PER_TEAM = 36.0   # height per cultivate row
const HEADER_MARGIN = 8.0   # left and right margin around planet name
const MIN_WIDTH     = 120.0 # never shrink below this

const GRAD_LEFT  = Color(0.133, 0.655, 0.875)
const GRAD_RIGHT = Color(0.043, 0.365, 0.592)

const MID_COLOR    = Color(0.216, 0.216, 0.216)  # #373737
const BOTTOM_COLOR = Color(0.133, 0.133, 0.133)  # #222222

const MOUSE_OFFSET = Vector2(14.0, 14.0)

const CLAIM_ICON     = preload("res://UI/claim2.svg")
const CULTIVATE_ICON = preload("res://UI/cultivatesmall.svg")

var _planet: Node = null
var _team_color: Color = Color.WHITE

var _header_mat: ShaderMaterial
var _header_rect: ColorRect = null
var _name_label: Label

var _claims_label:       Label
var _claims_icon:        TextureRect
var _claims_badge_style: StyleBoxFlat = null
var _tax_label:          Label = null
var _tax_badge:          PanelContainer = null
var _claims_badge:       PanelContainer = null
var _badges_row:         HBoxContainer = null
var _uncol_margin:       MarginContainer = null
var _mid_vbox:           VBoxContainer = null
var _top_spacer:         Control = null
var _inner_pad:          MarginContainer = null

# Container for the dynamic per-team cultivate badges
var _bot_box: VBoxContainer = null
var _bot_panel: Panel = null
var _mid_margin: MarginContainer = null
var _pending_unhover: Node = null
var _last_unhovered: Node = null

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
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
	_header_rect = header

	_name_label = Label.new()
	_name_label.text = "Planet"
	_name_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_name_label.offset_left = 8.0
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_name_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_name_label.add_theme_font_size_override("font_size", 17)
	_name_label.add_theme_color_override("font_color", Color.WHITE)
	_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var name_ls := LabelSettings.new()
	name_ls.font_size = 17
	var name_font := FontVariation.new()
	name_font.base_font = ThemeDB.fallback_font
	name_font.variation_embolden = 1.0
	name_ls.font = name_font
	name_ls.font_color = Color.WHITE
	_name_label.label_settings = name_ls
	header.add_child(_name_label)

	# Mid panel — MarginContainer drives height from content, no fixed MID_H needed
	var mid_margin = MarginContainer.new()
	mid_margin.add_theme_constant_override("margin_left", 0)
	mid_margin.add_theme_constant_override("margin_right", 0)
	mid_margin.add_theme_constant_override("margin_top", 0)
	mid_margin.add_theme_constant_override("margin_bottom", 0)
	mid_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mid_margin.position = Vector2(0.0, HEADER_H)
	mid_margin.size = Vector2(WIDTH, 0)

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

	# Inner padding container — grey fills the outer mid_margin, padding is inside
	var inner_pad = MarginContainer.new()
	inner_pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner_pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner_pad.add_theme_constant_override("margin_left", 4)
	inner_pad.add_theme_constant_override("margin_right", 4)
	inner_pad.add_theme_constant_override("margin_top", 4)
	inner_pad.add_theme_constant_override("margin_bottom", 4)
	inner_pad.add_child(mid_vbox)
	mid_margin.add_child(inner_pad)
	_mid_vbox = mid_vbox
	_inner_pad = inner_pad

	var badges_row = HBoxContainer.new()
	badges_row.add_theme_constant_override("separation", 6)
	badges_row.alignment = BoxContainer.ALIGNMENT_BEGIN
	badges_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mid_vbox.add_child(badges_row)
	_badges_row = badges_row

	_make_tax_badge(badges_row)
	_make_claims_badge(badges_row)

	# UNCOLLECTED — centered, thin font, real bottom margin only
	var uncol_margin = MarginContainer.new()
	uncol_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	uncol_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	uncol_margin.add_theme_constant_override("margin_left", 0)
	uncol_margin.add_theme_constant_override("margin_right", 0)
	uncol_margin.add_theme_constant_override("margin_top", 2)
	uncol_margin.add_theme_constant_override("margin_bottom", 0)
	mid_vbox.add_child(uncol_margin)
	_uncol_margin = uncol_margin

	var uncol = Label.new()
	uncol.text = "UNCOLLECTED"
	uncol.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	uncol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	uncol.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	uncol.mouse_filter = Control.MOUSE_FILTER_IGNORE
	uncol.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	var ls = LabelSettings.new()
	ls.font_size = 13
	ls.font_color = Color(0.75, 0.75, 0.75)
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
	_tax_badge = c

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

	_tax_label = Label.new()
	_tax_label.text = "5:5 tax"
	_tax_label.add_theme_font_size_override("font_size", 18)
	_tax_label.add_theme_color_override("font_color", Color.WHITE)
	_tax_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_tax_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.add_child(_tax_label)

func _make_claims_badge(parent: Node) -> void:
	var c = PanelContainer.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_claims_badge = c

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
	_claims_label.add_theme_font_size_override("font_size", 18)
	_claims_label.add_theme_color_override("font_color", Color.WHITE)
	_claims_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_claims_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(_claims_label)

# Builds one cultivate badge (icon + count) for a given team color.
func _make_cultivate_badge(team_color: Color, count: int, suffix: String = "") -> void:
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
	lbl.text = "x%d%s" % [count, suffix]
	lbl.add_theme_font_size_override("font_size", 20)
	lbl.add_theme_color_override("font_color", team_color)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(lbl)

# Clears and rebuilds all cultivate badges from current planet data.
func _rebuild_cultivate_badges(planet: Node) -> void:
	for child in _bot_box.get_children():
		child.queue_free()

	var tyc        = planet.get("team_yield_counts")
	var ttp        = planet.get("team_tax_paid")
	var tte        = planet.get("team_tax_earned")
	var dom_id: int = planet.get("dominant_team_id") if planet.get("dominant_team_id") != null else -1

	var row_count := 0

	# Dominant team always first
	if dom_id >= 0:
		var col := GameConfig.color_for(dom_id)
		var gross: int = int(tyc.get(dom_id, 0)) if tyc else 0
		var paid: int  = int(ttp.get(dom_id, 0.0)) if ttp else 0
		var net: int   = max(0, gross - paid)
		if net > 0:
			_make_cultivate_badge(col, net)
			row_count += 1
		var earned := int(tte.get(dom_id, 0.0)) if tte else 0
		if earned > 0:
			_make_cultivate_badge(col, earned, " in tax")
			row_count += 1

	# Other teams sorted by gross yield descending, only show if net > 0
	var others: Array = []
	if tyc:
		for tid in tyc:
			if tid == dom_id:
				continue
			var gross := int(tyc.get(tid, 0))
			if gross > 0:
				others.append([tid, gross])
	others.sort_custom(func(a, b): return a[1] > b[1])

	for entry in others:
		var tid: int = entry[0]
		var col := GameConfig.color_for(tid)
		var gross: int = entry[1]
		var paid: int  = int(ttp.get(tid, 0.0)) if ttp else 0
		var net: int   = max(0, gross - paid)
		if net > 0:
			_make_cultivate_badge(col, net)
			row_count += 1

	if row_count == 0:
		_bot_panel.visible = false
	else:
		_bot_panel.visible = true

	var cur_w: float = custom_minimum_size.x if custom_minimum_size.x > 0 else WIDTH
	var bot_h: float = BOTTOM_H_PER_TEAM * row_count
	_bot_panel.size = Vector2(cur_w, bot_h)
	var mid_bottom: float = HEADER_H + (_mid_margin.size.y if _mid_margin else MID_H)
	_bot_panel.position.y = mid_bottom
	custom_minimum_size = Vector2(cur_w, mid_bottom + bot_h)

# ── PANEL / SHADER HELPERS ────────────────────────────────────────────────────

func _on_mid_resized() -> void:
	if _bot_panel and _mid_margin:
		var mid_bottom := HEADER_H + _mid_margin.size.y
		_bot_panel.position.y = mid_bottom
		var cur_w: float = custom_minimum_size.x if custom_minimum_size.x > 0 else WIDTH
		custom_minimum_size = Vector2(cur_w, mid_bottom + _bot_panel.size.y)

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

func _update_header_gradient(planet: Node) -> void:
	var sprite: Variant = planet.get("outline_sprite")
	if sprite == null or not (sprite.material is ShaderMaterial):
		_header_mat.set_shader_parameter("color_left",  Color("#00f780"))
		_header_mat.set_shader_parameter("color_right", Color("#00a997"))
		return
	var col := _planet_base_color(planet)
	var h := col.h
	var is_red   := h > 0.92 or h < 0.05
	var is_green := h > 0.28 and h < 0.45
	if is_red or is_green:
		col = Color.from_hsv(h, minf(col.s * 1.3, 1.0), minf(col.v * 1.3, 1.0))
	_header_mat.set_shader_parameter("color_left",  col.lightened(0.25))
	_header_mat.set_shader_parameter("color_right", col.darkened(0.25))

func _planet_base_color(planet: Node) -> Color:
	var sprite: Variant = planet.get("outline_sprite")
	if sprite != null and sprite.material is ShaderMaterial:
		return sprite.material.get_shader_parameter("planet_color")
	return Color(0.12, 0.60, 0.72)  # bluegreen native fallback

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
	if _planet and is_instance_valid(_planet) and _planet != planet:
		if _planet.has_signal("yield_updated") and _planet.yield_updated.is_connected(_on_yield_updated):
			_planet.yield_updated.disconnect(_on_yield_updated)
		if _planet.has_signal("tax_updated") and _planet.tax_updated.is_connected(_on_tax_updated):
			_planet.tax_updated.disconnect(_on_tax_updated)

	_planet = planet
	_update_header_gradient(planet)

	_name_label.text = "Planet " + planet.planet_name if planet.get("planet_name") else "Planet"
	_resize_to_name()

	_refresh_claims(planet)
	_refresh_tax_badge(planet)
	_refresh_visibility(planet)
	_rebuild_cultivate_badges(planet)

	if planet.has_signal("yield_updated") and not planet.yield_updated.is_connected(_on_yield_updated):
		planet.yield_updated.connect(_on_yield_updated)
	if planet.has_signal("tax_updated") and not planet.tax_updated.is_connected(_on_tax_updated):
		planet.tax_updated.connect(_on_tax_updated)

	show()
	set_process(true)

func _on_planet_unhovered() -> void:
	# Only hide if the planet that fired unhovered is still the one we're showing.
	# This prevents the race where unhovered fires after the next planet's hovered.
	# We can't know which planet fired, so we check on next frame.
	_last_unhovered = _planet
	call_deferred("_check_still_hovered")

func _check_still_hovered() -> void:
	if _planet != null and is_instance_valid(_planet) and _planet == _last_unhovered:
		if _planet.has_signal("yield_updated") and _planet.yield_updated.is_connected(_on_yield_updated):
			_planet.yield_updated.disconnect(_on_yield_updated)
		if _planet.has_signal("tax_updated") and _planet.tax_updated.is_connected(_on_tax_updated):
			_planet.tax_updated.disconnect(_on_tax_updated)
		_planet = null
		hide()
	elif _planet != null and not is_instance_valid(_planet):
		# Planet was freed externally — clean up silently
		_planet = null
		hide()
	_last_unhovered = null

func _do_hide() -> void:
	if _planet and is_instance_valid(_planet):
		if _planet.has_signal("yield_updated") and _planet.yield_updated.is_connected(_on_yield_updated):
			_planet.yield_updated.disconnect(_on_yield_updated)
		if _planet.has_signal("tax_updated") and _planet.tax_updated.is_connected(_on_tax_updated):
			_planet.tax_updated.disconnect(_on_tax_updated)
	_planet = null
	hide()
	set_process(false)

func _on_yield_updated(_count: int) -> void:
	if _planet and is_instance_valid(_planet):
		_refresh_visibility(_planet)
		_rebuild_cultivate_badges(_planet)

func _on_tax_updated() -> void:
	if _planet and is_instance_valid(_planet):
		_refresh_tax_badge(_planet)
		_rebuild_cultivate_badges(_planet)

func _on_moves_updated(_remaining: int) -> void:
	if _planet and is_instance_valid(_planet):
		_refresh_claims(_planet)
		_refresh_visibility(_planet)

static func _gcd(a: int, b: int) -> int:
	while b != 0:
		var t := b
		b = a % b
		a = t
	return a

func _refresh_tax_badge(planet: Node) -> void:
	if not _tax_label:
		return
	var dom_id: int = planet.get("dominant_team_id") if planet.get("dominant_team_id") != null else -1
	if dom_id < 0:
		_tax_label.text = "no tax"
	else:
		var rate: int = planet.get("tax_rate") if planet.get("tax_rate") != null else 5
		var other := 10 - rate
		var g := _gcd(rate, other)
		_tax_label.text = "%d:%d tax" % [rate / g, other / g]

# ── PROCESS ───────────────────────────────────────────────────────────────────

func _process(_delta: float) -> void:
	# If the planet we're showing was freed externally, hide cleanly
	if _planet != null and not is_instance_valid(_planet):
		_planet = null
		hide()
		return
	global_position = get_global_mouse_position() + MOUSE_OFFSET

# ── HELPERS ───────────────────────────────────────────────────────────────────

# Resize all panels to fit the planet name text width.
func _resize_to_name() -> void:
	if not _name_label or not _name_label.label_settings:
		return
	var font: Font = _name_label.label_settings.font if _name_label.label_settings.font else ThemeDB.fallback_font
	var font_size: int = _name_label.label_settings.font_size
	var text_w: float = font.get_string_size(_name_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var new_width: float = maxf(MIN_WIDTH, text_w + HEADER_MARGIN * 2.0)

	# Resize header
	if _header_rect:
		_header_rect.size.x = new_width
	# Resize name label to match
	_name_label.offset_right = new_width - HEADER_MARGIN

	# Resize mid margin
	if _mid_margin:
		_mid_margin.custom_minimum_size.x = new_width
		_mid_margin.size.x = new_width
	if _inner_pad:
		_inner_pad.custom_minimum_size.x = new_width

	# Resize bot panel
	if _bot_panel:
		_bot_panel.size.x = new_width

	custom_minimum_size.x = new_width

# Show/hide mid panel elements based on planet state.
func _refresh_visibility(planet: Node) -> void:
	# Uncollected section: only show if yield_count > 0
	var has_yield: bool = (planet.get("yield_count") if planet.get("yield_count") != null else 0) > 0
	if _uncol_margin:
		_uncol_margin.visible = has_yield

	# Count claims on this planet
	var has_claims := false
	for cell in planet.grid.values():
		if cell.get("state", -1) == planet.CellState.CLAIMED:
			has_claims = true
			break

	# Tax badge: hide if no dominant team (no claims)
	var dom_id: int = planet.get("dominant_team_id") if planet.get("dominant_team_id") != null else -1
	var has_tax: bool = dom_id >= 0 and has_claims
	if _tax_badge:
		_tax_badge.visible = has_tax

	# Claims badge: hide if no claims at all
	if _claims_badge:
		_claims_badge.visible = has_claims

	# Hide the whole badges row if both badges are hidden
	var badges_visible: bool = has_tax or has_claims
	if _badges_row:
		_badges_row.visible = badges_visible

	# Hide the entire mid grey panel if there's nothing in it
	if _mid_margin:
		_mid_margin.visible = badges_visible or has_yield
		if _mid_margin.visible:
			_mid_margin.reset_size()
	# Force VBox to re-sort so hidden children don't leave gaps
	if _mid_vbox:
		_mid_vbox.queue_sort()

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

	if dominant_tid >= 0:
		_team_color = GameConfig.color_for(dominant_tid)
	else:
		_team_color = Color.WHITE

	var display_count := dominant_count if dominant_tid >= 0 else total_claimed
	_claims_label.text = "x %d" % display_count
	_claims_badge_style.border_color = _team_color
	_claims_icon.modulate            = _team_color
	_claims_label.add_theme_color_override("font_color", _team_color)
