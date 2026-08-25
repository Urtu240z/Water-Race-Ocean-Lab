# Surface Foam: scale, distance and microdetail

The production Surface Foam route is the dedicated `surface_foam_spectrum_solver.gd`.
It keeps its persistent RG16F history/source field, 30 Hz scheduler,
birth attack, lifetime, selectivity, evolution speed, ocean coupling and edge
controls from the previous phase.

## Spectral scale

Surface Foam now separates the spectral source from the persistent presentation
field. Production uses `surface_foam_source_domain_m = 8 m` and
`surface_foam_field_domain_m = 88 m`. The 512² H0/Jacobian is generated with
the normal reference spectrum at the 8 m source period:

```text
k = FFT grid vector, dk = 2*pi / source_domain
omega = omega(k)
amplitude = sqrt(2*TMA(k)*D(k, direction)*(domega_dk/k)*dk^2)
```

The field update maps each 88 m texel to source space using a seamless analytic
low-frequency warp. It reads the same 8 m Jacobian twice, applies whitecap and
Birth shaping independently to each sample, then uses a smooth regional
selection between the shaped targets. This is deperiodization, not a second
FFT: the source remains 8 m while the persistent field repeats only at 88 m.

The persistent field is RG16F: R is history and G is the selected deperiodized
target/support. Production fragment shading reads that field once; it no longer reads
the 8 m Jacobian directly. There is no target Hs, band-pass, feature remap or
additional simulation. Sea-state wind presets remain 6, 10 and 20 m/s for
CALM, RACE and ROUGH; Amount, Selectivity and Lifetime remain independent.

## Shading LOD

The shader samples the persistent history once and uses an independent Surface
Foam distance fade (200–600 m by default). Near is 0–45 m with coarse and fine
micro samples; Mid is 45–150 m with one coarse RG sample; Far is beyond 150 m
with history and scalar shaping only. J interpolation is skipped in Far.

The RGBA8 tile `surface_foam_micro_detail.png` is deterministic and tileable:
R is organic breakup and G is a bubble distance-like field. Near uses at most
two RG samples, Mid one, and Far none. `fwidth` provides boundary AA and G's
derivatives provide the subtle bubble normal without a third fetch. All visible
coverage remains multiplied by the physical persistent mask.

Topology debug modes 29, 30 and 31 expose the shaped targets from warp A,
warp B and the regional selection. Mode 26 exposes history (R), mode 16 the
selected source/support (G), mode 28 the final visible surface mask, and mode
32 runs the one-sample A path without the second Jacobian read.
