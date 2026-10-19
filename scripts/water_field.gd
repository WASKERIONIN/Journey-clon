class_name WaterField
extends Node
## Песчаное море: поле СОБЫТИЙ вместо поля высот.
##
## У SandField высота хранится в торе 800×800 и штампуется следами. Морю
## сетка не нужна (вариант А): каждое событие — расходящееся кольцо-пакет,
## а «дыхание» моря (мега-рябь песка ~9 м) считается аналитически. Формулы
## в точности те же, что в water.gdshader: шейдер рисует нормали, эта нода
## даёт физике ВЫСОТУ воды в точке — поплавок качается на том же «одеяле»
## и на тех же кольцах, что видит глаз.
##
## Кольца — ring buffer: при переполнении перезаписывается самый старый
## слот (при 24 слотах и жизни 5 с даже спам-клики не вытесняют живое).
## Uniform-ы пушатся в материал на 30 Гц — как карта песка у SandField.
##
## Вариант Б (настоящее волновое уравнение на compute) садится сюда же:
## у WaterField тот же публичный API (height_at / splash / nibble / wake).

const MAX_RINGS := 24
const RING_LIFE := 5.0 # с, после — слот освобождается

const RING_SPEED := 1.5 # м/с, фронт (должно совпадать с шейдером)
const RING_WAVELEN := 0.85
const RING_TAU := 0.55
const RING_W0 := 0.30
const RING_WG := 0.18
const RING_AMP := 0.055

const PUSH_HZ := 30.0 # частота пуша uniform-ов

var t := 0.0 # время поля — ЕДИНОЕ с шейдерным u_time
var mat: ShaderMaterial # куда пушим кольца (назначает WaterSurface)

# Живой ветер: WaterSurface обновляет каждый кадр из game (как у песка),
# чтобы физика поплавка качалась ровно на том «одеяле», что рисует шейдер.
var wind_dir := Vector2(0.32, -0.95)
var wind_power := 1.0
var mega_amp := 0.055 # дыхание моря — синхронно с uniform-ом шейдера

var _pos := PackedVector2Array()
var _t0 := PackedFloat32Array()
var _amp := PackedFloat32Array()
var _cursor := 0
var _push_clock := 0.0
var _last_wake := -10.0


func _ready() -> void:
	_pos.resize(MAX_RINGS)
	_t0.resize(MAX_RINGS)
	_t0.fill(-1000.0) # все слоты «давно умерли»
	_amp.resize(MAX_RINGS)
	_amp.fill(0.0)


# ---------------------------------------------------------------------------
# Публичное API
# ---------------------------------------------------------------------------

## Всплеск: посадка поплавка, прыжок рыбы, брошенный камень.
## strength 1.0 — поплавок; 1.5–2.0 — что-то покрупнее.
func splash(pos: Vector2, strength := 1.0) -> void:
	_add_ring(pos, clampf(strength, 0.1, 2.0))


## Поклёвка: короткая серия из трёх убывающих колец — «буль-буль-буль».
func nibble(pos: Vector2) -> void:
	_add_ring(pos, 0.45)
	_add_ring(pos + Vector2(0.12, 0.05), 0.30)
	_add_ring(pos + Vector2(-0.08, 0.10), 0.20)


## След в воде: подмотка поплавка, брод путника. Тротлится по времени.
func wake(pos: Vector2, strength := 1.0) -> void:
	if t - _last_wake < 0.33:
		return
	_last_wake = t
	_add_ring(pos, 0.30 * clampf(strength, 0.0, 2.0))


