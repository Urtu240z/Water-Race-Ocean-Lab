shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

// Phase 1 geometry only: LONG_COASTAL + LONG_REMAINDER + MID + SHORT.
uniform sampler2D displacement_long_coastal : filter_linear, repeat_enable;
uniform sampler2D displacement_long_remainder : filter_linear, repeat_enable;
uniform sampler2D displacement_mid : filter_linear, repeat_enable;
uniform sampler2D displacement_short : filter_linear, repeat_enable;
uniform sampler2D normal_long_coastal : filter_linear, repeat_enable;
uniform sampler2D normal_long_remainder : filter_linear, repeat_enable;
uniform sampler2D normal_mid : filter_linear, repeat_enable;
uniform sampler2D normal_short : filter_linear, repeat_enable;
uniform sampler2D coastal_field_texture : filter_linear, repeat_disable;
uniform sampler2D coastal_metrics_texture : filter_linear, repeat_disable;
uniform sampler2D coastal_warp_texture : filter_linear, repeat_disable;
uniform sampler2D coastal_warp_jacobian_texture : filter_linear, repeat_disable;
uniform float domain_long_coastal_m = 512.0;
uniform float domain_long_remainder_m = 512.0;
uniform float domain_mid_m = 137.0;
uniform float domain_short_m = 37.0;
uniform vec2 camera_world_xz = vec2(0.0);
uniform vec2 short_fade_range_m = vec2(24.0, 80.0);
uniform vec2 mid_fade_range_m = vec2(96.0, 280.0);
uniform vec2 long_fade_range_m = vec2(768.0, 2500.0);
uniform bool coastal_geometry_enabled = false;
uniform vec2 coastal_origin_xz = vec2(0.0);
uniform vec2 coastal_extent_m = vec2(1.0);
uniform vec2 coastal_warp_origin_xz = vec2(0.0);
uniform vec2 coastal_warp_extent_m = vec2(1.0);
uniform float coastal_warp_detj_safe = 0.5;
uniform float coastal_min_valid_depth_m = 0.25;
uniform float coastal_cell_size_m = 1.0;
uniform vec2 shore_vertical_depth_range_m = vec2(0.25, 6.0);
uniform vec2 shore_horizontal_depth_range_m = vec2(0.75, 12.0);
uniform vec3 base_color : source_color = vec3(0.015, 0.07, 0.10);
uniform float base_roughness : hint_range(0.0, 1.0) = 0.12;
uniform float base_specular : hint_range(0.0, 1.0) = 0.75;
// Godot maps dielectric SPECULAR to F0 as 0.16 * SPECULAR^2. 0.356835 is
// water's approximately 0.0204 normal-incidence reflectance (IOR 1.333).
uniform bool reflection_phase_1_enabled = true;
uniform float reflection_water_specular : hint_range(0.0, 1.0) = 0.356835;
uniform float reflection_min_roughness : hint_range(0.0, 1.0) = 0.045;
uniform float reflection_base_roughness : hint_range(0.0, 1.0) = 0.055;
uniform float reflection_distance_roughness : hint_range(0.0, 1.0) = 0.18;
uniform float reflection_slope_roughness_gain : hint_range(0.0, 1.0) = 0.16;
uniform vec2 reflection_distance_range_m = vec2(90.0, 650.0);
uniform vec2 reflection_slope_range = vec2(0.08, 0.55);
// Direct Crest Foam Phase 1: no new texture, history or simulation state.
// 0 OFF, 1 trigger only, 2 ON, 3 raw debug, 4 final debug.
uniform int crest_foam_mode = 2;
uniform vec2 crest_foam_height_range_m = vec2(0.10, 0.65);
uniform vec2 crest_foam_slope_range = vec2(0.05, 0.30);
uniform vec2 crest_foam_mid_detail_range = vec2(0.02, 0.18);
uniform vec2 crest_foam_distance_fade_range_m = vec2(110.0, 380.0);
uniform float crest_foam_mid_fragmentation : hint_range(0.0, 1.0) = 0.42;
uniform float crest_foam_strength : hint_range(0.0, 1.0) = 0.90;
uniform vec3 crest_foam_color : source_color = vec3(0.84, 0.89, 0.88);
uniform float crest_foam_roughness : hint_range(0.0, 1.0) = 0.78;
uniform float crest_foam_specular : hint_range(0.0, 1.0) = 0.12;
uniform int debug_band = 0;

varying float reflection_distance_to_camera;
varying float reflection_slope_magnitude;
varying float crest_foam_raw_trigger;
varying float crest_foam_mid_detail;

vec3 sample_displacement(sampler2D map, float domain_m, vec2 world_xz) {
	return texture(map, fract(world_xz / domain_m + vec2(0.5))).xyz;
}

float field_inside(vec2 uv) {
	return step(0.0, uv.x) * step(uv.x, 1.0) * step(0.0, uv.y) * step(uv.y, 1.0);
}

