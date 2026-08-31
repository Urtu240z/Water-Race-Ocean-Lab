#[compute]
#version 450

// POST_SKY runs after opaque color/depth and sky resolve, before transparent
// materials sample the background. Ocean V3 therefore sees this contribution
// through its existing screen-texture refraction/transmission path.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D scene_depth;
layout(set = 0, binding = 2) uniform sampler2D caustics_texture;
layout(set = 0, binding = 3) uniform sampler2D luma_gradient;

layout(set = 0, binding = 4, std140) uniform Params {
	mat4 inverse_view_projection;
	vec4 viewport; // width, height, unused, unused
	vec4 caustics; // sea level, tiling (1 / scale), strength, power
	vec4 lighting; // speed, chroma split, luminance-mask strength, sun strength
	vec4 layer_a; // speed multiplier, scale multiplier, panner direction xy
	vec4 layer_b; // speed multiplier, scale multiplier, panner direction xy
	vec4 fade; // start depth, max depth, time, enabled/debug
	vec4 sun; // surface -> sun direction, unused
} params;


vec3 sample_caustics(vec2 uv, float split) {
	if (split <= 0.000001) {
		float value = texture(caustics_texture, uv).r;
		return vec3(value);
	}
	return vec3(
		texture(caustics_texture, uv + vec2(split, split)).r,
		texture(caustics_texture, uv + vec2(split, -split)).r,
		texture(caustics_texture, uv + vec2(-split, -split)).r
	);
}


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
	vec2 screen_uv = (vec2(pixel) + vec2(0.5)) / params.viewport.xy;
	vec2 ndc = screen_uv * 2.0 - 1.0;
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
	float depth_mask = 1.0 - smoothstep(
		params.fade.x,
		max(params.fade.y, params.fade.x + 0.001),
		water_depth
	);
	if (depth_mask <= 0.0001) {
		return;
	}

	vec3 light = normalize(params.sun.xyz);
	float sun_height = smoothstep(0.04, 0.45, light.y);
	float sun_mask = mix(1.0, sun_height, params.lighting.w);
	if (sun_mask <= 0.0001) {
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
	) * params.caustics.y;

	float time = params.fade.z;
	vec2 uv_a = fract(
		projected * params.layer_a.y +
		params.layer_a.zw * (time * params.lighting.x * params.layer_a.x)
	);
	vec2 uv_b = fract(
		projected * params.layer_b.y +
		params.layer_b.zw * (time * params.lighting.x * params.layer_b.x)
	);
	vec3 layer_a = pow(max(sample_caustics(uv_a, params.lighting.y), vec3(0.0)), vec3(max(params.caustics.w, 0.01)));
	vec3 layer_b = pow(max(sample_caustics(uv_b, params.lighting.y), vec3(0.0)), vec3(max(params.caustics.w, 0.01)));
	vec3 caustic = min(layer_a, layer_b) * params.caustics.z;

	float luminance = dot(max(color.rgb, vec3(0.0)), vec3(0.299, 0.587, 0.114));
	float gradient_luma = texture(luma_gradient, vec2(clamp(luminance, 0.0, 1.0), 0.5)).r;
	float luminance_mask = mix(1.0, gradient_luma, params.lighting.z);
	caustic *= depth_mask * sun_mask * luminance_mask;

	if (params.fade.w > 1.5) {
		color.rgb = caustic;
	} else {
		color.rgb += caustic;
	}
	imageStore(color_image, pixel, color);
}
