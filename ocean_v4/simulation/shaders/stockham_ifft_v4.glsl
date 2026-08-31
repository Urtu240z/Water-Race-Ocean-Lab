#[compute]
#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba32f, set = 0, binding = 0) uniform restrict readonly image2D input_a;
layout(rgba32f, set = 0, binding = 1) uniform restrict readonly image2D input_b;
layout(rgba32f, set = 0, binding = 2) uniform restrict readonly image2D input_c;
layout(rgba32f, set = 0, binding = 3) uniform restrict writeonly image2D output_a;
layout(rgba32f, set = 0, binding = 4) uniform restrict writeonly image2D output_b;
layout(rgba32f, set = 0, binding = 5) uniform restrict writeonly image2D output_c;
layout(push_constant, std430) uniform Params { ivec4 values; } params;
vec2 cmul(vec2 a, vec2 b) { return vec2(a.x*b.x-a.y*b.y, a.x*b.y+a.y*b.x); }
vec4 butterfly(vec4 even_value, vec4 odd_value, vec2 twiddle) { return vec4(even_value.xy + cmul(twiddle, odd_value.xy), even_value.zw + cmul(twiddle, odd_value.zw)); }
void main() {
	ivec2 coord = ivec2(gl_GlobalInvocationID.xy); int n = params.values.z; if (coord.x >= n || coord.y >= n) return;
	int index = params.values.y == 0 ? coord.x : coord.y; int sub = params.values.x; int half_sub = sub / 2;
	int even_i = (index / sub) * half_sub + (index % half_sub); int odd_i = even_i + n / 2;
	ivec2 even_c = params.values.y == 0 ? ivec2(even_i, coord.y) : ivec2(coord.x, even_i);
	ivec2 odd_c = params.values.y == 0 ? ivec2(odd_i, coord.y) : ivec2(coord.x, odd_i);
	float sign_value = params.values.w != 0 ? 1.0 : -1.0; float angle = sign_value * 6.28318530718 * float(index) / float(sub); vec2 twiddle = vec2(cos(angle), sin(angle));
	imageStore(output_a, coord, butterfly(imageLoad(input_a, even_c), imageLoad(input_a, odd_c), twiddle));
	imageStore(output_b, coord, butterfly(imageLoad(input_b, even_c), imageLoad(input_b, odd_c), twiddle));
	imageStore(output_c, coord, butterfly(imageLoad(input_c, even_c), imageLoad(input_c, odd_c), twiddle));
}
