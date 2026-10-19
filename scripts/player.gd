class_name Player
extends Node3D
## Путник от первого лица: ходьба по пляжу и дюнам, бег по Shift,
## прыжок, брод по кромке воды и подъём на пирс.
##
## Тело не рендерится — вид от первого лица, удочка висит на камере.
## Этот узел — физика, следы на песке, брызги на воде и пыль.
##
## Песком правит SandField: фаза шага рождает отпечаток стопы, лёгкую пыль
## и звук. Где начинается вода — шаги больше не оставляют следов, вместо
## них идут круги по воде и брызги. Глубже WADE_LIMIT не пускает: берег
## читается телом, а не невидимой стеной.

const GRAVITY := 26.0
const WALK_MAX := 3.4 # спокойный шаг по песку
const SPRINT_MAX := 6.4 # бег по Shift
const ACCEL := 32.0
const SPRINT_ACCEL := 22.0
const FRICTION := 15.0
const AIR_ACCEL := 5.0
const JUMP_V := 6.4

const WADE_LIMIT := 0.78 # глубже — не пускает (по колено)
const WADE_SPEED := 0.62 # доля скорости в воде

const BOUND_X_MIN := -70.0
const BOUND_X_MAX := 196.0
const BOUND_Z := 244.0

var vel := Vector3.ZERO
var grounded := true
var heading := -PI * 0.5 # курс камеры (пишет CameraRig каждый кадр)
var sprint01 := 0.0 # 0..1 — насколько разогнались (камера, музыка, эффекты)
var wet01 := 0.0 # 0..1 — насколько глубоко стоим в воде
var game: GameState
var coast: Coast
var sand: SandField
var pier: Pier
var audio # SoundScape (подключается после создания)

var _gait_phase := 0.0
var _last_step_idx := 0
var _foot_side := 1.0
var _land_dust: CPUParticles3D
var _step_dust: CPUParticles3D
var _splash: CPUParticles3D


func setup(game_ref, coast_ref: Coast, sand_ref: SandField, pier_ref: Pier = null) -> void:
	game = game_ref
	coast = coast_ref
	sand = sand_ref
	pier = pier_ref
	var sp := coast.spawn_point()
	global_position = Vector3(sp.x, surface_at(sp.x, sp.y), sp.y)
	_build_fx()


## Поверхность под ногами: песок/дно или настил пирса (что выше).
func surface_at(x: float, z: float) -> float:
	var h := coast.ground_height(x, z)
	if pier != null:
		var d := pier.deck_height(x, z)
		if d > h:
			return d
	return h


func _build_fx() -> void:
	_land_dust = _make_dust(40, 0.8, Color(0.97, 0.78, 0.55, 0.40), 0.6, 1.2, 2.6)
	_land_dust.position = Vector3(0.0, 0.15, 0.0)
	add_child(_land_dust)

	_step_dust = _make_dust(9, 0.45, Color(0.96, 0.74, 0.52, 0.30), 0.32, 0.4, 1.0)
	_step_dust.position = Vector3(0.0, 0.06, 0.0)
	add_child(_step_dust)

	# брызги: белёсые капли, живут коротко и падают вниз
	_splash = _make_dust(16, 0.42, Color(0.86, 0.92, 0.95, 0.40), 0.10, 0.7, 1.6)
	_splash.position = Vector3(0.0, 0.02, 0.0)
	_splash.gravity = Vector3(0.0, -9.0, 0.0)
	_splash.damping_min = 0.5
	_splash.damping_max = 1.5
	add_child(_splash)


func _make_dust(amount: int, life: float, tint: Color, quad_size: float,
		v0: float, v1: float) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = amount
	p.lifetime = life
	p.lifetime_randomness = 0.3
	p.one_shot = true
	p.explosiveness = 1.0
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 0.2
	p.spread = 180.0
	p.initial_velocity_min = v0
	p.initial_velocity_max = v1
	p.gravity = Vector3(0.0, -2.0, 0.0)
	p.damping_min = 3.0
	p.damping_max = 5.0
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.2
	p.scale_amount_curve = ProcTextures.grow_curve(0.35, 1.15)
	p.color_ramp = ProcTextures.fade_ramp()
	var quad := QuadMesh.new()
	quad.size = Vector2(quad_size, quad_size)
	quad.material = ProcTextures.soft_material(tint)
	p.mesh = quad
	p.visibility_aabb = AABB(Vector3(-8.0, -5.0, -8.0), Vector3(16.0, 10.0, 16.0))
	p.emitting = false
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return p


