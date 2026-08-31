extends Node3D
## Isolated A/B harness for the Ocean V3 surface shader.
##
## The OceanV3 instance below is a hidden simulation owner. Its configured
## material is duplicated four times, so all candidates consume the same
## Texture2DRD resources, uniforms, seed and SimulationClock state.

const INTERNAL_VIEWPORT_SIZE := Vector2i(640, 360)
const CANDIDATE_NAMES := [&"BASELINE", &"OPTION A", &"OPTION B", &"OPTION C"]
const CANDIDATE_SHADER_PATHS := [
	"res://ocean_v3/tests/foam_visual_lab/shaders/ocean_surface_baseline.gdshader",
	"res://ocean_v3/tests/foam_visual_lab/shaders/ocean_surface_option_a.gdshader",
	"res://ocean_v3/tests/foam_visual_lab/shaders/ocean_surface_option_b.gdshader",
	"res://ocean_v3/tests/foam_visual_lab/shaders/ocean_surface_option_c.gdshader",
]
const SIMULATION_SEED := 20260820

const MeshBuilder := preload("res://ocean_v3/rendering/ocean_clipmap_mesh_builder.gd")
const ClipmapConfigScript := preload("res://ocean_v3/rendering/ocean_clipmap_config.gd")

@onready var _ocean: OceanV3 = $OceanV3
@onready var _simulation_camera: Camera3D = $SimulationCamera
@onready var _grid: GridContainer = $UI/Grid
@onready var _fullscreen_host: Control = $UI/FullscreenHost
@onready var _mode_label: Label = $UI/ModeLabel
@onready var _time_label: Label = $UI/TimeLabel
@onready var _help_label: Label = $UI/HelpLabel
@onready var _fullscreen_label: Label = $UI/FullscreenLabel

var _clock: Node
var _source_material: ShaderMaterial
var _candidate_materials: Array[ShaderMaterial] = []
var _candidate_viewports: Array[SubViewport] = []
var _candidate_containers: Array[SubViewportContainer] = []
var _pane_wrappers: Array[VBoxContainer] = []
var _uniform_names: Array[StringName] = []
var _test_mesh: ArrayMesh
var _lab_ready := false
var _initializing := false
var _mode := &"GRID"
var _selected_candidate := 1
var _fullscreen_baseline := true


func _ready() -> void:
	_clock = get_node_or_null(^"/root/SimulationClock")
	if _clock != null:
		_clock.set_seed(SIMULATION_SEED)
		_clock.time_scale = 1.0
		_clock.resume()
		_clock.reset_simulation(true)
	_configure_simulation_camera()
	var simulation_surface := _ocean.get_node_or_null(^"OpenOceanFFT/OceanClipmapSurface") as OceanClipmapSurface
	if simulation_surface != null:
		simulation_surface.set_tracking_camera(_simulation_camera)
	_build_test_mesh()
	_show_grid()
	_initializing = true
	call_deferred(&"_wait_for_shared_ocean")


func _process(_delta: float) -> void:
	if _lab_ready:
		_sync_candidate_materials()
	_update_hud()


func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	var key := event as InputEventKey
	match key.keycode:
		KEY_G:
			_show_grid()
		KEY_F:
			_show_fullscreen(false)
		KEY_P:
			_show_fullscreen(true)
		KEY_SPACE:
			if _mode == &"FULLSCREEN":
				_fullscreen_baseline = not _fullscreen_baseline
				_update_fullscreen_text()
		KEY_0:
			if _mode == &"PERF":
				_selected_candidate = 0
				_show_fullscreen(true)
		KEY_1:
			_select_candidate(1)
		KEY_2:
			_select_candidate(2)
		KEY_3:
			_select_candidate(3)
		KEY_F5:
			_toggle_freeze()


func _select_candidate(index: int) -> void:
	_selected_candidate = clampi(index, 1, 3)
	if _mode == &"PERF":
		_show_fullscreen(true)
	elif _mode == &"FULLSCREEN":
		_show_fullscreen(false)
	_update_fullscreen_text()


func _toggle_freeze() -> void:
	if _clock == null:
		return
	_clock.set_paused(not _clock.is_paused())
	_update_hud()


func _configure_simulation_camera() -> void:
	_simulation_camera.global_position = Vector3(0.0, 6.5, 18.0)
	_simulation_camera.fov = 62.0
	_simulation_camera.near = 0.1
	_simulation_camera.far = 500.0
	_simulation_camera.look_at(Vector3(0.0, 0.0, 0.0), Vector3.UP)
	_simulation_camera.make_current()


