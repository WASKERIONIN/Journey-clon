shader_type spatial;
// ПЕСЧАНЫЕ СУЩЕСТВА — полноэкранный SDF-реймарчинг поверх «песчаного моря».
//
// Ядро взято из шейдера «Fullscreen SDF Raymarching with Smooth CSG and
// Depth» (CC0 1.0, Stratos / vav-labs, godotshaders.com): квад, пришпиленный
// к near-плоскости, sphere tracing по SDF-сцене, окклюзия по depth-буферу
// сцены, запись НАСТОЯЩЕЙ глубины и антиалиасные силуэты через конус
// пикселя. Distance functions after Inigo Quilez.
//
// Что здесь «сценой» (map()) вместо демо-фигур:
//   • РЫБЫ-«ПЕСЧАНЫЕ КИТЫ» (как существа Journey): хребет из 6 сфер +
//     морда + спинной гребень + хвостовая лопасть (2 эллипсоида), всё
//     через smooth union — тело плавится в жидкую ленту, цвета плавятся
//     вместе с формой. Сфера тут не единственная форма: SDF умеет любые
//     примитивы (капсулы, конусы, торы) — см. rot2()/sd_ell() ниже.
//     Волна бежит по хребту к хвосту (хвост виляет сильнее) — фазу пушит
//     sand_fish.gd;
//   • БРЫЗГИ: кластеры капель (парбол на CPU), плавящиеся друг с другом
//     и с телом выпрыгнувшей рыбы — тот самый «metaball melt»;
//   • ПОДВОДНЫЙ СЛЕД: тело ниже воды скрыто глубинным буфером. На поверхности
//     остаётся только тонкий слабый след за рыбой — не постоянно видимый
//     силуэт. При прыжке полноценное SDF-тело выходит из воды с брызгами.
//
// Окклюзия делает всё остальное: часть тела ниже уровня моря автоматически
// прячется за морем, часть выше — стоит перед ним и пишет свою глубину
// (прозрачные объекты после неё тестируются уже против рыбы).
//
// Согласование с водой: палитра/туман — те же uniform-ы, что у water.gdshader;
// глубину для «вуали» берем из depth-текстуры, уровень моря — uniform.
//
// Требования: Godot 4.3+ (reversed-Z), Forward+. Квад создаёт sand_fish.gd,
// он же пушит все uniform-ы (рыбы, капли, центр обитания — за камерой).

render_mode unshaded, fog_disabled, depth_test_disabled, depth_draw_always, cull_disabled;

// ===== Качество реймарчинга (как у оригинала) =====
uniform float epsilon = 0.01;
uniform float max_ray_distance = 512.0;
uniform int max_steps = 96;

// ===== Свет — та же закатная палитра, что у воды/песка =====
uniform vec3 sun_dir = vec3(0.10, 0.26, -0.96); // к солнцу (как у песка)
uniform vec3 sand_sunny : source_color = vec3(0.93, 0.52, 0.30);
uniform vec3 sand_hot : source_color = vec3(1.00, 0.68, 0.36);
uniform vec3 sand_shade : source_color = vec3(0.40, 0.32, 0.52);
uniform vec3 horizon_col : source_color = vec3(0.96, 0.66, 0.55);
uniform vec3 sky_col : source_color = vec3(0.28, 0.24, 0.43);
uniform float night_amount : hint_range(0.0, 1.0) = 0.0;
uniform float fog_distance = 340.0;

// ===== Сцена =====
uniform float u_water_level = 0.0;
uniform float u_time = 0.0;
uniform vec2 u_center = vec2(0.0, 0.0); // камера: только ограничивает область raymarch
uniform float u_bounds_r = 130.0;       // радиус raymarch-culling вокруг камеры, м

// Рыбы: 6 слотов стаи + 1 слот пойманной рыбы; meta.x <= 0.001 — пусто
uniform vec4 u_fish_state[7]; // xyz — центр тела, w — курс (рад)
uniform vec2 u_fish_meta[7];  // x — размер (м), y — фаза волны тела
uniform vec3 u_fish_tint[7];  // базовый цвет существа
uniform float u_catch_flex = 1.0; // улов в центре экрана: меньше перегиба тела

// Брызги: 12 слотов; w <= 0.004 — слот пуст (анимация целиком на CPU)
uniform vec4 u_drops[12]; // xyz — центр, w — радиус
uniform vec3 u_drop_tint : source_color = vec3(0.98, 0.62, 0.38);

// След подводной рыбы — очень тонкий и малоконтрастный.
uniform float u_veil_strength = 0.42;

