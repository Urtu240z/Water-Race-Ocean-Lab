#[compute]
#version 450

// V1 persistent world-space field. Keep this marker so Godot reimports the
// RDShaderFile after shader ABI changes instead of reusing stale bytecode.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D previous_field;
layout(set = 0, binding = 1) uniform sampler2D bathymetry_source;
layout(set = 0, binding = 2, r16f) uniform image2D next_field;
layout(set = 0, binding = 3, std430) readonly buffer InjectionBuffer {
	vec4 injections[];
};

layout(push_constant, std430) uniform Params {
	vec4 map_data;       // origin xz, extent xz
	vec4 simulation;     // dt, diffusion, settling, current speed
	vec4 current;        // direction xz, orbital strength, time
	vec4 wave;           // direction xz, k, omega
	vec4 source;         // shallow start, shallow end, resuspension, enabled
	vec4 controls;       // injection count, source width, source height, reserved
} params;

float safe_value(float value) {
	return (isnan(value) || isinf(value)) ? 0.0 : value;
}

float field_sample(vec2 uv) {
	return clamp(safe_value(texture(previous_field, clamp(uv, vec2(0.0), vec2(1.0))).r), 0.0, 1.0);
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(next_field);
	if (pixel.x >= size.x || pixel.y >= size.y) return;
	vec2 uv = (vec2(pixel) + vec2(0.5)) / vec2(size);
	vec2 extent = max(params.map_data.zw, vec2(0.001));
	vec2 world_xz = params.map_data.xy + uv * extent;
	float dt = clamp(params.simulation.x, 0.0, 0.25);
	vec2 current_direction = normalize(params.current.xy + vec2(0.00001, 0.0));
	vec2 wave_direction = normalize(params.wave.xy + vec2(0.00001, 0.0));
	float phase = dot(world_xz, wave_direction) * params.wave.z + params.current.w * params.wave.w;
	vec2 slow_flow = normalize(vec2(
		sin(dot(world_xz, vec2(0.013, 0.009)) + params.current.w * 0.043),
		cos(dot(world_xz, vec2(-0.008, 0.017)) + params.current.w * 0.037)
		+ 0.00001
	)) * 0.035;
	vec2 flow = current_direction * params.simulation.w
		+ wave_direction * sin(phase) * params.current.z
		+ slow_flow;
	vec2 back_uv = uv - flow * dt / extent;
	float advected = field_sample(back_uv);
	vec2 texel = 1.0 / vec2(size);
	float neighborhood = (
		field_sample(back_uv + vec2(texel.x, 0.0))
		+ field_sample(back_uv - vec2(texel.x, 0.0))
		+ field_sample(back_uv + vec2(0.0, texel.y))
		+ field_sample(back_uv - vec2(0.0, texel.y))
	) * 0.25;
	float diffused = mix(advected, neighborhood, clamp(params.simulation.y, 0.0, 1.0) * clamp(dt * 8.0, 0.0, 1.0));

	vec2 bathy = texture(bathymetry_source, uv).rg;
	float depth_m = max(safe_value(bathy.r), 0.0);
	float water = step(0.5, safe_value(bathy.g));
	float shallow = 1.0 - smoothstep(
		min(params.source.x, params.source.y),
		max(params.source.x, params.source.y + 0.001),
		depth_m
	);
	float wave_shear = 0.5 + 0.5 * sin(phase);
	float broad_variation = 0.5 + 0.5 * sin(dot(world_xz, vec2(0.021, -0.016)) + params.current.w * 0.061);
	float source_patch = mix(0.22, 1.0, wave_shear * 0.72 + broad_variation * 0.28);
	float source = water * shallow * source_patch * max(params.source.z, 0.0)
		* step(0.5, params.source.w);

	float injected = 0.0;
	int injection_count = clamp(int(params.controls.x + 0.5), 0, 16);
	for (int index = 0; index < 16; index++) {
		if (index >= injection_count) break;
		vec4 injection = injections[index];
		float radius = max(injection.z, 0.001);
		float distance_sq = dot(world_xz - injection.xy, world_xz - injection.xy);
		injected = max(injected, exp(-distance_sq / (radius * radius)) * clamp(injection.w, 0.0, 1.0));
	}

	// Seabed resuspension is a continuous rate, while queued injections are
	// already concentration-space impulses.  Applying dt to the latter made a
	// strength 1.0 diagnostic injection only reach about 0.05 at 20 Hz.
	float result = diffused + source * dt + injected;
	result *= exp(-max(params.simulation.z, 0.0) * dt);
	result = clamp(safe_value(result), 0.0, 1.0);
	imageStore(next_field, pixel, vec4(result, 0.0, 0.0, 1.0));
}
