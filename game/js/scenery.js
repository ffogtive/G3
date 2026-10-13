// scenery.js — 한국 고속도로 배경 (도로 세그먼트·소품·표지판·VMS·현수막·하늘)
//
// 가설: 정적 배경은 "재질별 1메시"로 굽고(지오메트리 캐시 공유), 텍스트는 캔버스 텍스처로 캐시하면
//       모바일에서도 세그먼트당 draw call 2~4개로 '진짜 한국 고속도로' 느낌을 낼 수 있다.
//
// 좌표: 진행 방향 = −Z (z = −s), 1차선(lane 0) = 가장 왼쪽(−X), 노면 y = 0, 단위 m.
// 모든 정적 지오메트리는 직접 만든 버퍼(위치/법선/정점색)로 구워 재질별로 하나로 합친다.
//   → BufferGeometryUtils.mergeGeometries 와 같은 결과(재질당 메시 1개)를 할당 없이 바로 얻는다.
// 캐시된 지오메트리·재질·텍스처는 여러 그룹이 공유한다 → 호출자는 dispose() 하지 말 것.

import * as THREE from 'three';
import {
  NUM_LANES, LANE_W, laneX, ROAD_LEFT, ROAD_RIGHT, SHOULDER_W, MEDIAN_GAP, MEDIAN_W, MEDIAN_X,
  OPP_LANE_X, OPP_ROAD_LEFT, SEG_LEN, FONT_DISPLAY, FONT_UI, STAGES,
} from './config.js';

// ─────────────────────────────────────────────────────────────
// 레이아웃 (config 에서 파생 — 상수 재정의 아님)
const MED_L = MEDIAN_X - MEDIAN_W / 2;          // -8.7
const MED_R = MEDIAN_X + MEDIAN_W / 2;          // -7.8
const OPP_IN = MED_L - MEDIAN_GAP;              // -9.3  반대편 1차선 안쪽 끝
const OPP_OUT = OPP_ROAD_LEFT;                  // -23.7 반대편 4차선 바깥 끝
const SH_R = ROAD_RIGHT + SHOULDER_W;           // 10.2  우측 갓길 끝
const SH_L = OPP_OUT - SHOULDER_W;              // -26.7 반대편 갓길 끝
const CURB_W = 0.3;
const GR_OFF = 0.45;                            // 갓길 끝 → 가드레일 레일 면
const NB_OFF = 2.3;                             // 갓길 끝 → 방음벽 중심
const VERGE_X = 60;                             // 잔디 비탈 끝 |x|

/** 소품 배치용 참고 좌표 (추가 export). 전부 월드 x(m). */
export const LAYOUT = Object.freeze({
  medianL: MED_L, medianR: MED_R,
  oppInner: OPP_IN, oppOuter: OPP_OUT,
  shoulderR: SH_R, shoulderL: SH_L,
  guardrailR: SH_R + GR_OFF, guardrailL: SH_L - GR_OFF,
  barrierR: SH_R + NB_OFF, barrierL: SH_L - NB_OFF,
  vergeR: VERGE_X, vergeL: -VERGE_X,
  propMinR: SH_R + NB_OFF + 1.2,   // 이보다 바깥(+X)이면 방음벽/배수로와 안 겹침 (≈13.7)
  propMinL: SH_L - NB_OFF - 1.2,   // (≈ -30.2)
  streetLightR: SH_R + 1.05,       // 가로등 기둥 권장 x (가드레일 뒤) → 램프는 x≈7.6 (갓길 위)
  bannerR: SH_R + 3.4,             // 현수막 중심 권장 x
  billboardR: SH_R + 12,           // 광고판 중심 권장 x
});

// ─────────────────────────────────────────────────────────────
// 유틸
function rng(seed) {
  let a = (seed | 0) ^ 0x2545f491;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
function hash3(x, y, z) {
  const h = Math.sin(x * 127.1 + y * 311.7 + z * 74.7) * 43758.5453;
  return h - Math.floor(h);
}
const _col = new THREE.Color();
const _colCache = new Map();
/** sRGB hex → 선형 [r,g,b] (캐시) */
function C(hex) {
  let v = _colCache.get(hex);
  if (!v) { _col.setHex(hex); v = [_col.r, _col.g, _col.b]; _colCache.set(hex, v); }
  return v;
}
function toC(c) { return typeof c === 'number' ? C(c) : c; }
function mulC(c, f) { c = toC(c); return [c[0] * f, c[1] * f, c[2] * f]; }
function mixC(a, b, t) { a = toC(a); b = toC(b); return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t]; }

// ─────────────────────────────────────────────────────────────
// 지오메트리 빌더: 삼각형 단위로 위치/법선/정점색(+uv)을 쌓는다 (플랫 셰이딩 전제)
const _m4 = new THREE.Matrix4();
const _eu = new THREE.Euler();
const _v3 = new THREE.Vector3();
class GB {
  constructor(withUV = false) { this.p = []; this.n = []; this.c = []; this.uv = withUV ? [] : null; this.cv = null; }
  get empty() { return this.p.length === 0; }
  // 정점별 색 (그라데이션)
  triC(a, b, c, ca, cb, cc) {
    const n = this._norm(a, b, c);
    this._push(a, n, toC(ca)); this._push(b, n, toC(cb)); this._push(c, n, toC(cc));
  }
  tri(a, b, c, col, ua, ub, uc) {
    const n = this._norm(a, b, c), cc = toC(col);
    this._push(a, n, cc, ua); this._push(b, n, cc, ub); this._push(c, n, cc, uc);
  }
  quad(a, b, c, d, col, uvs) {
    if (uvs) { this.tri(a, b, c, col, uvs[0], uvs[1], uvs[2]); this.tri(a, c, d, col, uvs[0], uvs[2], uvs[3]); }
    else { this.tri(a, b, c, col); this.tri(a, c, d, col); }
  }
  // 바깥 기준점(ref)에서 멀어지는 쪽이 앞면이 되도록 자동 정렬
  triOut(a, b, c, col, ref) {
    const n = this._norm(a, b, c);
    const cx = (a[0] + b[0] + c[0]) / 3 - ref[0], cy = (a[1] + b[1] + c[1]) / 3 - ref[1], cz = (a[2] + b[2] + c[2]) / 3 - ref[2];
    if (n[0] * cx + n[1] * cy + n[2] * cz < 0) this.tri(a, c, b, col); else this.tri(a, b, c, col);
  }
  _norm(a, b, c) {
    const ux = b[0] - a[0], uy = b[1] - a[1], uz = b[2] - a[2];
    const vx = c[0] - a[0], vy = c[1] - a[1], vz = c[2] - a[2];
    let nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
    const l = Math.hypot(nx, ny, nz) || 1;
    return [nx / l, ny / l, nz / l];
  }
  _push(p, n, c, uv) {
    this.p.push(p[0], p[1], p[2]); this.n.push(n[0], n[1], n[2]); this.c.push(c[0], c[1], c[2]);
    if (this.uv) this.uv.push(uv ? uv[0] : 0, uv ? uv[1] : 0);
  }
  /** 수평 윗면 사각형 (y 높이), x0<x1, 위에서 보면 반시계 */
  top(x0, x1, za, zb, y, col) {
    const z0 = Math.max(za, zb), z1 = Math.min(za, zb);
    this.quad([x0, y, z0], [x1, y, z0], [x1, y, z1], [x0, y, z1], col);
  }
  /** 임의 4점 평면(위를 보게 자동 정렬). pts = [[x,z]...] */
  flat(pts, y, col) {
    const [a, b, c, d] = pts.map((q) => [q[0], y, q[1]]);
    const n = this._norm(a, b, c);
    if (n[1] < 0) this.quad(a, d, c, b, col); else this.quad(a, b, c, d, col);
  }
  /**
   * 박스. (x,z)=중심, y=바닥. o: { rx, ry, rz (중심 기준 회전), top: 윗면색, bot: 아랫면색, nb: 아랫면 생략, side: 옆면색 }
   */
  box(x, y, z, sx, sy, sz, col, o) {
    const hx = sx / 2, hy = sy / 2, hz = sz / 2, cy = y + hy;
    const P = [[-hx, -hy, -hz], [hx, -hy, -hz], [hx, hy, -hz], [-hx, hy, -hz], [-hx, -hy, hz], [hx, -hy, hz], [hx, hy, hz], [-hx, hy, hz]];
    if (o && (o.rx || o.ry || o.rz)) {
      _m4.makeRotationFromEuler(_eu.set(o.rx || 0, o.ry || 0, o.rz || 0));
      for (const q of P) { _v3.set(q[0], q[1], q[2]).applyMatrix4(_m4); q[0] = _v3.x; q[1] = _v3.y; q[2] = _v3.z; }
    }
    for (const q of P) { q[0] += x; q[1] += cy; q[2] += z; }
    const s = toC(col), t = o && o.top != null ? toC(o.top) : s, b = o && o.bot != null ? toC(o.bot) : s;
    this.quad(P[4], P[5], P[6], P[7], s); // +Z
    this.quad(P[1], P[0], P[3], P[2], s); // -Z
    this.quad(P[5], P[1], P[2], P[6], s); // +X
    this.quad(P[0], P[4], P[7], P[3], s); // -X
    this.quad(P[7], P[6], P[2], P[3], t); // +Y
    if (!(o && o.nb)) this.quad(P[0], P[1], P[5], P[4], b); // -Y
  }
  /** 박공 지붕(삼각기둥). 용마루가 Z축(alongX=false) 또는 X축 방향. by=처마 높이 */
  prism(cx, by, cz, w, h, d, col, alongX = false, endCol) {
    const ref = [cx, by + h * 0.3, cz];
    const P = (u, v, y) => (alongX ? [cx + v, y, cz + u] : [cx + u, y, cz + v]);
    // u = 가로(용마루 직각), v = 용마루 방향
    const hw = w / 2, hd = d / 2;
    const a = P(-hw, -hd, by), b = P(hw, -hd, by), c = P(hw, hd, by), e = P(-hw, hd, by);
    const r0 = P(0, -hd, by + h), r1 = P(0, hd, by + h);
    this.triOut(a, r0, r1, col, ref); this.triOut(a, r1, e, col, ref);
    this.triOut(b, c, r1, col, ref); this.triOut(b, r1, r0, col, ref);
    const ec = endCol != null ? endCol : col;
    this.triOut(a, b, r0, ec, ref); this.triOut(e, r1, c, ec, ref);
    this.triOut(a, e, c, mulC(col, 0.7), ref); this.triOut(a, c, b, mulC(col, 0.7), ref);
  }
  /** 수직 사각형 (x 고정, z 구간). facing: +1 → +X 바라봄, -1 → -X */
  vquadX(x, z0, z1, y0, y1, facing, col, u0 = 0, u1 = 1, v0 = 0, v1 = 1) {
    const zmin = Math.min(z0, z1), zmax = Math.max(z0, z1);
    if (facing > 0) this.quad([x, y0, zmax], [x, y0, zmin], [x, y1, zmin], [x, y1, zmax], col, [[u0, v0], [u1, v0], [u1, v1], [u0, v1]]);
    else this.quad([x, y0, zmin], [x, y0, zmax], [x, y1, zmax], [x, y1, zmin], col, [[u0, v0], [u1, v0], [u1, v1], [u0, v1]]);
  }
  /** 수직 사각형 (z 고정). facing: +1 → +Z 바라봄 */
  vquadZ(z, x0, x1, y0, y1, facing, col, u0 = 0, u1 = 1, v0 = 0, v1 = 1) {
    const xmin = Math.min(x0, x1), xmax = Math.max(x0, x1);
    if (facing > 0) this.quad([xmin, y0, z], [xmax, y0, z], [xmax, y1, z], [xmin, y1, z], col, [[u0, v0], [u1, v0], [u1, v1], [u0, v1]]);
    else this.quad([xmax, y0, z], [xmin, y0, z], [xmin, y1, z], [xmax, y1, z], col, [[u0, v0], [u1, v0], [u1, v1], [u0, v1]]);
  }
  /** Three 지오메트리 추가 (행렬 적용, 삼각형별 색: 상수 또는 fn(cx,cy,cz,ny)) */
  geo(src, matrix, col) {
    const g = src.index ? src.toNonIndexed() : src;
    const pos = g.attributes.position;
    const a = [0, 0, 0], b = [0, 0, 0], c = [0, 0, 0];
    for (let i = 0; i < pos.count; i += 3) {
      for (let k = 0; k < 3; k++) {
        _v3.fromBufferAttribute(pos, i + k);
        if (matrix) _v3.applyMatrix4(matrix);
        const t = k === 0 ? a : k === 1 ? b : c;
        t[0] = _v3.x; t[1] = _v3.y; t[2] = _v3.z;
      }
      let cc = col;
      if (typeof col === 'function') {
        const n = this._norm(a, b, c);
        cc = col((a[0] + b[0] + c[0]) / 3, (a[1] + b[1] + c[1]) / 3, (a[2] + b[2] + c[2]) / 3, n[1]);
      }
      this.tri(a.slice(), b.slice(), c.slice(), cc);
    }
    if (g !== src) g.dispose();
  }
  build() {
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.Float32BufferAttribute(this.p, 3));
    g.setAttribute('normal', new THREE.Float32BufferAttribute(this.n, 3));
    g.setAttribute('color', new THREE.Float32BufferAttribute(this.c, 3));
    if (this.uv) g.setAttribute('uv', new THREE.Float32BufferAttribute(this.uv, 2));
    g.computeBoundingSphere();
    g.computeBoundingBox();
    return g;
  }
}
const M4 = (x = 0, y = 0, z = 0, sx = 1, sy = 1, sz = 1, ry = 0, rz = 0, rx = 0) => {
  const m = new THREE.Matrix4();
  m.compose(new THREE.Vector3(x, y, z), new THREE.Quaternion().setFromEuler(new THREE.Euler(rx, ry, rz)), new THREE.Vector3(sx, sy, sz));
  return m;
};
// 공유 원형 지오메트리 (빌드 시 변환해서 굽기만 함)
const PRIM = {
  ico: new THREE.IcosahedronGeometry(1, 0),
  ico1: new THREE.IcosahedronGeometry(1, 1),
  cone6: new THREE.ConeGeometry(1, 1, 6, 1).translate(0, 0.5, 0),
  cone7: new THREE.ConeGeometry(1, 1, 7, 1).translate(0, 0.5, 0),
  cone4: new THREE.ConeGeometry(1, 1, 4, 1).translate(0, 0.5, 0),
  cyl8: new THREE.CylinderGeometry(1, 1, 1, 8, 1).translate(0, 0.5, 0),
  dodeca: new THREE.DodecahedronGeometry(1, 0),
};

// ─────────────────────────────────────────────────────────────
// 공유 재질
/** 공유 재질 (추가 export). vc: 정점색 플랫 램버트 / glow: 발광(조명 무시) / additive: 가산 광원 효과 */
export const SCENERY_MAT = {
  vc: new THREE.MeshLambertMaterial({ vertexColors: true, flatShading: true, name: 'scenery.vc' }),
  glow: new THREE.MeshBasicMaterial({ vertexColors: true, name: 'scenery.glow' }),
  additive: new THREE.MeshBasicMaterial({
    vertexColors: true, transparent: true, depthWrite: false, blending: THREE.AdditiveBlending,
    fog: false, side: THREE.DoubleSide, name: 'scenery.additive',
  }),
};
const MAT = SCENERY_MAT;

// ─────────────────────────────────────────────────────────────
// 폰트 / 캔버스 텍스트
const HAS_DOM = typeof document !== 'undefined';
const FONT_EN = '"Arial Black", "Helvetica Neue", Arial, sans-serif';

const BANNER_TEXTS = ['졸음운전! 자면 죽는다', '졸음쉼터 2km', '1차선은 추월차선!', '앞지르기 후 주행차로 복귀!', '깜빡이는 양보의 시작', '과속하면 골로 간다!'];
const AD_LIST = [
  { lines: ['휴게소 명물', '호두과자 3km'], bg: '#ffd23f', fg: '#6b2c0e', ac: '#d7261e', icon: 'walnut' },
  { lines: ['강원도 왕감자', '감자 맛집'], bg: '#fffaf0', fg: '#4a2f17', ac: '#2f8f3a', icon: 'potato' },
  { lines: ['타이어 펑크?', '참교육 정비소 24시'], bg: '#1f4fa3', fg: '#ffffff', ac: '#ffd23f', icon: 'tire' },
  { lines: ['정속주행은', '2차선에서!'], bg: '#0b7a4b', fg: '#ffffff', ac: '#ffe066', icon: 'lane' },
  { lines: ['선착순 분양중', '참교육 센트럴파크뷰'], bg: '#f4efe6', fg: '#1b2a4a', ac: '#c8102e', icon: 'apt' },
  { lines: ['한우 직판장', '다음 IC에서 5분'], bg: '#c8102e', fg: '#ffffff', ac: '#ffd23f', icon: 'cow' },
  { lines: ['영동 포도 · 안성 배', '산지 직송 특가'], bg: '#ffffff', fg: '#3b1d5a', ac: '#7b3fb8', icon: 'grape' },
];
const PLACE_EN = {
  서울: 'Seoul', 부산: 'Busan', 대전: 'Daejeon', 대구: 'Daegu', 광주: 'Gwangju', 강릉: 'Gangneung', 원주: 'Wonju',
  목포: 'Mokpo', 서산: 'Seosan', 통영: 'Tongyeong', 이천: 'Icheon', 순천: 'Suncheon', 진주: 'Jinju', 천안: 'Cheonan',
  수원: 'Suwon', 인천: 'Incheon', 평택: 'Pyeongtaek', 청주: 'Cheongju', 구미: 'Gumi', 울산: 'Ulsan',
};
const APT_BRANDS = [['행복마을', 0x2f7fc1], ['푸른숲', 0x2fa36a], ['한빛', 0xe0803a], ['참교육', 0xc8343a], ['햇살', 0xe2a72a]];

function glyphString() {
  let s = '0123456789km동.,!?·~-+%()ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz 구간단속시작방향출구휴게소졸음쉼터정체';
  for (const st of STAGES) {
    s += st.highway + st.direction + (st.vms || '') + st.title;
    for (const l of st.signs || []) s += l.join('');
  }
  s += BANNER_TEXTS.join('') + AD_LIST.map((a) => a.lines.join('')).join('') + APT_BRANDS.map((b) => b[0]).join('') + Object.keys(PLACE_EN).join('');
  return Array.from(new Set(s)).join('');
}

const _redraws = new Set();
let _redrawTimer = 0;
if (HAS_DOM && document.fonts && document.fonts.addEventListener) {
  // 폰트가 늦게 도착하면(타임아웃 이후) 이미 그린 캔버스를 다시 그린다
  document.fonts.addEventListener('loadingdone', () => {
    clearTimeout(_redrawTimer);
    _redrawTimer = setTimeout(() => { for (const f of _redraws) { try { f(); } catch (e) { /* noop */ } } }, 60);
  });
}

