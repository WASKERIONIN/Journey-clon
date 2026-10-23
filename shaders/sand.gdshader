shader_type spatial;
// Материал участвует в настоящем освещении Forward+: тени, SSAO/SSIL,
// фонарь и volumetric fog. Раньше unshaded делал дюны неизбежно плоскими.
render_mode diffuse_burley, specular_schlick_ggx;

// =====================================================================
// Шейдер песка — сердце игры.
// По мотивам доклада GDC «Sand Rendering in Journey» и разбора Alan Zucconi.
// Всё считается во фрагменте по мировым координатам — текстур почти нет.
//
// Настоящий песок: карта смещений (R32F, тор) от SandField реально
// изгибает геометрию (vertex) и даёт настоящие нормали (fragment):
// стенки следов ловят солнце, валы выброшенного песка светятся,
// дно следа темнеет и холоднеет. Никаких «нарисованных» следов.
// =====================================================================

// ---- Палитра (глава 1: тёплые дюны на закате) ----
uniform vec3 sun_dir = vec3(0.10, 0.26, -0.96); // к солнцу (туда же уходит путь)
uniform vec3 sand_sunny : source_color = vec3(0.93, 0.52, 0.30);
uniform vec3 sand_hot : source_color = vec3(1.00, 0.68, 0.36);
uniform vec3 sand_shade : source_color = vec3(0.40, 0.32, 0.52);
uniform vec3 horizon_col : source_color = vec3(0.96, 0.66, 0.55);
uniform vec3 sky_col : source_color = vec3(0.28, 0.24, 0.43);
uniform float fog_distance = 340.0;

// ---- Ветер: один вектор для ряби и струй ----
uniform vec2 wind_dir = vec2(0.32, -0.95); // нормализуется внутри
uniform float wind_power = 1.0;

uniform float glitter_amount = 0.20; // доля блестящих песчинок
uniform float night_amount : hint_range(0.0, 1.0) = 0.0;
uniform float shadow_star_intensity : hint_range(0.0, 2.5) = 2.5;
uniform float shadow_star_density : hint_range(0.15, 0.98) = 0.30;
uniform float sea_swell = 0.055; // дыхание моря — как в water.gdshader

// Общий переключатель прямого света Proxima + Schlick-GGX (A/B).
uniform float proxima_test = 0.0;
uniform float proxima_specular_strength = 0.55;
uniform vec3 proxima_diffuse_fresnel_tint = vec3(1.0);
uniform float proxima_diffuse_fresnel = 1.0;
uniform float proxima_diffuse_fresnel_falloff = 0.75;
uniform float proxima_diffuse_tangent_falloff = 0.75;
uniform vec3 proxima_retroreflection_tint = vec3(1.0);
uniform float proxima_retroreflection = 1.0;
uniform float proxima_retroreflection_falloff = 0.75;
uniform float proxima_retroreflection_tangent_falloff = 0.75;
uniform float proxima_specular_fresnel_falloff = 0.5;
uniform float proxima_smooth_terminator = 0.0;
uniform float proxima_smooth_terminator_length = 0.5;


// ---- Урез воды: мокрая полоса и подводный песок ----
// Море лежит плоско на sea_level; там, где песок выше — вода спрятана
// depth-тестом. Мокрую полосу и подводный песок красит этот же шейдер:
// у уреза песок темнее, холоднее и глянцевее, искры гаснут.
uniform float sea_level = 0.0;   // мировой Y уровня моря
uniform sampler2D shore_lut : filter_linear, repeat_disable;
uniform float shore_lut_z_min = -460.0;
uniform float shore_lut_z_max = 460.0;
uniform vec2 shadow_star_focus = vec2(0.0);
uniform float shadow_star_radius = 0.0;
uniform float wet_band = 0.16;   // ВЫСОТА над водой (м), где песок ещё мокрый
uniform float wet_darken = 0.44; // сила мокрого затемнения

// ---- Настоящий песок: карта смещений ----
uniform sampler2D sand_map : filter_linear, repeat_enable;
uniform vec2 sand_origin = vec2(0.0, 0.0); // мировой угол окна карты (x, z)
uniform float sand_texel = 0.12;           // метров на тексель
uniform float sand_edge = 40.0;            // текселей мягкого заноса у края окна

