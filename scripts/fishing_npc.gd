class_name FishingNpc
extends Node3D
## Причальный рыбак — песчаное существо из ТОГО ЖЕ SDF-шейдера, что и рыбы.
## Скрытая CC0-болванка с анимациями Idle/Talking/Interact двигает скелет,
## а шейдер рисует «плавленое» тело по костям: жилет, кепка, сапоги — и лицо
## с объёмными глазами, которые следят за игроком и моргают.
## Даёт короткие рыбацкие контракты и считает улов без отдельного квест-хаба.

const MODEL_PATH := "res://assets/npc/AnimationLibrary_Godot_Standard.glb"

# слот сустава → кость рига (слоты описаны в sand_sea_sdf.gdshader)
const JOINT_BONES: Array = [
	[0, "DEF-hips"], [1, "DEF-spine.002"], [2, "DEF-spine.003"],
	[3, "DEF-neck"], [4, "DEF-head"],
	[6, "DEF-upper_arm.L"], [7, "DEF-forearm.L"], [8, "DEF-hand.L"],
	[9, "DEF-upper_arm.R"], [10, "DEF-forearm.R"], [11, "DEF-hand.R"],
	[12, "DEF-thigh.L"], [13, "DEF-shin.L"], [14, "DEF-foot.L"], [15, "DEF-toe.L"],
	[16, "DEF-thigh.R"], [17, "DEF-shin.R"], [18, "DEF-foot.R"], [19, "DEF-toe.R"],
]
# радиусы капсул по слотам 0..19, м
const JOINT_RADIUS := [
	0.150, 0.170, 0.165, 0.085, 0.135, 0.050,
	0.095, 0.062, 0.052, 0.095, 0.062, 0.052,
	0.105, 0.078, 0.052, 0.040, 0.105, 0.078, 0.052, 0.040,
]
const CHAR_SCALE := 0.92
const HEAD_R := 0.118
const EYE_SEP := 0.052
const EYE_R := 0.034

const QUESTS := [
	{"title": "Утренний улов", "text": "Поймай любую рыбу × 3", "count": 3},
	{"title": "Трофей у причала", "text": "Поймай крупную рыбу (65 см+) × 1", "count": 1},
	{"title": "Ночной гость", "text": "Ночью поймай любую рыбу × 2", "count": 2},
]

var main: MainScene
var _anim: AnimationPlayer
var _skeleton: Skeleton3D
var _talking := false
var _quest_idx := -1
var _quest_progress := 0
var _interact_action := "npc_interact"
var _quest_actions: Array[String] = ["npc_quest_1", "npc_quest_2", "npc_quest_3"]
var _hint: Label
var _dialogue: PanelContainer
var _dialogue_text: Label
var _progress_text: Label
var _near_player := false

# ---- SDF-существо (тот же материал, что у песчаных рыб) ----
var _sdf_mat: ShaderMaterial
var _joint_bones := PackedInt32Array() # индекс кости по слоту (-1 — нет)
var _joint_world := PackedVector3Array()
var _head_pos := Vector3.ZERO
var _face_fwd := Vector3(0.0, 0.0, -1.0)
var _blink := 0.0
var _blink_t := -1.0 # >= 0 — идёт моргание
var _blink_next := 1.8
var _talk_open := 0.0
var _t := 0.0


func setup(main_ref: MainScene, pier: Pier) -> void:
	main = main_ref
	name = "FishingQuestGiver"
	# Shore end of the dock, within a few steps of the starting beach.
	var npc_x := pier.x_start - 1.35
	var npc_z := pier.pz + 0.62
	global_position = Vector3(npc_x, pier.deck_height(npc_x, npc_z) + 0.06, npc_z)
	rotation.y = PI * 0.5 # face the beach-side approach
	if main.fish != null:
		# рыбак живёт в лучшем слое песчаных существ — одном материале
		_sdf_mat = main.fish.mat
	_build_character()
	_build_ui()
	_ensure_actions()


