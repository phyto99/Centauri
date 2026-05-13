extends Node
## Web-only. Inert on native builds — GameConfig keeps defaults.

signal host_assigned(peer_id: int, is_host: bool)
signal player_joined(peer_id: int, team_id: int, player_name: String)
signal player_left(peer_id: int)
signal player_team_changed(peer_id: int, team_id: int)
signal player_name_changed(peer_id: int, player_name: String)

var room_id: String = ""
var known_players: Dictionary = {}  # peer_id → {name, team_id}
var local_name: String = ""

var _settings_cb: JavaScriptObject
var _start_cb:    JavaScriptObject
var _message_cb:  JavaScriptObject

func _ready() -> void:
	local_name = _generate_proxima_name()
	if OS.get_name() != "Web":
		return
	room_id = _room_id_from_url()
	_register_callbacks()
	_connect_to_room()

static func _generate_proxima_name() -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	while true:
		var pool := [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
		var d: Array[int] = []
		for _i in range(3):
			var idx := rng.randi_range(0, pool.size() - 1)
			d.append(pool[idx])
			pool.remove_at(idx)
		if (d[0] == 6 and d[1] == 7) or (d[1] == 6 and d[2] == 7):
			continue
		return "proxima%d%d%d" % [d[0], d[1], d[2]]
	return "proxima123"

func change_local_name(new_name: String) -> void:
	local_name = new_name
	if OS.get_name() == "Web":
		JavaScriptBridge.eval("if(window._centauriChangeName) window._centauriChangeName(%s);" % JSON.stringify(new_name))

func _register_callbacks() -> void:
	_settings_cb = JavaScriptBridge.create_callback(_on_settings)
	_start_cb    = JavaScriptBridge.create_callback(_on_start)
	_message_cb  = JavaScriptBridge.create_callback(_on_message)
	JavaScriptBridge.get_interface("window")._godotSettingsCallback = _settings_cb
	JavaScriptBridge.get_interface("window")._godotStartCallback    = _start_cb
	JavaScriptBridge.get_interface("window")._godotMessageCallback  = _message_cb

func _connect_to_room() -> void:
	if room_id.is_empty():
		push_warning("ColyseusSync: no roomId in URL, running with defaults")
		return
	JavaScriptBridge.eval("window._centauriPlayerName = %s;" % JSON.stringify(local_name))
	JavaScriptBridge.eval(_colyseus_js())
	JavaScriptBridge.eval("""
		fetch('/colyseus.js')
			.then(function(r){ return r.text(); })
			.then(function(code){
				(0, eval)(code);
				window._centauriConnect('%s');
			})
			.catch(function(e){ console.error('ColyseusSync: failed to load colyseus.js', e); });
	""" % room_id)

func _colyseus_js() -> String:
	return """
		window._centauriConnect = function(roomId) {
			var wsProto = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
			var client = new Colyseus.Client(wsProto + '//' + window.location.host);
			client.joinById(roomId, { name: window._centauriPlayerName || 'Player' }).then(function(room) {
				console.log('ColyseusSync: joined room', roomId, 'as session', room.sessionId);
				window._centauriChangeName = function(n) { room.send('change_name', { name: n }); };
				room.onMessage('settings_update', function(data) {
					if (window._godotSettingsCallback)
						window._godotSettingsCallback(JSON.stringify(data.config || data));
				});
				room.onMessage('game_start', function(data) {
					if (window._godotStartCallback)
						window._godotStartCallback(JSON.stringify(data));
				});
				room.onMessage('host_assigned', function(data) {
					console.log('ColyseusSync: host_assigned', data);
					if (window._godotMessageCallback)
						window._godotMessageCallback(JSON.stringify({type:'host_assigned', peerId:data.peerId, isHost:data.isHost}));
				});
				room.onMessage('player_joined', function(data) {
					console.log('ColyseusSync: player_joined', data);
					if (window._godotMessageCallback)
						window._godotMessageCallback(JSON.stringify({type:'player_joined', peerId:data.peerId, teamId:data.teamId, name:data.name}));
				});
				room.onMessage('player_left', function(data) {
					if (window._godotMessageCallback)
						window._godotMessageCallback(JSON.stringify({type:'player_left', peerId:data.peerId}));
				});
				room.onMessage('player_team_changed', function(data) {
					if (window._godotMessageCallback)
						window._godotMessageCallback(JSON.stringify({type:'player_team_changed', peerId:data.peerId, teamId:data.teamId}));
				});
				room.onMessage('player_name_changed', function(data) {
					if (window._godotMessageCallback)
						window._godotMessageCallback(JSON.stringify({type:'player_name_changed', peerId:data.peerId, name:data.name}));
				});
			}).catch(function(e) {
				console.error('ColyseusSync: could not join room', roomId, e);
			});
		};
	"""

func _on_settings(args: Array) -> void:
	var json_str: String = str(args[0]) if args.size() > 0 else ""
	var result: Variant = JSON.parse_string(json_str)
	if result is Dictionary:
		GameConfig.apply_settings(result)

func _on_start(args: Array) -> void:
	var json_str: String = str(args[0]) if args.size() > 0 else ""
	var result: Variant = JSON.parse_string(json_str)
	if result is Dictionary:
		var cfg: Dictionary = result.get("config", result) as Dictionary
		GameConfig.apply_settings(cfg)
		GameConfig.game_started.emit(result)

func _on_message(args: Array) -> void:
	var json_str: String = str(args[0]) if args.size() > 0 else ""
	var msg: Variant = JSON.parse_string(json_str)
	if not msg is Dictionary:
		return
	var t: String = str(msg.get("type", ""))
	match t:
		"host_assigned":
			var pid: int = int(msg.get("peerId", 0))
			var ih: bool = bool(msg.get("isHost", false))
			host_assigned.emit(pid, ih)
		"player_joined":
			var pid: int = int(msg.get("peerId", 0))
			var tid: int = int(msg.get("teamId", 0))
			var nm: String = str(msg.get("name", ""))
			known_players[pid] = {"name": nm, "team_id": tid}
			player_joined.emit(pid, tid, nm)
		"player_left":
			var pid: int = int(msg.get("peerId", 0))
			known_players.erase(pid)
			player_left.emit(pid)
		"player_team_changed":
			var pid: int = int(msg.get("peerId", 0))
			var tid: int = int(msg.get("teamId", 0))
			if known_players.has(pid):
				known_players[pid]["team_id"] = tid
			player_team_changed.emit(pid, tid)
		"player_name_changed":
			var pid: int = int(msg.get("peerId", 0))
			var nm: String = str(msg.get("name", ""))
			if known_players.has(pid):
				known_players[pid]["name"] = nm
			player_name_changed.emit(pid, nm)

func team_for_peer(peer_id: int) -> int:
	if known_players.has(peer_id):
		return int(known_players[peer_id]["team_id"])
	return 0

func _room_id_from_url() -> String:
	var href: String = JavaScriptBridge.eval("window.location.pathname")
	var parts := href.strip_edges().split("/")
	# Room IDs are alphanumeric (no hyphens) and at least 6 chars.
	# Skip known path segments like "centauri" and "centauri-mapmaker".
	for i in range(parts.size() - 1, -1, -1):
		var seg: String = parts[i]
		if seg.length() >= 6 and not seg.contains("-") and seg != "centauri":
			return seg
	return ""