varying vec3 w_pos;
varying vec3 w_normal;
varying vec2 v_dune; // x — 0..1 высота дюны (приходит из геометрии через UV2)

const float SAND_N = 800.0; // сторона карты в текселях

// ---- детерминированный хеш и value-noise ----
float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	vec3 q = p3.yzx + vec3(33.33);
	p3 += vec3(dot(p3, q));
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash12(i);
	float b = hash12(i + vec2(1.0, 0.0));
	float c = hash12(i + vec2(0.0, 1.0));
	float d = hash12(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// Смещение песка в мировой точке. Карта — тор: глобальные тексельные
// координаты заворачиваются mod(N), REPEAT склеивает шов. У края окна
// след плавно «заносится ветром» (за окном песок нетронут).
float sand_h(vec2 wp) {
	vec2 g = wp / sand_texel;               // глобальные непрерывные тексели
	vec2 l = g - sand_origin / sand_texel;  // локальные в окне [0..N]
	vec2 uv = (mod(floor(g), SAND_N) + fract(g)) / SAND_N;
	float m = min(min(l.x, l.y), SAND_N - max(l.x, l.y)); // текселей до края
	float edge = smoothstep(0.0, sand_edge, m);
	return texture(sand_map, uv).r * edge;
}

// Фаза мега-ряби (слой 2): одинакова в vertex (высота) и fragment (нормаль)
float mega_phase(vec2 wp, vec2 wdir, vec2 wperp) {
	float u = dot(wp, wdir);
	float v = dot(wp, wperp);
	float rn = vnoise(wp * 0.15);
	float rn2 = vnoise(wp * 0.07 + vec2(9.1, 3.3)); // вторая октава варпа
	return v * 0.70 + u * 0.16 + rn * 2.6 + rn2 * 3.4 + TIME * 0.25;
}

void vertex() {
	w_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// песок реально проминается: смещаем вершину по карте (слой 3)
	float h = sand_h(w_pos.xz);
	// слой 2 (как в Journey): мега-рябь — НАСТОЯЩАЯ геометрия,
	// волны ~9 м гребнями поперёк ветра, медленно ползут по ветру
	vec2 wdir_v = normalize(wind_dir);
	vec2 wperp_v = vec2(-wdir_v.y, wdir_v.x);
	float mph = mega_phase(w_pos.xz, wdir_v, wperp_v);
	// Волновая геометрическая рябь отключена: формы берега задаёт Coast.
	VERTEX.y += h;
	w_pos.y += h;
	w_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_dune = UV2;
}

void fragment() {
	vec2 wp = w_pos.xz;
	vec2 wdir = normalize(wind_dir);
	vec2 wperp = vec2(-wdir.y, wdir.x);

	vec3 L = normalize(sun_dir);
	vec3 N = normalize(w_normal);

	// Дистанция до фрагмента: мелкая деталь гаснет с расстоянием,
	// чтобы дюны оставались шелковистыми, а не рябило муаром.
	float dist = length(CAMERA_POSITION_WORLD - w_pos);
	float detail = exp(-dist * 0.030);

	// ---------- 0. Настоящий песок: карта смещений ----------
	// Градиент карты — это настоящий рельеф: стенки следов и валы.
	float t = sand_texel;
	float h = sand_h(wp);
	float hx1 = sand_h(wp + vec2(t, 0.0));
	float hx0 = sand_h(wp - vec2(t, 0.0));
	float hz1 = sand_h(wp + vec2(0.0, t));
	float hz0 = sand_h(wp - vec2(0.0, t));
	vec2 sgrad = vec2(hx1 - hx0, hz1 - hz0) / (2.0 * t);
	float churn = clamp(abs(h) * 10.0, 0.0, 1.0); // потревоженный песок
	N = normalize(N - vec3(sgrad.x, 0.0, sgrad.y));
	// Фазу ветра используем только для движения мокрой каймы;
	// на самой суше волновые нормали и полосы не рисуются.
	float mph = mega_phase(wp, wdir, wperp);

	// ---------- 2. Свет: солнце + небо + отблеск (три источника) ----------
	// Главный мотив тот же (тёплый склон к солнцу / сиреневая тень),
	// но тень теперь живая: сверху её заливает сиреневое небо,
	// снизу греет тёплый отблеск, отскочивший от соседних дюн.
	float ndl = dot(N, L);
	float crest = smoothstep(0.60, 0.95, v_dune.x);        // гребни дюн
	float hollow = 1.0 - smoothstep(0.10, 0.38, v_dune.x); // ложбины
	// запечённое ambient occlusion дюн (горизонтный AO по карте высот):
	// ложбины и подножия темнее, гребни открыты небу — форма объёма
	// читается с ЛЮБОГО ракурса, без SSAO
	float ao = mix(0.55, 1.0, clamp(v_dune.y, 0.0, 1.0));

	// ключевой свет: солнце с мягким переносом через кромку (wrap).
	// Порог освещённости щедрый: золотая сторона дюны занимает кадр,
	// сирень остаётся только глубокой тенью.
	float wrap = clamp((ndl + 0.45) / 1.05, 0.0, 1.0);
	vec3 base = mix(sand_shade, sand_sunny, smoothstep(0.0, 0.68, wrap));
	base = mix(base, sand_hot, pow(wrap, 2.0) * (0.35 + 0.50 * crest));
	// солнечная кромка: склоны, отвесные к солнцу, светятся изнутри
	base += vec3(1.0, 0.62, 0.34) * pow(clamp(ndl, 0.0, 1.0), 2.2) * 0.16;
	// прямое солнце AO почти не слушается, полусфера — целиком
	base *= mix(1.0, ao, 0.32);
	// заливка неба: сиреневая прохлада на теневых склонах
	base += sand_shade * clamp(N.y, 0.0, 1.0) * 0.22 * ao * (1.0 - wrap);
	// отблеск песка: тёплый свет, отскочивший от дюн, греет тень
	vec3 B = normalize(vec3(-L.x, 0.55, -L.z));
	base += vec3(1.00, 0.58, 0.32) * clamp(dot(N, B), 0.0, 1.0) * 0.28 * ao * (1.0 - wrap * 0.6);
	// ложбины — прохладнее тоном (глубину уже дал AO)
	base = mix(base, sand_shade, hollow * 0.18);
	// крупный тональный шум: дюны не одинаковые
	base *= mix(0.92, 1.07, vnoise(wp * 0.013 + vec2(3.1, 7.7)));
	// Мелкое зерно сохраняет фактуру песка без ветровых полос.
	base *= 1.0 + (vnoise(wp * 2.7) - 0.5) * 0.08 * detail;

	// ---------- 2a. Урез: прибой ----------
	// Высота воды в точке — ТА ЖЕ формула, что в vertex water.gdshader:
	// море дышит, и мокрая кайма ползёт по пляжу вместе с ним.
	float swash = (cos(mph) * 0.62 + cos(mph * 2.63 + 1.7) * 0.30
		+ cos(mph * 0.47 + 0.8) * 0.22) * sea_swell * wind_power;
	float above_sea = w_pos.y - (sea_level + swash);
	float wob = vnoise(wp * 0.35 + vec2(4.1, 8.3));
	// мокрая полоса: узкая, с рваным волокнистым краем
	float wet = 1.0 - smoothstep(-0.02, wet_band * (0.65 + 0.7 * wob), above_sea);
	wet *= 0.72 + 0.28 * wob;
	float sub = 1.0 - smoothstep(-1.6, 0.0, above_sea);
	// пена: узкая светлая кайма на самой кромке, вспенивается пятнами.
	// Полоса не должна читаться «лентой»: пятна рвут её на куски.
	float fw = 0.025 + 0.045 * vnoise(wp * 1.9 + vec2(2.0, 5.0));
	float foam = 1.0 - smoothstep(0.0, fw, abs(above_sea - 0.01));
	foam *= smoothstep(0.25, 0.75, vnoise(wp * 2.6 + vec2(TIME * 0.5, 0.0)));
	foam *= wet * (0.30 + 0.35 * vnoise(wp * 3.1 + vec2(TIME * 0.6, 0.0)));

	// ---------- 2b. След: настоящий рельеф красится как настоящий ----------
	float press = clamp(-h * 12.0, 0.0, 1.0); // дно следа
	float rise = clamp(h * 18.0, 0.0, 1.0);   // вал выброшенного песка
	// дно: свежий песок под песком — ТОТ ЖЕ цвет, лишь чуть плотнее;
	// глубину рисуют собственные нормали выемки, а не тёмная краска
	base = mix(base, base * vec3(0.92, 0.90, 0.99), press * 0.30);
	// вал: свежий сухой песок — светлее и теплее
	base = mix(base, base * vec3(1.18, 1.07, 0.88), rise * 0.5);
	// мокрый песок: темнее и холоднее, подводный — глуше и синее
	// мокрый песок — тот же тёплый песок, только плотнее и темнее; никакой
	// синевы (синева — признак воды, она теперь у моря, а не у берега)
	base = mix(base, base * vec3(0.62, 0.55, 0.50), wet * wet_darken);
	base = mix(base, base * vec3(0.34, 0.40, 0.48), sub * 0.55);
	// прибойная пена — тёплый свет, не белая краска
	base = mix(base, vec3(0.94, 0.90, 0.84), clamp(foam * 0.55, 0.0, 0.42));

	// ---------- 3. Глиттер (микрофасеты, по мотивам Zucconi) ----------
	// «Песчинки» размером с пиксель (LOD по дистанции). ДВА лба:
	//   • солнечный — искра вспыхивает ярче, когда солнце в кадре;
	//   • небесный — зерно ловит САМУ КАМЕРУ: песок сверкает и когда
	//     летишь боком, и когда солнце за спиной (как в Journey).
	vec3 V = normalize(CAMERA_POSITION_WORLD - w_pos);
	vec3 H = normalize(V + L);
	// LOD «мип-уровнями»: плотность меняется СТУПЕНЯМИ (3·2^k клеток/м) —
	// сетка прибита к миру. Непрерывный пересчёт от дистанции заставлял
	// блёстки «плыть» и растягиваться в шлейф при движении камеры.
	float need = 900.0 / max(dist, 0.001);
	float density = clamp(pow(2.0, floor(log2(need / 3.0))) * 3.0, 6.0, 130.0);
	vec2 celluv = floor(wp * density);
	float cellid = hash12(celluv);
	float cellb = hash12(celluv + vec2(7.31, 1.77));
	float cellc = fract(cellid * 13.7);
	// «зеркало» песчинки: ВЕРХНЯЯ полусфера, азимут равномерный —
	// никакого предпочтения по сторонам света (ошибка была именно тут:
	// мировое смещение делало блёстки видимыми только в одну сторону).
	vec3 G = normalize(vec3(cellid - 0.5, 0.05 + 0.95 * cellb, cellc - 0.5));
	// солнечный блик (half-vector, шевелится от зерна к зерну)
	vec3 Hg = normalize(H + vec3(cellid - 0.5, cellb - 0.5, cellc - 0.5) * 0.55);
	float sun_lobe = pow(clamp(dot(N, Hg), 0.0, 1.0), mix(22.0, 80.0, cellb));
	// небесный блик: зерно поймало взгляд — работает в ЛЮБОМ направлении
	float sky_lobe = pow(clamp(dot(G, V), 0.0, 1.0), mix(20.0, 70.0, cellc));
	// вдаль искр меньше — далеко не «ковёр», а редкие вспышки
	float glint = step(1.0 - glitter_amount * exp(-dist * 0.0035), cellid);
	float rate = mix(2.0, 8.0, cellb);
	glint *= 0.40 + 0.60 * (0.5 + 0.5 * sin(TIME * rate + cellid * 71.0));
	glint *= 1.0 - 0.85 * churn; // потревоженный песок почти не сверкает
	float glit_fade = exp(-dist * 0.004); // искры живут далеко, до горизонта
	glint *= 1.0 - 0.85 * wet; // мокрый песок не сверкает
	glint *= 1.0 - smoothstep(0.12, 0.82, night_amount); // ночью оставляем только искры в тенях
	// искры бьют сильно (2+ единицы) — даже на ярком песке после
	// Filmic-тонмаппинга они остаются точками, а glow даёт им ореол
	base += vec3(1.0, 0.92, 0.70) * (sun_lobe * 2.0 + sky_lobe * 2.2)
		* glint * glit_fade * mix(0.75, 1.0, ao);
	// шёлковый отблеск с ФРЕНЕЛЕМ (PBR-отклик): у кромки дюн, под скользящим
	// взглядом, песок «мокро» блестит сильнее — независимо от солнца
	// шёлк живёт только вблизи: на дальних дюнах скользящий отблеск
	// выжигал песок в белую пелену — глиттеру негде было вспыхивать
	float near_gloss = exp(-dist * 0.012);
	float fres = 0.35 + 0.65 * pow(1.0 - clamp(dot(N, V), 0.0, 1.0), 3.0);
	float sheen = pow(clamp(dot(N, H), 0.0, 1.0), 16.0) * 0.7
		+ pow(clamp(dot(N, H), 0.0, 1.0), 48.0) * 0.3;
	base += vec3(1.0, 0.72, 0.45) * sheen * fres * 0.045 * near_gloss
		* smoothstep(0.0, 0.5, wrap) * (1.0 - churn * 0.5);
	// скользящий ракурс: ближний песок у кромки дюны слегка рдеет
	base += vec3(0.90, 0.55, 0.35) * (fres - 0.35) * 0.10 * ao * near_gloss;

	// ---------- 4. Дымка к горизонту ----------
	float fog = 1.0 - exp(-pow(dist / fog_distance, 2.1));
	float above = smoothstep(-2.0, 16.0, w_pos.y - CAMERA_POSITION_WORLD.y);
	vec3 fcol = mix(horizon_col, sky_col, above * 0.6);

	// ---------- 4a. Ночная луна ----------
	// Глубокой ночью небесный ambient почти чёрный, а прямое солнце у
	// горизонта гаснет и самозатеняется: тёмная альбедо × тёмный свет =
	// ЧЁРНАЯ суша, по которой нельзя ходить. Лунный ключ печём в EMISSION:
	// его не умножает свет и не гасят тени — дюны ночью читаются с любого
	// ракурса, а форма остаётся запечённой в base (wrap + AO).
	float nightk = smoothstep(0.35, 0.85, night_amount);
	if (nightk > 0.0) {
		vec3 md = normalize(vec3(L.x, 0.55, L.z)); // луна над стороной солнца
		float mnl = clamp(dot(N, md) * 0.5 + 0.5, 0.0, 1.0);
		EMISSION = base * (0.55 + 0.40 * mnl) * nightk * (1.0 - fog);
	}

	ALBEDO = mix(base, fcol, fog);
	// Аналитическая нормаль следов и ряби теперь питает реальный BRDF,
	// поэтому фонарь скользит по гребням, а впадины получают контактную тень.
	NORMAL = normalize((VIEW_MATRIX * vec4(N, 0.0)).xyz);
	ROUGHNESS = mix(0.95, 0.80, clamp(fres, 0.0, 1.0)) + churn * 0.05
		- wet * 0.16;
	SPECULAR = 0.16;
	METALLIC = 0.0;
}

// Адаптация формул Proxima Diffuse + Schlick-GGX для материалов моря и песка (переключатель глобального A/B).
// Источник: ElSuicio, 2026; MIT, godotshaders.com/shader/
// proxima-ggx-the-callisto-protocol-light-model/.
// Copyright (c) 2026 ElSuicio. Permission is hereby granted, free of charge,
// to any person obtaining a copy of this software and associated files, to
// deal in the Software without restriction, including without limitation the
// rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
// sell copies, subject to inclusion of this copyright and permission notice.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
float proxima_h(float ctheta, float n, float cphi, float m) {
	return clamp(pow(max(1.0 - ctheta, 0.0), 5.0 * n)
		* pow(max(cphi, 0.0), 5.0 * m), 0.0, 1.0);
}

float proxima_r(float x) {
	return 2.0 * (1.0 - x);
}

float proxima_t(float x) {
	return clamp(x, 0.0, 1.0);
}

float shadow_star_shape(vec2 delta, float angle) {
	vec2 axis = vec2(cos(angle) * delta.x - sin(angle) * delta.y,
		sin(angle) * delta.x + cos(angle) * delta.y);
	float core = exp(-length(axis) * 28.0);
	float ray_x = exp(-abs(axis.x) * 13.0 - abs(axis.y) * 52.0);
	float ray_z = exp(-abs(axis.y) * 13.0 - abs(axis.x) * 52.0);
	return max(core, max(ray_x, ray_z) * 0.62);
}

// Россыпь звёзд в мировой сетке: крошечное ядро + мягкий ореол,
// мерцание от hash-фазы. Клетки прибиты к миру — звёзды не ездят с камерой.
vec3 shadow_star_field(vec2 xz, float scale, float seed) {
	vec2 sp = xz * scale;
	vec2 cell = floor(sp);
	vec2 local = fract(sp) - 0.5;
	float sid = hash12(cell + seed);
	float has = step(mix(0.94, 0.55, shadow_star_density), sid);
	vec2 off = (vec2(hash12(cell + seed + 1.31),
		hash12(cell + seed + 7.73)) - 0.5) * 0.62;
	float d = length(local - off);
	float tw = 0.55 + 0.45 * sin(TIME * (1.1 + sid * 2.6) + sid * 91.0);
	float core = exp(-d * d * 620.0);
	float halo = exp(-d * d * 70.0) * 0.10;
	vec3 tint = mix(vec3(0.80, 0.90, 1.05), vec3(1.05, 0.98, 0.86),
		hash12(cell + seed + 4.27));
	return tint * (core + halo) * has * tw;
}

void light() {
	vec3 n = normalize(NORMAL);
	vec3 l = normalize(LIGHT);
	vec3 v = normalize(VIEW);
	float nl = max(dot(n, l), 0.0);
	float nv = clamp(dot(n, v), 1e-3, 1.0);
	// ЗВЁЗДЫ В ТЕНЯХ — ТОЛЬКО в отброшенной тени от предметов (причал,
	// камни): ни тёмных склонов дюн, ни дневного света. Звёзды прибиты
	// к мировой сетке и не ездят с камерой.
	float cast_shadow = smoothstep(0.55, 0.88, 1.0 - clamp(ATTENUATION, 0.0, 1.0));
	float shore_u = clamp((w_pos.z - shore_lut_z_min)
		/ (shore_lut_z_max - shore_lut_z_min), 0.0, 1.0);
	float shore_x = texture(shore_lut, vec2(shore_u, 0.5)).r;
	float dry_sand = smoothstep(0.0, 1.5, w_pos.x - shore_x);
	// днём звёзд нет вообще — тень становится звёздной только к ночи
	float star_night = smoothstep(0.30, 0.80, night_amount);
	// звёзды — только на РОВНОМ песке и неподалёку: тени от предметов и
	// строений падают на плоское, а склоны при низком солнце покрыты
	// акне карты теней — звёзды там рисовали «полигональную сетку»
	float flat_g = smoothstep(0.78, 0.95, w_normal.y);
	float near_f = exp(-length(CAMERA_POSITION_WORLD - w_pos) * 0.010);
	// два масштаба: крупные редкие + мелкая россыпь
	vec3 field = shadow_star_field(w_pos.xz, 2.1, 0.0) * 1.25
		+ shadow_star_field(w_pos.xz, 5.3, 11.7) * 0.85;
	// Созвездие рыбака — четыре крупные звёзды вокруг квестодателя.
	float focus_dist = distance(w_pos.xz, shadow_star_focus);
	float star_zone = 1.0 - smoothstep(shadow_star_radius - 0.6,
		shadow_star_radius + 0.6, focus_dist);
	vec2 shadow_dir = normalize(-l.xz);
	vec2 shadow_side = vec2(-shadow_dir.y, shadow_dir.x);
	vec2 star_p1 = shadow_star_focus - shadow_side * 0.55 + shadow_dir * 0.50;
	vec2 star_p2 = shadow_star_focus + shadow_side * 0.47 + shadow_dir * 0.42;
	vec2 star_p3 = shadow_star_focus - shadow_side * 0.38 - shadow_dir * 0.38;
	vec2 star_p4 = shadow_star_focus + shadow_side * 0.61 - shadow_dir * 0.58;
	float constellation = shadow_star_shape(w_pos.xz - star_p1, 0.35)
		* step(shadow_star_density, hash12(vec2(17.1, 2.4)));
	constellation = max(constellation, shadow_star_shape(w_pos.xz - star_p2, 1.20)
		* step(shadow_star_density, hash12(vec2(31.8, 8.7))));
	constellation = max(constellation, shadow_star_shape(w_pos.xz - star_p3, 2.10)
		* step(shadow_star_density, hash12(vec2(9.2, 47.3))));
	constellation = max(constellation, shadow_star_shape(w_pos.xz - star_p4, 0.78)
		* step(shadow_star_density, hash12(vec2(53.7, 16.5))));
	DIFFUSE_LIGHT += vec3(1.65, 1.90, 2.40)
		* (field + constellation * star_zone * 1.6)
		* cast_shadow * dry_sand * star_night * flat_g * near_f
		* shadow_star_intensity;
	if (nl > 0.0) {
	vec3 h = normalize(v + l);
	float nh = clamp(dot(h, n), 0.0, 1.0);
	float hl = clamp(dot(h, l), 0.0, 1.0);
	vec3 radiance = LIGHT_COLOR * ATTENUATION;

	if (proxima_test < 0.5) {
		// Обычный Schlick-GGX для базового сравнения.
		float a = max(ROUGHNESS * ROUGHNESS, 0.002);
		float a2 = a * a;
		float q = 1.0 + (a2 - 1.0) * nh * nh;
		float d = a2 / (PI * q * q);
		float k = pow(ROUGHNESS + 1.0, 2.0) * 0.125;
		float gl = nl / (nl * (1.0 - k) + k);
		float gv = nv / (nv * (1.0 - k) + k);
		vec3 f0 = mix(vec3(0.08 * 0.16), ALBEDO, METALLIC);
		vec3 f = f0 + (1.0 - f0) * pow(1.0 - hl, 5.0);
		float fd90 = 0.5 + 2.0 * ROUGHNESS * hl * hl;
		float burley_l = 1.0 + (fd90 - 1.0) * pow(1.0 - nl, 5.0);
		float burley_v = 1.0 + (fd90 - 1.0) * pow(1.0 - nv, 5.0);
		DIFFUSE_LIGHT += radiance * ALBEDO * (1.0 / PI)
			* burley_l * burley_v * nl;
		SPECULAR_LIGHT += radiance * d * gl * gv * f / max(4.0 * nl * nv, 1e-3);
	} else {
	// Diffuse Proxima: Fresnel tint, retroreflection и smooth terminator.
	float alpha = ROUGHNESS * ROUGHNESS;
	float alpha2 = alpha * alpha;
	float vdl = max(dot(-v, l), 0.0);
	float theta_h = acos(nh);
	float theta_d = acos(hl);
	float alpha_f = proxima_h(hl, proxima_r(proxima_diffuse_fresnel_falloff),
		nh, proxima_r(proxima_diffuse_tangent_falloff));
	float alpha_r = proxima_h(nh, proxima_r(proxima_retroreflection_falloff),
		hl, proxima_r(proxima_retroreflection_tangent_falloff));
	float alpha_s = (1.0 - pow(1.0 - theta_d, 3.0))
		* (1.0 - pow(1.0 - theta_h, 3.0));
	vec3 rho_f = proxima_diffuse_fresnel * proxima_diffuse_fresnel_tint;
	vec3 rho_r = proxima_retroreflection * proxima_retroreflection_tint;
	vec3 c1 = mix(vec3(1.0), rho_f, alpha_f)
		* mix(vec3(1.0), rho_r, alpha_r);
	float smooth_term = mix(1.0, smoothstep(0.0,
		max(alpha_s * proxima_smooth_terminator_length, 1e-4), nl),
		alpha_s * proxima_smooth_terminator);
	vec3 fd = c1 * (1.0 / PI)
		* (alpha * (-0.55 + 0.19 / max(nl, 1e-3))
		* (1.0 - sqrt(vdl)) + 1.0) * smooth_term * nl;

	// Specular Trowbridge-Reitz GGX + Smith + Schlick Fresnel.
	float t = 1.0 + (alpha2 - 1.0) * nh * nh;
	float d = alpha2 / (PI * t * t);
	float gl = 1.0 / (nl + sqrt(alpha2 + (1.0 - alpha2) * nl * nl));
	float gv = 1.0 / (nv + sqrt(alpha2 + (1.0 - alpha2) * nv * nv));
	vec3 f0 = mix(vec3(proxima_specular_strength * 0.08), ALBEDO, vec3(METALLIC));
	float fh = pow(clamp(1.0 - hl, 0.0, 1.0),
		5.0 * proxima_r(proxima_specular_fresnel_falloff));
	vec3 fresnel = f0 + proxima_t(2.0
		- proxima_r(proxima_specular_fresnel_falloff)) * (1.0 - f0) * fh;
	vec3 fs = d * gl * gv * fresnel * nl;
	DIFFUSE_LIGHT += radiance * fd;
	SPECULAR_LIGHT += radiance * fs;
	}
	}
}
