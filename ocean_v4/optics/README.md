# Ocean V4 Optics — Phase 1

Phase 1 reuses the coastal bake's existing `metrics.r` depth read while the
surface already evaluates shoreline weights. A Beer-Lambert approximation uses
that depth to blend shallow and deep water colours; outside or at the soft edge
of the coastal transform it saturates to a finite deep-water optical depth.

No screen texture, depth texture, extra sampler, raymarch, compute, caustic,
volumetric or persistent state is introduced. Godot PBR remains responsible for
the existing Fresnel/specular response, while crest foam is mixed afterwards so
it remains opaque and rough.
