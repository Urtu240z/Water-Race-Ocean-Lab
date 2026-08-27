# Ocean V3 Wave Spectrum Presets

This is current implementation documentation. For the complete usage flow,
see [Ocean V3 — Usage & Integration Guide](OCEAN_V3_USAGE_GUIDE.md).

Ocean V3 now has one editable physical-authoring path:

`OceanWavePreset / OceanV3 exports -> OpenOceanFFTConfig LONG/MID/SHORT -> H0 -> GPU FFT + OceanQuery`

`OceanWaveBandSettings` owns the physical spectrum controls for one band:
Hs, choppiness, direction, directional/JONSWAP spread, fetch, swell, detail and
the wavelength/damping advanced controls. FFT resolution and domains remain
technical invariants (256; LONG 512 m, MID 137 m, SHORT 37 m).

`OceanWavePreset` contains global wind plus the three band resources. Applying a
preset copies it into the root exports; subsequent root edits are authoritative
and do not mutate or continuously reapply the Resource. The root coalesces auto
apply requests for 150 ms, then calls `OpenOceanFFTModule.set_wave_spectrum_settings`.

That module API is the sole runtime rebuild route. It rebuilds the canonical
three H0 datasets, rebuilds LONG_COASTAL/LONG_REMAINDER from the new LONG H0,
uploads the four render datasets, and refreshes REDUCED plus optional Golden
OceanQuery from the same three canonical H0 byte arrays.

The dedicated Surface Foam spectrum is deliberately excluded: wave-preset
changes neither alter its wind nor rebuild its H0. Crest Foam histories are
also retained while a smooth transition changes the source/target spectrum.
Legacy `SeaStateConfig` CALM/RACE/ROUGH loads the matching base `.tres`, so it
retains callers while using the same source of values as the authoring layer.
