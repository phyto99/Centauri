extends Node2D  # or Node, or whatever your main scene extends

# Preload the player scene
@export var player_scene: PackedScene  

# Starting positions for the test players
@export var player1_position: Vector2 = Vector2(100, 100)
@export var player2_position: Vector2 = Vector2(300, 100)
func _ready():
	# Spawn the test players
	spawn_test_players()

func spawn_test_players():
	# Spawn player 1 (cyan)
	var player1 = player_scene.instantiate()
	player1.team_id = 0  # Cyan
	player1.global_position = player1_position
	add_child(player1)
	player1.set_team_color(1)  # Explicitly call set_team_color after adding to scene
	
	# Spawn player 2 (magenta)
	var player2 = player_scene.instantiate()
	player2.team_id = 1  # Magenta
	player2.global_position = player2_position
	add_child(player2)
	player2.set_team_color(2)
	
	# Spawn player 2 (magenta)
	var player3 = player_scene.instantiate()
	player3.team_id = 1  # Magenta
	player3.global_position = player2_position
	add_child(player3)
	player3.set_team_color(3)
	
	var player4 = player_scene.instantiate()
	player4.team_id = 1  # Magenta
	player4.global_position = player2_position
	add_child(player4)
	player4.set_team_color(4)
	
	var player5 = player_scene.instantiate()
	player5.team_id = 1  # Magenta
	player5.global_position = player2_position
	add_child(player5)
	player5.set_team_color(5)
