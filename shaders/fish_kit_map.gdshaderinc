// =====================================================================
// КИТ ПЕСЧАНЫХ РЫБ — SDF-карта 7 видов (подключается из sand_sea_sdf.gdshader):
//     #include "res://shaders/fish_kit_map.gdshaderinc"
// Инклуд ставится ПОСЛЕ rot2()/sd_ell()/sdf_smooth_union()/hash12()
// и ПЕРЕД map(). Uniform-ы u_fk_* объявлены в sand_sea_sdf.gdshader,
// пушит их fish_kit.gd (CPU-скелет: FK-цепочка костей + нравы видов).
//
// Порт fish_kit.html 1:1 (в превью FK_FISH = 1, здесь 3 — код тот же).
// Каждый вид = кости-эллипсоиды + плавники/зубы/иглы/усы, ПОСАЖЕННЫЕ на
// кадры костей: кость шевелится — плавник едет вместе с ней.
// =====================================================================

// ---- параметры видов (индекс = вид; зеркалит SPECIES в fish_kit.gd) ----
float fk_upm(int sp) { // вертикальный множитель тела (лента — высокая, манта — плоская)
        if (sp == 1) { return 1.0; }
        if (sp == 3) { return 0.48; }
        if (sp == 4) { return 1.05; }
        if (sp == 2) { return 0.95; }
        return 1.0;
}

float fk_sdm(int sp) { // боковой множитель (лента узкая)
        if (sp == 1) { return 0.85; }
        if (sp == 4) { return 0.85; }
        return 1.0;
}

float fk_axm(int sp) { // продольный множитель (вытянутость кости)
        if (sp == 1) { return 1.50; }
        if (sp == 3) { return 1.30; }
        if (sp == 4) { return 1.30; }
        if (sp == 5 || sp == 6) { return 1.05; }
        return 1.15;
}

float fk_ext(int sp) { // радиус охвата вида (для dskips), × размер
        if (sp == 1) { return 2.4; }
        if (sp == 2) { return 1.8; }
        if (sp == 3) { return 1.9; }
        if (sp == 4) { return 2.0; }
        if (sp == 5) { return 1.3; }
        if (sp == 6) { return 2.1; }
        return 2.2;
}

float fk_meltk(int sp) { // ширина плавления тела: у плоских/мелких — уже
        if (sp == 0) { return 0.42; } // утверждённый облик странника
        if (sp == 1) { return 0.12; } // угорь — стройная змейка (0.26 раздувало
                                      // тело в сосиску и топило кайму-плавник)
        if (sp == 3) { return 0.20; }
        if (sp == 5) { return 0.26; }
        return 0.30;
}

// капсула AB радиуса r (усы, бич-хвост, иглы, зубы, посох эски)
float fk_capsule(vec3 p, vec3 a, vec3 b, float r) {
        vec3 pa = p - a;
        vec3 ba = b - a;
        float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-9), 0.0, 1.0);
        return length(pa - ba * h) - r;
}

// «лопасть» — сплюснутый эллипсоид от a к b: поперёк width, по нормали thin
float fk_blade(vec3 p, vec3 a, vec3 b, vec3 n, float width, float thin) {
        vec3 x = b - a;
        float L = max(length(x), 1e-5);
        x /= L;
        vec3 z = cross(x, n);
        float lz = length(z);
        z = lz > 1e-4 ? z / lz
                        : normalize(cross(x, abs(x.y) > 0.9 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0)));
        vec3 y = normalize(cross(z, x));
        vec3 q = p - (a + b) * 0.5;
        return sd_ell(vec3(dot(q, x), dot(q, y), dot(q, z)),
                        vec3(L * 0.55, width * 0.5, thin * 0.5));
}

// ---- кадр кости: f — к хвосту, sd — борт, up — вверх ----
// Кадр выводится из СОСЕДНИХ КОСТЕЙ: кости и есть подвижный скелет.
void fk_frame(int fi, int k, int N, out vec3 f, out vec3 sd, out vec3 up) {
        vec3 dv;
        if (k > 0 && k < N - 1) {
                dv = u_fk_bone[fi * FK_BONE + k + 1].xyz - u_fk_bone[fi * FK_BONE + k - 1].xyz;
        } else if (k == 0) {
                dv = u_fk_bone[fi * FK_BONE + 1].xyz - u_fk_bone[fi * FK_BONE].xyz;
        } else {
                dv = u_fk_bone[fi * FK_BONE + N - 1].xyz - u_fk_bone[fi * FK_BONE + N - 2].xyz;
        }
        f = length(dv) > 1e-5 ? normalize(dv) : vec3(0.0, 0.0, 1.0);
        vec3 ref = abs(f.y) > 0.95 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0);
        sd = normalize(cross(f, ref));
        up = cross(sd, f);
}