/**
 * 폰트 프리로드 (추가 export). 코어가 씬 빌드 전에 await.
 * Google Fonts 한글은 unicode-range 조각으로 나뉘므로, 실제로 그릴 글자들을 넘겨 해당 조각을 받는다.
 * @param {string} extraText 추가로 그릴 글자 (선택)
 * @param {number} timeoutMs 기본 2500
 * @returns {Promise<boolean>} 시간 내 로드 성공 여부 (실패해도 resolve, 늦게 오면 텍스처 자동 재그림)
 */
export async function preloadFonts(extraText = '', timeoutMs = 2500) {
  if (!HAS_DOM || !document.fonts || !document.fonts.load) return false;
  const text = glyphString() + extraText;
  const p = Promise.all([
    document.fonts.load('64px "Black Han Sans"', text),
    document.fonts.load('64px "Jua"', text),
  ]).then((r) => r.every((a) => a.length > 0)).catch(() => false);
  const t = new Promise((res) => setTimeout(() => res(false), timeoutMs));
  return Promise.race([p, t]);
}

function makeCanvas(w, h) {
  const c = document.createElement('canvas');
  c.width = w; c.height = h;
  return c;
}
function canvasTex(canvas, opts = {}) {
  const t = new THREE.CanvasTexture(canvas);
  t.colorSpace = THREE.SRGBColorSpace;
  t.anisotropy = opts.aniso || 8;
  if (opts.repeat) { t.wrapS = t.wrapT = THREE.RepeatWrapping; }
  return t;
}
/** 텍스트 텍스처: draw(ctx, w, h) 로 그리고, 폰트 늦게 오면 자동 재그림 */
function textTexture(w, h, draw, opts) {
  const cv = makeCanvas(w, h);
  const ctx = cv.getContext('2d');
  const tex = canvasTex(cv, opts);
  const redraw = () => { ctx.save(); ctx.clearRect(0, 0, w, h); draw(ctx, w, h); ctx.restore(); tex.needsUpdate = true; };
  redraw();
  _redraws.add(redraw);
  tex.userData.redraw = redraw;
  return tex;
}
function fitFont(ctx, text, family, px, maxW) {
  ctx.font = `${px}px ${family}`;
  const w = ctx.measureText(text).width;
  if (w > maxW) { px = Math.floor(px * maxW / w); ctx.font = `${px}px ${family}`; }
  return px;
}
function rrect(ctx, x, y, w, h, r) {
  ctx.beginPath();
  ctx.moveTo(x + r, y); ctx.arcTo(x + w, y, x + w, y + h, r); ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r); ctx.arcTo(x, y, x + w, y, r); ctx.closePath();
}
const _texCache = new Map();
const _matCache = new Map();
function cached(map, key, make) { let v = map.get(key); if (!v) { v = make(); map.set(key, v); } return v; }

// 공유 방사형 글로우 텍스처 (스프라이트용)
function glowTexture() {
  return cached(_texCache, 'glow', () => {
    const cv = makeCanvas(128, 128), ctx = cv.getContext('2d');
    const g = ctx.createRadialGradient(64, 64, 0, 64, 64, 64);
    g.addColorStop(0, 'rgba(255,255,255,1)'); g.addColorStop(0.25, 'rgba(255,255,255,0.55)');
    g.addColorStop(0.6, 'rgba(255,255,255,0.12)'); g.addColorStop(1, 'rgba(255,255,255,0)');
    ctx.fillStyle = g; ctx.fillRect(0, 0, 128, 128);
    return canvasTex(cv);
  });
}
function glowSpriteMat(hex) {
  return cached(_matCache, 'sprite|' + hex, () => new THREE.SpriteMaterial({
    map: glowTexture(), color: hex, blending: THREE.AdditiveBlending, transparent: true, depthWrite: false, fog: false,
  }));
}

// ─────────────────────────────────────────────────────────────
// 도로 팔레트
const PAL = {
  asphalt: 0x4b4e54, wheel: 0x44474d, oil: 0x46494f, gapAsph: 0x55585d, shoulder: 0x686b70,
  rumble: 0x878a8f, crack: 0x2a2b2f, patch: 0x3f4247,
  white: 0xf3f3ef, yellow: 0xf2c21b,
  curb: 0xb7b3a9, gravel: 0x9a9488, ditchEdge: 0xbdb9af, ditch: 0x6c6a63,
  grassA: 0x8acb5c, grassB: 0x7fbf52, tuft: 0x5f9f3f, tuft2: 0x6eae47, stem: 0x4f8a35, rock: 0x9c9a92,
  bar1: 0xb6b2a7, bar2: 0xc5c1b6, bar3: 0xd3cfc4,
  agRail: 0x285737, agFinA: 0x3fa65b, agFinB: 0x37964f, agTop: 0x5cc074,
  railHi: 0xd7dce0, railLo: 0xc4cacf, railGroove: 0x8f979f, post: 0x737a82,
  refW: 0xf7f7f7, refY: 0xffc21a,
  nbPost: 0x56616b, nbKick: 0xa29e93, nbGreen: 0x4c8c67, nbGreenRib: 0x63a67e, nbGrey: 0x98a2a8, nbGreyRib: 0xb6bec3,
  nbBlue: 0x6f93a8, nbBlueRib: 0x88abbf, nbCap: 0x47525c, nbFrame: 0x8c969e,
};
const FLOWER = [0xffffff, 0xffe14d, 0xff8fb1, 0xb48cff, 0xff6b4a];

// 방음벽 투명판 텍스처 (좌: 버드세이버 점, 우: 맹금류 스티커)
function acrylicMaterial() {
  return cached(_matCache, 'acrylic', () => {
    const W = 1024, H = 512, cv = makeCanvas(W, H), ctx = cv.getContext('2d');
    ctx.fillStyle = 'rgba(176,220,242,0.30)'; ctx.fillRect(0, 0, W, H);
    // 유리 반사 사선
    ctx.save(); ctx.globalCompositeOperation = 'source-over';
    for (const ox of [60, 560]) {
      const g = ctx.createLinearGradient(ox, 0, ox + 220, 0);
      g.addColorStop(0, 'rgba(255,255,255,0)'); g.addColorStop(0.5, 'rgba(255,255,255,0.22)'); g.addColorStop(1, 'rgba(255,255,255,0)');
      ctx.fillStyle = g; ctx.beginPath(); ctx.moveTo(ox + 120, 0); ctx.lineTo(ox + 260, 0); ctx.lineTo(ox + 140, H); ctx.lineTo(ox, H); ctx.fill();
    }
    ctx.restore();
    // 점 (패널 3.7m × 2.8m 에 512×512 매핑 → 타원 보정)
    ctx.fillStyle = 'rgba(18,22,28,0.92)';
    const cols = 15, rows = 11;
    for (let i = 0; i < cols; i++) for (let j = 0; j < rows; j++) {
      ctx.beginPath(); ctx.ellipse((i + 0.5) * 512 / cols, (j + 0.5) * H / rows, 4.6, 6.2, 0, 0, Math.PI * 2); ctx.fill();
    }
    // 맹금류 실루엣 2마리
    const hawk = (cx, cy, s, rot) => {
      ctx.save(); ctx.translate(cx, cy); ctx.rotate(rot); ctx.scale(s, s * 1.32);
      ctx.beginPath();
      ctx.moveTo(0, -18); ctx.quadraticCurveTo(6, -14, 7, -6);           // 머리→어깨
      ctx.lineTo(28, -12); ctx.lineTo(62, -4); ctx.lineTo(48, 2); ctx.lineTo(56, 6); ctx.lineTo(40, 8); ctx.lineTo(10, 6); // 오른날개
      ctx.lineTo(9, 22); ctx.lineTo(16, 40); ctx.lineTo(0, 34); ctx.lineTo(-16, 40); ctx.lineTo(-9, 22);   // 꼬리
      ctx.lineTo(-10, 6); ctx.lineTo(-40, 8); ctx.lineTo(-56, 6); ctx.lineTo(-48, 2); ctx.lineTo(-62, -4); ctx.lineTo(-28, -12); ctx.lineTo(-7, -6);
      ctx.quadraticCurveTo(-6, -14, 0, -18); ctx.closePath(); ctx.fill(); ctx.restore();
    };
    hawk(512 + 150, 150, 1.25, -0.15); hawk(512 + 360, 330, 1.05, 0.2);
    const tex = canvasTex(cv);
    return new THREE.MeshLambertMaterial({ map: tex, transparent: true, depthWrite: false, side: THREE.DoubleSide, name: 'scenery.acrylic' });
  });
}

// ─────────────────────────────────────────────────────────────
// 도로 세그먼트
const ROAD_VARIANTS = 4;
const _roadCache = new Map();
function normSB(v) { return v === 'left' || v === 'right' || v === 'both' ? v : null; }

function buildRoadGeo(length, night, sb, variant) {
  const r = rng(1013 + variant * 7919);
  const G = new GB();                  // 노면·잔디 (그림자 받기만)
  const S = new GB();                  // 구조물 (그림자 드리움)
  const N = night ? new GB() : null;   // 야간 발광 (차선 재귀반사, 반사체)
  const A = sb ? new GB(true) : null;  // 방음벽 투명판
  const LN = night ? N : G, DL = night ? N : S;
  const z0 = 0, z1 = -length, zc = -length / 2;
  const LY = 0.02;
  const cWhite = night ? 0xc6cbd4 : PAL.white;
  const cYellow = night ? 0xdcaa22 : PAL.yellow;
  const cRefW = night ? 0xf0f4ff : PAL.refW, cRefY = night ? 0xffc83c : PAL.refY;

  // 1) 노면 띠 (차선마다 바퀴자국 살짝 어둡게)
  const xs = [];
  const lane = (cx) => xs.push(
    [cx - 1.8, cx - 1.2, PAL.asphalt], [cx - 1.2, cx - 0.6, PAL.wheel], [cx - 0.6, cx - 0.15, PAL.asphalt],
    [cx - 0.15, cx + 0.15, PAL.oil], [cx + 0.15, cx + 0.6, PAL.asphalt], [cx + 0.6, cx + 1.2, PAL.wheel], [cx + 1.2, cx + 1.8, PAL.asphalt]);
  xs.push([SH_L, OPP_OUT, PAL.shoulder]);
  for (let j = 0; j < NUM_LANES; j++) lane(OPP_LANE_X(j));
  xs.push([OPP_IN, MED_L, PAL.gapAsph], [MED_L, MED_R, PAL.bar1], [MED_R, ROAD_LEFT, PAL.gapAsph]);
  for (let i = 0; i < NUM_LANES; i++) lane(laneX(i));
  xs.push([ROAD_RIGHT, SH_R, PAL.shoulder]);
  for (const [a, b, c] of xs) G.top(a, b, z0, z1, 0, c);

  // 2) 연석·자갈·배수로·잔디 (양쪽), 잔디는 20m 마다 명암 교차 (Crossy 풍 질주감)
  for (const side of [1, -1]) {
    const base = side > 0 ? SH_R : SH_L;
    const X = (d) => base + side * d;
    const far = VERGE_X - Math.abs(base);
    G.box(X(CURB_W / 2), 0, zc, CURB_W, 0.1, length, PAL.curb, { nb: true });
    const strips = [[CURB_W, 0.85, PAL.gravel, false], [0.85, 1.2, null, true], [1.2, 1.3, PAL.ditchEdge, false], [1.3, 1.7, PAL.ditch, false],
      [1.7, 1.8, PAL.ditchEdge, false], [1.8, far, null, true]];
    for (const [d0, d1, col, grass] of strips) {
      const xa = Math.min(X(d0), X(d1)), xb = Math.max(X(d0), X(d1));
      if (!grass) { G.top(xa, xb, z0, z1, 0, col); continue; }
      for (let s = 0; s < length; s += 20) {
        const band = Math.floor(s / 20) % 2;
        G.top(xa, xb, -s, -Math.min(s + 20, length), 0, band ? PAL.grassB : PAL.grassA);
      }
    }
    // 잔디 디테일: 풀 덤불, 꽃, 돌
    const nbHere = sb === 'both' || (sb === 'right' && side > 0) || (sb === 'left' && side < 0);
    for (let k = 0; k < 34; k++) {
      const d = 2.2 + r() * (far - 3), s = r() * length;
      if (nbHere && Math.abs(d - NB_OFF) < 0.6) continue;
      const x = X(d), z = -s, t = r();
      if (t < 0.55) {
        G.box(x, 0, z, 0.42, 0.22 + r() * 0.16, 0.42, r() < 0.5 ? PAL.tuft : PAL.tuft2, { nb: true, ry: r() * 1.5 });
        if (r() < 0.5) G.box(x + 0.25, 0, z + 0.2, 0.26, 0.16, 0.26, PAL.tuft2, { nb: true });
      } else if (t < 0.85) {
        G.box(x, 0, z, 0.06, 0.24, 0.06, PAL.stem, { nb: true });
        G.box(x, 0.24, z, 0.2, 0.16, 0.2, FLOWER[(r() * FLOWER.length) | 0]);
      } else {
        G.box(x, 0, z, 0.55 + r() * 0.3, 0.26, 0.45, PAL.rock, { nb: true, ry: r() * 1.5, top: 0xb0aea6 });
      }
    }
  }

  // 3) 차선 도색
  LN.top(ROAD_LEFT + 0.06, ROAD_LEFT + 0.28, z0, z1, LY, cYellow);         // 1차선 왼쪽 노란 실선
  LN.top(OPP_IN - 0.28, OPP_IN - 0.06, z0, z1, LY, cYellow);                // 반대편 노란 실선
  LN.top(ROAD_RIGHT - 0.11, ROAD_RIGHT + 0.11, z0, z1, LY, cWhite);         // 우측 가장자리 흰 실선
  LN.top(OPP_OUT - 0.11, OPP_OUT + 0.11, z0, z1, LY, cWhite);
  const dashXs = [];
  for (let i = 1; i < NUM_LANES; i++) dashXs.push(laneX(i) - 1.8);
  for (let j = 0; j < NUM_LANES - 1; j++) dashXs.push(OPP_LANE_X(j) - 1.8);
  // 점선: 6m 도색 + 4m 공백 (주기 10m → SEG_LEN 40m 에 정확히 4번, 이음매는 공백 안)
  for (const x of dashXs) for (let s = 2; s < length; s += 10) LN.top(x - 0.1, x + 0.1, -s, -Math.min(s + 6, length), LY, cWhite);

  // 4) 갓길 요철(럼블스트립)
  for (let s = 0.2; s < length; s += 0.6) {
    G.top(ROAD_RIGHT + 0.45, ROAD_RIGHT + 1.1, -s, -(s + 0.2), 0.012, PAL.rumble);
    G.top(OPP_OUT - 1.1, OPP_OUT - 0.45, -s, -(s + 0.2), 0.012, PAL.rumble);
  }

  // 5) 크랙 실링(검은 지렁이) & 보수 패치 — 변형마다 다름
  const laneCs = [];
  for (let i = 0; i < NUM_LANES; i++) laneCs.push(laneX(i));
  for (let j = 0; j < NUM_LANES; j++) laneCs.push(OPP_LANE_X(j));
  const nCr = 1 + ((r() * 2) | 0);
  for (let k = 0; k < nCr; k++) {
    let x = laneCs[(r() * laneCs.length) | 0] + (r() - 0.5) * 2.2, s = 1 + r() * (length - 6);
    const n = 2 + ((r() * 3) | 0);
    for (let q = 0; q < n; q++) {
      const x2 = x + (r() - 0.5) * 0.9, s2 = Math.min(length - 0.5, s + 0.5 + r() * 1.0);
      const dx = x2 - x, dz = -(s2 - s), l = Math.hypot(dx, dz) || 1, px = (-dz / l) * 0.05, pz = (dx / l) * 0.05;
      G.flat([[x - px, -s - pz], [x + px, -s + pz], [x2 + px, -s2 + pz], [x2 - px, -s2 - pz]], 0.008, PAL.crack);
      x = x2; s = s2;
    }
  }
  if (r() < 0.5) {
    const cx = laneCs[(r() * laneCs.length) | 0] + (r() - 0.5) * 1.2, s = 2 + r() * (length - 8), w = 1.6 + r() * 1.2, l = 2 + r() * 2.5;
    G.top(cx - w / 2, cx + w / 2, -s, -(s + l), 0.006, PAL.patch);
  }

  // 6) 중앙분리대 (계단형 저지 방호벽) + 녹색 눈부심방지판
  S.box(MEDIAN_X, 0, zc, MEDIAN_W, 0.2, length, PAL.bar1, { nb: true });
  S.box(MEDIAN_X, 0.2, zc, 0.64, 0.35, length, PAL.bar2, { nb: true });
  S.box(MEDIAN_X, 0.55, zc, 0.36, 0.3, length, PAL.bar3, { nb: true });
  S.box(MEDIAN_X, 0.85, zc, 0.12, 0.1, length, PAL.agRail, { nb: true });
  // 판 간격 0.4m (40m 에 100장), 폭 0.42m. 판면이 '우후방 위' 추격 카메라를 향하도록 −Y 회전 →
  // 게임 시점에서는 겹쳐서 녹색 띠로 보이고, 정면 시점에서는 살(slat)이 보인다.
  for (let s = 0.2, k = 0; s < length; s += 0.4, k++) {
    S.box(MEDIAN_X, 0.9, -s, 0.06, 0.72, 0.42, k % 2 ? PAL.agFinA : PAL.agFinB, { ry: -0.62, nb: true, top: PAL.agTop });
  }
  // 분리대 노란 반사체 (양쪽 면)
  for (let s = 4; s < length; s += 8) {
    DL.box(MEDIAN_X + 0.335, 0.33, -s, 0.04, 0.13, 0.24, cRefY);
    DL.box(MEDIAN_X - 0.335, 0.33, -s, 0.04, 0.13, 0.24, cRefY);
  }

  // 7) W빔 가드레일 (양쪽 바깥)
  for (const side of [1, -1]) {
    const base = side > 0 ? SH_R : SH_L;
    const X = (d) => base + side * d;
    for (let s = 2; s < length; s += 4) {
      S.box(X(GR_OFF + 0.2), 0, -s, 0.16, 0.95, 0.16, PAL.post, { nb: true, top: 0x8d949b });
      S.box(X(GR_OFF + 0.09), 0.5, -s, 0.1, 0.32, 0.14, PAL.post);
    }
    S.box(X(GR_OFF), 0.72, zc, 0.07, 0.15, length, PAL.railHi, { top: 0xe4e8eb });
    S.box(X(GR_OFF + 0.035), 0.65, zc, 0.05, 0.07, length, PAL.railGroove);
    S.box(X(GR_OFF), 0.51, zc, 0.07, 0.14, length, PAL.railLo);
    for (let s = 6; s < length; s += 8) DL.box(X(GR_OFF + 0.2), 0.95, -s, 0.09, 0.17, 0.05, cRefW);
  }

  // 8) 방음벽
  const sbSides = sb === 'both' ? [1, -1] : sb === 'right' ? [1] : sb === 'left' ? [-1] : [];
  for (const side of sbSides) {
    const base = side > 0 ? SH_R : SH_L;
    const bx = base + side * NB_OFF;
    const toRoad = -side;
    for (let s = 0; s < length; s += 4) {
      S.box(bx, 0, -s, 0.32, 5.15, 0.32, PAL.nbPost, { nb: true, top: 0x6a7580 });
      S.box(bx, 0, -s, 0.5, 0.25, 0.5, PAL.nbKick, { nb: true });
    }
    S.box(bx, 0, zc, 0.26, 0.6, length, PAL.nbKick, { nb: true, top: 0xb4b0a6 });
    S.box(bx, 4.85, zc, 0.24, 0.22, length, PAL.nbCap);
    let type = r() < 0.65 ? 'clear' : 'metal', run = 1 + ((r() * 3) | 0);
    let metal = r() < 0.6 ? 0 : r() < 0.5 ? 1 : 2;
    const MET = [[PAL.nbGreen, PAL.nbGreenRib], [PAL.nbGrey, PAL.nbGreyRib], [PAL.nbBlue, PAL.nbBlueRib]];
    for (let b = 0; b * 4 < length; b++) {
      if (run-- <= 0) {
        type = type === 'clear' ? (r() < 0.6 ? 'metal' : 'clear') : (r() < 0.75 ? 'clear' : 'metal');
        run = 1 + ((r() * 3) | 0);
        if (r() < 0.3) metal = (r() * 3) | 0;
      }
      const zb = -(b * 4 + 2), y1 = type === 'clear' ? 2.0 : 4.85;
      const [mc, rc] = MET[metal];
      S.box(bx, 0.6, zb, 0.12, y1 - 0.6, 3.68, mc);
      for (let y = 0.82; y < y1 - 0.15; y += 0.36) S.box(bx + toRoad * 0.075, y, zb, 0.03, 0.12, 3.68, rc, { nb: true });
      if (type === 'clear') {
        S.box(bx, 1.95, zb, 0.2, 0.14, 3.68, PAL.nbFrame);
        const hawk = r() < 0.3;
        A.vquadX(bx, -(b * 4 + 0.16), -(b * 4 + 3.84), 2.09, 4.85, toRoad, 0xffffff, hawk ? 0.5 : 0, hawk ? 1 : 0.5, 0, 1);
      }
    }
  }

  return {
    ground: G.build(), struct: S.build(),
    glow: N && !N.empty ? N.build() : null,
    glass: A && !A.empty ? A.build() : null,
  };
}

