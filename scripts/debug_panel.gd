class_name DebugPanel
extends CanvasLayer
## DEV-панель крутилок (F3): время суток, небо, песок, море, пост, ветер.
## По умолчанию скрыта — в игре игрока никакого текста нет.
## Живые значения применяются к материалам сразу же.
##
## Панель — инструмент разработки, поэтому говорит на языке материалов:
## песок — sand.gdshader, море — water.gdshader, оба смотрят на одни
## и те же uniform-ы палитры (их двигает главный ползунок «Время суток»).

var main

var _box: VBoxContainer
var _fps_label: Label
var _sun_elev := 16.4 # градусы
var _sun_azim := -61.4
## Ползунки, у которых есть «живой» геттер: при открытии панели они
## показывают реальное состояние сцены, а не дефолт, с которым родились.
var _live: Array[Dictionary] = []
var _ssao_check: CheckBox
var _msaa_check: CheckBox
var _vol_check: CheckBox


func setup(main_ref) -> void:
	main = main_ref
	layer = 20
	visible = false
	_build_ui()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_F3:
			visible = not visible
			if visible:
				_refresh()


func _process(_delta: float) -> void:
	if visible and _fps_label != null:
		_fps_label.text = "FPS: %d" % Engine.get_frames_per_second()


# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	panel.offset_left = -470.0
	panel.offset_top = 12.0
	panel.offset_right = -12.0
	panel.offset_bottom = 1030.0
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(panel)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(scroll)

	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 4)
	_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_box)

	_fps_label = _label("FPS: —")
	_box.add_child(_fps_label)

	var world: GameWorld = main.world
	var coast: Coast = main.coast

	_section("ГРАФИКА / АРТЕФАКТЫ")
	_ssao_check = _toggle("SSAO/SSIL (экранное AO)", world.screen_ao,
		func(on): world.set_screen_ao(on))
	_ssao_check.tooltip_text = "Чёрные прямоугольники на песке ночью — это половинное разрешение SSAO/SSIL. Выключено по умолчанию; включайте для A/B на своей видеокарте."
	_msaa_check = _toggle("MSAA 2x (сглаживание)", true,
		func(on):
			get_viewport().msaa_3d = Viewport.MSAA_2X if on else Viewport.MSAA_DISABLED)
	_msaa_check.tooltip_text = "Связка «PSSM-тени + экранные эффекты + MSAA 4x/8x» даёт чёрные квадраты (godot#103669/#81060). Проект живёт на 2x: если на вашей видеокарте песок всё ещё чёрный — выключите MSAA полностью и сравните."
	_vol_check = _toggle("Объёмный туман", world.volumetric,
		func(on): world.set_volumetric(on))
	_vol_check.tooltip_text = "Второй подозреваемый в «чёрных островах»: объёмный проход. Выключите и сравните кадр — разница видна сразу."

	_section("ВРЕМЯ СУТОК")
	_slider("Время (0=день, 1=ночь)", 0.0, 1.0, main.game.night01, 0.01,
		func(v): main.set_time(v),
		func(): return main.game.night01)
	_slider("Искры в тенях: яркость", 0.0, 2.5, 2.5, 0.02,
		func(v): main.coast.set_sand("shadow_star_intensity", v),
		func(): return coast.get_sand("shadow_star_intensity"))
	_slider("Искры в тенях: редкость", 0.15, 0.98, 0.30, 0.01,
		func(v): main.coast.set_sand("shadow_star_density", v),
		func(): return coast.get_sand("shadow_star_density"))

	_section("НЕБО")
	_slider("Солнце: высота°", 2.0, 85.0, _sun_elev, 0.5,
		func(v): _on_sun_changed(v, null))
	_slider("Солнце: азимут°", -180.0, 180.0, _sun_azim, 1.0,
		func(v): _on_sun_changed(null, v))
	_slider("Яркость солнца", 5.0, 140.0, 50.0, 1.0,
		func(v): world.set_sky("sun_intensity", v))
	_slider("Mie (дымка)", 0.0, 30.0, 8.0, 0.5,
		func(v): world.set_sky("mie_scattering", v * 0.000001))
	_slider("Слой Рэлея", 2000.0, 14000.0, 8000.0, 100.0,
		func(v): world.set_sky("rayleigh_scale_height", v))
	_slider("Мультирассеяние", 0.0, 0.2, 0.025, 0.002,
		func(v): world.set_sky("rayleigh_multi_scattering", v))
	_slider("Облака: покрытие", 0.0, 1.0, 0.5, 0.01,
		func(v): world.set_sky("cloud_cover", v))
	_slider("Облака: размер", 0.4, 3.0, 1.25, 0.05,
		func(v): world.set_sky("cloud_size", v))
	_slider("Облака: дрейф, м/с", 0.0, 25.0, 7.0, 0.5,
		func(v): world.set_sky("cloud_drift", v))

	_section("ПЕСОК / БЕРЕГ")
	_slider("Блёстки (доля)", 0.0, 0.5, 0.20, 0.01,
		func(v): coast.set_sand("glitter_amount", v),
		func(): return coast.get_sand("glitter_amount"))
	_slider("Дымка песка (м)", 100.0, 900.0, 340.0, 10.0,
		func(v):
			coast.set_sand("fog_distance", v)
			main.water.set_param("fog_distance", v))

	_section("МОРЕ")
	_slider("Дыхание моря", 0.0, 0.12, 0.055, 0.005,
		func(v): main.water.set_param("mega_amp", v))
	_slider("Кольца (сила)", 0.0, 0.15, 0.055, 0.005,
		func(v): main.water.set_param("ring_amp", v))
	_slider("Кольца (крутизна)", 0.0, 3.0, 1.4, 0.05,
		func(v): main.water.set_param("ring_boost", v))
	_slider("Глиттер поверхности", 0.0, 1.0, 1.0, 0.01,
		func(v): main.water.set_param("glitter_amount", v))
	_slider("Солнечный глиттер", 0.0, 1.0, 1.0, 0.01,
		func(v): main.water.set_param("solar_glitter_amount", v))
	var proxima_check := CheckBox.new()
	proxima_check.text = "Proxima + GGX: море и песок"
	proxima_check.tooltip_text = "A/B прямого света на двух главных материалах сцены; не меняет объекты StandardMaterial3D и солнечные частицы"
	proxima_check.toggled.connect(func(on):
		main.set_proxima_test(1.0 if on else 0.0))
	_box.add_child(proxima_check)
	_slider("Рябь моря (сила)", 0.0, 1.0, 0.50, 0.02,
		func(v): main.water.set_param("ripple_strength", v))

	_section("ПОСТ")
	_slider("Экспозиция", 0.5, 2.0, world.get_exposure(), 0.02,
		func(v): world.set_exposure(v),
		func(): return world.get_exposure())
	_slider("Порог glow", 0.5, 2.0, world.get_glow_threshold(), 0.02,
		func(v): world.set_glow_threshold(v),
		func(): return world.get_glow_threshold())

	_section("ЦВЕТ (ГРЕЙДИНГ)")
	_preset_slider()
	_slider("Сила грейда", 0.0, 1.0, main.color_grade.intensity, 0.01,
		func(v): main.color_grade.set_intensity(v))
	_slider("Тепло", -1.0, 1.0, 0.15, 0.01,
		func(v): main.color_grade.set_param("temperature", v))
	_slider("Контраст", 0.6, 1.7, 1.04, 0.01,
		func(v): main.color_grade.set_param("contrast", v))
	_slider("Вибранс", -0.6, 0.6, 0.12, 0.01,
		func(v): main.color_grade.set_param("vibrance", v))
	_slider("Ночь (Пуркинье)", 0.0, 1.0, main.color_grade.get_param("night"), 0.01,
		func(v): main.color_grade.set_param("night", v),
		func(): return main.color_grade.get_param("night"))

	_section("ВОЛЮМЕТРИК (ТУМАН)")
	_slider("Плотность", 0.002, 0.12, 0.008, 0.001,
		func(v): world.set_vol_fog("volumetric_fog_density", v),
		func(): return world.get_vol_fog("volumetric_fog_density"))
	_slider("Дальность, м", 48.0, 256.0, 160.0, 4.0,
		func(v): world.set_vol_fog("volumetric_fog_length", v))
	_slider("Анизотропия", 0.0, 1.0, 0.72, 0.02,
		func(v): world.set_vol_fog("volumetric_fog_anisotropy", v))
	_slider("Подсветка неба", 0.0, 1.0, 0.12, 0.02,
		func(v): world.set_vol_fog("volumetric_fog_ambient_inject", v))
	_slider("Фонарик", 0.0, 8.0, main.cam_rig.flashlight.light_energy, 0.1,
		func(v): main.cam_rig.flashlight.light_energy = v,
		func(): return main.cam_rig.flashlight.light_energy)

	_section("ВЕТЕР")
	_slider("Направление°", -180.0, 180.0, rad_to_deg(main.game.wind_base), 1.0,
		func(v): main.game.wind_base = deg_to_rad(v))

	_label("F3 — скрыть панель")


