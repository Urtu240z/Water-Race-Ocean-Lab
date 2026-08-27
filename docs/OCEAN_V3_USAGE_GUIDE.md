# Ocean V3 — Usage & Integration Guide

This guide is for putting the current Ocean V3 into a new scene and for
preparing a later move to another Godot project. It uses the public names and
paths in the current source. Ocean V3 does not include vehicle buoyancy or
gameplay objects; it provides the water surface and query contract.

## Use Ocean V3 in a new level in this project

### 1. Add the scene

Instantiate `res://ocean_v3/ocean_v3.tscn` as `OceanV3`. Keep its internal
children named `OpenOceanFFT` and `OceanClipmapSurface`. The scene already
assigns the current RACE preset and the three surface-detail textures.

An orienting level structure can be:

```text
Level
├── WorldEnvironment
├── Gameplay
├── OceanV3Mount
│   └── OceanV3
├── SeaStateZones
│   ├── CanalMain (OceanSeaStateZone3D)
│   ├── Harbour (OceanSeaStateZone3D)
│   └── ProtectedBay (OceanSeaStateZone3D)
└── Camera3D
```

`SeaStateZones` is only organizational. Zones can live anywhere in the scene
tree because they register through their group; they do not need to be under
OceanV3. The current registration policy assumes one active OceanV3 per
level: a zone registers with the first root in the `ocean_v3_root` group.

### 2. Set sea level and placement

Set the physical water height in the `clipmap_config` resource on
`OceanV3/OpenOceanFFT/OceanClipmapSurface`, specifically `sea_level_y`.
Keep the level's world units in meters and make the bathymetry baker use the
same sea level. The clipmap follows the active camera in XZ automatically;
its per-frame origin is not controlled by moving a gameplay object.

The default clipmap is a practical starting point: 128 cells, 0.25 m near
spacing, 10 levels, 7000 m horizon. Set its fade ranges and horizon for the
level and camera, then verify the camera's far clip includes the desired
horizon.

### 3. Check dependencies

The project must provide the three current autoloads: `SimulationClock`,
`OceanQualitySettings`, and `OceanModuleRegistry`. The OceanV3 scene also
expects the complete `res://ocean_v3/` runtime folder because the module
preloads its FFT, foam, query, Coastal, and breaker components even when
optional features are disabled.

### 4. Choose a wave preset

Select an `OceanWavePreset` resource in the OceanV3 root's `wave_preset`
property. The shipped resources are:

```text
res://ocean_v3/presets/waves/calm.tres
res://ocean_v3/presets/waves/race.tres
res://ocean_v3/presets/waves/rough.tres
res://ocean_v3/presets/waves/marejadilla.tres
```

Assigning a preset copies its values into the root exports and applies it.
Root edits then remain the authority. If you edit wave exports frequently,
`auto_apply_wave_changes` coalesces rebuilds over 150 ms. Use the root's
`Apply Selected Preset` and `Apply Wave Changes` tool buttons when authoring.

### 5. Transition the global state

Use the real public method from gameplay or a level controller:

```gdscript
@onready var ocean: OceanV3 = $OceanV3Mount/OceanV3
var race := preload("res://ocean_v3/presets/waves/race.tres") as OceanWavePreset

func make_water_rough() -> void:
	var rough := preload("res://ocean_v3/presets/waves/rough.tres") as OceanWavePreset
	ocean.transition_to_wave_preset(rough, 10.0)
```

`transition_to_wave_preset(preset, seconds)` keeps GPU and Reduced Query
coherent, interpolates physical parameters and choppiness, and keeps foam
history. Use a positive duration for weather/state changes. For an immediate
authoring or gameplay switch, assign `ocean.wave_preset = race` (or call
`apply_selected_wave_preset()` after changing the resource); a zero duration
also selects the immediate route. Do not rebuild foam histories to make a
preset or zone change.

### 6. Adjust visual appearance

Use the root's current exports for optical tuning: `Water Optics`, `Whitecaps
Foam`, `Whitecaps Foam / Crest Filigree`, and `Whitecaps Foam / Surface Foam`.
Tune these after the physical preset. `short_geometry_strength` controls the
visible geometric contribution of SHORT; it is not a query or band removal.

### 7. Configure Surface Detail

Leave `surface_detail_enabled` on only when the normal A/B and warp textures
are assigned. The packed scene assigns:

```text
surface_normal_texture_a = res://ocean_v3/rendering/surface_detail/surface_normal_a.tres
surface_normal_texture_b = res://ocean_v3/rendering/surface_detail/surface_normal_b.tres
surface_warp_texture      = res://ocean_v3/rendering/surface_detail/surface_warp_noise.tres
surface_foam_micro_detail = res://ocean_v3/rendering/surface_detail/surface_foam_micro_detail.png
```

`surface_detail_wave_follow` controls how the optical detail follows the
macro field. It never changes geometry or query; do not use it to compensate
for incorrect physical band settings.

### 8. Add Coastal/Bathymetry only when needed

For a level that needs the optional coastal path:

1. Add a `BathymetryBaker` node using
   `res://ocean_v3/bathymetry/bathymetry_baker.gd`.
