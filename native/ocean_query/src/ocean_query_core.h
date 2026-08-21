// OceanQuery core nativo (Fase 2C).
// Puerto EXACTO del hot path de OceanQueryReduced (GDScript 2B) a C++ plano,
// SIN godot-cpp, para validar matemática y medir velocidad real.
// No cambia ninguna fórmula; usa std::cos/std::sin estándar.

#pragma once

#include <vector>
#include <cstddef>

namespace oq {

struct Cascade {
    std::vector<double> kx, ky, omega;
    std::vector<double> a1, a2, c11, c12, c21, c22;
    std::vector<double> parity, weight;
    std::vector<double> h0_re, h0_im, h0n_re, h0n_im;
    std::vector<double> ev_h_re, ev_h_im, ev_v_re, ev_v_im;
    double inv_n2 = 0.0;
};

// Stride del buffer de salida (mismo contrato que la API nativa GDExtension).
enum SampleIndex {
    S_VALID = 0,
    S_HEIGHT,
    S_DX,
    S_DY,
    S_DZ,
    S_NX,
    S_NY,
    S_NZ,
    S_VX,
    S_VY,
    S_VZ,
    S_JACOBIAN_DET,
    S_FOLDOVER,
    S_RESIDUAL,
    S_ITERATIONS,
    S_STRIDE,
};

const int MAX_ITERATIONS = 3;
const double POSITION_TOLERANCE_M = 1.0e-3;
const double JACOBIAN_EPSILON = 1.0e-6;

class OceanQueryCore {
public:
    std::vector<Cascade> cascades;
    double sea_level = 0.0;
    bool prepared_valid = false;
    double prepared_time = 0.0;
    int diag_non_converged = 0;

    void clear() { cascades.clear(); prepared_valid = false; }

    void set_cascade_data(size_t cascade_index, double inv_n2,
                          const double *kx, const double *ky, const double *omega,
                          const double *a1, const double *a2,
                          const double *c11, const double *c12, const double *c21, const double *c22,
                          const double *parity, const double *weight,
                          const double *h0_re, const double *h0_im,
                          const double *h0n_re, const double *h0n_im,
                          size_t count);

    void finalize_spectrum();

    void ensure_prepared(double simulation_time);

    // Evalúa una posición world y escribe el sample en out (S_STRIDE doubles).
    // Si out == nullptr, sólo mide tiempo.
    void sample_world(double wx, double wz, double simulation_time, double *out);

    // Igual que sample_world pero asume ensure_prepared ya llamado.
    void sample_prepared(double wx, double wz, double *out) { sample_prepared_(wx, wz, out); }

    // Batch: evalúa n posiciones; out debe tener n*S_STRIDE doubles.
    void sample_batch_prepared(const double *positions_xz, size_t n, double *out);

private:
    void accumulate_(double qx, double qz, bool use_prepared, double sim_time,
                     double &h, double &dx, double &dz,
                     double &dhx, double &dhz,
                     double &dxx, double &dxz, double &dzx, double &dzz,
                     double &vh, double &vx, double &vz);

    void sample_prepared_(double wx, double wz, double *out);
};

} // namespace oq
