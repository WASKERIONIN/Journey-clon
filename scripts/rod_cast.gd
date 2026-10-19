class_name RodCast
extends Node3D
## Удочка от первого лица: «достать» → заряд → заброс (Безье, нормировка
## длиной дуги, всё на delta) → поплавок на воде → ожидание и поклёвка
## (BiteSystem, порт tideline) → подсечка → вываживание (FishFight: натяг,
## прогресс, рывки, усталость) → рыба в руках (CatchFish + CatchCard).
##
## Удилище — не одна палка, а ЦЕПОЧКА из 20 сегментов: изгиб распределяется
## по «костям» с нарастающим весом к вершинке, поэтому гнётся дугой в заброс,
## в поклёвку и в рывок рыбы. Кончик всегда смотрит в сторону лески, а поза
## удилища опущена ниже и уходит вправо — кадр не перекрыт.
##
## Управление:
##   ЛКМ (удочка опущена) — достать удочку
##   ЛКМ зажать     — заряд силы (видно по позе удилища)
##   ЛКМ отпустить  — заброс туда, куда смотрит камера (6–48 м от силы)
##   ЛКМ в окно поклёвки (поплавок нырнул) — подсечка
##   ЛКМ держать в вываживании — мотать; в рывок рыбы нельзя: натяг растёт
##   ПКМ / R        — вернуть снасть / отменить заряд
##   Q              — убрать удочку
##
## HUD (scripts/fishing_hud.gd) показывает: что нажать, силу заброса, окно
## подсечки, натяг/прогресс вываживания и сматывание. В мире: маркер-кольцо
## над поплавком в окно поклёвки, изгиб удилища, круг на воде.
##
## Сигналы: cast_started(power), bobber_landed(pos), cast_landed_on_sand(pos),
## bite_window_started(), fish_hooked(), fish_landed(size), fish_escaped(),
## line_retrieved(), reel_tick(), fish_caught(info), bite_missed(),
## line_snap(), tension_changed(t01), surge_telegraph().

signal cast_started(power: float)
signal bobber_landed(pos: Vector3)
signal cast_landed_on_sand(pos: Vector3)
signal bite_window_started()
signal fish_hooked()
signal fish_landed(fish_size: float)
signal fish_escaped()
signal line_retrieved()
signal reel_tick()
signal fish_caught(info: Dictionary)
signal bite_missed()
signal line_snap()
signal tension_changed(t01: float)
signal surge_telegraph()

enum S { RESTING, CHARGE, FLY, FLOAT, BITE, FIGHT, REEL_IN }

# --- заброс ---
const MIN_CAST := 6.0
const CAST_RANGE := 42.0
const CAST_SPEED := 26.0
const CHARGE_PERIOD := 1.7

# --- удилище ---
const ROD_SEGMENTS := 20
const BLANK_LEN := 1.48
const BLANK_Y0 := 0.12
const HANDLE_LEN := 0.27
const GRIP_POS := Vector3(0.36, -0.62, -0.56)
const STOW_POS := Vector3(0.32, -0.66, -0.50)
const HOLD_DIR := Vector3(0.60, 0.42, -0.68) # поза в камере: вправо-вверх-вперёд
const MAX_BEND := 1.30
const LAND_DIST := 3.0
const REEL_SPEED := 5.8   # м/с — леску видно, она не «телепортируется»
const REEL_TICK := 0.13

var game: GameState
var water: WaterSurface
var fish: SandFish # оставлен для совместимости; бой рыб теперь в FishFight
var coast: Coast
var sand: SandField

var stats: Dictionary = FishCatalog.default_stats()
var bite: BiteSystem
var fight: FishFight
var last_fish: Dictionary = {}

var state: int = S.RESTING
var stowed := true
var on_land := false
var zone := "shallow"

var _cam: Camera3D
var _t := 0.0
var _suppress := 0.4
var _await_release := false # клик, достававший удочку, не должен сразу её заряжать

# удилище
var _rod: Node3D
var _segs: Array[MeshInstance3D] = []
var _seg_len := BLANK_LEN / float(ROD_SEGMENTS)
var _root_pos := STOW_POS
var _root_q := Quaternion.IDENTITY
var _stow_q := Quaternion.IDENTITY
var _bend := 0.05
var _whip := 0.0
var _whip_phase := 0.0
var _bend_axis := Vector3.RIGHT
var _tip_local := Vector3.ZERO
var _tip_dir := Vector3.UP
var _bite_mark: Node3D

# мир
var _world: Node3D
var _bobber: Node3D
var _line_mi: MeshInstance3D
var _line_mesh: ImmediateMesh
var _catch: CatchFish
var _held: CatchFish
var _jump_t := 0.0
var _jump_from := Vector3.ZERO
var _held_t := 0.0

# заброс
var _power_t := 0.0
var _bez_a := Vector3.ZERO
var _bez_b := Vector3.ZERO
var _bez_c := Vector3.ZERO
var _lut := PackedFloat32Array()
var _bez_len := 1.0
var _fly_s := 0.0

# вываживание
var _tension := 0.0
var _reel_tick_t := 0.0
var _reel_from := 1.0
var _reel_ticks := 0.0


func _ready() -> void:
	_ensure_actions()
	_cam = get_parent() as Camera3D
	if _cam == null:
		push_error("ROD: RodCast должен висеть на Camera3D")
		return
	bite = BiteSystem.new()
	fight = FishFight.new()
	bite.nibble.connect(_on_bite_nibble)
	bite.bite_started.connect(_on_bite_started)
	bite.bite_missed.connect(_on_bite_missed)
	fight.surge_telegraph.connect(_on_surge_telegraph)
	fight.jumped.connect(_on_fight_jump)
	fight.finished.connect(_on_fight_finished)
	_build_rod()
	_build_world()


