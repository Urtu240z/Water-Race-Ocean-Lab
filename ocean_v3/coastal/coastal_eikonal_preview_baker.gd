@tool
class_name CoastalEikonalPreviewBaker
extends Node
## Orquestador de editor: BathymetryBaker real -> Eikonal CPU -> overlay temporal.
## Bathymetry y RenderingServer viven en el hilo principal; el solve es CPU puro
## y se ejecuta en un Thread de tooling. No integra Coastal en FFT ni shaders.

const DebugScript := preload("res://ocean_v3/coastal/coastal_eikonal_debug.gd")
const EikonalBakerScript := preload("res://ocean_v3/coastal/coastal_eikonal_baker.gd")

enum PreviewMode { REACHED, RAW_DIRECTION, RENDER_DIRECTION, SHADOW_SCALE }
const LOCAL_DIRECTION: PreviewMode = PreviewMode.RAW_DIRECTION
enum BakeState { IDLE, BAKING_BATHYMETRY, SOLVING_EIKONAL, BUILDING_DEBUG, DONE, ERROR }

const PREVIEW_OWNER_META := "_coastal_eikonal_preview_owner_id"

class EikonalWorker extends RefCounted:
	var bathymetry_data: Resource
	var incoming_direction_xz := Vector2.RIGHT
	var reference_wavelength_m := 16.0
	var gravity_mps2 := 9.81
	var min_valid_depth_m := 0.25
	var max_sweep_cycles := 16
	var convergence_tolerance_s := 1.0e-4
	var shadow_min_scale := 0.15
	var shadow_occlusion_entry_scale := 0.70
	var shadow_detour_length_m := 32.0
	var shadow_smoothing_passes := 2
	var shadow_recovery_enabled := true
	var shadow_diffraction_angle_deg := 12.0
	var shadow_recovery_strength := 1.0
	var direction_smoothing_passes := 3
	var direction_smoothing_strength := 0.35
	var direction_smoothing_threshold_deg := 6.0

	func run() -> Dictionary:
		var baker = EikonalBakerScript.new()
		baker.bathymetry_data = bathymetry_data
		baker.incoming_direction_xz = incoming_direction_xz
		baker.reference_wavelength_m = reference_wavelength_m
		baker.gravity_mps2 = gravity_mps2
		baker.min_valid_depth_m = min_valid_depth_m
		baker.max_sweep_cycles = max_sweep_cycles
		baker.convergence_tolerance_s = convergence_tolerance_s
		baker.shadow_min_scale = shadow_min_scale
		baker.shadow_occlusion_entry_scale = shadow_occlusion_entry_scale
		baker.shadow_detour_length_m = shadow_detour_length_m
		baker.shadow_smoothing_passes = shadow_smoothing_passes
		baker.shadow_recovery_enabled = shadow_recovery_enabled
		baker.shadow_diffraction_angle_deg = shadow_diffraction_angle_deg
		baker.shadow_recovery_strength = shadow_recovery_strength
		baker.direction_smoothing_passes = direction_smoothing_passes
		baker.direction_smoothing_strength = direction_smoothing_strength
		baker.direction_smoothing_threshold_deg = direction_smoothing_threshold_deg
		var data = baker.bake()
		return {
			"data": data,
			"base_metrics_ms": baker.last_base_metrics_ms,
			"eikonal_sweep_ms": baker.last_eikonal_sweep_ms,
			"phase_populate_ms": baker.last_phase_populate_ms,
			"shadow_ms": baker.last_shadow_ms,
			"cycles_used": baker.last_cycles_used,
			"directional_sweeps_used": baker.last_directional_sweeps_used,
			"final_max_change": baker.last_final_max_change,
			"shadow_geometric_ms": baker.last_shadow_geometric_ms,
			"shadow_recovery_ms": baker.last_shadow_recovery_ms,
			"direction_smoothing_ms": baker.last_direction_smoothing_ms,
		}

