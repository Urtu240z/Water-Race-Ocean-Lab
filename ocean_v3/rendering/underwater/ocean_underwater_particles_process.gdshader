shader_type particles;

// V1 deliberately keeps the motion procedural and local to the particle
// system. There is no FFT/OceanQuery/physics dependency here.
uniform float emission_depth_min_m = 4.0;
uniform float emission_depth_max_m = 50.0;
uniform float emission_width_near_m = 12.0;
uniform float emission_width_far_m = 60.0;
uniform float emission_height_near_m = 8.0;
uniform float emission_height_far_m = 30.0;
uniform float layer_seed = 1.0;
uniform float drift_speed = 0.05;
uniform float velocity_influence = 0.15;
uniform float max_flow_speed = 0.45;
uniform vec3 current_velocity = vec3(0.008, 0.001, -0.006);
uniform vec3 camera_velocity = vec3(0.0);
uniform float size_min = 0.005;
uniform float size_max = 0.025;
uniform float debug_size_multiplier = 1.0;
uniform vec3 camera_position_world = vec3(0.0);
uniform float max_particle_distance_m = 72.0;

float particle_hash(float value) {
	return fract(sin(value * 127.1 + layer_seed * 311.7) * 43758.5453123);
}

vec3 random_direction(float seed) {
	vec3 direction = vec3(
		particle_hash(seed + 1.0) * 2.0 - 1.0,
		particle_hash(seed + 2.0) * 2.0 - 1.0,
		particle_hash(seed + 3.0) * 2.0 - 1.0
	);
	return normalize(direction + vec3(0.0001, 0.0001, 0.0001));
}

vec3 bounded_relative_flow() {
	vec3 flow = -camera_velocity * velocity_influence;
	float flow_length = length(flow);
	if (flow_length > max_flow_speed) {
		flow *= max_flow_speed / flow_length;
	}
	return flow;
}

void start() {
	float seed = float(INDEX) + layer_seed * 97.0;
	float depth_max = max(emission_depth_max_m, emission_depth_min_m + 0.01);
	float depth = mix(emission_depth_min_m, depth_max, particle_hash(seed + 12.0));
	float depth_factor = clamp((depth - emission_depth_min_m) / (depth_max - emission_depth_min_m), 0.0, 1.0);
	float width = mix(emission_width_near_m, emission_width_far_m, depth_factor);
	float height = mix(emission_height_near_m, emission_height_far_m, depth_factor);
	vec3 position = vec3(
		(particle_hash(seed + 10.0) * 2.0 - 1.0) * width * 0.5,
		(particle_hash(seed + 11.0) * 2.0 - 1.0) * height * 0.5,
		-depth
	);
	float size = mix(size_min, size_max, particle_hash(seed + 13.0)) * debug_size_multiplier;
	TRANSFORM = mat4(1.0);
	TRANSFORM[0][0] = size;
	TRANSFORM[1][1] = size;
	TRANSFORM[2][2] = size;
	// local_coords=false means TRANSFORM is interpreted in world space. The
	// random range above is authored in emitter-local metres, so apply the
	// engine-provided emitter transform exactly once at spawn time.
	TRANSFORM[3].xyz = (EMISSION_TRANSFORM * vec4(position, 1.0)).xyz;

	vec3 drift = random_direction(seed + 20.0)
		* mix(0.35, 1.0, particle_hash(seed + 21.0)) * drift_speed;
	// A very small signed vertical component prevents a uniform "snow" fall
	// while keeping the overall motion calm.
	drift.y += (particle_hash(seed + 22.0) * 2.0 - 1.0) * drift_speed * 0.35;
	CUSTOM.xyz = drift;
	CUSTOM.w = particle_hash(seed + 23.0) * 6.2831853;
	VELOCITY = drift + current_velocity + bounded_relative_flow();
}

void process() {
	if (!RESTART) {
		if (distance(TRANSFORM[3].xyz, camera_position_world) > max_particle_distance_m) {
			ACTIVE = false;
			return;
		}
		float phase = CUSTOM.w + TIME * (0.12 + particle_hash(CUSTOM.w + 40.0) * 0.10);
		vec3 gentle_variation = vec3(
			sin(phase),
			0.35 * sin(phase * 0.71 + 1.7),
			cos(phase * 0.83)
		) * drift_speed * 0.035;
		vec3 target_velocity = CUSTOM.xyz + gentle_variation
			+ current_velocity + bounded_relative_flow();
		// Follow changes in apparent flow without introducing a fast jitter or
		// unbounded acceleration into the particle layer.
		VELOCITY = mix(VELOCITY, target_velocity, clamp(DELTA * 0.8, 0.0, 1.0));
		TRANSFORM[3].xyz += VELOCITY * DELTA;
	}
}
