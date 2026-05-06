extends Node2D

@export var player_scene: PackedScene
@export var planet_scene: PackedScene

@export var player1_position: Vector2 = Vector2(100, 100)
@export var player2_position: Vector2 = Vector2(300, 100)

func _ready():
	spawn_test_players()

func _sun_radius(sun: Node) -> float:
	var poly = sun.collision_shape.polygon
	if poly.size() > 0:
		return poly[0].length()
	return 300.0

func spawn_test_players():
	var sun_list = get_tree().get_nodes_in_group("sun_planet")

	# Configs: [team_id, color_id]
	var configs = [[0, 1], [1, 2], [1, 3], [1, 4], [1, 5]]

	if not sun_list.is_empty():
		var sun: Node = sun_list[0]
		var radius := _sun_radius(sun)
		for i in range(configs.size()):
			var angle := i * TAU / configs.size()
			var dir := Vector2(cos(angle), sin(angle))
			var player = player_scene.instantiate()
			player.team_id = configs[i][0]
			add_child(player)
			player.global_position = sun.global_position + dir * radius
			player.set_team_color(configs[i][1])
			player.attach_to_planet(sun)
	else:
		# Fallback: hardcoded positions when no sun exists
		for i in range(configs.size()):
			var pos = player1_position if i == 0 else player2_position
			var player = player_scene.instantiate()
			player.team_id = configs[i][0]
			player.global_position = pos
			add_child(player)
			player.set_team_color(configs[i][1])
