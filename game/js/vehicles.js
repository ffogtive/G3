// ════════════════════════════════════════════════════════════════════════
// vehicles.js — 차량·투사체 복셀 모델 (길건너친구들 풍 로우폴리)
//
// 가설: 게임 카메라는 뒤-위(≈16m 위, 18m 뒤)에서 내려다본다 →
//       차의 정체성은 "지붕 실루엣 + 뒷면(브레이크등·뒷유리·번호판·범퍼)"에서 나온다.
//       그래서 뒷면 디테일을 과장하고, 브레이크등은 트렁크 위로 살짝 솟게 만들어 위에서도 빨갛게 읽히게 한다.
//
// 구조
//  - 모든 지오메트리는 직접 만든 non-indexed 삼각형 누적기(GB)로 생성 → 한 번에 BufferGeometry 1개.
//    (BufferGeometryUtils.mergeGeometries 와 결과는 동일하지만, 박스/사다리꼴/각기둥을 바로 누적해서 더 가볍다)
//  - vertex color + MeshLambert(flatShading) 공유 재질 1개. 지면 근처 버텍스는 살짝 어둡게(가짜 AO) 구워 넣는다.
//  - 라이트(브레이크/비상등/헤드라이트): "꺼진 모습"은 차체 메시에 구워 두고, 켜질 때만 발광 메시를 보이게 한다.
//    → 꺼져 있는 라이트 메시는 visible=false 라서 draw call 0. (낮에 정체 중인 NPC = 차체+브레이크 = 2 draw call,
//      밤 = 차체+미등/브레이크+헤드 = 3, 해방 비상등 깜빡일 때만 +1)
//    mesh.material = MAT.xxxOn/Off 를 직접 바꿔도 visible 이 자동으로 따라간다(접근자).
//  - 램프는 "테두리색 + 6mm 솟은 밝은 코어" 버텍스색 (MAT.*On/Off 는 vertexColors) → 평면 빨강이 아니라 켜진 램프로 읽힘.
//    테일램프는 트렁크 윗면까지 감싸고(wrap) 바깥쪽은 호박색 세로띠, 트럭/버스는 지붕 뒤 모서리 차폭등까지
//    → 하네스(game/dev/vehicles.html?view=jam) 로 추격캠 "빨간 바다" 확인 ✅
//  - 지오메트리는 (kind, color, detailed, variant) 키로 캐시 → 같은 차종/색은 GPU 버퍼 공유. dispose 하지 말 것.
// ════════════════════════════════════════════════════════════════════════
import * as THREE from 'three';
import { PLAYER_COLOR, FONT_DISPLAY } from './config.js';

// ────────────────────────────────────────────────────────────────────────
// 재질
// ────────────────────────────────────────────────────────────────────────
// 라이트 재질은 vertexColors: 라이트 지오메트리에 "테두리 색 + 밝은 코어" 를 구워 넣어 발광처럼 보이게 한다.
// (On = 흰색 × 버텍스색 = 그대로, Off = 어두운 색 곱 → 밤 미등은 brakeOff 로 "어둡지만 분명한 빨강")
export const MAT = {
  body: new THREE.MeshLambertMaterial({ vertexColors: true, flatShading: true }),
  brakeOn: new THREE.MeshBasicMaterial({ color: 0xffffff, vertexColors: true }),
  brakeOff: new THREE.MeshBasicMaterial({ color: 0xa83434, vertexColors: true }),
  hazardOn: new THREE.MeshBasicMaterial({ color: 0xffffff, vertexColors: true }),
  hazardOff: new THREE.MeshBasicMaterial({ color: 0x5a4a30, vertexColors: true }),
  headOn: new THREE.MeshBasicMaterial({ color: 0xffffff, vertexColors: true }),
  headOff: new THREE.MeshBasicMaterial({ color: 0x9a9a90, vertexColors: true }),
  // ── 확장(계약 외) ──
  glass: new THREE.MeshLambertMaterial({ color: 0x2a3f6a, transparent: true, opacity: 0.4, flatShading: true }), // detailed 차량 유리 (운전자 보이게 살짝 옅게)
  glassTint: new THREE.MeshLambertMaterial({ color: 0x0a0d14, transparent: true, opacity: 0.8, flatShading: true }), // 썬팅 (villainSuv)
  glassScreen: new THREE.MeshBasicMaterial({ color: 0x63d9ff, transparent: true, opacity: 0.62 }), // 폰 화면빛으로 물든 실내 (villainPhone)
  glow: new THREE.MeshBasicMaterial({ vertexColors: true }),    // 항상 발광(폰 화면, 미사일 불꽃, 담뱃불)
  sirenR: new THREE.MeshBasicMaterial({ color: 0xff2236 }),
  sirenB: new THREE.MeshBasicMaterial({ color: 0x2f74ff }),
  beam: new THREE.MeshBasicMaterial({ color: 0xfff0b8, transparent: true, opacity: 0.14, blending: THREE.AdditiveBlending, depthWrite: false }),
};
MAT.body.name = 'vehicleBody';

