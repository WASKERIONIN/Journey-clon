class_name GodotFishSandFish
extends Node3D
## Песчаные существа — SDF-реймарчинг поверх «песчаного моря».
##
## Полноэкранный квад + шейдер sand_sea_sdf.gdshader (ядро — CC0 «Fullscreen
## SDF Raymarching with Smooth CSG and Depth», vav-labs): рыбы-«киты» из
## плавленых сфер выпрыгивают из моря и ныряют обратно, брызги — кластеры
## капель-метаболов, а рыбы под поверхностью видны как тёмные бугры,
## ползущие под песком («вуаль»).
##
## Скрипт живёт жизнью существ на CPU и пушит uniform-ы каждый кадр
## (6 рыб + 12 капель — копейки): курс/скорость/фаза волны, гауссов «бугор
## прыжка» в цикле, парбол капель. Все рыбьи места — в пределах сферы
## обитания, центр которой идёт за камерой: существа всегда рядом с кадром.
##
## Использование (после water.setup):
##   var fish := SandFish.new()
##   add_child(fish)
##   fish.setup(game, water.level_y, water.field)
## Брызги в мировую точку (посадка поплавка, поклёвка, нырок):
##   fish.splash_burst(global_pos, 1.0)
## Капли заодно роняют кольцо в WaterField — событие видно и как рябь.

const MAX_FISH := 6
const MAX_DROPS := 12
const SHADER_PATH := "res://shaders/sand_sea_sdf.gdshader"
const GRAVITY := 9.8

## События рыбалки — их слушает RodCast (удочка)
signal fish_arrived(idx: int) # рыба дошла до поплавка, кружит
signal nibbled(idx: int) # проба: тычок носом, мелкие кольца
signal biting(idx: int) # поклёвка — открыто окно подсечки
signal fish_freed(idx: int) # рыба ушла (испуг/прозеванное окно)
signal fish_removed(idx: int) # рыба поймана и изъята из моря

## Палитра существ — тёплые тона заката; свет моря докрашивает сам
const PALETTE: Array[Color] = [
	Color(0.95, 0.72, 0.42), # золото
	Color(0.86, 0.46, 0.33), # коралл
	Color(0.63, 0.53, 0.80), # сирень
	Color(0.80, 0.66, 0.46), # песок
]

@export_range(0, MAX_FISH) var fish_count := 4 ## сколько существ живёт сейчас
@export var bounds_radius := 130.0 ## радиус сферы обитания, м (центр — камера)
@export_range(0.4, 2.0) var size_mul := 1.0 ## множитель размера существ
@export_range(0.4, 2.4) var jump_mul := 1.0 ## множитель высоты прыжка

var water_level := 0.0
var water_field: GodotFishWaterField = null # кольца от всплесков (опционально)
var game = null # автозагрузка Game — общее солнце и туман с водой/песком
var material: ShaderMaterial
var t := 0.0 # время поля — единое с шейдерным u_time

var _quad: MeshInstance3D

# ---- рыбы (параллельные массивы, как у SandField) ----
var _fpos := PackedVector3Array()
var _fheading := PackedFloat32Array()
var _fturn := PackedFloat32Array()
var _fspeed := PackedFloat32Array()
var _fsize := PackedFloat32Array()
var _fphase := PackedFloat32Array()
var _fperiod := PackedFloat32Array()
var _foffset := PackedFloat32Array()
var _fcruise := PackedFloat32Array()
var _fjump := PackedFloat32Array()
var _fy := PackedFloat32Array() # сглаженная высота центра
var _ftint := PackedColorArray()

# ---- капли-брызги ----
var _dpos := PackedVector3Array()
var _dvel := PackedVector3Array()
var _dage := PackedFloat32Array()
var _dlife := PackedFloat32Array()
var _dr0 := PackedFloat32Array() # > 0 — капля жива
var _dcursor := 0

# ---- рыбалка: приманка/поклёвка/крючок (ведёт RodCast через lure_to/hook) ----
var _lure_idx := -1 # рыба, идущая к поплавку
var _lure_pos := Vector3.ZERO # точка интереса (поплавок; при вываживании тоже)
var _lure_phase := 0 # 0 нет, 1 подход, 2 пробы, 3 поклёвка
var _lure_timer := 0.0
var _nibbles_left := 0
var _hooked_idx := -1 # рыба на крючке (вываживание)
var _fscare := PackedFloat32Array() # > 0 — рыба убегает от поплавка


