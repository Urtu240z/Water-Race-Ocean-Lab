@tool
class_name CoastalBakeAuthoring
extends Node
## Authoring-only pipeline: geometry -> Bathymetry -> Eikonal -> Warp -> disk.
## Este Node no se instancia ni se ejecuta como parte del runtime de OceanV3.

const OUTPUT_ROOT := "res://ocean_v3/baked/coastal"
const SAFE_ID_CHARS := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"

@export_category("Source")
@export var coast_id := "coast"
@export var source_root: Node3D
@export var source: MeshInstance3D

@export_category("Bathymetry")
@export var sea_level_y := 0.0
@export_range(0.1, 32.0, 0.1, "suffix:m") var cell_size_m := 1.0
@export var bounds_min_xz := Vector2(-64.0, -64.0)
@export var bounds_max_xz := Vector2(64.0, 64.0)
@export var use_source_bounds := true
@export_range(0.0, 10000.0, 1.0, "suffix:m") var bounds_padding_m := 64.0
@export var synthetic_depth_enabled := true
@export_range(0.0, 10.0, 0.01) var synthetic_slope := 0.20
@export_range(0.0, 10000.0, 0.1, "suffix:m") var synthetic_max_depth_m := 20.0

@export_category("Eikonal")
@export var incoming_direction_xz := Vector2.RIGHT
@export_range(0.1, 200.0, 0.1, "suffix:m") var reference_wavelength_m := 16.0
@export_range(0.1, 30.0, 0.01, "suffix:m/s²") var gravity_mps2 := 9.81
@export_range(0.01, 20.0, 0.01, "suffix:m") var min_valid_depth_m := 0.25
@export_range(1, 512, 1) var max_sweep_cycles := 16
@export_range(0.0000001, 0.1, 0.0000001, "or_greater") var convergence_tolerance_s := 1.0e-4
@export var shadow_recovery_enabled := true
@export_range(0.0, 1.0, 0.01) var shadow_min_scale := 0.15
@export_range(0.0, 1.0, 0.01) var shadow_occlusion_entry_scale := 0.70
@export_range(0.1, 1000.0, 0.1, "suffix:m") var shadow_detour_length_m := 32.0
@export_range(0, 8, 1) var shadow_smoothing_passes := 2
@export_range(0.0, 45.0, 0.1, "suffix:deg") var shadow_diffraction_angle_deg := 12.0
@export_range(0.0, 1.0, 0.01) var shadow_recovery_strength := 1.0
@export_range(0, 8, 1) var direction_smoothing_passes := 3
@export_range(0.0, 1.0, 0.01) var direction_smoothing_strength := 0.35
@export_range(0.0, 90.0, 0.1, "suffix:deg") var direction_smoothing_threshold_deg := 6.0

@export_category("Cut locus")
@export var cut_locus_enabled := true
@export_range(0.0, 180.0, 0.1, "suffix:deg") var cut_locus_detect_angle_deg := 35.0
@export_range(0.0, 1000.0, 0.1, "suffix:m") var cut_locus_blend_radius_m := 12.0
@export_range(0, 64, 1) var cut_locus_blend_passes := 12
@export_range(0.0, 1.0, 0.01) var cut_locus_blend_strength := 0.55

@export_category("Phase regularization")
@export var phase_regularization_enabled := true
@export_range(0, 128, 1) var phase_regularization_passes := 24
@export_range(0.0, 1.0, 0.01) var phase_regularization_strength := 0.65
@export_range(0.0, 4.0, 0.01) var phase_regularization_raw_fidelity := 0.25

@export_category("Warp")
@export_enum("PHASE_TRANSVERSE_IDENTITY", "LEGACY_CHARACTERISTIC_BACKTRACE") var warp_mapping_mode := 0
@export_range(0.05, 8.0, 0.05) var backtrace_step_cells := 0.5
@export_range(0.0, 1.0, 0.01) var detj_safe_threshold := 0.5
@export_range(0, 1000000, 1) var max_backtrace_steps := 0

@export_category("Bake")
@export_tool_button("BAKE COASTAL ASSET", "Play") var bake_coastal_asset_button = bake_coastal_asset


