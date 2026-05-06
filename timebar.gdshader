shader_type canvas_item;
uniform float progress : hint_range(0.0, 1.0);

void fragment() {
    vec2 uv = UV;
    
    // Only show part of the sprite based on progress
    if (uv.x > progress) {
        COLOR.a = 0.0; // Make right side invisible
    }
    else {
        // Ensure the visible part has proper color/opacity
        // You might want to add a different color here if needed
        COLOR = vec4(COLOR.rgb, 1.0); // Ensure visible part is fully opaque
    }
}