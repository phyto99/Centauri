extends Node
## Web-only. Inert on native builds — GameConfig keeps defaults.

var _settings_cb: JavaScriptObject
var _start_cb:    JavaScriptObject

func _ready() -> void:
	if OS.get_name() != "Web":
		return
	_register_callbacks()
	_connect_to_room()

func _register_callbacks() -> void:
	_settings_cb = JavaScriptBridge.create_callback(_on_settings)
	_start_cb    = JavaScriptBridge.create_callback(_on_start)
	JavaScriptBridge.get_interface("window")._godotSettingsCallback = _settings_cb
	JavaScriptBridge.get_interface("window")._godotStartCallback    = _start_cb

func _connect_to_room() -> void:
	var room_id := _room_id_from_url()
	if room_id.is_empty():
		push_warning("ColyseusSync: no roomId in URL, running with defaults")
		return
	JavaScriptBridge.eval(_colyseus_js())
	JavaScriptBridge.eval("""
		(function() {
			var script = document.createElement('script');
			script.src = '/colyseus.js';
			script.onload = function() { _centauriConnect('%s'); };
			document.head.appendChild(script);
		})();
	""" % room_id)

func _colyseus_js() -> String:
	return """
		function _centauriConnect(roomId) {
			var client = new Colyseus.Client('ws://' + window.location.host);
			client.joinById(roomId).then(function(room) {
				room.onMessage('settings_update', function(data) {
					if (window._godotSettingsCallback)
						window._godotSettingsCallback(JSON.stringify(data.config || data));
				});
				room.onMessage('game_start', function(data) {
					if (window._godotStartCallback)
						window._godotStartCallback(JSON.stringify(data.config || data));
				});
			}).catch(function(e) {
				console.warn('ColyseusSync: could not join room', roomId, e);
			});
		}
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
		GameConfig.apply_settings(result)
		GameConfig.game_started.emit(result)

func _room_id_from_url() -> String:
	var href: String = JavaScriptBridge.eval("window.location.pathname")
	var parts := href.strip_edges().split("/")
	for i in range(parts.size() - 1, -1, -1):
		if parts[i].length() > 4:
			return parts[i]
	return ""
