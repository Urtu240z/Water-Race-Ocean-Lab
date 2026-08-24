#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Dedicated persistent surface foam driven only by SHORT's spectral Jacobian.
// The optional transport defaults to zero so the reference behavior remains
// anchored in spectral/base coordinates rather than hidden by advection.
layout(set = 0, binding = 0) uniform sampler2D displacement_map;
layout(set = 0, binding = 1) uniform sampler2D previous_displacement_map;
layout(set = 0, binding = 2) uniform sampler2D surface_foam_previous;
layout(r16f, set = 0, binding = 3) uniform restrict writeonly image2D surface_foam_next;

layout(push_constant, std430) uniform Params {
	vec4 foam; // whitecap, growth rate/sec, decay rate/sec, enabled
	vec4 transport; // delta seconds, advection strength, domain metres, unused
} params;

void main() {
	ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(surface_foam_next);
	if (any(greaterThanEqual(coord, size))) {
		return;
	}

	vec2 uv = (vec2(coord) + vec2(0.5)) / vec2(size);
	vec4 displacement_sample = textureLod(displacement_map, uv, 0.0);
	float jacobian = displacement_sample.a;
	if (isnan(jacobian) || isinf(jacobian)) {
		jacobian = 1.0;
	}

	float delta_s = max(params.transport.x, 0.0);
	vec2 current_displacement_xz = displacement_sample.xz;
	vec2 previous_displacement_xz = textureLod(previous_displacement_map, uv, 0.0).rg;
	vec2 velocity_xz = delta_s > 0.00001
		? (current_displacement_xz - previous_displacement_xz) / delta_s
		: vec2(0.0);
	vec2 backtrace_uv = uv - velocity_xz * delta_s * max(params.transport.y, 0.0)
		/ max(params.transport.z, 0.001);
	float previous = textureLod(surface_foam_previous, backtrace_uv, 0.0).r;
	if (isnan(previous) || isinf(previous)) {
		previous = 0.0;
	}

	float source = max(0.0, params.foam.x - jacobian) * clamp(params.foam.w, 0.0, 1.0);
	float decayed = previous * exp(-max(params.foam.z, 0.0) * delta_s);
	// Match OceanWaves' temporal dynamics: a persistent, even small, SHORT-J
	// source deposits foam every frame while existing foam decays continuously.
	// Both terms use rates per second and the real delta, so the integration is
	// independent of frame rate rather than converging to source's amplitude.
	float deposited = source * max(params.foam.y, 0.0) * delta_s;
	float next = clamp(decayed + deposited, 0.0, 1.0);
	imageStore(surface_foam_next, coord, vec4(clamp(next, 0.0, 1.0), 0.0, 0.0, 1.0));
}
