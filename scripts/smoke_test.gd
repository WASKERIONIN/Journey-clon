class_name SmokeTest
extends Node
## Автотест геймплея для headless-прогона (JOURNEY_SMOKE=1).
## Фазы: мир и берег → ходьба → брод у уреза → заброс (поплавок на воде) →
## поклёвка/подсечка/вываживание/поимка → возврат снасти, уборка удочки,
## заброс на песок.
##
## Тест ведёт себя как игрок: нажимает те же action-ы, смотрит теми же
## функциями, что и камера, ждёт реальные сигналы удочки. Никаких
## «тестовых телепортов» в логике рыбалки — только в подготовке фаз.

var main: MainScene
var phase := 0
var frames := 0
var results: Array[String] = []
var _fail := false

var _walk_ok := 0
var _walk_n := 0
var _peak_speed := 0.0
var _max_depth := 0.0
var _wet_seen := 0.0
var _caught := 0.0
var _escaped := false
var _retrieved := false
var _hooked := false
var _fight_seen := false
var _state_logged := false
var _extra_state := 0


func setup(main_ref: MainScene) -> void:
	main = main_ref
	# головной прогон без графики: главный цикл не должен обгонять физику
	Engine.max_fps = 60
	var rod: RodCast = main.rod
	rod.fish_landed.connect(func(sz: float) -> void: _caught = sz)
	rod.fish_escaped.connect(func() -> void: _escaped = true)
	rod.line_retrieved.connect(func() -> void: _retrieved = true)
	rod.fish_hooked.connect(func() -> void: _hooked = true)


func _physics_process(_delta: float) -> void:
	frames += 1
	match phase:
		0:
			_phase_world()
		1:
			_phase_walk()
		2:
			_phase_wade()
		3:
			_phase_cast()
		4:
			_phase_fish()
		5:
			_phase_extra()
		6:
			_finish()


# ---------------------------------------------------------------------------
# Фаза 0: мир собран, берег правильный, пирс ходится
# ---------------------------------------------------------------------------
func _phase_world() -> void:
	var coast: Coast = main.coast
	var water: WaterSurface = main.water
	var pier: Pier = main.pier
	var p: Player = main.player
	var rod: RodCast = main.rod

	if frames == 1:
		_check(coast != null, "мир: берег собран")
		_check(water != null, "мир: море собрано")
		_check(main.fish != null, "мир: существа собраны")
		_check(pier != null, "мир: пирс собран")
		_check(rod != null and rod.get_parent() is Camera3D, "удочка висит на камере")
		_check(main.audio != null, "звук поднят")
		_check(rod.stowed, "удочка изначально убрана (в руке)")
		var sp := coast.spawn_point()
		var h := coast.sample_height(sp.x, sp.y)
		_check(h > 0.5 and h < 4.0, "старт на сухом пляже (%.2f м над морем)" % h)
		_check(coast.height_at(sp.x - 60.0, sp.y) < -1.0,
			"в 60 м от старта уже глубина (%.2f м)" % coast.height_at(sp.x - 60.0, sp.y))
		var d1 := coast.height_at(coast.shore_x(sp.y) + 60.0, sp.y)
		_check(d1 > 2.0, "вглубь суши — дюны (%.1f м)" % d1)
		print("[SMOKE] урез при z=%.0f: x=%.1f, спавн=(%.1f, %.1f)" % [
			sp.y, coast.shore_x(sp.y), sp.x, sp.y])
		_check(p.grounded and absf(p.global_position.y - coast.ground_height(p.global_position.x, p.global_position.z)) < 0.2,
			"игрок стоит на песке")
		# пирс: настил над водой и на нём «пол» выше дна
		var px := pier.x_end + 1.5
		var deck := pier.deck_height(px, pier.pz)
		_check(deck > 0.8, "настил пирса над водой (%.2f м)" % deck)
		_check(coast.sample_height(px, pier.pz) < -0.5,
			"под пирсом вода (дно %.2f м)" % coast.sample_height(px, pier.pz))
		p.global_position = Vector3(px, deck, pier.pz)
		p.vel = Vector3.ZERO
		p.grounded = true
	if frames == 15:
		var sp2 := coast.spawn_point()
		_check(absf(p.global_position.y - pier.deck_height(p.global_position.x, p.global_position.z)) < 0.05,
			"игрок стоит на настиле (%.2f м)" % p.global_position.y)
		p.global_position = Vector3(sp2.x, coast.ground_height(sp2.x, sp2.y), sp2.y)
		p.vel = Vector3.ZERO
		p.grounded = true
	if frames > 35:
		_next()


