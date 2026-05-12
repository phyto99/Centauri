extends CanvasLayer
## Lightweight popup notifications. Call Toast.show("text").

var _label: Label
var _tween: Tween

func _ready() -> void:
	layer = 128
	GameConfig.settings_changed.connect(func(): display("Settings updated"))
	_label = Label.new()
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.custom_minimum_size = Vector2(400, 0)
	_label.add_theme_color_override("font_color", Color.WHITE)
	_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	_label.add_theme_constant_override("shadow_offset_x", 1)
	_label.add_theme_constant_override("shadow_offset_y", 1)
	_label.modulate.a = 0.0
	add_child(_label)
	_reposition()
	get_viewport().size_changed.connect(_reposition)

func display(text: String, duration: float = 2.0) -> void:
	_label.text = text
	if _tween:
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(_label, "modulate:a", 1.0, 0.15)
	_tween.tween_interval(duration)
	_tween.tween_property(_label, "modulate:a", 0.0, 0.4)

func _reposition() -> void:
	var vp := get_viewport().get_visible_rect().size
	_label.position = Vector2((vp.x - _label.custom_minimum_size.x) / 2.0, vp.y * 0.75)