/**
 * 도로 세그먼트 1개. s ∈ [0,length] (z: 0 → −length).
 * 메시: road(노면·잔디, receiveShadow) + struct(분리대·눈부심판·가드레일·방음벽, cast+receive)
 *       [+ glow(야간 차선·반사체 발광)] [+ glass(방음벽 투명판)] → draw call 2~4.
 * 지오메트리는 (length, night, soundBarrier, seed%4) 로 캐시·공유.
 * @param {number} length
 * @param {{night?:boolean, soundBarrier?:'left'|'right'|'both'|null, seed?:number}} opts
 */
export function buildRoadSegment(length = SEG_LEN, opts = {}) {
  const night = !!opts.night, sb = normSB(opts.soundBarrier), seed = opts.seed | 0;
  const variant = ((seed % ROAD_VARIANTS) + ROAD_VARIANTS) % ROAD_VARIANTS;
  const key = `${length}|${night ? 1 : 0}|${sb || '-'}|${variant}`;
  const geo = cached(_roadCache, key, () => buildRoadGeo(length, night, sb, variant));
  const g = new THREE.Group();
  g.name = 'roadSegment';
  const road = new THREE.Mesh(geo.ground, MAT.vc);
  road.name = 'road'; road.receiveShadow = true;
  const struct = new THREE.Mesh(geo.struct, MAT.vc);
  struct.name = 'struct'; struct.castShadow = true; struct.receiveShadow = true;
  g.add(road, struct);
  if (geo.glow) { const m = new THREE.Mesh(geo.glow, MAT.glow); m.name = 'glow'; g.add(m); }
  if (geo.glass) { const m = new THREE.Mesh(geo.glass, acrylicMaterial()); m.name = 'glass'; m.renderOrder = 2; g.add(m); }
  g.userData = { kind: 'roadSegment', length, night, soundBarrier: sb, seed, drawCalls: g.children.length };
  return g;
}

/**
 * 거대 잔디 바닥 (추가 export). 세그먼트 잔디(|x|≤60) 바깥을 채운다. y = −0.06, receiveShadow.
 * 카메라를 따라 x/z 를 40m 단위로 스냅해 옮기면 끝없이 보인다.
 * @param {{size?:number, color?:number, night?:boolean}} opts
 */
export function makeGround(opts = {}) {
  const size = opts.size || 3000;
  const key = 'ground|' + (opts.color || 0) + '|' + (opts.night ? 1 : 0);
  const mat = cached(_matCache, key, () => {
    // 멀리 보이는 들판 패치워크 (논·밭·풀) 텍스처
    const S = 256, cv = makeCanvas(S, S), ctx = cv.getContext('2d');
    const base = opts.color != null ? '#' + opts.color.toString(16).padStart(6, '0') : '#7fbd53';
    ctx.fillStyle = base; ctx.fillRect(0, 0, S, S);
    const r = rng(77);
    const fields = ['#82c057', '#78b64e', '#88c75d', '#74b14c', '#8ac862', '#7cbc5f', '#93c762'];
    for (let i = 0; i < 26; i++) {
      ctx.fillStyle = fields[(r() * fields.length) | 0];
      const w = 30 + r() * 70, h = 30 + r() * 70;
      ctx.fillRect(r() * S, r() * S, w, h);
    }
    ctx.globalAlpha = 0.18; ctx.fillStyle = '#4f8a35';
    for (let i = 0; i < 400; i++) ctx.fillRect(r() * S, r() * S, 2, 2);
    const tex = canvasTex(cv, { repeat: true, aniso: 4 });
    tex.repeat.set(size / 160, size / 160);
    tex.magFilter = THREE.NearestFilter;
    return new THREE.MeshLambertMaterial({ map: tex, name: 'scenery.ground' });
  });
  const geo = new THREE.PlaneGeometry(size, size, 1, 1).rotateX(-Math.PI / 2);
  const m = new THREE.Mesh(geo, mat);
  m.position.y = -0.06;
  m.receiveShadow = true;
  m.name = 'ground';
  return m;
}

// ─────────────────────────────────────────────────────────────
// 터널 (v0.4) — 갓길 없는 4차로 터널 구간 + 입구 포털
//
// 가설: 추격캠(뒤 16m·위 12.5m)은 터널 천장보다 높다 → 천장을 "안쪽만 보이는 단면(단면 컷어웨이)"으로 만들면
//       밖(위)에서는 백페이스 컬링으로 자동으로 잘려 차가 절대 가려지지 않고, 안쪽 낮은 카메라(인트로·킬캠)에서는
//       아치·제트팬·천장등이 다 보이는 진짜 터널이 된다. 볼록 단면이라 바깥 카메라→차 시선은 항상 뒷면만 지난다.
//  - 측벽 안쪽 면 |x| = wallX(8.55): 4차로(±7.2) + 0.35 측방여유 + 1.0m 검사원 보도 → 갓길(x 7.2~10.2)·갓길 차로(4)는 막힘
//  - 아치 위 바깥은 산(지붕) 단면: 측벽선의 어두운 암반면 + 높이 capY 의 잔디 윗면 → 바깥 소품·반대편 도로가 비치지 않음
//  - 주황 나트륨 줄조명 = 측벽 위(아치 어깨) 연속 등기구(위에서도 보임) + 천장 2줄(아래에서만 보임) + 노면/벽 가산 빛웅덩이
//  - 그림자: 셸은 castShadow=false (그림자 카메라 범위 밖이 밝게 튀는 문제 회피). 터널 안 어둠은 굽기 색 + userData.ambience 로
// ─────────────────────────────────────────────────────────────
/** 터널 치수 (추가 export). 전부 월드 m. */
export const TUNNEL = Object.freeze({
  wallX: 8.55,      // 측벽 안쪽 면 |x|
  walkX: 7.55,      // 노면 끝 = 보도 연석 |x|
  walkH: 0.25,      // 보도 높이
  springY: 3.0,     // 직벽 → 아치 시작
  crownY: 8.0,      // 천장 꼭대기 (안쪽)
  capY: 9.2,        // 산 윗면 (컷어웨이 단면 높이)
  portalTopY: 10.3, // 포털 현판부 꼭대기
  boardY: 9.1,      // 현판 중심 높이 (아치 꼭대기 바로 위 — 추격캠이 포털 30~45m 앞에서 화면 위쪽에 잡음)
  approach: 14,     // 포털 앞(+Z) 날개벽·비탈 길이
});
const TN = TUNNEL;
const TPAL = {
  asph: 0x47443f, wheel: 0x3e3c39, oil: 0x413f3c, gutter: 0x5a5650, white: 0xe9e9e2, yellow: 0xe8b81a,
  walk: 0xa8a398, walkTop: 0xb9b4a8, curbLine: 0xf2c21b,
  kick: 0x585b60, tile: 0xe4ddca, tileSeam: 0xb9b2a0, band: 0x2f8f5b, upper: 0xb49a78,
  archLo: 0xa98f6e, archHi: 0x585654, ring: 0x4a4846,
  rockLo: 0x241f1b, rockHi: 0x3b322a, cut: 0x6e5034, cutDark: 0x4f3926,
  housing: 0x34363b, lampRim: 0xff9a2e, lampCore: 0xffe2a0, led: 0xc8f4ff, exitG: 0x1fae5a,
  hydrant: 0xd8342c, fan: 0x8d9298, fanDark: 0x2b2d32,
  facade: 0xcdc6b6, facadeDark: 0xa8a294, portalRing: 0x8f8a7e, wing: 0xbdb7a9,
};
const _qn = (a, b, c) => { const ux = b[0] - a[0], uy = b[1] - a[1], uz = b[2] - a[2], vx = c[0] - a[0], vy = c[1] - a[1], vz = c[2] - a[2]; return [uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx]; };
/** 원하는 법선 n 쪽을 앞면으로 하는 사각형 (단색) */
function qf(G, a, b, c, d, col, n) { const k = _qn(a, b, c); if (k[0] * n[0] + k[1] * n[1] + k[2] * n[2] < 0) G.quad(a, d, c, b, col); else G.quad(a, b, c, d, col); }
/** 원하는 법선 n 쪽을 앞면으로 하는 사각형 (정점색 a,b,c,d) */
function qfC(G, a, b, c, d, ca, cb, cc, cd, n) {
  const k = _qn(a, b, c);
  if (k[0] * n[0] + k[1] * n[1] + k[2] * n[2] < 0) { G.triC(a, d, c, ca, cd, cc); G.triC(a, c, b, ca, cc, cb); }
  else { G.triC(a, b, c, ca, cb, cc); G.triC(a, c, d, ca, cc, cd); }
}
/** 아치 단면 점 i/N (0 = 왼쪽 직벽 위, N = 오른쪽). 타원: 반폭 wallX, 높이 crownY-springY */
function archPt(i, N) { const th = Math.PI * (1 - i / N); return [TN.wallX * Math.cos(th), TN.springY + (TN.crownY - TN.springY) * Math.sin(th)]; }
/** 아치 면 i 의 안쪽 법선 [nx, ny] */
function archN(i, N) {
  const a = archPt(i, N), b = archPt(i + 1, N), dx = b[0] - a[0], dy = b[1] - a[1];
  let nx = -dy, ny = dx; const mx = (a[0] + b[0]) / 2, my = (a[1] + b[1]) / 2;
  if (nx * (0 - mx) + ny * (TN.springY - my) < 0) { nx = -nx; ny = -ny; }
  const l = Math.hypot(nx, ny); return [nx / l, ny / l];
}
/** 아래(-Y)를 보는 면만 굽는 원기둥 (z 축) → 위(추격캠)에서는 안 보이고 터널 안 낮은 카메라에서만 보임 */
function undersideCylZ(G, cx, cy, z0, z1, r, n, col, colEnd) {
  for (let i = 0; i < n; i++) {
    const a0 = (i / n) * Math.PI * 2, a1 = ((i + 1) / n) * Math.PI * 2, am = (a0 + a1) / 2;
    const nx = Math.cos(am), ny = Math.sin(am);
    if (ny > -0.45) continue;
    const p = (a, z) => [cx + Math.cos(a) * r, cy + Math.sin(a) * r, z];
    qf(G, p(a0, z0), p(a1, z0), p(a1, z1), p(a0, z1), i % 2 ? col : colEnd, [nx, ny, 0]);
  }
}
const _tunnelCache = new Map();
function buildTunnelGeo(length, night, variant, opts) {
  const r = rng(4049 + variant * 6151);
  const G = new GB(), S = new GB(), N = new GB(), A = new GB();
  const z0 = 0, z1 = -length, zc = -length / 2, LY = 0.02, NA = 18;
  const band = opts.band ?? TPAL.band;

  // ── 1) 노면 (바퀴자국 띠) + 측방 배수로 + 차선 (터널 = 진로변경 제한 흰 실선)
  const xs = [];
  for (let i = 0; i < NUM_LANES; i++) {
    const cx = laneX(i);
    xs.push([cx - 1.8, cx - 1.2, TPAL.asph], [cx - 1.2, cx - 0.6, TPAL.wheel], [cx - 0.6, cx - 0.15, TPAL.asph],
      [cx - 0.15, cx + 0.15, TPAL.oil], [cx + 0.15, cx + 0.6, TPAL.asph], [cx + 0.6, cx + 1.2, TPAL.wheel], [cx + 1.2, cx + 1.8, TPAL.asph]);
  }
  xs.push([-TN.walkX, ROAD_LEFT, TPAL.gutter], [ROAD_RIGHT, TN.walkX, TPAL.gutter]);
  for (const [a, b, c] of xs) G.top(a, b, z0, z1, 0, c);
  G.top(ROAD_LEFT + 0.06, ROAD_LEFT + 0.28, z0, z1, LY, TPAL.yellow);
  G.top(ROAD_RIGHT - 0.11, ROAD_RIGHT + 0.11, z0, z1, LY, TPAL.white);
  for (let i = 1; i < NUM_LANES; i++) { const x = laneX(i) - LANE_W / 2; G.top(x - 0.08, x + 0.08, z0, z1, LY, TPAL.white); }
  for (let s = 5; s < length; s += 10) for (const sd of [-1, 1]) G.top(sd * TN.walkX - (sd > 0 ? 0.3 : 0), sd * TN.walkX + (sd < 0 ? 0.3 : 0), -s, -(s + 0.8), 0.006, 0x2c2b29); // 배수구

  // ── 2) 검사원 보도 (연석 노란 줄 + 호박 반사체)
  for (const sd of [-1, 1]) {
    const w = TN.wallX - TN.walkX + 0.05;
    G.box(sd * (TN.walkX + w / 2), 0, zc, w, TN.walkH, length, TPAL.walk, { top: TPAL.walkTop, nb: true });
    G.box(sd * (TN.walkX + 0.06), TN.walkH, zc, 0.12, 0.012, length, TPAL.curbLine, { nb: true });
    for (let s = 2.5; s < length; s += 5) N.box(sd * (TN.walkX - 0.01), 0.08, -s, 0.03, 0.1, 0.18, 0xffb21c);
  }

  // ── 3) 측벽 (안쪽만): 걸레받이 / 타일 / 색띠 / 타일 / 윗벽(조명 반사로 따뜻하게)
  const bands = [[TN.walkH, 0.75, TPAL.kick, TPAL.kick], [0.75, 1.2, TPAL.tile, TPAL.tile], [1.2, 1.45, band, band],
    [1.45, 2.5, TPAL.tile, mixC(TPAL.tile, 0xffb060, 0.18)], [2.5, TN.springY, mixC(TPAL.upper, 0xffa040, 0.15), TPAL.upper]];
  for (const sd of [-1, 1]) {
    const x = sd * TN.wallX, n = [-sd, 0, 0];
    for (const [y0, y1, c0, c1] of bands) qfC(S, [x, y0, z0], [x, y0, z1], [x, y1, z1], [x, y1, z0], c0, c0, c1, c1, n);
    for (let s = 0; s < length; s += 2.5) { const xx = x - sd * 0.008; qf(S, [xx, 0.75, -s], [xx, 0.75, -(s + 0.05)], [xx, 2.5, -(s + 0.05)], [xx, 2.5, -s], TPAL.tileSeam, n); }
    // 시선유도등 (LED, 4m 마다) + 비상구 표지(녹색, 오른쪽) / 소화전함(빨강, 왼쪽)
    for (let s = 2; s < length; s += 4) N.box(x - sd * 0.04, 0.95, -s, 0.08, 0.1, 0.1, TPAL.led);
    const se = length * 0.5 + (sd > 0 ? 0 : 10);
    if (sd > 0) {
      N.box(x - sd * 0.05, 2.0, -se, 0.08, 0.42, 0.95, TPAL.exitG);
      N.box(x - sd * 0.1, 2.12, -se + 0.2, 0.02, 0.18, 0.14, 0xffffff);               // 달리는 사람(약식)
      N.box(x - sd * 0.1, 2.16, -se - 0.12, 0.02, 0.06, 0.36, 0xffffff);              // 화살표
    } else {
      S.box(x - sd * 0.12, 0.85, -se, 0.24, 1.0, 0.8, TPAL.hydrant, { top: 0xe8524a });
      S.box(x - sd * 0.245, 0.98, -se, 0.012, 0.74, 0.6, 0xf4f4f2);
      S.box(x - sd * 0.25, 1.02, -se, 0.012, 0.66, 0.52, TPAL.hydrant);
    }
  }

  // ── 4) 아치 천장 (안쪽만) + 10m 마다 라이닝 이음 띠
  for (let i = 0; i < NA; i++) {
    const a = archPt(i, NA), b = archPt(i + 1, NA), [nx, ny] = archN(i, NA), n = [nx, ny, 0];
    const t0 = Math.abs(a[1] - TN.springY) / (TN.crownY - TN.springY), t1 = Math.abs(b[1] - TN.springY) / (TN.crownY - TN.springY);
    const ca = mixC(TPAL.archLo, TPAL.archHi, Math.pow(t0, 0.7)), cb = mixC(TPAL.archLo, TPAL.archHi, Math.pow(t1, 0.7));
    qfC(S, [a[0], a[1], z0], [a[0], a[1], z1], [b[0], b[1], z1], [b[0], b[1], z0], ca, ca, cb, cb, n);
    for (let s = 0; s < length; s += 10) {
      const o = 0.02, A0 = [a[0] + nx * o, a[1] + ny * o], B0 = [b[0] + nx * o, b[1] + ny * o];
      qf(S, [A0[0], A0[1], -s], [A0[0], A0[1], -(s + 0.3)], [B0[0], B0[1], -(s + 0.3)], [B0[0], B0[1], -s], TPAL.ring, n);
    }
  }

  // ── 5) 산 단면: 측벽선 암반면(안쪽을 봄) + 윗면(흙 단면 띠 + 잔디) + 바깥 끝 비탈
  for (const sd of [-1, 1]) {
    const x = sd * TN.wallX;
    qfC(S, [x, TN.springY, z0], [x, TN.springY, z1], [x, TN.capY, z1], [x, TN.capY, z0], TPAL.rockLo, TPAL.rockLo, TPAL.rockHi, TPAL.rockHi, [-sd, 0, 0]);
    const xa = x, xb = x + sd * 0.5, xc = x + sd * 1.6, far = sd * 60;
    qf(S, [xa, TN.capY, z0], [xb, TN.capY, z0], [xb, TN.capY, z1], [xa, TN.capY, z1], TPAL.cutDark, [0, 1, 0]);
    qf(S, [xb, TN.capY, z0], [xc, TN.capY, z0], [xc, TN.capY, z1], [xb, TN.capY, z1], TPAL.cut, [0, 1, 0]);
    for (let s = 0; s < length; s += 20) {
      const band2 = Math.floor(s / 20) % 2 ? PAL.grassB : PAL.grassA, za = -s, zb = -Math.min(s + 20, length);
      qf(S, [xc, TN.capY, za], [far, TN.capY, za], [far, TN.capY, zb], [xc, TN.capY, zb], band2, [0, 1, 0]);
    }
    qf(S, [far, TN.capY, z0], [far, 0, z0], [far, 0, z1], [far, TN.capY, z1], PAL.tuft, [sd, 0, 0]);
    // 산 위 소나무·덤불 (바깥쪽, 추격캠 가장자리 장식)
    for (let k = 0; k < 4; k++) {
      const x2 = sd * (12 + r() * 40), z2 = -(r() * length), h = 3 + r() * 3;
      if (r() < 0.65) {
        S.box(x2, TN.capY, z2, 0.35, h * 0.3, 0.35, 0x7a5a3a, { nb: true });
        S.geo(PRIM.cone6, M4(x2, TN.capY + h * 0.22, z2, h * 0.36, h * 0.8, h * 0.36, r() * 3), 0x2f6b3a);
      } else S.box(x2, TN.capY, z2, 1.2 + r(), 0.6, 1.0 + r(), PAL.tuft, { nb: true, ry: r() * 1.5, top: PAL.tuft2 });
    }
  }

  // ── 6) 줄조명: 아치 어깨(직벽 바로 위) 연속 등기구 — 위(추격캠)에서도 벽 따라 주황 줄로 읽힘
  const LA = 0.21; // 아치 어깨 각(rad) ≈ 12°
  for (const sd of [-1, 1]) {
    const lx = sd * TN.wallX * Math.cos(LA) - sd * 0.12, ly = TN.springY + (TN.crownY - TN.springY) * Math.sin(LA) - 0.05;
    const rz = sd * 0.6; // 얼굴이 도로 쪽 아래를 봄
    for (let s = 1; s < length; s += 2) {
      S.box(lx + sd * 0.05, ly - 0.16, -s - 0.75, 0.24, 0.32, 1.5, TPAL.housing, { rz });
      N.box(lx - sd * 0.06, ly - 0.12, -s - 0.75, 0.06, 0.24, 1.36, TPAL.lampRim, { rz });
      N.box(lx - sd * 0.09, ly - 0.08, -s - 0.75, 0.03, 0.14, 1.2, TPAL.lampCore, { rz });
    }
  }
  // 천장 2줄 등 (아래만 보이는 판) + 제트팬 1쌍 (아래만)
  for (const sd of [-1, 1]) {
    const lx = sd * 4.3, ly = TN.springY + (TN.crownY - TN.springY) * Math.sqrt(1 - (4.3 / TN.wallX) ** 2) - 0.12;
    for (let s = 3; s < length; s += 4) {
      const za = -s, zb = -(s + 2.2);
      qf(N, [lx - 0.22, ly, za], [lx + 0.22, ly, za], [lx + 0.22, ly, zb], [lx - 0.22, ly, zb], TPAL.lampRim, [0, -1, 0]);
      qf(N, [lx - 0.12, ly - 0.01, za - 0.1], [lx + 0.12, ly - 0.01, za - 0.1], [lx + 0.12, ly - 0.01, zb + 0.1], [lx - 0.12, ly - 0.01, zb + 0.1], TPAL.lampCore, [0, -1, 0]);
    }
    if (opts.fans !== false) {
      const fx = sd * 2.6, fy = TN.crownY - 1.05, fz = -length * 0.5;
      undersideCylZ(S, fx, fy, fz + 1.7, fz - 1.7, 0.52, 12, TPAL.fan, mixC(TPAL.fan, 0x000000, 0.12));
      undersideCylZ(S, fx, fy, fz + 1.75, fz + 1.45, 0.56, 12, TPAL.fanDark, TPAL.fanDark);
      undersideCylZ(S, fx, fy, fz - 1.45, fz - 1.75, 0.56, 12, TPAL.fanDark, TPAL.fanDark);
    }
  }

  // ── 7) 가산 빛웅덩이 (나트륨 주황): 벽 아래 노면 띠 + 등기구 아래 벽면
  const glowC = 0x6a3a08, glowW = 0x7a4410, black = 0x000000;
  for (const sd of [-1, 1]) {
    const xe = sd * TN.walkX, xi = sd * 3.2;
    qfC(A, [xe, 0.03, z0], [xe, 0.03, z1], [xi, 0.03, z1], [xi, 0.03, z0], glowC, glowC, black, black, [0, 1, 0]);
    const xw = sd * (TN.wallX - 0.03);
    qfC(A, [xw, 1.0, z0], [xw, 1.0, z1], [xw, TN.springY + 1.0, z1], [xw, TN.springY + 1.0, z0], black, black, glowW, glowW, [-sd, 0, 0]);
  }
  return { road: G.build(), shell: S.build(), glow: N.build(), add: A.build() };
}

