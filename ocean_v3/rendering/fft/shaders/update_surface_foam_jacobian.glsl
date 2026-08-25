#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8) in;

layout(set = 0, binding = 0) uniform sampler2D jacobian_map;
layout(set = 0, binding = 1) uniform sampler2D surface_foam_previous;
layout(rg16f, set = 0, binding = 2) uniform restrict writeonly image2D surface_foam_next;

layout(push_constant, std430) uniform Params {
	vec4 foam;
	vec4 timing;
	vec4 spatial; // field domain, source domain, warp amplitude, reserved
} params;

const float TAU = 6.283185307179586;
const float HISTORY_HYSTERESIS_WIDTH = 0.12;
const float HISTORY_ACTIVE_EPSILON = 0.001;

vec2 source_uv_a(vec2 field_world_xz) {
	float field_domain = max(params.spatial.x, 0.001);
	float phase_x = field_world_xz.x * TAU / field_domain;
	float phase_z = field_world_xz.y * TAU / field_domain;
	float amplitude = max(params.spatial.z, 0.0);
	vec2 warp = 0.5 * amplitude * vec2(
		sin(phase_x + 0.37) + sin(2.0 * phase_z + 1.11),
		cos(phase_z + 0.71) + cos(3.0 * phase_x + 2.07)
	);
	return (field_world_xz + warp) / max(params.spatial.y, 0.001);
}

vec2 source_uv_b(vec2 field_world_xz) {
	float field_domain = max(params.spatial.x, 0.001);
	float phase_x = field_world_xz.x * TAU / field_domain;
	float phase_z = field_world_xz.y * TAU / field_domain;
	float amplitude = max(params.spatial.z, 0.0);
	vec2 warp = 0.5 * amplitude * vec2(
		sin(phase_x + 0.37) + sin(2.0 * phase_z + 1.11),
		cos(phase_z + 0.71) + cos(3.0 * phase_x + 2.07)
	);
	mat2 rotation = mat2(vec2(0.7986355, -0.6018150), vec2(0.6018150, 0.7986355));
	vec2 transformed_warp = rotation * (warp * 1.19) + vec2(2.37, -1.41);
	return (field_world_xz + transformed_warp) / max(params.spatial.y, 0.001);
}

vec2 source_uv_direct(vec2 field_world_xz) {
	return field_world_xz / max(params.spatial.y, 0.001);
}

float deperiodized_selector(vec2 field_world_xz) {
	float field_domain = max(params.spatial.x, 0.001);
	float phase_x = field_world_xz.x * TAU / field_domain;
	float phase_z = field_world_xz.y * TAU / field_domain;
	float selector_raw = 0.5 + 0.5 * sin(phase_x + 0.83) * cos(2.0 * phase_z + 1.47);
	return smoothstep(0.42, 0.58, selector_raw);
}

float foam_source_from_jacobian(float jacobian) {
	float source = max(0.0, params.foam.x - jacobian) * clamp(params.foam.w, 0.0, 1.0);
	return clamp(source * max(params.foam.y, 0.0), 0.0, 1.0);
}

// Diagnostic topology source. It deliberately bypasses Amount, Birth
// Selectivity, temporal history and presentation shaping.
float raw_source_from_jacobian(float jacobian) {
	return max(0.0, params.foam.x - jacobian);
}

float foam_target_from_source(float source_normalized, float selectivity) {
	float selectivity_upper = selectivity + max(params.timing.w, 0.001);
	float birth_gate = smoothstep(selectivity, selectivity_upper, source_normalized);
	return source_normalized * birth_gate;
}

