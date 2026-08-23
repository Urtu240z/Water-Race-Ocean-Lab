extends Node3D
## Demo de Fase 3B.2B: océano FFT REAL con LONG dividido en COASTAL/REMAINDER.
## Default: RACE, FFT real (sin MONO), Coastal ON, warp activo, debug OFF.
## Controles: C Coastal, M composición, F forced warp, G gain, O efecto,
## D heatmap delta, B pre-break, P pausa, V cámara, J seabed,
## K breakers on/off, N debug de geometría breaker (LIP/TAKEOVER/REGION/OFF).

const BathymetryDataScript := preload("res://ocean_v3/bathymetry/bathymetry_data.gd")

const _GRID_WIDTH := 129
const _GRID_HEIGHT := 97
const _CELL_SIZE_M := 1.0
const _ORIGIN_XZ := Vector2(-64.0, -48.0)

enum SeabedMode { HIDDEN, ACTUAL_DEPTH, OVERLAY }
enum CameraMode { TOP, GRAZING, BREAKER_CLOSE }
enum CompositionMode { FULL, LONG_ONLY, LONG_COASTAL_ONLY, LONG_REMAINDER_ONLY, MID_SHORT_ONLY }
enum WarpEffectMode { WARP_AND_SHOALING, WARP_ONLY, SHOALING_ONLY }
enum BreakingDebug { OFF, DEPTH, STEEPNESS, CRESTNESS, PREBREAK }

const _COMPOSITION_NAMES := ["FULL", "LONG_ONLY", "LONG_COASTAL_ONLY", "LONG_REMAINDER_ONLY", "MID_SHORT_ONLY"]
const _WARP_EFFECT_NAMES := ["WARP + SHOALING", "WARP ONLY", "SHOALING ONLY"]
const _DEBUG_GAINS := [1.0, 4.0, 8.0]
const _FORCED_WARP_OFFSET_XZ := Vector2(37.0, 23.0)
const _BREAKING_DEBUG_NAMES := ["OFF", "DEPTH", "STEEPNESS", "CRESTNESS", "PREBREAK"]
const SeaStateScript := preload("res://ocean_v3/core/sea_state_config.gd")

@onready var _ocean = $OceanV3/OpenOceanFFT
@onready var _seabed_actual: MeshInstance3D = $SeabedActualDebug
@onready var _seabed_overlay: MeshInstance3D = $SeabedOverlayDebug
@onready var _status: Label = %Status
@onready var _top_camera: Camera3D = $TopCamera
@onready var _grazing_camera: Camera3D = $GrazingCamera
@onready var _breaker_close_camera: Camera3D = $BreakerCloseCamera

var _bathymetry = null
var _seabed_mode := SeabedMode.HIDDEN
var _camera_mode := CameraMode.TOP
var _coastal_enabled := true
var _composition_mode: int = CompositionMode.FULL
var _warp_effect_mode: int = WarpEffectMode.WARP_AND_SHOALING
var _forced_warp_enabled := false
var _debug_gain_index := 0
var _delta_heatmap_enabled := false
var _breaking_debug: int = BreakingDebug.OFF
var _breakers_enabled := true


