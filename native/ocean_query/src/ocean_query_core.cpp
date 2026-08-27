// OceanQuery core nativo (Fase 2C) — implementación.
// Puerto EXACTO de OceanQueryReduced._accumulate / _sample_world / _prepare_time.
// La matemática NO cambia respecto a 2B (GDScript).

#include "ocean_query_core.h"
#include "ocean_query_simd_avx2.h"

#include <cmath>
#include <cstring>
#include <algorithm>
#include <chrono>

#if defined(_M_X64) || defined(_M_IX86)
#include <intrin.h>
#endif

namespace oq {

namespace {

inline double smoothstep01(double edge0, double edge1, double x) {
    if (edge1 <= edge0) { return x > edge0 ? 1.0 : 0.0; }
    const double t = std::max(0.0, std::min(1.0, (x - edge0) / (edge1 - edge0)));
    return t * t * (3.0 - 2.0 * t);
}

inline double bilinear(const std::vector<double> &values, size_t i00, size_t i10, size_t i01, size_t i11, double tx, double tz) {
    return (1.0 - tz) * ((1.0 - tx) * values[i00] + tx * values[i10]) + tz * ((1.0 - tx) * values[i01] + tx * values[i11]);
}

inline double bilinear_byte(const std::vector<uint8_t> &values, size_t i00, size_t i10, size_t i01, size_t i11, double tx, double tz) {
    return (1.0 - tz) * ((1.0 - tx) * static_cast<double>(values[i00]) + tx * static_cast<double>(values[i10])) + tz * ((1.0 - tx) * static_cast<double>(values[i01]) + tx * static_cast<double>(values[i11]));
}

// Compilado en la TU scalar: esta función no contiene AVX y es segura antes
// del dispatch. AVX requiere CPU, OSXSAVE y XMM/YMM habilitados por el SO.
bool detect_avx2_runtime() {
#if defined(_M_X64) || defined(_M_IX86)
    int regs[4] = {0, 0, 0, 0};
    __cpuidex(regs, 0, 0);
    if (regs[0] < 7) { return false; }
    __cpuidex(regs, 1, 0);
    const bool avx = (regs[2] & (1 << 28)) != 0;
    const bool osxsave = (regs[2] & (1 << 27)) != 0;
    if (!avx || !osxsave) { return false; }
    const unsigned __int64 xcr0 = _xgetbv(0);
    if ((xcr0 & 0x6) != 0x6) { return false; }
    __cpuidex(regs, 7, 0);
    return (regs[1] & (1 << 5)) != 0;
#else
    return false;
#endif
}

} // namespace

bool CoastalRuntime::sample(double qx, double qz, CoastalSample &out) const {
    out.deep_x = qx; out.deep_z = qz; out.confidence = 0.0; out.effective_shoaling = 1.0;
    out.j00 = 1.0; out.j01 = 0.0; out.j10 = 0.0; out.j11 = 1.0;
    if (!enabled || width < 2 || height < 2 || cell_size <= 0.0) { return false; }
    const double gx = (qx - origin_x) / cell_size, gz = (qz - origin_z) / cell_size;
    if (gx < 0.0 || gz < 0.0 || gx > static_cast<double>(width - 1) || gz > static_cast<double>(height - 1)) { return false; }
    const int x0 = std::min(static_cast<int>(std::floor(gx)), width - 2);
    const int z0 = std::min(static_cast<int>(std::floor(gz)), height - 2);
    const double tx = gx - static_cast<double>(x0), tz = gz - static_cast<double>(z0);
    const size_t i00 = static_cast<size_t>(z0 * width + x0), i10 = i00 + 1, i01 = i00 + static_cast<size_t>(width), i11 = i01 + 1;
    // has_coastal_data(): alpha linear del field > 0.5, igual que shader.
    if (bilinear_byte(propagation_valid, i00, i10, i01, i11, tx, tz) <= 0.5) { return false; }
    out.deep_x = bilinear(deep_x, i00, i10, i01, i11, tx, tz);
    out.deep_z = bilinear(deep_z, i00, i10, i01, i11, tx, tz);
    out.j00 = bilinear(j00, i00, i10, i01, i11, tx, tz);
    out.j01 = bilinear(j01, i00, i10, i01, i11, tx, tz);
    out.j10 = bilinear(j10, i00, i10, i01, i11, tx, tz);
    out.j11 = bilinear(j11, i00, i10, i01, i11, tx, tz);
    out.confidence = smoothstep01(0.0, detj_safe, bilinear(det_j, i00, i10, i01, i11, tx, tz));
    out.confidence *= bilinear_byte(warp_valid, i00, i10, i01, i11, tx, tz);
    if (out.confidence <= 0.0) {
        out.deep_x = qx; out.deep_z = qz; out.j00 = 1.0; out.j01 = 0.0; out.j10 = 0.0; out.j11 = 1.0;
        return false;
    }
    out.effective_shoaling = 1.0 + (bilinear(shoaling, i00, i10, i01, i11, tx, tz) - 1.0) * out.confidence;
    return true;
}

void BatchWorkspace::ensure_capacity(size_t required) {
    if (required <= capacity) {
        return;
    }
    capacity = required;
    wx.resize(capacity); wz.resize(capacity); qx.resize(capacity); qz.resize(capacity);
    h.resize(capacity); dx.resize(capacity); dz.resize(capacity);
    dhx.resize(capacity); dhz.resize(capacity); dxx.resize(capacity); dxz.resize(capacity);
    dzx.resize(capacity); dzz.resize(capacity); vh.resize(capacity); vx.resize(capacity); vz.resize(capacity);
    cascade_h.resize(capacity); cascade_dx.resize(capacity); cascade_dz.resize(capacity);
    cascade_dhx.resize(capacity); cascade_dhz.resize(capacity); cascade_dxx.resize(capacity);
    cascade_dxz.resize(capacity); cascade_dzx.resize(capacity); cascade_dzz.resize(capacity);
    cascade_vh.resize(capacity); cascade_vx.resize(capacity); cascade_vz.resize(capacity);
    residual.resize(capacity);
    iterations.resize(capacity);
    done.resize(capacity);
    active_indices.resize(capacity);
    coastal_active_indices.resize(capacity);
    coastal_samples.resize(capacity);
    coastal_deep_x.resize(capacity); coastal_deep_z.resize(capacity);
    coastal_h.resize(capacity); coastal_dx.resize(capacity); coastal_dz.resize(capacity);
    coastal_dhx.resize(capacity); coastal_dhz.resize(capacity); coastal_dxx.resize(capacity); coastal_dxz.resize(capacity);
    coastal_dzx.resize(capacity); coastal_dzz.resize(capacity); coastal_vh.resize(capacity); coastal_vx.resize(capacity); coastal_vz.resize(capacity);
    coastal_deep_h.resize(capacity); coastal_deep_dx.resize(capacity); coastal_deep_dz.resize(capacity);
    coastal_deep_dhx.resize(capacity); coastal_deep_dhz.resize(capacity); coastal_deep_dxx.resize(capacity); coastal_deep_dxz.resize(capacity);
    coastal_deep_dzx.resize(capacity); coastal_deep_dzz.resize(capacity); coastal_deep_vh.resize(capacity); coastal_deep_vx.resize(capacity); coastal_deep_vz.resize(capacity);
    // 5R.1E: scratch del batch sharpened.
    sharpen_cdx.resize(capacity); sharpen_cdz.resize(capacity);
    sharpen_lqx.resize(capacity); sharpen_lqz.resize(capacity);
    sharpen_rqx.resize(capacity); sharpen_rqz.resize(capacity);
    band_l_c.resize(capacity); band_l_l.resize(capacity); band_l_r.resize(capacity);
    band_m_c.resize(capacity); band_m_l.resize(capacity); band_m_r.resize(capacity);
    jac_a.resize(capacity); jac_b.resize(capacity); jac_c.resize(capacity); jac_d.resize(capacity);
    fd_dx.resize(capacity); fd_dz.resize(capacity);
    fd_save_qx.resize(capacity); fd_save_qz.resize(capacity);
}

void OceanQueryCore::set_cascade_data(size_t cascade_index, double inv_n2,
                                      const double *kx, const double *ky, const double *omega,
                                      const double *a1, const double *a2,
                                      const double *c11, const double *c12,
                                      const double *c21, const double *c22,
                                      const double *parity, const double *weight,
                                      const double *h0_re, const double *h0_im,
                                      const double *h0n_re, const double *h0n_im,
                                      size_t count) {
    if (cascade_index >= cascades.size()) {
        cascades.resize(cascade_index + 1);
    }
    Cascade &c = cascades[cascade_index];
    c.inv_n2 = inv_n2;
    c.kx.assign(kx, kx + count);
    c.ky.assign(ky, ky + count);
    c.omega.assign(omega, omega + count);
    c.a1.assign(a1, a1 + count);
    c.a2.assign(a2, a2 + count);
    c.c11.assign(c11, c11 + count);
    c.c12.assign(c12, c12 + count);
    c.c21.assign(c21, c21 + count);
    c.c22.assign(c22, c22 + count);
    c.parity.assign(parity, parity + count);
    c.weight.assign(weight, weight + count);
    c.h0_re.assign(h0_re, h0_re + count);
    c.h0_im.assign(h0_im, h0_im + count);
    c.h0n_re.assign(h0n_re, h0n_re + count);
    c.h0n_im.assign(h0n_im, h0n_im + count);
    prepared_valid = false;
    breaker_prepared_valid = false;
}

void OceanQueryCore::finalize_spectrum() {
    for (Cascade &c : cascades) {
        const size_t count = c.kx.size();
        c.ev_h_re.assign(count, 0.0);
        c.ev_h_im.assign(count, 0.0);
        c.ev_v_re.assign(count, 0.0);
        c.ev_v_im.assign(count, 0.0);
        c.ev_a_h_re.assign(count, 0.0); c.ev_a_h_im.assign(count, 0.0);
        c.ev_b_h_re.assign(count, 0.0); c.ev_b_h_im.assign(count, 0.0);
        c.ev_a_v_re.assign(count, 0.0); c.ev_a_v_im.assign(count, 0.0);
        c.ev_b_v_re.assign(count, 0.0); c.ev_b_v_im.assign(count, 0.0);
        c.ev_coastal_h_re.assign(count, 0.0); c.ev_coastal_h_im.assign(count, 0.0);
        c.ev_coastal_v_re.assign(count, 0.0); c.ev_coastal_v_im.assign(count, 0.0);
        c.coastal_f_h.assign(count, 0.0); c.coastal_f_dx.assign(count, 0.0); c.coastal_f_dz.assign(count, 0.0); c.coastal_f_dhx.assign(count, 0.0); c.coastal_f_dhz.assign(count, 0.0);
        c.coastal_f_dxx.assign(count, 0.0); c.coastal_f_dxz.assign(count, 0.0); c.coastal_f_dzx.assign(count, 0.0); c.coastal_f_dzz.assign(count, 0.0); c.coastal_f_vh.assign(count, 0.0); c.coastal_f_vx.assign(count, 0.0); c.coastal_f_vz.assign(count, 0.0);
    }
    prepared_valid = false;
    breaker_prepared_valid = false;
}

void OceanQueryCore::set_coastal_long_weights(const double *pos, const double *neg, size_t count) {
    if (cascades.empty()) { return; }
    Cascade &c = cascades[0];
    if (count != c.kx.size()) { coastal.clear(); return; }
    c.coastal_weight_pos.assign(pos, pos + count);
    c.coastal_weight_neg.assign(neg, neg + count);
    c.coastal_nonzero_indices.clear();
    c.coastal_nonzero_indices.reserve(count);
    for (size_t idx = 0; idx < count; ++idx) {
        if (pos[idx] != 0.0 || neg[idx] != 0.0) {
            c.coastal_nonzero_indices.push_back(idx);
        }
    }
}

void OceanQueryCore::set_coastal_runtime(double origin_x, double origin_z, int width, int height,
                                         double cell_size, double detj_safe,
                                         const double *deep_x, const double *deep_z, const double *det_j,
                                         const double *j00, const double *j01, const double *j10, const double *j11,
                                         const uint8_t *warp_valid, const double *shoaling,
                                         const uint8_t *propagation_valid, size_t count) {
    if (width < 2 || height < 2 || cell_size <= 0.0 || count != static_cast<size_t>(width * height)) { coastal.clear(); return; }
    coastal.origin_x = origin_x; coastal.origin_z = origin_z; coastal.width = width; coastal.height = height;
    coastal.cell_size = cell_size; coastal.detj_safe = detj_safe;
    coastal.deep_x.assign(deep_x, deep_x + count); coastal.deep_z.assign(deep_z, deep_z + count);
    coastal.det_j.assign(det_j, det_j + count); coastal.j00.assign(j00, j00 + count);
    coastal.j01.assign(j01, j01 + count); coastal.j10.assign(j10, j10 + count); coastal.j11.assign(j11, j11 + count);
    coastal.warp_valid.assign(warp_valid, warp_valid + count); coastal.shoaling.assign(shoaling, shoaling + count);
    coastal.propagation_valid.assign(propagation_valid, propagation_valid + count);
    coastal.enabled = true;
}

void OceanQueryCore::ensure_prepared(double simulation_time) {
    if (prepared_valid && prepared_time == simulation_time) {
        return;
    }
    prepared_valid = true;
    prepared_time = simulation_time;
    for (Cascade &c : cascades) {
        const size_t count = c.kx.size();
        for (size_t idx = 0; idx < count; ++idx) {
            const double wt = c.omega[idx] * simulation_time;
            const double cw = std::cos(wt);
            const double sw = std::sin(wt);
            const double a_re = c.h0_re[idx] * cw - c.h0_im[idx] * sw;
            const double a_im = c.h0_re[idx] * sw + c.h0_im[idx] * cw;
            const double b_re = c.h0n_re[idx] * cw + c.h0n_im[idx] * sw;
            const double b_im = -c.h0n_re[idx] * sw + c.h0n_im[idx] * cw;
            c.ev_h_re[idx] = a_re + b_re;
            c.ev_h_im[idx] = a_im + b_im;
            c.ev_v_re[idx] = c.omega[idx] * (-a_im + b_im);
            c.ev_v_im[idx] = c.omega[idx] * (a_re - b_re);
            c.ev_a_h_re[idx] = a_re; c.ev_a_h_im[idx] = a_im;
            c.ev_b_h_re[idx] = b_re; c.ev_b_h_im[idx] = b_im;
            c.ev_a_v_re[idx] = -c.omega[idx] * a_im; c.ev_a_v_im[idx] = c.omega[idx] * a_re;
            c.ev_b_v_re[idx] = c.omega[idx] * b_im; c.ev_b_v_im[idx] = -c.omega[idx] * b_re;
            // Mantiene exactamente el orden de C original: peso*A + peso*B.
            if (idx < c.coastal_weight_pos.size() && idx < c.coastal_weight_neg.size()) {
                c.ev_coastal_h_re[idx] = c.coastal_weight_pos[idx] * a_re + c.coastal_weight_neg[idx] * b_re;
                c.ev_coastal_h_im[idx] = c.coastal_weight_pos[idx] * a_im + c.coastal_weight_neg[idx] * b_im;
                c.ev_coastal_v_re[idx] = c.coastal_weight_pos[idx] * c.ev_a_v_re[idx] + c.coastal_weight_neg[idx] * c.ev_b_v_re[idx];
                c.ev_coastal_v_im[idx] = c.coastal_weight_pos[idx] * c.ev_a_v_im[idx] + c.coastal_weight_neg[idx] * c.ev_b_v_im[idx];
                const double sig = c.parity[idx] * c.weight[idx];
                c.coastal_f_h[idx] = sig; c.coastal_f_dx[idx] = sig * c.a1[idx]; c.coastal_f_dz[idx] = sig * c.a2[idx];
                c.coastal_f_dhx[idx] = sig * -c.kx[idx]; c.coastal_f_dhz[idx] = sig * -c.ky[idx];
                c.coastal_f_dxx[idx] = sig * c.c11[idx]; c.coastal_f_dxz[idx] = sig * c.c12[idx];
                c.coastal_f_dzx[idx] = sig * c.c21[idx]; c.coastal_f_dzz[idx] = sig * c.c22[idx];
                c.coastal_f_vh[idx] = sig; c.coastal_f_vx[idx] = sig * c.a1[idx]; c.coastal_f_vz[idx] = sig * c.a2[idx];
            } else {
                c.ev_coastal_h_re[idx] = c.ev_coastal_h_im[idx] = 0.0;
                c.ev_coastal_v_re[idx] = c.ev_coastal_v_im[idx] = 0.0;
                c.coastal_f_h[idx] = c.coastal_f_dx[idx] = c.coastal_f_dz[idx] = c.coastal_f_dhx[idx] = c.coastal_f_dhz[idx] = 0.0;
                c.coastal_f_dxx[idx] = c.coastal_f_dxz[idx] = c.coastal_f_dzx[idx] = c.coastal_f_dzz[idx] = c.coastal_f_vh[idx] = c.coastal_f_vx[idx] = c.coastal_f_vz[idx] = 0.0;
            }
        }
    }
}

void OceanQueryCore::ensure_breaker_prepared(double simulation_time) {
    if (breaker_prepared_valid && breaker_prepared_time == simulation_time) {
        return;
    }
    breaker_prepared_valid = false;
    if (cascades.empty()) {
        return;
    }
    Cascade &c = cascades[0];
    const size_t count = c.kx.size();
    for (size_t idx = 0; idx < count; ++idx) {
        const double wt = c.omega[idx] * simulation_time;
        const double cw = std::cos(wt);
        const double sw = std::sin(wt);
        c.ev_a_h_re[idx] = c.h0_re[idx] * cw - c.h0_im[idx] * sw;
        c.ev_a_h_im[idx] = c.h0_re[idx] * sw + c.h0_im[idx] * cw;
        c.ev_b_h_re[idx] = c.h0n_re[idx] * cw + c.h0n_im[idx] * sw;
        c.ev_b_h_im[idx] = -c.h0n_re[idx] * sw + c.h0n_im[idx] * cw;
    }
    breaker_prepared_time = simulation_time;
    breaker_prepared_valid = true;
}

void OceanQueryCore::accumulate_breaker_long_(double qx, double qz, double &h,
                                               double &dhx, double &dhz) const {
    h = dhx = dhz = 0.0;
    if (cascades.empty()) {
        return;
    }
    const Cascade &c = cascades[0];
    for (size_t idx = 0; idx < c.kx.size(); ++idx) {
        const double h_re = c.coastal_weight_pos[idx] * c.ev_a_h_re[idx] +
                            c.coastal_weight_neg[idx] * c.ev_b_h_re[idx];
        const double h_im = c.coastal_weight_pos[idx] * c.ev_a_h_im[idx] +
                            c.coastal_weight_neg[idx] * c.ev_b_h_im[idx];
        const double phi = c.kx[idx] * qx + c.ky[idx] * qz;
        const double cp = std::cos(phi);
        const double sp = std::sin(phi);
        const double p_im = h_re * sp + h_im * cp;
        const double sig = c.parity[idx] * c.weight[idx];
        h += sig * (h_re * cp - h_im * sp);
        dhx += sig * -c.kx[idx] * p_im;
        dhz += sig * -c.ky[idx] * p_im;
    }
    h *= c.inv_n2;
    dhx *= c.inv_n2;
    dhz *= c.inv_n2;
}

void OceanQueryCore::sample_coastal_breaker_prepared(const double *positions_xz, size_t n,
                                                      double *out, bool include_slope) const {
    if (!breaker_prepared_valid || cascades.empty() || !coastal.enabled) {
        for (size_t i = 0; i < n; ++i) {
            double *dst = out + i * S_STRIDE;
            for (int field = 0; field < S_STRIDE; ++field) dst[field] = 0.0;
        }
        return;
    }
    for (size_t i = 0; i < n; ++i) {
        const double qx = positions_xz[2 * i];
        const double qz = positions_xz[2 * i + 1];
        CoastalSample sample;
        double *dst = out + i * S_STRIDE;
        for (int field = 0; field < S_STRIDE; ++field) dst[field] = 0.0;
        if (!coastal.sample(qx, qz, sample)) {
            continue;
        }
        double open_h = 0.0, open_dhx = 0.0, open_dhz = 0.0;
        accumulate_breaker_long_(qx, qz, open_h, open_dhx, open_dhz);
        double composed_h = open_h;
        double composed_dhx = open_dhx;
        double composed_dhz = open_dhz;
        if (sample.confidence > 0.0) {
            double deep_h = 0.0, deep_dhx = 0.0, deep_dhz = 0.0;
            accumulate_breaker_long_(sample.deep_x, sample.deep_z, deep_h, deep_dhx, deep_dhz);
            const double scaled_open = sample.effective_shoaling * (1.0 - sample.confidence);
            const double scaled_deep = sample.effective_shoaling * sample.confidence;
            composed_h = scaled_open * open_h + scaled_deep * deep_h - open_h;
            composed_dhx = scaled_open * open_dhx + scaled_deep * (sample.j00 * deep_dhx + sample.j10 * deep_dhz) - open_dhx;
            composed_dhz = scaled_open * open_dhz + scaled_deep * (sample.j01 * deep_dhx + sample.j11 * deep_dhz) - open_dhz;
        }
        dst[S_VALID] = 1.0;
        dst[S_HEIGHT] = sea_level + composed_h;
        dst[S_NX] = 0.0; dst[S_NY] = 1.0; dst[S_NZ] = 0.0;
        dst[S_JACOBIAN_DET] = 1.0;
        if (include_slope) {
            double nx = -composed_dhx, ny = 1.0, nz = -composed_dhz;
            const double length = std::sqrt(nx * nx + ny * ny + nz * nz);
            if (length > 1.0e-8) {
                nx /= length; ny /= length; nz /= length;
            }
            dst[S_NX] = nx; dst[S_NY] = ny; dst[S_NZ] = nz;
        }
        // Displacement, velocity, foldover, residual and Newton iterations are
        // deliberately zero/identity: this contract is height/slope-only.
    }
}

size_t OceanQueryCore::coastal_nonzero_pair_count() const {
    return cascades.empty() ? 0 : cascades[0].coastal_nonzero_indices.size();
}


void OceanQueryCore::set_crest_sharpen(double strength, double threshold, double max_gain,
                                       double long_weight, double mid_weight,
                                       double dir_x, double dir_z, double eps, double local_hs) {
    crest_sharpen_enabled = strength > 0.0;
    crest_sharpen_strength = strength;
    crest_sharpen_threshold = threshold;
    crest_sharpen_max_gain = max_gain;
    crest_sharpen_long_weight = long_weight;
    crest_sharpen_mid_weight = mid_weight;
    crest_sharpen_dir_x = dir_x;
    crest_sharpen_dir_z = dir_z;
    crest_sharpen_eps = eps;
    crest_sharpen_local_hs = local_hs;
}


double OceanQueryCore::band_height_(size_t band_index, double qx, double qz) const {
    // 5R1D: altura de UNA banda (LONG=0, MID=1) en q, con espectro prepared.
    const Cascade &c = cascades[band_index];
    const size_t count = c.kx.size();
    double total = 0.0;
    for (size_t idx = 0; idx < count; ++idx) {
        const double phi = c.kx[idx] * qx + c.ky[idx] * qz;
        const double cp = std::cos(phi);
        const double sp = std::sin(phi);
        const double p_re = c.ev_h_re[idx] * cp - c.ev_h_im[idx] * sp;
        const double sig = c.parity[idx] * c.weight[idx];
        total += sig * p_re;
    }
    return total * c.inv_n2;
}


void OceanQueryCore::apply_crest_sharpen_(double qx, double qz, double &h, double &dx, double &dz) const {
    // 5R1D: misma matemática 5R.1C del shader (sobre FFT base, no recursiva).
    if (!crest_sharpen_enabled || cascades.size() < 2) return;
    const double local_hs = std::max(crest_sharpen_local_hs, 0.05);
    const double eps = crest_sharpen_eps;
    const double dirx = crest_sharpen_dir_x, dirz = crest_sharpen_dir_z;
    const double l_c = band_height_(0, qx, qz);
    const double l_l = band_height_(0, qx - dirx * eps, qz - dirz * eps);
    const double l_r = band_height_(0, qx + dirx * eps, qz + dirz * eps);
    const double m_c = band_height_(1, qx, qz);
    const double m_l = band_height_(1, qx - dirx * eps, qz - dirz * eps);
    const double m_r = band_height_(1, qx + dirx * eps, qz + dirz * eps);
    const double curv_long = l_l - 2.0 * l_c + l_r;
    const double curv_mid = m_l - 2.0 * m_c + m_r;
    const double crest_long = std::clamp(-curv_long / local_hs, 0.0, 2.0) * crest_sharpen_long_weight;
    const double crest_mid = std::clamp(-curv_mid / std::max(local_hs * 0.4, 0.02), 0.0, 2.0) * crest_sharpen_mid_weight;
    const double crestness = crest_long + crest_mid;
    const double face_slope = std::abs(l_r - l_l) / (2.0 * eps);
    const double compression = smoothstep01(0.03, 0.22, face_slope);
    const double sharpen = smoothstep01(crest_sharpen_threshold, crest_sharpen_threshold + 0.25, crestness)
        * compression * crest_sharpen_strength;
    const double delta_y = sharpen * crest_sharpen_max_gain * local_hs;
    const double h_scale = 1.0 + sharpen * crest_sharpen_max_gain * 0.35;
    h += delta_y;
    dx *= h_scale;
    dz *= h_scale;
}


void OceanQueryCore::finite_jacobian_(double qx, double qz, double &ja, double &jb, double &jc, double &jd) {
    // 5R1D-hotfix: Jacobian 2D de q + final_dx/dz por diferencias finitas centrales.
    const double d = 0.05;
    double h, dx, dz, dhx, dhz, dxx, dxz, dzx, dzz, vh, vx, vz;
    double xp_x, xp_z, xm_x, xm_z, zp_x, zp_z, zm_x, zm_z;

    accumulate_(qx + d, qz, true, prepared_time, h, dx, dz, dhx, dhz, dxx, dxz, dzx, dzz, vh, vx, vz);
    apply_crest_sharpen_(qx + d, qz, h, dx, dz);
    xp_x = dx; xp_z = dz;
    accumulate_(qx - d, qz, true, prepared_time, h, dx, dz, dhx, dhz, dxx, dxz, dzx, dzz, vh, vx, vz);
    apply_crest_sharpen_(qx - d, qz, h, dx, dz);
    xm_x = dx; xm_z = dz;
    accumulate_(qx, qz + d, true, prepared_time, h, dx, dz, dhx, dhz, dxx, dxz, dzx, dzz, vh, vx, vz);
    apply_crest_sharpen_(qx, qz + d, h, dx, dz);
    zp_x = dx; zp_z = dz;
    accumulate_(qx, qz - d, true, prepared_time, h, dx, dz, dhx, dhz, dxx, dxz, dzx, dzz, vh, vx, vz);
    apply_crest_sharpen_(qx, qz - d, h, dx, dz);
    zm_x = dx; zm_z = dz;

    ja = 1.0 + (xp_x - xm_x) / (2.0 * d);
    jb = (zp_x - zm_x) / (2.0 * d);
    jc = (xp_z - xm_z) / (2.0 * d);
    jd = 1.0 + (zp_z - zm_z) / (2.0 * d);
}


size_t OceanQueryCore::coastal_pair_count() const {
    return cascades.empty() ? 0 : cascades[0].kx.size();
}

void OceanQueryCore::accumulate_(double qx, double qz, bool use_prepared, double sim_time,
                                 double &h, double &dx, double &dz,
                                 double &dhx, double &dhz,
                                 double &dxx, double &dxz, double &dzx, double &dzz,
                                 double &vh, double &vx, double &vz) {
    double total_h = 0.0, total_dx = 0.0, total_dz = 0.0;
    double total_dhx = 0.0, total_dhz = 0.0;
    double total_dxx = 0.0, total_dxz = 0.0, total_dzx = 0.0, total_dzz = 0.0;
    double total_vh = 0.0, total_vx = 0.0, total_vz = 0.0;

    for (const Cascade &c : cascades) {
        const double inv_n2 = c.inv_n2;
        const size_t count = c.kx.size();
        double lh = 0.0, ldx = 0.0, ldz = 0.0;
        double ldhx = 0.0, ldhz = 0.0;
        double ldxx = 0.0, ldxz = 0.0, ldzx = 0.0, ldzz = 0.0;
        double lvh = 0.0, lvx = 0.0, lvz = 0.0;
        for (size_t idx = 0; idx < count; ++idx) {
            double h_re, h_im, v_re, v_im;
            if (use_prepared) {
                h_re = c.ev_h_re[idx];
                h_im = c.ev_h_im[idx];
                v_re = c.ev_v_re[idx];
                v_im = c.ev_v_im[idx];
            } else {
                const double wt = c.omega[idx] * sim_time;
                const double cw = std::cos(wt);
                const double sw = std::sin(wt);
                const double a_re = c.h0_re[idx] * cw - c.h0_im[idx] * sw;
                const double a_im = c.h0_re[idx] * sw + c.h0_im[idx] * cw;
                const double b_re = c.h0n_re[idx] * cw + c.h0n_im[idx] * sw;
                const double b_im = -c.h0n_re[idx] * sw + c.h0n_im[idx] * cw;
                h_re = a_re + b_re;
                h_im = a_im + b_im;
                v_re = c.omega[idx] * (-a_im + b_im);
                v_im = c.omega[idx] * (a_re - b_re);
            }
            const double phi = c.kx[idx] * qx + c.ky[idx] * qz;
            const double cp = std::cos(phi);
            const double sp = std::sin(phi);
            const double p_re = h_re * cp - h_im * sp;
            const double p_im = h_re * sp + h_im * cp;
            const double q_re = v_re * cp - v_im * sp;
            const double q_im = v_re * sp + v_im * cp;
            const double sig = c.parity[idx] * c.weight[idx];
            lh += sig * p_re;
            ldx += sig * c.a1[idx] * p_im;
            ldz += sig * c.a2[idx] * p_im;
            ldhx += sig * -c.kx[idx] * p_im;
            ldhz += sig * -c.ky[idx] * p_im;
            ldxx += sig * c.c11[idx] * p_re;
            ldxz += sig * c.c12[idx] * p_re;
            ldzx += sig * c.c21[idx] * p_re;
            ldzz += sig * c.c22[idx] * p_re;
            lvh += sig * q_re;
            lvx += sig * c.a1[idx] * q_im;
            lvz += sig * c.a2[idx] * q_im;
        }
        total_h += lh * inv_n2;
        total_dx += ldx * inv_n2;
        total_dz += ldz * inv_n2;
        total_dhx += ldhx * inv_n2;
        total_dhz += ldhz * inv_n2;
        total_dxx += ldxx * inv_n2;
        total_dxz += ldxz * inv_n2;
        total_dzx += ldzx * inv_n2;
        total_dzz += ldzz * inv_n2;
        total_vh += lvh * inv_n2;
        total_vx += lvx * inv_n2;
        total_vz += lvz * inv_n2;
    }

    apply_coastal_correction_(qx, qz, use_prepared, sim_time, total_h, total_dx, total_dz,
                              total_dhx, total_dhz, total_dxx, total_dxz, total_dzx, total_dzz,
                              total_vh, total_vx, total_vz);
    h = total_h;
    dx = total_dx;
    dz = total_dz;
    dhx = total_dhx;
    dhz = total_dhz;
    dxx = total_dxx;
    dxz = total_dxz;
    dzx = total_dzx;
    dzz = total_dzz;
    vh = total_vh;
    vx = total_vx;
    vz = total_vz;
}

void OceanQueryCore::accumulate_coastal_long_(double qx, double qz, bool use_prepared, double sim_time,
                                              double &h, double &dx, double &dz,
                                              double &dhx, double &dhz,
                                              double &dxx, double &dxz, double &dzx, double &dzz,
                                              double &vh, double &vx, double &vz) const {
    h = dx = dz = dhx = dhz = dxx = dxz = dzx = dzz = vh = vx = vz = 0.0;
    if (cascades.empty()) { return; }
    const Cascade &c = cascades[0];
    if (c.coastal_weight_pos.size() != c.kx.size() || c.coastal_weight_neg.size() != c.kx.size()) { return; }
    double lh = 0.0, ldx = 0.0, ldz = 0.0, ldhx = 0.0, ldhz = 0.0;
    double ldxx = 0.0, ldxz = 0.0, ldzx = 0.0, ldzz = 0.0, lvh = 0.0, lvx = 0.0, lvz = 0.0;
    for (size_t idx = 0; idx < c.kx.size(); ++idx) {
        double ahr, ahi, bhr, bhi, avr, avi, bvr, bvi;
        if (use_prepared) {
            ahr = c.ev_a_h_re[idx]; ahi = c.ev_a_h_im[idx]; bhr = c.ev_b_h_re[idx]; bhi = c.ev_b_h_im[idx];
            avr = c.ev_a_v_re[idx]; avi = c.ev_a_v_im[idx]; bvr = c.ev_b_v_re[idx]; bvi = c.ev_b_v_im[idx];
        } else {
            const double wt = c.omega[idx] * sim_time, cw = std::cos(wt), sw = std::sin(wt);
            ahr = c.h0_re[idx] * cw - c.h0_im[idx] * sw; ahi = c.h0_re[idx] * sw + c.h0_im[idx] * cw;
            bhr = c.h0n_re[idx] * cw + c.h0n_im[idx] * sw; bhi = -c.h0n_re[idx] * sw + c.h0n_im[idx] * cw;
            avr = -c.omega[idx] * ahi; avi = c.omega[idx] * ahr;
            bvr = c.omega[idx] * bhi; bvi = -c.omega[idx] * bhr;
        }
        const double hr = c.coastal_weight_pos[idx] * ahr + c.coastal_weight_neg[idx] * bhr;
        const double hi = c.coastal_weight_pos[idx] * ahi + c.coastal_weight_neg[idx] * bhi;
        const double vr = c.coastal_weight_pos[idx] * avr + c.coastal_weight_neg[idx] * bvr;
        const double vi = c.coastal_weight_pos[idx] * avi + c.coastal_weight_neg[idx] * bvi;
        const double phi = c.kx[idx] * qx + c.ky[idx] * qz, cp = std::cos(phi), sp = std::sin(phi);
        const double pre = hr * cp - hi * sp, pim = hr * sp + hi * cp;
        const double qre = vr * cp - vi * sp, qim = vr * sp + vi * cp;
        const double sig = c.parity[idx] * c.weight[idx];
        lh += sig * pre; ldx += sig * c.a1[idx] * pim; ldz += sig * c.a2[idx] * pim;
        ldhx += sig * -c.kx[idx] * pim; ldhz += sig * -c.ky[idx] * pim;
        ldxx += sig * c.c11[idx] * pre; ldxz += sig * c.c12[idx] * pre;
        ldzx += sig * c.c21[idx] * pre; ldzz += sig * c.c22[idx] * pre;
        lvh += sig * qre; lvx += sig * c.a1[idx] * qim; lvz += sig * c.a2[idx] * qim;
    }
    h = lh * c.inv_n2; dx = ldx * c.inv_n2; dz = ldz * c.inv_n2;
    dhx = ldhx * c.inv_n2; dhz = ldhz * c.inv_n2;
    dxx = ldxx * c.inv_n2; dxz = ldxz * c.inv_n2; dzx = ldzx * c.inv_n2; dzz = ldzz * c.inv_n2;
    vh = lvh * c.inv_n2; vx = lvx * c.inv_n2; vz = lvz * c.inv_n2;
}

void OceanQueryCore::apply_coastal_correction_(double qx, double qz, bool use_prepared, double sim_time,
                                               double &h, double &dx, double &dz,
                                               double &dhx, double &dhz,
                                               double &dxx, double &dxz, double &dzx, double &dzz,
                                               double &vh, double &vx, double &vz) const {
    const bool profile = coastal_profile.enabled;
    std::chrono::steady_clock::time_point sample_start;
    if (profile) { sample_start = std::chrono::steady_clock::now(); }
    CoastalSample s;
    const bool active = coastal.sample(qx, qz, s);
    if (profile) {
        coastal_profile.sampler_us += static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - sample_start).count());
    }
    if (!active) { return; }
    double oh, odx, odz, odhx, odhz, odxx, odxz, odzx, odzz, ovh, ovx, ovz;
    double dh, ddx, ddz, ddhx, ddhz, ddxx, ddxz, ddzx, ddzz, dvh, dvx, dvz;
    std::chrono::steady_clock::time_point cq_start;
    if (profile) { cq_start = std::chrono::steady_clock::now(); }
    accumulate_coastal_long_(qx, qz, use_prepared, sim_time, oh, odx, odz, odhx, odhz, odxx, odxz, odzx, odzz, ovh, ovx, ovz);
    if (profile) {
        coastal_profile.cq_us += static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - cq_start).count());
    }
    std::chrono::steady_clock::time_point cdeep_start;
    if (profile) { cdeep_start = std::chrono::steady_clock::now(); }
    accumulate_coastal_long_(s.deep_x, s.deep_z, use_prepared, sim_time, dh, ddx, ddz, ddhx, ddhz, ddxx, ddxz, ddzx, ddzz, dvh, dvx, dvz);
    if (profile) {
        coastal_profile.cdeep_us += static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - cdeep_start).count());
    }
    std::chrono::steady_clock::time_point combine_start;
    if (profile) { combine_start = std::chrono::steady_clock::now(); }
    const double open = s.effective_shoaling * (1.0 - s.confidence), deep = s.effective_shoaling * s.confidence;
    h += open * oh + deep * dh - oh; dx += open * odx + deep * ddx - odx; dz += open * odz + deep * ddz - odz;
    vh += open * ovh + deep * dvh - ovh; vx += open * ovx + deep * dvx - ovx; vz += open * ovz + deep * dvz - ovz;
    dhx += open * odhx + deep * (s.j00 * ddhx + s.j10 * ddhz) - odhx;
    dhz += open * odhz + deep * (s.j01 * ddhx + s.j11 * ddhz) - odhz;
    dxx += open * odxx + deep * (ddxx * s.j00 + ddxz * s.j10) - odxx;
    dxz += open * odxz + deep * (ddxx * s.j01 + ddxz * s.j11) - odxz;
    dzx += open * odzx + deep * (ddzx * s.j00 + ddzz * s.j10) - odzx;
    dzz += open * odzz + deep * (ddzx * s.j01 + ddzz * s.j11) - odzz;
    if (profile) {
        coastal_profile.combine_us += static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - combine_start).count());
        coastal_profile.calls += 1;
    }
}

