shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2D displacement_long : repeat_enable, filter_linear;
uniform sampler2D displacement_mid : repeat_enable, filter_linear;
uniform sampler2D displacement_short : repeat_enable, filter_linear;
uniform sampler2D normal_long : repeat_enable, filter_linear;
uniform sampler2D normal_mid : repeat_enable, filter_linear;
uniform sampler2D normal_short : repeat_enable, filter_linear;
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
uniform int debug_mode = 0;
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
uniform vec3 base_color : source_color = vec3(0.18, 0.34, 0.44);
uniform vec3 slope_valley_color : source_color = vec3(0.02, 0.06, 0.12);
uniform vec3 slope_crest_color : source_color = vec3(0.95, 0.98, 1.0);
instance uniform float clipmap_level = 0.0;

varying vec3 derived_normal;
varying vec2 ocean_world_xz;
varying vec4 coastal_field;
varying vec4 coastal_metrics;
varying float coastal_mono_phase;
varying float coastal_mono_active;

vec2 spectrum_uv(vec2 world_xz, float domain_size_m) {
	return fract(world_xz / domain_size_m + vec2(0.5));
}

float distance_fade(vec2 fade_range, float distance_to_camera) {
	return 1.0 - smoothstep(fade_range.x, fade_range.y, distance_to_camera);
}

vec2 slope_from_normal(vec3 ocean_normal) {
	return -ocean_normal.xz / max(ocean_normal.y, 0.0001);
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
	coastal_mono_phase = 0.0;
	coastal_mono_active = 0.0;
	float distance_to_camera = distance(world_xz, camera_world_xz);
	float long_weight = band_mask.x * distance_fade(long_fade_range_m, distance_to_camera);
	float mid_weight = band_mask.y * distance_fade(mid_fade_range_m, distance_to_camera);
	float short_weight = band_mask.z * distance_fade(short_fade_range_m, distance_to_camera);
	vec2 coast_uv = coastal_uv(world_xz);
	coastal_field = textureLod(coastal_field_texture, clamp(coast_uv, vec2(0.0), vec2(1.0)), 0.0);
	coastal_metrics = textureLod(coastal_metrics_texture, clamp(coast_uv, vec2(0.0), vec2(1.0)), 0.0);
	bool coast_active = has_coastal_data(coast_uv, coastal_field);
	float phase_offset = coastal_field.r;
	float shoaling = coastal_field.g;
	vec2 long_sample_xz = world_xz;
	if (coast_active) {
		// sample_offset = phase_offset / k0. El signo + se valida con el
		// monocromático: k_local = k0 + d(phase_offset)/ds.
		long_sample_xz += coastal_incoming_direction_xz * (phase_offset / max(coastal_k0_rad_m, 0.0001));
	}
	vec3 long_displacement = textureLod(displacement_long, spectrum_uv(long_sample_xz, domain_long_m), 0.0).rgb;
	if (coast_active) {
		long_displacement *= shoaling;
	}
	vec3 mid_displacement = textureLod(displacement_mid, spectrum_uv(world_xz, domain_mid_m), 0.0).rgb;
	vec3 short_displacement = textureLod(displacement_short, spectrum_uv(world_xz, domain_short_m), 0.0).rgb;
	vec3 displacement = long_displacement * long_weight + mid_displacement * mid_weight + short_displacement * short_weight;

	vec3 long_normal = normalize(textureLod(normal_long, spectrum_uv(long_sample_xz, domain_long_m), 0.0).rgb);
	vec3 mid_normal = normalize(textureLod(normal_mid, spectrum_uv(world_xz, domain_mid_m), 0.0).rgb);
	vec3 short_normal = normalize(textureLod(normal_short, spectrum_uv(world_xz, domain_short_m), 0.0).rgb);
	// Aproximación 3B de regla de cadena: misma coordenada/factor de LONG.
	// La derivada espacial de phase_offset queda explícitamente para una fase posterior.
	vec2 slope = slope_from_normal(long_normal) * long_weight * (coast_active ? shoaling : 1.0);
	slope += slope_from_normal(mid_normal) * mid_weight;
	slope += slope_from_normal(short_normal) * short_weight;
	vec3 ocean_normal = normalize(vec3(-slope.x, 1.0, -slope.y));
	if (coastal_monochromatic_debug) {
		// Con transformación OFF, coast_active es falso: esta misma expresión
		// queda en la referencia profunda A*cos(k0*x-omega*t) en todo el plano.
		float mono_phase_offset = coast_active ? phase_offset : 0.0;
		float mono_shoaling = coast_active ? shoaling : 1.0;
		float mono_k = coast_active ? coastal_field.b : coastal_k0_rad_m;
		float phase = dot(world_xz, coastal_incoming_direction_xz) * coastal_k0_rad_m + mono_phase_offset - coastal_omega_rad_s * coastal_time_s;
		long_displacement = vec3(0.0, coastal_monochromatic_amplitude_m * mono_shoaling * cos(phase), 0.0);
		displacement = long_displacement * long_weight;
		vec2 mono_gradient = -coastal_incoming_direction_xz * coastal_monochromatic_amplitude_m * mono_shoaling * mono_k * sin(phase);
		ocean_normal = normalize(vec3(-mono_gradient.x, 1.0, -mono_gradient.y));
		coastal_mono_phase = phase;
		coastal_mono_active = 1.0;
	}

	if (!module_enabled) {
		displacement = vec3(0.0);
		ocean_normal = vec3(0.0, 1.0, 0.0);
	} else if (debug_mode == 1) {
		// HEIGHT ONLY: sin desplazamiento horizontal, para evaluar choppiness.
		displacement.xz = vec2(0.0);
	}
	VERTEX += displacement;
	NORMAL = ocean_normal;
	derived_normal = ocean_normal;
}


