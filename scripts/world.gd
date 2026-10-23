class_name GameWorld
extends Node3D
## Небо, луна, волюметрический туман (Forward+/Vulkan), виньетка.
## Всё строится кодом в setup(). Горизонт закрыт настоящими дальними
## дюнами — карта террейна расширена (см. Coast), никаких подставок.

var game: GameState # автозагрузка Game

var _sky_mat: ShaderMaterial
var _sun: DirectionalLight3D
var _env: Environment
var _using_sky_plus := false
var _cloud_drift := 7.0
var compat_fallback := false # Vulkan не поднялся → Godot ушёл в Compatibility
var screen_ao := false # SSAO/SSIL: по умолчанию ВЫКЛ (см. _apply_screen_ao)
var volumetric := true # объёмный туман: тумблер для A/B на своей видеокарте


func setup(game_ref) -> void:
	game = game_ref
	_build_environment()
	_build_sun()
	_build_vignette()


func _build_environment() -> void:
	# Полный Sky++ в Forward+: Rayleigh/Mie/Ozone + half-res raymarched
	# cumulus + cirrus. В Compatibility остаётся лёгкое прежнее небо.
	_using_sky_plus = RenderingServer.get_rendering_device() != null
	_sky_mat = ShaderMaterial.new()
	_sky_mat.shader = load("res://shaders/sky_plus.gdshader" if _using_sky_plus \
		else "res://shaders/sky.gdshader")
	if _using_sky_plus:
		_setup_sky_plus_material()
	else:
		_sky_mat.set_shader_parameter("sun_direction", game.sun_dir)

	var sky := Sky.new()
	sky.process_mode = Sky.PROCESS_MODE_REALTIME if _using_sky_plus else Sky.PROCESS_MODE_AUTOMATIC
	# Realtime Sky в Godot поддерживает только 256; явное значение убирает
	# предупреждение и совпадает с фактическим внутренним размером.
	sky.radiance_size = Sky.RADIANCE_SIZE_256 if _using_sky_plus else Sky.RADIANCE_SIZE_128
	sky.sky_material = _sky_mat

	_env = Environment.new()
	_env.background_mode = Environment.BG_SKY
	_env.sky = sky
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	_env.ambient_light_energy = 1.0

	# Киношный тонмаппинг: ночью чуть длиннее выдержка
	_env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	_env.tonemap_exposure = 1.08
	_env.tonemap_white = 4.0

	# Свечение: солнце и искры песка (в Compatibility glow есть)
	_env.glow_enabled = true
	_env.glow_intensity = 0.55
	_env.glow_strength = 1.0
	_env.glow_bloom = 0.08
	_env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	_env.glow_hdr_threshold = 1.15

	# Контактная глубина и непрямой экранный свет. ВАЖНО: по умолчанию
	# ВЫКЛЮЧЕНО. SSAO/SSIL в Forward+ считаются в половинном разрешении и на
	# больших плоскостях под скользящим ракурсом (наш пляж — 900×900 м) дают
	# чёрные прямоугольные острова; в связке с PSSM-тенями и MSAA 4x это
	# известные «black square artifacts» (godot#103669, #81060). Именно они
	# и превращали песок в «чёрный и пиксельный», когда фонарь выключен:
	# фонарь — единственный прямой свет, экранное AO гасит всё остальное.
	# Объём дюн уже запечён в UV2 (Coast: 8 азимутов × 3 дистанции), а
	# контактные тени дают настоящие тени от солнца. Тумблер — в DEV-панели.
	_apply_screen_ao(false)

	# Дымка в цвет горизонта — для любых материалов со стандартным туманом.
	_env.fog_enabled = true
	_env.fog_light_color = Game.HORIZON_COL
	_env.fog_density = 0.0034
	# Небо тоже должно уходить в дымку у горизонта. Нулевое значение делало
	# стык неба и дюн резким и визуально выдавало пост-эффект.
	_env.fog_sky_affect = 0.35

	# ВОЛЮМЕТРИЧЕСКИЙ ТУМАН (Forward+/Vulkan): настоящий 3D-объём —
	# луч фонаря и огонь маяка видны в воздухе. Ночь пустыни: плотный
	# холодный туман гуляет по дюнам. Крутилки — в DEV-панели (F3).
	_env.volumetric_fog_enabled = true
	# 0.09 превращало весь кадр в равномерную серую стену и убивало глубину.
	# Более длинный и прозрачный объём даёт планы, силуэты и световые лучи.
	_env.volumetric_fog_density = 0.026
	_env.volumetric_fog_albedo = Color(0.46, 0.52, 0.64)
	_env.volumetric_fog_emission = Color(0.006, 0.009, 0.018)
	_env.volumetric_fog_emission_energy = 0.35
	_env.volumetric_fog_anisotropy = 0.72
	_env.volumetric_fog_length = 160.0
	_env.volumetric_fog_detail_spread = 1.5
	_env.volumetric_fog_ambient_inject = 0.22
	_env.volumetric_fog_gi_inject = 0.0
	_env.volumetric_fog_sky_affect = 0.30
	_env.volumetric_fog_temporal_reprojection_enabled = true

	var world_env := WorldEnvironment.new()
	world_env.environment = _env
	add_child(world_env)


