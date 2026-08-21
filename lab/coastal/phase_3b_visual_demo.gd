extends Node3D
## Demo de inspección manual de Fase 3B. Sólo construye BathymetryData de Lab
## y conecta los controles al transform ya existente: no introduce física.

const BathymetryDataScript := preload("res://ocean_v3/bathymetry/bathymetry_data.gd")

const _GRID_WIDTH := 257
const _GRID_HEIGHT := 129
const _CELL_SIZE_M := 1.0
const _ORIGIN_XZ := Vector2(-128.0, -64.0)
const _DEBUG_FIELDS := [0, 1, 2, 5, 6, 7, 8]
const _DEBUG_FIELD_NAMES := ["NORMAL", "DEPTH", "WAVELENGTH", "SHOALING", "PHASE_OFFSET", "LOCAL_K", "VALID / SHADOW"]

enum SeabedMode { HIDDEN, ACTUAL_DEPTH, OVERLAY }
enum CameraMode { TOP, GRAZING }

@onready var _ocean = $OceanV3/OpenOceanFFT
@onready var _seabed_actual: MeshInstance3D = $SeabedActualDebug
@onready var _seabed_overlay: MeshInstance3D = $SeabedOverlayDebug
@onready var _bank_crest_marker: MeshInstance3D = $BankCrestMarker
@onready var _bank_guides: Node3D = $BankGuides
@onready var _wavelength_ruler: MeshInstance3D = $WavelengthRuler
@onready var _direction_arrows: MeshInstance3D = $DirectionArrows
@onready var _status: Label = %Status
@onready var _top_camera: Camera3D = $TopCamera
@onready var _grazing_camera: Camera3D = $GrazingCamera

var _bathymetry = null
var _debug_field_index := 0
var _seabed_mode := SeabedMode.HIDDEN
var _camera_mode := CameraMode.TOP
var _coastal_enabled := true
var _monochromatic_enabled := true
var _refraction_enabled := false


func _ready() -> void:
	# TOP looks vertically down, so it needs a horizontal reference up vector.
	_top_camera.look_at(Vector3(0.0, 0.0, 0.0), Vector3.FORWARD)
	_grazing_camera.look_at(Vector3(0.0, 0.0, 0.0), Vector3.UP)
	_bathymetry = _build_bank_bathymetry()
	_build_seabed_debugs(_bathymetry)
	_build_bank_guides()
	_build_wavelength_ruler()
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
		KEY_K:
			_monochromatic_enabled = not _monochromatic_enabled
			_apply_coastal_settings()
		KEY_J:
			_set_seabed_mode((_seabed_mode + 1) % (SeabedMode.OVERLAY + 1))
		KEY_H:
			_debug_field_index = (_debug_field_index + 1) % _DEBUG_FIELDS.size()
			_ocean.set_coastal_debug_field(_DEBUG_FIELDS[_debug_field_index])
		KEY_V:
			_set_camera_mode((_camera_mode + 1) % (CameraMode.GRAZING + 1))
		KEY_P:
			SimulationClock.toggle_paused()
		KEY_R:
			_refraction_enabled = not _refraction_enabled
			_apply_coastal_settings()
	_update_status()


func _apply_coastal_settings() -> void:
	_ocean.coastal_bathymetry_data = _bathymetry
	_ocean.coastal_propagation_enabled = _coastal_enabled
	_ocean.coastal_incoming_direction_xz = Vector2.RIGHT
	_ocean.coastal_reference_wavelength_m = 16.0
	_ocean.coastal_monochromatic_debug = _monochromatic_enabled
	# Ganancia de un instrumento visual; no afecta CoastalPropagationData.
	_ocean.coastal_monochromatic_amplitude_m = 0.75
	_ocean.coastal_eikonal_refraction_debug = _refraction_enabled
	_ocean.rebuild_coastal_propagation()
	_ocean.set_coastal_debug_field(_DEBUG_FIELDS[_debug_field_index])
	_build_direction_arrows()