func _ready() -> void:
	get_window().title = "3B.2B FFT Composition Diagnostic"
	_top_camera.look_at(Vector3(0.0, 0.0, 0.0), Vector3.FORWARD)
	_grazing_camera.look_at(Vector3(0.0, 0.0, 0.0), Vector3.UP)
	_breaker_close_camera.look_at(Vector3(0.0, 0.0, 0.0), Vector3.UP)
	_bathymetry = _build_bank_bathymetry()
	_build_seabed_debugs(_bathymetry)
	_set_seabed_mode(_seabed_mode)
	_set_camera_mode(_camera_mode)
	_apply_coastal_settings()
	_update_status()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_C:
			_coastal_enabled = not _coastal_enabled
			_apply_coastal_settings()
		KEY_P:
			SimulationClock.toggle_paused()
		KEY_V:
			_set_camera_mode((_camera_mode + 1) % (CameraMode.BREAKER_CLOSE + 1))
		KEY_J:
			_set_seabed_mode((_seabed_mode + 1) % (SeabedMode.OVERLAY + 1))
		KEY_M:
			_composition_mode = (_composition_mode + 1) % _COMPOSITION_NAMES.size()
			_apply_render_diagnostics()
		KEY_F:
			_forced_warp_enabled = not _forced_warp_enabled
			_apply_render_diagnostics()
		KEY_G:
			_debug_gain_index = (_debug_gain_index + 1) % _DEBUG_GAINS.size()
			_apply_render_diagnostics()
		KEY_O:
			_warp_effect_mode = (_warp_effect_mode + 1) % _WARP_EFFECT_NAMES.size()
			_apply_render_diagnostics()
		KEY_D:
			_delta_heatmap_enabled = not _delta_heatmap_enabled
			_apply_render_diagnostics()
		KEY_B:
			_breaking_debug = (_breaking_debug + 1) % _BREAKING_DEBUG_NAMES.size()
			_ocean.set_breaking_debug(_breaking_debug)
		KEY_K:
			_breakers_enabled = not _breakers_enabled
			_ocean.set_breakers_enabled(_breakers_enabled)
		KEY_N:
			_ocean.cycle_breaker_debug()
		KEY_H:
			_ocean.cycle_breaker_debug_slot()
		KEY_1:
			_ocean.set_sea_state(SeaStateScript.State.CALM)
		KEY_2:
			_ocean.set_sea_state(SeaStateScript.State.RACE)
		KEY_3:
			_ocean.set_sea_state(SeaStateScript.State.ROUGH)
		KEY_T:
			_ocean.cycle_spectrum_model()
		KEY_Q:
			_ocean.adjust_breaker_debug_stage(-0.05)
		KEY_E:
			_ocean.adjust_breaker_debug_stage(0.05)
		KEY_X:
			_ocean.toggle_breaker_profile_direction()
	_update_status()


func _apply_coastal_settings() -> void:
	_ocean.coastal_bathymetry_data = _bathymetry
	_ocean.coastal_propagation_enabled = _coastal_enabled
	# El warp debe seguir la dirección del sector LONG_COASTAL, no un eje debug.
	_ocean.coastal_incoming_direction_xz = _ocean.coastal_long_reference_direction()
	_ocean.coastal_reference_wavelength_m = 16.0
	_ocean.coastal_monochromatic_debug = false # FFT REAL, sin instrumento mono.
	_ocean.coastal_eikonal_refraction_debug = true # Eikonal + warp (3B.2B).
	_ocean.coastal_warp_enabled = true
	_ocean.rebuild_coastal_propagation()
	_apply_render_diagnostics()


func _apply_render_diagnostics() -> void:
	_ocean.set_coastal_render_diagnostics(_composition_mode, _warp_effect_mode,
		_forced_warp_enabled, _FORCED_WARP_OFFSET_XZ, _DEBUG_GAINS[_debug_gain_index],
		_delta_heatmap_enabled)
	_ocean.set_breaking_debug(_breaking_debug)


