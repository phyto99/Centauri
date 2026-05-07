extends CanvasLayer

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
	_panel.size = Vector2(260, 140)

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.10, 0.10, 0.13)
	style.border_color = Color(0.25, 0.25, 0.30)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.content_margin_left   = 20
	style.content_margin_right  = 20
	style.content_margin_top    = 18
	style.content_margin_bottom = 18
	_panel.add_theme_stylebox_override("panel", style)
	add_child(_panel)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 12)
	_panel.add_child(vbox)

	_ratio_label = Label.new()
	_ratio_label.text = "5 : 5"
	_ratio_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_ratio_label.add_theme_font_size_override("font_size", 30)
	_ratio_label.add_theme_color_override("font_color", Color.WHITE)
	vbox.add_child(_ratio_label)

	_slider = HSlider.new()
	_slider.min_value = 1
	_slider.max_value = 9
	_slider.step = 1
	_slider.value = 5
	_slider.tick_count = 9
	_slider.ticks_on_borders = true
	_slider.custom_minimum_size = Vector2(0, 20)
	vbox.add_child(_slider)
	_slider.value_changed.connect(func(_v): _refresh_label())

	var btn := Button.new()
	btn.text = "Set Tax"
	btn.pressed.connect(_on_confirm)
	vbox.add_child(btn)

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
	var owner := int(_slider.value)
	var other := 10 - owner
	var g := _gcd(owner, other)
	_ratio_label.text = "%d : %d" % [owner / g, other / g]

func _on_confirm() -> void:
	if is_instance_valid(_planet):
		_planet.tax_rate = int(_slider.value)
	visible = false

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode in [KEY_ENTER, KEY_KP_ENTER]:
			_on_confirm()
		elif event.keycode == KEY_ESCAPE:
			visible = false