func _update_status() -> void:
	var mode_name := "MONO PHASE DEBUG" if _monochromatic_enabled else "FFT"
	var probe_text := _probe_text()
	_status.text = "PHASE 3B / 3B.1 — COASTAL VISUAL DEMO\nC  Coastal: %s\nK  Mode: %s\nR  Propagation: %s\nV  Camera: %s\nP  Paused: %s\nJ  Seabed: %s\nH  Field: %s\nlambda deep: 16.0 m | bank min depth: 0.5 m\nRuler: 16 m ticks | Incoming: +X\n\n%s" % ["ON" if _coastal_enabled else "OFF", mode_name, "REFRACTED 3B.1" if _refraction_enabled else "STRAIGHT 3B", _camera_mode_name(), "YES" if SimulationClock.is_paused() else "NO", _seabed_mode_name(), _DEBUG_FIELD_NAMES[_debug_field_index], probe_text]


func _set_camera_mode(mode: int) -> void:
	_camera_mode = clampi(mode, CameraMode.TOP, CameraMode.GRAZING) as CameraMode
	if _camera_mode == CameraMode.TOP:
		_top_camera.make_current()
	else:
		_grazing_camera.make_current()


func _camera_mode_name() -> String:
	return "TOP" if _camera_mode == CameraMode.TOP else "GRAZING"


func _probe_text() -> String:
	var propagation = _ocean.coastal_propagation_data()
	if propagation == null:
		return "Probes: esperando CoastalPropagationData"
	var upstream = propagation.sample_propagation(Vector2(-90.0, 0.0))
	var crest = propagation.sample_propagation(Vector2.ZERO)
	var downstream = propagation.sample_propagation(Vector2(90.0, 0.0))
	return "UPSTREAM   lambda %.2f m\nBANK CREST lambda %.2f m\nDOWNSTREAM lambda %.2f m | phase offset %.3f rad" % [upstream.wavelength_m, crest.wavelength_m, downstream.wavelength_m, downstream.phase_offset_rad]


func _set_seabed_mode(mode: int) -> void:
	_seabed_mode = clampi(mode, SeabedMode.HIDDEN, SeabedMode.OVERLAY) as SeabedMode
	_seabed_actual.visible = _seabed_mode == SeabedMode.ACTUAL_DEPTH
	_seabed_overlay.visible = _seabed_mode == SeabedMode.OVERLAY
	_bank_crest_marker.visible = _seabed_mode == SeabedMode.OVERLAY


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
	# Banco suave, ancho en la dirección visible, h=0.5 m en su cresta.
	var bank_weight := exp(-(world_x * world_x / 900.0 + world_z * world_z / 1800.0))
	return 18.0 - 17.5 * bank_weight


func _build_seabed_debugs(data) -> void:
	_seabed_actual.mesh = _build_seabed_mesh(data, false)
	_seabed_overlay.mesh = _build_seabed_mesh(data, true)
	_seabed_actual.material_override = _make_seabed_material(false)
	_seabed_overlay.material_override = _make_seabed_material(true)
	_build_crest_marker()


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
	# Overlay es una herramienta de lectura: se dibuja por encima del agua,
	# sin alterar profundidad ni render del océano.
	material.no_depth_test = overlay
	material.render_priority = 127 if overlay else 0
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material


func _build_crest_marker() -> void:
	# Anillo, no disco: marca la cresta sin ocultar las olas mono/FFT.
	var crest := TorusMesh.new()
	crest.inner_radius = 10.5
	crest.outer_radius = 11.0
	crest.rings = 48
	crest.ring_segments = 12
	_bank_crest_marker.mesh = crest
	_bank_crest_marker.position = Vector3(0.0, 0.145, 0.0)
	_bank_crest_marker.scale = Vector3(1.0, 1.0, 1.35)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(1.0, 0.92, 0.12, 0.82)
	material.emission_enabled = true
	material.emission = Color(1.0, 0.48, 0.02, 1.0)
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = true
	material.render_priority = 127
	_bank_crest_marker.material_override = material