func _update_status() -> void:
	var warp: Variant = _ocean.coastal_warp_data()
	var warp_text := "BAKING (una vez, ~7 s)..." if _coastal_enabled and warp == null else ("ON valid=%d" % warp.valid_mask.count(1) if warp != null else "OFF")
	var long_direction: Vector2 = _ocean.coastal_long_reference_direction()
	var warp_direction: Vector2 = _ocean.coastal_warp_direction()
	var direction_error_deg: float = rad_to_deg(acos(clampf(long_direction.dot(warp_direction), -1.0, 1.0)))
	_status.text = "PHASE 4A — REAL FFT PRE-BREAK FIELD — Sea State: %s | Spectrum: %s\nB Break debug: %s | C Coastal: %s | P Paused: %s | V Camera: %s | J Seabed: %s\nM Composition: %s | O Effect: %s\nF Forced warp: %s (+37,+23 m) | G Gain: %.0fx | D Delta heatmap: %s\nLONG dir=(%.3f,%.3f) | Eikonal/warp=(%.3f,%.3f) | error=%.3f deg\n\nDepth=H_LONG/(gamma*h), gamma=.78 | steepness=k_local*(Hs_LONG/2) | crest=lambda/16\nWarp world->deep: %s\n%s\n%s\n%s\n%s\n%s" % [_ocean.sea_state_name(), _ocean.spectrum_model_name(), _BREAKING_DEBUG_NAMES[_breaking_debug], "ON" if _coastal_enabled else "OFF", "YES" if SimulationClock.is_paused() else "NO", _camera_mode_name(), _seabed_mode_name(), _COMPOSITION_NAMES[_composition_mode], _WARP_EFFECT_NAMES[_warp_effect_mode], "ON" if _forced_warp_enabled else "OFF", _DEBUG_GAINS[_debug_gain_index], "ON" if _delta_heatmap_enabled else "OFF", long_direction.x, long_direction.y, warp_direction.x, warp_direction.y, direction_error_deg, warp_text, _split_metrics_text(), _warp_probes_text(warp), _fft_diagnostics_text(), _query_coastal_text(), _breaker_text()]


func _split_metrics_text() -> String:
	var metrics: Dictionary = _ocean.coastal_energy_metrics()
	if metrics.is_empty():
		return "Split metrics: pending"
	return "Split H0 total=%.5f coastal=%.5f (%.2f%%) | variance C=%.7f R=%.7f cov=%.7f total=%.7f" % [metrics["weighted_h0_power_total"], metrics["weighted_h0_power_coastal"], 100.0 * metrics["weighted_h0_power_coastal_fraction"], metrics["reconstructed_spatial_variance_coastal"], metrics["reconstructed_spatial_variance_remainder"], metrics["coastal_remainder_covariance"], metrics["total_reconstructed_variance"]]


func _warp_probes_text(warp) -> String:
	if warp == null:
		return "Warp probes: pending"
	var propagation = _ocean.coastal_propagation_data()
	var lines: PackedStringArray = []
	for point in [Vector2(-20.0, 0.0), Vector2(0.0, 0.0), Vector2(10.0, 0.0), Vector2(20.0, 0.0)]:
		var sample = warp.sample_warp(point)
		var shoaling := 1.0
		if propagation != null:
			shoaling = propagation.sample_propagation(point).shoaling_scale
		lines.append("p(%+.0f,%+.0f) deep(%+.2f,%+.2f) d(%+.2f,%+.2f) detJ=%.3f valid=%s conf=%.3f S=%.3f" % [point.x, point.y, sample.deep_xz.x, sample.deep_xz.y, sample.deep_xz.x - point.x, sample.deep_xz.y - point.y, sample.jacobian_det, "Y" if sample.valid else "N", warp.shader_warp_confidence(point), shoaling])
	return "Warp probes (shader confidence): " + " | ".join(lines)


func _fft_diagnostics_text() -> String:
	var state: Dictionary = _ocean.coastal_fft_diagnostics()
	if not state.get("ready", false):
		return "FFT LONG: pending / not ready"
	var coastal: Dictionary = state["long_coastal"]
	var remainder: Dictionary = state["long_remainder"]
	return "FFT LONG: C ready=%s H0=%d disp=%d norm=%d bytes=%d | R ready=%s H0=%d disp=%d norm=%d bytes=%d | distinct C/R disp=%s norm=%s" % ["Y" if coastal["solver_ready"] else "N", coastal["h0_rid"], coastal["published_displacement_rid"], coastal["published_normal_rid"], coastal["h0_upload_bytes"], "Y" if remainder["solver_ready"] else "N", remainder["h0_rid"], remainder["published_displacement_rid"], remainder["published_normal_rid"], remainder["h0_upload_bytes"], "Y" if state["distinct_published_displacement_rid"] else "N", "Y" if state["distinct_published_normal_rid"] else "N"]


