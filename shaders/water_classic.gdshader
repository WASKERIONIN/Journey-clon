shader_type spatial;
// Вода, собранная из sand.gdshader. Тот же принцип, что у песка:
// высота считается из событий (кольца) и ветра, градиент — это НАСТОЯЩИЕ
// нормали, и всё освещение идёт через настоящий BRDF Forward+.
// Никаких «нарисованных» бликов поверх unshaded.
//
// Два слоя волн:
//   • ветровые ВАЛЫ (7–12 м) — геометрия (vertex) + нормали (fragment);
//     в отличие от песчаной ряби фаза бежит ПО ветру: гребень поперёк ветра;
//   • кольца от событий (всплеск поплавка, поклёвка, подмотка) — только
//     нормали (амплитуда сантиметры, геометрию не портят), с аналитическим
//     градиентом: расходящийся волновой пакет гауссовой формы.
//
// Глубина берётся из depth-текстуры: мелководье просвечивает песок,
// глубина уходит в индиго, у берега — мягкая кромка и пена. Рефракция —
// через screen-текстуру со сдвигом по нормали.
//
// render_mode: diffuse_burley + specular_schlick_ggx — как у песка,
// только roughness низкий: солнце само рисует дорожку.

render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// ---- Палитра (в Джорни-тона: закат над водой) ----
uniform vec3 sun_dir = vec3(0.10, 0.26, -0.96); // к солнцу (как у песка)
uniform vec3 sun_col : source_color = vec3(1.00, 0.72, 0.42);
uniform vec3 deep_col : source_color = vec3(0.055, 0.085, 0.21); // толща
uniform vec3 scatter_col : source_color = vec3(0.06, 0.10, 0.17); // муть в толще
uniform vec3 tint_col : source_color = vec3(0.86, 1.00, 0.97); // лёгкий холод тонкого слоя
uniform vec3 absorb = vec3(0.55, 0.28, 0.16); // поглощение: красный умирает первым
uniform vec3 horizon_col : source_color = vec3(0.96, 0.66, 0.55); // как у песка
uniform vec3 sky_col : source_color = vec3(0.28, 0.24, 0.43);     // как у песка
uniform vec3 foam_col : source_color = vec3(1.00, 0.85, 0.70);
uniform float fog_distance = 340.0;

// ---- Ветер (те же uniform-ы, что у песка: один ветер на всю игру) ----
uniform vec2 wind_dir = vec2(0.32, -0.95); // нормализуется внутри
uniform float wind_power = 1.0;

// ---- Ветровые валы (геометрия) ----
uniform float swell_amp = 0.08;  // м, амплитуда суммарного вала
uniform float swell_len = 7.0;   // м, длина первичной волны
uniform float wave_speed = 2.0;  // м/с, фазовая скорость

// ---- Мелкая рябь (только нормали) ----
uniform float ripple_amp = 0.035;
uniform float ripple_len = 1.6;  // м, первичная капиллярка

// ---- Кольца событий ----
uniform float ring_amp = 0.055;  // м при силе 1.0
uniform float ring_speed = 1.5;  // м/с, скорость фронта
uniform float ring_len = 0.85;   // м, длина волны пакета
uniform float ring_tau = 0.55;   // 1/с, затухание по времени
uniform float ring_w0 = 0.30;    // м, ширина пакета при рождении
uniform float ring_wg = 0.18;    // м/с, расползание ширины

// ---- Облик ----
uniform float normal_boost = 1.4;   // крутизна нормалей (художественный множитель)
uniform float glitter_amount = 0.10; // доля сверкающих фасеток (как у песка)
uniform float foam_gain = 0.5;       // сила пены (гребни колец + берег)
uniform float refr_strength = 0.05;  // сдвиг рефракции

uniform float u_time = 0.0;
uniform vec4 u_rings[24]; // x, z, t0, amp; amp <= 0.0005 — слот пуст

varying vec3 v_wpos;

const float PI_2 = 6.28318530718;

// ---- детерминированный хеш и value-noise (ТЕ ЖЕ, что у песка) ----
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

