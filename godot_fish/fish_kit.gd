class_name FishKit
extends Node3D
## КИТ ПЕСЧАНЫХ РЫБ — 7 видов на одном SDF-реймаршинге «песчаного моря».
##
## Каждый вид — это свой скелет-цепочка (кости, FK), свои плавники, окраска
## по реальному прототипу и свой нрав. Тело рисует шейдер
## sand_sea_sdf.gdshader + fish_kit_map.gdshaderinc; этот скрипт живёт
## жизнью рыб на CPU: курс/скорость/фаза волны, видовые циклы (прыжки,
## рывки, «водоросль» угря, копание усача, надувание пухляка) — и пушит
## uniform-ы каждый кадр (до 3 рыб × 12 костей — копейки).
##
## Виды (прототипы по ихтиологическим источникам, см. README):
##   0 Дюнный странник  — фирменный «песчаный кит», карангiformный ход
##   1 Угорь-лента      — ленточный угорь: змейка, замирает «водорослью»
##   2 Фонарник         — удильщик: засада под песком, эска-фонарь, рывки
##   3 Песчаная манта   — мобулиформные взмахи крыльев с волной к кончику
##   4 Стрела           — тунец: тунниформный ход, рывки с прыжком
##   5 Пухляк           — иглобрюх: гребля плавниками, надувание с иглами
##   6 Усач-грунтовик   — барабулька/осётр: копает дно усами-хемосенсорами
##
## Использование (после water.setup):
##   var kit := FishKit.new()
##   add_child(kit)
##   kit.setup(game, water.level_y, water.field)
##   kit.add_fish(2)          # + фонарник (слоты 0..2)
##   kit.set_species(0, 4)    # сменить вид слота 0 (плавный морф)
##   kit.set_showcase(0, true) # показ: рыба над песком — видна целиком (V в демо)
##   kit.startle()            # испуг (у вида своя реакция)
##   kit.force_jump()         # форс-прыжок (у бесхвостых — «фырке»)
## Отладка рига: kit.set_xray(true) — скелет просвечивает сквозь тело.

const MAX_FISH := 3
const FK_BONE := 12
const SHADER_PATH := "res://shaders/sand_sea_sdf.gdshader"
const GRAVITY := 9.8
const WANDER_R := 8.5 # радиус блуждания одной рыбы вокруг своей точки

