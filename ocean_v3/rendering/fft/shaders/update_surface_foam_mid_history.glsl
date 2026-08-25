#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8) in;

layout(set = 0, binding = 0) uniform sampler2D displacement_mid;
layout(set = 0, binding = 1) uniform sampler2D previous_mid_fold_history;
layout(r16f, set = 0, binding = 2) uniform restrict writeonly image2D next_mid_fold_history;

layout(push_constant, std430) uniform Params {
	vec4 timing; // delta_s, birth_attack_s, lifetime_s, reserved
	vec4 fold; // fold_start, fold_end, reserved, reserved
} params;

void main() {
	ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(next_mid_fold_history);
	if (any(greaterThanEqual(coord, size))) {
		return;
	}

	float mid_j = texelFetch(displacement_mid, coord, 0).a;
	if (isnan(mid_j) || isinf(mid_j)) {
		mid_j = 1.0;
	}
	float mid_compression = max(0.0, 1.0 - mid_j);
	float birth_target = smoothstep(
		params.fold.x,
		max(params.fold.y, params.fold.x + 0.001),
		mid_compression
	);
	float previous = texelFetch(previous_mid_fold_history, coord, 0).r;
	if (isnan(previous) || isinf(previous)) {
		previous = 0.0;
	}
	float rate = birth_target > previous
		? 1.0 / max(params.timing.y, 0.001)
		: 1.0 / max(params.timing.z, 0.001);
	float alpha = 1.0 - exp(-rate * max(params.timing.x, 0.0));
	float next = mix(previous, birth_target, clamp(alpha, 0.0, 1.0));
	imageStore(next_mid_fold_history, coord, vec4(next, 0.0, 0.0, 1.0));
}
