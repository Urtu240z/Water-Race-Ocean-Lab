// Translation unit AVX2 exclusivamente. SConstruct la compila con /arch:AVX2;
// no la llama el core hasta que CPUID + OSXSAVE + XGETBV confirman soporte.

#include "ocean_query_core.h"
#include "ocean_query_simd_avx2.h"

#include <immintrin.h>

#include <cmath>

namespace oq {
namespace {

inline __m256d set4(const double *v) { return _mm256_loadu_pd(v); }

inline void store_points(std::vector<double> &dst, size_t p0, size_t p1, size_t p2, size_t p3, __m256d value) {
    alignas(32) double lanes[4];
    _mm256_store_pd(lanes, value);
    dst[p0] = lanes[0]; dst[p1] = lanes[1]; dst[p2] = lanes[2]; dst[p3] = lanes[3];
}

inline __m256d sin_poly(__m256d x) {
    const __m256d z = _mm256_mul_pd(x, x);
    __m256d p = _mm256_set1_pd(1.6059043836821613e-10);       // +1/6227020800
    p = _mm256_add_pd(_mm256_set1_pd(-2.505210838544172e-8), _mm256_mul_pd(z, p));
    p = _mm256_add_pd(_mm256_set1_pd(2.7557319223985893e-6), _mm256_mul_pd(z, p));
    p = _mm256_add_pd(_mm256_set1_pd(-1.9841269841269841e-4), _mm256_mul_pd(z, p));
    p = _mm256_add_pd(_mm256_set1_pd(8.3333333333333332e-3), _mm256_mul_pd(z, p));
    p = _mm256_add_pd(_mm256_set1_pd(-1.6666666666666666e-1), _mm256_mul_pd(z, p));
    return _mm256_add_pd(x, _mm256_mul_pd(_mm256_mul_pd(x, z), p));
}

inline __m256d cos_poly(__m256d x) {
    const __m256d z = _mm256_mul_pd(x, x);
    __m256d p = _mm256_set1_pd(-1.1470745597729725e-11);      // -1/87178291200
    p = _mm256_add_pd(_mm256_set1_pd(2.08767569878681e-9), _mm256_mul_pd(z, p));
    p = _mm256_add_pd(_mm256_set1_pd(-2.755731922398589e-7), _mm256_mul_pd(z, p));
    p = _mm256_add_pd(_mm256_set1_pd(2.48015873015873e-5), _mm256_mul_pd(z, p));
    p = _mm256_add_pd(_mm256_set1_pd(-1.388888888888889e-3), _mm256_mul_pd(z, p));
    p = _mm256_add_pd(_mm256_set1_pd(4.1666666666666664e-2), _mm256_mul_pd(z, p));
    p = _mm256_add_pd(_mm256_set1_pd(-0.5), _mm256_mul_pd(z, p));
    return _mm256_add_pd(_mm256_set1_pd(1.0), _mm256_mul_pd(z, p));
}

inline void sincos_vector(__m256d phi, __m256d &s, __m256d &c) {
    // Payne-Hanek no es necesario para el rango real del laboratorio
    // (|phi| << 1e6); split pi/2 mantiene el error de reducción bajo ese
    // límite. Fuera de él se usa la ruta scalar por lane en el llamador.
    const __m256d q = _mm256_round_pd(_mm256_mul_pd(phi, _mm256_set1_pd(0.63661977236758134308)),
                                      _MM_FROUND_TO_NEAREST_INT | _MM_FROUND_NO_EXC);
    __m256d r = _mm256_sub_pd(phi, _mm256_mul_pd(q, _mm256_set1_pd(1.57079632679489655800)));
    r = _mm256_sub_pd(r, _mm256_mul_pd(q, _mm256_set1_pd(6.12323399573676603587e-17)));
    const __m256d sr = sin_poly(r);
    const __m256d cr = cos_poly(r);
    const __m256d q4 = _mm256_sub_pd(q, _mm256_mul_pd(_mm256_floor_pd(_mm256_mul_pd(q, _mm256_set1_pd(0.25))), _mm256_set1_pd(4.0)));
    const __m256d m1 = _mm256_cmp_pd(q4, _mm256_set1_pd(1.0), _CMP_EQ_OQ);
    const __m256d m2 = _mm256_cmp_pd(q4, _mm256_set1_pd(2.0), _CMP_EQ_OQ);
    const __m256d m3 = _mm256_cmp_pd(q4, _mm256_set1_pd(3.0), _CMP_EQ_OQ);
    s = _mm256_blendv_pd(sr, cr, m1);
    s = _mm256_blendv_pd(s, _mm256_sub_pd(_mm256_setzero_pd(), sr), m2);
    s = _mm256_blendv_pd(s, _mm256_sub_pd(_mm256_setzero_pd(), cr), m3);
    c = _mm256_blendv_pd(cr, _mm256_sub_pd(_mm256_setzero_pd(), sr), m1);
    c = _mm256_blendv_pd(c, _mm256_sub_pd(_mm256_setzero_pd(), cr), m2);
    c = _mm256_blendv_pd(c, sr, m3);
}

inline void sincos_lanes(__m256d phi, __m256d &s, __m256d &c) {
    alignas(32) double in[4], so[4], co[4];
    _mm256_store_pd(in, phi);
    for (int lane = 0; lane < 4; ++lane) { so[lane] = std::sin(in[lane]); co[lane] = std::cos(in[lane]); }
    s = set4(so); c = set4(co);
}

inline void sincos_safe(__m256d phi, __m256d &s, __m256d &c) {
    // La reducción vectorial está medida para el rango del océano; para
    // coordenadas extremas se mantiene corrección total por lane en vez de
    // degradar silenciosamente la fase con una reducción imprecisa.
    const __m256d sign = _mm256_set1_pd(-0.0);
    const __m256d abs_phi = _mm256_andnot_pd(sign, phi);
    const int large_lane = _mm256_movemask_pd(_mm256_cmp_pd(abs_phi, _mm256_set1_pd(1048576.0), _CMP_GT_OQ));
    if (large_lane != 0) { sincos_lanes(phi, s, c); }
    else { sincos_vector(phi, s, c); }
}

inline void scalar_tail(const Cascade &c, BatchWorkspace &batch, size_t p) {
    double h = 0.0, dx = 0.0, dz = 0.0, dhx = 0.0, dhz = 0.0;
    double dxx = 0.0, dxz = 0.0, dzx = 0.0, dzz = 0.0, vh = 0.0, vx = 0.0, vz = 0.0;
    for (size_t idx = 0; idx < c.kx.size(); ++idx) {
        const double phi = c.kx[idx] * batch.qx[p] + c.ky[idx] * batch.qz[p];
        const double cp = std::cos(phi), sp = std::sin(phi);
        const double pre = c.ev_h_re[idx] * cp - c.ev_h_im[idx] * sp;
        const double pim = c.ev_h_re[idx] * sp + c.ev_h_im[idx] * cp;
        const double qre = c.ev_v_re[idx] * cp - c.ev_v_im[idx] * sp;
        const double qim = c.ev_v_re[idx] * sp + c.ev_v_im[idx] * cp;
        const double sig = c.parity[idx] * c.weight[idx];
        h += sig * pre; dx += sig * c.a1[idx] * pim; dz += sig * c.a2[idx] * pim;
        dhx += sig * -c.kx[idx] * pim; dhz += sig * -c.ky[idx] * pim;
        dxx += sig * c.c11[idx] * pre; dxz += sig * c.c12[idx] * pre;
        dzx += sig * c.c21[idx] * pre; dzz += sig * c.c22[idx] * pre;
        vh += sig * qre; vx += sig * c.a1[idx] * qim; vz += sig * c.a2[idx] * qim;
    }
    batch.cascade_h[p] = h; batch.cascade_dx[p] = dx; batch.cascade_dz[p] = dz;
    batch.cascade_dhx[p] = dhx; batch.cascade_dhz[p] = dhz;
    batch.cascade_dxx[p] = dxx; batch.cascade_dxz[p] = dxz; batch.cascade_dzx[p] = dzx; batch.cascade_dzz[p] = dzz;
    batch.cascade_vh[p] = vh; batch.cascade_vx[p] = vx; batch.cascade_vz[p] = vz;
}

} // namespace

void sincos_pd_avx2(const double *phi4, double *sin4, double *cos4) {
    const __m256d phi = set4(phi4);
    __m256d s, c;
    sincos_safe(phi, s, c);
    _mm256_storeu_pd(sin4, s);
    _mm256_storeu_pd(cos4, c);
}

void evaluate_batch_avx2(const std::vector<Cascade> &cascades, BatchWorkspace &batch,
                         const size_t *indices, size_t active_count, bool vector_sincos) {
    const __m256d zero = _mm256_setzero_pd();
    for (const Cascade &cascade : cascades) {
        size_t ai = 0;
        for (; ai + 4 <= active_count; ai += 4) {
            const size_t p0 = indices[ai], p1 = indices[ai + 1], p2 = indices[ai + 2], p3 = indices[ai + 3];
            const __m256i gather = _mm256_set_epi64x(static_cast<long long>(p3), static_cast<long long>(p2),
                                                       static_cast<long long>(p1), static_cast<long long>(p0));
            const __m256d qx = _mm256_i64gather_pd(batch.qx.data(), gather, 8);
            const __m256d qz = _mm256_i64gather_pd(batch.qz.data(), gather, 8);
            __m256d h = zero, dx = zero, dz = zero, dhx = zero, dhz = zero;
            __m256d dxx = zero, dxz = zero, dzx = zero, dzz = zero, vh = zero, vx = zero, vz = zero;
            for (size_t idx = 0; idx < cascade.kx.size(); ++idx) {
                const __m256d phi = _mm256_add_pd(_mm256_mul_pd(_mm256_set1_pd(cascade.kx[idx]), qx),
                                                   _mm256_mul_pd(_mm256_set1_pd(cascade.ky[idx]), qz));
                __m256d sp, cp;
                if (vector_sincos) { sincos_safe(phi, sp, cp); } else { sincos_lanes(phi, sp, cp); }
                const __m256d h_re = _mm256_set1_pd(cascade.ev_h_re[idx]);
                const __m256d h_im = _mm256_set1_pd(cascade.ev_h_im[idx]);
                const __m256d v_re = _mm256_set1_pd(cascade.ev_v_re[idx]);
                const __m256d v_im = _mm256_set1_pd(cascade.ev_v_im[idx]);
                const __m256d pre = _mm256_sub_pd(_mm256_mul_pd(h_re, cp), _mm256_mul_pd(h_im, sp));
                const __m256d pim = _mm256_add_pd(_mm256_mul_pd(h_re, sp), _mm256_mul_pd(h_im, cp));
                const __m256d qre = _mm256_sub_pd(_mm256_mul_pd(v_re, cp), _mm256_mul_pd(v_im, sp));
                const __m256d qim = _mm256_add_pd(_mm256_mul_pd(v_re, sp), _mm256_mul_pd(v_im, cp));
                const __m256d sig = _mm256_set1_pd(cascade.parity[idx] * cascade.weight[idx]);
                h = _mm256_add_pd(h, _mm256_mul_pd(sig, pre));
                dx = _mm256_add_pd(dx, _mm256_mul_pd(sig, _mm256_mul_pd(_mm256_set1_pd(cascade.a1[idx]), pim)));
                dz = _mm256_add_pd(dz, _mm256_mul_pd(sig, _mm256_mul_pd(_mm256_set1_pd(cascade.a2[idx]), pim)));
                dhx = _mm256_add_pd(dhx, _mm256_mul_pd(sig, _mm256_mul_pd(_mm256_set1_pd(-cascade.kx[idx]), pim)));
                dhz = _mm256_add_pd(dhz, _mm256_mul_pd(sig, _mm256_mul_pd(_mm256_set1_pd(-cascade.ky[idx]), pim)));
                dxx = _mm256_add_pd(dxx, _mm256_mul_pd(sig, _mm256_mul_pd(_mm256_set1_pd(cascade.c11[idx]), pre)));
                dxz = _mm256_add_pd(dxz, _mm256_mul_pd(sig, _mm256_mul_pd(_mm256_set1_pd(cascade.c12[idx]), pre)));
                dzx = _mm256_add_pd(dzx, _mm256_mul_pd(sig, _mm256_mul_pd(_mm256_set1_pd(cascade.c21[idx]), pre)));
                dzz = _mm256_add_pd(dzz, _mm256_mul_pd(sig, _mm256_mul_pd(_mm256_set1_pd(cascade.c22[idx]), pre)));
                vh = _mm256_add_pd(vh, _mm256_mul_pd(sig, qre));
                vx = _mm256_add_pd(vx, _mm256_mul_pd(sig, _mm256_mul_pd(_mm256_set1_pd(cascade.a1[idx]), qim)));
                vz = _mm256_add_pd(vz, _mm256_mul_pd(sig, _mm256_mul_pd(_mm256_set1_pd(cascade.a2[idx]), qim)));
            }
            store_points(batch.cascade_h, p0,p1,p2,p3,h); store_points(batch.cascade_dx,p0,p1,p2,p3,dx); store_points(batch.cascade_dz,p0,p1,p2,p3,dz);
            store_points(batch.cascade_dhx,p0,p1,p2,p3,dhx); store_points(batch.cascade_dhz,p0,p1,p2,p3,dhz);
            store_points(batch.cascade_dxx,p0,p1,p2,p3,dxx); store_points(batch.cascade_dxz,p0,p1,p2,p3,dxz);
            store_points(batch.cascade_dzx,p0,p1,p2,p3,dzx); store_points(batch.cascade_dzz,p0,p1,p2,p3,dzz);
            store_points(batch.cascade_vh,p0,p1,p2,p3,vh); store_points(batch.cascade_vx,p0,p1,p2,p3,vx); store_points(batch.cascade_vz,p0,p1,p2,p3,vz);
        }
        for (; ai < active_count; ++ai) { scalar_tail(cascade, batch, indices[ai]); }
        for (size_t j = 0; j < active_count; ++j) {
            const size_t p = indices[j]; const double inv = cascade.inv_n2;
            batch.h[p] += batch.cascade_h[p] * inv; batch.dx[p] += batch.cascade_dx[p] * inv; batch.dz[p] += batch.cascade_dz[p] * inv;
            batch.dhx[p] += batch.cascade_dhx[p] * inv; batch.dhz[p] += batch.cascade_dhz[p] * inv;
            batch.dxx[p] += batch.cascade_dxx[p] * inv; batch.dxz[p] += batch.cascade_dxz[p] * inv;
            batch.dzx[p] += batch.cascade_dzx[p] * inv; batch.dzz[p] += batch.cascade_dzz[p] * inv;
            batch.vh[p] += batch.cascade_vh[p] * inv; batch.vx[p] += batch.cascade_vx[p] * inv; batch.vz[p] += batch.cascade_vz[p] * inv;
        }
    }
}

} // namespace oq
