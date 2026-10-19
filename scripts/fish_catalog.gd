class_name FishCatalog
extends RefCounted
## Каталог рыб и баланс клёва — порт системы из открытого проекта
## bridge-mind/tideline (Three.js, MIT): зоны по дистанции заброса,
## редкость, время суток, окно подсечки, «характер» борьбы.
##
## Здесь только ДАННЫЕ и чистые функции (что и когда клюёт, какой размер
## и сила попались). Сама поклёвка живёт в BiteSystem, вываживание —
## в FishFight, вид — в CatchFish. Баланс — в одном месте.

## Редкости: подпись, цвет для карточки, опыт, множитель окна подсечки, звёзды.
const RARITY := {
	"common": {"label": "Обычная", "color": Color(0.68, 0.74, 0.79),
		"xp": 12, "hook_mult": 1.15, "stars": 1},
	"uncommon": {"label": "Необычная", "color": Color(0.38, 0.85, 0.55),
		"xp": 22, "hook_mult": 1.05, "stars": 2},
	"rare": {"label": "Редкая", "color": Color(0.35, 0.65, 1.0),
		"xp": 40, "hook_mult": 0.98, "stars": 3},
	"epic": {"label": "Эпическая", "color": Color(0.75, 0.55, 1.0),
		"xp": 72, "hook_mult": 0.90, "stars": 4},
	"legendary": {"label": "Легендарная", "color": Color(1.0, 0.69, 0.24),
		"xp": 130, "hook_mult": 0.80, "stars": 5},
}

