class_name FishFight
extends RefCounted
## Вываживание рыбы — порт поединка из bridge-mind/tideline (MIT).
##
## Две шкалы, обе невидимые (HUD нет): НАТЯГ и ПРОГРЕСС.
##   • держишь ЛКМ (подмотка) — прогресс растёт, натяг растёт;
##   • отпустил — натяг падает, но рыба отбирает леску (прогресс тает);
##   • рыба делает РЫВКИ: сначала предупреждение (0.75 с), потом 1.1–1.9 с
##     активной фазы. В рывок подматывать нельзя — натяг взлетает ×3.4.
## Натяг 100 — леска рвётся. Прогресс 0 дольше 2.5 с — рыба сходит с крючка.
## Уставшая рыба (после stamina, 9–24 с) слабеет и реже рвётся.
##
## События — сигналами: RodCast рисует поплавок/удилище/прыжки и играет звук,
## этот класс только считает бой. Никакой вёрстки и HUD.

signal surge_telegraph
signal surge_started
signal surge_ended
signal jumped(pos: Vector3)
signal finished(result: String) # "landed" | "snapped" | "escaped"

const REEL_RATE := 18.0       # %/с прогресса при подмотке
const ESCAPE_RATE := 3.8      # %/с прогресса теряется в покое
const TENSION_GAIN := 22.0    # %/с натяга при подмотке
const TENSION_RECOVER := 22.0 # %/с восстановления в покое
const SURGE_REEL_MULT := 3.4  # натяг при подмотке в рывок
const SURGE_REST_GAIN := 8.0  # натяг в рывок даже без подмотки
const TELEGRAPH_TIME := 0.75  # с — предупреждение о рывке
const SURGE_MIN := 1.1
const SURGE_MAX := 1.9
const START_PROGRESS := 8.0
const START_TENSION := 18.0
const MAX_FIGHT_TIME := 55.0
const ESCAPE_GRACE := 2.5
const MIN_FISH_DIST := 3.0
const TIRED_STRENGTH_MULT := 0.62
const TIRED_SURGE_SPACING := 1.6
const LANDING_TIME := 0.9

var active := false
var phase := "idle" # idle | fight | landing
var fish: Dictionary = {}
var tension := 0.0
var progress := 0.0
var t := 0.0
var fish_point := Vector3.ZERO # xz + относительная просадка по y
var fish_world_pos := Vector3.ZERO # где рыба в мире прямо сейчас
var landing_pos := Vector3.ZERO

var rng := RandomNumberGenerator.new()

var _stats: Dictionary = {}
var _player := Vector3.ZERO
var _start_dist := 12.0
var _angle := 0.0
var _angle_drift := 0.2
var _surge_state := "calm" # calm | telegraph | active
var _surge_t := 0.0
var _surge_timer := 0.0
var _surge_every: Array = [4.0, 6.5]
var _tired := false
var _land_t := 0.0
var _land_from := Vector3.ZERO
var _land_mid := Vector3.ZERO
var _land_to := Vector3.ZERO
var _zero_t := 0.0


func _init() -> void:
	rng.randomize()


func start(p_fish: Dictionary, start_pos: Vector3, player_pos: Vector3,
		stats: Dictionary) -> void:
	fish = p_fish
	_stats = stats
	_player = player_pos
	active = true
	phase = "fight"
	t = 0.0
	tension = START_TENSION
	progress = START_PROGRESS
	_tired = false
	_zero_t = 0.0
	var dx := start_pos.x - player_pos.x
	var dz := start_pos.z - player_pos.z
	_start_dist = maxf(4.0, Vector2(dx, dz).length())
	_angle = atan2(dx, dz)
	_angle_drift = rng.randf_range(0.2, 0.5) * (1.0 if rng.randf() < 0.5 else -1.0)
	fish_point = start_pos
	var fight: Dictionary = fish.get("fight", {})
	_surge_every = fight.get("surge_every", [4.0, 6.5])
	_surge_state = "calm"
	_surge_timer = rng.randf_range(_surge_every[0], _surge_every[1]) * 0.7
	_surge_t = 0.0
	_zero_t = 0.0


func stop() -> void:
	active = false
	phase = "idle"


func is_surging() -> bool:
	return _surge_state == "active"


func is_telegraphing() -> bool:
	return _surge_state == "telegraph"


func is_tired() -> bool:
	return _tired