func _preset_slider() -> void:
	var grade: ColorGrader = main.color_grade
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_box.add_child(row)

	var l := _label("Пресет")
	l.custom_minimum_size = Vector2(170.0, 0)
	row.add_child(l)

	var s := HSlider.new()
	s.min_value = 0.0
	s.max_value = float(grade.preset_count() - 1)
	s.step = 1.0
	s.value = grade.preset_idx
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.custom_minimum_size = Vector2(150.0, 20.0)
	row.add_child(s)

	var vlabel := _label(grade.preset_name(grade.preset_idx))
	vlabel.custom_minimum_size = Vector2(130.0, 0)
	row.add_child(vlabel)
	s.value_changed.connect(func(v): grade.apply_preset(int(v)))
	s.value_changed.connect(func(v): vlabel.text = grade.preset_name(int(v)))


func _section(title: String) -> void:
	var l := _label(title)
	l.add_theme_color_override("font_color", Color(1.0, 0.8, 0.5))
	_box.add_child(l)


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 13)
	return l


func _slider(text: String, min_v: float, max_v: float, val: float, step: float,
		cb: Callable, getter := Callable()) -> HSlider:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_box.add_child(row)

	var l := _label(text)
	l.custom_minimum_size = Vector2(170.0, 0)
	row.add_child(l)

	var s := HSlider.new()
	s.min_value = min_v
	s.max_value = max_v
	s.step = step
	s.value = val
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.custom_minimum_size = Vector2(150.0, 20.0)
	s.value_changed.connect(cb)
	row.add_child(s)

	var vlabel := _label("%.3f" % val)
	vlabel.custom_minimum_size = Vector2(58.0, 0)
	row.add_child(vlabel)
	s.value_changed.connect(func(v): vlabel.text = "%.3f" % v)
	if getter.is_valid():
		_live.append({"slider": s, "label": vlabel, "get": getter})
	return s


