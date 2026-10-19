class_name GodotFishRodCast
extends Node3D
## Удочка от первого лица: заряд → заброс (Безье, нормировка длиной дуги,
## всё на delta) → поплавок на воде → поклёвка → подсечка → вываживание.
##
## Вешается НА КАМЕРУ (как FpsArms):
##   var rod := RodCast.new()
##   rig.cam.add_child(rod)
##   rod.setup(game, water, fish) # water: WaterSurface, fish: SandFish
##
## Управление (свои action-ы, пистолету не мешают):
##   ЛКМ зажать    — заряд силы (ходит туда-обратно, видна по позе удилища)
##   ЛКМ отпустить — заброс туда, куда смотрит камера (дальность от силы)
##   ЛКМ в окно поклёвки (поплавок нырнул) — подсечка
##   ЛКМ держать в вываживании — мотать (во время рывка рыбы нельзя)
##   ПКМ / R — вернуть поплавок / отменить заряд
##
## HUD нет (конвенция проекта): сила читается по изгибу/наклону удилища,
## поклёвка — по нырку поплавка и кольцам на воде. Поплавок качается на
## ТОЙ ЖЕ воде, что видит глаз: water.surface_height() = уровень + дыхание
## + кольца (CPU-зеркало шейдера).
##
## Сигналы: cast_started(power), bobber_landed(pos), bite_window_started(),
## fish_hooked(), fish_landed(size), fish_escaped(), line_retrieved().

signal cast_started(power: float)
signal bobber_landed(pos: Vector3)
signal bite_window_started()
signal fish_hooked()
signal fish_landed(size: float)
signal fish_escaped()
signal line_retrieved()

enum S { RESTING, CHARGE, FLY, FLOAT, BITE, FIGHT, REEL_IN }

# --- заброс ---
const MIN_CAST := 6.0 # м, ближе не плюнет
const CAST_RANGE := 42.0 # м поверх минимума при полной силе
const CAST_SPEED := 26.0 # м/с полёта поплавка (путь нормирован длиной дуги)
const CHARGE_PERIOD := 1.7 # с на полный ход силы туда-обратно

# --- рыбалка ---
const BITE_WINDOW := 0.55 # с, окно подсечки (рыба держит 0.85 — с запасом)
const REEL_SPEED := 6.5 # м/с подмотки с зажатой ЛКМ
const REEL_ASSIST := 1.1 # м/с ленивая подмотка без ЛКМ — чтобы не зависало
const FIGHT_MAX_DIST := 34.0 # м, дальше рыба вырывает леску (но не рвёт)
const TENSION_RATE := 1.9 # натяг растёт, если мотать в момент рывка
const LAND_DIST := 3.2 # м — рыба у игрока

# --- поза удилища (в пространстве камеры) ---
const GRIP_POS := Vector3(0.18, -0.17, -0.32)
const TIP_LOCAL := Vector3(0.0, 0.56, 0.0) # кончик вершинки в шарнире _tip

var game # автозагрузка Game — только ветер для дрейфа поплавка
var water # WaterSurface — уровень/высота воды
var fish # SandFish — всплески, приманивание, подсечка
var state: int = S.RESTING

var _cam: Camera3D
var _t := 0.0
var _suppress := 0.35 # с тишины после старта (клик захвата курсора)

# удилище
var _root: Node3D # рукоять + комель
var _tip: Node3D # шарнир вершинки (изгиб)
var _bend := 0.03 # текущий изгиб, рад (плюс = на себя, минус = вперёд)
var _bend_tgt := 0.03

# мир (top_level: дети живут в мировых координатах)
var _world: Node3D
var _bobber: Node3D
var _line_mi: MeshInstance3D
var _line_mesh: ImmediateMesh

# заряд/заброс
var _power_t := 0.0
var _bez_a := Vector3.ZERO
var _bez_b := Vector3.ZERO
var _bez_c := Vector3.ZERO
var _lut := PackedFloat32Array() # накопленные длины дуги, 13 точек
var _bez_len := 1.0
var _fly_s := 0.0 # пройденный поплавком путь, м

# рыбалка
var _bite_t := 0.0 # с до следующей попытки приманить рыбу
var _relure_t := 0.0 # троттлинг lure_to
var _window_t := 0.0 # осталось окна подсечки
var _lure_idx := -1 # рыба, идущая к поплавку
var _dive := 0.0 # текущее погружение поплавка, м
var _dive_tgt := 0.0
var _jiggle := 0.0 # тычок носом — мелкая дрожь
var _pulling := false # рыба тянет (в этот момент мотать нельзя)
var _pull_t := 0.0
var _tension := 0.0 # 0..1, при 1 — сход


