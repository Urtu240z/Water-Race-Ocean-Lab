// ocean_breaking_common.gdshaderinc
// Funciones y uniforms COMPARTIDOS del detector GPU de pre-break (Phase 4A) y
// del takeover de geometrÃ­a local de breaker (Phase 4B).
//
// Este include se procesa al inicio de cada shader (Godot exige includes antes
// del resto del cÃ³digo) y declara aquÃ­ mismo los uniforms compartidos para que
// las funciones puedan referenciarlos: cada shader que lo incluya recibe su
// propia copia textual de estas declaraciones con los mismos nombres, y por
// tanto el mÃ³dulo puede fijarlos con set_shader_parameter de forma idÃ©ntica.
//
// Los shaders que incluyan este archivo NO deben redeclarar estos uniforms
// (darÃ­a un error de duplicado); sÃ³lo declaran sus uniforms propios.
//
// La ruta de detecciÃ³n samplea SOLO la macroestructura LONG real:
// LONG_COASTAL (warped/shoaled) + LONG_REMAINDER (open). MID/SHORT entran
// Ãºnicamente en surface_displacement_break/surface_slope_break (integraciÃ³n
// visual del ribetÃ³n con la superficie base), jamÃ¡s en el trigger.

uniform sampler2D displacement_long_coastal : repeat_enable, filter_linear;
uniform sampler2D displacement_long_remainder : repeat_enable, filter_linear;
uniform sampler2D displacement_mid : repeat_enable, filter_linear;
uniform sampler2D displacement_short : repeat_enable, filter_linear;
uniform sampler2D normal_long_coastal : repeat_enable, filter_linear;
uniform sampler2D normal_long_remainder : repeat_enable, filter_linear;
uniform sampler2D normal_mid : repeat_enable, filter_linear;
uniform sampler2D normal_short : repeat_enable, filter_linear;
uniform sampler2D coastal_field_texture : repeat_disable, filter_linear;
uniform sampler2D coastal_metrics_texture : repeat_disable, filter_linear;
uniform sampler2D coastal_phase_texture : repeat_disable, filter_linear;
uniform sampler2D coastal_warp_texture : repeat_disable, filter_linear;
uniform sampler2D coastal_warp_jacobian_texture : repeat_disable, filter_linear;
uniform float domain_long_coastal_m = 512.0;
