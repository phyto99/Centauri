extends Node
## Spawns/removes ships based on Colyseus roster + NetManager relay events.
## process_mode ALWAYS so team changes work while paused.

const PLAYER_SCENE := "res://player.tscn"
const ORBIT_RADIUS := 300.0  # fallback if no sun found

var _ships: Dictionary = {}      # peer_id → player node
var _local_peer_id: int = 0
var _main_node: Node = null
var _ship_back_dist: float = 50.0  # distance from ship center to its back edge
var _redistribute_queued: bool = false  # deduplicate deferred calls

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
	ColyseusSync.player_name_changed.connect(_on_player_name_changed)
	NetManager.peer_connected.connect(_on_relay_peer_connected)
	NetManager.peer_disconnected.connect(_on_relay_peer_disconnected)
	NetManager.position_received.connect(_on_position_received)
	GameConfig.game_started.connect(_on_game_started)

func _on_game_started(_cfg: Dictionary) -> void:
	_main_node = get_tree().get_first_node_in_group("main")

func _on_host_assigned(peer_id: int, _is_host: bool) -> void:
	_local_peer_id = peer_id
	_spawn_local(peer_id)
	_queue_redistribute()

func _on_player_joined(peer_id: int, team_id: int, player_name: String) -> void:
	if peer_id == _local_peer_id:
		if _ships.has(peer_id):
			(_ships[peer_id] as Node).call("set_team", team_id)
		return
	if _ships.has(peer_id):
		return
	_spawn_remote(peer_id, team_id, player_name)
	_queue_redistribute()

func _on_player_left(peer_id: int) -> void:
	if _ships.has(peer_id):
		_ships[peer_id].queue_free()
		_ships.erase(peer_id)
	_queue_redistribute()

func _on_player_team_changed(peer_id: int, team_id: int) -> void:
	if _ships.has(peer_id):
		(_ships[peer_id] as Node).call("set_team", team_id)
	Toast.display("Team changed")

func _on_player_name_changed(peer_id: int, new_name: String) -> void:
	if _ships.has(peer_id):
		(_ships[peer_id] as Node).call("set_player_name", new_name)

func _on_relay_peer_connected(peer_id: int) -> void:
	pass

func _on_relay_peer_disconnected(peer_id: int) -> void:
	_on_player_left(peer_id)

func _on_position_received(peer_id: int, pos: Vector2, rot: float, thrusting: bool, planet_idx: int) -> void:
	if not GameConfig.game_running:
		return
	if not _ships.has(peer_id) or peer_id == _local_peer_id:
		return
	var ship: Node = _ships[peer_id]
	ship.global_position = pos
	ship.global_rotation = rot
	ship.call("set_thrusting", thrusting)
	# Give the remote ship its landing state so player.gd's physics loop
	# moves it with the planet every frame (smooth), not just at 20 Hz (jittery).
	if planet_idx >= 0:
		var planet := _planet_by_idx(planet_idx)
		if planet != null and is_instance_valid(planet):
			ship.set("landed_planet", planet)
			ship.set("landing_offset", pos - planet.global_position)
			ship.set("planet_rotation_at_landing", planet.rotation)
		else:
			ship.set("landed_planet", null)
	else:
		ship.set("landed_planet", null)

func _planet_by_idx(pidx: int) -> Node:
	if _main_node == null:
		_main_node = get_tree().get_first_node_in_group("main")
	if _main_node == null:
		return null
	var dict: Variant = _main_node.get("_planet_by_idx")
	if dict is Dictionary and (dict as Dictionary).has(pidx):
		return (dict as Dictionary)[pidx]
	return null

func broadcast_local_position() -> void:
	if not _ships.has(_local_peer_id):
		return
	var ship: Node = _ships[_local_peer_id]
	var planet_idx: int = -1
	var lp: Variant = ship.get("landed_planet")
	if lp != null and is_instance_valid(lp as Node):
		var pidx: Variant = (lp as Node).get("planet_idx")
		if pidx != null:
			planet_idx = int(pidx)
	NetManager.send_position(ship.global_position, ship.global_rotation, ship.call("is_thrusting"), planet_idx)

func _spawn_local(peer_id: int) -> void:
	var ship: Node = _load_player()
	ship.set("is_local", true)
	ship.set("peer_id", peer_id)
	ship.set("player_name", ColyseusSync.local_name)
	ship.call("set_team", ColyseusSync.team_for_peer(peer_id))
	_add_ship(peer_id, ship)

func _spawn_remote(peer_id: int, team_id: int, player_name: String) -> void:
	var ship: Node = _load_player()
	ship.set("is_local", false)
	ship.set("peer_id", peer_id)
	ship.set("player_name", player_name)
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

# Defers redistribution to end-of-frame so rapid bursts of player_joined signals
# (e.g. full room state on join) all collapse into one layout pass.
func _queue_redistribute() -> void:
	if _redistribute_queued:
		return
	_redistribute_queued = true
	call_deferred("_redistribute_ships")

func _redistribute_ships() -> void:
	_redistribute_queued = false
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

	# Group ships by team, sorted by peer_id within each team for determinism
	var team_groups: Dictionary = {}  # team_id → [peer_id, ...]
	for pid in _ships.keys():
		var ship: Node = _ships[pid]
		if not is_instance_valid(ship):
			continue
		var tid: int = int(ship.get("team_id"))
		if not team_groups.has(tid):
			team_groups[tid] = []
		team_groups[tid].append(pid)

	var team_ids: Array = team_groups.keys()
	team_ids.sort()
	for tid in team_ids:
		team_groups[tid].sort()

	# Round-robin across teams so teammates are maximally spread around the circle.
	# Slot i → position (i * TAU / total - PI/2).  Same algorithm as singleplayer.
	var queues: Array = []
	for tid in team_ids:
		queues.append(team_groups[tid].duplicate())

	var slot_order: Array = []
	var any_left := true
	while any_left:
		any_left = false
		for q in queues:
			if not q.is_empty():
				slot_order.append(q.pop_front())
				any_left = true

	var total: int = max(slot_order.size(), 1)
	for i in range(slot_order.size()):
		var pid: int = slot_order[i]
		var ship: Node = _ships[pid]
		if not is_instance_valid(ship):
			continue
		var angle: float = float(i) * TAU / float(total) - PI / 2.0
		ship.global_position = center + Vector2.from_angle(angle) * spawn_r
		ship.global_rotation = angle
