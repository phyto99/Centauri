extends Node

var players = []
var current_camera_index = 0
var team_color = "" # New variable to store the current team's color

func _ready():
	# Find all players in the scene
	call_deferred("initialize_cameras")

func initialize_cameras():
	# Wait a frame to ensure all players are spawned
	await get_tree().process_frame
	
	# Find all players
	players = get_tree().get_nodes_in_group("players")
	
	# If no players were found, they might not be in a group
	if players.size() == 0:
		# Try to find all instances of your player class
		# Replace "Player" with your actual player class name
		var potential_players = get_tree().get_nodes_in_group("Player")
		
		# Or scan the entire tree for RigidBody2D nodes
		if potential_players.size() == 0:
			for node in get_tree().get_nodes_in_group("RigidBody2D"):
				if node.has_node("Camera2D"):
					players.append(node)
	
	print("Found " + str(players.size()) + " players with cameras")
	
	# Disable all cameras initially
	for player in players:
		if player.has_node("Camera2D"):
			player.get_node("Camera2D").enabled = false
	
	# Enable the first camera and set initial team color
	if players.size() > 0:
		set_active_camera(0)

func _input(event):
	# Number key handling for camera switching
	if event is InputEventKey and event.pressed:
		for i in range(10):  # 0-9 keys
			if event.keycode == KEY_0 + i:  # KEY_0, KEY_1, etc.
				if i == 0:
					# Treat 0 key as 10th player
					if 9 < players.size():
						set_active_camera(9)
				else:
					# 1-9 keys correspond to players 0-8
					if i-1 < players.size():
						set_active_camera(i-1)

func set_active_camera(index):
	if index < 0 or index >= players.size():
		return
		
	# Disable all cameras
	for player in players:
		if player.has_node("Camera2D"):
			player.get_node("Camera2D").enabled = false
	
	# Enable the selected camera
	players[index].get_node("Camera2D").enabled = true
	current_camera_index = index
	
	# Set the team color based on the player's team
	# You'll need to adapt this part based on how your player nodes store team information
	if players[index].has_method("get_team_color"):
		# If the player has a method to get its team color
		team_color = players[index].get_team_color()
	elif players[index].has_meta("team_color"):
		# If the player has metadata for team color
		team_color = players[index].get_meta("team_color")
	elif players[index].get("team_color") != null:
		# If the player has a team_color property
		team_color = players[index].team_color
	else:
		# Fallback: assign team colors based on index
		var colors = ["cyan", "magenta", "lime", "gold"]
		team_color = colors[index % colors.size()]
	
	print("Switched to player " + str(index + 1) + "'s view, Team color: " + team_color)
