class_name FishingDemo
extends Node3D
## Автономная демо-сцена комплекта «песчаное море + рыбалка»: вода, существа
## и удочка, собранные кодом в одну сцену. Служит ПРОВЕРКОЙ перед
## интеграцией: если эта сцена работает, комплект совместим с проектом.
##
## Запуск: сделай в проекте сцену с одной нодой Node3D и повесь этот скрипт,
## затем F6 (или root.add_child(FishingDemo.new()) из любого запускающего).
##
## Управление:
##   ЛКМ зажать / отпустить — заряд силы / заброс (сила видна по изгибу)
##   ЛКМ в окно поклёвки    — подсечка (поплавок нырнул под воду — момент)
##   ЛКМ держать в вываживании — мотать (в момент рывка нельзя)
##   ПКМ / R                — вернуть снасть / отменить заряд
##   клик по окну           — захват мыши (обзор), ESC — отпустить
##   WASD / Q E — полёт камеры, Shift — быстрее
##
## Демо живёт БЕЗ Terrain и без FpsArms: только море и снасть. В основную
## игру комплект ставится иначе (README, раздел «Заброс и поклёвка»):
##   rod := RodCast.new()
##   rig.cam.add_child(rod)
##   rod.setup(game, water, fish)
## Здесь вместо автозагрузки Game — утка DemoGame с теми же полями.

const CAM_POS := Vector3(0.0, 2.6, 16.0)

var water: GodotFishWaterSurface
var fish: GodotFishSandFish
var rod: GodotFishRodCast
var cam: Camera3D

var _keys := {}
var _speed := 6.0
var _yaw := 0.0
var _pitch := -0.12
var _mouse_captured := false


## Утка-заглушка автозагрузки Game: ровно те поля и методы, что читают
## WaterSurface / SandFish / RodCast: sun_dir, FOG_DISTANCE, wind_dir(),
## wind_strength. В основном проекте передают настоящий Game.
class DemoGame:
	var sun_dir := Vector3(0.10, 0.26, -0.96).normalized()
	var FOG_DISTANCE := 340.0
	var wind_strength := 1.0
	var _wind := Vector2(0.32, -0.95).normalized()

	func wind_dir() -> Vector2:
		return _wind


func _ready() -> void:
	var game := DemoGame.new()
	_build_sky(game.sun_dir)

	water = GodotFishWaterSurface.new()
	add_child(water)
	water.setup(game, Vector2.ZERO, 300.0, 0.0)
	#                 центр XZ     размер  уровень Y (0.0 = море в мировой нуле)

	fish = GodotFishSandFish.new()
	fish.fish_count = 4 # менять ДО add_child
	add_child(fish)
	fish.setup(game, water.level_y, water.field)

	_build_camera()
	rod = GodotFishRodCast.new()
	cam.add_child(rod) # удочка живёт НА КАМЕРЕ, как FpsArms
	rod.setup(game, water, fish)
	_connect_signals()


func _build_sky(sun_dir: Vector3) -> void:
	var sun := DirectionalLight3D.new()
	# лучи летят ПРОТИВ sun_dir (sun_dir — направление НА солнце, как в шейдерах)
	sun.look_at_from_position(Vector3.ZERO, Vector3.ZERO - sun_dir)
	sun.light_energy = 1.2
	sun.light_color = Color(1.0, 0.85, 0.66)
	add_child(sun)

	var env := Environment.new()
	var sky := Sky.new()
	var mat := ProceduralSkyMaterial.new()
	mat.sky_top_color = Color(0.28, 0.24, 0.43)
	mat.sky_horizon_color = Color(0.96, 0.66, 0.55)
	mat.ground_bottom_color = Color(0.40, 0.32, 0.52)
	mat.ground_horizon_color = Color(0.96, 0.66, 0.55)
	sky.sky_material = mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)


func _build_camera() -> void:
	cam = Camera3D.new()
	cam.position = CAM_POS
	cam.fov = 75.0
	cam.near = 0.05 # рукоять удочки в ~0.3 м от глаза
	cam.far = 1200.0
	add_child(cam)
	cam.make_current()


func _connect_signals() -> void:
	# сигналы RodCast — сюда вешается счёт/инвентарь/звук в основном проекте
	rod.cast_started.connect(func(p: float) -> void:
		print("DEMO: заброс, сила %.2f" % p))
	rod.bobber_landed.connect(func(pos: Vector3) -> void:
		print("DEMO: приводнение (%.1f, %.1f)" % [pos.x, pos.z]))
	rod.fish_hooked.connect(func() -> void:
		print("DEMO: ВЗЯЛА! Вываживай..."))
	rod.fish_landed.connect(func(sz: float) -> void:
		print("DEMO: поймал! размер %.2f" % sz))
	rod.fish_escaped.connect(func() -> void:
		print("DEMO: сход..."))
	rod.line_retrieved.connect(func() -> void:
		print("DEMO: снасть в руках"))


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and _mouse_captured:
		_yaw = wrapf(_yaw - event.relative.x * 0.0022, -PI, PI)
		_pitch = clampf(_pitch - event.relative.y * 0.0022, -1.2, 0.6)
	elif event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT and not _mouse_captured:
		_mouse_captured = true
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	elif event is InputEventKey:
		var k := event as InputEventKey
		_keys[k.keycode] = k.pressed
		if k.pressed and k.keycode == KEY_ESCAPE:
			_mouse_captured = false
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func _process(delta: float) -> void:
	if cam == null:
		return
	cam.rotation = Vector3(_pitch, _yaw, 0.0)
	var f := -cam.global_transform.basis.z
	var r := cam.global_transform.basis.x
	var move := Vector3.ZERO
	if _keys.get(KEY_W, false):
		move += f
	if _keys.get(KEY_S, false):
		move -= f
	if _keys.get(KEY_D, false):
		move += r
	if _keys.get(KEY_A, false):
		move -= r
	if _keys.get(KEY_E, false):
		move += Vector3.UP
	if _keys.get(KEY_Q, false):
		move -= Vector3.UP
	if move != Vector3.ZERO:
		var spd := _speed * (2.5 if _keys.get(KEY_SHIFT, false) else 1.0)
		cam.global_position += move.normalized() * spd * delta
	cam.global_position.y = maxf(cam.global_position.y, 0.6) # не нырять под море
