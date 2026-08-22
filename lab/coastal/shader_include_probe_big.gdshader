// Sonda: inc real + función con return directo (sin variable local).
shader_type spatial;
render_mode unshaded;

#include "res://ocean_v3/rendering/shaders/ocean_breaking_common.gdshaderinc"

float level_color(float level) {
	return mix(vec3(0.12, 0.85, 0.95), vec3(0.95, 0.25, 0.12), fract(level * 0.61803398875));
}

void vertex() {
	VERTEX.y += level_color(1.0) * 0.0;
}

void fragment() {
	ALBEDO = vec3(1.0);
}
