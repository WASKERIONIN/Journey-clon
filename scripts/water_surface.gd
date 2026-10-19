class_name WaterSurface
extends MeshInstance3D
## Море: меш + материал + поле колец, в одном узле.
##
## Поверхность плоская (уровень воды), «дыхание» и кольца считаются
## аналитически — и в шейдере, и в CPU-зеркале WaterField, поэтому поплавок
## качается ровно на той воде, которую рисует глаз.
##
## Сетка НЕОДНОРОДНАЯ: у берега ячейка ~1.2 м (волны «дыхания» ~9 м читаются
## гладко), дальше шаг геометрически растёт до километров — море уходит за
## горизонт, оставаясь дешёвым.
##
## Урез: карта высот читается по фрагментам, без подрезания вершин воды
## к рельефу и без висящей плёнки. Градиент прозрачности сглаживает кромку.

const SHADER_PATH := "res://shaders/water.gdshader"

const DENSE_SPAN := 620.0 # однородная зона вокруг берега, м
const DENSE_CELL := 1.25 # ячейка в ней, м
const FAR_LIMIT := 3600.0 # докуда доходит море
const FAR_GROWTH := 1.16 # рост шага вдали

var field: WaterField
var level_y := 0.0
var mesh_size := 240.0

var game: GameState # автозагрузка Game (ветер — общий с песком)
var coast: Coast
var _night01 := 0.0
var _mat: ShaderMaterial


func setup(game_ref, center: Vector2, p_level_y: float) -> void:
	game = game_ref
	level_y = p_level_y
	position = Vector3(center.x, level_y, center.y)

	_build_mesh()

	_mat = ShaderMaterial.new()
	_mat.shader = load(SHADER_PATH)
	if game != null:
		_mat.set_shader_parameter("sun_dir", game.sun_dir)
		_mat.set_shader_parameter("fog_distance", game.FOG_DISTANCE)
	# уровень моря: шейдер вычисляет глубину у кромки берега
	_mat.set_shader_parameter("sea_level", level_y)
	material_override = _mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# море непрозрачное в глубине, alpha используется только у мягкого уреза; рисуем ПЕРВЫМ:
	# SDF-квад существ читает u_screen с уже нарисованной водой (по ней
	# считается «вуаль» подводных китов) и рисуется поверх (у него 4096).
	# transparency = 0 выключает сортировку по глубине — порядок задаёт
	# sorting_offset, иначе море уплывало за SDF-слой.
	transparency = 0.0
	sorting_offset = -4096.0

	field = WaterField.new()
	field.name = "WaterField"
	add_child(field)
	field.mat = _mat
	field._push_uniforms() # сразу нулевые кольца, чтобы шейдер не ждал 1/30 с


## Высота поверхности моря в мировой точке (уровень + дыхание + кольца).
func surface_height(x: float, z: float) -> float:
	if field == null:
		return level_y
	var shore_fade := 1.0
	if coast != null:
		var depth := coast.water_depth(x, z)
		var t := clampf(depth / 4.0, 0.0, 1.0)
		shore_fade = t * t * (3.0 - 2.0 * t)
	return level_y + field.height_at(x, z) * shore_fade


func material() -> ShaderMaterial:
	return _mat


func set_param(param: String, value) -> void:
	if _mat != null:
		_mat.set_shader_parameter(param, value)


## Карта высот берега из Coast: по ней море кладёт плёнку прибоя на песок.
func set_ground(tex: Texture2D, origin: Vector2, cell: float, n: int,
		coast_ref: Coast = null) -> void:
	coast = coast_ref
	set_param("ground_tex", tex)
	set_param("ground_origin", origin)
	set_param("ground_cell", cell)
	set_param("ground_n", float(n))


func apply_sun(dir: Vector3) -> void:
	set_param("sun_dir", dir)


## Палитра моря: день — бирюза/индиго, ночь — почти чёрная глубина.
## Песок сюда НЕ подмешивается: у суши и воды разные материалы.
const DAY_SHALLOW := Color(0.30, 0.66, 0.62)
const DAY_MID := Color(0.10, 0.38, 0.48)
const DAY_DEEP := Color(0.035, 0.150, 0.300)
const DAY_FOAM := Color(0.95, 0.92, 0.86)
const NIGHT_SHALLOW := Color(0.045, 0.110, 0.120)
const NIGHT_MID := Color(0.012, 0.040, 0.060)
const NIGHT_DEEP := Color(0.003, 0.010, 0.022)
const NIGHT_FOAM := Color(0.30, 0.36, 0.42)


