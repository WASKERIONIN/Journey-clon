class_name BiteSystem
extends RefCounted
## Ожидание поклёвки — порт из bridge-mind/tideline (MIT), переписан на GDScript.
##
## Три состояния: ждём (WAIT) → рыба пробует наживку (тихие «тычки»,
## поплавок дрожит) → настоящая поклёвка (WINDOW, поплавок ныряет,
## есть короткое окно на подсечку). Рыба «выкатывается» в момент поклёвки,
## поэтому время суток и зона имеют значение именно тогда.
##
## Промах не отменяет заброс: рыба уходит, и ожидание начинается заново
## (как в tideline). Сход с крючка и обрыв — забота FishFight.

signal nibble
signal bite_started(fish: Dictionary)
signal bite_missed(fish: Dictionary)

enum B { IDLE, WAIT, WINDOW }

## Окно подсечки: база × множитель редкости (0.80…1.15) = 0.84…1.21 с.
const HOOK_WINDOW_BASE := 1.05

var state: int = B.IDLE
var zone := "shallow"
var segment := "day"
var fish: Dictionary = {}
var rng := RandomNumberGenerator.new()

var _wait := 0.0
var _t := 0.0
var _window := 0.0
var _window_total := 1.0
var _nibbles: Array[float] = []
var _nibble_end := 0.0
var _dip := 0.0
var _wind := 1.0
var _stats: Dictionary = {}
var forced_id := "" # тест: конкретный вид вместо случайного


func _init() -> void:
	rng.randomize()


## Начать ждать поклёвку в зоне (после падения поплавка на воду).
func begin(p_zone: String, p_segment: String, wind: float,
		stats: Dictionary = {}) -> void:
	zone = p_zone
	segment = p_segment
	_wind = wind
	_stats = stats
	_nibbles.clear()
	fish = {}
	_t = 0.0
	_nibble_end = 0.0
	_dip = 0.0
	_wait = FishCatalog.roll_wait(zone, segment, wind, rng)
	var speed: float = _stats.get("bite_speed", 1.0)
	_wait *= clampf(speed, 0.5, 2.0)
	# «тычки» перед настоящей поклёвкой: 1–2 раза, в разных долях ожидания
	if rng.randf() < 0.65:
		_nibbles.append(_wait * rng.randf_range(0.40, 0.55))
	if rng.randf() < 0.35:
		_nibbles.append(_wait * rng.randf_range(0.70, 0.85))
	state = B.WAIT


func cancel() -> void:
	state = B.IDLE
	fish = {}
	_nibbles.clear()
	_dip = 0.0


## Сколько поплавок «утоплен» сейчас (0..1): читается визуалом.
func dip() -> float:
	if state == B.WINDOW:
		return 0.34
	return _dip


func window_left() -> float:
	return _window


## Остаток окна подсечки 0..1 — для индикатора в HUD.
func window01() -> float:
	if not in_window():
		return 0.0
	return clampf(_window / maxf(_window_total, 0.001), 0.0, 1.0)


func in_window() -> bool:
	return state == B.WINDOW


func update(delta: float) -> void:
	if state == B.IDLE:
		return
	if _nibble_end > 0.0:
		_nibble_end -= delta
		if _nibble_end <= 0.0:
			_nibble_end = 0.0
			_dip = 0.0
	if state == B.WAIT:
		_t += delta
		if not _nibbles.is_empty() and _t >= _nibbles[0]:
			_nibbles.pop_front()
			_dip = 0.10
			_nibble_end = 0.35
			nibble.emit()
		if _t >= _wait:
			_start_bite()
	elif state == B.WINDOW:
		_window -= delta
		if _window <= 0.0:
			var missed := fish
			_dip = 0.0
			# рыба ушла, но заброс остался: ждём следующую
			begin(zone, segment, _wind, _stats)
			bite_missed.emit(missed)


## Игрок подсекает. Возвращает пойманную рыбу или {} если окно уже закрыто.
func hook_attempt() -> Dictionary:
	if state != B.WINDOW:
		return {}
	var caught := fish
	state = B.IDLE
	fish = {}
	_dip = 0.0
	return caught


## Тест/скриншоты: мгновенная настоящая поклёвка (без ожидания).
func debug_force_bite() -> void:
	if state == B.WAIT:
		_t = _wait
		_start_bite()


func _start_bite() -> void:
	if forced_id != "":
		var sp := FishCatalog.find_species(forced_id)
		if not sp.is_empty():
			fish = FishCatalog.make_fish(sp, rng)
		else:
			fish = FishCatalog.roll_fish(zone, segment, rng)
	else:
		fish = FishCatalog.roll_fish(zone, segment, rng)
	_window = float(fish.get("hook_window", HOOK_WINDOW_BASE))
	_window_total = _window
	_nibbles.clear()
	_dip = 0.34
	state = B.WINDOW
	bite_started.emit(fish)
