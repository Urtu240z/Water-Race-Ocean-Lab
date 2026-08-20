shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2D displacement_long : repeat_enable, filter_linear;
uniform sampler2D displacement_mid : repeat_enable, filter_linear;
uniform sampler2D displacement_short : repeat_enable, filter_linear;
uniform sampler2D normal_long : repeat_enable, filter_linear;
uniform sampler2D normal_mid : repeat_enable, filter_linear;
uniform sampler2D normal_short : repeat_enable, filter_linear;
uniform float domain_long_m = 512.0;
uniform float domain_mid_m = 128.0;
uniform float domain_short_m = 32.0;
uniform vec3 band_mask = vec3(1.0);
uniform int debug_mode = 0; // 0 full, 1 height only, 2 normals
uniform bool module_enabled = true;
uniform vec3 base_color : source_color = vec3(0.075, 0.20, 0.27);

varying vec3 derived_normal;

vec2 spectrum_uv(vec2 world_xz, float domain_size_m) {
	return fract(world_xz / domain_size_m + vec2(0.5));
}

vec2 slope_from_normal(vec3 ocean_normal) {
	return -ocean_normal.xz / max(ocean_normal.y, 0.0001);
}

void vertex() {
	vec2 world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
	vec3 long_displacement = textureLod(displacement_long, spectrum_uv(world_xz, domain_long_m), 0.0).rgb;
	vec3 mid_displacement = textureLod(displacement_mid, spectrum_uv(world_xz, domain_mid_m), 0.0).rgb;
	vec3 short_displacement = textureLod(displacement_short, spectrum_uv(world_xz, domain_short_m), 0.0).rgb;
	vec3 displacement = long_displacement * band_mask.x + mid_displacement * band_mask.y + short_displacement * band_mask.z;

	vec3 long_normal = normalize(textureLod(normal_long, spectrum_uv(world_xz, domain_long_m), 0.0).rgb);
	vec3 mid_normal = normalize(textureLod(normal_mid, spectrum_uv(world_xz, domain_mid_m), 0.0).rgb);
	vec3 short_normal = normalize(textureLod(normal_short, spectrum_uv(world_xz, domain_short_m), 0.0).rgb);
	vec2 slope = slope_from_normal(long_normal) * band_mask.x;
	slope += slope_from_normal(mid_normal) * band_mask.y;
	slope += slope_from_normal(short_normal) * band_mask.z;
	vec3 ocean_normal = normalize(vec3(-slope.x, 1.0, -slope.y));

	if (!module_enabled) {
		displacement = vec3(0.0);
		ocean_normal = vec3(0.0, 1.0, 0.0);
	} else if (debug_mode == 1) {
		displacement.xz = vec2(0.0);
	}
	VERTEX += displacement;
	NORMAL = ocean_normal;
	derived_normal = ocean_normal;
}

void fragment() {
	ALBEDO = debug_mode == 2 ? derived_normal * 0.5 + 0.5 : base_color;
	ROUGHNESS = 0.42;
	SPECULAR = 0.35;
}
