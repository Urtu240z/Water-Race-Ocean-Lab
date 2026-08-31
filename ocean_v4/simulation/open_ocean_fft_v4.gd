class_name OpenOceanFFTV4
extends Node3D
## Owns three physical V4 bands. LONG is rendered as coastal + remainder.

const Config := preload("res://ocean_v4/simulation/open_ocean_fft_config_v4.gd")
const Spectrum := preload("res://ocean_v3/core/tessendorf_spectrum.gd")
const Solver := preload("res://ocean_v4/simulation/gpu_stockham_fft_v4.gd")

var configs: Array[OpenOceanFFTConfigV4] = []
var _cascades: Array[Dictionary] = []
var _textures_published := false


func configure(bands: Array[Dictionary], simulation_seed: int) -> void:
	_release()
	configs = _make_configs(bands)
	var long_h0 := Spectrum.build_h0_rgba32f(configs[0], Spectrum.derive_cascade_seed(simulation_seed, configs[0].id))
	var split: Dictionary = Spectrum.split_h0_rgba32f(configs[0], long_h0, 20.0, 35.0)
	_append_cascade(configs[0], split["coastal"], "LONG_COASTAL")
	_append_cascade(configs[0], split["remainder"], "LONG_REMAINDER")
	for index in range(1, configs.size()):
		var config := configs[index]
		_append_cascade(config, Spectrum.build_h0_rgba32f(config, Spectrum.derive_cascade_seed(simulation_seed, config.id)), config.id)


func publish_textures() -> bool:
	var all_ready := not _cascades.is_empty()
	for cascade in _cascades:
		var solver: GPUStockhamFFTV4 = cascade.solver
		all_ready = all_ready and solver.ready
		if not solver.ready:
			continue
		cascade.displacement.texture_rd_rid = solver.displacement_rid
		cascade.normal.texture_rd_rid = solver.normal_rid
	if all_ready and not _textures_published:
		_textures_published = true
		print("OceanV4 FFT textures published: LONG_COASTAL/LONG_REMAINDER/MID/SHORT Texture2DRD RIDs are valid.")
		return true
	return false


func advance(simulation_time_s: float) -> void:
	for cascade in _cascades:
		var solver: GPUStockhamFFTV4 = cascade.solver
		if solver.ready:
			RenderingServer.call_on_render_thread(solver.dispatch.bind(simulation_time_s))


func displacement_textures() -> Array[Texture2DRD]:
	var result: Array[Texture2DRD] = []
	for cascade in _cascades: result.append(cascade.displacement)
	return result


func normal_textures() -> Array[Texture2DRD]:
	var result: Array[Texture2DRD] = []
	for cascade in _cascades: result.append(cascade.normal)
	return result


func _append_cascade(config: OpenOceanFFTConfigV4, h0: PackedByteArray, render_id: String) -> void:
	_print_h0_diagnostic(render_id, h0)
	var solver := Solver.new()
	var displacement := Texture2DRD.new()
	var normal := Texture2DRD.new()
	RenderingServer.call_on_render_thread(solver.initialize.bind(config, h0, "OceanV4.%s" % render_id))
	_cascades.append({"solver": solver, "displacement": displacement, "normal": normal})


func _exit_tree() -> void:
	_release()


func _release() -> void:
	_textures_published = false
	for cascade in _cascades:
		cascade.displacement.texture_rd_rid = RID()
		cascade.normal.texture_rd_rid = RID()
		RenderingServer.call_on_render_thread(cascade.solver.free_resources)
	_cascades.clear()


func _make_configs(bands: Array[Dictionary]) -> Array[OpenOceanFFTConfigV4]:
	var result: Array[OpenOceanFFTConfigV4] = []
	for index in bands.size():
		var band := bands[index]
		var config: OpenOceanFFTConfigV4 = Config.new()
		config.id = ["LONG", "MID", "SHORT"][index]
		config.spectrum_model = OpenOceanFFTConfig.SpectrumModel.JONSWAP_HASSELMANN
		config.resolution = 256
		config.domain_size_m = [512.0, 137.0, 37.0][index]
		config.wind_speed_mps = band.wind_speed_mps
		config.wind_direction = band.direction.normalized()
		config.target_hs_m = band.target_hs_m
		config.choppiness = band.choppiness
		config.directional_spread = band.directional_spread
		config.fetch_length_m = band.fetch_length_m
		config.swell = band.swell
		config.jonswap_spread = band.jonswap_spread
		config.min_wavelength_m = band.min_wavelength_m
		config.max_wavelength_m = band.max_wavelength_m
		config.transition_width_m = band.transition_width_m
		config.short_wave_damping_m = band.short_wave_damping_m
		result.append(config)
	return result


func _print_h0_diagnostic(band_id: String, h0: PackedByteArray) -> void:
	var peak := 0.0
	for byte_offset in range(0, h0.size(), 16 * 97):
		peak = maxf(peak, maxf(absf(h0.decode_float(byte_offset)), absf(h0.decode_float(byte_offset + 4))))
	print("OceanV4 FFT %s H0 sample peak=%.5f (non-zero=%s)" % [band_id, peak, peak > 0.000001])
