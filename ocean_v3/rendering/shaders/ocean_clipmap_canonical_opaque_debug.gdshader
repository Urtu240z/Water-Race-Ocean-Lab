shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

void vertex() {
	vec4 world_position = MODEL_MATRIX * vec4(VERTEX, 1.0);
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * world_position;
}

void fragment() {
	ALBEDO = vec3(0.5);
}
