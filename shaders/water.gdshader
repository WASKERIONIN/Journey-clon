shader_type spatial;
// МОРЕ — отдельная стихия рядом с тёплым песком.
//
// Палитра намеренно НЕ песочная: мелководье — бирюза, глубина — синий
// индиго, под скользящим взглядом поверхность зеркалит небо и ловит
// солнечную дорожку. Поэтому суша и вода читаются как два разных
// материала даже на горизонте.
//
// Урез. Море получает от Coast карту высот поверхности (height_tex) —
// ровно ту, по которой построен меш берега. По ней:
//   • глубина честная и считается ПО ФРАГМЕНТУ (высота воды минус
//     высота песка в этом пикселе), поэтому кромка — ровная линия по
//     рельефу, а не граница треугольников;
//   • поверхность воды — ровная плоскость (море + дыхание), она
//     пересекает песок по мокрой кайме; никакой «плёнки», висящей над
//     бугристым пляжем, поэтому нет ни лоскутов, ни пластин;
//   • дыхание моря затухает к кромке, зато накат ползёт по пляжу;
//   • альфа растёт от нуля по глубине — переход вода↔суша плавный;
//   • пена двумя полосами по контуру глубины с рваным шумом.
//
// Кольца событий (всплеск поплавка, поклёвка, подмотка) — единственный
// «водный» слой, который отвечает на действия игрока.

render_mode diffuse_burley, specular_schlick_ggx, blend_mix, depth_draw_always;

// ---- Вода: своя палитра, не песок ----
uniform vec3 water_shallow : source_color = vec3(0.30, 0.66, 0.62);
uniform vec3 water_mid : source_color = vec3(0.10, 0.38, 0.48);
uniform vec3 water_deep : source_color = vec3(0.035, 0.150, 0.300);
uniform vec3 foam_col : source_color = vec3(0.95, 0.92, 0.86);
uniform vec3 sun_col : source_color = vec3(1.0, 0.80, 0.52);
uniform vec3 sun_dir = vec3(0.10, 0.26, -0.96); // к солнцу (как у песка)

// ---- Небо/дымка (общие с песком) ----
uniform vec3 horizon_col : source_color = vec3(0.96, 0.66, 0.55);
uniform vec3 sky_col : source_color = vec3(0.28, 0.24, 0.43);
uniform float fog_distance = 340.0;

// ---- Ветер: один вектор на всю игру ----
uniform vec2 wind_dir = vec2(0.32, -0.95);
uniform float wind_power = 1.0;

// ---- Дыхание моря: та же мега-рябь, что у песка (слой 2, ~9 м) ----
uniform float mega_amp = 0.055;

// ---- Мелкая рябь (только нормали) ----
uniform float ripple_freq = 1.35;
uniform float ripple_speed = 1.1;
uniform float ripple_strength = 0.34;
uniform float glitter_amount = 1.0; // общий мелкий глиттер поверхности
uniform float solar_glitter_amount = 1.0; // отдельные частицы солнечной дорожки
uniform float night_amount : hint_range(0.0, 1.0) = 0.0; // 0=день, 1=ночь
// Временный A/B-тест прямого света: Proxima diffuse + Schlick-GGX.
// По умолчанию выключен, солнечный глиттер от него не зависит.
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

// ---- Кольца событий ----
uniform float ring_amp = 0.055;
uniform float ring_speed = 1.5;
uniform float ring_len = 0.85;
uniform float ring_tau = 0.55;
uniform float ring_w0 = 0.30;
uniform float ring_wg = 0.18;
uniform float ring_boost = 1.4;

uniform float u_time = 0.0;

// ---- Берег: карта высот и мягкий стык ----
uniform sampler2D ground_tex : filter_linear, repeat_disable;
uniform vec2 ground_origin = vec2(-280.0, -450.0);
uniform float ground_cell = 1.184;
uniform float ground_n = 761.0;
uniform float sea_level = 0.0;
uniform float shore_fade = 0.03; // м, мягкость стыка с предметами по depth

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform vec4 u_rings[24]; // x, z, t0, amp; amp <= 0.0005 — слот пуст

varying vec3 w_pos;

const float PI_2 = 6.28318530718;

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

float mega_phase(vec2 wp, vec2 wdir, vec2 wperp) {
	float u = dot(wp, wdir);
	float v = dot(wp, wperp);
	float rn = vnoise(wp * 0.15);
	float rn2 = vnoise(wp * 0.07 + vec2(9.1, 3.3));
	return v * 0.70 + u * 0.16 + rn * 2.6 + rn2 * 3.4 + u_time * 0.25;
}

