#[compute]
#version 450

// One WaterInterface SubViewport supplies the displaced Ocean V3 interface.
// RG = octahedral macro normal, B = positive view depth, A = valid coverage.
// The compositor never binds FFT/coastal resources and never tests a flat plane.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D resolved_depth;
layout(set = 0, binding = 3) uniform sampler2D water_interface;

layout(set = 0, binding = 2, std140) uniform Params {
	mat4 inverse_view_projection;
	vec4 viewport; // width, height
	vec4 camera; // xyz
	vec4 absorption; // rgb, scale
	vec4 scattering; // rgb, strength
	vec4 medium; // density, max distance, waterline feather
	vec4 state; // viewer medium: AIR=0 WATER=1 CROSSING=2, local water factor, debug, enabled
	vec4 camera_forward; // world-space camera forward
} params;

const float EPSILON = 0.00001;
const float IOR_AIR = 1.0003;
const float IOR_WATER = 1.333;
const int DEBUG_INTERFACE_VALID = 1;
const int DEBUG_INTERFACE_DEPTH = 2;
const int DEBUG_INTERFACE_NORMAL = 3;
const int DEBUG_VIEWER_MEDIUM = 4;
const int DEBUG_PIXEL_MEDIUM = 5;
const int DEBUG_SNELL_K = 6;
const int DEBUG_TIR = 7;
const int DEBUG_WATERLINE = 8;

bool finite_vec3(vec3 value) {
	return !any(isnan(value)) && !any(isinf(value));
}

bool reconstruct_world(vec2 uv, float raw_depth, out vec3 world_position) {
	vec4 world = params.inverse_view_projection * vec4(uv * 2.0 - 1.0, raw_depth, 1.0);
	if (abs(world.w) <= EPSILON) return false;
	world_position = world.xyz / world.w;
	return finite_vec3(world_position);
}

vec3 view_ray_world(vec2 uv) {
	// In reversed-Z the far point is depth 0. The ray direction is invariant to
	// its depth after the perspective divide.
	vec3 world;
	if (reconstruct_world(uv, 0.0, world)) {
		vec3 ray = world - params.camera.xyz;
		float ray_length = length(ray);
		if (ray_length > EPSILON && finite_vec3(ray)) return ray / ray_length;
	}
	return normalize(params.camera_forward.xyz);
}

vec3 decode_octahedral_normal(vec2 encoded) {
	vec2 f = encoded * 2.0 - 1.0;
	vec3 n = vec3(f, 1.0 - abs(f.x) - abs(f.y));
	if (n.z < 0.0) n.xy = (vec2(1.0) - abs(n.yx)) * sign(n.xy);
	return normalize(n);
}

float interface_ray_distance(float view_depth, vec3 ray_direction) {
	float view_alignment = max(abs(dot(ray_direction, normalize(params.camera_forward.xyz))), 0.02);
	return view_depth / view_alignment;
}

