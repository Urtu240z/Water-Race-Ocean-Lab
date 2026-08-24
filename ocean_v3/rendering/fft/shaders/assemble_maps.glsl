#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba32f, set = 0, binding = 0) uniform restrict readonly image2D spatial_a;
layout(rgba32f, set = 0, binding = 1) uniform restrict readonly image2D spatial_b;
layout(rgba32f, set = 0, binding = 2) uniform restrict writeonly image2D displacement_map;
// normal_map is persistent: alpha is read from the previous frame before the
// current normal/Jacobian result is stored back into the same image.
layout(rgba16f, set = 0, binding = 3) uniform restrict image2D normal_map;

layout(push_constant, std430) uniform Params {
	vec4 values; // domain, normalization, texel metres, reserved
	vec4 foam; // whitecap threshold, grow(delta), decay(delta), cascade weight
} params;

ivec2 wrap_coord(ivec2 coord, ivec2 size) {
	return ivec2((coord.x + size.x) % size.x, (coord.y + size.y) % size.y);
}

vec3 displacement_at(ivec2 coord, ivec2 size) {
	ivec2 wrapped = wrap_coord(coord, size);
	float checkerboard = ((wrapped.x + wrapped.y) & 1) == 0 ? 1.0 : -1.0;
	vec4 a = imageLoad(spatial_a, wrapped);
	vec4 b = imageLoad(spatial_b, wrapped);
	return vec3(a.z, a.x, b.x) * (checkerboard * params.values.y);
}

void main() {
	ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(spatial_a);
	if (any(greaterThanEqual(coord, size))) {
		return;
	}

	vec3 displacement = displacement_at(coord, size);
	vec3 left = displacement_at(coord - ivec2(1, 0), size);
	vec3 right = displacement_at(coord + ivec2(1, 0), size);
	vec3 down = displacement_at(coord - ivec2(0, 1), size);
	vec3 up = displacement_at(coord + ivec2(0, 1), size);
	float inverse_two_dx = 0.5 / params.values.z;
	vec3 derivative_x = vec3(1.0, 0.0, 0.0) + (right - left) * inverse_two_dx;
	vec3 derivative_z = vec3(0.0, 0.0, 1.0) + (up - down) * inverse_two_dx;
	float dXdx = (right.x - left.x) * inverse_two_dx;
	float dZdx = (right.z - left.z) * inverse_two_dx;
	float dXdz = (up.x - down.x) * inverse_two_dx;
	float dZdz = (up.z - down.z) * inverse_two_dx;
	// Horizontal deformation of the displaced surface. X/Z follow the same
	// displacement convention used by displacement_at() above.
	float jacobian = (1.0 + dXdx) * (1.0 + dZdz) - dZdx * dXdz;
	float foam_source = max(0.0, params.foam.x - jacobian);
	float foam = imageLoad(normal_map, coord).a;
	if (isnan(foam) || isinf(foam)) {
		foam = 0.0;
	}
	foam *= exp(-max(params.foam.z, 0.0));
	foam += foam_source * max(params.foam.y, 0.0) * max(params.foam.w, 0.0);
	foam = clamp(foam, 0.0, 1.0);
	vec3 normal = normalize(cross(derivative_z, derivative_x));
	if (any(isnan(displacement)) || any(isinf(displacement)) || any(isnan(normal)) || any(isinf(normal))) {
		displacement = vec3(0.0);
		normal = vec3(0.0, 1.0, 0.0);
	}
	imageStore(displacement_map, coord, vec4(displacement, 1.0));
	imageStore(normal_map, coord, vec4(normal, foam));
}
