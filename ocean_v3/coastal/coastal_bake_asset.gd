class_name CoastalBakeAsset
extends Resource
## Manifest canónico de una costa horneada offline.
## Los arrays grandes viven en los tres Resources referenciados, no aquí.

const CURRENT_FORMAT_VERSION := 1

@export var format_version := CURRENT_FORMAT_VERSION
@export var coast_id := ""
@export var bathymetry: BathymetryData
@export var propagation: CoastalPropagationData
@export var warp: CoastalWarpData

@export_category("Bathymetry metadata")
@export var bathymetry_cell_size_m := 0.0
@export var bathymetry_sea_level_y := 0.0
@export var bathymetry_bounds_min_xz := Vector2.ZERO
@export var bathymetry_bounds_max_xz := Vector2.ZERO
@export var bathymetry_synthetic_depth_enabled := false
@export var bathymetry_synthetic_slope := 0.0
@export var bathymetry_synthetic_max_depth_m := 0.0

@export_category("Eikonal metadata")
@export var eikonal_incoming_direction_xz := Vector2.RIGHT
@export var eikonal_reference_wavelength_m := 0.0
@export var eikonal_gravity_mps2 := 9.81
@export var eikonal_min_valid_depth_m := 0.0
@export var eikonal_max_sweep_cycles := 0
@export var eikonal_convergence_tolerance_s := 0.0
@export var eikonal_shadow_recovery_enabled := false
@export var eikonal_shadow_min_scale := 0.0
@export var eikonal_shadow_occlusion_entry_scale := 0.0
@export var eikonal_shadow_detour_length_m := 0.0
@export var eikonal_shadow_smoothing_passes := 0
@export var eikonal_shadow_diffraction_angle_deg := 0.0
@export var eikonal_shadow_recovery_strength := 0.0
@export var eikonal_direction_smoothing_passes := 0
@export var eikonal_direction_smoothing_strength := 0.0
@export var eikonal_direction_smoothing_threshold_deg := 0.0
@export var eikonal_cut_locus_enabled := false
@export var eikonal_cut_locus_detect_angle_deg := 0.0
@export var eikonal_cut_locus_blend_radius_m := 0.0
@export var eikonal_cut_locus_blend_passes := 0
@export var eikonal_cut_locus_blend_strength := 0.0
@export var eikonal_phase_regularization_enabled := false
@export var eikonal_phase_regularization_passes := 0
@export var eikonal_phase_regularization_strength := 0.0
@export var eikonal_phase_regularization_raw_fidelity := 0.0

@export_category("Warp metadata")
@export var warp_backtrace_step_cells := 0.0
@export var warp_max_backtrace_steps := 0
@export var warp_detj_safe_threshold := 0.0


func is_valid() -> bool:
	if format_version != CURRENT_FORMAT_VERSION or coast_id.strip_edges().is_empty():
		return false
	if bathymetry == null or propagation == null or warp == null:
		return false
	if eikonal_incoming_direction_xz.length_squared() <= 1.0e-8 or eikonal_reference_wavelength_m <= 0.0 or eikonal_gravity_mps2 <= 0.0 or eikonal_min_valid_depth_m < 0.0:
		return false
	if not bathymetry.is_valid() or not propagation.is_valid() or not warp.is_valid():
		return false
	if not _same_grid(bathymetry, propagation) or not _same_grid(bathymetry, warp):
		return false
	if not is_equal_approx(bathymetry_cell_size_m, bathymetry.cell_size_m) or not is_equal_approx(bathymetry_sea_level_y, bathymetry.sea_level_y):
		return false
	if not bathymetry_bounds_min_xz.is_equal_approx(bathymetry.world_origin_xz) or not bathymetry_bounds_max_xz.is_equal_approx(bathymetry.world_max_xz()):
		return false
	if propagation.propagation_kind != 1: # EIKONAL_2D_3B1
		return false
	if eikonal_incoming_direction_xz.normalized().dot(propagation.incoming_direction_xz.normalized()) < 0.9999:
		return false
	if not is_equal_approx(propagation.k0_rad_m, warp.k0_rad_m):
		return false
	if not is_equal_approx(propagation.omega_ref_rad_s, warp.omega_ref_rad_s):
		return false
	if propagation.incoming_direction_xz.normalized().dot(warp.incoming_direction_xz.normalized()) < 0.9999:
		return false
	return true


func _same_grid(a, b) -> bool:
	return a.width == b.width \
		and a.height == b.height \
		and is_equal_approx(a.cell_size_m, b.cell_size_m) \
		and a.world_origin_xz.is_equal_approx(b.world_origin_xz)


func describe() -> String:
	return "%s v%d (%dx%d, %.3fm)" % [coast_id, format_version, bathymetry.width, bathymetry.height, bathymetry.cell_size_m]