float swell_of(float mph) {
	return cos(mph) * 0.62 + cos(mph * 2.63 + 1.7) * 0.30
		+ cos(mph * 0.47 + 0.8) * 0.22;
}

// Высота поверхности берега: билинейная выборка той же карты, что у меша.
float ground_at(vec2 wp) {
	vec2 uv = (wp - ground_origin) / (ground_cell * (ground_n - 1.0));
	if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) {
		return -6.0; // за картой — глубокое море
	}
	return texture(ground_tex, uv).r;
}

void vertex() {
	w_pos = (MODEL_MATRIX * vec4(VERTEX.x, VERTEX.y, VERTEX.z, 1.0)).xyz;
	vec2 wdir_v = normalize(wind_dir);
	vec2 wperp_v = vec2(-wdir_v.y, wdir_v.x);

	// Волна плавно затухает к урезу. Большая амплитуда в открытом море
	// не раскачивает shoreline-сэмплы и не рвёт кромку на треугольники.
	float ground = ground_at(w_pos.xz);
	float shore_depth = max(sea_level - ground, 0.0);
	float shore_t = clamp(shore_depth / 4.0, 0.0, 1.0);
	float shore_wave_fade = shore_t * shore_t * (3.0 - 2.0 * shore_t);
	float hrip = swell_of(mega_phase(w_pos.xz, wdir_v, wperp_v))
		* mega_amp * wind_power * shore_wave_fade;
	float y = hrip;

	VERTEX.y += y;
	w_pos.y += y;
}

