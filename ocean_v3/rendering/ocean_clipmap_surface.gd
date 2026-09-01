@tool
class_name OceanClipmapSurface
extends Node3D
## Renderer geométrico centrado en cámara; no conoce ni modifica el campo FFT.

const MeshBuilder := preload("res://ocean_v3/rendering/ocean_clipmap_mesh_builder.gd")
const ClipmapConfigScript := preload("res://ocean_v3/rendering/ocean_clipmap_config.gd")
const BREAKING_DIAGNOSTIC_SHADER_PATH := "res://ocean_v3/rendering/shaders/ocean_surface_debug.gdshader"
const WATER_INTERFACE_SHADER_PATH := "res://ocean_v3/rendering/shaders/ocean_surface_interface.gdshader"
# Layer 20 is reserved for the auxiliary WaterInterface SubViewport.  The
# visible camera removes this bit; the interface camera renders only this bit.
const WATER_INTERFACE_LAYER := 1 << 19

enum DebugMode {
	FULL_DISPLACEMENT,
	HEIGHT_ONLY,
	NORMALS,
	SLOPE,
	WIREFRAME,
}

enum CoastalDebugField {
	OFF,
	DEPTH,
	WAVELENGTH,
	PHASE_SPEED,
	GROUP_VELOCITY,
	SHOALING,
	PHASE_OFFSET,
	LOCAL_K,
	REACHABILITY,
	SHORE_DEPTH,
	SHORE_VERTICAL_WEIGHT,
	SHORE_HORIZONTAL_WEIGHT,
}

## Phase 4A — instrumentación GPU de pre-break. No crea entidades persistentes.
enum BreakingDebug {
	OFF,
	DEPTH,
	STEEPNESS,
	CRESTNESS,
	PREBREAK,
	OPEN_BREAK,
	DEPTH_BREAK,
	BREAK_ONSET,
	BREAK_STRENGTH,
	PARENT_HEIGHT,
	PARENT_CREST_SCALE,
	BAND_ATTRIBUTION,
	SEGMENT_SPAN,
	SEGMENT_ASYMMETRY,
	SEGMENT_COHERENCE,
}

## Instrumentación temporal 3B.2B: selecciona contribuciones reales, no color.
enum CoastalCompositionDebug {
	FULL,
	LONG_ONLY,
	LONG_COASTAL_ONLY,
	LONG_REMAINDER_ONLY,
	MID_SHORT_ONLY,
}

enum CoastalWarpEffectDebug {
	WARP_AND_SHOALING,
	WARP_ONLY,
	SHOALING_ONLY,
}

@export var clipmap_config := ClipmapConfigScript.new()
@export var shore_stabilization_enabled := true
@export var shore_vertical_depth_range_m := Vector2(0.25, 6.0)
@export var shore_horizontal_depth_range_m := Vector2(0.75, 12.0)
# Full triangle validation is retained for explicit development/test runs, but
# not repeated during every deterministic production startup.
@export var validate_mesh_geometry_on_build := false

var _surface_material := ShaderMaterial.new()
var _wireframe_material := ShaderMaterial.new()
var _breaking_debug_material: ShaderMaterial
var _breaking_diagnostic_shader: Shader
# LOD colours are a diagnostic view.  Keeping this cache empty in production is
# intentional: each entry is a complete ShaderMaterial with all ocean uniforms.
var _lod_debug_materials: Array[ShaderMaterial] = []
var _levels: Array[MeshInstance3D] = []
var _water_interface_proxy_root: Node3D
var _water_interface_proxy_material: ShaderMaterial
var _water_interface_proxy_levels: Array[MeshInstance3D] = []
var _debug_mode: int = DebugMode.FULL_DISPLACEMENT
var _module_enabled := true
var _lod_debug := false
var _periodicity_debug := false
var _coastal_debug_field: int = CoastalDebugField.OFF
var _coastal_runtime_enabled := true
var _coastal_performance_enabled := true
var _coastal_propagation_available := false
var _coastal_transform_requested := false
var _coastal_monochromatic_debug := false
var _coastal_eikonal_phase_debug := false
var _coastal_warp_available := false
var _breaking_debug: int = BreakingDebug.OFF
var _band_long_enabled := true
var _band_mid_enabled := true
var _band_short_enabled := true
var _tracking_camera: Camera3D
var _triangle_count := 0
var _breaking_open_model: Dictionary = {
	&"breaking_long_hs_m": 0.50,
	&"breaking_mid_hs_m": 0.25,
	&"breaking_long_min_wavelength_m": 16.0,
	&"breaking_long_max_wavelength_m": 128.0,
	&"breaking_mid_min_wavelength_m": 4.0,
	&"breaking_mid_max_wavelength_m": 20.0,
	&"breaking_long_direction_xz": Vector2.RIGHT,
	&"breaking_mid_direction_xz": Vector2.RIGHT,
}


func _ready() -> void:
	if Engine.is_editor_hint():
		_prepare_editor_preview()