func _toggle(text: String, value: bool, cb: Callable) -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.button_pressed = value
	c.toggled.connect(cb)
	_box.add_child(c)
	return c


## Синхронизация: «Время суток» меняет не только себя, но и палитры,
## экспозицию, туман; «Ночь (Пуркинье)» живёт в color_grade. Раньше панель
## показывала дефолты слайдеров, и по ней нельзя было понять, что в кадре
## (например, «Ночь 0.000» при включённой ночи).
func _refresh() -> void:
	for item in _live:
		var s: HSlider = item["slider"]
		var lab: Label = item["label"]
		var cb: Callable = item["get"]
		var v: float = float(cb.call())
		v = clampf(v, s.min_value, s.max_value)
		s.set_value_no_signal(v)
		lab.text = "%.3f" % v
	if _ssao_check != null:
		_ssao_check.set_pressed_no_signal(main.world.screen_ao)
	if _msaa_check != null:
		_msaa_check.set_pressed_no_signal(get_viewport().msaa_3d != Viewport.MSAA_DISABLED)
	if _vol_check != null:
		_vol_check.set_pressed_no_signal(main.world.volumetric)


# ---------------------------------------------------------------------------
# Применение
# ---------------------------------------------------------------------------

func _on_sun_changed(elev: Variant, azim: Variant) -> void:
	if elev != null:
		_sun_elev = float(elev)
	if azim != null:
		_sun_azim = float(azim)
	var el := deg_to_rad(_sun_elev)
	var az := deg_to_rad(_sun_azim)
	var dir := Vector3(sin(az) * cos(el), sin(el), -cos(az) * cos(el)).normalized()
	main.apply_sun(dir)