## Виды песчаного моря. zones: shallow (≤13 м), mid (≤28 м), deep (дальше).
## times: day / dusk / night (см. time_segment()).
## fight: strength — натяг, surge_every — пауза между рывками (с),
##        heft — тяжесть (медленнее подмотка), stamina — сколько секунд
##        рыба свежая (потом слабеет).
const SPECIES := [
	{
		"id": "mackerel", "name": "Серебристая макрель", "rarity": "common",
		"zones": ["shallow", "mid"], "times": ["day", "dusk"], "base": 26.0,
		"size_cm": [24.0, 48.0], "weight_mid": 0.9, "value": 16,
		"strength": 0.80, "surge": [4.0, 6.5], "heft": 0.80, "stamina": 9.0,
		"shape": "slim", "col_a": Color(0.29, 0.50, 0.66), "col_b": Color(0.78, 0.83, 0.86),
		"col_fin": Color(0.23, 0.31, 0.41), "glow": false,
		"desc": "Ходит стаями у самого уреза, вспыхивает серебром на солнце.",
	},
	{
		"id": "flounder", "name": "Песчаная камбала", "rarity": "common",
		"zones": ["shallow"], "times": ["day", "dusk", "night"], "base": 30.0,
		"size_cm": [28.0, 58.0], "weight_mid": 1.6, "value": 18,
		"strength": 0.90, "surge": [4.5, 7.0], "heft": 1.20, "stamina": 10.0,
		"shape": "flat", "col_a": Color(0.69, 0.60, 0.42), "col_b": Color(0.52, 0.45, 0.31),
		"col_fin": Color(0.47, 0.39, 0.26), "glow": false,
		"desc": "Живой коврик: лежит на песчаном дне и ждёт, пока обед проплывёт мимо.",
	},
	{
		"id": "sandcat", "name": "Песчаный сом", "rarity": "common",
		"zones": ["shallow", "mid"], "times": ["night"], "base": 23.0,
		"size_cm": [42.0, 95.0], "weight_mid": 5.0, "value": 24,
		"strength": 1.05, "surge": [4.0, 6.5], "heft": 1.45, "stamina": 13.0,
		"shape": "standard", "col_a": Color(0.42, 0.47, 0.52), "col_b": Color(0.29, 0.32, 0.36),
		"col_fin": Color(0.23, 0.26, 0.30), "glow": false,
		"desc": "Ночной тяжеловес песчаного дна. Тянет медленно и упрямо.",
	},
	{
		"id": "perch", "name": "Морской окунь", "rarity": "uncommon",
		"zones": ["mid"], "times": ["day", "dusk"], "base": 20.0,
		"size_cm": [30.0, 55.0], "weight_mid": 1.8, "value": 30,
		"strength": 1.00, "surge": [4.0, 6.0], "heft": 1.00, "stamina": 11.0,
		"shape": "standard", "col_a": Color(0.30, 0.49, 0.31), "col_b": Color(0.66, 0.76, 0.60),
		"col_fin": Color(0.18, 0.32, 0.20), "glow": false,
		"desc": "Полосатый и любопытный: где один, там и вся стая.",
	},
	{
		"id": "eel", "name": "Песчаный угорь", "rarity": "uncommon",
		"zones": ["mid", "deep"], "times": ["night"], "base": 13.0,
		"size_cm": [55.0, 120.0], "weight_mid": 2.4, "value": 34,
		"strength": 1.10, "surge": [2.8, 4.5], "heft": 1.00, "stamina": 12.0,
		"shape": "long", "col_a": Color(0.31, 0.42, 0.32), "col_b": Color(0.22, 0.31, 0.24),
		"col_fin": Color(0.17, 0.24, 0.18), "glow": false,
		"desc": "Живой провод: дёргается постоянно. Главное — не терять спокойствие.",
	},
	{
		"id": "salmon", "name": "Королевский лосось", "rarity": "rare",
		"zones": ["mid", "deep"], "times": ["day", "dusk"], "base": 8.0,
		"size_cm": [55.0, 105.0], "weight_mid": 7.0, "value": 60,
		"strength": 1.40, "surge": [3.5, 5.5], "heft": 1.50, "stamina": 14.0,
		"shape": "slim", "col_a": Color(0.66, 0.71, 0.75), "col_b": Color(0.85, 0.39, 0.35),
		"col_fin": Color(0.47, 0.52, 0.55), "glow": false,
		"desc": "Рождён против течения, сложен как атлет — и бьётся так же.",
	},
	{
		"id": "snapper", "name": "Красный луциан", "rarity": "rare",
		"zones": ["deep"], "times": ["day", "night"], "base": 7.0,
		"size_cm": [45.0, 85.0], "weight_mid": 4.5, "value": 70,
		"strength": 1.45, "surge": [3.5, 5.5], "heft": 1.30, "stamina": 13.0,
		"shape": "standard", "col_a": Color(0.83, 0.34, 0.29), "col_b": Color(0.94, 0.56, 0.50),
		"col_fin": Color(0.66, 0.23, 0.19), "glow": false,
		"desc": "Багровый и зоркий. Держится глубины и не прощает слабины.",
	},
	{
		"id": "ray", "name": "Золотой скат", "rarity": "epic",
		"zones": ["shallow"], "times": ["dusk", "night"], "base": 3.0,
		"size_cm": [60.0, 140.0], "weight_mid": 6.0, "value": 150,
		"strength": 1.50, "surge": [3.0, 5.0], "heft": 1.40, "stamina": 15.0,
		"shape": "flat", "col_a": Color(0.94, 0.70, 0.26), "col_b": Color(0.99, 0.88, 0.60),
		"col_fin": Color(0.85, 0.55, 0.16), "glow": true,
		"desc": "Плывущее золото песчаного мелководья. Виден сквозь воду.",
	},
	{
		"id": "marlin", "name": "Песчаный марлин", "rarity": "legendary",
		"zones": ["deep"], "times": ["night"], "base": 1.2,
		"size_cm": [180.0, 330.0], "weight_mid": 90.0, "value": 900,
		"strength": 2.20, "surge": [2.6, 4.2], "heft": 2.60, "stamina": 24.0,
		"shape": "billed", "col_a": Color(0.18, 0.37, 0.66), "col_b": Color(0.50, 0.70, 0.91),
		"col_fin": Color(0.11, 0.25, 0.47), "glow": true,
		"desc": "Корона песчаного моря. Одна такая ночь — уже история.",
	},
	{
		"id": "dune_wanderer", "name": "Дюнный странник", "rarity": "uncommon",
		"zones": ["shallow", "mid"], "times": ["day", "dusk"], "base": 9.0,
		"size_cm": [45.0, 105.0], "weight_mid": 8.0, "value": 34,
		"strength": 1.05, "surge": [4.0, 6.0], "heft": 1.2, "stamina": 12.0,
		"shape": "slim", "col_a": Color(0.93, 0.65, 0.30), "col_b": Color(0.98, 0.84, 0.59),
		"col_fin": Color(0.76, 0.42, 0.20), "glow": false, "kit_species": 0,
		"desc": "Большой золотой странник песчаного моря; волна бежит по его хвосту.",
	},
	{
		"id": "ribbon_eel", "name": "Угорь-лента", "rarity": "rare",
		"zones": ["mid", "deep"], "times": ["night"], "base": 7.0,
		"size_cm": [65.0, 155.0], "weight_mid": 2.8, "value": 62,
		"strength": 1.25, "surge": [2.8, 4.5], "heft": 0.9, "stamina": 14.0,
		"shape": "long", "col_a": Color(0.08, 0.19, 0.63), "col_b": Color(0.36, 0.52, 0.89),
		"col_fin": Color(1.0, 0.74, 0.13), "glow": true, "kit_species": 1,
		"desc": "Сапфировая лента с золотой каймой скользит в ночной воде.",
	},
	{
		"id": "angler", "name": "Фонарник", "rarity": "epic",
		"zones": ["deep"], "times": ["night"], "base": 3.5,
		"size_cm": [35.0, 88.0], "weight_mid": 4.0, "value": 115,
		"strength": 1.55, "surge": [3.0, 4.8], "heft": 1.1, "stamina": 16.0,
		"shape": "standard", "col_a": Color(0.17, 0.12, 0.24), "col_b": Color(0.39, 0.27, 0.39),
		"col_fin": Color(0.58, 0.37, 0.23), "glow": true, "kit_species": 2,
		"desc": "Глубинный хищник с живым голубым фонарём над головой.",
	},
	{
		"id": "sand_manta", "name": "Песчаная манта", "rarity": "rare",
		"zones": ["mid", "deep"], "times": ["day", "dusk"], "base": 5.5,
		"size_cm": [85.0, 190.0], "weight_mid": 28.0, "value": 86,
		"strength": 1.4, "surge": [4.5, 7.0], "heft": 1.8, "stamina": 16.0,
		"shape": "flat", "col_a": Color(0.36, 0.23, 0.16), "col_b": Color(0.95, 0.90, 0.82),
		"col_fin": Color(0.27, 0.17, 0.13), "glow": false, "kit_species": 3,
		"desc": "Ширококрылая манта размеренно машет крыльями у дна.",
	},
	{
		"id": "sand_arrow", "name": "Стрела", "rarity": "rare",
		"zones": ["mid", "deep"], "times": ["day", "dusk"], "base": 5.0,
		"size_cm": [55.0, 125.0], "weight_mid": 11.0, "value": 78,
		"strength": 1.65, "surge": [2.6, 4.0], "heft": 1.2, "stamina": 15.0,
		"shape": "slim", "col_a": Color(0.12, 0.25, 0.67), "col_b": Color(0.87, 0.91, 0.98),
		"col_fin": Color(1.0, 0.73, 0.12), "glow": false, "kit_species": 4,
		"desc": "Синяя торпеда: резко ускоряется и вылетает из воды.",
	},
	{
		"id": "puffer", "name": "Пухляк", "rarity": "uncommon",
		"zones": ["shallow", "mid"], "times": ["day", "dusk", "night"], "base": 8.0,
		"size_cm": [22.0, 52.0], "weight_mid": 1.2, "value": 28,
		"strength": 0.82, "surge": [5.0, 8.0], "heft": 0.75, "stamina": 9.0,
		"shape": "standard", "col_a": Color(0.69, 0.62, 0.30), "col_b": Color(0.95, 0.87, 0.65),
		"col_fin": Color(0.50, 0.40, 0.21), "glow": false, "kit_species": 5,
		"desc": "Небольшой иглобрюх гребёт плавниками и раздувается от испуга.",
	},
	{
		"id": "bottom_forager", "name": "Усач-грунтовик", "rarity": "uncommon",
		"zones": ["shallow", "mid"], "times": ["day", "dusk"], "base": 6.5,
		"size_cm": [38.0, 92.0], "weight_mid": 4.5, "value": 42,
		"strength": 1.0, "surge": [4.2, 6.5], "heft": 1.1, "stamina": 12.0,
		"shape": "standard", "col_a": Color(0.91, 0.34, 0.17), "col_b": Color(1.0, 0.82, 0.67),
		"col_fin": Color(0.96, 0.78, 0.48), "glow": false, "kit_species": 6,
		"desc": "Донный сыщик с усами-хемосенсорами, копается в мягком песке.",
	},
]


