// OceanQuery core nativo (Fase 2C) — implementación.
// Puerto EXACTO de OceanQueryReduced._accumulate / _sample_world / _prepare_time.
// La matemática NO cambia respecto a 2B (GDScript).

#include "ocean_query_core.h"

#include <cmath>
#include <cstring>

namespace oq {

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
}

void OceanQueryCore::finalize_spectrum() {
    for (Cascade &c : cascades) {
        const size_t count = c.kx.size();
        c.ev_h_re.assign(count, 0.0);
        c.ev_h_im.assign(count, 0.0);
        c.ev_v_re.assign(count, 0.0);
        c.ev_v_im.assign(count, 0.0);
    }
    prepared_valid = false;
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
        }
    }
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

void OceanQueryCore::sample_prepared_(double wx, double wz, double *out) {
    // Newton world_xz -> q (mismo algoritmo que GDScript).
    double qx = wx, qz = wz;
    double h, dx, dz, dhx, dhz, dxx, dxz, dzx, dzz, vh, vx, vz;
    accumulate_(qx, qz, true, prepared_time, h, dx, dz, dhx, dhz, dxx, dxz, dzx, dzz, vh, vx, vz);
    double fx = qx + dx - wx;
    double fz = qz + dz - wz;
    double residual = std::sqrt(fx * fx + fz * fz);
    int iterations = 0;
    bool converged = residual <= POSITION_TOLERANCE_M;
    while (!converged && iterations < MAX_ITERATIONS) {
        const double det_j = (1.0 + dxx) * (1.0 + dzz) - dxz * dzx;
        if (std::abs(det_j) <= JACOBIAN_EPSILON) {
            break;
        }
        const double inv_det = 1.0 / det_j;
        const double delta_x = inv_det * ((1.0 + dzz) * fx - dxz * fz);
        const double delta_z = inv_det * (-dzx * fx + (1.0 + dxx) * fz);
        qx -= delta_x;
        qz -= delta_z;
        accumulate_(qx, qz, true, prepared_time, h, dx, dz, dhx, dhz, dxx, dxz, dzx, dzz, vh, vx, vz);
        fx = qx + dx - wx;
        fz = qz + dz - wz;
        residual = std::sqrt(fx * fx + fz * fz);
        iterations += 1;
        converged = residual <= POSITION_TOLERANCE_M;
    }
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
    for (size_t i = 0; i < n; ++i) {
        sample_prepared_(positions_xz[2 * i], positions_xz[2 * i + 1], out + i * S_STRIDE);
    }
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
    diag_last_spectral_point_evaluations += active_count;
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
