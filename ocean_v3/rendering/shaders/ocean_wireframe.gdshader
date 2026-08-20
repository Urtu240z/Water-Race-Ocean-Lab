shader_type spatial;
render_mode wireframe, cull_disabled, unshaded;

uniform sampler2D displacement_long : repeat_enable, filter_linear;
uniform sampler2D displacement_mid : repeat_enable, filter_linear;
uniform sampler2D displacement_short : repeat_enable, filter_linear;
uniform float domain_long_m = 512.0;
uniform float domain_mid_m = 128.0;
uniform float domain_short_m = 32.0;
uniform vec2 camera_world_xz = vec2(0.0);
uniform vec2 short_fade_range_m = vec2(24.0, 80.0);
uniform vec2 mid_fade_range_m = vec2(96.0, 320.0);
uniform vec2 long_fade_range_m = vec2(768.0, 2500.0);
uniform vec3 band_mask = vec3(1.0);
uniform bool module_enabled = true;
uniform bool clipmap_lod_debug = false;
uniform bool periodicity_debug = false;
instance uniform float clipmap_level = 0.0;

varying vec2 ocean_world_xz;

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
	return 1.0 - smoothstep(0.485, 0.5, max(cell.x, cell.y));
}

void vertex() {
	vec2 world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
	ocean_world_xz = world_xz;
	if (module_enabled) {
		float distance_to_camera = distance(world_xz, camera_world_xz);
		float long_weight = band_mask.x * distance_fade(long_fade_range_m, distance_to_camera);
		float mid_weight = band_mask.y * distance_fade(mid_fade_range_m, distance_to_camera);
		float short_weight = band_mask.z * distance_fade(short_fade_range_m, distance_to_camera);
		vec3 displacement = textureLod(displacement_long, spectrum_uv(world_xz, domain_long_m), 0.0).rgb * long_weight;
		displacement += textureLod(displacement_mid, spectrum_uv(world_xz, domain_mid_m), 0.0).rgb * mid_weight;
		displacement += textureLod(displacement_short, spectrum_uv(world_xz, domain_short_m), 0.0).rgb * short_weight;
		VERTEX += displacement;
	}
}

void fragment() {
	vec3 color = clipmap_lod_debug ? level_color(clipmap_level) : vec3(0.68, 0.91, 1.0);
	if (periodicity_debug) {
		float lines = max(periodic_grid(ocean_world_xz, domain_long_m), max(periodic_grid(ocean_world_xz, domain_mid_m), periodic_grid(ocean_world_xz, domain_short_m)));
		color = mix(color, vec3(1.0, 0.85, 0.15), lines);
	}
	ALBEDO = color;
}