func _build_character() -> void:
	var packed := load(MODEL_PATH) as PackedScene
	if packed == null:
		push_error("Fishing NPC: cannot load CC0 humanoid animation pack")
		return
	var character := packed.instantiate()
	character.name = "CC0Humanoid"
	add_child(character)
	character.scale = Vector3(CHAR_SCALE, CHAR_SCALE, CHAR_SCALE)
	# Меш-болванка скрыта: рыбака рисует SDF-шейдер по костям этого рига.
	for node in character.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		mesh_instance.visible = false
		mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_skeleton = _find_skeleton(character)

	_anim = _find_animation_player(character)
	if _anim != null:
		_anim.animation_finished.connect(_on_animation_finished)
		# Imported GLTF clip paths are relative to the instanced scene root.
		# Explicitly bind there rather than trusting a possibly nested default root.
		_anim.root_node = _anim.get_path_to(character)
		var idle := _find_animation("Idle_Loop")
		if idle.is_empty():
			idle = _find_animation("Idle_Talking_Loop")
		if idle.is_empty():
			idle = _find_animation("Idle_Talking")
		if idle.is_empty():
			for clip in _anim.get_animation_list():
				var clip_name := str(clip).to_lower()
				if "idle" in clip_name and not ("crouch" in clip_name
					or "sitting" in clip_name or "pistol" in clip_name
					or "torch" in clip_name):
					idle = str(clip)
					break
		if not idle.is_empty():
			_anim.active = true
			_anim.play(idle)
			_anim.advance(0.15)
			print("[NPC] CC0 animation playing: %s; root=%s" % [idle, _anim.root_node])
		else:
			push_warning("Fishing NPC: no idle clip in imported animation player: %s" % str(_anim.get_animation_list()))
	else:
		push_warning("Fishing NPC: imported animation player was not found")

	if _skeleton != null:
		_bind_joints()
	else:
		push_warning("Fishing NPC: imported humanoid skeleton was not found")


## Привязка слотов суставов к костям рига + первый замер позы.
func _bind_joints() -> void:
	_joint_bones.resize(20)
	_joint_bones.fill(-1)
	_joint_world.resize(20)
	for entry in JOINT_BONES:
		_joint_bones[int(entry[0])] = _skeleton.find_bone(str(entry[1]))
	_update_joints(0.016)
	_push_sdf()


## Мировые позы суставов из скрытого рига + взгляд лица на игрока.
func _update_joints(delta: float) -> void:
	var skel_tf := _skeleton.global_transform
	var head_basis := Basis.IDENTITY
	for slot in range(20):
		var bi := _joint_bones[slot]
		if bi < 0:
			continue
		var pose := skel_tf * _skeleton.get_bone_global_pose(bi)
		_joint_world[slot] = pose.origin
		if slot == 4:
			head_basis = pose.basis
	# макушка — продолжение оси головы: кепка сидит на голове, а не на шее
	var head_up := head_basis.y.normalized()
	_joint_world[5] = _joint_world[4] + head_up * 0.20
	_head_pos = _joint_world[4] + head_up * 0.105

	# взгляд: игрок рядом и впереди — лицо поворачивается к нему
	var head_fwd := -head_basis.z.normalized()
	var want := head_fwd
	if main != null and main.player != null:
		var target: Vector3 = main.player.global_position + Vector3(0.0, 1.55, 0.0)
		var to_p := target - _head_pos
		var dist := to_p.length()
		if dist < 8.0 and dist > 0.25 and to_p.dot(head_fwd) > -0.25 * dist:
			want = to_p / dist
	# лёгкие «отвлечённые» взгляды, когда игрок не в фокусе
	var glance := head_basis * Vector3(sin(_t * 0.29) * 0.16, sin(_t * 0.21 + 1.7) * 0.11, 0.0)
	want = (want + glance).normalized()
	_face_fwd = _face_fwd.slerp(want, 1.0 - exp(-5.0 * delta))
	if _face_fwd.length_squared() < 0.25:
		_face_fwd = want
	else:
		_face_fwd = _face_fwd.normalized()

	# моргание: короткое закрывание, иногда двойное
	if _blink_t >= 0.0:
		_blink_t -= delta
		if _blink_t < 0.0:
			_blink = 0.0
		else:
			_blink = clampf(1.0 - absf(_blink_t - 0.07) / 0.07, 0.0, 1.0)
	else:
		_blink_next -= delta
		if _blink_next <= 0.0:
			_blink_t = 0.14
			_blink_next = 0.24 if randf() < 0.22 else randf_range(2.2, 5.4)

	# рот: болтает, когда разговор открыт или играет жест
	var want_talk := 0.06
	if _talking or (_dialogue != null and _dialogue.visible):
		want_talk = 0.35 + 0.55 * absf(sin(_t * 8.5)) * (0.55 + 0.45 * sin(_t * 3.1))
	_talk_open = lerpf(_talk_open, clampf(want_talk, 0.0, 1.0), 1.0 - exp(-8.0 * delta))