vec4 coastal_warp_state(vec2 world_xz) {
	if (!coastal_geometry_enabled) return vec4(world_xz, 0.0, 1.0);
	vec2 coast_uv = (world_xz - coastal_origin_xz) / max(coastal_extent_m, vec2(0.0001));
	vec4 field = textureLod(coastal_field_texture, clamp(coast_uv, vec2(0.0), vec2(1.0)), 0.0);
	float render_confidence = field_inside(coast_uv) * clamp(field.a, 0.0, 1.0);
	vec2 warp_uv = (world_xz - coastal_warp_origin_xz) / max(coastal_warp_extent_m, vec2(0.0001));
	vec4 warp = textureLod(coastal_warp_texture, clamp(warp_uv, vec2(0.0), vec2(1.0)), 0.0);
	float warp_confidence = smoothstep(0.0, coastal_warp_detj_safe, warp.b) * warp.a * field_inside(warp_uv) * render_confidence;
	return vec4(warp.xy, warp_confidence, mix(1.0, field.g, warp_confidence));
}

void shore_weights(vec2 world_xz, out float vertical_weight, out float horizontal_weight) {
	vertical_weight = 1.0;
	horizontal_weight = 1.0;
	if (!coastal_geometry_enabled) return;
	vec2 uv = (world_xz - coastal_origin_xz) / max(coastal_extent_m, vec2(0.0001));
	float inside = field_inside(uv);
	float depth = max(textureLod(coastal_metrics_texture, clamp(uv, vec2(0.0), vec2(1.0)), 0.0).r, 0.0);
	float water = smoothstep(0.0, max(coastal_min_valid_depth_m, 0.001), depth);
	float vertical = water * smoothstep(min(shore_vertical_depth_range_m.x, shore_vertical_depth_range_m.y), max(shore_vertical_depth_range_m.x, shore_vertical_depth_range_m.y), depth);
	float horizontal = water * smoothstep(min(shore_horizontal_depth_range_m.x, shore_horizontal_depth_range_m.y), max(shore_horizontal_depth_range_m.x, shore_horizontal_depth_range_m.y), depth);
	vertical_weight = mix(1.0, vertical, inside);
	horizontal_weight = mix(1.0, horizontal, inside);
}

vec2 slope_from_normal(vec3 normal_value) {
	vec3 n = normalize(normal_value);
	return -n.xz / max(n.y, 0.0001);
}

vec2 shoreline_vertical_gradient(vec2 world_xz) {
	if (!coastal_geometry_enabled) return vec2(0.0);
	float step_m = max(coastal_cell_size_m, 0.25);
	float vm;
	float hm;
	float vp;
	float hp;
	shore_weights(world_xz - vec2(step_m, 0.0), vm, hm);
	shore_weights(world_xz + vec2(step_m, 0.0), vp, hp);
	float dx = (vp - vm) / (2.0 * step_m);
	shore_weights(world_xz - vec2(0.0, step_m), vm, hm);
	shore_weights(world_xz + vec2(0.0, step_m), vp, hp);
	return vec2(dx, (vp - vm) / (2.0 * step_m));
}

vec3 total_displacement(vec2 world_xz) {
	float distance_to_camera = length(world_xz - camera_world_xz);
	float long_weight = 1.0 - smoothstep(long_fade_range_m.x, long_fade_range_m.y, distance_to_camera);
	float mid_weight = 1.0 - smoothstep(mid_fade_range_m.x, mid_fade_range_m.y, distance_to_camera);
	float short_weight = 1.0 - smoothstep(short_fade_range_m.x, short_fade_range_m.y, distance_to_camera);
	vec4 coastal = coastal_warp_state(world_xz);
	vec3 long_coastal_open = sample_displacement(displacement_long_coastal, domain_long_coastal_m, world_xz);
	vec3 long_coastal_deep = sample_displacement(displacement_long_coastal, domain_long_coastal_m, coastal.xy);
	vec3 long_coastal = mix(long_coastal_open, long_coastal_deep, coastal.z) * coastal.w;
	vec3 long_remainder = sample_displacement(displacement_long_remainder, domain_long_remainder_m, world_xz);
	vec3 mid = sample_displacement(displacement_mid, domain_mid_m, world_xz) * mid_weight;
	vec3 short_wave = sample_displacement(displacement_short, domain_short_m, world_xz) * short_weight;
	vec3 displacement = (long_coastal + long_remainder) * long_weight;
	if (debug_band == 1) displacement = (long_coastal + long_remainder) * long_weight;
	else if (debug_band == 2) displacement = mid;
	else if (debug_band == 3) displacement = short_wave;
	else displacement += mid + short_wave;
	float vertical_weight;
	float horizontal_weight;
	shore_weights(world_xz, vertical_weight, horizontal_weight);
	displacement.xz *= horizontal_weight;
	displacement.y *= vertical_weight;
	return displacement;
}

