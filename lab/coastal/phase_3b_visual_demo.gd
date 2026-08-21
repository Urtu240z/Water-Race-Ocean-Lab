extends Node3D
## Demo de inspección manual de Fase 3B. Sólo construye BathymetryData de Lab
## y conecta los controles al transform ya existente: no introduce física.

const BathymetryDataScript := preload("res://ocean_v3/bathymetry/bathymetry_data.gd")

const _GRID_WIDTH := 257
const _GRID_HEIGHT := 129
const _CELL_SIZE_M := 1.0
const _ORIGIN_XZ := Vector2(-128.0, -64.0)
const _DEBUG_FIELDS := [0, 1, 2, 5, 6] # NORMAL, depth, lambda, shoaling, phase.
const _DEBUG_FIELD_NAMES := ["NORMAL", "DEPTH", "WAVELENGTH", "SHOALING", "PHASE_OFFSET"]

@onready var _ocean = $OceanV3/OpenOceanFFT
@onready var _seabed_debug: MeshInstance3D = $SeabedDebug
@onready var _status: Label = %Status
@onready var _camera: Camera3D = $Camera3D

var _bathymetry = null
var _debug_field_index := 0
var _coastal_enabled := true
var _monochromatic_enabled := true


func _ready() -> void:
	_camera.look_at(Vector3(0.0, 0.0, 0.0), Vector3.UP)
	_bathymetry = _build_bank_bathymetry()
	_build_seabed_debug(_bathymetry)
	_apply_coastal_settings()
	_update_status()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_C:
			_coastal_enabled = not _coastal_enabled
			_apply_coastal_settings()
		KEY_K:
			_monochromatic_enabled = not _monochromatic_enabled
			_apply_coastal_settings()
		KEY_J:
			_seabed_debug.visible = not _seabed_debug.visible
		KEY_H:
			_debug_field_index = (_debug_field_index + 1) % _DEBUG_FIELDS.size()
			_ocean.set_coastal_debug_field(_DEBUG_FIELDS[_debug_field_index])
	_update_status()


func _apply_coastal_settings() -> void:
	_ocean.coastal_bathymetry_data = _bathymetry
	_ocean.coastal_propagation_enabled = _coastal_enabled
	_ocean.coastal_incoming_direction_xz = Vector2.RIGHT
	_ocean.coastal_reference_wavelength_m = 16.0
	_ocean.coastal_monochromatic_debug = _monochromatic_enabled
	_ocean.coastal_monochromatic_amplitude_m = 0.45
	_ocean.rebuild_coastal_propagation()
	_ocean.set_coastal_debug_field(_DEBUG_FIELDS[_debug_field_index])


func _update_status() -> void:
	_status.text = "PHASE 3B — FINITE-DEPTH VISUAL DEMO\nC  Coastal: %s\nK  Mode: %s\nJ  Seabed debug: %s\nH  Field: %s\nlambda ref = 16 m\n\nIncoming direction: +X\nDeep  ->  submerged bank  ->  deep" % ["ON" if _coastal_enabled else "OFF", "MONO" if _monochromatic_enabled else "FFT", "ON" if _seabed_debug.visible else "OFF", _DEBUG_FIELD_NAMES[_debug_field_index]]


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
	# Banco suave, ancho en la dirección visible, h=0.5 m en su cresta.
	var bank_weight := exp(-(world_x * world_x / 900.0 + world_z * world_z / 1800.0))
	return 18.0 - 17.5 * bank_weight


func _build_seabed_debug(data) -> void:
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for z in data.height - 1:
		for x in data.width - 1:
			_add_floor_triangle(tool, data, x, z, x + 1, z, x + 1, z + 1)
			_add_floor_triangle(tool, data, x, z, x + 1, z + 1, x, z + 1)
	_seabed_debug.mesh = tool.commit()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_seabed_debug.material_override = material


func _add_floor_triangle(tool: SurfaceTool, data, ax: int, az: int, bx: int, bz: int, cx: int, cz: int) -> void:
	_add_floor_vertex(tool, data, ax, az)
	_add_floor_vertex(tool, data, bx, bz)
	_add_floor_vertex(tool, data, cx, cz)


func _add_floor_vertex(tool: SurfaceTool, data, x: int, z: int) -> void:
	var index: int = z * data.width + x
	var world_xz: Vector2 = data.world_origin_xz + Vector2(float(x), float(z)) * data.cell_size_m
	var shallow: float = 1.0 - clampf(data.depth_m[index] / 18.0, 0.0, 1.0)
	tool.set_color(Color(lerpf(0.03, 0.9, shallow), lerpf(0.15, 0.38, shallow), lerpf(0.22, 0.05, shallow), 0.45))
	tool.add_vertex(Vector3(world_xz.x, -data.depth_m[index], world_xz.y))