2. Assign `source_root` (or `source`) to the level's mesh source, set
   `sea_level_y`, bounds/cell size, and optionally `output_path`.
3. Run `BAKE PREVIEW` while authoring or call `bake_to_resource()` to save a
   `BathymetryData` resource. The bake is offline/dev-time.
4. Assign the resulting resource to
   `OceanV3/OpenOceanFFT.coastal_bathymetry_data`.
5. Enable `coastal_propagation_enabled`; leave
   `coastal_eikonal_enabled` and `coastal_warp_enabled` on for the current
   production-oriented path, then call `rebuild_coastal_propagation()` once
   after the resource/direction/settings are ready.

`rebuild_coastal_propagation()` returns `false` and leaves LONG open when
Coastal is disabled or the data is invalid. The runtime path is a baked,
representative LONG component; it is not required for open ocean, and it does
not turn the other bands into finite-depth waves.

### 9. Add Sea State Zones when local water is needed

Add `OceanSeaStateZone3D` from the Create Node dialog. Use `box_size_m` for
the physical X/Z extent, move the node to the water position, and rotate it
around Y. Keep `Node3D.scale` at `(1, 1, 1)`. Configure the absolute target
values and `feather_distance_m`; no Area3D, collision shape, body signals, or
player script are needed.

Example local calm channel:

```text
box_size_m                 = (120, 160)
long_amplitude_multiplier  = 0.35
mid_amplitude_multiplier   = 0.10
short_amplitude_multiplier = 0.03
choppiness_multiplier      = 0.45
foam_generation_multiplier = 0.10
feather_distance_m         = 30
strength                   = 1
priority                   = 0
```

The runtime composes at most eight enabled zones by priority, then node path.
Targets are absolute relative to the global state, so a value of `0.35`
means 35% of the current global LONG amplitude at the zone core. See
[SEA_STATE_ZONES.md](../ocean_v3/SEA_STATE_ZONES.md) for the editor handles
and full field semantics.

### 10. Query the water from gameplay

Use physics-time methods for gameplay. The returned sample is a real
`OceanQuerySample`, not a dictionary:

```gdscript
@onready var ocean: OceanV3 = $"../OceanV3Mount/OceanV3"

func _physics_process(_delta: float) -> void:
	var sample: OceanQuerySample = ocean.sample_water_physics_time(global_position)
	if not sample.valid:
		return
	global_position.y = sample.height
	var water_normal := sample.normal
	var water_velocity := sample.surface_velocity
	var foldover := sample.foldover_risk
```

For multiple points, preserve point order:

```gdscript
var points: Array[Vector3] = [bow_position, stern_position, left_float, right_float]
var samples: Array = ocean.sample_water_batch_physics_time(points)
for index in samples.size():
	var sample: OceanQuerySample = samples[index]
	if sample.valid:
		var contact_height := sample.height
		var contact_normal := sample.normal
		var contact_velocity := sample.surface_velocity
		# Feed these values into the consuming gameplay object's own contact logic.
```

For a deliberately chosen time (for example a render-synchronized visual
effect), use `sample_water(point, time)` or
`sample_water_batch_at_time(points, time)`. For the explicit prepared route,
call `prepare_query_time(time)` before `sample_water_prepared(point)`.

Each sample currently provides:

| Field | Meaning |
|---|---|
| `valid` | Newton converged and all returned values are finite |
| `height` | Absolute world Y: sea level plus vertical displacement |
| `displacement` | Parametric relative `(Dx, H, Dz)` |
| `normal` | Unit surface normal at the solved parametric point |
| `surface_velocity` | Time derivative/orbital velocity at that point, not fixed-XZ intersection velocity |
| `jacobian_det` | Horizontal parametrization determinant |
| `foldover_risk` | `true` when the determinant is at or below zero |
| `query_residual_m` / `query_iterations` | Newton diagnostics |

`turbulence` and `whitewater` are currently default fields, not generated
gameplay signals. Build spray, buoyancy, or contact behavior in the consuming
gameplay project; this guide does not add a flotation system.

### 11. Debug the level