/**
 * 터널 구간 1개 (추가 export). buildRoadSegment 와 같은 규약: s ∈ [0,length] (z: 0 → −length), 원점 = 구간 시작 x=0.
 * 메시 4개 = draw call 4: road(노면·보도, receiveShadow) / shell(측벽·아치·산 단면·제트팬, 안쪽만) / glow(등기구·유도등, 발광) / light(가산 빛웅덩이)
 * 반대편 차로·중앙분리대·갓길·가드레일 없음 (터널 = 한 방향 단독 터널). |x| > wallX 는 산 단면이 덮는다.
 * @param {number} length 기본 SEG_LEN
 * @param {{night?:boolean, seed?:number, band?:number, fans?:boolean}} opts  band: 측벽 색띠 색 (터널마다 다르게), fans: 제트팬(기본 true)
 * userData: { kind:'tunnelSegment', length, wallX, crownY, capY, shoulder:false, ambience } — ambience = 터널 안 권장 조명(코어가 보간)
 */
export function buildTunnelSegment(length = SEG_LEN, opts = {}) {
  const night = !!opts.night, seed = opts.seed | 0;
  const variant = ((seed % ROAD_VARIANTS) + ROAD_VARIANTS) % ROAD_VARIANTS;
  const key = `tunnel|${length}|${night ? 1 : 0}|${variant}|${opts.band ?? '-'}|${opts.fans === false ? 0 : 1}`;
  const geo = cached(_tunnelCache, key, () => buildTunnelGeo(length, night, variant, opts));
  const g = new THREE.Group();
  g.name = 'tunnelSegment';
  const road = new THREE.Mesh(geo.road, MAT.vc); road.name = 'road'; road.receiveShadow = true;
  const shell = new THREE.Mesh(geo.shell, MAT.vc); shell.name = 'shell'; shell.receiveShadow = true;
  const glow = new THREE.Mesh(geo.glow, MAT.glow); glow.name = 'glow';
  const light = new THREE.Mesh(geo.add, MAT.additive); light.name = 'light'; light.renderOrder = 1;
  g.add(road, shell, glow, light);
  g.userData = {
    kind: 'tunnelSegment', length, night, seed, wallX: TN.wallX, crownY: TN.crownY, capY: TN.capY, shoulder: false,
    ambience: TUNNEL_AMBIENCE, drawCalls: 4,
  };
  return g;
}
/** 터널 안 권장 조명 (추가 export): 코어가 플레이어가 터널 안일 때 world.hemi/sun/fog 를 이 값으로 보간 */
export const TUNNEL_AMBIENCE = Object.freeze({ hemiSky: 0xffdcb4, hemiGround: 0x5a4632, hemiI: 1.45, sunI: 0.55, fog: 0x3a2c22, fogNear: 50, fogFar: 260 });

// 포털 현판 (캔버스): 녹색 판 + 흰 테두리 + 터널 이름(크게) + 길이
const SIGN_X = TN.wallX + 2.6, SIGN_Y = 2.6; // 입구 안내 표지 (오른쪽 날개벽 끝 바깥, 판 하단 2.6m)
function tunnelBoardMaterial(name, sub, night, stacked = false) {
  const key = 'tboard|' + name + '|' + sub + '|' + (night ? 1 : 0) + '|' + (stacked ? 1 : 0);
  return cached(_matCache, key, () => {
    if (stacked) { // 길가 표지: 위 이름 / 아래 길이 (2줄)
      const W = 1024, H = 350;
      const tex = textTexture(W, H, (ctx) => {
        ctx.fillStyle = '#0b7a4b'; rrect(ctx, 0, 0, W, H, 30); ctx.fill();
        ctx.strokeStyle = '#ffffff'; ctx.lineWidth = 10; rrect(ctx, 16, 16, W - 32, H - 32, 22); ctx.stroke();
        ctx.fillStyle = '#ffffff'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
        fitFont(ctx, name, FONT_DISPLAY, sub ? 150 : 190, W - 110);
        ctx.fillText(name, W / 2, sub ? H * 0.38 : H * 0.53);
        if (sub) { fitFont(ctx, sub, FONT_DISPLAY, 92, W - 160); ctx.fillText(sub, W / 2, H * 0.75); }
      }, { aniso: 16 });
      return new THREE.MeshLambertMaterial({ map: tex, emissive: 0xffffff, emissiveMap: tex, emissiveIntensity: night ? 0.6 : 0.25, name: 'scenery.tunnelSign' });
    }
    const W = 1536, H = 300;
    const tex = textTexture(W, H, (ctx) => {
      ctx.fillStyle = '#0b7a4b'; rrect(ctx, 0, 0, W, H, 34); ctx.fill();
      ctx.strokeStyle = '#ffffff'; ctx.lineWidth = 12; rrect(ctx, 18, 18, W - 36, H - 36, 24); ctx.stroke();
      ctx.fillStyle = '#ffffff'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
      const spaced = [...name].join(name.length <= 6 ? ' ' : '');
      fitFont(ctx, spaced, FONT_DISPLAY, 190, sub ? W * 0.62 : W - 120);
      ctx.fillText(spaced, sub ? W * 0.4 : W / 2, H * 0.54);
      if (sub) {
        ctx.fillStyle = 'rgba(255,255,255,0.85)'; ctx.fillRect(W * 0.745, 62, 6, H - 124);
        fitFont(ctx, sub, FONT_DISPLAY, 92, W * 0.22);
        ctx.fillStyle = '#ffffff'; ctx.fillText(sub, W * 0.87, H * 0.54);
      }
    }, { aniso: 16 });
    return new THREE.MeshLambertMaterial({ map: tex, emissive: 0xffffff, emissiveMap: tex, emissiveIntensity: night ? 0.6 : 0.25, name: 'scenery.tunnelBoard' });
  });
}
const _portalCache = new Map();
function buildPortalGeo(night) {
  const F = new GB(), NA = 18, T = 0.8, ZF = T; // 정면 z = +0.8 (다가오는 차 쪽), 뒷면 z = 0 (터널 시작)
  const W = 16, topC = TN.portalTopY, topS = TN.capY + 0.5, cw = 4.6;
  const topAt = (x) => (Math.abs(x) <= cw ? topC : topS);
  const nF = [0, 0, 1];
  // 정면: 옆 블록 + 아치 위 띠 (각 아치 면 위로 수직 띠)
  for (const sd of [-1, 1]) {
    const xa = sd * TN.wallX, xb = sd * W;
    qf(F, [xa, 0, ZF], [xb, 0, ZF], [xb, topS, ZF], [xa, topS, ZF], TPAL.facade, nF);
    for (let y = 1.2; y < topS - 0.5; y += 1.2) qf(F, [xa + sd * 0.7, y, ZF + 0.01], [xb, y, ZF + 0.01], [xb, y + 0.06, ZF + 0.01], [xa + sd * 0.7, y + 0.06, ZF + 0.01], TPAL.facadeDark, nF);
    // 끝면 + 윗면
    qf(F, [xb, 0, 0], [xb, 0, ZF], [xb, topS, ZF], [xb, topS, 0], TPAL.facadeDark, [sd, 0, 0]);
    qf(F, [xa, topS, 0], [xb, topS, 0], [xb, topS, ZF], [xa, topS, ZF], TPAL.facade, [0, 1, 0]);
  }
  for (let i = 0; i < NA; i++) {
    const a = archPt(i, NA), b = archPt(i + 1, NA), ta = topAt(a[0]), tb = topAt(b[0]);
    qf(F, [a[0], a[1], ZF], [b[0], b[1], ZF], [b[0], tb, ZF], [a[0], ta, ZF], TPAL.facade, nF);
    qf(F, [a[0], ta, 0], [b[0], tb, 0], [b[0], tb, ZF], [a[0], ta, ZF], TPAL.facade, [0, 1, 0]); // 윗면
    // 개구부 안쪽 면 (두께) + 포털 링(정면에 0.6m 띠, 6cm 돌출)
    const [nx, ny] = archN(i, NA);
    qf(F, [a[0], a[1], 0], [b[0], b[1], 0], [b[0], b[1], ZF], [a[0], a[1], ZF], TPAL.facadeDark, [nx, ny, 0]);
    const o = 0.6, A2 = [a[0] - nx * o, a[1] - ny * o], B2 = [b[0] - nx * o, b[1] - ny * o];
    qf(F, [a[0], a[1], ZF + 0.06], [b[0], b[1], ZF + 0.06], [B2[0], B2[1], ZF + 0.06], [A2[0], A2[1], ZF + 0.06], TPAL.portalRing, nF);
    qf(F, [a[0], a[1], ZF], [b[0], b[1], ZF], [b[0], b[1], ZF + 0.06], [a[0], a[1], ZF + 0.06], TPAL.portalRing, [nx, ny, 0]);
  }
  for (const sd of [-1, 1]) { // 직벽부 링 + 개구부 직벽 두께 + 아래 노랑/검정 경고띠
    const x = sd * TN.wallX, xo = sd * (TN.wallX + 0.6);
    qf(F, [x, 0, ZF + 0.06], [xo, 0, ZF + 0.06], [xo, TN.springY, ZF + 0.06], [x, TN.springY, ZF + 0.06], TPAL.portalRing, nF);
    qf(F, [x, 0, 0], [x, 0, ZF + 0.06], [x, TN.springY, ZF + 0.06], [x, TN.springY, 0], TPAL.facadeDark, [-sd, 0, 0]);
    for (let k = 0; k < 6; k++) {
      const y0 = k * 0.42, y1 = y0 + 0.42, col = k % 2 ? 0x1b1c1f : 0xf2c21b;
      qf(F, [x, y0, ZF + 0.07], [xo, y0 + 0.2, ZF + 0.07], [xo, y1 + 0.2, ZF + 0.07], [x, y1, ZF + 0.07], col, nF);
    }
  }
  // 날개벽 (도로 쪽 면, 높이 capY → 0.9 로 낮아짐) + 바깥 잔디 비탈 + 소나무
  const AP = TN.approach;
  for (const sd of [-1, 1]) {
    const xw = sd * (TN.wallX + 0.3), xo = sd * (TN.wallX + 0.9);
    qf(F, [xw, 0, ZF], [xw, 0, ZF + AP], [xw, 0.9, ZF + AP], [xw, topS, ZF], TPAL.wing, [-sd, 0, 0]);
    qf(F, [xw, topS, ZF], [xw, 0.9, ZF + AP], [xo, 0.9, ZF + AP], [xo, topS, ZF], TPAL.facadeDark, [0, 1, 0.2]);
    qf(F, [xw, 0, ZF + AP], [xo, 0, ZF + AP], [xo, 0.9, ZF + AP], [xw, 0.9, ZF + AP], TPAL.facadeDark, [0, 0, 1]);
    const xg = sd * 60;
    qfC(F, [xo, topS, ZF], [xo, 0.9, ZF + AP], [xg, 0.0, ZF + AP + 30], [xg, topS, ZF], PAL.grassA, PAL.grassB, PAL.grassB, PAL.grassA, [0, 1, 0.3]);
    qf(F, [xo, topS - 0.01, 0], [xg, topS - 0.01, 0], [xg, topS - 0.01, ZF], [xo, topS - 0.01, ZF], PAL.grassA, [0, 1, 0]);
    const rr = rng(sd > 0 ? 91 : 17);
    for (let k = 0; k < 7; k++) {
      const t = rr(), u = 0.15 + rr() * 0.8, x = xo + (xg - xo) * u * 0.6, z = ZF + (AP + 30 * u * 0.6) * t * 0.9;
      const yS = topS + (0 - topS) * Math.max(0, Math.min(1, (z - ZF) / (AP + 30 * u))) , h = 3 + rr() * 3;
      F.box(x, yS - 0.2, z, 0.35, h * 0.3, 0.35, 0x7a5a3a, { nb: true });
      F.geo(PRIM.cone6, M4(x, yS - 0.2 + h * 0.22, z, h * 0.36, h * 0.8, h * 0.36, rr() * 3), 0x2f6b3a);
    }
  }
  // 현판 받침 (판 뒤 어두운 테두리)
  F.box(0, TN.boardY - 0.86, ZF + 0.03, 7.9, 1.72, 0.06, 0x3a3d42);
  // 입구 오른쪽 터널 안내 표지 기둥 (판은 별도 메시) — 낮아서 추격캠에서 오래 읽힘
  F.box(SIGN_X - 1.4, 0, ZF + AP - 1.0, 0.16, SIGN_Y + 0.1, 0.16, 0x8a939b, { nb: true });
  F.box(SIGN_X + 1.4, 0, ZF + AP - 1.0, 0.16, SIGN_Y + 0.1, 0.16, 0x8a939b, { nb: true });
  F.box(SIGN_X, SIGN_Y - 0.08, ZF + AP - 1.08, 3.96, 1.46, 0.08, 0x9aa1a8);
  return F.build();
}
/**
 * 터널 입구 포털 (추가 export). 원점 x=0, s=0 = 터널 시작면, 정면은 +Z(다가오는 차)를 봄, 두께 0.8m 는 +Z 쪽.
 * 구성: 콘크리트 면벽(개구부 = 터널 단면) + 포털 링 + 경고띠 + 현판('○○터널' 캔버스) + 날개벽·잔디 비탈(+Z 로 approach m).
 * 출구 포털 = 같은 함수 opts.exit=true (현판 없음) 를 rotation.y = π 로 터널 끝 s 에 배치.
 * 추격캠이 지나갈 때 현판부가 시야를 막으니 world._overhead() 에 등록해 반투명 페이드를 권장 (게이트리와 동일).
 * @param {string} name 예: '죽령터널'
 * @param {{night?:boolean, length?:number, exit?:boolean, sub?:string}} opts length(m) → 'L=4,600m' 표기
 */
