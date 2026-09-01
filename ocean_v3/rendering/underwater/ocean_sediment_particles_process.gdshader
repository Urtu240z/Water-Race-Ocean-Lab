shader_type particles;

uniform sampler2D sediment_field_texture : repeat_disable, filter_linear;
uniform sampler2D bathymetry_texture : repeat_disable, filter_linear;
uniform vec2 sediment_field_origin_xz = vec2(0.0);
uniform vec2 sediment_field_extent_m = vec2(1.0);
uniform vec2 bathymetry_origin_xz = vec2(0.0);
uniform vec2 bathymetry_extent_m = vec2(1.0);
uniform float bathymetry_depth_scale_m = 32.0;
uniform float sea_level_y = 0.0;
uniform float spawn_radius_m = 36.0;
uniform float layer_seed = 1.0;
uniform float height_min_m = 0.05;
uniform float height_max_m = 1.5;
uniform float field_threshold = 0.15;
uniform vec2 current_direction_xz = vec2(1.0, 0.0);
uniform float current_speed_mps = 0.20;
uniform float orbital_strength_mps = 0.08;
uniform float wave_k_rad_m = 0.20;
uniform float wave_omega_rad_s = 0.70;
uniform float vertical_wander_m = 0.08;

float hash_value(float value) {
	return fract(sin(value * 127.1 + layer_seed * 311.7) * 43758.5453123);
}

vec2 field_uv(vec2 world_xz) {
	return (world_xz - sediment_field_origin_xz) / max(sediment_field_extent_m, vec2(0.001));
}

vec2 bathymetry_uv(vec2 world_xz) {
	return (world_xz - bathymetry_origin_xz) / max(bathymetry_extent_m, vec2(0.001));
}

void start() {
	float seed = float(INDEX) + layer_seed * 97.0;
	vec2 local_xz = vec2(
		(hash_value(seed + 10.0) * 2.0 - 1.0) * spawn_radius_m,
		(hash_value(seed + 11.0) * 2.0 - 1.0) * spawn_radius_m
	);
	vec2 world_xz = EMISSION_TRANSFORM[3].xz + local_xz;
	vec2 field_sample_uv = field_uv(world_xz);
	vec2 bathy_sample_uv = bathymetry_uv(world_xz);
	float concentration = texture(sediment_field_texture, clamp(field_sample_uv, vec2(0.0), vec2(1.0))).r;
	vec2 bathy = texture(bathymetry_texture, clamp(bathy_sample_uv, vec2(0.0), vec2(1.0))).rg;
	float inside = step(0.0, field_sample_uv.x) * step(field_sample_uv.x, 1.0)
		* step(0.0, field_sample_uv.y) * step(field_sample_uv.y, 1.0);
	float water = step(0.5, bathy.g);
	float active = inside * water * step(field_threshold, concentration);
	float height = mix(height_min_m, height_max_m, hash_value(seed + 12.0));
	float depth_m = max(bathy.r * bathymetry_depth_scale_m, 0.0);
	vec3 world_position = vec3(world_xz.x, sea_level_y - depth_m + height, world_xz.y);
	TRANSFORM = mat4(1.0);
	float width = mix(0.7, 2.5, hash_value(seed + 13.0));
	float vertical = mix(0.35, 1.0, hash_value(seed + 14.0));
	TRANSFORM[0][0] = width;
	TRANSFORM[1][1] = vertical;
	TRANSFORM[2][2] = 0.0;
	TRANSFORM[3].xyz = world_position;
	float phase = hash_value(seed + 15.0) * 6.2831853;
	CUSTOM.xyz = vec3(
		current_direction_xz.x * current_speed_mps,
		0.0,
		current_direction_xz.y * current_speed_mps
	);
	CUSTOM.w = TIME;
	VELOCITY = CUSTOM.xyz;
	if (active < 0.5) ACTIVE = false;
}

void process() {
	if (!RESTART) {
		float phase = TIME * wave_omega_rad_s + float(INDEX) * 0.37;
		vec3 orbital = vec3(
			current_direction_xz.x * sin(phase) * orbital_strength_mps,
			0.0,
			current_direction_xz.y * sin(phase) * orbital_strength_mps
		);
		VELOCITY = CUSTOM.xyz + orbital;
		TRANSFORM[3].xyz += VELOCITY * DELTA;
		TRANSFORM[3].y += sin(phase * 0.71 + layer_seed) * vertical_wander_m * DELTA;
	}
}
