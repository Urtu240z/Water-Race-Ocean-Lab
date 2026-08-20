#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba32f, set = 0, binding = 0) uniform restrict readonly image2D input_a;
layout(rgba32f, set = 0, binding = 1) uniform restrict readonly image2D input_b;
layout(rgba32f, set = 0, binding = 2) uniform restrict writeonly image2D output_a;
layout(rgba32f, set = 0, binding = 3) uniform restrict writeonly image2D output_b;

layout(push_constant, std430) uniform Params {
	ivec4 values; // subtransform size, axis, resolution, inverse
} params;

vec2 complex_multiply(vec2 a, vec2 b) {
	return vec2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x);
}

vec4 butterfly(vec4 even_value, vec4 odd_value, vec2 twiddle) {
	return vec4(
		even_value.xy + complex_multiply(twiddle, odd_value.xy),
		even_value.zw + complex_multiply(twiddle, odd_value.zw)
	);
}

void main() {
	ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
	int n = params.values.z;
	if (coord.x >= n || coord.y >= n) {
		return;
	}

	int index = params.values.y == 0 ? coord.x : coord.y;
	int subtransform = params.values.x;
	int half_subtransform = subtransform / 2;
	int even_index = (index / subtransform) * half_subtransform + (index % half_subtransform);
	int odd_index = even_index + n / 2;
	ivec2 even_coord = params.values.y == 0 ? ivec2(even_index, coord.y) : ivec2(coord.x, even_index);
	ivec2 odd_coord = params.values.y == 0 ? ivec2(odd_index, coord.y) : ivec2(coord.x, odd_index);

	float sign_value = params.values.w != 0 ? 1.0 : -1.0;
	float angle = sign_value * 6.283185307179586 * (float(index) / float(subtransform));
	vec2 twiddle = vec2(cos(angle), sin(angle));
	imageStore(output_a, coord, butterfly(imageLoad(input_a, even_coord), imageLoad(input_a, odd_coord), twiddle));
	imageStore(output_b, coord, butterfly(imageLoad(input_b, even_coord), imageLoad(input_b, odd_coord), twiddle));
}
