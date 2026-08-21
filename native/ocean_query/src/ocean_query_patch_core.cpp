// OceanQueryPatchCore — Fase 2C.1A (prototipo). Implementación.

#include "ocean_query_patch_core.h"

#include <cmath>
#include <cstring>

namespace oq_patch {

void OceanQueryPatchCore::clear() {
    core.clear();
    specs.clear();
    grids.clear();
}

void OceanQueryPatchCore::set_grid_spec(int cascade_index, double spacing, int nx, int nz) {
    if (cascade_index >= static_cast<int>(specs.size())) {
        specs.resize(cascade_index + 1);
        grids.resize(cascade_index + 1);
    }
    GridSpec &spec = specs[cascade_index];
    spec.spacing = spacing;
    spec.nx = nx;
    spec.nz = nz;
    // Los pasos de fase dependen del spacing y de kx/ky de la cascada;
    // se (re)calculan aquí cuando el spacing/config cambia.
    GridData &g = grids[cascade_index];
    g.spec = spec;
    if (cascade_index < static_cast<int>(core.cascades.size())) {
        const oq::Cascade &c = core.cascades[cascade_index];
        const size_t count = c.kx.size();
        g.step_x_re.resize(count);
        g.step_x_im.resize(count);
        g.step_z_re.resize(count);
        g.step_z_im.resize(count);
        for (size_t idx = 0; idx < count; ++idx) {
            const double ax = c.kx[idx] * spacing;
            const double az = c.ky[idx] * spacing;
            g.step_x_re[idx] = std::cos(ax);
            g.step_x_im[idx] = std::sin(ax);
            g.step_z_re[idx] = std::cos(az);
            g.step_z_im[idx] = std::sin(az);
        }
    }
}

size_t OceanQueryPatchCore::build_patch(double cx, double cz) {
    if (specs.empty()) {
        return 0;
    }
    const size_t n_grids = specs.size();
    grids.resize(n_grids);
    for (size_t gi = 0; gi < n_grids; ++gi) {
        if (specs[gi].valid() && gi < core.cascades.size()) {
            build_grid_(gi, cx, cz);
        }
    }
    patch_build_count += 1;
    size_t bytes = 0;
    for (const GridData &g : grids) {
        bytes += g.fields.size() * sizeof(double);
        bytes += (g.step_x_re.size() + g.step_x_im.size() + g.step_z_re.size() + g.step_z_im.size()) * sizeof(double);
    }
    return bytes;
}

// Construye la rejilla de la cascada gi con recurrencia de fase:
//   phase(x0 + ix*dx, z0 + iz*dz) = exp(i*(kx*(x0+ix*dx) + ky*(z0+iz*dz)))
//   avanzando con step_x = exp(i*kx*dx) y step_z = exp(i*ky*dz).
// Cada nodo acumula EXACTAMENTE las mismas contribuciones que accumulate_()
// (mismos kx, ky, omega, a1/a2, c11..c22, parity, weight, inv_n2, ev_h/ev_v).
void OceanQueryPatchCore::build_grid_(size_t gi, double cx, double cz) {
    const GridSpec &spec = specs[gi];
    const oq::Cascade &c = core.cascades[gi];
    GridData &g = grids[gi];
    const int nx = spec.nx;
    const int nz = spec.nz;
    const double dx = spec.spacing;
    const double dz = spec.spacing;
    // Patch world-aligned centrado en (cx, cz): la esquina es el centro menos
    // la mitad de la extensión. No se rota con el jetski.
    g.x0 = cx - 0.5 * (nx - 1) * dx;
    g.z0 = cz - 0.5 * (nz - 1) * dz;
    g.fields.assign(static_cast<size_t>(PF_COUNT) * static_cast<size_t>(nx) * static_cast<size_t>(nz), 0.0);
    double *fields = g.fields.data();

    const size_t count = c.kx.size();
    const double inv_n2 = c.inv_n2;
    const double *kx = c.kx.data();
    const double *ky = c.ky.data();
    const double *a1 = c.a1.data();
    const double *a2 = c.a2.data();
    const double *c11 = c.c11.data();
    const double *c12 = c.c12.data();
    const double *c21 = c.c21.data();
    const double *c22 = c.c22.data();
    const double *parity = c.parity.data();
    const double *weight = c.weight.data();
    const double *ev_h_re = c.ev_h_re.data();
    const double *ev_h_im = c.ev_h_im.data();
    const double *ev_v_re = c.ev_v_re.data();
    const double *ev_v_im = c.ev_v_im.data();

    const size_t row_stride = static_cast<size_t>(PF_COUNT) * static_cast<size_t>(nx);

    for (size_t idx = 0; idx < count; ++idx) {
        const double sig = parity[idx] * weight[idx];
        const double h_re = ev_h_re[idx];
        const double h_im = ev_h_im[idx];
        const double v_re = ev_v_re[idx];
        const double v_im = ev_v_im[idx];
        // Fase en el origen de la rejilla (esquina inferior-izquierda).
        const double phi0 = kx[idx] * g.x0 + ky[idx] * g.z0;
        double z_re = std::cos(phi0);
        double z_im = std::sin(phi0);
        const double sx_re = g.step_x_re[idx];
        const double sx_im = g.step_x_im[idx];
        const double sz_re = g.step_z_re[idx];
        const double sz_im = g.step_z_im[idx];

        for (int iz = 0; iz < nz; ++iz) {
            double x_re = z_re;
            double x_im = z_im;
            double *row = fields + static_cast<size_t>(iz) * row_stride;
            for (int ix = 0; ix < nx; ++ix) {
                const double cp = x_re;
                const double sp = x_im;
                const double p_re = h_re * cp - h_im * sp;
                const double p_im = h_re * sp + h_im * cp;
                const double q_re = v_re * cp - v_im * sp;
                const double q_im = v_re * sp + v_im * cp;
                double *f = row + static_cast<size_t>(ix) * PF_COUNT;
                f[PF_H] += sig * p_re;
                f[PF_DX] += sig * a1[idx] * p_im;
                f[PF_DZ] += sig * a2[idx] * p_im;
                f[PF_DHX] += sig * -kx[idx] * p_im;
                f[PF_DHZ] += sig * -ky[idx] * p_im;
                f[PF_DXX] += sig * c11[idx] * p_re;
                f[PF_DXZ] += sig * c12[idx] * p_re;
                f[PF_DZX] += sig * c21[idx] * p_re;
                f[PF_DZZ] += sig * c22[idx] * p_re;
                f[PF_VH] += sig * q_re;
                f[PF_VX] += sig * a1[idx] * q_im;
                f[PF_VZ] += sig * a2[idx] * q_im;
                // Avance de fase en X: phase(x+dx) = phase(x) * step_x.
                const double n_re = x_re * sx_re - x_im * sx_im;
                x_im = x_re * sx_im + x_im * sx_re;
                x_re = n_re;
            }
            // Avance de fase en Z entre filas.
            const double n_re = z_re * sz_re - z_im * sz_im;
            z_im = z_re * sz_im + z_im * sz_re;
            z_re = n_re;
        }
    }

    // Escala por inv_n2 (igual que accumulate_: suma por cascada y luego 1/N²).
    const size_t total = static_cast<size_t>(PF_COUNT) * static_cast<size_t>(nx) * static_cast<size_t>(nz);
    for (size_t i = 0; i < total; ++i) {
        fields[i] *= inv_n2;
    }
}

// Interpolación bilineal directa de los 12 campos, sumando los tres grids.
void OceanQueryPatchCore::evaluate_fields_(double qx, double qz, double out_fields[PF_COUNT], bool &inside) {
    double acc[PF_COUNT] = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0};
    inside = true;
    for (const GridData &g : grids) {
        if (!g.spec.valid()) {
            continue;
        }
        const int nx = g.spec.nx;
        const int nz = g.spec.nz;
        const double dx = g.spec.spacing;
        const double u = (qx - g.x0) / dx;
        const double v = (qz - g.z0) / dx;
        const int ix = static_cast<int>(std::floor(u));
        const int iz = static_cast<int>(std::floor(v));
        // Bilinear requiere el nodo (ix+1, iz+1) existente.
        if (ix < 0 || iz < 0 || ix >= nx - 1 || iz >= nz - 1) {
            inside = false;
            return;
        }
        const double fu = u - static_cast<double>(ix);
        const double fv = v - static_cast<double>(iz);
        const double w00 = (1.0 - fu) * (1.0 - fv);
        const double w10 = fu * (1.0 - fv);
        const double w01 = (1.0 - fu) * fv;
        const double w11 = fu * fv;
        const double *f00 = g.fields.data() + (static_cast<size_t>(iz) * nx + static_cast<size_t>(ix)) * PF_COUNT;
        const double *f10 = f00 + PF_COUNT;
        const double *f01 = f00 + static_cast<size_t>(nx) * PF_COUNT;
        const double *f11 = f01 + PF_COUNT;
        for (int k = 0; k < PF_COUNT; ++k) {
            acc[k] += w00 * f00[k] + w10 * f10[k] + w01 * f01[k] + w11 * f11[k];
        }
    }
    for (int k = 0; k < PF_COUNT; ++k) {
        out_fields[k] = acc[k];
    }
}

