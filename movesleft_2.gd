extends Label

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var ls := LabelSettings.new()
	ls.font_size = 16
	ls.font_color = Color(0, 0, 0, 1)
	ls.font = load("res://fonts/SEGOEUI.TTF")
	label_settings = ls

func _process(_delta: float) -> void:
	for ship in get_tree().get_nodes_in_group("players"):
		if not is_instance_valid(ship):
			continue
		var cam = ship.get_node_or_null("Camera2D")
		if not (cam and cam.enabled):
			continue
		var tid: int = ship.get("team_id") if ship.get("team_id") != null else 0
		text = "%d MOVES REMAINING" % GameConfig.get_team_moves(tid)
		return