func _ready() -> void:
	_ensure_actions()
	_cam = get_parent() as Camera3D
	if _cam == null:
		push_error("ROD: RodCast должен висеть на Camera3D")
	_build_rod()
	_build_world()


## Подключение к игре. water: WaterSurface, fish: SandFish (можно null —
## тогда удочка работает, но рыбы клевать не будут).
func setup(game_ref, water_ref, fish_ref) -> void:
	game = game_ref
	water = water_ref
	fish = fish_ref
	if fish != null and not fish.nibbled.is_connected(_on_fish_nibbled):
		fish.nibbled.connect(_on_fish_nibbled)
		fish.biting.connect(_on_fish_biting)
		fish.fish_freed.connect(_on_fish_freed)


func _ensure_actions() -> void:
	if not InputMap.has_action("rod_cast"):
		InputMap.add_action("rod_cast")
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		InputMap.action_add_event("rod_cast", ev)
	if not InputMap.has_action("rod_recall"):
		InputMap.add_action("rod_recall")
		var mb := InputEventMouseButton.new()
		mb.button_index = MOUSE_BUTTON_RIGHT
		InputMap.action_add_event("rod_recall", mb)
		var k := InputEventKey.new()
		k.physical_keycode = KEY_R
		InputMap.action_add_event("rod_recall", k)


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
	_animate_rod(delta)
	_draw_line()


# ---------------------------------------------------------------------------
# Состояния
# ---------------------------------------------------------------------------

func _st_resting(_delta: float) -> void:
	_bend_tgt = 0.03 + 0.015 * sin(_t * 1.3)
	if _suppress <= 0.0 and water != null and Input.is_action_just_pressed("rod_cast"):
		state = S.CHARGE
		_power_t = 0.0


func charge_power() -> float:
	return pingpong(_power_t / CHARGE_PERIOD, 1.0)


func _st_charge(delta: float) -> void:
	_power_t += delta
	var p := charge_power()
	_bend_tgt = 0.06 + 0.34 * p # удилище откидывается назад
	if Input.is_action_just_released("rod_cast"):
		_cast(p)
	elif Input.is_action_just_pressed("rod_recall"):
		state = S.RESTING


func _cast(power: float) -> void:
	if _cam == null:
		return
	var origin := _cam.global_position
	var fdir := -_cam.global_transform.basis.z
	var hd := Vector2(fdir.x, fdir.z)
	if hd.length_squared() < 1e-6:
		hd = Vector2(0.0, -1.0)
	hd = hd.normalized()
	var dist := MIN_CAST + power * CAST_RANGE
	# если смотрим на воду — ограничиваем прицел самой плоскостью воды
	if fdir.y < -0.02 and water != null:
		var tp := (water.level_y - origin.y) / fdir.y
		var horiz := tp * sqrt(maxf(1.0 - fdir.y * fdir.y, 0.0))
		dist = clampf(horiz, MIN_CAST, MIN_CAST + power * CAST_RANGE)
	_bez_a = _tip.to_global(TIP_LOCAL)
	_bez_c = Vector3(origin.x + hd.x * dist, water.level_y, origin.z + hd.y * dist)
	_bez_b = (_bez_a + _bez_c) * 0.5 + Vector3.UP * (1.5 + 0.28 * dist)
	_build_lut()
	_bez_len = _lut[12]
	_fly_s = 0.0
	_bobber.visible = true
	state = S.FLY
	cast_started.emit(power)


func _st_fly(delta: float) -> void:
	_fly_s += delta * CAST_SPEED # путь нормирован длиной дуги — скорость честная
	var u := _lut_u(_fly_s)
	_bobber.global_position = _bez(_bez_a, _bez_b, _bez_c, u)
	_bend_tgt = -0.26 # хлыст вперёд
	if _fly_s >= _bez_len:
		_bobber.global_position = _bez_c
		if fish != null:
			fish.splash_burst(_bez_c, 0.8) # капли + кольцо в WaterField
			_lure_idx = fish.lure_to(_bez_c)
		_bite_t = randf_range(4.0, 9.0)
		_relure_t = 2.0
		state = S.FLOAT
		bobber_landed.emit(_bez_c)


