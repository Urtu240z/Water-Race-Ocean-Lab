shader_type spatial;

// Direct GPU diagnostic: a temporary horizontal projection near the selected
// seabed point. It never reads field data back to the CPU.
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled;

uniform sampler2D sediment_field_texture : repeat_disable, filter_linear;
uniform vec2 sediment_field_origin_xz = vec2(0.0);
uniform vec2 sediment_field_extent_m = vec2(1.0);
uniform int debug_mode = 0; // 0 = concentration heat map, 1 = world -> field UV.

varying vec2 debug_world_xz;

void vertex() {
	debug_world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}

vec3 field_heat(float value) {
	if (value < 0.25) return mix(vec3(0.0), vec3(0.02, 0.08, 1.0), value / 0.25);
	if (value < 0.5) return mix(vec3(0.02, 0.08, 1.0), vec3(1.0, 0.92, 0.02), (value - 0.25) / 0.25);
	return mix(vec3(1.0, 0.92, 0.02), vec3(1.0), (value - 0.5) / 0.5);
}

void fragment() {
	vec2 uv = (debug_world_xz - sediment_field_origin_xz) / max(sediment_field_extent_m, vec2(0.001));
	float inside = step(0.0, uv.x) * step(uv.x, 1.0) * step(0.0, uv.y) * step(uv.y, 1.0);
	if (debug_mode == 1) {
		ALBEDO = vec3(clamp(uv, vec2(0.0), vec2(1.0)), inside);
		ALPHA = 0.96;
		return;
	}
	float concentration = inside * clamp(texture(sediment_field_texture, clamp(uv, vec2(0.0), vec2(1.0))).r, 0.0, 1.0);
	ALBEDO = field_heat(concentration);
	ALPHA = 0.96;
}