@export_category("Bathymetry")
@export var bathymetry_baker: BathymetryBaker

@export_category("Coastal Eikonal")
@export var incoming_direction_xz := Vector2.RIGHT
@export_range(0.1, 200.0, 0.1, "suffix:m") var reference_wavelength_m := 16.0
@export_range(0.1, 30.0, 0.01, "suffix:m/s²") var gravity_mps2 := 9.81
@export_range(0.01, 20.0, 0.01, "suffix:m") var min_valid_depth_m := 0.25
@export_range(1, 512, 1) var max_sweep_cycles := 16
@export_range(0.0000001, 0.1, 0.0000001, "or_greater") var convergence_tolerance_s := 1.0e-4

@export_category("Shadow")
@export_range(0.0, 1.0, 0.01) var shadow_min_scale := 0.15
@export_range(0.0, 1.0, 0.01) var shadow_occlusion_entry_scale := 0.70
@export_range(0.1, 1000.0, 0.1, "suffix:m") var shadow_detour_length_m := 32.0
@export_range(0, 8, 1) var shadow_smoothing_passes := 2
@export var shadow_recovery_enabled := true
@export_range(0.0, 45.0, 0.1, "suffix:deg") var shadow_diffraction_angle_deg := 12.0
@export_range(0.0, 1.0, 0.01) var shadow_recovery_strength := 1.0

@export_category("Direction Smoothing")
@export_range(0, 8, 1) var direction_smoothing_passes := 3
@export_range(0.0, 1.0, 0.01) var direction_smoothing_strength := 0.35
@export_range(0.0, 90.0, 0.1, "suffix:deg") var direction_smoothing_threshold_deg := 6.0

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

@export_category("Diagnostics")
@export var bake_state: BakeState = BakeState.IDLE
var last_bathymetry_ms := 0.0
var last_eikonal_ms := 0.0
var last_debug_mesh_ms := 0.0
var last_total_ms := 0.0
var last_cycles_used := 0
var last_directional_sweeps_used := 0
var last_final_max_change := 0.0
var last_shadow_geometric_ms := 0.0
var last_shadow_recovery_ms := 0.0
var last_direction_smoothing_ms := 0.0

var _preview: CoastalEikonalDebug = null
var _bathymetry_data: BathymetryData = null
var _coastal_data: CoastalPropagationData = null
var _eikonal_thread: Thread = null
var _eikonal_worker: EikonalWorker = null
var _pending_bathymetry_data: BathymetryData = null
var _pending_total_start_usec := 0
var _pending_bathymetry_ms := 0.0
var _pending_eikonal_start_usec := 0
var _pending_base_metrics_ms := 0.0
var _pending_eikonal_sweep_ms := 0.0
var _pending_phase_populate_ms := 0.0
var _pending_shadow_ms := 0.0
var _pending_shadow_geometric_ms := 0.0
var _pending_shadow_recovery_ms := 0.0
var _pending_direction_smoothing_ms := 0.0
var _discard_worker_result := false


func _ready() -> void:
	set_process(false)