func _st_float(delta: float) -> void:
	_dive_tgt = 0.0
	_bobber.global_position = _sit(delta)
	_bend_tgt = 0.10 + 0.02 * sin(_t * 1.1)
	if fish != null:
		fish.lure_refresh(_bobber.global_position)
		_bite_t -= delta
		_relure_t -= delta
		if _lure_idx == -1 and _bite_t <= 0.0 and _relure_t <= 0.0:
			_lure_idx = fish.lure_to(_bobber.global_position)
			_relure_t = 2.0
	if Input.is_action_just_pressed("rod_recall"):
		_recall()


func _st_bite(delta: float) -> void:
	# рыба тащит поплавок под воду — окно подсечки
	_window_t -= delta
	_bobber.global_position = _sit(delta)
	_bend_tgt = 0.30
	if _window_t <= 0.0:
		state = S.FLOAT # прозевал — рыба сама выйдет из игры (fish_freed)
		return
	if _suppress <= 0.0 and Input.is_action_just_pressed("rod_cast"):
		if fish != null and _lure_idx != -1 and fish.hook(_lure_idx):
			state = S.FIGHT
			_pulling = false
			_pull_t = 0.8
			_tension = 0.0
			fish_hooked.emit()
	if Input.is_action_just_pressed("rod_recall"):
		_recall()


func _st_fight(delta: float) -> void:
	_pull_t -= delta
	if _pull_t <= 0.0:
		_pulling = not _pulling
		_pull_t = randf_range(0.8, 1.4) if _pulling else randf_range(0.9, 1.7)
		if _pulling and fish != null and water != null and water.field != null:
			var b := _bobber.global_position
			water.field.splash(Vector2(b.x, b.z), 0.5) # рывок — кольцо
	var bp := _bobber.global_position
	var cp := _cam.global_position
	var to_cam := Vector2(cp.x - bp.x, cp.z - bp.z)
	var dcam := to_cam.length()
	var held := Input.is_action_pressed("rod_cast") and _suppress <= 0.0
	if fish != null:
		fish.hooked_refresh(bp) # рыба на крючке следует за поплавком
	if _pulling:
		# рыба тянет ОТ игрока; мотать в этот момент — накапливать натяг
		if dcam < FIGHT_MAX_DIST:
			var away := Vector3(-to_cam.x, 0.0, -to_cam.y).normalized()
			bp += away * 2.3 * delta
		if held:
			_tension += delta * TENSION_RATE
		else:
			_tension = maxf(0.0, _tension - delta * 1.1)
		if _tension >= 1.0:
			_escape()
			return
	else:
		# затишье — мотаем (с ЛКМ быстро, без неё лениво)
		var spd := REEL_SPEED if held else REEL_ASSIST
		if dcam > LAND_DIST:
			var home := Vector3(to_cam.x, 0.0, to_cam.y).normalized()
			bp += home * spd * delta
			if water != null and water.field != null:
				water.field.wake(Vector2(bp.x, bp.z), 0.6)
		else:
			_land()
			return
	var dive := -0.12 if _pulling else -0.03
	if water != null:
		bp.y = water.surface_height(bp.x, bp.z) + 0.035 + dive
	_bobber.global_position = bp
	if _pulling:
		_bend_tgt = 0.46 + 0.06 * sin(_t * 31.0)
	else:
		_bend_tgt = 0.30 + 0.03 * sin(_t * 17.0)


func _st_reel(delta: float) -> void:
	var bp := _bobber.global_position
	var cp := _cam.global_position
	var to_cam := Vector2(cp.x - bp.x, cp.z - bp.z)
	if to_cam.length() > 2.6:
		var home := Vector3(to_cam.x, 0.0, to_cam.y).normalized()
		bp += home * 9.0 * delta
		if water != null:
			bp.y = water.surface_height(bp.x, bp.z) + 0.035
		_bobber.global_position = bp
		if water != null and water.field != null:
			water.field.wake(Vector2(bp.x, bp.z), 0.7)
		_bend_tgt = 0.22
	else:
		state = S.RESTING
		_bobber.visible = false
		line_retrieved.emit()


# ---------------------------------------------------------------------------
# События рыб (SandFish)
# ---------------------------------------------------------------------------

func _on_fish_nibbled(idx: int) -> void:
	if state == S.FLOAT and idx == _lure_idx:
		_jiggle = 1.0
		_dive_tgt = -0.02