void vertex() {
	vec3 world_base = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 xz = world_base.xz;
	vec3 displacement = total_displacement(xz);
	float distance_to_camera = length(xz - camera_world_xz);
	float long_weight = 1.0 - smoothstep(long_fade_range_m.x, long_fade_range_m.y, distance_to_camera);
	float mid_weight = 1.0 - smoothstep(mid_fade_range_m.x, mid_fade_range_m.y, distance_to_camera);
	float short_weight = 1.0 - smoothstep(short_fade_range_m.x, short_fade_range_m.y, distance_to_camera);
	vec4 coastal = coastal_warp_state(xz);
	vec2 coastal_open_slope = slope_from_normal(textureLod(normal_long_coastal, fract(xz / domain_long_coastal_m + vec2(0.5)), 0.0).rgb);
	vec2 coastal_deep_slope = slope_from_normal(textureLod(normal_long_coastal, fract(coastal.xy / domain_long_coastal_m + vec2(0.5)), 0.0).rgb);
	vec2 warp_uv = (xz - coastal_warp_origin_xz) / max(coastal_warp_extent_m, vec2(0.0001));
	vec4 jacobian = textureLod(coastal_warp_jacobian_texture, clamp(warp_uv, vec2(0.0), vec2(1.0)), 0.0);
	vec2 coastal_world_slope = vec2(
		jacobian.r * coastal_deep_slope.x + jacobian.b * coastal_deep_slope.y,
		jacobian.g * coastal_deep_slope.x + jacobian.a * coastal_deep_slope.y
	);
	vec2 long_slope = (mix(coastal_open_slope, coastal_world_slope, coastal.z) * coastal.w
		+ slope_from_normal(textureLod(normal_long_remainder, fract(xz / domain_long_remainder_m + vec2(0.5)), 0.0).rgb)) * long_weight;
	vec2 mid_slope = slope_from_normal(textureLod(normal_mid, fract(xz / domain_mid_m + vec2(0.5)), 0.0).rgb) * mid_weight;
	vec2 short_slope = slope_from_normal(textureLod(normal_short, fract(xz / domain_short_m + vec2(0.5)), 0.0).rgb) * short_weight;
	vec2 slope = long_slope + mid_slope + short_slope;
	if (debug_band == 1) slope = long_slope;
	else if (debug_band == 2) slope = mid_slope;
	else if (debug_band == 3) slope = short_slope;
	float vertical_weight;
	float horizontal_weight;
	shore_weights(xz, vertical_weight, horizontal_weight);
	float pre_envelope_height = displacement.y / max(vertical_weight, 0.001);
	slope = slope * vertical_weight + pre_envelope_height * shoreline_vertical_gradient(xz);
	VERTEX += displacement;
	NORMAL = normalize(vec3(-slope.x, 1.0, -slope.y));
	reflection_distance_to_camera = distance_to_camera;
	reflection_slope_magnitude = length(slope);
	// Height selects the upper wave body; LONG+MID slope selects compression-like
	// crest support. SHORT is deliberately excluded from the trigger.
	crest_foam_raw_trigger = smoothstep(
		crest_foam_height_range_m.x,
		max(crest_foam_height_range_m.y, crest_foam_height_range_m.x + 0.001),
		max(displacement.y, 0.0)
	) * smoothstep(
		crest_foam_slope_range.x,
		max(crest_foam_slope_range.y, crest_foam_slope_range.x + 0.001),
		length(long_slope + mid_slope)
	);
	crest_foam_mid_detail = smoothstep(
		crest_foam_mid_detail_range.x,
		max(crest_foam_mid_detail_range.y, crest_foam_mid_detail_range.x + 0.001),
		length(mid_slope)
	);
}

void fragment() {
	ALBEDO = base_color;
	if (reflection_phase_1_enabled) {
		float distance_weight = smoothstep(
			reflection_distance_range_m.x,
			max(reflection_distance_range_m.y, reflection_distance_range_m.x + 0.001),
			reflection_distance_to_camera
		);
		float slope_weight = smoothstep(
			reflection_slope_range.x,
			max(reflection_slope_range.y, reflection_slope_range.x + 0.001),
			reflection_slope_magnitude
		);
		ROUGHNESS = clamp(
			mix(reflection_base_roughness, reflection_distance_roughness, distance_weight)
			+ slope_weight * reflection_slope_roughness_gain,
			reflection_min_roughness,
			1.0
		);
		SPECULAR = reflection_water_specular;
	} else {
		ROUGHNESS = base_roughness;
		SPECULAR = base_specular;
	}
	float crest_distance_fade = 1.0 - smoothstep(
		crest_foam_distance_fade_range_m.x,
		max(crest_foam_distance_fade_range_m.y, crest_foam_distance_fade_range_m.x + 0.001),
		reflection_distance_to_camera
	);
	float crest_foam = crest_foam_raw_trigger
		* mix(1.0, crest_foam_mid_detail, crest_foam_mid_fragmentation)
		* crest_distance_fade * crest_foam_strength;
	if (crest_foam_mode == 2) {
		ALBEDO = mix(ALBEDO, crest_foam_color, crest_foam);
		ROUGHNESS = mix(ROUGHNESS, crest_foam_roughness, crest_foam);
		SPECULAR = mix(SPECULAR, crest_foam_specular, crest_foam);
	} else if (crest_foam_mode == 3) {
		ALBEDO = vec3(crest_foam_raw_trigger);
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
	} else if (crest_foam_mode == 4) {
		ALBEDO = vec3(crest_foam);
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
	}
	ALPHA = 1.0;
}
