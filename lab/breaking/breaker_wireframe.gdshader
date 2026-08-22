shader_type spatial;
render_mode wireframe, cull_disabled, unshaded;

// Debug de malla para el prototipo de cross-section.
void fragment() {
	ALBEDO = vec3(0.85, 0.9, 1.0);
}