## Подключение к игре: water — WaterSurface, coast — берег, sand — следы.
## fish оставлен в подписи ради совместимости вызова из main.gd.
func setup(game_ref, water_ref, fish_ref, coast_ref = null, sand_ref = null) -> void:
	game = game_ref
	water = water_ref
	fish = fish_ref
	coast = coast_ref
	sand = sand_ref
	if _catch != null:
		_catch.bind_sdf(fish)
	if _held != null:
		_held.bind_sdf(fish)


func _ensure_actions() -> void:
	_add_mouse_action("rod_cast", MOUSE_BUTTON_LEFT)
	_add_mouse_action("rod_recall", MOUSE_BUTTON_RIGHT)
	if InputMap.has_action("rod_recall"):
		var k := InputEventKey.new()
		k.physical_keycode = KEY_R
		InputMap.action_add_event("rod_recall", k)
	_add_key_action("rod_toggle", KEY_Q)


func _add_mouse_action(action: String, button: MouseButton) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action)
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	InputMap.action_add_event(action, ev)


func _add_key_action(action: String, key: Key) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action)
	var ev := InputEventKey.new()
	ev.physical_keycode = key
	InputMap.action_add_event(action, ev)


func _process(delta: float) -> void:
	_t += delta
	if _suppress > 0.0:
		_suppress -= delta
	match state:
		S.RESTING:
			_st_resting(delta)
		S.CHARGE:
			_st_charge(delta)
		S.FLY:
			_st_fly(delta)
		S.FLOAT:
			_st_float(delta)
		S.BITE:
			_st_bite(delta)
		S.FIGHT:
			_st_fight(delta)
		S.REEL_IN:
			_st_reel(delta)
	_update_rod(delta)
	_update_visual_fish(delta)
	_update_bite_mark(delta)
	_draw_line()


# ---------------------------------------------------------------------------
# Состояния
# ---------------------------------------------------------------------------

func _st_resting(_delta: float) -> void:
	if stowed:
		# первый клик — достаём удочку (не забрасываем той же кнопкой)
		if Input.is_action_just_pressed("rod_cast") and water != null:
			stowed = false
			_await_release = true
		return
	if _await_release:
		# ждём, пока кнопку отпустят: иначе тот же клик уйдёт в заряд
		if not Input.is_action_pressed("rod_cast"):
			_await_release = false
		return
	if _suppress > 0.0:
		return
	if Input.is_action_just_pressed("rod_toggle"):
		stowed = true
		return
	# is_action_pressed, а не just_pressed: клик, пришедший в «глухие»
	# полсекунды после поимки, больше не теряется — заряд начнётся,
	# как только рука снова готова
	if water != null and Input.is_action_pressed("rod_cast"):
		state = S.CHARGE
		_power_t = 0.0


func charge_power() -> float:
	# 0→1→0, период CHARGE_PERIOD (без глобального pingpong — совместимо везде)
	var t := fmod(_power_t / CHARGE_PERIOD, 2.0)
	return 1.0 - absf(t - 1.0)


func _st_charge(delta: float) -> void:
	_power_t += delta
	if Input.is_action_just_released("rod_cast"):
		_cast(charge_power())
	elif Input.is_action_just_pressed("rod_recall"):
		# отмена заряда: если поплавок уже на воде — возвращаемся к ожиданию
		state = S.FLOAT if _bobber.visible else S.RESTING


## Целимся: сначала вода, но если по лучу раньше встречается песок —
## поплавок падает на песок (и рыбы туда не придут).
func _cast(power: float) -> void:
	if _cam == null or water == null:
		return
	var origin := _cam.global_position
	var fdir := -_cam.global_transform.basis.z
	var hd := Vector2(fdir.x, fdir.z)
	if hd.length_squared() < 1e-6:
		hd = Vector2(0.0, -1.0)
	hd = hd.normalized()

	var max_d := MIN_CAST + power * CAST_RANGE * float(stats.get("cast_mult", 1.0))
	var water_d := INF
	if fdir.y < -0.02:
		var wd: float = (water.level_y - origin.y) / fdir.y
		if wd > 0.0:
			water_d = wd
	var land_d := INF
	if coast != null:
		land_d = _ray_ground(origin, fdir, max_d + 50.0)

	var dist := max_d
	on_land = false
	var land_point := Vector3.ZERO
	if land_d < water_d and land_d < max_d + 0.01:
		on_land = true
		land_point = origin + fdir * land_d
		dist = land_d
	elif water_d < INF:
		dist = minf(water_d, max_d)

	var target := Vector3(origin.x + hd.x * dist, water.level_y, origin.z + hd.y * dist)
	if not on_land and coast != null and not coast.is_water(target.x, target.z):
		# луч пересёк уровень моря НАД сушей (слабый заброс вдоль пляжа) —
		# это песок, а не вода: поплавок должен лечь на него, а не висеть
		on_land = true
		land_point = target
		dist = maxf(land_point.distance_to(origin), 0.5)
		target = Vector3(target.x, coast.ground_height(target.x, target.z) + 0.06, target.z)
	if on_land:
		var gh: float = coast.ground_height(land_point.x, land_point.z)
		target = Vector3(land_point.x, gh + 0.06, land_point.z)

	_bez_a = _tip_world()
	_bez_c = target
	_bez_b = (_bez_a + _bez_c) * 0.5 + Vector3.UP * (1.5 + 0.28 * dist)
	_build_lut()
	_bez_len = _lut[12]
	_fly_s = 0.0
	_bobber.visible = true
	state = S.FLY
	_whip = 1.0
	_whip_phase = 0.0
	cast_started.emit(power)


