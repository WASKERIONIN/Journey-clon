class_name SandField
extends Node
## Настоящий песок: поле смещений высоты (CPU-симуляция) + карта для шейдера.
##
## Путник РЕАЛЬНО продавливает песок: след — это геометрия (вершинное
## смещение в шейдере террейна) и настоящие нормали (стенки следа ловят
## солнце, вал выброшенного песка светится свежим песком). Физика ходит
## по той же карте: путник ступает в собственные следы.
##
## Песок ведёт себя как песок:
##   • свежевыкопанный ОСЕДАЕТ (релаксация пятен);
##   • осыпается, если склон круче угла естественного откоса (талюс);
##   • медленно ЗАНОСИТСЯ ветром (старение + плавное растворение у края
##     окна — след «затягивается», когда путник уходит вперёд).
##
## Хранение: тор N×N текселей, привязанный к МИРОВОЙ сетке, — окно
## скользит за путником без копирования: новые столбцы/строки просто
## обнуляются. Карта отдаётся шейдеру как ImageTexture (R32F), шейдер
## адресует её через mod() с REPEAT — шов тора незаметен.

const N := 800 # текселей на сторону карты
const TEXEL := 0.12 # метров на тексель
const EXTENT := float(N) * TEXEL # окно 96×96 м вокруг путника

const MAX_DEPTH := 0.26 # предельное продавливание, м
const MAX_RISE := 0.13 # предельная высота вала, м

const SETTLE_BLEND := 0.26 # доля оседания за визит точки релаксации
const TALUS_STEP := 0.075 # перепад на тексель (~32°), после которого песок «течёт»
const TALUS_MOVE := 0.26 # доля переноса за визит

# Занос ветром: 4 строки карты в кадр (полный проход 3.3 с), множитель за
# проход 0.86 → полураспад ~15 с: след visibly затягивается меньше чем за
# минуту. В порывы ветра (wind_strength до ~1.3) занос заметно быстрее.
const AGE_ROWS_PER_FRAME := 4
const AGE_ROW_FACTOR := 0.86 # ^wind_strength в рантайме
const AGE_SYNC_ROWS := 200 # строк старения, после которых карту всё же грузим

const SPOT_VISITS := 128 # точек релаксации за кадр
const SPOT_TTL := 1.0 # жизнь точки релаксации, с
const SPOT_CAP := 420 # максимум точек (потом новые игнорируем)

var stamp_count := 0 # диагностика / smoke-тест

var game: GameState # автозагрузка Game (сила ветра для заноса)
var player: Player # за кем скользит окно

var _grid := PackedFloat32Array() # тор: [sj * N + si], мировые смещения (м)
var _tex: ImageTexture
var _img: Image

var _min_gi := 0 # глобальная ячейка края окна (мир замощен сеткой TEXEL)
var _min_gj := 0
var win_x0 := 0.0 # мировой угол окна — уходит в шейдер
var win_z0 := 0.0

var _spots: Array[Vector2i] = [] # активные точки релаксации (глобальные ячейки)
var _spot_life: PackedFloat32Array = []
var _age_row := 0
var _age_since_upload := 0
var _upload_pending := false
var _upload_clock := 0.0
var _churn := FastNoiseLite.new()

const _DIRS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]


func setup(game_ref = null) -> void:
	game = game_ref
	_grid.resize(N * N)
	_grid.fill(0.0)
	_churn.seed = 4242
	_churn.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_churn.frequency = 0.35
	_churn.fractal_octaves = 1
	_upload()


# ---------------------------------------------------------------------------
# Публичное API
# ---------------------------------------------------------------------------

## Текстура карты для шейдера террейна.
func get_texture() -> ImageTexture:
	return _tex


## Смещение песка в точке (билинейно, в точности как выборка GPU).
func disp_at(x: float, z: float) -> float:
	var lx := (x - win_x0) / TEXEL
	var lz := (z - win_z0) / TEXEL
	if lx < 2.0 or lz < 2.0 or lx > float(N - 3) or lz > float(N - 3):
		return 0.0 # за окном песок нетронут (путник всегда в центре)
	var fx := x / TEXEL - 0.5
	var fz := z / TEXEL - 0.5
	var i0 := floori(fx)
	var j0 := floori(fz)
	var tx := fx - float(i0)
	var tz := fz - float(j0)
	var a := _grid[_idx(i0, j0)]
	var b := _grid[_idx(i0 + 1, j0)]
	var c := _grid[_idx(i0, j0 + 1)]
	var d := _grid[_idx(i0 + 1, j0 + 1)]
	return lerpf(lerpf(a, b, tx), lerpf(c, d, tx), tz)


## Градиент смещения (dh/dx, dh/dz) — наклон песка для физики.
func disp_gradient(x: float, z: float) -> Vector2:
	var e := TEXEL * 2.0
	return Vector2(
		(disp_at(x + e, z) - disp_at(x - e, z)) / (2.0 * e),
		(disp_at(x, z + e) - disp_at(x, z - e)) / (2.0 * e)
	)