func _ready() -> void:
	_build_material()
	_build_quad()
	_init_fish()
	_init_drops()


func _build_material() -> void:
	material = ShaderMaterial.new()
	material.shader = load(SHADER_PATH)
	if game != null:
		material.set_shader_parameter("sun_dir", game.sun_dir)
		material.set_shader_parameter("fog_distance", game.FOG_DISTANCE)


func _build_quad() -> void:
	_quad = MeshInstance3D.new()
	_quad.name = "SdfQuad"
	var qm := QuadMesh.new()
	qm.size = Vector2(2.0, 2.0)
	_quad.mesh = qm
	_quad.extra_cull_margin = 16384.0 # квад всегда в кадре
	_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_quad.sorting_offset = 4096.0 # среди прозрачных рисуемся ПЕРВЫМИ,
	# чтобы частицы и леска ложились поверх существ
	_quad.material_override = material
	add_child(_quad)


func _init_fish() -> void:
	_fpos.resize(MAX_FISH)
	_fheading.resize(MAX_FISH)
	_fturn.resize(MAX_FISH)
	_fspeed.resize(MAX_FISH)
	_fsize.resize(MAX_FISH)
	_fphase.resize(MAX_FISH)
	_fperiod.resize(MAX_FISH)
	_foffset.resize(MAX_FISH)
	_fcruise.resize(MAX_FISH)
	_fjump.resize(MAX_FISH)
	_fy.resize(MAX_FISH)
	_ftint.resize(MAX_FISH)
	_fscare.resize(MAX_FISH)

	var center := Vector2.ZERO
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		center = Vector2(cam.global_position.x, cam.global_position.z)
	for i in range(MAX_FISH):
		var active := i < fish_count
		var ang := randf() * TAU
		var rad := randf_range(10.0, bounds_radius * 0.5)
		_fpos[i] = Vector3(center.x + cos(ang) * rad,
			water_level - randf_range(0.5, 1.2),
			center.y + sin(ang) * rad)
		_fheading[i] = randf() * TAU
		_fturn[i] = 0.0
		_fspeed[i] = randf_range(1.3, 2.2)
		_fsize[i] = (randf_range(0.55, 0.95) * size_mul) if active else 0.0
		_fphase[i] = randf() * TAU
		_fperiod[i] = randf_range(8.0, 14.0)
		_foffset[i] = randf() * _fperiod[i]
		_fcruise[i] = randf_range(0.5, 1.2)
		_fjump[i] = _fsize[i] * randf_range(0.9, 1.4) * jump_mul
		_fy[i] = _fpos[i].y
		_ftint[i] = PALETTE[i % PALETTE.size()] if active else Color(0, 0, 0)
		_fscare[i] = 0.0


func _init_drops() -> void:
	_dpos.resize(MAX_DROPS)
	_dvel.resize(MAX_DROPS)
	_dage.resize(MAX_DROPS)
	_dlife.resize(MAX_DROPS)
	_dr0.resize(MAX_DROPS)
	_dr0.fill(0.0) # все слоты пусты


func setup(game_ref, p_level: float, wf: GodotFishWaterField = null) -> void:
	game = game_ref
	water_level = p_level
	water_field = wf
	if material != null and game != null:
		material.set_shader_parameter("sun_dir", game.sun_dir)
		material.set_shader_parameter("fog_distance", game.FOG_DISTANCE)


## Публичное событие: брызги-капли в мировой точке (посадка поплавка,
## поклёвка, нырок рыбы). Заодно кладёт кольцо в WaterField, если он задан.
func splash_burst(world_pos: Vector3, strength := 1.0) -> void:
	_burst(world_pos, clampf(strength, 0.2, 2.0))


func _process(delta: float) -> void:
	t += delta
	var center := Vector2.ZERO
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		center = Vector2(cam.global_position.x, cam.global_position.z)
		_quad.global_position = cam.global_position # страховка от фрустума
	for i in range(fish_count):
		_sim_fish(i, delta, center)
	_sim_drops(delta)
	_push_uniforms(center)


# ---------------------------------------------------------------------------
# Жизнь существ
# ---------------------------------------------------------------------------