## Энергия объёмного рассеяния у направленного света (диагностика CI:
## отрицательное значение возвращает расчётное ночное/дневное значение).
func set_sun_fog_energy(v: float) -> void:
	if _sun == null:
		return
	_sun.light_volumetric_fog_energy = v if v >= 0.0 \
		else lerpf(0.75, 0.10, game.night01)


## Объёмный туман — A/B-тумблер: на некоторых драйверах объёмный проход
## бывает источником артефактов, а стоить он может несколько кадров.
func set_volumetric(on: bool) -> void:
	volumetric = on
	if _env != null:
		_env.volumetric_fog_enabled = on


## Экранное AO (SSAO + SSIL) — A/B-тумблер для DEV-панели и для тех, кто
## хочет проверить артефакт на своей видеокарте. Значения подобраны так,
## чтобы даже включённое AO не выжигало песок: маленький радиус, мягкая
## интенсивность и `ssao_light_affect = 0` (прямой свет не трогаем).
func set_screen_ao(on: bool) -> void:
	_apply_screen_ao(on)


func _apply_screen_ao(on: bool) -> void:
	screen_ao = on
	if _env == null:
		return
	_env.ssao_enabled = on
	_env.ssao_radius = 1.4
	_env.ssao_intensity = 0.75
	_env.ssao_power = 1.5
	_env.ssao_detail = 0.5
	_env.ssao_horizon = 0.06
	_env.ssao_sharpness = 0.98
	_env.ssao_light_affect = 0.0
	_env.ssao_ao_channel_affect = 0.0
	_env.ssil_enabled = on
	_env.ssil_radius = 2.5
	_env.ssil_intensity = 0.30
	_env.ssil_normal_rejection = 1.5