## Дистанция заброса → зона. Мелководье ближе, глубина — дальше.
static func zone_for_distance(d: float) -> String:
	if d <= 13.0:
		return "shallow"
	if d <= 28.0:
		return "mid"
	return "deep"


static func zone_label(zone: String) -> String:
	match zone:
		"shallow":
			return "мелководье"
		"mid":
			return "отмель"
		_:
			return "глубина"


## Время суток из ночного ползунка (0 — золотой час, 1 — глубокая ночь).
static func time_segment(night01: float) -> String:
	if night01 < 0.24:
		return "day"
	if night01 < 0.58:
		return "dusk"
	return "night"


static func time_label(segment: String) -> String:
	match segment:
		"day":
			return "день"
		"dusk":
			return "закат"
		_:
			return "ночь"


static func rarity_of(id: String) -> Dictionary:
	var r: Dictionary = RARITY.get(id, RARITY["common"])
	return r


## Стартовые снасти (в будущем — магазин/прогрессия из tideline).
static func default_stats() -> Dictionary:
	return {
		"cast_mult": 1.0, # длина заброса
		"reel": 1.0,      # скорость подмотки
		"line": 1.0,      # прочность лески
		"control": 1.0,   # контроль в рывок
		"bite_speed": 1.0, # множитель ожидания (меньше — быстрее)
	}


