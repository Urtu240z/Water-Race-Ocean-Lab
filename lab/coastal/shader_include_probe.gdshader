// Sonda: función de usuario CON variable local + include (tipo corregido).
shader_type spatial;
render_mode unshaded;

uniform sampler2D probe_tex;

vec3 level_color(float level) {
	float wave = fract(level * 0.61803398875);
	return mix(vec3(0.12, 0.85, 0.95), vec3(0.95, 0.25, 0.12), wave);
}

#include "res://lab/coastal/shader_include_probe_inc.gdshaderinc"

void vertex() {
	VERTEX.y += level_color(1.0).x * 0.0 + probe_height_at(VERTEX.xz) * 0.0;
}

void fragment() {
	ALBEDO = vec3(1.0);
}
