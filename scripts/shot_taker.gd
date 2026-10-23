class_name ShotTaker
extends Node
## CI-кадры (JOURNEY_SHOT=1): берег, A/B света, удочка, заброс, поклёвка,
## пойманная рыба, пирс и прыжок песчаного кита. Сценарий ведёт себя как игрок и снимает
## кадр в момент события (а не по номеру кадра — рендер в CI медленный).
##
## Скриншоты кладутся в $SHOT_DIR и коммитятся CI: это единственный способ
## увидеть визуал без локального Godot. SDF-слой существ включается только
## на кадр с прыжком — программный рендер lavapipe не тянет его постоянно.
##
## Важно: `process_priority = -100`, чтобы нажатия action-ов пришли раньше,
## чем их прочитает удочка (иначе is_action_just_pressed теряется).

var main: MainScene
var _dir := ""
var _state := 0
var _t := 0.0 # время сценария (сек игрового времени, не стенного)
var _fs := 0
var _caught := 0.0
var _catch_capture_wait := -1


func setup(main_ref: MainScene) -> void:
	main = main_ref
	_dir = OS.get_environment("SHOT_DIR")
	if _dir.is_empty():
		_dir = "."
	# сценарий жмёт action-ы из _process — наш _process должен идти первым
	process_priority = -100
	main.rod.fish_landed.connect(func(sz: float) -> void: _caught = sz)
	main.fish.set_sdf_enabled(false) # экономим программный рендер
	main.fish_kit.set_sdf_enabled(false)
	main.rod.stats["line"] = 2.0 # хорошая леска: кадр не должен зависеть от баланса
	# конкретный вид: кадр должен быть быстрым и предсказуемым (не 40-секундный бой)
	main.rod.bite.forced_id = "perch"
	# ставим путника ближе к урезу: отсюда заброс гарантированно уходит
	# в воду, а в кадр попадают море, пирс и дюны за спиной
	var px := main.coast.shore_x(Coast.SPAWN_Z) + 9.0
	main.player.global_position = Vector3(px, main.coast.ground_height(px, Coast.SPAWN_Z), Coast.SPAWN_Z)
	main.player.vel = Vector3.ZERO
	main.player.grounded = true
	main.cam_rig.set_view(-PI * 0.5 + 0.42, -0.04)
	print("[SHOT] кадры в ", _dir)
	_go(0)


func _go(s: int) -> void:
	_state = s
	_t = 0.0
	_fs = 0


