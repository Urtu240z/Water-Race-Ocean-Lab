// OceanQuery core nativo (Fase 2C).
// Puerto EXACTO del hot path de OceanQueryReduced (GDScript 2B) a C++ plano,
// SIN godot-cpp, para validar matemática y medir velocidad real.
// No cambia ninguna fórmula; usa std::cos/std::sin estándar.

#pragma once

#include <vector>
#include <cstddef>
#include <cstdint>

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
const int TRUE_BATCH_WARM_STRIDE = S_STRIDE + 2;

// SoA reutilizable para la ruta TRUE_BATCH. Sólo crece cuando la capacidad
// solicitada aumenta; nunca crea objetos por punto durante una consulta.
struct BatchWorkspace {
    size_t capacity = 0;
    std::vector<double> wx, wz, qx, qz;
    std::vector<double> h, dx, dz, dhx, dhz, dxx, dxz, dzx, dzz, vh, vx, vz;
    std::vector<double> cascade_h, cascade_dx, cascade_dz;
    std::vector<double> cascade_dhx, cascade_dhz, cascade_dxx, cascade_dxz, cascade_dzx, cascade_dzz;
    std::vector<double> cascade_vh, cascade_vx, cascade_vz;
    std::vector<double> residual;
    std::vector<int> iterations;
    std::vector<uint8_t> done;
    std::vector<size_t> active_indices;

    void ensure_capacity(size_t required);
};

class OceanQueryCore {
public:
    std::vector<Cascade> cascades;
    double sea_level = 0.0;
    bool prepared_valid = false;
    double prepared_time = 0.0;
    int diag_non_converged = 0;
    // Diagnóstico de la última operación TRUE_BATCH: una evaluación equivale
    // a evaluar todos los modos de las cascadas para un punto activo.
    size_t diag_last_spectral_point_evaluations = 0;
    int diag_last_newton_histogram[5] = {0, 0, 0, 0, 0}; // 0/1/2/3/no-conv.

    // La detección vive en el objeto scalar: ninguna instrucción AVX2 se
    // ejecuta antes de decidir llamar a la translation unit AVX2 aislada.
    bool force_scalar = false;

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
    // Producción: dispatch AVX2 si está disponible; scalar siempre fallback.
    void sample_batch_prepared(const double *positions_xz, size_t n, double *out);

    // Referencia explícita para tests, benchmark y CPUs sin AVX2.
    void sample_batch_scalar_prepared(const double *positions_xz, size_t n, double *out);

    // Subtest aislado: AVX2 en aritmética, std::sin/cos por lane.
    void sample_batch_avx2_scalar_trig_prepared(const double *positions_xz, size_t n, double *out);

    // TRUE_BATCH mode-major: reutiliza Workspace SoA y resuelve Newton de
    // forma colectiva. out tiene n*S_STRIDE doubles.
    void sample_batch_true_prepared(const double *positions_xz, size_t n, double *out);

    // Variante temporal. initial_q_xz contiene la predicción q de cada punto;
    // si un valor no es finito se usa world_xz. out tiene n*(S_STRIDE + 2):
    // el contrato normal seguido de qx,qz resueltos para el siguiente tick.
    void sample_batch_warm_prepared(const double *positions_xz, const double *initial_q_xz,
                                    size_t n, double *out);

    bool avx2_supported() const;
    const char *query_execution_backend() const;

    // Exposición pública de accumulate_ para diagnósticos del PATCH (2C.1A):
    // permite verificar que un nodo del grid reproduce EXACTAMENTE la suma del
    // core DIRECT en ese q (recurrencia de fase vs sin/cos directos).
    void accumulate_public(double qx, double qz, bool use_prepared, double sim_time,
                           double &h, double &dx, double &dz,
                           double &dhx, double &dhz,
                           double &dxx, double &dxz, double &dzx, double &dzz,
                           double &vh, double &vx, double &vz) {
        accumulate_(qx, qz, use_prepared, sim_time, h, dx, dz, dhx, dhz,
                    dxx, dxz, dzx, dzz, vh, vx, vz);
    }

private:
    BatchWorkspace batch_;

    void accumulate_(double qx, double qz, bool use_prepared, double sim_time,
                     double &h, double &dx, double &dz,
                     double &dhx, double &dhz,
                     double &dxx, double &dxz, double &dzx, double &dzz,
                     double &vh, double &vx, double &vz);

    void sample_prepared_(double wx, double wz, double *out);

    void evaluate_true_batch_(const size_t *indices, size_t active_count);
    void evaluate_avx2_batch_(const size_t *indices, size_t active_count, bool vector_sincos);
    void build_sample_from_fields_(size_t point_index, bool converged, double *out) const;
    void solve_true_batch_(size_t n, double *out, bool append_solved_q);
    void solve_avx2_batch_(size_t n, double *out, bool vector_sincos);
};

} // namespace oq