func _build_test_mesh() -> void:
	# 128x128 cells over 16x16 metres: enough samples for vertex displacement,
	# while staying deliberately smaller than the production clipmap.
	var config := ClipmapConfigScript.new()
	config.cells_per_side = 128
	config.base_spacing_m = 0.125
	config.level_count = 1
	config.sea_level_y = 0.0
	var geometry: Dictionary = MeshBuilder.build_level_geometry(config, 0)
	_test_mesh = MeshBuilder.create_mesh(geometry)


func _wait_for_shared_ocean() -> void:
	var module := _ocean.get_node_or_null(^"OpenOceanFFT")
	var waited := 0
	while is_inside_tree() and (module == null or not _ocean_ready(module)) and waited < 900:
		await get_tree().process_frame
		waited += 1
		module = _ocean.get_node_or_null(^"OpenOceanFFT")
	if not is_inside_tree() or not _ocean_ready(module):
		_initializing = false
		push_error("FoamVisualLab: shared OceanV3 did not become ready.")
		return
	_source_material = _ocean.get_node(^"OpenOceanFFT/OceanClipmapSurface").get_surface_material()
	if _source_material == null or _source_material.shader == null:
		_initializing = false
		push_error("FoamVisualLab: OceanV3 surface material has no shader.")
		return
	_build_candidate_materials()
	_build_candidate_viewports()
	_lab_ready = true
	_initializing = false
	_sync_candidate_materials()
	_update_hud()
	print("FOAM VISUAL LAB: ready; shared OceanV3 simulation; seed=%d; mesh=16m/128 cells" % SIMULATION_SEED)


func _ocean_ready(module: Node) -> bool:
	if module == null or not is_instance_valid(module):
		return false
	var surface := module.get_node_or_null(^"OceanClipmapSurface") as OceanClipmapSurface
	if surface == null:
		return false
	# The surface material is configured synchronously by OpenOceanFFT. Individual
	# GPU fields may finish publishing later and are mirrored every frame.
	return surface.get_surface_material() != null and surface.get_surface_material().shader != null


func _build_candidate_materials() -> void:
	_candidate_materials.clear()
	_uniform_names.clear()
	for uniform_info in _source_material.shader.get_shader_uniform_list():
		var uniform_name := StringName(String(uniform_info.get("name", "")))
		if not String(uniform_name).is_empty() and uniform_name not in [&"screen_texture", &"depth_texture"]:
			_uniform_names.append(uniform_name)
	for index in CANDIDATE_SHADER_PATHS.size():
		var material := _source_material.duplicate() as ShaderMaterial
		material.shader = load(CANDIDATE_SHADER_PATHS[index]) as Shader
		material.resource_name = "FoamVisualLab_%s" % CANDIDATE_NAMES[index]
		_candidate_materials.append(material)


func _build_candidate_viewports() -> void:
	_candidate_viewports.clear()
	_candidate_containers.clear()
	_pane_wrappers.clear()
	for index in CANDIDATE_NAMES.size():
		var wrapper := VBoxContainer.new()
		wrapper.name = "Pane_%s" % CANDIDATE_NAMES[index].to_pascal_case()
		wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		wrapper.size_flags_vertical = Control.SIZE_EXPAND_FILL
		var label := Label.new()
		label.text = "%s   [%d]" % [CANDIDATE_NAMES[index], index]
		label.add_theme_font_size_override(&"font_size", 16)
		label.add_theme_color_override(&"font_color", Color(0.75, 0.93, 1.0, 1.0))
		wrapper.add_child(label)
		var container := _make_candidate_container(index)
		wrapper.add_child(container)
		_grid.add_child(wrapper)
		_pane_wrappers.append(wrapper)
		_candidate_containers.append(container)


func _make_candidate_container(index: int) -> SubViewportContainer:
	var container := SubViewportContainer.new()
	container.name = "Viewport_%s" % CANDIDATE_NAMES[index].to_pascal_case()
	container.custom_minimum_size = Vector2(INTERNAL_VIEWPORT_SIZE)
	container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	container.stretch = true
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var viewport := SubViewport.new()
	viewport.name = "RenderViewport"
	viewport.size = INTERNAL_VIEWPORT_SIZE
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.handle_input_locally = false
	viewport.transparent_bg = false
	var world := World3D.new()
	var source_environment := ($WorldEnvironment as WorldEnvironment).environment
	world.environment = source_environment.duplicate() as Environment
	viewport.world_3d = world
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-42.0, -28.0, 0.0)
	light.light_color = Color(1.0, 0.94, 0.84, 1.0)
	light.light_energy = 1.2
	light.shadow_enabled = false
	viewport.add_child(light)
	var camera := Camera3D.new()
	camera.name = "Camera"
	camera.position = Vector3(0.0, 6.5, 18.0)
	camera.fov = 62.0
	camera.near = 0.1
	camera.far = 500.0
	viewport.add_child(camera)
	camera.look_at_from_position(Vector3(0.0, 6.5, 18.0), Vector3.ZERO, Vector3.UP)
	camera.current = true
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "SharedGeometry"
	mesh_instance.mesh = _test_mesh
	mesh_instance.material_override = _candidate_materials[index]
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh_instance.position = Vector3.ZERO
	viewport.add_child(mesh_instance)
	container.add_child(viewport)
	_candidate_viewports.append(viewport)
	return container


