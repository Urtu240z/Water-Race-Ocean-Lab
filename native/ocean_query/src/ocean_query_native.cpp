// OceanQueryNative — GDExtension (Fase 2C). Implementación.

#include "ocean_query_native.h"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

using namespace godot;

void OceanQueryNative::_bind_methods() {
    ClassDB::bind_method(D_METHOD("clear"), &OceanQueryNative::clear);
    ClassDB::bind_method(D_METHOD("set_sea_level", "sea_level"), &OceanQueryNative::set_sea_level);
    ClassDB::bind_method(D_METHOD("set_cascade_data",
                                  "cascade_index", "inv_n2",
                                  "kx", "ky", "omega",
                                  "a1", "a2", "c11", "c12", "c21", "c22",
                                  "parity", "weight",
                                  "h0_re", "h0_im", "h0n_re", "h0n_im"),
                         &OceanQueryNative::set_cascade_data);
    ClassDB::bind_method(D_METHOD("finalize_spectrum"), &OceanQueryNative::finalize_spectrum);
    ClassDB::bind_method(D_METHOD("ensure_prepared", "simulation_time"), &OceanQueryNative::ensure_prepared);
    ClassDB::bind_method(D_METHOD("sample_world", "wx", "wz", "simulation_time"), &OceanQueryNative::sample_world);
    ClassDB::bind_method(D_METHOD("sample_prepared", "wx", "wz"), &OceanQueryNative::sample_prepared);
    ClassDB::bind_method(D_METHOD("sample_batch_prepared", "positions"), &OceanQueryNative::sample_batch_prepared);
    ClassDB::bind_method(D_METHOD("sample_batch", "simulation_time", "positions"), &OceanQueryNative::sample_batch);
    ClassDB::bind_method(D_METHOD("get_diag_non_converged"), &OceanQueryNative::get_diag_non_converged);
    ClassDB::bind_method(D_METHOD("get_diag_last_iterations"), &OceanQueryNative::get_diag_last_iterations);
    ClassDB::bind_method(D_METHOD("get_diag_last_residual"), &OceanQueryNative::get_diag_last_residual);
}

void OceanQueryNative::clear() {
    core_.clear();
}

void OceanQueryNative::set_sea_level(double sea_level) {
    core_.sea_level = sea_level;
}

void OceanQueryNative::set_cascade_data(
    int cascade_index, double inv_n2,
    const PackedFloat64Array &kx, const PackedFloat64Array &ky, const PackedFloat64Array &omega,
    const PackedFloat64Array &a1, const PackedFloat64Array &a2,
    const PackedFloat64Array &c11, const PackedFloat64Array &c12,
    const PackedFloat64Array &c21, const PackedFloat64Array &c22,
    const PackedFloat64Array &parity, const PackedFloat64Array &weight,
    const PackedFloat64Array &h0_re, const PackedFloat64Array &h0_im,
    const PackedFloat64Array &h0n_re, const PackedFloat64Array &h0n_im) {
    const size_t count = static_cast<size_t>(kx.size());
    core_.set_cascade_data(
        static_cast<size_t>(cascade_index), inv_n2,
        kx.ptr(), ky.ptr(), omega.ptr(),
        a1.ptr(), a2.ptr(), c11.ptr(), c12.ptr(), c21.ptr(), c22.ptr(),
        parity.ptr(), weight.ptr(),
        h0_re.ptr(), h0_im.ptr(), h0n_re.ptr(), h0n_im.ptr(), count);
}

void OceanQueryNative::finalize_spectrum() {
    core_.finalize_spectrum();
}

void OceanQueryNative::ensure_prepared(double simulation_time) {
    core_.ensure_prepared(simulation_time);
}

PackedFloat64Array OceanQueryNative::sample_to_packed_(const double *out) {
    PackedFloat64Array result;
    result.resize(oq::S_STRIDE);
    for (int i = 0; i < oq::S_STRIDE; ++i) {
        result[i] = out[i];
    }
    return result;
}

PackedFloat64Array OceanQueryNative::sample_world(double wx, double wz, double simulation_time) {
    double out[oq::S_STRIDE];
    core_.sample_world(wx, wz, simulation_time, out);
    return sample_to_packed_(out);
}

PackedFloat64Array OceanQueryNative::sample_prepared(double wx, double wz) {
    double out[oq::S_STRIDE];
    core_.sample_prepared(wx, wz, out);
    return sample_to_packed_(out);
}

PackedFloat64Array OceanQueryNative::sample_batch_prepared(const PackedVector3Array &positions) {
    const size_t n = static_cast<size_t>(positions.size());
    if (n == 0) {
        return PackedFloat64Array();
    }
    // Copia XZ contiguo (el core usa double*).
    std::vector<double> xz(2 * n);
    for (size_t i = 0; i < n; ++i) {
        const Vector3 p = positions[static_cast<int64_t>(i)];
        xz[2 * i] = p.x;
        xz[2 * i + 1] = p.z;
    }
    std::vector<double> out(n * oq::S_STRIDE);
    core_.sample_batch_prepared(xz.data(), n, out.data());
    PackedFloat64Array result;
    result.resize(static_cast<int64_t>(n) * oq::S_STRIDE);
    for (size_t i = 0; i < n * oq::S_STRIDE; ++i) {
        result[static_cast<int64_t>(i)] = out[i];
    }
    return result;
}

PackedFloat64Array OceanQueryNative::sample_batch(double simulation_time, const PackedVector3Array &positions) {
    ensure_prepared(simulation_time);
    return sample_batch_prepared(positions);
}

int OceanQueryNative::get_diag_non_converged() const {
    return core_.diag_non_converged;
}

int OceanQueryNative::get_diag_last_iterations() const {
    return 0;
}

double OceanQueryNative::get_diag_last_residual() const {
    return 0.0;
}
