// Deterministic offline generator for the Surface Foam RGBA8 tile.
// R = organic breakup/noise. G = bubble-distance-like field (0 exterior,
// 0.5 boundary, 1 interior). B/A are reserved for future channels.
// The tile uses periodic analytic coordinates, so no seam is introduced.
const fs = require('fs');
const zlib = require('zlib');

const W = 1024;
const H = 1024;
const TAU = Math.PI * 2;
const out = 'ocean_v3/rendering/surface_detail/surface_foam_micro_detail.png';

function hash(x, y, seed) {
  let n = (Math.imul(x, 374761393) + Math.imul(y, 668265263) + seed) | 0;
  n = Math.imul(n ^ (n >>> 13), 1274126177);
  return ((n ^ (n >>> 16)) >>> 0) / 4294967295;
}

function smooth(t) { return t * t * (3 - 2 * t); }

// Periodic value noise with a mild domain warp. All octaves wrap on the tile.
function periodicNoise(x, y, cells, seed) {
  const fx = x * cells;
  const fy = y * cells;
  const x0 = Math.floor(fx) % cells;
  const y0 = Math.floor(fy) % cells;
  const x1 = (x0 + 1) % cells;
  const y1 = (y0 + 1) % cells;
  const tx = smooth(fx - Math.floor(fx));
  const ty = smooth(fy - Math.floor(fy));
  const a = hash((x0 + cells) % cells, (y0 + cells) % cells, seed);
  const b = hash(x1, (y0 + cells) % cells, seed);
  const c = hash((x0 + cells) % cells, y1, seed);
  const d = hash(x1, y1, seed);
  return (a + (b - a) * tx) * (1 - ty) + (c + (d - c) * tx) * ty;
}

function noise(x, y, seed) {
  const wx = periodicNoise(x + periodicNoise(x, y, 3, seed + 7) * 0.08, y, 5, seed + 11);
  const wy = periodicNoise(x, y + periodicNoise(x, y, 3, seed + 17) * 0.08, 5, seed + 23);
  let sum = 0;
  let amp = 0;
  for (const [cells, weight] of [[4, 0.52], [8, 0.28], [16, 0.14], [32, 0.06]]) {
    sum += periodicNoise(wx, wy, cells, seed + cells * 31) * weight;
    amp += weight;
  }
  return sum / amp;
}

function torusDelta(a, b) {
  let d = Math.abs(a - b);
  return Math.min(d, 1 - d);
}

// Irregular elliptical bubbles. A sparse union gives holes without making a
// regular cellular pattern; noise perturbs the radius and keeps the boundary.
function bubbles(x, y) {
  let field = 0;
  const sites = [
    [0.12, 0.18, 0.060, 1.3], [0.31, 0.09, 0.043, 0.8], [0.47, 0.25, 0.075, 1.1],
    [0.70, 0.14, 0.052, 0.9], [0.87, 0.31, 0.066, 1.25], [0.18, 0.48, 0.050, 0.75],
    [0.39, 0.55, 0.085, 1.2], [0.61, 0.45, 0.047, 0.9], [0.81, 0.59, 0.058, 1.1],
    [0.08, 0.82, 0.070, 1.0], [0.31, 0.88, 0.045, 1.35], [0.55, 0.76, 0.064, 0.8],
    [0.75, 0.90, 0.080, 1.15], [0.96, 0.73, 0.048, 0.9]
  ];
  for (const [sx, sy, radius, aspect] of sites) {
    const dx = torusDelta(x, sx);
    const dy = torusDelta(y, sy);
    const angle = (sx * 19.0 + sy * 31.0) * TAU;
    const ca = Math.cos(angle), sa = Math.sin(angle);
    const rx = (dx * ca - dy * sa) / radius;
    const ry = (dx * sa + dy * ca) / (radius * aspect);
    const d = Math.sqrt(rx * rx + ry * ry);
    const wobble = 0.84 + 0.22 * noise((x + sx) % 1, (y + sy) % 1, 71 + Math.floor(sx * 100));
    field = Math.max(field, 1 - d / wobble);
  }
  return Math.max(0, Math.min(1, field * 0.5 + 0.5));
}

function u32be(n) { const b = Buffer.alloc(4); b.writeUInt32BE(n >>> 0, 0); return b; }
function chunk(type, data) {
  const t = Buffer.from(type);
  const crc = crc32(Buffer.concat([t, data]));
  return Buffer.concat([u32be(data.length), t, data, u32be(crc)]);
}
function crc32(buf) {
  let c = 0xffffffff;
  for (const v of buf) {
    c ^= v;
    for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xedb88320 & -(c & 1));
  }
  return (c ^ 0xffffffff) >>> 0;
}

const rows = Buffer.alloc((W * 4 + 1) * H);
for (let y = 0; y < H; y++) {
  rows[y * (W * 4 + 1)] = 0;
  for (let x = 0; x < W; x++) {
    const u = x / W;
    const v = y / H;
    const r = Math.max(0, Math.min(255, Math.round(noise(u, v, 101) * 255)));
    const g = Math.max(0, Math.min(255, Math.round(bubbles(u, v) * 255)));
    const i = y * (W * 4 + 1) + 1 + x * 4;
    rows[i] = r;
    rows[i + 1] = g;
    rows[i + 2] = 0;
    rows[i + 3] = 255;
  }
}

const ihdr = Buffer.alloc(13);
ihdr.writeUInt32BE(W, 0); ihdr.writeUInt32BE(H, 4);
ihdr[8] = 8; ihdr[9] = 6; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
const png = Buffer.concat([
  Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
  chunk('IHDR', ihdr),
  chunk('IDAT', zlib.deflateSync(rows, { level: 6 })),
  chunk('IEND', Buffer.alloc(0))
]);
fs.mkdirSync('ocean_v3/rendering/surface_detail', { recursive: true });
fs.writeFileSync(out, png);
console.log(`${out} ${W}x${H} RGBA8`);
