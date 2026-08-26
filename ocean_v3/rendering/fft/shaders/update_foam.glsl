#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// All sampled inputs use repeat + hardware-linear filtering. New fresh foam is
// born from current spectral J, while both previous history channels receive the
// same semi-Lagrangian trace.
layout(set = 0, binding = 0) uniform sampler2D displacement_map;
layout(set = 0, binding = 1) uniform sampler2D previous_displacement_map;
layout(set = 0, binding = 2) uniform sampler2D foam_previous;
layout(rg16f, set = 0, binding = 3) uniform restrict writeonly image2D foam_next;

layout(push_constant, std430) uniform Params {
	vec4 fresh; // whitecap threshold, attack rate/sec, cascade weight, deposit strength
	vec4 transport; // residual decay rate/sec, delta seconds, enabled, strength
	// ABI shared with GPUStockhamFFT foam_push:
	// x = domain metres, y = transition alpha, z = signed target-current
	// whitecap delta, w = 1 while a global wave transition is active.
	vec4 domain;
} params;

// The release rate is derived from the existing residual decay rate so the
// public push-constant layout stays compact and rates remain per-second.
const float RESIDUAL_DECAY_BASE_MULTIPLIER = 1.15;
const float FRESH_RELEASE_BASE_MULTIPLIER = 2.0;

void main() {
	ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(foam_next);
	if (any(greaterThanEqual(coord, size))) {
		return;
	}

	vec2 uv = (vec2(coord) + vec2(0.5)) / vec2(size);
	vec4 current_displacement_sample = textureLod(displacement_map, uv, 0.0);
	float jacobian = current_displacement_sample.a;
	if (isnan(jacobian) || isinf(jacobian)) {
		jacobian = 1.0;
	}
	vec2 current_displacement_xz = current_displacement_sample.xz;
	vec2 previous_displacement_xz = textureLod(previous_displacement_map, uv, 0.0).rg;
	float delta_s = max(params.transport.y, 0.0);
	vec2 velocity_xz = delta_s > 0.00001
		? (current_displacement_xz - previous_displacement_xz) / delta_s
		: vec2(0.0);
	vec2 backtrace_uv = uv - velocity_xz * delta_s
		* params.transport.z * params.transport.w / max(params.domain.x, 0.001);
	float previous_residual = textureLod(foam_previous, backtrace_uv, 0.0).r;
	if (isnan(previous_residual) || isinf(previous_residual)) {
		previous_residual = 0.0;
	}
	// Birth remains tied to the current compression field below. This is only the
	// inherited temporal state, which must travel with the foam just like residual.
	float previous_fresh = textureLod(foam_previous, backtrace_uv, 0.0).g;
	if (isnan(previous_fresh) || isinf(previous_fresh)) {
		previous_fresh = 0.0;
	}

	float effective_whitecap = params.fresh.x;
	float transition_alpha = clamp(params.domain.y, 0.0, 1.0);
	float whitecap_delta = params.domain.z;
	bool transition_active = params.domain.w > 0.5;
	// Recover both endpoint thresholds from the effective value. Mixing the two
	// ReLU sources gives the first physically valid TARGET crests a gradual birth;
	// applying ReLU only after threshold lerp would hold them at zero until late.
	float current_whitecap = effective_whitecap - transition_alpha * whitecap_delta;
	float target_whitecap = current_whitecap + whitecap_delta;
	float source_current = max(0.0, current_whitecap - jacobian);
	float source_target = max(0.0, target_whitecap - jacobian);
	float source = transition_active
		? mix(source_current, source_target, transition_alpha)
		: max(0.0, effective_whitecap - jacobian);
	float compression = effective_whitecap - jacobian;
	float fresh_target = clamp(source * max(params.fresh.z, 0.0), 0.0, 1.0);
	float fresh_attack_rate = max(params.fresh.y, 0.0);
	float fresh_release_rate = max(params.transport.x, 0.0)
		* FRESH_RELEASE_BASE_MULTIPLIER / RESIDUAL_DECAY_BASE_MULTIPLIER;
	float fresh_rate = fresh_target > previous_fresh
		? fresh_attack_rate
		: fresh_release_rate;
	float fresh_alpha = 1.0 - exp(-fresh_rate * delta_s);
	float fresh = mix(previous_fresh, fresh_target, fresh_alpha);

	float residual_decay_rate = max(params.transport.x, 0.0);
	float residual = previous_residual * exp(-residual_decay_rate * delta_s);
	if (transition_active) {
		// The field remains persistent, but transition-time history cannot stay
		// visibly detached from the blended crest. Fresh requires compression at the
		// current texel; residual accepts a broader host window and still advects.
		float normalized_compression = compression / max(abs(effective_whitecap), 0.001);
		float fresh_host_support = smoothstep(0.0, 1.0, normalized_compression);
		float residual_host_support = smoothstep(-1.0, 1.0, normalized_compression);
		// Vanish at both endpoint alphas, preserving steady endpoint behavior while
		// accelerating release only through the physical transition interval.
		float transition_lock = 4.0 * transition_alpha * (1.0 - transition_alpha);
		fresh *= exp(-fresh_release_rate * transition_lock * (1.0 - fresh_host_support) * delta_s);
		residual *= exp(-residual_decay_rate * transition_lock * (1.0 - residual_host_support) * delta_s);
	}
	// Because fresh is now temporal state, max() deposits a frame-rate
	// independent target and avoids linear accumulation/saturation plateaus.
	residual = max(residual, fresh * max(params.fresh.w, 0.0));
	imageStore(foam_next, coord, vec4(clamp(residual, 0.0, 1.0), clamp(fresh, 0.0, 1.0), 0.0, 1.0));
}
