class_name CoastProps
extends Node3D
## Декор берега: «морские пальцы» (тёмные каменные столбы в воде),
## коряги, выброшенные прибоем, и мелкие камни у подножия дюн.
##
## Всё — процедурная геометрия (MeshKit), две-три draw-call-группы:
## камень, мокрое дерево, сухое дерево. Никаких ассетов.
## Позиции привязаны к линии уреза, поэтому работают при любой кривизне
## берега: камни стоят в воде, коряги — на песке.

var coast: Coast
var game: GameState


func setup(coast_ref, game_ref) -> void:
	coast = coast_ref
	game = game_ref
	_build_stacks()
	_build_driftwood()
	_build_stones()


func _rock_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.albedo_color = Color.WHITE
	m.roughness = 0.92
	m.metallic_specular = 0.30
	return m


func _wood_material(wet: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.albedo_color = Color.WHITE
	m.roughness = 0.95 if not wet else 0.72
	m.metallic_specular = 0.28
	return m


## Тёмные столбы в воде: дальние ориентиры и «необычность» берега.
func _build_stacks() -> void:
	var st := MeshKit.begin()
	var basalt := Color(0.115, 0.105, 0.110)
	var spots := [
		# z, сколько метров от уреза в море, высота, радиус
		[-168.0, 66.0, 17.0, 3.4],
		[-118.0, 96.0, 23.0, 4.1],
		[-44.0, 120.0, 12.0, 2.2],
		[52.0, 78.0, 19.0, 3.0],
		[118.0, 105.0, 27.0, 4.6],
		[186.0, 72.0, 14.0, 2.6],
	]
	var i := 0
	for s in spots:
		var z: float = s[0]
		var out: float = s[1]
		var h: float = s[2]
		var r: float = s[3]
		var x := coast.shore_x(z) - out
		var base := Vector3(x, coast.height_at(x, z) - 0.4, z)
		MeshKit.add_rock_stack(st, base, h, r, r * 0.55, 300 + i * 37,
			basalt, 12, 6)
		i += 1
		# мелкий «спутник» рядом — силуэт не одинок
		var x2 := x + r * 1.6
		var z2 := z + r * 1.2
		var base2 := Vector3(x2, coast.height_at(x2, z2) - 0.4, z2)
		MeshKit.add_rock_stack(st, base2, h * 0.34, r * 0.55, r * 0.3,
			700 + i * 13, basalt, 10, 4)

	var mi := MeshInstance3D.new()
	mi.mesh = MeshKit.finish(st)
	mi.material_override = _rock_material()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(mi)


## Коряги на пляже: выброшены прибоем, полузасыпаны песком.
func _build_driftwood() -> void:
	var st := MeshKit.begin()
	var dry := Color(0.255, 0.205, 0.165)
	var bleached := Color(0.36, 0.31, 0.255)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4711
	var spots := [-84.0, 18.0, 92.0, 168.0, -152.0]
	for z in spots:
		var inland := rng.randf_range(5.0, 15.0)
		var x := coast.shore_x(z) + inland
		var y := coast.sample_height(x, z)
		var ang := rng.randf_range(-0.9, 0.9)
		var dir := Vector3(cos(ang), 0.0, sin(ang))
		var ln := rng.randf_range(2.4, 5.6)
		var a := Vector3(x, y - 0.06, z) - dir * ln * 0.5
		var b := a + dir * ln
		b.y = coast.sample_height(b.x, b.z) + rng.randf_range(0.02, 0.25)
		var col := dry.lerp(bleached, rng.randf() * 0.8)
		MeshKit.add_log(st, a, b, rng.randf_range(0.13, 0.22),
			rng.randf_range(0.05, 0.10), col, 8)
		# пара обломанных веток
		for _k in range(2):
			var p := a.lerp(b, rng.randf_range(0.25, 0.75))
			var bd := Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(0.15, 0.7),
				rng.randf_range(-1.0, 1.0)).normalized()
			MeshKit.add_log(st, p, p + bd * rng.randf_range(0.5, 1.2),
				0.055, 0.02, col * 0.9, 6)

	var mi := MeshInstance3D.new()
	mi.mesh = MeshKit.finish(st)
	mi.material_override = _wood_material(false)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(mi)


## Мелкие камни у подножия дюн — глаз цепляется за масштаб.
func _build_stones() -> void:
	var st := MeshKit.begin()
	var rng := RandomNumberGenerator.new()
	rng.seed = 1301
	var tone := Color(0.24, 0.205, 0.19)
	for i in range(26):
		var z := rng.randf_range(-210.0, 210.0)
		var inland := rng.randf_range(24.0, 62.0)
		var x := coast.shore_x(z) + inland
		var y := coast.sample_height(x, z)
		var s := rng.randf_range(0.22, 0.75)
		MeshKit.add_rock_stack(st, Vector3(x, y - 0.12, z), s,
			s * 0.9, s * 0.5, 900 + i * 7,
			tone.lerp(Color(0.35, 0.30, 0.27), rng.randf()), 7, 3)
	var mi := MeshInstance3D.new()
	mi.mesh = MeshKit.finish(st)
	mi.material_override = _rock_material()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(mi)