func _physics_process(delta: float) -> void:
	var wish := _wish_dir()
	if grounded:
		_step_grounded(delta, wish)
	else:
		_step_air(delta, wish)
	_bounds(delta)
	_update_gait(delta)
	game.sprint01 = game.sprint01 * 0.90 + sprint01 * 0.10
	game.player_altitude = global_position.y


func _wish_dir() -> Vector3:
	var fwd := Input.get_action_strength("move_forward") - Input.get_action_strength("move_back")
	var side := Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
	if absf(fwd) < 0.001 and absf(side) < 0.001:
		return Vector3.ZERO
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return Vector3.ZERO
	var cam_basis := cam.global_transform.basis
	var f := -cam_basis.z
	f.y = 0.0
	var r := cam_basis.x
	r.y = 0.0
	if f.length_squared() < 0.001 and r.length_squared() < 0.001:
		return Vector3.ZERO
	var dir := (f.normalized() * fwd + r.normalized() * side)
	if dir.length() > 1.0:
		dir = dir.normalized()
	return dir


func _step_grounded(delta: float, wish: Vector3) -> void:
	var pos := global_position
	var depth := maxf(0.0, Coast.SEA_LEVEL - coast.ground_height(pos.x, pos.z))
	# «мокрые ноги» не замедляют: вода чувствуется только от щиколотки,
	# иначе кромка читается как вязкий песок
	var in_water := depth > 0.12 and (pier == null or not pier.is_on(pos.x, pos.z))
	wet01 = clampf((depth - 0.12) / 0.66, 0.0, 1.0) if in_water else 0.0

	var sprinting := Input.is_action_pressed("sprint") and not in_water
	var max_speed := SPRINT_MAX if sprinting else WALK_MAX
	if in_water:
		max_speed *= lerpf(1.0, WADE_SPEED, wet01)

	var hv := Vector3(vel.x, 0.0, vel.z)
	if wish.length_squared() > 0.001:
		var acc := SPRINT_ACCEL if sprinting else ACCEL
		hv = hv.move_toward(wish * max_speed, acc * delta)
	else:
		hv = hv.move_toward(Vector3.ZERO, FRICTION * delta)
	vel.x = hv.x
	vel.z = hv.z
	vel.y = 0.0

	# хотим шагнуть — но сначала проверяем брод: глубже лимита не пускаем
	var target := pos + hv * delta
	var target_depth := Coast.SEA_LEVEL - coast.ground_height(target.x, target.z)
	var target_on_pier := pier != null and pier.is_on(target.x, target.z)
	if target_depth > WADE_LIMIT and not target_on_pier:
		# край воды — край: гасим только шаг в море, без «скольжения»
		var ld := coast.land_dir(pos.x, pos.z)
		var vn := hv.dot(ld)
		if vn < 0.0:
			hv -= ld * vn
		vel.x = hv.x
		vel.z = hv.z
		target = pos + hv * delta
		if Coast.SEA_LEVEL - coast.ground_height(target.x, target.z) > WADE_LIMIT:
			vel.x = 0.0
			vel.z = 0.0
			target = pos

	global_position.x = target.x
	global_position.z = target.z
	var surf := surface_at(global_position.x, global_position.z)
	# с пирса/обрыва шагаем в пустоту — это падение, а не «съезд»
	if global_position.y - surf > 0.55:
		grounded = false
		return
	global_position.y = surf

	if Input.is_action_just_pressed("jump"):
		vel.y = JUMP_V
		grounded = false
		if sand != null and wet01 < 0.1:
			sand.stamp_foot(
				Vector2(pos.x, pos.z),
				Vector2(sin(heading), cos(heading)),
				0.34, 0.24, 0.050, 0.018
			)
		return

	sprint01 = clampf((Vector2(vel.x, vel.z).length() - WALK_MAX) / (SPRINT_MAX - WALK_MAX), 0.0, 1.0)


func _step_air(delta: float, wish: Vector3) -> void:
	vel.y -= GRAVITY * delta
	if wish.length_squared() > 0.001:
		vel.x += wish.x * AIR_ACCEL * delta
		vel.z += wish.z * AIR_ACCEL * delta
	global_position += vel * delta
	var surf := surface_at(global_position.x, global_position.z)
	if global_position.y <= surf:
		global_position.y = surf
		grounded = true
		var impact := maxf(0.0, -vel.y)
		var impact01 := clampf(impact / 15.0, 0.0, 1.0)
		vel.y = 0.0
		sprint01 = 0.0
		var wet := Coast.SEA_LEVEL - coast.ground_height(global_position.x, global_position.z)
		if sand != null and impact > 2.0 and wet < 0.10:
			sand.stamp_land(
				Vector2(global_position.x, global_position.z),
				Vector2(sin(heading), cos(heading)),
				0.06 + 0.08 * impact01
			)
		if audio != null:
			if wet > 0.05:
				audio.on_water_step(0.8, impact01)
			elif impact > 2.5:
				audio.on_land(impact01)
		if impact > 6.0:
			_land_dust.restart()