## Паспорта видов — числа 1:1 с fish_kit.html (зеркало шейдер-инклуда).
const SPECIES: Array[Dictionary] = [
	{ # 0 — утверждённый облик «песчаного кита»
		"name": "Дюнный странник", "latin": "Therion arenae",
		"proto": "фирменное существо «песчаного моря»",
		"desc": "Большой песчаный кит. Волна бежит по задней трети тела — плывёт «хвостом», экономно и с размахом, как дельфин.",
		"loco": "карангиформная — работает хвостовая треть",
		"paint": "золотой верх, светлее к хвосту (контртень)",
		"beh": "кружит над дном, дышит «одеялом», периодически выпрыгивает",
		"s": 1.0, "n": 8, "seg": 0.335,
		"radii": [0.42, 0.45, 0.41, 0.35, 0.28, 0.21, 0.15, 0.10],
		"wave": { "a0": 0.05, "a1": 0.42, "lag": 0.80, "v0": 0.0, "v1": 0.055, "lagv": 0.75 },
		"freq": { "base": 5.0, "k": 2.2 },
		"cruise": 1.5, "depth": 0.8,
		"jump": { "period": [8.0, 14.0], "h": [0.9, 1.4] },
		"flap": { "amp": 0.30, "freq": 2.0 },
		"top": Color(1.0, 0.78, 0.38), "belly": Color(1.0, 0.92, 0.76),
		"acc": Color(0.98, 0.66, 0.30), "glowc": Color(1.0, 0.8, 0.5),
		"melt": 1.0,
	},
	{ # 1 — ленточный угорь: сапфир с искрами, жёлтая кайма, змейка
		"name": "Угорь-лента", "latin": "Fascina caerulea",
		"proto": "ленточный угорь (Rhinomuraena quaesita)",
		"desc": "Электрическая змейка песков: сапфировое тело в белых искрах и ярко-жёлтая кайма-плавник от затылка до кончика хвоста. Плывёт волной по всему телу, а замирая — колышется, как водоросль.",
		"loco": "ангуиллиформная — волна по всему телу, растёт к хвосту",
		"paint": "сапфир с белыми искрами, чёрное горло, жёлтая кайма плавника",
		"beh": "скользит змейкой; замирает «водорослью», покачиваясь на месте",
		"s": 1.15, "n": 12, "seg": 0.21,
		"radii": [0.15, 0.16, 0.155, 0.145, 0.13, 0.115, 0.10, 0.085, 0.07, 0.055, 0.045, 0.035],
		"wave": { "a0": 0.10, "a1": 0.55, "lag": 0.60, "v0": 0.01, "v1": 0.06, "lagv": 0.55 },
		"freq": { "base": 2.8, "k": 2.6 },
		"cruise": 0.8, "depth": 0.65,
		"hover": { "every": [10.0, 16.0], "pitch": 0.35, "hold": 3.0 },
		"flap": { "amp": 0.35, "freq": 2.2 },
		"top": Color(0.07, 0.16, 0.58), "belly": Color(0.30, 0.44, 0.82),
		"acc": Color(1.0, 0.78, 0.12), "glowc": Color(0.35, 0.55, 1.0),
		"melt": 0.9,
	},
	{ # 2 — удильщик: засада, эска-фонарь, зубы
		"name": "Фонарник", "latin": "Lucerna profunda",
		"proto": "глубоководный удильщик (Melanocetus)",
		"desc": "Засадный охотник: прячется под песком, а над головой несёт посох с живым фонариком — светятся симбиотические бактерии.",
		"loco": "засада: висит на плавниках, рывок — и снова в песок",
		"paint": "чёрно-фиолетовая бронза, зубастая пасть, ряды фотофоров",
		"beh": "крадётся в «вуали»; при рывке эска вспыхивает",
		"s": 0.8, "n": 7, "seg": 0.30,
		"radii": [0.52, 0.55, 0.50, 0.42, 0.32, 0.22, 0.14],
		"wave": { "a0": 0.015, "a1": 0.10, "lag": 0.90, "v0": 0.005, "v1": 0.05, "lagv": 0.85 },
		"freq": { "base": 2.0, "k": 1.2 },
		"cruise": 0.45, "depth": 1.6,
		"lunge": { "every": [7.0, 11.0], "speed": 3.2, "dur": 0.8 },
		"flap": { "amp": 0.45, "freq": 3.0 },
		"top": Color(0.14, 0.10, 0.20), "belly": Color(0.26, 0.18, 0.26),
		"acc": Color(0.45, 0.30, 0.20), "glowc": Color(0.55, 0.90, 1.0),
		"melt": 1.0,
	},
	{ # 3 — манта: машет крыльями, волна к кончику
		"name": "Песчаная манта", "latin": "Ala sabulosa",
		"proto": "гигантская манта (Mobula birostris)",
		"desc": "Крылатый гигант песков: машет грудными крыльями, как птица в небе, и по лопасти к кончику бежит волна. Мирный фильтратор.",
		"loco": "мобулиформная — взмахи крыльев с волной к кончику",
		"paint": "тёмный шоколад сверху, белый низ, белые плечевые пятна (Mobula)",
		"beh": "широкие виражи с креном; крыло иногда чиркает по песку",
		"s": 1.25, "n": 6, "seg": 0.36,
		"radii": [0.34, 0.38, 0.34, 0.27, 0.18, 0.10],
		"wave": { "a0": 0.02, "a1": 0.10, "lag": 0.85, "v0": 0.005, "v1": 0.04, "lagv": 0.80 },
		"freq": { "base": 1.6, "k": 0.6 },
		"wingfreq": 1.2,
		"cruise": 1.3, "depth": 0.55,
		"jump": { "period": [11.0, 17.0], "h": [0.5, 0.9] },
		"flap": { "amp": 0.50, "freq": 1.2 },
		"top": Color(0.36, 0.23, 0.16), "belly": Color(0.95, 0.92, 0.85),
		"acc": Color(0.24, 0.15, 0.11), "glowc": Color(1.0, 0.85, 0.7),
		"melt": 1.0,
	},
	{ # 4 — тунец: торпеда, серп хвоста, рывки
		"name": "Стрела", "latin": "Sagitta luna",
		"proto": "тунец (Thunnus thynnus)",
		"desc": "Торпеда в металлической синеве: корпус неподвижен, работает только серп хвоста. Рывки-броски с прыжком на выходе.",
		"loco": "тунниформная — ось жёсткая, бьёт серп хвоста",
		"paint": "индиго-верх, серебряный низ, янтарные финлеты",
		"beh": "патрулирует; рывки-броски с прыжком на выходе",
		"s": 0.9, "n": 8, "seg": 0.30,
		"radii": [0.30, 0.34, 0.35, 0.33, 0.28, 0.20, 0.115, 0.075],
		"wave": { "a0": 0.012, "a1": 0.14, "lag": 0.95, "v0": 0.005, "v1": 0.04, "lagv": 0.90 },
		"freq": { "base": 2.2, "k": 1.0 },
		"dash": { "every": [6.0, 9.0], "speed": 6.0, "dur": 1.1 },
		"cruise": 1.7, "depth": 0.7,
		"jump": { "period": [14.0, 20.0], "h": [1.1, 1.5] },
		"flap": { "amp": 0.12, "freq": 2.0 },
		"top": Color(0.10, 0.24, 0.62), "belly": Color(0.92, 0.94, 0.98),
		"acc": Color(1.0, 0.78, 0.10), "glowc": Color(1.0, 0.9, 0.6),
		"melt": 0.9,
	},
	{ # 5 — иглобрюх: гребля плавниками, надувание с иглами
		"name": "Пухляк", "latin": "Globus spinosus",
		"proto": "иглобрюх-диодон (Diodon holocanthus)",
		"desc": "Шар на маленьких вёслах: гребёт грудными плавниками, как жук лапками. При испуге раздувается вдвое, и иглы встают дыбом.",
		"loco": "MPF — гребля плавниками, тело почти жёсткое",
		"paint": "оливково-песочный в тёмных кляксах, маска у глаз, иглы слоновой кости",
		"beh": "ковыляет вразвалку; испуг = надувание с иглами",
		"s": 0.55, "n": 5, "seg": 0.26,
		"radii": [0.48, 0.52, 0.48, 0.38, 0.24],
		"wave": { "a0": 0.01, "a1": 0.07, "lag": 0.90, "v0": 0.005, "v1": 0.03, "lagv": 0.90 },
		"freq": { "base": 1.8, "k": 1.0 },
		"cruise": 0.55, "depth": 0.5,
		"puff": { "scare": 2.5, "idle_every": [10.0, 16.0] },
		"flap": { "amp": 0.55, "freq": 5.2 },
		"top": Color(0.66, 0.60, 0.28), "belly": Color(0.96, 0.90, 0.70),
		"acc": Color(0.55, 0.42, 0.20), "glowc": Color(1.0, 0.9, 0.7),
		"melt": 0.85,
	},
	{ # 6 — барабулька+осётр: усики, щитки, копает дно
		"name": "Усач-грунтовик", "latin": "Barbatus fossor",
		"proto": "барабулька + осётр (Parupeneus, Acipenser)",
		"desc": "Донный сыщик с усиками-хемосенсорами: ныряет под песок и прощупывает дно, поднимая кольца мути. По спине — костяные щитки.",
		"loco": "субкарангиформная — волна доходит до середины тела",
		"paint": "кораллово-красная барабулька: красный верх, розово-кремовый низ, светлые щитки",
		"beh": "ныряет «носом в песок», копает, потом продувается",
		"s": 1.0, "n": 9, "seg": 0.27,
		"radii": [0.24, 0.29, 0.31, 0.30, 0.27, 0.23, 0.18, 0.13, 0.08],
		"wave": { "a0": 0.05, "a1": 0.30, "lag": 0.85, "v0": 0.01, "v1": 0.06, "lagv": 0.80 },
		"freq": { "base": 3.2, "k": 2.0 },
		"probe": { "every": [9.0, 14.0], "depth": 1.7, "dur": 2.6 },
		"cruise": 1.0, "depth": 0.75,
		"flap": { "amp": 0.30, "freq": 2.6 },
		"top": Color(0.95, 0.36, 0.18), "belly": Color(1.0, 0.85, 0.72),
		"acc": Color(0.96, 0.84, 0.55), "glowc": Color(1.0, 0.9, 0.7),
		"melt": 1.0,
	},
]

@export var bounds_radius := 45.0 ## радиус блуждания вокруг опорной точки, м
@export var debug_xray := false ## скелет просвечивает сквозь тело (отладка рига)

var water_level := 0.0
var water_field: WaterField = null # кольца от всплесков/мути (опционально)
var game = null # автозагрузка Game — общее солнце и туман с водой/песком
var coast = null # берег (class_name Coast) — зона рыб по глубине, а не по X
var night_amount := 0.0
var material: ShaderMaterial
var t := 0.0 # время поля — единое с шейдерным u_time
var _quad: MeshInstance3D