func _st_fly(delta: float) -> void:
	_fly_s += delta * CAST_SPEED # путь нормирован длиной дуги — скорость честная
	var u := _lut_u(_fly_s)
	_bobber.global_position = _bez(_bez_a, _bez_b, _bez_c, u)
	if _fly_s >= _bez_len:
		_bobber.global_position = _bez_c
		if on_land:
			# шлёпнулся на песок: вмятина, никакой рыбы
			if sand != null:
				sand.stamp_foot(
					Vector2(_bez_c.x, _bez_c.z), Vector2(0.0, -1.0),
					0.16, 0.20, 0.022, 0.012
				)
			cast_landed_on_sand.emit(_bez_c)
			state = S.FLOAT
		else:
			if water != null and water.field != null:
				water.field.splash(Vector2(_bez_c.x, _bez_c.z), 0.8)
			var origin := _cam.global_position
			var flat := Vector2(_bez_c.x - origin.x, _bez_c.z - origin.z).length()
			zone = FishCatalog.zone_for_distance(flat)
			bite.begin(zone, FishCatalog.time_segment(game.night01),
				game.wind_strength, stats)
			bobber_landed.emit(_bez_c)
			state = S.FLOAT


func _st_float(delta: float) -> void:
	_bobber.global_position = _sit(delta)
	if Input.is_action_just_pressed("rod_recall"):
		_recall()
		return
	if not on_land:
		bite.update(delta)
		if state != S.FLOAT:
			return # поклёвка началась в этом же кадре — не перебиваем её зарядом
	if Input.is_action_just_pressed("rod_cast") and _suppress <= 0.0:
		# леска уже в воде: ЛКМ сначала СМАТЫВАЕТ её (видно, как поплавок
		# идёт к берегу), и только потом можно заряжать новый заброс
		_recall()


func _st_bite(delta: float) -> void:
	_bobber.global_position = _sit(delta)
	bite.update(delta)
	if state != S.BITE:
		return
	if _suppress <= 0.0 and Input.is_action_just_pressed("rod_cast"):
		var caught := bite.hook_attempt()
		if not caught.is_empty():
			_begin_fight(caught)
			return
	if Input.is_action_just_pressed("rod_recall"):
		_recall()


func _begin_fight(f: Dictionary) -> void:
	last_fish = f
	_tension = 0.0
	_reel_tick_t = 0.0
	var player_flat := Vector3(_cam.global_position.x, 0.0, _cam.global_position.z)
	fight.start(f, _bobber.global_position, player_flat, stats)
	state = S.FIGHT
	_catch.setup(f)
	_catch.visible = false
	_jump_t = 0.0
	_held.visible = false
	_whip = 0.55
	if water != null and water.field != null:
		var bp := _bobber.global_position
		water.field.splash(Vector2(bp.x, bp.z), 1.0)
	fish_hooked.emit()


func _st_fight(delta: float) -> void:
	var reeling := Input.is_action_pressed("rod_cast") and _suppress <= 0.0
	var wy := water.surface_height(fight.fish_point.x, fight.fish_point.z)
	fight.update(delta, reeling, stats, _hand_target(), wy)
	if state != S.FIGHT:
		return # сигнал finished уже перевёл состояние
	var fp := fight.fish_world_pos
	_bobber.global_position = fp + Vector3.UP * 0.04
	_tension = fight.tension
	tension_changed.emit(fight.tension / 100.0)
	var t01 := fight.tension / 100.0
	if reeling and not fight.is_surging():
		_reel_tick_t -= delta
		if _reel_tick_t <= 0.0:
			_reel_tick_t = 0.11
			reel_tick.emit()
	if water != null and water.field != null:
		water.field.wake(Vector2(fp.x, fp.z), 0.45 + 0.6 * t01)
	if reeling:
		_bobber.global_position.y -= 0.10 * t01
	if fight.phase == "landing":
		_bobber.visible = false
	elif not fight.is_surging() and _jump_t <= 0.0:
		_catch.visible = false


func _st_reel(delta: float) -> void:
	var bp := _bobber.global_position
	var cp := _cam.global_position
	var to_cam := Vector2(cp.x - bp.x, cp.z - bp.z)
	if to_cam.length() > 2.2:
		# леска наматывается на катушку постепенно — с щелчками и кругами
		var home := Vector3(to_cam.x, 0.0, to_cam.y).normalized()
		bp += home * REEL_SPEED * delta
		if on_land and coast != null:
			bp.y = coast.ground_height(bp.x, bp.z) + 0.06
		elif water != null:
			bp.y = water.surface_height(bp.x, bp.z) + 0.035
		_bobber.global_position = bp
		if water != null and water.field != null and not on_land:
			water.field.wake(Vector2(bp.x, bp.z), 0.45)
		_reel_ticks -= delta
		if _reel_ticks <= 0.0:
			_reel_ticks = REEL_TICK
			reel_tick.emit()
	else:
		state = S.RESTING
		on_land = false
		_bobber.visible = false
		line_retrieved.emit()


# ---------------------------------------------------------------------------
# События BiteSystem
# ---------------------------------------------------------------------------

func _on_bite_nibble() -> void:
	if state != S.FLOAT:
		return
	if water != null and water.field != null:
		var bp := _bobber.global_position
		water.field.nibble(Vector2(bp.x, bp.z))
	if sand != null and on_land:
		sand.stamp_foot(Vector2(_bobber.global_position.x, _bobber.global_position.z),
			Vector2(0, -1), 0.10, 0.10, 0.01, 0.005)


func _on_bite_started(f: Dictionary) -> void:
	if state != S.FLOAT and state != S.BITE:
		return
	last_fish = f
	state = S.BITE
	if water != null and water.field != null:
		var bp := _bobber.global_position
		water.field.splash(Vector2(bp.x, bp.z), 1.1)
	bite_window_started.emit()


