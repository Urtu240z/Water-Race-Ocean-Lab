// OceanQueryNative — GDExtension (Fase 2C).
// Envoltorio godot-cpp sobre el core C++ portátil (ocean_query_core.h).
// NO reimplementa la matemática: delega en OceanQueryCore (puerto exacto de
// OceanQueryReduced GDScript 2B). El pairing canónico/Nyquist/importance se
// construye en GDScript; aquí sólo se reciben los arrays compactos.

#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

#include <vector>

#include "ocean_query_core.h"

namespace godot {

class OceanQueryNative : public RefCounted {
    GDCLASS(OceanQueryNative, RefCounted)

private:
    oq::OceanQueryCore core_;
    // Buffers C++ contiguos reutilizados; sólo crecen con la capacidad batch.
    std::vector<double> batch_xz_;
    std::vector<double> batch_warm_q_;
    std::vector<double> batch_out_;

    static void _bind_methods();

    // Convierte un sample del core (double out[oq::S_STRIDE]) a PackedFloat64Array.
    PackedFloat64Array sample_to_packed_(const double *out);

public:
    void clear();
    void set_sea_level(double sea_level);

    void set_cascade_data(
        int cascade_index, double inv_n2,
        const PackedFloat64Array &kx, const PackedFloat64Array &ky, const PackedFloat64Array &omega,
        const PackedFloat64Array &a1, const PackedFloat64Array &a2,
        const PackedFloat64Array &c11, const PackedFloat64Array &c12,
        const PackedFloat64Array &c21, const PackedFloat64Array &c22,
        const PackedFloat64Array &parity, const PackedFloat64Array &weight,
        const PackedFloat64Array &h0_re, const PackedFloat64Array &h0_im,
        const PackedFloat64Array &h0n_re, const PackedFloat64Array &h0n_im);

    void finalize_spectrum();
    void ensure_prepared(double simulation_time);

    PackedFloat64Array sample_world(double wx, double wz, double simulation_time);
    PackedFloat64Array sample_prepared(double wx, double wz);
    // Referencia escalar estable.
    PackedFloat64Array sample_batch_prepared(const PackedVector3Array &positions);
    PackedFloat64Array sample_batch(double simulation_time, const PackedVector3Array &positions);
    // Ruta experimental 2C.1B TRUE_BATCH. warm devuelve stride 17: los 15
    // campos normales y qx,qz resueltos para alimentar el tick siguiente.
    PackedFloat64Array sample_batch_true_prepared(const PackedVector3Array &positions);
    PackedFloat64Array sample_batch_warm_prepared(const PackedVector3Array &positions,
                                                  const PackedVector3Array &initial_q);

    int get_diag_non_converged() const;
    int get_diag_last_iterations() const;
    double get_diag_last_residual() const;
    int get_diag_last_spectral_point_evaluations() const;
    PackedInt32Array get_diag_last_newton_histogram() const;
};

} // namespace godot