# ---- рыбы (параллельные массивы, как у SandFish) ----
var _sp := PackedInt32Array() # вид
var _active := [] # слот занят (bool)
var _pending := PackedInt32Array() # вид на смену (-1 — нет)
var _morph := PackedFloat32Array()
var _morph_tgt := PackedFloat32Array()
var _pos: Array[Vector3] = [] # голова (Array — чтобы менять компоненты на месте)
var _home := PackedVector2Array() # мировая «домашняя» точка блуждания
var _heading := PackedFloat32Array()
var _turn := PackedFloat32Array()
var _speed := PackedFloat32Array()
var _phase := PackedFloat32Array()
var _wing_ph := PackedFloat32Array()
var _bank := PackedFloat32Array()
var _pitch := PackedFloat32Array()
var _pposed := [] # поза для показа (bool) — из превью; в игре не используется
var _pp_y := PackedFloat32Array()
var _pp_pitch := PackedFloat32Array()
var _jump_period := PackedFloat32Array()
var _jump_offset := PackedFloat32Array()
var _jump_h := PackedFloat32Array()
var _scare := PackedFloat32Array()
var _dash_t := PackedFloat32Array()
var _dash_next := PackedFloat32Array()
var _lunge_t := PackedFloat32Array()
var _lunge_next := PackedFloat32Array()
var _hover := PackedFloat32Array()
var _hover_next := PackedFloat32Array()
var _hover_k := PackedFloat32Array()
var _probe := PackedFloat32Array()
var _probe_next := PackedFloat32Array()
var _probe_k := PackedFloat32Array()
var _probe_ring := PackedFloat32Array()
var _inflate := PackedFloat32Array()
var _inflate_tgt := PackedFloat32Array()
var _puff_t := PackedFloat32Array()
var _puff_idle_next := PackedFloat32Array()
var _wake_t := PackedFloat32Array()
var _act := PackedFloat32Array()
var _act_tgt := PackedFloat32Array()
var _hop_t := PackedFloat32Array() # подскок в показе (время/высота)
var _hop_h := PackedFloat32Array()
var _lure_mid := PackedVector3Array() # желе-эска: колено посоха
var _lure_mid_v := PackedVector3Array()
var _lure_core_v := PackedVector3Array() # скорость луковицы (_bulb — позиция)
var _lure_hist: Array = [] # по слоту: Array[Vector3] — история ядра эски
var _lobe_a := PackedVector3Array() # желейный комок (смещение от ядра)
var _lure_pulse := PackedFloat32Array()
var _lure_fresh: Array = [] # bool — эска ждёт rest-инициализации

# ---- результаты FK (пуш в шейдер) ----
var _bones_flat := PackedVector4Array() # MAX_FISH × FK_BONE (xyz + радиус)
var _center := PackedVector3Array()
var _bulb := PackedVector3Array()
var _f0 := PackedVector3Array()
var _sd0 := PackedVector3Array()
var _up0 := PackedVector3Array()


func _ready() -> void:
	_build_material()
	_build_quad()
	_init_slots()


func _build_material() -> void:
	material = ShaderMaterial.new()
	material.shader = load(SHADER_PATH)
	if game != null:
		material.set_shader_parameter("sun_dir", game.sun_dir)
		material.set_shader_parameter("fog_distance", game.FOG_DISTANCE)


func _build_quad() -> void:
	_quad = MeshInstance3D.new()
	_quad.name = "FishKitQuad"
	var qm := QuadMesh.new()
	qm.size = Vector2(2.0, 2.0)
	_quad.mesh = qm
	_quad.extra_cull_margin = 16384.0
	_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_quad.sorting_offset = 4095.0 # сразу после SandFish-квада, перед частицами
	_quad.material_override = material
	add_child(_quad)


func _init_slots() -> void:
	_sp.resize(MAX_FISH)
	_pending.resize(MAX_FISH)
	_pending.fill(-1)
	_morph.resize(MAX_FISH)
	_morph_tgt.resize(MAX_FISH)
	_pos.resize(MAX_FISH)
	_home.resize(MAX_FISH)
	_heading.resize(MAX_FISH)
	_turn.resize(MAX_FISH)
	_speed.resize(MAX_FISH)
	_phase.resize(MAX_FISH)
	_wing_ph.resize(MAX_FISH)
	_bank.resize(MAX_FISH)
	_pitch.resize(MAX_FISH)
	_pp_y.resize(MAX_FISH)
	_pp_pitch.resize(MAX_FISH)
	_jump_period.resize(MAX_FISH)
	_jump_offset.resize(MAX_FISH)
	_jump_h.resize(MAX_FISH)
	_scare.resize(MAX_FISH)
	_dash_t.resize(MAX_FISH)
	_dash_next.resize(MAX_FISH)
	_lunge_t.resize(MAX_FISH)
	_lunge_next.resize(MAX_FISH)
	_hover.resize(MAX_FISH)
	_hover_next.resize(MAX_FISH)
	_hover_k.resize(MAX_FISH)
	_probe.resize(MAX_FISH)
	_probe_next.resize(MAX_FISH)
	_probe_k.resize(MAX_FISH)
	_probe_ring.resize(MAX_FISH)
	_inflate.resize(MAX_FISH)
	_inflate_tgt.resize(MAX_FISH)
	_puff_t.resize(MAX_FISH)
	_puff_idle_next.resize(MAX_FISH)
	_wake_t.resize(MAX_FISH)
	_act.resize(MAX_FISH)
	_act_tgt.resize(MAX_FISH)
	_hop_t.resize(MAX_FISH)
	_hop_h.resize(MAX_FISH)
	_lure_mid.resize(MAX_FISH)
	_lure_mid_v.resize(MAX_FISH)
	_lure_core_v.resize(MAX_FISH)
	_lobe_a.resize(MAX_FISH)
	_lure_pulse.resize(MAX_FISH)
	_center.resize(MAX_FISH)
	_bulb.resize(MAX_FISH)
	_f0.resize(MAX_FISH)
	_sd0.resize(MAX_FISH)
	_up0.resize(MAX_FISH)
	for i in range(MAX_FISH):
		_active.append(false)
		_pposed.append(false)
		_pos.append(Vector3.ZERO)
		_lure_hist.append([])
		_lure_fresh.append(true)
	_bones_flat.resize(MAX_FISH * FK_BONE)
	_drops_pos.resize(MAX_DROPS)
	_drops_vel.resize(MAX_DROPS)
	_drops_age.resize(MAX_DROPS)
	_drops_life.resize(MAX_DROPS)
	_drops_r0.resize(MAX_DROPS)
	_drops_r0.fill(0.0) # все капли мертвы


