class_name GameState
extends Node
## Автозагрузка «Game»: глобальное состояние — ветер, солнце, время суток.
## Единственный источник истины о ветре: его читают шейдер песка, моря,
## существ и частицы. Ссылки water/main — для событий (круги на воде).
##
## Никакого HUD и текста не предусмотрено: сила заброса читается по
## удилищу, поклёвка — по поплавку, день/ночь — крутилкой F3.

# --- Светила и палитра (по умолчанию — золотой час над морем) ---
# Направление К солнцу — вар (меняется DEV-панелью F3)
var night01 := 0.0 # 0=день … 1=ночь: красит свет, песок, небо, море, туман
var sun_dir := Vector3(-0.55, 0.185, -0.30).normalized()

const SAND_SUNNY := Color(0.98, 0.62, 0.30)
const SAND_HOT := Color(1.00, 0.78, 0.42)
const SAND_SHADE := Color(0.47, 0.40, 0.56)
const HORIZON_COL := Color(1.00, 0.70, 0.48)
const SKY_COL := Color(0.27, 0.24, 0.44)

const FOG_DISTANCE := 340.0

# --- Ветер ---
var wind_base := 0.18 # дует с моря на берег (почти +X), чуть вдоль берега
var wind_angle := 0.18 # текущее (гуляет вокруг базы)
var wind_strength := 1.0
var elapsed := 0.0

# --- Состояние игрока (читают: камера, музыка, звук) ---
var sprint01 := 0.0 # 0..1 — насколько путник разогнался
var player_altitude := 0.0

# --- Ссылки на узлы (ставит main.gd) ---
var main = null
var water = null # WaterSurface — круги от шагов в воде


func _ready() -> void:
	_ensure_input()


func _process(delta: float) -> void:
	elapsed += delta
	# Ветер живёт: медленно гуляет направление и сила (сумма синусов).
	wind_angle = wind_base + 0.28 * sin(elapsed * 0.021) + 0.12 * sin(elapsed * 0.047 + 1.7)
	wind_strength = 1.0 + 0.22 * sin(elapsed * 0.033 + 4.0) + 0.10 * sin(elapsed * 0.081)


func wind_dir() -> Vector2:
	return Vector2(cos(wind_angle), sin(wind_angle))


func wind_dir_3d() -> Vector3:
	return Vector3(cos(wind_angle), 0.0, sin(wind_angle))


## Страховка: если action-ы из project.godot не подхватились — добавляем кодом.
func _ensure_input() -> void:
	_add_key_action("move_forward", [KEY_W, KEY_UP])
	_add_key_action("move_back", [KEY_S, KEY_DOWN])
	_add_key_action("move_left", [KEY_A, KEY_LEFT])
	_add_key_action("move_right", [KEY_D, KEY_RIGHT])
	_add_key_action("jump", [KEY_SPACE])
	_add_key_action("sprint", [KEY_SHIFT])
	_add_key_action("rod_toggle", [KEY_Q])
	_add_key_action("flashlight", [KEY_F])
	if not InputMap.has_action("rod_cast"):
		InputMap.add_action("rod_cast")
		var mouse := InputEventMouseButton.new()
		mouse.button_index = MOUSE_BUTTON_LEFT
		InputMap.action_add_event("rod_cast", mouse)
	if not InputMap.has_action("rod_recall"):
		InputMap.add_action("rod_recall")
		var mb := InputEventMouseButton.new()
		mb.button_index = MOUSE_BUTTON_RIGHT
		InputMap.action_add_event("rod_recall", mb)
		var k := InputEventKey.new()
		k.physical_keycode = KEY_R
		InputMap.action_add_event("rod_recall", k)


func _add_key_action(action: String, keys: Array) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action)
	for k in keys:
		var ev := InputEventKey.new()
		ev.physical_keycode = k
		InputMap.action_add_event(action, ev)
