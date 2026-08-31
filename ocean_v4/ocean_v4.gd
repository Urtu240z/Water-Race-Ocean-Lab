class_name OceanV4
extends Node3D
## Phase 0 owner: deterministic LONG/MID/SHORT open-ocean waves and base surface.

const FFT := preload("res://ocean_v4/simulation/open_ocean_fft_v4.gd")

@export_category("Simulation")
@export var simulation_seed := 20260820
@export_range(0.0, 60.0, 0.1) var global_wind_speed_mps := 18.0
@export var simulation_time_s := 0.0
@export var advance_time := true
@export_enum("FULL", "LONG", "MID", "SHORT") var debug_band := 0

@export_category("LONG")
@export var long_target_hs_m := 2.5
@export var long_choppiness := 2.0
@export var long_direction := Vector2(1.0, 0.1)
@export var long_spread := 5.0

@export_category("MID")
@export var mid_target_hs_m := 0.6
@export var mid_choppiness := 1.25
@export var mid_direction := Vector2(1.0, 0.38)
@export var mid_spread := 3.5

@export_category("SHORT")
@export var short_target_hs_m := 0.12
@export var short_choppiness := 0.4
@export var short_direction := Vector2(1.0, 0.62)
@export var short_spread := 3.0

@onready var open_ocean_fft: OpenOceanFFTV4 = $OpenOceanFFT
@onready var clipmap_surface: OceanClipmapSurfaceV4 = $OceanClipmapSurface

var _physics_frames := 0


func _ready() -> void:
	open_ocean_fft.configure(_bands(), simulation_seed)
	open_ocean_fft.publish_textures()
	clipmap_surface.debug_band = debug_band
	clipmap_surface.configure(open_ocean_fft.configs, open_ocean_fft.displacement_textures(), open_ocean_fft.normal_textures())
	clipmap_surface.set_tracking_camera(_find_lab_camera())
	print("OceanV4 simulation time startup: %.3f s" % simulation_time_s)


func _physics_process(_delta: float) -> void:
	if advance_time:
		simulation_time_s += 1.0 / float(Engine.physics_ticks_per_second)
	_physics_frames += 1
	if _physics_frames == 120:
		print("OceanV4 simulation time after 120 physics frames: %.3f s" % simulation_time_s)


func _process(_delta: float) -> void:
	if open_ocean_fft.publish_textures():
		clipmap_surface.bind_fft_textures(open_ocean_fft.configs, open_ocean_fft.displacement_textures(), open_ocean_fft.normal_textures())
	open_ocean_fft.advance(simulation_time_s)


func reset_simulation(next_seed := simulation_seed) -> void:
	simulation_seed = next_seed
	simulation_time_s = 0.0
	_physics_frames = 0
	open_ocean_fft.configure(_bands(), simulation_seed)
	open_ocean_fft.publish_textures()
	clipmap_surface.debug_band = debug_band
	clipmap_surface.configure(open_ocean_fft.configs, open_ocean_fft.displacement_textures(), open_ocean_fft.normal_textures())


func cycle_debug_band() -> void:
	debug_band = (debug_band + 1) % 4
	clipmap_surface.set_debug_band(debug_band)
	print("OceanV4 debug band: %s" % ["FULL", "LONG", "MID", "SHORT"][debug_band])


func _bands() -> Array[Dictionary]:
	return [
		_band(long_target_hs_m, long_choppiness, long_direction, long_spread, 25000.0, 0.8, 0.05, 16.0, 128.0, 4.0, 0.35),
		_band(mid_target_hs_m, mid_choppiness, mid_direction, mid_spread, 3000.0, 0.45, 0.35, 4.0, 20.0, 0.75, 0.35),
		_band(short_target_hs_m, short_choppiness, short_direction, short_spread, 300.0, 0.15, 0.75, 0.5, 5.0, 0.15, 0.2),
	]


func _band(target_hs_m: float, choppiness: float, direction: Vector2, directional_spread: float, fetch_length_m: float, swell: float, jonswap_spread: float, min_wavelength_m: float, max_wavelength_m: float, transition_width_m: float, short_wave_damping_m: float) -> Dictionary:
	return {
		"wind_speed_mps": global_wind_speed_mps, "target_hs_m": target_hs_m,
		"choppiness": choppiness, "direction": direction,
		"directional_spread": directional_spread, "fetch_length_m": fetch_length_m,
		"swell": swell, "jonswap_spread": jonswap_spread,
		"min_wavelength_m": min_wavelength_m, "max_wavelength_m": max_wavelength_m,
		"transition_width_m": transition_width_m, "short_wave_damping_m": short_wave_damping_m,
	}


func _find_lab_camera() -> Camera3D:
	var cameras := get_tree().get_nodes_in_group(&"lab_camera")
	return cameras[0] as Camera3D if not cameras.is_empty() else get_viewport().get_camera_3d()