// ЦЕПНОЙ ГРЕБЕНЬ: лопасти между СОСЕДНИМИ костями i0..i1 — каждая прижата
// к своей точке хребта, поэтому гребень едет по волне вместе со спиной и
// не может «отклеиться» (базы утоплены в плоть на глубину hb; sgn +1 —
// вверх, -1 — вниз). Высота профилем: H0 → пик HP в uP → H1, перекрытие
// 0.40*L сглаживает цепочку в сплошную лопасть.
void fk_ridge(inout vec4 acc, vec3 p, int fi, int N, int i0, int i1, float hb,
        float sgn, float H0, float HP, float H1, float uP, float th, vec3 col,
        float ml) {
        i0 = i0 < 0 ? 0 : i0;
        i1 = i1 > N - 1 ? N - 1 : i1;
        float den = max(float(i1 - i0), 1.0);
        for (int kk = 0; kk < 12; kk++) {
                int k = i0 + kk;
                if (k >= i1) {
                        break;
                }
                vec3 f1;
                vec3 sd1;
                vec3 up1;
                fk_frame(fi, k, N, f1, sd1, up1);
                vec3 f2;
                vec3 sd2;
                vec3 up2;
                fk_frame(fi, k + 1, N, f2, sd2, up2);
                float uA = float(k - i0) / den;
                float uB = float(k + 1 - i0) / den;
                float HA = H0 + (HP - H0) * smoothstep(0.0, uP, uA)
                                + (H1 - HP) * smoothstep(uP, 1.0, uA);
                float HB = H0 + (HP - H0) * smoothstep(0.0, uP, uB)
                                + (H1 - HP) * smoothstep(uP, 1.0, uB);
                float rA = u_fk_bone[fi * FK_BONE + k].w;
                float rB = u_fk_bone[fi * FK_BONE + k + 1].w;
                // пластинка-эллипсоид на середину сегмента (примитив sd_ell —
                // стабилен на всех GPU, в отличие от лопастей fk_blade в цепочке)
                vec3 b0 = u_fk_bone[fi * FK_BONE + k].xyz;
                vec3 b1 = u_fk_bone[fi * FK_BONE + k + 1].xyz;
                vec3 fl = normalize(b1 - b0);
                vec3 upm = up1 + up2;
                upm = normalize(upm - fl * dot(fl, upm));
                vec3 sdl = cross(fl, upm);
                float rm = (rA + rB) * 0.5;
                float Hm = (HA + HB) * 0.5;
                float Lseg = max(length(b1 - b0), 1e-5);
                vec3 c = (b0 + b1) * 0.5 + upm * (sgn * (rm * hb + Hm * 0.35));
                vec3 q = p - c;
                vec3 ql = vec3(dot(q, fl), dot(q, upm), dot(q, sdl));
                acc = sdf_smooth_union(acc, sd_ell(ql,
                                vec3(Lseg * 0.75, Hm * 0.85 + rm * 0.25, th * 0.5)),
                                col, ml);
        }
}

// мягкое значение-шум: пятна/горошек без «клеток»
float fk_vnoise(vec2 q) {
        vec2 i = floor(q), f = fract(q);
        vec2 w = f * f * (3.0 - 2.0 * f);
        float a = hash12(i), b = hash12(i + vec2(1.0, 0.0));
        float c2 = hash12(i + vec2(0.0, 1.0)), d = hash12(i + vec2(1.0, 1.0));
        return mix(mix(a, b, w.x), mix(c2, d, w.x), w.y);
}