void OceanQueryCore::sample_prepared_(double wx, double wz, double *out) {
    // Newton world_xz -> q usando el displacement FINAL (base + crest sharpening).
    double qx = wx, qz = wz;
    double h, dx, dz, dhx, dhz, dxx, dxz, dzx, dzz, vh, vx, vz;
    int iterations = 0;
    bool converged = false;
    double residual = 0.0;
    while (true) {
        accumulate_(qx, qz, true, prepared_time, h, dx, dz, dhx, dhz, dxx, dxz, dzx, dzz, vh, vx, vz);
        apply_crest_sharpen_(qx, qz, h, dx, dz);
        const double fx = qx + dx - wx;
        const double fz = qz + dz - wz;
        residual = std::sqrt(fx * fx + fz * fz);
        if (residual <= POSITION_TOLERANCE_M || iterations >= MAX_ITERATIONS) {
            converged = residual <= POSITION_TOLERANCE_M;
            break;
        }
        double ja, jb, jc, jd;
        finite_jacobian_(qx, qz, ja, jb, jc, jd);
        const double det = ja * jd - jb * jc;
        if (std::abs(det) <= JACOBIAN_EPSILON) {
            break;
        }
        const double inv = 1.0 / det;
        qx -= inv * (jd * fx - jb * fz);
        qz -= inv * (-jc * fx + ja * fz);
        iterations += 1;
    }
    // Re-evalúa la superficie FINAL en q resuelto (no aplicar sharpening 2 veces).
    accumulate_(qx, qz, true, prepared_time, h, dx, dz, dhx, dhz, dxx, dxz, dzx, dzz, vh, vx, vz);
    apply_crest_sharpen_(qx, qz, h, dx, dz);
    if (!converged) {
        diag_non_converged += 1;
    }

    // Construcción del sample (mismo orden que GDScript _build_sample).
    double disp[3] = {dx, h, dz};
    double tangent_x[3] = {1.0 + dxx, dhx, dzx};
    double tangent_z[3] = {dxz, dhz, 1.0 + dzz};
    double normal[3];
    normal[0] = tangent_z[1] * tangent_x[2] - tangent_z[2] * tangent_x[1];
    normal[1] = tangent_z[2] * tangent_x[0] - tangent_z[0] * tangent_x[2];
    normal[2] = tangent_z[0] * tangent_x[1] - tangent_z[1] * tangent_x[0];
    double len2 = normal[0] * normal[0] + normal[1] * normal[1] + normal[2] * normal[2];
    if (len2 > 1.0e-14) {
        double len = std::sqrt(len2);
        normal[0] /= len;
        normal[1] /= len;
        normal[2] /= len;
        if (normal[1] < 0.0) {
            normal[0] = -normal[0];
            normal[1] = -normal[1];
            normal[2] = -normal[2];
        }
    } else {
        normal[0] = 0.0;
        normal[1] = 1.0;
        normal[2] = 0.0;
    }
    const double det_j = (1.0 + dxx) * (1.0 + dzz) - dxz * dzx;

    // Escribe el contrato (stride S_STRIDE).
    out[S_VALID] = converged ? 1.0 : 0.0;
    out[S_HEIGHT] = sea_level + h;
    out[S_DX] = disp[0];
    out[S_DY] = disp[1];
    out[S_DZ] = disp[2];
    out[S_NX] = normal[0];
    out[S_NY] = normal[1];
    out[S_NZ] = normal[2];
    out[S_VX] = vx;
    out[S_VY] = vh;
    out[S_VZ] = vz;
    out[S_JACOBIAN_DET] = det_j;
    out[S_FOLDOVER] = det_j <= 0.0 ? 1.0 : 0.0;
    out[S_RESIDUAL] = residual;
    out[S_ITERATIONS] = static_cast<double>(iterations);
}