// КИТ ПЕСЧАНЫХ РЫБ (godot_fish): 3 слота × 12 костей, семь видов.
const int FK_FISH = 3;
const int FK_BONE = 12;
uniform vec4 u_fk_bone[36];
uniform vec4 u_fk_params[3];
uniform vec4 u_fk_flags[3];
uniform vec3 u_fk_top[3];
uniform vec3 u_fk_belly[3];
uniform vec3 u_fk_acc[3];
uniform vec3 u_fk_glow_c[3];
uniform vec4 u_fk_glow[3];
uniform vec3 u_fk_center[3];
uniform vec4 u_fk_lure[3];
uniform vec4 u_fk_lure2[3];
uniform float u_fk_xray = 0.0;

// ===== РЫБАК-СУЩЕСТВО (квестодатель) — ТОТ ЖЕ SDF-raymarch, что и рыбы =====
// Тело собрано из «плавленых» капсул по костям CC0-рига (жилет, кепка,
// сапоги), а лицо — объёмные глаза с радужкой, зрачком, бликами и веками,
// которые следят за игроком. u_npc_head.w <= 0.001 — рыбака нет в этом
// материале (FishKit-квад его не дублирует).
// Суставы: 0 таз, 1 живот, 2 грудь, 3 шея, 4 голова, 5 макушка (ось шляпы),
// 6/9 плечи, 7/10 локти, 8/11 кисти, 12/16 бёдра, 13/17 колени,
// 14/18 голеностопы, 15/19 стопы.
uniform vec4 u_npc_joints[20]; // xyz — сустав, w — радиус капсулы
uniform vec4 u_npc_head = vec4(0.0, -100.0, 0.0, 0.0); // центр головы + радиус
uniform vec4 u_npc_face = vec4(0.0, 0.0, -1.0, 0.0); // взгляд xyz + открытость рта
uniform vec4 u_npc_eyes = vec4(0.0, 0.052, 0.034, 0.0); // морг, разлёт, радиус, —
uniform vec3 u_npc_skin : source_color = vec3(0.82, 0.47, 0.28);
uniform vec3 u_npc_cloth : source_color = vec3(0.10, 0.85, 0.95);
uniform vec3 u_npc_pants : source_color = vec3(0.36, 0.26, 0.20);
uniform vec3 u_npc_hat : source_color = vec3(0.42, 0.29, 0.18);
uniform vec3 u_npc_boot : source_color = vec3(0.27, 0.19, 0.14);

uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;
uniform sampler2D u_screen : hint_screen_texture, filter_linear;

// ---- детерминированный хеш (ТЕ ЖЕ, что у воды/песка) ----
float hash12(vec2 p) {
        vec3 p3 = fract(vec3(p.xyx) * 0.1031);
        vec3 q = p3.yzx + vec3(33.33);
        p3 += vec3(dot(p3, q));
        return fract((p3.x + p3.y) * p3.z);
}

// ===== CSG на парах (цвет, дистанция) — из оригинала (CC0, vav-labs) =====
// IQ smooth min: плавятся и форма, и цвет. Результат <= min(a, b),
// т.е. дистанция остаётся консервативной — sphere tracing безопасен.
vec4 sdf_smooth_union(vec4 a, float d, vec3 col, float k) {
        k = max(k, 1e-6);
        float h = clamp(0.5 + 0.5 * (d - a.w) / k, 0.0, 1.0);
        return vec4(mix(col, a.rgb, h), mix(d, a.w, h) - k * h * (1.0 - h));
}

// ===== Примитивы плавников (сфера — не единственная форма в SDF!) =====
// Поворот точки в плоскости (dir, up) — локальные координаты хвоста.
vec2 rot2(vec2 v, float a) {
        float c = cos(a);
        float sn = sin(a);
        return vec2(c * v.x - sn * v.y, sn * v.x + c * v.y);
}

// Сплюснутый эллипсоид (Inigo Quilez). Оценка консервативна
// (<= настоящей дистанции), так что sphere tracing остаётся безопасным.
float sd_ell(vec3 p, vec3 r) {
        float k0 = length(p / r);
        return min(r.x, min(r.y, r.z)) * (k0 - 1.0);
}

// Сужающаяся капсула (IQ): радиус плавно меняется от ra к rb.
float sd_capsule_t(vec3 p, vec3 a, vec3 b, float ra, float rb) {
        vec3 pa = p - a;
        vec3 ba = b - a;
        float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
        return length(pa - ba * h) - mix(ra, rb, h);
}

// Эллипсоид с центром c в базисе (side, up, fwd) — для кепки рыбака.
float sd_ell_f(vec3 p, vec3 c, vec3 side, vec3 up, vec3 fwd, vec3 r) {
        vec3 q = p - c;
        return sd_ell(vec3(dot(q, side), dot(q, up), dot(q, fwd)), r);
}