The standalone Lab controls are documented in
[Ocean Lab](OCEAN_V3_TROUBLESHOOTING.md#ocean-lab). In a production level,
call the same public OceanV3/module methods from a development controller or
inspect `query_backend_name()`, `is_fft_enabled()`, `clipmap_level_count()`,
`clipmap_extent_m()`, and `breaker_pool_summary()` as appropriate.

### 12. New-scene checklist

- [ ] `res://ocean_v3/ocean_v3.tscn` instanced without renaming internal nodes
- [ ] `sea_level_y` is correct and matches any bathymetry bake
- [ ] A wave preset is assigned and applied
- [ ] Camera is active, far clip covers the desired horizon, and clipmap fades are appropriate
- [ ] Surface Detail textures are present if `surface_detail_enabled` is on
- [ ] At least one `sample_water_physics_time()` query tested at a gameplay point
- [ ] Bathymetry assigned and Coastal rebuilt only if the level needs it
- [ ] Sea State Zones use Box Size, not Node3D scale, and there are at most eight enabled
- [ ] Foam is visible/disabled intentionally; histories are not reset during transitions
- [ ] Breakers are checked only when valid Coastal data enables them
- [ ] No shader, RenderingDevice, missing-resource, or RID errors appear on startup

## Migrating Ocean V3 to another Godot project

### Required runtime

For the current scene-based runtime, copy the complete `ocean_v3/` directory,
including scripts, the packed scene, presets, shader sources, LUT/resource
files, and surface-detail textures. The module's preloads make Coastal,
breaking, query, FFT, and foam script files parse-time dependencies even when
their features are disabled. Keep `ocean_v3/ocean_v3.tscn` and its internal
node paths intact.

Add these autoloads under the exact names in the destination project's
`project.godot`:

```ini
[autoload]
SimulationClock="*res://ocean_v3/core/simulation_clock.gd"
OceanQualitySettings="*res://ocean_v3/core/ocean_quality_settings.gd"
OceanModuleRegistry="*res://ocean_v3/core/ocean_module_registry.gd"
```

`SimulationClock` and `OceanModuleRegistry` are runtime requirements. The
current module also references `OceanQualitySettings` as a project singleton
for the established project contract, so keep it present even though its
profiles do not yet drive quality changes.

### Optional components

These are part of the copied runtime folder but optional in a given level:

- `ocean_v3/bathymetry/` and `ocean_v3/coastal/` for baked bathymetry,
  Coastal propagation, Eikonal/refraction, warp, and their debug/preview tools;
- `ocean_v3/breaking/` and breaker shaders/LUT for local breaker ribbons;
- Native OceanQuery files for acceleration;
- `addons/ocean_v3_tools/` for editor-only zone gizmos;
- `lab/`, test scripts, benchmark executables, Lab assets, and the Lab scene
  are not runtime dependencies of OceanV3 and should not be copied for a
  production level.

Although Coastal and breaking are optional features, their scripts are still
preloaded by the current `OpenOceanFFTModule`; remove or rewrite preload
dependencies only in a separate code task, not during integration.

### Editor only

Copy `addons/ocean_v3_tools/` only if designers need the custom
`OceanSeaStateZone3D` gizmo. Enable
`res://addons/ocean_v3_tools/plugin.cfg` in the destination editor. Runtime
zone registration does not require the plugin; without it, edit `box_size_m`
and `feather_distance_m` in the Inspector.

### Native components

The optional GDExtension descriptor is
`native/ocean_query/water_race_ocean_query.gdextension`. The current Windows
library path is
`native/ocean_query/bin/water_race_ocean_query.windows.template_release.x86_64.dll`.
With the descriptor and matching DLL present, `OpenOceanFFTModule` detects
the registered `OceanQueryNative` class. The current Native route includes
runtime AVX2 selection and a scalar fallback inside the extension; AVX2 is
not a load-time requirement.

If the extension is absent or cannot register, Reduced GDScript remains the
supported fallback. Native does not currently represent local Sea State Zones
or an active global wave transition, so those cases intentionally route to
Reduced. The Linux `.so` convention is present in the descriptor but has not
been compiled or validated in this project.

Build inputs under `native/ocean_query/` (`SConstruct`, the build batch file,
the template, and offline `godot-cpp`/SCons dependencies) are development
inputs, not required runtime assets. Do not treat old benchmark executables
as production dependencies.

### Project settings and singletons

The current project records this tested configuration:

```ini
config/features=PackedStringArray("4.7", "Forward Plus")
rendering/rendering_device/driver.windows="d3d12"
physics/3d/physics_engine="Jolt Physics"
physics/common/physics_interpolation=true
```

The runtime requirement is Godot 4.7-compatible Forward Plus with a working
`RenderingDevice` backend for the compute shaders and `Texture2DRD`. D3D12 is
the tested Windows configuration in this repository, not a universal OceanV3
hard requirement. Vulkan/other backends require their own validation. Jolt is
the current project physics setting but OceanV3 itself does not require Jolt
for its query evaluator; a consuming project must choose and validate its
own gameplay physics/interpolation setup.

The current project also uses 0.7 3D scale and a 1920×1080 window. These are
project presentation choices, not OceanV3 integration requirements.

### Resource dependencies to audit when copying

The packed scene directly references the three Surface Detail resources, the
Surface Foam micro-detail image, the RACE preset, and the root/module/surface
scripts. The module preloads the internal runtime scripts and shaders under
`ocean_v3/`. The destination must therefore preserve `res://` paths or update
the scene/resources consistently. Do not copy Lab-only HDR, boats, island,
BathymetryBaker scene wiring, cameras, HUD, or benchmark assets unless the
new level explicitly uses them.

## See also

- [Current architecture](OCEAN_V3_ARCHITECTURE.md)
- [Wave preset notes](WAVE_SPECTRUM_PRESETS.md)
- [Sea State Zones](../ocean_v3/SEA_STATE_ZONES.md)
- [Troubleshooting](OCEAN_V3_TROUBLESHOOTING.md)