func configure(configs: Array[OpenOceanFFTConfig], displacements: Array[Texture2DRD], normals: Array[Texture2DRD], foams: Array[Texture2DRD], surface_foam: Texture2DRD, surface_foam_field_domain_m: float) -> void:
	var configure_started_usec := Time.get_ticks_usec()
	assert(clipmap_config.is_valid())
	# 3B.2B: 4 cascadas de render: LONG_COASTAL, LONG_REMAINDER, MID, SHORT.
	assert(configs.size() == 4 and displacements.size() == 4 and normals.size() == 4 and foams.size() == 4 and surface_foam != null)
	_surface_material.shader = load("res://ocean_v3/rendering/shaders/ocean_surface.gdshader")
	_wireframe_material.shader = load("res://ocean_v3/rendering/shaders/ocean_wireframe.gdshader")
	var shader_assigned_usec := Time.get_ticks_usec()
	_configure_materials(configs, displacements, normals, foams, surface_foam, surface_foam_field_domain_m)
	var materials_configured_usec := Time.get_ticks_usec()
	_rebuild_levels()
	var levels_rebuilt_usec := Time.get_ticks_usec()
	_apply_debug_mode()
	print("OCEAN STARTUP surface: shader=%d ms materials=%d ms clipmap=%d ms lod_debug=%d total=%d ms" % [
		int(float(shader_assigned_usec - configure_started_usec) / 1000.0),
		int(float(materials_configured_usec - shader_assigned_usec) / 1000.0),
		int(float(levels_rebuilt_usec - materials_configured_usec) / 1000.0),
		0 if _lod_debug_materials.is_empty() else 1,
		int(float(Time.get_ticks_usec() - configure_started_usec) / 1000.0),
	])


func _process(_delta: float) -> void:
	var camera := _tracking_camera if is_instance_valid(_tracking_camera) else get_viewport().get_camera_3d()
	if camera == null:
		return
	global_position = Vector3(camera.global_position.x, clipmap_config.sea_level_y, camera.global_position.z)
	var camera_xz := Vector2(camera.global_position.x, camera.global_position.z)
	# The wireframe shader has no camera-relative ocean sampling.  Do not publish
	# a per-frame value to it (or to inactive LOD diagnostics).
	_set_surface_material_shader_parameter(&"camera_world_xz", camera_xz)


func set_tracking_camera(camera: Camera3D) -> void:
	_tracking_camera = camera


## Phase 4B: expone el material del clipmap como fuente única de los uniforms
## compartidos (texturas coastal/warp/FFT, fades, band_mask, composición, ...).
## El pool de breakers copia desde aquí; no duplica el plomería de parámetros.
func get_surface_material() -> ShaderMaterial:
	return _surface_material


func ensure_water_interface_proxy() -> int:
	## Shares the production meshes and all dynamic material inputs.  Only the
	## proxy material's fragment path differs: it encodes interface data and
	## returns before the visual water shading work.
	if _water_interface_proxy_root == null:
		_water_interface_proxy_root = Node3D.new()
		_water_interface_proxy_root.name = &"WaterInterfaceProxy"
		add_child(_water_interface_proxy_root)
	if _water_interface_proxy_material == null and _surface_material.shader != null:
		_water_interface_proxy_material = _surface_material.duplicate() as ShaderMaterial
		if _water_interface_proxy_material != null:
			var interface_shader := Shader.new()
			var interface_source := FileAccess.get_file_as_string(WATER_INTERFACE_SHADER_PATH)
			interface_source = interface_source.replace("#include \"res://ocean_v3/rendering/shaders/ocean_surface.gdshader\"", FileAccess.get_file_as_string("res://ocean_v3/rendering/shaders/ocean_surface.gdshader"))
			interface_shader.code = interface_source
			_water_interface_proxy_material.shader = interface_shader
			_water_interface_proxy_material.set_shader_parameter(&"water_interface_depth_max_m", 500.0)
	_rebuild_water_interface_proxy_levels()
	return WATER_INTERFACE_LAYER


func release_water_interface_proxy() -> void:
	if _water_interface_proxy_root != null:
		_water_interface_proxy_root.queue_free()
	_water_interface_proxy_root = null
	_water_interface_proxy_material = null
	_water_interface_proxy_levels.clear()


func set_water_interface_depth_max(max_depth_m: float) -> void:
	if _water_interface_proxy_material != null:
		_water_interface_proxy_material.set_shader_parameter(&"water_interface_depth_max_m", maxf(max_depth_m, 1.0))


func _rebuild_water_interface_proxy_levels() -> void:
	if _water_interface_proxy_root == null or _water_interface_proxy_material == null:
		return
	for level in _water_interface_proxy_levels:
		if is_instance_valid(level):
			level.queue_free()
	_water_interface_proxy_levels.clear()
	for level_index in _levels.size():
		var source := _levels[level_index]
		if source == null or source.mesh == null:
			continue
		var proxy := MeshInstance3D.new()
		proxy.name = "InterfaceLevel%d" % level_index
		proxy.mesh = source.mesh
		proxy.material_override = _water_interface_proxy_material
		proxy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		proxy.extra_cull_margin = source.extra_cull_margin
		proxy.layers = WATER_INTERFACE_LAYER
		proxy.set_instance_shader_parameter(&"clipmap_level", float(level_index))
		_water_interface_proxy_root.add_child(proxy)
		_water_interface_proxy_levels.append(proxy)


