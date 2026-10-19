class_name GodotFishWaterSurface
extends MeshInstance3D
## Песчаное море: меш + материал + поле колец, в одном узле.
##
## Строится кодом (как Terrain): плоскость с плотной сеткой под вершинное
## смещение «дыхания» (мега-рябь песка ~9 м). Уровень воды задаётся
## позицией узла по Y — шейдер считает, что узел НЕ ПОВЁРНУТ (только
## перенос): w_pos берётся из MODEL_MATRIX напрямую, как у песка.
##
## Кромка берега не рисуется: море выглядит как песок и сделано из того же
## шейдера, поэтому линия уреза срастается с берегом сама — там, где песок
## выше уровня воды, обычный depth-тест прячет море. Налил «воду» на любую
## высоту — берег получился сам.
##
## Использование (после terrain.setup):
##   var water := WaterSurface.new()
##   add_child(water)
##   water.setup(game, Vector2(-40, -120), 240.0, -6.0)
## Поплавок:  bobber.y = water.surface_height(x, z)

const SHADER_PATH := "res://shaders/water.gdshader"

var field: GodotFishWaterField
var level_y := 0.0
var size := 240.0

var game # автозагрузка Game (ветер — общий с песком)


func setup(game_ref, center: Vector2, p_size: float, p_level_y: float,
		segments: int = 192) -> void:
	game = game_ref
	size = p_size
	level_y = p_level_y
	position = Vector3(center.x, level_y, center.y)

	_build_mesh(segments)

	var mat := ShaderMaterial.new()
	mat.shader = load(SHADER_PATH)
	if game != null:
		mat.set_shader_parameter("sun_dir", game.sun_dir)
		mat.set_shader_parameter("fog_distance", game.FOG_DISTANCE)
	material_override = mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	field = GodotFishWaterField.new()
	field.name = "WaterField"
	add_child(field)
	field.material = mat
	field._push_uniforms() # сразу нулевые кольца, чтобы шейдер не ждал 1/30 с


## Высота поверхности моря в мировой точке (уровень + дыхание + кольца).
func surface_height(x: float, z: float) -> float:
	if field == null:
		return level_y
	return level_y + field.height_at(x, z)


func _process(_delta: float) -> void:
	if game == null or material_override == null:
		return
	var m: ShaderMaterial = material_override
	# один ветер на всю игру — как у песка (рябь и дыхание бегут вместе)
	m.set_shader_parameter("wind_dir", game.wind_dir())
	m.set_shader_parameter("wind_power", game.wind_strength)
	# и поле знает тот же ветер — физика поплавка совпадает с картинкой
	if field != null:
		field.wind_dir = game.wind_dir()
		field.wind_power = game.wind_strength
		var ma: Variant = m.get_shader_parameter("mega_amp")
		if ma != null:
			field.mega_amp = ma # если амплитуду тюнили вручную


func _build_mesh(segments: int) -> void:
	var n := segments + 1
	var count := n * n
	var half := size * 0.5
	var cell := size / float(segments)

	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	verts.resize(count)
	normals.resize(count)
	uvs.resize(count)
	for iz in range(n):
		var lz := -half + float(iz) * cell
		for ix in range(n):
			var i := iz * n + ix
			var lx := -half + float(ix) * cell
			verts[i] = Vector3(lx, 0.0, lz)
			normals[i] = Vector3.UP
			uvs[i] = Vector2(lx, lz) * 0.01

	# Winding — ТОТ ЖЕ, что у Terrain (FACE_Y: cross(e1,e2) = -Y),
	# иначе грань вывернута и море видно только снизу.
	var idx := PackedInt32Array()
	idx.resize(segments * segments * 6)
	var w := 0
	for iz in range(segments):
		for ix in range(segments):
			var a := iz * n + ix
			var b := a + 1
			var c := a + n
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
