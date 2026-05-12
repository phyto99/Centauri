extends Node
## Godot-side WebSocket relay for peer position sync.
## process_mode ALWAYS so it runs while paused.

signal peer_connected(peer_id: int)
signal peer_disconnected(peer_id: int)
signal position_received(peer_id: int, pos: Vector2, rot: float, thrusting: bool)

const SEND_HZ := 20
const TYPE_DATA        := 0
const TYPE_PEER_CONN   := 1
const TYPE_PEER_DISC   := 2
const TYPE_YOUR_ID     := 3

var my_peer_id: int = 0
var is_host: bool = false

var _ws := WebSocketPeer.new()
var _connected := false
var _send_timer := 0.0
var _room_id := ""

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	ColyseusSync.host_assigned.connect(_on_host_assigned)
	if not ColyseusSync.room_id.is_empty():
		_connect_relay(ColyseusSync.room_id)
	# Native / no room: relay skipped, single-player only

func _on_host_assigned(peer_id: int, ih: bool) -> void:
	my_peer_id = peer_id
	is_host = ih

func _connect_relay(room: String) -> void:
	_room_id = room
	var host: String
	if OS.get_name() == "Web":
		var proto: String = str(JavaScriptBridge.eval("window.location.protocol === 'https:' ? 'wss:' : 'ws:'"))
		host = proto + "//" + str(JavaScriptBridge.eval("window.location.host"))
	else:
		host = "ws://localhost:3000"
	_ws.connect_to_url("%s/centauri-godot/%s" % [host, room])

func _process(delta: float) -> void:
	_ws.poll()
	var state := _ws.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if not _connected:
			_connected = true
		_drain_packets()
		_send_timer += delta
		if _send_timer >= 1.0 / SEND_HZ:
			_send_timer = 0.0
			PlayerSpawner.broadcast_local_position()
	elif state == WebSocketPeer.STATE_CLOSED and _connected:
		_connected = false

func _drain_packets() -> void:
	while _ws.get_available_packet_count() > 0:
		var pkt := _ws.get_packet()
		if pkt.size() < 5:
			continue
		var msg_type: int = pkt[0]
		var peer_id: int = pkt[1] | (pkt[2] << 8) | (pkt[3] << 16) | (pkt[4] << 24)
		match msg_type:
			TYPE_YOUR_ID:
				my_peer_id = peer_id
			TYPE_PEER_CONN:
				peer_connected.emit(peer_id)
			TYPE_PEER_DISC:
				peer_disconnected.emit(peer_id)
			TYPE_DATA:
				_parse_position(peer_id, pkt.slice(5))

func _parse_position(peer_id: int, payload: PackedByteArray) -> void:
	# 9 bytes: float32 x, float32 y, float32 rot, uint8 thrusting
	if payload.size() < 9:
		return
	var buf := StreamPeerBuffer.new()
	buf.data_array = payload
	buf.big_endian = false
	var x: float = buf.get_float()
	var y: float = buf.get_float()
	var rot: float = buf.get_float()
	var thrusting: bool = buf.get_u8() != 0
	position_received.emit(peer_id, Vector2(x, y), rot, thrusting)

func send_position(pos: Vector2, rot: float, thrusting: bool) -> void:
	if _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	# dest 0 = broadcast to all peers
	var buf := StreamPeerBuffer.new()
	buf.big_endian = false
	buf.put_u32(0)       # dest peer_id = broadcast
	buf.put_float(pos.x)
	buf.put_float(pos.y)
	buf.put_float(rot)
	buf.put_u8(1 if thrusting else 0)
	_ws.put_packet(buf.data_array)
