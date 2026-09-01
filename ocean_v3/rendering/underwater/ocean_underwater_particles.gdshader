shader_type spatial;

render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled;

uniform vec4 particle_color : source_color = vec4(0.38, 0.61, 0.62, 0.035);
uniform float strength = 1.0;
uniform float near_fade_start_m = 0.15;
uniform float near_fully_visible_m = 0.70;
uniform float far_fade_start_m = 10.0;
uniform float far_fade_end_m = 20.0;

varying float particle_distance_m;

void vertex() {
	// Billboard in the shader so the custom procedural alpha remains cheap and
	// the particle material does not depend on a texture-backed StandardMaterial.
	vec3 particle_center_world = MODEL_MATRIX[3].xyz;
	float particle_size = length(MODEL_MATRIX[0].xyz);
	vec3 camera_right = normalize(INV_VIEW_MATRIX[0].xyz);
	vec3 camera_up = normalize(INV_VIEW_MATRIX[1].xyz);
	vec3 billboard_world = particle_center_world
		+ camera_right * VERTEX.x * particle_size
		+ camera_up * VERTEX.y * particle_size;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(billboard_world, 1.0);
	particle_distance_m = distance(CAMERA_POSITION_WORLD, particle_center_world);
}

void fragment() {
	vec2 centered_uv = UV * 2.0 - 1.0;
	float radius = length(centered_uv);
	float angle = atan(centered_uv.y, centered_uv.x);
	float irregular_edge = 1.0
		+ 0.08 * sin(angle * 3.0 + 0.7)
		+ 0.05 * sin(angle * 7.0 - 1.1)
		+ 0.03 * sin(angle * 11.0 + 2.0);
	float soft_disc = 1.0 - smoothstep(0.62 * irregular_edge, irregular_edge, radius);
	soft_disc *= smoothstep(0.0, 0.22, soft_disc);

	float near_fade = smoothstep(near_fade_start_m, near_fully_visible_m, particle_distance_m);
	float far_fade = 1.0 - smoothstep(far_fade_start_m, far_fade_end_m, particle_distance_m);
	float alpha = soft_disc * near_fade * far_fade * particle_color.a * strength;

	ALBEDO = particle_color.rgb;
	ALPHA = alpha;
}