// ---- окраска тела по прототипу (контртень + узоры) ----
// c — высота в долях радиуса (1 спина, -1 брюхо), dside — борт, u — 0 морда → 1 хвост
vec3 fk_paint(int sp, float u, float c, float dside, vec3 top, vec3 belly) {
        // манте — резкая граница, пухляку — низкая (олива до боков), угрю — высокая
        float cth = sp == 3 ? 0.18 : (sp == 5 ? 0.25 : (sp == 1 ? 0.85 : 0.60));
        vec3 col = mix(belly, top, smoothstep(-0.45, cth, c)); // контртень (Thayer)
        if (sp == 1) {        // угорь: белые искры по сапфиру + чёрное горло
                float spark = smoothstep(0.80, 0.70,
                        fk_vnoise(vec2(u * 14.0 + 2.0, c * 4.0 + 7.0)) * 0.62
                                + fk_vnoise(vec2(u * 30.0, c * 9.0 + 1.0)) * 0.38);
                col = mix(col, vec3(0.94, 0.97, 1.05),
                        spark * 0.45 * smoothstep(0.15, 0.55, c));
                col = mix(col, vec3(0.03, 0.03, 0.05),
                        smoothstep(0.34, 0.06, u) * smoothstep(0.30, -0.15, c) * 0.85);
                col = mix(col, col * 0.60, smoothstep(0.88, 0.99, u));
        } else if (sp == 2) { // фонарник: светлый низ, темнеет к хвосту
                col = mix(col, col * 1.45, smoothstep(-0.15, -0.75, c));
                col = mix(col, vec3(0.05, 0.04, 0.06), smoothstep(0.55, 0.95, u) * 0.5);
        } else if (sp == 3) { // манта: белые пятна-«плечи» за головой + тёмный бич
                float band = smoothstep(0.22, 0.12, u) * smoothstep(0.03, 0.10, u);
                float sh = band * smoothstep(0.22, 0.40, abs(dside))
                        * smoothstep(0.10, 0.45, c);
                col = mix(col, vec3(0.88, 0.86, 0.80), sh * 0.75);
                col = mix(col, col * 0.50, smoothstep(0.74, 0.96, u));
        } else if (sp == 4) { // стрела: полосы тунца + серебряная боковая
                col = mix(col, col * 0.68,
                        smoothstep(0.32, 0.02, abs(sin(u * 24.0))) * smoothstep(-0.15, 0.55, c));
                col = mix(col, belly * 1.05, (1.0 - smoothstep(0.05, 0.30, abs(c))) * 0.5);
        } else if (sp == 5) { // пухляк: мягкие кляксы-пятна + маска у глаз (диодон)
                float nb = fk_vnoise(vec2(u * 7.0, c * 4.5 + 3.1)) * 0.55
                        + fk_vnoise(vec2(u * 16.0 + 4.0, c * 10.0)) * 0.45;
                float blot = smoothstep(0.56, 0.42, nb)
                        * smoothstep(-0.55, -0.10, c) * smoothstep(0.90, 0.50, c);
                col = mix(col, col * 0.40, blot * 0.8);
                col = mix(col, col * 0.26,
                        smoothstep(0.45, 0.12, u) * smoothstep(0.10, 0.50, c)
                                * smoothstep(0.30, 0.62, abs(dside)));
        } else if (sp == 6) { // усач: тёмно-красная боковая линия (барабулька)
                col = mix(col, vec3(0.44, 0.12, 0.08), smoothstep(0.20, 0.04, abs(c)) * 0.8);
                col = mix(col, col * 0.78, smoothstep(0.80, 0.98, u));
        }
        return col;
}

