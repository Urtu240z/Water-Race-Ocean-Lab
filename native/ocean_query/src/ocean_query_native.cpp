// OceanQueryNative — GDExtension (Fase 2C). Implementación.

#include "ocean_query_native.h"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

#include <limits>

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
    ClassDB::bind_method(D_METHOD("set_coastal_long_weights", "pos", "neg"), &OceanQueryNative::set_coastal_long_weights);
    ClassDB::bind_method(D_METHOD("set_coastal_runtime", "origin_x", "origin_z", "width", "height", "cell_size", "detj_safe", "deep_x", "deep_z", "det_j", "j00", "j01", "j10", "j11", "warp_valid", "shoaling", "propagation_valid"), &OceanQueryNative::set_coastal_runtime);
    ClassDB::bind_method(D_METHOD("clear_coastal"), &OceanQueryNative::clear_coastal);
    ClassDB::bind_method(D_METHOD("set_coastal_profile_enabled", "enabled"), &OceanQueryNative::set_coastal_profile_enabled);
    ClassDB::bind_method(D_METHOD("reset_coastal_profile"), &OceanQueryNative::reset_coastal_profile);
    ClassDB::bind_method(D_METHOD("get_coastal_profile_us"), &OceanQueryNative::get_coastal_profile_us);
    ClassDB::bind_method(D_METHOD("get_coastal_pair_counts"), &OceanQueryNative::get_coastal_pair_counts);
    ClassDB::bind_method(D_METHOD("ensure_prepared", "simulation_time"), &OceanQueryNative::ensure_prepared);
    ClassDB::bind_method(D_METHOD("sample_world", "wx", "wz", "simulation_time"), &OceanQueryNative::sample_world);
    ClassDB::bind_method(D_METHOD("sample_prepared", "wx", "wz"), &OceanQueryNative::sample_prepared);
    ClassDB::bind_method(D_METHOD("sample_batch_prepared", "positions"), &OceanQueryNative::sample_batch_prepared);
    ClassDB::bind_method(D_METHOD("sample_batch_scalar_prepared", "positions"), &OceanQueryNative::sample_batch_scalar_prepared);
    ClassDB::bind_method(D_METHOD("sample_batch_avx2_scalar_trig_prepared", "positions"), &OceanQueryNative::sample_batch_avx2_scalar_trig_prepared);
    ClassDB::bind_method(D_METHOD("sample_batch", "simulation_time", "positions"), &OceanQueryNative::sample_batch);
    ClassDB::bind_method(D_METHOD("sample_batch_true_prepared", "positions"), &OceanQueryNative::sample_batch_true_prepared);
    ClassDB::bind_method(D_METHOD("sample_batch_warm_prepared", "positions", "initial_q"), &OceanQueryNative::sample_batch_warm_prepared);
    ClassDB::bind_method(D_METHOD("get_diag_non_converged"), &OceanQueryNative::get_diag_non_converged);
    ClassDB::bind_method(D_METHOD("get_diag_last_iterations"), &OceanQueryNative::get_diag_last_iterations);
    ClassDB::bind_method(D_METHOD("get_diag_last_residual"), &OceanQueryNative::get_diag_last_residual);
    ClassDB::bind_method(D_METHOD("get_diag_last_spectral_point_evaluations"), &OceanQueryNative::get_diag_last_spectral_point_evaluations);
    ClassDB::bind_method(D_METHOD("get_diag_last_newton_histogram"), &OceanQueryNative::get_diag_last_newton_histogram);
    ClassDB::bind_method(D_METHOD("get_cpu_supports_avx2"), &OceanQueryNative::get_cpu_supports_avx2);
    ClassDB::bind_method(D_METHOD("get_query_execution_backend"), &OceanQueryNative::get_query_execution_backend);
    ClassDB::bind_method(D_METHOD("set_force_scalar", "enabled"), &OceanQueryNative::set_force_scalar);
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

void OceanQueryNative::set_coastal_long_weights(const PackedFloat64Array &pos, const PackedFloat64Array &neg) {
    if (pos.size() != neg.size()) { core_.clear_coastal(); return; }
    core_.set_coastal_long_weights(pos.ptr(), neg.ptr(), static_cast<size_t>(pos.size()));
}

void OceanQueryNative::set_coastal_profile_enabled(bool enabled) { core_.set_coastal_profile_enabled(enabled); }

void OceanQueryNative::reset_coastal_profile() { core_.reset_coastal_profile(); }