func _sync_candidate_materials() -> void:
	if _source_material == null:
		return
	var camera_xz := Vector2(0.0, 18.0)
	var render_time := float(_clock.get_render_time()) if _clock != null else 0.0
	# This is intentionally a lab-only material-state mirror. It keeps dynamic
	# breaker/coastal/reflection uniforms identical without touching production.
	for material in _candidate_materials:
		for uniform_name in _uniform_names:
			var value = _source_material.get_shader_parameter(uniform_name)
			if value != null:
				material.set_shader_parameter(uniform_name, value)
		material.set_shader_parameter(&"camera_world_xz", camera_xz)
		material.set_shader_parameter(&"coastal_time_s", render_time)


func _show_grid() -> void:
	_mode = &"GRID"
	_fullscreen_host.visible = false
	_grid.visible = true
	for index in _candidate_containers.size():
		_reparent_to_grid(index)
		_candidate_viewports[index].render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_update_fullscreen_text()
	_update_hud()


func _show_fullscreen(perf_mode: bool) -> void:
	_mode = &"PERF" if perf_mode else &"FULLSCREEN"
	_grid.visible = false
	_fullscreen_host.visible = true
	var active_index := _selected_candidate if perf_mode else (_selected_candidate if not _fullscreen_baseline else 0)
	for index in _candidate_containers.size():
		_candidate_viewports[index].render_target_update_mode = SubViewport.UPDATE_ALWAYS if index == active_index else SubViewport.UPDATE_DISABLED
		if index == active_index:
			_reparent_to_fullscreen(index)
		else:
			_reparent_to_grid(index)
	_update_fullscreen_text()
	_update_hud()


func _reparent_to_fullscreen(index: int) -> void:
	var container := _candidate_containers[index]
	if container.get_parent() != _fullscreen_host:
		if container.get_parent() != null:
			container.get_parent().remove_child(container)
		_fullscreen_host.add_child(container)
	container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _reparent_to_grid(index: int) -> void:
	var container := _candidate_containers[index]
	var wrapper := _pane_wrappers[index]
	if container.get_parent() != wrapper:
		if container.get_parent() != null:
			container.get_parent().remove_child(container)
		wrapper.add_child(container)
	container.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)


func _update_fullscreen_text() -> void:
	if _mode == &"GRID":
		_fullscreen_label.text = ""
		return
	if _mode == &"PERF":
		_fullscreen_label.text = "PERF MODE — %s only | 0 BASELINE | 1/2/3 candidate | G grid" % CANDIDATE_NAMES[_selected_candidate]
	else:
		var shown := "BASELINE" if _fullscreen_baseline else String(CANDIDATE_NAMES[_selected_candidate])
		_fullscreen_label.text = "FULLSCREEN A/B — %s | SPACE baseline/candidate | 1/2/3 select | P perf | G grid" % shown


func _update_hud() -> void:
	var time_value := float(_clock.get_render_time()) if _clock != null else 0.0
	var frozen: bool = _clock != null and _clock.is_paused()
	var mode_text := "FOAM VISUAL LAB  |  %s" % _mode
	if _mode == &"PERF":
		var fps := Engine.get_frames_per_second()
		var frame_ms := 1000.0 / float(fps) if fps > 0 else 0.0
		var cpu_process_ms := float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0
		mode_text += "  |  ACTIVE: %s  |  FPS: %d  |  FRAME: %.2f ms  |  CPU: %.2f ms  |  GPU: unavailable" % [CANDIDATE_NAMES[_selected_candidate], fps, frame_ms, cpu_process_ms]
	_mode_label.text = mode_text
	_time_label.text = "TIME: %.3f s   %s" % [time_value, "FROZEN" if frozen else "PLAY"]
	_help_label.text = "F5 freeze/play   F fullscreen A/B   SPACE toggle baseline/candidate   P perf   G grid   1/2/3 candidate   0 baseline perf"