void OceanQueryCore::sample_world(double wx, double wz, double simulation_time, double *out) {
    ensure_prepared(simulation_time);
    sample_prepared_(wx, wz, out);
}

void OceanQueryCore::sample_batch_prepared(const double *positions_xz, size_t n, double *out) {
    if (crest_sharpen_enabled) {
        // 5R.1E: con sharpening la inversión usa displacement FINAL + Jacobian
        // finito. Ahora existe una ruta AVX2 específica (misma matemática del
        // hotfix); scalar queda como fallback para CPUs sin AVX2, force_scalar
        // y batches pequeños.
        if (avx2_supported() && !force_scalar && n >= 4) {
            batch_.ensure_capacity(n);
            for (size_t p = 0; p < n; ++p) {
                batch_.wx[p] = positions_xz[2 * p]; batch_.wz[p] = positions_xz[2 * p + 1];
                batch_.qx[p] = batch_.wx[p]; batch_.qz[p] = batch_.wz[p];
            }
            solve_avx2_batch_sharpened_(n, out, true);
            return;
        }
        sample_batch_scalar_prepared(positions_xz, n, out);
        return;
    }
    if (avx2_supported() && !force_scalar && n >= 4) {
        batch_.ensure_capacity(n);
        for (size_t p = 0; p < n; ++p) {
            batch_.wx[p] = positions_xz[2 * p]; batch_.wz[p] = positions_xz[2 * p + 1];
            batch_.qx[p] = batch_.wx[p]; batch_.qz[p] = batch_.wz[p];
        }
        solve_avx2_batch_(n, out, true);
        return;
    }
    sample_batch_scalar_prepared(positions_xz, n, out);
}

