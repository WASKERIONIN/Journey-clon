shader_type sky;

// =====================================================================
// Физически достоверное небо: рассеяние Рэлея, Mie (двухдолевая фаза
// Хеньи-Гринштейна), поглощение озоном, диск солнца, планета.
// По мотивам «Freeman's Sky Shader» (NiwlGames, CC0) — адаптация под
// Compatibility: солнце передаётся uniform'ом (в GLES3-небе нет
// LIGHT0_DIRECTION), высота наблюдателя фиксирована (нет POSITION),
// half-res проход не используется (в GLES3 не заполняется для
// кастомных материалов неба — дали чёрный зенит; считаем напрямую,
// сэмплов меньше: 12×4).
// =====================================================================

group_uniforms Sun;

uniform float sun_intensity : hint_range(0.0, 314.159, 0.1) = 50.0;
uniform vec3 sun_wavelengths = vec3(0.680, 0.550, 0.480);
uniform vec3 sun_direction = vec3(0.16, 0.44, -0.88); // К солнцу (ставится из Game.SUN_DIR)

group_uniforms Atmosphere.Rayleigh;

/** Толщина слоя, где происходит рэлеевское рассеяние (красные закаты). */
uniform float rayleigh_scale_height : hint_range(0.0, 100000.0, 1.0) = 8000.0;
/** Мультирассеяние Рэлея: лёгкая «подсветка» теней, чтобы небо не чернело. */
uniform float rayleigh_multi_scattering : hint_range(0.0, 1.0, 0.001) = 0.025;

group_uniforms Atmosphere.Mie;

/** Толщина слоя Mie-рассеяния (ореол солнца, дымка). */
uniform float mie_scale_height : hint_range(0.0, 1e5, 1.0) = 1200.0;
/** Сила Mie — в пустыне воздуха «толще», ореол солнца богаче. */
uniform float mie_scattering : hint_range(0.0, 1.0, 1e-7) = 8e-6;
uniform float mie_albedo : hint_range(0.0, 1.0, 0.01) = 0.9;
/** Двухдолевая фаза Хеньи-Гринштейна: вперёд/назад и их вес. */
uniform float mie_g_forward : hint_range(0.0, 1.0, 0.01) = 0.85;
uniform float mie_g_backward : hint_range(-1.0, 0.0, 0.01) = -0.15;
uniform float mie_weight : hint_range(0.0, 1.0, 0.01) = 0.85;
/** Мультирассеяние Mie — мягкая вторая доля. */
uniform float mie_multi_scattering : hint_range(0.0, 1.0, 0.01) = 0.30;
uniform float multiscattering_mie_g_forward : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform float multiscattering_mie_g_backward : hint_range(-1.0, 0.0, 0.01) = -0.05;
uniform float multiscattering_mie_weight : hint_range(0.0, 1.0, 0.01) = 0.75;

group_uniforms Atmosphere.Ozone;

const vec3 ozone_extinction = vec3(0.650, 1.881, 0.085) * 1e-6;
uniform float ozone_center : hint_range(0.0, 1e5, 1.0) = 25000.0;
uniform float ozone_width : hint_range(0.0, 1e5, 1.0) = 30000.0;

group_uniforms Planet;

uniform float planet_radius = 6360000.0;
uniform float atmosphere_height = 100000.0;
/** Высота наблюдателя (метры) — Compatibility-небо не даёт POSITION. */
uniform float base_altitude = 4.0;
/** Цвет «планеты» под ногами — золото песка. */
uniform vec3 ground_color = vec3(0.42, 0.28, 0.17);

group_uniforms Clouds;

/** Облака: покрытие неба (0 — чисто, 1 — плотно). */
uniform float cloud_cover : hint_range(0.0, 1.0, 0.01) = 0.5;
/** Резкость края: меньше — мягче и пушистее. */
uniform float cloud_softness : hint_range(0.05, 0.6, 0.01) = 0.22;
/** Размер облаков: больше — крупнее. */
uniform float cloud_size : hint_range(0.4, 3.0, 0.05) = 1.25;
/** Скорость дрейфа, м/с. */
uniform float cloud_drift : hint_range(0.0, 25.0, 0.5) = 7.0;
/** Непрозрачность облачных форм. */
uniform float cloud_opacity : hint_range(0.0, 1.0, 0.01) = 0.92;

