#[compute]
#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba32f, set = 0, binding = 0) uniform restrict readonly image2D spatial_a;
layout(rgba32f, set = 0, binding = 1) uniform restrict readonly image2D spatial_b;
layout(rgba32f, set = 0, binding = 2) uniform restrict readonly image2D spatial_c;
layout(rgba32f, set = 0, binding = 3) uniform restrict writeonly image2D displacement_map;
layout(rgba16f, set = 0, binding = 4) uniform restrict writeonly image2D normal_map;
layout(push_constant, std430) uniform Params { vec4 values; } params;
ivec2 wrap_coord(ivec2 c, ivec2 s) { return ivec2((c.x+s.x)%s.x, (c.y+s.y)%s.y); }
vec3 displacement_at(ivec2 c, ivec2 s) { ivec2 w=wrap_coord(c,s); float checker=((w.x+w.y)&1)==0?1.0:-1.0; vec4 a=imageLoad(spatial_a,w), b=imageLoad(spatial_b,w); return vec3(a.z,a.x,b.x)*(checker*params.values.y); }
void main() {
	ivec2 c=ivec2(gl_GlobalInvocationID.xy), s=imageSize(spatial_a); if(any(greaterThanEqual(c,s))) return;
	vec3 d=displacement_at(c,s), left=displacement_at(c-ivec2(1,0),s), right=displacement_at(c+ivec2(1,0),s), down=displacement_at(c-ivec2(0,1),s), up=displacement_at(c+ivec2(0,1),s);
	float inv_two_dx=0.5/params.values.z; vec3 tx=vec3(1,0,0)+(right-left)*inv_two_dx; vec3 tz=vec3(0,0,1)+(up-down)*inv_two_dx; vec3 n=normalize(cross(tz,tx));
	if(any(isnan(d))||any(isinf(d))||any(isnan(n))||any(isinf(n))){d=vec3(0);n=vec3(0,1,0);}
	imageStore(displacement_map,c,vec4(d,1.0)); imageStore(normal_map,c,vec4(n,1.0));
}