void OceanQueryCore::sample_batch_scalar_prepared(const double *positions_xz, size_t n, double *out) {
    for (size_t i = 0; i < n; ++i) {
        sample_prepared_(positions_xz[2 * i], positions_xz[2 * i + 1], out + i * S_STRIDE);
    }
}

void OceanQueryCore::sample_batch_avx2_scalar_trig_prepared(const double *positions_xz, size_t n, double *out) {
    if (!avx2_supported() || n < 4) { sample_batch_scalar_prepared(positions_xz, n, out); return; }
    batch_.ensure_capacity(n);
    for (size_t p = 0; p < n; ++p) {
        batch_.wx[p] = positions_xz[2 * p]; batch_.wz[p] = positions_xz[2 * p + 1];
        batch_.qx[p] = batch_.wx[p]; batch_.qz[p] = batch_.wz[p];
    }
    solve_avx2_batch_(n, out, false);
}

bool OceanQueryCore::avx2_supported() const { return detect_avx2_runtime(); }

const char *OceanQueryCore::query_execution_backend() const {
    return avx2_supported() && !force_scalar ? "AVX2" : "SCALAR";
}

void OceanQueryCore::evaluate_true_batch_(const size_t *indices, size_t active_count) {
    for (size_t ai = 0; ai < active_count; ++ai) {
        const size_t p = indices[ai];
        batch_.h[p] = batch_.dx[p] = batch_.dz[p] = 0.0;
        batch_.dhx[p] = batch_.dhz[p] = 0.0;
        batch_.dxx[p] = batch_.dxz[p] = batch_.dzx[p] = batch_.dzz[p] = 0.0;
        batch_.vh[p] = batch_.vx[p] = batch_.vz[p] = 0.0;
    }

    // Orden mode-major. Dentro de cada punto se mantiene exactamente el mismo
    // orden de sumas de modos y de reducción por cascada que DIRECT_SCALAR.
    for (const Cascade &c : cascades) {
        for (size_t ai = 0; ai < active_count; ++ai) {
            const size_t p = indices[ai];
            batch_.cascade_h[p] = batch_.cascade_dx[p] = batch_.cascade_dz[p] = 0.0;
            batch_.cascade_dhx[p] = batch_.cascade_dhz[p] = 0.0;
            batch_.cascade_dxx[p] = batch_.cascade_dxz[p] = 0.0;
            batch_.cascade_dzx[p] = batch_.cascade_dzz[p] = 0.0;
            batch_.cascade_vh[p] = batch_.cascade_vx[p] = batch_.cascade_vz[p] = 0.0;
        }
        const size_t count = c.kx.size();
        for (size_t idx = 0; idx < count; ++idx) {
            const double h_re = c.ev_h_re[idx];
            const double h_im = c.ev_h_im[idx];
            const double v_re = c.ev_v_re[idx];
            const double v_im = c.ev_v_im[idx];
            const double sig = c.parity[idx] * c.weight[idx];
            for (size_t ai = 0; ai < active_count; ++ai) {
                const size_t p = indices[ai];
                const double phi = c.kx[idx] * batch_.qx[p] + c.ky[idx] * batch_.qz[p];
                const double cp = std::cos(phi);
                const double sp = std::sin(phi);
                const double p_re = h_re * cp - h_im * sp;
                const double p_im = h_re * sp + h_im * cp;
                const double q_re = v_re * cp - v_im * sp;
                const double q_im = v_re * sp + v_im * cp;
                batch_.cascade_h[p] += sig * p_re;
                batch_.cascade_dx[p] += sig * c.a1[idx] * p_im;
                batch_.cascade_dz[p] += sig * c.a2[idx] * p_im;
                batch_.cascade_dhx[p] += sig * -c.kx[idx] * p_im;
                batch_.cascade_dhz[p] += sig * -c.ky[idx] * p_im;
                batch_.cascade_dxx[p] += sig * c.c11[idx] * p_re;
                batch_.cascade_dxz[p] += sig * c.c12[idx] * p_re;
                batch_.cascade_dzx[p] += sig * c.c21[idx] * p_re;
                batch_.cascade_dzz[p] += sig * c.c22[idx] * p_re;
                batch_.cascade_vh[p] += sig * q_re;
                batch_.cascade_vx[p] += sig * c.a1[idx] * q_im;
                batch_.cascade_vz[p] += sig * c.a2[idx] * q_im;
            }
        }
        for (size_t ai = 0; ai < active_count; ++ai) {
            const size_t p = indices[ai];
            const double inv_n2 = c.inv_n2;
            batch_.h[p] += batch_.cascade_h[p] * inv_n2;
            batch_.dx[p] += batch_.cascade_dx[p] * inv_n2;
            batch_.dz[p] += batch_.cascade_dz[p] * inv_n2;
            batch_.dhx[p] += batch_.cascade_dhx[p] * inv_n2;
            batch_.dhz[p] += batch_.cascade_dhz[p] * inv_n2;
            batch_.dxx[p] += batch_.cascade_dxx[p] * inv_n2;
            batch_.dxz[p] += batch_.cascade_dxz[p] * inv_n2;
            batch_.dzx[p] += batch_.cascade_dzx[p] * inv_n2;
            batch_.dzz[p] += batch_.cascade_dzz[p] * inv_n2;
            batch_.vh[p] += batch_.cascade_vh[p] * inv_n2;
            batch_.vx[p] += batch_.cascade_vx[p] * inv_n2;
            batch_.vz[p] += batch_.cascade_vz[p] * inv_n2;
        }
    }
    // Coastal se evalúa por punto (sampler escalar) después del kernel base.
    // La suma base permanece mode-major; sólo C(q), C(F(q)) es adicional.
    for (size_t ai = 0; ai < active_count; ++ai) {
        const size_t p = indices[ai];
        apply_coastal_correction_(batch_.qx[p], batch_.qz[p], true, prepared_time,
                                  batch_.h[p], batch_.dx[p], batch_.dz[p], batch_.dhx[p], batch_.dhz[p],
                                  batch_.dxx[p], batch_.dxz[p], batch_.dzx[p], batch_.dzz[p],
                                  batch_.vh[p], batch_.vx[p], batch_.vz[p]);
    }
    diag_last_spectral_point_evaluations += active_count;
}