func _on_bite_missed(_f: Dictionary) -> void:
	if state != S.BITE:
		return
	state = S.FLOAT
	_suppress = 0.25
	bite_missed.emit()


# ---------------------------------------------------------------------------
# События FishFight
# ---------------------------------------------------------------------------

func _on_surge_telegraph() -> void:
	_whip = maxf(_whip, 0.8)
	surge_telegraph.emit()
	if water != null and water.field != null:
		var bp := _bobber.global_position
		water.field.splash(Vector2(bp.x, bp.z), 0.8)
	_bobber.global_position.y += 0.05


func _on_fight_jump(pos: Vector3) -> void:
	var wy := water.surface_height(pos.x, pos.z)
	_jump_from = Vector3(pos.x, wy, pos.z)
	_jump_t = 0.85
	_catch.setup(last_fish)
	_catch.visible = true
	if water != null and water.field != null:
		water.field.splash(Vector2(pos.x, pos.z), 1.3)


func _on_fight_finished(result: String) -> void:
	if result == "landed":
		_land_fish()
	elif result == "snapped":
		_fail(true)
	else:
		_fail(false)


func _land_fish() -> void:
	var size_cm: float = float(last_fish.get("size_cm", 0.0))
	_catch.visible = false
	_bobber.visible = false
	_jump_t = 0.0
	state = S.RESTING
	stowed = false
	_suppress = 0.5
	tension_changed.emit(0.0)
	_held.setup(last_fish)
	# Экранный «осмотр улова»: выводим SDF-рыбу в центр перед камерой,
	# не прячем её низко в позе у груди. Размер по виду ограничен уже в
	# CatchFish, поэтому даже крупный марлин не вылезает за кадр.
	_held.scale = Vector3.ONE * 0.90
	_held.position = Vector3(0.0, 0.02, -1.65)
	_held.rotation = Vector3(0.0, PI * 0.5, 0.0)
	_held.set_wiggle(0.10)
	_held.visible = true
	_held_t = 2.4
	fish_landed.emit(size_cm)
	fish_caught.emit(last_fish)


func _fail(line_broke: bool) -> void:
	_catch.visible = false
	_jump_t = 0.0
	tension_changed.emit(0.0)
	fish_escaped.emit()
	if line_broke:
		# леска лопнула — снасть потеряна, нужен новый заброс
		_bobber.visible = false
		state = S.RESTING
		_suppress = 0.6
		line_snap.emit()
	else:
		# рыба сошла с крючка: поплавок остался, ждём следующую
		state = S.FLOAT
		_suppress = 0.4
		bite.begin(zone, FishCatalog.time_segment(game.night01),
			game.wind_strength, stats)


# ---------------------------------------------------------------------------
# Возврат снасти
# ---------------------------------------------------------------------------

func _recall() -> void:
	bite.cancel()
	# клик, которым сматывали, не должен превратиться в новый заряд
	if Input.is_action_pressed("rod_cast"):
		_await_release = true
	_reel_from = maxf(line_out_distance(), 1.0)
	_reel_ticks = 0.0
	state = S.REEL_IN
	tension_changed.emit(0.0)


func _sit(delta: float) -> Vector3:
	var bp := _bobber.global_position
	if game != null and not on_land:
		var w2 := game.wind_dir()
		bp.x += w2.x * 0.12 * delta
		bp.z += w2.y * 0.12 * delta
	var dip_m := 0.0
	if not on_land:
		dip_m = bite.dip() * 0.62
		# Поплавок следует высоте и наклону той же волны, что рисует море.
		# Небольшая инерционная качка добавляется поверх поклёвки.
		var wave_y := water.surface_height(bp.x, bp.z)
		bp.y = wave_y + 0.035 - dip_m \
			+ sin(_t * 2.7 + bp.x * 0.31) * 0.018 * (1.0 - bite.dip())
		var eps := 0.18
		var sx := (water.surface_height(bp.x + eps, bp.z) - water.surface_height(bp.x - eps, bp.z)) / (2.0 * eps)
		var sz := (water.surface_height(bp.x, bp.z + eps) - water.surface_height(bp.x, bp.z - eps)) / (2.0 * eps)
		var normal := Vector3(-sx, 1.0, -sz).normalized()
		var axis_x := Vector3.RIGHT - normal * Vector3.RIGHT.dot(normal)
		if axis_x.length_squared() > 0.0001:
			axis_x = axis_x.normalized()
			var axis_z := axis_x.cross(normal).normalized()
			var target_basis := Basis(axis_x, normal, axis_z)
			var blend := 1.0 - exp(-5.0 * delta)
			_bobber.global_transform.basis = _bobber.global_transform.basis.slerp(target_basis, blend)
	elif coast != null:
		bp.y = coast.ground_height(bp.x, bp.z) + 0.06
	return bp


# ---------------------------------------------------------------------------
# Утилиты
# ---------------------------------------------------------------------------

func is_pulling() -> bool:
	return fight != null and fight.is_surging()


func is_surging() -> bool:
	return fight != null and fight.is_surging()


func fight_tension() -> float:
	return fight.tension if fight != null else 0.0


func fight_progress() -> float:
	return fight.progress if fight != null else 0.0


func bobber_position() -> Vector3:
	return _bobber.global_position


## Убрать рыбу из рук (телепорт/переход сцены — руки не должны «нести» её).
func clear_held() -> void:
	_held.visible = false
	_held_t = 0.0


## Тест/скриншоты: оборвать бой (сценарий не должен зависнуть в вываживании).
func debug_cancel_fight() -> void:
	if state == S.FIGHT:
		fight.stop()
		_catch.visible = false
		_bobber.visible = false
		_tension = 0.0
		state = S.RESTING
		stowed = false
		tension_changed.emit(0.0)


