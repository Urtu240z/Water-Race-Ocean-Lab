# Ocean V3 — Sunrays V3 and Sediment V2 Hotfix

## Sunrays V3

The underwater compositor no longer binds or samples the caustics texture for
sunrays. It keeps the existing four-tap, per-tap light-entry, Beer–Lambert and
Henyey–Greenstein integration architecture, but the per-tap beam field is now
procedural in light space.

For `L = normalize(light_into_water)`, the shader selects a nonparallel
reference axis and constructs `U = normalize(cross(reference, L))` and
`V = normalize(cross(L, U))`. Every tap uses
`beam_coord = vec2(dot(P, U), dot(P, V))`. Therefore `P + L * d` retains the
same beam coordinate: field geometry is world anchored and extruded in the
physical light direction, not in camera or screen space.

The procedural field combines meter-space ridges with approximately 8.7 m,
2.9 m, and 1.8 m spacing, plus a very slow transverse warp. Animation defaults
to zero; no coordinate translation is performed. `SUNRAYS_BEAM_COORD` exposes
the transverse coordinate and `SUNRAYS_BEAM_FIELD` exposes its shaped ridge
field. Existing vector, tap-validity, depth, integral, final, and exaggerated
diagnostics remain available.

## Sediment V2 test path

Sediment source remains a continuous, delta-time-scaled rate. Queued test
injections are concentration impulses and are deliberately not scaled by
delta-time. The diagnostic action chooses a valid water/seabed cell within
20 m, preferring one about 8 m ahead of the camera, queues a 9 m / 0.90
impulse, validates field and bathymetry constraints, and may be repeated.

The test action prints deterministic field-center proxy information without a
GPU readback and shows a temporary orange world-space marker for six seconds.
This separates target/field injection diagnosis from the particle cloud and
wisp render paths while preserving the persistent GPU simulation and its
world-space field.