void OceanQueryCore::evaluate_avx2_batch_(const size_t *indices, size_t active_count, bool vector_sincos) {
    if (active_count < 4) { evaluate_true_batch_(indices, active_count); return; }
    for (size_t ai = 0; ai < active_count; ++ai) {
        const size_t p = indices[ai];
        batch_.h[p] = batch_.dx[p] = batch_.dz[p] = 0.0;
        batch_.dhx[p] = batch_.dhz[p] = 0.0;
        batch_.dxx[p] = batch_.dxz[p] = batch_.dzx[p] = batch_.dzz[p] = 0.0;
        batch_.vh[p] = batch_.vx[p] = batch_.vz[p] = 0.0;
    }
    const size_t coastal_active_count = sample_coastal_batch_(indices, active_count);
    const bool fuse_coastal_q = coastal_active_count > 0;
    const auto base_start = coastal_profile.enabled ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point();
    evaluate_batch_avx2(cascades, batch_, indices, active_count, vector_sincos, fuse_coastal_q);
    if (coastal_profile.enabled) {
        coastal_profile.base_us += static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - base_start).count());
    }
    if (fuse_coastal_q) {
        const auto deep_start = coastal_profile.enabled ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point();
        evaluate_coastal_long_batch_avx2(cascades[0], batch_, batch_.coastal_active_indices.data(), coastal_active_count, vector_sincos);
        if (coastal_profile.enabled) {
            coastal_profile.cdeep_us += static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - deep_start).count());
        }
        apply_coastal_batch_(batch_.coastal_active_indices.data(), coastal_active_count);
    }
    diag_last_spectral_point_evaluations += active_count;
}

