// OceanQueryNative — GDExtension (Fase 2C).
// Envoltorio godot-cpp sobre el core C++ portátil (ocean_query_core.h).
// NO reimplementa la matemática: delega en OceanQueryCore (puerto exacto de
// OceanQueryReduced GDScript 2B). El pairing canónico/Nyquist/importance se
// construye en GDScript; aquí sólo se reciben los arrays compactos.

#pragma once

#include <godot_cpp/classes/ref_counted.hpp>

#include "ocean_query_core.h"

namespace godot {

class OceanQueryNative : public RefCounted {
    GDCLASS(OceanQueryNative, RefCounted)

private:
    oq::OceanQueryCore core_;
    // Buffer plano de salida batch reutilizado (evita allocs por llamada).
    PackedFloat64Array batch_out_;

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
    PackedFloat64Array sample_batch_prepared(const PackedVector3Array &positions);
    PackedFloat64Array sample_batch(double simulation_time, const PackedVector3Array &positions);

    int get_diag_non_converged() const;
    int get_diag_last_iterations() const;
    double get_diag_last_residual() const;
};

} // namespace godot