// ---- ТЕЛО ВИДА fi: кости-эллипсоиды + плавники/зубы/иглы/усы по видам ----
vec4 fk_fish_sdf(vec3 p, int fi) {
        vec4 acc = vec4(0.0, 0.0, 0.0, 1e9);
        float sAll = u_fk_params[fi].x;
        float morph = u_fk_params[fi].w;
        if (sAll < 0.001 || morph < 0.003) {
                return acc;
        }
        float s = sAll * morph;
        float ph = u_fk_params[fi].y;
        float flap = u_fk_params[fi].z;
        int sp = int(u_fk_flags[fi].x + 0.5);
        float melt = u_fk_flags[fi].y;
        float infl = u_fk_flags[fi].z;
        int N = int(u_fk_flags[fi].w + 0.5);
        if (N < 2) {
                return acc;
        }
        float act = u_fk_glow[fi].w;
        vec3 top = u_fk_top[fi];
        vec3 belly = u_fk_belly[fi];
        vec3 accC = u_fk_acc[fi];
        vec3 glowC = u_fk_glow_c[fi];
        float km = s * melt * fk_meltk(sp);
        int base = fi * FK_BONE;

        // 1) тело — «кости» как эллипсоиды плоти
        for (int k = 0; k < FK_BONE; k++) {
                if (k >= N) {
                        break;
                }
                vec3 bp = u_fk_bone[base + k].xyz;
                float r = u_fk_bone[base + k].w;
                vec3 f;
                vec3 sd;
                vec3 up;
                fk_frame(fi, k, N, f, sd, up);
                float t = float(k) / max(float(N - 1), 1.0);
                vec3 q = p - bp;
                vec3 ql = vec3(dot(q, f), dot(q, up), dot(q, sd));
                vec3 rad = vec3(r * fk_axm(sp), r * fk_upm(sp), r * fk_sdm(sp));
                vec3 col;
                if (sp == 0) {
                        col = mix(top * 1.15, top * 0.70, t); // утверждённый облик странника
                        // горошек: оливковые точки на джиттер-решётке
                        vec2 pa = vec2(ql.y / max(rad.y, 1e-4), ql.z / max(rad.z, 1e-4));
                        float az = atan(pa.y, pa.x);
                        vec2 gp2 = vec2(t * 11.0, az * 3.2 + 40.0);
                        vec2 gc = floor(gp2), gf = fract(gp2);
                        float md = 8.0;
                        for (int py = -1; py <= 1; py++) {
                                for (int px = -1; px <= 1; px++) {
                                        vec2 o = vec2(float(px), float(py));
                                        vec2 j = vec2(hash12(gc + o), hash12(gc + o + 7.31));
                                        md = min(md, length(gf - o - j * 0.8));
                                }
                        }
                        float pea = smoothstep(0.30, 0.17, md) * smoothstep(-0.10, 0.35, pa.x);
                        col = mix(col, col * vec3(0.55, 0.60, 0.48), pea * 0.85);
                } else {
                        col = fk_paint(sp, t, ql.y / max(rad.y, 1e-4), ql.z / max(rad.z, 1e-4),
                                        top, belly);
                }
                acc = sdf_smooth_union(acc, sd_ell(ql, rad), col, km);
        }

        // кадры головы и хвоста — на них сажаются плавники
        vec3 f0;
        vec3 sd0;
        vec3 up0;
        fk_frame(fi, 0, N, f0, sd0, up0);
        vec3 fT;
        vec3 sdT;
        vec3 upT;
        fk_frame(fi, N - 1, N, fT, sdT, upT);
        vec3 stem = u_fk_bone[base + N - 1].xyz;
        vec3 hw0 = normalize(u_fk_bone[base].xyz - u_fk_bone[base + 1].xyz); // к морде
        vec3 hh = -fT;

        // 2) морда
        if (sp == 0) { // странник — маленький нос (утверждённый облик)
                vec3 sn = u_fk_bone[base].xyz + hw0 * (0.576 * s);
                acc = sdf_smooth_union(acc, length(p - sn) - 0.16 * s, top * 0.92, 0.22 * s);
        } else if (sp == 2) { // фонарник — крупная шаровая пасть
                vec3 sn = u_fk_bone[base].xyz + hw0 * (0.26 * s);
                acc = sdf_smooth_union(acc, length(p - sn) - 0.30 * s, top * 0.95, 0.20 * s);
        } else if (sp == 1) { // угорь — заострённая морда
                vec3 sn = u_fk_bone[base].xyz + hw0 * (0.30 * s);
                vec3 qs = p - sn;
                vec3 qsl = vec3(dot(qs, hw0), dot(qs, up0), dot(qs, sd0));
                acc = sdf_smooth_union(acc, sd_ell(qsl, vec3(0.15, 0.055, 0.055) * s),
                                top * 0.95, 0.10 * s);
        } else if (sp == 6) { // усач — заострённое рыльце
                vec3 sn = u_fk_bone[base].xyz + hw0 * (0.28 * s);
                vec3 qs = p - sn;
                vec3 qsl = vec3(dot(qs, hw0), dot(qs, up0), dot(qs, sd0));
                acc = sdf_smooth_union(acc, sd_ell(qsl, vec3(0.16, 0.075, 0.075) * s),
                                top * 0.95, 0.12 * s);
        }

        // 3) хвост
        if (sp == 0) { // лопасть-«ласта» (утверждённая формула странника)
                vec3 qt = p - stem;
                vec3 ql = vec3(dot(qt, hh), dot(qt, upT), dot(qt, sdT));
                vec2 qu = rot2(ql.xy, 0.62) + vec2(0.36 * s, 0.0);
                vec2 qd = rot2(ql.xy, -0.50) + vec2(0.32 * s, 0.0);
                float du = sd_ell(vec3(qu.x, qu.y, ql.z), vec3(0.34 * s, 0.095 * s, 0.038 * s));
                float dl = sd_ell(vec3(qd.x, qd.y, ql.z), vec3(0.30 * s, 0.085 * s, 0.034 * s));
                acc = sdf_smooth_union(acc, du, top * 0.90, 0.15 * s);
                acc = sdf_smooth_union(acc, dl, top * 0.90, 0.15 * s);
        } else if (sp == 1 || sp == 2 || sp == 5) { // веер (угорь/фонарник/пухляк)
                vec3 fs = sp == 2 ? vec3(0.18, 0.40, 0.07) : (sp == 1 ? vec3(0.10, 0.20, 0.035)
                                : vec3(0.13, 0.24, 0.05));
                vec3 c = stem + fT * (0.09 * s);
                vec3 qv = p - c;
                vec3 qvl = vec3(dot(qv, fT), dot(qv, upT), dot(qv, sdT));
                acc = sdf_smooth_union(acc, sd_ell(qvl, fs * s), accC * 0.9, 0.10 * s);
        } else if (sp == 3) { // бич-хвост манты: две капсулы с волной
                float wl = 1.5 * s;
                vec3 b = stem + fT * (0.75 * s) - upT * (0.12 * s) + sdT * (sin(ph - 2.0) * 0.15 * s);
                vec3 c2 = b + fT * (0.75 * s) - upT * (0.20 * s) + sdT * (sin(ph - 3.1) * 0.20 * s);
                acc = sdf_smooth_union(acc, fk_capsule(p, stem, b, 0.020 * s), top * 0.8, 0.06 * s);
                acc = sdf_smooth_union(acc, fk_capsule(p, b, c2, 0.011 * s), top * 0.75, 0.05 * s);
        } else if (sp == 4) { // серп тунца (лунный хвост)
                vec3 qt = p - stem;
                vec3 ql = vec3(dot(qt, hh), dot(qt, upT), dot(qt, sdT));
                vec2 qu = rot2(ql.xy, 0.95) + vec2(0.40 * s, 0.0);
                vec2 qd = rot2(ql.xy, -0.92) + vec2(0.38 * s, 0.0);
                float du = sd_ell(vec3(qu.x, qu.y, ql.z), vec3(0.50 * s, 0.105 * s, 0.032 * s));
                float dl = sd_ell(vec3(qd.x, qd.y, ql.z), vec3(0.48 * s, 0.100 * s, 0.030 * s));
                acc = sdf_smooth_union(acc, du, top * 0.95, 0.12 * s);
                acc = sdf_smooth_union(acc, dl, top * 0.95, 0.12 * s);
        } else if (sp == 6) { // гетероцеркальный хвост осетра: верхняя лопасть длиннее
                vec3 qt = p - stem;
                vec3 ql = vec3(dot(qt, hh), dot(qt, upT), dot(qt, sdT));
                vec2 qu = rot2(ql.xy, 0.60) + vec2(0.30 * s, 0.0);
                vec2 qd = rot2(ql.xy, -0.38) + vec2(0.20 * s, 0.0);
                float du = sd_ell(vec3(qu.x, qu.y, ql.z), vec3(0.34 * s, 0.10 * s, 0.034 * s));
                float dl = sd_ell(vec3(qd.x, qd.y, ql.z), vec3(0.22 * s, 0.075 * s, 0.028 * s));
                acc = sdf_smooth_union(acc, du, top * 0.80, 0.12 * s);
                acc = sdf_smooth_union(acc, dl, top * 0.80, 0.12 * s);
        }

        // 4) грудные плавники (у манты — ГОРИЗОНТАЛЬНЫЕ КРЫЛЬЯ: хорда вдоль
        //    хода, тонкость по вертикали; взмах вокруг оси хода, волна к кончику)
        if (sp == 3) {
                for (int wside = 0; wside < 2; wside++) {
                        float sgn = wside == 0 ? 1.0 : -1.0;
                        // ЖЁСТКОЕ крыло: сегменты коллинеарны — нет складки и «перетекания массы»
                        vec3 wb = u_fk_bone[base + 1].xyz + sd0 * (sgn * u_fk_bone[base + 1].w * 0.55)
                                - up0 * (u_fk_bone[base + 1].w * 0.25);
                        vec3 w1 = normalize(sd0 * (sgn * cos(flap)) - up0 * (sin(flap) * 0.55)
                                - f0 * 0.22);
                        vec3 t1 = wb + w1 * (0.85 * s);
                        vec3 t2 = t1 + w1 * (0.60 * s)
                                - up0 * (sin(flap - 0.55) * 0.08 * s);
                        // хорда вдоль хода (f0) — лопасть ЛЕЖИТ горизонтально
                        acc = sdf_smooth_union(acc, fk_blade(p, wb, t1, f0, 0.52 * s, 0.05 * s),
                                        top * 0.92, 0.06 * s);
                        acc = sdf_smooth_union(acc, fk_blade(p, t1, t2, f0, 0.34 * s, 0.04 * s),
                                        top * 0.85, 0.05 * s);
                }
                for (int wside = 0; wside < 2; wside++) { // головные «рога»
                        float sgn = wside == 0 ? 1.0 : -1.0;
                        vec3 cb = u_fk_bone[base].xyz + hw0 * (0.40 * s) + sd0 * (sgn * 0.16 * s)
                                - up0 * (0.04 * s);
                        vec3 ct = cb + hw0 * (0.30 * s) + up0 * (0.10 * s)
                                + sd0 * (sgn * 0.10 * s * sin(ph * 1.3 + sgn * 1.2));
                        acc = sdf_smooth_union(acc, fk_blade(p, cb, ct, up0, 0.10 * s, 0.035 * s),
                                        top * 0.95, 0.05 * s);
                }
        } else {
                float pl = sp == 0 ? 0.46 : (sp == 1 ? 0.20 : (sp == 2 ? 0.34
                                : (sp == 4 ? 0.40 : (sp == 5 ? 0.26 : 0.38)))) * s;
                float pw = sp == 0 ? 0.17 : (sp == 1 ? 0.12 : (sp == 2 ? 0.22
                                : (sp == 4 ? 0.14 : (sp == 5 ? 0.19 : 0.20)))) * s;
                float pth = sp == 0 ? 0.055 : (sp == 1 ? 0.04 : (sp == 2 ? 0.07
                                : (sp == 4 ? 0.045 : (sp == 5 ? 0.06 : 0.055)))) * s;
                float r1 = u_fk_bone[base + 1].w;
                for (int wside = 0; wside < 2; wside++) {
                        float sgn = wside == 0 ? 1.0 : -1.0;
                        vec3 wb = u_fk_bone[base + 1].xyz + sd0 * (sgn * r1 * 0.70) - up0 * (r1 * 0.20);
                        vec3 tip = wb + (sd0 * (sgn * cos(flap)) - up0 * (sin(flap))) * pl;
                        acc = sdf_smooth_union(acc, fk_blade(p, wb, tip, f0, pw, pth),
                                        accC * 0.92, 0.06 * s);
                }
        }

        // 5) видовые детали
        if (sp == 0) { // спинной гребень-тор (утверждённый)
                vec3 q = p - (u_fk_bone[base + 2].xyz + f0 * (0.24 * s) + up0 * (0.30 * s));
                vec2 tq = vec2(length(vec2(dot(q, f0), dot(q, up0))) - 0.17 * s, dot(q, sd0));
                acc = sdf_smooth_union(acc, length(tq) - 0.085 * s, top * 1.08, 0.12 * s);
        } else if (sp == 1) { // УГОРЬ: жёлтая кайма-плавник вдоль спины и брюха
                // кайма лопастями между СОСЕДНИМИ костями — едет по волне вместе
                // со спиной. Глюк прошлой версии: корни сидели на коже (1.02r) и
                // тонули в melt-вздутии тела — теперь корни ПОДНЯТЫ (1.25r), а
                // ширина увеличена: кайма непрерывна и не «мигает»
                for (int k = 1; k < N - 2; k++) {
                        vec3 f;
                        vec3 sd;
                        vec3 up;
                        fk_frame(fi, k, N, f, sd, up);
                        vec3 f2;
                        vec3 sd2;
                        vec3 up2;
                        fk_frame(fi, k + 1, N, f2, sd2, up2);
                        float t = float(k) / max(float(N - 1), 1.0);
                        vec3 fb = u_fk_bone[base + k].xyz + up * (u_fk_bone[base + k].w * 1.25);
                        vec3 fbn = u_fk_bone[base + k + 1].xyz
                                        + up2 * (u_fk_bone[base + k + 1].w * 1.25);
                        float wD = (0.16 - 0.08 * t) * s; // кайма тает к хвосту
                        acc = sdf_smooth_union(acc,
                                        fk_blade(p, fb, fbn, up, wD, 0.020 * s),
                                        accC * (1.0 + 0.30 * act), 0.03 * s);
                        vec3 vb = u_fk_bone[base + k].xyz - up * (u_fk_bone[base + k].w * 1.25);
                        vec3 vbn = u_fk_bone[base + k + 1].xyz
                                        - up2 * (u_fk_bone[base + k + 1].w * 1.25);
                        float wV = (0.10 - 0.05 * t) * s;
                        acc = sdf_smooth_union(acc,
                                        fk_blade(p, vb, vbn, up, wV, 0.016 * s),
                                        accC * 0.85, 0.03 * s);
                }
        } else if (sp == 2) { // УДИЛЬЩИК: ЖЕЛЕЙНАЯ удочка-иллиций, зубы, фотофоры
                vec3 lb = u_fk_bone[base].xyz + hw0 * (0.10 * s) + up0 * (u_fk_bone[base].w * 0.95);
                vec3 lt = u_fk_glow[fi].xyz;        // ядро эски (верле на CPU)
                float br = u_fk_lure[fi].w;         // радиус луковицы
                if (br > 0.001) {
                        vec3 midL = u_fk_lure[fi].xyz;      // колено посоха (тоже верле)
                        acc = sdf_smooth_union(acc, fk_capsule(p, lb, midL, 0.012 * s),
                                        top * 0.6, 0.02 * s);
                        acc = sdf_smooth_union(acc, fk_capsule(p, midL, lt, 0.009 * s),
                                        top * 0.6, 0.018 * s);
                        // желе: ядро + догоняющий комок + микрокомок, плавятся в каплю
                        float pulse = u_fk_lure2[fi].w;
                        float bs = br * (1.0 + 0.09 * sin(u_time * 4.2) * (0.35 + 0.65 * pulse));
                        vec3 jA = u_fk_lure2[fi].xyz;
                        vec3 jB = -0.55 * jA - up0 * (0.35 * bs);
                        acc = sdf_smooth_union(acc, length(p - lt) - bs,
                                        glowC * (1.5 + 2.4 * act), 0.035 * s);
                        acc = sdf_smooth_union(acc, length(p - lt - jA) - bs * 0.58,
                                        glowC * (1.4 + 2.0 * act), 0.05 * s);
                        acc = sdf_smooth_union(acc, length(p - lt - jB) - bs * 0.40,
                                        glowC * (1.3 + 1.8 * act), 0.05 * s);
                }
                vec3 mouth = u_fk_bone[base].xyz + hw0 * (0.26 * s);
                for (int i = 0; i < 6; i++) {
                        float ang = 6.28318530718 * float(i) / 6.0;
                        vec3 off = sd0 * (cos(ang) * 0.55) + up0 * (sin(ang) * 0.55);
                        vec3 tb = mouth + off * (0.30 * s * 0.92);
                        vec3 tt = tb + off * (0.035 * s) + hw0 * (0.10 * s) - up0 * (0.015 * s);
                        acc = sdf_smooth_union(acc, fk_capsule(p, tb, tt, 0.011 * s),
                                        vec3(0.88, 0.84, 0.72), 0.02 * s);
                }
                for (int k = 1; k <= 3; k++) {
                        vec3 f;
                        vec3 sd;
                        vec3 up;
                        fk_frame(fi, k, N, f, sd, up);
                        for (int wside = 0; wside < 2; wside++) {
                                float sgn = wside == 0 ? 1.0 : -1.0;
                                vec3 pp = u_fk_bone[base + k].xyz + sd * (sgn * u_fk_bone[base + k].w * 0.92);
                                acc = sdf_smooth_union(acc,
                                                length(p - pp) - 0.020 * s,
                                                glowC * (1.1 + 1.4 * act), 0.02 * s);
                        }
                }
        } else if (sp == 4) { // ТУНЕЦ: спинной плавник ВДОЛЬ тела, финлеты, кили
                // цепной гребень 1→4: лопасти между соседними костями, корни
                // в плоти — плавник едет по волне хребта и не отклеивается
                // (раньше был один прямой клин 2→4 — его середину отрывало
                // от изогнутой спины, и «дыра» гуляла по телу вместе с волной)
                fk_ridge(acc, p, fi, N, 1, 4, 0.78, 1.0, 0.08 * s, 0.20 * s,
                                0.06 * s, 0.55, 0.030 * s, accC, 0.05 * s);
                for (int j = 0; j < 5; j++) { // жёлтые финлеты сверху
                        int bi = 3 + j;
                        if (bi >= N - 1) {
                                break;
                        }
                        vec3 f;
                        vec3 sd;
                        vec3 up;
                        fk_frame(fi, bi, N, f, sd, up);
                        vec3 fb = u_fk_bone[base + bi].xyz + up * (u_fk_bone[base + bi].w * 0.85);
                        vec3 ft = fb + up * (0.11 * s) + f * (0.07 * s);
                        acc = sdf_smooth_union(acc, fk_blade(p, fb, ft, f, 0.07 * s, 0.022 * s),
                                        accC * 1.05, 0.03 * s);
                }
                for (int j = 0; j < 4; j++) { // и снизу (анальные)
                        int bi = 3 + j;
                        if (bi >= N - 1) {
                                break;
                        }
                        vec3 f;
                        vec3 sd;
                        vec3 up;
                        fk_frame(fi, bi, N, f, sd, up);
                        vec3 fb = u_fk_bone[base + bi].xyz - up * (u_fk_bone[base + bi].w * 0.85);
                        vec3 ft = fb - up * (0.10 * s) + f * (0.06 * s);
                        acc = sdf_smooth_union(acc, fk_blade(p, fb, ft, f, 0.07 * s, 0.022 * s),
                                        accC * 1.05, 0.03 * s);
                }
                for (int wside = 0; wside < 2; wside++) { // боковые кили стебля
                        float sgn = wside == 0 ? 1.0 : -1.0;
                        int bi = N - 2;
                        vec3 f;
                        vec3 sd;
                        vec3 up;
                        fk_frame(fi, bi, N, f, sd, up);
                        vec3 kb = u_fk_bone[base + bi].xyz + sd * (sgn * u_fk_bone[base + bi].w * 0.8);
                        vec3 kt = kb + f * (0.14 * s);
                        acc = sdf_smooth_union(acc, fk_blade(p, kb, kt, up, 0.05 * s, 0.03 * s),
                                        accC, 0.03 * s);
                }
        } else if (sp == 5) { // ПУХЛЯК: спинной/анальный веер + иглы по надуванию
                vec3 dv = u_fk_bone[base + 2].xyz + up0 * (u_fk_bone[base + 2].w * 1.02);
                vec3 qv = p - dv;
                vec3 qvl = vec3(dot(qv, f0), dot(qv, up0), dot(qv, sd0));
                acc = sdf_smooth_union(acc, sd_ell(qvl, vec3(0.10, 0.15, 0.030) * s),
                                accC * 0.9, 0.07 * s);
                vec3 av = u_fk_bone[base + 3].xyz - up0 * (u_fk_bone[base + 3].w * 1.02);
                vec3 qa = p - av;
                vec3 qal = vec3(dot(qa, f0), dot(qa, up0), dot(qa, sd0));
                acc = sdf_smooth_union(acc, sd_ell(qal, vec3(0.09, 0.12, 0.028) * s),
                                accC * 0.9, 0.07 * s);
                if (infl > 0.015) { // ИГЛЫ: ровная сфера направлений (спираль Фибоначчи)
                        for (int i = 0; i < 18; i++) {
                                int bi = 1 + (i % max(N - 1, 1));
                                if (bi >= N) {
                                        break;
                                }
                                vec3 f;
                                vec3 sd;
                                vec3 up;
                                fk_frame(fi, bi, N, f, sd, up);
                                float zi = 1.0 - 2.0 * (float(i) + 0.5) / 18.0;
                                float ri = sqrt(max(0.0, 1.0 - zi * zi));
                                float ai = float(i) * 2.39996 + 0.7 + float(bi) * 1.13;
                                vec3 dir_out = normalize(
                                                sd * (ri * cos(ai)) + up * (ri * sin(ai)) + f * zi);
                                float r = u_fk_bone[base + bi].w;
                                float L = r * (0.42 + 0.85 * infl); // видны и в покое
                                vec3 sbase = u_fk_bone[base + bi].xyz + dir_out * (r * 0.74);
                                vec3 tip = sbase + dir_out * L + f * (L * (1.0 - infl) * 0.30);
                                acc = sdf_smooth_union(acc, fk_capsule(p, sbase, tip, 0.016 * s),
                                                vec3(0.92, 0.88, 0.76), 0.034 * s);
                        }
                }
        } else if (sp == 6) { // УСАЧ: усики-хемосенсоры, костяные щитки, спинной плавник
                for (int wside = 0; wside < 2; wside++) {
                        float sgn = wside == 0 ? 1.0 : -1.0;
                        vec3 bb = u_fk_bone[base].xyz + hw0 * (u_fk_bone[base].w * 0.8)
                                        - up0 * (u_fk_bone[base].w * 0.35) + sd0 * (sgn * 0.05 * s);
                        vec3 wig = sd0 * (sgn * (0.04 + 0.05 * act) * s
                                        * sin(u_time * 5.0 + float(wside) * 1.7));
                        vec3 bt = bb + hw0 * (0.16 * s) - up0 * (0.20 * s) + wig;
                        acc = sdf_smooth_union(acc, fk_capsule(p, bb, bt, 0.015 * s),
                                        accC * 0.75, 0.03 * s);
                }
                for (int k = 1; k <= 6; k++) { // щитки по хребту (осетровые)
                        if (k >= N - 1) {
                                break;
                        }
                        vec3 f;
                        vec3 sd;
                        vec3 up;
                        fk_frame(fi, k, N, f, sd, up);
                        vec3 sbase = u_fk_bone[base + k].xyz + up * (u_fk_bone[base + k].w * 0.55);
                        vec3 st = sbase + up * (0.085 * s) + f * (0.05 * s);
                        acc = sdf_smooth_union(acc, fk_capsule(p, sbase, st, 0.015 * s),
                                        accC * 1.10, 0.045 * s);
                }
                // спинной плавник ВДОЛЬ тела: цепной гребень 2→6, прижат к
                // волне хребта; заканчивается задолго до хвоста — хвостовую
                // лопасть при движении больше не задевает и не искажает
                fk_ridge(acc, p, fi, N, 2, 6, 0.75, 1.0, 0.05 * s, 0.19 * s,
                                0.04 * s, 0.45, 0.032 * s, top * 0.70, 0.05 * s);
        }

        return acc;
}

// ---- скелет для X-ray (u_fk_xray): бусины-позвонки + капсулы между ними ----
float fk_rig_dist(vec3 p) {
        float d = 1e9;
        for (int fi = 0; fi < FK_FISH; fi++) {
                float s = u_fk_params[fi].x * u_fk_params[fi].w;
                int N = int(u_fk_flags[fi].w + 0.5);
                if (s < 0.001 || N < 2) {
                        continue;
                }
                for (int k = 0; k < FK_BONE; k++) {
                        if (k >= N) {
                                break;
                        }
                        d = min(d, length(p - u_fk_bone[fi * FK_BONE + k].xyz) - 0.045 * s);
                        if (k + 1 < N) {
                                d = min(d, fk_capsule(p, u_fk_bone[fi * FK_BONE + k].xyz,
                                                u_fk_bone[fi * FK_BONE + k + 1].xyz, 0.014 * s));
                        }
                }
        }
        return d;
}