func set_surface_shader_parameter(parameter: StringName, value: Variant) -> void:
	_set_surface_material_shader_parameter(parameter, value)


func sync_lod_debug_materials_from_surface() -> void:
	# Kept as a compatibility entry point for OceanV3.  The former implementation
	# enumerated every shader property and copied it to every dormant LOD material
	# after every visual sync.  Lazy creation duplicates the current material,
	# while normal update routes keep the small dynamic set in sync when LOD debug
	# is actually visible; there is no production-wide property-list fanout.
	pass


func _surface_materials() -> Array[ShaderMaterial]:
	var materials: Array[ShaderMaterial] = [_surface_material]
	if _water_interface_proxy_material != null:
		materials.append(_water_interface_proxy_material)
	if _breaking_diagnostic_active() and _breaking_debug_material != null:
		materials.append(_breaking_debug_material)
	if _lod_debug:
		materials.append_array(_lod_debug_materials)
	return materials


func _all_materials() -> Array[ShaderMaterial]:
	var materials: Array[ShaderMaterial] = [_surface_material, _wireframe_material]
	if _lod_debug:
		materials.append_array(_lod_debug_materials)
	return materials


func _set_surface_material_shader_parameter(parameter: StringName, value: Variant) -> void:
	for material in _surface_materials():
		material.set_shader_parameter(parameter, value)


func _set_all_materials_shader_parameter(parameter: StringName, value: Variant) -> void:
	for material in _all_materials():
		material.set_shader_parameter(parameter, value)


func _ensure_lod_debug_materials() -> void:
	if _lod_debug_materials.size() == clipmap_config.level_count:
		return
	_lod_debug_materials.clear()
	if _surface_material.shader == null:
		return
	# Duplicate only at first explicit LOD-debug activation.  This captures the
	# complete current uniform state once, without get_shader_parameter readbacks.
	for level_index in clipmap_config.level_count:
		var debug_material := _surface_material.duplicate() as ShaderMaterial
		if debug_material == null:
			push_error("No se pudo duplicar el material debug del clipmap L%d." % level_index)
			continue
		debug_material.set_shader_parameter(&"lod_debug_index", float(level_index))
		_lod_debug_materials.append(debug_material)


func _breaking_diagnostic_active() -> bool:
	return _breaking_debug >= BreakingDebug.OPEN_BREAK


func _ensure_breaking_debug_material() -> void:
	if _breaking_debug_material != null:
		return
	var activation_started_usec := Time.get_ticks_usec()
	var shader_load_usec := 0
	if _breaking_diagnostic_shader == null:
		var resource_load_started_usec := Time.get_ticks_usec()
		_breaking_diagnostic_shader = load(BREAKING_DIAGNOSTIC_SHADER_PATH) as Shader
		shader_load_usec = Time.get_ticks_usec() - resource_load_started_usec
	if _breaking_diagnostic_shader == null:
		push_error("No se pudo cargar el shader de diagnóstico de breaking.")
		return
	_breaking_debug_material = _surface_material.duplicate() as ShaderMaterial
	if _breaking_debug_material == null:
		push_error("No se pudo duplicar el material de diagnóstico de breaking.")
		return
	var shader_assignment_started_usec := Time.get_ticks_usec()
	_breaking_debug_material.shader = _breaking_diagnostic_shader
	_apply_breaking_open_model(_breaking_debug_material)
	print("OCEAN BREAKING DEBUG activation: resource_load=%d ms shader_assignment=%d ms total=%d ms" % [
		int(float(shader_load_usec) / 1000.0),
		int(float(Time.get_ticks_usec() - shader_assignment_started_usec) / 1000.0),
		int(float(Time.get_ticks_usec() - activation_started_usec) / 1000.0),
	])


func set_surface_foam_spectrum(surface_foam: Texture2DRD, field_domain_m: float) -> void:
	_set_surface_material_shader_parameter(&"surface_foam_short", surface_foam)
	_set_surface_material_shader_parameter(&"surface_foam_field_domain_m", field_domain_m)


func set_surface_foam_jacobian(jacobian: Texture2DRD, source_domain_m: float) -> void:
	_set_surface_material_shader_parameter(&"surface_foam_jacobian", jacobian)
	_set_surface_material_shader_parameter(&"surface_foam_source_domain_m", source_domain_m)


func set_surface_foam_topology(topology: Texture2DRD, source_domain_m: float) -> void:
	_set_surface_material_shader_parameter(&"surface_foam_topology", topology)
	_set_surface_material_shader_parameter(&"surface_foam_source_domain_m", source_domain_m)


func set_surface_foam_mid_fold_history(history: Texture2DRD) -> void:
	_set_surface_material_shader_parameter(&"surface_foam_mid_fold_history", history)


## 3B.2B: reaplica los rangos de fade (la demo ajusta long_fade para ver el
## warp sobre el banco local). No altera el campo FFT.
func apply_fade_ranges(config) -> void:
	for material in _all_materials():
		material.set_shader_parameter(&"short_fade_range_m", config.short_fade_range_m)
		material.set_shader_parameter(&"mid_fade_range_m", config.mid_fade_range_m)
		material.set_shader_parameter(&"long_fade_range_m", config.long_fade_range_m)


