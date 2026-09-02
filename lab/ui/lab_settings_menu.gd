extends Control

signal close_requested

const SETTINGS_PATH := "user://lab_runtime_settings.cfg"
const SETTINGS_SECTION := "runtime"
const FIXED_RESOLUTIONS := [Vector2i(1280, 800), Vector2i(1280, 720), Vector2i(1600, 900), Vector2i(1920, 1080)]
const MIN_RENDER_SCALE := 0.5
const MAX_RENDER_SCALE := 1.0
const MAX_SHIFT_SPEED := 250.0

@onready var resolution_option: OptionButton = %Resolution
@onready var upscaling_option: OptionButton = %Upscaling
@onready var render_scale_slider: HSlider = %RenderScale
@onready var render_scale_value: Label = %RenderScaleValue
@onready var internal_resolution: Label = %InternalResolution
@onready var sharpness_slider: HSlider = %Sharpness
@onready var sharpness_value: Label = %SharpnessValue
@onready var shift_speed_slider: HSlider = %ShiftSpeed
@onready var shift_speed_value: Label = %ShiftSpeedValue
@onready var slow_speed_slider: HSlider = %SlowSpeed
@onready var slow_speed_value: Label = %SlowSpeedValue
@onready var performance_label: Label = %Performance
@onready var render_scale_label: Label = %RenderScaleLabel
@onready var sharpness_label: Label = %SharpnessLabel
@onready var ocean_overlay_check: CheckButton = %OceanOverlay

var _root_viewport: Viewport
var _free_camera: Camera3D
var _ocean_v3: OceanV3
var _defaults: Dictionary
var _updating := false
var _initialized := false
var _resolution_sizes: Array[Vector2i] = []


func _ready() -> void:
	for control in [resolution_option, upscaling_option, render_scale_slider, sharpness_slider, shift_speed_slider, slow_speed_slider]:
		control.focus_mode = Control.FOCUS_ALL
	$Center/Panel/Margin/VBox/Buttons/Close.grab_focus()
	resolution_option.item_selected.connect(_on_resolution_selected)
	upscaling_option.item_selected.connect(_on_upscaling_selected)
	render_scale_slider.value_changed.connect(_on_render_scale_changed)
	sharpness_slider.value_changed.connect(_on_sharpness_changed)
	shift_speed_slider.value_changed.connect(_on_shift_speed_changed)
	slow_speed_slider.value_changed.connect(_on_slow_speed_changed)
	ocean_overlay_check.toggled.connect(_on_ocean_overlay_toggled)
	$Center/Panel/Margin/VBox/Buttons/Reset.pressed.connect(_reset_to_defaults)
	$Center/Panel/Margin/VBox/Buttons/Close.pressed.connect(func() -> void: close_requested.emit())


func initialize(free_camera: Camera3D, ocean_v3: OceanV3) -> void:
	if _initialized:
		return
	_free_camera = free_camera
	_ocean_v3 = ocean_v3
	_root_viewport = get_tree().root
	_capture_project_defaults()
	_build_resolution_options()
	_apply_user_settings_if_valid()
	_initialized = true


func open_menu() -> void:
	visible = true
	resolution_option.grab_focus()
	_update_performance_label()


func close_menu() -> void:
	visible = false


func _capture_project_defaults() -> void:
	var window_size := get_window().size
	_defaults = {
		"resolution_index": _resolution_index_for_size(window_size),
		"resolution_size": window_size,
		"scaling_mode": _root_viewport.scaling_3d_mode,
		"render_scale": _root_viewport.scaling_3d_scale,
		"fsr_sharpness": _root_viewport.fsr_sharpness,
		"shift_speed": _free_camera.get_sprint_speed_mps(),
		"slow_speed": _free_camera.get_slow_speed_mps(),
		"ocean_overlay_enabled": _ocean_v3.performance_overlay_enabled(),
	}


func _build_resolution_options() -> void:
	_resolution_sizes.clear()
	resolution_option.clear()
	var native_size := _native_screen_size()
	_resolution_sizes.append(native_size)
	resolution_option.add_item("Current / Native Screen (%d x %d)" % [native_size.x, native_size.y])
	for resolution_size in FIXED_RESOLUTIONS:
		_resolution_sizes.append(resolution_size)
		resolution_option.add_item("%d x %d" % [resolution_size.x, resolution_size.y])