# ---------------------------------------------------------------------------
# Фаза 1: обычная ходьба вдоль берега
# ---------------------------------------------------------------------------
func _phase_walk() -> void:
	var p: Player = main.player
	if frames == 1:
		main.cam_rig.set_view(0.0, -0.05) # вдоль берега (+Z)
		Input.action_press("move_forward")
	if frames >= 30 and frames <= 170 and frames % 10 == 0:
		var spd := Vector3(p.vel.x, 0.0, p.vel.z).length()
		_walk_n += 1
		_peak_speed = maxf(_peak_speed, spd)
		if spd > 1.2 and spd < 4.2:
			_walk_ok += 1
		print("[SMOKE] ходьба: кадр %d spd=%.2f (%.1f, %.1f)" % [
			frames, spd, p.global_position.x, p.global_position.z])
	if frames == 185:
		Input.action_release("move_forward")
	if frames > 235:
		_check(_walk_ok >= _walk_n - 2,
			"ходьба: скорость в норме %d из %d (пик %.1f м/с)" % [_walk_ok, _walk_n, _peak_speed])
		_check(p.vel.length() < 0.7, "ходьба: без ввода остановился (%.2f м/с)" % p.vel.length())
		_check(p.grounded, "ходьба: на земле")
		_check(main.sand.stamp_count > 5, "песок: отпечатки остаются (%d штампов)" % main.sand.stamp_count)
		_next()


# ---------------------------------------------------------------------------
# Фаза 2: брод — глубже лимита не пускает, вода чувствуется
# ---------------------------------------------------------------------------
func _phase_wade() -> void:
	var p: Player = main.player
	var coast: Coast = main.coast
	if frames == 1:
		var sx := coast.shore_x(Coast.SPAWN_Z)
		p.global_position = Vector3(sx - 4.0,
			coast.ground_height(sx - 4.0, Coast.SPAWN_Z), Coast.SPAWN_Z)
		p.vel = Vector3.ZERO
		p.grounded = true
		main.cam_rig.set_view(-PI * 0.5, -0.10) # в море
		Input.action_press("move_forward")
	if frames > 10:
		var depth := Coast.SEA_LEVEL - coast.ground_height(p.global_position.x, p.global_position.z)
		_max_depth = maxf(_max_depth, depth)
		_wet_seen = maxf(_wet_seen, p.wet01)
		if frames % 40 == 0:
			print("[SMOKE] брод: кадр %d x=%.1f глубина=%.2f wet01=%.2f" % [
				frames, p.global_position.x, depth, p.wet01])
	if frames == 220:
		Input.action_release("move_forward")
	if frames > 250:
		_check(_max_depth > 0.25, "брод: вода под ногами (глубина до %.2f м)" % _max_depth)
		_check(_max_depth < Player.WADE_LIMIT + 0.22,
			"брод: глубже лимита не пускает (макс %.2f при лимите %.2f)" % [_max_depth, Player.WADE_LIMIT])
		_check(_wet_seen > 0.2, "брод: игрок чувствует воду (wet01 до %.2f)" % _wet_seen)
		_next()