## Заселить слот рыбой вида species_id (0..6). Возвращает индекс слота или -1.
func add_fish(species_id: int, at := Vector2.ZERO) -> int:
	for i in range(MAX_FISH):
		if _active[i]:
			continue
		_active[i] = true
		_spawn(i, species_id, at)
		return i
	return -1


func _spawn(i: int, species_id: int, at: Vector2) -> void:
	_sp[i] = clampi(species_id, 0, SPECIES.size() - 1)
	_pending[i] = -1
	_morph[i] = 1.0
	_morph_tgt[i] = 1.0
	_pposed[i] = false
	_pos[i] = Vector3(at.x, 0.0, at.y)
	if at == Vector2.ZERO:
		# расселить от опорной точки, чтобы рыбы не сливались
		var ang := randf() * TAU
		var rad := 4.0 + 5.0 * float(i)
		_pos[i] = Vector3(cos(ang) * rad, 0.0, sin(ang) * rad)
	# домашняя точка блуждания — не мировой ноль: рыбы патрулируют свою отмель
	_home[i] = Vector2(_pos[i].x, _pos[i].z)
	_heading[i] = randf() * TAU
	_reset_species(i, _sp[i])


## Мягкая смена вида слота (тело «переплавляется» через морф).
func set_species(i: int, species_id: int) -> void:
	if i < 0 or i >= MAX_FISH or not _active[i]:
		return
	_pending[i] = clampi(species_id, 0, SPECIES.size() - 1)


## ПОКАЗ: рыба поднята над песком и кружит у камеры — видна целиком
## (все виды, даже не прыгающие). set_showcase(i, false) — обычное поведение.
func set_showcase(i: int, on: bool) -> void:
	if i < 0 or i >= MAX_FISH or not _active[i]:
		return
	_pposed[i] = on
	if on:
		_pp_y[i] = 0.9 * SPECIES[_sp[i]].s
		_pp_pitch[i] = 0.04
		_scare[i] = 0.0
		_hop_t[i] = 0.0


## Активен ли показ у слота.
func is_showcase(i: int) -> bool:
	return i >= 0 and i < MAX_FISH and _active[i] and _pposed[i]


## Испуг: у каждого вида своя реакция (пухляк надувается, стрела даёт дёру).
func startle(i := -1) -> void:
	for k in range(MAX_FISH):
		if i != -1 and k != i:
			continue
		if not _active[k] or _scare[k] > 0.0:
			continue
		_scare[k] = 1.4
		var above := _pos[k].y > -0.5
		if above:
			_burst(Vector3(_pos[k].x, maxf(_pos[k].y, 0.0), _pos[k].z), 0.8)


## Форс-прыжок (видам с прыжком); в показе — подскок у ВСЕХ видов.
func force_jump(i := -1) -> void:
	for k in range(MAX_FISH):
		if i != -1 and k != i:
			continue
		if not _active[k]:
			continue
		var sp: Dictionary = SPECIES[_sp[k]]
		if _pposed[k]: # показ: подскок над песком
			_hop_t[k] = 0.8
			_hop_h[k] = (0.5 + randf() * 0.35) * sp.s + 0.3
			_burst(Vector3(_pos[k].x, maxf(_pos[k].y, 0.0), _pos[k].z), 0.7)
			continue
		if sp.has("jump"):
			_jump_h[k] = sp.s * randf_range(sp.jump.h[0], sp.jump.h[1])
			_jump_offset[k] = fposmod(0.55 * _jump_period[k] - t - 0.25, _jump_period[k])
		else:
			_burst(Vector3(_pos[k].x, maxf(_pos[k].y, 0.0), _pos[k].z), 1.0)


## Отладка: скелет просвечивает сквозь тело.
func set_xray(on: bool) -> void:
	debug_xray = on


## Текущий вид слота (-1 — слот пуст).
func species_of(i: int) -> int:
	if i < 0 or i >= MAX_FISH or not _active[i]:
		return -1
	return _sp[i]


## Есть ли свободный слот.
func has_free_slot() -> bool:
	for i in range(MAX_FISH):
		if not _active[i]:
			return true
	return false


func setup(game_ref, p_level: float, wf: WaterField = null, coast_ref = null) -> void:
	game = game_ref
	water_level = p_level
	water_field = wf
	coast = coast_ref
	if material != null and game != null:
		material.set_shader_parameter("sun_dir", game.sun_dir)
		material.set_shader_parameter("fog_distance", game.FOG_DISTANCE)


func apply_sun(dir: Vector3) -> void:
	if material != null:
		material.set_shader_parameter("sun_dir", dir)


func apply_night01(value: float) -> void:
	night_amount = clampf(value, 0.0, 1.0)
	if material != null:
		material.set_shader_parameter("fog_distance", lerpf(340.0, 130.0, night_amount))
	_push_uniforms()


func set_sdf_enabled(on: bool) -> void:
	if _quad != null:
		_quad.visible = on


## Минимальная глубина для вида размером s: тело не касается дна. Ниже — мель.
func _zone_depth_for(s: float) -> float:
	return maxf(1.2, 1.35 * s + 0.55)


func _process(delta: float) -> void:
	t += delta
	var any := false
	for i in range(MAX_FISH):
		if not _active[i]:
			continue
		any = true
		_sim_fish(i, delta)
		_solve_bones(i, delta)
	if any or _pushed == false:
		_push_uniforms()
		_pushed = true


# ---------------------------------------------------------------------------
# Сброс динамики вида (при заселении и смене вида)
# ---------------------------------------------------------------------------

