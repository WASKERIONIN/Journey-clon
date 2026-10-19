class_name CatchFish
extends Node3D
## Тонкий контроллер позы пойманной рыбы. Геометрии здесь нет: рыба в
## воде, в прыжке и в руках отрисовывается только общим SDF-реймарчером.

var _sdf: SandFish
var _info: Dictionary = {}
var _phase := 0.0
var _wiggle := 1.0
var _size_sdf := 0.25
var _tint := Color(0.6, 0.62, 0.6)


func bind_sdf(renderer: SandFish) -> void:
	_sdf = renderer


func setup(info: Dictionary) -> void:
	_info = info
	var size_cm := float(info.get("size_cm", 40.0))
	# В SDF-бланке длина тела 2.4 * s; этот коэффициент даёт
	# примерно реальные сантиметры в мировых метрах.
	_size_sdf = clampf(size_cm / 160.0, 0.10, 0.80)
	var tint: Color = info.get("col_a", Color(0.6, 0.62, 0.6))
	_tint = tint
	_wiggle = 1.0


func _process(delta: float) -> void:
	_phase += delta * 7.0 * _wiggle
	if _sdf == null:
		return
	if not visible or _info.is_empty():
		_sdf.clear_catch_visual(self)
		return

	var forward := -global_transform.basis.z
	var heading := atan2(forward.z, forward.x)
	var scale_vec := global_transform.basis.get_scale()
	var scale_mul := maxf(scale_vec.x, maxf(scale_vec.y, scale_vec.z))
	_sdf.set_catch_visual(self, global_position, _size_sdf * scale_mul,
		heading, _phase, _tint, _wiggle)


## Поставить SDF-рыбу в мировую позу (для прыжка/полёта).
func pose_world(pos: Vector3, yaw: float, roll: float) -> void:
	global_position = pos
	rotation = Vector3(0.0, yaw, roll)
	visible = true


func set_wiggle(v: float) -> void:
	_wiggle = clampf(v, 0.0, 1.5)