void fragment() {
	vec2 wp = w_pos.xz;
	vec2 wdir = normalize(wind_dir);
	vec2 wperp = vec2(-wdir.y, wdir.x);

	// ---------- берег под водой ----------
	// Глубина считается ПО ФРАГМЕНТУ: поверхность моря минус высота
	// песка в этом пикселе; кромка не зависит от рёбер сетки воды.
	float ground = ground_at(wp);
	float depth_m = w_pos.y - ground;
	// Оставляем небольшой переход по обе стороны уреза, чтобы прозрачность
	// сгладила субпиксельные расхождения между картой высот и сеткой берега.
	if (depth_m < -0.35) {
		// Раньше отсечка стояла почти точно на урезе (-0.08), и видимая
		// кромка воды была ГРАНИЦЕЙ discard: она наследует шаг карты высот
		// и на экране выглядит ступеньками-«пикселями». Теперь discard
		// глубоко под сушей, а видимую кромку рисует плавная альфа.
		discard;
	}
	float near_shore = 1.0 - smoothstep(-0.08, 0.9, depth_m);
	float mph = mega_phase(wp, wdir, wperp);

	vec3 L = normalize(sun_dir);
	vec3 N = vec3(0.0, 1.0, 0.0);

	float dist = length(CAMERA_POSITION_WORLD - w_pos);
	float detail = exp(-dist * 0.030);

	// ---------- слой 2: дыхание моря ----------
	float ms1 = sin(mph);
	float ms2 = sin(mph * 2.63 + 1.7);
	float ms3 = sin(mph * 0.47 + 0.8);
	float mdv = (-0.62 * 0.70 * ms1 - 0.30 * 2.63 * 0.70 * ms2
		- 0.22 * 0.47 * 0.70 * ms3) * mega_amp;
	float mdu = (-0.62 * 0.16 * ms1 - 0.30 * 2.63 * 0.16 * ms2
		- 0.22 * 0.47 * 0.16 * ms3) * mega_amp;
	vec2 mgrad = (wperp * mdv + wdir * mdu) * wind_power;
	// вдали волны должны сливаться в ровное зеркало, иначе получаются
	// бесконечные параллельные полосы «кордуроем» до горизонта
	float mega_fade = mix(0.30, 1.0, exp(-dist * 0.010));
	N = normalize(N - vec3(mgrad.x, 0.0, mgrad.y) * 0.42
		* (1.0 - 0.92 * near_shore) * mega_fade);

	// ---------- слой 1: ветровая рябь из трёх поездов ----------
	// Один поезд давал «кордурой» — длинные параллельные полосы. Три
	// направления под углом друг к другу + шум дают живую поверхность.
	float n1 = vnoise(wp * 0.33);
	float n2 = vnoise(wp * 0.90 + vec2(17.0, 9.0));
	vec2 d1 = wdir;
	vec2 d2 = normalize(wdir + vec2(0.62, -0.55));
	vec2 d3 = normalize(wdir + vec2(-0.78, -0.30));
	float ph1 = dot(wp, d1) * ripple_freq + n1 * 5.0 + u_time * ripple_speed;
	float ph2 = dot(wp, d2) * ripple_freq * 1.9 + n2 * 4.0 + u_time * ripple_speed * 1.5;
	float ph3 = dot(wp, d3) * ripple_freq * 3.4 + n1 * 3.0 + u_time * ripple_speed * 2.3;
	vec2 wgrad = d1 * cos(ph1) * 0.55 + d2 * cos(ph2) * 0.36
		+ d3 * cos(ph3) * 0.24;
	float amp = 0.40 + 0.60 * vnoise(wp * 0.11 + vec2(3.7, 1.3));
	wgrad *= ripple_strength * wind_power * detail * amp
		* (1.0 - 0.88 * near_shore);
	N = normalize(N - vec3(wgrad.x, 0.0, wgrad.y) * 0.42);

	// ---------- кольца событий ----------
	float rk = PI_2 / ring_len;
	vec2 rgrad = vec2(0.0);
	for (int i = 0; i < 24; i++) {
		vec4 rg = u_rings[i];
		if (rg.w < 0.0005) {
			continue;
		}
		float age = u_time - rg.z;
		if (age < 0.0) {
			continue;
		}
		vec2 d = wp - rg.xy;
		float dd = max(length(d), 0.0001);
		float rf = ring_speed * age;
		float bw = ring_w0 + ring_wg * age;
		float x = (dd - rf) / bw;
		float env = exp(-x * x);
		float ph = rk * (dd - rf);
		float dec = exp(-age * ring_tau) / sqrt(max(rf, 0.6));
		float a = ring_amp * rg.w * dec;
		float dhdd = a * (env * (-2.0 * x / bw) * cos(ph) - env * sin(ph) * rk);
		rgrad += (d / dd) * dhdd;
	}
	N = normalize(N - vec3(rgrad.x * ring_boost, 0.0, rgrad.y * ring_boost));

	// ---------- цвет воды ----------
	vec3 base = mix(water_shallow, water_mid, smoothstep(0.0, 3.0, depth_m));
	base = mix(base, water_deep, smoothstep(1.0, 12.0, depth_m));
	base = mix(base, water_shallow * 1.22, near_shore * 0.45);
	float ndl = clamp(dot(N, L) * 0.5 + 0.5, 0.0, 1.0);
	base *= 0.80 + 0.32 * ndl;

	// ---------- френель: небо в воде ----------
	vec3 V = normalize(CAMERA_POSITION_WORLD - w_pos);
	vec3 R = reflect(-V, N);
	float fres = pow(1.0 - clamp(dot(N, V), 0.0, 1.0), 3.2);
	vec3 sky_ref = mix(horizon_col, sky_col, smoothstep(0.02, 0.42, R.y));
	// вода подкрашивает отражение в холод: тёплый закат не должен делать
	// море песочного цвета — иначе суша и вода сливаются на скользящем
	// ракурсе, где зеркало доминирует.
	sky_ref = mix(sky_ref, sky_ref * vec3(0.60, 0.80, 1.02), 0.62);
	// на скользящих ракурсах вода почти зеркалит небо — поэтому горизонт
	// светлый, а не тёмная полоса
	float mirror = clamp(0.05 + 0.92 * fres, 0.0, 0.88);
	mirror *= 1.0 - 0.18 * near_shore;
	base = mix(base, sky_ref, mirror);

	// Солнечный глиттер не обрывается у горизонта: ближние искры остаются
	// точечными, а вдали переходят в широкую мерцающую дорожку по солнцу.
	vec3 H = normalize(V + L);
	// Ночью та же дорожка — лунная: холодный блик вместо тёплого солнца.
	// Без этого единственный «свет» на воде ночью был тёплым пятном,
	// а сама вода уходила в чёрный.
	vec3 lit_col = mix(sun_col, vec3(0.68, 0.82, 1.15), night_amount);
	float far_glit = smoothstep(120.0, 900.0, dist);
	float need = 900.0 / max(dist, 0.001);
	float lod_density = pow(2.0, floor(log2(need / 3.0))) * 3.0;
	float density = clamp(lod_density, mix(6.0, 1.2, far_glit), 72.0);
	vec2 celluv = floor(wp * density);
	float cellid = hash12(celluv);
	float cellb = hash12(celluv + vec2(7.31, 1.77));
	float cellc = fract(cellid * 13.7);
	vec3 G = normalize(vec3(cellid - 0.5, 0.05 + 0.95 * cellb, cellc - 0.5));
	vec3 Hg = normalize(H + vec3(cellid - 0.5, cellb - 0.5, cellc - 0.5) * 0.55);
	float sun_lobe = pow(clamp(dot(N, Hg), 0.0, 1.0), mix(30.0, 110.0, cellb));
	float sky_lobe = pow(clamp(dot(G, V), 0.0, 1.0), mix(24.0, 80.0, cellc));
	float glit_chance = glitter_amount * mix(exp(-dist * 0.002), 0.42, far_glit);
	float glint = step(1.0 - glit_chance, cellid);
	float glit_fade = mix(exp(-dist * 0.0025), 0.38, far_glit)
		* (1.0 - 0.92 * near_shore);
	base += lit_col * (sun_lobe * 1.6 + sky_lobe * 0.26) * glint * glit_fade;

	float path_power = mix(180.0, 34.0, far_glit);
	float path = pow(clamp(dot(N, H), 0.0, 1.0), path_power);
	base += lit_col * path * 0.55 * (1.0 - 0.85 * near_shore);
	// СОЛНЕЧНЫЙ глиттер — не широкая полоса света: редкие отдельные
	// отражающие «частицы» собираются только в направлении солнечной дорожки.
	// Ячейки укрупняются вдаль, а размер искры держим в пикселях, чтобы
	// блики не исчезали на горизонте и не превращались в сплошную заливку.
	vec2 view_xz = V.xz / max(length(V.xz), 1e-4);
	vec2 sun_xz = L.xz / max(length(L.xz), 1e-4);
	float road_alignment = clamp(-dot(view_xz, sun_xz), 0.0, 1.0);
	float sun_road = pow(road_alignment, 8.0);
	float spark_cell_size = mix(3.2, 11.0, far_glit);
	vec2 spark_uv = wp / spark_cell_size;
	vec2 spark_cell = floor(spark_uv);
	vec2 spark_local = fract(spark_uv) - vec2(0.5);
	float spark_seed = hash12(spark_cell);
	vec2 spark_jitter = vec2(hash12(spark_cell + vec2(5.7, 2.3)),
		hash12(spark_cell + vec2(1.9, 8.1))) - vec2(0.5);
	vec2 spark_pos = (spark_local - spark_jitter * 0.54) * spark_cell_size;
	float pixel_world = max(0.35, dist * 2.0
		/ max(VIEWPORT_SIZE.y * PROJECTION_MATRIX[1][1], 1.0));
	float spark_radius = max(0.55, pixel_world * 0.95);
	float spark_core = 1.0 - smoothstep(spark_radius * 0.30, spark_radius,
		length(spark_pos));
	float ray_width = max(0.12, pixel_world * 0.12);
	float ray_v = (1.0 - smoothstep(ray_width, ray_width * 2.4, abs(spark_pos.x)))
		* (1.0 - smoothstep(spark_radius, spark_radius * 3.2, abs(spark_pos.y)));
	float ray_h = (1.0 - smoothstep(ray_width, ray_width * 2.4, abs(spark_pos.y)))
		* (1.0 - smoothstep(spark_radius, spark_radius * 3.2, abs(spark_pos.x)));
	float sparkle_shape = max(spark_core, max(ray_v, ray_h) * 0.72);
	float microfacet_seed = hash12(spark_cell + vec2(11.7, 4.1));
	vec3 microfacet_n = normalize(vec3((microfacet_seed - 0.5) * 0.38, 1.0,
		hash12(spark_cell + vec2(3.3, 15.1)) * 0.38 - 0.19));
	float microfacet_match = 0.45 + 0.55 * pow(
		clamp(dot(microfacet_n, H), 0.0, 1.0), 10.0);
	float spark_select = step(1.0 - solar_glitter_amount * 0.32, spark_seed);
	float spark_twinkle = 0.72 + 0.28 * sin(u_time * 3.4 + spark_seed * 71.0);
	vec3 spark_tint = mix(lit_col, vec3(0.90, 0.95, 1.08), spark_core * 0.82);
	vec3 distant_glitter = spark_tint * sparkle_shape * spark_select * sun_road
		* microfacet_match * spark_twinkle * far_glit * solar_glitter_amount
		* 9.0 * (1.0 - 0.70 * near_shore);
	base += distant_glitter;

	// ---------- пена прибоя ----------
	// Обе полосы идут по КОНТУРУ глубины: кромка на песке и вал чуть
	// дальше. Контур живой, потому что сама поверхность дышит накатом.
	float fn = vnoise(vec2(wp.x * 0.85 + u_time * 0.10, wp.y * 1.55));
	float fn2 = vnoise(vec2(wp.x * 3.2 - u_time * 0.38, wp.y * 2.35));
	float edge = exp(-pow((depth_m - 0.014 - 0.014 * sin(wp.x * 0.9 + u_time * 1.3)) / 0.075, 2.0));
	float edge2 = exp(-pow((depth_m - 0.17 - 0.03 * sin(wp.y * 0.21 + u_time * 1.15)) / 0.08, 2.0));
	float foam = edge * smoothstep(0.02, 0.40, fn) * (0.72 + 0.28 * fn2);
	foam += edge2 * smoothstep(0.45, 0.85, fn2) * 0.55;
	foam = clamp(foam, 0.0, 1.0);
	base = mix(base, foam_col * (0.80 + 0.20 * ndl), foam * 0.95);

	// ---------- дымка к горизонту ----------
	float fog = 1.0 - exp(-pow(dist / fog_distance, 2.1));
	float above = smoothstep(-2.0, 16.0, w_pos.y - CAMERA_POSITION_WORLD.y);
	vec3 fcol = mix(horizon_col, sky_col, above * 0.6);
	// Искры — отдельный HDR-слой: они остаются резкими поверх дымки,
	// а glow даёт им маленький ореол, не превращая дорожку в сплошную полосу.
	// Ночная луна: та же схема, что у песка — холодный ключ в EMISSION,
	// иначе глубокой ночью вода уходит в чёрный квадрат.
	float nightk = smoothstep(0.35, 0.85, night_amount);
	vec3 moon_reveal = vec3(0.0);
	if (nightk > 0.0) {
		vec3 md = normalize(vec3(L.x, 0.55, L.z));
		float mnl = clamp(dot(N, md) * 0.5 + 0.5, 0.0, 1.0);
		float low_sun = 1.0 - smoothstep(0.05, 0.25, L.y);
		// Добавка, а НЕ «base × множитель»: у глубокой воды base почти
		// нулевой, и прежняя формула ночью умножала ноль на ноль — море
		// становилось АБСОЛЮТНО чёрным прямоугольником до горизонта.
		vec3 moon_sky = vec3(0.020, 0.032, 0.058);
		moon_reveal = (base * (0.55 + 0.55 * mnl) + moon_sky * (0.60 + 0.40 * mnl))
			* (0.45 + 0.65 * low_sun) * nightk * (1.0 - fog);
	}
	ALBEDO = mix(base - distant_glitter, fcol, fog);
	EMISSION = distant_glitter + moon_reveal;

	NORMAL = normalize((VIEW_MATRIX * vec4(N.x, N.y, N.z, 0.0)).xyz);
	float rough = mix(0.16, 0.55, near_shore);
	ROUGHNESS = mix(rough, 0.88, foam);
	SPECULAR = mix(0.55, 0.18, near_shore);
	METALLIC = 0.0;

	// ---------- мягкий урез ----------
	// Альфа растёт от нуля по глубине: кромка получается градиентной,
	// а не ступенькой из полигонов.
	float shore_a = smoothstep(-0.35, 0.30, depth_m);
	// Открытое море непрозрачное: мягкий alpha нужен только на кромке,
	// иначе сквозь мелководье просвечивает дно и пропадает цвет воды.
	float sea_a = shore_a;
	float a = max(sea_a, foam * 0.92);
	// предметы (пирс, камни) закрывают воду мягко
	float sd = texture(depth_tex, SCREEN_UV).r;
	vec2 ndc_xy = SCREEN_UV * 2.0 - 1.0;
	vec4 ndc = vec4(ndc_xy.x, ndc_xy.y, sd, 1.0);
	vec4 vp = INV_PROJECTION_MATRIX * ndc;
	vp.xyz /= vp.w;
	float scene_z = -vp.z;
	float water_z = -VERTEX.z;
	float obj_a = smoothstep(0.0, shore_fade, scene_z - water_z);
	ALPHA = clamp(min(a, obj_a), 0.0, 1.0);
}

// Адаптация формул Proxima Diffuse + Schlick-GGX для A/B-теста воды.
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

void light() {
	vec3 n = normalize(NORMAL);
	vec3 l = normalize(LIGHT);
	vec3 v = normalize(VIEW);
	float nl = max(dot(n, l), 0.0);
	float nv = clamp(dot(n, v), 1e-3, 1.0);
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
		vec3 f0 = mix(vec3(0.04 * proxima_specular_strength), ALBEDO, METALLIC);
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
