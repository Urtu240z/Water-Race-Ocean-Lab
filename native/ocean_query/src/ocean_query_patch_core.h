// OceanQueryPatchCore — Fase 2C.1A (prototipo).
// Patch LOCAL world-aligned alrededor de un centro: evalúa TODAS las
// contribuciones REDUCED (misma matemática que OceanQueryCore::accumulate_)
// en una rejilla por cascada usando recurrencia de fase (sin un sin/cos por
// modo×nodo), y resuelve queries world-space con Newton sobre campos
// interpolados bilinealmente.
//
// RESTRICCIONES de la fase: double (no float32), std::cos/std::sin normales,
// sin AVX/SIMD manual, sin fast-math, sin LUT, sin multithreading.
// El core DIRECT (OceanQueryCore) queda INTACTO como referencia y fallback:
// si Newton del patch sale de la región interpolable, el llamador usa DIRECT.
//
// Código C++ portable (nada Win32): la futura build Linux/Steam Deck podrá
// usar exactamente este mismo archivo.

#pragma once

#include "ocean_query_core.h"

#include <vector>

namespace oq_patch {

// Los 12 campos por nodo (mismo orden que OceanQueryCore::accumulate_).
enum PatchField {
    PF_H = 0,    // altura H(q)
    PF_DX,       // desplazamiento horizontal X
    PF_DZ,       // desplazamiento horizontal Z
    PF_DHX,      // dH/dx
    PF_DHZ,      // dH/dz
    PF_DXX,      // dDx/dx
    PF_DXZ,      // dDx/dz
    PF_DZX,      // dDz/dx
    PF_DZZ,      // dDz/dz
    PF_VH,       // velocidad vertical
    PF_VX,       // velocidad horizontal X
    PF_VZ,       // velocidad horizontal Z
    PF_COUNT = 12
};

struct GridSpec {
    double spacing = 0.0; // metros entre nodos
    int nx = 0;           // nodos en X (impar recomendado)
    int nz = 0;           // nodos en Z (impar recomendado)
    bool valid() const { return spacing > 0.0 && nx >= 2 && nz >= 2; }
};

// Una rejilla construida para una cascada.
struct GridData {
    GridSpec spec;
    double x0 = 0.0, z0 = 0.0; // esquina inferior-izquierda (world)
    // 12 campos por nodo, layout node-major (nodo i → fields[12*i .. 12*i+11]).
    std::vector<double> fields;
    // Pasos de fase por modo, precomputados cuando el spacing/config no cambia:
    // step_x = exp(i*kx*spacing), step_z = exp(i*ky*spacing).
    std::vector<double> step_x_re, step_x_im;
    std::vector<double> step_z_re, step_z_im;
};

class OceanQueryPatchCore {
public:
    // Espectro compacto + ev_h/ev_v preparados: reutiliza el core DIRECT
    // (misma matemática, mismo ensure_prepared). El patch SÓLO añade la
    // evaluación en rejilla y la interpolación.
    oq::OceanQueryCore core;

    // Specs por índice de cascada (0=LONG, 1=MID, 2=SHORT).
    std::vector<GridSpec> specs;
    // Grids construidos (uno por cascada con spec válida).
    std::vector<GridData> grids;

    // Diag / contadores.
    long long patch_build_count = 0;
    long long patch_fallback_count = 0;      // query pidió q fuera del patch
    long long patch_non_converged_count = 0; // dentro del patch, Newton sin converger
    long long patch_direct_invalid_count = 0;

    void clear();
    void set_grid_spec(int cascade_index, double spacing, int nx, int nz);

    // Construye (o reconstruye) los grids centrados en (cx, cz). Devuelve
    // bytes totales de campos + pasos de fase.
    size_t build_patch(double cx, double cz);

    // Query world-space usando SÓLO interpolación del patch.
    //  out: buffer S_STRIDE (mismo contrato que el core DIRECT).
    //  return: 1 = válido (dentro del patch, Newton convergido)
    //          0 = fuera del patch en alguna evaluación → llamador usa DIRECT
    //         -1 = dentro pero Newton no convergió (out relleno, valid=0)
    int sample_patch_prepared(double wx, double wz, double *out);

private:
    void build_grid_(size_t gi, double cx, double cz);
    // Evalúa los 12 campos en q interpolando los tres grids. Si q cae fuera
    // de cualquier grid, inside=false y out no se toca.
    void evaluate_fields_(double qx, double qz, double out_fields[PF_COUNT], bool &inside);
};

} // namespace oq_patch
