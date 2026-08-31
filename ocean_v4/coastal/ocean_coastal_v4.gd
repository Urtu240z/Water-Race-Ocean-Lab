class_name OceanCoastalV4
extends Node
## V4 owner for the offline coastal geometry field.
##
## This node intentionally consumes only the immutable bake resource API
## (propagation + warp textures). It never instantiates Ocean V3 nodes,
## schedulers, breakers, queries, foam, reflections, or diagnostics.

@export var bake_asset: Resource

var _shader_state := {}


func configure(asset: Resource = bake_asset) -> bool:
	_shader_state = {}
	bake_asset = asset
	if bake_asset == null or not bake_asset.has_method(&"is_valid") or not bake_asset.is_valid():
		push_error("OceanV4 coastal geometry needs a valid immutable coastal bake asset.")
		return false
	var propagation = bake_asset.get(&"propagation")
	var warp = bake_asset.get(&"warp")
	if propagation == null or warp == null or not propagation.has_method(&"build_gpu_textures") or not warp.has_method(&"build_gpu_textures"):
		push_error("OceanV4 coastal bake asset is missing propagation or warp geometry data.")
		return false
	var propagation_textures: Dictionary = propagation.build_gpu_textures()
	var warp_textures: Dictionary = warp.build_gpu_textures()
	if propagation_textures.is_empty() or warp_textures.is_empty():
		push_error("OceanV4 coastal bake could not create its immutable GPU textures.")
		return false
	_shader_state = {
		"field": propagation_textures.get("field"),
		"metrics": propagation_textures.get("metrics"),
		"warp": warp_textures.get("warp"),
		"jacobian": warp_textures.get("jacobian"),
		"origin_xz": propagation.world_origin_xz,
		"extent_m": propagation.world_max_xz() - propagation.world_origin_xz,
		"warp_origin_xz": warp.world_origin_xz,
		"warp_extent_m": warp.world_max_xz() - warp.world_origin_xz,
		"warp_detj_safe": warp.detj_safe_threshold,
		"min_valid_depth_m": maxf(propagation.min_valid_depth_m, 0.001),
		"cell_size_m": maxf(propagation.cell_size_m, 0.25),
	}
	print("OceanV4 coastal geometry ready: %s" % bake_asset.describe())
	return true


func shader_state() -> Dictionary:
	return _shader_state.duplicate()
