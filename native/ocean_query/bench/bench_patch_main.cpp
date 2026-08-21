// bench_patch_main.cpp - benchmark PATCH vs DIRECT (Fase 2C.1A).
// Prototipo standalone: compara OceanQueryPatchCore (local, world-aligned,
// recurrencia de fase + interpolacion bilineal) contra OceanQueryCore DIRECT
// (verdad del Reduced). Mismo lector de datos que bench_main.cpp.
//
// Uso: bench_patch_main <data_file> <cfg:A|B> [out_prefix]
//   cfg A: LONG 1.0 m (7x7), MID 0.5 m (13x13), SHORT 0.25 m (25x25)
//   cfg B: LONG 1.0 m (7x7), MID 0.5 m (13x13), SHORT 0.125 m (49x49)

#include "../src/ocean_query_core.h"
#include "../src/ocean_query_patch_core.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

static std::vector<double> read_line(std::istream &in) {
    std::vector<double> values;
    std::string line;
    std::getline(in, line);
    std::istringstream ss(line);
    double v;
    while (ss >> v) {
        values.push_back(v);
    }
    return values;
}

static bool load_data(const char *path, oq::OceanQueryCore &direct, oq_patch::OceanQueryPatchCore &patch) {
    std::ifstream in(path);
    if (!in) {
        std::fprintf(stderr, "no se pudo abrir %s\n", path);
        return false;
    }
    auto header = read_line(in);
    const size_t cascade_count = static_cast<size_t>(header[0]);
    direct.sea_level = header[1];
    patch.core.sea_level = header[1];
    for (size_t ci = 0; ci < cascade_count; ++ci) {
        auto meta = read_line(in);
        const size_t count = static_cast<size_t>(meta[2]);
        std::vector<double> kx = read_line(in), ky = read_line(in), omega = read_line(in);
        std::vector<double> a1 = read_line(in), a2 = read_line(in);
        std::vector<double> c11 = read_line(in), c12 = read_line(in);
        std::vector<double> c21 = read_line(in), c22 = read_line(in);
        std::vector<double> parity = read_line(in), weight = read_line(in);
        std::vector<double> h0_re = read_line(in), h0_im = read_line(in);
        std::vector<double> h0n_re = read_line(in), h0n_im = read_line(in);
        if (kx.size() != count || ky.size() != count || omega.size() != count ||
            a1.size() != count || a2.size() != count || c11.size() != count ||
            c12.size() != count || c21.size() != count || c22.size() != count ||
            parity.size() != count || weight.size() != count || h0_re.size() != count ||
            h0_im.size() != count || h0n_re.size() != count || h0n_im.size() != count) {
            std::fprintf(stderr, "datos incompletos cascade %zu\n", ci);
            return false;
        }
        direct.set_cascade_data(ci, meta[1],
                                kx.data(), ky.data(), omega.data(),
                                a1.data(), a2.data(), c11.data(), c12.data(), c21.data(), c22.data(),
                                parity.data(), weight.data(),
                                h0_re.data(), h0_im.data(), h0n_re.data(), h0n_im.data(), count);
        patch.core.set_cascade_data(ci, meta[1],
                                    kx.data(), ky.data(), omega.data(),
                                    a1.data(), a2.data(), c11.data(), c12.data(), c21.data(), c22.data(),
                                    parity.data(), weight.data(),
                                    h0_re.data(), h0_im.data(), h0n_re.data(), h0n_im.data(), count);
    }
    direct.finalize_spectrum();
    patch.core.finalize_spectrum();
    return true;
}

static void configure_patch(oq_patch::OceanQueryPatchCore &patch, char cfg) {
    patch.set_grid_spec(0, 1.0, 7, 7);   // LONG  1.0 m -> 7x7
    patch.set_grid_spec(1, 0.5, 13, 13); // MID   0.5 m -> 13x13
    if (cfg == 'B') {
        patch.set_grid_spec(2, 0.125, 49, 49); // SHORT 0.125 m -> 49x49
    } else {
        patch.set_grid_spec(2, 0.25, 25, 25);  // SHORT 0.25 m -> 25x25
    }
}

