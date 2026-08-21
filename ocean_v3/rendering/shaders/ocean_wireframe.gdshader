shader_type spatial;
render_mode wireframe, cull_disabled, unshaded;

uniform sampler2D displacement_long : repeat_enable, filter_linear;
uniform sampler2D displacement_mid : repeat_enable, filter_linear;
uniform sampler2D displacement_short : repeat_enable, filter_linear;
uniform sampler2D coastal_field_texture : repeat_disable, filter_linear;
uniform sampler2D coastal_metrics_texture : repeat_disable, filter_linear;
uniform float domain_long_m = 512.0;
uniform float domain_mid_m = 137.0;
uniform float domain_short_m = 37.0;
uniform vec2 camera_world_xz = vec2(0.0);
uniform vec2 short_fade_range_m = vec2(24.0, 80.0);
uniform vec2 mid_fade_range_m = vec2(96.0, 320.0);
uniform vec2 long_fade_range_m = vec2(768.0, 2500.0);
uniform vec3 band_mask = vec3(1.0);
uniform bool module_enabled = true;
uniform bool clipmap_lod_debug = false;
uniform bool periodicity_debug = false;
uniform bool coastal_propagation_enabled = false;
uniform bool coastal_monochromatic_debug = false;
uniform int coastal_debug_field = 0;
uniform float coastal_monochromatic_amplitude_m = 0.35;
uniform vec2 coastal_origin_xz = vec2(0.0);
uniform vec2 coastal_extent_m = vec2(1.0);
uniform vec2 coastal_incoming_direction_xz = vec2(1.0, 0.0);
uniform float coastal_k0_rad_m = 0.392699;
uniform float coastal_omega_rad_s = 1.962;
uniform float coastal_time_s = 0.0;
instance uniform float clipmap_level = 0.0;

varying vec2 ocean_world_xz;
varying vec4 coastal_field;
varying vec4 coastal_metrics;

vec2 spectrum_uv(vec2 world_xz, float domain_size_m) {
	return fract(world_xz / domain_size_m + vec2(0.5));
}

float distance_fade(vec2 fade_range, float distance_to_camera) {
	return 1.0 - smoothstep(fade_range.x, fade_range.y, distance_to_camera);
}

vec3 level_color(float level) {
	float wave = fract(level * 0.61803398875);
	return mix(vec3(0.12, 0.85, 0.95), vec3(0.95, 0.25, 0.12), wave);
}

float periodic_grid(vec2 world_xz, float domain_size_m) {
	vec2 cell = abs(fract(world_xz / domain_size_m + 0.5) - 0.5);
	return smoothstep(0.485, 0.5, max(cell.x, cell.y));
}

vec2 coastal_uv(vec2 world_xz) {
	return (world_xz - coastal_origin_xz) / max(coastal_extent_m, vec2(0.0001));
}

bool has_coastal_data(vec2 uv, vec4 field_data) {
	return coastal_propagation_enabled && uv.x >= 0.0 && uv.x <= 1.0 && uv.y >= 0.0 && uv.y <= 1.0 && field_data.a > 0.5;
}

void vertex() {
	vec2 world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
	ocean_world_xz = world_xz;
	coastal_field = vec4(0.0, 1.0, 0.0, 0.0);
	coastal_metrics = vec4(0.0);
	if (module_enabled) {
		float distance_to_camera = distance(world_xz, camera_world_xz);
		float long_weight = band_mask.x * distance_fade(long_fade_range_m, distance_to_camera);
		float mid_weight = band_mask.y * distance_fade(mid_fade_range_m, distance_to_camera);
		float short_weight = band_mask.z * distance_fade(short_fade_range_m, distance_to_camera);
		vec2 coast_uv = coastal_uv(world_xz);
		coastal_field = textureLod(coastal_field_texture, clamp(coast_uv, vec2(0.0), vec2(1.0)), 0.0);
		coastal_metrics = textureLod(coastal_metrics_texture, clamp(coast_uv, vec2(0.0), vec2(1.0)), 0.0);
		bool coast_active = has_coastal_data(coast_uv, coastal_field);
		vec2 long_sample_xz = world_xz;
		if (coast_active) long_sample_xz += coastal_incoming_direction_xz * (coastal_field.r / max(coastal_k0_rad_m, 0.0001));
		vec3 displacement = textureLod(displacement_long, spectrum_uv(long_sample_xz, domain_long_m), 0.0).rgb * long_weight;
		if (coast_active) displacement *= coastal_field.g;
		displacement += textureLod(displacement_mid, spectrum_uv(world_xz, domain_mid_m), 0.0).rgb * mid_weight;
		displacement += textureLod(displacement_short, spectrum_uv(world_xz, domain_short_m), 0.0).rgb * short_weight;
		if (coastal_monochromatic_debug && coast_active) {
			float phase = dot(world_xz, coastal_incoming_direction_xz) * coastal_k0_rad_m + coastal_field.r - coastal_omega_rad_s * coastal_time_s;
			displacement = vec3(0.0, coastal_monochromatic_amplitude_m * coastal_field.g * cos(phase), 0.0);
		}
		VERTEX += displacement;
	}
}

void fragment() {
	vec3 color = clipmap_lod_debug ? level_color(clipmap_level) : vec3(0.68, 0.91, 1.0);
	if (periodicity_debug) {
		float lines = max(periodic_grid(ocean_world_xz, domain_long_m), max(periodic_grid(ocean_world_xz, domain_mid_m), periodic_grid(ocean_world_xz, domain_short_m)));
		color = mix(color, vec3(1.0, 0.85, 0.15), lines);
	}
	if (coastal_debug_field > 0 && coastal_propagation_enabled) {
		float value = 0.0;
		if (coastal_debug_field == 1) value = coastal_metrics.r / 12.0;
		else if (coastal_debug_field == 2) value = coastal_metrics.g / 32.0;
		else if (coastal_debug_field == 3) value = coastal_metrics.b / 8.0;
		else if (coastal_debug_field == 4) value = coastal_metrics.a / 8.0;
		else if (coastal_debug_field == 5) value = (coastal_field.g - 1.0) * 8.0;
		else if (coastal_debug_field == 6) value = abs(coastal_field.r) / 6.2831853;
		color = mix(vec3(0.02, 0.05, 0.12), vec3(0.95, 0.8, 0.18), clamp(value, 0.0, 1.0));
	}
	ALBEDO = color;
}
