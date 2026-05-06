shader_type canvas_item;

uniform vec4 team_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);

void fragment() {
	vec4 color = texture(TEXTURE, UV);
	color.rgb = team_color.rgb;
	COLOR = color;
}