void store_debug(ivec2 pixel, vec3 value) {
	vec4 color = imageLoad(color_image, pixel);
	color.rgb = value;
	imageStore(color_image, pixel, color);
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.viewport.xy);
	if (pixel.x >= size.x || pixel.y >= size.y || params.state.w < 0.5) return;
	vec2 uv = (vec2(pixel) + vec2(0.5)) / params.viewport.xy;
	vec4 interface_sample = textureLod(water_interface, uv, 0.0);
	bool interface_valid = interface_sample.a > 0.5 && interface_sample.b > EPSILON
		&& !isnan(interface_sample.b) && !isinf(interface_sample.b);
	float interface_depth = interface_valid ? interface_sample.b : 0.0;
	vec3 interface_normal = interface_valid ? decode_octahedral_normal(interface_sample.rg) : vec3(0.0, 1.0, 0.0);
	vec3 ray_direction = view_ray_world(uv);
	float cos_i = interface_valid ? clamp(abs(dot(ray_direction, interface_normal)), 0.0, 1.0) : 1.0;
	float eta = IOR_WATER / IOR_AIR;
	float snell_k = interface_valid ? 1.0 - eta * eta * (1.0 - cos_i * cos_i) : 1.0;
	bool tir = interface_valid && snell_k < 0.0;
	int viewer_medium = int(params.state.x + 0.5);
	float viewer_water = viewer_medium == 1 ? 1.0 : viewer_medium == 0 ? 0.0 : step(0.5, params.state.y);
	// CROSSING is the only state that needs the real interface mask. A camera
	// locally in air sees water after a valid interface; locally in water keeps
	// water as the default even when looking at the seabed or a missing horizon.
	float pixel_medium = viewer_medium == 0 ? 0.0 : viewer_medium == 1 ? 1.0
		: viewer_water > 0.5 ? 1.0 : (interface_valid ? 1.0 : 0.0);
	int debug_mode = int(params.state.z + 0.5);
	if (debug_mode == DEBUG_INTERFACE_VALID) {
		store_debug(pixel, vec3(interface_valid ? 1.0 : 0.0)); return;
	}
	if (debug_mode == DEBUG_INTERFACE_DEPTH) {
		store_debug(pixel, vec3(clamp(interface_depth / max(params.medium.y, 0.001), 0.0, 1.0))); return;
	}
	if (debug_mode == DEBUG_INTERFACE_NORMAL) {
		store_debug(pixel, interface_normal * 0.5 + 0.5); return;
	}
	if (debug_mode == DEBUG_VIEWER_MEDIUM) {
		store_debug(pixel, vec3(viewer_medium == 0 ? 0.0 : viewer_medium == 1 ? 1.0 : 0.5)); return;
	}
	if (debug_mode == DEBUG_PIXEL_MEDIUM || debug_mode == DEBUG_WATERLINE) {
		store_debug(pixel, vec3(pixel_medium)); return;
	}
	if (debug_mode == DEBUG_SNELL_K) {
		store_debug(pixel, vec3(clamp(snell_k, 0.0, 1.0))); return;
	}
	if (debug_mode == DEBUG_TIR) {
		store_debug(pixel, vec3(tir ? 1.0 : 0.0)); return;
	}
	if (pixel_medium <= EPSILON) return;
	float raw_depth = texelFetch(resolved_depth, pixel, 0).r;
	vec3 scene_world;
	bool scene_valid = raw_depth > EPSILON && raw_depth <= 1.000001
		&& reconstruct_world(uv, raw_depth, scene_world);
	float scene_distance = scene_valid ? length(scene_world - params.camera.xyz) : params.medium.y;
	float interface_distance = interface_valid ? interface_ray_distance(interface_depth, ray_direction) : params.medium.y;
	float water_path_m;
	if (viewer_medium == 2 && viewer_water < 0.5) {
		// Camera locally in air: only the segment behind its actual interface is water.
		water_path_m = interface_valid && scene_valid ? max(scene_distance - interface_distance, 0.0) : 0.0;
	} else {
		// Camera locally below: integrate up to the first real interface if one is
		// visible; otherwise the scene distance/full finite fallback is underwater.
		water_path_m = interface_valid ? min(scene_distance, interface_distance) : scene_distance;
	}
	water_path_m = clamp(water_path_m, 0.0, params.medium.y);
	if (water_path_m <= EPSILON || isnan(water_path_m) || isinf(water_path_m)) return;
	vec4 color = imageLoad(color_image, pixel);
	vec3 transmittance = exp(-max(params.absorption.rgb, vec3(0.0)) * max(params.absorption.w, 0.0) * water_path_m);
	float scattering_response = 1.0 - exp(-max(params.medium.x, 0.0) * water_path_m);
	vec3 underwater_color = color.rgb * transmittance
		+ max(params.scattering.rgb, vec3(0.0)) * scattering_response * max(params.scattering.w, 0.0);
	color.rgb = mix(color.rgb, underwater_color, pixel_medium);
	imageStore(color_image, pixel, color);
}