group_uniforms Quality;

uniform int view_samples : hint_range(0, 256) = 12;
uniform int sun_samples : hint_range(0, 256) = 4;


float get_atmosphere_radius() {
	return planet_radius + atmosphere_height;
}

// Пересечение луча со сферой (Inigo Quilez)
vec2 ray_sphere_intersection(vec3 ray_origin, vec3 ray_direction, float sphere_radius) {
	float b = dot(ray_origin, ray_direction);
	float c = dot(ray_origin, ray_origin) - sphere_radius * sphere_radius;
	float discriminant = b * b - c;
	if (discriminant < 0.0) {
		return vec2(-1.0);
	}
	float root = sqrt(discriminant);
	return vec2(-b - root, -b + root);
}

// Рэлеевский коэффициент рассеяния: ~1/λ⁴ — вот откуда синева и закаты
vec3 get_rayleigh_scattering() {
	return (1.0 / (sun_wavelengths * sun_wavelengths * sun_wavelengths * sun_wavelengths)) * 1e-6;
}

float get_mie_extinction() {
	return mie_scattering / mie_albedo;
}

// Полная фаза Рэлея
float get_rayleigh_phase(float cos_theta) {
	return 0.05968310365 * (1.0 + cos_theta * cos_theta);
}

// Хеньи-Гринштейн
float henyey_greenstein_phase(float cos_theta, float g) {
	float g2 = g * g;
	return 0.07957747154 * (1.0 - g2) / pow(1.0 + g2 - 2.0 * g * cos_theta, 1.5);
}

float get_mie_phase(float cos_theta, float g_backward, float g_forward, float weight) {
	return mix(
		henyey_greenstein_phase(cos_theta, g_backward),
		henyey_greenstein_phase(cos_theta, g_forward),
		weight
	);
}

// Плотности: Рэлей / Mie / озон
vec3 get_optical_depth_at_point(vec3 position) {
	float altitude = length(position) - planet_radius;
	return vec3(
		exp(-altitude / rayleigh_scale_height),
		exp(-altitude / mie_scale_height),
		max(0.0, 1.0 - abs(altitude - ozone_center) / (ozone_width / 2.0))
	);
}

// Прозрачность пути (закон Ламберта, полушаг)
vec3 get_transmittance(vec3 origin, vec3 direction, float dist, int samples) {
	float step_length = dist / float(samples);
	vec3 accumulated_optical_depth = vec3(0.0);
	vec3 optical_depth_start = get_optical_depth_at_point(origin);
	for (int i = 0; i < samples; i++) {
		vec3 optical_depth_end = get_optical_depth_at_point(origin + direction * float(i + 1) * step_length);
		accumulated_optical_depth += mix(optical_depth_start, optical_depth_end, 0.5) * step_length;
		optical_depth_start = optical_depth_end;
	}
	return exp(-(
		get_rayleigh_scattering() * accumulated_optical_depth.x
		+ get_mie_extinction() * accumulated_optical_depth.y
		+ ozone_extinction * accumulated_optical_depth.z
	));
}