// Капсула между суставами рыбака ia→ib с плавлением цвета (как у рыб).
vec4 npc_seg(vec4 acc, vec3 p, int ia, int ib, vec3 col, float k) {
        vec4 A = u_npc_joints[ia];
        vec4 B = u_npc_joints[ib];
        return sdf_smooth_union(acc, sd_capsule_t(p, A.xyz, B.xyz, A.w, B.w), col, k);
}

// Виды и SDF-скелет FishKit из отдельного SDF include.
#include "res://shaders/fish_kit_map.gdshaderinc"

// ===== Тело существа i в точке p =====
// Хребет: 6 сфер от морды к хвосту; волна sin(phase - t*4.2) бежит назад,
// амплитуда растёт к хвосту (0.05s -> 0.43s) — та же пластика, что у
// «дыхания» моря, только быстрая. Плюс морда, спинной гребень и хвостовая
// лопасть-«ласта» из двух сплюснутых эллипсоидов.
vec4 fish_sdf(vec3 p, vec3 C, float s, float heading, float phase, vec3 tint,
        float body_flex) {
        vec3 dir = vec3(cos(heading), 0.0, sin(heading));
        vec3 side = vec3(-dir.z, 0.0, dir.x);
        vec3 up = vec3(0.0, 1.0, 0.0);
        float L = 2.4 * s;

        vec4 acc = vec4(0.0, 0.0, 0.0, 1e9);

        // хребет (морда -> хвост)
        for (int k = 0; k < 6; k++) {
                float t = float(k) / 5.0;
                float lat = sin(phase - t * 4.2) * s * (0.05 + 0.38 * t) * body_flex;
                float vert = sin(phase - t * 3.1 + 1.3) * s * 0.10 * t * body_flex;
                vec3 c = C + dir * ((0.5 - t) * L) + side * lat + up * vert;
                float r = s * (0.40 - 0.18 * t);
                vec3 col = mix(tint * 1.15, tint * 0.70, t); // спина светлее хвоста
                acc = sdf_smooth_union(acc, length(p - c) - r, col, 0.46 * s);
        }

        // морда
        vec3 sn = C + dir * (0.74 * L);
        acc = sdf_smooth_union(acc, length(p - sn) - s * 0.16, tint * 0.92, 0.22 * s);

        // спинной плавник: толстый тор без «дырки» — цельный гребень
        vec3 q = p - (C + dir * (0.12 * L) + up * (0.30 * s));
        vec2 tq = vec2(length(vec2(dot(q, dir), dot(q, up))) - 0.17 * s, dot(q, side));
        acc = sdf_smooth_union(acc, length(tq) - 0.085 * s, tint * 1.08, 0.12 * s);

        // хвостовая лопасть: два сплюснутых эллипсоида, растущих из стебля
        // назад-вверх и назад-вниз. Стебель НАСЛЕДУЕТ волну хребта (та же
        // формула при t = 1: lat 0.43s, vert 0.10s) — хвост приклеен к
        // последней сфере хребта и больше не отстаёт на вилях.
        vec3 stem = C - dir * (0.5 * L)
                + side * (sin(phase - 4.2) * 0.43 * s * body_flex)
                + up * (sin(phase - 1.8) * 0.10 * s * body_flex);
        vec3 qt = p - stem;
        vec3 ql = vec3(dot(qt, dir), dot(qt, up), dot(qt, side));
        // поворот в (dir, up): +угол валит лопасть назад-вверх,
        // -угол — назад-вниз; по боку эллипсоид тонкий (ql.z)
        vec2 qu = rot2(ql.xy, 0.62) + vec2(0.36 * s, 0.0);
        vec2 qd = rot2(ql.xy, -0.50) + vec2(0.32 * s, 0.0);
        float du = sd_ell(vec3(qu.x, qu.y, ql.z), vec3(0.34 * s, 0.095 * s, 0.038 * s));
        float dl = sd_ell(vec3(qd.x, qd.y, ql.z), vec3(0.30 * s, 0.085 * s, 0.034 * s));
        acc = sdf_smooth_union(acc, du, tint * 0.90, 0.15 * s);
        acc = sdf_smooth_union(acc, dl, tint * 0.90, 0.15 * s);

        return acc;
}