## Тест/скриншоты: мгновенная настоящая поклёвка.
func debug_fast_lure() -> void:
	if state == S.FLOAT and not on_land:
		_suppress = 0.0
		bite.debug_force_bite()


func _player_pos() -> Vector3:
	return Vector3(_cam.global_position.x, 0.0, _cam.global_position.z)


## Куда рыба прилетит в руки: чуть впереди и ниже глаз.
func _hand_target() -> Vector3:
	var fwd := -_cam.global_transform.basis.z
	return _cam.global_position + fwd * 1.05 - Vector3.UP * 0.30


## Марш луча по берегу: где луч встречает песок (или INF).
func _ray_ground(from: Vector3, dir: Vector3, max_d: float) -> float:
	var t := 0.4
	var step := 0.7
	var prev := t
	while t < max_d:
		var p := from + dir * t
		if p.y <= coast.ground_height(p.x, p.z):
			var lo := prev
			var hi := t
			for _k in range(10):
				var mid := (lo + hi) * 0.5
				var pm := from + dir * mid
				if pm.y <= coast.ground_height(pm.x, pm.z):
					hi = mid
				else:
					lo = mid
			return hi
		prev = t
		t += step
		step = minf(step * 1.12, 4.0)
	return INF


func _bez(a: Vector3, b: Vector3, c: Vector3, u: float) -> Vector3:
	var w := 1.0 - u
	return a * (w * w) + b * (2.0 * w * u) + c * (u * u)


## LUT длины дуги Безье: 13 отсчётов, накопленная дистанция.
func _build_lut() -> void:
	_lut.resize(13)
	_lut[0] = 0.0
	var prev := _bez_a
	var acc := 0.0
	for i in range(1, 13):
		var p := _bez(_bez_a, _bez_b, _bez_c, float(i) / 12.0)
		acc += prev.distance_to(p)
		_lut[i] = acc
		prev = p


func _lut_u(s: float) -> float:
	var sc := clampf(s, 0.0, _bez_len)
	for i in range(1, 13):
		if _lut[i] >= sc:
			var lo := _lut[i - 1]
			var hi := _lut[i]
			var f := 0.0 if hi <= lo else (sc - lo) / (hi - lo)
			return (float(i - 1) + f) / 12.0
	return 1.0


## Мир: поплавок, леска, видимая рыба. top_level — мировые координаты.
func _build_world() -> void:
	_world = Node3D.new()
	_world.top_level = true
	add_child(_world)

	_bobber = Node3D.new()
	_world.add_child(_bobber)
	var mat_lo := StandardMaterial3D.new()
	mat_lo.albedo_color = Color(0.86, 0.46, 0.33)
	mat_lo.roughness = 0.45
	var lo := MeshInstance3D.new()
	var sl := SphereMesh.new()
	sl.radius = 0.175
	sl.height = 0.35
	lo.mesh = sl
	lo.material_override = mat_lo
	_bobber.add_child(lo)
	# тёмная юбка: на светлой глади поплавок держит силуэт
	var skirt := MeshInstance3D.new()
	var sk := CylinderMesh.new()
	sk.top_radius = 0.10
	sk.bottom_radius = 0.013
	sk.height = 0.16
	sk.radial_segments = 10
	skirt.mesh = sk
	var sm := StandardMaterial3D.new()
	sm.albedo_color = Color(0.18, 0.10, 0.07)
	sm.roughness = 0.8
	skirt.material_override = sm
	skirt.position = Vector3(0.0, -0.20, 0.0)
	_bobber.add_child(skirt)
	var mat_hi := StandardMaterial3D.new()
	mat_hi.albedo_color = Color(1.0, 0.96, 0.88)
	mat_hi.roughness = 0.45
	mat_hi.emission_enabled = true
	mat_hi.emission = Color(0.55, 0.42, 0.24)
	mat_hi.emission_energy_multiplier = 0.55
	var hi := MeshInstance3D.new()
	var sh := SphereMesh.new()
	sh.radius = 0.120
	sh.height = 0.240
	hi.mesh = sh
	hi.material_override = mat_hi
	hi.position = Vector3(0.0, 0.135, 0.0)
	_bobber.add_child(hi)

	# Верхняя антенна с контрастным наконечником — поплавок читается в воде,
	# а леска действительно заканчивается на металлическом крепёжном ушке.
	var antenna := MeshInstance3D.new()
	var antenna_mesh := CylinderMesh.new()
	antenna_mesh.top_radius = 0.014
	antenna_mesh.bottom_radius = 0.022
	antenna_mesh.height = 0.17
	antenna_mesh.radial_segments = 8
	antenna.mesh = antenna_mesh
	var antenna_mat := StandardMaterial3D.new()
	antenna_mat.albedo_color = Color(0.80, 0.15, 0.10)
	antenna_mat.roughness = 0.5
	antenna_mat.emission_enabled = true
	antenna_mat.emission = Color(0.55, 0.06, 0.025)
	antenna_mat.emission_energy_multiplier = 0.38
	antenna.material_override = antenna_mat
	antenna.position = Vector3(0.0, 0.285, 0.0)
	_bobber.add_child(antenna)
	var eyelet := MeshInstance3D.new()
	var eyelet_mesh := TorusMesh.new()
	eyelet_mesh.inner_radius = 0.026
	eyelet_mesh.outer_radius = 0.041
	eyelet_mesh.ring_segments = 8
	eyelet_mesh.rings = 5
	eyelet.mesh = eyelet_mesh
	eyelet.scale = Vector3.ONE * 0.72
	eyelet.rotation.x = PI * 0.5
	var eyelet_mat := StandardMaterial3D.new()
	eyelet_mat.albedo_color = Color(0.20, 0.17, 0.13)
	eyelet_mat.metallic = 0.72
	eyelet_mat.roughness = 0.32
	eyelet.material_override = eyelet_mat
	eyelet.position = Vector3(0.0, 0.265, 0.0)
	_bobber.add_child(eyelet)
	_bobber.visible = false

	# маркер поклёвки: два вертикальных кольца крестом над поплавком.
	# Горизонтальное кольцо вдали читается полоской, а крест видно с любого
	# ракурса — на 40 м поплавок сам по себе всего пара пикселей.
	_bite_mark = Node3D.new()
	var rm := StandardMaterial3D.new()
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rm.albedo_color = Color(1.0, 0.78, 0.36)
	rm.emission_enabled = true
	rm.emission = Color(1.0, 0.62, 0.22)
	rm.emission_energy_multiplier = 2.4
	for i in 2:
		var ring := MeshInstance3D.new()
		var tor := TorusMesh.new()
		tor.inner_radius = 0.38
		tor.outer_radius = 0.47
		tor.ring_segments = 24
		ring.mesh = tor
		ring.material_override = rm
		ring.rotation = Vector3(PI * 0.5, PI * 0.5 * float(i), 0.0)
		ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_bite_mark.add_child(ring)
	_bite_mark.visible = false
	_world.add_child(_bite_mark)

	_line_mi = MeshInstance3D.new()
	_line_mesh = ImmediateMesh.new()
	_line_mi.mesh = _line_mesh
	var lm := StandardMaterial3D.new()
	lm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lm.albedo_color = Color(0.14, 0.11, 0.09)
	_line_mi.material_override = lm
	_line_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_world.add_child(_line_mi)

	_catch = CatchFish.new()
	_catch.visible = false
	_world.add_child(_catch)

	_held = CatchFish.new()
	_held.visible = false
	if _cam != null:
		_cam.add_child(_held)


