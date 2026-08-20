shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2D displacement_map : repeat_enable, filter_linear;
uniform sampler2D ocean_normal_map : repeat_enable, filter_linear;
uniform float domain_size_m = 128.0;
uniform int debug_mode = 0; // 0 full, 1 height only, 2 normals
uniform bool module_enabled = true;
uniform vec3 base_color : source_color = vec3(0.075, 0.20, 0.27);

varying vec3 derived_normal;

void vertex() {
	vec2 world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
	vec2 spectrum_uv = fract(world_xz / domain_size_m + vec2(0.5));
	vec3 displacement = textureLod(displacement_map, spectrum_uv, 0.0).rgb;
	vec3 ocean_normal = normalize(textureLod(ocean_normal_map, spectrum_uv, 0.0).rgb);
	if (!module_enabled) {
		displacement = vec3(0.0);
		ocean_normal = vec3(0.0, 1.0, 0.0);
	} else if (debug_mode == 1) {
		displacement.xz = vec2(0.0);
	}
	VERTEX += displacement;
	NORMAL = ocean_normal;
	derived_normal = ocean_normal;
}

void fragment() {
	ALBEDO = debug_mode == 2 ? derived_normal * 0.5 + 0.5 : base_color;
	ROUGHNESS = 0.42;
	SPECULAR = 0.35;
}