func _query_coastal_text() -> String:
	var point := Vector3(-5.0, 0.0, 0.0)
	var coastal = _ocean.sample_water(point, SimulationClock.simulation_time)
	var open = _ocean.sample_water_open_reference(point, SimulationClock.simulation_time)
	return "Query Coastal: %s | probe q=(%+.0f,%+.0f) height coastal=%.5f open=%.5f delta=%+.6f" % ["ON" if _coastal_enabled else "OFF", point.x, point.z, coastal.height, open.height, coastal.height - open.height]


func _breaker_text() -> String:
	## Phase 4B: estado del pool de geometría local (datos CPU deterministas;
	## el trigger real vive en GPU, sin readback).
	var summary: Dictionary = _ocean.breaker_pool_summary()
	var enabled_text := "ON" if _breakers_enabled else "OFF"
	if summary.is_empty() or not summary.get("configured", false):
		return "Breakers (K): %s | debug (N): %s | sin coastal válido -> 0 slots" % [enabled_text, _ocean.breaker_debug_name()]
	var lines: PackedStringArray = []
	for index in summary["anchors"].size():
		var anchor: Dictionary = summary["anchors"][index]
		var direction: Vector2 = anchor["direction"]
		lines.append("slot %d p=(%+.1f,%+.1f) d=(%+.2f,%+.2f) h=%.2fm lam=%.1fm" % [index, anchor["xz"].x, anchor["xz"].y, direction.x, direction.y, anchor["depth_m"], anchor["wavelength_m"]])
	var body := " | ".join(lines)
	var slot_text := "Breaker debug slot (H): %s/%d" % [_ocean.breaker_debug_slot_name(), summary["slots"]]
	var stage_text := "CrossStage (Q/E): %.2f" % _ocean.breaker_debug_stage()
	var dir_text := "ProfileDir (X): %s" % _ocean.breaker_profile_direction_name()
	return "Breakers (K): %s | debug (N): %s | %s | %s | %s | slots %d/%d\n%s" % [enabled_text, _ocean.breaker_debug_name(), slot_text, stage_text, dir_text, summary["slots"], summary["max_slots"], body]


func _set_camera_mode(mode: int) -> void:
	_camera_mode = clampi(mode, CameraMode.TOP, CameraMode.BREAKER_CLOSE) as CameraMode
	if _camera_mode == CameraMode.TOP:
		_top_camera.make_current()
	elif _camera_mode == CameraMode.GRAZING:
		_grazing_camera.make_current()
	else:
		_breaker_close_camera.make_current()


func _camera_mode_name() -> String:
	match _camera_mode:
		CameraMode.TOP: return "TOP"
		CameraMode.GRAZING: return "GRAZING"
		CameraMode.BREAKER_CLOSE: return "BREAKER_CLOSE"
	return "UNKNOWN"


func _set_seabed_mode(mode: int) -> void:
	_seabed_mode = clampi(mode, SeabedMode.HIDDEN, SeabedMode.OVERLAY) as SeabedMode
	_seabed_actual.visible = _seabed_mode == SeabedMode.ACTUAL_DEPTH
	_seabed_overlay.visible = _seabed_mode == SeabedMode.OVERLAY


func _seabed_mode_name() -> String:
	match _seabed_mode:
		SeabedMode.HIDDEN: return "HIDDEN"
		SeabedMode.ACTUAL_DEPTH: return "ACTUAL"
		SeabedMode.OVERLAY: return "OVERLAY"
	return "UNKNOWN"