# ---------------------------------------------------------------------------
# Удилище: цепочка сегментов
# ---------------------------------------------------------------------------

func _build_rod() -> void:
	_rod = Node3D.new()
	add_child(_rod)
	_rod.visible = false # убранная удочка не торчит в кадре
	_rod.position = STOW_POS
	var stow_basis := Basis(Vector3.RIGHT, -2.05) * Basis(Vector3.UP, -0.22)
	_rod.basis = stow_basis
	_stow_q = Quaternion(stow_basis)
	_root_q = _stow_q
	_root_pos = STOW_POS

	var mat_cork := StandardMaterial3D.new()
	mat_cork.albedo_color = Color(0.42, 0.30, 0.19)
	mat_cork.roughness = 0.82
	var mat_carbon := StandardMaterial3D.new()
	# бланк светлее «чёрного карбона»: на светлом песке чёрное удилище
	# пропадает, и остаётся только леска
	mat_carbon.albedo_color = Color(0.37, 0.30, 0.24)
	mat_carbon.roughness = 0.46
	mat_carbon.metallic = 0.18
	var mat_metal := StandardMaterial3D.new()
	mat_metal.albedo_color = Color(0.60, 0.57, 0.50)
	mat_metal.roughness = 0.30
	mat_metal.metallic = 0.85

	# рукоять
	var handle := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.017
	cm.bottom_radius = 0.021
	cm.height = HANDLE_LEN
	cm.radial_segments = 10
	handle.mesh = cm
	handle.material_override = mat_cork
	handle.position = Vector3(0.0, BLANK_Y0 - HANDLE_LEN * 0.5, 0.0)
	_rod.add_child(handle)

	# комель и катушкодержатель
	var seat := MeshInstance3D.new()
	var cs := CylinderMesh.new()
	cs.top_radius = 0.0165
	cs.bottom_radius = 0.0165
	cs.height = 0.055
	cs.radial_segments = 10
	seat.mesh = cs
	seat.material_override = mat_metal
	seat.position = Vector3(0.0, BLANK_Y0 + 0.02, 0.0)
	_rod.add_child(seat)

	# 20 сегментов бланка: «кости» с нарастающим изгибом
	_segs.clear()
	for i in range(ROD_SEGMENTS):
		var r0 := lerpf(0.0210, 0.0065, float(i) / float(ROD_SEGMENTS - 1))
		var r1 := lerpf(0.0210, 0.0065, float(i + 1) / float(ROD_SEGMENTS - 1))
		var mi := MeshInstance3D.new()
		var cm2 := CylinderMesh.new()
		cm2.bottom_radius = r0
		cm2.top_radius = r1
		cm2.height = _seg_len * 1.04
		cm2.radial_segments = 6
		mi.mesh = cm2
		mi.material_override = mat_carbon
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_rod.add_child(mi)
		_segs.append(mi)

	# светящийся кончик — по нему видно леску и поклёвку
	var tip := MeshInstance3D.new()
	var ts := SphereMesh.new()
	ts.radius = 0.006
	ts.height = 0.012
	ts.radial_segments = 6
	ts.rings = 4
	tip.mesh = ts
	var tm := StandardMaterial3D.new()
	tm.albedo_color = Color(0.98, 0.62, 0.24)
	tm.emission_enabled = true
	tm.emission = Color(1.0, 0.55, 0.18)
	tm.emission_energy_multiplier = 0.9
	tip.material_override = tm
	tip.position = Vector3(0.0, BLANK_Y0 + BLANK_LEN, 0.0)
	_rod.add_child(tip)

	# катушка: барабан с осью поперёк бланка + дужка лесоукладывателя
	var drum := MeshInstance3D.new()
	var dm := CylinderMesh.new()
	dm.top_radius = 0.030
	dm.bottom_radius = 0.030
	dm.height = 0.036
	dm.radial_segments = 14
	drum.mesh = dm
	drum.material_override = mat_metal
	drum.position = Vector3(0.0, 0.058, 0.046)
	drum.rotation.z = PI * 0.5
	_rod.add_child(drum)
	var bail := MeshInstance3D.new()
	var bm := TorusMesh.new()
	bm.inner_radius = 0.038
	bm.outer_radius = 0.044
	bm.ring_segments = 12
	bail.mesh = bm
	bail.material_override = mat_metal
	bail.position = Vector3(0.012, 0.058, 0.046)
	bail.rotation.y = PI * 0.5
	_rod.add_child(bail)

	# ручка катушки сбоку
	var crank := MeshInstance3D.new()
	var cc := CylinderMesh.new()
	cc.top_radius = 0.005
	cc.bottom_radius = 0.005
	cc.height = 0.050
	cc.radial_segments = 6
	crank.mesh = cc
	crank.material_override = mat_metal
	crank.position = Vector3(0.048, 0.058, 0.046)
	crank.rotation.z = PI * 0.5
	_rod.add_child(crank)

	_update_spine(0.0)


