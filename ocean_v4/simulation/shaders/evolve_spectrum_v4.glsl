#[compute]
#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba32f, set = 0, binding = 0) uniform restrict readonly image2D h0_current;
layout(rgba32f, set = 0, binding = 1) uniform restrict readonly image2D h0_unused;
layout(rgba32f, set = 0, binding = 2) uniform restrict writeonly image2D spectrum_a;
layout(rgba32f, set = 0, binding = 3) uniform restrict writeonly image2D spectrum_b;
layout(rgba32f, set = 0, binding = 4) uniform restrict writeonly image2D spectrum_c;
layout(push_constant, std430) uniform Params { vec4 values; float unused_transition; } params;
vec2 cmul(vec2 a, vec2 b) { return vec2(a.x*b.x-a.y*b.y, a.x*b.y+a.y*b.x); }
void main() {
	ivec2 coord = ivec2(gl_GlobalInvocationID.xy); ivec2 size = imageSize(h0_current);
	if (any(greaterThanEqual(coord, size))) return;
	vec2 k = vec2(coord - size / 2) * (6.28318530718 / params.values.w);
	float klen = length(k); vec4 h0 = imageLoad(h0_current, coord);
	float phase = -sqrt(params.values.y * klen) * params.values.x;
	vec2 pos = vec2(cos(phase), sin(phase)); vec2 neg = vec2(pos.x, -pos.y);
	vec2 height = cmul(h0.xy, pos) + cmul(h0.zw, neg);
	vec2 dx = vec2(0.0), dz = vec2(0.0), dhx_dx = vec2(0.0), dhz_dz = vec2(0.0), dhz_dx = vec2(0.0);
	if (klen > 0.000001) {
		vec2 minus_i_h = vec2(height.y, -height.x); float lambda = -params.values.z;
		dx = minus_i_h * (k.x / klen) * lambda; dz = minus_i_h * (k.y / klen) * lambda;
		dhx_dx = vec2(-dx.y, dx.x) * k.x; dhz_dz = vec2(-dz.y, dz.x) * k.y; dhz_dx = vec2(-dz.y, dz.x) * k.x;
	}
	imageStore(spectrum_a, coord, vec4(height, dx)); imageStore(spectrum_b, coord, vec4(dz, dhx_dx)); imageStore(spectrum_c, coord, vec4(dhz_dz, dhz_dx));
}
