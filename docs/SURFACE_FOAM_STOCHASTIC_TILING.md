# Surface Foam Stochastic Deperiodization

Surface Foam retains its existing 8 m direct-J source domain, FFT, H0, temporal
history and MID fold generation. Only shader sampling changes.

When enabled, each world-space fragment maps into a 32 m triangular lattice.
Its containing triangle supplies three lattice vertices. A deterministic
mathematical hash of each vertex selects a 0/90/180/270-degree rotation, an
optional X mirror and a source-domain phase offset. The three transformed
direct-J samples independently form `max(0, whitecap - J)` and are then blended
with smooth normalized barycentric weights. J values are never mixed before the
threshold.

The history field is sampled with the same lattice rule and remains only the
existing temporal envelope. Direct-J stays the fine filament topology at every
visible distance. Surface Foam and Crest Filigree consume the same resulting
`surface_foam_macro`, so Filigree has no extra stochastic sampling path.

With stochastic deperiodization disabled, sampling falls back to the original
single periodic Direct-J and field reads for direct comparison. The mapping uses
no time, camera state, CPU state, extra textures or buffers; it is stable during
camera motion and SimulationClock pauses.