func set_band_debug(mode: int) -> void:
	var masks := [Vector3.ONE, Vector3(1.0, 0.0, 0.0), Vector3(0.0, 1.0, 0.0), Vector3(0.0, 0.0, 1.0)]
	var mask: Vector3 = masks[clampi(mode, 0, masks.size() - 1)]
	_band_long_enabled = is_equal_approx(mask.x, 1.0)
	_band_mid_enabled = is_equal_approx(mask.y, 1.0)
	_band_short_enabled = is_equal_approx(mask.z, 1.0)
	_apply_band_mask(mask)


## Temporary runtime diagnosis: independently gates the existing LONG/MID/SHORT
## band_mask for both the shaded and wireframe materials. It does not alter FFT,
## clipmap topology, LOD fades, or the existing ALL/LONG/MID/SHORT debug cycle.
func set_band_enabled(long_enabled: bool, mid_enabled: bool, short_enabled: bool) -> void:
	if _band_long_enabled != long_enabled:
		print("OCEAN BAND LONG: %s" % ("ON" if long_enabled else "OFF"))
	if _band_mid_enabled != mid_enabled:
		print("OCEAN BAND MID: %s" % ("ON" if mid_enabled else "OFF"))
	if _band_short_enabled != short_enabled:
		print("OCEAN BAND SHORT: %s" % ("ON" if short_enabled else "OFF"))
	_band_long_enabled = long_enabled
	_band_mid_enabled = mid_enabled
	_band_short_enabled = short_enabled
	_apply_band_mask(Vector3(
		1.0 if _band_long_enabled else 0.0,
		1.0 if _band_mid_enabled else 0.0,
		1.0 if _band_short_enabled else 0.0
	))
	print("OCEAN BANDS: LONG=%s MID=%s SHORT=%s" % [
		"ON" if _band_long_enabled else "OFF",
		"ON" if _band_mid_enabled else "OFF",
		"ON" if _band_short_enabled else "OFF",
	])


func is_band_enabled(band_index: int) -> bool:
	match band_index:
		0:
			return _band_long_enabled
		1:
			return _band_mid_enabled
		2:
			return _band_short_enabled
	return false


func _apply_band_mask(mask: Vector3) -> void:
	_set_all_materials_shader_parameter(&"band_mask", mask)


func set_module_enabled(enabled: bool) -> void:
	_module_enabled = enabled
	visible = enabled
	_set_all_materials_shader_parameter(&"module_enabled", enabled)


func cycle_debug_mode() -> void:
	_debug_mode = (_debug_mode + 1) % (DebugMode.WIREFRAME + 1)
	_apply_debug_mode()


func set_debug_mode(mode: int) -> void:
	_debug_mode = clampi(mode, 0, DebugMode.WIREFRAME)
	_apply_debug_mode()


func toggle_lod_debug() -> void:
	_lod_debug = not _lod_debug
	if _lod_debug:
		_ensure_lod_debug_materials()
	_set_surface_material_shader_parameter(&"clipmap_lod_debug", _lod_debug)
	_apply_debug_mode()


func toggle_periodicity_debug() -> void:
	_periodicity_debug = not _periodicity_debug
	_set_all_materials_shader_parameter(&"periodicity_debug", _periodicity_debug)


func set_coastal_propagation(data, monochromatic_debug := false, monochromatic_amplitude_m := 0.35, transform_enabled := true, eikonal_phase_debug := false) -> void:
	## Sólo LONG consume esta transformación. MID/SHORT y sus H0 quedan intactos.
	var enabled: bool = data != null and data.is_valid()
	var textures: Dictionary = data.build_gpu_textures() if enabled else {}
	_coastal_propagation_available = enabled
	_coastal_transform_requested = transform_enabled
	_coastal_monochromatic_debug = monochromatic_debug
	_coastal_eikonal_phase_debug = eikonal_phase_debug
	for material in _all_materials():
		# data_enabled permite MONO/Eikonal y sus probes; transform_enabled sólo
		# autoriza el warp visual de LONG (nunca para Eikonal 3B.1).
		material.set_shader_parameter(&"coastal_propagation_enabled", enabled and _coastal_runtime_enabled and _coastal_performance_enabled)
		material.set_shader_parameter(&"coastal_transform_enabled", enabled and transform_enabled and _coastal_runtime_enabled and _coastal_performance_enabled)
		material.set_shader_parameter(&"coastal_monochromatic_debug", monochromatic_debug and enabled and _coastal_runtime_enabled and _coastal_performance_enabled)
		material.set_shader_parameter(&"coastal_eikonal_phase_debug", eikonal_phase_debug and monochromatic_debug and enabled and _coastal_runtime_enabled and _coastal_performance_enabled)
		material.set_shader_parameter(&"coastal_monochromatic_amplitude_m", monochromatic_amplitude_m)
		if not enabled:
			continue
		material.set_shader_parameter(&"coastal_field_texture", textures["field"])
		material.set_shader_parameter(&"coastal_metrics_texture", textures["metrics"])
		material.set_shader_parameter(&"coastal_phase_texture", textures["phase"])
		material.set_shader_parameter(&"coastal_origin_xz", data.world_origin_xz)
		material.set_shader_parameter(&"coastal_extent_m", data.world_max_xz() - data.world_origin_xz)
		material.set_shader_parameter(&"coastal_k0_rad_m", data.k0_rad_m)
		material.set_shader_parameter(&"coastal_omega_rad_s", data.omega_ref_rad_s)
		material.set_shader_parameter(&"coastal_incoming_direction_xz", data.incoming_direction_xz)
		material.set_shader_parameter(&"coastal_min_valid_depth_m", maxf(data.min_valid_depth_m, 0.001))
		material.set_shader_parameter(&"coastal_cell_size_m", maxf(data.cell_size_m, 0.25))
	set_coastal_debug_field(_coastal_debug_field)


