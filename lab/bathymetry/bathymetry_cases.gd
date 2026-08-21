@tool
extends Node3D
## Escena de Lab para inspección inmediata de RAMP/BANK/ISLAND.

const Factory := preload("res://lab/bathymetry/bathymetry_case_factory.gd")
const BakerScript := preload("res://ocean_v3/bathymetry/bathymetry_baker.gd")
const DebugScript := preload("res://ocean_v3/bathymetry/bathymetry_debug.gd")

@export var debug_mode := 0 # BathymetryDebug.Mode.DEPTH
	set(value):
		debug_mode = value
		for child in get_children():
			if child is MeshInstance3D and child.name.ends_with("Debug"):
				child.mode = value


func _ready() -> void:
	if get_node_or_null("RampBeach") != null:
		return
	_add_case("RampBeach", Factory.make_ramp_beach())
	_add_case("SubmergedBank", Factory.make_submerged_bank())
	_add_case("SimpleIsland", Factory.make_simple_island())


func _add_case(label: String, source: MeshInstance3D) -> void:
	source.name = label
	add_child(source)
	var baker = BakerScript.new()
	baker.name = "%sBaker" % label
	baker.source = source
	baker.sea_level_y = 0.0
	baker.cell_size_m = 1.0
	add_child(baker)
	var data := baker.bake()
	var debug = DebugScript.new()
	debug.name = "%sDebug" % label
	debug.data = data
	debug.mode = debug_mode
	add_child(debug)