export function buildTunnelPortal(name = '○○터널', opts = {}) {
  const night = !!opts.night;
  const geo = cached(_portalCache, 'portal|' + (night ? 1 : 0), () => buildPortalGeo(night));
  const g = new THREE.Group();
  g.name = 'tunnelPortal';
  const body = new THREE.Mesh(geo, MAT.vc); body.name = 'facade'; body.castShadow = true; body.receiveShadow = true;
  g.add(body);
  let board = null;
  if (!opts.exit) {
    const sub = opts.sub ?? (opts.length ? `L=${Math.round(opts.length).toLocaleString('en-US')}m` : '');
    const bw = 7.6, bh = 1.5;
    board = new THREE.Mesh(cached(_propCache, 'tboardGeo', () => new THREE.PlaneGeometry(bw, bh)), tunnelBoardMaterial(name, sub, night));
    board.name = 'board'; board.position.set(0, TN.boardY, 0.8 + 0.07);
    const side = new THREE.Mesh(cached(_propCache, 'tsideGeo', () => new THREE.PlaneGeometry(3.8, 1.3)), tunnelBoardMaterial(name, sub, night, true));
    side.name = 'sideSign'; side.position.set(SIGN_X, SIGN_Y + 0.65, 0.8 + TN.approach - 1.0);
    g.add(board, side);
  }
  g.userData = { kind: 'tunnelPortal', name, board, drawCalls: g.children.length, approach: TN.approach };
  return g;
}

// ─────────────────────────────────────────────────────────────
// 소품
const _propCache = new Map();
const PROP_VARIANTS = {
  tree: 12, pine: 8, bush: 6, apartment: 60, mountain: 10, paddy: 9, church: 4, streetLight: 1,
  billboard: AD_LIST.length, cloud: 8, cctv: 1, house: 8,
};

// 아파트 외벽 창문 텍스처 (4세대 × 8층, 반복)
function facadeTextures() {
  return cached(_texCache, 'facade', () => {
    const W = 512, H = 512, CW = 128, CH = 64;
    const day = makeCanvas(W, H), d = day.getContext('2d');
    const nightC = makeCanvas(W, H), n = nightC.getContext('2d');
    const r = rng(4242);
    d.fillStyle = '#f4f0e6'; d.fillRect(0, 0, W, H);
    n.fillStyle = '#000'; n.fillRect(0, 0, W, H);
    const curtains = ['#e9d9b8', '#cfe0ea', '#f1d2d2', '#d9e8c9', '#e8e0d0'];
    const lights = ['#ffd27a', '#ffe1a0', '#ffc35a', '#fff0c8', '#a9c9ff'];
    for (let fy = 0; fy < 8; fy++) for (let ux = 0; ux < 4; ux++) {
      const x0 = ux * CW, y0 = fy * CH;
      // 슬래브 그림자 줄
      d.fillStyle = '#ddd7c9'; d.fillRect(x0, y0 + CH - 6, CW, 6);
      // 발코니 창 (유리)
      const wx = x0 + 10, wy = y0 + 9, ww = CW - 20, wh = 40;
      const g = d.createLinearGradient(0, wy, 0, wy + wh);
      g.addColorStop(0, '#9bbad0'); g.addColorStop(0.5, '#6f90a9'); g.addColorStop(1, '#5a7890');
      d.fillStyle = g; d.fillRect(wx, wy, ww, wh);
      if (r() < 0.35) { d.fillStyle = curtains[(r() * curtains.length) | 0]; d.fillRect(wx + (r() < 0.5 ? 4 : ww - 34), wy + 3, 30, wh - 6); }
      // 창틀
      d.fillStyle = '#ffffff';
      d.fillRect(wx - 3, wy - 3, ww + 6, 4); d.fillRect(wx - 3, wy + wh - 1, ww + 6, 4);
      d.fillRect(wx - 3, wy, 4, wh); d.fillRect(wx + ww - 1, wy, 4, wh);
      d.fillRect(wx + ww * 0.5 - 2, wy, 4, wh); d.fillRect(wx + ww * 0.25 - 1, wy, 3, wh);
      // 난간
      d.fillStyle = 'rgba(255,255,255,0.85)'; d.fillRect(wx, wy + wh - 13, ww, 3);
      // 실외기
      if (r() < 0.22) { d.fillStyle = '#c9c9c4'; d.fillRect(wx + ww - 22, wy + wh - 16, 18, 13); d.fillStyle = '#8f8f8a'; d.fillRect(wx + ww - 18, wy + wh - 13, 10, 7); }
      // 야간 점등 마스크
      if (r() < 0.5) {
        n.fillStyle = lights[(r() * lights.length) | 0];
        n.fillRect(wx, wy, ww, wh);
        n.fillStyle = 'rgba(0,0,0,0.85)'; n.fillRect(wx + ww * 0.5 - 2, wy, 4, wh); n.fillRect(wx, wy + wh - 13, ww, 3);
      }
    }
    return { day: canvasTex(day, { repeat: true, aniso: 4 }), night: canvasTex(nightC, { repeat: true, aniso: 4 }) };
  });
}
function facadeMaterial(night) {
  return cached(_matCache, 'facade|' + (night ? 1 : 0), () => {
    const t = facadeTextures();
    return night
      ? new THREE.MeshLambertMaterial({ map: t.day, emissive: 0xffffff, emissiveMap: t.night, emissiveIntensity: 1.0, name: 'scenery.facadeNight' })
      : new THREE.MeshLambertMaterial({ map: t.day, name: 'scenery.facade' });
  });
}
function aptLabelMaterial(num, brandIdx, night) {
  return cached(_matCache, `aptLabel|${num}|${brandIdx}|${night ? 1 : 0}`, () => {
    const [brand, accent] = APT_BRANDS[brandIdx];
    const accHex = '#' + accent.toString(16).padStart(6, '0');
    const tex = textTexture(512, 320, (ctx, w, h) => {
      ctx.fillStyle = '#f4f0e6'; ctx.fillRect(0, 0, w, h);
      ctx.textBaseline = 'alphabetic'; ctx.textAlign = 'center';
      fitFont(ctx, brand, FONT_UI, 58, w * 0.8);
      ctx.fillStyle = accHex; ctx.fillText(brand, w / 2, 70);
      // 로고 마크 (작은 잎사귀/사각)
      ctx.fillRect(w / 2 - 70, 84, 140, 6);
      ctx.font = `200px ${FONT_DISPLAY}`;
      const numW = ctx.measureText(String(num)).width;
      ctx.font = `120px ${FONT_DISPLAY}`;
      const dongW = ctx.measureText('동').width;
      const total = numW + dongW + 8, sx = (w - total) / 2;
      ctx.textAlign = 'left'; ctx.fillStyle = '#26324a';
      ctx.font = `200px ${FONT_DISPLAY}`; ctx.fillText(String(num), sx, 290);
      ctx.font = `120px ${FONT_DISPLAY}`; ctx.fillText('동', sx + numW + 8, 290);
    }, { aniso: 4 });
    return new THREE.MeshLambertMaterial({ map: tex, emissive: night ? 0xffffff : 0x000000, emissiveMap: night ? tex : null, emissiveIntensity: night ? 0.18 : 0, name: 'scenery.aptLabel' });
  });
}

function propApartment(seed, night) {
  const num = 101 + (seed % 12);
  const H = 25 + (Math.floor(seed / 12) % 5) * 5;
  const brandIdx = Math.floor(seed / 3) % APT_BRANDS.length;
  const accent = APT_BRANDS[brandIdx][1];
  const W = 14, D = 10, baseH = 3.2;
  const wall = 0xf4f0e6;
  const B = new GB();
  // 1층 필로티
  B.box(0, 0, 0, W - 1.0, baseH, D - 1.0, 0x6d7277, { nb: true });
  for (const x of [-6.6, -2.2, 2.2, 6.6]) for (const z of [-4.7, 4.7]) B.box(x, 0, z, 0.6, baseH, 0.6, 0xe2ddd1, { nb: true });
  B.box(0, 0, 4.9, 2.6, 2.4, 0.4, 0x6f8fa8, { nb: true }); // 공동현관
  // 본체
  B.box(0, baseH, 0, W, H - baseH, D, wall, { bot: 0xd9d4c7 });
  // 층 띠(측면) & accent 세로 띠
  for (const sx of [1, -1]) {
    B.box(sx * (W / 2 + 0.05), baseH, D / 2 - 1.0, 0.1, H - baseH, 1.5, accent, { nb: true });
    B.box(sx * (W / 2 + 0.05), baseH, -D / 2 + 0.55, 0.1, H - baseH, 0.5, mixC(accent, 0xffffff, 0.45), { nb: true });
  }
  // 옥상 캡 + 옥탑
  B.box(0, H, 0, W + 0.3, 0.55, D + 0.3, 0xe6e1d5);
  B.box(-2.6, H + 0.55, -0.8, 4.4, 3.4, 4.2, 0xebe7dc, { top: 0xd8d3c6 });
  B.box(3.6, H + 0.55, 1.0, 3.4, 2.2, 2.8, 0x9fbccc, { top: 0x8eaabb });
  // 크라운 (브랜드 색 지붕 장식)
  B.box(0, H + 0.55, D / 2 - 0.1, W * 0.7, 0.5, 0.25, accent);
  B.box(-W * 0.35, H + 0.55, D / 2 - 0.1, 0.4, 2.6, 0.4, accent);
  B.box(W * 0.35, H + 0.55, D / 2 - 0.1, 0.4, 2.6, 0.4, accent);
  B.box(0, H + 2.8, D / 2 - 0.1, W * 0.7 + 0.4, 0.35, 0.4, accent);

  // 정면/후면 창문
  const F = new GB(true);
  const fy0 = baseH + 0.25, fy1 = H - 0.35, floors = (fy1 - fy0) / 2.8;
  F.vquadZ(D / 2 + 0.02, -W / 2 + 0.25, W / 2 - 0.25, fy0, fy1, 1, 0xffffff, 0, 1, 0, floors / 8);
  F.vquadZ(-D / 2 - 0.02, -W / 2 + 0.25, W / 2 - 0.25, fy0, fy1, -1, 0xffffff, 0, 1, 0, floors / 8);

  // 측면 "10X동" 라벨 (양쪽)
  const L = new GB(true);
  const lz0 = -D / 2 + 1.0, lz1 = D / 2 - 1.95, lw = lz1 - lz0, lh = lw * 320 / 512;
  const ly1 = H - 0.9, ly0 = ly1 - lh;
  L.vquadX(W / 2 + 0.03, lz0, lz1, ly0, ly1, 1, 0xffffff);
  L.vquadX(-W / 2 - 0.03, lz0, lz1, ly0, ly1, -1, 0xffffff);

  return {
    parts: [
      { geo: B.build(), mat: MAT.vc, cast: true, receive: true, name: 'body' },
      { geo: F.build(), mat: () => facadeMaterial(night), cast: false, receive: true, name: 'facade' },
      { geo: L.build(), mat: () => aptLabelMaterial(num, brandIdx, night), cast: false, receive: true, name: 'label' },
    ],
    info: { number: num, height: H, width: W, depth: D },
  };
}

function propTree(seed) {
  const r = rng(seed * 977 + 11), B = new GB();
  const pals = [[0x3f9a3d, 0x5cbc4c], [0x2f8a46, 0x52b45a], [0x4f9c2e, 0x7cc648], [0x3a8f4f, 0x66b86c]];
  const pal = pals[seed % 4];
  const style = Math.floor(seed / 4) % 3;
  const th = 1.3 + r() * 0.7;
  B.box(0, 0, 0, 0.55, th + 0.6, 0.55, 0x8a5a3a, { nb: true, top: 0x9a6a48 });
  const two = (cx, cy, cz, n) => (n > 0.45 ? pal[1] : pal[0]);
  if (style === 0) {
    B.box(0, th, 0, 2.8, 2.0, 2.8, pal[0], { top: pal[1] });
    B.box(0.25, th + 2.0, -0.15, 1.9, 1.3, 1.9, pal[1], { top: mixC(pal[1], 0xffffff, 0.15) });
    B.box(-1.0, th + 0.5, 0.9, 1.0, 1.0, 1.0, pal[0], { top: pal[1] });
  } else if (style === 1) {
    B.geo(PRIM.ico, M4(0, th + 1.5, 0, 1.9, 1.75, 1.9, r() * 3), two);
    B.geo(PRIM.ico, M4(0.5, th + 2.7, 0.25, 1.2, 1.1, 1.2, r() * 3), (x, y, z, n) => (n > 0.2 ? mixC(pal[1], 0xffffff, 0.12) : pal[1]));
  } else {
    B.box(0, th, 0, 2.3, 1.7, 2.3, pal[0], { top: pal[1] });
    B.box(0, th + 1.7, 0, 1.8, 1.6, 1.8, pal[1], { top: mixC(pal[1], 0xffffff, 0.12) });
    B.box(0, th + 3.3, 0, 1.1, 1.0, 1.1, pal[1], { top: mixC(pal[1], 0xffffff, 0.2) });
  }
  return { parts: [{ geo: B.build(), mat: MAT.vc, cast: true, receive: true }], info: { height: th + 4 } };
}

function propPine(seed) {
  const r = rng(seed * 613 + 5), B = new GB();
  const lean = (r() - 0.5) * 0.16;
  B.box(0, 0, 0, 0.42, 2.6, 0.42, 0x9a5536, { nb: true, rz: lean, top: 0xa8653f });
  const layers = [[1.7, 2.2, 1.3], [2.8, 1.75, 1.25], [3.8, 1.25, 1.15], [4.7, 0.7, 1.05]];
  const cs = [[0x2d6b3d, 0x3f8a4c], [0x2a6236, 0x3a7d45], [0x336f3a, 0x4a9150]][seed % 3];
  layers.forEach(([y, rad, h], i) => {
    const ox = lean * -y * 0.5 + (r() - 0.5) * 0.25, oz = (r() - 0.5) * 0.25;
    B.geo(PRIM.cone7, M4(ox, y, oz, rad, h, rad, r() * 3), (x, yy, z, n) => (n > 0.55 ? cs[1] : cs[0]));
    if (i < 2) B.box(ox, y - 0.15, oz, rad * 1.5, 0.3, rad * 1.5, cs[0], { ry: r() * 2 });
  });
  return { parts: [{ geo: B.build(), mat: MAT.vc, cast: true, receive: true }], info: { height: 5.8 } };
}

function propBush(seed) {
  const r = rng(seed * 331 + 9), B = new GB();
  const g = [[0x4c9a3a, 0x66b84d], [0x3f8c44, 0x5aaa5c], [0x5a9e34, 0x7bc04a]][seed % 3];
  const n = 2 + (seed % 2);
  for (let i = 0; i < n; i++) {
    const s = 0.7 + r() * 0.45;
    B.geo(PRIM.ico, M4((r() - 0.5) * 1.4, s * 0.7, (r() - 0.5) * 1.0, s, s * 0.8, s, r() * 3), (x, y, z, ny) => (ny > 0.4 ? g[1] : g[0]));
  }
  if (r() < 0.4) B.box(0.4, 0.95, 0.5, 0.2, 0.2, 0.2, FLOWER[(r() * FLOWER.length) | 0]);
  return { parts: [{ geo: B.build(), mat: MAT.vc, cast: true, receive: true }], info: { height: 1.6 } };
}

function propMountain(seed) {
  const r = rng(seed * 131 + 3), B = new GB();
  const R = 40 + r() * 40, Hm = 30 + r() * 30;
  const rocky = Hm > 46;
  const greens = [0x4b8c3e, 0x3f7d38, 0x528f42, 0x5a9a48, 0x467f3a];
  const profile = (t) => 0.55 * (2 * t - t * t) + 0.45 * t * t * (3 - 2 * t);
  const peak = (cx, cz, R, H, segs, rings) => {
    const grid = [];
    const apex = [cx + (hash3(cx, H, 3) - 0.5) * R * 0.08, H, cz + (hash3(cz, H, 5) - 0.5) * R * 0.08];
    for (let k = 0; k <= rings; k++) {
      const t = k / rings, row = [];
      for (let i = 0; i < segs; i++) {
        if (k === rings) { row.push(apex); continue; }
        const a = (i / segs) * Math.PI * 2 + (hash3(k, i, cx) - 0.5) * 0.25;
        const rr = R * (1 - t) * (1 + (hash3(i, k, cz) - 0.5) * (k === 0 ? 0.12 : 0.3));
        const y = k === 0 ? -0.6 : H * profile(t) * (1 + (hash3(k * 7, i * 3, R) - 0.5) * 0.16);
        row.push([cx + Math.cos(a) * rr, y, cz + Math.sin(a) * rr]);
      }
      grid.push(row);
    }
    const ref = [cx, -H * 0.4, cz];
    const colFor = (y) => {
      const hf = y / H;
      if (rocky && hf > 0.8) return hash3(y, cx, 1) < 0.6 ? 0x8f8b7d : 0x7d7a6d;
      const c = greens[(hash3(y * 3.1, cx, cz) * greens.length) | 0];
      return mulC(c, hf < 0.25 ? 0.92 : 1.0 + hf * 0.08);
    };
    for (let k = 0; k < rings; k++) for (let i = 0; i < segs; i++) {
      const i2 = (i + 1) % segs;
      const a = grid[k][i], b = grid[k][i2], c = grid[k + 1][i2], d = grid[k + 1][i];
      if (k === rings - 1) { B.triOut(a, b, c, colFor((a[1] + c[1]) / 2), ref); continue; }
      B.triOut(a, b, c, colFor((a[1] + b[1] + c[1]) / 3), ref);
      B.triOut(a, c, d, colFor((a[1] + c[1] + d[1]) / 3), ref);
    }
  };
  peak(0, 0, R, Hm, 12, 5);
  const side = r() < 0.5 ? 1 : -1;
  peak(side * R * 0.55, -R * 0.2, R * 0.62, Hm * 0.62, 10, 4);
  if (r() < 0.6) peak(-side * R * 0.5, R * 0.15, R * 0.5, Hm * 0.45, 9, 3);
  // 소나무 점점이
  const nP = Math.floor(R * 0.9);
  for (let i = 0; i < nP; i++) {
    const t = 0.06 + r() * 0.7, a = r() * Math.PI * 2;
    const rr = R * (1 - t) * 0.94, y = Hm * profile(t) * 0.97 - 0.6;
    if (rocky && t > 0.75) continue;
    const s = 1.3 + r() * 1.1;
    B.geo(PRIM.cone6, M4(Math.cos(a) * rr, y, Math.sin(a) * rr, s, s * 2.6, s, r() * 2), r() < 0.5 ? 0x2b5a2f : 0x316a35);
  }
  return { parts: [{ geo: B.build(), mat: MAT.vc, cast: false, receive: false }], info: { radius: R, height: Hm } };
}