void fragment() {
	// Modo normal simple (0 y 1): agua opaca azul/gris iluminada.
	// Modos de diagnóstico (2 NORMALS, 3 SLOPE): unlit/emission, independientes
	// del sol del laboratorio y de la exposición, para leer pendientes.
	vec3 color = base_color;
	if (debug_mode == 2) {
		color = normalize(derived_normal) * 0.5 + 0.5;
	} else if (debug_mode == 3) {
		vec3 n = normalize(derived_normal);

		vec2 slope = -n.xz / max(n.y, 0.05);
		vec2 slope_dir = normalize(vec2(0.7, -0.7));

		float signed_slope = dot(slope, slope_dir);
		float shade = clamp(0.5 + signed_slope * 5.0, 0.0, 1.0);

		color = mix(slope_valley_color, slope_crest_color, shade);
	}
	if (coastal_mono_active > 0.5) {
		// Bandas de fase mono: los máximos son líneas cyan/blancas estrechas,
		// independientes de luz, normal, specular o exposición.
		float crest = 0.5 + 0.5 * cos(coastal_mono_phase);
		float crest_line = smoothstep(0.88, 0.985, crest);
		color = mix(vec3(0.005, 0.025, 0.12), vec3(0.03, 0.34, 0.68), pow(crest, 1.6));
		color = mix(color, vec3(0.78, 1.0, 1.0), crest_line);
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

	if (clipmap_lod_debug) {
		color = level_color(clipmap_level);
	}
	if (periodicity_debug) {
		float lines = max(periodic_grid(ocean_world_xz, domain_long_m), max(periodic_grid(ocean_world_xz, domain_mid_m), periodic_grid(ocean_world_xz, domain_short_m)));
		color = mix(color, vec3(1.0, 0.85, 0.15), lines);
	}

	bool unlit = debug_mode >= 2 || clipmap_lod_debug || periodicity_debug || coastal_debug_field > 0 || coastal_mono_active > 0.5;
	if (unlit) {
		ALBEDO = vec3(0.0);
		EMISSION = color;
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
	} else {
		ALBEDO = color;
		EMISSION = vec3(0.0);
		ROUGHNESS = 0.42;
		SPECULAR = 0.35;
	}
}
