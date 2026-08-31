#[compute]
#version 450

// PRE_TRANSPARENT compositor pass. The resolved color image contains the
// opaque scene; caustics are added in-place before Ocean V3's transparent water.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D scene_depth;
layout(set = 0, binding = 2) uniform sampler2D caustics_texture;

layout(push_constant, std430) uniform Params {
	mat4 inverse_view_projection;
	vec4 viewport; // width, height, unused, unused
	vec4 caustics; // sea level, texture scale, strength, power
	vec4 fade; // start depth, max depth, time, enabled/debug
	vec4 sun; // surface -> sun direction, unused
} params;

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.viewport.xy);
	if (pixel.x >= size.x || pixel.y >= size.y) {
		return;
	}

	vec4 color = imageLoad(color_image, pixel);
	if (params.fade.w < 0.5) {
		return;
	}
	float raw_depth = texelFetch(scene_depth, pixel, 0).r;
	if (!(raw_depth > 0.000001) || raw_depth > 1.000001) {
		return;
	}
	vec2 uv = (vec2(pixel) + vec2(0.5)) / params.viewport.xy;
	vec2 ndc = uv * 2.0 - 1.0;
	vec4 world_position = params.inverse_view_projection * vec4(ndc, raw_depth, 1.0);
	if (abs(world_position.w) <= 0.000001) {
		return;
	}
	world_position /= world_position.w;
	if (any(isnan(world_position.xyz)) || any(isinf(world_position.xyz))) {
		return;
	}

	float water_depth = params.caustics.x - world_position.y;
	if (water_depth <= 0.0) {
		return;
	}
	float shallow = 1.0 - smoothstep(params.fade.x, max(params.fade.y, params.fade.x + 0.001), water_depth);
	if (shallow <= 0.0001) {
		return;
	}
	vec3 light = normalize(params.sun.xyz);
	float sun_height = smoothstep(0.04, 0.45, light.y);
	if (sun_height <= 0.0001) {
		return;
	}
	vec2 sun_axis = vec2(light.x, light.z);
	if (dot(sun_axis, sun_axis) < 0.000001) {
		sun_axis = vec2(0.0, 1.0);
	} else {
		sun_axis = normalize(sun_axis);
	}
	vec2 sun_tangent = vec2(-sun_axis.y, sun_axis.x);
	vec2 projected = vec2(
		dot(world_position.xz, sun_tangent),
		dot(world_position.xz, sun_axis)
	) * max(params.caustics.y, 0.0001);
	float time = params.fade.z;
	vec2 uv_a = fract(projected + vec2(time * 0.030, -time * 0.018));
	vec2 uv_b = fract(projected * vec2(1.07, 0.93) + vec2(-time * 0.021, time * 0.026));
	float sample_a = pow(max(texture(caustics_texture, uv_a).r, 0.0), max(params.caustics.w, 0.01));
	float sample_b = pow(max(texture(caustics_texture, uv_b).r, 0.0), max(params.caustics.w, 0.01));
	float caustic = min(sample_a, sample_b) * params.caustics.z * shallow * sun_height;
	if (params.fade.w > 1.5) {
		color.rgb = vec3(caustic);
	} else {
		color.rgb += vec3(caustic);
	}
	imageStore(color_image, pixel, color);
}
