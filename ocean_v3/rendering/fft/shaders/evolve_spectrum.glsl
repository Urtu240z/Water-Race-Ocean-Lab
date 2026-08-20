#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba32f, set = 0, binding = 0) uniform restrict readonly image2D h0_texture;
layout(rgba32f, set = 0, binding = 1) uniform restrict writeonly image2D spectrum_a;
layout(rgba32f, set = 0, binding = 2) uniform restrict writeonly image2D spectrum_b;

layout(push_constant, std430) uniform Params {
	vec4 values; // time, gravity, choppiness, domain size
} params;

vec2 complex_multiply(vec2 a, vec2 b) {
	return vec2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x);
}

void main() {
	ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(h0_texture);
	if (any(greaterThanEqual(coord, size))) {
		return;
	}

	vec2 centered = vec2(coord - size / 2);
	vec2 k = centered * (6.283185307179586 / params.values.w);
	float k_length = length(k);
	vec4 h0 = imageLoad(h0_texture, coord);
	float omega = sqrt(params.values.y * k_length);
	float phase = omega * params.values.x;
	vec2 positive_phase = vec2(cos(phase), sin(phase));
	vec2 negative_phase = vec2(positive_phase.x, -positive_phase.y);
	vec2 height = complex_multiply(h0.xy, positive_phase) + complex_multiply(h0.zw, negative_phase);

	vec2 dx = vec2(0.0);
	vec2 dz = vec2(0.0);
	if (k_length > 0.000001) {
		vec2 minus_i_h = vec2(height.y, -height.x);
		dx = minus_i_h * (k.x / k_length) * params.values.z;
		dz = minus_i_h * (k.y / k_length) * params.values.z;
	}
	imageStore(spectrum_a, coord, vec4(height, dx));
	imageStore(spectrum_b, coord, vec4(dz, 0.0, 0.0));
}
