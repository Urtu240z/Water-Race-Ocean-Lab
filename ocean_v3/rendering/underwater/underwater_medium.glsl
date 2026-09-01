#[compute]
#version 450

// The local interface is a GPU-probed LONG+MID tangent plane at the camera.
// If the probe is unavailable or invalid, sea_level remains the deterministic
// flat fallback. No CPU wave query or GPU-to-CPU readback is involved.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D scene_depth;
layout(set = 0, binding = 3) uniform sampler2D local_surface_probe;

layout(set = 0, binding = 2, std140) uniform Params {
	mat4 inverse_view_projection;
	vec4 viewport; // width, height, unused, unused
	vec4 camera; // xyz, local probe dispatch succeeded
	vec4 medium; // sea level, transition width, max optical distance, absorption scale
	vec4 absorption; // rgb, scattering strength
	vec4 scattering; // rgb, scattering density
	vec4 state; // legacy camera factor, debug mode, enabled, waterline feather
} params;

const float EPSILON = 0.00001;
const float WATERLINE_REFERENCE_DISTANCE_M = 12.0;


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


void local_surface_plane(out vec3 plane_point, out vec3 plane_normal, out bool probe_valid) {
	plane_point = vec3(params.camera.x, params.medium.x, params.camera.z);
	plane_normal = vec3(0.0, 1.0, 0.0);
	probe_valid = false;
	if (params.camera.w <= 0.5) {
		return;
	}
	vec4 probe = texelFetch(local_surface_probe, ivec2(0), 0);
	if (probe.w <= 0.5 || isnan(probe.x) || isinf(probe.x)
			|| any(isnan(probe.yz)) || any(isinf(probe.yz))) {
		return;
	}
	vec3 candidate_normal = normalize(vec3(-probe.y, 1.0, -probe.z));
	if (!finite_vec3(candidate_normal) || candidate_normal.y <= EPSILON) {
		return;
	}
	plane_point.y = probe.x;
	plane_normal = candidate_normal;
	probe_valid = true;
}


float plane_side(vec3 point, vec3 plane_point, vec3 plane_normal) {
	return dot(point - plane_point, plane_normal);
}


float distance_to_plane(vec3 origin, vec3 direction, vec3 plane_point,
		vec3 plane_normal, out bool hit) {
	hit = false;
	float denominator = dot(direction, plane_normal);
	if (abs(denominator) <= EPSILON) {
		return 0.0;
	}
	float distance_m = dot(plane_point - origin, plane_normal) / denominator;
	if (distance_m > EPSILON && !isnan(distance_m) && !isinf(distance_m)) {
		hit = true;
		return distance_m;
	}
	return 0.0;
}


float water_path_for_scene(vec3 scene_world, bool scene_valid, vec2 uv,
		vec3 plane_point, vec3 plane_normal) {
	vec3 camera_world = params.camera.xyz;
	bool camera_below = plane_side(camera_world, plane_point, plane_normal) < 0.0;
	if (!scene_valid) {
		if (!camera_below) {
			return 0.0;
		}
		vec3 sky_world;
		if (reconstruct_world(uv, 0.0, sky_world)) {
			vec3 sky_direction = normalize(sky_world - camera_world);
			bool surface_hit;
			float surface_distance = distance_to_plane(camera_world, sky_direction,
				plane_point, plane_normal, surface_hit);
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
	bool scene_below = plane_side(scene_world, plane_point, plane_normal) < 0.0;
	if (!camera_below && !scene_below) {
		return 0.0;
	}
	if (camera_below && scene_below) {
		return ray_length;
	}
	bool surface_hit;
	float surface_distance = distance_to_plane(camera_world, ray_direction,
		plane_point, plane_normal, surface_hit);
	if (!surface_hit || surface_distance > ray_length) {
		return 0.0;
	}
	return camera_below ? surface_distance : ray_length - surface_distance;
}


float waterline_mask(vec2 uv, vec3 plane_point, vec3 plane_normal) {
	float transition_width = max(params.medium.y, EPSILON);
	float camera_side = plane_side(params.camera.xyz, plane_point, plane_normal);
	if (camera_side > transition_width) {
		return 0.0;
	}
	if (camera_side < -transition_width) {
		return 1.0;
	}
	vec3 ray_world;
	if (reconstruct_world(uv, 0.0, ray_world)) {
		vec3 ray_direction = normalize(ray_world - params.camera.xyz);
		if (finite_vec3(ray_direction)) {
			float signed_plane_side = camera_side
				+ dot(ray_direction, plane_normal) * WATERLINE_REFERENCE_DISTANCE_M;
			float feather_m = max(params.state.w * WATERLINE_REFERENCE_DISTANCE_M, EPSILON);
			return 1.0 - smoothstep(-feather_m, feather_m, signed_plane_side);
		}
	}
	float feather_uv = max(params.state.w, EPSILON);
	return smoothstep(0.5 - feather_uv, 0.5 + feather_uv, uv.y);
}


void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.viewport.xy);
	if (pixel.x >= size.x || pixel.y >= size.y || params.state.z < 0.5) {
		return;
	}

	vec2 uv = (vec2(pixel) + vec2(0.5)) / params.viewport.xy;
	int debug_mode = int(params.state.y + 0.5);
	vec3 plane_point;
	vec3 plane_normal;
	bool probe_valid;
	local_surface_plane(plane_point, plane_normal, probe_valid);
	float medium_mask = waterline_mask(uv, plane_point, plane_normal);
	if (debug_mode == 8) {
		vec3 ray_world;
		float side = plane_side(params.camera.xyz, plane_point, plane_normal);
		if (reconstruct_world(uv, 0.0, ray_world)) {
			vec3 direction = normalize(ray_world - params.camera.xyz);
			if (finite_vec3(direction)) {
				side += dot(direction, plane_normal) * WATERLINE_REFERENCE_DISTANCE_M;
			}
		}
		vec4 debug_color = imageLoad(color_image, pixel);
		debug_color.rgb = vec3(clamp(0.5 - side / WATERLINE_REFERENCE_DISTANCE_M, 0.0, 1.0));
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
	float raw_depth = texelFetch(scene_depth, pixel, 0).r;
	vec3 scene_world = vec3(0.0);
	bool scene_valid = raw_depth > EPSILON && raw_depth <= 1.000001
		&& reconstruct_world(uv, raw_depth, scene_world);
	float water_path_m = clamp(water_path_for_scene(scene_world, scene_valid, uv,
		plane_point, plane_normal), 0.0, params.medium.z);
	if (isnan(water_path_m) || isinf(water_path_m)) {
		water_path_m = 0.0;
	}
	if (water_path_m <= EPSILON) {
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
		color.rgb = vec3(float(probe_valid), medium_mask, 0.0);
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