static double lcg01(uint64_t &s) {
    s = s * 6364136223846793005ULL + 1442695040888963407ULL;
    return static_cast<double>((s >> 33) & 0xFFFFFF) / 16777216.0; // [0,1)
}

struct ErrStats {
    std::vector<double> h, dhoriz, dvert, norm_deg, vel, jac;
    void add(double eh, double edh, double edv, double ang_deg, double ev, double ej) {
        h.push_back(eh);
        dhoriz.push_back(edh);
        dvert.push_back(edv);
        norm_deg.push_back(ang_deg);
        vel.push_back(ev);
        jac.push_back(ej);
    }
    static double rmse(const std::vector<double> &v) {
        if (v.empty()) return 0.0;
        double s = 0.0;
        for (double x : v) s += x * x;
        return std::sqrt(s / static_cast<double>(v.size()));
    }
    static double p95(const std::vector<double> &v) {
        if (v.empty()) return 0.0;
        std::vector<double> c = v;
        std::sort(c.begin(), c.end());
        size_t idx = static_cast<size_t>(0.95 * static_cast<double>(c.size() - 1));
        return c[idx];
    }
    static double maxv(const std::vector<double> &v) {
        if (v.empty()) return 0.0;
        return *std::max_element(v.begin(), v.end());
    }
    void print(const char *tag) const {
        std::printf("%s height   RMSE %.6f P95 %.6f MAX %.6f (n=%zu)\n", tag, rmse(h), p95(h), maxv(h), h.size());
        std::printf("%s dHoriz  RMSE %.6f P95 %.6f\n", tag, rmse(dhoriz), p95(dhoriz));
        std::printf("%s dVert   RMSE %.6f P95 %.6f\n", tag, rmse(dvert), p95(dvert));
        std::printf("%s normal  RMSE %.4f deg P95 %.4f MAX %.4f\n", tag, rmse(norm_deg), p95(norm_deg), maxv(norm_deg));
        std::printf("%s vel     RMSE %.6f P95 %.6f\n", tag, rmse(vel), p95(vel));
        std::printf("%s jacob   RMSE %.6f\n", tag, rmse(jac));
    }
};

static double vec_angle_deg(const double a[3], const double b[3]) {
    double dot = a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
    dot = std::max(-1.0, std::min(1.0, dot));
    return std::acos(dot) * 180.0 / 3.14159265358979323846;
}

struct QuerySet {
    std::vector<double> xz;   // 2*n
    std::vector<int> kind;    // 0=hull 1=grid 2=rand 3=center 4=border 5=outside
};

static QuerySet gen_queries(double cx, double cz, double half, uint64_t rng_seed) {
    QuerySet q;
    const double hw = 1.55, hl = 0.60; // casco ~3.1 x 1.2 m
    for (int i = 0; i < 4; ++i) {
        for (int j = 0; j < 4; ++j) {
            double x = cx - hw + (2.0 * hw) * (i / 3.0);
            double z = cz - hl + (2.0 * hl) * (j / 3.0);
            q.xz.push_back(x); q.xz.push_back(z); q.kind.push_back(0);
        }
    }
    for (int i = 0; i < 6; ++i) {
        for (int j = 0; j < 6; ++j) {
            double x = cx - half + (2.0 * half) * (i / 5.0);
            double z = cz - half + (2.0 * half) * (j / 5.0);
            q.xz.push_back(x); q.xz.push_back(z); q.kind.push_back(1);
        }
    }
    uint64_t s = rng_seed;
    for (int k = 0; k < 40; ++k) {
        double x = cx - half + 2.0 * half * lcg01(s);
        double z = cz - half + 2.0 * half * lcg01(s);
        q.xz.push_back(x); q.xz.push_back(z); q.kind.push_back(2);
    }
    for (int k = 0; k < 8; ++k) {
        double a = 6.283185307179586 * lcg01(s);
        double r = 0.5 * lcg01(s);
        q.xz.push_back(cx + r * std::cos(a)); q.xz.push_back(cz + r * std::sin(a)); q.kind.push_back(3);
    }
    for (int k = 0; k < 8; ++k) {
        double off = half - 0.5;
        double x = cx + (k < 4 ? -off : off);
        double z = cz + ((k % 4) < 2 ? -off : off);
        q.xz.push_back(x); q.xz.push_back(z); q.kind.push_back(4);
    }
    for (int k = 0; k < 4; ++k) {
        double off = half + 1.0 + 0.5 * lcg01(s);
        double a = 6.283185307179586 * lcg01(s);
        q.xz.push_back(cx + off * std::cos(a)); q.xz.push_back(cz + off * std::sin(a)); q.kind.push_back(5);
    }
    return q;
}