func _reset_species(i: int, sp_id: int) -> void:
	var sp: Dictionary = SPECIES[sp_id]
	_sp[i] = sp_id
	_speed[i] = sp.cruise
	_phase[i] = randf() * TAU
	_wing_ph[i] = 0.0
	_pitch[i] = 0.0
	_pp_y[i] = 0.9 * sp.s if _pposed[i] else 0.0
	_pp_pitch[i] = 0.04
	_jump_period[i] = 12.0
	_jump_offset[i] = randf() * 12.0
	_jump_h[i] = 0.0
	if sp.has("jump"):
		_jump_period[i] = randf_range(sp.jump.period[0], sp.jump.period[1])
		_jump_offset[i] = randf() * _jump_period[i]
		_jump_h[i] = sp.s * randf_range(sp.jump.h[0], sp.jump.h[1])
	_dash_t[i] = 0.0
	if sp.has("dash"):
		_dash_next[i] = randf_range(sp.dash.every[0], sp.dash.every[1])
	else:
		_dash_next[i] = 1e9
	_lunge_t[i] = 0.0
	if sp.has("lunge"):
		_lunge_next[i] = randf_range(sp.lunge.every[0], sp.lunge.every[1])
	else:
		_lunge_next[i] = 1e9
	_hover[i] = 0.0
	if sp.has("hover"):
		_hover_next[i] = randf_range(sp.hover.every[0], sp.hover.every[1])
	else:
		_hover_next[i] = 1e9
	_hover_k[i] = 0.0
	_probe[i] = 0.0
	if sp.has("probe"):
		_probe_next[i] = randf_range(sp.probe.every[0], sp.probe.every[1])
	else:
		_probe_next[i] = 1e9
	_probe_k[i] = 0.0
	_probe_ring[i] = 0.0
	_inflate[i] = 0.0
	_inflate_tgt[i] = 0.0
	_puff_t[i] = 0.0
	if sp.has("puff"):
		_puff_idle_next[i] = randf_range(sp.puff.idle_every[0], sp.puff.idle_every[1])
	else:
		_puff_idle_next[i] = 1e9
	_wake_t[i] = 0.0
	_scare[i] = 0.0
	_act_tgt[i] = 0.35 if sp_id == 2 else 0.0
	_act[i] = _act_tgt[i]
	_hop_t[i] = 0.0
	_hop_h[i] = 0.6
	_lure_fresh[i] = true
	_pos[i].y = _pp_y[i] if _pposed[i] else (-sp.depth * sp.s)


# ---------------------------------------------------------------------------
# Жизнь рыбы: общее блуждание + видовые циклы (порт simFish из fish_kit.html)
# ---------------------------------------------------------------------------