// ────────────────────────────────────────────────────────────────────────
// 색 / 수학 유틸
// ────────────────────────────────────────────────────────────────────────
const _col = new THREE.Color();
const _lin = new Map();
function lin(hex) {
  let v = _lin.get(hex);
  if (!v) { _col.setHex(hex); v = [_col.r, _col.g, _col.b]; _lin.set(hex, v); }
  return v;
}
function mixHex(a, b, t) {
  const ar = (a >> 16) & 255, ag = (a >> 8) & 255, ab = a & 255;
  const br = (b >> 16) & 255, bg = (b >> 8) & 255, bb = b & 255;
  return (Math.round(ar + (br - ar) * t) << 16) | (Math.round(ag + (bg - ag) * t) << 8) | Math.round(ab + (bb - ab) * t);
}
const shade = (hex, k) => (k < 1 ? mixHex(hex, 0x000000, 1 - k) : mixHex(hex, 0xffffff, k - 1));
const lum = (hex) => (((hex >> 16) & 255) * 0.3 + ((hex >> 8) & 255) * 0.59 + (hex & 255) * 0.11) / 255;
const lerp = (a, b, t) => a + (b - a) * t;
const smooth = (a, b, x) => { const t = Math.min(1, Math.max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t); };
const SIDES = [-1, 1];
const xr = (s, a, b) => (s > 0 ? [a, b] : [-b, -a]); // 좌우 대칭 x 범위
function rng32(seed) { let a = seed >>> 0; return () => { a = (a + 0x6d2b79f5) | 0; let t = Math.imul(a ^ (a >>> 15), 1 | a); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; }
const _m4 = () => new THREE.Matrix4();
function trs(x, y, z, rx = 0, ry = 0, rz = 0, s = 1) {
  const q = new THREE.Quaternion().setFromEuler(new THREE.Euler(rx, ry, rz));
  return _m4().compose(new THREE.Vector3(x, y, z), q, typeof s === 'number' ? new THREE.Vector3(s, s, s) : new THREE.Vector3(s[0], s[1], s[2]));
}

// 팔레트
const C = {
  tire: 0x232428, hub: 0xc6ccd4, hubDark: 0x6f7680, dark: 0x2b2d32, under: 0x1c1d21, well: 0x141518,
  glass: 0x1d2a48, glassHi: 0x41608f, mirror: 0xa9c9e2, chrome: 0xe3e8ee, chromeDark: 0x8e97a2,
  plateW: 0xf4f4ef, plateY: 0xf6c21c, plateTxt: 0x23252a, skin: 0xf3c79f, hair: 0x2a211c,
  interior: 0x2a2c33, seat: 0x3b3e47, white: 0xf4f4f2, red: 0xe23b3b, yellow: 0xffcf3a,
};
const OFF_BAKE = { brake: 0x7c1d1f, hazard: 0xa86a12, head: 0xe2e5da };
// 켜진 라이트: [테두리, 코어]
const LAMP_COL = { brake: [0xff1c1c, 0xff9a8a], hazard: [0xffa000, 0xfff2a8], head: [0xfff0c0, 0xffffff] };

// ────────────────────────────────────────────────────────────────────────
// GB — 삼각형 누적기 (position / normal / color, non-indexed)
//  모든 도형은 볼록체 → 삼각형 감김(winding)을 "도형 중심에서 바깥" 기준으로 자동 보정한다.
//  면 이름: L(-X) R(+X) D(-Y) U(+Y) F(-Z, 앞) K(+Z, 뒤)
// ────────────────────────────────────────────────────────────────────────
const HEX_FACES = [['L', 0, 4, 6, 2], ['R', 1, 3, 7, 5], ['D', 0, 1, 5, 4], ['U', 2, 6, 7, 3], ['F', 0, 2, 3, 1], ['K', 4, 5, 7, 6]];
class GB {
  constructor() { this.p = []; this.n = []; this.c = []; this.m = null; }
  get tris() { return this.p.length / 9; }
  _x(x, y, z) {
    const m = this.m; if (!m) return [x, y, z];
    const e = m.elements;
    return [e[0] * x + e[4] * y + e[8] * z + e[12], e[1] * x + e[5] * y + e[9] * z + e[13], e[2] * x + e[6] * y + e[10] * z + e[14]];
  }
  with(mat, fn) { const prev = this.m; this.m = prev ? prev.clone().multiply(mat) : mat.clone(); fn(this); this.m = prev; return this; }
  at(x, y, z, rx, ry, rz, s, fn) { return this.with(trs(x, y, z, rx, ry, rz, s), fn); }
  tri(a, b, c, col, ctr) {
    const ux = b[0] - a[0], uy = b[1] - a[1], uz = b[2] - a[2];
    const vx = c[0] - a[0], vy = c[1] - a[1], vz = c[2] - a[2];
    let nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
    const len = Math.hypot(nx, ny, nz);
    if (len < 1e-12) return;
    nx /= len; ny /= len; nz /= len;
    if (ctr) {
      const mx = (a[0] + b[0] + c[0]) / 3 - ctr[0], my = (a[1] + b[1] + c[1]) / 3 - ctr[1], mz = (a[2] + b[2] + c[2]) / 3 - ctr[2];
      if (nx * mx + ny * my + nz * mz < 0) { const t = b; b = c; c = t; nx = -nx; ny = -ny; nz = -nz; }
    }
    this.p.push(a[0], a[1], a[2], b[0], b[1], b[2], c[0], c[1], c[2]);
    this.n.push(nx, ny, nz, nx, ny, nz, nx, ny, nz);
    const k = lin(col);
    this.c.push(k[0], k[1], k[2], k[0], k[1], k[2], k[0], k[1], k[2]);
  }
  quad(a, b, c, d, col, ctr) { this.tri(a, b, c, col, ctr); this.tri(a, c, d, col, ctr); }
  hexa(k, col, skip, fc) {
    const v = k.map((q) => this._x(q[0], q[1], q[2]));
    const ctr = [0, 0, 0];
    for (const q of v) { ctr[0] += q[0] / 8; ctr[1] += q[1] / 8; ctr[2] += q[2] / 8; }
    for (const [nm, i0, i1, i2, i3] of HEX_FACES) {
      if (skip && skip.includes(nm)) continue;
      this.quad(v[i0], v[i1], v[i2], v[i3], fc && fc[nm] !== undefined ? fc[nm] : col, ctr);
    }
    return this;
  }
  box(x0, x1, y0, y1, z0, z1, col, skip, fc) {
    return this.hexa([[x0, y0, z0], [x1, y0, z0], [x0, y1, z0], [x1, y1, z0], [x0, y0, z1], [x1, y0, z1], [x0, y1, z1], [x1, y1, z1]], col, skip, fc);
  }
  boxc(cx, cy, cz, w, h, d, col, skip, fc) { return this.box(cx - w / 2, cx + w / 2, cy - h / 2, cy + h / 2, cz - d / 2, cz + d / 2, col, skip, fc); }
  // 사다리꼴 기둥: F = { b:[x0,x1,z0,z1] (y0 에서), t:[x0,x1,z0,z1] (y1 에서), y0, y1 }
  frustum(F, col, skip, fc) {
    const k = [];
    for (let i = 0; i < 8; i++) { const R = i & 2 ? F.t : F.b; k.push([i & 1 ? R[1] : R[0], i & 2 ? F.y1 : F.y0, i & 4 ? R[3] : R[2]]); }
    return this.hexa(k, col, skip, fc);
  }
  // 사다리꼴 내부의 부분 영역 (u: x, v: z, w: y 비율)
  sub(F, u0, u1, v0, v1, w0, w1, col, skip, fc) {
    const k = [];
    for (let i = 0; i < 8; i++) k.push(fpt(F, i & 1 ? u1 : u0, i & 4 ? v1 : v0, i & 2 ? w1 : w0));
    return this.hexa(k, col, skip, fc);
  }
  // n각 기둥/원뿔. axis 방향 길이 len, -len/2 쪽 반지름 r0, +len/2 쪽 r1
  prism(n, r0, r1, len, axis, cx, cy, cz, col, o = {}) {
    const a0 = o.a0 ?? 0, h = len / 2;
    const P = (r, a, t) => {
      const cs = Math.cos(a) * r, sn = Math.sin(a) * r;
      if (axis === 'x') return this._x(cx + t, cy + cs, cz + sn);
      if (axis === 'y') return this._x(cx + cs, cy + t, cz + sn);
      return this._x(cx + cs, cy + sn, cz + t);
    };
    const ctr = this._x(cx, cy, cz);
    const A = [], B = [];
    for (let i = 0; i < n; i++) { const a = a0 + (i / n) * Math.PI * 2; A.push(P(r0, a, -h)); B.push(P(r1, a, h)); }
    const side = o.side ?? col;
    for (let i = 0; i < n; i++) { const j = (i + 1) % n; this.quad(A[i], A[j], B[j], B[i], side, ctr); }
    if (r0 > 0 && !o.noA) { const ca = P(0, 0, -h); for (let i = 0; i < n; i++) this.tri(ca, A[i], A[(i + 1) % n], o.capA ?? col, ctr); }
    if (r1 > 0 && !o.noB) { const cb = P(0, 0, h); for (let i = 0; i < n; i++) this.tri(cb, B[i], B[(i + 1) % n], o.capB ?? col, ctr); }
    return this;
  }
  // 위경도 타원체. colFn(iLon, iLat) → hex. o: { th0, th1 (경도 범위), ph0, ph1 (위도 범위, 0 = +Y 극) } → 반구/돔
  sphere(rx, ry, rz, nLon, nLat, cx, cy, cz, colFn, o = {}) {
    const ctr = this._x(cx, cy, cz);
    const th0 = o.th0 ?? 0, th1 = o.th1 ?? Math.PI * 2, ph0 = o.ph0 ?? 0, ph1 = o.ph1 ?? Math.PI;
    const V = [];
    for (let j = 0; j <= nLat; j++) {
      const ph = ph0 + (j / nLat) * (ph1 - ph0), row = [];
      for (let i = 0; i <= nLon; i++) {
        const th = th0 + (i / nLon) * (th1 - th0);
        row.push(this._x(cx + Math.sin(ph) * Math.cos(th) * rx, cy + Math.cos(ph) * ry, cz + Math.sin(ph) * Math.sin(th) * rz));
      }
      V.push(row);
    }
    for (let j = 0; j < nLat; j++) for (let i = 0; i < nLon; i++) this.quad(V[j][i], V[j][i + 1], V[j + 1][i + 1], V[j + 1][i], colFn(i, j), ctr);
    return this;
  }
  // a→b 를 잇는 각재 (단면 tx × ty)
  beam(a, b, tx, ty, col) {
    const d = new THREE.Vector3(b[0] - a[0], b[1] - a[1], b[2] - a[2]);
    const len = d.length(); d.normalize();
    const q = new THREE.Quaternion().setFromUnitVectors(new THREE.Vector3(0, 0, 1), d);
    const m = _m4().compose(new THREE.Vector3((a[0] + b[0]) / 2, (a[1] + b[1]) / 2, (a[2] + b[2]) / 2), q, new THREE.Vector3(1, 1, 1));
    return this.with(m, (g) => g.box(-tx / 2, tx / 2, -ty / 2, ty / 2, -len / 2, len / 2, col));
  }
  build(ao = false) {
    const g = new THREE.BufferGeometry();
    const pos = new Float32Array(this.p), nor = new Float32Array(this.n), col = new Float32Array(this.c);
    if (ao) for (let i = 0; i < pos.length; i += 3) { const f = 0.7 + 0.3 * smooth(0.06, 1.05, pos[i + 1]); col[i] *= f; col[i + 1] *= f; col[i + 2] *= f; }
    g.setAttribute('position', new THREE.BufferAttribute(pos, 3));
    g.setAttribute('normal', new THREE.BufferAttribute(nor, 3));
    g.setAttribute('color', new THREE.BufferAttribute(col, 3));
    g.computeBoundingBox(); g.computeBoundingSphere();
    return g;
  }
}
function fpt(F, u, v, w) {
  const bx = lerp(F.b[0], F.b[1], u), bz = lerp(F.b[2], F.b[3], v);
  const tx = lerp(F.t[0], F.t[1], u), tz = lerp(F.t[2], F.t[3], v);
  return [lerp(bx, tx, w), lerp(F.y0, F.y1, w), lerp(bz, tz, w)];
}
const outsetF = (F, d) => ({ b: [F.b[0] - d, F.b[1] + d, F.b[2] - d, F.b[3] + d], t: [F.t[0] - d, F.t[1] + d, F.t[2] - d, F.t[3] + d], y0: F.y0, y1: F.y1 });

// ── 3×5 픽셀 폰트 (TAXI / POLICE / 112 등). face: K(뒤 +Z) F(앞) L(-X) R(+X) U(윗면, 뒤에서 읽힘)
const FONT = {
  A: ['.#.', '#.#', '###', '#.#', '#.#'], C: ['###', '#..', '#..', '#..', '###'], E: ['###', '#..', '##.', '#..', '###'],
  I: ['###', '.#.', '.#.', '.#.', '###'], L: ['#..', '#..', '#..', '#..', '###'], O: ['###', '#.#', '#.#', '#.#', '###'],
  P: ['##.', '#.#', '##.', '#..', '#..'], T: ['###', '.#.', '.#.', '.#.', '.#.'], X: ['#.#', '#.#', '.#.', '#.#', '#.#'],
  V: ['#.#', '#.#', '#.#', '.#.', '.#.'],
  1: ['.#.', '##.', '.#.', '.#.', '###'], 2: ['##.', '..#', '.#.', '#..', '###'], ' ': ['...', '...', '...', '...', '...'],
};
function textRows(str) {
  const rows = ['', '', '', '', ''];
  [...str].forEach((ch, i) => { const g = FONT[ch] || FONT[' ']; for (let r = 0; r < 5; r++) rows[r] += (i ? '.' : '') + g[r]; });
  return rows;
}
// rows: 문자열 배열('#' = 켜짐). 중심 (cx,cy,cz), 픽셀 크기 px
function pixelArt(g, rows, face, cx, cy, cz, px, col) {
  const W = rows[0].length, H = rows.length;
  const map = (u, v) => {
    switch (face) {
      case 'K': return [cx + u, cy + v, cz];
      case 'F': return [cx - u, cy + v, cz];
      case 'L': return [cx, cy + v, cz + u];
      case 'R': return [cx, cy + v, cz - u];
      default: return [cx + u, cy, cz - v]; // U
    }
  };
  const nrm = { K: [0, 0, 1], F: [0, 0, -1], L: [-1, 0, 0], R: [1, 0, 0], U: [0, 1, 0] }[face];
  const ctr = g._x(cx - nrm[0], cy - nrm[1], cz - nrm[2]);
  for (let r = 0; r < H; r++) {
    let i = 0;
    while (i < W) {
      if (rows[r][i] !== '#') { i++; continue; }
      let j = i; while (j < W && rows[r][j] === '#') j++;
      const u0 = (i - W / 2) * px, u1 = (j - W / 2) * px, v1 = (H / 2 - r) * px, v0 = v1 - px;
      const a = map(u0, v0), b = map(u1, v0), c2 = map(u1, v1), d = map(u0, v1);
      g.quad(g._x(...a), g._x(...b), g._x(...c2), g._x(...d), col, ctr);
      i = j;
    }
  }
}
// 면 위 평면 다각형 (u,v: 면 중심 기준 좌표, 매핑은 pixelArt 와 동일) → 삼각형 팬
const FACE_N = { K: [0, 0, 1], F: [0, 0, -1], L: [-1, 0, 0], R: [1, 0, 0], U: [0, 1, 0] };
function faceMap(face, cx, cy, cz) {
  switch (face) {
    case 'K': return (u, v) => [cx + u, cy + v, cz];
    case 'F': return (u, v) => [cx - u, cy + v, cz];
    case 'L': return (u, v) => [cx, cy + v, cz + u];
    case 'R': return (u, v) => [cx, cy + v, cz - u];
    default: return (u, v) => [cx + u, cy, cz - v];
  }
}
function facePoly(g, face, cx, cy, cz, pts, col) {
  if (pts.length < 3) return;
  const m = faceMap(face, cx, cy, cz), n = FACE_N[face];
  const ctr = g._x(cx - n[0], cy - n[1], cz - n[2]);
  const P = pts.map(([u, v]) => g._x(...m(u, v)));
  for (let i = 1; i < P.length - 1; i++) g.tri(P[0], P[i], P[i + 1], col, ctr);
}
function clipU(poly, lim, s) { // s=+1: u >= lim 만 남김, s=-1: u <= lim
  const out = [];
  for (let i = 0; i < poly.length; i++) {
    const A = poly[i], B = poly[(i + 1) % poly.length];
    const ia = (A[0] - lim) * s >= 0, ib = (B[0] - lim) * s >= 0;
    if (ia) out.push(A);
    if (ia !== ib) { const t = (lim - A[0]) / (B[0] - A[0]); out.push([lim, A[1] + (B[1] - A[1]) * t]); }
  }
  return out;
}
// 사선(45°) 경고 줄무늬 데칼: 면 위 w×h 영역에 폭 sw 띠를 col 로 (바탕색은 호출자가 그린 면). 면에서 4mm 띄워 호출할 것
function hazardStripes(g, face, cx, cy, cz, w, h, sw, col, dir = 1) {
  const u0 = -w / 2, u1 = w / 2, v0 = -h / 2, v1 = h / 2;
  for (let a = u0 - h - sw; a < u1 + sw; a += sw * 2) {
    let poly = dir > 0 ? [[a, v0], [a + sw, v0], [a + sw + h, v1], [a + h, v1]] : [[a + h, v0], [a + h + sw, v0], [a + sw, v1], [a, v1]];
    poly = clipU(clipU(poly, u0, 1), u1, -1);
    facePoly(g, face, cx, cy, cz, poly, col);
  }
}
// 점멸 램프(스트로브) 박스: 테두리색 + 앞/뒤/윗면으로 솟은 밝은 코어 → 켜지면 "번쩍" 으로 읽힘
function strobeBox(G, x0, x1, y0, y1, z0, z1, rim, core) {
  const e = 0.008, p = 0.006;
  G.box(x0 - e, x1 + e, y0 - e, y1 + e, z0 - e, z1 + e, rim);
  const ix = Math.min(0.08, (x1 - x0) * 0.22), iy = Math.min(0.05, (y1 - y0) * 0.25);
  G.box(x0 + ix, x1 - ix, y0 + iy, y1 + e + p, z0 - e - p, z1 + e + p, core);
}

// ────────────────────────────────────────────────────────────────────────
// 빌드 컨텍스트 / 공용 파츠
// ────────────────────────────────────────────────────────────────────────
function newCtx(detailed, variant, color) {
  return {
    detailed, variant, color,
    body: new GB(), brake: new GB(), hazard: new GB(), head: new GB(), glow: new GB(), glass: new GB(),
    sirenR: null, sirenB: null, driver: null, driverPos: null, driverTop: 0.44,
    cannon: null, wheels: [], signs: [], info: {},
    // 확장 파츠: [{ key, idx?, gb, mat: 'body'|MAT 키, pos?, name, visible? }] → body 자식 메시, userData[key] (idx 있으면 배열)
    extra: [], points: {}, ud: {},   // points: { name: [x,y,z] } → body 자식 Object3D. ud: userData 에 그대로 복사할 값
  };
}
// 라이트: 발광 메시엔 전체 박스, 차체엔 1cm 안쪽으로 "꺼진 색" 구워넣기 (켜지면 발광 박스가 덮음 → z-fight 없음)
//  켜진 박스 = 진한 테두리색 + 바깥면(뒤/앞, o.top 이면 윗면도)으로 6mm 솟은 밝은 코어 → 평면 색이 아니라 "빛나는" 램프로 읽힘
//  o: { core=true, dir(+1 뒤, −1 앞; 기본 = z 부호), top=false(윗면에도 코어), col:[테두리, 코어] }
function lamp(c, which, x0, x1, y0, y1, z0, z1, bake, o = {}) {
  const [rim, core] = o.col || LAMP_COL[which];
  const G = c[which];
  G.box(x0, x1, y0, y1, z0, z1, rim);
  const w = x1 - x0, h = y1 - y0, d = z1 - z0;
  if (o.core !== false && w > 0.09 && h > 0.06) {
    const dir = o.dir ?? (z0 + z1 > 0 ? 1 : -1);
    const ix = Math.min(0.09, Math.max(0.025, w * 0.26)), iy = Math.min(0.08, Math.max(0.022, h * 0.28)), iz = d * 0.3, p = 0.006;
    const cy1 = o.top ? y1 + p : y1 - iy;
    if (dir > 0) G.box(x0 + ix, x1 - ix, y0 + iy, cy1, z0 + (o.top ? Math.min(0.06, iz) : iz), z1 + p, core);
    else G.box(x0 + ix, x1 - ix, y0 + iy, cy1, z0 - p, z1 - (o.top ? Math.min(0.06, iz) : iz), core);
  }
  const e = 0.01;
  c.body.box(x0 + e, x1 - e, y0 + e, y1 - e, z0 + e, z1 - e, bake ?? OFF_BAKE[which]);
}
// 캐빈 사다리꼴 면(주로 D필러 세로 램프). 코어는 뒷면(v=1)에만 1cm 솟음
function lampSub(c, which, F, u0, u1, v0, v1, w0, w1, bake) {
  const [rim, core] = LAMP_COL[which];
  c[which].sub(outsetF(F, 0.03), u0, u1, v0, v1, w0, w1, rim, 'D');
  const du = (u1 - u0) * 0.24, dw = (w1 - w0) * 0.16;
  c[which].sub(outsetF(F, 0.04), u0 + du, u1 - du, v0 + (v1 - v0) * 0.3, v1, w0 + dw, w1 - dw, core, 'D');
  c.body.sub(outsetF(F, 0.02), u0, u1, v0, v1, w0, w1, bake ?? OFF_BAKE[which], 'D');
}
const addWheel = (c, x, z, r, w, o = {}, y = r) => c.wheels.push({ x, y, z, r, w, o });

// 바퀴 (팔각 타이어 + 휠 + 센터캡). side: -1/+1 = 바깥쪽 한 면만, 0 = 양면(detailed 공유 지오메트리)
function wheelParts(g, x, y, z, r, w, o = {}) {
  const k = 1 / Math.cos(Math.PI / 8), a0 = Math.PI / 8;
  const tire = o.tire ?? C.tire;
  g.prism(8, r * k, r * k, w, 'x', x, y, z, tire, { a0 });
  const hr = r * (o.hubK ?? 0.56) * k;
  const sides = o.side ? [o.side] : SIDES;
  for (const s of sides) {
    const hx = x + s * (w / 2 + 0.012);
    g.prism(8, s < 0 ? hr * 0.8 : hr, s < 0 ? hr : hr * 0.8, 0.05, 'x', hx, y, z, o.rim ?? C.hub, { a0, noA: s > 0, noB: s < 0 });
    const cx0 = hx + s * 0.02, cx1 = hx + s * 0.042;
    g.box(Math.min(cx0, cx1), Math.max(cx0, cx1), y - r * 0.17, y + r * 0.17, z - r * 0.17, z + r * 0.17, o.cap ?? C.hubDark);
    if (o.spoke) { // 2살 스포크 막대 (센터캡보다 낮게) — 회전이 한눈에 보임
      const sx0 = hx + s * 0.012, sx1 = hx + s * 0.034;
      g.box(Math.min(sx0, sx1), Math.max(sx0, sx1), y - hr * 0.86, y + hr * 0.86, z - r * 0.09, z + r * 0.09, o.spokeCol ?? C.hubDark);
    }
  }
  if (o.lugs) {
    for (let i = 0; i < 8; i++) {
      const a = (i / 8) * Math.PI * 2, sd = i % 2 ? 1 : -1;
      g.with(_m4().makeTranslation(x, y, z).multiply(_m4().makeRotationX(a)), (q) => {
        q.box(sd > 0 ? -0.02 : -w / 2, sd > 0 ? w / 2 : 0.02, r - 0.01, r + 0.06, -r * 0.16, r * 0.16, tire);
      });
    }
  }
}
function plate(g, x, y, z, dir, yellow) {
  const pc = yellow ? C.plateY : C.plateW;
  const z0 = dir > 0 ? z : z - 0.02, z1 = dir > 0 ? z + 0.02 : z;
  g.box(x - 0.27, x + 0.27, y - 0.075, y + 0.075, z0, z1, pc);
  const t0 = dir > 0 ? z1 : z0 - 0.006, t1 = dir > 0 ? z1 + 0.006 : z0;
  g.box(x - 0.21, x - 0.05, y - 0.032, y + 0.032, t0, t1, C.plateTxt);
  g.box(x + 0.0, x + 0.21, y - 0.032, y + 0.032, t0, t1, C.plateTxt);
}
// 유리창 패널 (detailed: 투명 재질로 실내가 보이게)
function glassPanels(g, F, openLeft, col = C.glass, noRear = false) {
  const wB = F.b[1] - F.b[0], dB = F.b[3] - F.b[2];
  const tu = 0.03 / wB, tv = 0.03 / dB;
  g.sub(F, 0, 1, 0, tv, 0, 1, col, 'DU');
  if (!noRear) g.sub(F, 0, 1, 1 - tv, 1, 0, 1, col, 'DU');
  g.sub(F, 0, tu, openLeft ? 0.52 : tv, 1 - tv, 0, 1, col, 'DU');
  g.sub(F, 1 - tu, 1, tv, 1 - tv, 0, 1, col, 'DU');
}
// 유리 반사 하이라이트 (얇은 세로 띠 2개) — 비detailed 불투명 유리에만
function glassShine(g, F, face) {
  const Fo = outsetF(F, 0.006);
  const v = face === 'K' ? [0.985, 1] : [0, 0.015];
  g.sub(Fo, 0.18, 0.3, v[0], v[1], 0.12, 0.92, C.glassHi, 'DU');
  g.sub(Fo, 0.36, 0.41, v[0], v[1], 0.12, 0.92, C.glassHi, 'DU');
}
// 스커트(바퀴 구멍 있는 하부) — 버스/트럭/포터용. 바퀴 z 위치마다 구멍 + 안쪽 검은 휠하우스
function skirt(g, x0, x1, y0, y1, z0, z1, holes, r, col) {
  let z = z0;
  const hs = holes.slice().sort((a, b) => a - b);
  for (const hz of hs) {
    const a = hz - r - 0.1, b = hz + r + 0.1;
    if (a > z) g.box(x0, x1, y0, y1, z, a, col, 'D');
    g.box(x0 + 0.06, x1 - 0.06, Math.max(0.12, y0), y1, a, b, C.well, 'D');
    z = b;
  }
  if (z < z1) g.box(x0, x1, y0, y1, z, z1, col, 'D');
}

// 운전자 머리 GB 생성 (spec.scale: 장난감처럼 큰 머리). 반환: 스케일 반영한 머리 꼭대기 높이
function makeDriver(c, spec) {
  const hs = spec.scale ?? 1;
  let top = 0.44;
  c.driver = new GB();
  c.driver.with(_m4().makeScale(hs, hs, hs), (g) => { top = HEADS[spec.head](g, spec); });
  return top * hs;
}
// ── 운전자 머리 (원점 = 목, 앞 = -Z). 반환: 머리 꼭대기 높이
const EYE = 0x1b1b1f;
function face2(g, skin, eyeY = 0.2) {
  g.box(-0.17, 0.17, 0.02, 0.36, -0.16, 0.16, skin, 'D');
  g.box(-0.11, -0.05, eyeY - 0.03, eyeY + 0.03, -0.172, -0.16, EYE);
  g.box(0.05, 0.11, eyeY - 0.03, eyeY + 0.03, -0.172, -0.16, EYE);
}
const HEADS = {
  npc(g, o) { face2(g, o.skin ?? C.skin); g.box(-0.18, 0.18, 0.3, 0.4, -0.12, 0.18, o.hair ?? C.hair); g.box(-0.18, 0.18, 0.12, 0.3, 0.08, 0.18, o.hair ?? C.hair); return 0.4; },
  hero(g, o = {}) { // 참교육 머신 기사: 삐죽머리 + 빨간 머리띠(꼬리 휘날림) + 결의의 눈썹 (o.shades: 암행 선글라스)
    face2(g, C.skin);
    const hr = 0x22201f, band = 0xe2231a;
    g.box(-0.18, 0.18, 0.29, 0.39, -0.13, 0.18, hr);
    g.box(-0.18, 0.18, 0.1, 0.3, 0.08, 0.18, hr);
    g.box(-0.15, -0.04, 0.38, 0.47, -0.04, 0.1, hr); g.box(0.0, 0.11, 0.38, 0.5, 0.0, 0.14, hr); g.box(-0.05, 0.05, 0.38, 0.45, -0.13, -0.03, hr);
    g.box(-0.188, 0.188, 0.245, 0.3, -0.172, 0.188, band);
    g.box(0.02, 0.075, 0.12, 0.28, 0.188, 0.34, band); g.box(0.085, 0.13, 0.06, 0.25, 0.188, 0.3, band);
    g.box(-0.13, -0.035, 0.235, 0.26, -0.176, -0.16, EYE); g.box(0.035, 0.13, 0.235, 0.26, -0.176, -0.16, EYE); // 눈썹
    g.box(-0.06, 0.06, 0.075, 0.105, -0.172, -0.16, 0x9a3b2b);
    if (o.shades) { // 검은 선글라스 (눈썹은 위로 보이게 → 결의 유지)
      g.box(-0.168, 0.168, 0.16, 0.24, -0.186, -0.16, 0x0b0b0d);
      g.box(-0.19, -0.168, 0.2, 0.232, -0.175, 0.07, 0x0b0b0d); g.box(0.168, 0.19, 0.2, 0.232, -0.175, 0.07, 0x0b0b0d);
      g.box(-0.135, -0.085, 0.205, 0.228, -0.191, -0.186, 0x7b8798); g.box(0.035, 0.085, 0.205, 0.228, -0.191, -0.186, 0x7b8798);
    }
    return 0.5;
  },
  boss(g) { // 정속주행 김사장: 흰 골프캡 + 검은 선글라스 + 콧수염 + 비릿한 미소
    face2(g, C.skin);
    const cap = 0xf6f6f0, brim = 0x1f2f55;
    g.box(-0.185, 0.185, 0.12, 0.29, 0.04, 0.18, 0x5c5750); // 희끗한 옆·뒷머리
    g.box(-0.188, 0.188, 0.28, 0.43, -0.15, 0.188, cap);
    g.box(-0.13, 0.13, 0.43, 0.46, -0.09, 0.13, cap);
    g.box(-0.165, 0.165, 0.28, 0.31, -0.37, -0.15, brim);
    g.box(-0.045, 0.045, 0.33, 0.39, -0.16, -0.15, 0xd8342c);
    g.box(-0.04, 0.04, 0.33, 0.4, 0.188, 0.196, brim); // 뒤 사이즈 조절 밴드
    g.box(-0.168, 0.168, 0.165, 0.25, -0.185, -0.16, 0x0b0b0d); // 선글라스
    g.box(-0.19, -0.168, 0.2, 0.235, -0.175, 0.07, 0x0b0b0d); g.box(0.168, 0.19, 0.2, 0.235, -0.175, 0.07, 0x0b0b0d);
    g.box(-0.13, -0.085, 0.215, 0.24, -0.19, -0.185, 0x7b8798); g.box(0.04, 0.085, 0.215, 0.24, -0.19, -0.185, 0x7b8798);
    g.box(-0.08, 0.08, 0.115, 0.14, -0.174, -0.16, 0x3a2f2a); // 콧수염
    g.box(-0.06, 0.03, 0.07, 0.095, -0.172, -0.16, 0x7a3326); g.box(0.03, 0.085, 0.085, 0.115, -0.172, -0.16, 0x7a3326); // 비죽
    return 0.46;
  },
  trucker(g, o) { // 화물차 형님/아우: 캡 or 수건 머리띠
    face2(g, 0xe0a97c);
    g.box(-0.18, 0.18, 0.12, 0.29, 0.06, 0.18, C.hair);
    if (o.towel) {
      g.box(-0.18, 0.18, 0.29, 0.38, -0.13, 0.18, C.hair);
      g.box(-0.19, 0.19, 0.27, 0.34, -0.175, 0.19, 0xf2f2ea);
      g.box(0.1, 0.17, 0.18, 0.3, 0.19, 0.24, 0xf2f2ea);
    } else {
      const cap = o.cap ?? 0xd8342c;
      g.box(-0.188, 0.188, 0.28, 0.42, -0.15, 0.188, cap);
      g.box(-0.16, 0.16, 0.28, 0.31, -0.36, -0.15, cap);
      g.box(-0.08, 0.08, 0.32, 0.39, -0.16, -0.15, 0xf4f4f2);
    }
    g.box(-0.07, 0.07, 0.07, 0.1, -0.172, -0.16, 0x7a3326);
    return 0.44;
  },
  phone(g) { // 숏폼중독: 고개 푹 숙임, 얼굴에 시안색 화면빛, 흰 이어버드
    g.with(_m4().makeRotationX(-0.5), (h) => {
      const skin = mixHex(C.skin, 0x6ff2ff, 0.35);
      h.box(-0.17, 0.17, 0.02, 0.36, -0.16, 0.16, C.skin, 'D', { F: skin });
      h.box(-0.11, -0.05, 0.14, 0.18, -0.172, -0.16, EYE); h.box(0.05, 0.11, 0.14, 0.18, -0.172, -0.16, EYE); // 내리깐 눈
      h.box(-0.04, 0.04, 0.07, 0.1, -0.172, -0.16, 0x9a3b4b); // ㅋㅋ 입
      const hair = 0x3b2418;
      h.box(-0.185, 0.185, 0.28, 0.4, -0.14, 0.185, hair);
      h.box(-0.185, 0.185, 0.04, 0.3, 0.06, 0.185, hair);
      h.box(-0.07, 0.07, 0.3, 0.46, 0.14, 0.26, hair); // 똥머리
      h.box(-0.2, -0.17, 0.14, 0.2, -0.02, 0.04, 0xffffff); h.box(0.17, 0.2, 0.14, 0.2, -0.02, 0.04, 0xffffff);
    });
    return 0.42;
  },
  bro(g) { // 차선물기 대마왕: 반삭 + 선글라스
    face2(g, 0xe6b287);
    g.box(-0.18, 0.18, 0.31, 0.37, -0.13, 0.18, 0x1a1a1a);
    g.box(-0.18, 0.18, 0.14, 0.31, 0.12, 0.18, 0x1a1a1a);
    g.box(-0.17, 0.17, 0.17, 0.25, -0.185, -0.16, 0x0b0b0d);
    g.box(-0.13, -0.08, 0.215, 0.24, -0.19, -0.185, 0x8a6a2a); g.box(0.04, 0.09, 0.215, 0.24, -0.19, -0.185, 0x8a6a2a);
    g.box(-0.06, 0.06, 0.07, 0.095, -0.172, -0.16, 0x7a3326);
    return 0.38;
  },
  grandpa(g) { // 전설의 경운기 할배: 밀짚모자 + 흰 콧수염 + 그을린 피부
    face2(g, 0xc98a55, 0.19);
    g.box(-0.13, -0.03, 0.235, 0.255, -0.176, -0.16, 0xf2f2f2); g.box(0.03, 0.13, 0.235, 0.255, -0.176, -0.16, 0xf2f2f2); // 흰 눈썹
    g.box(-0.1, 0.1, 0.08, 0.13, -0.176, -0.16, 0xf2f2f2); // 콧수염
    g.box(-0.04, 0.04, 0.12, 0.17, -0.19, -0.16, 0xb87448); // 코
    g.box(-0.44, 0.44, 0.3, 0.34, -0.44, 0.44, 0xfff1c2, '', { D: 0xd9c48a }); // 챙 (건초보다 훨씬 연한 밀짚색)
    g.box(-0.22, 0.22, 0.34, 0.56, -0.22, 0.22, 0xfbe7a6, '', { U: 0xfff4cc }); // 크라운
    g.box(-0.225, 0.225, 0.34, 0.41, -0.225, 0.225, 0xd8342c); // 빨간 띠
    return 0.56;
  },
};

// ────────────────────────────────────────────────────────────────────────
// 승용차 공통 빌더 (compact / sedan / suv / taxi / police / player / villainSedan / villainSuv / villainPhone / van)
// ────────────────────────────────────────────────────────────────────────
function passenger(c, P) {
  const B = c.body, D = c.detailed;
  const { L, W, yb, belt, roofY, col } = P;
  const hood = P.hood ?? belt - 0.04;
  const roofT = P.roofT ?? 0.09;
  const roofTop = roofY + roofT;
  const hl = L / 2, hw = W / 2, zf = -hl + 0.06, zr = hl - 0.06;
  const cab = P.cab;
  const bump = P.bumper ?? shade(col, 0.84);
  const glassCol = P.glassCol ?? C.glass;
  const wr = P.wheel;

  // ── 하부 차체 (후드가 약간 낮으면 2단)
  const zh = cab.zb0 + 0.05;
  if (hood < belt - 0.001) { B.box(-hw, hw, yb, hood, zf, zh, col, 'D'); B.box(-hw, hw, yb, belt, zh, zr, col, 'D'); }
  else B.box(-hw, hw, yb, belt, zf, zr, col, 'D');
  B.box(-hw + 0.14, hw - 0.14, 0.13, yb + 0.01, zf + 0.3, zr - 0.3, C.under, 'DU'); // 언더바디 그림자 띠
  // 범퍼 + 립 + 디퓨저
  B.box(-hw - 0.015, hw + 0.015, yb - 0.03, yb + 0.22, -hl, zf + 0.26, bump, 'D');
  B.box(-hw - 0.015, hw + 0.015, yb - 0.03, yb + 0.24, zr - 0.26, hl, bump, 'D');
  B.box(-hw + 0.3, hw - 0.3, yb - 0.05, yb + 0.07, -hl - 0.025, zf + 0.12, C.dark, 'D');
  B.box(-hw + 0.26, hw - 0.26, yb - 0.06, yb + 0.07, zr - 0.12, hl + 0.025, C.dark, 'D');
  plate(B, 0, yb + 0.12, hl, 1, P.yellowPlate);
  plate(B, 0, yb + 0.1, -hl - 0.025, -1, P.yellowPlate);

  // ── 앞: 그릴 + 헤드라이트 + 앞 깜빡이(옆으로 감김)
  const gw = P.grilleW ?? hw * 0.4;
  const hy1 = hood - 0.05, hy0 = hy1 - (P.headH ?? 0.17);
  B.box(-gw, gw, yb + 0.21, hood - 0.08, zf - 0.03, zf + 0.02, P.grille ?? C.dark);
  for (const s of SIDES) {
    lamp(c, 'head', ...xr(s, gw + 0.05, hw - 0.17), hy0, hy1, zf - 0.04, zf + 0.04);
    // 앞 방향지시등: 모서리를 감싸고 후드 위로 2cm 솟음 → 해방 연출(앞-위 카메라)에서 깜빡임이 보임
    lamp(c, 'hazard', ...xr(s, hw - 0.17, hw + 0.014), hy0, hood + 0.02, zf - 0.04, zf + 0.3, undefined, { top: true, dir: -1 });
  }

  // ── 뒤: 테일램프. 추격캠(≈38° 위)에서 크게 읽히도록 트렁크 윗면까지 감싸 올라감(wrap) + 3cm 솟음.
  //    방향지시등(호박색)은 테일램프 바로 아래 바깥 모서리 (옆으로 감김)
  const ty1 = belt + 0.03, ty0 = belt - (P.tailH ?? 0.27);
  const tail = P.tail ?? 'pair';
  const wrap = Math.max(0.1, Math.min(P.tailWrap ?? 0.3, zr - cab.zb1 - 0.04));
  if (tail !== 'none') {
    // 바깥쪽 = 호박색 방향지시등 세로 띠(윗면까지 감쌈), 안쪽 = 큰 빨간 브레이크등
    const amb = P.tailAmb ?? 0.19, tin = P.tailIn ?? 0.2, tout = hw - amb;
    for (const s of SIDES) {
      if (tail === 'vert') {
        const wz = zr - Math.min(wrap, 0.12);
        lamp(c, 'brake', ...xr(s, hw - (P.tailW ?? 0.5), tout), ty0, ty1, wz, zr + 0.05, undefined, { top: true });
        lamp(c, 'hazard', ...xr(s, tout, hw + 0.014), ty0, ty1, wz - 0.1, zr + 0.05, undefined, { top: true });
      } else {
        lamp(c, 'brake', ...xr(s, tin, tout), ty0, ty1, zr - wrap, zr + 0.05, undefined, { top: true });
        lamp(c, 'hazard', ...xr(s, tout, hw + 0.014), ty0, ty1, zr - wrap, zr + 0.05, undefined, { top: true });
      }
    }
    if (tail === 'bar') lamp(c, 'brake', -tin - 0.005, tin + 0.005, belt - 0.1, ty1 - 0.005, zr - wrap * 0.5, zr + 0.05, undefined, { top: true });
  }
  if (P.hmsl === 'trunk') lamp(c, 'brake', -0.3, 0.3, belt, belt + 0.07, zr - 0.2, zr - 0.04, undefined, { top: true, dir: 1 });

  // ── 바퀴 + 휠하우스
  const wout = wr.out ?? 0.03;
  for (const wz of [wr.zF, wr.zR]) for (const s of SIDES) {
    B.box(...xr(s, hw - 0.04, hw + 0.005), yb - 0.02, Math.min(belt - 0.04, wr.r * 2 + 0.06), wz - wr.r - 0.08, wz + wr.r + 0.08, C.well, 'D');
    if (P.flares) B.box(...xr(s, hw - 0.05, hw + wout + 0.012), wr.r * 2 - 0.05, wr.r * 2 + 0.07, wz - wr.r - 0.14, wz + wr.r + 0.14, P.flareCol ?? C.dark);
  }
  if (P.sill) for (const s of SIDES) B.box(...xr(s, hw - 0.03, hw + 0.012), yb - 0.01, yb + 0.12, wr.zF + wr.r + 0.1, wr.zR - wr.r - 0.1, P.flareCol ?? C.dark, 'D');
  const wx = hw + wout - wr.w / 2;
  addWheel(c, -wx, wr.zF, wr.r, wr.w, wr.o); addWheel(c, wx, wr.zF, wr.r, wr.w, wr.o);
  addWheel(c, -wx, wr.zR, wr.r, wr.w, wr.o); addWheel(c, wx, wr.zR, wr.r, wr.w, wr.o);

  // ── 캐빈 (유리 사다리꼴 + 필러 + 지붕)
  const F = { b: [-hw + cab.inB, hw - cab.inB, cab.zb0, cab.zb1], t: [-hw + cab.inT, hw - cab.inT, cab.zt0, cab.zt1], y0: belt, y1: roofY };
  if (!D) { B.frustum(F, glassCol, 'DU'); if (P.shine !== false) { glassShine(B, F, 'K'); glassShine(B, F, 'F'); } }
  else glassPanels(c.glass, F, P.openLeft, C.glass, P.noRearGlass);
  const Fo = outsetF(F, 0.014);
  const wB = F.b[1] - F.b[0], dB = F.b[3] - F.b[2];
  const pa = P.pillarA ?? 0.08, pc = P.pillarC ?? 0.14, pcz = P.pillarCz ?? 0.12, bv = P.pillarBv ?? 0.48;
  const pcol = P.pillarCol ?? col;
  for (const s of SIDES) {
    const U = (a, b) => (s < 0 ? [a, b] : [1 - b, 1 - a]);
    B.sub(Fo, ...U(0, pa / wB), 0, pa / dB, 0, 1, pcol, 'DU');                 // A
    B.sub(Fo, ...U(0, pc / wB), 1 - pcz / dB, 1, 0, 1, pcol, 'DU');            // C/D
    if (bv > 0) B.sub(Fo, ...U(0, 0.028 / wB), bv - 0.045 / dB, bv + 0.045 / dB, 0, 1, pcol, 'DU'); // B
  }
  B.box(F.t[0] - 0.025, F.t[1] + 0.025, roofY, roofTop, F.t[2] - 0.04, F.t[3] + 0.04, col);
  if (P.hmsl === 'roof') lamp(c, 'brake', -0.32, 0.32, roofTop - 0.012, roofTop + 0.055, F.t[3] - 0.1, F.t[3] + 0.05, undefined, { top: true, dir: 1 });
  if (P.tail === 'vert' && P.dTail !== false) for (const s of SIDES) { // D필러 세로 램프 (해치백/SUV/밴의 큰 "ㄱ"자 테일램프)
    const uw = Math.min(0.32, Math.max(pc + 0.06, 0.3) / wB);
    const U = s < 0 ? [0, uw] : [1 - uw, 1];
    lampSub(c, 'brake', F, U[0], U[1], 1 - (pcz + 0.02) / dB, 1, 0, P.dTailH ?? 0.5);
  }
  // 사이드미러 (뒷면 = 거울색 → 뒤에서 반짝)
  for (const s of SIDES) {
    B.box(...xr(s, F.b[1] - 0.03, hw + 0.15), belt + 0.03, belt + 0.16, cab.zb0 + 0.1, cab.zb0 + 0.27, col, '', { K: C.mirror });
    lamp(c, 'hazard', ...xr(s, hw - 0.01, hw + 0.15), belt + 0.16, belt + 0.2, cab.zb0 + 0.1, cab.zb0 + 0.27, undefined, { core: false }); // 미러 위 리피터
  }

  // ── detailed: 실내 + 운전자
  const sz = lerp(cab.zb0, cab.zb1, P.seatV ?? 0.5);
  if (D) {
    const ix0 = F.b[0] + 0.05, ix1 = F.b[1] - 0.05;
    B.box(ix0, ix1, belt, belt + 0.015, F.b[2] + 0.05, F.b[3] - 0.05, C.interior, 'D');
    B.box(ix0, ix1, belt, belt + 0.13, F.b[2] + 0.02, F.b[2] + 0.32, C.interior, 'D');
    for (const s of SIDES) B.box(...xr(s, 0.07, ix1 - 0.04), belt, belt + 0.24, sz, sz + 0.12, C.seat, 'D');
    if (P.rearSeat !== false && cab.zb1 - sz > 0.7) B.box(ix0 + 0.02, ix1 - 0.02, belt, belt + 0.2, cab.zb1 - 0.34, cab.zb1 - 0.2, C.seat, 'D');
    // 도어 손잡이
    for (const s of SIDES) for (const v of [0.36, 0.66]) {
      const z = lerp(cab.zb0, cab.zb1, v);
      B.box(...xr(s, hw, hw + 0.018), belt - 0.12, belt - 0.08, z, z + 0.14, shade(col, 0.7));
    }
  }
  if (D && P.driver) {
    const dx = -(F.b[1]) * 0.47, dz = sz - 0.1;
    const top = makeDriver(c, P.driver);
    const dy = Math.min(belt + 0.1, roofY - top - 0.02);
    c.driverPos = [dx, dy, dz];
    const shirt = P.driver.shirt ?? 0x4a6fa5;
    B.box(dx - 0.2, dx + 0.2, belt - 0.02, dy + 0.02, dz - 0.1, dz + 0.13, shirt);
    B.box(dx - 0.14, dx + 0.14, belt + 0.1, belt + 0.25, dz - 0.38, dz - 0.34, C.dark); // 핸들
  }
  return { hl, hw, zf, zr, F, Fo, roofTop, sz, hood, cab, wr, yb, belt, roofY, bump };
}

// ── 차종별 ──────────────────────────────────────────────────────────────
function buildCompact(c, p) {
  const ray = p.variant === 1;
  const P = ray
    ? { L: 3.6, W: 1.62, yb: 0.27, hood: 0.8, belt: 0.86, roofY: 1.62, col: p.color,
      cab: { zb0: -0.6, zb1: 1.64, zt0: -0.32, zt1: 1.62, inB: 0.04, inT: 0.08 },
      wheel: { r: 0.33, w: 0.3, zF: -1.17, zR: 1.15, out: 0.04 }, tail: 'vert', tailH: 0.34, hmsl: 'roof', pillarC: 0.12, pillarCz: 0.12, pillarBv: 0.4, dTailH: 0.5 }
    : { L: 3.6, W: 1.66, yb: 0.27, hood: 0.78, belt: 0.84, roofY: 1.45, col: p.color,
      cab: { zb0: -0.72, zb1: 1.62, zt0: -0.1, zt1: 1.44, inB: 0.05, inT: 0.17 },
      wheel: { r: 0.34, w: 0.3, zF: -1.15, zR: 1.13, out: 0.04 }, tail: 'vert', tailH: 0.32, hmsl: 'roof', pillarC: 0.13, pillarCz: 0.13, pillarBv: 0.42 };
  Object.assign(P, p.extraP || {});
  const r = passenger(c, P);
  return { L: P.L, W: P.W, r, exhaust: [0.45, P.yb, r.hl] };
}
function buildSedan(c, p) {
  const v = p.variant;
  const P = { L: 4.6, W: 1.84, yb: 0.3, hood: 0.81, belt: 0.86, roofY: 1.36, col: p.color,
    cab: { zb0: -0.92, zb1: 1.12, zt0: -0.22, zt1: 0.8, inB: 0.06, inT: 0.19 },
    wheel: { r: 0.37, w: 0.32, zF: -1.42, zR: 1.42, out: 0.03 }, tail: v === 1 ? 'bar' : 'pair', hmsl: v === 1 ? 'none' : 'roof',
    pillarC: 0.22, pillarCz: 0.34, pillarBv: 0.47, ...(p.extraP || {}) };
  const r = passenger(c, P);
  const B = c.body;
  if (v === 2) { // 스포티: 트렁크 립 스포일러
    B.box(-r.hw + 0.12, r.hw - 0.12, r.belt + 0.04, r.belt + 0.08, r.zr - 0.2, r.zr + 0.02, shade(p.color, 0.8));
  }
  B.box(-0.04, 0.04, r.roofTop, r.roofTop + 0.06, r.F.t[3] - 0.24, r.F.t[3] - 0.06, C.dark); // 샤크핀 안테나
  return { L: P.L, W: P.W, r, exhaust: [0.5, P.yb, r.hl] };
}
function buildSuv(c, p) {
  const P = { L: 4.7, W: 1.94, yb: 0.4, hood: 0.98, belt: 1.03, roofY: 1.66, col: p.color,
    cab: { zb0: -0.82, zb1: 2.12, zt0: -0.12, zt1: 1.98, inB: 0.06, inT: 0.15 },
    wheel: { r: 0.42, w: 0.36, zF: -1.5, zR: 1.45, out: 0.05 }, tail: 'vert', tailH: 0.3, hmsl: 'roof',
    pillarC: 0.13, pillarCz: 0.14, flares: true, sill: true, bumper: C.dark };
  const r = passenger(c, P);
  const B = c.body;
  // 루프랙
  for (const s of SIDES) {
    B.box(...xr(s, r.F.t[1] - 0.12, r.F.t[1] - 0.05), r.roofTop + 0.05, r.roofTop + 0.1, r.F.t[2] + 0.1, r.F.t[3] - 0.08, C.chromeDark);
    for (const z of [r.F.t[2] + 0.14, r.F.t[3] - 0.14]) B.box(...xr(s, r.F.t[1] - 0.12, r.F.t[1] - 0.05), r.roofTop, r.roofTop + 0.05, z - 0.05, z + 0.05, C.dark);
  }
  if (p.variant === 1) B.box(-0.42, 0.42, r.roofY + 0.01, r.roofTop + 0.008, 0.1, 0.9, C.glass); // 선루프
  return { L: P.L, W: P.W, r, exhaust: [0.55, P.yb, r.hl] };
}
function buildTaxi(c, p) {
  const black = p.variant === 1;
  const res = buildSedan(c, { ...p, variant: 0, color: p.color, extraP: { yellowPlate: true } });
  const r = res.r, B = c.body;
  // 지붕 택시등 (밤엔 헤드라이트와 함께 켜짐)
  const zc = (r.F.t[2] + r.F.t[3]) / 2 + 0.05;
  const sy0 = r.roofTop + 0.02, sy1 = sy0 + 0.22;
  B.box(-0.34, 0.34, r.roofTop, sy0 + 0.005, zc - 0.22, zc + 0.22, C.dark);
  lamp(c, 'head', -0.3, 0.3, sy0, sy1, zc - 0.16, zc + 0.16, black ? 0xf6c21c : 0xf7f3e6, { core: false, col: [black ? 0xffd23a : 0xfff4d6] });
  const rows = textRows('TAXI'), tc = black ? 0x1d1f22 : 0xd8342c;
  pixelArt(B, rows, 'K', 0, (sy0 + sy1) / 2, zc + 0.16 + 0.004, 0.034, tc);
  pixelArt(B, rows, 'F', 0, (sy0 + sy1) / 2, zc - 0.16 - 0.004, 0.034, tc);
  if (!black) for (const s of SIDES) B.box(...xr(s, r.hw, r.hw + 0.008), r.belt - 0.2, r.belt - 0.12, r.zf + 0.3, r.zr - 0.3, 0xf4f4f2); // 흰 띠
  return res;
}
function buildPolice(c, p) {
  const res = buildSedan(c, { ...p, variant: 0, color: C.white });
  const r = res.r, B = c.body;
  const blue = 0x1f4fa3;
  for (const s of SIDES) {
    B.box(...xr(s, r.hw - 0.005, r.hw + 0.009), r.belt - 0.33, r.belt - 0.1, r.zf + 0.12, r.zr - 0.12, blue);
    B.box(...xr(s, r.hw - 0.005, r.hw + 0.009), r.belt - 0.09, r.belt - 0.06, r.zf + 0.12, r.zr - 0.12, 0xb8d82e);
    pixelArt(B, textRows('POLICE'), s < 0 ? 'L' : 'R', s * (r.hw + 0.013), r.belt - 0.215, 0.05, 0.034, 0xffffff);
  }
  B.box(-r.hw + 0.02, r.hw - 0.02, r.hood, r.hood + 0.008, r.zf + 0.05, r.cab.zb0 - 0.05, C.white); // 후드
  pixelArt(B, textRows('112'), 'U', 0, r.belt + 0.006, (r.cab.zb1 + r.zr) / 2 + 0.05, 0.05, blue); // 트렁크 위 "112"
  // 경광등
  const zc = (r.F.t[2] + r.F.t[3]) / 2, y0 = r.roofTop;
  B.box(-0.6, 0.6, y0, y0 + 0.05, zc - 0.17, zc + 0.17, C.dark);
  B.box(-0.05, 0.05, y0 + 0.05, y0 + 0.16, zc - 0.13, zc + 0.13, C.dark);
  c.sirenR = new GB(); c.sirenB = new GB();
  c.sirenR.box(-0.58, -0.05, y0 + 0.05, y0 + 0.18, zc - 0.15, zc + 0.15, 0xffffff);
  c.sirenB.box(0.05, 0.58, y0 + 0.05, y0 + 0.18, zc - 0.15, zc + 0.15, 0xffffff);
  B.box(-0.57, -0.06, y0 + 0.06, y0 + 0.17, zc - 0.14, zc + 0.14, 0x8a1420);
  B.box(0.06, 0.57, y0 + 0.06, y0 + 0.17, zc - 0.14, zc + 0.14, 0x1a3a8a);
  return res;
}
function buildPlayer(c, p) {
  const col = p.color;
  const P = { L: 4.2, W: 1.92, yb: 0.32, hood: 0.84, belt: 0.88, roofY: 1.42, col,
    cab: { zb0: -0.62, zb1: 1.86, zt0: -0.02, zt1: 1.6, inB: 0.07, inT: 0.2 },
    wheel: { r: 0.44, w: 0.4, zF: -1.3, zR: 1.3, out: 0.07, o: { rim: 0xd9dee5, cap: 0xe2231a, hubK: 0.6 } },
    tail: 'pair', tailH: 0.27, tailIn: 0.3, tailAmb: 0.2, hmsl: 'none', bumper: C.dark, flares: true, sill: true,
    pillarC: 0.16, pillarCz: 0.16, pillarBv: 0.46, seatV: 0.36,
    driver: { head: 'hero', shirt: 0xf4f4f2, scale: 1.2 } };
  const r = passenger(c, P);
  const B = c.body, k = 0x1b1c1f;
  // 검은 레이싱 스트라이프 (후드·지붕·트렁크·뒷면)
  for (const s of SIDES) {
    const [x0, x1] = xr(s, 0.11, 0.3);
    B.box(x0, x1, r.hood, r.hood + 0.012, r.zf - 0.005, r.cab.zb0 + 0.05, k);
    B.box(x0, x1, r.roofTop, r.roofTop + 0.012, r.F.t[2] - 0.045, r.F.t[3] + 0.045, k);
    B.box(x0, x1, r.belt, r.belt + 0.012, r.cab.zb1, r.zr + 0.005, k);
    B.box(x0, x1, r.yb + 0.25, r.belt + 0.005, r.zr, r.zr + 0.012, k);
    B.box(x0, x1, r.yb + 0.21, r.hood - 0.06, r.zf - 0.042, r.zf - 0.03, k);
  }
  // 후드 스쿠프
  B.box(-0.2, 0.2, r.hood, r.hood + 0.08, r.zf + 0.32, r.zf + 0.72, k, '', { F: 0x0c0c0e });
  // 루프 스포일러 + 보조 브레이크등
  const zt1 = r.F.t[3];
  B.box(r.F.t[0] - 0.03, r.F.t[1] + 0.03, r.roofTop - 0.01, r.roofTop + 0.06, zt1 - 0.05, zt1 + 0.24, k);
  for (const s of SIDES) B.box(...xr(s, r.F.t[1] - 0.12, r.F.t[1] - 0.06), r.roofY - 0.1, r.roofTop, zt1 + 0.1, zt1 + 0.2, k);
  lamp(c, 'brake', -0.34, 0.34, r.roofTop + 0.0, r.roofTop + 0.07, zt1 + 0.19, zt1 + 0.27, undefined, { top: true });
  // 쌍 머플러 (크롬)
  for (const s of SIDES) B.prism(8, 0.08, 0.08, 0.2, 'z', s * 0.5, r.yb + 0.02, r.hl + 0.03, C.chrome, { capB: 0x111114 });
  // 확성기 (선거유세차 st.) — 지붕 왼쪽 앞, 앞을 향함
  megaphone(B, -0.58, r.roofTop, r.F.t[2] + 0.16);
  // 압정 캐논 (별도 오브젝트: 조준/반동용). 피벗 = 지붕 중앙, 총구 ≈ (0, 1.95, -0.4)
  const cz = (r.F.t[2] + r.F.t[3]) / 2 + 0.05;
  mountCannon(c, r.roofTop, cz, 1.95, -0.4);
  c.ud.beaconPos = [-0.55, r.roofTop + 0.14, r.F.t[3] - 0.3];
  return { L: P.L, W: P.W, r, exhaust: [0.5, P.yb + 0.02, r.hl + 0.14] };
}
// 확성기 (선거유세차 st.): (mx, roofTop, mz) 에 앞(-Z)을 향해
function megaphone(B, mx, roofTop, mz) {
  const my = roofTop + 0.24;
  B.box(mx - 0.03, mx + 0.03, roofTop, my - 0.05, mz + 0.02, mz + 0.08, C.dark);
  B.prism(8, 0.19, 0.065, 0.38, 'z', mx, my, mz - 0.02, 0xf4f4f2, { capA: 0x3a3d44, a0: Math.PI / 8 });
  B.prism(8, 0.198, 0.198, 0.04, 'z', mx, my, mz - 0.2, 0xe2231a, { a0: Math.PI / 8, noA: true, noB: true });
  B.box(mx - 0.07, mx + 0.07, my - 0.07, my + 0.07, mz + 0.17, mz + 0.27, 0x9aa3ad);
}
// 지붕 캐논 장착: 피벗 (0, roofTop, cz), 총구 월드(차량 로컬) 위치 (0, muzzleY, muzzleZ). o: buildCannon 옵션
function mountCannon(c, roofTop, cz, muzzleY, muzzleZ, o) {
  c.cannon = buildCannon(muzzleY - roofTop, muzzleZ - cz, o);
  c.cannonPos = [0, roofTop, cz];
  c.muzzle = [0, muzzleY - roofTop, muzzleZ - cz - 0.02];
}
// 캐논 로컬: 원점 = 지붕 위 피벗, 앞 = -Z. barrelY/muzzleZ: 총구 위치. o.scale: 포탑·드럼 크기 (총구 위치는 그대로)
function buildCannon(barrelY, muzzleZ, o = {}) {
  const s = o.scale ?? 1;
  if (s === 1) return cannonParts(new GB(), barrelY, muzzleZ, o);
  const g = new GB();
  g.with(_m4().makeScale(s, s, s), (q) => cannonParts(q, barrelY / s, muzzleZ / s, o));
  return g;
}
function cannonParts(g, barrelY, muzzleZ, o) {
  const chrome = 0xd7dde5, ring = 0x5b626c, red = o.drum ?? 0xe2231a;
  g.prism(8, 0.3, 0.27, 0.08, 'y', 0, 0.04, 0, 0x34373d, { a0: Math.PI / 8 });           // 회전 링
  g.box(-0.24, 0.24, 0.08, barrelY + 0.13, -0.26, 0.26, chrome, '', { U: 0xeef1f5 });     // 포탑
  g.box(-0.25, 0.25, barrelY - 0.05, barrelY + 0.02, -0.27, 0.27, ring);                   // 띠
  g.box(-0.18, 0.18, 0.12, barrelY - 0.07, 0.262, 0.28, 0x2b2d32);                         // 뒷면 해치
  g.box(-0.08, 0.08, 0.18, 0.26, 0.28, 0.3, 0xffcf3a);                                     // 노란 경고 라벨
  const bl = -muzzleZ - 0.26;
  g.prism(8, 0.1, 0.09, bl, 'z', 0, barrelY, -0.26 - bl / 2, chrome, { a0: Math.PI / 8 }); // 포신
  for (const t of [0.25, 0.6]) g.prism(8, 0.115, 0.115, 0.06, 'z', 0, barrelY, -0.26 - bl * t, ring, { a0: Math.PI / 8 });
  g.prism(8, 0.14, 0.13, 0.16, 'z', 0, barrelY, muzzleZ + 0.08, chrome, { a0: Math.PI / 8, capA: 0x111114 }); // 총구
  // 압정 탄창 드럼 (빨강) + 위에 꽂힌 압정들
  const dy = barrelY + 0.13;
  g.prism(8, 0.19, 0.19, 0.2, 'y', 0, dy + 0.1, 0.04, red, { a0: Math.PI / 8 });
  g.prism(8, 0.2, 0.2, 0.04, 'y', 0, dy + 0.19, 0.04, 0xffffff, { a0: Math.PI / 8 });
  for (let i = 0; i < 6; i++) {
    const a = (i / 6) * Math.PI * 2, x = Math.cos(a) * 0.1, z = 0.04 + Math.sin(a) * 0.1;
    g.box(x - 0.035, x + 0.035, dy + 0.21, dy + 0.235, z - 0.035, z + 0.035, chrome);
    g.box(x - 0.01, x + 0.01, dy + 0.235, dy + 0.3, z - 0.01, z + 0.01, 0x9aa3ad);
  }
  return g;
}
function buildVillainSedan(c, p) { // 정속주행 김사장: 베이지 각그랜저, 크롬, 팔 걸치기
  const col = p.color;
  const P = { L: 4.9, W: 1.84, yb: 0.3, hood: 0.84, belt: 0.86, roofY: 1.38, roofT: 0.08, col,
    cab: { zb0: -0.86, zb1: 1.22, zt0: -0.4, zt1: 0.94, inB: 0.05, inT: 0.11 },
    wheel: { r: 0.36, w: 0.3, zF: -1.56, zR: 1.5, out: 0.02, o: { rim: C.chrome, hubK: 0.68, cap: 0xb8bfc8 } },
    tail: 'none', bumper: C.chrome, grille: C.chrome, grilleW: 0.5, hmsl: 'none', headH: 0.15,
    pillarC: 0.26, pillarCz: 0.32, pillarBv: 0.5, seatV: 0.42, openLeft: true, noRearGlass: true,
    driver: { head: 'boss', shirt: 0xf3a6b8, scale: 1.32 } };
  const r = passenger(c, P);
  const B = c.body, hw = r.hw;
  // 뒷유리 레이스 커튼 (사장님 차 국룰) — 추격캠에서 "흰 주름 커튼 + 아래 물결 레이스" 로 일반 세단과 즉시 구분
  {
    const F = r.F, wB = F.b[1] - F.b[0], dB = F.b[3] - F.b[2];
    const u0 = (P.pillarC - 0.03) / wB, u1 = 1 - u0, vA = 1 - 0.075 / dB, vB = 1 - 0.012 / dB, vC = 1 - 0.035 / dB;
    const n = 10, lace = 0xfbf8ef, fold = 0xe2d8c2;
    for (let i = 0; i < n; i++) {
      const a = lerp(u0, u1, i / n), b = lerp(u0, u1, (i + 1) / n), m = (b - a) * 0.18;
      B.sub(F, a, b, vA, i % 2 ? vC : vB, 0.16, 0.9, i % 2 ? fold : lace);         // 세로 주름 (깊이 교대)
      B.sub(F, a + m, b - m, vA, vB, 0.06, 0.16, lace);                             // 아래 물결 레이스
      B.sub(F, a + (b - a) * 0.4, b - (b - a) * 0.4, vA, vB + 0.004 / dB, 0.36, 0.42, 0xd6c9ad); // 레이스 무늬 점
    }
    B.sub(F, u0, u1, vA, vB + 0.006 / dB, 0.88, 0.99, 0xf3ead6);                   // 위 주름 덮개
    for (const s of SIDES) { // 뒷문 창 커튼 (반쯤 묶음)
      const U = s < 0 ? [0.0, 0.04] : [0.96, 1.0];
      B.sub(F, ...U, 0.56, 0.72, 0.12, 0.94, lace);
    }
  }
  // 레트로 와이드 테일램프 (빨강 큰 블록 + 바깥 호박색) + 사이 크롬 가니시
  const ty0 = r.belt - 0.31, ty1 = r.belt + 0.03;
  for (const s of SIDES) {
    lamp(c, 'brake', ...xr(s, 0.3, hw - 0.25), ty0, ty1, r.zr - 0.24, r.zr + 0.05, undefined, { top: true });
    lamp(c, 'hazard', ...xr(s, hw - 0.25, hw + 0.014), ty0, ty1, r.zr - 0.16, r.zr + 0.05, undefined, { top: true });
  }
  B.box(-0.3, 0.3, ty0 + 0.02, ty1 - 0.04, r.zr, r.zr + 0.04, C.chrome);
  B.box(-0.29, 0.29, ty0 + 0.05, ty1 - 0.07, r.zr + 0.04, r.zr + 0.05, 0x7a1515);
  // 크롬 그릴 가로줄 + 후드 엠블럼 + 크롬 사이드 몰딩 + 창틀 크롬
  for (let i = 0; i < 3; i++) { const y = r.yb + 0.26 + i * 0.08; B.box(-0.48, 0.48, y, y + 0.025, r.zf - 0.05, r.zf - 0.03, 0x8e97a2); }
  B.box(-0.03, 0.03, r.hood, r.hood + 0.07, r.zf + 0.04, r.zf + 0.1, C.chrome);
  for (const s of SIDES) B.box(...xr(s, hw - 0.005, hw + 0.012), r.belt - 0.07, r.belt - 0.035, r.zf + 0.1, r.zr - 0.1, C.chrome);
  B.sub(outsetF(r.F, 0.018), 0, 1, 0, 1, 0, 0.06, C.chrome, 'DU');
  // 휩 안테나 (올드카)
  B.box(hw - 0.14, hw - 0.115, r.belt, r.belt + 0.95, r.zr - 0.34, r.zr - 0.315, 0x1b1b1b);
  // 창밖으로 걸친 왼팔 (detailed)
  if (c.detailed && c.driverPos) {
    const [dx, , dz] = c.driverPos;
    B.box(-hw - 0.1, dx - 0.12, r.belt - 0.02, r.belt + 0.1, dz - 0.2, dz - 0.04, 0xf3a6b8);
    B.box(-hw - 0.16, -hw - 0.04, r.belt - 0.2, r.belt + 0.08, dz - 0.2, dz - 0.05, C.skin);
    B.box(-hw - 0.17, -hw - 0.12, r.belt - 0.12, r.belt - 0.04, dz - 0.19, dz - 0.06, 0xe0b000); // 금시계
  }
  return { L: P.L, W: P.W, r, exhaust: [0.55, P.yb, r.hl] };
}
function buildVillainSuv(c, p) { // 차선물기 대마왕: 너무 넓은 블랙 박스 SUV
  const col = p.color;
  const P = { L: 5.0, W: 2.42, yb: 0.52, hood: 1.16, belt: 1.2, roofY: 1.98, roofT: 0.1, col,
    cab: { zb0: -0.9, zb1: 2.3, zt0: -0.62, zt1: 2.28, inB: 0.07, inT: 0.13 },
    wheel: { r: 0.56, w: 0.5, zF: -1.66, zR: 1.6, out: 0.09, o: { rim: 0xd9a92c, cap: 0x15161a, hubK: 0.62, spokeCol: 0x8a6a14 } },
    tail: 'vert', tailH: 0.42, hmsl: 'roof', glassCol: 0x0c1019, bumper: C.dark, grille: 0x15161a, grilleW: 0.6, headH: 0.2,
    pillarA: 0.1, pillarC: 0.12, pillarCz: 0.12, pillarBv: 0.5, flares: true, sill: true, shine: true, seatV: 0.32,
    driver: { head: 'bro', shirt: 0x111214, scale: 1.3 } };
  const r = passenger(c, P);
  const B = c.body, hw = r.hw;
  // 뒷문 스페어타이어
  const sk = 1 / Math.cos(Math.PI / 8);
  B.prism(8, 0.47 * sk, 0.47 * sk, 0.26, 'z', 0, r.belt - 0.02, r.zr + 0.15, C.tire, { a0: Math.PI / 8, capB: 0x17181b });
  const gold = 0xe6b62e;
  B.prism(8, 0.4 * sk, 0.4 * sk, 0.03, 'z', 0, r.belt - 0.02, r.zr + 0.295, gold, { a0: Math.PI / 8, noA: true });      // 금테 커버
  B.prism(8, 0.34 * sk, 0.34 * sk, 0.03, 'z', 0, r.belt - 0.02, r.zr + 0.305, 0x111214, { a0: Math.PI / 8, noA: true }); // 검정 커버
  pixelArt(B, textRows('VIP'), 'K', 0, r.belt - 0.02, r.zr + 0.322, 0.05, gold);                                         // "VIP" 금박
  B.sub(outsetF(r.F, 0.02), 0, 1, 0, 1, 0, 0.05, C.chrome, 'DU');                                                         // 창 아래 크롬 띠
  // 루프박스 + 레일
  for (const s of SIDES) B.box(...xr(s, r.F.t[1] - 0.14, r.F.t[1] - 0.06), r.roofTop, r.roofTop + 0.09, r.F.t[2] + 0.1, r.F.t[3] - 0.1, C.chromeDark);
  B.frustum({ b: [-0.78, 0.78, 0.05, 2.0], t: [-0.7, 0.7, 0.18, 1.88], y0: r.roofTop + 0.09, y1: r.roofTop + 0.44 }, 0x2a2c31, '', { U: 0x34373d });
  // 루프 LED 바 (밤엔 헤드라이트와 함께)
  B.box(-0.85, 0.85, r.roofTop, r.roofTop + 0.16, r.F.t[2] - 0.04, r.F.t[2] + 0.06, 0x15161a);
  lamp(c, 'head', -0.8, 0.8, r.roofTop + 0.03, r.roofTop + 0.13, r.F.t[2] - 0.065, r.F.t[2] - 0.02);
  // 불바 (크롬)
  for (const s of SIDES) B.box(...xr(s, 0.42, 0.5), r.yb - 0.05, r.hood + 0.03, r.zf - 0.22, r.zf - 0.14, C.chrome);
  B.box(-0.62, 0.62, r.hood - 0.06, r.hood + 0.03, r.zf - 0.24, r.zf - 0.12, C.chrome);
  B.box(-0.62, 0.62, r.yb + 0.08, r.yb + 0.15, r.zf - 0.24, r.zf - 0.12, C.chrome);
  // 사이드 스텝 + 쌍 머플러
  for (const s of SIDES) B.box(...xr(s, hw - 0.04, hw + 0.14), r.yb - 0.12, r.yb - 0.04, P.wheel.zF + 0.65, P.wheel.zR - 0.65, C.chrome);
  for (const x of [0.62, 0.8]) B.prism(8, 0.07, 0.07, 0.18, 'z', x, r.yb - 0.02, r.hl + 0.02, C.chrome, { capB: 0x111114 });
  if (c.detailed) B.box(-0.6 - 0.16, -0.6 + 0.16, r.belt + 0.02, r.belt + 0.05, r.sz - 0.2, r.sz + 0.03, 0xe0b000); // 금목걸이
  return { L: 5.45, W: P.W, r, tint: true, exhaust: [0.7, P.yb, r.hl] }; // 길이 = 불바(앞 +0.24) + 스페어(뒤 +0.3) 포함
}
function buildVillainPhone(c, p) { // 숏폼중독 드라이버: 핫핑크 경차 + 거치대 폰 + 손에 든 폰
  const P = { L: 3.7, W: 1.68, yb: 0.27, hood: 0.78, belt: 0.84, roofY: 1.46, col: p.color,
    cab: { zb0: -0.72, zb1: 1.68, zt0: -0.1, zt1: 1.5, inB: 0.05, inT: 0.17 },
    wheel: { r: 0.34, w: 0.3, zF: -1.18, zR: 1.16, out: 0.04, o: { rim: 0xffffff, cap: 0xff6fb0 } }, tail: 'vert', tailH: 0.32, hmsl: 'roof',
    pillarC: 0.13, pillarCz: 0.13, pillarBv: 0.42, seatV: 0.36, driver: { head: 'phone', shirt: 0x7b5cd6, scale: 1.3 } };
  const r = passenger(c, P);
  const B = c.body;
  const screen = (g, x0, x1, y0, y1, z0, z1) => { // 위 시안 → 아래 핑크
    const ym = (y0 + y1) / 2;
    g.box(x0, x1, ym, y1, z0, z1, 0x6ff6ff); g.box(x0, x1, y0, ym, z0, z1, 0xff7ad0);
  };
  const scr = c.detailed ? c.glow : B;
  // 대시보드 거치대 폰 (뒤를 향해 화면 → 뒷유리 너머로 빛남)
  const hz = r.cab.zb0 + 0.3, hy = r.belt + 0.24;
  B.box(-0.03, 0.03, r.belt + 0.1, hy - 0.16, hz - 0.03, hz + 0.03, C.dark);
  B.box(-0.17, 0.17, hy - 0.2, hy + 0.2, hz, hz + 0.04, 0x15161a);
  screen(scr, -0.15, 0.15, hy - 0.18, hy + 0.18, hz + 0.04, hz + 0.05);
  // 손에 든 폰 (운전자 얼굴 앞, 아래)
  if (c.detailed && c.driverPos) {
    const [dx, dy, dz] = c.driverPos;
    const px = dx + 0.03, py = dy + 0.02, pz = dz - 0.3;
    B.box(px - 0.08, px + 0.08, py - 0.13, py + 0.13, pz - 0.02, pz + 0.01, 0x15161a);
    screen(c.glow, px - 0.065, px + 0.065, py - 0.11, py + 0.11, pz + 0.01, pz + 0.02);
    B.box(px - 0.12, px + 0.12, py - 0.17, py - 0.07, pz - 0.04, pz + 0.06, C.skin); // 손
  }
  // 뒷면 하트 스티커
  pixelArt(B, ['.#.#.', '#####', '#####', '.###.', '..#..'], 'K', 0, r.belt - 0.13, r.zr + 0.004, 0.035, 0xffffff);
  return { L: P.L, W: P.W, r, glass: 'screen', exhaust: [0.45, P.yb, r.hl] }; // 유리 = 폰 화면빛 (밤 스테이지에서 실내가 시안으로 빛남)
}
function buildVan(c, p) {
  if (p.variant === 1) return buildBoxTruck(c, p);
  const P = { L: 5.1, W: 1.92, yb: 0.36, hood: 0.95, belt: 1.0, roofY: 1.86, col: p.color,
    cab: { zb0: -1.62, zb1: 2.45, zt0: -1.06, zt1: 2.4, inB: 0.04, inT: 0.1 },
    wheel: { r: 0.38, w: 0.34, zF: -1.75, zR: 1.6, out: 0.03 }, tail: 'vert', tailH: 0.32, hmsl: 'roof',
    pillarC: 0.12, pillarCz: 0.12, pillarBv: 0.3, headH: 0.16 };
  const r = passenger(c, P);
  const B = c.body;
  // 슬라이딩 도어 레일 + 추가 필러
  B.box(r.hw - 0.002, r.hw + 0.01, r.belt + 0.02, r.belt + 0.05, 0.2, 1.6, C.dark);
  for (const s of SIDES) B.sub(r.Fo, ...(s < 0 ? [0, 0.028 / (r.F.b[1] - r.F.b[0])] : [1 - 0.028 / (r.F.b[1] - r.F.b[0]), 1]), 0.62, 0.64, 0, 1, p.color, 'DU');
  return { L: P.L, W: P.W, r, exhaust: [0.5, P.yb, r.hl] };
}

// ── 포터(1톤) 캡 — pickup1t / 택배 탑차 공용. 반환: 캡 뒤 z
function porterCab(c, col, hl, hw, opts = {}) {
  const B = c.body, D = c.detailed;
  const zF = -hl, zB = -hl + 1.62, yb = 0.7, belt = 1.14, roofY = 1.9;
  const wzF = -hl + 0.82;
  // 하부 (앞바퀴 휠하우스 포함)
  const wr = opts.wr ?? 0.33, ww = opts.ww ?? 0.28; // 바퀴 (플레이어 변형은 더 큼직하게)
  skirt(B, -hw, hw, 0.38, yb, zF + 0.06, zB, [wzF], wr, col);
  B.box(-hw, hw, yb, belt, zF + 0.06, zB, col, 'D');
  // 범퍼 + 그릴 + 헤드라이트 (포터 얼굴: 아래 모서리 큰 사각 라이트 + 검은 그릴 띠)
  B.box(-hw - 0.02, hw + 0.02, 0.32, 0.56, zF - 0.04, zF + 0.3, C.dark, 'D');
  B.box(-0.5, 0.5, 0.6, 0.86, zF + 0.02, zF + 0.08, 0x1a1b1e);
  for (let i = 0; i < 3; i++) B.box(-0.46, 0.46, 0.64 + i * 0.07, 0.66 + i * 0.07, zF, zF + 0.02, 0x4a4e55);
  B.box(-0.07, 0.07, 0.95, 1.03, zF + 0.035, zF + 0.065, C.chrome); // 엠블럼
  for (const s of SIDES) {
    lamp(c, 'head', ...xr(s, 0.52, hw - 0.1), 0.6, 0.86, zF + 0.02, zF + 0.1);
    lamp(c, 'hazard', ...xr(s, hw - 0.1, hw + 0.014), 0.6, 0.86, zF + 0.02, zF + 0.25);
  }
  plate(B, 0, 0.44, zF - 0.04, -1, opts.yellowPlate);
  // 캐빈
  const F = { b: [-hw + 0.03, hw - 0.03, zF + 0.1, zB - 0.02], t: [-hw + 0.08, hw - 0.08, zF + 0.32, zB - 0.02], y0: belt, y1: roofY };
  if (!D) { B.frustum(F, C.glass, 'DU'); glassShine(B, F, 'F'); } else glassPanels(c.glass, F, false);
  const Fo = outsetF(F, 0.014), wB = F.b[1] - F.b[0], dB = F.b[3] - F.b[2];
  for (const s of SIDES) {
    const U = (a, b) => (s < 0 ? [a, b] : [1 - b, 1 - a]);
    B.sub(Fo, ...U(0, 0.08 / wB), 0, 0.09 / dB, 0, 1, col, 'DU');
    B.sub(Fo, ...U(0, 0.03 / wB), 0.62, 0.68, 0, 1, col, 'DU');
  }
  B.sub(Fo, 0, 1, 0.72, 1, 0, 1, col, 'DU');                                        // 캡 뒷벽(작은 뒷창)
  B.sub(outsetF(F, 0.02), 0.28, 0.72, 0.99, 1, 0.35, 0.85, C.glass, 'DU');
  B.box(F.t[0] - 0.02, F.t[1] + 0.02, roofY, roofY + 0.09, F.t[2] - 0.04, F.t[3] + 0.02, col);
  for (const s of SIDES) {
    B.beam([s * (hw - 0.02), belt + 0.18, zF + 0.4], [s * (hw + 0.18), belt + 0.3, zF + 0.32], 0.035, 0.035, C.dark);
    B.box(...xr(s, hw + 0.12, hw + 0.22), belt + 0.12, belt + 0.42, zF + 0.27, zF + 0.36, C.dark, '', { K: C.mirror });
  }
  if (D && opts.driver) {
    const top = makeDriver(c, opts.driver);
    const dx = -hw * 0.45, dz = zF + 0.85, dy = Math.min(belt + 0.1, roofY - top - 0.02);
    c.driverPos = [dx, dy, dz];
    B.box(dx - 0.2, dx + 0.2, belt - 0.02, dy + 0.02, dz - 0.1, dz + 0.13, opts.driver.shirt ?? 0x4a6fa5);
  }
  addWheel(c, -(hw - 0.12), wzF, wr, ww, opts.wo); addWheel(c, hw - 0.12, wzF, wr, ww, opts.wo);
  return zB;
}
function buildPorter(c, p) {
  const col = p.color, hl = 2.45, hw = 0.89, B = c.body, v = p.variant;
  const zB = porterCab(c, col, hl, hw);
  const deckY = 0.82, gateY = 1.22, z0 = zB + 0.06, z1 = hl;
  // 프레임 + 적재함
  B.box(-0.42, 0.42, 0.42, 0.72, zB, hl - 0.05, C.under, 'D');
  B.box(-hw, hw, 0.72, deckY, z0, z1, 0x7b818a, 'D');
  const gate = 0xc9ced4, rib = 0x9aa1aa;
  for (const s of SIDES) {
    B.box(...xr(s, hw - 0.04, hw), deckY, gateY, z0, z1, gate);
    for (const z of [z0 + 0.8, z0 + 1.6, z0 + 2.4]) B.box(...xr(s, hw, hw + 0.012), deckY, gateY, z - 0.03, z + 0.03, rib);
  }
  B.box(-hw, hw, deckY, gateY + 0.22, z0, z0 + 0.05, gate);                  // 앞 헤드보드
  for (const x of [-0.6, -0.2, 0.2, 0.6]) B.box(x - 0.03, x + 0.03, gateY, gateY + 0.22, z0 - 0.01, z0 + 0.06, rib);
  B.box(-hw, hw, deckY, gateY, z1 - 0.04, z1, gate, '', { K: 0xd6dade });     // 뒷문
  for (const s of SIDES) B.box(...xr(s, 0.2, 0.24), deckY + 0.06, gateY - 0.06, z1, z1 + 0.015, rib);
  // 뒷램프 (적재함 아래 모서리) + 범퍼 + 번호판
  B.box(-hw, hw, 0.28, 0.4, z1 - 0.12, z1 + 0.02, C.dark);
  B.box(-hw + 0.02, hw - 0.02, 0.4, 0.8, z1 - 0.1, z1 - 0.04, C.dark); // 램프 받침
  for (const s of SIDES) {
    lamp(c, 'brake', ...xr(s, 0.34, hw - 0.17), 0.41, 0.81, z1 - 0.06, z1 + 0.04);
    lamp(c, 'hazard', ...xr(s, hw - 0.17, hw + 0.012), 0.41, 0.81, z1 - 0.06, z1 + 0.04);
  }
  plate(B, 0, 0.58, z1 - 0.04, 1, false);
  // 짐 (변형)
  const cy = deckY;
  if (v === 0) { // 택배 상자
    const box = 0xc8955a, tape = 0xe8d6a8;
    const bx = [[-0.75, -0.05, z0 + 0.1, z0 + 0.8, 0.5], [0.0, 0.78, z0 + 0.1, z0 + 0.7, 0.42], [-0.7, 0.1, z0 + 0.9, z0 + 1.5, 0.38], [0.15, 0.8, z0 + 0.85, z0 + 1.65, 0.55], [-0.55, 0.25, z0 + 0.15, z0 + 0.7, 0.3, 0.5]];
    for (const [x0, x1, za, zb, h, yo = 0] of bx) {
      B.box(x0, x1, cy + yo, cy + yo + h, za, zb, box, 'D');
      B.box((x0 + x1) / 2 - 0.05, (x0 + x1) / 2 + 0.05, cy + yo + h, cy + yo + h + 0.006, za, zb, tape);
    }
  } else if (v === 1) { // 배추
    const g1 = 0x5fae3e, g2 = 0xcfe8a0, rnd = rng32(77);
    for (let i = 0; i < 4; i++) for (let j = 0; j < 6; j++) {
      const x = -0.62 + i * 0.41 + (rnd() - 0.5) * 0.06, z = z0 + 0.3 + j * 0.4, y = cy + 0.02 + (rnd() * 0.08);
      B.box(x - 0.17, x + 0.17, y, y + 0.32, z - 0.17, z + 0.17, g1, 'D', { U: g2 });
      B.box(x - 0.1, x + 0.1, y + 0.32, y + 0.38, z - 0.1, z + 0.1, 0x7cc455);
    }
  } else { // 파란 방수포 + 고무줄
    const tarp = 0x2f6fd6;
    B.frustum({ b: [-hw + 0.06, hw - 0.06, z0 + 0.08, z1 - 0.08], t: [-hw + 0.3, hw - 0.3, z0 + 0.35, z1 - 0.3], y0: cy, y1: cy + 0.75 }, tarp, 'D', { U: 0x3d7fe6 });
    for (const t of [0.2, 0.5, 0.8]) B.sub({ b: [-hw + 0.04, hw - 0.04, z0 + 0.06, z1 - 0.06], t: [-hw + 0.28, hw - 0.28, z0 + 0.33, z1 - 0.28], y0: cy, y1: cy + 0.77 }, 0, 1, t - 0.012, t + 0.012, 0, 1, 0x1c1d21, 'D');
  }
  addWheel(c, -(hw - 0.2), 1.35, 0.33, 0.42); addWheel(c, hw - 0.2, 1.35, 0.33, 0.42);
  return { L: hl * 2, W: hw * 2, exhaust: [0.5, 0.4, hl] };
}
function buildBoxTruck(c, p) { // 택배 탑차 (흰 박스 + 초록 띠)
  const hl = 2.6, hw = 0.92, B = c.body;
  const zB = porterCab(c, p.color, hl, 0.89);
  const y0 = 0.74, y1 = 2.62, z0 = zB + 0.06, z1 = hl;
  B.box(-0.42, 0.42, 0.42, y0, zB, hl - 0.05, C.under, 'D');
  B.box(-hw, hw, y0, y1, z0, z1, 0xf2f3f4, 'D', { U: 0xe6e8ea });
  const green = 0x1f9a4b;
  for (const s of SIDES) {
    B.box(...xr(s, hw, hw + 0.01), 1.32, 1.56, z0 + 0.05, z1 - 0.05, green);
    B.box(...xr(s, hw, hw + 0.01), 1.6, 1.66, z0 + 0.05, z1 - 0.05, 0xf6c21c);
  }
  B.box(-hw - 0.02, hw + 0.02, y1 - 0.06, y1, z0 - 0.02, z1 + 0.02, 0xa9b0b8, 'D');
  B.box(-hw + 0.04, hw - 0.04, y0 + 0.06, y1 - 0.08, z1, z1 + 0.02, 0xe9ebed);
  B.box(-0.01, 0.01, y0 + 0.06, y1 - 0.08, z1 + 0.02, z1 + 0.03, 0x8e97a2);
  for (const x of [-0.45, 0.45]) B.box(x - 0.025, x + 0.025, y0 + 0.1, y1 - 0.12, z1 + 0.02, z1 + 0.05, 0x7b818a);
  B.box(-hw + 0.04, hw - 0.04, 1.32, 1.56, z1 + 0.02, z1 + 0.03, green);
  B.box(-hw, hw, 0.28, 0.4, z1 - 0.12, z1 + 0.02, C.dark);
  B.box(-hw + 0.02, hw - 0.02, 0.4, 0.74, z1 - 0.1, z1 - 0.01, C.dark);
  for (const s of SIDES) {
    lamp(c, 'brake', ...xr(s, 0.34, hw - 0.17), 0.41, 0.73, z1 - 0.03, z1 + 0.06);
    lamp(c, 'hazard', ...xr(s, hw - 0.17, hw + 0.012), 0.41, 0.73, z1 - 0.03, z1 + 0.06);
    // 박스 위 뒤 모서리 차폭등 (빨강) + 안쪽 호박색 — 높은 추격캠에서 멀리서도 보임
    lamp(c, 'brake', ...xr(s, hw - 0.28, hw + 0.02), y1 - 0.2, y1 + 0.035, z1 - 0.16, z1 + 0.06, undefined, { top: true });
    lamp(c, 'hazard', ...xr(s, hw - 0.48, hw - 0.3), y1 - 0.12, y1 + 0.035, z1 - 0.1, z1 + 0.06, undefined, { top: true });
  }
  plate(B, 0, 0.58, z1 + 0.0, 1, true);
  addWheel(c, -(hw - 0.22), 1.45, 0.34, 0.44); addWheel(c, hw - 0.22, 1.45, 0.34, 0.44);
  return { L: hl * 2, W: hw * 2, exhaust: [0.5, 0.4, hl] };
}

// ── 25톤 트럭 캡 (truck / villainTruck 공용)
function truckCab(c, col, hl, opts = {}) {
  const B = c.body, D = c.detailed;
  const hw = 1.24, zF = -hl, zB = -hl + 2.1, y0 = 1.06, belt = 1.95, roofY = 2.86;
  const wz = -hl + 0.92, r = 0.52;
  // 하부 에이프런 + 스텝 + 휠하우스
  skirt(B, -hw, hw, 0.44, y0, zF + 0.04, zB, [wz], r, shade(col, 0.88));
  B.box(-hw - 0.02, hw + 0.02, 0.42, 0.74, zF - 0.06, zF + 0.3, C.dark, 'D');
  for (const s of SIDES) B.box(...xr(s, hw - 0.1, hw + 0.01), 0.62, 0.68, wz + r + 0.18, zB - 0.06, 0x9aa1aa);
  // 캡 본체 + 그릴
  B.box(-hw, hw, y0, belt, zF, zB, col, 'D');
  B.box(-0.95, 0.95, y0 + 0.1, belt - 0.1, zF - 0.03, zF + 0.02, 0x1a1b1e);
  for (let i = 0; i < 4; i++) B.box(-0.9, 0.9, y0 + 0.16 + i * 0.17, y0 + 0.2 + i * 0.17, zF - 0.05, zF - 0.03, C.chrome);
  B.box(-0.12, 0.12, belt - 0.07, belt + 0.02, zF - 0.06, zF - 0.02, C.chrome);
  for (const s of SIDES) {
    lamp(c, 'head', ...xr(s, 0.62, hw - 0.12), 0.76, 0.98, zF - 0.06, zF + 0.04);
    lamp(c, 'hazard', ...xr(s, hw - 0.12, hw + 0.03), 0.76, 0.98, zF - 0.06, zF + 0.22);
  }
  plate(B, 0, 0.6, zF - 0.07, -1, opts.yellowPlate !== false);
  // 유리 + 필러 + 지붕 + 디플렉터 + 썬바이저
  const F = { b: [-hw + 0.03, hw - 0.03, zF + 0.02, zB - 0.02], t: [-hw + 0.08, hw - 0.08, zF + 0.16, zB - 0.02], y0: belt, y1: roofY };
  if (!D) { B.frustum(F, C.glass, 'DU'); glassShine(B, F, 'F'); } else glassPanels(c.glass, F, false);
  const Fo = outsetF(F, 0.014), wB = F.b[1] - F.b[0], dB = F.b[3] - F.b[2];
  for (const s of SIDES) {
    const U = (a, b) => (s < 0 ? [a, b] : [1 - b, 1 - a]);
    B.sub(Fo, ...U(0, 0.1 / wB), 0, 0.12 / dB, 0, 1, col, 'DU');
    B.sub(Fo, ...U(0, 0.03 / wB), 0.55, 0.6, 0, 1, col, 'DU');
  }
  B.sub(Fo, 0, 1, 0.66, 1, 0, 1, col, 'DU');
  B.box(F.t[0] - 0.03, F.t[1] + 0.03, roofY, roofY + 0.12, F.t[2] - 0.05, F.t[3] + 0.02, col);
  B.frustum({ b: [-hw + 0.1, hw - 0.1, F.t[2] + 0.3, zB - 0.04], t: [-hw + 0.22, hw - 0.22, zB - 0.6, zB - 0.04], y0: roofY + 0.12, y1: 3.5 }, shade(col, 0.95), 'D');
  B.box(F.t[0] + 0.02, F.t[1] - 0.02, roofY - 0.05, roofY + 0.03, F.t[2] - 0.24, F.t[2], C.dark);
  for (let i = 0; i < 5; i++) { const x = -0.6 + i * 0.3; lamp(c, 'hazard', x - 0.05, x + 0.05, roofY + 0.05, roofY + 0.11, F.t[2] - 0.08, F.t[2] - 0.02); }
  // 큰 미러 (팔 + 거울)
  for (const s of SIDES) {
    B.box(...xr(s, hw - 0.02, hw + 0.24), 2.34, 2.38, zF + 0.24, zF + 0.29, C.dark);
    B.box(...xr(s, hw + 0.16, hw + 0.27), 1.72, 2.42, zF + 0.2, zF + 0.32, C.dark, '', { K: C.mirror });
  }
  if (D && opts.driver) {
    const top = makeDriver(c, opts.driver);
    const dx = -hw * 0.5, dz = zF + 0.95, dy = Math.min(belt + 0.12, roofY - top - 0.04);
    c.driverPos = [dx, dy, dz];
    B.box(dx - 0.22, dx + 0.22, belt - 0.02, dy + 0.02, dz - 0.1, dz + 0.14, opts.driver.shirt ?? 0x4a6fa5);
    B.box(F.b[0] + 0.05, F.b[1] - 0.05, belt, belt + 0.14, F.b[2] + 0.02, F.b[2] + 0.36, C.interior);
    B.box(dx - 0.16, dx + 0.16, belt + 0.12, belt + 0.3, dz - 0.4, dz - 0.36, C.dark);
  }
  addWheel(c, -(hw - 0.22), wz, r, 0.42); addWheel(c, hw - 0.22, wz, r, 0.42);
  return { zB, hw };
}
// 트럭 공통 섀시 / 뒤 범퍼 / 뒤 바퀴
function truckRear(c, hl, hw, axles, { plateYellow = true } = {}) {
  const B = c.body, r = 0.52;
  B.box(-0.5, 0.5, 0.62, 1.12, -hl + 2.0, hl - 0.1, C.under, 'D');
  // 연료탱크 + 측면 가드
  B.prism(8, 0.26, 0.26, 0.9, 'z', -hw + 0.32, 0.72, -hl + 2.85, 0xc6ccd4, { a0: Math.PI / 8 });
  for (const s of SIDES) for (const y of [0.56, 0.82]) B.box(...xr(s, hw - 0.1, hw - 0.02), y, y + 0.07, -hl + 3.4, axles[0] - r - 0.14, 0x9aa1aa);
  // 뒤 램프바
  B.box(-hw + 0.04, hw - 0.04, 0.58, 0.98, hl - 0.14, hl - 0.04, C.dark);
  for (const s of SIDES) {
    lamp(c, 'brake', ...xr(s, 0.3, 0.98), 0.61, 0.95, hl - 0.06, hl + 0.04);
    lamp(c, 'hazard', ...xr(s, 0.98, hw - 0.04), 0.61, 0.95, hl - 0.06, hl + 0.04);
    B.box(...xr(s, 0.82, 1.2), 0.12, 0.66, hl - 0.34, hl - 0.28, 0x111214); // 흙받이
  }
  plate(B, 0, 0.75, hl - 0.06, 1, plateYellow);
  // 반사띠 (빨강/흰 교대)
  for (let i = 0; i < 10; i++) {
    const x = -hw + 0.06 + i * ((hw * 2 - 0.12) / 10);
    B.box(x, x + (hw * 2 - 0.12) / 10, 0.52, 0.58, hl - 0.06, hl - 0.02, i % 2 ? 0xf4f4f2 : 0xd8342c);
  }
  for (const z of axles) for (const s of SIDES) B.box(...xr(s, hw - 0.6, hw - 0.04), 0.3, 1.12, z - r - 0.1, z + r + 0.1, C.well, 'D');
  for (const z of axles) { addWheel(c, -(hw - 0.33), z, r, 0.62); addWheel(c, hw - 0.33, z, r, 0.62); }
}
function buildTruck(c, p) {
  const hl = 4.75, B = c.body;
  const { zB, hw } = truckCab(c, p.color, hl);
  const axles = [hl - 2.3, hl - 1.05];
  truckRear(c, hl, hw + 0.01, axles);
  const z0 = zB + 0.12, z1 = hl - 0.03, bw = 1.25;
  if (p.variant === 0) { // 윙바디 박스
    const y0 = 1.14, y1 = 3.6, wht = 0xf0f2f4, rail = 0xa9b0b8;
    B.box(-bw, bw, y0, y1, z0, z1, wht, 'D', { U: 0xe4e7ea });
    B.box(-bw - 0.02, bw + 0.02, y1 - 0.14, y1, z0 - 0.02, z1 + 0.02, rail, 'D');
    B.box(-bw - 0.02, bw + 0.02, y0, y0 + 0.16, z0 - 0.02, z1 + 0.02, rail, 'D');
    for (const s of SIDES) for (let z = z0 + 1.3; z < z1 - 0.5; z += 1.3) B.box(...xr(s, bw, bw + 0.015), y0 + 0.16, y1 - 0.14, z - 0.04, z + 0.04, 0xd3d7dc);
    // 뒷문: 테두리 + 세로 잠금봉 4개 + 반사띠
    B.box(-bw + 0.06, bw - 0.06, y0 + 0.18, y1 - 0.16, z1 + 0.02, z1 + 0.04, 0xe6e9ec);
    B.box(-0.012, 0.012, y0 + 0.18, y1 - 0.16, z1 + 0.04, z1 + 0.05, 0x8e97a2);
    for (const x of [-0.85, -0.35, 0.35, 0.85]) {
      B.box(x - 0.025, x + 0.025, y0 + 0.2, y1 - 0.2, z1 + 0.04, z1 + 0.08, 0x7b818a);
      B.box(x - 0.03, x + 0.1, y0 + 0.9, y0 + 0.96, z1 + 0.04, z1 + 0.1, 0x5b626c);
    }
    for (let i = 0; i < 8; i++) {
      const x = -bw + 0.1 + i * ((bw * 2 - 0.2) / 8);
      B.box(x, x + (bw * 2 - 0.2) / 8, y0 + 0.2, y0 + 0.3, z1 + 0.04, z1 + 0.055, i % 2 ? 0xf4f4f2 : 0xd8342c);
    }
    for (const s of SIDES) for (let i = 0; i < 6; i++) {
      const z = z0 + 0.4 + i * 1.1;
      B.box(...xr(s, bw + 0.015, bw + 0.025), y0 + 0.03, y0 + 0.12, z, z + 0.5, i % 2 ? 0xf4f4f2 : 0xd8342c);
    }
    // 박스 위 뒤 모서리 차폭등 (빨강, 윗면까지) + 안쪽 호박색 → 정체 속 25톤이 멀리서도 "빨간 눈"으로 읽힘
    for (const s of SIDES) {
      lamp(c, 'brake', ...xr(s, bw - 0.34, bw + 0.025), y1 - 0.28, y1 + 0.035, z1 - 0.22, z1 + 0.08, undefined, { top: true });
      lamp(c, 'hazard', ...xr(s, bw - 0.6, bw - 0.38), y1 - 0.16, y1 + 0.035, z1 - 0.12, z1 + 0.08, undefined, { top: true });
    }
  } else { // 카고 + 국방색 천막
    const deck = 1.14;
    B.box(-bw, bw, deck, deck + 0.14, z0, z1, 0x5b626c, 'D');
    for (const s of SIDES) B.box(...xr(s, bw - 0.05, bw), deck + 0.14, deck + 0.7, z0, z1, 0xc9ced4);
    B.box(-bw, bw, deck + 0.14, deck + 0.7, z1 - 0.05, z1, 0xc9ced4);
    const tarp = 0x6b7a3a;
    B.box(-bw + 0.03, bw - 0.03, deck + 0.7, 3.1, z0 + 0.04, z1 - 0.06, tarp, 'D', { U: 0x768545 });
    B.frustum({ b: [-bw + 0.03, bw - 0.03, z0 + 0.04, z1 - 0.06], t: [-bw + 0.4, bw - 0.4, z0 + 0.04, z1 - 0.06], y0: 3.1, y1: 3.4 }, 0x768545, 'D');
    for (let z = z0 + 0.7; z < z1 - 0.3; z += 1.2) B.box(-bw + 0.01, bw - 0.01, deck + 0.7, 3.12, z - 0.03, z + 0.03, 0x3d4422, 'D');
    for (const s of SIDES) lamp(c, 'brake', ...xr(s, bw - 0.3, bw + 0.025), deck + 0.48, deck + 0.72, z1 - 0.08, z1 + 0.06);
  }
  return { L: hl * 2, W: 2.5, exhaust: [-hw + 0.2, 2.6, zB - 0.1] };
}
function buildVillainTruck(c, p) { // 화물차 나란히: 25톤 카고 + 수박 가득
  const hl = 4.75, B = c.body, v = p.variant;
  const { zB, hw } = truckCab(c, p.color, hl, { driver: v === 0 ? { head: 'trucker', cap: 0xd8342c, shirt: 0x3a6e3a, scale: 1.35 } : { head: 'trucker', towel: true, shirt: 0x2f4f8f, scale: 1.35 } });
  const axles = [hl - 2.3, hl - 1.05];
  truckRear(c, hl, hw + 0.01, axles);
  const z0 = zB + 0.12, z1 = hl - 0.03, bw = 1.25, deck = 1.14, gy = deck + 0.82;
  const gate = 0xd1d6dc, rib = 0xa3abb4;
  B.box(-bw, bw, deck, deck + 0.14, z0, z1, 0x5b626c, 'D');
  for (const s of SIDES) {
    B.box(...xr(s, bw - 0.05, bw), deck + 0.14, gy, z0, z1, gate);
    B.box(...xr(s, bw - 0.06, bw + 0.02), gy - 0.06, gy, z0, z1, 0xe8ebee);
    for (let z = z0 + 0.6; z < z1 - 0.2; z += 0.75) B.box(...xr(s, bw, bw + 0.015), deck + 0.16, gy - 0.07, z - 0.03, z + 0.03, rib);
  }
  B.box(-bw, bw, deck + 0.14, gy + 0.65, z0, z0 + 0.08, gate);           // 헤드보드 (높음)
  for (const x of [-0.9, -0.45, 0, 0.45, 0.9]) B.box(x - 0.03, x + 0.03, gy, gy + 0.65, z0 + 0.08, z0 + 0.1, rib);
  B.box(-bw, bw, deck + 0.14, gy, z1 - 0.06, z1, gate, '', { K: 0xdde1e5 }); // 뒷문
  for (const s of SIDES) { // 뒷문 기둥 위 차폭등 (급정거 체크 때 위에서도 번쩍)
    B.box(...xr(s, bw - 0.22, bw + 0.02), gy - 0.02, gy + 0.02, z1 - 0.24, z1 + 0.02, C.dark);
    lamp(c, 'brake', ...xr(s, bw - 0.21, bw + 0.01), gy + 0.02, gy + 0.2, z1 - 0.22, z1 + 0.04, undefined, { top: true });
  }
  // 수박 더미: 채움 + 위층 수박들
  B.box(-bw + 0.06, bw - 0.06, deck + 0.14, gy - 0.12, z0 + 0.1, z1 - 0.08, 0x2a6a2e, 'DKF');
  const rnd = rng32(1234 + v * 99);
  const melon = (x, y, z, s = 1) => B.at(x, y, z, 0, rnd() * Math.PI, (rnd() - 0.5) * 0.4, 1, (g) => melonParts(g, 0.3 * s, 0.27 * s, 0.33 * s, 8, 5));
  for (let i = 0; i < 4; i++) for (let j = 0; j < 10; j++) {
    melon(-0.85 + i * 0.57 + (rnd() - 0.5) * 0.08, gy - 0.12 + 0.2 + rnd() * 0.05, z0 + 0.42 + j * 0.645 + (rnd() - 0.5) * 0.1);
  }
  for (let i = 0; i < 3; i++) for (let j = 0; j < 8; j++) {
    melon(-0.57 + i * 0.57 + (rnd() - 0.5) * 0.1, gy - 0.12 + 0.62, z0 + 0.75 + j * 0.7 + (rnd() - 0.5) * 0.12);
  }
  for (let j = 0; j < 4; j++) melon((rnd() - 0.5) * 0.3, gy - 0.12 + 1.0, z0 + 1.4 + j * 1.2);
  // 뒷문 "꿀수박" 간판 (detailed 만, 캔버스 텍스처)
  c.signs.push({ key: 'melon', w: 2.2, h: 0.62, pos: [0, (deck + 0.14 + gy) / 2 + 0.02, z1 + 0.012] });
  return { L: hl * 2, W: 2.5, exhaust: [-hw + 0.2, 2.6, zB - 0.1] };
}
function melonParts(g, rx, ry, rz, nLon = 10, nLat = 6) {
  const dk = 0x1f5f26, lt = 0x5aa848;
  g.sphere(rx, ry, rz, nLon, nLat, 0, 0, 0, (i) => (i % 2 ? dk : lt));
  g.box(-0.025, 0.025, ry - 0.02, ry + 0.05, -0.025, 0.025, 0x6b4a2a);
}
function buildBus(c, p) {
  const hl = 5.75, hw = 1.25, B = c.body;
  const base = p.variant === 1 ? 0x26324a : 0xf4f4f2, stripe = p.color, wz = [-hl + 2.0, hl - 2.55], r = 0.52;
  skirt(B, -hw, hw, 0.42, 1.1, -hl + 0.05, hl - 0.04, wz, r, base);
  B.box(-hw, hw, 1.1, 3.12, -hl + 0.05, hl - 0.04, base, 'D', { U: shade(base, 0.97) });
  // 측면 창 띠 + 기둥 + 출입문(오른쪽 앞)
  const gl = C.glass, gl2 = 0x141d33;
  for (const s of SIDES) {
    B.box(...xr(s, hw - 0.01, hw + 0.012), 1.62, 2.84, -hl + 1.3, hl - 0.6, gl);
    for (let z = -hl + 2.45; z < hl - 0.7; z += 1.2) B.box(...xr(s, hw + 0.012, hw + 0.02), 1.62, 2.84, z, z + 0.08, gl2);
    B.box(...xr(s, hw + 0.012, hw + 0.02), 2.3, 2.45, -hl + 1.3, hl - 0.6, C.glassHi);
  }
  B.box(hw - 0.01, hw + 0.014, 0.5, 2.84, -hl + 0.25, -hl + 1.15, gl);
  B.box(hw + 0.014, hw + 0.022, 0.5, 2.84, -hl + 0.68, -hl + 0.72, gl2);
  // 리버리 띠
  for (const s of SIDES) {
    B.box(...xr(s, hw - 0.005, hw + 0.016), 1.18, 1.45, -hl + 0.06, hl - 0.05, stripe);
    B.box(...xr(s, hw - 0.005, hw + 0.016), 1.49, 1.55, -hl + 1.2, hl - 0.05, shade(stripe, 0.75));
    B.box(...xr(s, hw - 0.005, hw + 0.016), 1.45, 2.95, hl - 0.55, hl - 0.05, stripe);
  }
  B.box(-hw + 0.02, hw - 0.02, 1.18, 1.45, hl - 0.04, hl - 0.03, stripe);
  // 앞: 큰 앞유리 + 행선판 + 라이트 + 범퍼
  B.box(-hw + 0.08, hw - 0.08, 1.15, 2.95, -hl + 0.02, -hl + 0.06, gl);
  B.box(-hw + 0.08, hw - 0.08, 1.15, 2.95, -hl + 0.06, -hl + 0.065, gl);
  B.box(-0.03, 0.03, 1.15, 2.6, -hl + 0.01, -hl + 0.02, C.dark);
  B.box(-0.85, 0.85, 2.64, 2.86, -hl, -hl + 0.02, 0x111114);
  B.box(-0.7, 0.7, 2.7, 2.8, -hl - 0.006, -hl, 0xffa31a);
  B.box(-hw - 0.02, hw + 0.02, 0.42, 0.76, -hl - 0.06, -hl + 0.3, C.dark, 'D');
  for (const s of SIDES) {
    lamp(c, 'head', ...xr(s, 0.62, hw - 0.12), 0.8, 1.0, -hl - 0.02, -hl + 0.07);
    lamp(c, 'hazard', ...xr(s, hw - 0.12, hw + 0.015), 0.8, 1.0, -hl - 0.02, -hl + 0.24);
  }
  plate(B, 0, 0.6, -hl - 0.07, -1, true);
  // 토끼귀 미러
  for (const s of SIDES) {
    B.box(...xr(s, 0.95, 1.32), 2.86, 2.94, -hl - 0.36, -hl + 0.08, C.dark);
    B.box(...xr(s, 1.12, 1.3), 2.2, 2.86, -hl - 0.44, -hl - 0.33, C.dark, '', { K: C.mirror });
  }
  // 뒤: 작은 뒷창 + 엔진 루버 + 세로 테일램프 + 범퍼
  B.box(-0.92, 0.92, 2.3, 2.92, hl - 0.04, hl - 0.01, gl);
  for (let i = 0; i < 5; i++) { const y = 0.95 + i * 0.13; B.box(-0.72, 0.72, y, y + 0.06, hl - 0.04, hl + 0.0, 0x3a3d44); }
  for (const s of SIDES) {
    lamp(c, 'brake', ...xr(s, 0.72, hw - 0.02), 0.78, 1.72, hl - 0.06, hl + 0.05);
    lamp(c, 'hazard', ...xr(s, 0.72, hw - 0.02), 1.74, 1.98, hl - 0.06, hl + 0.05);
    lamp(c, 'brake', ...xr(s, hw - 0.3, hw + 0.01), 2.94, 3.16, hl - 0.2, hl + 0.04, undefined, { top: true }); // 지붕 뒤 모서리 차폭등
    for (const z of [-hl + 1.6, -0.6, 1.4]) lamp(c, 'hazard', ...xr(s, hw, hw + 0.02), 0.55, 0.64, z, z + 0.18); // 측면 마커
  }
  lamp(c, 'brake', -0.55, 0.55, 2.95, 3.16, hl - 0.22, hl + 0.03, undefined, { top: true });
  B.box(-hw - 0.02, hw + 0.02, 0.42, 0.72, hl - 0.2, hl + 0.06, C.dark, 'D');
  plate(B, 0, 0.84, hl - 0.04, 1, true);
  // 지붕 에어컨 + 해치
  B.box(-0.82, 0.82, 3.12, 3.3, -1.6, 1.9, 0xd5d9de, 'D', { U: 0xe2e5e8 });
  for (const z of [-hl + 1.2, hl - 1.3]) B.box(-0.35, 0.35, 3.12, 3.17, z - 0.35, z + 0.35, 0xc3c8ce, 'D');
  for (const z of wz) { addWheel(c, -(hw - 0.24), z, r, 0.46); addWheel(c, hw - 0.24, z, r, 0.46); }
  return { L: hl * 2, W: hw * 2, exhaust: [0.7, 0.45, hl] };
}
function chickenParts(g) { // 원점 = 몸 중심, 앞 = -Z, 크기 ~0.6
  const wh = 0xf8f8f4, sh = 0xdedcd2;
  g.box(-0.2, 0.2, -0.18, 0.16, -0.22, 0.24, wh, '', { D: sh });
  g.box(-0.14, 0.14, 0.12, 0.42, -0.24, 0.02, wh);
  g.box(-0.04, 0.04, 0.42, 0.5, -0.18, -0.08, 0xe5302a); g.box(-0.04, 0.04, 0.42, 0.47, -0.08, 0.0, 0xe5302a);
  g.box(-0.06, 0.06, 0.2, 0.28, -0.36, -0.24, 0xffb22a);
  g.box(-0.035, 0.035, 0.1, 0.2, -0.3, -0.24, 0xe5302a);
  g.box(-0.145, -0.135, 0.28, 0.33, -0.18, -0.12, 0x111111); g.box(0.135, 0.145, 0.28, 0.33, -0.18, -0.12, 0x111111);
  for (const s of SIDES) g.box(...xr(s, 0.2, 0.25), -0.1, 0.1, -0.12, 0.16, sh);
  g.box(-0.13, 0.13, 0.0, 0.26, 0.24, 0.34, wh);
  for (const s of SIDES) { g.box(...xr(s, 0.06, 0.1), -0.34, -0.18, -0.02, 0.02, 0xff9a1a); g.box(...xr(s, 0.04, 0.13), -0.36, -0.33, -0.1, 0.03, 0xff9a1a); }
}
function hayParts(g, w = 1.2, h = 0.72, d = 0.8) { // 원점 = 중심
  const hay = 0xe7c25c, dk = 0xc9a03e, lt = 0xf3d77e, strap = 0x8a3b23;
  g.box(-w / 2, w / 2, -h / 2, h / 2, -d / 2, d / 2, hay, '', { U: lt, D: dk });
  const rnd = rng32(Math.round(w * 1000 + d * 10));
  for (let i = 0; i < 7; i++) { // 지푸라기 뭉치
    const x = (rnd() - 0.5) * (w - 0.2), z = (rnd() - 0.5) * (d - 0.2);
    g.box(x - 0.09, x + 0.09, h / 2 - 0.02, h / 2 + 0.03, z - 0.06, z + 0.06, i % 2 ? dk : lt);
  }
  for (const t of [-0.28, 0.28]) {
    const x = t * w;
    g.box(x - 0.035, x + 0.035, -h / 2 - 0.012, h / 2 + 0.012, -d / 2 - 0.012, d / 2 + 0.012, strap);
  }
  for (const s of SIDES) for (let i = 0; i < 3; i++) {
    const y = (rnd() - 0.5) * (h - 0.2), z = (rnd() - 0.5) * (d - 0.2);
    g.box(...xr(s, w / 2 - 0.02, w / 2 + 0.07), y - 0.03, y + 0.03, z - 0.05, z + 0.05, lt);
  }
}
function buildTractor(c, p) { // 경운기 + 트레일러 + 할배 + 건초 + 닭
  const B = c.body, col = p.color, dk = 0x3a3d42, D = c.detailed;
  const light = shade(col, 1.25);
  // ── 엔진부 (앞)
  B.box(-0.3, 0.3, 0.36, 0.58, -1.86, -1.7, C.dark);
  B.box(-0.3, 0.3, 0.58, 1.2, -1.76, -1.34, col, 'D', { U: light });
  B.box(-0.24, 0.24, 0.66, 1.12, -1.78, -1.76, 0x1d1e21);
  for (let i = 0; i < 4; i++) B.box(-0.22, 0.22, 0.7 + i * 0.1, 0.73 + i * 0.1, -1.79, -1.78, 0x6b7179);
  B.box(-0.06, 0.06, 1.2, 1.28, -1.5, -1.4, C.chrome);
  B.box(-0.13, 0.13, 1.18, 1.4, -1.66, -1.52, C.dark);
  lamp(c, 'head', -0.1, 0.1, 1.21, 1.37, -1.7, -1.64);
  B.box(-0.28, 0.28, 0.48, 1.04, -1.34, -0.94, dk);
  for (let i = 0; i < 3; i++) B.box(-0.3, 0.3, 0.62 + i * 0.12, 0.66 + i * 0.12, -1.3, -0.98, 0x55595f);
  B.box(-0.27, 0.27, 1.04, 1.24, -1.32, -0.98, col, '', { U: light });
  B.box(-0.05, 0.05, 1.24, 1.3, -1.2, -1.1, C.dark);
  // 플라이휠 (오른쪽) + 벨트커버 (왼쪽)
  B.prism(10, 0.31, 0.31, 0.08, 'x', 0.38, 0.84, -1.18, 0x2b2d32, { capB: 0x3a3d44 });
  B.box(0.42, 0.44, 0.58, 1.1, -1.21, -1.15, 0xc23a2a); B.box(0.42, 0.44, 0.81, 0.87, -1.44, -0.92, 0xc23a2a);
  B.prism(8, 0.07, 0.07, 0.06, 'x', 0.45, 0.84, -1.18, C.chrome);
  B.box(-0.42, -0.28, 0.56, 1.02, -1.42, -0.96, col);
  // 배기 (연기 위치)
  B.prism(6, 0.045, 0.045, 0.52, 'y', 0.17, 1.46, -1.06, C.dark);
  B.prism(8, 0.08, 0.08, 0.2, 'y', 0.17, 1.36, -1.06, 0x55595f);
  B.box(0.11, 0.25, 1.72, 1.76, -1.12, -0.98, C.dark);
  // 미션 + 차축 + 펜더
  B.box(-0.22, 0.22, 0.3, 0.84, -0.98, -0.46, dk);
  B.box(-0.52, 0.52, 0.38, 0.56, -1.08, -0.82, C.dark);
  for (const s of SIDES) {
    B.box(...xr(s, 0.46, 0.8), 1.0, 1.05, -1.5, -0.42, col, '', { U: light });
    B.box(...xr(s, 0.46, 0.8), 0.76, 1.0, -1.52, -1.46, col);
  }
  // 핸들바 (길게 뒤로) + 그립
  for (const s of SIDES) {
    B.beam([s * 0.16, 0.82, -0.56], [s * 0.44, 1.06, 0.06], 0.06, 0.06, 0x55595f);
    B.beam([s * 0.44, 1.06, 0.04], [s * 0.46, 1.08, 0.24], 0.08, 0.08, 0x111214);
    B.beam([s * 0.3, 0.95, -0.24], [s * 0.36, 1.08, -0.18], 0.025, 0.025, C.chrome);
  }
  B.beam([-0.3, 0.94, -0.26], [0.3, 0.94, -0.26], 0.04, 0.04, 0x55595f);
  // ── 트레일러
  B.beam([0, 0.44, -0.55], [0, 0.56, 0.12], 0.08, 0.08, C.dark);
  const tb = 0x4f79a8, wood = 0xa67a4c, z0 = 0.04, z1 = 1.88, tw = 0.82;
  B.box(-tw, tw, 0.56, 0.66, z0, z1, tb, 'D');
  B.box(-tw + 0.04, tw - 0.04, 0.66, 0.68, z0 + 0.04, z1 - 0.04, wood);
  for (const s of SIDES) B.box(...xr(s, tw - 0.05, tw), 0.66, 0.98, z0, z1, tb, '', { U: shade(tb, 1.15) });
  B.box(-tw, tw, 0.66, 0.98, z0, z0 + 0.05, tb); B.box(-tw, tw, 0.66, 0.98, z1 - 0.05, z1, tb);
  B.box(-0.72, 0.72, 0.26, 0.36, 1.26, 1.36, C.dark);
  // 저속차량 삼각표지 + 뒤 램프
  B.prism(3, 0.26, 0.26, 0.03, 'z', 0, 0.86, z1 + 0.02, 0xd8342c, { a0: Math.PI / 2 });
  B.prism(3, 0.17, 0.17, 0.03, 'z', 0, 0.86, z1 + 0.04, 0xff8a1a, { a0: Math.PI / 2 });
  for (const s of SIDES) {
    lamp(c, 'brake', ...xr(s, 0.4, 0.82), 0.66, 0.97, z1 - 0.02, z1 + 0.06);
    lamp(c, 'hazard', ...xr(s, 0.6, 0.84), 0.98, 1.1, z1 - 0.14, z1 + 0.04, undefined, { top: true }); // 뒤 기둥 위 호박색
  }
  // ── 할배 (트레일러 앞에 앉음)
  const shirt = 0xe9e4d4, vest = 0x6f6248, pants = 0x4a4f5a;
  B.box(-0.2, 0.2, 0.68, 1.12, 0.34, 0.6, shirt);
  B.box(-0.21, 0.21, 0.82, 1.1, 0.33, 0.61, vest, '', { F: shirt });
  B.box(-0.205, 0.205, 0.82, 1.1, 0.325, 0.33, shirt);
  for (const s of SIDES) {
    B.box(...xr(s, 0.03, 0.19), 0.68, 0.8, 0.1, 0.42, pants);
    B.box(...xr(s, 0.04, 0.18), 0.4, 0.72, 0.06, 0.16, pants);
    B.box(...xr(s, 0.04, 0.18), 0.36, 0.44, -0.04, 0.16, 0x1b1b1b);
    B.beam([s * 0.2, 1.06, 0.44], [s * 0.42, 1.02, 0.16], 0.1, 0.1, shirt);
    B.box(...xr(s, 0.39, 0.5), 1.0, 1.12, 0.1, 0.2, 0xc98a55);
  }
  B.box(-0.22, 0.22, 1.08, 1.16, 0.32, 0.62, 0xf4f4f0); // 목수건
  if (D) { c.driver = new GB(); c.driverTop = HEADS.grandpa(c.driver); c.driverPos = [0, 1.14, 0.47]; }
  else B.with(_m4().makeTranslation(0, 1.14, 0.47), (g) => HEADS.grandpa(g));
  // 건초 + 닭
  B.at(-0.36, 0.68 + 0.22, 1.33, 0, Math.PI / 2, 0, 1, (g) => hayParts(g, 0.92, 0.44, 0.66));
  B.at(0.36, 0.68 + 0.22, 1.33, 0, Math.PI / 2, 0, 1, (g) => hayParts(g, 0.92, 0.44, 0.66));
  B.at(0.0, 1.12 + 0.2, 1.52, 0, Math.PI / 2 + 0.15, 0, 1, (g) => hayParts(g, 0.7, 0.4, 0.56));
  B.at(0.12, 1.52 + 0.24, 1.54, 0, -0.5, 0, 0.75, (g) => chickenParts(g));
  // 바퀴: 구동 2 (러그 + 빨간 휠) + 트레일러 2
  addWheel(c, -0.62, -0.95, 0.46, 0.26, { lugs: true, rim: 0xd8452b, cap: 0xf6c21c, hubK: 0.5 }, 0.5);
  addWheel(c, 0.62, -0.95, 0.46, 0.26, { lugs: true, rim: 0xd8452b, cap: 0xf6c21c, hubK: 0.5 }, 0.5);
  addWheel(c, -0.76, 1.31, 0.3, 0.18, { rim: 0xc6ccd4 });
  addWheel(c, 0.76, 1.31, 0.3, 0.18, { rim: 0xc6ccd4 });
  return { L: 3.75, W: 1.64, exhaust: [0.17, 1.78, -1.05] };
}

// ────────────────────────────────────────────────────────────────────────
// 차종 테이블
// ────────────────────────────────────────────────────────────────────────
const KINDS = {
  compact: { build: buildCompact, variants: 3, canon: (v) => (v === 2 ? 1 : 0), color: 0xf4f4f2 },
  sedan: { build: buildSedan, variants: 3, color: 0xf4f4f2 },
  suv: { build: buildSuv, variants: 2, color: 0x2b2d31 },
  taxi: { build: buildTaxi, variants: 5, canon: (v) => (v === 4 ? 1 : 0), livery: (v) => (v === 1 ? 0x1d1f22 : 0xf08a24) },
  van: { build: buildVan, variants: 3, canon: (v) => (v === 2 ? 1 : 0), color: 0xf4f4f2 },
  pickup1t: { build: buildPorter, variants: 3, livery: () => 0x2a5db0 },
  truck: { build: buildTruck, variants: 2, color: 0xf4f4f2 },
  bus: { build: buildBus, variants: 3, canon: (v) => (v === 2 ? 1 : 0), color: 0x2f6fd6 },
  police: { build: buildPolice, variants: 1, livery: () => 0xf4f4f2 },
  player: { build: buildPlayer, detailed: true, color: PLAYER_COLOR },
  villainSedan: { build: buildVillainSedan, detailed: true, color: 0xd9c9a3 },
  villainTruck: { build: buildVillainTruck, detailed: true, variants: 2, colorVariant: true, color: 0x2f6fd6 },
  villainSuv: { build: buildVillainSuv, detailed: true, color: 0x1d1f22 },
  villainPhone: { build: buildVillainPhone, detailed: true, color: 0xe85d9a },
  tractor: { build: buildTractor, detailed: true, color: 0x3f8f3a },
};
export const VEHICLE_KINDS = Object.keys(KINDS);

const GEO_CACHE = new Map();
const WHEEL_CACHE = new Map();
function wheelGeo(w) {
  const k = `${w.r}|${w.w}|${JSON.stringify(w.o || {})}`;
  let g = WHEEL_CACHE.get(k);
  if (!g) { const gb = new GB(); wheelParts(gb, 0, 0, 0, w.r, w.w, { spoke: !w.o?.lugs, ...w.o, side: 0 }); g = gb.build(false); WHEEL_CACHE.set(k, g); }
  return g;
}
function compile(kind, def, p) {
  const c = newCtx(p.detailed, p.variant, p.color);
  const info = def.build(c, p);
  const E = { info, wheels: [] };
  const main = p.detailed ? c.wheels.slice(0, 4) : [];
  const merged = p.detailed ? c.wheels.slice(4) : c.wheels;
  for (const w of merged) wheelParts(c.body, w.x, w.y, w.z, w.r, w.w, { ...w.o, side: Math.sign(w.x) || 1 });
  for (const w of main) E.wheels.push({ x: w.x, y: w.y, z: w.z, r: w.r, geo: wheelGeo(w) });
  E.body = c.body.build(true);
  E.brake = c.brake.tris ? c.brake.build() : null;
  E.hazard = c.hazard.tris ? c.hazard.build() : null;
  E.head = c.head.tris ? c.head.build() : null;
  E.glow = c.glow.tris ? c.glow.build() : null;
  E.glass = c.glass.tris ? c.glass.build() : null;
  E.sirenR = c.sirenR ? c.sirenR.build() : null;
  E.sirenB = c.sirenB ? c.sirenB.build() : null;
  E.driver = c.driver ? c.driver.build(false) : null;
  E.driverPos = c.driverPos;
  E.cannon = c.cannon ? c.cannon.build(false) : null;
  E.cannonPos = c.cannonPos; E.muzzle = c.muzzle;
  E.signs = c.signs;
  // 치수: 길이/폭 = 차체 공칭값(충돌용), 높이 = 실제 최고점
  const bb = E.body.boundingBox;
  let top = bb.max.y;
  if (E.cannon) top = Math.max(top, c.cannonPos[1] + E.cannon.boundingBox.max.y);
  if (E.driver) top = Math.max(top, c.driverPos[1] + E.driver.boundingBox.max.y);
  E.dims = { length: info.L, width: info.W, height: Math.round(top * 100) / 100 };
  E.wheelRadius = (E.wheels[0] || c.wheels[0])?.r ?? 0.4;
  E.wheelRadii = c.wheels.slice(0, 4).map((w) => w.r);
  // 헤드라이트 빔 (detailed 만, 노면 위 가산 사다리꼴)
  if (p.detailed && E.head) {
    const zf = bb.min.z + 0.1, hw = info.W / 2;
    const g = new THREE.BufferGeometry();
    const L = 13, y = 0.05;
    g.setAttribute('position', new THREE.BufferAttribute(new Float32Array([
      -hw * 0.8, y, zf, hw * 0.8, y, zf, 3.4, y, zf - L, -hw * 0.8, y, zf, 3.4, y, zf - L, -3.4, y, zf - L]), 3));
    g.computeBoundingSphere();
    E.beam = g;
  }
  return E;
}

// 라이트 메시: material 대입 시 visible 자동 (Off = 숨김 → draw call 0, 단 keepOn 이면 Off 재질로 보임)
function lightMesh(geo, onMat, offMat, name) {
  const m = new THREE.Mesh(geo, offMat);
  m.name = name; m.castShadow = false; m.receiveShadow = false;
  m.userData.keepOn = false;
  let cur = offMat;
  Object.defineProperty(m, 'material', {
    configurable: true, enumerable: true,
    get() { return cur; },
    set(v) { cur = v; m.visible = v !== offMat || m.userData.keepOn; },
  });
  m.material = offMat;
  return m;
}

function instantiate(kind, E, detailed) {
  const g = new THREE.Group();
  g.name = 'vehicle:' + kind;
  const flashMats = [];
  const bodyMat = detailed ? MAT.body.clone() : MAT.body;
  if (detailed) { bodyMat.name = 'vehicleBodyFlash'; flashMats.push(bodyMat); }
  const bodyMesh = new THREE.Mesh(E.body, bodyMat);
  bodyMesh.name = 'bodyMesh'; bodyMesh.castShadow = true; bodyMesh.receiveShadow = false;
  let body = bodyMesh;
  if (detailed) { body = new THREE.Group(); body.name = 'body'; body.add(bodyMesh); }
  g.add(body);
  const brake = E.brake ? lightMesh(E.brake, MAT.brakeOn, MAT.brakeOff, 'brake') : null;
  const hazard = E.hazard ? lightMesh(E.hazard, MAT.hazardOn, MAT.hazardOff, 'hazard') : null;
  const head = E.head ? lightMesh(E.head, MAT.headOn, MAT.headOff, 'head') : null;
  if (brake) body.add(brake);
  if (hazard) body.add(hazard);
  if (head) body.add(head);
  if (head && E.beam) { const bm = new THREE.Mesh(E.beam, MAT.beam); bm.name = 'beam'; bm.renderOrder = 2; head.add(bm); }
  let glass = null, screen = null, driver = null, cannon = null, muzzle = null, siren = null;
  if (E.glass) {
    glass = new THREE.Mesh(E.glass, E.info.glass === 'screen' ? MAT.glassScreen : E.info.tint ? MAT.glassTint : MAT.glass);
    glass.name = 'glass'; glass.castShadow = true; body.add(glass);
  }
  if (E.glow) { screen = new THREE.Mesh(E.glow, MAT.glow); screen.name = 'glow'; body.add(screen); }
  if (E.sirenR) {
    const r = new THREE.Mesh(E.sirenR, MAT.sirenR), b = new THREE.Mesh(E.sirenB, MAT.sirenB);
    r.name = 'sirenR'; b.name = 'sirenB'; r.visible = b.visible = false; body.add(r, b); siren = [r, b]; // setSiren(v, t) 로 켬
  }
  if (E.driver) {
    driver = new THREE.Group(); driver.name = 'driver';
    driver.position.set(...E.driverPos);
    const dm = new THREE.Mesh(E.driver, bodyMat); dm.castShadow = false; driver.add(dm);
    body.add(driver);
  }
  if (E.cannon) {
    cannon = new THREE.Group(); cannon.name = 'cannon';
    cannon.position.set(...E.cannonPos);
    const cm = new THREE.Mesh(E.cannon, bodyMat); cm.castShadow = true; cannon.add(cm);
    muzzle = new THREE.Object3D(); muzzle.name = 'muzzle'; muzzle.position.set(...E.muzzle); cannon.add(muzzle);
    body.add(cannon);
  }
  for (const s of E.signs || []) {
    const tex = signTexture(s.key);
    if (!tex) continue;
    const sm = new THREE.Mesh(new THREE.PlaneGeometry(s.w, s.h), signMat(s.key, tex));
    sm.name = 'sign'; sm.position.set(...s.pos); body.add(sm);
  }
  const exhaust = new THREE.Object3D(); exhaust.name = 'exhaust';
  exhaust.position.set(...E.info.exhaust); body.add(exhaust);
  const wheels = [];
  for (const w of E.wheels) {
    const wm = new THREE.Mesh(w.geo, bodyMat);
    wm.name = 'wheel'; wm.castShadow = true; wm.position.set(w.x, w.y, w.z);
    g.add(wm); wheels.push(wm);
  }
  g.userData = {
    kind, detailed,
    length: E.dims.length, width: E.dims.width, height: E.dims.height,
    body, brake, hazard, head, wheels, wheelRadius: E.wheelRadius, wheelRadii: E.wheelRadii,
    driver, flashMats,
    // 확장
    glass, screen, siren, cannon, muzzle, exhaust,
  };
  return g;
}

export function buildVehicle(kind, opts = {}) {
  const def = KINDS[kind] || KINDS.sedan;
  if (!KINDS[kind]) kind = 'sedan';
  const detailed = opts.detailed ?? !!def.detailed;
  const nv = def.variants || 1;
  const raw = Math.floor(Math.abs(opts.seed ?? 0)) % nv;
  let color = (opts.livery ?? (def.livery ? def.livery(def.canon ? def.canon(raw) : raw) : (opts.color ?? def.color))) >>> 0;
  // colorVariant: seed 없이 색만 다르게 주면 변형도 색으로 갈림 (나란히 달리는 두 트럭의 운전자가 다르게)
  const variant = def.colorVariant && opts.seed === undefined ? color % nv : def.canon ? def.canon(raw) : raw;
  const key = `${kind}|${color}|${detailed ? 1 : 0}|${variant}`;
  let E = GEO_CACHE.get(key);
  if (!E) { E = compile(kind, def, { color, detailed, variant, seed: opts.seed ?? 0 }); GEO_CACHE.set(key, E); }
  return instantiate(kind, E, detailed);
}

// ────────────────────────────────────────────────────────────────────────
// 상태 제어
// ────────────────────────────────────────────────────────────────────────
export function setBrake(vehicle, on) { const m = vehicle?.userData?.brake; if (m) m.material = on ? MAT.brakeOn : MAT.brakeOff; }
export function setHazard(vehicle, on) { const m = vehicle?.userData?.hazard; if (m) m.material = on ? MAT.hazardOn : MAT.hazardOff; }
export function setHeadlights(vehicle, on) {
  const ud = vehicle?.userData; if (!ud) return;
  if (ud.head) ud.head.material = on ? MAT.headOn : MAT.headOff;
  // 밤에는 꺼진 브레이크등도 미등(어두운 빨강 발광)으로 보이게
  if (ud.brake) { const cur = ud.brake.material; ud.brake.userData.keepOn = !!on; ud.brake.material = cur; }
}
export function setFlash(vehicle, amount) {
  const mats = vehicle?.userData?.flashMats; if (!mats) return;
  const a = Math.max(0, Math.min(1, amount || 0));
  for (let i = 0; i < mats.length; i++) mats[i].emissive.setRGB(a, a, a);
}
// 확장: 경찰 경광등 교대 점멸. t = 초. 둘 다 끄려면 setSiren(v, null)
export function setSiren(vehicle, t) {
  const s = vehicle?.userData?.siren; if (!s) return;
  if (t === null || t === false) { s[0].visible = s[1].visible = false; return; }
  const ph = Math.floor(t * 6) % 2 === 0;
  s[0].visible = ph; s[1].visible = !ph;
}
// 확장: detailed 차량의 per-vehicle 재질 해제 (지오메트리는 캐시 공유 → dispose 금지)
export function disposeVehicle(vehicle) { for (const m of vehicle?.userData?.flashMats || []) m.dispose(); }

// ────────────────────────────────────────────────────────────────────────
// 캔버스 간판 (꿀수박)
// ────────────────────────────────────────────────────────────────────────
const TEX = new Map(), SIGN_MAT = new Map();
const SIGN_DRAW = {
  melon(x, w, h) {
    x.fillStyle = '#fff6d8'; x.fillRect(0, 0, w, h);
    x.strokeStyle = '#2a6a2e'; x.lineWidth = 14; x.strokeRect(7, 7, w - 14, h - 14);
    x.textAlign = 'center'; x.textBaseline = 'middle';
    x.fillStyle = '#e02a2a'; x.font = `${Math.round(h * 0.66)}px ${FONT_DISPLAY}`;
    x.fillText('꿀수박', w * 0.38, h * 0.54);
    x.fillStyle = '#1f5f26'; x.font = `${Math.round(h * 0.34)}px ${FONT_DISPLAY}`;
    x.fillText('1통 만원', w * 0.8, h * 0.54);
  },
};
function signTexture(key) {
  if (TEX.has(key)) return TEX.get(key);
  if (typeof document === 'undefined') return null;
  const cv = document.createElement('canvas'); cv.width = 512; cv.height = 144;
  const x = cv.getContext('2d');
  const draw = () => { x.clearRect(0, 0, cv.width, cv.height); SIGN_DRAW[key](x, cv.width, cv.height); };
  draw();
  const t = new THREE.CanvasTexture(cv);
  t.colorSpace = THREE.SRGBColorSpace; t.anisotropy = 4;
  TEX.set(key, t);
  try { document.fonts?.load(`64px ${FONT_DISPLAY}`).then(() => { draw(); t.needsUpdate = true; }).catch(() => {}); } catch (e) { /* noop */ }
  return t;
}
function signMat(key, tex) {
  let m = SIGN_MAT.get(key);
  if (!m) { m = new THREE.MeshLambertMaterial({ map: tex }); SIGN_MAT.set(key, m); }
  return m;
}

// ────────────────────────────────────────────────────────────────────────
// 투사체 (원점 = 중심, 과장된 크기). missile 은 +Z 가 앞 (Object3D.lookAt 규약)
// ────────────────────────────────────────────────────────────────────────
const PROJ_CACHE = new Map();
const PROJ = {
  tack(g) { // 압정: 은색 원판 머리 + 위로 솟은 침 (~0.5m)
    const a0 = Math.PI / 8;
    g.prism(8, 0.25, 0.25, 0.07, 'y', 0, -0.12, 0, 0xd9dfe6, { a0, capA: 0x9aa3ad, capB: 0xeef2f6 });
    g.prism(8, 0.255, 0.255, 0.025, 'y', 0, -0.165, 0, 0x8e97a2, { a0, noA: true, noB: true });
    g.prism(8, 0.1, 0.08, 0.06, 'y', 0, -0.06, 0, 0xc6ccd4, { a0 });
    g.prism(6, 0.05, 0.0, 0.3, 'y', 0, 0.12, 0, 0xaab3bd);
    g.box(-0.12, -0.04, -0.084, -0.08, 0.06, 0.14, 0xffffff);
    return { radius: 0.26 };
  },
  missile(g, glow) { // 분노 미사일: 빨간 몸통 + 노란 날개 + 화난 눈 + 불꽃 꼬리. 앞 = +Z
    const a0 = Math.PI / 8, red = 0xe23b3b, yel = 0xffcf3a;
    g.prism(8, 0.18, 0.18, 0.95, 'z', 0, 0, 0.0, red, { a0 });
    g.prism(8, 0.18, 0.0, 0.42, 'z', 0, 0, 0.685, red, { a0 });
    g.prism(8, 0.186, 0.186, 0.08, 'z', 0, 0, 0.38, 0xf4f4f2, { a0, noA: true, noB: true });
    g.prism(8, 0.186, 0.186, 0.06, 'z', 0, 0, -0.3, 0x2b2d32, { a0, noA: true, noB: true });
    g.prism(8, 0.14, 0.12, 0.12, 'z', 0, 0, -0.53, 0x3a3d44, { a0, capA: 0x111114 });
    for (let i = 0; i < 4; i++) g.at(0, 0, -0.32, 0, 0, (i * Math.PI) / 2 + Math.PI / 4, 1, (q) => q.box(-0.025, 0.025, 0.16, 0.44, -0.22, 0.12, yel));
    for (const s of SIDES) { // 화난 눈 + 눈썹
      g.box(...xr(s, 0.07, 0.15), 0.02, 0.12, 0.42, 0.47, 0xffffff, '', {}).box(...xr(s, 0.09, 0.14), 0.03, 0.09, 0.47, 0.48, 0x111111);
      g.at(s * 0.11, 0.15, 0.46, 0, 0, s * 0.35, 1, (q) => q.box(-0.06, 0.06, -0.018, 0.018, -0.01, 0.03, 0x111111));
    }
    const k = 1;
    glow.prism(8, 0.13 * k, 0.0, 0.75, 'z', 0, 0, -0.97, 0xff7a1a, { a0, noB: true });
    glow.prism(8, 0.08, 0.0, 0.5, 'z', 0, 0, -0.84, 0xfff27a, { a0 });
    return { radius: 0.5, flame: [0, 0, -0.59] };
  },
  cup(g) { // 테이크아웃 아아: 투명컵 속 커피+얼음, 크라프트 슬리브, 위에서 보면 커피색(투명 뚜껑) → 납작해진 웅덩이도 갈색 (~0.75m)
    const a0 = Math.PI / 8, coffee = 0x5a3320, top = 0x6e4126;
    g.prism(8, 0.15, 0.18, 0.34, 'y', 0, -0.13, 0, coffee, { a0 });
    g.prism(8, 0.18, 0.2, 0.14, 'y', 0, 0.11, 0, 0xc6e4ec, { a0, noA: true });
    g.prism(8, 0.18, 0.192, 0.16, 'y', 0, -0.06, 0, 0xc89a62, { a0, noA: true, noB: true });
    g.box(-0.05, 0.05, -0.1, -0.02, -0.2, -0.17, 0xf4f4f2);
    g.prism(8, 0.215, 0.215, 0.04, 'y', 0, 0.2, 0, 0xf6f6f2, { a0 });                       // 흰 뚜껑 테
    g.prism(8, 0.18, 0.18, 0.012, 'y', 0, 0.226, 0, top, { a0, noA: true });                // 뚜껑 너머 커피
    for (const [x, z, k] of [[-0.08, -0.05, 0.05], [0.06, 0.07, 0.045], [0.07, -0.08, 0.04], [-0.04, 0.09, 0.035]]) {
      g.box(x - k, x + k, 0.226, 0.245, z - k, z + k, 0xe4f3f8);                            // 얼음
    }
    g.prism(8, 0.06, 0.05, 0.04, 'y', 0, 0.25, 0, 0xf6f6f2, { a0 });                        // 빨대 구멍
    g.beam([0.0, 0.24, 0.0], [0.07, 0.54, 0.04], 0.045, 0.045, 0x2fae5a);
    return { radius: 0.3 };
  },
  watermelon(g) { melonParts(g, 0.45, 0.4, 0.45, 10, 6); return { radius: 0.45 }; },
  hay(g) { hayParts(g, 1.2, 0.72, 0.8); return { radius: 0.6 }; },
  phone(g, glow) { // 스마트폰 (~0.7m): 앞 = 화면(시안→핑크 발광), 뒤 = 핫핑크 케이스 + 빛나는 하트 → 어느 면이 보여도 읽힘
    g.box(-0.18, 0.18, -0.34, 0.34, -0.035, 0.035, 0x17181c);
    glow.box(-0.155, 0.155, 0.0, 0.31, -0.045, -0.035, 0x6ff6ff);
    glow.box(-0.155, 0.155, -0.31, 0.0, -0.045, -0.035, 0xff7ad0);
    g.box(-0.05, 0.05, 0.3, 0.32, -0.046, -0.04, 0x111111);
    g.box(-0.197, 0.197, -0.357, 0.357, -0.03, 0.062, 0xff4fa0, '', { K: 0xff62ac });       // 케이스
    g.box(0.02, 0.16, 0.16, 0.32, 0.062, 0.09, 0x2a2b30);                                    // 카메라 섬
    for (const [x, y] of [[0.055, 0.27], [0.125, 0.27], [0.055, 0.2]]) g.box(x - 0.025, x + 0.025, y - 0.025, y + 0.025, 0.09, 0.1, 0x0c0c0e);
    pixelArt(glow, ['.#.#.', '#####', '#####', '.###.', '..#..'], 'K', -0.01, -0.08, 0.064, 0.05, 0xfff0f8); // 빛나는 하트
    return { radius: 0.36 };
  },
  butt(g, glow) { // 담배꽁초 (~0.55m), 끝불 발광
    const a0 = Math.PI / 8;
    g.prism(8, 0.08, 0.08, 0.22, 'x', -0.16, 0, 0, 0xd9944a, { a0 });
    for (const x of [-0.22, -0.12]) g.box(x - 0.01, x + 0.01, 0.06, 0.084, -0.03, 0.03, 0xb06a2a);
    g.prism(8, 0.08, 0.08, 0.3, 'x', 0.1, 0, 0, 0xf2f0e8, { a0 });
    g.prism(8, 0.081, 0.081, 0.03, 'x', -0.04, 0, 0, 0xe0c27a, { a0, noA: true, noB: true });
    g.prism(8, 0.082, 0.07, 0.04, 'x', 0.27, 0, 0, 0x8a8a88, { a0, noA: true });
    glow.prism(8, 0.07, 0.05, 0.05, 'x', 0.315, 0, 0, 0xff4a1a, { a0, capB: 0xffc23a });
    return { radius: 0.28 };
  },
  chicken(g) { chickenParts(g); return { radius: 0.35 }; },
};
export const PROJECTILE_KINDS = Object.keys(PROJ);

export function buildProjectile(kind) {
  if (!PROJ[kind]) kind = 'cup';
  let E = PROJ_CACHE.get(kind);
  if (!E) {
    const g = new GB(), glow = new GB();
    const info = PROJ[kind](g, glow);
    E = { body: g.build(false), glow: glow.tris ? glow.build(false) : null, info };
    PROJ_CACHE.set(kind, E);
  }
  const mesh = new THREE.Mesh(E.body, MAT.body);
  mesh.castShadow = true; mesh.name = 'proj:' + kind;
  let obj = mesh;
  if (E.glow) {
    obj = new THREE.Group(); obj.name = 'proj:' + kind; obj.add(mesh);
    const gm = new THREE.Mesh(E.glow, MAT.glow); gm.name = 'glow';
    if (E.info.flame) { // 불꽃은 노즐 기준으로 스케일되도록 피벗 이동
      const f = E.info.flame;
      gm.position.set(f[0], f[1], f[2]);
      if (!E.glowShifted) { E.glow.translate(-f[0], -f[1], -f[2]); E.glowShifted = true; }
      obj.userData.flame = gm;
    }
    obj.add(gm); obj.userData.glow = gm;
  }
  obj.userData.kind = kind;
  obj.userData.radius = E.info.radius;
  return obj;
}

// ────────────────────────────────────────────────────────────────────────
// 투하 경고 마커 (노면, 지름 ~3m). userData.setProgress(0..1)
// ────────────────────────────────────────────────────────────────────────
let WARN_GEO = null;
function warnGeo() {
  if (WARN_GEO) return WARN_GEO;
  const flat = (geo) => geo.rotateX(-Math.PI / 2);
  const ticks = [];
  for (let i = 0; i < 4; i++) {
    const t = new THREE.PlaneGeometry(0.22, 0.42); t.translate(0, 1.72, 0); t.rotateZ((i * Math.PI) / 2); ticks.push(t);
  }
  const tickGeo = new THREE.BufferGeometry();
  { // 4개 병합
    const arrs = ticks.map((t) => t.toNonIndexed().attributes.position.array);
    const all = new Float32Array(arrs.reduce((n, a) => n + a.length, 0));
    let o = 0; for (const a of arrs) { all.set(a, o); o += a.length; }
    tickGeo.setAttribute('position', new THREE.BufferAttribute(all, 3));
  }
  const xg = new THREE.BufferGeometry();
  {
    const a = new THREE.PlaneGeometry(2.1, 0.32).toNonIndexed(), b = a.clone();
    a.rotateZ(Math.PI / 4); b.rotateZ(-Math.PI / 4);
    const pa = a.attributes.position.array, pb = b.attributes.position.array;
    const all = new Float32Array(pa.length + pb.length); all.set(pa); all.set(pb, pa.length);
    xg.setAttribute('position', new THREE.BufferAttribute(all, 3));
  }
  WARN_GEO = {
    ring: flat(new THREE.RingGeometry(1.3, 1.52, 40)),
    inner: flat(new THREE.RingGeometry(0.98, 1.05, 40)),
    fill: flat(new THREE.CircleGeometry(1.3, 40)),
    x: flat(xg), ticks: flat(tickGeo),
  };
  return WARN_GEO;
}
export function buildWarningMarker() {
  const G = warnGeo();
  const g = new THREE.Group(); g.name = 'warningMarker';
  const mk = (color, opacity) => new THREE.MeshBasicMaterial({ color, transparent: true, opacity, depthWrite: false, side: THREE.DoubleSide, polygonOffset: true, polygonOffsetFactor: -2, polygonOffsetUnits: -4 });
  const ringMat = mk(0xff2a2a, 0.95), fillMat = mk(0xff2a2a, 0.3), xMat = mk(0xffffff, 0.85), innerMat = mk(0xffffff, 0.7), tickMat = mk(0xffd23a, 0.95);
  const ring = new THREE.Mesh(G.ring, ringMat), inner = new THREE.Mesh(G.inner, innerMat), fill = new THREE.Mesh(G.fill, fillMat);
  const x = new THREE.Mesh(G.x, xMat), ticks = new THREE.Mesh(G.ticks, tickMat);
  const parts = [fill, inner, x, ring, ticks];
  parts.forEach((m, i) => { m.position.y = 0.03 + i * 0.002; m.renderOrder = 3 + i; m.castShadow = false; m.receiveShadow = false; g.add(m); });
  const setProgress = (p) => {
    p = Math.max(0, Math.min(1, p || 0));
    fill.scale.setScalar(Math.max(0.001, p));
    fillMat.opacity = 0.22 + 0.4 * p;
    const blink = 0.5 + 0.5 * Math.cos(p * p * 70);
    ringMat.opacity = 0.6 + 0.4 * blink;
    xMat.opacity = 0.55 + 0.4 * blink;
    const sc = 1 + 0.06 * blink * p;
    ring.scale.setScalar(sc); x.scale.setScalar(sc * (0.9 + 0.1 * p));
    ticks.rotation.y = p * Math.PI * 0.5;
    ticks.scale.setScalar(1.15 - 0.15 * p);
  };
  setProgress(0);
  g.userData = { setProgress, materials: [ringMat, fillMat, xMat, innerMat, tickMat] };
  return g;
}
