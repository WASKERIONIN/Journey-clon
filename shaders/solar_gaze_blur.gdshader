shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;
uniform float blur_amount : hint_range(0.0, 1.0) = 0.0;
uniform float max_radius_px : hint_range(0.5, 8.0) = 4.0;

void fragment() {
	vec2 pixel = SCREEN_PIXEL_SIZE * max_radius_px * blur_amount;
	vec3 center = texture(screen_texture, SCREEN_UV).rgb;
	vec3 blur = center * 0.28;
	blur += texture(screen_texture, SCREEN_UV + vec2(pixel.x, 0.0)).rgb * 0.12;
	blur += texture(screen_texture, SCREEN_UV - vec2(pixel.x, 0.0)).rgb * 0.12;
	blur += texture(screen_texture, SCREEN_UV + vec2(0.0, pixel.y)).rgb * 0.12;
	blur += texture(screen_texture, SCREEN_UV - vec2(0.0, pixel.y)).rgb * 0.12;
	blur += texture(screen_texture, SCREEN_UV + pixel * 0.72).rgb * 0.06;
	blur += texture(screen_texture, SCREEN_UV - pixel * 0.72).rgb * 0.06;
	blur += texture(screen_texture, SCREEN_UV + vec2(pixel.x, -pixel.y) * 0.72).rgb * 0.06;
	blur += texture(screen_texture, SCREEN_UV + vec2(-pixel.x, pixel.y) * 0.72).rgb * 0.06;
	// Короткое, деликатное смягчение — мир остаётся читаемым.
	COLOR = vec4(mix(center, blur, blur_amount * 0.48), 1.0);
}