void main() {
	ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(surface_foam_next);
	if (any(greaterThanEqual(coord, size))) {
		return;
	}
	vec2 field_uv = (vec2(coord) + vec2(0.5)) / vec2(size);
	vec2 field_world_xz = (field_uv - vec2(0.5)) * params.spatial.x;
	float jacobian_a = textureLod(jacobian_map, source_uv_a(field_world_xz), 0.0).r;
	float jacobian_b = jacobian_a;
	if (params.spatial.w != 3.0) {
		jacobian_b = textureLod(jacobian_map, source_uv_b(field_world_xz), 0.0).r;
	}
	if (isnan(jacobian_a) || isinf(jacobian_a)) {
		jacobian_a = 1.0;
	}
	if (isnan(jacobian_b) || isinf(jacobian_b)) {
		jacobian_b = 1.0;
	}
	float source_a = foam_source_from_jacobian(jacobian_a);
	float source_b = foam_source_from_jacobian(jacobian_b);
	float raw_source_a = raw_source_from_jacobian(jacobian_a);
	float raw_source_b = raw_source_from_jacobian(jacobian_b);
	float birth_selectivity = clamp(params.foam.z, 0.0, 1.0);
	float sustain_selectivity = max(birth_selectivity - HISTORY_HYSTERESIS_WIDTH, 0.0);
	float birth_target_a = foam_target_from_source(source_a, birth_selectivity);
	float birth_target_b = foam_target_from_source(source_b, birth_selectivity);
	float sustain_target_a = foam_target_from_source(source_a, sustain_selectivity);
	float sustain_target_b = foam_target_from_source(source_b, sustain_selectivity);
	float selector = deperiodized_selector(field_world_xz);
	float selected_birth_target = params.spatial.w == 3.0 ? birth_target_a : mix(birth_target_a, birth_target_b, selector);
	float selected_sustain_target = params.spatial.w == 3.0 ? sustain_target_a : mix(sustain_target_a, sustain_target_b, selector);
	float selected_raw_source = params.spatial.w == 3.0 ? raw_source_a : mix(raw_source_a, raw_source_b, selector);
	float previous = textureLod(surface_foam_previous, field_uv, 0.0).r;
	if (isnan(previous) || isinf(previous)) {
		previous = 0.0;
	}
	float delta_s = max(params.timing.x, 0.0);
	// New coverage must clear the original birth gate. Existing coverage gets a
	// slightly lower sustain gate, but releases when physical support is gone.
	float target = previous > HISTORY_ACTIVE_EPSILON ? selected_sustain_target : selected_birth_target;
	float attack_rate = 1.0 / max(params.timing.y, 0.001);
	float release_rate = 1.0 / max(params.timing.z, 0.001);
	float rate = target > previous ? attack_rate : release_rate;
	float alpha = 1.0 - exp(-rate * delta_s);
	float next = mix(previous, target, clamp(alpha, 0.0, 1.0));
	float debug_source = selected_birth_target;
	if (params.spatial.w == 1.0) {
		debug_source = birth_target_a;
	} else if (params.spatial.w == 2.0) {
		debug_source = birth_target_b;
	} else if (params.spatial.w == 4.0) {
		float direct_jacobian = textureLod(jacobian_map, source_uv_direct(field_world_xz), 0.0).r;
		if (isnan(direct_jacobian) || isinf(direct_jacobian)) {
			direct_jacobian = 1.0;
		}
		debug_source = foam_target_from_source(foam_source_from_jacobian(direct_jacobian), birth_selectivity);
	} else if (params.spatial.w == 5.0 || params.spatial.w == 8.0) {
		// RAW_J_SOURCE and RAW_SELECTED_SOURCE are the same selected topology.
		debug_source = selected_raw_source;
	} else if (params.spatial.w == 6.0) {
		debug_source = raw_source_a;
	} else if (params.spatial.w == 7.0) {
		debug_source = raw_source_b;
	} else if (params.spatial.w == 9.0) {
		float direct_jacobian = textureLod(jacobian_map, source_uv_direct(field_world_xz), 0.0).r;
		if (isnan(direct_jacobian) || isinf(direct_jacobian)) {
			direct_jacobian = 1.0;
		}
		debug_source = raw_source_from_jacobian(direct_jacobian);
	}
	imageStore(surface_foam_next, coord, vec4(next, debug_source, 0.0, 1.0));
}
