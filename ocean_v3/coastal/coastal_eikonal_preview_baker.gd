@tool
class_name CoastalEikonalPreviewBaker
extends Node
## Orquestador de editor: BathymetryBaker real -> Eikonal CPU -> overlay temporal.
## No convierte el solver en Node ni integra Coastal en FFT, shaders u OceanQuery.

const DebugScript := preload("res://ocean_v3/coastal/coastal_eikonal_debug.gd")

enum PreviewMode { REACHED, LOCAL_DIRECTION, SHADOW_SCALE }

const PREVIEW_OWNER_META := "_coastal_eikonal_preview_owner_id"

@export_category("Bathymetry")
@export var bathymetry_baker: BathymetryBaker

@export_category("Coastal Eikonal")
@export var incoming_direction_xz := Vector2.RIGHT
@export_range(0.1, 200.0, 0.1, "suffix:m") var reference_wavelength_m := 16.0
@export_range(0.1, 30.0, 0.01, "suffix:m/s²") var gravity_mps2 := 9.81
@export_range(0.01, 20.0, 0.01, "suffix:m") var min_valid_depth_m := 0.25
@export_range(1, 512, 1) var max_sweeps := 96
@export_range(0.0000001, 0.1, 0.0000001, "or_greater") var convergence_tolerance_s := 1.0e-6

@export_category("Shadow")
@export_range(0.0, 1.0, 0.01) var shadow_min_scale := 0.15
@export_range(0.0, 1.0, 0.01) var shadow_occlusion_entry_scale := 0.70
@export_range(0.1, 1000.0, 0.1, "suffix:m") var shadow_detour_length_m := 32.0
@export_range(0, 8, 1) var shadow_smoothing_passes := 2

@export_category("Preview")
@export var preview_mode: PreviewMode = PreviewMode.SHADOW_SCALE:
	set(value):
		preview_mode = value
		_update_preview_mode()
@export_range(-100.0, 100.0, 0.01, "suffix:m") var preview_vertical_offset_m := 0.12:
	set(value):
		preview_vertical_offset_m = value
		_update_preview_transform()
@export_tool_button("BAKE COASTAL PREVIEW", "Play") var bake_coastal_preview_button = bake_coastal_preview
@export_tool_button("CLEAR PREVIEW", "Remove") var clear_preview_button = clear_preview

var _preview: CoastalEikonalDebug = null
var _bathymetry_data: BathymetryData = null
var _coastal_data: CoastalPropagationData = null


func bake_coastal_preview() -> void:
	var total_start := Time.get_ticks_usec()
	print("COASTAL PREVIEW START")
	if bathymetry_baker == null:
		push_error("CoastalEikonalPreviewBaker: asigna Bathymetry Baker antes de BAKE COASTAL PREVIEW.")
		return
	var direction := incoming_direction_xz.normalized()
	if direction.length_squared() <= 1.0e-8:
		push_error("CoastalEikonalPreviewBaker: Incoming Direction XZ no puede ser Vector2.ZERO.")
		return
	print("COASTAL PREVIEW: baking bathymetry...")
	var bathymetry_start := Time.get_ticks_usec()
	var bathymetry_data = bathymetry_baker.bake()
	var bathymetry_ms := float(Time.get_ticks_usec() - bathymetry_start) / 1000.0
	if bathymetry_data == null or not bathymetry_data.is_valid():
		push_error("CoastalEikonalPreviewBaker: BathymetryBaker no produjo BathymetryData válida.")
		return
	var eikonal_baker := CoastalEikonalBaker.new()
	eikonal_baker.bathymetry_data = bathymetry_data
	eikonal_baker.incoming_direction_xz = direction
	eikonal_baker.reference_wavelength_m = reference_wavelength_m
	eikonal_baker.gravity_mps2 = gravity_mps2
	eikonal_baker.min_valid_depth_m = min_valid_depth_m
	eikonal_baker.max_sweeps = max_sweeps
	eikonal_baker.convergence_tolerance_s = convergence_tolerance_s
	eikonal_baker.shadow_min_scale = shadow_min_scale
	eikonal_baker.shadow_occlusion_entry_scale = shadow_occlusion_entry_scale
	eikonal_baker.shadow_detour_length_m = shadow_detour_length_m
	eikonal_baker.shadow_smoothing_passes = shadow_smoothing_passes
	var eikonal_start := Time.get_ticks_usec()
	var coastal_data = eikonal_baker.bake()
	var eikonal_ms := float(Time.get_ticks_usec() - eikonal_start) / 1000.0
	if coastal_data == null or not coastal_data.is_valid():
		push_error("CoastalEikonalPreviewBaker: CoastalEikonalBaker no produjo CoastalPropagationData válida.")
		return
	if _preview_parent() == null:
		push_error("CoastalEikonalPreviewBaker: no se encontró parent para el preview temporal.")
		return

	# Sólo después de un bake válido se sustituye el overlay propio anterior.
	clear_preview()
	var preview: CoastalEikonalDebug = DebugScript.new()
	preview.name = "%s_CoastalEikonalPreview" % name if not name.is_empty() else "CoastalEikonalPreview"
	_preview_parent().add_child(preview, false, Node.INTERNAL_MODE_FRONT)
	preview.owner = null
	preview.set_meta(PREVIEW_OWNER_META, get_instance_id())
	preview.set_as_top_level(true)
	preview.global_transform = Transform3D.IDENTITY
	_preview = preview
	_bathymetry_data = bathymetry_data
	_coastal_data = coastal_data
	preview.base_y = bathymetry_data.sea_level_y
	preview.y_offset_m = preview_vertical_offset_m
	preview.mode = preview_mode as CoastalEikonalDebug.Mode
	print("COASTAL PREVIEW: building debug mesh...")
	var debug_start := Time.get_ticks_usec()
	preview.data = coastal_data
	var debug_ms := float(Time.get_ticks_usec() - debug_start) / 1000.0
	_print_statistics(coastal_data)
	print("bathymetry = %.3f ms" % bathymetry_ms)
	print("base metrics = %.3f ms" % eikonal_baker.last_base_metrics_ms)
	print("eikonal sweep = %.3f ms" % eikonal_baker.last_eikonal_sweep_ms)
	print("phase populate = %.3f ms" % eikonal_baker.last_phase_populate_ms)
	print("shadow field = %.3f ms" % eikonal_baker.last_shadow_ms)
	print("eikonal total = %.3f ms" % eikonal_ms)
	print("debug mesh = %.3f ms" % debug_ms)
	print("total = %.3f ms" % (float(Time.get_ticks_usec() - total_start) / 1000.0))


