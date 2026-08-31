extends SceneTree
## Deterministic Phase 0 check: V4's physical config produces V3-reference H0.

const Preset := preload("res://ocean_v3/presets/waves/rough.tres")
const Spectrum := preload("res://ocean_v3/core/tessendorf_spectrum.gd")
const V4Config := preload("res://ocean_v4/simulation/open_ocean_fft_config_v4.gd")


func _init() -> void:
	var source_configs = Preset.build_cascades()
	for source in source_configs:
		var v4 = V4Config.new()
		for property in [
			"id", "resolution", "domain_size_m", "gravity_mps2", "min_wavelength_m", "max_wavelength_m",
			"transition_width_m", "wind_direction", "wind_speed_mps", "energy", "directional_spread",
			"short_wave_damping_m", "choppiness", "target_hs_m", "spectrum_model", "fetch_length_m",
			"swell", "jonswap_alpha", "detail", "jonswap_spread",
		]:
			v4.set(property, source.get(property))
		var seed := Spectrum.derive_cascade_seed(20260820, source.id)
		var expected := Spectrum.build_h0_rgba32f(source, seed)
		var actual := Spectrum.build_h0_rgba32f(v4, seed)
		assert(expected == actual, "V4 H0 diverged for %s" % source.id)
		print("OceanV4 %s: H0 exact; Hs %.4f m" % [source.id, v4.measured_hs_m])
	quit()
