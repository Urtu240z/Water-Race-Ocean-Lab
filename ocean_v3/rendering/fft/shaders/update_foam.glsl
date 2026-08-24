#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// All sampled inputs use repeat + hardware-linear filtering. Fresh foam samples
// current spectral J; only residual history receives a semi-Lagrangian trace.
layout(set = 0, binding = 0) uniform sampler2D displacement_map;
layout(set = 0, binding = 1) uniform sampler2D previous_displacement_map;
layout(set = 0, binding = 2) uniform sampler2D foam_previous;
layout(rg16f, set = 0, binding = 3) uniform restrict writeonly image2D foam_next;

layout(push_constant, std430) uniform Params {
	vec4 fresh; // whitecap threshold, growth(delta), cascade weight, deposit strength
	vec4 transport; // residual decay(delta), delta seconds, enabled, strength
	vec4 domain; // domain metres
} params;

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

	float source = max(0.0, params.fresh.x - jacobian);
	float fresh_target = clamp(source * max(params.fresh.z, 0.0), 0.0, 1.0);
	float fresh_birth = 1.0 - exp(-max(params.fresh.y, 0.0));
	// G has no history: it is deliberately tied to this frame's compression.
	float fresh = mix(0.0, fresh_target, fresh_birth);
	float residual = previous_residual * exp(-max(params.transport.x, 0.0));
	// Deposit via max rather than linear accumulation to avoid saturation plateaus.
	residual = max(residual, fresh * max(params.fresh.w, 0.0));
	imageStore(foam_next, coord, vec4(clamp(residual, 0.0, 1.0), clamp(fresh, 0.0, 1.0), 0.0, 1.0));
}
