shader_type spatial;
render_mode wireframe, cull_disabled, unshaded;

uniform sampler2D displacement_map : repeat_enable, filter_linear;
uniform float domain_size_m = 128.0;
uniform bool module_enabled = true;

void vertex() {
	vec2 world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
	vec2 spectrum_uv = fract(world_xz / domain_size_m + vec2(0.5));
	if (module_enabled) {
		VERTEX += textureLod(displacement_map, spectrum_uv, 0.0).rgb;
	}
}

void fragment() {
	ALBEDO = vec3(0.68, 0.91, 1.0);
}