func _apply_user_settings_if_valid() -> void:
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) != OK:
		_apply_values(_defaults)
		return
	var values := {
		"resolution_index": int(config.get_value(SETTINGS_SECTION, "resolution_index", -1)),
		"scaling_mode": int(config.get_value(SETTINGS_SECTION, "scaling_mode", -1)),
		"render_scale": float(config.get_value(SETTINGS_SECTION, "render_scale", -1.0)),
		"sharpness_percent": float(config.get_value(SETTINGS_SECTION, "sharpness_percent", -1.0)),
		"shift_speed": float(config.get_value(SETTINGS_SECTION, "shift_speed", -1.0)),
		"slow_speed": float(config.get_value(SETTINGS_SECTION, "slow_speed", -1.0)),
		"ocean_overlay_enabled": bool(config.get_value(SETTINGS_SECTION, "ocean_v3_performance_overlay", _defaults["ocean_overlay_enabled"])),
	}
	if not _valid_user_values(values):
		_apply_values(_defaults)
		return
	_apply_values(values)


func _valid_user_values(values: Dictionary) -> bool:
	var mode: int = values["scaling_mode"]
	return values["resolution_index"] >= 0 and values["resolution_index"] < _resolution_sizes.size() \
		and (mode == Viewport.SCALING_3D_MODE_BILINEAR or mode == Viewport.SCALING_3D_MODE_FSR or mode == Viewport.SCALING_3D_MODE_FSR2) \
		and values["render_scale"] >= MIN_RENDER_SCALE and values["render_scale"] <= MAX_RENDER_SCALE \
		and values["sharpness_percent"] >= 0.0 and values["sharpness_percent"] <= 100.0 \
		and values["shift_speed"] >= _free_camera.movement_speed and values["shift_speed"] <= MAX_SHIFT_SPEED \
		and values["slow_speed"] >= 0.5 and values["slow_speed"] <= _free_camera.movement_speed \
		and typeof(values["ocean_overlay_enabled"]) == TYPE_BOOL


func _apply_values(values: Dictionary) -> void:
	_updating = true
	var resolution_index: int = values["resolution_index"]
	resolution_option.select(resolution_index)
	_apply_resolution(resolution_index, values.get("resolution_size", _resolution_sizes[resolution_index]))
	var mode: int = values["scaling_mode"]
	var scaling_mode := mode as Viewport.Scaling3DMode
	upscaling_option.select(_mode_to_option(scaling_mode))
	_root_viewport.scaling_3d_mode = scaling_mode
	var render_scale := clampf(float(values["render_scale"]), MIN_RENDER_SCALE, MAX_RENDER_SCALE)
	render_scale_slider.value = render_scale * 100.0
	_root_viewport.scaling_3d_scale = 1.0 if mode == Viewport.SCALING_3D_MODE_BILINEAR else render_scale
	var sharpness_percent := _fsr_sharpness_to_percent(float(values["fsr_sharpness"])) if values.has("fsr_sharpness") else float(values["sharpness_percent"])
	sharpness_slider.value = sharpness_percent
	_root_viewport.fsr_sharpness = _percent_to_godot_sharpness(sharpness_percent)
	shift_speed_slider.min_value = _free_camera.movement_speed
	shift_speed_slider.max_value = maxf(MAX_SHIFT_SPEED, _free_camera.movement_speed)
	shift_speed_slider.value = clampf(float(values["shift_speed"]), shift_speed_slider.min_value, shift_speed_slider.max_value)
	slow_speed_slider.max_value = _free_camera.movement_speed
	slow_speed_slider.value = clampf(float(values["slow_speed"]), 0.5, _free_camera.movement_speed)
	_free_camera.set_sprint_speed_mps(shift_speed_slider.value)
	_free_camera.set_slow_speed_mps(slow_speed_slider.value)
	ocean_overlay_check.button_pressed = bool(values["ocean_overlay_enabled"])
	_ocean_v3.set_performance_overlay_enabled(ocean_overlay_check.button_pressed)
	_updating = false
	_update_labels()


func _on_resolution_selected(index: int) -> void:
	if _updating:
		return
	_apply_resolution(index)
	_save_user_settings()


func _apply_resolution(index: int, fallback_size: Variant = null) -> void:
	if index == 0:
		_resolution_sizes[0] = _native_screen_size()
		resolution_option.set_item_text(0, "Current / Native Screen (%d x %d)" % [_resolution_sizes[0].x, _resolution_sizes[0].y])
	var output_size: Vector2i = _resolution_sizes[index]
	if fallback_size is Vector2i:
		output_size = fallback_size
	get_window().size = output_size


func _on_upscaling_selected(index: int) -> void:
	if _updating:
		return
	_root_viewport.scaling_3d_mode = _option_to_mode(index)
	_root_viewport.scaling_3d_scale = 1.0 if index == 0 else render_scale_slider.value / 100.0
	_update_labels()
	_save_user_settings()


