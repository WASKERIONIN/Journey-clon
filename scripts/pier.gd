class_name Pier
extends Node3D
## Старый рыбацкий пирс: доски, сваи, перила и фонарь на конце.
##
## Пирс — не декорация: по настилу реально ходит игрок. У него есть
## deck_height(x, z) — поверхность настила; Player берёт max(песок, настил),
## поэтому можно зайти с пляжа и уйти по доскам над водой.
##
## Геометрия — код: один меш на все доски/сваи/перила (MeshKit), плюс
## фонарь (тёплый огонёк) — днём почти погас, ночью светит и красит
## волюметрический туман.

const HALF_W := 1.35 # полширины настила, м
const PLANK := 0.24 # шаг досок, м
const POST_STEP := 4.2 # шаг свай, м

var game: GameState
var coast: Coast
var pz := -36.0 # z оси пирса
var x_start := 0.0 # береговой конец
var x_end := 0.0 # морской конец
var deck_y0 := 0.0
var deck_y1 := 1.3

var _lamp: OmniLight3D
var _lamp_glow: MeshInstance3D


func setup(coast_ref, game_ref, z: float) -> void:
	coast = coast_ref
	game = game_ref
	pz = z
	var sx := coast.shore_x(z)
	x_start = sx + 6.0
	x_end = sx - 26.0
	deck_y0 = maxf(coast.sample_height(x_start, z) + 0.10, 0.55)
	deck_y1 = maxf(deck_y0 + 0.45, 1.25)
	_build()


## Высота настила в мировой точке, или -INF, если точка не на пирсе.
func deck_height(x: float, z: float) -> float:
	if absf(z - pz) > HALF_W - 0.02:
		return -INF
	if x > x_start + 0.6 or x < x_end:
		return -INF
	var u := clampf((x - x_end) / (x_start - x_end), 0.0, 1.0) # 1 — берег
	return lerpf(deck_y1, deck_y0, u)


func is_on(x: float, z: float) -> bool:
	return deck_height(x, z) > -INF


func _deck_y(x: float) -> float:
	var u := clampf((x - x_end) / (x_start - x_end), 0.0, 1.0)
	return lerpf(deck_y1, deck_y0, u)