// ===== ТЕЛО РЫБАКА: суставы CC0-рига → «плавленые» капсулы =====
// Тот же smooth-union, что у рыб: формы и цвета перетекают друг в друга.
vec4 npc_sdf(vec3 p) {
        vec4 acc = vec4(u_npc_skin, 1e9);

        // торс: таз (штаны) → живот/грудь (жилет) → шея → основа головы
        acc = npc_seg(acc, p, 0, 1, u_npc_pants, 0.055);
        acc = npc_seg(acc, p, 1, 2, u_npc_cloth, 0.055);
        acc = npc_seg(acc, p, 2, 3, u_npc_cloth, 0.040);
        acc = npc_seg(acc, p, 3, 4, u_npc_skin, 0.040);

        // руки: плечо-локоть в рукаве жилета, предплечье и кисть — кожа
        acc = npc_seg(acc, p, 2, 6, u_npc_cloth, 0.045);
        acc = npc_seg(acc, p, 6, 7, u_npc_cloth, 0.035);
        acc = npc_seg(acc, p, 7, 8, u_npc_skin, 0.030);
        acc = npc_seg(acc, p, 2, 9, u_npc_cloth, 0.045);
        acc = npc_seg(acc, p, 9, 10, u_npc_cloth, 0.035);
        acc = npc_seg(acc, p, 10, 11, u_npc_skin, 0.030);

        // ноги: штаны до голеностопа, стопы — сапоги
        acc = npc_seg(acc, p, 0, 12, u_npc_pants, 0.050);
        acc = npc_seg(acc, p, 12, 13, u_npc_pants, 0.040);
        acc = npc_seg(acc, p, 13, 14, u_npc_pants, 0.035);
        acc = npc_seg(acc, p, 14, 15, u_npc_boot, 0.030);
        acc = npc_seg(acc, p, 0, 16, u_npc_pants, 0.050);
        acc = npc_seg(acc, p, 16, 17, u_npc_pants, 0.040);
        acc = npc_seg(acc, p, 17, 18, u_npc_pants, 0.035);
        acc = npc_seg(acc, p, 18, 19, u_npc_boot, 0.030);

        // базис головы: «вверх» — от макушки, взгляд несёт u_npc_face
        vec3 hup = normalize(u_npc_joints[5].xyz - u_npc_head.xyz);
        vec3 hfwd = normalize(u_npc_face.xyz - hup * dot(u_npc_face.xyz, hup) + vec3(1e-5));
        vec3 hside = normalize(cross(hfwd, hup));
        float hr = u_npc_head.w;

        // голова + нос-кнопка
        acc = sdf_smooth_union(acc, length(p - u_npc_head.xyz) - hr, u_npc_skin, 0.035);
        vec3 nc = u_npc_head.xyz + hfwd * (hr * 0.92) - hup * (hr * 0.10);
        acc = sdf_smooth_union(acc, length(p - nc) - hr * 0.20, u_npc_skin, 0.015);

        // кепка рыбака: аккуратные поля + низкая тулья, размер — от радиуса
        // головы. Сидит плотно на макушке и не заслоняет лицо.
        vec3 hc = u_npc_head.xyz + hup * (hr * 0.62);
        acc = sdf_smooth_union(acc,
                sd_ell_f(p, hc, hside, hup, hfwd, vec3(hr * 1.32, hr * 0.10, hr * 1.20)),
                u_npc_hat * 0.82, 0.018);
        acc = sdf_smooth_union(acc,
                sd_ell_f(p, hc + hup * (hr * 0.26), hside, hup, hfwd,
                        vec3(hr * 1.00, hr * 0.42, hr * 0.92)),
                u_npc_hat, 0.02);

        // глаза — выпуклые шарики, наполовину торчащие из лица: почти без
        // плавления (k=0.004), форма шара читается чётко и не тает в голове
        vec3 ec = u_npc_head.xyz + hfwd * (hr * 0.88) + hup * (hr * 0.12);
        float er = u_npc_eyes.z;
        acc = sdf_smooth_union(acc, length(p - (ec + hside * u_npc_eyes.y)) - er,
                vec3(0.97, 0.94, 0.88), 0.004);
        acc = sdf_smooth_union(acc, length(p - (ec - hside * u_npc_eyes.y)) - er,
                vec3(0.97, 0.94, 0.88), 0.004);
        return acc;
}

