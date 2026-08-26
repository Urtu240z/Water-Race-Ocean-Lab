#[compute]
#version 450

// Surface Foam only consumes the spectral Jacobian.  Keep just the three
// complex derivatives in two payloads; height and horizontal displacement are
// intentionally not materialised here.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba32f, set = 0, binding = 0) uniform restrict readonly image2D h0_texture;
layout(rgba32f, set = 0, binding = 1) uniform restrict writeonly image2D payload_a;
layout(rgba32f, set = 0, binding = 2) uniform restrict writeonly image2D payload_b;

layout(set = 0, binding = 3, std140) uniform Params { vec4 values; } params; // time, gravity, depth, source domain

vec2 cmul(vec2 a, vec2 b) { return vec2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x); }

void main() {
	ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(h0_texture);
	if (any(greaterThanEqual(coord, size))) return;
	vec2 k = vec2(coord - size / 2) * (6.283185307179586 / params.values.w);
	float k_length = length(k);
	vec4 h0 = imageLoad(h0_texture, coord);
	float omega = sqrt(params.values.y * k_length * tanh(k_length * params.values.z));
	vec2 phase = vec2(cos(omega * params.values.x), sin(omega * params.values.x));
	vec2 height = cmul(h0.xy, phase) + cmul(h0.zw, vec2(phase.x, -phase.y));
	vec2 dhx_dx = vec2(0.0);
	vec2 dhz_dz = vec2(0.0);
	vec2 dhz_dx = vec2(0.0);
	if (k_length > 0.000001) {
		vec2 unit_k = k / k_length;
		dhx_dx = -height * k.y * unit_k.y;
		dhz_dz = -height * k.x * unit_k.x;
		dhz_dx = -height * k.y * unit_k.x;
	}
	imageStore(payload_a, coord, vec4(dhx_dx, dhz_dz));
	imageStore(payload_b, coord, vec4(dhz_dx, 0.0, 0.0));
}