func bake_coastal_preview() -> void:
	if _eikonal_thread != null:
		push_warning("Coastal preview bake already running.")
		return
	var total_start := Time.get_ticks_usec()
	_set_bake_state(BakeState.BAKING_BATHYMETRY)
	print("COASTAL PREVIEW START")
	if bathymetry_baker == null:
		_set_bake_state(BakeState.ERROR)
		push_error("CoastalEikonalPreviewBaker: asigna Bathymetry Baker antes de BAKE COASTAL PREVIEW.")
		return
	var direction := incoming_direction_xz.normalized()
	if direction.length_squared() <= 1.0e-8:
		_set_bake_state(BakeState.ERROR)
		push_error("CoastalEikonalPreviewBaker: Incoming Direction XZ no puede ser Vector2.ZERO.")
		return
	print("COASTAL PREVIEW: baking bathymetry...")
	var bathymetry_start := Time.get_ticks_usec()
	var bathymetry_data = bathymetry_baker.bake()
	last_bathymetry_ms = float(Time.get_ticks_usec() - bathymetry_start) / 1000.0
	if bathymetry_data == null or not bathymetry_data.is_valid():
		_set_bake_state(BakeState.ERROR)
		push_error("CoastalEikonalPreviewBaker: BathymetryBaker no produjo BathymetryData válida.")
		return
	_pending_bathymetry_data = bathymetry_data
	_pending_total_start_usec = total_start
	_pending_bathymetry_ms = last_bathymetry_ms
	_pending_eikonal_start_usec = Time.get_ticks_usec()
	_discard_worker_result = false
	_eikonal_worker = EikonalWorker.new()
	_eikonal_worker.bathymetry_data = bathymetry_data
	_eikonal_worker.incoming_direction_xz = direction
	_eikonal_worker.reference_wavelength_m = reference_wavelength_m
	_eikonal_worker.gravity_mps2 = gravity_mps2
	_eikonal_worker.min_valid_depth_m = min_valid_depth_m
	_eikonal_worker.max_sweep_cycles = max_sweep_cycles
	_eikonal_worker.convergence_tolerance_s = convergence_tolerance_s
	_eikonal_worker.shadow_min_scale = shadow_min_scale
	_eikonal_worker.shadow_occlusion_entry_scale = shadow_occlusion_entry_scale
	_eikonal_worker.shadow_detour_length_m = shadow_detour_length_m
	_eikonal_worker.shadow_smoothing_passes = shadow_smoothing_passes
	_eikonal_thread = Thread.new()
	_set_bake_state(BakeState.SOLVING_EIKONAL)
	print("COASTAL PREVIEW: solving eikonal in worker thread...")
	var start_error: Error = _eikonal_thread.start(Callable(_eikonal_worker, "run"))
	if start_error != OK:
		_eikonal_thread = null
		_eikonal_worker = null
		_set_bake_state(BakeState.ERROR)
		push_error("CoastalEikonalPreviewBaker: no se pudo iniciar el worker Eikonal (%s)." % start_error)
		return
	set_process(true)


func _process(_delta: float) -> void:
	if _eikonal_thread == null or _eikonal_thread.is_alive():
		return
	var result: Variant = _eikonal_thread.wait_to_finish()
	_eikonal_thread = null
	_eikonal_worker = null
	last_eikonal_ms = float(Time.get_ticks_usec() - _pending_eikonal_start_usec) / 1000.0
	if _discard_worker_result or not is_inside_tree():
		_pending_bathymetry_data = null
		set_process(false)
		return
	if typeof(result) != TYPE_DICTIONARY:
		_set_bake_state(BakeState.ERROR)
		push_error("CoastalEikonalPreviewBaker: el worker no devolvió un resultado.")
		set_process(false)
		return
	var coastal_resource: Resource = result.get("data")
	if coastal_resource == null or not coastal_resource.is_valid():
		_set_bake_state(BakeState.ERROR)
		push_error("CoastalEikonalPreviewBaker: CoastalEikonalBaker no produjo CoastalPropagationData válida.")
		set_process(false)
		return
	last_cycles_used = int(result.get("cycles_used", 0))
	last_directional_sweeps_used = int(result.get("directional_sweeps_used", 0))
	last_final_max_change = float(result.get("final_max_change", 0.0))
	_pending_base_metrics_ms = float(result.get("base_metrics_ms", 0.0))
	_pending_eikonal_sweep_ms = float(result.get("eikonal_sweep_ms", 0.0))
	_pending_phase_populate_ms = float(result.get("phase_populate_ms", 0.0))
	_pending_shadow_ms = float(result.get("shadow_ms", 0.0))
	_pending_shadow_geometric_ms = float(result.get("shadow_geometric_ms", 0.0))
	_pending_shadow_recovery_ms = float(result.get("shadow_recovery_ms", 0.0))
	_pending_direction_smoothing_ms = float(result.get("direction_smoothing_ms", 0.0))
	last_shadow_geometric_ms = _pending_shadow_geometric_ms
	last_shadow_recovery_ms = _pending_shadow_recovery_ms
	last_direction_smoothing_ms = _pending_direction_smoothing_ms
	_set_bake_state(BakeState.BUILDING_DEBUG)
	_install_preview(_pending_bathymetry_data, coastal_resource as CoastalPropagationData)
	_pending_bathymetry_data = null
	set_process(false)