// ===== ЛИЦО РЫБАКА: радужка, зрачок, блики, морг, брови, рот =====
// Глаза живут в базисе головы — они всегда на лице, следят за игроком
// (зрачок смещён вдоль u_npc_face) и моргают (u_npc_eyes.x).
vec3 npc_paint(vec3 p, vec3 albedo) {
        float hr = u_npc_head.w;
        if (hr <= 0.001) {
                return albedo;
        }
        vec3 hup = normalize(u_npc_joints[5].xyz - u_npc_head.xyz);
        vec3 hfwd = normalize(u_npc_face.xyz - hup * dot(u_npc_face.xyz, hup) + vec3(1e-5));
        vec3 hside = normalize(cross(hfwd, hup));
        float er = u_npc_eyes.z;
        float blink = clamp(u_npc_eyes.x, 0.0, 1.0);
        vec3 ec = u_npc_head.xyz + hfwd * (hr * 0.88) + hup * (hr * 0.12);

        // брови — тёплые тёмные «пятнышки» над глазами (до глаз, чтобы
        // шарики глаз перекрывали края бровей, а не наоборот)
        for (int s = 0; s < 2; s++) {
                vec3 sg = (s == 0) ? hside : -hside;
                vec3 bc = ec + sg * u_npc_eyes.y + hup * (hr * 0.26) - hfwd * (hr * 0.14);
                vec3 bq = p - bc;
                vec3 bl = vec3(dot(bq, hside), dot(bq, hup), dot(bq, hfwd));
                float brow = 1.0 - smoothstep(0.72, 1.05,
                        length(bl / vec3(er * 1.75, er * 0.38, er * 0.90)));
                albedo = mix(albedo, vec3(0.24, 0.13, 0.09), brow * 0.8);
        }

        for (int s = 0; s < 2; s++) {
                vec3 sg = (s == 0) ? hside : -hside;
                vec3 eye_c = ec + sg * u_npc_eyes.y;
                vec3 d = p - eye_c;
                float r = length(d);
                // порог щедрый: hit-точка «гуляет» до 1 см (eps). Сама краска
                // гасится ПО УГЛУ у экватора шарика — радиальной границы на
                // видимой части нет, и ступеньки марша не превращаются в кольца
                if (r > er * 1.48) {
                        continue;
                }
                vec3 q = d / max(r, 1e-5);
                float ang = acos(clamp(dot(q, hfwd), -1.0, 1.0));
                // Живой взгляд: белок + плотный диск радужки + зрачок-пуговица
                // + один блик. Только ПЛОСКИЕ заливки — мягкие градиенты и
                // каймы складывались в «слои» под перспективой боковых шариков.
                float iris = 1.0 - smoothstep(0.54, 0.60, ang);
                float pupil = 1.0 - smoothstep(0.28, 0.34, ang);
                vec3 col = vec3(0.97, 0.95, 0.91);
                col = mix(col, vec3(0.14, 0.48, 0.56), iris);
                col = mix(col, vec3(0.05, 0.06, 0.09), pupil);
                vec3 hl = normalize(hfwd * 0.70 + hup * 0.60 + sg * 0.36);
                float shine = 1.0 - smoothstep(0.16, 0.23, acos(clamp(dot(q, hl), -1.0, 1.0)));
                col = mix(col, vec3(1.0), shine);
                // моргание: кожа сползает сверху вниз
                float lid = mix(1.30, -1.10, blink);
                float lidk = smoothstep(lid - 0.12, lid + 0.12, dot(q, hup));
                col = mix(col, albedo, lidk);
                // край краски — по углу у экватора шарика (в складке слияния);
                // радиальная часть — только страховочная, вне видимой зоны
                float dome = (1.0 - smoothstep(1.35, 1.55, ang))
                        * (1.0 - smoothstep(er * 1.38, er * 1.48, r));
                albedo = mix(albedo, col, dome);
        }

        // рот: тёмный овал под носом, открывается при разговоре
        vec3 mc = u_npc_head.xyz + hfwd * (hr * 0.92) - hup * (hr * 0.42);
        vec3 mq = p - mc;
        vec3 ml = vec3(dot(mq, hside), dot(mq, hup), dot(mq, hfwd));
        float open = clamp(u_npc_face.w, 0.0, 1.0);
        vec3 mr = vec3(hr * (0.36 + 0.22 * open), hr * (0.12 + 0.34 * open), hr * 0.42);
        float mo = 1.0 - smoothstep(0.72, 1.08, length(ml / mr));
        albedo = mix(albedo, vec3(0.16, 0.09, 0.08), mo * 0.92);
        return albedo;
}