## Sky++ preset: original look, but tuned from 64+64 marches to a practical
## 16 atmosphere / 24 cloud samples. Clouds render in the half-resolution pass.
func _setup_sky_plus_material() -> void:
	_sky_mat.set_shader_parameter("atmosphere_sample_count", 16)
	_sky_mat.set_shader_parameter("rayleigh_strength", 1.0)
	_sky_mat.set_shader_parameter("mie_strength", 0.82)
	_sky_mat.set_shader_parameter("ozone_strength", 1.0)
	_sky_mat.set_shader_parameter("mie_anisotropy_factor", 0.78)
	_sky_mat.set_shader_parameter("atmosphere_density", 1.0)
	_sky_mat.set_shader_parameter("exposure", 11.5)
	_sky_mat.set_shader_parameter("sundisc_intensity", 24.0)
	_sky_mat.set_shader_parameter("sun_disc_feather", 0.35)
	_sky_mat.set_shader_parameter("coverage", 0.43)
	_sky_mat.set_shader_parameter("cloud_smoothness", 0.075)
	_sky_mat.set_shader_parameter("cloud_marches", 24)
	_sky_mat.set_shader_parameter("light_marches", 6)
	_sky_mat.set_shader_parameter("density_coeff", 1.18)
	_sky_mat.set_shader_parameter("light_strength", 18.0)
	_sky_mat.set_shader_parameter("cloud_shape_size", 3.2)
	_sky_mat.set_shader_parameter("cloud_noise_size", 11.0)
	_sky_mat.set_shader_parameter("cloud_noise_factor", 0.24)
	_sky_mat.set_shader_parameter("cloud_base_color", Color(0.58, 0.64, 0.76))
	_sky_mat.set_shader_parameter("cloud_overcast_color", Color(0.16, 0.20, 0.30))
	_sky_mat.set_shader_parameter("cloud_shape", _noise_3d(64, 2, 0.023, FastNoiseLite.TYPE_SIMPLEX_SMOOTH))
	_sky_mat.set_shader_parameter("cloud_noise", _noise_3d(64, 19, 0.045, FastNoiseLite.TYPE_CELLULAR))
	_sky_mat.set_shader_parameter("cloud_color_texture", _noise_2d(256, 41, 0.018, 3))
	_sky_mat.set_shader_parameter("use_cirrus", true)
	_sky_mat.set_shader_parameter("cirrus_texture", _noise_2d(512, 73, 0.012, 4))
	_sky_mat.set_shader_parameter("cirrus_distortion_texture", _noise_2d(256, 7, 0.02, 2))
	_sky_mat.set_shader_parameter("cirrus_mask_texture", _noise_2d(256, 101, 0.008, 2))
	_sky_mat.set_shader_parameter("cirrus_scale", 0.22)
	_sky_mat.set_shader_parameter("cirrus_opacity", 0.16)
	_sky_mat.set_shader_parameter("use_rainbow", false)
	_sky_mat.set_shader_parameter("dim_stars_at_day", true)


func _noise_3d(px: int, seed_value: int, frequency: float, noise_type: int) -> NoiseTexture3D:
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.frequency = frequency
	noise.noise_type = noise_type as FastNoiseLite.NoiseType
	noise.fractal_octaves = 3
	var texture := NoiseTexture3D.new()
	texture.width = px
	texture.height = px
	texture.depth = px
	texture.seamless = true
	texture.noise = noise
	return texture


func _noise_2d(px: int, seed_value: int, frequency: float, octaves: int) -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.frequency = frequency
	noise.fractal_octaves = octaves
	var texture := NoiseTexture2D.new()
	texture.width = px
	texture.height = px
	texture.seamless = true
	texture.noise = noise
	return texture


func _build_sun() -> void:
	# Свет нужен в первую очередь небу (диск солнца).
	_sun = DirectionalLight3D.new()
	var forward: Vector3 = -(game.sun_dir as Vector3).normalized()
	_sun.basis = Basis.looking_at(forward, Vector3.UP)
	_sun.light_color = Color(1.0, 0.83, 0.66)
	_sun.light_energy = 1.15
	_sun.shadow_enabled = true
	# PSSM-каскады с явными границами: три ближних каскада дают чёткую
	# контактную тень под пирсом и камнями вместо каши из одного каскада
	# на 180 м. Дальний каскад — только для силуэтов дюн.
	_sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	_sun.directional_shadow_split_1 = 0.04
	_sun.directional_shadow_split_2 = 0.13
	_sun.directional_shadow_split_3 = 0.40
	_sun.directional_shadow_blend_splits = true
	_sun.directional_shadow_max_distance = 140.0
	_sun.directional_shadow_fade_start = 0.85
	# Акне карты теней при низком солнце рисовало на склонах чёрные
	# прямоугольные блоки («полигональная сетка»). Смещение 0.4 м — это
	# 4× дефолт: тень «отклеивалась» от предметов; 2.2 по нормали — тоже
	# много. Теперь мягкое, но привязанное к геометрии смещение.
	_sun.shadow_bias = 0.08
	_sun.shadow_normal_bias = 1.2
	_sun.shadow_blur = 1.1
	_sun.light_volumetric_fog_energy = 0.75
	add_child(_sun)

	# Если Vulkan не поднялся, Godot молча уходит в Compatibility —
	# волюметрики там нет. Честно фиксируем и усиливаем depth-fog.
	compat_fallback = RenderingServer.get_rendering_device() == null
	if compat_fallback:
		print("WORLD: Vulkan недоступен — Compatibility-фолбэк, ",
			"волюметрический туман заменён плотной дымкой")


