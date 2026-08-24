#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba32f, set = 0, binding = 0) uniform restrict readonly image2D spatial_a;
layout(rgba32f, set = 0, binding = 1) uniform restrict readonly image2D spatial_b;
layout(rgba32f, set = 0, binding = 2) uniform restrict readonly image2D spatial_c;
layout(rgba32f, set = 0, binding = 3) uniform restrict writeonly image2D displacement_map;
// normal_map is persistent: alpha is read from the previous frame before the
// current normal/Jacobian result is stored back into the same image.
layout(rgba16f, set = 0, binding = 4) uniform restrict image2D normal_map;

layout(push_constant, std430) uniform Params {
	vec4 values; // domain, normalization, texel metres, foam source gain
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
	float checkerboard = ((coord.x + coord.y) & 1) == 0 ? 1.0 : -1.0;
	float spectral_scale = checkerboard * params.values.y;
	vec4 spatial_b_value = imageLoad(spatial_b, coord);
	vec4 spatial_c_value = imageLoad(spatial_c, coord);
	float dhx_dx = spatial_b_value.z * spectral_scale;
	float dhz_dz = spatial_c_value.x * spectral_scale;
	float dhz_dx = spatial_c_value.z * spectral_scale;
	// dHx/dz == dHz/dx for the current irrotational Tessendorf displacement.
	// This is the production Jacobian; central differences above remain only
	// for the geometric normal.
	float jacobian = (1.0 + dhx_dx) * (1.0 + dhz_dz) - dhz_dx * dhz_dx;
	if (isnan(jacobian) || isinf(jacobian)) {
		jacobian = 1.0;
	}
	float foam_source = max(0.0, params.foam.x - jacobian);
	float previous_foam = imageLoad(normal_map, coord).a;
	if (isnan(previous_foam) || isinf(previous_foam)) {
		previous_foam = 0.0;
	}
	float residual = previous_foam * exp(-max(params.foam.z, 0.0));
	float target_source = clamp(foam_source * max(params.values.w, 0.0) * max(params.foam.w, 0.0), 0.0, 1.0);
	float birth_alpha = 1.0 - exp(-max(params.foam.y, 0.0));
	float foam = max(residual, mix(residual, target_source, birth_alpha));
	vec3 normal = normalize(cross(derivative_z, derivative_x));
	if (any(isnan(displacement)) || any(isinf(displacement)) || any(isnan(normal)) || any(isinf(normal))) {
		displacement = vec3(0.0);
		normal = vec3(0.0, 1.0, 0.0);
	}
	// Alpha retains the exact spectral J for GPU-only diagnostic rendering.
	imageStore(displacement_map, coord, vec4(displacement, jacobian));
	imageStore(normal_map, coord, vec4(normal, foam));
}