func set_real_seabed_coverage(data) -> void:
	## Cobertura geométrica baked para Water Optics. Es independiente de Coastal:
	## la propagación puede apagarse sin perder la autoridad real del seabed.
	var enabled: bool = data != null and data.has_method("has_real_seabed_coverage") \
		and data.has_real_seabed_coverage()
	var texture: Texture2D = data.build_gpu_seabed_coverage_texture() if enabled else null
	if texture == null:
		enabled = false
	for material in _all_materials():
		material.set_shader_parameter(&"real_seabed_coverage_enabled", enabled)
		if not enabled:
			continue
		material.set_shader_parameter(&"real_seabed_coverage_texture", texture)
		material.set_shader_parameter(&"real_seabed_coverage_origin_xz", data.world_origin_xz)
		material.set_shader_parameter(&"real_seabed_coverage_extent_m", data.world_max_xz() - data.world_origin_xz)


func set_coastal_warp(warp_data, enabled := true) -> void:
	## 3B.2B: pasa el CoastalWarpData al shader (deep_xz/detJ/valid + J).
	## El shader samplea LONG_COASTAL en deep_xz cuando el warp es válido y
	## blend suave en NEAR_CAUSTIC; fallback a world_xz en inválido/folded.
	var warp_enabled: bool = enabled and warp_data != null and warp_data.is_valid()
	var textures: Dictionary = warp_data.build_gpu_textures() if warp_enabled else {}
	_coastal_warp_available = warp_enabled
	for material in _all_materials():
		material.set_shader_parameter(&"coastal_warp_enabled", warp_enabled and _coastal_runtime_enabled and _coastal_performance_enabled)
		if not warp_enabled:
			continue
		material.set_shader_parameter(&"coastal_warp_texture", textures["warp"])
		material.set_shader_parameter(&"coastal_warp_jacobian_texture", textures["jacobian"])
		material.set_shader_parameter(&"coastal_warp_origin_xz", warp_data.world_origin_xz)
		material.set_shader_parameter(&"coastal_warp_extent_m", warp_data.world_max_xz() - warp_data.world_origin_xz)
		material.set_shader_parameter(&"coastal_warp_detj_safe", warp_data.detj_safe_threshold)


func set_coastal_runtime_enabled(enabled: bool) -> void:
	## Activa/desactiva la presentación de los datos ya horneados. No reconstruye
	## Bathymetry, Eikonal, warp, H0 ni texturas GPU; sólo cambia uniforms.
	_coastal_runtime_enabled = enabled
	for material in _all_materials():
		var effective_enabled := enabled and _coastal_performance_enabled
		material.set_shader_parameter(&"coastal_propagation_enabled", _coastal_propagation_available and effective_enabled)
		material.set_shader_parameter(&"coastal_transform_enabled", _coastal_propagation_available and _coastal_transform_requested and effective_enabled)
		material.set_shader_parameter(&"coastal_monochromatic_debug", _coastal_propagation_available and _coastal_monochromatic_debug and effective_enabled)
		material.set_shader_parameter(&"coastal_eikonal_phase_debug", _coastal_propagation_available and _coastal_eikonal_phase_debug and effective_enabled)
		material.set_shader_parameter(&"coastal_warp_enabled", _coastal_warp_available and effective_enabled)


func set_performance_profile(spectral_enabled: bool, coastal_enabled: bool,
		crest_foam_solver_enabled: bool, surface_foam_solver_enabled: bool,
		surface_foam_render_enabled: bool, prebreak_enabled: bool,
		_breakers_enabled: bool) -> void:
	## Performance-only shader gates. The public material controls remain unchanged.
	var surface_available := spectral_enabled and surface_foam_solver_enabled
	for material in _all_materials():
		material.set_shader_parameter(&"perf_spectral_enabled", spectral_enabled)
		material.set_shader_parameter(&"perf_crest_foam_solver_enabled", crest_foam_solver_enabled)
		material.set_shader_parameter(&"perf_surface_foam_solver_enabled", surface_available)
		material.set_shader_parameter(&"perf_surface_foam_render_enabled", surface_foam_render_enabled)
		material.set_shader_parameter(&"perf_prebreak_enabled", prebreak_enabled)
	_coastal_performance_enabled = coastal_enabled
	set_coastal_runtime_enabled(_coastal_runtime_enabled)


