# Ocean V4 Reflections — Phase 1

Phase 1 uses Godot's existing spatial PBR environment/specular response only.
It supplies a physical dielectric water F0 and roughness derived from the
already-displaced wave slope and camera distance. The shader still consumes the
same V4 LONG, MID, SHORT and coastal normal/displacement contract.

It intentionally owns no screen, depth, viewport, compute, temporal or SSPR
resource. Local-object reflections (boats, island and shore) therefore remain
out of scope for this phase and are a possible future Phase 2 decision.