// ---- Ветровые валы: высота в мировой точке ----
// Фаза бежит ПО ветру (u), гребни поперёк ветра — как у настоящей воды.
// Варп из двух октав шума изгибает прямые гребни в живые линии.
// Эта же функция зеркалится в water_field.gd (height_at) для физики поплавка.
float wind_h(vec2 wp) {
        vec2 wdir = normalize(wind_dir);
        vec2 wperp = vec2(-wdir.y, wdir.x);
        float u = dot(wp, wdir);  // вдоль ветра
        float v = dot(wp, wperp); // поперёк

        float warp = vnoise(wp * 0.06) * 2.2 + vnoise(wp * 0.023 + vec2(4.7, 1.3)) * 3.1;

        float k1 = PI_2 / swell_len;
        float k2 = k1 / 1.6;            // второй вал длиннее
        float w1 = k1 * wave_speed;     // omega = k * c
        float w2 = k2 * wave_speed * 1.15;

        float ph1 = u * k1 + v * 0.12 + warp + u_time * w1;
        float ph2 = u * k2 - v * 0.21 + warp * 0.7 + u_time * w2 + 1.7;
        float ph3 = ph1 * 2.13 + 0.9;   // короткая зыбь поверх первичной

        float a = swell_amp * wind_power;
        return (cos(ph1) * 0.55 + cos(ph2) * 0.30 + cos(ph3) * 0.15) * a;
}

void vertex() {
        v_wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
        // валы реально гнут геометрию (кольца — сантиметры, их несут нормали)
        float h = wind_h(v_wpos.xz);
        VERTEX.y += h;
        v_wpos.y += h;
}