func _install_preview(bathymetry_data: BathymetryData, coastal_data: CoastalPropagationData) -> void:
	if _preview_parent() == null:
		_set_bake_state(BakeState.ERROR)
		push_error("CoastalEikonalPreviewBaker: no se encontró parent para el preview temporal.")
		return
	clear_preview(false)
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
	last_debug_mesh_ms = float(Time.get_ticks_usec() - debug_start) / 1000.0
	last_total_ms = float(Time.get_ticks_usec() - _pending_total_start_usec) / 1000.0
	_print_statistics(coastal_data)
	print("bathymetry = %.3f ms" % _pending_bathymetry_ms)
	print("base metrics = %.3f ms" % _pending_base_metrics_ms)
	print("eikonal sweep = %.3f ms" % _pending_eikonal_sweep_ms)
	print("phase populate = %.3f ms" % _pending_phase_populate_ms)
	print("shadow field = %.3f ms" % _pending_shadow_ms)
	print("shadow geometric = %.3f ms" % _pending_shadow_geometric_ms)
	print("shadow recovery = %.3f ms" % _pending_shadow_recovery_ms)
	print("direction smoothing = %.3f ms" % _pending_direction_smoothing_ms)
	print("eikonal total = %.3f ms" % last_eikonal_ms)
	print("debug mesh = %.3f ms" % last_debug_mesh_ms)
	print("total = %.3f ms" % last_total_ms)
	_set_bake_state(BakeState.DONE)


func clear_preview(update_state: bool = true) -> void:
	if _eikonal_thread != null:
		_discard_worker_result = true
		return
	var preview := _find_owned_preview()
	_preview = null
	if preview != null and is_instance_valid(preview) and preview.get_meta(PREVIEW_OWNER_META, -1) == get_instance_id():
		var parent := preview.get_parent()
		if parent != null:
			parent.remove_child(preview)
		preview.free()
	_coastal_data = null
	_bathymetry_data = null
	if update_state and bake_state != BakeState.IDLE:
		_set_bake_state(BakeState.IDLE)


func _exit_tree() -> void:
	_discard_worker_result = true
	if _eikonal_thread != null:
		_eikonal_thread.wait_to_finish()
		_eikonal_thread = null
		_eikonal_worker = null
	clear_preview()


func _set_bake_state(state: BakeState) -> void:
	if bake_state == state:
		return
	bake_state = state
	print("COASTAL PREVIEW STATE: %s" % _state_name(state))


func _state_name(state: BakeState) -> String:
	match state:
		BakeState.IDLE: return "IDLE"
		BakeState.BAKING_BATHYMETRY: return "BAKING BATHYMETRY"
		BakeState.SOLVING_EIKONAL: return "SOLVING EIKONAL"
		BakeState.BUILDING_DEBUG: return "BUILDING DEBUG"
		BakeState.DONE: return "DONE"
		BakeState.ERROR: return "ERROR"
	return "UNKNOWN"


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
	print("sweeps = %d | cycles = %d | directional sweeps = %d | final change = %.8f | residual = %.8f" % [data.eikonal_sweeps, last_cycles_used, last_directional_sweeps_used, last_final_max_change, data.eikonal_max_residual_rad_m])