func _bounds(_delta: float) -> void:
	var pos := global_position
	var push := Vector3.ZERO
	if pos.x > BOUND_X_MAX:
		push.x = BOUND_X_MAX - pos.x
	elif pos.x < BOUND_X_MIN:
		push.x = BOUND_X_MIN - pos.x
	if pos.z > BOUND_Z:
		push.z = BOUND_Z - pos.z
	elif pos.z < -BOUND_Z:
		push.z = -BOUND_Z - pos.z
	if push != Vector3.ZERO:
		global_position += push
		vel.x = 0.0 if push.x != 0.0 else vel.x
		vel.z = 0.0 if push.z != 0.0 else vel.z


# ---------------------------------------------------------------------------
## Следы: фаза шага крутится с частотой шагов; на каждом π стопа касается
## песка — отпечаток, пыль, звук. В воде — брызги и круги.
# ---------------------------------------------------------------------------
func _update_gait(delta: float) -> void:
	if not grounded:
		return
	var hv := Vector3(vel.x, 0.0, vel.z)
	var hspd := hv.length()
	if hspd < 0.35:
		return
	var fwd := Vector2(sin(heading), cos(heading))
	if hspd > 0.5:
		fwd = Vector2(hv.x, hv.z) / hspd
	var pos := Vector2(global_position.x, global_position.z)

	var on_pier := pier != null and pier.is_on(pos.x, pos.y)
	var depth := Coast.SEA_LEVEL - coast.ground_height(pos.x, pos.y)
	var cadence: float = clampf(0.78 * hspd, 0.7, 3.1) # шагов/с ≈ 0.8 на метр
	_gait_phase += cadence * PI * delta
	var step_idx := int(_gait_phase / PI)
	if step_idx > _last_step_idx:
		_last_step_idx = step_idx
		_plant_foot(pos, fwd, hspd, depth, on_pier)


func _plant_foot(pos: Vector2, fwd: Vector2, hspd: float, depth: float, on_pier: bool) -> void:
	var spd01 := clampf(hspd / SPRINT_MAX, 0.0, 1.0)
	var perp := Vector2(-fwd.y, fwd.x)
	var p := pos - fwd * 0.28 + perp * (0.10 * _foot_side + randf_range(-0.04, 0.04))
	_foot_side = -_foot_side
	if on_pier:
		# по доскам — глухой деревянный шаг без следов
		if audio != null:
			audio.on_step(spd01, 0.35)
		return
	if depth > 0.04:
		# в воде: круги по воде + брызги, следов нет
		if game != null and game.water != null and game.water.field != null:
			game.water.field.wake(p, 0.6 + 0.6 * spd01)
		if audio != null:
			audio.on_water_step(spd01, 0.0)
		_splash.position = Vector3(pos.x, Coast.SEA_LEVEL + 0.02, pos.y)
		_splash.restart()
		return
	var f := fwd.rotated(randf_range(-0.35, 0.35))
	if sand != null:
		sand.stamp_foot(
			p, f,
			(0.46 + 0.22 * spd01) * randf_range(0.85, 1.20),
			(0.26 + 0.14 * spd01) * randf_range(0.85, 1.30),
			(0.050 + 0.034 * spd01) * randf_range(0.80, 1.35),
			0.016 + 0.014 * spd01
		)
		if randf() < 0.28:
			var kick := p + f * randf_range(0.10, 0.45) + perp * randf_range(-0.30, 0.30) * _foot_side
			sand.stamp_track(kick, kick + f * 0.22, randf_range(0.10, 0.20), randf_range(0.02, 0.04), 0.010)
	if audio != null:
		audio.on_step(clampf(hspd / 3.0, 0.0, 1.0), 1.0)
	if spd01 > 0.25:
		_step_dust.restart()


## Покачивание головы для камеры: тот же такт, что ставит следы.
func gait_bob() -> float:
	var hv := Vector3(vel.x, 0.0, vel.z)
	var spd01 := clampf(hv.length() / 3.0, 0.0, 1.0)
	return sin(_gait_phase) * 0.018 * spd01