## Пуш позы рыбака в общий SDF-материал песчаных существ.
func _push_sdf() -> void:
	if _sdf_mat == null:
		return
	var arr := PackedVector4Array()
	arr.resize(20)
	for slot in range(20):
		arr[slot] = Vector4(_joint_world[slot], JOINT_RADIUS[slot] * CHAR_SCALE)
	_sdf_mat.set_shader_parameter("u_npc_joints", arr)
	_sdf_mat.set_shader_parameter("u_npc_head", Vector4(_head_pos, HEAD_R))
	_sdf_mat.set_shader_parameter("u_npc_face", Vector4(_face_fwd, _talk_open))
	_sdf_mat.set_shader_parameter("u_npc_eyes", Vector4(_blink, EYE_SEP, EYE_R, 0.0))
	# ночь чуть синит ткани — та же палитра, что у песка и моря
	var night := 0.0
	if main != null and main.game != null:
		night = main.game.night01
	_sdf_mat.set_shader_parameter("u_npc_skin",
		Color(0.82, 0.47, 0.28).lerp(Color(0.50, 0.38, 0.46), night * 0.5))
	_sdf_mat.set_shader_parameter("u_npc_cloth",
		Color(0.13, 0.33, 0.35).lerp(Color(0.10, 0.17, 0.32), night * 0.55))
	_sdf_mat.set_shader_parameter("u_npc_pants",
		Color(0.36, 0.26, 0.20).lerp(Color(0.23, 0.21, 0.30), night * 0.5))
	_sdf_mat.set_shader_parameter("u_npc_hat",
		Color(0.42, 0.29, 0.18).lerp(Color(0.27, 0.23, 0.30), night * 0.5))
	_sdf_mat.set_shader_parameter("u_npc_boot",
		Color(0.27, 0.19, 0.14).lerp(Color(0.18, 0.16, 0.23), night * 0.5))


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found != null:
			return found
	return null


func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node as AnimationPlayer
	for child in node.get_children():
		var found := _find_animation_player(child)
		if found != null:
			return found
	return null


func _find_animation(fragment: String) -> String:
	if _anim == null:
		return ""
	for anim_name in _anim.get_animation_list():
		if str(anim_name).ends_with(fragment):
			return str(anim_name)
	return ""


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 16
	add_child(layer)
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)

	_hint = Label.new()
	_hint.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_hint.position = Vector2(-150.0, -108.0)
	_hint.size = Vector2(300.0, 36.0)
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.add_theme_font_size_override("font_size", 20)
	_hint.add_theme_color_override("font_color", Color(1.0, 0.84, 0.59))
	_hint.add_theme_color_override("font_shadow_color", Color(0.08, 0.06, 0.05, 0.9))
	_hint.add_theme_constant_override("shadow_offset_x", 2)
	_hint.add_theme_constant_override("shadow_offset_y", 2)
	_hint.visible = false
	root.add_child(_hint)

	_dialogue = PanelContainer.new()
	_dialogue.set_anchors_preset(Control.PRESET_CENTER)
	_dialogue.position = Vector2(-260.0, -165.0)
	_dialogue.size = Vector2(520.0, 330.0)
	_dialogue.visible = false
	_dialogue.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.055, 0.075, 0.09, 0.94)
	panel_style.border_color = Color(0.78, 0.53, 0.31, 0.95)
	panel_style.set_border_width_all(2)
	panel_style.set_corner_radius_all(10)
	panel_style.set_content_margin_all(22)
	_dialogue.add_theme_stylebox_override("panel", panel_style)
	root.add_child(_dialogue)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	_dialogue.add_child(column)
	var heading := Label.new()
	heading.text = "СТАРЫЙ РЫБАК"
	heading.add_theme_font_size_override("font_size", 23)
	heading.add_theme_color_override("font_color", Color(0.98, 0.72, 0.43))
	column.add_child(heading)
	_dialogue_text = Label.new()
	_dialogue_text.text = "Море сегодня щедрое. Выбери работу — снасть уже у тебя."
	_dialogue_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_dialogue_text.add_theme_font_size_override("font_size", 17)
	_dialogue_text.add_theme_color_override("font_color", Color(0.90, 0.91, 0.85))
	column.add_child(_dialogue_text)
	for i in QUESTS.size():
		var choice := Label.new()
		choice.text = "%d   %s — %s" % [i + 1, QUESTS[i].title, QUESTS[i].text]
		choice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		choice.add_theme_font_size_override("font_size", 16)
		choice.add_theme_color_override("font_color", Color(0.82, 0.86, 0.79))
		column.add_child(choice)
	_progress_text = Label.new()
	_progress_text.add_theme_font_size_override("font_size", 16)
	_progress_text.add_theme_color_override("font_color", Color(0.98, 0.80, 0.48))
	column.add_child(_progress_text)
	var close_label := Label.new()
	close_label.text = "E — закрыть"
	close_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	close_label.add_theme_font_size_override("font_size", 14)
	close_label.add_theme_color_override("font_color", Color(0.67, 0.73, 0.72))
	column.add_child(close_label)