static void run_accuracy(oq::OceanQueryCore &direct, oq_patch::OceanQueryPatchCore &patch,
                         const char *tag, const std::vector<double> &times,
                         const std::vector<double> &centers, double half) {
    ErrStats all, hull, center;
    long long fallback = 0, nonconv = 0, total = 0;
    long long fb_kind[6] = {0, 0, 0, 0, 0, 0};
    long long n_kind[6] = {0, 0, 0, 0, 0, 0};
    double direct_invalid = 0.0;
    double residual_sum_p = 0.0, residual_sum_d = 0.0;
    double iter_sum_p = 0.0, iter_sum_d = 0.0;
    long long jac_sign_mismatch = 0;
    double node_err = 0.0;
    int node_err_n = 0;

    for (double t : times) {
        direct.ensure_prepared(t);
        patch.core.ensure_prepared(t);
        for (size_t ci = 0; ci + 1 < centers.size(); ci += 2) {
            const double cx = centers[ci], cz = centers[ci + 1];
            patch.build_patch(cx, cz);
            QuerySet qs = gen_queries(cx, cz, half, 20260820);
            for (size_t i = 0; i + 1 < qs.xz.size(); i += 2) {
                const double wx = qs.xz[i], wz = qs.xz[i + 1];
                const int kind = qs.kind[i / 2];
                double out_d[oq::S_STRIDE], out_p[oq::S_STRIDE];
                direct.sample_prepared(wx, wz, out_d);
                int rc = patch.sample_patch_prepared(wx, wz, out_p);
                total += 1;
                n_kind[kind] += 1;
                if (rc == 0) {
                    fallback += 1;
                    fb_kind[kind] += 1;
                    continue;
                }
                if (rc == -1) {
                    nonconv += 1;
                }
                if (out_d[oq::S_VALID] < 0.5) {
                    direct_invalid += 1.0;
                }
                double edh = std::hypot(out_p[oq::S_DX] - out_d[oq::S_DX], out_p[oq::S_DZ] - out_d[oq::S_DZ]);
                double edv = std::abs(out_p[oq::S_DY] - out_d[oq::S_DY]);
                double eh = std::abs(out_p[oq::S_HEIGHT] - out_d[oq::S_HEIGHT]);
                double ang = vec_angle_deg(out_p + oq::S_NX, out_d + oq::S_NX);
                double ev = std::hypot(out_p[oq::S_VX] - out_d[oq::S_VX], out_p[oq::S_VZ] - out_d[oq::S_VZ]);
                ev = std::hypot(ev, out_p[oq::S_VY] - out_d[oq::S_VY]);
                double ej = std::abs(out_p[oq::S_JACOBIAN_DET] - out_d[oq::S_JACOBIAN_DET]);
                if ((out_p[oq::S_JACOBIAN_DET] <= 0.0) != (out_d[oq::S_JACOBIAN_DET] <= 0.0)) {
                    jac_sign_mismatch += 1;
                }
                all.add(eh, edh, edv, ang, ev, ej);
                if (kind == 0) hull.add(eh, edh, edv, ang, ev, ej);
                if (kind == 3) center.add(eh, edh, edv, ang, ev, ej);
                residual_sum_p += out_p[oq::S_RESIDUAL];
                residual_sum_d += out_d[oq::S_RESIDUAL];
                iter_sum_p += out_p[oq::S_ITERATIONS];
                iter_sum_d += out_d[oq::S_ITERATIONS];
            }
            // Nodo exacto de CADA grid: recurrencia pura vs DIRECT de esa cascada.
            for (size_t gi = 0; gi < patch.grids.size(); ++gi) {
                const oq_patch::GridData &g = patch.grids[gi];
                if (!g.spec.valid()) continue;
                const int nx = g.spec.nx;
                const int mid = nx / 2;
                const double qxn = g.x0 + mid * g.spec.spacing;
                const double qzn = g.z0 + mid * g.spec.spacing;
                const double *f = g.fields.data() + (static_cast<size_t>(mid) * nx + mid) * oq_patch::PF_COUNT;
                oq::OceanQueryCore solo;
                solo.sea_level = 0.0;
                const oq::Cascade &sc = patch.core.cascades[gi];
                solo.set_cascade_data(0, sc.inv_n2, sc.kx.data(), sc.ky.data(), sc.omega.data(),
                                      sc.a1.data(), sc.a2.data(), sc.c11.data(), sc.c12.data(),
                                      sc.c21.data(), sc.c22.data(), sc.parity.data(), sc.weight.data(),
                                      sc.h0_re.data(), sc.h0_im.data(), sc.h0n_re.data(), sc.h0n_im.data(),
                                      sc.kx.size());
                solo.finalize_spectrum();
                solo.ensure_prepared(t);
                double h, dx, dz, dhx, dhz, dxx, dxz, dzx, dzz, vh, vx, vz;
                solo.accumulate_public(qxn, qzn, true, t, h, dx, dz, dhx, dhz, dxx, dxz, dzx, dzz, vh, vx, vz);
                node_err += std::abs(f[oq_patch::PF_H] - h) + std::abs(f[oq_patch::PF_DX] - dx) + std::abs(f[oq_patch::PF_DZ] - dz);
                node_err_n += 3;
            }
        }
    }
    char full[128];
    std::snprintf(full, sizeof(full), "ACC %s", tag);
    all.print(full);
    hull.print("  HULL");
    center.print("  CENTER");
    std::printf("%s queries=%lld fallback=%lld (%.2f%%) nonconv=%lld (%.2f%%) direct_invalid=%.2f%% jac_sign_mismatch=%lld\n",
                full, total, fallback, 100.0 * fallback / std::max(total, 1LL),
                nonconv, 100.0 * nonconv / std::max(total, 1LL),
                100.0 * direct_invalid / std::max(total, 1LL), jac_sign_mismatch);
    std::printf("%s fallback_by_kind (0=hull 1=grid 2=rand 3=center 4=border 5=outside): ",
                full);
    for (int k = 0; k < 6; ++k) {
        std::printf("k%d:%lld/%lld ", k, fb_kind[k], n_kind[k]);
    }
    std::printf("\n");
    std::printf("%s newton patch_res_avg=%.6f direct_res_avg=%.6f patch_iter_avg=%.2f direct_iter_avg=%.2f\n",
                full, residual_sum_p / std::max(total - fallback, 1LL), residual_sum_d / std::max(total - fallback, 1LL),
                iter_sum_p / std::max(total - fallback, 1LL), iter_sum_d / std::max(total - fallback, 1LL));
    std::printf("%s node_exact_recurrence_avg_err=%.3e (n=%d)\n", full, node_err / std::max(node_err_n, 1), node_err_n);
}