func clear_preview() -> void:
	var preview := _find_owned_preview()
	_preview = null
	if preview == null or not is_instance_valid(preview):
		return
	if preview.get_meta(PREVIEW_OWNER_META, -1) != get_instance_id():
		return
	var parent := preview.get_parent()
	if parent != null:
		parent.remove_child(preview)
	preview.free()
	_coastal_data = null
	_bathymetry_data = null


func _exit_tree() -> void:
	clear_preview()


func _update_preview_mode() -> void:
	var preview := _find_owned_preview()
	if preview != null and is_instance_valid(preview):
		preview.mode = preview_mode as CoastalEikonalDebug.Mode


func _update_preview_transform() -> void:
	var preview := _find_owned_preview()
	if preview != null and is_instance_valid(preview):
		preview.base_y = _bathymetry_data.sea_level_y if _bathymetry_data != null else 0.0
		preview.y_offset_m = preview_vertical_offset_m


func _preview_parent() -> Node:
	if is_inside_tree():
		var edited_root := get_tree().edited_scene_root
		if edited_root != null:
			return edited_root
	return get_parent()


func _find_owned_preview() -> CoastalEikonalDebug:
	if _preview != null and is_instance_valid(_preview):
		return _preview
	var parent := _preview_parent()
	if parent == null:
		return null
	for child in parent.get_children(true):
		if child is CoastalEikonalDebug and child.get_meta(PREVIEW_OWNER_META, -1) == get_instance_id():
			return child as CoastalEikonalDebug
	return null


func _print_statistics(data: CoastalPropagationData) -> void:
	var water_count := 0
	var reached_count := 0
	var unreached_count := 0
	var shadow_min := INF
	var shadow_max := -INF
	var shadow_sum := 0.0
	for index in data.width * data.height:
		if data.valid_mask[index] == 0:
			continue
		water_count += 1
		if data.reached_mask[index] != 0:
			reached_count += 1
		else:
			unreached_count += 1
		var scale: float = data.shadow_scale[index]
		shadow_min = minf(shadow_min, scale)
		shadow_max = maxf(shadow_max, scale)
		shadow_sum += scale
	var shadow_average := shadow_sum / float(water_count) if water_count > 0 else 0.0
	print("COASTAL PREVIEW:")
	print("grid = %dx%d" % [data.width, data.height])
	print("reached = %d | unreached = %d | water = %d" % [reached_count, unreached_count, water_count])
	print("shadow min/avg/max = %.4f / %.4f / %.4f" % [shadow_min if water_count > 0 else 0.0, shadow_average, shadow_max if water_count > 0 else 0.0])
	print("sweeps = %d | residual = %.8f" % [data.eikonal_sweeps, data.eikonal_max_residual_rad_m])