## Отпечаток стопы: капсула от пятки к носку, пятка глубже, носок мягче,
## по краям — вал выброшенного песка (впереди — больше, песок толкается).
func stamp_foot(
	pos: Vector2, fwd: Vector2,
	p_len: float, p_wid: float, p_depth: float, p_rim: float
) -> void:
	var half_len := p_len * 0.5
	var a := pos - fwd * half_len
	var b := pos + fwd * half_len
	_stamp_capsule(a, b, p_wid * 0.5, p_depth, p_rim, 0.19, true)


## Борозда скольжения: непрерывная churned ложбина с валиками по бокам.
func stamp_track(a: Vector2, b: Vector2, p_wid: float, p_depth: float, p_rim: float) -> void:
	_stamp_capsule(a, b, p_wid * 0.5, p_depth, p_rim, 0.22, false)


## Отпечаток посадки: широкое овальное углубление от двух стоп.
func stamp_land(pos: Vector2, fwd: Vector2, p_depth: float) -> void:
	var a := pos - fwd * 0.12
	var b := pos + fwd * 0.12
	_stamp_capsule(a, b, 0.22, p_depth, 0.022, 0.16, false)


# ---------------------------------------------------------------------------
# Симуляция
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	if player != null:
		_follow(player.global_position.x, player.global_position.z)
	_relax(delta)
	_age()
	_upload_clock += delta
	var stale := _age_since_upload >= AGE_SYNC_ROWS
	if (_upload_pending and _upload_clock >= 1.0 / 30.0) or stale:
		_upload()


## Окно скользит за путником: вошедшие столбцы/строки обнуляются
## (за окном всё начинается с нетронутого песка).
func _follow(px: float, pz: float) -> void:
	var cgi := roundi(px / TEXEL)
	var cgj := roundi(pz / TEXEL)
	var half := N >> 1 # половина окна (целочисленно, без деления)
	var n_min_gi := cgi - half
	var n_min_gj := cgj - half
	var dgi := n_min_gi - _min_gi
	var dgj := n_min_gj - _min_gj
	if dgi == 0 and dgj == 0:
		return
	if absi(dgi) >= half or absi(dgj) >= half:
		# телепорт (респаун, смена главы) — песок вокруг новый
		_grid.fill(0.0)
		_spots.clear()
		_spot_life.clear()
	else:
		if dgi != 0:
			_zero_entering_columns(dgi, n_min_gi)
		if dgj != 0:
			_zero_entering_rows(dgj, n_min_gj)
	_min_gi = n_min_gi
	_min_gj = n_min_gj
	win_x0 = float(_min_gi) * TEXEL
	win_z0 = float(_min_gj) * TEXEL
	_upload_pending = true


func _zero_entering_columns(dgi: int, n_min_gi: int) -> void:
	var from_gi := n_min_gi + N - dgi if dgi > 0 else n_min_gi
	var count := absi(dgi)
	for gj in range(_min_gj, _min_gj + N):
		for k in range(count):
			_grid[_idx(from_gi + k, gj)] = 0.0


func _zero_entering_rows(dgj: int, n_min_gj: int) -> void:
	var from_gj := n_min_gj + N - dgj if dgj > 0 else n_min_gj
	var count := absi(dgj)
	for gi in range(_min_gi, _min_gi + N):
		for k in range(count):
			_grid[_idx(gi, from_gj + k)] = 0.0


## Релаксация свежих пятен: песок оседает и осыпается.
func _relax(delta: float) -> void:
	if _spots.is_empty():
		return
	var visits := 0
	var i := 0
	while i < _spots.size():
		_spot_life[i] -= delta
		if _spot_life[i] <= 0.0:
			_remove_spot(i)
			continue
		if visits < SPOT_VISITS:
			_settle(_spots[i])
			visits += 1
		i += 1


func _settle(cell: Vector2i) -> void:
	var gi := cell.x
	var gj := cell.y
	# точка за пределами окна больше не актульна
	if gi < _min_gi + 1 or gi > _min_gi + N - 2 or gj < _min_gj + 1 or gj > _min_gj + N - 2:
		return
	var c := _idx(gi, gj)
	# 1) оседание: подтягиваемся к соседям
	var s := 0.25 * (
		_grid[_idx(gi + 1, gj)]
		+ _grid[_idx(gi - 1, gj)]
		+ _grid[_idx(gi, gj + 1)]
		+ _grid[_idx(gi, gj - 1)]
	)
	var v := lerpf(_grid[c], s, SETTLE_BLEND)
	_grid[c] = v
	# 2) осыпание: перепад круче угла откоса — песок течёт вниз
	for k in range(4):
		var ni: int = gi + _DIRS[k].x
		var nj: int = gj + _DIRS[k].y
		var nidx := _idx(ni, nj)
		var d := v - _grid[nidx]
		if d > TALUS_STEP:
			var mov := (d - TALUS_STEP) * TALUS_MOVE * 0.5
			v -= mov
			_grid[c] = v
			_grid[nidx] = clampf(_grid[nidx] + mov, -MAX_DEPTH, MAX_RISE)