func bake_coastal_asset() -> CoastalBakeAsset:
	## Operación explícita de authoring; nunca la llama OceanV3 al ejecutar el juego.
	var safe_id := _sanitize_coast_id(coast_id)
	if safe_id.is_empty():
		push_error("CoastalBakeAuthoring: coast_id vacío o inválido.")
		return null
	if source_root == null and source == null:
		push_error("CoastalBakeAuthoring: asigna source_root o source.")
		return null
	var direction := incoming_direction_xz.normalized()
	if direction.length_squared() <= 1.0e-8:
		push_error("CoastalBakeAuthoring: incoming_direction_xz no puede ser cero.")
		return null

	var bathymetry_baker := BathymetryBaker.new()
	bathymetry_baker.source_root = source_root
	bathymetry_baker.source = source
	bathymetry_baker.sea_level_y = sea_level_y
	bathymetry_baker.cell_size_m = cell_size_m
	bathymetry_baker.bounds_min_xz = bounds_min_xz
	bathymetry_baker.bounds_max_xz = bounds_max_xz
	bathymetry_baker.use_source_bounds = use_source_bounds
	bathymetry_baker.bounds_padding_m = bounds_padding_m
	bathymetry_baker.synthetic_depth_enabled = synthetic_depth_enabled
	bathymetry_baker.synthetic_slope = synthetic_slope
	bathymetry_baker.synthetic_max_depth_m = synthetic_max_depth_m
	print("COASTAL ASSET: baking bathymetry...")
	var bathymetry: BathymetryData = bathymetry_baker.bake()
	if bathymetry == null or not bathymetry.is_valid():
		push_error("CoastalBakeAuthoring: BathymetryData inválida.")
		return null

	var eikonal_baker := CoastalEikonalBaker.new()
	eikonal_baker.bathymetry_data = bathymetry
	eikonal_baker.incoming_direction_xz = direction
	eikonal_baker.reference_wavelength_m = reference_wavelength_m
	eikonal_baker.gravity_mps2 = gravity_mps2
	eikonal_baker.min_valid_depth_m = min_valid_depth_m
	eikonal_baker.max_sweep_cycles = max_sweep_cycles
	eikonal_baker.convergence_tolerance_s = convergence_tolerance_s
	eikonal_baker.shadow_recovery_enabled = shadow_recovery_enabled
	eikonal_baker.shadow_min_scale = shadow_min_scale
	eikonal_baker.shadow_occlusion_entry_scale = shadow_occlusion_entry_scale
	eikonal_baker.shadow_detour_length_m = shadow_detour_length_m
	eikonal_baker.shadow_smoothing_passes = shadow_smoothing_passes
	eikonal_baker.shadow_diffraction_angle_deg = shadow_diffraction_angle_deg
	eikonal_baker.shadow_recovery_strength = shadow_recovery_strength
	eikonal_baker.direction_smoothing_passes = direction_smoothing_passes
	eikonal_baker.direction_smoothing_strength = direction_smoothing_strength
	eikonal_baker.direction_smoothing_threshold_deg = direction_smoothing_threshold_deg
	eikonal_baker.cut_locus_enabled = cut_locus_enabled
	eikonal_baker.cut_locus_detect_angle_deg = cut_locus_detect_angle_deg
	eikonal_baker.cut_locus_blend_radius_m = cut_locus_blend_radius_m
	eikonal_baker.cut_locus_blend_passes = cut_locus_blend_passes
	eikonal_baker.cut_locus_blend_strength = cut_locus_blend_strength
	eikonal_baker.phase_regularization_enabled = phase_regularization_enabled
	eikonal_baker.phase_regularization_passes = phase_regularization_passes
	eikonal_baker.phase_regularization_strength = phase_regularization_strength
	eikonal_baker.phase_regularization_raw_fidelity = phase_regularization_raw_fidelity
	print("COASTAL ASSET: solving Eikonal...")
	var propagation: CoastalPropagationData = eikonal_baker.bake()
	if propagation == null or not propagation.is_valid():
		push_error("CoastalBakeAuthoring: CoastalPropagationData inválida.")
		return null

	var warp_baker := CoastalWarpBaker.new()
	warp_baker.propagation = propagation
	warp_baker.mapping_mode = warp_mapping_mode
	warp_baker.backtrace_step_cells = backtrace_step_cells
	warp_baker.max_backtrace_steps = max_backtrace_steps
	warp_baker.detj_safe_threshold = detj_safe_threshold
	print("COASTAL ASSET: building warp...")
	var warp: CoastalWarpData = warp_baker.bake()
	if warp == null or not warp.is_valid():
		push_error("CoastalBakeAuthoring: CoastalWarpData inválida.")
		return null

	var asset := CoastalBakeAsset.new()
	asset.coast_id = safe_id
	asset.bathymetry = bathymetry
	asset.propagation = propagation
	asset.warp = warp
	asset.bathymetry_cell_size_m = bathymetry.cell_size_m
	asset.bathymetry_sea_level_y = bathymetry.sea_level_y
	asset.bathymetry_bounds_min_xz = bathymetry.world_origin_xz
	asset.bathymetry_bounds_max_xz = bathymetry.world_max_xz()
	asset.bathymetry_synthetic_depth_enabled = synthetic_depth_enabled
	asset.bathymetry_synthetic_slope = synthetic_slope
	asset.bathymetry_synthetic_max_depth_m = synthetic_max_depth_m
	asset.eikonal_incoming_direction_xz = direction
	asset.eikonal_reference_wavelength_m = reference_wavelength_m
	asset.eikonal_gravity_mps2 = gravity_mps2
	asset.eikonal_min_valid_depth_m = min_valid_depth_m
	asset.eikonal_max_sweep_cycles = max_sweep_cycles
	asset.eikonal_convergence_tolerance_s = convergence_tolerance_s
	asset.eikonal_shadow_recovery_enabled = shadow_recovery_enabled
	asset.eikonal_shadow_min_scale = shadow_min_scale
	asset.eikonal_shadow_occlusion_entry_scale = shadow_occlusion_entry_scale
	asset.eikonal_shadow_detour_length_m = shadow_detour_length_m
	asset.eikonal_shadow_smoothing_passes = shadow_smoothing_passes
	asset.eikonal_shadow_diffraction_angle_deg = shadow_diffraction_angle_deg
	asset.eikonal_shadow_recovery_strength = shadow_recovery_strength
	asset.eikonal_direction_smoothing_passes = direction_smoothing_passes
	asset.eikonal_direction_smoothing_strength = direction_smoothing_strength
	asset.eikonal_direction_smoothing_threshold_deg = direction_smoothing_threshold_deg
	asset.eikonal_cut_locus_enabled = cut_locus_enabled
	asset.eikonal_cut_locus_detect_angle_deg = cut_locus_detect_angle_deg
	asset.eikonal_cut_locus_blend_radius_m = cut_locus_blend_radius_m
	asset.eikonal_cut_locus_blend_passes = cut_locus_blend_passes
	asset.eikonal_cut_locus_blend_strength = cut_locus_blend_strength
	asset.eikonal_phase_regularization_enabled = phase_regularization_enabled
	asset.eikonal_phase_regularization_passes = phase_regularization_passes
	asset.eikonal_phase_regularization_strength = phase_regularization_strength
	asset.eikonal_phase_regularization_raw_fidelity = phase_regularization_raw_fidelity
	asset.warp_backtrace_step_cells = backtrace_step_cells
	asset.warp_max_backtrace_steps = max_backtrace_steps
	asset.warp_detj_safe_threshold = detj_safe_threshold
	if not asset.is_valid():
		push_error("CoastalBakeAuthoring: el manifest no supera la validación de grid.")
		return null

	var output_dir := "%s/%s" % [OUTPUT_ROOT, safe_id]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output_dir))
	var bathymetry_path := "%s/bathymetry.res" % output_dir
	var propagation_path := "%s/propagation.res" % output_dir
	var warp_path := "%s/warp.res" % output_dir
	var asset_path := "%s/coastal_bake.tres" % output_dir
	# Asigna el resource_path antes de serializar el manifest para que el .tres
	# conserve referencias ext_resource y no embeba los arrays grandes.
	bathymetry.resource_path = bathymetry_path
	propagation.resource_path = propagation_path
	warp.resource_path = warp_path
	for resource_pair in [[bathymetry, bathymetry_path], [propagation, propagation_path], [warp, warp_path]]:
		var save_error: Error = ResourceSaver.save(resource_pair[0], resource_pair[1], ResourceSaver.FLAG_CHANGE_PATH)
		if save_error != OK:
			push_error("CoastalBakeAuthoring: no se pudo guardar %s (error %d)." % [resource_pair[1], save_error])
			return null
	var error: Error = ResourceSaver.save(asset, asset_path)
	if error != OK:
		push_error("CoastalBakeAuthoring: no se pudo guardar %s (error %d)." % [asset_path, error])
		return null
	print("COASTAL ASSET: saved %s" % asset_path)
	return asset


func _sanitize_coast_id(value: String) -> String:
	var result := ""
	for character in value.strip_edges():
		if SAFE_ID_CHARS.find(character) >= 0:
			result += character
	return result
