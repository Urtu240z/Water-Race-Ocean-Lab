# Underwater V2 recovery pass

## Confirmed causes

- **RenderingDevice errors:** the POST effect sampled the auxiliary
  `ViewportTexture` before its first frame and independently fetched the main
  depth layer. Those handles were not guaranteed to be valid at callback time,
  yet the code still built a uniform set and dispatched. The corrected path
  validates the color image, interface texture, opaque-depth snapshot, shader,
  pipeline, sampler and parameter buffer before every bind/dispatch. The
  opaque depth snapshot is produced by a separate PRE_TRANSPARENT effect.
- **Square Snell boundary:** the old criterion used screen-space/viewport
  distance, so its boundary inherited the framebuffer aspect ratio. The
  compositor now derives incidence from the reconstructed world view ray and
  the interface macro normal; TIR is the physical Snell discriminant.
- **Missing mixed medium:** a CPU FFT query (and later a whole-frame medium
  boolean) could not describe a wave crossing different pixels. The CPU state
  is now only an inexpensive mean-sea-level AIR/WATER/CROSSING guard. A single
  full-resolution WaterInterface SubViewport renders the displaced clipmap
  geometry and encodes normalized normal/depth plus the camera-side bit per
  covered pixel. The compositor uses that buffer as the sole waterline authority.

## Interface architecture

The auxiliary viewport shares the Ocean V3 displaced clipmap meshes but uses a
compile-time `OCEAN_WATER_INTERFACE` shader variant. Its fragment stage is
unshaded and writes only normalized RG oct-normal, B interface depth and A
validity/side. No second scene render, FFT raymarch, CPU readback or per-pixel
OceanQuery is introduced. The PRE opaque depth capture is used only as the
opaque scene endpoint; it is never differenced against the interface buffer.
