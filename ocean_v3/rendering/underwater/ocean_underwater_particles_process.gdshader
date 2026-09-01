shader_type particles;

// V1 deliberately keeps the motion procedural and local to the particle
// system. There is no FFT/OceanQuery/physics dependency here.
uniform vec3 emission_extents = vec3(12.0, 6.0, 12.0);
uniform float layer_seed = 1.0;
uniform float drift_speed = 0.05;
uniform float velocity_influence = 0.15;
uniform float max_flow_speed = 0.45;
uniform vec3 current_velocity = vec3(0.008, 0.001, -0.006);
uniform vec3 camera_velocity = vec3(0.0);
uniform float size_min = 0.005;
uniform float size_max = 0.025;

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
	vec3 position = vec3(
		particle_hash(seed + 10.0) * 2.0 - 1.0,
		particle_hash(seed + 11.0) * 2.0 - 1.0,
		particle_hash(seed + 12.0) * 2.0 - 1.0
	) * emission_extents;
	float size = mix(size_min, size_max, particle_hash(seed + 13.0));
	TRANSFORM = mat4(1.0);
	TRANSFORM[0][0] = size;
	TRANSFORM[1][1] = size;
	TRANSFORM[2][2] = size;
	TRANSFORM[3].xyz = position;

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