func coastal_runtime_enabled() -> bool:
	return _coastal_runtime_enabled


func set_coastal_composition_debug(mode: int) -> void:
	var clamped := clampi(mode, CoastalCompositionDebug.FULL, CoastalCompositionDebug.MID_SHORT_ONLY)
	for material in _all_materials():
		material.set_shader_parameter(&"coastal_composition_debug", clamped)


func cycle_coastal_composition_debug() -> void:
	var current: int = int(_surface_material.get_shader_parameter(&"coastal_composition_debug"))
	set_coastal_composition_debug(CoastalCompositionDebug.LONG_COASTAL_ONLY if current == CoastalCompositionDebug.FULL else CoastalCompositionDebug.FULL)


func coastal_composition_debug_name() -> String:
	var current: int = int(_surface_material.get_shader_parameter(&"coastal_composition_debug"))
	return CoastalCompositionDebug.keys()[clampi(current, CoastalCompositionDebug.FULL, CoastalCompositionDebug.MID_SHORT_ONLY)]


func set_coastal_render_diagnostics(composition_mode: int, warp_effect_mode: int,
		forced_warp_enabled: bool, forced_warp_offset_xz: Vector2, debug_gain: float,
		delta_heatmap_enabled: bool) -> void:
	## Sólo diagnóstico visual 3B.2B. No muta H0, la FFT ni los datos horneados.
	for material in _all_materials():
		material.set_shader_parameter(&"coastal_composition_debug", clampi(composition_mode, CoastalCompositionDebug.FULL, CoastalCompositionDebug.MID_SHORT_ONLY))
		material.set_shader_parameter(&"coastal_warp_effect_debug", clampi(warp_effect_mode, CoastalWarpEffectDebug.WARP_AND_SHOALING, CoastalWarpEffectDebug.SHOALING_ONLY))
		material.set_shader_parameter(&"coastal_forced_warp_debug", forced_warp_enabled)
		material.set_shader_parameter(&"coastal_forced_warp_offset_xz", forced_warp_offset_xz)
		material.set_shader_parameter(&"coastal_debug_gain", clampf(debug_gain, 1.0, 8.0))
		material.set_shader_parameter(&"coastal_delta_heatmap", delta_heatmap_enabled)


func set_coastal_time(simulation_time_s: float) -> void:
	_set_surface_material_shader_parameter(&"coastal_time_s", simulation_time_s)


func set_coastal_debug_field(field: int) -> void:
	_coastal_debug_field = clampi(field, CoastalDebugField.OFF, CoastalDebugField.SHORE_HORIZONTAL_WEIGHT)
	_set_all_materials_shader_parameter(&"coastal_debug_field", _coastal_debug_field)


func set_breaking_debug(mode: int) -> void:
	## Las señales 5R.3 siguen siendo GPU/debug-only: no crean candidates CPU.
	_breaking_debug = clampi(mode, BreakingDebug.OFF, BreakingDebug.SEGMENT_COHERENCE)
	if _breaking_diagnostic_active():
		_ensure_breaking_debug_material()
	_set_surface_material_shader_parameter(&"breaking_debug_mode", _breaking_debug)
	_apply_debug_mode()


func set_breaking_energy_model(long_hs_m: float, coastal_energy_fraction: float) -> void:
	## Hs del LONG completo y fracción de varianza de LONG_COASTAL. El shader
	## estima Hs local desde energía + shoaling; nunca usa eta instantánea como H.
	for material in _all_materials():
		material.set_shader_parameter(&"breaking_long_hs_m", maxf(long_hs_m, 0.0))
		material.set_shader_parameter(&"breaking_coastal_energy_fraction", clampf(coastal_energy_fraction, 0.0, 1.0))


func set_breaking_open_model(long_hs_m: float, mid_hs_m: float,
		long_min_wavelength_m: float, long_max_wavelength_m: float,
		mid_min_wavelength_m: float, mid_max_wavelength_m: float,
		long_direction_xz: Vector2, mid_direction_xz: Vector2) -> void:
	## Contrato de STEP 2 para OPEN_BREAK. Son parámetros espectrales ya existentes;
	## no hay readback ni nueva textura. MID/LONG siguen siendo la única entrada.
	var safe_long_direction := long_direction_xz.normalized() if long_direction_xz.length_squared() > 1.0e-8 else Vector2.RIGHT
	var safe_mid_direction := mid_direction_xz.normalized() if mid_direction_xz.length_squared() > 1.0e-8 else safe_long_direction
	_breaking_open_model = {
		&"breaking_long_hs_m": maxf(long_hs_m, 0.0),
		&"breaking_mid_hs_m": maxf(mid_hs_m, 0.0),
		&"breaking_long_min_wavelength_m": maxf(long_min_wavelength_m, 0.05),
		&"breaking_long_max_wavelength_m": maxf(long_max_wavelength_m, long_min_wavelength_m),
		&"breaking_mid_min_wavelength_m": maxf(mid_min_wavelength_m, 0.05),
		&"breaking_mid_max_wavelength_m": maxf(mid_max_wavelength_m, mid_min_wavelength_m),
		&"breaking_long_direction_xz": safe_long_direction,
		&"breaking_mid_direction_xz": safe_mid_direction,
	}
	if _breaking_debug_material != null:
		_apply_breaking_open_model(_breaking_debug_material)
	for material in _all_materials():
		material.set_shader_parameter(&"breaking_long_hs_m", _breaking_open_model[&"breaking_long_hs_m"])