using Clock = std::chrono::steady_clock;
static double ms(Clock::duration d) { return std::chrono::duration<double, std::milli>(d).count(); }

static double median5(double t[5]) {
    std::sort(t, t + 5);
    return t[2];
}

static void run_perf(oq::OceanQueryCore &direct, oq_patch::OceanQueryPatchCore &patch,
                     const char *tag, double t, const std::vector<double> &racer_pos, double half) {
    direct.ensure_prepared(t);
    patch.core.ensure_prepared(t);
    {
        double times[5];
        for (int rep = 0; rep < 5; ++rep) {
            auto t0 = Clock::now();
            direct.ensure_prepared(1.0 + rep);
            direct.ensure_prepared(1.0 + rep);
            times[rep] = ms(Clock::now() - t0);
        }
        double d_prep = median5(times);
        for (int rep = 0; rep < 5; ++rep) {
            auto t0 = Clock::now();
            patch.core.ensure_prepared(1.0 + rep);
            patch.core.ensure_prepared(1.0 + rep);
            times[rep] = ms(Clock::now() - t0);
        }
        double p_prep = median5(times);
        std::printf("PERF %s prepare_ms DIRECT=%.4f PATCH=%.4f\n", tag, d_prep, p_prep);
    }
    {
        patch.set_grid_spec(1, 0.0, 0, 0);
        patch.set_grid_spec(2, 0.0, 0, 0);
        double times[5];
        for (int rep = 0; rep < 5; ++rep) {
            auto t0 = Clock::now();
            patch.build_patch(racer_pos[0], racer_pos[1]);
            times[rep] = ms(Clock::now() - t0);
        }
        double t_long = median5(times);
        patch.set_grid_spec(1, 0.5, 13, 13);
        for (int rep = 0; rep < 5; ++rep) {
            auto t0 = Clock::now();
            patch.build_patch(racer_pos[0], racer_pos[1]);
            times[rep] = ms(Clock::now() - t0);
        }
        double t_long_mid = median5(times);
        bool cfg_b = (std::string(tag).find("_B") != std::string::npos);
        patch.set_grid_spec(2, cfg_b ? 0.125 : 0.25, cfg_b ? 49 : 25, cfg_b ? 49 : 25);
        for (int rep = 0; rep < 5; ++rep) {
            auto t0 = Clock::now();
            patch.build_patch(racer_pos[0], racer_pos[1]);
            times[rep] = ms(Clock::now() - t0);
        }
        double t_all = median5(times);
        std::printf("PERF %s build LONG=%.4f MID=%.4f SHORT=%.4f TOTAL=%.4f ms\n",
                    tag, t_long, t_long_mid - t_long, t_all - t_long_mid, t_all);
        patch.build_patch(racer_pos[0], racer_pos[1]);
    }
    // Memoria por patch (campos + pasos de fase) y determinismo (2 builds iguales).
    {
        size_t bytes = 0;
        for (size_t gi = 0; gi < patch.grids.size(); ++gi) {
            const oq_patch::GridData &g = patch.grids[gi];
            if (!g.spec.valid()) continue;
            const size_t nodes = static_cast<size_t>(g.spec.nx) * static_cast<size_t>(g.spec.nz);
            bytes += nodes * oq_patch::PF_COUNT * sizeof(double);
            bytes += (g.step_x_re.size() + g.step_x_im.size() + g.step_z_re.size() + g.step_z_im.size()) * sizeof(double);
            std::printf("PERF %s grid %zu %dx%d (%.3f m) nodos=%zu campos=%.1f KB pasos=%.1f KB\n",
                        tag, gi, g.spec.nx, g.spec.nz, g.spec.spacing, nodes,
                        nodes * oq_patch::PF_COUNT * sizeof(double) / 1024.0,
                        (g.step_x_re.size() * 4 * sizeof(double)) / 1024.0);
        }
        std::printf("PERF %s memoria_patch_total=%.1f KB\n", tag, bytes / 1024.0);
        // determinismo: dos builds con el mismo centro deben dar el mismo campo H
        patch.build_patch(racer_pos[0], racer_pos[1]);
        const oq_patch::GridData &g0 = patch.grids[2];
        double h_before = g0.fields[oq_patch::PF_H];
        patch.build_patch(racer_pos[0], racer_pos[1]);
        const oq_patch::GridData &g1 = patch.grids[2];
        double max_diff = 0.0;
        for (size_t i = 0; i < g1.fields.size(); ++i) {
            double d = std::abs(g0.fields[i] - g1.fields[i]);
            if (d > max_diff) max_diff = d;
        }
        std::printf("PERF %s determinismo_build_max_diff=%.3e\n", tag, max_diff);
    }
    const int counts[] = {16, 32, 64};
    for (int c : counts) {
        double times_d[5], times_p[5];
        std::vector<double> qxz;
        for (int i = 0; i < c; ++i) {
            double a = 6.283185307179586 * i / c;
            qxz.push_back(racer_pos[0] + 1.0 * std::cos(a));
            qxz.push_back(racer_pos[1] + 1.0 * std::sin(a));
        }
        std::vector<double> outd(c * oq::S_STRIDE), outp(c * oq::S_STRIDE);
        for (int rep = 0; rep < 5; ++rep) {
            auto t0 = Clock::now();
            for (int i = 0; i < c; ++i) direct.sample_prepared(qxz[2 * i], qxz[2 * i + 1], &outd[i * oq::S_STRIDE]);
            times_d[rep] = ms(Clock::now() - t0);
        }
        for (int rep = 0; rep < 5; ++rep) {
            auto t0 = Clock::now();
            for (int i = 0; i < c; ++i) patch.sample_patch_prepared(qxz[2 * i], qxz[2 * i + 1], &outp[i * oq::S_STRIDE]);
            times_p[rep] = ms(Clock::now() - t0);
        }
        std::printf("PERF %s queries %d DIRECT=%.4f PATCH=%.4f (x%.1f)\n",
                    tag, c, median5(times_d), median5(times_p), median5(times_d) / std::max(median5(times_p), 1e-4));
    }
    const int racers_counts[] = {1, 4, 8};
    for (int nr : racers_counts) {
        const int per_racer = 16;
        const int nq = nr * per_racer;
        std::vector<double> centers_xz, qxz;
        for (int r = 0; r < nr; ++r) {
            double cx = racer_pos[0] + (r % 4) * 40.0;
            double cz = racer_pos[1] + (r / 4) * 40.0;
            centers_xz.push_back(cx); centers_xz.push_back(cz);
            for (int i = 0; i < per_racer; ++i) {
                double a = 6.283185307179586 * (i + r) / per_racer;
                qxz.push_back(cx + 1.0 * std::cos(a));
                qxz.push_back(cz + 1.0 * std::sin(a));
            }
        }
        std::vector<double> out(nq * oq::S_STRIDE);
        double times_d[5], times_p[5];
        for (int rep = 0; rep < 5; ++rep) {
            auto t0 = Clock::now();
            for (int i = 0; i < nq; ++i) direct.sample_prepared(qxz[2 * i], qxz[2 * i + 1], &out[i * oq::S_STRIDE]);
            times_d[rep] = ms(Clock::now() - t0);
        }
        for (int rep = 0; rep < 5; ++rep) {
            auto t0 = Clock::now();
            for (int r = 0; r < nr; ++r) patch.build_patch(centers_xz[2 * r], centers_xz[2 * r + 1]);
            for (int i = 0; i < nq; ++i) patch.sample_patch_prepared(qxz[2 * i], qxz[2 * i + 1], &out[i * oq::S_STRIDE]);
            times_p[rep] = ms(Clock::now() - t0);
        }
        std::printf("PERF %s scenario %d racers (%dq): DIRECT=%.4f PATCH=%.4f (x%.2f)\n",
                    tag, nr, nq, median5(times_d), median5(times_p),
                    median5(times_d) / std::max(median5(times_p), 1e-4));
    }
}

