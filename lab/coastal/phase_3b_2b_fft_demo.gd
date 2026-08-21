extends Node3D
## Demo de Fase 3B.2B: océano FFT REAL con LONG dividido en COASTAL/REMAINDER.
## Default: RACE, FFT real (sin MONO), Coastal ON, warp activo, debug OFF.
## Controles: C = Coastal ON/OFF, W = warp debug, P = pause, V = cámara,
##           H = campo coastal debug, J = seabed overlay.

const BathymetryDataScript := preload("res://ocean_v3/bathymetry/bathymetry_data.gd")

const _GRID_WIDTH := 129
const _GRID_HEIGHT := 97
const _CELL_SIZE_M := 1.0
const _ORIGIN_XZ := Vector2(-64.0, -48.0)

enum SeabedMode { HIDDEN, ACTUAL_DEPTH, OVERLAY }
enum CameraMode { TOP, GRAZING }

@onready var _ocean = $OceanV3/OpenOceanFFT
@onready var _seabed_actual: MeshInstance3D = $SeabedActualDebug
@onready var _seabed_overlay: MeshInstance3D = $SeabedOverlayDebug
@onready var _status: Label = %Status
@onready var _top_camera: Camera3D = $TopCamera
@onready var _grazing_camera: Camera3D = $GrazingCamera

var _bathymetry = null
var _seabed_mode := SeabedMode.HIDDEN
var _camera_mode := CameraMode.TOP
var _coastal_enabled := true


func _ready() -> void:
	_top_camera.look_at(Vector3(0.0, 0.0, 0.0), Vector3.FORWARD)
	_grazing_camera.look_at(Vector3(0.0, 0.0, 0.0), Vector3.UP)
	# 3B.2B: el banco de la demo cubre ±64 m; el fade LONG estándar (768-2500 m)
	# haría LONG (y el warp) invisible sobre el banco. Ajustamos el fade LONG de
	# la DEMO para que el banco quede dentro de la zona LONG y la refracción sea
	# visible. Es config de demo, NO del sistema.
	var clipmap = _ocean.get_node("OceanClipmapSurface").clipmap_config
	clipmap.long_fade_range_m = Vector2(32.0, 260.0)
	_ocean.get_node("OceanClipmapSurface").apply_fade_ranges(clipmap)
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
			_set_camera_mode((_camera_mode + 1) % (CameraMode.GRAZING + 1))
		KEY_J:
			_set_seabed_mode((_seabed_mode + 1) % (SeabedMode.OVERLAY + 1))
	_update_status()


func _apply_coastal_settings() -> void:
	_ocean.coastal_bathymetry_data = _bathymetry
	_ocean.coastal_propagation_enabled = _coastal_enabled
	_ocean.coastal_incoming_direction_xz = Vector2.RIGHT
	_ocean.coastal_reference_wavelength_m = 16.0
	_ocean.coastal_monochromatic_debug = false # FFT REAL, sin instrumento mono.
	_ocean.coastal_eikonal_refraction_debug = true # Eikonal + warp (3B.2B).
	_ocean.coastal_warp_enabled = true
	_ocean.rebuild_coastal_propagation()


func _update_status() -> void:
	var warp: Variant = _ocean.coastal_warp_data()
	var warp_text := "BAKING (una vez, ~7 s)..." if _coastal_enabled and warp == null else ("ON valid=%d" % warp.valid_mask.count(1) if warp != null else "OFF")
	_status.text = "PHASE 3B.2B — FFT REAL + LONG COASTAL/REMAINDER (RACE)\nC  Coastal: %s\nP  Paused: %s\nV  Camera: %s\nJ  Seabed: %s\n\nWarp world->deep: %s\n\nEl mar es FFT real (LONG_COASTAL + LONG_REMAINDER + MID + SHORT).\nEl banco comprime/refracta LONG_COASTAL vía el warp; MID/SHORT intactos." % ["ON" if _coastal_enabled else "OFF", "YES" if SimulationClock.is_paused() else "NO", _camera_mode_name(), _seabed_mode_name(), warp_text]


func _set_camera_mode(mode: int) -> void:
	_camera_mode = clampi(mode, CameraMode.TOP, CameraMode.GRAZING) as CameraMode
	if _camera_mode == CameraMode.TOP:
		_top_camera.make_current()
	else:
		_grazing_camera.make_current()


func _camera_mode_name() -> String:
	return "TOP" if _camera_mode == CameraMode.TOP else "GRAZING"


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