func _build() -> void:
	var st := MeshKit.begin()
	var wood := Color(0.235, 0.170, 0.120)
	var wood_dark := Color(0.165, 0.120, 0.090)
	var wood_wet := Color(0.115, 0.090, 0.072)

	# --- доски настила: каждая со своим тоном и микро-наклоном ---
	var rng := RandomNumberGenerator.new()
	rng.seed = 90210
	var n := int((x_start - x_end) / PLANK)
	for i in range(n):
		var x := x_end + (float(i) + 0.5) * PLANK
		var y := _deck_y(x)
		var c := wood.lerp(wood_dark, rng.randf() * 0.55)
		if y < 0.55:
			c = c.lerp(wood_wet, 0.5) # у воды доски мокрые
		var b := Basis(Vector3.UP, rng.randf_range(-0.012, 0.012))
		b = Basis(Vector3.BACK, rng.randf_range(-0.008, 0.008)) * b
		MeshKit.add_box(st, Vector3(x, y, pz), Vector3(PLANK * 0.84, 0.055,
			HALF_W * 2.0 - 0.04), b, c)

	# --- продольные балки под настилом ---
	for side: float in [-1.0, 1.0]:
		var xm := (x_start + x_end) * 0.5
		var span := (x_start - x_end)
		var slope := (deck_y0 - deck_y1) / maxf(span, 0.01)
		var beam := Basis(Vector3.BACK, atan(slope))
		MeshKit.add_box(st,
			Vector3(xm, _deck_y(xm) - 0.115, pz + side * (HALF_W - 0.22)),
			Vector3(span, 0.16, 0.10), beam, wood_dark)

	# --- сваи: от дна до настила ---
	var px := x_end
	while px <= x_start + 0.01:
		var top := _deck_y(px) - 0.09
		for side: float in [-1.0, 1.0]:
			var z := pz + side * (HALF_W - 0.10)
			var bottom := coast.sample_height(px, z) - 0.6
			var h := top - bottom
			if h < 0.4:
				continue
			var col := wood_wet.lerp(wood_dark, clampf((top - 0.5) / 6.0, 0.0, 0.6))
			MeshKit.add_cylinder(st, Vector3(px, bottom + h * 0.5, z),
				0.115, 0.095, h, 8, col, false, false)
			# «косынка» — поперечная распорка
			MeshKit.add_box(st, Vector3(px, top - 0.45, z),
				Vector3(0.09, 0.09, 0.5), Basis.IDENTITY, wood_dark)
		px += POST_STEP

	# --- перила: стойки и две перекладины по обеим сторонам ---
	for side: float in [-1.0, 1.0]:
		var z := pz + side * (HALF_W - 0.06)
		var x := x_end + 0.4
		while x <= x_start - 0.2:
			var y := _deck_y(x)
			MeshKit.add_box(st, Vector3(x, y + 0.5, z),
				Vector3(0.075, 1.0, 0.075), Basis.IDENTITY, wood_dark)
			x += 2.5
		# перекладины — сегменты по 2.5 м вдоль уклона
		for hgt: float in [0.55, 0.97]:
			x = x_end + 0.2
			while x < x_start - 0.2:
				var x2 := minf(x + 2.5, x_start)
				var y1 := _deck_y(x) + hgt
				var y2 := _deck_y(x2) + hgt
				var mid := Vector3((x + x2) * 0.5, (y1 + y2) * 0.5, z)
				var ang := atan2(y2 - y1, x2 - x)
				var b := Basis(Vector3.BACK, ang)
				MeshKit.add_box(st, mid, Vector3(x2 - x, 0.065, 0.06), b, wood)
				x = x2

	# --- фонарный столб на конце ---
	var lx := x_end + 0.55
	var ly := _deck_y(lx)
	var lz := pz + HALF_W - 0.30
	MeshKit.add_box(st, Vector3(lx, ly + 1.05, lz), Vector3(0.10, 2.1, 0.10),
		Basis.IDENTITY, wood_dark)
	MeshKit.add_box(st, Vector3(lx, ly + 2.12, lz), Vector3(0.34, 0.06, 0.34),
		Basis.IDENTITY, wood_dark)
	# стекло фонаря — светится (материал отдельный, ниже)
	var lamp_mat := StandardMaterial3D.new()
	lamp_mat.albedo_color = Color(1.0, 0.72, 0.38)
	lamp_mat.emission_enabled = true
	lamp_mat.emission = Color(1.0, 0.55, 0.22)
	lamp_mat.emission_energy_multiplier = 1.6
	lamp_mat.roughness = 0.4
	_lamp_glow = MeshInstance3D.new()
	var lm := SphereMesh.new()
	lm.radius = 0.11
	lm.height = 0.24
	_lamp_glow.mesh = lm
	_lamp_glow.material_override = lamp_mat
	_lamp_glow.position = Vector3(lx, ly + 1.98, lz)
	add_child(_lamp_glow)

	_lamp = OmniLight3D.new()
	_lamp.position = Vector3(lx, ly + 1.98, lz)
	_lamp.light_color = Color(1.0, 0.62, 0.30)
	_lamp.omni_range = 22.0
	_lamp.light_energy = 1.2
	_lamp.shadow_enabled = false
	_lamp.light_volumetric_fog_energy = 1.0
	add_child(_lamp)

	# --- один меш на всё дерево ---
	var mi := MeshInstance3D.new()
	mi.mesh = MeshKit.finish(st)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color.WHITE
	mat.roughness = 0.88
	mat.metallic_specular = 0.30
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(mi)


func _process(_delta: float) -> void:
	if _lamp == null or game == null:
		return
	var n: float = clampf(game.night01, 0.0, 1.0)
	var flick := 0.92 + 0.08 * sin(game.elapsed * 7.3) * sin(game.elapsed * 2.1)
	# 4.2 энергии + emission 2.6 выжигали вокруг фонаря белое пятно на
	# пол-экрана (и glow добивал): ночью фонарь — тёплая точка, а не сварка.
	_lamp.light_energy = (0.35 + 2.4 * n) * flick
	if _lamp_glow != null:
		(_lamp_glow.material_override as StandardMaterial3D).emission_energy_multiplier \
			= 0.25 + 1.5 * n