function propPaddy(seed) {
  const r = rng(seed * 59 + 21), B = new GB();
  const stage = seed % 3; // 0 모내기(물), 1 초록, 2 황금
  const water = [0x7cb6d4, 0x6a9c86, 0x8f7c50][stage];
  const rice = [0x9ad66a, 0x5cae3c, 0xe2bd45][stage], riceTop = [0xb6e584, 0x76c44f, 0xf2d56a][stage];
  const rh = [0.18, 0.42, 0.55][stage];
  B.box(0, -0.06, 0, 19.4, 0.06, 19.4, water, { nb: true });
  // 논두렁
  const dk = 0x8a7550, dkTop = 0x86b452;
  B.box(0, 0 - 0.05, 9.7, 20, 0.38, 0.7, dk, { nb: true, top: dkTop });
  B.box(0, 0 - 0.05, -9.7, 20, 0.38, 0.7, dk, { nb: true, top: dkTop });
  B.box(9.7, 0 - 0.05, 0, 0.7, 0.38, 18.7, dk, { nb: true, top: dkTop });
  B.box(-9.7, 0 - 0.05, 0, 0.7, 0.38, 18.7, dk, { nb: true, top: dkTop });
  // 벼 줄
  for (let x = -8.6; x <= 8.7; x += 0.9) {
    for (let c = 0; c < 4; c++) {
      const z0 = -9.1 + c * 4.6 + 0.2, l = 4.1 + (r() - 0.5) * 0.3;
      B.box(x + (r() - 0.5) * 0.06, 0, z0 + l / 2, stage === 0 ? 0.22 : 0.42, rh * (0.85 + r() * 0.3), l, rice, { nb: true, top: riceTop });
    }
  }
  if (stage === 2 || r() < 0.3) {
    // 허수아비
    const sx = (r() - 0.5) * 10, sz = (r() - 0.5) * 10;
    B.box(sx, 0, sz, 0.12, 2.0, 0.12, 0x7a5532, { nb: true });
    B.box(sx, 1.35, sz, 1.6, 0.12, 0.12, 0x7a5532);
    B.box(sx, 0.95, sz, 0.6, 0.7, 0.32, r() < 0.5 ? 0xd8452f : 0x2f6fd6);
    B.box(sx, 1.68, sz, 0.42, 0.42, 0.42, 0xf1dcb0);
    B.box(sx, 2.06, sz, 0.9, 0.08, 0.9, 0xe6c05a);
    B.box(sx, 2.12, sz, 0.42, 0.22, 0.42, 0xe6c05a);
  } else {
    // 백로 1~2마리
    const n = 1 + (r() < 0.5 ? 1 : 0);
    for (let i = 0; i < n; i++) {
      const ex = (r() - 0.5) * 12, ez = (r() - 0.5) * 12, ry = r() * Math.PI * 2;
      const cs = Math.cos(ry), sn = Math.sin(ry);
      const P = (dx, dz) => [ex + dx * cs + dz * sn, ez - dx * sn + dz * cs];
      B.box(ex, 0, ez, 0.05, 0.55, 0.05, 0x222222, { nb: true });
      B.box(ex, 0.5, ez, 0.36, 0.34, 0.62, 0xffffff, { ry });
      let [nx, nz] = P(0, 0.32); B.box(nx, 0.75, nz, 0.12, 0.42, 0.12, 0xffffff, { ry });
      [nx, nz] = P(0, 0.42); B.box(nx, 1.12, nz, 0.17, 0.15, 0.24, 0xffffff, { ry });
      [nx, nz] = P(0, 0.6); B.box(nx, 1.15, nz, 0.06, 0.06, 0.24, 0xf2c21b, { ry });
    }
  }
  return { parts: [{ geo: B.build(), mat: MAT.vc, cast: false, receive: true }], info: { size: 20, stage } };
}

function propChurch(seed, night) {
  const r = rng(seed * 17 + 1), B = new GB(), Gw = night ? new GB() : null;
  const brick = seed % 2 === 1;
  const wall = brick ? 0xb65b42 : 0xf1ede4, trim = brick ? 0xe8dfd0 : 0xd9d2c4;
  const roof = [0x4b5563, 0x9e3a32, 0x2f6a6a, 0x3d4a70][seed % 4];
  const W = 7, D = 10, Hw = 5;
  B.box(0, 0, 0, W, Hw, D, wall, { nb: true });
  B.box(0, 0, 0, W + 0.2, 0.5, D + 0.2, trim, { nb: true });
  B.prism(0, Hw, 0, W + 0.8, 3.2, D + 0.6, roof, false, wall);
  // 종탑 (정면 +Z)
  const tz = D / 2 + 0.9, TH = 13;
  B.box(0, 0, tz, 2.8, TH, 2.8, wall, { nb: true });
  B.box(0, TH, tz, 3.1, 0.4, 3.1, trim);
  B.box(0, TH + 0.4, tz, 2.4, 1.8, 2.4, trim);
  B.box(0, TH + 0.9, tz + 1.21, 1.0, 1.0, 0.02, 0x2a2f3a); // 종탑 창
  B.geo(PRIM.cone4, M4(0, TH + 2.2, tz, 2.0, 5.0, 2.0, Math.PI / 4), roof);
  // 십자가
  const cy = TH + 7.2;
  const crossC = night ? 0xff2a2a : 0xffffff;
  const CG = night ? Gw : B;
  CG.box(0, cy, tz, 0.26, 2.4, 0.26, crossC);
  CG.box(0, cy + 1.45, tz, 1.4, 0.26, 0.26, crossC);
  // 창문 (아치형 느낌: 세로 긴 창)
  const winC = night ? 0xffd78a : 0x34507a;
  const WG = night ? Gw : B;
  for (let z = -3.2; z <= 3.3; z += 2.1) for (const sx of [1, -1]) {
    WG.box(sx * (W / 2 + 0.01), 1.4, z, 0.04, 2.4, 0.8, winC);
    WG.box(sx * (W / 2 + 0.01), 3.8, z, 0.04, 0.3, 0.5, winC);
  }
  B.box(0, 0, tz + 1.41, 1.2, 2.2, 0.06, 0x6b4428); // 문
  WG.box(0, 8.5, tz + 1.41, 0.9, 1.6, 0.04, night ? 0xffcf70 : 0x7a4fb0); // 종탑 스테인드글라스
  const parts = [{ geo: B.build(), mat: MAT.vc, cast: true, receive: true }];
  if (Gw) {
    parts.push({ geo: Gw.build(), mat: MAT.glow, cast: false, receive: false, name: 'glow' });
    parts.push({ sprite: 0xff2020, pos: [0, cy + 1.3, tz + 0.2], scale: 9, name: 'crossHalo' });
  }
  return { parts, info: { height: cy + 2.4 } };
}

function propStreetLight(seed, night, opts) {
  // 메시: 기둥(vc) [+ 야간: 가산 FX(램프 렌즈 + 노면 빛웅덩이) + 헤일로 스프라이트] → 최대 3개
  const B = new GB(), FX = night ? new GB() : null;
  const steel = 0xa9b0b7, dark = 0x7f878f;
  B.box(0, 0, 0, 0.7, 0.45, 0.7, 0xb2aea4, { nb: true });
  B.box(0, 0.45, 0, 0.28, 9.6, 0.28, steel, { nb: true, top: dark });
  const arms = opts && opts.double ? [-1, 1] : [-1];
  const halos = [];
  for (const sx of arms) {
    const L = 3.5;
    B.box(sx * L / 2, 9.75, 0, L, 0.16, 0.16, steel, { rz: sx * -0.07 });
    B.box(sx * L * 0.25, 9.3, 0, 0.1, 0.8, 0.1, dark, { rz: sx * 0.7 });
    const lx = sx * (L + 0.25);
    B.box(lx, 9.72, 0, 1.15, 0.28, 0.5, 0x8f979f, { top: 0x9fa7ae });
    B.box(lx, 9.66, 0, 0.95, 0.06, 0.36, night ? 0x6b6450 : 0xe9eef2);
    if (FX) {
      // 렌즈(가산으로 하얗게 빛남)
      const ly = 9.64, hx = 0.47, hz = 0.18, lc = [0.9, 0.78, 0.5];
      FX.triC([lx - hx, ly, hz], [lx + hx, ly, hz], [lx + hx, ly, -hz], lc, lc, lc);
      FX.triC([lx - hx, ly, hz], [lx + hx, ly, -hz], [lx - hx, ly, -hz], lc, lc, lc);
      // 노면 빛웅덩이: 중심 → 중간 링 → 가장자리(0) 2단 감쇠.
      // 주의: 가산 혼합은 sRGB 인코딩 값끼리 더해지므로 낮은 선형값으로도 충분히 밝다
      const segs = 16, Y = 0.045, cBot = [0, 0, 0];
      const ring = (rad, a) => [lx + Math.cos(a) * rad, Y, Math.sin(a) * rad];
      const cC = [0.13, 0.1, 0.05], cM = [0.03, 0.022, 0.01];
      for (let i = 0; i < segs; i++) {
        const a0 = (i / segs) * Math.PI * 2, a1 = ((i + 1) / segs) * Math.PI * 2;
        const c = [lx, Y, 0], m0 = ring(3.0, a0), m1 = ring(3.0, a1), e0 = ring(6.8, a0), e1 = ring(6.8, a1);
        FX.triC(c, m1, m0, cC, cM, cM);
        FX.triC(m0, m1, e1, cM, cM, cBot); FX.triC(m0, e1, e0, cM, cBot, cBot);
      }
      halos.push([lx, 9.5, 0]);
    }
  }
  const parts = [{ geo: B.build(), mat: MAT.vc, cast: true, receive: false }];
  if (FX) {
    parts.push({ geo: FX.build(), mat: MAT.additive, cast: false, receive: false, name: 'lightFx', order: 3 });
    // 헤일로는 팔 하나당 1개 (double 이면 2개 → 이 경우만 4개)
    for (const h of halos) parts.push({ sprite: 0xffd890, pos: h, scale: 3.6, name: 'halo' });
  }
  return { parts, info: { height: 10, lampX: -3.75 } };
}

function adMaterial(ad, night) {
  const key = 'ad|' + ad.lines.join('/') + '|' + (night ? 1 : 0);
  return cached(_matCache, key, () => {
    const tex = textTexture(1024, 440, (ctx, w, h) => drawAd(ctx, w, h, ad), { aniso: 8 });
    return new THREE.MeshLambertMaterial({ map: tex, emissive: 0xffffff, emissiveMap: tex, emissiveIntensity: night ? 0.75 : 0.12, name: 'scenery.ad' });
  });
}
function drawAdIcon(ctx, icon, cx, cy, s, ad) {
  ctx.save(); ctx.translate(cx, cy); ctx.scale(s, s);
  if (icon === 'walnut') {
    for (const [x, y] of [[-34, 10], [30, 14], [0, -26]]) {
      ctx.fillStyle = '#9a5b2a'; ctx.beginPath(); ctx.arc(x, y, 34, 0, 7); ctx.fill();
      ctx.strokeStyle = '#6b3a17'; ctx.lineWidth = 5; ctx.beginPath(); ctx.arc(x - 6, y, 18, -1, 1); ctx.stroke();
      ctx.beginPath(); ctx.arc(x + 10, y - 4, 14, 2, 4); ctx.stroke();
    }
  } else if (icon === 'potato') {
    ctx.fillStyle = '#c99a5b'; ctx.beginPath(); ctx.ellipse(0, 0, 70, 52, 0.3, 0, 7); ctx.fill();
    ctx.fillStyle = '#8f6334'; for (const [x, y] of [[-30, -10], [10, 18], [28, -20], [-8, -30]]) { ctx.beginPath(); ctx.arc(x, y, 5, 0, 7); ctx.fill(); }
  } else if (icon === 'tire') {
    ctx.fillStyle = '#1b1b1d'; ctx.beginPath(); ctx.arc(0, 0, 66, 0, 7); ctx.fill();
    ctx.fillStyle = '#9aa1a9'; ctx.beginPath(); ctx.arc(0, 0, 30, 0, 7); ctx.fill();
    ctx.strokeStyle = ad.ac; ctx.lineWidth = 9;
    for (let i = 0; i < 6; i++) { const a = i * 1.05 + 0.3; ctx.beginPath(); ctx.moveTo(Math.cos(a) * 78, Math.sin(a) * 78); ctx.lineTo(Math.cos(a) * 100, Math.sin(a) * 100); ctx.stroke(); }
  } else if (icon === 'lane') {
    ctx.fillStyle = '#ffffff'; ctx.fillRect(-12, -80, 24, 160);
    ctx.fillStyle = ad.ac; ctx.beginPath(); ctx.moveTo(40, -70); ctx.lineTo(80, -20); ctx.lineTo(56, -20); ctx.lineTo(56, 70); ctx.lineTo(24, 70); ctx.lineTo(24, -20); ctx.lineTo(0, -20); ctx.closePath(); ctx.fill();
  } else if (icon === 'apt') {
    ctx.fillStyle = '#1b2a4a';
    ctx.fillRect(-70, -40, 40, 120); ctx.fillRect(-20, -80, 44, 160); ctx.fillRect(34, -20, 40, 100);
    ctx.fillStyle = '#ffd23f'; for (let y = -70; y < 70; y += 22) { ctx.fillRect(-12, y, 10, 10); ctx.fillRect(6, y, 10, 10); }
  } else if (icon === 'cow') {
    ctx.fillStyle = '#ffffff'; ctx.beginPath(); ctx.ellipse(0, 0, 66, 50, 0, 0, 7); ctx.fill();
    ctx.fillStyle = '#8b5a2b'; ctx.beginPath(); ctx.ellipse(0, 10, 56, 40, 0, 0, 7); ctx.fill();
    ctx.fillStyle = '#f1b0a0'; ctx.beginPath(); ctx.ellipse(0, 30, 30, 18, 0, 0, 7); ctx.fill();
    ctx.fillStyle = '#222'; ctx.beginPath(); ctx.arc(-20, -4, 7, 0, 7); ctx.arc(20, -4, 7, 0, 7); ctx.fill();
    ctx.fillStyle = '#e8dcc0'; ctx.fillRect(-64, -52, 22, 16); ctx.fillRect(42, -52, 22, 16);
  } else if (icon === 'grape') {
    ctx.fillStyle = '#7b3fb8';
    for (const [x, y] of [[-30, -30], [0, -30], [30, -30], [-15, -4], [15, -4], [0, 22], [-30, 22 - 26 + 26], [30, 22 - 26 + 26]]) { ctx.beginPath(); ctx.arc(x, y, 17, 0, 7); ctx.fill(); }
    ctx.fillStyle = '#3a8f3a'; ctx.beginPath(); ctx.ellipse(18, -58, 26, 12, -0.4, 0, 7); ctx.fill();
  }
  ctx.restore();
}
function drawAd(ctx, w, h, ad) {
  ctx.fillStyle = ad.bg; ctx.fillRect(0, 0, w, h);
  ctx.strokeStyle = ad.ac; ctx.lineWidth = 18; ctx.strokeRect(9, 9, w - 18, h - 18);
  const iconW = ad.icon ? 300 : 0;
  if (ad.icon) {
    ctx.fillStyle = 'rgba(255,255,255,0.18)'; ctx.beginPath(); ctx.arc(170, h / 2, 140, 0, 7); ctx.fill();
    drawAdIcon(ctx, ad.icon, 170, h / 2, 1.35, ad);
  }
  const tx = iconW + (w - iconW) / 2, maxW = w - iconW - 70;
  ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
  fitFont(ctx, ad.lines[0], FONT_DISPLAY, 92, maxW);
  ctx.fillStyle = ad.ac; ctx.fillText(ad.lines[0], tx, h * 0.3);
  fitFont(ctx, ad.lines[1], FONT_DISPLAY, 150, maxW);
  ctx.lineWidth = 10; ctx.strokeStyle = 'rgba(0,0,0,0.18)'; ctx.strokeText(ad.lines[1], tx, h * 0.66 + 4);
  ctx.fillStyle = ad.fg; ctx.fillText(ad.lines[1], tx, h * 0.66);
}