func _sim_fish(i: int, delta: float, center: Vector2) -> void:
	var s := _fsize[i]
	if s < 0.001:
		return

	# рыбалка: рыбы на приманке/крючке живут по своим фазам (ведёт RodCast)
	if i == _lure_idx:
		_sim_lure(i, delta, s)
		return
	if i == _hooked_idx:
		_sim_hooked(i, delta, s)
		return
	var boost := 1.0
	if _fscare[i] > 0.0:
		_fscare[i] -= delta
		boost = 1.9
		var away := atan2(_fpos[i].z - _lure_pos.z, _fpos[i].x - _lure_pos.x)
		var dhs := wrapf(away - _fheading[i], -PI, PI)
		_fturn[i] += clampf(dhs * 3.0, -0.7, 0.7) * delta * 6.0

	# курс: случайное блуждание + мягкий возврат в границы обитания
	if _fscare[i] <= 0.0:
		_fturn[i] += (randf() - 0.5) * 2.4 * delta
	var to_c := center - Vector2(_fpos[i].x, _fpos[i].z)
	if to_c.length() > bounds_radius * 0.72:
		var ah := atan2(to_c.y, to_c.x)
		var dh := wrapf(ah - _fheading[i], -PI, PI)
		_fturn[i] += dh * 1.6 * delta
	_fturn[i] = clampf(_fturn[i], -0.7, 0.7)
	_fheading[i] += _fturn[i] * delta
	_fpos[i] += Vector3(cos(_fheading[i]), 0.0, sin(_fheading[i])) * _fspeed[i] * boost * delta

	# волна тела бежит к хвосту
	_fphase[i] += delta * (5.0 + _fspeed[i] * 2.2)

	# прыжок: гауссов бугор в цикле — плавный нырок под песок и выход
	var cy := fposmod(t + _foffset[i], _fperiod[i])
	var x := (cy - 0.55 * _fperiod[i]) / (0.09 * _fperiod[i])
	var bump := exp(-x * x)
	var target := water_level - _fcruise[i] + (_fcruise[i] + _fjump[i]) * bump
	var prev_y := _fy[i]
	_fy[i] = lerpf(_fy[i], target, 1.0 - exp(-7.0 * delta))
	_fpos[i].y = _fy[i]

	# всплески на пересечении поверхности: выход поменьше, вход погромче
	var above_now := _fy[i] > water_level + 0.25 * s
	var above_prev := prev_y > water_level + 0.25 * s
	if above_now and not above_prev:
		_burst(_fpos[i], 0.6)
	elif above_prev and not above_now:
		_burst(_fpos[i], 1.1)


func _burst(pos: Vector3, strength: float) -> void:
	var n := int(5.0 + 4.0 * strength)
	for j in range(n):
		var k := _dcursor
		_dcursor = (_dcursor + 1) % MAX_DROPS
		var ang := randf() * TAU
		var rad := randf_range(0.25, 0.85) * (0.6 + 0.4 * strength)
		_dpos[k] = pos + Vector3(cos(ang) * 0.15, 0.08, sin(ang) * 0.15)
		_dvel[k] = Vector3(cos(ang) * rad,
			randf_range(1.6, 2.8) * (0.7 + 0.4 * strength),
			sin(ang) * rad)
		_dage[k] = 0.0
		_dlife[k] = randf_range(0.65, 1.05)
		_dr0[k] = randf_range(0.045, 0.085) * (0.8 + 0.4 * strength) # мелкая брызга (было 0.08–0.15)
	if water_field != null:
		water_field.splash(Vector2(pos.x, pos.z), strength)


func _sim_drops(delta: float) -> void:
	for k in range(MAX_DROPS):
		if _dr0[k] <= 0.0:
			continue
		_dage[k] += delta
		_dvel[k].y -= GRAVITY * delta
		_dpos[k] += _dvel[k] * delta
		if _dage[k] > _dlife[k] or _dpos[k].y < water_level - 0.15:
			_dr0[k] = 0.0 # капля умерла — слот свободен


# ---------------------------------------------------------------------------
# Пуш uniform-ов (каждый кадр: 6 рыб + 12 капель — копейки)
# ---------------------------------------------------------------------------

