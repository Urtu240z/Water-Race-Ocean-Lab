shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2D displacement_long : filter_linear, repeat_enable;
uniform sampler2D displacement_mid : filter_linear, repeat_enable;
uniform sampler2D displacement_short : filter_linear, repeat_enable;
uniform sampler2D normal_long : filter_linear, repeat_enable;
uniform sampler2D normal_mid : filter_linear, repeat_enable;
uniform sampler2D normal_short : filter_linear, repeat_enable;
uniform float domain_long_m = 512.0;
uniform float domain_mid_m = 137.0;
uniform float domain_short_m = 37.0;
uniform vec2 camera_world_xz = vec2(0.0);
uniform vec2 short_fade_range_m = vec2(24.0, 80.0);
uniform vec2 mid_fade_range_m = vec2(96.0, 280.0);
uniform vec2 long_fade_range_m = vec2(768.0, 2500.0);
uniform vec3 base_color : source_color = vec3(0.015, 0.07, 0.10);
uniform float base_roughness : hint_range(0.0, 1.0) = 0.12;
uniform float base_specular : hint_range(0.0, 1.0) = 0.75;
uniform int debug_band = 0;

vec3 sample_displacement(sampler2D map, float domain_m, vec2 world_xz) {
	return texture(map, fract(world_xz / domain_m + vec2(0.5))).xyz;
}

vec3 total_displacement(vec2 world_xz) {
	float distance_to_camera = length(world_xz - camera_world_xz);
	float short_weight = 1.0 - smoothstep(short_fade_range_m.x, short_fade_range_m.y, distance_to_camera);
	float mid_weight = 1.0 - smoothstep(mid_fade_range_m.x, mid_fade_range_m.y, distance_to_camera);
	vec3 long_displacement = sample_displacement(displacement_long, domain_long_m, world_xz);
	vec3 mid_displacement = sample_displacement(displacement_mid, domain_mid_m, world_xz) * mid_weight;
	vec3 short_displacement = sample_displacement(displacement_short, domain_short_m, world_xz) * short_weight;
	if (debug_band == 1) return long_displacement;
	if (debug_band == 2) return mid_displacement;
	if (debug_band == 3) return short_displacement;
	return long_displacement + mid_displacement + short_displacement;
}

void vertex() {
	vec3 world_base = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 xz = world_base.xz;
	vec3 displacement = total_displacement(xz);
	float derivative_step = 0.35;
	vec3 x0 = total_displacement(xz - vec2(derivative_step, 0.0));
	vec3 x1 = total_displacement(xz + vec2(derivative_step, 0.0));
	vec3 z0 = total_displacement(xz - vec2(0.0, derivative_step));
	vec3 z1 = total_displacement(xz + vec2(0.0, derivative_step));
	vec3 tangent_x = vec3(1.0, 0.0, 0.0) + (x1 - x0) / (2.0 * derivative_step);
	vec3 tangent_z = vec3(0.0, 0.0, 1.0) + (z1 - z0) / (2.0 * derivative_step);
	VERTEX += displacement;
	NORMAL = normalize(cross(tangent_z, tangent_x));
}

void fragment() {
	ALBEDO = base_color;
	ROUGHNESS = base_roughness;
	SPECULAR = base_specular;
	ALPHA = 1.0;
}
