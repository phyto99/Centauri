extends Node

var thrust_power:      float = 1000.0
var thrust_depletion:  float = 10.0
var fuel_efficiency:   float = 0.5
var fuel_recovery:     float = 2.0
var tick_speed:        float = 1.0
var session_duration:  float = 120.0
var map_json:          Dictionary = {}
var team_colors:       Array[Color] = []

signal settings_changed
signal game_started(config: Dictionary)

func _ready() -> void:
	team_colors = [
		Color(0, 1, 1),
		Color(1, 0, 1),
		Color(0, 1, 0),
		Color(1, 1, 0),
		Color(0, 0, 1),
		Color(1, 0, 0),
		Color(0, 0.5, 0),
	]

func apply_settings(cfg: Dictionary) -> void:
	if cfg.has("thrustPower"):      thrust_power      = float(cfg["thrustPower"])
	if cfg.has("thrustDepletion"):  thrust_depletion  = float(cfg["thrustDepletion"])
	if cfg.has("fuelEfficiency"):   fuel_efficiency   = float(cfg["fuelEfficiency"])
	if cfg.has("fuelRecovery"):     fuel_recovery     = float(cfg["fuelRecovery"])
	if cfg.has("tickSpeed"):        tick_speed        = float(cfg["tickSpeed"])
	if cfg.has("sessionDuration"):  session_duration  = maxf(10.0, float(cfg["sessionDuration"]))
	if cfg.has("mapJson") and cfg["mapJson"] != null:
		map_json = cfg["mapJson"]
	if cfg.has("teamColors") and cfg["teamColors"] is Array:
		_apply_team_colors(cfg["teamColors"])
	Engine.time_scale = tick_speed
	settings_changed.emit()

func _apply_team_colors(arr: Array) -> void:
	if arr.is_empty():
		return
	team_colors.clear()
	for i in arr.size():
		var tc: Dictionary = arr[i]
		var hex: int = int(tc.get("color", 0))
		team_colors.append(Color(
			((hex >> 16) & 0xff) / 255.0,
			((hex >> 8)  & 0xff) / 255.0,
			( hex        & 0xff) / 255.0
		))

func color_for(team_id: int) -> Color:
	if team_colors.is_empty():
		return Color.WHITE
	return team_colors[team_id % team_colors.size()]
