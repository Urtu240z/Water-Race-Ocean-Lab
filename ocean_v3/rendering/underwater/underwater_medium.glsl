#[compute]
#version 450

// Water coverage comes from the renderer's depth before and after transparent
// geometry. The ocean already writes its displaced surface depth, so this is a
// per-pixel FFT/coastal interface without an extra wave evaluation or readback.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D post_transparent_depth;
layout(set = 0, binding = 3) uniform sampler2D pre_transparent_depth;

layout(set = 0, binding = 2, std140) uniform Params {
	mat4 inverse_view_projection;
	vec4 viewport; // width, height, unused, unused
	vec4 camera; // xyz, depth snapshot available
	vec4 medium; // mean sea level, transition width, max optical distance, absorption scale
	vec4 absorption; // rgb, scattering strength
	vec4 scattering; // rgb, scattering density
	vec4 state; // CPU transition factor, debug mode, enabled, waterline feather
} params;

const float EPSILON = 0.00001;
const float DEPTH_WRITE_EPSILON = 0.00001;


bool finite_vec3(vec3 value) {
	return !any(isnan(value)) && !any(isinf(value));
}


bool reconstruct_world(vec2 uv, float raw_depth, out vec3 world_position) {
	vec2 ndc = uv * 2.0 - 1.0;
	vec4 world = params.inverse_view_projection * vec4(ndc, raw_depth, 1.0);
	if (abs(world.w) <= EPSILON) {
		return false;
	}
	world_position = world.xyz / world.w;
	return finite_vec3(world_position);
}


float distance_to_mean_surface(vec3 origin, vec3 direction, out bool hit) {
	hit = false;
	if (abs(direction.y) <= EPSILON) {
		return 0.0;
	}
	float distance_m = (params.medium.x - origin.y) / direction.y;
	if (distance_m > EPSILON && !isnan(distance_m) && !isinf(distance_m)) {
		hit = true;
		return distance_m;
	}
	return 0.0;
}


float water_path_for_scene(vec3 scene_world, bool scene_valid, vec2 uv) {
	vec3 camera_world = params.camera.xyz;
	bool camera_below = camera_world.y < params.medium.x;
	if (!scene_valid) {
		if (!camera_below) {
			return 0.0;
		}
		vec3 sky_world;
		if (reconstruct_world(uv, 0.0, sky_world)) {
			bool surface_hit;
			float surface_distance = distance_to_mean_surface(camera_world,
				normalize(sky_world - camera_world), surface_hit);
			if (surface_hit) {
				return surface_distance;
			}
		}
		return params.medium.z;
	}
	vec3 ray = scene_world - camera_world;
	float ray_length = length(ray);
	if (ray_length <= EPSILON || isnan(ray_length) || isinf(ray_length)) {
		return 0.0;
	}
	vec3 ray_direction = ray / ray_length;
	bool scene_below = scene_world.y < params.medium.x;
	if (!camera_below && !scene_below) {
		return 0.0;
	}
	if (camera_below && scene_below) {
		return ray_length;
	}
	bool surface_hit;
	float surface_distance = distance_to_mean_surface(camera_world, ray_direction, surface_hit);
	if (!surface_hit || surface_distance > ray_length) {
		return 0.0;
	}
	return camera_below ? surface_distance : ray_length - surface_distance;
}


bool water_wrote_depth(float pre_depth, float post_depth) {
	// Forward+ uses reversed Z: a nearer transparent surface raises depth.
	bool post_valid = post_depth > EPSILON && post_depth <= 1.000001;
	if (!post_valid) {
		return false;
	}
	bool pre_valid = pre_depth > EPSILON && pre_depth <= 1.000001;
	return !pre_valid || post_depth > pre_depth + DEPTH_WRITE_EPSILON;
}


float waterline_mask(float pre_depth, float post_depth) {
	float transition = clamp(params.state.x, 0.0, 1.0);
	if (transition <= EPSILON) {
		return 0.0;
	}
	if (transition >= 1.0 - EPSILON) {
		return 1.0;
	}
	// Within the crossing band the displaced ocean depth, not CPU state, decides
	// every pixel. This preserves steep FFT and coastal silhouettes.
	return water_wrote_depth(pre_depth, post_depth) ? 1.0 : 0.0;
}


void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.viewport.xy);
	if (pixel.x >= size.x || pixel.y >= size.y || params.state.z < 0.5) {
		return;
	}
	vec2 uv = (vec2(pixel) + vec2(0.5)) / params.viewport.xy;
	int debug_mode = int(params.state.y + 0.5);
	float post_depth = texelFetch(post_transparent_depth, pixel, 0).r;
	float pre_depth = texelFetch(pre_transparent_depth, pixel, 0).r;
	float medium_mask = waterline_mask(pre_depth, post_depth);
	if (debug_mode == 8) {
		vec4 debug_color = imageLoad(color_image, pixel);
		debug_color.rgb = vec3(water_wrote_depth(pre_depth, post_depth) ? 1.0 : 0.0);
		imageStore(color_image, pixel, debug_color);
		return;
	}
	if (debug_mode == 9) {
		vec4 debug_color = imageLoad(color_image, pixel);
		debug_color.rgb = vec3(medium_mask);
		imageStore(color_image, pixel, debug_color);
		return;
	}
	if (medium_mask <= EPSILON) {
		return;
	}
	// For pixels covered by water, pre-transparent depth is the scene endpoint
	// behind the actual ocean surface. It is also the correct sky sentinel.
	vec3 scene_world = vec3(0.0);
	bool scene_valid = pre_depth > EPSILON && pre_depth <= 1.000001
		&& reconstruct_world(uv, pre_depth, scene_world);
	float water_path_m = clamp(water_path_for_scene(scene_world, scene_valid, uv), 0.0, params.medium.z);
	if (isnan(water_path_m) || isinf(water_path_m) || water_path_m <= EPSILON) {
		return;
	}
	vec4 color = imageLoad(color_image, pixel);
	if (debug_mode == 2) {
		color.rgb = vec3(water_path_m / max(params.medium.z, EPSILON)) * medium_mask;
	} else if (debug_mode == 3) {
		color.rgb = mix(color.rgb,
			exp(-max(params.absorption.rgb, vec3(0.0)) * max(params.medium.w, 0.0) * water_path_m),
			medium_mask);
	} else if (debug_mode == 4) {
		float response = 1.0 - exp(-max(params.scattering.w, 0.0) * water_path_m);
		color.rgb = max(params.scattering.rgb, vec3(0.0)) * response
			* max(params.absorption.w, 0.0) * medium_mask;
	} else if (debug_mode == 5) {
		color.rgb = vec3(params.state.x, medium_mask, 0.0);
	} else if (debug_mode < 6 || debug_mode == 10) {
		vec3 transmittance = exp(-max(params.absorption.rgb, vec3(0.0))
			* max(params.medium.w, 0.0) * water_path_m);
		float scattering_response = 1.0 - exp(-max(params.scattering.w, 0.0) * water_path_m);
		vec3 underwater_color = color.rgb * transmittance
			+ max(params.scattering.rgb, vec3(0.0)) * scattering_response
				* max(params.absorption.w, 0.0);
		color.rgb = mix(color.rgb, underwater_color, medium_mask);
	}
	imageStore(color_image, pixel, color);
}