## Базис с +Y вдоль dir (для сегментов удилища).
func _basis_from_up(dir: Vector3) -> Basis:
	var ref := Vector3.RIGHT
	if absf(dir.dot(ref)) > 0.95:
		ref = Vector3.FORWARD
	var z := ref.cross(dir).normalized()
	var x := dir.cross(z).normalized()
	return Basis(x, dir, z)


func _fight_t01() -> float:
	if fight == null:
		return 0.0
	return clampf(fight.tension / 100.0, 0.0, 1.0)


## Куда смотрит удилище: горизонталь к цели + подъём по состоянию.
func _aim_dir(d: Vector3) -> Vector3:
	var to := d.normalized() if d.length_squared() > 0.0001 else HOLD_DIR
	# Удочка стоит ДИАГОНАЛЬЮ через кадр (вправо-вверх), а не смотрит торцом
	# в поплавок: бланк видно целиком, кончик не лезет в середину кадра.
	# В вываживании доля «позы» падает — удилище тянется к рыбе.
	var w := 0.80
	match state:
		S.CHARGE:
			w = 0.86
		S.FLY:
			w = 0.72
		S.BITE:
			w = 0.66
		S.FIGHT:
			w = 0.62 - 0.22 * _fight_t01()
	var aim := (HOLD_DIR.normalized() * w + to * (1.0 - w)).normalized()
	if state == S.CHARGE:
		# замах: удилище уходит назад-вверх
		aim = (aim + Vector3(0.0, 0.55, 0.60) * charge_power()).normalized()
	elif state == S.BITE and bite != null:
		# поклёвка: кончик клюёт вниз
		aim = (aim + Vector3(0.0, -0.30, 0.0) * bite.dip()).normalized()
	return aim


func _dir_to_target() -> Vector3:
	var target := _cam.global_position - _cam.global_transform.basis.z * 12.0 - Vector3.UP * 2.0
	if state in [S.FLY, S.FLOAT, S.BITE, S.FIGHT] and _bobber.visible:
		target = _bobber.global_position
	var local := _cam.global_transform.affine_inverse() * target
	var d := local - GRIP_POS
	if d.length_squared() < 0.0001:
		d = Vector3(0.0, -1.0, -3.0)
	return d.normalized()


func _update_rod(delta: float) -> void:
	_rod.visible = not stowed
	var target_pos := GRIP_POS
	var target_q := _root_q
	var bend_target := 0.03
	var axis_cam := Vector3.RIGHT
	# хлыст затухает всегда, даже когда удилище убрано
	_whip = maxf(0.0, _whip - delta * 2.4)
	_whip_phase += delta * 34.0
	if stowed:
		target_pos = STOW_POS
		target_q = _stow_q
		bend_target = 0.015
	else:
		var d := _dir_to_target()
		var aim := _aim_dir(d)
		var roll := -0.22
		if state == S.CHARGE:
			roll = -0.10
		target_q = Quaternion(_basis_from_up(aim) * Basis(Vector3.UP, roll))
		axis_cam = aim.cross(d)
		if axis_cam.length_squared() < 0.003:
			axis_cam = Vector3.RIGHT
		else:
			axis_cam = axis_cam.normalized()
		var ang := aim.angle_to(d)
		var t01 := _fight_t01()
		var bend_k := 0.35
		match state:
			S.RESTING:
				bend_k = 0.22
			S.CHARGE:
				bend_k = 0.25
			S.FLY:
				bend_k = 0.55
			S.FLOAT:
				bend_k = 0.38
			S.BITE:
				bend_k = 0.85
			S.FIGHT:
				bend_k = 0.45 + 0.65 * t01
		bend_target = clampf(ang, 0.0, 1.25) * bend_k
		match state:
			S.CHARGE:
				bend_target += 0.06 + 0.20 * charge_power()
			S.FLY:
				bend_target += 0.22
			S.BITE:
				bend_target += 0.10
			S.FIGHT:
				bend_target += 0.10 + 0.40 * t01
		if state == S.FIGHT and fight != null and fight.is_surging():
			bend_target += 0.08 + 0.05 * sin(_t * 30.0)
		# хлыст: короткая затухающая волна после заброса / рывка / подсечки
		bend_target += _whip * 0.26 * sin(_whip_phase)
		# дыхание/дрожь рук
		var bob := Vector3(sin(_t * 0.9) * 0.004, sin(_t * 1.3) * 0.005, 0.0)
		if state == S.CHARGE:
			var p := charge_power()
			bob += Vector3(-0.012, 0.030, 0.075) * p
		elif state == S.FIGHT:
			var shake := 0.004 + 0.010 * t01
			bob += Vector3(sin(_t * 37.0), cos(_t * 29.0), 0.0) * shake
		target_pos = GRIP_POS + bob

	var k := 1.0 - exp(-10.0 * delta)
	_root_pos = _root_pos.lerp(target_pos, k)
	_root_q = _root_q.slerp(target_q, k)
	# ось изгиба — в системе координат удилища
	var axis_local := _root_q.inverse() * axis_cam
	if axis_local.length_squared() < 0.01:
		axis_local = Vector3.RIGHT
	else:
		axis_local = axis_local.normalized()
	_bend = lerpf(_bend, clampf(bend_target, 0.0, MAX_BEND), 1.0 - exp(-8.0 * delta))
	_bend_axis = _bend_axis.slerp(axis_local, 1.0 - exp(-8.0 * delta))
	if _bend_axis.length_squared() < 0.01:
		_bend_axis = Vector3.RIGHT
	else:
		_bend_axis = _bend_axis.normalized()
	_rod.transform = Transform3D(Basis(_root_q), _root_pos)
	_update_spine(_bend)