// ===== СЦЕНА — единственная функция, знающая мир =====
// Возвращает (цвет.rgb, дистанция.w). Дистанция консервативна: пропущенные
// (далёкие) объекты учитываются через dskips — их сферическая граница,
// чтобы ray не переступил через невидимую рыбу.
// real_d — дистанция ТОЛЬКО до настоящих поверхностей (без skip-сфер).
// Skip-сферы — консервативные границы невидимых объектов; в силуэтном AA
// их учитывать нельзя: пролёт мимо границы считался бы «касанием» и пиксель
// красился чёрным (acc.rgb = 0 при невычисленном объекте) — это и есть
// «чёрный берег в пикселях», и главная нагрузка GPU (5 SDF на пиксель).
vec4 map_ex(vec3 p, out float real_d) {
        vec4 acc = vec4(0.0, 0.0, 0.0, 1e9);
        float dskips = 1e9;

        for (int i = 0; i < 7; i++) {
                float s = u_fish_meta[i].x;
                if (s < 0.001) {
                        continue;
                }
                vec3 C = u_fish_state[i].xyz;
                float bd = length(p - C) - 2.1 * s; // до сферической границы тела
                if (bd > 0.7 * s + 0.1) {
                        dskips = min(dskips, bd);
                        continue;
                }
                float body_flex = (i == 6) ? u_catch_flex : 1.0;
                vec4 f = fish_sdf(p, C, s, u_fish_state[i].w, u_fish_meta[i].y,
                        u_fish_tint[i], body_flex);
                acc = sdf_smooth_union(acc, f.w, f.rgb, 0.42 * s);
        }

        for (int j = 0; j < 12; j++) {
                vec4 d = u_drops[j];
                if (d.w < 0.004) {
                        continue;
                }
                float dd = length(p - d.xyz) - d.w;
                if (dd > 0.35) {
                        dskips = min(dskips, dd);
                        continue;
                }
                acc = sdf_smooth_union(acc, dd, u_drop_tint, 0.07);
        }

        // Три новых вида FishKit используют ту же сцену и тот же SDF raymarcher.
        for (int fi = 0; fi < FK_FISH; fi++) {
                float sF = u_fk_params[fi].x * u_fk_params[fi].w;
                if (sF < 0.001) {
                        continue;
                }
                float extF = fk_ext(int(u_fk_flags[fi].x + 0.5)) * sF
                        * (1.0 + 0.9 * u_fk_flags[fi].z) + 0.25;
                float bdF = length(p - u_fk_center[fi]) - extF;
                if (bdF > 0.6 * sF + 0.1) {
                        dskips = min(dskips, bdF);
                        continue;
                }
                vec4 f = fk_fish_sdf(p, fi);
                if (f.w < 1e8) {
                        acc = sdf_smooth_union(acc, f.w, f.rgb, 0.30 * sF);
                }
        }

        // Рыбак у причала — тот же «плавленый» стиль, что у песчаных рыб.
        if (u_npc_head.w > 0.001) {
                vec3 npc_c = (u_npc_joints[0].xyz + u_npc_head.xyz) * 0.5 + vec3(0.0, 0.25, 0.0);
                float bdN = length(p - npc_c) - 1.75;
                if (bdN > 0.35) {
                        dskips = min(dskips, bdN);
                } else {
                        vec4 nf = npc_sdf(p);
                        acc = sdf_smooth_union(acc, nf.w, nf.rgb, 0.12);
                }
        }

        real_d = acc.w;
        return vec4(acc.rgb, min(acc.w, dskips));
}

vec4 map(vec3 p) {
        float _rd;
        return map_ex(p, _rd);
}

float map_dist(vec3 p) { return map(p).w; }

// Тетраэдральный градиент (4 касания) — из оригинала.
vec3 estimate_normal(vec3 p) {
        float e = max(epsilon * 0.5, 0.002);
        vec2 k = vec2(1.0, -1.0);
        return normalize(
                k.xyy * map_dist(p + k.xyy * e) +
                k.yyx * map_dist(p + k.yyx * e) +
                k.yxy * map_dist(p + k.yxy * e) +
                k.xxx * map_dist(p + k.xxx * e));
}