# ---------------------------------------------------------------------------
# Фаза 3: достать удочку и забросить — поплавок ложится на воду
# ---------------------------------------------------------------------------
func _phase_cast() -> void:
	var p: Player = main.player
	var rod: RodCast = main.rod
	if frames == 1:
		Input.action_release("move_forward")
		# ближе к урезу: заброс должен уходить в воду, а не в пляж
		var px := main.coast.shore_x(Coast.SPAWN_Z) + 6.0
		p.global_position = Vector3(px, main.coast.ground_height(px, Coast.SPAWN_Z), Coast.SPAWN_Z)
		p.vel = Vector3.ZERO
		p.grounded = true
		main.cam_rig.set_view(-PI * 0.5, -0.14) # в море, чуть вниз
	if frames == 5:
		Input.action_press("rod_cast")
	if frames == 7:
		Input.action_release("rod_cast") # первый клик достаёт удочку
	if frames == 20:
		Input.action_press("rod_cast") # заряд
	if frames == 62:
		Input.action_release("rod_cast") # заброс
		Engine.time_scale = 2.0
	if frames > 64 and rod.state == RodCast.S.FLOAT:
		_check(not rod.stowed, "удочка: достали из-за спины")
		_check(not rod.on_land, "заброс: поплавок упал на воду")
		var bp := rod.bobber_position()
		_check(absf(bp.y - Coast.SEA_LEVEL) < 0.4,
			"поплавок на уровне моря (y=%.2f)" % bp.y)
		var d := Vector2(bp.x - p.global_position.x, bp.z - p.global_position.z).length()
		_check(d > 5.0 and d < 55.0, "заброс: дальность %.1f м" % d)
		print("[SMOKE] заброс: поплавок в (%.1f, %.2f, %.1f), сила %.2f" % [bp.x, bp.y, bp.z, d])
		_next()
	if frames > 420 and not _fail:
		_check(false, "заброс: поплавок так и не лёг на воду (state %d)" % rod.state)
		_next()


# ---------------------------------------------------------------------------
# Фаза 4: рыба → поклёвка → подсечка → вываживание → поимка
# ---------------------------------------------------------------------------
func _phase_fish() -> void:
	var rod: RodCast = main.rod
	if frames == 1:
		Engine.time_scale = 3.0
		# проверяем механику, а не баланс: берём хорошую леску, как у игрока
		# с прокачкой, иначе редкая сильная рыба может не влезть в лимит кадров
		rod.stats["line"] = 2.0
		rod.debug_fast_lure()
	if rod.state == RodCast.S.BITE and not _hooked:
		# окно подсечки: жмём ЛКМ, как игрок
		Input.action_press("rod_cast")
		print("[SMOKE] поклёвка! подсекаем (кадр %d)" % frames)
	elif rod.state == RodCast.S.FIGHT:
		if not _fight_seen:
			_fight_seen = true
			Input.action_release("rod_cast")
			Engine.time_scale = 1.0 # вываживание ведём в реальном времени
		# мотать, пока натяг не подошёл к красной черте; в рывок — отпускать
		var t01 := rod.fight_tension() / 100.0
		if rod.is_pulling() or t01 > 0.62:
			Input.action_release("rod_cast")
		else:
			Input.action_press("rod_cast")
	elif frames > 20:
		Input.action_release("rod_cast")
	if _hooked and frames % 180 == 0 and rod.state == RodCast.S.FIGHT:
		print("[SMOKE] вываживание: кадр %d, рывок=%s, натяг=%.0f, прогресс=%.0f" % [
			frames, str(rod.is_pulling()), rod.fight_tension(), rod.fight_progress()])
	if _escaped:
		_check(false, "рыба сошла (натяг) — этого быть не должно")
		Engine.time_scale = 1.0
		_next()
	if _caught > 0.0:
		Input.action_release("rod_cast")
		Engine.time_scale = 1.0
		_check(_hooked, "рыба: подсечка удалась")
		_check(_caught > 0.2, "рыба: поймана (размер %.2f)" % _caught)
		_check(rod.state == RodCast.S.RESTING, "рыба: удочка снова наготове")
		_check(main.fish.nearest_distance(main.player.global_position) >= 0.0,
			"рыба: в море остались существа")
		_next()
	if frames > 4200 and not _fail:
		_check(false, "рыба: не поймана за 4200 кадров (state %d, hooked=%s)" % [
			rod.state, str(_hooked)])
		Engine.time_scale = 1.0
		_next()
	elif frames > 900 and not _state_logged:
		_state_logged = true
		print("[SMOKE] рыба: долго, state=%d, on_land=%s, lure=%s" % [
			rod.state, str(rod.on_land), rod.zone])