int OceanQueryPatchCore::sample_patch_prepared(double wx, double wz, double *out) {
    double qx = wx, qz = wz;
    double fields[PF_COUNT];
    bool inside = true;
    evaluate_fields_(qx, qz, fields, inside);
    if (!inside) {
        patch_fallback_count += 1;
        return 0;
    }
    double h = fields[PF_H];
    double dx_ = fields[PF_DX];
    double dz_ = fields[PF_DZ];
    double dhx = fields[PF_DHX];
    double dhz = fields[PF_DHZ];
    double dxx = fields[PF_DXX];
    double dxz = fields[PF_DXZ];
    double dzx = fields[PF_DZX];
    double dzz = fields[PF_DZZ];
    double vh = fields[PF_VH];
    double vx = fields[PF_VX];
    double vz = fields[PF_VZ];

    double fx = qx + dx_ - wx;
    double fz = qz + dz_ - wz;
    double residual = std::sqrt(fx * fx + fz * fz);
    int iterations = 0;
    bool converged = residual <= oq::POSITION_TOLERANCE_M;
    while (!converged && iterations < oq::MAX_ITERATIONS) {
        const double det_j = (1.0 + dxx) * (1.0 + dzz) - dxz * dzx;
        if (std::abs(det_j) <= oq::JACOBIAN_EPSILON) {
            break;
        }
        const double inv_det = 1.0 / det_j;
        const double delta_x = inv_det * ((1.0 + dzz) * fx - dxz * fz);
        const double delta_z = inv_det * (-dzx * fx + (1.0 + dxx) * fz);
        qx -= delta_x;
        qz -= delta_z;
        evaluate_fields_(qx, qz, fields, inside);
        if (!inside) {
            patch_fallback_count += 1;
            return 0;
        }
        // Los campos usados para el sample final son los del último q evaluado
        // (igual que accumulate_ por referencia en el core DIRECT).
        h = fields[PF_H];
        dx_ = fields[PF_DX];
        dz_ = fields[PF_DZ];
        dhx = fields[PF_DHX];
        dhz = fields[PF_DHZ];
        dxx = fields[PF_DXX];
        dxz = fields[PF_DXZ];
        dzx = fields[PF_DZX];
        dzz = fields[PF_DZZ];
        vh = fields[PF_VH];
        vx = fields[PF_VX];
        vz = fields[PF_VZ];
        fx = qx + dx_ - wx;
        fz = qz + dz_ - wz;
        residual = std::sqrt(fx * fx + fz * fz);
        iterations += 1;
        converged = residual <= oq::POSITION_TOLERANCE_M;
    }
    if (!converged) {
        patch_non_converged_count += 1;
    }

    // Construcción del sample (mismo orden que el core DIRECT).
    const double disp[3] = {dx_, h, dz_};
    const double tangent_x[3] = {1.0 + dxx, dhx, dzx};
    const double tangent_z[3] = {dxz, dhz, 1.0 + dzz};
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

    out[oq::S_VALID] = converged ? 1.0 : 0.0;
    out[oq::S_HEIGHT] = core.sea_level + h;
    out[oq::S_DX] = disp[0];
    out[oq::S_DY] = disp[1];
    out[oq::S_DZ] = disp[2];
    out[oq::S_NX] = normal[0];
    out[oq::S_NY] = normal[1];
    out[oq::S_NZ] = normal[2];
    out[oq::S_VX] = vx;
    out[oq::S_VY] = vh;
    out[oq::S_VZ] = vz;
    out[oq::S_JACOBIAN_DET] = det_j;
    out[oq::S_FOLDOVER] = det_j <= 0.0 ? 1.0 : 0.0;
    out[oq::S_RESIDUAL] = residual;
    out[oq::S_ITERATIONS] = static_cast<double>(iterations);
    return 1;
}

} // namespace oq_patch
