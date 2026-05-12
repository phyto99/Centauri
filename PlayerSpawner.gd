extends Node
## Spawns/removes ships based on Colyseus roster + NetManager relay events.
## process_mode ALWAYS so team changes work while paused.

const PLAYER_SCENE := "res://player.tscn"
const ORBIT_RADIUS := 300.0  # fallback if no sun found

var _ships: Dictionary = {}      # peer_id → player node
var _local_peer_id: int = 0
var _main_node: Node = null
var _ship_back_dist: float = 50.0  # distance from ship center to its back edge

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Measure ship back edge once so spawn_r matches singleplayer's spawn_players()
	var scene: PackedScene = load(PLAYER_SCENE)
	if scene:
		var probe: Node = scene.instantiate()
		var cpoly = probe.get_node_or_null("CollisionPolygon2D")
		if cpoly and cpoly.polygon.size() > 0:
			var min_x := INF
			for pt: Vector2 in cpoly.polygon:
				min_x = min(min_x, pt.x)
			_ship_back_dist = -(min_x + cpoly.position.x)
		probe.free()
	ColyseusSync.host_assigned.connect(_on_host_assigned)
	ColyseusSync.player_joined.connect(_on_player_joined)
	ColyseusSync.player_left.connect(_on_player_left)
	ColyseusSync.player_team_changed.connect(_on_player_team_changed)
	NetManager.peer_connected.connect(_on_relay_peer_connected)
	NetManager.peer_disconnected.connect(_on_relay_peer_disconnected)
	NetManager.position_received.connect(_on_position_received)
	GameConfig.game_started.connect(_on_game_started)

func _on_game_started(_cfg: Dictionary) -> void:
	_main_node = get_tree().get_first_node_in_group("main")

func _on_host_assigned(peer_id: int, _is_host: bool) -> void:
	_local_peer_id = peer_id
	_spawn_local(peer_id)
	_redistribute_ships()

func _on_player_joined(peer_id: int, team_id: int, player_name: String) -> void:
	if peer_id == _local_peer_id:
		if _ships.has(peer_id):
			(_ships[peer_id] as Node).call("set_team", team_id)
		return
	if _ships.has(peer_id):
		return
	_spawn_remote(peer_id, team_id, player_name)
	_redistribute_ships()

func _on_player_left(peer_id: int) -> void:
	if _ships.has(peer_id):
		_ships[peer_id].queue_free()
		_ships.erase(peer_id)
	_redistribute_ships()

func _on_player_team_changed(peer_id: int, team_id: int) -> void:
	if _ships.has(peer_id):
		(_ships[peer_id] as Node).call("set_team", team_id)
	Toast.display("Team changed")

func _on_relay_peer_connected(peer_id: int) -> void:
	pass

func _on_relay_peer_disconnected(peer_id: int) -> void:
	_on_player_left(peer_id)

func _on_position_received(peer_id: int, pos: Vector2, rot: float, thrusting: bool) -> void:
	if _ships.has(peer_id) and peer_id != _local_peer_id:
		var ship: Node = _ships[peer_id]
		ship.global_position = pos
		ship.global_rotation = rot
		ship.call("set_thrusting", thrusting)

func broadcast_local_position() -> void:
	if _ships.has(_local_peer_id):
		var ship: Node = _ships[_local_peer_id]
		NetManager.send_position(ship.global_position, ship.global_rotation, ship.call("is_thrusting"))

func _spawn_local(peer_id: int) -> void:
	var ship: Node = _load_player()
	ship.set("is_local", true)
	ship.set("peer_id", peer_id)
	ship.call("set_team", ColyseusSync.team_for_peer(peer_id))
	_add_ship(peer_id, ship)

func _spawn_remote(peer_id: int, team_id: int, _player_name: String) -> void:
	var ship: Node = _load_player()
	ship.set("is_local", false)
	ship.set("peer_id", peer_id)
	ship.call("set_team", team_id)
	_add_ship(peer_id, ship)

func _load_player() -> Node:
	var scene: PackedScene = load(PLAYER_SCENE)
	return scene.instantiate()

func _add_ship(peer_id: int, ship: Node) -> void:
	_ships[peer_id] = ship
	if _main_node == null:
		_main_node = get_tree().get_first_node_in_group("main")
	var parent := _main_node if _main_node != null else get_tree().current_scene
	parent.add_child(ship)

func _redistribute_ships() -> void:
	if GameConfig.game_running:
		return
	var sun: Node = get_tree().get_nodes_in_group("sun_planet").front()
	var center := Vector2.ZERO
	var spawn_r := ORBIT_RADIUS
	if sun and is_instance_valid(sun):
		center = sun.global_position
		var sr_raw = sun.get("surface_radius")
		var sr: float = float(sr_raw) if sr_raw != null else float(sun.get("current_size") if sun.get("current_size") else 80)
		spawn_r = sr + _ship_back_dist

	var keys: Array = _ships.keys()
	keys.sort()
	var total: int = max(keys.size(), 1)
	for i in range(keys.size()):
		var pid: int = keys[i]
		var ship: Node = _ships[pid]
		if not is_instance_valid(ship):
			continue
		var angle: float = float(i) * TAU / float(total) - PI / 2.0
		ship.global_position = center + Vector2.from_angle(angle) * spawn_r
		ship.global_rotation = angle