func _apply_breaking_open_model(material: ShaderMaterial) -> void:
	if material == null:
		return
	for parameter_key in _breaking_open_model:
		material.set_shader_parameter(StringName(parameter_key), _breaking_open_model[parameter_key])


func breaking_debug_name() -> String:
	return BreakingDebug.keys()[_breaking_debug]


func debug_mode_name() -> String:
	match _debug_mode:
		DebugMode.FULL_DISPLACEMENT: return "DX + HEIGHT + DZ"
		DebugMode.HEIGHT_ONLY: return "HEIGHT ONLY"
		DebugMode.NORMALS: return "NORMALS"
		DebugMode.SLOPE: return "SLOPE / GEOMETRY"
		DebugMode.WIREFRAME: return "WIREFRAME"
	return "UNKNOWN"


func lod_debug_name() -> String:
	return "ON" if _lod_debug else "OFF"


func periodicity_debug_name() -> String:
	return "ON" if _periodicity_debug else "OFF"


func triangle_count() -> int:
	return _triangle_count


func level_count() -> int:
	return _levels.size()


func final_half_extent_m() -> float:
	return clipmap_config.final_half_extent_m()


func _configure_materials(configs: Array[OpenOceanFFTConfig], displacements: Array[Texture2DRD], normals: Array[Texture2DRD], foams: Array[Texture2DRD], surface_foam: Texture2DRD, surface_foam_field_domain_m: float) -> void:
	# 3B.2B: índices de render -> LONG_COASTAL=0, LONG_REMAINDER=1, MID=2, SHORT=3.
	var ids := ["long_coastal", "long_remainder", "mid", "short"]
	_breaking_open_model = {
		&"breaking_long_hs_m": configs[0].target_hs_m,
		&"breaking_mid_hs_m": configs[2].target_hs_m,
		&"breaking_long_min_wavelength_m": configs[0].min_wavelength_m,
		&"breaking_long_max_wavelength_m": configs[0].max_wavelength_m,
		&"breaking_mid_min_wavelength_m": configs[2].min_wavelength_m,
		&"breaking_mid_max_wavelength_m": configs[2].max_wavelength_m,
		&"breaking_long_direction_xz": configs[0].wind_direction.normalized(),
		&"breaking_mid_direction_xz": configs[2].wind_direction.normalized(),
	}
	for material in _all_materials():
		material.set_shader_parameter(&"module_enabled", _module_enabled)
		material.set_shader_parameter(&"perf_spectral_enabled", true)
		material.set_shader_parameter(&"perf_crest_foam_solver_enabled", true)
		material.set_shader_parameter(&"perf_surface_foam_solver_enabled", true)
		material.set_shader_parameter(&"perf_surface_foam_render_enabled", true)
		material.set_shader_parameter(&"perf_prebreak_enabled", true)
		material.set_shader_parameter(&"short_fade_range_m", clipmap_config.short_fade_range_m)
		material.set_shader_parameter(&"mid_fade_range_m", clipmap_config.mid_fade_range_m)
		material.set_shader_parameter(&"long_fade_range_m", clipmap_config.long_fade_range_m)
		material.set_shader_parameter(&"clipmap_lod_debug", _lod_debug)
		material.set_shader_parameter(&"periodicity_debug", _periodicity_debug)
		material.set_shader_parameter(&"coastal_propagation_enabled", false)
		material.set_shader_parameter(&"coastal_transform_enabled", false)
		material.set_shader_parameter(&"coastal_monochromatic_debug", false)
		material.set_shader_parameter(&"coastal_eikonal_phase_debug", false)
		material.set_shader_parameter(&"coastal_debug_field", CoastalDebugField.OFF)
		material.set_shader_parameter(&"shore_stabilization_enabled", shore_stabilization_enabled)
		material.set_shader_parameter(&"shore_vertical_depth_range_m", shore_vertical_depth_range_m)
		material.set_shader_parameter(&"shore_horizontal_depth_range_m", shore_horizontal_depth_range_m)
		material.set_shader_parameter(&"coastal_min_valid_depth_m", 0.25)
		material.set_shader_parameter(&"coastal_cell_size_m", 1.0)
		material.set_shader_parameter(&"breaking_debug_mode", BreakingDebug.OFF)
		material.set_shader_parameter(&"breaking_long_hs_m", configs[0].target_hs_m)
		material.set_shader_parameter(&"breaking_coastal_energy_fraction", 0.5)
		material.set_shader_parameter(&"coastal_warp_enabled", false)
		material.set_shader_parameter(&"coastal_composition_debug", CoastalCompositionDebug.FULL)
		material.set_shader_parameter(&"coastal_warp_effect_debug", CoastalWarpEffectDebug.WARP_AND_SHOALING)
		material.set_shader_parameter(&"coastal_forced_warp_debug", false)
		material.set_shader_parameter(&"coastal_forced_warp_offset_xz", Vector2(37.0, 23.0))
		material.set_shader_parameter(&"coastal_debug_gain", 1.0)
		material.set_shader_parameter(&"coastal_delta_heatmap", false)
		for index in 4:
			material.set_shader_parameter("domain_%s_m" % ids[index], configs[index].domain_size_m)
			material.set_shader_parameter("displacement_%s" % ids[index], displacements[index])
	_set_surface_material_shader_parameter(&"normal_long_coastal", normals[0])
	_set_surface_material_shader_parameter(&"normal_long_remainder", normals[1])
	_set_surface_material_shader_parameter(&"normal_mid", normals[2])
	_set_surface_material_shader_parameter(&"normal_short", normals[3])
	_set_surface_material_shader_parameter(&"foam_long_coastal", foams[0])
	_set_surface_material_shader_parameter(&"foam_long_remainder", foams[1])
	_set_surface_material_shader_parameter(&"foam_mid", foams[2])
	_set_surface_material_shader_parameter(&"foam_short", foams[3])
	_set_surface_material_shader_parameter(&"surface_foam_short", surface_foam)
	_set_surface_material_shader_parameter(&"surface_foam_field_domain_m", surface_foam_field_domain_m)


