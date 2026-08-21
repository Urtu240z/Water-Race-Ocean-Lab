extends SceneTree
## Fase 3A: datos horneados world-space; ninguna query consulta mallas.

const Factory := preload("res://lab/bathymetry/bathymetry_case_factory.gd")
const BakerScript := preload("res://ocean_v3/bathymetry/bathymetry_baker.gd")
const DataScript := preload("res://ocean_v3/bathymetry/bathymetry_data.gd")
const DebugScript := preload("res://ocean_v3/bathymetry/bathymetry_debug.gd")

var _failures := 0


func _initialize() -> void:
	_validate_ramp()
	_validate_bank()
	_validate_island()
	_validate_memory()
	_validate_debug_mesh()
	if _failures == 0:
		print("PHASE_3A_BATHYMETRY: PASS")
		quit(0)
	else:
		push_error("PHASE_3A_BATHYMETRY: %d fallos" % _failures)
		quit(1)


func _bake(source: MeshInstance3D):
	var baker = BakerScript.new()
	baker.source = source
	baker.sea_level_y = 0.0
	baker.cell_size_m = 1.0
	baker.use_source_bounds = true
	var data = baker.bake()
	source.free()
	baker.free()
	return data


func _validate_ramp() -> void:
	var data = _bake(Factory.make_ramp_beach())
	_check(data != null and data.is_valid(), "ramp: recurso válido")
	# Centro local (-8, 0), trasladado por Factory a X=-40: depth=8 m.
	var sample = data.sample_bathymetry(Vector2(-40.0, 0.0))
	_check(absf(sample.depth_m - 8.0) < 1.0e-5, "ramp: depth analítico interior")
	_check(absf(sample.gradient_x + 0.34) < 1.0e-5 and absf(sample.gradient_z) < 1.0e-5, "ramp: gradiente ∇depth")
	_check(sample.is_water, "ramp: agua profunda")
	# Interpolación bilinear en una posición negativa/no nodo.
	var bilinear = data.sample_bathymetry(Vector2(-39.5, 0.5))
	_check(absf(bilinear.depth_m - (8.0 - 0.34 * 0.5)) < 1.0e-5, "ramp: bilinear world-space negativo")
	var outside = data.sample_bathymetry(Vector2(-200.0, 0.0))
	_check(not outside.in_bounds, "ramp: bounds fuera explícito")
	# Determinismo: mismo mesh/params -> buffers idénticos.
	var repeat = _bake(Factory.make_ramp_beach())
	_check(data.depth_m == repeat.depth_m and data.gradient_x == repeat.gradient_x and data.land_water_mask == repeat.land_water_mask, "ramp: bake determinista")


func _validate_bank() -> void:
	var data = _bake(Factory.make_submerged_bank())
	var bank = data.sample_bathymetry(Vector2(32.0, 0.0))
	var deep = data.sample_bathymetry(Vector2(52.0, 0.0))
	_check(absf(bank.depth_m - 4.0) < 1.0e-5, "bank: profundidad máxima del banco")
	_check(deep.depth_m > 8.8 and deep.depth_m < 9.1, "bank: profundo alrededor")
	_check(absf(bank.gradient_x) < 1.0e-5 and absf(bank.gradient_z) < 1.0e-5, "bank: gradiente central")
	_check(bank.is_water and deep.is_water, "bank: siempre sumergido")


func _validate_island() -> void:
	var data = _bake(Factory.make_simple_island())
	var center = data.sample_bathymetry(Vector2(0.0, 42.0))
	var shore_land = data.sample_bathymetry(Vector2(3.0, 42.0))
	var shore_water = data.sample_bathymetry(Vector2(4.0, 42.0))
	var deep = data.sample_bathymetry(Vector2(16.0, 42.0))
	_check(center.depth_m < 0.0 and not center.is_water, "island: centro tierra sin profundidad inventada")
	_check(not shore_land.is_water and shore_water.is_water, "island: shoreline water-land derivada")
	_check(deep.depth_m > 7.9 and deep.is_water, "island: agua profunda exterior")


func _validate_memory() -> void:
	var data = DataScript.new()
	for size in [256, 512, 1024]:
		data.width = size
		data.height = size
		var expected = size * size * 18
		_check(data.approximate_memory_bytes() == expected, "memory: %dx%d = %d bytes" % [size, size, expected])


func _validate_debug_mesh() -> void:
	var data = DataScript.new()
	data.width = 2
	data.height = 2
	data.cell_size_m = 1.0
	data.depth_m = PackedFloat32Array([1.0, 2.0, -1.0, 0.0])
	data.gradient_x = PackedFloat32Array([0.0, 1.0, 0.0, 1.0])
	data.gradient_z = PackedFloat32Array([0.0, 0.0, 1.0, 1.0])
	data.slope_magnitude = PackedFloat32Array([0.0, 1.0, 1.0, 1.4])
	data.land_water_mask = PackedByteArray([1, 1, 0, 0])
	var debug = DebugScript.new()
	debug.data = data
	for mode in [0, 1, 2]:
		debug.mode = mode
		_check(debug.mesh != null, "debug: modo %d genera overlay" % mode)
	debug.free()


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)
