class_name SolarGazeBlur
extends CanvasLayer
## Мягкое расфокусирование окружения после продолжительного взгляда
## вдоль направления солнечной дорожки. Время выдержки задаёт MainScene.

var _mat: ShaderMaterial


func setup() -> void:
	layer = 8 # до звёзд, HUD и остальных слоёв интерфейса
	_mat = ShaderMaterial.new()
	_mat.shader = load("res://shaders/solar_gaze_blur.gdshader")
	var rect := ColorRect.new()
	rect.material = _mat
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(rect)
	set_amount(0.0)


func set_amount(value: float) -> void:
	if _mat != null:
		_mat.set_shader_parameter("blur_amount", clampf(value, 0.0, 1.0))
