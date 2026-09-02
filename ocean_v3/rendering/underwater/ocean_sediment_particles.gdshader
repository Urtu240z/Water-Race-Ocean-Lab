shader_type spatial;

render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled;

uniform sampler2D sediment_field_texture : repeat_disable, filter_linear;
uniform vec2 sediment_field_origin_xz = vec2(0.0);
uniform vec2 sediment_field_extent_m = vec2(1.0);
uniform vec4 particle_color : source_color = vec4(0.32, 0.27, 0.16, 0.06);
uniform float strength = 1.0;
uniform float field_threshold = 0.10;
uniform float field_contrast = 0.75;
uniform bool wisps = false;
// 0 = production; 1/2 = Stage 2/3 plumbing; 3..6 = production alpha
// components; 7 = production output exaggerated only.
uniform int debug_mode = 0;

varying float particle_distance_m;
varying float particle_field_density;

float sample_density(vec3 world_position) {
	vec2 uv = (world_position.xz - sediment_field_origin_xz) / max(sediment_field_extent_m, vec2(0.001));
	float inside = step(0.0, uv.x) * step(uv.x, 1.0) * step(0.0, uv.y) * step(uv.y, 1.0);
	return inside * clamp(texture(sediment_field_texture, clamp(uv, vec2(0.0), vec2(1.0))).r, 0.0, 1.0);
}

void vertex() {
	vec3 particle_center_world = MODEL_MATRIX[3].xyz;
	float particle_width = length(MODEL_MATRIX[0].xyz);
	float particle_height = length(MODEL_MATRIX[1].xyz);
	vec3 camera_right = normalize(INV_VIEW_MATRIX[0].xyz);
	vec3 camera_up = normalize(INV_VIEW_MATRIX[1].xyz);
	vec3 billboard_world = particle_center_world
		+ camera_right * VERTEX.x * particle_width
		+ camera_up * VERTEX.y * particle_height;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(billboard_world, 1.0);
	particle_distance_m = distance(CAMERA_POSITION_WORLD, particle_center_world);
	particle_field_density = sample_density(particle_center_world);
}

void fragment() {
	vec2 centered_uv = UV * 2.0 - 1.0;
	float radius = length(centered_uv);
	float angle = atan(centered_uv.y, centered_uv.x);
	float irregular_edge = 1.0
		+ 0.10 * sin(angle * 3.0 + 0.9)
		+ 0.06 * sin(angle * 7.0 - 1.3)
		+ 0.035 * sin(angle * 11.0 + 2.1);
	float soft_shape = 1.0 - smoothstep(0.55 * irregular_edge, irregular_edge, radius);
	soft_shape *= smoothstep(0.0, 0.25, soft_shape);
	if (wisps) {
		float filament = 1.0 - smoothstep(0.18, 0.72, abs(centered_uv.y + 0.18 * sin(centered_uv.x * 4.0)));
		soft_shape *= filament;
	}
	if (debug_mode == 1) {
		// Stage 2: process-shader candidates only. Do not sample the field or use
		// production density/alpha, so a missing candidate cannot be mistaken for
		// subtle production art direction.
		ALBEDO = vec3(0.02, 1.0, 0.16);
		ALPHA = clamp(soft_shape * 0.92, 0.0, 1.0);
	} else if (debug_mode == 2) {
		// Stage 3: the same world->field UV mapping as production. Red proves a
		// valid candidate outside the field; bright green proves a field match.
		bool matched = particle_field_density >= field_threshold;
		ALBEDO = matched ? vec3(0.02, 1.0, 0.16) : vec3(1.0, 0.025, 0.02);
		ALPHA = clamp(soft_shape * 0.92, 0.0, 1.0);
	} else {
		float density = smoothstep(field_threshold, 1.0, particle_field_density);
		density = pow(max(density, 0.0), max(field_contrast, 0.1));
		float distance_fade = 1.0 - smoothstep(28.0, 42.0, particle_distance_m);
		float alpha_final = soft_shape * density * distance_fade * particle_color.a * strength;
		if (debug_mode == 3) {
			// Component views are white with their real value as opacity. This keeps
			// zero-valued candidates transparent instead of drawing black quads.
			ALBEDO = vec3(1.0);
			ALPHA = clamp(density, 0.0, 1.0);
		} else if (debug_mode == 4) {
			ALBEDO = vec3(1.0);
			ALPHA = clamp(soft_shape, 0.0, 1.0);
		} else if (debug_mode == 5) {
			ALBEDO = vec3(1.0);
			ALPHA = clamp(distance_fade, 0.0, 1.0);
		} else if (debug_mode == 6) {
			// Raw production alpha before the safety clamp: no boosted display value.
			ALBEDO = vec3(1.0);
			ALPHA = clamp(alpha_final, 0.0, 1.0);
		} else {
			float visual_alpha = alpha_final * (debug_mode == 7 ? 5.0 : 1.0);
			ALBEDO = particle_color.rgb;
			ALPHA = clamp(visual_alpha, 0.0, 0.35);
		}
	}
}