// --- Modo golden: compara PATCH contra una referencia GOLDEN (OceanQueryReference)
// generada por dump_golden_patch.gd. Uso:
//   bench_patch_main <data_file> <cfg:A|B> --golden <ref_golden.txt>
// El archivo ref tiene una línea por query en el MISMO orden que gen_queries
// (mismo RNG): valid height dx dy dz nx ny nz vx vy vz jac foldover res iter.
static void run_golden(oq::OceanQueryCore &direct, oq_patch::OceanQueryPatchCore &patch,
                       const char *tag, const std::vector<double> &times,
                       const std::vector<double> &centers, double half,
                       const char *ref_path, bool small) {
    std::ifstream in(ref_path);
    if (!in) {
        std::fprintf(stderr, "no se pudo abrir golden ref %s\n", ref_path);
        return;
    }
    ErrStats all, hull, all_direct, hull_direct;
    long long total = 0, invalid_ref = 0, fb = 0;
    const std::vector<double> times_sel = small ? std::vector<double>{3.5} : times;
    const size_t center_sel = small ? 2 : centers.size();
    for (double t : times_sel) {
        patch.core.ensure_prepared(t);
        direct.ensure_prepared(t);
        for (size_t ci = 0; ci + 1 < center_sel; ci += 2) {
            const double cx = centers[ci], cz = centers[ci + 1];
            patch.build_patch(cx, cz);
            QuerySet qs = gen_queries(cx, cz, half, 20260820);
            for (size_t i = 0; i + 1 < qs.xz.size(); i += 2) {
                if (small && qs.kind[i / 2] != 0 && qs.kind[i / 2] != 3) continue;
                double ref[oq::S_STRIDE];
                for (int k = 0; k < oq::S_STRIDE; ++k) {
                    if (!(in >> ref[k])) {
                        std::fprintf(stderr, "ref truncado\n");
                        return;
                    }
                }
                total += 1;
                if (ref[oq::S_VALID] < 0.5) {
                    invalid_ref += 1;
                    continue;
                }
                const double wx = qs.xz[i], wz = qs.xz[i + 1];
                double out_p[oq::S_STRIDE], out_d[oq::S_STRIDE];
                int rc = patch.sample_patch_prepared(wx, wz, out_p);
                direct.sample_prepared(wx, wz, out_d);
                double edh = std::hypot(out_p[oq::S_DX] - ref[oq::S_DX], out_p[oq::S_DZ] - ref[oq::S_DZ]);
                double edv = std::abs(out_p[oq::S_DY] - ref[oq::S_DY]);
                double eh = std::abs(out_p[oq::S_HEIGHT] - ref[oq::S_HEIGHT]);
                double ang = vec_angle_deg(out_p + oq::S_NX, ref + oq::S_NX);
                double ev = std::hypot(out_p[oq::S_VX] - ref[oq::S_VX], out_p[oq::S_VZ] - ref[oq::S_VZ]);
                ev = std::hypot(ev, out_p[oq::S_VY] - ref[oq::S_VY]);
                double ej = std::abs(out_p[oq::S_JACOBIAN_DET] - ref[oq::S_JACOBIAN_DET]);
                all.add(eh, edh, edv, ang, ev, ej);
                if (qs.kind[i / 2] == 0) hull.add(eh, edh, edv, ang, ev, ej);
                // DIRECT vs GOLDEN (mismo dataset, para aislar el error del PATCH)
                double edh_d = std::hypot(out_d[oq::S_DX] - ref[oq::S_DX], out_d[oq::S_DZ] - ref[oq::S_DZ]);
                double edv_d = std::abs(out_d[oq::S_DY] - ref[oq::S_DY]);
                double eh_d = std::abs(out_d[oq::S_HEIGHT] - ref[oq::S_HEIGHT]);
                double ang_d = vec_angle_deg(out_d + oq::S_NX, ref + oq::S_NX);
                double ev_d = std::hypot(out_d[oq::S_VX] - ref[oq::S_VX], out_d[oq::S_VZ] - ref[oq::S_VZ]);
                ev_d = std::hypot(ev_d, out_d[oq::S_VY] - ref[oq::S_VY]);
                double ej_d = std::abs(out_d[oq::S_JACOBIAN_DET] - ref[oq::S_JACOBIAN_DET]);
                all_direct.add(eh_d, edh_d, edv_d, ang_d, ev_d, ej_d);
                if (qs.kind[i / 2] == 0) hull_direct.add(eh_d, edh_d, edv_d, ang_d, ev_d, ej_d);
            }
        }
    }
    char full[128];
    std::snprintf(full, sizeof(full), "GOLD %s", tag);
    all.print(full);
    hull.print("  GOLD_HULL");
    std::printf("%s queries=%lld invalid_ref=%lld patch_fallback=%lld\n", full, total, invalid_ref, fb);
    std::printf("  DIRECT_REF (baseline reduced vs golden):\n");
    all_direct.print("    DIRECT");
    hull_direct.print("    DIRECT_HULL");
}