func _prepare_editor_preview() -> void:
	_surface_material.shader = load("res://ocean_v3/rendering/shaders/ocean_surface.gdshader")
	_wireframe_material.shader = load("res://ocean_v3/rendering/shaders/ocean_wireframe.gdshader")
	if _levels.is_empty() and clipmap_config.is_valid():
		_rebuild_levels()
	_apply_debug_mode()

func _rebuild_levels() -> void:
	var rebuild_started_usec := Time.get_ticks_usec()
	for level in _levels:
		level.queue_free()
	_levels.clear()
	# A topology rebuild invalidates the per-level overrides, but does not create
	# them unless the user has explicitly requested the diagnostic view.
	_lod_debug_materials.clear()
	if _lod_debug:
		_ensure_lod_debug_materials()
	_triangle_count = 0
	for level_index in clipmap_config.level_count:
		var generation_started_usec := Time.get_ticks_usec()
		var geometry := MeshBuilder.build_level_geometry(clipmap_config, level_index)
		var generation_finished_usec := Time.get_ticks_usec()
		var validation_finished_usec := generation_finished_usec
		if validate_mesh_geometry_on_build:
			var error := MeshBuilder.validate_geometry(geometry)
			validation_finished_usec = Time.get_ticks_usec()
			if not error.is_empty():
				push_error("Clipmap L%d inválido: %s" % [level_index, error])
				continue
		var mesh_creation_started_usec := Time.get_ticks_usec()
		var level_mesh := MeshBuilder.create_mesh(geometry)
		var mesh_creation_finished_usec := Time.get_ticks_usec()
		var instance := MeshInstance3D.new()
		instance.name = "Level%d" % level_index
		instance.mesh = level_mesh
		instance.material_override = _surface_material
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		instance.extra_cull_margin = clipmap_config.extra_cull_margin_m
		add_child(instance)
		instance.set_instance_shader_parameter(&"clipmap_level", float(level_index))
		_levels.append(instance)
		_triangle_count += int(float(geometry.indices.size()) / 3.0)
		print("OCEAN STARTUP clipmap L%d: generate=%d ms validate=%d ms mesh=%d ms instance=%d ms vertices=%d indices=%d" % [
			level_index,
			int(float(generation_finished_usec - generation_started_usec) / 1000.0),
			int(float(validation_finished_usec - generation_finished_usec) / 1000.0),
			int(float(mesh_creation_finished_usec - mesh_creation_started_usec) / 1000.0),
			int(float(Time.get_ticks_usec() - mesh_creation_finished_usec) / 1000.0),
			geometry.vertices.size(), geometry.indices.size(),
		])
	print("OCEAN STARTUP clipmap total: levels=%d triangles=%d total=%d ms validation=%s" % [
		_levels.size(), _triangle_count, int(float(Time.get_ticks_usec() - rebuild_started_usec) / 1000.0),
		"ON" if validate_mesh_geometry_on_build else "OFF",
	])
	_rebuild_water_interface_proxy_levels()


func _apply_debug_mode() -> void:
	if _lod_debug:
		_ensure_lod_debug_materials()
	for level_index in _levels.size():
		var level := _levels[level_index]
		if _breaking_diagnostic_active() and _breaking_debug_material != null:
			level.material_override = _breaking_debug_material
		elif _lod_debug and level_index < _lod_debug_materials.size():
			level.material_override = _lod_debug_materials[level_index]
		else:
			level.material_override = _wireframe_material if _debug_mode == DebugMode.WIREFRAME else _surface_material
		level.set_instance_shader_parameter(&"clipmap_level", float(level_index))
	_set_surface_material_shader_parameter(&"debug_mode", mini(_debug_mode, DebugMode.SLOPE))