void fragment() {
        vec2 wp = v_wpos.xz;
        vec2 wdir = normalize(wind_dir);
        vec2 wperp = vec2(-wdir.y, wdir.x);
        float u = dot(wp, wdir);
        float v = dot(wp, wperp);

        vec3 L = normalize(sun_dir);
        vec3 V = normalize(CAMERA_POSITION_WORLD - v_wpos);
        float dist = length(CAMERA_POSITION_WORLD - v_wpos);
        float detail = exp(-dist * 0.020); // дальняя рябь гаснет — шелк без муара

        // ---------- 1. Градиент: ветер (конечные разности) + кольца (аналитика) ----------
        vec2 grad = vec2(0.0);
        float e = 0.35;
        float h0 = wind_h(wp);
        grad += vec2(wind_h(wp + vec2(e, 0.0)) - h0, wind_h(wp + vec2(0.0, e)) - h0) / e;

        // мелкая рябь: две полосы, аналитический градиент (как рябь песка)
        float kr1 = PI_2 / ripple_len;
        float kr2 = PI_2 / (ripple_len * 0.34);
        float n1 = vnoise(wp * 0.33);
        float n2 = vnoise(wp * 0.9 + vec2(17.0, 9.0));
        float phr1 = u * kr1 + v * 0.10 + n1 * 3.0 + u_time * kr1 * wave_speed * 1.25;
        float phr2 = u * kr2 - v * 0.15 + n2 * 3.4 + u_time * kr2 * wave_speed * 1.45;
        float a1 = ripple_amp * detail * wind_power;
        float a2 = ripple_amp * 0.55 * detail * wind_power;
        float s1 = sin(phr1);
        float s2 = sin(phr2);
        grad += (wdir * (-s1 * kr1) + wperp * (-s1 * 0.10)) * a1;
        grad += (wdir * (-s2 * kr2) + wperp * (s2 * 0.15)) * a2;

        // кольца событий: расходящиеся пакеты с аналитическим градиентом
        float crest = 0.0;
        float rk = PI_2 / ring_len;
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
                // dh/ddist: производная пакета env*cos по радиусу
                float dhdd = a * (env * (-2.0 * x / bw) * cos(ph) - env * sin(ph) * rk);
                grad += (d / dd) * dhdd;
                crest += a * env * pow(max(cos(ph), 0.0), 3.0);
        }

        vec3 N = normalize(vec3(-grad.x * normal_boost, 1.0, -grad.y * normal_boost));

        // ---------- 2. Глубина: сцена под водой через depth-текстуру ----------
        float frag_z = -VERTEX.z;
        float raw = texture(u_depth_tex, SCREEN_UV).r;
        vec4 vp4 = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, raw, 1.0);
        float scene_z = -vp4.xyz / vp4.w;
        float thick = max(scene_z - frag_z, 0.0);

        // рефракция: сдвиг экранной выборки по градиенту, гасится у берега
        vec2 ruv = clamp(SCREEN_UV + vec2(grad.x, grad.y) * refr_strength
                        * (1.0 / (1.0 + thick)), vec2(0.001), vec2(0.999));
        vec3 refr = texture(u_screen_tex, ruv).rgb;

        // поглощение по Беру: красный умирает первым -> толща синеет
        vec3 trans = exp(-absorb * thick);
        vec3 under = refr * tint_col * trans + scatter_col * (1.0 - trans);

        // ---------- 3. Отражение неба (аналитическое, в палитре Джорни) ----------
        float ndv = clamp(dot(N, V), 0.0, 1.0);
        float fres = 0.02 + 0.98 * pow(1.0 - ndv, 5.0);
        vec3 R = reflect(-V, N);
        R.y = max(R.y, 0.015); // тыльная сторона волны не смотрит в песок
        vec3 refl = mix(horizon_col, sky_col, smoothstep(0.0, 0.30, R.y));
        float rsun = max(dot(R, L), 0.0);
        refl += sun_col * (pow(rsun, 250.0) * 2.5 + pow(rsun, 40.0) * 0.20);

        // ---------- 4. Солнечный глинт + глиттер ----------
        vec3 H = normalize(V + L);
        float ndh = clamp(dot(N, H), 0.0, 1.0);
        float glint = pow(ndh, mix(320.0, 140.0, clamp(wind_power * 0.6, 0.0, 1.0)));
        // фасетки-искры: как у песка, только реже и тоньше
        float need = 500.0 / max(dist, 0.001);
        float density = clamp(pow(2.0, floor(log2(need / 3.0))) * 3.0, 6.0, 90.0);
        vec2 celluv = floor(wp * density);
        float cellid = hash12(celluv);
        float cellb = hash12(celluv + vec2(7.31, 1.77));
        vec3 Hg = normalize(H + vec3(cellid - 0.5, cellb - 0.5, 0.0) * 0.5);
        float sparkle = pow(clamp(dot(N, Hg), 0.0, 1.0), mix(40.0, 90.0, cellb));
        sparkle *= step(1.0 - glitter_amount * exp(-dist * 0.004), cellid);
        sparkle *= 0.5 + 0.5 * sin(u_time * mix(3.0, 7.0, cellb) + cellid * 71.0);

        // ---------- 5. Пена: гребни колец + кромка берега ----------
        float shore = 1.0 - smoothstep(0.0, 0.30, thick);
        float foam = clamp(crest * 6.0 * foam_gain + shore * 0.4 * foam_gain, 0.0, 1.0);

        // ---------- 6. Сборка ----------
        vec3 base = mix(under, refl, fres);
        base += sun_col * glint * (2.2 + 1.4 * wind_power);
        base += sun_col * sparkle * 1.4;
        base = mix(base, foam_col, foam * 0.65);

        // дымка к горизонту — та же, что у песка
        float fog = 1.0 - exp(-pow(dist / fog_distance, 2.1));
        float above = smoothstep(-2.0, 16.0, v_wpos.y - CAMERA_POSITION_WORLD.y);
        vec3 fcol = mix(horizon_col, sky_col, above * 0.6);

        ALBEDO = mix(base, fcol, fog);
        NORMAL = normalize((VIEW_MATRIX * vec4(N, 0.0)).xyz);
        ROUGHNESS = mix(0.045, 0.085, clamp(wind_power * 0.6, 0.0, 1.0)) + foam * 0.25;
        SPECULAR = 0.35;
        METALLIC = 0.0;
        ALPHA = clamp(smoothstep(0.012, 0.18, thick) + foam * 1.2, 0.0, 1.0);
}
