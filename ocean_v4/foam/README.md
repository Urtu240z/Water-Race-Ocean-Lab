# Ocean V4 Crest Foam — Phase 1B

Phase 1B is an ephemeral material response, not a foam simulation. Positive
displaced height and LONG slope produce the crest signal; SHORT never triggers
coverage. The interpolated scalar is shaped in fragment into a soft edge and a
denser core. MID only modulates density within a non-zero floor, so it cannot
cut a crest into periodic dots. A world-space distance fade limits foam to the
useful near and middle field.

The implementation adds only scalar shaping plus one `fwidth` anti-alias band
in fragment. It has no history, topology texture, compute dispatch, extra
sampler, readback, Surface Foam, breakers or boat/wake contribution. When the
crest signal disappears, so does the foam. Those omitted systems remain future
decisions rather than hidden dependencies.