func _build_bank_bathymetry():
	var data = BathymetryDataScript.new()
	data.world_origin_xz = _ORIGIN_XZ
	data.width = _GRID_WIDTH
	data.height = _GRID_HEIGHT
	data.cell_size_m = _CELL_SIZE_M
	data.sea_level_y = 0.0
	var count := _GRID_WIDTH * _GRID_HEIGHT
	data.depth_m.resize(count)
	data.gradient_x.resize(count)
	data.gradient_z.resize(count)
	data.slope_magnitude.resize(count)
	data.land_water_mask.resize(count)
	for z in _GRID_HEIGHT:
		for x in _GRID_WIDTH:
			var index := z * _GRID_WIDTH + x
			var world_x := _ORIGIN_XZ.x + float(x) * _CELL_SIZE_M
			var world_z := _ORIGIN_XZ.y + float(z) * _CELL_SIZE_M
			data.depth_m[index] = _bank_depth(world_x, world_z)
			data.land_water_mask[index] = 1
	for z in _GRID_HEIGHT:
		for x in _GRID_WIDTH:
			var index := z * _GRID_WIDTH + x
			var x0 := maxi(x - 1, 0)
			var x1 := mini(x + 1, _GRID_WIDTH - 1)
			var z0 := maxi(z - 1, 0)
			var z1 := mini(z + 1, _GRID_HEIGHT - 1)
			var gx: float = (data.depth_m[z * _GRID_WIDTH + x1] - data.depth_m[z * _GRID_WIDTH + x0]) / (float(x1 - x0) * _CELL_SIZE_M)
			var gz: float = (data.depth_m[z1 * _GRID_WIDTH + x] - data.depth_m[z0 * _GRID_WIDTH + x]) / (float(z1 - z0) * _CELL_SIZE_M)
			data.gradient_x[index] = gx
			data.gradient_z[index] = gz
			data.slope_magnitude[index] = sqrt(gx * gx + gz * gz)
	return data


func _bank_depth(world_x: float, world_z: float) -> float:
	var bank_weight := exp(-(world_x * world_x / 900.0 + world_z * world_z / 1800.0))
	return 18.0 - 17.5 * bank_weight


func _build_seabed_debugs(data) -> void:
	_seabed_actual.mesh = _build_seabed_mesh(data, false)
	_seabed_overlay.mesh = _build_seabed_mesh(data, true)
	_seabed_actual.material_override = _make_seabed_material(false)
	_seabed_overlay.material_override = _make_seabed_material(true)


func _build_seabed_mesh(data, overlay: bool) -> ArrayMesh:
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for z in data.height - 1:
		for x in data.width - 1:
			_add_floor_triangle(tool, data, overlay, x, z, x + 1, z, x + 1, z + 1)
			_add_floor_triangle(tool, data, overlay, x, z, x + 1, z + 1, x, z + 1)
	return tool.commit()


func _make_seabed_material(overlay: bool) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = overlay
	material.render_priority = 127 if overlay else 0
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material


func _add_floor_triangle(tool: SurfaceTool, data, overlay: bool, ax: int, az: int, bx: int, bz: int, cx: int, cz: int) -> void:
	_add_floor_vertex(tool, data, overlay, ax, az)
	_add_floor_vertex(tool, data, overlay, bx, bz)
	_add_floor_vertex(tool, data, overlay, cx, cz)


func _add_floor_vertex(tool: SurfaceTool, data, overlay: bool, x: int, z: int) -> void:
	var index: int = z * data.width + x
	var world_xz: Vector2 = data.world_origin_xz + Vector2(float(x), float(z)) * data.cell_size_m
	var shallow: float = 1.0 - clampf(data.depth_m[index] / 18.0, 0.0, 1.0)
	tool.set_color(Color(lerpf(0.02, 1.0, shallow), lerpf(0.10, 0.52, shallow), lerpf(0.30, 0.03, shallow), 0.55 if overlay else 0.45))
	var height: float = data.sea_level_y + 0.10 if overlay else -data.depth_m[index]
	tool.add_vertex(Vector3(world_xz.x, height, world_xz.y))