func _build_bank_guides() -> void:
	for guide in _bank_guides.get_children():
		guide.queue_free()
	_add_bank_guide("BANK START", -36.0, Color(0.3, 0.9, 1.0, 1.0))
	_add_bank_guide("BANK CREST", 0.0, Color(1.0, 0.9, 0.15, 1.0))
	_add_bank_guide("BANK END", 36.0, Color(0.3, 0.9, 1.0, 1.0))


func _add_bank_guide(label_text: String, world_x: float, color: Color) -> void:
	var guide := MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 0.18
	cylinder.bottom_radius = 0.18
	cylinder.height = 8.0
	guide.mesh = cylinder
	guide.position = Vector3(world_x, 4.0, -62.0)
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.no_depth_test = true
	material.render_priority = 126
	guide.material_override = material
	_bank_guides.add_child(guide)
	var text := Label3D.new()
	text.text = label_text
	text.font_size = 42
	text.outline_size = 6
	text.modulate = color
	text.position = Vector3(world_x, 8.6, -62.0)
	text.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	text.no_depth_test = true
	_bank_guides.add_child(text)


func _build_wavelength_ruler() -> void:
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_LINES)
	for world_x in range(-112, 113, 16):
		tool.set_color(Color(0.8, 0.95, 1.0, 0.9))
		tool.add_vertex(Vector3(float(world_x), 0.14, 60.0))
		tool.add_vertex(Vector3(float(world_x), 2.1, 60.0))
	_wavelength_ruler.mesh = tool.commit()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = true
	material.render_priority = 126
	_wavelength_ruler.material_override = material


func _build_direction_arrows() -> void:
	var propagation = _ocean.coastal_propagation_data()
	_direction_arrows.mesh = null
	_direction_arrows.visible = _refraction_enabled
	if propagation == null or not _refraction_enabled:
		return
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_LINES)
	for world_z in range(-42, 43, 14):
		for world_x in range(-84, 85, 14):
			var sample = propagation.sample_propagation(Vector2(float(world_x), float(world_z)))
			if not sample.valid:
				continue
			var origin := Vector3(float(world_x), 1.35, float(world_z))
			var tip := origin + Vector3(sample.local_direction_xz.x, 0.0, sample.local_direction_xz.y) * 4.5
			tool.set_color(Color(0.25, 1.0, 0.92, 0.85))
			tool.add_vertex(origin)
			tool.add_vertex(tip)
	_direction_arrows.mesh = tool.commit()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = true
	material.render_priority = 125
	_direction_arrows.material_override = material


func _add_floor_triangle(tool: SurfaceTool, data, overlay: bool, ax: int, az: int, bx: int, bz: int, cx: int, cz: int) -> void:
	_add_floor_vertex(tool, data, overlay, ax, az)
	_add_floor_vertex(tool, data, overlay, bx, bz)
	_add_floor_vertex(tool, data, overlay, cx, cz)


func _add_floor_vertex(tool: SurfaceTool, data, overlay: bool, x: int, z: int) -> void:
	var index: int = z * data.width + x
	var world_xz: Vector2 = data.world_origin_xz + Vector2(float(x), float(z)) * data.cell_size_m
	var shallow: float = 1.0 - clampf(data.depth_m[index] / 18.0, 0.0, 1.0)
	# Azul oscuro = profundo; naranja/amarillo = banco somero.
	tool.set_color(Color(lerpf(0.02, 1.0, shallow), lerpf(0.10, 0.52, shallow), lerpf(0.30, 0.03, shallow), 0.55 if overlay else 0.45))
	var height: float = data.sea_level_y + 0.10 if overlay else -data.depth_m[index]
	tool.add_vertex(Vector3(world_xz.x, height, world_xz.y))
