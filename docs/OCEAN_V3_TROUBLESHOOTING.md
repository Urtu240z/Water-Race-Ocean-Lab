# Ocean V3 — Troubleshooting and Debugging

This is a current operational guide. Historical reports may describe old bugs
or intermediate behavior; do not use them as expected runtime behavior.

## Water is visible but OceanQuery does not match

- Confirm the query uses the same OceanV3 instance that renders the level.
- Use `sample_water_physics_time()` for gameplay and check `sample.valid`.
- Confirm `sea_level_y` and any Coastal `BathymetryData` use the same world
  coordinates and units.
- Check `query_backend_name()`. Local zones and global transitions force
  Reduced; Native is not selected in those cases by design.
- If Coastal is enabled, verify that `rebuild_coastal_propagation()` was
  called after assigning valid bathymetry. Invalid/out-of-range coastal data
  falls back to open LONG behavior.
- Do not compare a render-time sample with a physics-time sample and call the
  difference a geometry bug; use `sample_water_batch_at_time()` when matching
  the visual tracker.

## Sea State Zones do not appear to work

Check that the node uses the `OceanSeaStateZone3D` script, is enabled, and is
inside the active scene tree. It registers through the
`ocean_sea_state_zone` group; it does not need to be a child of OceanV3. Only
the first eight enabled zones after priority/path ordering are composed. The
zone changes the water field at its world XZ position; it does not detect
player entry.

If the visual outline is missing in the editor, enable the `Ocean V3 Tools`
plugin. The runtime field still works without the editor plugin.

## Node scale warning on a zone

Reset `Node3D.scale` to `(1, 1, 1)` and edit `box_size_m` or use the X/Z gizmo
handles. Scale is deliberately non-authoritative, so scaling the node is not
the supported way to change the physical rectangle.

## More than eight active zones

This is a real bounded limit in the current shader uniform arrays and root
composition. Disable or merge zones, or raise the limit only as a separate
runtime/shader change. The first eight are selected by priority and node path.

## Coastal has no effect

`coastal_propagation_enabled` must be true, `coastal_bathymetry_data` must be
valid, and `rebuild_coastal_propagation()` must complete with valid data. The
current Coastal path affects only LONG_COASTAL and is disabled outside the
baked data bounds. `coastal_runtime_enabled` is a presentation A/B toggle over
resident baked data; it does not rebuild the bake.

Missing bathymetry is not an error in an open-ocean level: the module warns
and leaves LONG open. It is an error only when the level expects Coastal.

## Editor plugin or gizmo is not loaded

In `project.godot`, enable `res://addons/ocean_v3_tools/plugin.cfg`, restart or
reload the editor, and ensure the node really has
`res://ocean_v3/core/ocean_sea_state_zone_3d.gd`. Without the plugin, edit the
same properties in the Inspector.

## Surface Detail has no visible texture detail

Confirm `surface_detail_enabled` and all three normal/warp textures. Check
`surface_detail_wave_follow`, normal sizes, strength, fade start/end, and
`ocean_surface_detail_quality`. Surface Detail is fragment-only: it cannot
repair missing physical waves or change OceanQuery.

## Shader, RenderingDevice, or RID errors

Confirm the project runs a Godot 4.7-compatible Forward Plus
`RenderingDevice` backend and that all `res://ocean_v3/` paths were preserved.
The repository's tested Windows backend is D3D12, but that is not declared a
universal backend requirement. Check the first shader/resource error; later
RID errors are often a consequence of an earlier failed resource load. Avoid
renaming `OpenOceanFFT` or `OceanClipmapSurface` inside the packed scene.

## Native and Reduced differences

Native is optional. If the DLL is not registered, the module intentionally
uses Reduced GDScript. During global transitions or with local zones, Reduced
is intentional even when Native is installed. The Native descriptor currently
targets the Windows x86_64 DLL; the Linux path is not validated here.

Use `query_backend_name()` and sample validity/residual diagnostics before
comparing timings or values. The Golden Reference is debug/test-only and is
not the production path.

## Global transition appears stalled

The target H0/query payload is prepared asynchronously before the visible
transition starts. `wave_transition_state()` exposes `preparing`, `active`,
`alpha`, `elapsed_s`, and `cancelled`. While preparing, the visible state is
intentionally held. A second request is queued/retargeted according to the
current transition state. A zero duration applies immediately.

Foam schedulers and histories should continue evolving through a smooth
preset transition. Do not clear foam histories as a workaround.

## Foam or breakers seem absent

Crest Foam and Surface Foam are separate systems. Check the corresponding
root enable flags, update settings, and debug mode. Surface Foam also needs its
technical solver/resources to initialize. Breaker ribbons additionally require
`breaker_enabled`, Coastal runtime enabled, valid propagation data, and a
candidate field with eligible energy/depth. Coastal OFF intentionally means
no breaker pool output.

## Ocean Lab

The Lab is a reference/debug scene, not a production dependency. Its current
keyboard controls are:

| Key | Action |
|---|---|
| `Tab` | Toggle free/reference camera |
| `WASD`, `Q/E`, `Shift`, mouse | Move, vertical move, speed modifier, look |
| `P` | Pause/resume SimulationClock |
| `R` | Reset simulation, preserve seed |
| `N` | Start with `simulation_seed + 1` |
| `O` | Ocean FFT on/off |
| `C` | Coastal presentation on/off |
| `Shift+C` | Cycle Coastal composition debug |
| `V` | Cycle surface debug view |
| `B` | Cycle ALL/LONG/MID/SHORT band view |
| `L` | Clipmap LOD debug |
| `T` | Periodicity debug |
| `M` | Toggle metric references |
| `X` | Cycle PHILLIPS/JONSWAP_HASSELMANN |
| `H` | Ocean shape debug |
| `Z` | Crest-sharpen debug |
| `G` | Toggle VERTEX/FRAGMENT normal shading |
| `Y` | Toggle query probe snapshot |
| `F2` | Breaker Ribbon diagnostic visibility |
| `F3` | Cycle foam debug modes |
| `F4` | Sea State Zone heatmap |
| `4/5/6` | Smooth CALM/RACE/ROUGH transition |
| `Shift+4/5/6` | Immediate CALM/RACE/ROUGH switch |
| `1/2/3` | DECK/STANDARD/DEV_HIGH profile selection |
| `,` / `.` | Halve/double time scale, clamped 0.125–8 |
| `F1` | Toggle HUD |

The Lab wires a demo zone at runtime and builds its own Bathymetry → Eikonal
→ Warp path. A new level should not copy that Lab setup unless it needs those
features.
