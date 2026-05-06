extends Node2D

@export var player_scene: PackedScene
@export var player_count: int = 5

func _ready() -> void:
	spawn_random_planets()
	spawn_players()

func spawn_players() -> void:
	var sun = get_tree().get_nodes_in_group("sun_planet").front()
	if not sun or not player_scene:
		return
	for i in range(player_count):
		var angle := i * TAU / player_count - PI / 2.0
		var p := player_scene.instantiate()
		p.team_id = i
		add_child(p)
		p.global_position = sun.global_position + Vector2.from_angle(angle) * sun.surface_radius

func spawn_random_planets() -> void:
	var sun = get_tree().get_nodes_in_group("sun_planet").front()
	if not sun:
		return
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	for i in range(6):
		var angle := i * TAU / 6.0 + rng.randf_range(-0.4, 0.4)
		var dist  := rng.randf_range(500.0, 1000.0)
		var planet := RigidBody2D.new()
		planet.set_script(load("res://PlanetBuilder.gd"))
		planet.sprite_scene       = sun.sprite_scene
		planet.claim_stamp_scene  = sun.claim_stamp_scene
		planet.cultivate_stamp_scene = sun.cultivate_stamp_scene
		planet.current_size = rng.randi_range(7, 60)
		planet.position     = Vector2.from_angle(angle) * dist
		add_child(planet)