function propBillboard(seed, night, opts) {
  let ad = AD_LIST[seed % AD_LIST.length];
  if (opts && opts.text) {
    const lines = Array.isArray(opts.text) ? opts.text : String(opts.text).split('\n');
    ad = { ...ad, lines: lines.length > 1 ? lines : ['', lines[0]], icon: opts.icon !== undefined ? opts.icon : ad.icon };
  }
  const B = new GB(), Gw = night ? new GB() : null;
  const PW = 10.6, PH = 4.8, PY = 6.2;
  for (const sx of [-3, 3]) {
    B.box(sx, 0, 0, 0.9, 0.5, 0.9, 0xb2aea4, { nb: true });
    B.box(sx, 0.5, -0.1, 0.42, PY - 0.3, 0.42, 0x5b636b, { nb: true });
  }
  B.box(0, PY - 0.25, 0.0, PW + 0.4, 0.3, 0.6, 0x5b636b);
  B.box(0, PY, -0.05, PW, PH, 0.3, 0x3a3f45, { top: 0xdfe3e6 });
  B.box(0, PY - 0.1, -0.05, PW + 0.2, 0.2, 0.36, 0xdfe3e6);
  B.box(0, PY + PH, -0.05, PW + 0.2, 0.22, 0.36, 0xdfe3e6);
  // 조명 팔
  for (const lx of [-3.6, 0, 3.6]) {
    B.box(lx, PY + PH + 0.1, 0.55, 0.08, 0.08, 1.0, 0x444a50);
    (Gw || B).box(lx, PY + PH + 0.0, 1.0, 0.5, 0.14, 0.26, night ? 0xfff2cc : 0x50565c);
  }
  const F = new GB(true);
  F.vquadZ(0.11, -PW / 2 + 0.12, PW / 2 - 0.12, PY + 0.12, PY + PH - 0.12, 1, 0xffffff);
  const parts = [
    { geo: B.build(), mat: MAT.vc, cast: true, receive: true },
    { geo: F.build(), mat: () => adMaterial(ad, night), cast: false, receive: false, name: 'face' },
  ];
  if (Gw) parts.push({ geo: Gw.build(), mat: MAT.glow, cast: false, receive: false, name: 'lamps' });
  return { parts, info: { height: PY + PH + 0.3, text: ad.lines } };
}

function cloudMaterial(night) {
  return cached(_matCache, 'cloud|' + (night ? 1 : 0), () => new THREE.MeshLambertMaterial({
    vertexColors: true, flatShading: true, emissive: night ? 0x1c2244 : 0x9aa6b8, name: 'scenery.cloud',
  }));
}
function propCloud(seed, night) {
  const r = rng(seed * 71 + 2), B = new GB();
  const top = 0xffffff, side = 0xf8fbfe, bot = 0xeaf0f7;
  const L = 14 + r() * 10, D = 7 + r() * 3;
  B.box(0, 0, 0, L, 2.2, D, side, { top, bot });
  // 가운데가 높은 뭉게구름 (양 끝 낮게)
  const n = 3 + (seed % 3);
  for (let i = 0; i < n; i++) {
    const t = i / Math.max(1, n - 1) - 0.5, mid = 1 - Math.abs(t) * 1.6;
    const w = 4.5 + r() * 3 + mid * 2, hh = 2.2 + mid * 3 + r() * 1.2, d = D * (0.6 + r() * 0.3);
    B.box(t * L * 0.72 + (r() - 0.5) * 1.5, 1.0, (r() - 0.5) * 2, w, hh, d, side, { top, bot });
  }
  B.box((r() - 0.5) * L * 0.2, 3.6 + r(), (r() - 0.5) * 1.2, 4.5 + r() * 2.5, 2.4 + r() * 1.2, D * 0.5, side, { top, bot });
  return { parts: [{ geo: B.build(), mat: () => cloudMaterial(night), cast: false, receive: false }], info: { length: L } };
}

function signPlateMaterial(label) {
  return cached(_matCache, 'cctvSign|' + label, () => {
    const tex = textTexture(512, 456, (ctx, w, h) => {
      ctx.fillStyle = '#ffffff'; rrect(ctx, 0, 0, w, h, 28); ctx.fill();
      ctx.strokeStyle = '#1b1b1b'; ctx.lineWidth = 10; rrect(ctx, 12, 12, w - 24, h - 24, 22); ctx.stroke();
      ctx.fillStyle = '#1f4fa3'; rrect(ctx, 26, 26, w - 52, 160, 14); ctx.fill();
      ctx.fillStyle = '#ffffff'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
      fitFont(ctx, label, FONT_DISPLAY, 112, w - 90); ctx.fillText(label, w / 2, 110);
      // 제한속도 원판
      ctx.fillStyle = '#ffffff'; ctx.beginPath(); ctx.arc(150, 318, 98, 0, 7); ctx.fill();
      ctx.strokeStyle = '#d7261e'; ctx.lineWidth = 26; ctx.beginPath(); ctx.arc(150, 318, 86, 0, 7); ctx.stroke();
      ctx.fillStyle = '#111'; fitFont(ctx, '100', FONT_EN, 84, 120); ctx.fillText('100', 150, 322);
      // 카메라 아이콘
      ctx.fillStyle = '#111'; rrect(ctx, 290, 268, 150, 96, 14); ctx.fill(); ctx.fillRect(320, 248, 50, 26);
      ctx.fillStyle = '#fff'; ctx.beginPath(); ctx.arc(365, 316, 32, 0, 7); ctx.fill();
      ctx.fillStyle = '#111'; ctx.beginPath(); ctx.arc(365, 316, 18, 0, 7); ctx.fill();
      ctx.fillStyle = '#111'; ctx.font = `46px ${FONT_DISPLAY}`; ctx.fillText('시작', 365, 410);
    }, { aniso: 8 });
    return new THREE.MeshLambertMaterial({ map: tex, emissive: 0xffffff, emissiveMap: tex, emissiveIntensity: 0.2, name: 'scenery.cctvSign' });
  });
}

function propCCTV(seed, night, opts) {
  const B = new GB(), Gw = night ? new GB() : null;
  const px = SH_R + 1.05, armY = 7.4, steel = 0xaab2b9, dark = 0x7f878f;
  B.box(px, 0, 0, 1.0, 0.5, 1.0, 0xb2aea4, { nb: true });
  B.box(px, 0.5, 0, 0.42, armY + 0.2, 0.42, steel, { nb: true, top: dark });
  const xl = ROAD_LEFT - 0.2;
  B.box((px + xl) / 2, armY, 0, px - xl, 0.32, 0.32, steel);
  B.box((px + xl) / 2 + 2, armY + 0.85, 0, px - xl - 4, 0.18, 0.18, steel);
  for (let x = xl + 1.5; x < px - 0.5; x += 2.2) B.box(x, armY + 0.3, 0, 0.12, 0.6, 0.12, dark);
  B.box(px - 1.4, armY - 0.9, 0, 0.14, 2.1, 0.14, dark, { rz: 0.75 });
  for (let i = 0; i < NUM_LANES; i++) {
    const x = laneX(i);
    B.box(x, armY - 0.62, 0.05, 0.62, 0.55, 0.95, 0xeef1f4, { top: 0xffffff });
    B.box(x, armY - 0.07, 0.05, 0.12, 0.07, 0.12, dark);
    B.box(x, armY - 0.25, 0.25, 0.7, 0.06, 1.0, 0xdfe3e6); // 차양
    B.box(x, armY - 0.55, 0.54, 0.34, 0.34, 0.06, 0x15181c);
    (Gw || B).box(x + 0.22, armY - 0.2, 0.53, 0.08, 0.08, 0.04, night ? 0xff3030 : 0x8a1d1d); // 작동 LED
  }
  // 구간단속 표지판 (기둥, 정면 +Z)
  B.box(px, 3.0, 0.28, 1.95, 1.75, 0.08, 0x9aa1a8);
  const F = new GB(true);
  F.vquadZ(0.33, px - 0.92, px + 0.92, 3.05, 3.05 + 1.64, 1, 0xffffff);
  const parts = [
    { geo: B.build(), mat: MAT.vc, cast: true, receive: true },
    { geo: F.build(), mat: () => signPlateMaterial((opts && opts.label) || '구간단속'), cast: false, receive: false, name: 'sign' },
  ];
  if (Gw) parts.push({ geo: Gw.build(), mat: MAT.glow, cast: false, receive: false, name: 'leds' });
  return { parts, info: { height: armY + 1.1, spansRoad: true } };
}

function propHouse(seed, night) {
  const r = rng(seed * 43 + 8), B = new GB(), Gw = night ? new GB() : null;
  const roof = [0x2f6fb8, 0xc4473a, 0x2f8f86, 0x3a62a8][seed % 4];
  const wall = [0xf2ead8, 0xf6f3ec, 0xeadfcf][Math.floor(seed / 4) % 3];
  const W = 8, D = 5.5, Hw = 2.8;
  B.box(0, 0, 0, W + 0.4, 0.35, D + 0.4, 0xa9a59b, { nb: true });
  B.box(0, 0.35, 0, W, Hw, D, wall, { nb: true });
  B.prism(0, 0.35 + Hw, 0, D + 1.0, 1.6, W + 0.8, roof, true, wall);
  const winC = night ? 0xffd27a : 0x35577a;
  const WG = night ? Gw : B;
  WG.box(-2.2, 1.2, D / 2 + 0.01, 1.4, 1.0, 0.04, winC);
  WG.box(2.4, 1.2, D / 2 + 0.01, 1.4, 1.0, 0.04, winC);
  B.box(0.2, 0.35, D / 2 + 0.02, 1.1, 2.0, 0.05, 0x7a5a3a);
  B.box(-2.2, 1.15, D / 2 + 0.03, 1.5, 0.08, 0.06, 0xffffff);
  B.box(2.4, 1.15, D / 2 + 0.03, 1.5, 0.08, 0.06, 0xffffff);
  if (seed % 2 === 0) { // ㄱ자 별채
    B.box(W / 2 - 1.6, 0.35, -D / 2 - 1.8, 3.2, Hw - 0.3, 3.6, wall, { nb: true });
    B.prism(W / 2 - 1.6, 0.35 + Hw - 0.3, -D / 2 - 1.8, 3.8, 1.3, 4.2, roof, false, wall);
  }
  // 장독대
  const jx = -W / 2 - 1.2, jz = 1.0;
  B.box(jx, 0, jz, 2.2, 0.3, 1.6, 0x9c978c, { nb: true });
  for (let i = 0; i < 4; i++) {
    const s = 0.28 + r() * 0.12, x = jx - 0.65 + (i % 2) * 1.0 + (r() - 0.5) * 0.1, z = jz - 0.35 + Math.floor(i / 2) * 0.7;
    B.geo(PRIM.cyl8, M4(x, 0.3, z, s, s * 1.7, s), 0x6b3b22);
    B.geo(PRIM.cyl8, M4(x, 0.3 + s * 1.7, z, s * 0.8, 0.08, s * 0.8), 0x4e2a17);
  }
  // 돌담
  for (let x = -W / 2 - 2.2; x < W / 2 + 2.2; x += 1.1) B.box(x, 0, D / 2 + 3.2, 1.0, 0.6 + r() * 0.15, 0.5, r() < 0.5 ? 0x9c988e : 0xaaa69c, { nb: true });
  const parts = [{ geo: B.build(), mat: MAT.vc, cast: true, receive: true }];
  if (Gw) parts.push({ geo: Gw.build(), mat: MAT.glow, cast: false, receive: false, name: 'windows' });
  return { parts, info: { height: 4.8 } };
}

const PROP_BUILDERS = {
  tree: propTree, pine: propPine, bush: propBush, apartment: propApartment, mountain: propMountain,
  paddy: propPaddy, church: propChurch, streetLight: propStreetLight, billboard: propBillboard,
  cloud: propCloud, cctv: propCCTV, house: propHouse,
};

/**
 * 배경 소품. 원점 = 바닥 중심 (cctv 만 예외: 원점 = 도로 x=0, 기둥은 x≈+11.25 에 있고 팔이 도로 위로 뻗음).
 * 메시 1~3개, 공유 재질, 지오메트리는 (kind, seed%variants, night, opts) 로 캐시.
 * @param {'tree'|'pine'|'apartment'|'mountain'|'paddy'|'church'|'streetLight'|'billboard'|'cloud'|'cctv'|'house'|'bush'} kind
 * @param {number} seed
 * @param {{night?:boolean, double?:boolean, text?:string|string[], icon?:string|null, label?:string}} opts
 *   double: streetLight 양팔(분리대용) / text: billboard 문구 / label: cctv 표지 문구
 */
export function buildProp(kind, seed = 0, opts = {}) {
  const builder = PROP_BUILDERS[kind];
  const g = new THREE.Group();
  g.name = 'prop:' + kind;
  if (!builder) { console.warn('[scenery] unknown prop kind', kind); return g; }
  const night = !!opts.night;
  const nv = PROP_VARIANTS[kind] || 1;
  const v = ((seed | 0) % nv + nv) % nv;
  const key = `${kind}|${v}|${night ? 1 : 0}|${opts.double ? 1 : 0}|${opts.text ? String(opts.text) : ''}|${opts.label || ''}|${opts.icon || ''}`;
  const def = cached(_propCache, key, () => builder(v, night, opts));
  for (const p of def.parts) {
    let o;
    if (p.sprite != null) {
      o = new THREE.Sprite(glowSpriteMat(p.sprite));
      o.position.set(p.pos[0], p.pos[1], p.pos[2]);
      o.scale.setScalar(p.scale);
      o.renderOrder = 3;
    } else {
      o = new THREE.Mesh(p.geo, typeof p.mat === 'function' ? p.mat() : p.mat);
      o.castShadow = !!p.cast; o.receiveShadow = !!p.receive;
      if (p.order) o.renderOrder = p.order;
    }
    if (p.name) o.name = p.name;
    g.add(o);
  }
  g.userData = { kind, seed, night, ...def.info, drawCalls: g.children.length };
  return g;
}

// ─────────────────────────────────────────────────────────────
// 문형 지주 (표지판 / VMS 공용)
function gantryFrame(B, beamY0, beamY1, zc) {
  const xl = MEDIAN_X, xr = SH_R + 1.05;
  const steel = 0xaab2b9, steel2 = 0x949da5, conc = 0xb8b4aa;
  B.box(xl, 0.85, zc, 0.9, 0.4, 1.5, conc);
  B.box(xr, 0, zc, 1.3, 0.55, 1.7, conc, { nb: true });
  for (const [px, y0] of [[xl, 1.25], [xr, 0.55]]) {
    for (const dz of [-0.42, 0.42]) B.box(px, y0, zc + dz, 0.3, beamY1 - y0 + 0.25, 0.3, steel, { nb: true });
    for (let y = y0 + 0.8; y < beamY1; y += 1.1) B.box(px, y, zc, 0.14, 0.12, 0.84, steel2);
    B.box(px, beamY1 + 0.25, zc, 0.5, 0.12, 1.15, steel2);
  }
  const span = xr - xl, mx = (xl + xr) / 2;
  for (const dz of [-0.42, 0.42]) {
    for (const y of [beamY0, beamY1]) B.box(mx, y, zc + dz, span, 0.24, 0.24, steel);
    const hgt = beamY1 - beamY0;
    let k = 0;
    for (let x = xl + 0.6; x < xr - 0.5; x += 1.25, k++) {
      B.box(x, beamY0, zc + dz, 0.11, hgt, 0.11, steel2, { nb: true });
      const ang = Math.atan2(1.25, hgt) * (k % 2 ? 1 : -1);
      B.box(x + 0.625, beamY0 + 0.05, zc + dz, 0.09, Math.hypot(1.25, hgt) - 0.1, 0.09, steel2, { rz: ang });
    }
  }
  for (let x = xl + 0.6; x < xr - 0.5; x += 2.5) {
    B.box(x, beamY0, zc, 0.09, 0.09, 0.84, steel2); B.box(x, beamY1, zc, 0.09, 0.09, 0.84, steel2);
  }
}

function drawShield(ctx, cx, top, w, route) {
  const h = w * 1.08;
  ctx.save(); ctx.translate(cx - w / 2, top);
  const path = () => {
    ctx.beginPath(); ctx.moveTo(0, h * 0.08); ctx.quadraticCurveTo(w * 0.25, 0, w * 0.5, h * 0.1); ctx.quadraticCurveTo(w * 0.75, 0, w, h * 0.08);
    ctx.lineTo(w, h * 0.5); ctx.quadraticCurveTo(w * 0.98, h * 0.85, w * 0.5, h); ctx.quadraticCurveTo(w * 0.02, h * 0.85, 0, h * 0.5); ctx.closePath();
  };
  path(); ctx.fillStyle = '#ffffff'; ctx.fill();
  ctx.save(); ctx.translate(w * 0.5, h * 0.5); ctx.scale(0.86, 0.86); ctx.translate(-w * 0.5, -h * 0.5);
  path(); ctx.clip();
  ctx.fillStyle = '#1f4fa3'; ctx.fillRect(0, 0, w, h);
  ctx.fillStyle = '#d7261e'; ctx.fillRect(0, 0, w, h * 0.3);
  ctx.restore();
  ctx.fillStyle = '#ffffff'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
  fitFont(ctx, String(route), FONT_EN, w * 0.5, w * 0.7);
  ctx.fillText(String(route), w * 0.5, h * 0.6);
  ctx.restore();
  return h;
}
function drawUpArrow(ctx, cx, top, h, w) {
  const sw = w * 0.32, hh = h * 0.42;
  ctx.fillStyle = '#ffffff';
  ctx.beginPath();
  ctx.moveTo(cx, top); ctx.lineTo(cx + w / 2, top + hh); ctx.lineTo(cx + sw / 2, top + hh); ctx.lineTo(cx + sw / 2, top + h);
  ctx.lineTo(cx - sw / 2, top + h); ctx.lineTo(cx - sw / 2, top + hh); ctx.lineTo(cx - w / 2, top + hh); ctx.closePath(); ctx.fill();
}
function signMaterial(lines, route, bw, bh, night) {
  const key = 'gsign|' + JSON.stringify(lines) + '|' + route + '|' + bw + 'x' + bh + '|' + (night ? 1 : 0);
  return cached(_matCache, key, () => {
    const W = 2048, H = Math.round(W * bh / bw);
    const tex = textTexture(W, H, (ctx) => {
      ctx.fillStyle = '#0b7a4b'; rrect(ctx, 0, 0, W, H, 40); ctx.fill();
      ctx.strokeStyle = '#ffffff'; ctx.lineWidth = 14; rrect(ctx, 22, 22, W - 44, H - 44, 30); ctx.stroke();
      const leftW = 380;
      if (route != null) {
        const sw = 190, sh = sw * 1.08, ah = H - 110 - sh - 30;
        drawShield(ctx, 40 + leftW / 2, 52, sw, route);
        drawUpArrow(ctx, 40 + leftW / 2, 52 + sh + 26, Math.max(120, ah), 150);
      } else {
        drawUpArrow(ctx, 40 + leftW / 2, 70, H - 140, 200);
      }
      ctx.fillStyle = 'rgba(255,255,255,0.9)'; ctx.fillRect(40 + leftW + 10, 60, 6, H - 120);
      const n = Math.max(1, lines.length), x0 = 40 + leftW + 70, x1 = W - 80;
      const rowH = (H - 90) / n;
      lines.forEach((ln, i) => {
        const name = String(ln[0] || ''), dist = String(ln[1] || ''), en = ln[2] != null ? ln[2] : PLACE_EN[name];
        const cy = 45 + rowH * (i + 0.5);
        const namePx = Math.min(rowH * 0.6, 210);
        ctx.fillStyle = '#ffffff'; ctx.textBaseline = 'alphabetic'; ctx.textAlign = 'left';
        fitFont(ctx, name, FONT_DISPLAY, namePx, (x1 - x0) * 0.55);
        ctx.fillText(name, x0, cy + namePx * 0.22);
        if (en) {
          const nw = ctx.measureText(name).width;
          ctx.font = `${Math.round(namePx * 0.34)}px ${FONT_EN}`;
          ctx.fillText(en, x0 + nw + 28, cy + namePx * 0.22);
        }
        const m = dist.match(/^\s*([\d.,]+)\s*([a-zA-Z]*)\s*$/);
        ctx.textAlign = 'right';
        if (m) {
          const unit = m[2] || '';
          ctx.font = `${Math.round(namePx * 0.5)}px ${FONT_DISPLAY}`;
          const uw = unit ? ctx.measureText(unit).width : 0;
          if (unit) ctx.fillText(unit, x1, cy + namePx * 0.22);
          ctx.font = `${Math.round(namePx * 0.92)}px ${FONT_DISPLAY}`;
          ctx.fillText(m[1], x1 - uw - (unit ? 14 : 0), cy + namePx * 0.22);
        } else {
          ctx.font = `${Math.round(namePx * 0.8)}px ${FONT_DISPLAY}`;
          ctx.fillText(dist, x1, cy + namePx * 0.22);
        }
        if (i < n - 1) { ctx.fillStyle = 'rgba(255,255,255,0.35)'; ctx.fillRect(x0, 45 + rowH * (i + 1) - 2, x1 - x0, 4); }
      });
    }, { aniso: 16 });
    return new THREE.MeshLambertMaterial({ map: tex, emissive: 0xffffff, emissiveMap: tex, emissiveIntensity: night ? 0.55 : 0.22, name: 'scenery.sign' });
  });
}

