#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8) in;

layout(set = 0, binding = 0) uniform sampler2D jacobian_map;
layout(set = 0, binding = 1) uniform sampler2D surface_foam_previous;
layout(r16f, set = 0, binding = 2) uniform restrict writeonly image2D surface_foam_next;

layout(push_constant, std430) uniform Params {
	vec4 foam;
	vec4 timing;
} params;

void main() {
	ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(surface_foam_next);
	if (any(greaterThanEqual(coord, size))) {
		return;
	}
	vec2 uv = (vec2(coord) + vec2(0.5)) / vec2(size);
	float jacobian = textureLod(jacobian_map, uv, 0.0).r;
	if (isnan(jacobian) || isinf(jacobian)) {
		jacobian = 1.0;
	}
	float previous = textureLod(surface_foam_previous, uv, 0.0).r;
	if (isnan(previous) || isinf(previous)) {
		previous = 0.0;
	}
	float delta_s = max(params.timing.x, 0.0);
	float source = max(0.0, params.foam.x - jacobian) * clamp(params.foam.w, 0.0, 1.0);
	float decayed = previous * exp(-max(params.foam.z, 0.0) * delta_s);
	float deposited = source * max(params.foam.y, 0.0) * delta_s;
	float next = clamp(decayed + deposited, 0.0, 1.0);
	imageStore(surface_foam_next, coord, vec4(next, 0.0, 0.0, 1.0));
}