func _push_uniforms(center: Vector2) -> void:
	var st := PackedVector4Array()
	st.resize(MAX_FISH)
	var mt := PackedVector2Array()
	mt.resize(MAX_FISH)
	var tn := PackedVector3Array()
	tn.resize(MAX_FISH)
	for i in range(MAX_FISH):
		if i >= fish_count:
			continue
		st[i] = Vector4(_fpos[i].x, _fpos[i].y, _fpos[i].z, _fheading[i])
		mt[i] = Vector2(_fsize[i], _fphase[i])
		tn[i] = Vector3(_ftint[i].r, _ftint[i].g, _ftint[i].b)

	var dp := PackedVector4Array()
	dp.resize(MAX_DROPS)
	for k in range(MAX_DROPS):
		if _dr0[k] <= 0.0:
			continue
		var r := _dr0[k] * (1.0 - 0.35 * clampf(_dage[k] / _dlife[k], 0.0, 1.0))
		dp[k] = Vector4(_dpos[k].x, _dpos[k].y, _dpos[k].z, r)

	material.set_shader_parameter("u_fish_state", st)
	material.set_shader_parameter("u_fish_meta", mt)
	material.set_shader_parameter("u_fish_tint", tn)
	material.set_shader_parameter("u_drops", dp)
	material.set_shader_parameter("u_center", center)
	material.set_shader_parameter("u_bounds_r", bounds_radius)
	material.set_shader_parameter("u_water_level", water_level)
	material.set_shader_parameter("u_time", t)


# ---------------------------------------------------------------------------
# Рыбалка: приманивание, пробы, поклёвка, подсечка (ведёт RodCast)
# ---------------------------------------------------------------------------

## Приманить рыбу к точке (поплавок). idx = -1 — ближайшая активная.
## Возвращает индекс или -1. Одна рыба на приманке за раз.
func lure_to(pos: Vector3, idx := -1) -> int:
	if idx == -1:
		if _lure_idx != -1:
			return -1
		var best := -1
		var bd := 1e12
		for i in range(fish_count):
			if _fsize[i] < 0.001 or _fscare[i] > 0.0 or i == _hooked_idx:
				continue
			var d := Vector2(_fpos[i].x - pos.x, _fpos[i].z - pos.z).length_squared()
			if d < bd:
				bd = d
				best = i
		if best == -1:
			return -1
		idx = best
	if idx < 0 or idx >= MAX_FISH or _fsize[idx] < 0.001:
		return -1
	_lure_idx = idx
	_lure_pos = pos
	_lure_phase = 1
	return idx


## Поплавок дрейфует — обновляем точку интереса (вызывает RodCast).
func lure_refresh(pos: Vector3) -> void:
	if _lure_idx != -1:
		_lure_pos = pos


## Поплавок двигается при вываживании — рыба на крючке следует за ним.
func hooked_refresh(pos: Vector3) -> void:
	if _hooked_idx != -1:
		_lure_pos = pos


## Подсечка (RodCast в окно поклёвки). true — рыба на крючке.
func hook(idx: int) -> bool:
	if idx != _lure_idx or _lure_phase != 3:
		return false
	_lure_phase = 0
	_lure_idx = -1
	_hooked_idx = idx
	# форс-вскидка: рыба выпрыгивает у поплавка — «взяла!»
	_fperiod[idx] = minf(_fperiod[idx], 4.5)
	_foffset[idx] = fposmod(0.55 * _fperiod[idx] - t, _fperiod[idx])
	_fjump[idx] = _fsize[idx] * randf_range(1.7, 2.1) * jump_mul
	return true


## Испуг: рыба бросает приманку/крючок и уходит прочь.
func scare(idx: int) -> void:
	if idx < 0 or idx >= MAX_FISH or _fsize[idx] < 0.001:
		return
	_fscare[idx] = 1.6
	if _lure_idx == idx:
		_lure_idx = -1
		_lure_phase = 0
	if _hooked_idx == idx:
		_hooked_idx = -1


## Рыба изъята (RodCast подвёл к берегу): всплеск, слот гаснет (шейдер
## пропустит мета.x < 0.001). Возвращает размер — для счёта/инвентаря.
func claim_catch(idx: int) -> float:
	var sz := _fsize[idx]
	if sz > 0.001:
		var at := _fpos[idx]
		at.y = water_level # капли из-под воды умерли бы сразу
		_burst(at, 1.5)
	_fsize[idx] = 0.0
	if _hooked_idx == idx:
		_hooked_idx = -1
	fish_removed.emit(idx)
	return sz