## Основной шаг боя. land_target — куда рыба прилетит в руки (камера).
func update(delta: float, reeling: bool, stats: Dictionary,
		land_target: Vector3, water_y: float) -> void:
	if not active:
		return
	_stats = stats
	if phase == "landing":
		_update_landing(delta)
		return

	var fight: Dictionary = fish.get("fight", {})
	t += delta
	var stamina: float = float(fight.get("stamina", 10.0))
	_tired = t > stamina
	var strength: float = float(fight.get("strength", 1.0))
	if _tired:
		strength *= TIRED_STRENGTH_MULT
	var reel: float = float(stats.get("reel", 1.0))
	var line: float = float(stats.get("line", 1.0))
	var control: float = float(stats.get("control", 1.0))
	var heft: float = maxf(float(fight.get("heft", 1.0)), 0.4)

	_update_surge(delta)
	var surging := _surge_state == "active"

	if reeling:
		var surge_mult := 1.0 + (SURGE_REEL_MULT - 1.0) / maxf(control, 0.5)
		if not surging:
			surge_mult = 1.0
		tension += delta * TENSION_GAIN * strength * surge_mult / maxf(line, 0.5)
		progress += delta * (REEL_RATE * reel / heft) * (0.55 if surging else 1.0)
	else:
		tension -= delta * TENSION_RECOVER * (0.45 if surging else 1.0)
		if surging:
			tension += delta * SURGE_REST_GAIN * strength / maxf(line, 0.5)
		progress -= delta * ESCAPE_RATE * strength * (1.5 if surging else 0.7)

	if tension >= 100.0:
		_fail("snapped")
		return
	# рыба уходит, если леска провисла надолго, а не от первого касания нуля
	if progress <= 0.0:
		_zero_t += delta
	else:
		_zero_t = 0.0
	if _zero_t > ESCAPE_GRACE:
		_fail("escaped")
		return
	if t > MAX_FIGHT_TIME:
		_fail("escaped")
		return
	tension = clampf(tension, 0.0, 100.0)
	if progress >= 100.0:
		_begin_landing(land_target)
		return
	progress = maxf(progress, 0.0)

	# точка рыбы: ходит вокруг игрока и подходит с прогрессом
	var k := progress / 100.0
	var dist := lerpf(_start_dist, MIN_FISH_DIST, k)
	_angle += sin(t * 0.7) * _angle_drift * delta
	if surging:
		_angle += sin(t * 6.0) * 1.1 * delta
	fish_point = Vector3(
		_player.x + sin(_angle) * dist,
		0.0,
		_player.z + cos(_angle) * dist
	)
	var dive := -0.14 if surging else -0.02
	fish_point.y = dive # относительная поправка; мировую высоту даёт вода
	fish_world_pos = Vector3(fish_point.x, water_y + dive, fish_point.z)


## Позиция рыбы для вида (мировая высота подставляется водой).
func fish_world(water_y: float) -> Vector3:
	return Vector3(fish_point.x, water_y + fish_point.y, fish_point.z)


func _update_surge(delta: float) -> void:
	match _surge_state:
		"calm":
			_surge_timer -= delta
			if _surge_timer <= 0.0:
				_surge_state = "telegraph"
				_surge_t = TELEGRAPH_TIME
				surge_telegraph.emit()
				_try_jump()
		"telegraph":
			_surge_t -= delta
			if _surge_t <= 0.0:
				_surge_state = "active"
				_surge_t = rng.randf_range(SURGE_MIN, SURGE_MAX)
				surge_started.emit()
		"active":
			_surge_t -= delta
			if _surge_t <= 0.0:
				_surge_state = "calm"
				var spacing := TIRED_SURGE_SPACING if _tired else 1.0
				_surge_timer = rng.randf_range(_surge_every[0], _surge_every[1]) * spacing
				surge_ended.emit()


## Крупная рыба в предупреждении о рывке выпрыгивает из воды.
func _try_jump() -> void:
	var size_cm: float = float(fish.get("size_cm", 30.0))
	if size_cm < 30.0 or rng.randf() > 0.75:
		return
	jumped.emit(fish_world_pos)


func _begin_landing(land_target: Vector3) -> void:
	phase = "landing"
	_land_t = 0.0
	tension = 0.0
	_land_from = fish_world_pos
	_land_to = land_target
	_land_mid = (_land_from + _land_to) * 0.5 + Vector3.UP * 3.4
	landing_pos = _land_from


func _update_landing(delta: float) -> void:
	_land_t += delta
	var k := clampf(_land_t / LANDING_TIME, 0.0, 1.0)
	# квадратичная кривая Безье через высокую середину
	var a := _land_from.lerp(_land_mid, k)
	var b := _land_mid.lerp(_land_to, k)
	landing_pos = a.lerp(b, k)
	if k >= 1.0:
		active = false
		phase = "idle"
		finished.emit("landed")


func _fail(result: String) -> void:
	active = false
	phase = "idle"
	tension = 0.0
	finished.emit(result)
