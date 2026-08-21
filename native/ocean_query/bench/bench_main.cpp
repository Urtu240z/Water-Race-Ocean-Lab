// bench_main.cpp â€” benchmark standalone del core C++ (Fase 2C).
// Lee datos compactos generados por dump_data.gd y mide prepare + queries.
// Uso: bench_main.exe <data_file> <out_file>

#include "../src/ocean_query_core.h"

#include <chrono>
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

    // C. batch prepared.
    for (int count : counts) {
        std::vector<double> out(static_cast<size_t>(count) * oq::S_STRIDE);
        double times[5];
        for (int rep = 0; rep < 5; ++rep) {
            auto t0 = clock::now();
            core.sample_batch_prepared(positions_xz.data(), count, out.data());
            times[rep] = ms(clock::now() - t0);
        }
        for (int a = 0; a < 4; ++a)
            for (int b = a + 1; b < 5; ++b)
                if (times[b] < times[a]) { double t = times[a]; times[a] = times[b]; times[b] = t; }
        std::printf("CORE_BENCH batch %d %.4f\n", count, times[2]);
    }

    // D. dump de resultados para comparaciÃ³n de exactitud (16 posiciones, t=3.5).
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


