// bench_main.cpp â€” benchmark standalone del core C++ (Fase 2C).
// Lee datos compactos generados por dump_data.gd y mide prepare + queries.
// Uso: bench_main.exe <data_file> <out_file>

#include "../src/ocean_query_core.h"

#include <chrono>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <limits>
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

int main(int argc, char **argv) {
    if (argc < 3) {
        std::fprintf(stderr, "uso: bench_main <data_file> <out_file>\n");
        return 1;
    }
    std::ifstream in(argv[1]);
    if (!in) {
        std::fprintf(stderr, "no se pudo abrir %s\n", argv[1]);
        return 1;
    }

    oq::OceanQueryCore core;
    auto header = read_line(in); // cascade_count sea_level
    const size_t cascade_count = static_cast<size_t>(header[0]);
    core.sea_level = header[1];
    for (size_t ci = 0; ci < cascade_count; ++ci) {
        auto meta = read_line(in); // index inv_n2 count
        const size_t count = static_cast<size_t>(meta[2]);
        std::vector<double> kx = read_line(in);
        std::vector<double> ky = read_line(in);
        std::vector<double> omega = read_line(in);
        std::vector<double> a1 = read_line(in);
        std::vector<double> a2 = read_line(in);
        std::vector<double> c11 = read_line(in);
        std::vector<double> c12 = read_line(in);
        std::vector<double> c21 = read_line(in);
        std::vector<double> c22 = read_line(in);
        std::vector<double> parity = read_line(in);
        std::vector<double> weight = read_line(in);
        std::vector<double> h0_re = read_line(in);
        std::vector<double> h0_im = read_line(in);
        std::vector<double> h0n_re = read_line(in);
        std::vector<double> h0n_im = read_line(in);
        if (kx.size() != count || ky.size() != count || omega.size() != count ||
            a1.size() != count || a2.size() != count || c11.size() != count ||
            c12.size() != count || c21.size() != count || c22.size() != count ||
            parity.size() != count || weight.size() != count || h0_re.size() != count ||
            h0_im.size() != count || h0n_re.size() != count || h0n_im.size() != count) {
            std::fprintf(stderr, "datos incompletos cascade %zu\n", ci);
            return 1;
        }
        core.set_cascade_data(ci, meta[1],
                              kx.data(), ky.data(), omega.data(),
                              a1.data(), a2.data(), c11.data(), c12.data(), c21.data(), c22.data(),
                              parity.data(), weight.data(),
                              h0_re.data(), h0_im.data(), h0n_re.data(), h0n_im.data(),
                              count);
    }
    core.finalize_spectrum();

    // Posiciones (misma rejilla que el benchmark GDScript 2B, 20x20 m).
    std::vector<double> positions_xz;
    for (int i = 0; i < 64; ++i) {
        positions_xz.push_back(-10.0 + double(i % 8) * 2.8);
        positions_xz.push_back(-10.0 + double(i / 8) * 2.8);
    }

    using clock = std::chrono::steady_clock;
    auto ms = [](clock::duration d) { return std::chrono::duration<double, std::milli>(d).count(); };

    // A. prepare_time (media de 5, incl. cache).
    {
        double total = 0.0;
        for (int rep = 0; rep < 5; ++rep) {
            auto t0 = clock::now();
            core.ensure_prepared(1.0 + rep);
            core.ensure_prepared(1.0 + rep); // cacheado
            total += ms(clock::now() - t0);
        }
        std::printf("CORE_BENCH prepare_time_ms %.4f\n", total / 5.0);
    }

    const int counts[] = {1, 4, 8, 16, 32, 64};
    core.ensure_prepared(3.5);
    // Warmup.
    for (int i = 0; i < 4; ++i) {
        double out[oq::S_STRIDE];
        core.sample_prepared(positions_xz[2 * i], positions_xz[2 * i + 1], out);
    }

    // B. individual prepared queries.
    for (int count : counts) {
        double times[5];
        for (int rep = 0; rep < 5; ++rep) {
            auto t0 = clock::now();
            for (int i = 0; i < count; ++i) {
                double out[oq::S_STRIDE];
                core.sample_prepared(positions_xz[2 * i], positions_xz[2 * i + 1], out);
            }
            times[rep] = ms(clock::now() - t0);
        }
        // Mediana (sort simple).
        for (int a = 0; a < 4; ++a)
            for (int b = a + 1; b < 5; ++b)
                if (times[b] < times[a]) { double t = times[a]; times[a] = times[b]; times[b] = t; }
        std::printf("CORE_BENCH individual %d %.4f\n", count, times[2]);
    }

    // C. DIRECT_SCALAR batch de referencia (conserva el bucle por punto).
    for (int count : counts) {
        std::vector<double> out(static_cast<size_t>(count) * oq::S_STRIDE);
        double times[7];
        for (int rep = 0; rep < 7; ++rep) {
            auto t0 = clock::now();
            core.sample_batch_prepared(positions_xz.data(), count, out.data());
            times[rep] = ms(clock::now() - t0);
        }
        for (int a = 0; a < 6; ++a)
            for (int b = a + 1; b < 7; ++b)
                if (times[b] < times[a]) { double t = times[a]; times[a] = times[b]; times[b] = t; }
        std::printf("TRUE_BATCH_BENCH direct_scalar %d %.4f\n", count, times[3]);
    }

    // D. TRUE_BATCH_COLD: loop mode-major colectivo, siete repeticiones.
    for (int count : counts) {
        std::vector<double> out(static_cast<size_t>(count) * oq::S_STRIDE);
        double times[7];
        for (int rep = 0; rep < 7; ++rep) {
            auto t0 = clock::now();
            core.sample_batch_true_prepared(positions_xz.data(), count, out.data());
            times[rep] = ms(clock::now() - t0);
        }
        std::sort(times, times + 7);
        std::printf("TRUE_BATCH_BENCH true_batch_cold %d %.4f evals %zu hist %d/%d/%d/%d/%d\n",
                    count, times[3], core.diag_last_spectral_point_evaluations,
                    core.diag_last_newton_histogram[0], core.diag_last_newton_histogram[1],
                    core.diag_last_newton_histogram[2], core.diag_last_newton_histogram[3],
                    core.diag_last_newton_histogram[4]);
    }

    // E. TRUE_BATCH_WARM temporal: casco sintético 3.1 x 1.2 m, 600 ticks
    // a 60 Hz. El predictor es q_prev + (world_t - world_prev).
    {
        const int racer_counts[] = {1, 4, 8};
        for (const int racer_count : racer_counts) {
        const int point_count = 16 * racer_count;
        std::vector<double> world(static_cast<size_t>(point_count) * 2);
        std::vector<double> previous_world(static_cast<size_t>(point_count) * 2);
        std::vector<double> previous_q(static_cast<size_t>(point_count) * 2,
                                       std::numeric_limits<double>::quiet_NaN());
        std::vector<double> out(static_cast<size_t>(point_count) * oq::TRUE_BATCH_WARM_STRIDE);
        std::vector<double> ticks;
        ticks.reserve(600);
        size_t total_evals = 0;
        int hist[5] = {0, 0, 0, 0, 0};
        for (int tick = 0; tick < 600; ++tick) {
            const double t = double(tick) / 60.0;
            const double yaw = 0.012 * tick + 0.00012 * tick * tick;
            const double fx = std::sin(yaw), fz = std::cos(yaw);
            const double rx = fz, rz = -fx;
            for (int p = 0; p < point_count; ++p) {
                const int local = p % 16;
                const int racer = p / 16;
                const double u = -1.55 + 3.10 * double(local % 4) / 3.0;
                const double v = -0.60 + 1.20 * double(local / 4) / 3.0;
                const double racer_yaw = yaw + 0.13 * racer;
                const double racer_fx = std::sin(racer_yaw), racer_fz = std::cos(racer_yaw);
                const double racer_rx = racer_fz, racer_rz = -racer_fx;
                const size_t o = static_cast<size_t>(p) * 2;
                world[o] = -8.0 + 0.13 * tick + 7.0 * racer + racer_rx * u + racer_fx * v;
                world[o + 1] = 3.0 + 0.04 * tick - 5.0 * racer + racer_rz * u + racer_fz * v;
                if (tick > 0) {
                    previous_q[o] += world[o] - previous_world[o];
                    previous_q[o + 1] += world[o + 1] - previous_world[o + 1];
                }
            }
            core.ensure_prepared(t);
            const auto start = clock::now();
            core.sample_batch_warm_prepared(world.data(), previous_q.data(), point_count, out.data());
            ticks.push_back(ms(clock::now() - start));
            total_evals += core.diag_last_spectral_point_evaluations;
            for (int h = 0; h < 5; ++h) hist[h] += core.diag_last_newton_histogram[h];
            for (int p = 0; p < point_count; ++p) {
                const size_t o = static_cast<size_t>(p) * oq::TRUE_BATCH_WARM_STRIDE;
                previous_q[static_cast<size_t>(p) * 2] = out[o + oq::S_STRIDE];
                previous_q[static_cast<size_t>(p) * 2 + 1] = out[o + oq::S_STRIDE + 1];
                previous_world[static_cast<size_t>(p) * 2] = world[static_cast<size_t>(p) * 2];
                previous_world[static_cast<size_t>(p) * 2 + 1] = world[static_cast<size_t>(p) * 2 + 1];
            }
        }
        std::sort(ticks.begin(), ticks.end());
        std::printf("TRUE_BATCH_BENCH warm_temporal_%dx16 median %.4f p95 %.4f evals_per_tick %.2f hist %d/%d/%d/%d/%d\n",
                    racer_count, ticks[ticks.size() / 2], ticks[static_cast<size_t>(ticks.size() * 0.95)],
                    double(total_evals) / 600.0, hist[0], hist[1], hist[2], hist[3], hist[4]);
        }
    }

    // F. dump de resultados para comparaciÃ³n de exactitud (16 posiciones, t=3.5).
    {
        std::ofstream out(argv[2]);
        std::vector<double> buf(static_cast<size_t>(16) * oq::S_STRIDE);
        core.sample_batch_prepared(positions_xz.data(), 16, buf.data());
        for (size_t i = 0; i < 16; ++i) {
            for (int k = 0; k < oq::S_STRIDE; ++k) {
                if (k) out << ' ';
                out << std::scientific << buf[i * oq::S_STRIDE + k];
            }
            out << '\n';
        }
    }
    std::printf("CORE_BENCH diag_non_converged %d\n", core.diag_non_converged);
    return 0;
}


