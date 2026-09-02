#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba32f, set = 0, binding = 0) uniform restrict readonly image2D input_packed;
layout(rgba32f, set = 0, binding = 1) uniform restrict writeonly image2D output_packed;
layout(set = 0, binding = 2, std140) uniform Params { ivec4 values; } params; // subtransform, axis, resolution, inverse

vec2 cmul(vec2 a, vec2 b) { return vec2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x); }
vec4 butterfly(vec4 even_value, vec4 odd_value, vec2 twiddle) {
	return vec4(even_value.xy + cmul(twiddle, odd_value.xy), even_value.zw + cmul(twiddle, odd_value.zw));
}
void main() {
	ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
	int n = params.values.z;
	if (coord.x >= n || coord.y >= n) return;
	int index = params.values.y == 0 ? coord.x : coord.y;
	int subtransform = params.values.x;
	int half_subtransform = subtransform / 2;
	int even_index = (index / subtransform) * half_subtransform + (index % half_subtransform);
	int odd_index = even_index + n / 2;
	ivec2 even_coord = params.values.y == 0 ? ivec2(even_index, coord.y) : ivec2(coord.x, even_index);
	ivec2 odd_coord = params.values.y == 0 ? ivec2(odd_index, coord.y) : ivec2(coord.x, odd_index);
	float sign_value = params.values.w != 0 ? 1.0 : -1.0;
	vec2 twiddle = vec2(cos(sign_value * 6.283185307179586 * float(index) / float(subtransform)), sin(sign_value * 6.283185307179586 * float(index) / float(subtransform)));
	imageStore(output_packed, coord, butterfly(imageLoad(input_packed, even_coord), imageLoad(input_packed, odd_coord), twiddle));
}
