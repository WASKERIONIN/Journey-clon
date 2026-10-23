class_name CameraRig
extends Node3D
## Камера от первого лица: обзор мышью (захват курсора), глаза на высоте
## 1.66 м, лёгкое покачивание в такт шагам, FOV «дышит» на бегу.
## Фонарик — на случай ночи (F): тёплый конус, в волюметрическом тумане
## читается лучом. По умолчанию выключен — день и закат не нуждаются.

const EYE := 1.66
const FOV_BASE := 74.0
const FOV_SPRINT := 84.0
const PITCH_MIN := -1.35
const PITCH_MAX := 1.35
const SENS := 0.0022 # рад на пиксель

var cam: Camera3D
var player: Player
var flashlight: SpotLight3D
var flash_on := false

var yaw := PI # fwd = (sin(yaw), 0, cos(yaw))
var pitch := 0.0

var _fov := FOV_BASE
var _interactive := true


func setup(main_ref) -> void:
	player = main_ref.player
	_interactive = OS.get_environment("JOURNEY_SMOKE") != "1" \
		and OS.get_environment("JOURNEY_SHOT") != "1"

	cam = Camera3D.new()
	add_child(cam)
	cam.fov = FOV_BASE
	cam.near = 0.02 # удочка близко к камере
	cam.far = 2200.0
	cam.make_current()

	flashlight = SpotLight3D.new()
	cam.add_child(flashlight)
	flashlight.position = Vector3(0.10, -0.26, 0.0)
	flashlight.rotation_degrees = Vector3(-9.0, 0.0, 0.0)
	flashlight.spot_range = 34.0
	flashlight.spot_angle = 30.0
	# Мягкий край конуса: пятно на песке не «вырезано ножницами» и не
	# превращается в прожектор, который выжигает полкадра.
	flashlight.spot_angle_attenuation = 1.2
	# Затухание Godot ≈ (1-(d/range)^4)^2 * d^(-attenuation). Раньше тут
	# стояли decay 0.2 + энергия 5.0: фонарь почти не гас с расстоянием,
	# заливал всё вокруг и МАСКИРОВАЛ проблему — ночью песок был чёрным
	# именно без него. Теперь это честный конус на 15–20 м, а ночь должна
	# читаться и без фонаря (свет луны + ambient + emission).
	flashlight.spot_attenuation = 1.05
	flashlight.light_color = Color(1.0, 0.90, 0.74)
	flashlight.light_energy = 3.6
	# вью-модель удочки живёт на layer 2 — фонарь светит только мир
	flashlight.light_cull_mask = 1
	flashlight.light_volumetric_fog_energy = 1.4
	flashlight.shadow_enabled = true
	flashlight.shadow_bias = 0.04
	flashlight.shadow_normal_bias = 1.0
	flashlight.visible = flash_on

	yaw = player.heading
	if _interactive:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		apply_mouse_motion(event.relative)
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_ESCAPE and _interactive:
			# ESC — отпустить/захватить курсор (пауза-лайт)
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE \
				if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else Input.MOUSE_MODE_CAPTURED
		elif event.physical_keycode == KEY_F:
			flash_on = not flash_on
			flashlight.visible = flash_on
	elif event is InputEventMouseButton and event.pressed and _interactive:
		if event.button_index == MOUSE_BUTTON_LEFT \
				and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## Поворот взгляда мышью (радиан на пиксель) — общий путь для ввода и тестов.
func apply_mouse_motion(rel: Vector2) -> void:
	yaw = wrapf(yaw - rel.x * SENS, -PI, PI)
	pitch = clampf(pitch - rel.y * SENS, PITCH_MIN, PITCH_MAX)


## Задать взгляд напрямую (тесты/сценарии CI).
func set_view(new_yaw: float, new_pitch: float) -> void:
	yaw = wrapf(new_yaw, -PI, PI)
	pitch = clampf(new_pitch, PITCH_MIN, PITCH_MAX)


func _physics_process(delta: float) -> void:
	player.heading = yaw

	var p := player.global_position
	cam.global_position = p + Vector3(0.0, EYE + player.gait_bob(), 0.0)

	# взгляд: forward = (sin(yaw), 0, cos(yaw)) при pitch = 0
	var b := Basis(Vector3.UP, yaw + PI) * Basis(Vector3.RIGHT, pitch)
	cam.basis = b

	_update_fov(delta)


func _update_fov(delta: float) -> void:
	var hv := Vector3(player.vel.x, 0.0, player.vel.z)
	var spd01 := clampf((hv.length() - Player.WALK_MAX) / (Player.SPRINT_MAX - Player.WALK_MAX), 0.0, 1.0)
	var target_fov := lerpf(FOV_BASE, FOV_SPRINT, clampf(spd01 * 0.8 + player.sprint01 * 0.4, 0.0, 1.0))
	_fov = lerpf(_fov, target_fov, 1.0 - exp(-3.2 * delta))
	cam.fov = _fov