## Вес вида при текущей зоне/времени. Не в своей зоне — почти не клюёт,
## не в своё время — редко (но шанс есть). Так игрок может «переждать»
## и получить другой набор рыб.
static func _weight(sp: Dictionary, zone: String, segment: String) -> float:
	var zones: Array = sp["zones"]
	var times: Array = sp["times"]
	var w: float = sp["base"]
	if not zones.has(zone):
		w *= 0.16
	if not times.has(segment):
		w *= 0.22
	return w


static func roll_species(zone: String, segment: String,
		rng: RandomNumberGenerator) -> Dictionary:
	var total := 0.0
	var weights: Array[float] = []
	for sp: Dictionary in SPECIES:
		var w := _weight(sp, zone, segment)
		weights.append(w)
		total += w
	var r := rng.randf() * total
	var acc := 0.0
	for i in range(SPECIES.size()):
		acc += weights[i]
		if r <= acc:
			return SPECIES[i]
	return SPECIES[0]


## Вид по id (для тестов/сценариев); пустой словарь, если такого нет.
static func find_species(id: String) -> Dictionary:
	for sp: Dictionary in SPECIES:
		if str(sp["id"]) == id:
			return sp
	return {}


## Полноценный экземпляр: размер, вес, цена, характер борьбы, окно подсечки.
static func roll_fish(zone: String, segment: String,
		rng: RandomNumberGenerator) -> Dictionary:
	return make_fish(roll_species(zone, segment, rng), rng)


static func make_fish(sp: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
	var rar_id: String = sp["rarity"]
	var rar: Dictionary = RARITY[rar_id]
	var sizes: Array = sp["size_cm"]
	var min_s: float = sizes[0]
	var max_s: float = sizes[1]
	# к крупным особям — редкий шанс (степень 1.8 смещает к мелочи)
	var size_cm: float = roundf(lerpf(min_s, max_s, pow(rng.randf(), 1.8)) * 10.0) / 10.0
	var mid: float = (min_s + max_s) * 0.5
	var ratio: float = size_cm / mid
	var weight_kg: float = maxf(0.01, float(sp["weight_mid"]) * pow(ratio, 2.9))
	var value: int = int(roundf(float(sp["value"]) * (0.45 + 0.55 * pow(ratio, 2.2))))
	var size_norm: float = (size_cm - min_s) / maxf(max_s - min_s, 0.001)
	return {
		"id": sp["id"],
		"name": sp["name"],
		"rarity": rar_id,
		"rarity_label": rar["label"],
		"rarity_color": rar["color"],
		"stars": rar["stars"],
		"size_cm": size_cm,
		"weight_kg": roundf(weight_kg * 100.0) / 100.0,
		"value": value,
		"xp": int(rar["xp"]),
		"size_norm": size_norm,
		"fight": {
			"strength": float(sp["strength"]) * (0.85 + 0.35 * size_norm),
			"surge_every": sp["surge"],
			"heft": float(sp["heft"]),
			"stamina": float(sp["stamina"]),
		},
		"hook_window": 1.05 * float(rar["hook_mult"]),
		"shape": sp["shape"],
		"kit_species": int(sp.get("kit_species", -1)),
		"col_a": sp["col_a"],
		"col_b": sp["col_b"],
		"col_fin": sp["col_fin"],
		"glow": sp["glow"],
		"desc": sp["desc"],
	}


## Ожидание поклёвки: 4.5–13 с, с поправкой на зону, время и ветер.
static func roll_wait(zone: String, segment: String, wind: float,
		rng: RandomNumberGenerator) -> float:
	var w := rng.randf_range(4.5, 13.0)
	if zone == "deep":
		w *= 1.15
	elif zone == "shallow":
		w *= 0.90
	if segment == "night":
		w *= 1.12
	# на ветру рыба смелее берёт приманку (волны прячут рыбака)
	w *= lerpf(1.10, 0.90, clampf((wind - 0.8) / 0.5, 0.0, 1.0))
	return clampf(w, 3.0, 22.0)