## Высота воды в точке СЕЙЧАС: дыхание (мега-рябь) + все живые кольца.
## Зеркало шейдерной математики (mega_phase + кольца) — поплавок и физика
## качаются ровно на той воде, которую рисует шейдер.
func height_at(x: float, z: float) -> float:
	var h := _mega_h_cpu(x, z)
	for i in range(MAX_RINGS):
		var a := _amp[i]
		if a < 0.0005:
			continue
		var age := t - _t0[i]
		if age < 0.0:
			continue
		var dd := Vector2(x, z).distance_to(_pos[i])
		var rf := RING_SPEED * age
		var bw := RING_W0 + RING_WG * age
		var xx := (dd - rf) / bw
		var env := exp(-xx * xx)
		var ph := TAU / RING_WAVELEN * (dd - rf)
		var dec := exp(-age * RING_TAU) / sqrt(maxf(rf, 0.6))
		h += RING_AMP * a * env * cos(ph) * dec
	return h


## Высота поверхности для ноды воды (уровень добавляет WaterSurface).
func surface_offset(x: float, z: float) -> float:
	return height_at(x, z)


# ---------------------------------------------------------------------------
# Ядро колец
# ---------------------------------------------------------------------------

func _add_ring(pos: Vector2, amp: float) -> void:
	var i := _cursor
	_cursor = (_cursor + 1) % MAX_RINGS
	_pos[i] = pos
	_t0[i] = t
	_amp[i] = amp


func _process(delta: float) -> void:
	t += delta
	# гашение мёртвых слотов (не обязательно, но держит uniform чистым)
	for i in range(MAX_RINGS):
		if _amp[i] > 0.0 and t - _t0[i] > RING_LIFE:
			_amp[i] = 0.0
	# пуш в материал на PUSH_HZ (как карта песка на 30 Гц у SandField)
	_push_clock += delta
	if mat != null and _push_clock >= 1.0 / PUSH_HZ:
		_push_uniforms()
		_push_clock = 0.0


func _push_uniforms() -> void:
	var data := PackedVector4Array()
	data.resize(MAX_RINGS)
	for i in range(MAX_RINGS):
		data[i] = Vector4(_pos[i].x, _pos[i].y, _t0[i], _amp[i])
	mat.set_shader_parameter("u_rings", data)
	mat.set_shader_parameter("u_time", t)


# ---------------------------------------------------------------------------
# CPU-зеркало дыхания моря (mega_phase в шейдере, 1:1 из песка)
# ---------------------------------------------------------------------------

func _hash12(p: Vector2) -> float:
	var p3 := Vector3(fposmod(p.x * 0.1031, 1.0), fposmod(p.y * 0.1031, 1.0),
			fposmod(p.x * 0.1031, 1.0))
	var q := Vector3(p3.y, p3.z, p3.x) + Vector3(33.33, 33.33, 33.33)
	p3 += Vector3(p3.dot(q), p3.dot(q), p3.dot(q))
	return fposmod((p3.x + p3.y) * p3.z, 1.0)


func _vnoise(p: Vector2) -> float:
	var i := p.floor()
	var f := p - i
	f = Vector2(f.x * f.x * (3.0 - 2.0 * f.x), f.y * f.y * (3.0 - 2.0 * f.y)) # smoothstep 3f²-2f³
	var a := _hash12(i)
	var b := _hash12(i + Vector2(1.0, 0.0))
	var c := _hash12(i + Vector2(0.0, 1.0))
	var d := _hash12(i + Vector2(1.0, 1.0))
	return lerpf(lerpf(a, b, f.x), lerpf(c, d, f.x), f.y)


func _mega_h_cpu(x: float, z: float) -> float:
	var wdir := wind_dir.normalized() if wind_dir.length_squared() > 0.0001 else Vector2(0.32, -0.95)
	var wperp := Vector2(-wdir.y, wdir.x)
	var wp := Vector2(x, z)
	var u := wp.dot(wdir)
	var v := wp.dot(wperp)

	var rn := _vnoise(wp * 0.15)
	var rn2 := _vnoise(wp * 0.07 + Vector2(9.1, 3.3))

	var mph := v * 0.70 + u * 0.16 + rn * 2.6 + rn2 * 3.4 + t * 0.25

	return (cos(mph) * 0.62 + cos(mph * 2.63 + 1.7) * 0.30
			+ cos(mph * 0.47 + 0.8) * 0.22) * mega_amp * wind_power # ровно как в шейдере
