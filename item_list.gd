extends ItemList

func _ready():
	# Connect signals
	PlanetBuilder.connect("yield_updated", _on_yield_updated)
	PlanetBuilder.connect("food_updated", _on_food_updated)
	PlanetBuilder.connect("dominion_updated", _on_dominion_updated)
	PlanetBuilder.connect("diversity_updated", _on_diversity_updated)
	PlanetBuilder.connect("efficiency_updated", _on_efficiency_updated)
	
	# Set initial values from PlanetBuilder
	set_item_text(8, str(PlanetBuilder.yield_count))
	set_item_text(12, str(PlanetBuilder.food))
	set_item_text(13, str(PlanetBuilder.dominion))
	set_item_text(14, str(PlanetBuilder.diversity))
	set_item_text(15, str(round(PlanetBuilder.efficiency * 10) / 10) + "%")

func _on_yield_updated(count):
	set_item_text(8, str(count))

func _on_food_updated(amount):
	set_item_text(12, str(amount))

func _on_dominion_updated(amount):
	set_item_text(13, str(amount))

func _on_diversity_updated(amount):
	set_item_text(14, str(amount))

func _on_efficiency_updated(amount):
	set_item_text(15, str(round(amount * 10) / 10) + "%")