func _ensure_actions() -> void:
	_add_key_action(_interact_action, KEY_E)
	for i in _quest_actions.size():
		_add_key_action(_quest_actions[i], KEY_1 + i)


func _add_key_action(action: String, key: Key) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action)
	var event := InputEventKey.new()
	event.physical_keycode = key
	InputMap.action_add_event(action, event)


func _process(delta: float) -> void:
	_t += delta
	if _skeleton != null and _sdf_mat != null:
		_update_joints(delta)
		_push_sdf()
	if main == null or main.player == null:
		return
	var distance := global_position.distance_to(main.player.global_position)
	_near_player = distance < 5.2
	_hint.visible = _near_player and not _dialogue.visible
	if _hint.visible:
		if _quest_idx >= 0:
			var quest: Dictionary = QUESTS[_quest_idx]
			_hint.text = "E  Рыбак · %s (%d/%d)" % [
				quest.title, _quest_progress, int(quest.count)]
		else:
			_hint.text = "E  Поговорить с рыбаком"
	if not _near_player:
		_dialogue.visible = false
		return
	if Input.is_action_just_pressed(_interact_action):
		_dialogue.visible = not _dialogue.visible
		if _dialogue.visible:
			_update_quest_text()
	for i in _quest_actions.size():
		if _dialogue.visible and Input.is_action_just_pressed(_quest_actions[i]):
			_accept_quest(i)


func _accept_quest(index: int) -> void:
	if index < 0 or index >= QUESTS.size():
		return
	_quest_idx = index
	_quest_progress = 0
	_update_quest_text()
	_play_talk()


func _update_quest_text() -> void:
	if _quest_idx < 0:
		_dialogue_text.text = "Море сегодня щедрое. Выбери работу — снасть уже у тебя."
		_progress_text.text = ""
		return
	var quest: Dictionary = QUESTS[_quest_idx]
	if _quest_idx == 1:
		_dialogue_text.text = "Ищи покрупнее. Такой трофей долго помнят у костра."
	elif _quest_idx == 2:
		_dialogue_text.text = "После заката рыба подходит ближе. Возвращайся с двумя."
	else:
		_dialogue_text.text = "Никакой хитрости — просто принеси три рыбы."
	_progress_text.text = "Задание: %s  %d / %d" % [quest.title, _quest_progress, int(quest.count)]


func on_fish_caught(info: Dictionary) -> void:
	if _quest_idx < 0:
		return
	var counts := false
	match _quest_idx:
		0:
			counts = true
		1:
			counts = float(info.get("size_cm", 0.0)) >= 65.0
		2:
			counts = main.game.night01 >= 0.55
	if not counts:
		return
	_quest_progress += 1
	var target := int(QUESTS[_quest_idx].count)
	if _quest_progress >= target:
		_dialogue_text.text = "Вот это улов! Работа выполнена — возвращайся, как захочешь ещё."
		_quest_idx = -1
		_quest_progress = 0
	else:
		_update_quest_text()


func _play_talk() -> void:
	if _anim == null:
		return
	var talk := _find_animation("Interact")
	if talk.is_empty():
		talk = _find_animation("Idle_Talking_Loop")
	if not talk.is_empty():
		_talking = true
		_anim.play(talk)


func _on_animation_finished(_animation_name: StringName) -> void:
	if not _talking or _anim == null:
		return
	_talking = false
	var idle := _find_animation("Idle_Talking_Loop")
	if idle.is_empty():
		idle = _find_animation("Idle_Loop")
	if not idle.is_empty():
		_anim.play(idle)