func _process(_delta: float) -> void:
	if _using_sky_plus and _sky_mat != null:
		# Два масштаба дрейфуют неодинаково — форма облаков эволюционирует,
		# а не ездит цельной маской по небу.
		var drift: Vector3 = (game.wind_dir_3d() as Vector3) \
			* float(game.elapsed) * _cloud_drift * 0.00018
		_sky_mat.set_shader_parameter("cloud_shape_offset", drift)
		_sky_mat.set_shader_parameter("cloud_noise_offset", -drift * 1.7)
		_sky_mat.set_shader_parameter("cirrus_offset", Vector2(drift.x, drift.z) * 0.35)


## Виньетка: лёгкое затемнение углов — собирает кадр, работает в любом
## рендерере (обычный Control поверх 3D, текстура генерируется кодом).
func _build_vignette() -> void:
	var rect := TextureRect.new()
	rect.texture = ProcTextures.vignette(512, 0.34)
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var layer := CanvasLayer.new()
	layer.layer = 10
	layer.add_child(rect)
	add_child(layer)


# ---------------------------------------------------------------------------
# API для DEV-панели (F3)
# ---------------------------------------------------------------------------

func set_sky(param: String, value) -> void:
	if not _using_sky_plus:
		_sky_mat.set_shader_parameter(param, value)
		return
	# Совместимость DEV-панели со словарём uniform-ов Sky++.
	match param:
		"sun_intensity": _sky_mat.set_shader_parameter("sundisc_intensity", float(value) * 0.48)
		"mie_scattering": _sky_mat.set_shader_parameter("mie_strength", clampf(float(value) * 100000.0, 0.0, 3.0))
		"rayleigh_scale_height": _sky_mat.set_shader_parameter("rayleigh_strength", float(value) / 8000.0)
		"rayleigh_multi_scattering": _sky_mat.set_shader_parameter("ozone_strength", 0.75 + float(value) * 10.0)
		"cloud_cover": _sky_mat.set_shader_parameter("coverage", value)
		"cloud_size": _sky_mat.set_shader_parameter("cloud_shape_size", float(value) * 2.5)
		"cloud_drift": _cloud_drift = float(value)
		_: _sky_mat.set_shader_parameter(param, value)


func get_exposure() -> float:
	return _env.tonemap_exposure


func set_exposure(v: float) -> void:
	_env.tonemap_exposure = v


func get_glow_threshold() -> float:
	return _env.glow_hdr_threshold


func set_glow_threshold(v: float) -> void:
	_env.glow_hdr_threshold = v


## Волюметрический туман: крутилки DEV-панели. В Compatibility-фолбэке
## плотность дополнительно уезжает в depth-fog — крутилки не мёртвые.
func set_vol_fog(param: String, value) -> void:
	_env.set(param, value)
	if param == "volumetric_fog_density" and compat_fallback:
		_env.fog_density = clampf(float(value) * 0.12, 0.002, 0.03)


## Живое значение тумана/окружения — для DEV-панели: ползунки должны
## показывать то, что реально стоит в сцене, а не свои дефолты.
func get_vol_fog(param: String) -> float:
	if _env == null:
		return 0.0
	return float(_env.get(param))