func _sim_fish(i: int, delta: float) -> void:
	var sp: Dictionary = SPECIES[_sp[i]]
	var s: float = sp.s

	# морф-переход при смене вида
	if _pending[i] != -1:
		_morph_tgt[i] = 0.0
		if _morph[i] < 0.03:
			if _pposed[i]: # показ: кадр подстраивается под новый вид
				_pp_y[i] = 0.9 * SPECIES[_pending[i]].s
			_reset_species(i, _pending[i])
			_pending[i] = -1
			_morph_tgt[i] = 1.0
	_morph[i] += (_morph_tgt[i] - _morph[i]) * (1.0 - exp(-7.0 * delta))

	var boost := 1.0
	_act_tgt[i] = 0.35 if _sp[i] == 2 else 0.0
	var pitch_tgt := _pp_pitch[i] if _pposed[i] else 0.0

	# --- испуг: прочь от игрока/камеры, у вида своя реакция ---
	if _scare[i] > 0.0:
		_scare[i] -= delta
		if not _pposed[i]: # в показе не убегает — только видовые реакции
			boost = 2.6
			var cam := get_viewport().get_camera_3d()
			var cx := _pos[i].x
			var cz := _pos[i].z
			if cam != null:
				cx -= cam.global_position.x
				cz -= cam.global_position.z
			var away := atan2(cz, cx)
			var dhs := wrapf(away - _heading[i], -PI, PI)
			_turn[i] += clampf(dhs * 3.0, -0.7, 0.7) * delta * 6.0
		if _sp[i] == 2:
			_act_tgt[i] = 0.06 # фонарь гаснет
		if _sp[i] == 4 and _dash_t[i] <= 0.0:
			_dash_t[i] = sp.dash.dur
		if _sp[i] == 5 and _puff_t[i] <= 0.0:
			_puff_t[i] = sp.puff.scare

	# --- прыжок циклом (странник / манта / стрела) ---
	var bump := 0.0
	if sp.has("jump"):
		var cy := fposmod(t + _jump_offset[i], _jump_period[i])
		var x := (cy - 0.55 * _jump_period[i]) / (0.09 * _jump_period[i])
		bump = exp(-x * x)
		if coast != null and not _pposed[i] \
				and coast.water_depth(_pos[i].x, _pos[i].z) < _zone_depth_for(float(sp.s)):
			bump = 0.0 # на мелководье не выпрыгиваем — не садимся на песок

	# --- стрела: рывок-бросок, на выходе — прыжок ---
	if sp.has("dash") and not _pposed[i]:
		if _dash_t[i] > 0.0:
			_dash_t[i] -= delta
			boost = maxf(boost, sp.dash.speed / maxf(sp.cruise, 0.01))
			_turn[i] *= exp(-8.0 * delta)
			_act_tgt[i] = 0.5
			if _dash_t[i] <= 0.0:
				_jump_offset[i] = fposmod(0.55 * _jump_period[i] - t - 0.05, _jump_period[i])
		else:
			_dash_next[i] -= delta
			if _dash_next[i] <= 0.0 and _scare[i] <= 0.0:
				_dash_t[i] = sp.dash.dur
				_dash_next[i] = randf_range(sp.dash.every[0], sp.dash.every[1])

	# --- фонарник: засада, короткие рывки с вспышкой эски ---
	if sp.has("lunge") and not _pposed[i]:
		if _lunge_t[i] > 0.0:
			_lunge_t[i] -= delta
			boost = maxf(boost, sp.lunge.speed / sp.cruise)
			_act_tgt[i] = 1.0
		else:
			_lunge_next[i] -= delta
			if _lunge_next[i] <= 0.0 and _scare[i] <= 0.0:
				_lunge_t[i] = sp.lunge.dur
				_lunge_next[i] = randf_range(sp.lunge.every[0], sp.lunge.every[1])
				_turn[i] += randf_range(-2.0, 2.0)

	# --- угорь: замирает «водорослью», покачиваясь на месте ---
	_hover_k[i] = 0.0
	if sp.has("hover") and not _pposed[i]:
		if _hover[i] > 0.0:
			_hover[i] -= delta
			var k: float = minf(
				clampf((sp.hover.hold + 2.0 - _hover[i]) / 1.2, 0.0, 1.0),
				clampf(_hover[i] / 1.2, 0.0, 1.0))
			_hover_k[i] = k
			pitch_tgt += sp.hover.pitch * k
			_act_tgt[i] = maxf(_act_tgt[i], 0.6 * k)
		else:
			_hover_next[i] -= delta
			if _hover_next[i] <= 0.0 and _scare[i] <= 0.0:
				_hover[i] = sp.hover.hold + 2.0
				_hover_next[i] = randf_range(sp.hover.every[0], sp.hover.every[1])

	# --- усач: нырок и копание дна ---
	_probe_k[i] = 0.0
	if sp.has("probe") and not _pposed[i]:
		if _probe[i] > 0.0:
			_probe[i] -= delta
			var kp: float = minf(
				clampf((sp.probe.dur + 1.6 - _probe[i]) / 1.2, 0.0, 1.0),
				clampf(_probe[i] / 1.2, 0.0, 1.0))
			_probe_k[i] = kp
			pitch_tgt -= 0.45 * kp
			_act_tgt[i] = maxf(_act_tgt[i], kp)
			if kp > 0.6:
				_probe_ring[i] -= delta
				if _probe_ring[i] <= 0.0: # кольца мути у рыла
					_probe_ring[i] = 0.55
					var nx := _pos[i].x + cos(_heading[i]) * 1.3 * s
					var nz := _pos[i].z + sin(_heading[i]) * 1.3 * s
					if water_field != null:
						water_field.splash(Vector2(nx, nz), 0.35)
		else:
			_probe_next[i] -= delta
			if _probe_next[i] <= 0.0 and _scare[i] <= 0.0:
				_probe[i] = sp.probe.dur + 1.6
				_probe_ring[i] = 0.0

	# --- пухляк: надувание (испуг / «подышит» от скуки) ---
	if sp.has("puff"):
		if _puff_t[i] > 0.0:
			_puff_t[i] -= delta
			_inflate_tgt[i] = 1.0
		else:
			_inflate_tgt[i] = 0.0
			_puff_idle_next[i] -= delta
			if _puff_idle_next[i] <= 0.0 and _scare[i] <= 0.0:
				_puff_t[i] = 1.6
				_puff_idle_next[i] = randf_range(sp.puff.idle_every[0], sp.puff.idle_every[1])
		_inflate[i] += (_inflate_tgt[i] - _inflate[i]) * (1.0 - exp(-6.0 * delta))

	# --- движение: блуждание в круге + возврат ---
	if _pposed[i]:
		# ПОКАЗ: рыба кружит над песком у камеры — видна целиком
		_turn[i] = 0.12 + sin(t * 0.5) * 0.05
		if _hop_t[i] > 0.0:
			_hop_t[i] -= delta
	else:
		if _scare[i] <= 0.0 and _dash_t[i] <= 0.0:
			_turn[i] += (randf() - 0.5) * 2.4 * delta
		var to_c := Vector2(_pos[i].x - _home[i].x, _pos[i].z - _home[i].y)
		if to_c.length() > bounds_radius * 0.72:
			var ah := atan2(-to_c.y, -to_c.x)
			var dh := wrapf(ah - _heading[i], -PI, PI)
			_turn[i] += dh * 1.8 * delta
		# Курс от мели: выбираем глубину вперёд-вбок, чтобы не выйти на песок.
		if coast != null:
			var need: float = _zone_depth_for(float(sp.s))
			var d_here: float = coast.water_depth(_pos[i].x, _pos[i].z)
			if d_here < need + 2.2:
				var best_h: float = _heading[i]
				var best_d: float = d_here
				for a: float in [-0.85, -0.35, 0.35, 0.85]:
					var h: float = _heading[i] + a
					var dp: float = coast.water_depth(_pos[i].x + cos(h) * 5.0,
						_pos[i].z + sin(h) * 5.0)
					if dp > best_d + 0.03:
						best_d = dp
						best_h = h
				if best_d > d_here + 0.03:
					var dh2: float = wrapf(best_h - _heading[i], -PI, PI)
					_turn[i] += clampf(dh2 * 3.4, -0.9, 0.9) * delta * 5.0
	_turn[i] = clampf(_turn[i], -0.7, 0.7)
	var spd_k := 1.0 - 0.85 * _hover_k[i] # «водоросль» — почти стоп
	_heading[i] += _turn[i] * delta
	_speed[i] += (sp.cruise - _speed[i]) * (1.0 - exp(-1.5 * delta))
	var spd := _speed[i] * boost * spd_k
	if _pposed[i]:
		spd *= 0.1
	_pos[i].x += cos(_heading[i]) * spd * delta
	_pos[i].z += sin(_heading[i]) * spd * delta

	_bank[i] += (clampf(_turn[i] * 2.2, -0.55, 0.55) - _bank[i]) * (1.0 - exp(-3.0 * delta))
	_pitch[i] += (pitch_tgt - _pitch[i]) * (1.0 - exp(-4.0 * delta))
	_act[i] += (_act_tgt[i] - _act[i]) * (1.0 - exp(-5.0 * delta))

	# волна тела: частота растёт со скоростью (как у живых рыб)
	_phase[i] += delta * (sp.freq.base + spd * sp.freq.k)
	var wf: float = float(sp.flap.freq)
	if sp.has("wingfreq"):
		wf = float(sp.wingfreq)
	_wing_ph[i] += delta * wf

	# --- глубина: своя глубина + дыхание + видовые нырки + прыжок ---
	var y_tgt: float = _pp_y[i] if _pposed[i] \
			else (-float(sp.depth) * s + sin(t * 0.5) * 0.15 * s)
	if _pposed[i]:
		if _hop_t[i] > 0.0: # подскок в показе — у всех видов
			var hk: float = 1.0 - _hop_t[i] / 0.8
			y_tgt += sin(PI * clampf(hk, 0.0, 1.0)) * _hop_h[i]
	else:
		if sp.has("hover"):
			y_tgt += (-0.25 * s - y_tgt) * _hover_k[i] # «водоросль» — у поверхности
		if sp.has("probe"):
			y_tgt += (-sp.probe.depth * s - y_tgt) * _probe_k[i]
		if sp.has("lunge") and _lunge_t[i] > 0.0:
			y_tgt = -0.55 * s
		if sp.has("jump"):
			y_tgt += (sp.depth * s + _jump_h[i]) * bump
	var prev_y := _pos[i].y
	_pos[i].y += (y_tgt - _pos[i].y) * (1.0 - exp(-7.0 * delta))
	if coast != null and not _pposed[i]:
		# дно: тело с запасом выше песка (усачу разрешено копать)
		var clear: float = 0.38 * s
		if _probe_k[i] > 0.3:
			clear = -0.55 * s
		var floor_y: float = coast.ground_height(_pos[i].x, _pos[i].z) + clear + 0.12
		floor_y = minf(floor_y, water_level - 0.30 * s)
		if _pos[i].y < floor_y:
			_pos[i].y = floor_y

	# всплески на пересечении поверхности
	var above_now := _pos[i].y > 0.25 * s
	var above_prev := prev_y > 0.25 * s
	if above_now and not above_prev:
		_burst(_pos[i], 0.6)
	elif above_prev and not above_now:
		_burst(_pos[i], 1.1)
	if _sp[i] == 3 and absf(_pos[i].y + 0.2) < 0.06 and _morph[i] > 0.5:
		# крыло манты чиркает по песку — расходящиеся кольца
		_wake_t[i] -= delta
		if _wake_t[i] <= 0.0:
			_wake_t[i] = 0.9
			if water_field != null:
				water_field.splash(Vector2(_pos[i].x, _pos[i].z), 0.3)