// Интеграл яркости вдоль взгляда
vec3 integrate_radiance(vec3 ray_origin, vec3 ray_direction, float target_distance, int samples, vec3 sun_dir) {
	float cos_theta = dot(ray_direction, sun_dir);
	float step_length = target_distance / float(samples);

	float rayleigh_phase = get_rayleigh_phase(cos_theta);
	float mie_phase = get_mie_phase(cos_theta, mie_g_backward, mie_g_forward, mie_weight);
	float ms_mie_phase = get_mie_phase(cos_theta, multiscattering_mie_g_backward, multiscattering_mie_g_forward, multiscattering_mie_weight);

	vec3 accumulated_optical_depth = vec3(0.0);
	vec3 accumulated_radiance = vec3(0.0);
	vec3 view_transmittance = vec3(0.0);
	vec3 optical_depth_start = get_optical_depth_at_point(ray_origin);

	for (int i = 0; i < samples; i++) {
		vec3 optical_depth_end = get_optical_depth_at_point(ray_origin + ray_direction * float(i + 1) * step_length);
		vec3 step_optical_depth = mix(optical_depth_start, optical_depth_end, 0.5) * step_length;
		accumulated_optical_depth += step_optical_depth;

		vec3 sample_point = ray_origin + ray_direction * (float(i) + 0.5) * step_length;
		view_transmittance = exp(-(
			get_rayleigh_scattering() * accumulated_optical_depth.x
			+ get_mie_extinction() * accumulated_optical_depth.y
			+ ozone_extinction * accumulated_optical_depth.z
		));

		vec3 sun_radiance = vec3(0.0);
		vec2 planet_hit = ray_sphere_intersection(sample_point, sun_dir, planet_radius);
		if (planet_hit.y <= 0.0) {
			vec2 atmosphere_hit = ray_sphere_intersection(sample_point, sun_dir, get_atmosphere_radius());
			vec3 sun_transmittance = get_transmittance(sample_point, sun_dir, atmosphere_hit.y, sun_samples);
			vec3 scattering_coeff = (
				step_optical_depth.x * get_rayleigh_scattering() * rayleigh_phase
				+ step_optical_depth.y * mie_scattering * mie_phase
			);
			sun_radiance = sun_transmittance * sun_intensity * scattering_coeff;
		}
		accumulated_radiance += sun_radiance * view_transmittance;

		// мультирассеяние: мягкая подсветка, чтобы тени дышали
		vec3 rayleigh_ambient = step_optical_depth.x * get_rayleigh_scattering() * rayleigh_multi_scattering;
		vec3 mie_ambient = vec3(step_optical_depth.y * mie_scattering * ms_mie_phase * mie_multi_scattering);
		accumulated_radiance += (rayleigh_ambient + mie_ambient) * view_transmittance;

		optical_depth_start = optical_depth_end;
	}

	// диск солнца (за атмосферой — с прозрачностью пути)
	vec3 sun_disk = vec3(0.0);
	float planet_hit = ray_sphere_intersection(ray_origin, ray_direction, planet_radius).y;
	if (planet_hit < 0.0) {
		sun_disk = smoothstep(0.99975, 1.0, cos_theta) * sun_intensity * view_transmittance;
	}
	return accumulated_radiance + sun_disk;
}

// ---------------------------------------------------------------------
// Облака: мягкий кучевой «потолок» — по мотивам Sunshine Clouds, но
// без композитора и compute (в Compatibility их нет): слой FBM-форм
// рисуется прямо в небе, дёшево и без единой текстуры. Светотень —
// пробой формы со стороны солнца, у кромки против солнца — серебро.
// ---------------------------------------------------------------------
float chash(vec2 p) {
	p = fract(p * vec2(127.1, 311.7));
	p += dot(p, p + 34.23);
	return fract(p.x * p.y);
}

float cnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(chash(i), chash(i + vec2(1.0, 0.0)), f.x),
		mix(chash(i + vec2(0.0, 1.0)), chash(i + vec2(1.0, 1.0)), f.x),
		f.y
	);
}

float fbm2(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	mat2 rot = mat2(vec2(0.80, 0.60), vec2(-0.60, 0.80));
	for (int i = 0; i < 4; i++) {
		v += a * cnoise(p);
		p = rot * p * 2.02;
		a *= 0.5;
	}
	return v;
}

/** Форма облака: низкочастотная масса + высокочастичная «кучевость» кромки. */
float cloud_shape(vec2 p) {
	return fbm2(p) + (fbm2(p * 2.6 + vec2(11.3, 7.1)) - 0.5) * 0.16;
}

