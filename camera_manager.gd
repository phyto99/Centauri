extends Node

var players = []
var current_camera_index = 0
var team_color = ""

func _ready():
	add_to_group("camera_manager")
	process_mode = Node.PROCESS_MODE_ALWAYS
	call_deferred("initialize_cameras")

func _live_players() -> Array:
	players = players.filter(func(p): return is_instance_valid(p))
	return players

func initialize_cameras():
	await get_tree().process_frame
	refresh_players()

func refresh_players() -> void:
	players = get_tree().get_nodes_in_group("players").filter(
		func(p): return is_instance_valid(p))
	for player in players:
		var cam = player.get_node_or_null("Camera2D")
		if cam:
			cam.process_mode = Node.PROCESS_MODE_ALWAYS
	if players.size() > 0:
		set_active_camera(0)

func _input(event):
	if event is InputEventKey and event.pressed:
		var live := _live_players()
		for i in range(10):
			if event.keycode == KEY_0 + i:
				var idx := 9 if i == 0 else i - 1
				if idx < live.size():
					set_active_camera(idx)

func set_active_camera(index):
	var live := _live_players()
	if live.is_empty() or index < 0 or index >= live.size():
		return

	for player in live:
		var cam = player.get_node_or_null("Camera2D")
		if cam:
			cam.enabled = false

	var active_player = live[index]
	var cam = active_player.get_node_or_null("Camera2D")
	if cam:
		cam.enabled = true
	current_camera_index = index

	var tid: int = active_player.get("team_id") if active_player.get("team_id") != null else index
	var resolved_color: Color = GameConfig.color_for(tid)
	team_color = resolved_color

	var ui := get_tree().get_first_node_in_group("ui_controller")
	if ui and ui.has_method("set_team_color"):
		ui.set_team_color(resolved_color)

	for p in live:
		var cl = p.get_node_or_null("CanvasLayer")
		if cl:
			cl.visible = (p == active_player)
	if active_player.has_method("set_fuel_bar_color"):
		active_player.set_fuel_bar_color(resolved_color)

	_refresh_planet_sprites()

func _refresh_planet_sprites() -> void:
	var live := _live_players()
	if live.is_empty() or current_camera_index >= live.size():
		return
	var active_ship = live[current_camera_index]
	var active_landed = active_ship.get("landed_planet")
	for planet in get_tree().get_nodes_in_group("planets"):
		if planet.get("is_sun"):
			continue
		if planet.has_method("set_player_landed"):
			planet.set_player_landed(active_landed == planet)