## Брызги-капли (парбол, как sand_fish._burst; слоты — свои, 12 штук)
func _burst(pos: Vector3, strength: float) -> void:
	var n := int(5.0 + 4.0 * strength)
	for j in range(n):
		var k := _drops_cursor
		_drops_cursor = (_drops_cursor + 1) % MAX_DROPS
		var ang := randf() * TAU
		var rad := randf_range(0.25, 0.85) * (0.6 + 0.4 * strength)
		_drops_pos[k] = pos + Vector3(cos(ang) * 0.15, 0.08, sin(ang) * 0.15)
		_drops_vel[k] = Vector3(cos(ang) * rad,
				randf_range(1.6, 2.8) * (0.7 + 0.4 * strength),
				sin(ang) * rad)
		_drops_age[k] = 0.0
		_drops_life[k] = randf_range(0.65, 1.05)
		_drops_r0[k] = randf_range(0.045, 0.085) * (0.8 + 0.4 * strength)
	if water_field != null:
		water_field.splash(Vector2(pos.x, pos.z), 0.6 + 0.8 * strength)


const MAX_DROPS := 12
var _drops_pos := PackedVector3Array()
var _drops_vel: Array[Vector3] = [] # компоненты меняются на месте (гравитация)
var _drops_age := PackedFloat32Array()
var _drops_life := PackedFloat32Array()
var _drops_r0 := PackedFloat32Array()
var _drops_cursor := 0
var _pushed := false


func _sim_drops(delta: float) -> void:
	for k in range(MAX_DROPS):
		if _drops_r0[k] <= 0.0:
			continue
		_drops_age[k] += delta
		_drops_vel[k].y -= GRAVITY * delta
		_drops_pos[k] += _drops_vel[k] * delta
		if _drops_age[k] > _drops_life[k] or _drops_pos[k].y < water_level - 0.15:
			_drops_r0[k] = 0.0


# ---------------------------------------------------------------------------
# FK-цепочка КОСТЕЙ (порт solveBones): кость i+1 продолжает кадр кости i
# с собственным изгибом — yaw-волна к хвосту + вертикальная волна.
# ---------------------------------------------------------------------------

static func _cross(a: Vector3, b: Vector3) -> Vector3:
	return Vector3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)


static func _rot_axis(v: Vector3, k: Vector3, th: float) -> Vector3:
	# Родригес: поворот v вокруг единичной k
	var c := cos(th)
	var sn := sin(th)
	return v * c + k.cross(v) * sn + k * k.dot(v) * (1.0 - c)


func _solve_bones(i: int, delta: float) -> void:
	var sp: Dictionary = SPECIES[_sp[i]]
	var s: float = sp.s * _morph[i]
	var n: int = sp.n
	var infl: float = _inflate[i]
	var seg_len: float = sp.seg * s * (1.0 + 0.22 * infl)
	var head := _pos[i]
	# головной кадр: курс + питч (нос вверх/вниз) + банк (крен в вираже)
	var cy := cos(_heading[i])
	var sy := sin(_heading[i])
	var cp := cos(_pitch[i])
	var spn := sin(_pitch[i])
	var fwd := Vector3(cy * cp, spn, sy * cp)
	var ref := Vector3(0, 1, 0) if absf(fwd.y) < 0.95 else Vector3(1, 0, 0)
	var right := _cross(fwd, ref).normalized()
	var up := _cross(right, fwd)
	if absf(_bank[i]) > 1e-4:
		right = _rot_axis(right, fwd, _bank[i])
		up = _rot_axis(up, fwd, _bank[i])
	var wv: Dictionary = sp.wave
	var pos := head
	for k in range(n):
		_bones_flat[i * FK_BONE + k] = Vector4(pos.x, pos.y, pos.z,
				sp.radii[k] * s * (1.0 + 0.85 * infl))
		if k == n - 1:
			break
		var tk := float(k) / float(n - 1)
		var yaw: float = (float(wv.a0) + (float(wv.a1) - float(wv.a0)) * tk) * sin(_phase[i] - k * float(wv.lag))
		var pit: float = (float(wv.v0) + (float(wv.v1) - float(wv.v0)) * tk) \
				* sin(_phase[i] * 0.75 + 1.3 - k * float(wv.lagv))
		fwd = _rot_axis(fwd, up, yaw)
		fwd = _rot_axis(fwd, right, pit)
		fwd = fwd.normalized()
		# переортогонализация без потери крена: right тянем вдоль цепочки
		var d_rf := right.dot(fwd)
		right = right - fwd * d_rf
		if right.length() < 0.05:
			var r2 := Vector3(0, 1, 0) if absf(fwd.y) < 0.95 else Vector3(1, 0, 0)
			right = _cross(fwd, r2).normalized()
		else:
			right = right.normalized()
		up = _cross(right, fwd)
		pos -= fwd * seg_len
	for k in range(n, FK_BONE):
		_bones_flat[i * FK_BONE + k] = Vector4(0.0, 0.0, 0.0, 0.0)
	# центр тела — среднее по костям (окраска/вуаль/граница)
	var c := Vector3.ZERO
	for k in range(n):
		c += Vector3(_bones_flat[i * FK_BONE + k].x,
				_bones_flat[i * FK_BONE + k].y,
				_bones_flat[i * FK_BONE + k].z)
	_center[i] = c / float(n)
	# кадр кости 0 — как fk_frame в шейдере (для позиции эски фонарника)
	var f0 := (Vector3(_bones_flat[i * FK_BONE].x, _bones_flat[i * FK_BONE].y,
			_bones_flat[i * FK_BONE].z)
		- Vector3(_bones_flat[i * FK_BONE + 1].x, _bones_flat[i * FK_BONE + 1].y,
			_bones_flat[i * FK_BONE + 1].z)).normalized()
	_f0[i] = f0
	var ref0 := Vector3(0, 1, 0) if absf(f0.y) < 0.95 else Vector3(1, 0, 0)
	_sd0[i] = _cross(f0, ref0).normalized()
	_up0[i] = _cross(_sd0[i], f0)
	# эска фонарника: посох-иллиций — ЖЕЛЕ на пружине (Эйлер),
	# качается вслед за головой; комок догоняет с запаздыванием
	if _sp[i] == 2:
		var s2: float = sp.s * _morph[i]
		var r0: float = sp.radii[0] * s2
		var lb := Vector3(_bones_flat[i * FK_BONE].x, _bones_flat[i * FK_BONE].y,
				_bones_flat[i * FK_BONE].z) \
				- _f0[i] * (0.10 * s2) + _up0[i] * (r0 * 0.95)
		var rest_mid: Vector3 = lb - _f0[i] * (0.22 * s2) + _up0[i] * (0.28 * s2)
		var rest_core: Vector3 = lb - _f0[i] * (0.45 * s2) + _up0[i] * (0.55 * s2)
		if _lure_fresh[i]:
			_lure_mid[i] = rest_mid
			_lure_mid_v[i] = Vector3.ZERO
			_bulb[i] = rest_core
			_lure_core_v[i] = Vector3.ZERO
			_lure_hist[i].clear()
			_lure_fresh[i] = false
		else:
			# мягкая пружина: посох провисает и колышется за головой
			_lure_mid_v[i] += ((rest_mid - _lure_mid[i]) * 60.0
					- _lure_mid_v[i] * 6.5) * delta
			_lure_mid_v[i].y -= 1.4 * delta
			_lure_mid[i] += _lure_mid_v[i] * delta
			_lure_core_v[i] += ((rest_core - _bulb[i]) * 42.0
					- _lure_core_v[i] * 5.5) * delta
			_lure_core_v[i].y -= 1.8 * delta
			_bulb[i] += _lure_core_v[i] * delta
		_lure_hist[i].push_front(_bulb[i])
		if _lure_hist[i].size() > 6:
			_lure_hist[i].pop_back()
		if _lure_hist[i].size() >= 4:
			var dv: Vector3 = _lure_hist[i][3] - _bulb[i]
			_lobe_a[i] = dv.limit_length(0.42 * (0.055 + 0.02 * _act[i]) * s2)
		else:
			_lobe_a[i] = Vector3.ZERO
		_lure_pulse[i] = clampf(_lure_core_v[i].length() * 0.9, 0.0, 1.0)
	else:
		_bulb[i] = _center[i]


