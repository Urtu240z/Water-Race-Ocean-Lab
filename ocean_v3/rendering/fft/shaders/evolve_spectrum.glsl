#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba32f, set = 0, binding = 0) uniform restrict readonly image2D h0_texture;
layout(rgba32f, set = 0, binding = 1) uniform restrict writeonly image2D spectrum_a;
layout(rgba32f, set = 0, binding = 2) uniform restrict writeonly image2D spectrum_b;
layout(rgba32f, set = 0, binding = 3) uniform restrict writeonly image2D spectrum_c;

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
	vec2 dhx_dx = vec2(0.0);
	vec2 dhz_dz = vec2(0.0);
	vec2 dhz_dx = vec2(0.0);
	if (k_length > 0.000001) {
		// Config choppiness is positive; Tessendorf horizontal displacement uses
		// negative lambda so crests compress instead of valleys.
		float lambda = -params.values.z;
		vec2 minus_i_h = vec2(height.y, -height.x);
		dx = minus_i_h * (k.x / k_length) * lambda;
		dz = minus_i_h * (k.y / k_length) * lambda;
		// Spectral derivatives of the already-established horizontal fields.
		// d/dx and d/dz multiply a Fourier coefficient by i*kx / i*kz.
		// With this potential displacement, dDx/dz == dDz/dx, so the third
		// cross derivative is sufficient for the full horizontal Jacobian.
		dhx_dx = vec2(-dx.y, dx.x) * k.x;
		dhz_dz = vec2(-dz.y, dz.x) * k.y;
		dhz_dx = vec2(-dz.y, dz.x) * k.x;
	}
	imageStore(spectrum_a, coord, vec4(height, dx));
	imageStore(spectrum_b, coord, vec4(dz, dhx_dx));
	imageStore(spectrum_c, coord, vec4(dhz_dz, dhz_dx));
}