func _process(delta: float) -> void:
	_t += delta
	_fs += 1
	var rod: RodCast = main.rod
	var t := _t
	match _state:
		0: # стартовый вид: эталонный свет воды
			if t > 0.8 and _fs > 2:
				_capture("shot_a_coast.png")
				# Замораживаем игровое время, чтобы A/B сравнивал свет,
				# а не изменившуюся фазу ряби между двумя кадрами.
				Engine.time_scale = 0.0
				main.set_proxima_test(1.0)
				_go(10)
		10: # A/B-кадр той же камеры с моделью Proxima + Schlick-GGX
			if _fs > 4:
				_capture("shot_j_proxima.png")
				main.set_proxima_test(0.0)
				main.set_time(1.0)
				_go(11)
		11: # звёзды на песке в настоящих тенях причала и камней
			if _fs == 1:
				var pier: Pier = main.pier
				# Frame a dry, shadowed patch beside the landward end of the pier.
				var target_z := pier.pz + 2.8
				var target_x := pier.x_start + 2.2
				var target := Vector3(target_x,
					main.coast.ground_height(target_x, target_z), target_z)
				var camera_x := target_x + 5.0
				var camera_z := target_z + 3.0
				var camera_y := main.coast.ground_height(camera_x, camera_z)
				main.player.global_position = Vector3(camera_x, camera_y, camera_z)
				main.player.vel = Vector3.ZERO
				main.player.grounded = true
				main.hud.visible = false
				main.cam_rig.set_physics_process(false)
				main.cam_rig.cam.global_position = main.player.global_position \
					+ Vector3(0.0, CameraRig.EYE, 0.0)
				main.cam_rig.cam.look_at(target, Vector3.UP)
				print("[SHOT] night sand camera=%s target=%s forward=%s" % [
					main.cam_rig.cam.global_position, target, -main.cam_rig.cam.global_basis.z])
			if _fs > 4:
				_capture("shot_k_night_stars.png")
				main.hud.visible = true
				main.cam_rig.set_physics_process(true)
				main.set_time(0.0)
				main.cam_rig.set_view(atan2(main.game.sun_dir.x, main.game.sun_dir.z), -0.38)
				Engine.time_scale = 4.0
				_go(12)
		12: # выдержка взгляда на солнечной дорожке до мягкого blur
			if t > 12.0:
				_capture("shot_l_solar_gaze_blur.png")
				Engine.time_scale = 1.0
				main.cam_rig.set_view(-PI * 0.5 + 0.42, -0.04)
				Input.action_press("rod_cast")
				_go(1)
		1: # удочка достаётся
			if t > 0.25:
				Input.action_release("rod_cast")
			if t > 0.7 and _fs > 4:
				_capture("shot_b_rod.png")
				main.cam_rig.set_view(-PI * 0.5 + 0.06, -0.10) # прямо в море
				Input.action_press("rod_cast") # заряд
				_go(2)
		2:
			if t > 1.0 and _fs > 10:
				_capture("shot_c_charge.png")
				Input.action_release("rod_cast") # заброс
				_go(3)
		3: # ждём, пока поплавок ляжет на воду
			if rod.state == RodCast.S.FLOAT and _fs > 2:
				if rod.on_land:
					_finish("поплавок лёг на песок вместо воды — прицел в скрипте")
					return
				_capture("shot_d_bobber.png")
				Engine.time_scale = 2.0
				rod.debug_fast_lure()
				_go(4)
			elif t > 12.0:
				_finish("заброс не удался, state=%d" % rod.state)
		4: # ждём поклёвки
			if rod.state == RodCast.S.BITE and _fs > 1:
				_capture("shot_e_bite.png")
				Engine.time_scale = 1.0
				Input.action_press("rod_cast") # подсечка
				_go(5)
			elif t > 10.0 and _fs % 120 == 0:
				print("[SHOT] ждём поклёвку: state=%d, зона=%s, on_land=%s, натяг=%.0f, прогресс=%.0f" % [
					rod.state, rod.zone, str(rod.on_land), rod.fight_tension(), rod.fight_progress()])
			if t > 22.0:
				_finish("поклёвки не было, state=%d" % rod.state)
		5: # подсекли — вываживаем
			if t > 0.15:
				Input.action_release("rod_cast")
			if rod.state == RodCast.S.FIGHT and t > 0.6 and _fs > 3:
				_capture("shot_f_fight.png")
				_go(6)
			elif t > 4.0:
				_finish("подсечка не удалась, state=%d" % rod.state)
		6: # вываживание: мотаем в затишье; 2× — чтобы уложиться в кадры рендера
			Engine.time_scale = 2.0
			if rod.is_pulling() or rod.fight_tension() > 62.0:
				Input.action_release("rod_cast")
			else:
				Input.action_press("rod_cast")
			# Отдельный контрольный кадр проверяет и центрирование улова, и
			# гладкость того же SDF-тела после поимки.
			if _caught > 0.0 and _catch_capture_wait < 0:
				main.fish.set_sdf_enabled(true)
				main.fish_kit.set_sdf_enabled(true)
				_catch_capture_wait = 3
			if _catch_capture_wait >= 0:
				_catch_capture_wait -= 1
				if _catch_capture_wait == 0:
					_capture("shot_i_caught_fish.png")
					main.fish.set_sdf_enabled(false)
					main.fish_kit.set_sdf_enabled(false)
					Input.action_release("rod_cast")
					_go(7)
			elif rod.state == RodCast.S.RESTING or t > 16.0:
				Input.action_release("rod_cast")
				_go(7)
		7: # пирс: геройский вид с моря на берег
			if _fs == 1:
				Engine.time_scale = 1.0
				if rod.state == RodCast.S.FIGHT:
					rod.debug_cancel_fight()
				rod.clear_held() # путник телепортировался — рыбы в руках уже нет
				var pier: Pier = main.pier
				var deck := pier.deck_height(pier.x_end + 2.0, pier.pz)
				main.player.global_position = Vector3(pier.x_end + 2.0, deck, pier.pz)
				main.player.vel = Vector3.ZERO
				main.player.grounded = true
				main.cam_rig.set_view(PI * 0.5, -0.10)
			if t > 0.8 and _fs > 4:
				_capture("shot_g_pier.png")
				_go(8)
		8: # прыжок песчаного кита у пирса (SDF включаем на пару кадров)
			var target := _breach_target()
			main.fish.set_sdf_enabled(true)
			main.fish_kit.set_sdf_enabled(true)
			main.fish.debug_breach_near(target)
			if _fs == 2:
				var d: Vector3 = target - main.cam_rig.cam.global_position
				main.cam_rig.set_view(atan2(d.x, d.z), -0.16)
			if t > 0.45 and _fs > 4:
				_capture("shot_h_breach.png")
				_go(9)
		9:
			if t > 0.1 and _fs > 3:
				_go(13)
		13: # крупный контрольный кадр человека и живого idle-рига у причала
			if _fs == 1:
				main.fish.set_sdf_enabled(true) # рыбак живёт в SDF-слое рыб
				var npc: FishingNpc = main.fishing_npc
				var px := npc.global_position.x + 2.4
				var pz := npc.global_position.z + 1.0
				var beach_y := main.coast.ground_height(px, pz)
				main.player.global_position = Vector3(px, beach_y, pz)
				main.player.vel = Vector3.ZERO
				main.player.grounded = true
				main.hud.visible = false
				main.catch_card.visible = false
				var camera_pos := main.player.global_position + Vector3(0.0, CameraRig.EYE, 0.0)
				var look := npc.global_position + Vector3(0.0, 0.92, 0.0) - camera_pos
				main.cam_rig.set_view(atan2(look.x, look.z),
					clampf(atan2(look.y, Vector2(look.x, look.z).length()), -0.9, 0.2))
				for visual in main.rod.find_children("*", "VisualInstance3D", true, false):
					(visual as VisualInstance3D).visible = false
			if t > 0.45 and _fs > 4:
				_capture("shot_m_fisherman.png")
				Input.action_press("npc_interact")
				_go(14)
		14: # UI: контракт рыбака должен работать так же, как и модель
			if _fs == 1:
				Input.action_release("npc_interact")
				Input.action_press("npc_quest_1")
			elif _fs == 2:
				Input.action_release("npc_quest_1")
			if t > 0.4 and _fs > 4:
				_capture("shot_n_quest.png")
				_go(15)
		15: # Ночь у берега + фонарик: разбор «всё чернеет» — контроль БЕЗ фонаря
			if _fs == 1:
				main.set_time(1.0)
				# низкое солнце над морем — тёмное небо, как в отчёте игрока
				main.apply_sun(Vector3(-0.55, 0.06, -0.30).normalized())
				var sx := main.coast.shore_x(Coast.SPAWN_Z) + 6.0
				main.player.global_position = Vector3(sx,
					main.coast.ground_height(sx, Coast.SPAWN_Z), Coast.SPAWN_Z)
				main.player.vel = Vector3.ZERO
				main.player.grounded = true
				main.hud.visible = false
				main.catch_card.visible = false
				main.cam_rig.set_view(PI * 0.5, -0.02) # взгляд на сушу (+X)
				main.cam_rig.flashlight.visible = false
				main.cam_rig.flash_on = false
			if t > 0.5 and _fs > 6:
				_capture("shot_o_flash_off.png")
				main.cam_rig.flashlight.visible = true
				main.cam_rig.flash_on = true
				_go(16)
		16: # фонарик включён «как есть» — главная улика игрока
			if _fs > 6:
				_capture("shot_p_flash_full.png")
				main.cam_rig.flashlight.shadow_enabled = false
				_go(17)
		17: # фонарик без теней — если чернота уйдёт, виновата карта теней
			if _fs > 6:
				_capture("shot_q_flash_noshadow.png")
				main.cam_rig.flashlight.shadow_enabled = true
				main.cam_rig.flashlight.light_volumetric_fog_energy = 0.0
				_go(18)
		18: # фонарик без объёмного луча — если чернота уйдёт, виноват объёмный туман
			if _fs > 6:
				_capture("shot_r_flash_nofog.png")
				main.cam_rig.flashlight.light_volumetric_fog_energy = 2.2
				main.cam_rig.flashlight.light_energy = 0.0
				_go(19)
		19: # источник видим, но энергии 0 — только путь шейдера light() на кадр
			if _fs > 6:
				_capture("shot_s_flash_zero.png")
				_finish("")


func _breach_target() -> Vector3:
	var pier: Pier = main.pier
	return Vector3(pier.x_end + 9.0, Coast.SEA_LEVEL, pier.pz - 9.0)


func _finish(reason: String) -> void:
	if reason != "":
		print("[SHOT] стоп: ", reason)
	print("[SHOT] готово")
	get_tree().quit(0)


func _capture(fname: String) -> void:
	var img := get_viewport().get_texture().get_image()
	if img == null:
		push_warning("SHOT: viewport image недоступен")
		return
	var path := _dir.path_join(fname)
	var err := img.save_png(path)
	print("[SHOT] ", path, " -> ", err)