# ---------------------------------------------------------------------------
# Пуш uniform-ов (каждый кадр: 3 рыбы × 12 костей + 12 капель — копейки)
# ---------------------------------------------------------------------------

func _push_uniforms() -> void:
	_sim_drops(get_process_delta_time())
	var bones_all := PackedVector4Array()
	bones_all.resize(MAX_FISH * FK_BONE)
	var params := PackedVector4Array()
	params.resize(MAX_FISH)
	var flags := PackedVector4Array()
	flags.resize(MAX_FISH)
	var top := PackedVector3Array()
	top.resize(MAX_FISH)
	var belly := PackedVector3Array()
	belly.resize(MAX_FISH)
	var acc := PackedVector3Array()
	acc.resize(MAX_FISH)
	var glow_c := PackedVector3Array()
	glow_c.resize(MAX_FISH)
	var glow := PackedVector4Array()
	glow.resize(MAX_FISH)
	var lure := PackedVector4Array() # желе-эска (колено посоха + радиус)
	lure.resize(MAX_FISH)
	var lure2 := PackedVector4Array() # комок + пульс
	lure2.resize(MAX_FISH)
	var centers := PackedVector3Array()
	centers.resize(MAX_FISH)
	for i in range(MAX_FISH):
		if not _active[i]:
			continue
		var sp: Dictionary = SPECIES[_sp[i]]
		for k in range(FK_BONE):
			bones_all[i * FK_BONE + k] = _bones_flat[i * FK_BONE + k]
		var flap: float = sin(_wing_ph[i]) * float(sp.flap.amp)
		params[i] = Vector4(sp.s, _phase[i], flap, _morph[i])
		flags[i] = Vector4(float(_sp[i]), sp.melt, _inflate[i], float(sp.n))
		var top_color: Color = sp.top.lerp(Color(0.065, 0.075, 0.13), night_amount * 0.78)
		var belly_color: Color = sp.belly.lerp(Color(0.12, 0.14, 0.22), night_amount * 0.72)
		var accent_color: Color = sp.acc.lerp(Color(0.18, 0.24, 0.42), night_amount * 0.62)
		var glow_color: Color = sp.glowc.lerp(Color(0.30, 0.44, 0.88), night_amount * 0.38)
		top[i] = Vector3(top_color.r, top_color.g, top_color.b)
		belly[i] = Vector3(belly_color.r, belly_color.g, belly_color.b)
		acc[i] = Vector3(accent_color.r, accent_color.g, accent_color.b)
		glow_c[i] = Vector3(glow_color.r, glow_color.g, glow_color.b)
		glow[i] = Vector4(_bulb[i].x, _bulb[i].y, _bulb[i].z, _act[i])
		if _sp[i] == 2:
			var br_lure: float = (0.055 + 0.02 * _act[i]) * float(sp.s) * _morph[i]
			lure[i] = Vector4(_lure_mid[i].x, _lure_mid[i].y,
				_lure_mid[i].z, br_lure)
			lure2[i] = Vector4(_lobe_a[i].x, _lobe_a[i].y,
				_lobe_a[i].z, _lure_pulse[i])
		centers[i] = _center[i]
	var dp := PackedVector4Array()
	dp.resize(MAX_DROPS)
	for k in range(MAX_DROPS):
		if _drops_r0[k] <= 0.0:
			continue
		var r := _drops_r0[k] * (1.0 - 0.35 * clampf(_drops_age[k] / _drops_life[k], 0.0, 1.0))
		dp[k] = Vector4(_drops_pos[k].x, _drops_pos[k].y, _drops_pos[k].z, r)

	material.set_shader_parameter("u_fk_bone", bones_all)
	material.set_shader_parameter("u_fk_params", params)
	material.set_shader_parameter("u_fk_flags", flags)
	material.set_shader_parameter("u_fk_top", top)
	material.set_shader_parameter("u_fk_belly", belly)
	material.set_shader_parameter("u_fk_acc", acc)
	material.set_shader_parameter("u_fk_glow_c", glow_c)
	material.set_shader_parameter("u_fk_glow", glow)
	material.set_shader_parameter("u_fk_lure", lure)
	material.set_shader_parameter("u_fk_lure2", lure2)
	material.set_shader_parameter("u_fk_center", centers)
	material.set_shader_parameter("u_fk_xray", 1.0 if debug_xray else 0.0)
	material.set_shader_parameter("u_drops", dp)
	var cam := get_viewport().get_camera_3d()
	var center2 := Vector2.ZERO
	if cam != null:
		center2 = Vector2(cam.global_position.x, cam.global_position.z)
		_quad.global_position = cam.global_position
	material.set_shader_parameter("u_center", center2)
	material.set_shader_parameter("u_bounds_r", bounds_radius * 2.0 + 20.0)
	material.set_shader_parameter("u_water_level", water_level)
	material.set_shader_parameter("u_time", t)