func _on_render_scale_changed(value: float) -> void:
	if _updating:
		return
	_root_viewport.scaling_3d_scale = value / 100.0
	_update_labels()
	_save_user_settings()


func _on_sharpness_changed(value: float) -> void:
	if _updating:
		return
	_root_viewport.fsr_sharpness = _percent_to_godot_sharpness(value)
	_update_labels()
	_save_user_settings()


func _on_shift_speed_changed(value: float) -> void:
	if _updating:
		return
	_free_camera.set_sprint_speed_mps(value)
	_update_labels()
	_save_user_settings()


func _on_slow_speed_changed(value: float) -> void:
	if _updating:
		return
	_free_camera.set_slow_speed_mps(value)
	_update_labels()
	_save_user_settings()


func _on_ocean_overlay_toggled(enabled: bool) -> void:
	if _updating:
		return
	_ocean_v3.set_performance_overlay_enabled(enabled)
	_save_user_settings()


func _update_labels() -> void:
	render_scale_value.text = "%d%%" % int(round(render_scale_slider.value))
	sharpness_value.text = "%d%%" % int(round(sharpness_slider.value))
	shift_speed_value.text = "%d m/s" % int(round(shift_speed_slider.value))
	slow_speed_value.text = "%.1f m/s" % slow_speed_slider.value
	var native := upscaling_option.selected == 0
	render_scale_slider.editable = not native
	sharpness_slider.editable = not native
	render_scale_label.modulate.a = 0.45 if native else 1.0
	sharpness_label.modulate.a = 0.45 if native else 1.0
	var output := get_window().size
	var internal_scale := 1.0 if native else render_scale_slider.value / 100.0
	internal_resolution.text = "Output: %d x %d\nInternal 3D: %d x %d" % [output.x, output.y, roundi(output.x * internal_scale), roundi(output.y * internal_scale)]


func _update_performance_label() -> void:
	performance_label.text = "FPS: %d    Frame: %.2f ms" % [Engine.get_frames_per_second(), get_process_delta_time() * 1000.0]


func _process(_delta: float) -> void:
	if visible:
		_update_performance_label()


func _reset_to_defaults() -> void:
	var default_values := _defaults.duplicate()
	_apply_values(default_values)
	var absolute_path := ProjectSettings.globalize_path(SETTINGS_PATH)
	if FileAccess.file_exists(absolute_path):
		DirAccess.remove_absolute(absolute_path)


func _save_user_settings() -> void:
	if _updating:
		return
	var config := ConfigFile.new()
	config.set_value(SETTINGS_SECTION, "resolution_index", resolution_option.selected)
	config.set_value(SETTINGS_SECTION, "scaling_mode", _option_to_mode(upscaling_option.selected))
	config.set_value(SETTINGS_SECTION, "render_scale", render_scale_slider.value / 100.0)
	config.set_value(SETTINGS_SECTION, "sharpness_percent", sharpness_slider.value)
	config.set_value(SETTINGS_SECTION, "shift_speed", shift_speed_slider.value)
	config.set_value(SETTINGS_SECTION, "slow_speed", slow_speed_slider.value)
	config.set_value(SETTINGS_SECTION, "ocean_v3_performance_overlay", _ocean_v3.performance_overlay_enabled())
	config.save(SETTINGS_PATH)


func _native_screen_size() -> Vector2i:
	return DisplayServer.screen_get_size(DisplayServer.window_get_current_screen())


func _resolution_index_for_size(output_size: Vector2i) -> int:
	for index in range(FIXED_RESOLUTIONS.size()):
		if FIXED_RESOLUTIONS[index] == output_size:
			return index + 1
	return 0


func _option_to_mode(index: int) -> Viewport.Scaling3DMode:
	match index:
		1:
			return Viewport.SCALING_3D_MODE_FSR
		2:
			return Viewport.SCALING_3D_MODE_FSR2
		_:
			return Viewport.SCALING_3D_MODE_BILINEAR


func _mode_to_option(mode: Viewport.Scaling3DMode) -> int:
	if mode == Viewport.SCALING_3D_MODE_FSR:
		return 1
	if mode == Viewport.SCALING_3D_MODE_FSR2:
		return 2
	return 0


func _percent_to_godot_sharpness(percent: float) -> float:
	return lerpf(2.0, 0.0, clampf(percent, 0.0, 100.0) / 100.0)


func _fsr_sharpness_to_percent(value: float) -> float:
	return inverse_lerp(2.0, 0.0, clampf(value, 0.0, 2.0)) * 100.0


func _godot_sharpness_to_percent(value: float) -> float:
	return _fsr_sharpness_to_percent(value)
