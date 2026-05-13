shader_type canvas_item;

uniform vec4 planet_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float contrast : hint_range(0.5, 6.0) = 1.5;
// brightness multiplier — use to compensate darker colors
uniform float brightness : hint_range(0.1, 3.0) = 1.0;

void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	float lum = dot(tex.rgb, vec3(0.299, 0.587, 0.114));
	// Contrast around midpoint
	float c = (lum - 0.5) * contrast + 0.5;
	c = clamp(c, 0.0, 1.0);
	vec3 tinted = planet_color.rgb * c * brightness;
	tinted = clamp(tinted, vec3(0.0), vec3(1.0));
	COLOR = vec4(tinted, tex.a * COLOR.a);
}