PackedInt64Array OceanQueryNative::get_coastal_profile_us() const {
    PackedInt64Array values;
    values.resize(6);
    values[0] = static_cast<int64_t>(core_.coastal_profile.base_us);
    values[1] = static_cast<int64_t>(core_.coastal_profile.sampler_us);
    values[2] = static_cast<int64_t>(core_.coastal_profile.cq_us);
    values[3] = static_cast<int64_t>(core_.coastal_profile.cdeep_us);
    values[4] = static_cast<int64_t>(core_.coastal_profile.combine_us);
    values[5] = static_cast<int64_t>(core_.coastal_profile.calls);
    return values;
}

PackedInt64Array OceanQueryNative::get_coastal_pair_counts() const {
    PackedInt64Array values;
    values.resize(2);
    values[0] = static_cast<int64_t>(core_.coastal_nonzero_pair_count());
    values[1] = static_cast<int64_t>(core_.coastal_pair_count());
    return values;
}

void OceanQueryNative::set_coastal_runtime(double origin_x, double origin_z, int width, int height,
                                           double cell_size, double detj_safe,
                                           const PackedFloat32Array &deep_x, const PackedFloat32Array &deep_z,
                                           const PackedFloat32Array &det_j,
                                           const PackedFloat32Array &j00, const PackedFloat32Array &j01,
                                           const PackedFloat32Array &j10, const PackedFloat32Array &j11,
                                           const PackedByteArray &warp_valid, const PackedFloat32Array &shoaling,
                                           const PackedByteArray &propagation_valid) {
    const size_t count = static_cast<size_t>(width) * static_cast<size_t>(height);
    if (width < 2 || height < 2 || deep_x.size() != static_cast<int64_t>(count) || deep_z.size() != static_cast<int64_t>(count)
        || det_j.size() != static_cast<int64_t>(count) || j00.size() != static_cast<int64_t>(count)
        || j01.size() != static_cast<int64_t>(count) || j10.size() != static_cast<int64_t>(count) || j11.size() != static_cast<int64_t>(count)
        || shoaling.size() != static_cast<int64_t>(count) || warp_valid.size() != static_cast<int64_t>(count)
        || propagation_valid.size() != static_cast<int64_t>(count)) { core_.clear_coastal(); return; }
    const auto copy_f32 = [count](const PackedFloat32Array &src) {
        std::vector<double> dst(count);
        const float *in = src.ptr();
        for (size_t i = 0; i < count; ++i) { dst[i] = static_cast<double>(in[i]); }
        return dst;
    };
    const std::vector<double> dx = copy_f32(deep_x), dz = copy_f32(deep_z), det = copy_f32(det_j);
    const std::vector<double> a = copy_f32(j00), b = copy_f32(j01), c = copy_f32(j10), d = copy_f32(j11), sh = copy_f32(shoaling);
    core_.set_coastal_runtime(origin_x, origin_z, width, height, cell_size, detj_safe,
                              dx.data(), dz.data(), det.data(), a.data(), b.data(), c.data(), d.data(),
                              reinterpret_cast<const uint8_t *>(warp_valid.ptr()), sh.data(),
                              reinterpret_cast<const uint8_t *>(propagation_valid.ptr()), count);
}

void OceanQueryNative::clear_coastal() { core_.clear_coastal(); }

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
    batch_xz_.resize(2 * n);
    for (size_t i = 0; i < n; ++i) {
        const Vector3 p = positions[static_cast<int64_t>(i)];
        batch_xz_[2 * i] = p.x;
        batch_xz_[2 * i + 1] = p.z;
    }
    batch_out_.resize(n * oq::S_STRIDE);
    core_.sample_batch_prepared(batch_xz_.data(), n, batch_out_.data());
    PackedFloat64Array result;
    result.resize(static_cast<int64_t>(n) * oq::S_STRIDE);
    for (size_t i = 0; i < n * oq::S_STRIDE; ++i) {
        result[static_cast<int64_t>(i)] = batch_out_[i];
    }
    return result;
}

PackedFloat64Array OceanQueryNative::sample_batch_scalar_prepared(const PackedVector3Array &positions) {
    const size_t n = static_cast<size_t>(positions.size());
    if (n == 0) { return PackedFloat64Array(); }
    batch_xz_.resize(2 * n);
    for (size_t i = 0; i < n; ++i) {
        const Vector3 p = positions[static_cast<int64_t>(i)];
        batch_xz_[2 * i] = p.x; batch_xz_[2 * i + 1] = p.z;
    }
    batch_out_.resize(n * oq::S_STRIDE);
    core_.sample_batch_scalar_prepared(batch_xz_.data(), n, batch_out_.data());
    PackedFloat64Array result;
    result.resize(static_cast<int64_t>(batch_out_.size()));
    for (size_t i = 0; i < batch_out_.size(); ++i) result[static_cast<int64_t>(i)] = batch_out_[i];
    return result;
}