func apply_night01(v: float) -> void:
	_night01 = clampf(v, 0.0, 1.0)
	set_param("water_shallow", DAY_SHALLOW.lerp(NIGHT_SHALLOW, v))
	set_param("water_mid", DAY_MID.lerp(NIGHT_MID, v))
	set_param("water_deep", DAY_DEEP.lerp(NIGHT_DEEP, v))
	set_param("foam_col", DAY_FOAM.lerp(NIGHT_FOAM, v))
	set_param("horizon_col", Coast.DAY_HORIZON.lerp(Coast.NIGHT_HORIZON, v))
	set_param("sky_col", Coast.DAY_SKY.lerp(Coast.NIGHT_SKY, v))
	set_param("fog_distance", lerpf(340.0, 130.0, v))
	# На ночной воде гасим обычные микроблики и солнечные частицы:
	# редкие огни остаются, а звёзды на песке не превращаются в сплошную россыпь.
	set_param("glitter_amount", lerpf(1.0, 0.08, _night01))
	set_param("solar_glitter_amount", lerpf(1.0, 0.0, _night01))


func _process(_delta: float) -> void:
	if game == null or _mat == null:
		return
	# Погода усиливает море нелинейно; ночью дыхание чуть спокойнее.
	# F3 меняет базовый mega_amp, а этот множитель мягко следует ветру.
	var weather01 := clampf((game.wind_strength - 0.65) / 0.70, 0.0, 1.0)
	var weather_gain := lerpf(0.72, 1.28, weather01)
	var night_gain := lerpf(1.0, 0.84, _night01)
	var sea_power := clampf(game.wind_strength * weather_gain * night_gain, 0.45, 1.65)
	_mat.set_shader_parameter("wind_dir", game.wind_dir())
	_mat.set_shader_parameter("wind_power", sea_power)
	if field != null:
		field.wind_dir = game.wind_dir()
		field.wind_power = sea_power
		var ma: Variant = _mat.get_shader_parameter("mega_amp")
		if ma != null:
			field.mega_amp = ma # CPU-поплавок следует за F3 и морским состоянием


# ---------------------------------------------------------------------------
# Неоднородная сетка: плотно у берега, редко вдали
# ---------------------------------------------------------------------------

## Координаты оси: однородный центр + геометрически растущие хвосты.
func _axis() -> PackedFloat32Array:
	var half := DENSE_SPAN * 0.5
	var n := int(round(DENSE_SPAN / DENSE_CELL))
	var step := DENSE_SPAN / float(n)
	var tail := PackedFloat32Array()
	var x := half
	var s := step
	while x < FAR_LIMIT:
		s *= FAR_GROWTH
		x += s
		tail.append(x)
	var head := PackedFloat32Array()
	x = -half
	s = step
	while x > -FAR_LIMIT:
		s *= FAR_GROWTH
		x -= s
		head.append(x)

	var out := PackedFloat32Array()
	out.resize(head.size() + n + 1 + tail.size())
	var k := 0
	for i in range(head.size() - 1, -1, -1):
		out[k] = head[i]
		k += 1
	for i in range(n + 1):
		out[k] = -half + float(i) * step
		k += 1
	for i in range(tail.size()):
		out[k] = tail[i]
		k += 1
	return out


func _build_mesh() -> void:
	var xs := _axis()
	var zs := _axis()
	var nx := xs.size()
	var nz := zs.size()
	var count := nx * nz

	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	verts.resize(count)
	normals.resize(count)
	uvs.resize(count)
	for iz in range(nz):
		var lz := zs[iz]
		for ix in range(nx):
			var i := iz * nx + ix
			var lx := xs[ix]
			verts[i] = Vector3(lx, 0.0, lz)
			normals[i] = Vector3.UP
			uvs[i] = Vector2(lx, lz) * 0.01

	# Winding — тот же, что у берега (FACE_Y), иначе грань вывернута.
	var idx := PackedInt32Array()
	idx.resize((nx - 1) * (nz - 1) * 6)
	var w := 0
	for iz in range(nz - 1):
		for ix in range(nx - 1):
			var a := iz * nx + ix
			var b := a + 1
			var c := a + nx
			var d := c + 1
			idx[w] = d
			idx[w + 1] = c
			idx[w + 2] = b
			idx[w + 3] = c
			idx[w + 4] = a
			idx[w + 5] = b
			w += 6

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx

	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh = m
