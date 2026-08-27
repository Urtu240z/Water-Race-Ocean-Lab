# Ocean V3 Documentation

This directory is the documentation entry point for the current Ocean V3
implementation. The source code is authoritative when a phase report and the
current implementation disagree.

## Start here

- [Production usage and integration guide](OCEAN_V3_USAGE_GUIDE.md)
- [Current architecture](OCEAN_V3_ARCHITECTURE.md)
- [Sea State Zones](../ocean_v3/SEA_STATE_ZONES.md)
- [Debugging and Ocean Lab](OCEAN_V3_TROUBLESHOOTING.md#ocean-lab)
- [Migration and integration](OCEAN_V3_USAGE_GUIDE.md#migrating-ocean-v3-to-another-godot-project)

## Current systems

- [Wave presets and transitions](WAVE_SPECTRUM_PRESETS.md)
- [Surface Foam implementation notes](SURFACE_FOAM_DIRECT_TOPOLOGY.md),
  [scale/LOD](SURFACE_FOAM_SCALE_LOD.md), and
  [stochastic deperiodization](SURFACE_FOAM_STOCHASTIC_TILING.md)
- [Current troubleshooting](OCEAN_V3_TROUBLESHOOTING.md)
- [Current status and bounded roadmap](OCEAN_V3_ARCHITECTURE.md#current-implementation-status-and-roadmap)

## Current implementation status

| System | Status | Canonical documentation |
|---|---|---|
| Open-ocean FFT and clipmap | Implemented | [Architecture](OCEAN_V3_ARCHITECTURE.md#open-ocean-rendering) |
| CALM/RACE/ROUGH presets | Implemented | [Wave presets](WAVE_SPECTRUM_PRESETS.md) |
| Smooth global preset transition | Implemented | [Architecture](OCEAN_V3_ARCHITECTURE.md#global-wave-state) |
| Surface Detail | Implemented, optical only | [Architecture](OCEAN_V3_ARCHITECTURE.md#surface-detail) |
| OceanQuery Reduced | Implemented production fallback | [Architecture](OCEAN_V3_ARCHITECTURE.md#oceanquery) |
| OceanQuery Native | Implemented optional Windows acceleration | [Usage guide](OCEAN_V3_USAGE_GUIDE.md#native-components) |
| Sea State Zones | Implemented for render and Reduced Query | [Sea State Zones](../ocean_v3/SEA_STATE_ZONES.md) |
| Bathymetry and Coastal | Implemented optional V1 LONG path | [Architecture](OCEAN_V3_ARCHITECTURE.md#coastal-and-bathymetry) |
| Crest Foam / Surface Foam / Crest Filigree | Implemented | [Architecture](OCEAN_V3_ARCHITECTURE.md#foam) |
| Breaker Ribbon Pool | Implemented optional local representation | [Architecture](OCEAN_V3_ARCHITECTURE.md#breaking) |
| Quality profiles | Infrastructure only; not a live quality switch | [Usage guide](OCEAN_V3_USAGE_GUIDE.md#project-settings-and-singletons) |
| Ocean Lab | Implemented reference/debug scene | [Troubleshooting](OCEAN_V3_TROUBLESHOOTING.md#ocean-lab) |
| Vehicle buoyancy/gameplay | Not part of Ocean V3 runtime | [Usage guide](OCEAN_V3_USAGE_GUIDE.md#oceanquery-for-gameplay) |

## Historical / phase reports

The `PHASE_*.md` and `GATE_1_NOTES.md` files are retained as implementation
records. They are useful for validation context and decisions, but they are
not the current API or architecture specification. The historical design
document [WATER_RACE_OCEAN_V3_DESIGN.md](../WATER_RACE_OCEAN_V3_DESIGN.md) is
also retained for the original project direction.

## Reading rule

Use the current architecture and usage guide for production work. Use phase
reports only for historical rationale, test context, and old measurements;
historical performance numbers are not guarantees for the current HEAD.