## Разложить изгиб по сегментам (вес растёт к вершинке) и запомнить кончик.
func _update_spine(bend: float) -> void:
	if _segs.is_empty():
		return
	var dir := Vector3.UP
	var p := Vector3(0.0, BLANK_Y0, 0.0)
	# вес растёт к вершинке нелинейно: основной изгиб — в последней трети,
	# комель держится прямым (так гнётся настоящий бланк)
	var wsum := 0.0
	for i in range(ROD_SEGMENTS):
		wsum += pow(float(i + 1) / float(ROD_SEGMENTS), 1.6)
	for i in range(ROD_SEGMENTS):
		var w := pow(float(i + 1) / float(ROD_SEGMENTS), 1.6) / wsum
		dir = dir.rotated(_bend_axis, bend * w)
		var mi := _segs[i]
		mi.transform = Transform3D(_basis_from_up(dir), p + dir * _seg_len * 0.5)
		p += dir * _seg_len
	_tip_local = p
	_tip_dir = dir


func _tip_world() -> Vector3:
	return _rod.to_global(_tip_local)


## Маркер поклёвки: кольцо над поплавком, пульсирует в такт окну подсечки.
func _update_bite_mark(delta: float) -> void:
	if _bite_mark == null:
		return
	var near := state == S.BITE and _bobber.visible
	_bite_mark.visible = near
	if not near:
		return
	var bp := _bobber.global_position
	_bite_mark.global_position = bp + Vector3.UP * 0.68
	_bite_mark.rotation.y += delta * 2.6
	var pulse := 1.0 + 0.12 * sin(_t * 14.0)
	_bite_mark.scale = Vector3(pulse, pulse, pulse)


## Дистанция лески (для HUD и подсказок): от глаз до поплавка.
func line_out_distance() -> float:
	if _cam == null or not _bobber.visible:
		return 0.0
	var d := _bobber.global_position - _cam.global_position
	return Vector2(d.x, d.z).length()


## Прогресс сматывания 0..1 (пока REEL_IN).
func reel_progress() -> float:
	if state != S.REEL_IN:
		return 0.0
	return clampf(1.0 - line_out_distance() / maxf(_reel_from, 0.001), 0.0, 1.0)


## Сколько осталось окна подсечки (0..1) — для полоски в HUD.
func bite_window01() -> float:
	return bite.window01() if bite != null else 0.0


## Готовность к забросу (HUD): удочка в руке и леска смотана.
func ready_to_cast() -> bool:
	return not stowed and state == S.RESTING


## Видимая рыба: прыжки в рывок и полёт в руки при вываживании.
func _update_visual_fish(delta: float) -> void:
	if _held.visible:
		_held_t -= delta
		# Не перезаписываем центрированный preview прежней позой «у груди».
		_held.position.y = 0.02 + sin(_t * 2.4) * 0.008
		_held.rotation.z = sin(_t * 3.1) * 0.015
		if _held_t <= 0.0:
			_held.visible = false
	if _jump_t > 0.0:
		_jump_t -= delta
		var k := clampf(1.0 - _jump_t / 0.85, 0.0, 1.0)
		var h := clampf(float(last_fish.get("size_cm", 40.0)) / 110.0, 0.5, 2.2)
		var arc := sin(k * PI) * h
		var yaw := atan2(_cam.global_position.x - _jump_from.x,
			_cam.global_position.z - _jump_from.z)
		_catch.pose_world(_jump_from + Vector3.UP * arc, yaw, lerpf(0.9, -1.2, k))
		if _jump_t <= 0.0:
			_catch.visible = false
	if fight == null or not fight.active:
		return
	if fight.phase == "landing":
		var fp := fight.landing_pos
		var yaw2 := atan2(fp.x - _cam.global_position.x, fp.z - _cam.global_position.z)
		_catch.pose_world(fp, yaw2, -0.4)


## Леска: от настоящего кончика удилища к поплавку, с провисом.
func _draw_line() -> void:
	_line_mesh.clear_surfaces()
	var line_on := state in [S.FLY, S.FLOAT, S.BITE, S.FIGHT]
	if not line_on or _cam == null or not _bobber.visible:
		return
	var tip := _tip_world()
	var end := _bobber.global_position + Vector3.UP * 0.265
	var sag := 0.08
	var t01 := _fight_t01()
	match state:
		S.FLOAT:
			sag = 0.10 + 0.03 * sin(_t * 1.7)
		S.BITE:
			sag = 0.035
		S.FIGHT:
			sag = 0.02 + 0.16 * (1.0 - t01)
	_render_line(tip, end, sag)


func _render_line(a: Vector3, b: Vector3, sag: float) -> void:
	var mid := (a + b) * 0.5 + Vector3.DOWN * sag
	_line_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	var steps := 12
	for i in range(steps + 1):
		var u := float(i) / float(steps)
		var w := 1.0 - u
		var p := a * (w * w) + mid * (2.0 * w * u) + b * (u * u)
		_line_mesh.surface_add_vertex(p)
	_line_mesh.surface_end()
