extends SceneTree
## CPU validation for the editable wave-spectrum authoring layer.
## Run: Godot --headless --path . --script res://tests/wave_spectrum_presets_validation.gd

var _failures: Array[String] = []


func _init() -> void:
	_validate_base_presets_match_legacy_values()
	_validate_marejadilla()
	_validate_root_overrides_only_change_requested_band()
	if _failures.is_empty():
		print("PASS: editable wave spectrum presets")
		quit(0)
	for failure in _failures:
		push_error(failure)
	quit(1)


func _validate_base_presets_match_legacy_values() -> void:
	var expected := {
		SeaStateConfig.State.CALM: [6.0, [[0.20, 0.55, Vector2(1.0, 0.10), 8.0, 0.35, 0.04, 7.0, 1.0], [0.09, 0.45, Vector2(1.0, 0.18), 6.0, 0.38, 0.008, 7.0, 0.20], [0.03, 0.25, Vector2(1.0, 0.25), 4.0, 0.78, 0.0, 7.0, 0.0]]],
		SeaStateConfig.State.RACE: [12.0, [[0.59, 1.00, Vector2(1.0, 0.15), 7.0, 0.50, 0.80, 5.5, 1.0], [0.25, 0.70, Vector2(1.0, 0.30), 5.0, 0.54, 0.16, 5.5, 0.50], [0.05, 0.35, Vector2(1.0, 0.45), 4.0, 0.58, 0.12, 5.5, 0.05]]],
		SeaStateConfig.State.ROUGH: [18.0, [[2.50, 2.00, Vector2(1.0, 0.10), 5.0, 0.62, 1.60, 4.5, 1.0], [0.60, 1.25, Vector2(1.0, 0.38), 3.5, 0.66, 0.42, 4.5, 0.65], [0.12, 0.40, Vector2(1.0, 0.62), 3.0, 0.68, 0.22, 4.5, 0.10]]],
	}
	for state in expected:
		var cascades := SeaStateConfig.build_cascades(state)
		var entry: Array = expected[state]
		for index in 3:
			var config: OpenOceanFFTConfig = cascades[index]
			var values: Array = entry[1][index]
			_check(is_equal_approx(config.wind_speed_mps, entry[0]), "%s wind speed" % SeaStateConfig.state_name(state))
			_check(is_equal_approx(config.target_hs_m, values[0]), "%s %d Hs" % [SeaStateConfig.state_name(state), index])
			_check(is_equal_approx(config.choppiness, values[1]), "%s %d choppiness" % [SeaStateConfig.state_name(state), index])
			_check(config.wind_direction.is_equal_approx((values[2] as Vector2).normalized()), "%s %d direction" % [SeaStateConfig.state_name(state), index])
			_check(is_equal_approx(config.directional_spread, values[3]), "%s %d directional spread" % [SeaStateConfig.state_name(state), index])
			_check(is_equal_approx(config.foam_whitecap, values[4]), "%s %d foam whitecap" % [SeaStateConfig.state_name(state), index])
			_check(is_equal_approx(config.foam_amount, values[5]), "%s %d foam amount" % [SeaStateConfig.state_name(state), index])
			_check(is_equal_approx(config.foam_decay, values[6]), "%s %d foam decay" % [SeaStateConfig.state_name(state), index])
			_check(is_equal_approx(config.foam_cascade_weight, values[7]), "%s %d foam weight" % [SeaStateConfig.state_name(state), index])
			_check(config.domain_size_m == [512.0, 137.0, 37.0][index], "%s %d invariant domain" % [SeaStateConfig.state_name(state), index])


func _validate_marejadilla() -> void:
	var preset := load("res://ocean_v3/presets/waves/marejadilla.tres") as OceanWavePreset
	_check(preset != null, "marejadilla preset loads")
	if preset == null:
		return
	var cascades := preset.build_cascades()
	_check(is_equal_approx(preset.global_wind_speed_mps, 10.0), "marejadilla global wind")
	_check(is_equal_approx(cascades[0].target_hs_m, 0.07), "marejadilla LONG Hs")
	_check(is_equal_approx(cascades[1].target_hs_m, 0.11), "marejadilla MID Hs")
	_check(is_equal_approx(cascades[2].target_hs_m, 0.22), "marejadilla SHORT Hs")
	_check(is_equal_approx(cascades[2].choppiness, 1.25), "marejadilla SHORT choppiness")
	_check(is_equal_approx(preset.short_geometry_strength, 0.45), "marejadilla short geometry")
	var hs := sqrt(0.07 * 0.07 + 0.11 * 0.11 + 0.22 * 0.22)
	_check(is_equal_approx(hs, 0.25573424), "marejadilla combined Hs")


func _validate_root_overrides_only_change_requested_band() -> void:
	# Mirrors OceanV3's root-authoritative export handoff without loading its
	# runtime module (SceneTree --script has no autoload identifiers).
	var preset := load("res://ocean_v3/presets/waves/race.tres") as OceanWavePreset
	var before := preset.build_cascades()
	var edited := preset.duplicate(true) as OceanWavePreset
	edited.short_band.target_hs_m = 0.22
	edited.short_band.choppiness = 1.25
	var after := edited.build_cascades()
	_check(is_equal_approx(before[0].target_hs_m, after[0].target_hs_m), "SHORT edit leaves LONG Hs unchanged")
	_check(is_equal_approx(before[1].target_hs_m, after[1].target_hs_m), "SHORT edit leaves MID Hs unchanged")
	_check(is_equal_approx(after[2].target_hs_m, 0.22), "SHORT Hs override reaches config")
	_check(is_equal_approx(after[2].choppiness, 1.25), "SHORT choppiness override reaches config")


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