size_t OceanQueryCore::sample_coastal_batch_(const size_t *indices, size_t active_count) {
    if (!coastal.enabled || cascades.empty() || cascades[0].coastal_nonzero_indices.empty()) { return 0; }
    const auto start = coastal_profile.enabled ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point();
    size_t count = 0;
    for (size_t ai = 0; ai < active_count; ++ai) {
        const size_t p = indices[ai];
        CoastalSample sample;
        if (!coastal.sample(batch_.qx[p], batch_.qz[p], sample)) { continue; }
        batch_.coastal_samples[p] = sample;
        batch_.coastal_deep_x[p] = sample.deep_x;
        batch_.coastal_deep_z[p] = sample.deep_z;
        batch_.coastal_active_indices[count++] = p;
    }
    if (coastal_profile.enabled) {
        coastal_profile.sampler_us += static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - start).count());
    }
    return count;
}

void OceanQueryCore::apply_coastal_batch_(const size_t *indices, size_t active_count) {
    const auto start = coastal_profile.enabled ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point();
    for (size_t ai = 0; ai < active_count; ++ai) {
        const size_t p = indices[ai];
        const CoastalSample &s = batch_.coastal_samples[p];
        const double open = s.effective_shoaling * (1.0 - s.confidence), deep = s.effective_shoaling * s.confidence;
        batch_.h[p] += open * batch_.coastal_h[p] + deep * batch_.coastal_deep_h[p] - batch_.coastal_h[p];
        batch_.dx[p] += open * batch_.coastal_dx[p] + deep * batch_.coastal_deep_dx[p] - batch_.coastal_dx[p];
        batch_.dz[p] += open * batch_.coastal_dz[p] + deep * batch_.coastal_deep_dz[p] - batch_.coastal_dz[p];
        batch_.vh[p] += open * batch_.coastal_vh[p] + deep * batch_.coastal_deep_vh[p] - batch_.coastal_vh[p];
        batch_.vx[p] += open * batch_.coastal_vx[p] + deep * batch_.coastal_deep_vx[p] - batch_.coastal_vx[p];
        batch_.vz[p] += open * batch_.coastal_vz[p] + deep * batch_.coastal_deep_vz[p] - batch_.coastal_vz[p];
        batch_.dhx[p] += open * batch_.coastal_dhx[p] + deep * (s.j00 * batch_.coastal_deep_dhx[p] + s.j10 * batch_.coastal_deep_dhz[p]) - batch_.coastal_dhx[p];
        batch_.dhz[p] += open * batch_.coastal_dhz[p] + deep * (s.j01 * batch_.coastal_deep_dhx[p] + s.j11 * batch_.coastal_deep_dhz[p]) - batch_.coastal_dhz[p];
        batch_.dxx[p] += open * batch_.coastal_dxx[p] + deep * (batch_.coastal_deep_dxx[p] * s.j00 + batch_.coastal_deep_dxz[p] * s.j10) - batch_.coastal_dxx[p];
        batch_.dxz[p] += open * batch_.coastal_dxz[p] + deep * (batch_.coastal_deep_dxx[p] * s.j01 + batch_.coastal_deep_dxz[p] * s.j11) - batch_.coastal_dxz[p];
        batch_.dzx[p] += open * batch_.coastal_dzx[p] + deep * (batch_.coastal_deep_dzx[p] * s.j00 + batch_.coastal_deep_dzz[p] * s.j10) - batch_.coastal_dzx[p];
        batch_.dzz[p] += open * batch_.coastal_dzz[p] + deep * (batch_.coastal_deep_dzx[p] * s.j01 + batch_.coastal_deep_dzz[p] * s.j11) - batch_.coastal_dzz[p];
    }
    if (coastal_profile.enabled) {
        coastal_profile.combine_us += static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - start).count());
        coastal_profile.calls += active_count;
    }
}

void OceanQueryCore::build_sample_from_fields_(size_t p, bool converged, double *out) const {
    const double dx = batch_.dx[p], dz = batch_.dz[p];
    const double dxx = batch_.dxx[p], dxz = batch_.dxz[p];
    const double dzx = batch_.dzx[p], dzz = batch_.dzz[p];
    const double dhx = batch_.dhx[p], dhz = batch_.dhz[p];
    double normal[3];
    normal[0] = dhz * dzx - (1.0 + dzz) * dhx;
    normal[1] = (1.0 + dzz) * (1.0 + dxx) - dxz * dzx;
    normal[2] = dxz * dhx - dhz * (1.0 + dxx);
    const double len2 = normal[0] * normal[0] + normal[1] * normal[1] + normal[2] * normal[2];
    if (len2 > 1.0e-14) {
        const double len = std::sqrt(len2);
        normal[0] /= len; normal[1] /= len; normal[2] /= len;
        if (normal[1] < 0.0) { normal[0] = -normal[0]; normal[1] = -normal[1]; normal[2] = -normal[2]; }
    } else {
        normal[0] = 0.0; normal[1] = 1.0; normal[2] = 0.0;
    }
    const double det_j = (1.0 + dxx) * (1.0 + dzz) - dxz * dzx;
    out[S_VALID] = converged ? 1.0 : 0.0;
    out[S_HEIGHT] = sea_level + batch_.h[p];
    out[S_DX] = dx; out[S_DY] = batch_.h[p]; out[S_DZ] = dz;
    out[S_NX] = normal[0]; out[S_NY] = normal[1]; out[S_NZ] = normal[2];
    out[S_VX] = batch_.vx[p]; out[S_VY] = batch_.vh[p]; out[S_VZ] = batch_.vz[p];
    out[S_JACOBIAN_DET] = det_j;
    out[S_FOLDOVER] = det_j <= 0.0 ? 1.0 : 0.0;
    out[S_RESIDUAL] = batch_.residual[p];
    out[S_ITERATIONS] = static_cast<double>(batch_.iterations[p]);
}

