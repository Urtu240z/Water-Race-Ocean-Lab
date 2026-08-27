shader_type spatial;

render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec4 albedo_color : source_color = vec4(0.72, 0.76, 0.70, 1.0);
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform bool use_albedo_texture = false;
uniform float roughness : hint_range(0.0, 1.0) = 0.8;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform vec3 emission_color : source_color = vec3(0.0);
uniform float emission_energy = 0.0;
uniform float sea_level_y = 0.0;
uniform float clip_epsilon = 0.001;

varying vec3 mirror_world_position;

void vertex() {
	mirror_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// Original source geometry below the water becomes above-water geometry
	// after mirroring. Remove that virtual underwater belly in world space.
	if (mirror_world_position.y > sea_level_y + clip_epsilon) {
		discard;
	}

	vec4 base = albedo_color;
	if (use_albedo_texture) {
		base *= texture(albedo_texture, UV);
	}
	ALBEDO = base.rgb;
	ALPHA = base.a;
	ROUGHNESS = roughness;
	METALLIC = metallic;
	EMISSION = emission_color * emission_energy;
}