PackedFloat64Array OceanQueryNative::sample_batch_avx2_scalar_trig_prepared(const PackedVector3Array &positions) {
    const size_t n = static_cast<size_t>(positions.size());
    if (n == 0) { return PackedFloat64Array(); }
    batch_xz_.resize(2 * n);
    for (size_t i = 0; i < n; ++i) {
        const Vector3 p = positions[static_cast<int64_t>(i)];
        batch_xz_[2 * i] = p.x; batch_xz_[2 * i + 1] = p.z;
    }
    batch_out_.resize(n * oq::S_STRIDE);
    core_.sample_batch_avx2_scalar_trig_prepared(batch_xz_.data(), n, batch_out_.data());
    PackedFloat64Array result;
    result.resize(static_cast<int64_t>(batch_out_.size()));
    for (size_t i = 0; i < batch_out_.size(); ++i) result[static_cast<int64_t>(i)] = batch_out_[i];
    return result;
}

PackedFloat64Array OceanQueryNative::sample_batch_true_prepared(const PackedVector3Array &positions) {
    const size_t n = static_cast<size_t>(positions.size());
    if (n == 0) { return PackedFloat64Array(); }
    batch_xz_.resize(2 * n);
    for (size_t i = 0; i < n; ++i) {
        const Vector3 p = positions[static_cast<int64_t>(i)];
        batch_xz_[2 * i] = p.x;
        batch_xz_[2 * i + 1] = p.z;
    }
    batch_out_.resize(n * oq::S_STRIDE);
    core_.sample_batch_true_prepared(batch_xz_.data(), n, batch_out_.data());
    PackedFloat64Array result;
    result.resize(static_cast<int64_t>(batch_out_.size()));
    for (size_t i = 0; i < batch_out_.size(); ++i) { result[static_cast<int64_t>(i)] = batch_out_[i]; }
    return result;
}

PackedFloat64Array OceanQueryNative::sample_batch_warm_prepared(const PackedVector3Array &positions,
                                                                  const PackedVector3Array &initial_q) {
    const size_t n = static_cast<size_t>(positions.size());
    if (n == 0) { return PackedFloat64Array(); }
    batch_xz_.resize(2 * n);
    batch_warm_q_.resize(2 * n);
    for (size_t i = 0; i < n; ++i) {
        const Vector3 p = positions[static_cast<int64_t>(i)];
        batch_xz_[2 * i] = p.x;
        batch_xz_[2 * i + 1] = p.z;
        if (i < static_cast<size_t>(initial_q.size())) {
            const Vector3 q = initial_q[static_cast<int64_t>(i)];
            batch_warm_q_[2 * i] = q.x;
            batch_warm_q_[2 * i + 1] = q.z;
        } else {
            batch_warm_q_[2 * i] = std::numeric_limits<double>::quiet_NaN();
            batch_warm_q_[2 * i + 1] = std::numeric_limits<double>::quiet_NaN();
        }
    }
    batch_out_.resize(n * oq::TRUE_BATCH_WARM_STRIDE);
    core_.sample_batch_warm_prepared(batch_xz_.data(), batch_warm_q_.data(), n, batch_out_.data());
    PackedFloat64Array result;
    result.resize(static_cast<int64_t>(batch_out_.size()));
    for (size_t i = 0; i < batch_out_.size(); ++i) { result[static_cast<int64_t>(i)] = batch_out_[i]; }
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

int OceanQueryNative::get_diag_last_spectral_point_evaluations() const {
    return static_cast<int>(core_.diag_last_spectral_point_evaluations);
}

PackedInt32Array OceanQueryNative::get_diag_last_newton_histogram() const {
    PackedInt32Array result;
    result.resize(5);
    for (int i = 0; i < 5; ++i) { result[i] = core_.diag_last_newton_histogram[i]; }
    return result;
}

bool OceanQueryNative::get_cpu_supports_avx2() const { return core_.avx2_supported(); }

String OceanQueryNative::get_query_execution_backend() const { return String(core_.query_execution_backend()); }

void OceanQueryNative::set_force_scalar(bool enabled) { core_.force_scalar = enabled; }
