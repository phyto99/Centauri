extends Button

func _ready():
	# Connect the button press signal to the return to menu function
	self.pressed.connect(_on_return_button_pressed)

func _on_return_button_pressed():
	# Change to the main scene
	get_tree().change_scene_to_file("res://menu.tscn")

	
	
	#Later you should make this go to --- New Game NOTICE NOTICE NOTICE NOTICE NOTICE NOTICE 
	#Quit to new game