vec4 cloud_layer(vec3 dir, vec3 sun_dir) {
	// только над горизонтом; у самого горизонта растворяются в даль
	float band = smoothstep(0.02, 0.16, dir.y);
	if (band <= 0.002) {
		return vec4(0.0);
	}
	vec2 uv = dir.xz / (dir.y + 0.10);
	vec2 p = uv * (3.0 / cloud_size)
		+ vec2(0.916, 0.401) * TIME * cloud_drift * 0.006;
	float shape = cloud_shape(p);
	float thr = mix(0.70, 0.34, cloud_cover);
	float density = smoothstep(thr, thr + cloud_softness, shape);
	if (density <= 0.003) {
		return vec4(0.0);
	}
	// тень/свет: со стороны солнца форма плотнее — значит, мы в тени
	float shape_sun = cloud_shape(p + normalize(sun_dir.xz + vec2(1e-4, 1e-4)) * 0.34);
	float lit = clamp(0.5 + (shape - shape_sun) * 2.1, 0.0, 1.0);
	// низкое солнце — облака теплеют (закатная краска)
	float elev = clamp(sun_dir.y * 1.7, 0.0, 1.0);
	vec3 sun_col = mix(vec3(1.06, 0.63, 0.40), vec3(1.02, 0.99, 0.95), elev);
	vec3 shade_col = mix(vec3(0.60, 0.50, 0.50), vec3(0.56, 0.60, 0.70), elev);
	vec3 col = mix(shade_col, sun_col, lit);
	// серебряная кромка: тонкий край облака против солнца светится
	float rim = 1.0 - smoothstep(0.0, 0.45, density);
	float towards = max(dot(dir, sun_dir), 0.0);
	col += vec3(1.0, 0.87, 0.68) * pow(rim, 3.0) * pow(towards, 5.0) * 1.35;
	return vec4(col, density * band * cloud_opacity);
}

void sky() {
	vec3 final_color = vec3(0.0);
	vec3 sun_dir = normalize(sun_direction);

	vec3 ray_origin = vec3(0.0, planet_radius + base_altitude, 0.0);
	vec3 ray_direction = EYEDIR;

	float atmosphere_radius = get_atmosphere_radius();
	vec2 atmosphere_hit = ray_sphere_intersection(ray_origin, ray_direction, atmosphere_radius);
	vec2 ground_hit = ray_sphere_intersection(ray_origin, ray_direction, planet_radius);
	bool hits_ground = ground_hit.y > 0.0;
	float atmosphere_distance = hits_ground ? ground_hit.x : atmosphere_hit.y;
	int samples = hits_ground ? view_samples / 2 : view_samples;

	final_color = integrate_radiance(ray_origin, ray_direction, atmosphere_distance, samples, sun_dir);

	// «планета» под ногами: золото песка в рассеянном свете
	if (hits_ground) {
		vec3 ground_point = ray_origin + ray_direction * atmosphere_distance;
		vec3 ground_normal = normalize(ground_point);
		float direct_light = max(dot(ground_normal, sun_dir), 0.0);
		vec3 sun_transmittance = vec3(0.0);
		if (direct_light > 0.0) {
			float ground_to_sun = ray_sphere_intersection(ground_point, sun_dir, atmosphere_radius).y;
			sun_transmittance = get_transmittance(ground_point, sun_dir, ground_to_sun, sun_samples);
		}
		vec3 ground_albedo = ground_color * (direct_light * sun_intensity * sun_transmittance) * (1.0 / PI);
		vec3 to_eye = get_transmittance(ray_origin, ray_direction, atmosphere_distance, view_samples);
		final_color += ground_albedo * to_eye;
	}
	// кучевые облака поверх атмосферы
	vec4 cl = cloud_layer(ray_direction, sun_dir);
	final_color = mix(final_color, cl.rgb, cl.a);

	// дебандинг: физический градиент не должен полосить
	// (EYEDIR вместо SCREEN_UV — одинаково работает в Forward+ и Compatibility)
	float dither = fract(sin(dot(EYEDIR.xz * 917.0, vec2(12.9898, 78.233))) * 43758.5453);
	COLOR = final_color + vec3((dither - 0.5) * (2.5 / 255.0));
}
