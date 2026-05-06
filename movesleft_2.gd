extends Label

func _process(_delta):
	text = str(PlanetBuilder.moves_remaining)