/**
 * 녹색 도로 안내표지판 문형 지주. 원점 x=0, s=0(z=0). 판은 +Z(다가오는 차)를 바라봄. 판 하단 6.5m.
 * 지주: 좌 기둥 = 중앙분리대 위(MEDIAN_X), 우 기둥 = 갓길 바깥(x≈11.25).
 * @param {Array<[string,string,string?]>} lines  [['부산','387km'], ['대전','128km']]  (3번째=영문, 생략 시 사전)
 * @param {{night?:boolean, route?:number, width?:number}} opts  route: 고속도로 노선번호 방패
 */
export function buildGantrySign(lines, opts = {}) {
  lines = lines && lines.length ? lines : [['부산', '387km']];
  const night = !!opts.night;
  const bw = opts.width || 12, bh = Math.max(2.4, 1.0 + lines.length * 1.3), by = 6.5;
  const B = new GB();
  gantryFrame(B, by + 0.4, by + bh - 0.3, -0.75);
  B.box(0, by - 0.08, -0.12, bw + 0.16, bh + 0.16, 0.16, 0x9aa1a8);
  for (let x = -bw / 2 + 1; x < bw / 2; x += 2.5) B.box(x, by + 0.2, -0.45, 0.1, bh - 0.4, 0.5, 0x8a939b);
  const F = new GB(true);
  F.vquadZ(-0.03, -bw / 2, bw / 2, by, by + bh, 1, 0xffffff);
  const g = new THREE.Group();
  g.name = 'gantrySign';
  const frame = new THREE.Mesh(cached(_propCache, 'gantryFrame|' + bh + '|' + bw, () => B.build()), MAT.vc);
  frame.castShadow = true; frame.receiveShadow = true;
  const face = new THREE.Mesh(cached(_propCache, 'gantryFace|' + bh + '|' + bw, () => F.build()), signMaterial(lines, opts.route, bw, bh, night));
  face.name = 'board';
  g.add(frame, face);
  g.userData = { kind: 'gantrySign', board: face, width: bw, height: bh, bottom: by, drawCalls: 2 };
  return g;
}

// ─────────────────────────────────────────────────────────────
// VMS (도로전광표지): 검은 판 + 주황 LED 도트 매트릭스
const VMS_COLS = 224, VMS_ROWS = 40, VMS_P = 8;
function vmsTiles() {
  return cached(_texCache, 'vmsTiles', () => {
    const P = VMS_P;
    const off = makeCanvas(P, P), o = off.getContext('2d');
    o.fillStyle = '#060607'; o.fillRect(0, 0, P, P);
    o.fillStyle = '#2b2419'; o.beginPath(); o.arc(P / 2, P / 2, P * 0.34, 0, 7); o.fill();
    const mask = makeCanvas(P, P), m = mask.getContext('2d');
    m.fillStyle = '#fff'; m.beginPath(); m.arc(P / 2, P / 2, P * 0.42, 0, 7); m.fill();
    return { off, mask };
  });
}
/**
 * 도로 위 주황 LED 전광판. 원점 x=0, z=0. 판 하단 6.6m, +Z를 바라봄.
 * userData.setText(text, color='#ffb000') — 캔버스 재그림 ('\n' 으로 2줄 가능)
 */
export function buildVMS(text, opts = {}) {
  const night = !!opts.night;
  const bw = opts.width || 11, bh = 2.3, by = 6.6;
  const B = new GB();
  gantryFrame(B, by + 0.35, by + bh - 0.35, -0.95);
  B.box(0, by, -0.35, bw, bh, 0.7, 0x1c1f24, { top: 0x2a2e34 });
  B.box(0, by - 0.1, -0.3, bw + 0.2, 0.12, 0.8, 0x8a939b);
  B.box(0, by + bh, -0.3, bw + 0.2, 0.12, 0.8, 0x8a939b);
  B.box(-bw / 2 - 0.05, by - 0.1, -0.3, 0.12, bh + 0.32, 0.8, 0x8a939b);
  B.box(bw / 2 + 0.05, by - 0.1, -0.3, 0.12, bh + 0.32, 0.8, 0x8a939b);
  // 상단 소형 표지 띠 (도로공사 로고 대용 주황 줄)
  B.box(0, by + bh + 0.12, -0.05, bw * 0.3, 0.1, 0.04, 0xf08a1c);
  const ledW = bw - 0.5, ledH = ledW * VMS_ROWS / VMS_COLS;
  const F = new GB(true);
  F.vquadZ(0.005, -ledW / 2, ledW / 2, by + (bh - ledH) / 2, by + (bh + ledH) / 2, 1, 0xffffff);

  // 인스턴스마다 자체 캔버스 (setText 로 바뀜)
  const W = VMS_COLS * VMS_P, H = VMS_ROWS * VMS_P;
  const out = makeCanvas(W, H), octx = out.getContext('2d');
  const mat = makeCanvas(VMS_COLS, VMS_ROWS), mctx = mat.getContext('2d', { willReadFrequently: true });
  const tmp = makeCanvas(W, H), tctx = tmp.getContext('2d');
  const tex = canvasTex(out, { aniso: 8 });
  const tiles = vmsTiles();
  const offPat = octx.createPattern(tiles.off, 'repeat');
  const maskPat = tctx.createPattern(tiles.mask, 'repeat');
  let curText = '', curColor = '#ffb000';
  const draw = () => {
    const lines = String(curText).split('\n');
    mctx.clearRect(0, 0, VMS_COLS, VMS_ROWS);
    mctx.fillStyle = '#fff'; mctx.textAlign = 'center'; mctx.textBaseline = 'middle';
    let px = lines.length > 1 ? 18 : 31;
    mctx.font = `${px}px ${FONT_DISPLAY}`;
    const maxW = Math.max(...lines.map((l) => mctx.measureText(l).width));
    if (maxW > VMS_COLS - 8) { px = Math.floor(px * (VMS_COLS - 8) / maxW); mctx.font = `${px}px ${FONT_DISPLAY}`; }
    lines.forEach((l, i) => mctx.fillText(l, VMS_COLS / 2, VMS_ROWS / 2 + (i - (lines.length - 1) / 2) * (VMS_ROWS / lines.length) + 1));
    const id = mctx.getImageData(0, 0, VMS_COLS, VMS_ROWS), d = id.data;
    for (let i = 3; i < d.length; i += 4) { const on = d[i] > 100 ? 255 : 0; d[i - 3] = d[i - 2] = d[i - 1] = 255; d[i] = on; }
    mctx.putImageData(id, 0, 0);
    octx.globalCompositeOperation = 'source-over'; octx.filter = 'none'; octx.globalAlpha = 1;
    octx.fillStyle = offPat; octx.fillRect(0, 0, W, H);
    tctx.globalCompositeOperation = 'source-over'; tctx.clearRect(0, 0, W, H);
    tctx.imageSmoothingEnabled = false; tctx.drawImage(mat, 0, 0, W, H);
    tctx.globalCompositeOperation = 'source-in'; tctx.fillStyle = curColor; tctx.fillRect(0, 0, W, H);
    tctx.globalCompositeOperation = 'destination-in'; tctx.fillStyle = maskPat; tctx.fillRect(0, 0, W, H);
    tctx.globalCompositeOperation = 'source-over';
    octx.globalCompositeOperation = 'lighter'; octx.globalAlpha = 0.55; octx.filter = 'blur(5px)';
    octx.drawImage(tmp, 0, 0);
    octx.filter = 'none'; octx.globalAlpha = 1; octx.globalCompositeOperation = 'source-over';
    octx.drawImage(tmp, 0, 0);
    tex.needsUpdate = true;
  };
  const setText = (t, color = '#ffb000') => {
    curText = t == null ? '' : String(t); curColor = color;
    draw();
    if (HAS_DOM && document.fonts && document.fonts.check && !document.fonts.check(`32px "Black Han Sans"`, curText)) {
      const want = curText;
      document.fonts.load(`32px "Black Han Sans"`, want).then(() => { if (curText === want) draw(); }).catch(() => {});
    }
  };
  _redraws.add(draw);
  setText(text || '', opts.color || '#ffb000');

  const g = new THREE.Group();
  g.name = 'vms';
  const frame = new THREE.Mesh(cached(_propCache, 'vmsFrame|' + bw, () => B.build()), MAT.vc);
  frame.castShadow = true; frame.receiveShadow = true;
  const face = new THREE.Mesh(cached(_propCache, 'vmsFace|' + bw, () => F.build()), new THREE.MeshBasicMaterial({ map: tex, name: 'scenery.vms' }));
  face.name = 'led';
  g.add(frame, face);
  g.userData = {
    kind: 'vms', board: face, width: bw, height: bh, bottom: by, drawCalls: 2,
    setText, get text() { return curText; },
    dispose() { _redraws.delete(draw); tex.dispose(); face.material.dispose(); },
  };
  return g;
}

// ─────────────────────────────────────────────────────────────
// 현수막
function bannerMaterial(text, colors) {
  const key = 'banner|' + text + '|' + (colors ? colors.join(',') : '');
  return cached(_matCache, key, () => {
    const tex = textTexture(1024, 228, (ctx, w, h) => {
      ctx.fillStyle = '#fbfbf5'; ctx.fillRect(0, 0, w, h);
      ctx.fillStyle = 'rgba(0,0,0,0.04)'; for (let y = 0; y < h; y += 6) ctx.fillRect(0, y, w, 2);
      // 앞부분(! 또는 첫 단어까지) 빨강, 나머지 파랑
      let a = text, b = '';
      const m = text.match(/^(.*?[!?])\s*(.*)$/);
      if (m && m[2]) { a = m[1]; b = m[2]; }
      else { const sp = text.indexOf(' '); if (sp > 0) { a = text.slice(0, sp); b = text.slice(sp + 1); } }
      const ca = colors ? colors[0] : '#d7261e', cb = colors ? colors[1] || colors[0] : '#1f4fa3';
      ctx.textBaseline = 'middle';
      let px = 150;
      ctx.font = `${px}px ${FONT_DISPLAY}`;
      const gap = b ? 34 : 0;
      let wa = ctx.measureText(a).width, wb = b ? ctx.measureText(b).width : 0;
      const maxW = w - 80;
      if (wa + wb + gap > maxW) { px = Math.floor(px * maxW / (wa + wb + gap)); ctx.font = `${px}px ${FONT_DISPLAY}`; wa = ctx.measureText(a).width; wb = b ? ctx.measureText(b).width : 0; }
      let x = (w - (wa + wb + gap)) / 2;
      ctx.textAlign = 'left';
      ctx.fillStyle = ca; ctx.fillText(a, x, h / 2 + 6);
      if (b) { ctx.fillStyle = cb; ctx.fillText(b, x + wa + gap, h / 2 + 6); }
      // 고리 구멍
      ctx.fillStyle = '#9aa0a6';
      for (const [gx, gy] of [[16, 16], [w - 16, 16], [16, h - 16], [w - 16, h - 16]]) { ctx.beginPath(); ctx.arc(gx, gy, 8, 0, 7); ctx.fill(); }
    }, { aniso: 8 });
    return new THREE.MeshLambertMaterial({ map: tex, side: THREE.DoubleSide, emissive: 0xffffff, emissiveMap: tex, emissiveIntensity: 0.08, name: 'scenery.banner' });
  });
}
/**
 * 현수막 (흰 천 + 빨강/파랑 글씨) — 두 기둥 사이, 원점 = 바닥 중심, 천은 +Z 를 바라봄.
 * 권장 배치: x ≈ LAYOUT.bannerR (13.6), 폭 5.4m.
 * @param {string} text  '졸음운전! 자면 죽는다'  (! 앞부분 빨강, 뒤 파랑)
 * @param {{width?:number, height?:number, colors?:[string,string], seed?:number}} opts
 */
export function buildBanner(text = '졸음운전! 자면 죽는다', opts = {}) {
  const W = opts.width || 5.4, H = opts.height || 1.2, y0 = 1.0;
  const seed = opts.seed | 0;
  const geoKey = `banner|${W}|${H}|${seed % 3}`;
  const posts = cached(_propCache, geoKey + '|posts', () => {
    const B = new GB();
    for (const sx of [-1, 1]) {
      B.box(sx * (W / 2 + 0.15), 0, 0, 0.4, 0.25, 0.4, 0xb2aea4, { nb: true });
      B.box(sx * (W / 2 + 0.15), 0.25, 0, 0.1, y0 + H + 0.25, 0.1, 0x8d949b, { nb: true, top: 0xd7261e });
      B.box(sx * (W / 2 + 0.07), y0 + H - 0.08, 0, 0.18, 0.04, 0.04, 0x333333);
      B.box(sx * (W / 2 + 0.07), y0 + 0.04, 0, 0.18, 0.04, 0.04, 0x333333);
    }
    return B.build();
  });
  const cloth = cached(_propCache, geoKey + '|cloth', () => {
    const g = new THREE.PlaneGeometry(W, H, 18, 2);
    const p = g.attributes.position;
    for (let i = 0; i < p.count; i++) {
      const x = p.getX(i), y = p.getY(i);
      p.setZ(i, Math.sin(x * 2.1 + seed) * 0.05 + Math.sin(x * 0.9 + y * 2 + seed * 2) * 0.03);
    }
    g.translate(0, y0 + H / 2, 0);
    g.computeVertexNormals();
    return g;
  });
  const g = new THREE.Group();
  g.name = 'banner';
  const pm = new THREE.Mesh(posts, MAT.vc); pm.castShadow = true; pm.receiveShadow = true;
  const cm = new THREE.Mesh(cloth, bannerMaterial(String(text), opts.colors)); cm.castShadow = true; cm.name = 'cloth';
  g.add(pm, cm);
  g.userData = { kind: 'banner', text, width: W, drawCalls: 2 };
  return g;
}

// ─────────────────────────────────────────────────────────────
// 하늘 돔
/**
 * 그라데이션 하늘 (반경 900, 안쪽 면). fog:false, depthWrite:false, depthTest:false, renderOrder −1000.
 * 카메라를 따라다니게 position 을 카메라 위치로 매 프레임 복사. 어두운 top 이면 별이 자동으로 뜬다.
 * userData.setColors(top, bottom)
 * @param {number} topColor
 * @param {number} bottomColor
 * @param {{stars?:boolean, exponent?:number}} opts  (추가 옵션)
 */
export function makeSkyDome(topColor = 0x5fb8ff, bottomColor = 0xd8f0ff, opts = {}) {
  const geo = new THREE.SphereGeometry(900, 32, 16);
  const uniforms = {
    topColor: { value: new THREE.Color(topColor) },
    bottomColor: { value: new THREE.Color(bottomColor) },
    exponent: { value: opts.exponent || 0.6 },
    stars: { value: 0 },
  };
  const autoStars = () => {
    const c = uniforms.topColor.value;
    uniforms.stars.value = opts.stars != null ? (opts.stars ? 1 : 0) : (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b < 0.03 ? 1 : 0);
  };
  autoStars();
  const mat = new THREE.ShaderMaterial({
    name: 'scenery.sky',
    uniforms,
    side: THREE.BackSide, depthWrite: false, depthTest: false, fog: false,
    vertexShader: /* glsl */`
      varying vec3 vDir;
      void main() {
        vDir = position;
        vec4 p = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
        gl_Position = p.xyww;
      }`,
    fragmentShader: /* glsl */`
      uniform vec3 topColor; uniform vec3 bottomColor; uniform float exponent; uniform float stars;
      varying vec3 vDir;
      float hash(vec3 p) { p = fract(p * 0.3183099 + 0.1); p *= 17.0; return fract(p.x * p.y * p.z * (p.x + p.y + p.z)); }
      void main() {
        vec3 d = normalize(vDir);
        float h = clamp(d.y, 0.0, 1.0);
        vec3 col = mix(bottomColor, topColor, pow(h, exponent));
        col = mix(col, bottomColor * 1.04, smoothstep(0.08, 0.0, h) * 0.5);
        if (stars > 0.5 && d.y > 0.06) {
          vec3 q = d * 140.0; vec3 cell = floor(q); vec3 f = fract(q) - 0.5;
          float r = hash(cell);
          if (r > 0.975) {
            float s = smoothstep(0.22, 0.0, length(f)) * smoothstep(0.06, 0.3, d.y);
            col += vec3(0.9, 0.92, 1.0) * s * (0.5 + 0.5 * fract(r * 37.0));
          }
        }
        gl_FragColor = vec4(col, 1.0);
        #include <tonemapping_fragment>
        #include <colorspace_fragment>
      }`,
  });
  const m = new THREE.Mesh(geo, mat);
  m.name = 'skyDome';
  m.frustumCulled = false;
  m.renderOrder = -1000;
  m.userData.setColors = (top, bottom) => {
    if (top != null) uniforms.topColor.value.set(top);
    if (bottom != null) uniforms.bottomColor.value.set(bottom);
    autoStars();
  };
  return m;
}