## Старение: несколько строк карты в кадр плавно «заносится ветром».
## Полный проход — 3.3 с; в порывы ветра множитель steep'ится — занос
## ускоряется вместе с погодой.
func _age() -> void:
	var wind := 1.0
	if game != null:
		wind = clampf(game.wind_strength, 0.5, 1.6)
	var f := pow(AGE_ROW_FACTOR, wind)
	for _r in range(AGE_ROWS_PER_FRAME):
		var base := _age_row * N
		for i in range(base, base + N):
			if _grid[i] != 0.0:
				_grid[i] *= f
		_age_row = (_age_row + 1) % N
	_age_since_upload += AGE_ROWS_PER_FRAME


func _upload() -> void:
	var bytes := _grid.to_byte_array()
	_img = Image.create_from_data(N, N, false, Image.FORMAT_RF, bytes)
	if _tex == null:
		_tex = ImageTexture.create_from_image(_img)
	else:
		_tex.update(_img)
	_upload_pending = false
	_upload_clock = 0.0
	_age_since_upload = 0


# ---------------------------------------------------------------------------
## Ядро штампа: капсула (сегмент a→b радиуса half_wid).
## Внутри — продавливание, вокруг — вал выброшенного песка.
## foot=true — асимметрия пятка/носок.
# ---------------------------------------------------------------------------
func _stamp_capsule(a: Vector2, b: Vector2, half_wid: float, depth: float, rim: float, rim_w: float, foot: bool) -> void:
	var ab := b - a
	var ab2 := ab.length_squared()
	var band := half_wid + rim_w
	# bbox штампа в мировых метрах по обоим концам капсулы
	var lo_x := minf(a.x, b.x) - band
	var hi_x := maxf(a.x, b.x) + band
	var lo_z := minf(a.y, b.y) - band
	var hi_z := maxf(a.y, b.y) + band
	var gi0 := maxi(floori(lo_x / TEXEL), _min_gi + 2)
	var gi1 := mini(floori(hi_x / TEXEL), _min_gi + N - 3)
	var gj0 := maxi(floori(lo_z / TEXEL), _min_gj + 2)
	var gj1 := mini(floori(hi_z / TEXEL), _min_gj + N - 3)

	var inv2 := 1.0 / ab2 if ab2 > 0.000001 else 0.0
	for gj in range(gj0, gj1 + 1):
		var cz := (float(gj) + 0.5) * TEXEL
		for gi in range(gi0, gi1 + 1):
			var cx := (float(gi) + 0.5) * TEXEL
			var dx := cx - a.x
			var dz := cz - a.y
			var t := 0.0
			if inv2 > 0.0:
				t = clampf((dx * ab.x + dz * ab.y) * inv2, 0.0, 1.0)
			var qx := dx - ab.x * t
			var qz := dz - ab.y * t
			var d := sqrt(qx * qx + qz * qz)
			var delta := 0.0
			if d < half_wid:
				var r01 := d / half_wid
				var c01 := 1.0 - r01 * r01 # плоское дно, мягкие стенки
				var shape := 1.0
				if foot:
					var along := t * 2.0 - 1.0 # -1 пятка … +1 носок
					shape = 0.82 + 0.36 * _smoothf(along, -1.0, 0.3)
					shape *= 1.0 - 0.25 * _smoothf(along, 0.3, 1.0)
				var dl := depth * (0.45 + 0.55 * c01) * shape
				dl *= 1.0 + _churn.get_noise_2d(cx, cz) * 0.55
				delta = -dl
			elif d < band:
				var k := (d - half_wid) / rim_w
				var bell := sin(PI * k)
				var toe := 1.0
				if foot:
					toe = 1.0 + 0.7 * _smoothf(t, 0.55, 1.0)
				delta = rim * bell * bell * toe
				delta *= 1.0 + _churn.get_noise_2d(cx + 7.0, cz) * 0.50
			if delta != 0.0:
				var idx := _idx(gi, gj)
				_grid[idx] = clampf(_grid[idx] + delta, -MAX_DEPTH, MAX_RISE)

	_upload_pending = true
	stamp_count += 1
	_add_spot(a)
	if b.distance_squared_to(a) > 0.04:
		_add_spot(b)


func _add_spot(p: Vector2) -> void:
	if _spots.size() >= SPOT_CAP:
		return
	_spots.append(Vector2i(floori(p.x / TEXEL), floori(p.y / TEXEL)))
	_spot_life.append(SPOT_TTL)


func _remove_spot(i: int) -> void:
	var last := _spots.size() - 1
	_spots[i] = _spots[last]
	_spot_life[i] = _spot_life[last]
	_spots.remove_at(last)
	_spot_life.remove_at(last)


## Индекс в торе для глобальной ячейки.
func _idx(gi: int, gj: int) -> int:
	var si := gi % N
	if si < 0:
		si += N
	var sj := gj % N
	if sj < 0:
		sj += N
	return sj * N + si


func _smoothf(v: float, e0: float, e1: float) -> float:
	var t := clampf((v - e0) / (e1 - e0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)