void vertex() {
        // Пришиваем квад к near-плоскости -> полноэкранность
        // (reversed-Z: near = 1.0). Позиция ноды не важна.
        POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment() {
        float eps = max(epsilon, 1e-4);
        int steps = clamp(max_steps, 1, 512);
        vec2 ndc_xy = SCREEN_UV * 2.0 - 1.0;
        // Луч через пиксель — через far-плоскость (reversed-Z: far = 0).
        vec4 far_view = INV_PROJECTION_MATRIX * vec4(ndc_xy, 0.0, 1.0);
        far_view.xyz /= far_view.w;
        vec3 cam_pos = INV_VIEW_MATRIX[3].xyz;
        vec3 rd = normalize((INV_VIEW_MATRIX * vec4(normalize(far_view.xyz), 0.0)).xyz);
        float max_dist = min(max(max_ray_distance, 0.01), length(far_view.xyz));

        // Окклюзия: геометрия сцены останавливает луч.
        float depth_raw = texture(depth_texture, SCREEN_UV).r;
        float scene_t = -1.0;
        if (depth_raw > 0.0001) {
                vec4 dview = INV_PROJECTION_MATRIX * vec4(ndc_xy, depth_raw, 1.0);
                dview.xyz /= dview.w;
                scene_t = length(dview.xyz);
                max_dist = min(max_dist, scene_t);
        }

        // Transparent water is absent from the opaque depth texture on many
        // renderers. Intersect its mean plane explicitly so submerged SDF fish
        // cannot leak through as a permanent HUD-like silhouette.
        float water_surface_t = -1.0;
        vec3 water_surface_pos = vec3(0.0);
        bool water_surface_visible = false;
        if (cam_pos.y > u_water_level + 0.05 && rd.y < -0.02) {
                float candidate_t = (u_water_level - cam_pos.y) / rd.y;
                bool no_opaque_occluder = depth_raw <= 0.0001
                        || scene_t + 0.35 >= candidate_t;
                if (candidate_t > 0.0 && candidate_t < length(far_view.xyz)
                        && no_opaque_occluder) {
                        water_surface_t = candidate_t;
                        water_surface_pos = cam_pos + rd * candidate_t;
                        water_surface_visible = true;
                        max_dist = min(max_dist, candidate_t);
                }
        }

        float alpha = 0.0;
        vec3 out_col = vec3(0.0);
        float out_depth = depth_raw;

        // Сфера обитания: вне её делать нечего (и дёшево, и без артефактов).
        vec3 bc = vec3(u_center.x, u_water_level, u_center.y);
        vec3 oc = cam_pos - bc;
        float bb = dot(oc, rd);
        float cc = dot(oc, oc) - u_bounds_r * u_bounds_r;
        float disc = bb * bb - cc;

        if (disc > 0.0) {
                float sq = sqrt(disc);
                float t_near = max(-bb - sq, 0.0);
                float t_far = min(-bb + sq, max_dist);

                if (t_near < t_far) {
                        // Конус пикселя — для антиалиасных силуэтов.
                        float pixel_angle = 2.0 / (VIEWPORT_SIZE.y * PROJECTION_MATRIX[1][1]);
                        float t = t_near;
                        bool hit = false;
                        float coverage = 1e9;
                        float t_edge = t_near;
                        for (int s = 0; s < steps; s++) {
                                if (t + eps > t_far) {
                                        break;
                                }
                                float real_d;
                                float d = map_ex(cam_pos + rd * t, real_d).w;
                                if (d < eps) {
                                        hit = true;
                                        break;
                                }
                                // Силуэтный AA — только по настоящим поверхностям:
                                // skip-сферы не дают «касание» и чёрную заливку.
                                float ratio = real_d / max(t * pixel_angle, 1e-6);
                                if (ratio < coverage) {
                                        coverage = ratio;
                                        t_edge = t;
                                }
                                // Минимальный шаг 2 см: у границ skip-сфер d->0
                                // и луч ползёт по миллиметру, сжигая весь бюджет
                                // шагов (это и грело видеокарту).
                                t += max(d, 0.02);
                        }

                        if (hit || coverage < 1.0) {
                                // ---- попадание: свет «мокрого песка» ----
                                float shade_t = t;
                                if (hit) {
                                        alpha = 1.0;
                                } else {
                                        alpha = clamp(1.0 - coverage, 0.0, 1.0);
                                        shade_t = t_edge;
                                }
                                vec3 p = cam_pos + rd * shade_t;
                                vec4 sc = map(p);
                                vec3 albedo = npc_paint(p, sc.rgb);
                                vec3 n = estimate_normal(p);
                                vec3 v = -rd;
                                vec3 l = normalize(sun_dir);

                                float ndl = dot(n, l);
                                float wrap = clamp((ndl + 0.45) / 1.05, 0.0, 1.0);
                                vec3 col = albedo * (sky_col * 0.55
                                        + sand_sunny * (0.22 + 0.95 * wrap));
                                // Луна ночью: дневная палитра гаснет почти в ноль,
                                // и без холодного ключевого света существо теряло
                                // объём и выглядело «нетекстурным» пятном.
                                vec3 md = normalize(vec3(-l.x, 0.55, -l.z));
                                float mnl = clamp(dot(n, md) * 0.5 + 0.5, 0.0, 1.0);
                                col += albedo * vec3(0.30, 0.38, 0.58)
                                        * (0.30 + 0.70 * mnl) * night_amount;
                                // солнечная кромка — как у моря
                                col += sand_hot * pow(clamp(ndl, 0.0, 1.0), 2.2) * 0.26;
                                // тёплый отсвет снизу, отскочивший от дюн
                                vec3 B = normalize(vec3(-l.x, 0.55, -l.z));
                                col += vec3(1.00, 0.58, 0.32)
                                        * clamp(dot(n, B), 0.0, 1.0) * 0.20 * (1.0 - wrap * 0.6);
                                // блик + сиреневый рим
                                vec3 h = normalize(l + v);
                                float ndv = clamp(dot(n, v), 0.0, 1.0);
                                col += vec3(1.0, 0.85, 0.60)
                                        * pow(clamp(dot(n, h), 0.0, 1.0), 42.0) * 0.55;
                                col += sand_shade * pow(1.0 - ndv, 3.0) * 0.30;

                                // глиттер «мокрого песка»: редкие вспышки на теле
                                vec2 gp = floor(p.xz * 5.0);
                                float gid = hash12(gp);
                                float gsel = step(1.0 - 0.15, gid);
                                vec3 Hg = normalize(h + vec3(
                                        hash12(gp + vec2(3.1, 7.7)),
                                        hash12(gp + vec2(5.7, 1.3)),
                                        hash12(gp + vec2(9.2, 4.4))) - 1.5);
                                float glit = pow(clamp(dot(n, Hg), 0.0, 1.0), 50.0) * gsel
                                        * (0.5 + 0.5 * sin(u_time * 6.0 + gid * 71.0));
                                col += vec3(1.0, 0.92, 0.70) * glit * 1.2 * exp(-shade_t * 0.004);

                                // дымка — та же формула, что у моря
                                float fog = 1.0 - exp(-pow(shade_t / fog_distance, 2.1));
                                float above = smoothstep(-2.0, 16.0, p.y - cam_pos.y);
                                vec3 fcol = mix(horizon_col, sky_col, above * 0.6);
                                col = mix(col, fcol, fog);

                                out_col = col;
                                vec4 clip = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(p, 1.0));
                                out_depth = clip.z / clip.w;
                        } else {
                                // ---- Тонкий след по поверхности моря ----
                                // Поверхность выбирается ray/plane пересечением, поскольку
                                // прозрачная вода не всегда попадает в depth-текстуру.
                                if (water_surface_visible && cam_pos.y > u_water_level + 0.05
                                                && rd.y < -0.02) {
                                        float fz = 1.0 - exp(-pow(water_surface_t / fog_distance, 2.1));
                                        if (fz < 0.97) {
                                                float m = 0.0;
                                                vec3 tw = vec3(0.0);
                                                for (int i = 0; i < 7; i++) {
                                                        float s = u_fish_meta[i].x;
                                                        if (s < 0.001) {
                                                                continue;
                                                        }
                                                        vec3 C = u_fish_state[i].xyz;
                                                        float sub = u_water_level - C.y;
                                                        if (sub < 0.05) {
                                                                continue; // выпрыгнувшее тело рисуется SDF-ом
                                                        }
                                                        vec2 e = water_surface_pos.xz - C.xz;
                                                        vec2 dir2 = vec2(cos(u_fish_state[i].w),
                                                                sin(u_fish_state[i].w));
                                                        vec2 prp2 = vec2(-dir2.y, dir2.x);
                                                        float along = dot(e, dir2);
                                                        float across = abs(dot(e, prp2));
                                                        // Узкий след за рыбой вместо постоянного пятна-силуэта.
                                                        float pixel_world = scene_t * pixel_angle;
                                                        float width = max(s * 0.08, pixel_world * 1.35);
                                                        float tail_in = smoothstep(-5.0 * s, -4.0 * s, along);
                                                        float tail_out = 1.0 - smoothstep(-0.75 * s, -0.12 * s, along);
                                                        float edge = 1.0 - smoothstep(width * 0.45, width, across);
                                                        float ripple = 0.62 + 0.38 * sin(along * 3.2
                                                                + u_time * 2.4 + u_fish_meta[i].y);
                                                        float depth_fade = exp(-sub / max(s * 3.0, 1.0));
                                                        float mi = tail_in * tail_out * edge * ripple
                                                                * depth_fade * (1.0 - fz);
                                                        m = max(m, mi);
                                                        tw += u_fish_tint[i] * mi;
                                                }
                                                if (m > 0.003) {
                                                        vec3 avg = tw / max(m, 1e-4);
                                                        vec3 scene_col = texture(u_screen, SCREEN_UV).rgb;
                                                        out_col = scene_col * (1.0 - 0.12 * m)
                                                                + avg * 0.18 * m;
                                                        alpha = clamp(m * u_veil_strength * 0.35, 0.0, 0.10);
                                                }
                                        }
                        }
                }
        }
        }

        ALBEDO = out_col;
        ALPHA = alpha;
        DEPTH = out_depth;
}
