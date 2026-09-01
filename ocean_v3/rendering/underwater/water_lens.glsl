#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;

struct Droplet {
	vec4 position_radius; // uv.xy, radius, distortion strength
	vec4 velocity_opacity; // uv/s xy, opacity, pinning
	vec4 seed_age_lifetime; // seed, age, lifetime, unused
};

layout(set = 0, binding = 1, std140) uniform Params {
	vec4 viewport; // width, height, time, debug mode
	vec4 wet_state; // wetness, entry amount, entry t, exit t
	vec4 airflow; // lens-space direction xy, strength, speed
	vec4 event_data; // seed, sheet direction xy, transition strength
	Droplet droplets[64];
} params;

const float EPSILON = 0.00001;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float hash13(float p) {
	return fract(sin(p * 91.173 + params.event_data.x * 17.31) * 43758.5453);
}

vec3 sample_image_offset(ivec2 pixel, ivec2 size, vec2 offset_px) {
	ivec2 sample_pixel = clamp(pixel + ivec2(round(offset_px)), ivec2(0), size - ivec2(1));
	return imageLoad(color_image, sample_pixel).rgb;
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.viewport.xy);
	if (pixel.x >= size.x || pixel.y >= size.y) return;
	vec4 color = imageLoad(color_image, pixel);
	float wetness = clamp(params.wet_state.x, 0.0, 1.0);
	int debug_mode = int(params.viewport.w + 0.5);
	if (wetness <= EPSILON && params.wet_state.y <= EPSILON && params.wet_state.w <= EPSILON) return;
	vec2 uv = (vec2(pixel) + vec2(0.5)) / params.viewport.xy;
	vec2 distortion = vec2(0.0);
	float droplet_mask = 0.0;
	float velocity_mask = 0.0;
	for (int index = 0; index < 64; index++) {
		Droplet drop = params.droplets[index];
		float radius = max(drop.position_radius.z, 0.0001);
		vec2 delta = uv - drop.position_radius.xy;
		vec2 drop_velocity = drop.velocity_opacity.xy;
		float drop_speed = length(drop_velocity);
		vec2 drop_axis = drop_speed > EPSILON ? drop_velocity / drop_speed : vec2(0.0, 1.0);
		vec2 drop_perp = vec2(-drop_axis.y, drop_axis.x);
		float stretch = 1.0 + clamp(drop_speed * 10.0, 0.0, 3.0);
		vec2 anisotropic_delta = vec2(dot(delta, drop_axis) / stretch, dot(delta, drop_perp));
		float distance_uv = length(anisotropic_delta);
		float support = 1.0 - smoothstep(radius * 0.55, radius, distance_uv);
		float amount = support * clamp(drop.velocity_opacity.z, 0.0, 1.0);
		droplet_mask = max(droplet_mask, amount);
		velocity_mask = max(velocity_mask, amount * clamp(drop_speed * 0.12, 0.0, 1.0));
		vec2 radial = distance_uv > EPSILON ? anisotropic_delta / distance_uv : vec2(0.0);
		float edge = smoothstep(radius, radius * 0.16, distance_uv);
		distortion += radial * edge * drop.position_radius.w * drop.velocity_opacity.z;
	}
	// Entry impact: randomized concentric refractive rings plus a fine bubble
	// field. Both are event-seeded, so consecutive entries are not identical.
	float entry_t = clamp(params.wet_state.z, 0.0, 1.0);
	if (params.wet_state.y > EPSILON && entry_t < 1.0) {
		vec2 center = vec2(
			0.5 + (hash13(2.0) - 0.5) * 0.22,
			0.5 + (hash13(3.0) - 0.5) * 0.18
		);
		float radius = length(uv - center);
		float ring = exp(-abs(radius - (0.10 + entry_t * 0.45)) * 90.0)
			* (1.0 - smoothstep(0.72, 1.0, entry_t));
		distortion += normalize(uv - center + vec2(EPSILON)) * ring * params.wet_state.y * 0.035;
		for (int bubble = 0; bubble < 24; bubble++) {
			float seed = float(bubble) + params.event_data.x * 0.37;
			vec2 bubble_center = center + vec2(hash13(seed), hash13(seed + 19.0) - 0.5)
				* vec2(0.45, 0.55) * entry_t;
			float bubble_radius = mix(0.0015, 0.006, hash13(seed + 7.0));
			float bubble_shape = 1.0 - smoothstep(bubble_radius * 0.6, bubble_radius, length(uv - bubble_center));
			droplet_mask = max(droplet_mask, bubble_shape * params.wet_state.y * (1.0 - entry_t));
		}
	}
	// Exit sheet: a seeded directional wipe with a soft irregular edge.
	float exit_t = clamp(params.wet_state.w, 0.0, 1.0);
	if (exit_t < 1.0 && params.event_data.w > EPSILON) {
		vec2 flow = normalize(params.event_data.yz + vec2(0.001));
		float along = dot(uv - 0.5, flow) + 0.5;
		float edge_noise = hash12(floor((uv * 18.0 + params.event_data.x) * 3.0) / 3.0) * 0.07;
		float sheet = 1.0 - smoothstep(exit_t * 1.25 - 0.16 + edge_noise, exit_t * 1.25 + 0.08 + edge_noise, along);
		distortion += flow * sheet * params.event_data.w * 0.045;
		droplet_mask = max(droplet_mask, sheet * params.event_data.w * 0.7);
	}
	if (debug_mode == 1) {
		color.rgb = vec3(droplet_mask);
	} else if (debug_mode == 2) {
		color.rgb = vec3(params.airflow.xy * 0.5 + 0.5, clamp(params.airflow.z, 0.0, 1.0));
	} else if (debug_mode == 3) {
		color.rgb = vec3(wetness);
	} else if (debug_mode == 4) {
		color.rgb = vec3(velocity_mask, droplet_mask, 0.0);
	} else {
		vec2 offset_px = distortion * params.viewport.xy * 0.8;
		vec3 refracted = sample_image_offset(pixel, size, offset_px);
		float highlight = clamp(droplet_mask * (0.12 + 0.18 * (1.0 - wetness)), 0.0, 0.22);
		color.rgb = mix(color.rgb, refracted, clamp(droplet_mask * 0.65, 0.0, 0.72));
		color.rgb += vec3(highlight * 0.65, highlight * 0.82, highlight);
	}
	imageStore(color_image, pixel, color);
}
