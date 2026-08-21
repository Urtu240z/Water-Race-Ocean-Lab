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
uniform vec2 camera_world_xz = vec2(0.0);
uniform vec2 short_fade_range_m = vec2(24.0, 80.0);
uniform vec2 mid_fade_range_m = vec2(96.0, 320.0);
uniform vec2 long_fade_range_m = vec2(768.0, 2500.0);
uniform vec3 band_mask = vec3(1.0);
uniform int debug_mode = 0;
uniform bool module_enabled = true;
uniform bool clipmap_lod_debug = false;
uniform bool periodicity_debug = false;
uniform vec3 base_color : source_color = vec3(0.18, 0.34, 0.44);
uniform vec3 slope_light_direction = vec3(0.55, 0.65, -0.55);
uniform vec3 slope_valley_color : source_color = vec3(0.02, 0.06, 0.12);
uniform vec3 slope_crest_color : source_color = vec3(0.95, 0.98, 1.0);
instance uniform float clipmap_level = 0.0;

varying vec3 derived_normal;
varying vec2 ocean_world_xz;

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
	return 1.0 - smoothstep(0.485, 0.5, max(cell.x, cell.y));
}

void vertex() {
	vec2 world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
	ocean_world_xz = world_xz;
	float distance_to_camera = distance(world_xz, camera_world_xz);
	float long_weight = band_mask.x * distance_fade(long_fade_range_m, distance_to_camera);
	float mid_weight = band_mask.y * distance_fade(mid_fade_range_m, distance_to_camera);
	float short_weight = band_mask.z * distance_fade(short_fade_range_m, distance_to_camera);
	vec3 long_displacement = textureLod(displacement_long, spectrum_uv(world_xz, domain_long_m), 0.0).rgb;
	vec3 mid_displacement = textureLod(displacement_mid, spectrum_uv(world_xz, domain_mid_m), 0.0).rgb;
	vec3 short_displacement = textureLod(displacement_short, spectrum_uv(world_xz, domain_short_m), 0.0).rgb;
	vec3 displacement = long_displacement * long_weight + mid_displacement * mid_weight + short_displacement * short_weight;

	vec3 long_normal = normalize(textureLod(normal_long, spectrum_uv(world_xz, domain_long_m), 0.0).rgb);
	vec3 mid_normal = normalize(textureLod(normal_mid, spectrum_uv(world_xz, domain_mid_m), 0.0).rgb);
	vec3 short_normal = normalize(textureLod(normal_short, spectrum_uv(world_xz, domain_short_m), 0.0).rgb);
	vec2 slope = slope_from_normal(long_normal) * long_weight;
	slope += slope_from_normal(mid_normal) * mid_weight;
	slope += slope_from_normal(short_normal) * short_weight;
	vec3 ocean_normal = normalize(vec3(-slope.x, 1.0, -slope.y));

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
		float n_dot_l = dot(normalize(derived_normal), normalize(slope_light_direction));
		float shade = clamp(n_dot_l * 0.5 + 0.5, 0.0, 1.0);
		color = mix(slope_valley_color, slope_crest_color, shade);
	}

	if (clipmap_lod_debug) {
		color = level_color(clipmap_level);
	}
	if (periodicity_debug) {
		float lines = max(periodic_grid(ocean_world_xz, domain_long_m), max(periodic_grid(ocean_world_xz, domain_mid_m), periodic_grid(ocean_world_xz, domain_short_m)));
		color = mix(color, vec3(1.0, 0.85, 0.15), lines);
	}

	bool unlit = debug_mode >= 2 || clipmap_lod_debug || periodicity_debug;
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