## Жизнь рыбы на приманке: подход -> пробы («буль-буль») -> поклёвка.
func _sim_lure(i: int, delta: float, s: float) -> void:
	var to := _lure_pos - _fpos[i]
	var dxz := Vector2(to.x, to.z).length()
	var steer := 0.0
	var spd := _fspeed[i]
	if _lure_phase == 1:
		if dxz < 4.0:
			_lure_phase = 2
			_lure_timer = randf_range(0.8, 1.5)
			_nibbles_left = 1 + (randi() % 3)
			fish_arrived.emit(i)
		else:
			var dh := wrapf(atan2(to.z, to.x) - _fheading[i], -PI, PI)
			steer = clampf(dh * 2.5, -0.7, 0.7)
			spd = maxf(spd, 3.2)
	elif _lure_phase == 2:
		# кружит у поплавка, изредка тыкается носом
		var tangent := atan2(to.z, to.x) + PI * 0.5
		var dh2 := wrapf(tangent - _fheading[i], -PI, PI)
		steer = clampf(dh2 * 1.4, -0.5, 0.5)
		spd = 1.4
		_lure_timer -= delta
		if _lure_timer <= 0.0:
			_nibbles_left -= 1
			if _nibbles_left > 0:
				nibbled.emit(i)
				if water_field != null:
					water_field.nibble(Vector2(_lure_pos.x, _lure_pos.z))
				_lure_timer = randf_range(0.7, 1.3)
			else:
				_lure_phase = 3
				_lure_timer = 0.85 # окно держит рыба; у RodCast 0.55 — с запасом
				biting.emit(i)
				if water_field != null:
					water_field.nibble(Vector2(_lure_pos.x, _lure_pos.z))
	elif _lure_phase == 3:
		# поклёвка: проходит ПОД поплавком, дёргая его вниз
		var dh3 := wrapf(atan2(to.z, to.x) - _fheading[i], -PI, PI)
		steer = clampf(dh3 * 2.0, -0.6, 0.6)
		spd = 2.2
		_lure_timer -= delta
		if _lure_timer <= 0.0:
			# окно прозевано — рыба уходит
			_lure_phase = 0
			_lure_idx = -1
			_fscare[i] = 1.6
			fish_freed.emit(i)
			return
	_fturn[i] = clampf(_fturn[i] + steer * delta, -0.7, 0.7)
	_fheading[i] += _fturn[i] * delta
	_fpos[i] += Vector3(cos(_fheading[i]), 0.0, sin(_fheading[i])) * spd * delta
	_fphase[i] += delta * (5.0 + spd * 2.2)
	# глубина: в пробах и поклёвке — под самой поверхностью (вуаль дышит)
	var target_y := water_level - _fcruise[i]
	if _lure_phase >= 2:
		target_y = water_level - 0.42 * s
	_fy[i] = lerpf(_fy[i], target_y, 1.0 - exp(-5.0 * delta))
	_fpos[i].y = _fy[i]


## Рыба на крючке: следует за поплавком (за ведром лески), у поверхности.
func _sim_hooked(i: int, delta: float, s: float) -> void:
	var to := _lure_pos - _fpos[i]
	var dxz := Vector2(to.x, to.z).length()
	var dh := wrapf(atan2(to.z, to.x) - _fheading[i], -PI, PI)
	var steer := clampf(dh * 2.6, -0.7, 0.7)
	_fturn[i] = clampf(_fturn[i] + steer * delta, -0.7, 0.7)
	var spd := 3.0
	if dxz < 2.5:
		spd = 1.6 # держится у поплавка, не наезжает
	_fheading[i] += _fturn[i] * delta
	_fpos[i] += Vector3(cos(_fheading[i]), 0.0, sin(_fheading[i])) * spd * delta
	_fphase[i] += delta * (6.0 + spd * 2.0)
	var target_y := water_level - 0.35 * s
	_fy[i] = lerpf(_fy[i], target_y, 1.0 - exp(-6.0 * delta))
	_fpos[i].y = _fy[i]
