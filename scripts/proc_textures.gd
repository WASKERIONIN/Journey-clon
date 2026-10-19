class_name ProcTextures
extends RefCounted
## Генерация маленьких текстур и материалов кодом — никаких бинарных ассетов.
## Все материалы частиц включают vertex_color_use_as_albedo, чтобы
## работать с color_ramp (плавное появление/затухание жизни частицы).


## Мягкий белый круг (альфа падает от центра к краю).
static func radial(px: int = 48, falloff: float = 1.6) -> ImageTexture:
	var img := Image.create(px, px, false, Image.FORMAT_RGBA8)
	var c := float(px - 1) * 0.5
	for y in range(px):
		for x in range(px):
			var d := Vector2(float(x) - c, float(y) - c).length() / c
			var a := pow(clampf(1.0 - d, 0.0, 1.0), falloff)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	return ImageTexture.create_from_image(img)


## Чёрная точка — безопасное значение по умолчанию для sampler2D.
static func black_pixel() -> ImageTexture:
	var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	img.set_pixel(0, 0, Color(0.0, 0.0, 0.0, 1.0))
	return ImageTexture.create_from_image(img)


## Виньетка: мягкое затемнение углов кадра (пост-эффект без поста).
## Alpha растёт от 0.62 радиуса до края, максимум strength.
static func vignette(px: int = 512, strength := 0.34) -> ImageTexture:
	var img := Image.create(px, px, false, Image.FORMAT_RGBA8)
	var c := float(px - 1) * 0.5
	for y in range(px):
		for x in range(px):
			var d := Vector2(float(x) - c, float(y) - c).length() / c
			var a := pow(clampf((d - 0.62) / 0.55, 0.0, 1.0), 1.6) * strength
			img.set_pixel(x, y, Color(0.0, 0.0, 0.0, a))
	return ImageTexture.create_from_image(img)


## Мягкая пыль/дымка: обычная альфа, билборд, цвет — оттенок песка.
## Не аддитивная — не раздувается glow и не «выжигает» кадр в белое.
static func soft_material(tint: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.albedo_texture = radial(48, 1.6)
	m.albedo_color = tint
	m.vertex_color_use_as_albedo = true
	m.disable_receive_shadows = true
	return m


## Штрих/лента песка: без билборда, двусторонняя (плоская лента видна
## с обеих сторон). additive=true — «ловит солнце»; false — пыльный след.
static func streak_material(tint: Color, additive := true) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if additive:
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	else:
		m.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.albedo_color = tint
	m.vertex_color_use_as_albedo = true
	m.disable_receive_shadows = true
	return m


## Рампа затухания: частица ярко рождается и гаснет к концу жизни.
static func fade_ramp() -> Gradient:
	var g := Gradient.new()
	g.set_color(0, Color(1.0, 1.0, 1.0, 1.0))
	g.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	return g


## Рампа «вспыхнуть и погаснуть»: мягкое появление и уход.
static func swell_ramp() -> Gradient:
	var g := Gradient.new()
	g.set_color(0, Color(1.0, 1.0, 1.0, 0.0))
	g.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	g.add_point(0.3, Color(1.0, 1.0, 1.0, 1.0))
	return g


## Кривая роста облачка пыли.
static func grow_curve(from_v: float, to_v: float) -> Curve:
	var c := Curve.new()
	c.clear_points()
	c.add_point(Vector2(0.0, from_v))
	c.add_point(Vector2(1.0, to_v))
	return c