// --- Modo dump-queries: escribe las posiciones/tiempos que usa el dataset de
// precisión (mismo orden y RNG que run_accuracy/run_golden), para que el
// GDScript Golden (dump_golden_patch.gd) evalúe exactamente las mismas queries.
// Uso: bench_patch_main <data_file> <cfg:A|B> --dump-queries <file> [small]
// Con "small": solo kinds hull(0)+center(3), 1 tiempo (3.5) y 2 centros
// (dataset reducido para el GOLDEN, que es muy lento en GDScript).
static void run_dump_queries(const std::vector<double> &times,
                             const std::vector<double> &centers, double half,
                             const char *out_path, bool small) {
    std::ofstream out(out_path);
    const std::vector<double> times_sel = small ? std::vector<double>{3.5} : times;
    const size_t center_sel = small ? 2 : centers.size();
    for (double t : times_sel) {
        for (size_t ci = 0; ci + 1 < center_sel; ci += 2) {
            const double cx = centers[ci], cz = centers[ci + 1];
            QuerySet qs = gen_queries(cx, cz, half, 20260820);
            for (size_t i = 0; i + 1 < qs.xz.size(); i += 2) {
                if (small && qs.kind[i / 2] != 0 && qs.kind[i / 2] != 3) continue;
                out << t << " " << qs.xz[i] << " " << qs.xz[i + 1] << "\n";
            }
        }
    }
    std::printf("DUMP_QUERIES %s (small=%d)\n", out_path, small ? 1 : 0);
}

