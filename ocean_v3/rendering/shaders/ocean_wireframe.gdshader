shader_type spatial;
render_mode wireframe, cull_disabled, unshaded;

uniform sampler2D displacement_long : repeat_enable, filter_linear;
uniform sampler2D displacement_mid : repeat_enable, filter_linear;
uniform sampler2D displacement_short : repeat_enable, filter_linear;
uniform float domain_long_m = 512.0;
uniform float domain_mid_m = 128.0;
uniform float domain_short_m = 32.0;
uniform vec3 band_mask = vec3(1.0);
uniform bool module_enabled = true;

vec2 spectrum_uv(vec2 world_xz, float domain_size_m) {
	return fract(world_xz / domain_size_m + vec2(0.5));
}

void vertex() {
	vec2 world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
	if (module_enabled) {
		vec3 displacement = textureLod(displacement_long, spectrum_uv(world_xz, domain_long_m), 0.0).rgb * band_mask.x;
		displacement += textureLod(displacement_mid, spectrum_uv(world_xz, domain_mid_m), 0.0).rgb * band_mask.y;
		displacement += textureLod(displacement_short, spectrum_uv(world_xz, domain_short_m), 0.0).rgb * band_mask.z;
		VERTEX += displacement;
	}
}

void fragment() {
	ALBEDO = vec3(0.68, 0.91, 1.0);
}