void OceanQueryCore::solve_true_batch_(size_t n, double *out, bool append_solved_q) {
    diag_last_spectral_point_evaluations = 0;
    for (int &count : diag_last_newton_histogram) { count = 0; }
    size_t active_count = n;
    for (size_t p = 0; p < n; ++p) {
        batch_.iterations[p] = 0;
        batch_.active_indices[p] = p;
    }
    evaluate_true_batch_(batch_.active_indices.data(), active_count);

    for (size_t ai = 0; ai < active_count; ++ai) {
        const size_t p = batch_.active_indices[ai];
        const double fx = batch_.qx[p] + batch_.dx[p] - batch_.wx[p];
        const double fz = batch_.qz[p] + batch_.dz[p] - batch_.wz[p];
        batch_.residual[p] = std::sqrt(fx * fx + fz * fz);
    }

    const int minimum_iterations = 0;
    for (size_t p = 0; p < n; ++p) {
        batch_.done[p] = (batch_.residual[p] <= POSITION_TOLERANCE_M && minimum_iterations == 0) ? 1 : 0;
    }
    size_t next_count = 0;
    for (size_t p = 0; p < n; ++p) if (!batch_.done[p]) batch_.active_indices[next_count++] = p;
    active_count = next_count;

    for (int iteration = 0; iteration < MAX_ITERATIONS && active_count > 0; ++iteration) {
        next_count = 0;
        for (size_t ai = 0; ai < active_count; ++ai) {
            const size_t p = batch_.active_indices[ai];
            const double det_j = (1.0 + batch_.dxx[p]) * (1.0 + batch_.dzz[p]) - batch_.dxz[p] * batch_.dzx[p];
            if (std::abs(det_j) <= JACOBIAN_EPSILON) {
                continue;
            }
            const double fx = batch_.qx[p] + batch_.dx[p] - batch_.wx[p];
            const double fz = batch_.qz[p] + batch_.dz[p] - batch_.wz[p];
            const double inv_det = 1.0 / det_j;
            batch_.qx[p] -= inv_det * ((1.0 + batch_.dzz[p]) * fx - batch_.dxz[p] * fz);
            batch_.qz[p] -= inv_det * (-batch_.dzx[p] * fx + (1.0 + batch_.dxx[p]) * fz);
            batch_.active_indices[next_count++] = p;
        }
        active_count = next_count;
        if (active_count == 0) { break; }
        evaluate_true_batch_(batch_.active_indices.data(), active_count);
        next_count = 0;
        for (size_t ai = 0; ai < active_count; ++ai) {
            const size_t p = batch_.active_indices[ai];
            const double fx = batch_.qx[p] + batch_.dx[p] - batch_.wx[p];
            const double fz = batch_.qz[p] + batch_.dz[p] - batch_.wz[p];
            batch_.residual[p] = std::sqrt(fx * fx + fz * fz);
            batch_.iterations[p] = iteration + 1;
            if (batch_.residual[p] <= POSITION_TOLERANCE_M && batch_.iterations[p] >= minimum_iterations) {
                batch_.done[p] = 1;
            } else {
                batch_.active_indices[next_count++] = p;
            }
        }
        active_count = next_count;
    }

    for (size_t p = 0; p < n; ++p) {
        const bool is_converged = batch_.done[p] != 0;
        if (is_converged) {
            ++diag_last_newton_histogram[batch_.iterations[p]];
        } else {
            ++diag_last_newton_histogram[4];
            ++diag_non_converged;
        }
        double *sample = out + p * (append_solved_q ? TRUE_BATCH_WARM_STRIDE : S_STRIDE);
        build_sample_from_fields_(p, is_converged, sample);
        if (append_solved_q) {
            sample[S_STRIDE] = batch_.qx[p];
            sample[S_STRIDE + 1] = batch_.qz[p];
        }
    }
}

void OceanQueryCore::solve_avx2_batch_(size_t n, double *out, bool vector_sincos) {
    diag_last_spectral_point_evaluations = 0;
    for (int &count : diag_last_newton_histogram) { count = 0; }
    size_t active_count = n;
    for (size_t p = 0; p < n; ++p) {
        batch_.iterations[p] = 0;
        batch_.active_indices[p] = p;
    }
    evaluate_avx2_batch_(batch_.active_indices.data(), active_count, vector_sincos);
    for (size_t ai = 0; ai < active_count; ++ai) {
        const size_t p = batch_.active_indices[ai];
        const double fx = batch_.qx[p] + batch_.dx[p] - batch_.wx[p];
        const double fz = batch_.qz[p] + batch_.dz[p] - batch_.wz[p];
        batch_.residual[p] = std::sqrt(fx * fx + fz * fz);
        batch_.done[p] = batch_.residual[p] <= POSITION_TOLERANCE_M ? 1 : 0;
    }
    size_t next_count = 0;
    for (size_t p = 0; p < n; ++p) if (!batch_.done[p]) batch_.active_indices[next_count++] = p;
    active_count = next_count;
    for (int iteration = 0; iteration < MAX_ITERATIONS && active_count > 0; ++iteration) {
        next_count = 0;
        for (size_t ai = 0; ai < active_count; ++ai) {
            const size_t p = batch_.active_indices[ai];
            const double det_j = (1.0 + batch_.dxx[p]) * (1.0 + batch_.dzz[p]) - batch_.dxz[p] * batch_.dzx[p];
            if (std::abs(det_j) <= JACOBIAN_EPSILON) { continue; }
            const double fx = batch_.qx[p] + batch_.dx[p] - batch_.wx[p];
            const double fz = batch_.qz[p] + batch_.dz[p] - batch_.wz[p];
            const double inv_det = 1.0 / det_j;
            batch_.qx[p] -= inv_det * ((1.0 + batch_.dzz[p]) * fx - batch_.dxz[p] * fz);
            batch_.qz[p] -= inv_det * (-batch_.dzx[p] * fx + (1.0 + batch_.dxx[p]) * fz);
            batch_.active_indices[next_count++] = p;
        }
        active_count = next_count;
        if (active_count == 0) { break; }
        // Para conjuntos activos pequeños el evaluador cae a scalar; evita
        // pagar gathers y setup AVX2 cuando quedan menos de cuatro puntos.
        evaluate_avx2_batch_(batch_.active_indices.data(), active_count, vector_sincos);
        next_count = 0;
        for (size_t ai = 0; ai < active_count; ++ai) {
            const size_t p = batch_.active_indices[ai];
            const double fx = batch_.qx[p] + batch_.dx[p] - batch_.wx[p];
            const double fz = batch_.qz[p] + batch_.dz[p] - batch_.wz[p];
            batch_.residual[p] = std::sqrt(fx * fx + fz * fz);
            batch_.iterations[p] = iteration + 1;
            if (batch_.residual[p] <= POSITION_TOLERANCE_M) { batch_.done[p] = 1; }
            else { batch_.active_indices[next_count++] = p; }
        }
        active_count = next_count;
    }
    for (size_t p = 0; p < n; ++p) {
        const bool converged = batch_.done[p] != 0;
        if (converged) { ++diag_last_newton_histogram[batch_.iterations[p]]; }
        else { ++diag_last_newton_histogram[4]; ++diag_non_converged; }
        build_sample_from_fields_(p, converged, out + p * S_STRIDE);
    }
}

// --- 5R.1E: batch sharpened (crest sharpening ON) ----------------------------
// Replica EXACTAMENTE la matemática del hotfix scalar (sample_prepared_ y
// finite_jacobian_) pero procesando lanes en AVX2. La base FFT + coastal se
// reutiliza de evaluate_avx2_batch_; el crest sharpening se vectoriza con
// evaluate_band_height_avx2 (LONG/MID × center/left/right). El Jacobian finito
// evalúa el displacement FINAL en 4 offsets (±0.05 m) por diferencias centrales.

void OceanQueryCore::apply_crest_sharpen_batch_(const size_t *indices, size_t active_count, bool vector_sincos) {
    if (!crest_sharpen_enabled || cascades.size() < 2 || active_count == 0) { return; }
    const double local_hs = std::max(crest_sharpen_local_hs, 0.05);
    const double eps = crest_sharpen_eps;
    const double dirx = crest_sharpen_dir_x, dirz = crest_sharpen_dir_z;
    for (size_t ai = 0; ai < active_count; ++ai) {
        const size_t p = indices[ai];
        const double qx = batch_.qx[p], qz = batch_.qz[p];
        batch_.sharpen_lqx[p] = qx - dirx * eps;
        batch_.sharpen_lqz[p] = qz - dirz * eps;
        batch_.sharpen_rqx[p] = qx + dirx * eps;
        batch_.sharpen_rqz[p] = qz + dirz * eps;
    }
    evaluate_band_height_avx2(cascades[0], batch_.qx.data(), batch_.qz.data(), indices, active_count, batch_.band_l_c.data(), vector_sincos);
    evaluate_band_height_avx2(cascades[0], batch_.sharpen_lqx.data(), batch_.sharpen_lqz.data(), indices, active_count, batch_.band_l_l.data(), vector_sincos);
    evaluate_band_height_avx2(cascades[0], batch_.sharpen_rqx.data(), batch_.sharpen_rqz.data(), indices, active_count, batch_.band_l_r.data(), vector_sincos);
    evaluate_band_height_avx2(cascades[1], batch_.qx.data(), batch_.qz.data(), indices, active_count, batch_.band_m_c.data(), vector_sincos);
    evaluate_band_height_avx2(cascades[1], batch_.sharpen_lqx.data(), batch_.sharpen_lqz.data(), indices, active_count, batch_.band_m_l.data(), vector_sincos);
    evaluate_band_height_avx2(cascades[1], batch_.sharpen_rqx.data(), batch_.sharpen_rqz.data(), indices, active_count, batch_.band_m_r.data(), vector_sincos);
    const double strength = crest_sharpen_strength;
    const double threshold = crest_sharpen_threshold;
    const double max_gain = crest_sharpen_max_gain;
    const double long_w = crest_sharpen_long_weight, mid_w = crest_sharpen_mid_weight;
    for (size_t ai = 0; ai < active_count; ++ai) {
        const size_t p = indices[ai];
        const double curv_long = batch_.band_l_l[p] - 2.0 * batch_.band_l_c[p] + batch_.band_l_r[p];
        const double curv_mid = batch_.band_m_l[p] - 2.0 * batch_.band_m_c[p] + batch_.band_m_r[p];
        const double crest_long = std::clamp(-curv_long / local_hs, 0.0, 2.0) * long_w;
        const double crest_mid = std::clamp(-curv_mid / std::max(local_hs * 0.4, 0.02), 0.0, 2.0) * mid_w;
        const double crestness = crest_long + crest_mid;
        const double face_slope = std::abs(batch_.band_l_r[p] - batch_.band_l_l[p]) / (2.0 * eps);
        const double compression = smoothstep01(0.03, 0.22, face_slope);
        const double sharpen = smoothstep01(threshold, threshold + 0.25, crestness)
            * compression * strength;
        const double delta_y = sharpen * max_gain * local_hs;
        const double h_scale = 1.0 + sharpen * max_gain * 0.35;
        batch_.h[p] += delta_y;
        batch_.dx[p] *= h_scale;
        batch_.dz[p] *= h_scale;
    }
}