# ---------------------------------------------------------------------------
# Фаза 5: вернуть снасть, убрать удочку, заброс на песок
# ---------------------------------------------------------------------------
func _phase_extra() -> void:
	var rod: RodCast = main.rod
	match _extra_state:
		0: # заброс, чтобы вернуть снасть
			if frames == 10:
				Input.action_press("rod_cast")
			elif frames == 45:
				Input.action_release("rod_cast")
			elif frames > 47 and rod.state == RodCast.S.FLOAT:
				Input.action_press("rod_recall")
				_extra_state = 1
				frames = 0
			elif frames > 500:
				_check(false, "снасть: заброс для возврата не удался (state %d)" % rod.state)
				_extra_state = 9
				frames = 0
		1: # ждём возврата лески
			if _retrieved or rod.state == RodCast.S.RESTING:
				Input.action_release("rod_recall")
				_check(_retrieved, "снасть: возвращается в руки (line_retrieved)")
				Input.action_press("rod_toggle")
				_extra_state = 2
				frames = 0
			elif frames > 1100:
				_check(false, "снасть: не вернулась за 1100 кадров (state %d)" % rod.state)
				_extra_state = 9
				frames = 0
		2: # Q — убрать удочку
			if frames == 2:
				Input.action_release("rod_toggle")
			if frames == 8:
				_check(rod.stowed, "удочка: убирается (Q)")
				Input.action_press("rod_cast")
			if frames == 10:
				Input.action_release("rod_cast")
			if frames == 18:
				_check(not rod.stowed, "удочка: снова достаётся кликом")
				main.cam_rig.set_view(PI * 0.5, -0.55) # в песок под ногами
				Input.action_press("rod_cast")
				_extra_state = 3
				frames = 0
		3: # заброс в песок
			if frames == 32:
				Input.action_release("rod_cast")
			elif frames > 34 and rod.state == RodCast.S.FLOAT:
				_check(rod.on_land, "заброс в песок: поплавок честно падает на песок")
				Input.action_press("rod_recall")
				_extra_state = 4
				frames = 0
			elif frames > 500:
				_check(false, "заброс в песок: поплавок не долетел (state %d)" % rod.state)
				_extra_state = 9
				frames = 0
		4: # возврат с песка
			if rod.state == RodCast.S.RESTING:
				Input.action_release("rod_recall")
				_check(not rod.on_land, "заброс в песок: снасть вернулась")
				_extra_state = 9
				frames = 0
			elif frames > 500:
				_check(false, "заброс в песок: снасть не вернулась (state %d)" % rod.state)
				_extra_state = 9
				frames = 0
		9:
			if frames > 5:
				_next()


# ---------------------------------------------------------------------------
func _next() -> void:
	phase += 1
	frames = 0
	_extra_state = 0


func _check(ok: bool, what: String) -> void:
	results.append(("PASS " if ok else "FAIL ") + what)
	if not ok:
		_fail = true


func _finish() -> void:
	for line in results:
		print("[SMOKE] ", line)
	print("[SMOKE] итог: ", "ЕСТЬ ПРОВАЛЫ" if _fail else "ВСЁ ПРОШЛО")
	get_tree().quit(1 if _fail else 0)
