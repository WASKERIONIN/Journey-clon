shader_type canvas_item;

// =====================================================================
// Киношный колор-грейдинг поверх всего кадра — по мотивам ассета
// «Color Grading» (Rytelier): тени/средние/света, вибранс, контраст,
// температура, «ночь Пуркинье». Ассет живёт на композиторных эффектах
// (Forward+), у нас gl_compatibility — поэтому грейд рисуется
// полноэкранным прямоугольником, читающим экран. Управление — DEV-панель.
// =====================================================================

uniform sampler2D screen_tex : hint_screen_texture;

group_uniforms Grade;

uniform float intensity : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform vec3 tint_shadows : source_color = vec3(1.0);
uniform vec3 tint_midtones : source_color = vec3(1.0);
uniform vec3 tint_highlights : source_color = vec3(1.0);
uniform float brightness : hint_range(0.5, 1.6, 0.01) = 1.0;
uniform float contrast : hint_range(0.6, 1.7, 0.01) = 1.0;
/** Вибранс: насыщает блёклые цвета, не ломая уже яркие. */
uniform float vibrance : hint_range(-0.6, 0.6, 0.01) = 0.0;
/** Температура: + тепло, − холод. */
uniform float temperature : hint_range(-1.0, 1.0, 0.01) = 0.0;
/** «Ночь Пуркинье»: в темноте глаз видит приглушённо и синевато. */
uniform float night : hint_range(0.0, 1.0, 0.01) = 0.0;

vec3 grade(vec3 c) {
	// зоны по яркости: тень / середина / света — у каждой свой тон
	float lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
	float w_s = pow(1.0 - clamp(lum, 0.0, 1.0), 2.0);
	float w_h = pow(clamp(lum, 0.0, 1.0), 2.0);
	float w_m = max(1.0 - w_s - w_h, 0.0);
	c *= tint_shadows * w_s + tint_midtones * w_m + tint_highlights * w_h;
	// температура: тёпло-холодный сдвиг баланса
	c *= vec3(1.0 + 0.10 * temperature, 1.0, 1.0 - 0.08 * temperature);
	// контраст вокруг «плёночной» середины + яркость
	c = (c - 0.18) * contrast + 0.18;
	c *= brightness;
	// вибранс: слабонасыщенные тянутся сильнее, яркие почти не тронуты
	float mx = max(max(c.r, c.g), c.b);
	float mn = min(min(c.r, c.g), c.b);
	float sat = clamp(mx - mn, 0.0, 1.0);
	float vib_amt = vibrance * (1.0 - sat);
	float lum2 = dot(c, vec3(0.2126, 0.7152, 0.0722));
	c = mix(vec3(lum2), c, 1.0 + vib_amt);
	// Пуркинье: сумеречное зрение — синий канал живёт, остальное гаснет
	float dark = 1.0 - clamp(lum * 1.6, 0.0, 1.0);
	float nk = night * dark;
	c = mix(c, vec3(dot(c, vec3(0.35, 0.55, 0.75))) * vec3(0.55, 0.65, 1.05), nk);
	return max(c, vec3(0.0));
}

void fragment() {
	vec3 c = texture(screen_tex, SCREEN_UV).rgb;
	COLOR = vec4(mix(c, grade(c), intensity), 1.0);
}