int main(int argc, char **argv) {
    if (argc < 3) {
        std::fprintf(stderr, "uso: bench_patch_main <data_file> <cfg:A|B> [out_prefix] | --golden <ref> | --dump-queries <file>\n");
        return 1;
    }
    const char *data_file = argv[1];
    const char cfg = argv[2][0];
    const char *prefix = argc >= 4 ? argv[3] : "";
    const char *golden_ref = nullptr;
    const char *dump_queries = nullptr;
    bool small = false;
    for (int a = 3; a < argc; ++a) {
        if (std::string(argv[a]) == "--golden" && a + 1 < argc) {
            golden_ref = argv[a + 1];
        }
        if (std::string(argv[a]) == "--dump-queries" && a + 1 < argc) {
            dump_queries = argv[a + 1];
        }
        if (std::string(argv[a]) == "small") {
            small = true;
        }
    }

    oq::OceanQueryCore direct;
    oq_patch::OceanQueryPatchCore patch;
    if (!load_data(data_file, direct, patch)) {
        return 1;
    }
    configure_patch(patch, cfg);
    std::string fn = data_file;
    size_t p0 = fn.find("data_");
    std::string state_seed = fn.substr(p0 + 5);
    for (char &ch : state_seed) if (ch == '.') ch = '_';
    std::string tag = std::string(prefix) + state_seed + "_" + cfg;

    const std::vector<double> times = {0.0, 2.3, 3.5};
    const std::vector<double> centers = {
        0.0, 0.0,
        10.0, 20.0,
        37.5, -12.25,
        -25.0, 60.0,
    };
    if (dump_queries) {
        run_dump_queries(times, centers, 3.0, dump_queries, small);
        return 0;
    }
    if (golden_ref) {
        run_golden(direct, patch, tag.c_str(), times, centers, 3.0, golden_ref, small);
        std::printf("DONE_GOLDEN %s\n", tag.c_str());
        return 0;
    }

    run_accuracy(direct, patch, tag.c_str(), times, centers, 3.0);

    const std::vector<double> racer_pos = {5.0, -5.0};
    run_perf(direct, patch, tag.c_str(), 3.5, racer_pos, 3.0);

    std::printf("DONE %s patch_builds=%lld fallback_total=%lld nonconv_total=%lld\n",
                tag.c_str(), patch.patch_build_count, patch.patch_fallback_count, patch.patch_non_converged_count);
    return 0;
}