func _on_fish_biting(idx: int) -> void:
	if state == S.FLOAT and idx == _lure_idx:
		state = S.BITE
		_window_t = BITE_WINDOW
		_dive_tgt = -0.30
		bite_window_started.emit()


func _on_fish_freed(idx: int) -> void:
	if idx == _lure_idx:
		_lure_idx = -1
	if state == S.BITE:
		state = S.FLOAT
		_dive_tgt = 0.0
		_bite_t = randf_range(5.0, 10.0)
		_relure_t = 2.5


# ---------------------------------------------------------------------------
# Переходы
# ---------------------------------------------------------------------------

func _recall() -> void:
	if fish != null and _lure_idx != -1:
		fish.scare(_lure_idx)
		_lure_idx = -1
	_dive_tgt = 0.0
	state = S.REEL_IN


func _land() -> void:
	var sz := 0.0
	if fish != null and _lure_idx != -1:
		sz = fish.claim_catch(_lure_idx)
	_lure_idx = -1
	_dive_tgt = 0.0
	state = S.RESTING
	_bobber.visible = false
	fish_landed.emit(sz)


func _escape() -> void:
	_tension = 0.0
	if fish != null and _lure_idx != -1:
		fish.splash_burst(_bobber.global_position, 1.2)
		fish.scare(_lure_idx)
	_lure_idx = -1
	_dive_tgt = 0.0
	state = S.FLOAT
	_bite_t = randf_range(6.0, 11.0)
	_relure_t = 3.0
	fish_escaped.emit()


# ---------------------------------------------------------------------------
# Утилиты
# ---------------------------------------------------------------------------

## Посадка поплавка на воду: дрейф по ветру + высота поверхности + нырок.
func _sit(delta: float) -> Vector3:
	var bp := _bobber.global_position
	if game != null:
		var w2 := game.wind_dir()
		bp.x += w2.x * 0.12 * delta
		bp.z += w2.y * 0.12 * delta
	_dive = lerpf(_dive, _dive_tgt, 1.0 - exp(-9.0 * delta))
	_jiggle = maxf(0.0, _jiggle - delta * 2.4)
	if water != null:
		bp.y = water.surface_height(bp.x, bp.z) + 0.035 + _dive \
				+ sin(_t * 26.0) * 0.045 * _jiggle
	return bp


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


## Обратный LUT: путь -> параметр u (равномерная скорость по кривой).
func _lut_u(s: float) -> float:
	var sc := clampf(s, 0.0, _bez_len)
	for i in range(1, 13):
		if _lut[i] >= sc:
			var lo := _lut[i - 1]
			var hi := _lut[i]
			var f := 0.0 if hi <= lo else (sc - lo) / (hi - lo)
			return (float(i - 1) + f) / 12.0
	return 1.0


# ---------------------------------------------------------------------------
# Вид: удилище, леска, поплавок
# ---------------------------------------------------------------------------

func _build_rod() -> void:
	_root = Node3D.new()
	add_child(_root)
	var d := Vector3(-0.15, 0.62, -0.77).normalized() # ось удилища: вперёд-вверх
	var x := Vector3.UP.cross(d).normalized()
	var z := x.cross(d).normalized()
	_root.basis = Basis(x, d, z)
	_root.position = GRIP_POS

	var mat_h := StandardMaterial3D.new()
	mat_h.albedo_color = Color(0.33, 0.22, 0.13) # тёплое дерево рукояти
	mat_h.roughness = 0.75
	var mat_r := StandardMaterial3D.new()
	mat_r.albedo_color = Color(0.16, 0.13, 0.11) # тёмный углепластик
	mat_r.roughness = 0.5

	var handle := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.015
	cm.bottom_radius = 0.017
	cm.height = 0.24
	handle.mesh = cm
	handle.material_override = mat_h
	handle.position = Vector3(0.0, 0.12, 0.0)
	_root.add_child(handle)

	var butt := MeshInstance3D.new()
	var cb := CylinderMesh.new()
	cb.top_radius = 0.0105
	cb.bottom_radius = 0.0125
	cb.height = 0.52
	butt.mesh = cb
	butt.material_override = mat_r
	butt.position = Vector3(0.0, 0.50, 0.0)
	_root.add_child(butt)

	_tip = Node3D.new()
	_tip.position = Vector3(0.0, 0.76, 0.0)
	_root.add_child(_tip)
	var top := MeshInstance3D.new()
	var ct := CylinderMesh.new()
	ct.top_radius = 0.0025
	ct.bottom_radius = 0.0102
	ct.height = 0.56
	top.mesh = ct
	top.material_override = mat_r
	top.position = Vector3(0.0, 0.28, 0.0)
	_tip.add_child(top)

	# катушка — плоское кольцо, повёрнутое к камере
	var reel := MeshInstance3D.new()
	var tr := TorusMesh.new()
	tr.inner_radius = 0.028
	tr.outer_radius = 0.042
	reel.mesh = tr
	reel.material_override = mat_r
	reel.position = Vector3(-0.05, 0.14, 0.0)
	reel.rotation.x = PI * 0.5
	_root.add_child(reel)

	for mi in [handle, butt, top, reel]:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.layers = 2 # слой вью-модели, как у FpsArms (фонарь не засвечивает)