## ГЛАВНЫЙ ПОЛЗУНОК «НОЧЬ» (0=день, 1=ночь): красит всё сразу —
## небо, свет, песок, туман, экспозицию, грейдинг.
func apply_night01(v: float) -> void:
	game.night01 = clampf(v, 0.0, 1.0)
	var n: float = game.night01
	# Заливка. Ночью небо почти чёрное, и если ambient задавить (было 0.42),
	# песок освещает ТОЛЬКО фонарик: выключил его — всё чёрное. Дневная
	# заливка, наоборот, слабее солнца, иначе кадр уходит в белое.
	_env.ambient_light_energy = lerpf(0.72, 0.95, n)
	# ВАЖНО (это и был корень «чёрного песка»): в Godot
	# `ambient_light_energy` действует, ТОЛЬКО когда
	# `ambient_light_sky_contribution < 1.0`. При contribution = 1.0
	# (дефолт) вся заливка берётся из СРЕДНЕЙ радиации неба: ночью небо
	# в кадре светлое у горизонта, но его средняя энергия — почти ноль,
	# поэтому земля получала ~0 заливки и была видна только с фонарём.
	# Ночью отдаём 45% заливки явному лунно-синему цвету.
	# Днём sky_contribution = 1.0, то есть поведение не меняется.
	_env.ambient_light_color = Color(0.78, 0.82, 0.92).lerp(Color(0.13, 0.17, 0.30), n)
	_env.ambient_light_sky_contribution = lerpf(1.0, 0.55, n)
	_env.tonemap_exposure = lerpf(0.95, 1.12, n)
	_env.fog_light_color = Game.HORIZON_COL.lerp(Color(0.13, 0.17, 0.30), n)
	# днём дымка лёгкая (0.008 volumetric = белая пелена на полкадра),
	# к ночи туман сгущается — но 0.019 заливало кадр молоком и стирало
	# рельеф дюн: держим объём читаемым, глубину даёт свет, а не мгла.
	_env.fog_density = lerpf(0.0011, 0.0022, n) if not compat_fallback \
		else lerpf(0.0011, 0.008, n)
	_env.volumetric_fog_density = lerpf(0.0016, 0.0045, n)
	_env.volumetric_fog_albedo = Color(0.72, 0.72, 0.72).lerp(Color(0.46, 0.52, 0.66), n)
	# Ночной glow: порог ниже — искры песка и фонарь пирса дают тёплый ореол,
	# не превращая небо в белое пятно.
	_env.glow_hdr_threshold = lerpf(1.15, 1.10, n)
	_env.glow_intensity = lerpf(0.55, 0.42, n)
	if _using_sky_plus:
		_sky_mat.set_shader_parameter("exposure", lerpf(13.5, 9.5, n))
		# Ночью диск солнца не должен светить как прожектор: при пороге glow
		# 1.02 диск в 10 единиц + аддитивный glow давали белый СТОЛБ на
		# пол-экрана у горизонта (виден на кадре ночного моря).
		_sky_mat.set_shader_parameter("sundisc_intensity", lerpf(32.0, 2.2, n))
		_sky_mat.set_shader_parameter("coverage", lerpf(0.34, 0.48, n))
	else:
		_sky_mat.set_shader_parameter("sun_intensity", lerpf(50.0, 8.0, n))
	# «Луна» — тот же направленный источник: ночью он не должен гаснуть в
	# ноль, иначе дюны теряют форму и остаётся плоская заливка.
	_sun.light_energy = lerpf(0.85, 0.70, n)
	_sun.light_color = Color(1.0, 0.83, 0.66).lerp(Color(0.58, 0.70, 1.0), n)
	# Объёмный туман от направленного «солнца»: ночью свет идёт почти
	# вдоль горизонта, и энергия 0.75 рисовала у пирса белый СВЕТОВОЙ
	# СТОЛБ на пол-экрана (глоу добивал). Луна в тумане светит мягко.
	_sun.light_volumetric_fog_energy = lerpf(0.75, 0.10, n)


## Смена солнца: небо + свет (базис и цвет по Кельвину — низкое солнце
## краснеет, высокое белеет).
func apply_sun(dir: Vector3) -> void:
	# Sky++ читает LIGHT0_DIRECTION напрямую; fallback получает uniform.
	if not _using_sky_plus:
		_sky_mat.set_shader_parameter("sun_direction", dir)
	_sun.basis = Basis.looking_at(-dir.normalized(), Vector3.UP)
	# Цвет зависит и от высоты, и от времени суток. Раньше «день/ночь»
	# переключались скачком по night01 > 0.5 и затирали «луну», которую
	# выставил apply_night01(): после любого движения ползунка солнца сцена
	# могла стать тёплой в полночь или синей в полдень.
	var elev01 := smoothf(dir.y, 0.05, 0.55)
	var day_col := Color(1.0, 0.83, 0.66).lerp(Color(1.0, 0.97, 0.92), elev01)
	var night_col := Color(0.62, 0.72, 1.0).lerp(Color(0.86, 0.90, 1.0), elev01)
	_sun.light_color = day_col.lerp(night_col, game.night01)


func smoothf(v: float, a: float, b: float) -> float:
	var t := clampf((v - a) / (b - a), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)