void OceanQueryCore::evaluate_center_sharpened_(const size_t *indices, size_t active_count, bool vector_sincos) {
    evaluate_avx2_batch_(indices, active_count, vector_sincos);
    apply_crest_sharpen_batch_(indices, active_count, vector_sincos);
    // Guarda el dx/dz FINAL del centro: el Jacobian finito sobrescribe batch_.dx/dz
    // y el paso de Newton necesita el residual del centro.
    for (size_t ai = 0; ai < active_count; ++ai) {
        const size_t p = indices[ai];
        batch_.sharpen_cdx[p] = batch_.dx[p];
        batch_.sharpen_cdz[p] = batch_.dz[p];
    }
}

void OceanQueryCore::evaluate_offset_final_(const size_t *indices, size_t active_count, double ox, double oz, bool vector_sincos) {
    for (size_t ai = 0; ai < active_count; ++ai) {
        const size_t p = indices[ai];
        batch_.fd_save_qx[p] = batch_.qx[p];
        batch_.fd_save_qz[p] = batch_.qz[p];
        batch_.qx[p] += ox;
        batch_.qz[p] += oz;
    }
    evaluate_avx2_batch_(indices, active_count, vector_sincos);
    apply_crest_sharpen_batch_(indices, active_count, vector_sincos);
    for (size_t ai = 0; ai < active_count; ++ai) {
        const size_t p = indices[ai];
        batch_.fd_dx[p] = batch_.dx[p];
        batch_.fd_dz[p] = batch_.dz[p];
        batch_.qx[p] = batch_.fd_save_qx[p];
        batch_.qz[p] = batch_.fd_save_qz[p];
    }
}

void OceanQueryCore::compute_finite_jacobian_batch_(const size_t *indices, size_t active_count, bool vector_sincos) {
    const double d = 0.05;
    const double inv_2d = 1.0 / (2.0 * d);
    evaluate_offset_final_(indices, active_count, d, 0.0, vector_sincos);
    for (size_t ai = 0; ai < active_count; ++ai) {
        const size_t p = indices[ai];
        batch_.jac_a[p] = 1.0 + batch_.fd_dx[p] * inv_2d;
        batch_.jac_c[p] = batch_.fd_dz[p] * inv_2d;
    }
    evaluate_offset_final_(indices, active_count, -d, 0.0, vector_sincos);
    for (size_t ai = 0; ai < active_count; ++ai) {
        const size_t p = indices[ai];
        batch_.jac_a[p] -= batch_.fd_dx[p] * inv_2d;
        batch_.jac_c[p] -= batch_.fd_dz[p] * inv_2d;
    }
    evaluate_offset_final_(indices, active_count, 0.0, d, vector_sincos);
    for (size_t ai = 0; ai < active_count; ++ai) {
        const size_t p = indices[ai];
        batch_.jac_b[p] = batch_.fd_dx[p] * inv_2d;
        batch_.jac_d[p] = 1.0 + batch_.fd_dz[p] * inv_2d;
    }
    evaluate_offset_final_(indices, active_count, 0.0, -d, vector_sincos);
    for (size_t ai = 0; ai < active_count; ++ai) {
        const size_t p = indices[ai];
        batch_.jac_b[p] -= batch_.fd_dx[p] * inv_2d;
        batch_.jac_d[p] -= batch_.fd_dz[p] * inv_2d;
    }
}

void OceanQueryCore::solve_avx2_batch_sharpened_(size_t n, double *out, bool vector_sincos) {
    diag_last_spectral_point_evaluations = 0;
    for (int &count : diag_last_newton_histogram) { count = 0; }
    size_t active_count = n;
    for (size_t p = 0; p < n; ++p) {
        batch_.iterations[p] = 0;
        batch_.active_indices[p] = p;
    }
    evaluate_center_sharpened_(batch_.active_indices.data(), active_count, vector_sincos);
    for (size_t ai = 0; ai < active_count; ++ai) {
        const size_t p = batch_.active_indices[ai];
        const double fx = batch_.qx[p] + batch_.dx[p] - batch_.wx[p];
        const double fz = batch_.qz[p] + batch_.dz[p] - batch_.wz[p];
        batch_.residual[p] = std::sqrt(fx * fx + fz * fz);
        batch_.done[p] = batch_.residual[p] <= POSITION_TOLERANCE_M ? 1 : 0;
    }
    size_t next_count = 0;
    for (size_t p = 0; p < n; ++p) if (!batch_.done[p]) batch_.active_indices[next_count++] = p;
    active_count = next_count;

    for (int iteration = 0; iteration < MAX_ITERATIONS && active_count > 0; ++iteration) {
        compute_finite_jacobian_batch_(batch_.active_indices.data(), active_count, vector_sincos);
        next_count = 0;
        for (size_t ai = 0; ai < active_count; ++ai) {
            const size_t p = batch_.active_indices[ai];
            const double det = batch_.jac_a[p] * batch_.jac_d[p] - batch_.jac_b[p] * batch_.jac_c[p];
            if (std::abs(det) <= JACOBIAN_EPSILON) { continue; }
            const double fx = batch_.qx[p] + batch_.sharpen_cdx[p] - batch_.wx[p];
            const double fz = batch_.qz[p] + batch_.sharpen_cdz[p] - batch_.wz[p];
            const double inv = 1.0 / det;
            batch_.qx[p] -= inv * (batch_.jac_d[p] * fx - batch_.jac_b[p] * fz);
            batch_.qz[p] -= inv * (-batch_.jac_c[p] * fx + batch_.jac_a[p] * fz);
            batch_.active_indices[next_count++] = p;
        }
        active_count = next_count;
        if (active_count == 0) { break; }
        evaluate_center_sharpened_(batch_.active_indices.data(), active_count, vector_sincos);
        next_count = 0;
        for (size_t ai = 0; ai < active_count; ++ai) {
            const size_t p = batch_.active_indices[ai];
            const double fx = batch_.qx[p] + batch_.dx[p] - batch_.wx[p];
            const double fz = batch_.qz[p] + batch_.dz[p] - batch_.wz[p];
            batch_.residual[p] = std::sqrt(fx * fx + fz * fz);
            batch_.iterations[p] = iteration + 1;
            if (batch_.residual[p] <= POSITION_TOLERANCE_M) { batch_.done[p] = 1; }
            else { batch_.active_indices[next_count++] = p; }
        }
        active_count = next_count;
    }

    for (size_t p = 0; p < n; ++p) {
        const bool converged = batch_.done[p] != 0;
        if (converged) { ++diag_last_newton_histogram[batch_.iterations[p]]; }
        else { ++diag_last_newton_histogram[4]; ++diag_non_converged; }
        build_sample_from_fields_(p, converged, out + p * S_STRIDE);
    }
}

void OceanQueryCore::sample_batch_true_prepared(const double *positions_xz, size_t n, double *out) {
    if (n == 0) { return; }
    batch_.ensure_capacity(n);
    for (size_t p = 0; p < n; ++p) {
        batch_.wx[p] = positions_xz[2 * p]; batch_.wz[p] = positions_xz[2 * p + 1];
        batch_.qx[p] = batch_.wx[p]; batch_.qz[p] = batch_.wz[p];
    }
    solve_true_batch_(n, out, false);
}

void OceanQueryCore::sample_batch_warm_prepared(const double *positions_xz, const double *initial_q_xz,
                                                 size_t n, double *out) {
    if (n == 0) { return; }
    batch_.ensure_capacity(n);
    for (size_t p = 0; p < n; ++p) {
        batch_.wx[p] = positions_xz[2 * p]; batch_.wz[p] = positions_xz[2 * p + 1];
        const double qx = initial_q_xz[2 * p], qz = initial_q_xz[2 * p + 1];
        const bool valid_guess = std::isfinite(qx) && std::isfinite(qz);
        batch_.qx[p] = valid_guess ? qx : batch_.wx[p];
        batch_.qz[p] = valid_guess ? qz : batch_.wz[p];
    }
    solve_true_batch_(n, out, true);
}

} // namespace oq
