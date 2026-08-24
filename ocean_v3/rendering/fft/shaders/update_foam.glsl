#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// The sampled displacement map provides spectral J in alpha. The sampler is
// repeat + linear, so a high-resolution foam cell sees a continuous J field.
layout(set = 0, binding = 0) uniform sampler2D displacement_map;
layout(r16f, set = 0, binding = 1) uniform restrict readonly image2D foam_previous;
layout(r16f, set = 0, binding = 2) uniform restrict writeonly image2D foam_next;

layout(push_constant, std430) uniform Params {
	vec4 foam; // whitecap threshold, grow(delta), decay(delta), cascade weight
} params;

void main() {
	ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(foam_next);
	if (any(greaterThanEqual(coord, size))) {
		return;
	}

	vec2 uv = (vec2(coord) + vec2(0.5)) / vec2(size);
	float jacobian = textureLod(displacement_map, uv, 0.0).a;
	if (isnan(jacobian) || isinf(jacobian)) {
		jacobian = 1.0;
	}
	float previous = imageLoad(foam_previous, coord).r;
	if (isnan(previous) || isinf(previous)) {
		previous = 0.0;
	}

	float source = max(0.0, params.foam.x - jacobian);
	float residual = previous * exp(-max(params.foam.z, 0.0));
	float target = clamp(source * max(params.foam.w, 0.0), 0.0, 1.0);
	float birth_alpha = 1.0 - exp(-max(params.foam.y, 0.0));
	float foam = max(residual, mix(residual, target, birth_alpha));
	imageStore(foam_next, coord, vec4(clamp(foam, 0.0, 1.0)));
}