func _build_world() -> void:
	_world = Node3D.new()
	_world.top_level = true # дети — в мировых координатах, не в пространстве камеры
	add_child(_world)

	# поплавок: коралловый низ + светлый верх (палитра заката)
	_bobber = Node3D.new()
	_world.add_child(_bobber)
	var mat_lo := StandardMaterial3D.new()
	mat_lo.albedo_color = Color(0.86, 0.46, 0.33)
	mat_lo.roughness = 0.45
	var lo := MeshInstance3D.new()
	var sl := SphereMesh.new()
	sl.radius = 0.145
	sl.height = 0.29
	lo.mesh = sl
	lo.material_override = mat_lo
	_bobber.add_child(lo)
	var mat_hi := StandardMaterial3D.new()
	mat_hi.albedo_color = Color(0.97, 0.91, 0.80)
	mat_hi.roughness = 0.5
	var hi := MeshInstance3D.new()
	var sh := SphereMesh.new()
	sh.radius = 0.099
	sh.height = 0.198
	hi.mesh = sh
	hi.material_override = mat_hi
	hi.position = Vector3(0.0, 0.115, 0.0)
	_bobber.add_child(hi)
	_bobber.visible = false

	# леска — ImmediateMesh, перестраивается каждый кадр
	_line_mi = MeshInstance3D.new()
	_line_mesh = ImmediateMesh.new()
	_line_mi.mesh = _line_mesh
	var lm := StandardMaterial3D.new()
	lm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lm.albedo_color = Color(0.14, 0.11, 0.09)
	_line_mi.material_override = lm
	_line_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_world.add_child(_line_mi)


func _animate_rod(delta: float) -> void:
	_bend = lerpf(_bend, _bend_tgt, 1.0 - exp(-8.0 * delta))
	_tip.rotation.x = _bend
	# дыхание рук + сдвиги по состоянию
	var pos := GRIP_POS + Vector3(sin(_t * 0.9) * 0.004, sin(_t * 1.3) * 0.005, 0.0)
	var rot_z := sin(_t * 0.7) * 0.008
	if state == S.CHARGE:
		var p := charge_power()
		pos += Vector3(-0.012, 0.035, 0.09) * p # замах на себя
		rot_z += 0.10 * p
	elif state == S.FIGHT:
		var shake := 0.006 * _tension + (0.004 if _pulling else 0.0)
		pos += Vector3(sin(_t * 37.0), cos(_t * 29.0), 0.0) * shake
	_root.position = pos
	_root.rotation.z = rot_z


func _draw_line() -> void:
	_line_mesh.clear_surfaces()
	var show := state in [S.FLY, S.FLOAT, S.BITE, S.FIGHT, S.REEL_IN]
	if not show or _cam == null or not _bobber.visible:
		return
	var tip := _tip.to_global(TIP_LOCAL)
	var end := _bobber.global_position + Vector3.UP * 0.10
	var sag := 0.06
	match state:
		S.FLOAT:
			sag = 0.10 + 0.03 * sin(_t * 1.7)
		S.BITE, S.FIGHT:
			sag = 0.02
			if state == S.FIGHT and _pulling:
				sag += sin(_t * 47.0) * 0.03 # вибрация натянутой лески
		S.REEL_IN:
			sag = 0.04
	var mid := (tip + end) * 0.5 - Vector3.UP * sag
	_line_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for i in range(15):
		_line_mesh.surface_add_vertex(_bez(tip, mid, end, float(i) / 14.0))
	_line_mesh.surface_end()
