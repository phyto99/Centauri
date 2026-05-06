extends Control

func _ready():
	# Connect the start button signal
	$VBoxContainer/StartButton.pressed.connect(_on_start_button_pressed)
	
	# Connect the quit button signal
	$VBoxContainer/QuitButton.pressed.connect(_on_quit_button_pressed)
	
	# Preload the sound effects
	var ui_sound = preload("res://UI.wav")
	var button_sound = preload("res://Button.wav")
	
	# Set up the AudioStreamPlayer for UI sound
	var ui_player = AudioStreamPlayer.new()
	ui_player.stream = ui_sound
	ui_player.name = "UISound"
	add_child(ui_player)
	
	# Set up the AudioStreamPlayer for button sound
	var button_player = AudioStreamPlayer.new()
	button_player.stream = button_sound
	button_player.name = "ButtonSound"
	add_child(button_player)

func _on_start_button_pressed():
	# Play UI sound
	$UISound.play()
	
	# Wait for the sound to finish before changing scene
	await $UISound.finished
	
	# Change to the main game scene
	get_tree().change_scene_to_file("res://main.tscn")

func _on_quit_button_pressed():
	# Play button sound
	$ButtonSound.play()
	
	# Wait for the sound to finish before quitting
	await $ButtonSound.finished
	
	# Quit the game
	get_tree().quit()
