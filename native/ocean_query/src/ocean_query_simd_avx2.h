// Kernel AVX2 aislado de OceanQuery. Este header no incluye intrinsics: el
// core scalar puede declararlo y decidir el dispatch en CPUs sin AVX2.
#pragma once

#include <cstddef>
#include <vector>

namespace oq {

struct Cascade;
struct BatchWorkspace;

// Sólo debe llamarse tras OceanQueryCore::avx2_supported(). vector_sincos
// selecciona polinomio AVX2; false conserva std::sin/cos por lane para medir
// el peso de trigonometría sin cambiar el resto de la aritmética.
void evaluate_batch_avx2(const std::vector<Cascade> &cascades, BatchWorkspace &batch,
                         const size_t *indices, size_t active_count, bool vector_sincos,
                         bool fuse_coastal_q = false);

// C(F(q)) exacto del LONG coastal: sólo recorre pares de peso no nulo y usa
// el mismo sincos vectorial que el kernel base.
void evaluate_coastal_long_batch_avx2(const Cascade &cascade, BatchWorkspace &batch,
                                      const size_t *indices, size_t active_count, bool vector_sincos);

// 5R.1E: altura de UNA banda (sólo h, sin coastal ni derivadas) para el crest
// sharpening. q viene de arrays explícitos (center/±dir*eps) y out_h recibe un
// valor por punto activo. Replica band_height_ del core scalar.
void evaluate_band_height_avx2(const Cascade &cascade, const double *qx, const double *qz,
                               const size_t *indices, size_t active_count,
                               double *out_h, bool vector_sincos);

// Sonda aislada de precisión para los tests/benchmarks de trigonometría.
void sincos_pd_avx2(const double *phi4, double *sin4, double *cos4);

} // namespace oq
