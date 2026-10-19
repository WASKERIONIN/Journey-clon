class_name ColorGrader
extends CanvasLayer
## Полноэкранный колор-грейдинг — по мотивам ассета «Color Grading»
## (Rytelier): тени/средние/света, вибранс, температура, «ночь Пуркинье».
## Эффекты ассета — композиторные (Forward+), у нас gl_compatibility:
## грейд рисуется шейдерным прямоугольником поверх кадра. Пресеты
## и крутилки — в DEV-панели (F3); в игре игрока никакого UI нет.

const PRESETS := [
	{
		"name": "Нейтрал",
		"tint_shadows": Color(1.00, 1.00, 1.00),
		"tint_midtones": Color(1.00, 1.00, 1.00),
		"tint_highlights": Color(1.00, 1.00, 1.00),
		"brightness": 1.0, "contrast": 1.0, "vibrance": 0.0,
		"temperature": 0.0, "night": 0.0,
	},
	{
		"name": "Тёплая пустыня",
		"tint_shadows": Color(1.05, 1.00, 0.95),
		"tint_midtones": Color(1.04, 1.00, 0.96),
		"tint_highlights": Color(1.03, 1.00, 0.97),
		"brightness": 1.02, "contrast": 1.04, "vibrance": 0.12,
		"temperature": 0.15, "night": 0.0,
	},
	{
		"name": "Золотой час",
		"tint_shadows": Color(1.10, 0.98, 0.92),
		"tint_midtones": Color(1.08, 1.00, 0.88),
		"tint_highlights": Color(1.06, 0.98, 0.85),
		"brightness": 1.03, "contrast": 1.06, "vibrance": 0.18,
		"temperature": 0.35, "night": 0.0,
	},
	{
		"name": "Бирюзовый закат",
		"tint_shadows": Color(0.92, 1.02, 1.10),
		"tint_midtones": Color(1.00, 1.00, 1.00),
		"tint_highlights": Color(1.06, 0.99, 0.90),
		"brightness": 1.0, "contrast": 1.10, "vibrance": 0.15,
		"temperature": 0.10, "night": 0.0,
	},
	{
		"name": "Ночь (Пуркинье)",
		"tint_shadows": Color(0.90, 0.95, 1.10),
		"tint_midtones": Color(0.95, 0.98, 1.05),
		"tint_highlights": Color(1.00, 1.00, 1.02),
		"brightness": 0.90, "contrast": 1.08, "vibrance": -0.06,
		"temperature": -0.25, "night": 0.8,
	},
	{
		"name": "Плёнка",
		"tint_shadows": Color(1.06, 1.03, 1.02),
		"tint_midtones": Color(1.02, 1.00, 0.99),
		"tint_highlights": Color(0.99, 0.98, 0.96),
		"brightness": 1.0, "contrast": 0.94, "vibrance": 0.08,
		"temperature": 0.05, "night": 0.0,
	},
]

var _mat: ShaderMaterial
var preset_idx := 4 # ночь: «Пуркинье» — хоррор по умолчанию
var intensity := 0.38


func setup() -> void:
	layer = 11 # поверх виньетки (10), под DEV-панелью (20)
	_mat = ShaderMaterial.new()
	_mat.shader = load("res://shaders/color_grade.gdshader")
	var rect := ColorRect.new()
	rect.material = _mat
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(rect)
	apply_preset(preset_idx)
	set_intensity(intensity)


func preset_name(idx: int) -> String:
	return PRESETS[clampi(idx, 0, PRESETS.size() - 1)]["name"]


func preset_count() -> int:
	return PRESETS.size()


## Применить пресет целиком (точечные крутилки DEV-панели — поверх).
func apply_preset(idx: int) -> void:
	preset_idx = clampi(idx, 0, PRESETS.size() - 1)
	var p: Dictionary = PRESETS[preset_idx]
	for key in ["tint_shadows", "tint_midtones", "tint_highlights",
			"brightness", "contrast", "vibrance", "temperature", "night"]:
		_mat.set_shader_parameter(key, p[key])


func set_intensity(v: float) -> void:
	intensity = clampf(v, 0.0, 1.0)
	_mat.set_shader_parameter("intensity", intensity)


## Точечная правка одного параметра (крутилки DEV-панели).
func set_param(key: String, v: float) -> void:
	_mat.set_shader_parameter(key, v)
