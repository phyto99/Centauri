extends CanvasLayer

const BG_COLOR = Color(0.168627, 0.176471, 0.180392)

var _planet: Node = null
var _slider: HSlider = null
var _ratio_label: Label = null
var _panel: Panel = null

func _ready() -> void:
	layer = 100
	_build_ui()
	visible = false

func _build_ui() -> void:
	_panel = Panel.new()
	_panel.size = Vector2(260, 100)

	var style := StyleBoxFlat.new()
	style.bg_color = BG_COLOR
	style.set_border_width_all(0)
	style.set_corner_radius_all(0)
	style.content_margin_left   = 0
	style.content_margin_right  = 0
	style.content_margin_top    = 0
	style.content_margin_bottom = 0
	_panel.add_theme_stylebox_override("panel", style)
	add_child(_panel)

	# Ratio label
	_ratio_label = Label.new()
	_ratio_label.text = "1 : 1"
	_ratio_label.position = Vector2(0, 10)
	_ratio_label.size = Vector2(260, 28)
	_ratio_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_ratio_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_ratio_label.add_theme_font_size_override("font_size", 20)
	_ratio_label.add_theme_color_override("font_color", Color.WHITE)
	_panel.add_child(_ratio_label)

	# Slider — no ticks
	_slider = HSlider.new()
	_slider.min_value = 1
	_slider.max_value = 9
	_slider.step = 1
	_slider.value = 5
	_slider.tick_count = 0
	_slider.ticks_on_borders = false
	_slider.position = Vector2(16, 44)
	_slider.size = Vector2(228, 20)
	_panel.add_child(_slider)
	_slider.value_changed.connect(func(_v): _refresh_label())

	# Confirm button
	var btn := Button.new()
	btn.text = "Confirm"
	btn.position = Vector2(16, 70)
	btn.size = Vector2(228, 24)
	btn.pressed.connect(_on_confirm)
	_panel.add_child(btn)

func open(planet: Node) -> void:
	_planet = planet
	_slider.value = planet.get("tax_rate") if planet.get("tax_rate") != null else 5
	_refresh_label()
	var vp := get_viewport().get_visible_rect().size
	_panel.position = (vp - _panel.size) * 0.5
	visible = true

static func _gcd(a: int, b: int) -> int:
	while b != 0:
		var t := b
		b = a % b
		a = t
	return a

func _refresh_label() -> void:
	var owner_val := int(_slider.value)
	var other := 10 - owner_val
	var g := _gcd(owner_val, other)
	_ratio_label.text = "Set Tax  %d : %d" % [owner_val / g, other / g]

func _on_confirm() -> void:
	if is_instance_valid(_planet):
		_planet.tax_rate = int(_slider.value)
		if _planet.has_signal("tax_updated"):
			_planet.emit_signal("tax_updated")
		if OS.get_name() == "Web" and not ColyseusSync.room_id.is_empty():
			ColyseusSync.send_game_event("tax_rate_set", {
				"planet_idx": _planet.planet_idx,
				"tax_rate":   int(_slider.value),
			})
	visible = false

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode in [KEY_ENTER, KEY_KP_ENTER, KEY_E]:
			_on_confirm()
