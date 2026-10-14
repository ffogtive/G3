// fx.js — 3D 파티클 · 카메라 셰이크 · 스피드라인 (길건너친구들 풍 통통한 큐브)
//
// 가설: 계약서대로 FX 클래스를 만들면 코어(main/boss/weapons)가 그대로 붙고,
//      큐브 파티클이 "참교육" 쾌감의 절반을 담당한다. → 크고, 밝고, 과장되게.
//
// 구조 (전부 풀링 — update() 에서 할당 0)
//  · CubePool  : InstancedMesh 1개 = draw call 1개. Float32Array(stride) SoA + swap-remove.
//                활성 0개면 visible=false (draw 0). 꽉 차면 라운드로빈으로 덮어씀.
//      basic    — 무광 원색(가짜 면 음영 vertex color): 불꽃, 불덩이           cap 900
//      glow     — 가산 블렌딩: 폭발의 뜨거운 부분                           cap 320
//      lit      — 램버트 + 약한 자체발광: 파편                                cap 500
//      smoke    — 램버트 + 중간 자체발광: 연기·연기꼬리·흙먼지 (아래서 봐도 안 칙칙)  cap 1000
//      confetti — 램버트 + 강한 자체발광, 납작한 조각, 팔랑팔랑                 cap 700
//  · Billboard : 하트/별 (InstancedMesh plane, alphaTest) — 하트 60 / 별 30, 오래된 것부터 재활용
//  · Sprite    : 글로우(가산) 28 / 반짝별(일반) 28 — 폭발 코어 섬광, hitFlash, twinkle★
//  · 링(충격파) 10, 코어 섬광(icosa) 6, smokeTrail 이미터 16, 스피드라인 72 (카메라 자식)
//  · 셰이크: trauma 누적(상한 1.2) → 사인합 노이즈. 오프셋 ≈ 0.8m × trauma^1.5.
//  · 시간: 큐브 파티클/링/트레일/스피드라인 = 게임 dt (슬로모션 불덩이).
//          섬광·스프라이트·셰이크 = max(게임 dt, 실제 경과) → 히트스톱 중에도 "쾅", 슬로모에서도 섬광이 금방 걷힘.
//  · 카메라 코앞(1.5~8m) 큐브/스프라이트는 줄어들거나 투명해짐 → 킬캠이 불덩이·연기꼬리를 관통해도 화면이 안 막힘.
//  · twinkle: 화면 안에서 터지면 카메라 자식으로 고정 → 같은 프레임에 드론샷으로 홱 돌아가도 1초간 보임.
import * as THREE from 'three';

// ───────────────────────────── 결정적 RNG (하네스 스크린샷 재현용)
let _seed = 0x2f6e2b1d;
function rnd() {
  _seed ^= _seed << 13; _seed ^= _seed >>> 17; _seed ^= _seed << 5;
  return (_seed >>> 0) / 4294967296;
}
const rr = (a, b) => a + (b - a) * rnd();
const clamp = (v, a, b) => (v < a ? a : v > b ? b : v);
const num = (v, d) => { const n = +v; return Number.isFinite(n) ? n : d; };
const easeOutBack = (x) => { const c1 = 1.9, c3 = c1 + 1, u = x - 1; return 1 + c3 * u * u * u + c1 * u * u; };

// ───────────────────────────── 임시 객체 (재사용)
const _p = new THREE.Vector3(), _s = new THREE.Vector3(), _v = new THREE.Vector3(), _w = new THREE.Vector3();
const _P = new THREE.Vector3(), _D = new THREE.Vector3(), _R = new THREE.Vector3(), _U = new THREE.Vector3();
const _q = new THREE.Quaternion(), _q2 = new THREE.Quaternion(), _cq = new THREE.Quaternion();
const _e = new THREE.Euler(), _m = new THREE.Matrix4(), _c = new THREE.Color();
const AX_Z = new THREE.Vector3(0, 0, 1);
// 프레임 공유 값. double 을 함수 인자로 넘기면 V8 이 매번 HeapNumber 로 박싱하므로 typed array 로 공유
const CAM = new Float64Array(3);   // 카메라 월드 위치
const FRAME = new Float64Array(2); // [0] = 게임 dt (클램프), [1] = 연출 dt = max(게임 dt, 실제 경과)

// 인스턴스 버퍼 부분 업로드 [0, count). addUpdateRange() 는 매번 {start,count} 객체를 만들므로
// 속성마다 범위 객체 1개를 재사용한다 (three 는 업로드 후 updateRanges 를 비움).
function uploadRange(attr, count) {
  let r = attr.userData && attr.userData.fxRange;
  if (!r) { attr.userData = attr.userData || {}; r = attr.userData.fxRange = { start: 0, count: 0 }; }
  r.start = 0; r.count = count;
  const ur = attr.updateRanges;
  ur.length = 0; ur.push(r);
  attr.needsUpdate = true;
}
function readPos(p, out) {
  if (!p || typeof p !== 'object') return false;
  const x = Array.isArray(p) ? +p[0] : +p.x, y = Array.isArray(p) ? +p[1] : +p.y, z = Array.isArray(p) ? +p[2] : +p.z;
  if (!Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(z)) return false;
  out.set(x, y, z);
  return true;
}
function setColor(c, v, fallback) {
  try {
    if (typeof v === 'number' && Number.isFinite(v)) c.setHex(v);
    else if (v && v.isColor) c.copy(v);
    else if (typeof v === 'string' && v) c.set(v);
    else c.setHex(fallback);
  } catch { c.setHex(fallback); }
  return c;
}
// 단위 구 위 랜덤 방향 → out
function randDir(out) {
  const u = rnd() * 2 - 1, a = rnd() * Math.PI * 2, r = Math.sqrt(1 - u * u);
  return out.set(r * Math.cos(a), u, r * Math.sin(a));
}

// ───────────────────────────── 색 램프 (sRGB hex → linear)
function ramp(stops) {
  const out = new Float32Array(stops.length * 4);
  stops.forEach(([t, hex], i) => { _c.setHex(hex); out[i * 4] = t; out[i * 4 + 1] = _c.r; out[i * 4 + 2] = _c.g; out[i * 4 + 3] = _c.b; });
  return out;
}
const R_FIRE = 0, R_SPARK = 1, R_GLOW = 2, R_SMOKE = 3, R_TRAILFIRE = 4, R_HIT = 5, R_EMBER = 6;
const RAMPS = [
  ramp([[0, 0xffffff], [0.06, 0xfff07a], [0.16, 0xffc81a], [0.32, 0xff8a10], [0.5, 0xf04a18], [0.66, 0xb02a18], [0.8, 0x3c3232], [1, 0x4c4646]]),
  ramp([[0, 0xffffff], [0.18, 0xfff27a], [0.5, 0xffb41e], [0.8, 0xff5a14], [1, 0xc42a10]]),
  ramp([[0, 0xffd27a], [0.3, 0xffa830], [0.62, 0xff5a10], [1, 0x000000]]),
  ramp([[0, 0x3e3836], [0.45, 0x5e5958], [1, 0x8a8686]]),
  ramp([[0, 0xfff8c8], [0.35, 0xffc83a], [0.7, 0xff6a14], [1, 0xb8301a]]),
  ramp([[0, 0xffffff], [1, 0xfff0a0]]),
  ramp([[0, 0xffe08a], [0.4, 0xff7a1a], [1, 0x5a2a20]]),
];
function rampColor(r, t, tr, tg, tb, out, o) {
  const n = r.length >> 2;
  let k = 1;
  while (k < n - 1 && t > r[k * 4]) k++;
  const a = (k - 1) * 4, b = k * 4, t0 = r[a], t1 = r[b];
  let u = t1 > t0 ? (t - t0) / (t1 - t0) : 0;
  u = u < 0 ? 0 : u > 1 ? 1 : u;
  out[o] = (r[a + 1] + (r[b + 1] - r[a + 1]) * u) * tr;
  out[o + 1] = (r[a + 2] + (r[b + 2] - r[a + 2]) * u) * tg;
  out[o + 2] = (r[a + 3] + (r[b + 3] - r[a + 3]) * u) * tb;
}

// ───────────────────────────── 크기 커브 (t = life/max) — CubePool.update 안에 인라인 (함수 호출 시 double 박싱 회피)
//  SHRINK: 1→0 (살짝 볼록)   POP: 0→1.22 팍 커졌다가 줄어듦   GROW: 0.35→1 부풀고 끝에서 줄어듦
//  HOLD: 바로 1, 끝 20% 에서 줄어듦   FLASH: 0.5→1.2 후 제곱으로 줄어듦
const C_SHRINK = 0, C_POP = 1, C_GROW = 2, C_HOLD = 3, C_FLASH = 4;

// ───────────────────────────── CubePool
const S = 32; // stride
const PX = 0, PY = 1, PZ = 2, VX = 3, VY = 4, VZ = 5, EX = 6, EY = 7, EZ = 8, WX = 9, WY = 10, WZ = 11,
  SX = 12, SY = 13, SZ = 14, LIFE = 15, MAX = 16, DELAY = 17, GRAV = 18, DRAG = 19, BOUNCE = 20, CURVE = 21,
  RAMP = 22, CR = 23, CG = 24, CB = 25, FLAGS = 26, PHASE = 27, FREQ = 28, ENDMUL = 29, AMP = 30, STR = 31;
const F_STRETCH = 1, F_FLUTTER = 2, F_SETTLE = 4;

class CubePool {
  constructor(parent, geo, material, cap, name) {
    this.cap = cap;
    this.n = 0;
    this.rr = 0;
    this.dirty = false;
    this.d = new Float32Array(cap * S);
    const mesh = new THREE.InstancedMesh(geo, material, cap);
    mesh.name = 'fx.' + name;
    mesh.frustumCulled = false;
    mesh.castShadow = false;
    mesh.receiveShadow = false;
    mesh.instanceMatrix.setUsage(THREE.DynamicDrawUsage);
    mesh.instanceColor = new THREE.InstancedBufferAttribute(new Float32Array(cap * 3).fill(1), 3);
    mesh.instanceColor.setUsage(THREE.DynamicDrawUsage);
    mesh.count = 0;
    mesh.visible = false;
    parent.add(mesh);
    this.mesh = mesh;
  }
  // 새 파티클 슬롯 (기본값 채움) → data offset
  add() {
    let i;
    if (this.n < this.cap) i = this.n++;
    else { i = this.rr; this.rr = (this.rr + 1) % this.cap; }
    const d = this.d, o = i * S;
    d.fill(0, o, o + S);
    d[o + MAX] = 1; d[o + BOUNCE] = -1; d[o + RAMP] = -1; d[o + ENDMUL] = 1;
    d[o + CR] = d[o + CG] = d[o + CB] = 1;
    d[o + SX] = d[o + SY] = d[o + SZ] = 1;
    this.dirty = true;
    return o;
  }
  clear() {
    this.n = 0; this.rr = 0; this.dirty = false;
    this.mesh.count = 0; this.mesh.visible = false;
  }
  // CAM = 카메라 월드 위치: 카메라 코앞(1.5~8m)의 큐브는 작아져서 화면을 가리지 않는다 (킬캠이 불덩이/연기꼬리를 관통)
  update(camMoved) {
    const dt = FRAME[0];
    let n = this.n;
    if (n === 0) { if (this.mesh.visible) { this.mesh.visible = false; this.mesh.count = 0; } return; }
    if (dt <= 0 && !this.dirty && !camMoved) return; // 정지(히트스톱/일시정지) 중엔 다시 쓸 필요 없음
    this.dirty = false;
    const d = this.d, mat = this.mesh.instanceMatrix.array, col = this.mesh.instanceColor.array;
    const cx = CAM[0], cy = CAM[1], cz = CAM[2];
    let i = 0;
    while (i < n) {
      const o = i * S;
      if (d[o + DELAY] > 0) {
        d[o + DELAY] -= dt;
        mat.fill(0, i * 16, i * 16 + 16); // 아직 안 나타남 (scale 0)
        i++;
        continue;
      }
      d[o + LIFE] += dt;
      if (d[o + LIFE] >= d[o + MAX]) {
        n--;
        if (i !== n) d.copyWithin(o, n * S, n * S + S);
        continue;
      }
      const t = d[o + LIFE] / d[o + MAX], fl = d[o + FLAGS];
      let px = d[o + PX], py = d[o + PY], pz = d[o + PZ], vx = d[o + VX], vy = d[o + VY], vz = d[o + VZ];
      let k;
      const cv = d[o + CURVE];
      if (cv === C_SHRINK) k = 1 - t * t * 0.35 - t * 0.65;
      else if (cv === C_POP) { if (t < 0.1) { const q = t / 0.1; k = 1.22 * q * (2 - q); } else k = 1.22 * Math.pow(1 - (t - 0.1) / 0.9, 0.85); }
      else if (cv === C_GROW) {
        if (t < 0.16) { const q = t / 0.16; k = 0.35 + 0.65 * q * (2 - q); } else k = 1;
        if (t > 0.62) { const q = (t - 0.62) / 0.38; k *= 1 - q * q; }
      } else if (cv === C_HOLD) k = t < 0.035 ? t / 0.035 : t > 0.8 ? (1 - t) / 0.2 : 1;
      else if (cv === C_FLASH) { if (t < 0.08) k = 0.5 + 0.7 * (t / 0.08); else { const q = 1 - (t - 0.08) / 0.92; k = 1.2 * q * q; } }
      else k = 1 - t;
      k *= 1 + (d[o + ENDMUL] - 1) * t;
      {
        const ex = px - cx, ey = py - cy, ez = pz - cz, dd = ex * ex + ey * ey + ez * ez;
        if (dd < 64) { const u = (Math.sqrt(dd) - 1.5) / 6.5; k *= u <= 0 ? 0 : u * u * (3 - 2 * u); }
      }
      if (dt > 0) {
        const dr = 1 / (1 + d[o + DRAG] * dt);
        vy -= d[o + GRAV] * dt;
        vx *= dr; vy *= dr; vz *= dr;
        px += vx * dt; py += vy * dt; pz += vz * dt;
        if (fl & F_FLUTTER) {
          const life = d[o + LIFE], ph = d[o + PHASE], fq = d[o + FREQ], amp = d[o + AMP];
          px += Math.cos(ph + life * fq) * amp * dt;
          pz += Math.sin(ph * 1.7 + life * fq * 0.83) * amp * dt;
        }
        d[o + EX] += d[o + WX] * dt; d[o + EY] += d[o + WY] * dt; d[o + EZ] += d[o + WZ] * dt;
        const b = d[o + BOUNCE];
        if (b >= 0) {
          const h = 0.5 * d[o + SY] * k;
          if (py < h) {
            py = h;
            if (vy < 0) {
              vy = -vy * b;
              if (vy < 1.1) vy = 0;
              vx *= 0.62; vz *= 0.62;
              d[o + WX] *= 0.55; d[o + WY] *= 0.55; d[o + WZ] *= 0.55;
              if (fl & F_SETTLE) { // 컨페티: 바닥에 납작하게 눕는다
                vx = vz = vy = 0;
                d[o + EX] = 0; d[o + EZ] = 0; d[o + WX] = d[o + WY] = d[o + WZ] = 0;
                d[o + FLAGS] = fl & ~F_FLUTTER;
              }
            }
          }
        }
        d[o + PX] = px; d[o + PY] = py; d[o + PZ] = pz; d[o + VX] = vx; d[o + VY] = vy; d[o + VZ] = vz;
      }
      // 회전: 속도 방향(불꽃 줄기) 또는 오일러 → 쿼터니언. 행렬은 직접 합성해 기록 (double 인자 박싱 없음)
      let sx = d[o + SX] * k, sy = d[o + SY] * k, sz = d[o + SZ] * k;
      if (fl & F_STRETCH) {
        const sp = Math.sqrt(vx * vx + vy * vy + vz * vz);
        if (sp > 1e-3) { _v.x = vx / sp; _v.y = vy / sp; _v.z = vz / sp; _q.setFromUnitVectors(AX_Z, _v); } else _q.identity();
        const st = sp * d[o + STR];
        sz += (st < 1.8 ? st : 1.8) * k;
      } else {
        _e._x = d[o + EX]; _e._y = d[o + EY]; _e._z = d[o + EZ];
        _q.setFromEuler(_e);
      }
      if (k <= 0) { sx = 0; sy = 0; sz = 0; }
      const qx = _q._x, qy = _q._y, qz = _q._z, qw = _q._w;
      const x2 = qx + qx, y2 = qy + qy, z2 = qz + qz;
      const xx = qx * x2, xy = qx * y2, xz = qx * z2, yy = qy * y2, yz = qy * z2, zz = qz * z2;
      const wx = qw * x2, wy = qw * y2, wz = qw * z2;
      const m = i * 16;
      mat[m] = (1 - (yy + zz)) * sx; mat[m + 1] = (xy + wz) * sx; mat[m + 2] = (xz - wy) * sx; mat[m + 3] = 0;
      mat[m + 4] = (xy - wz) * sy; mat[m + 5] = (1 - (xx + zz)) * sy; mat[m + 6] = (yz + wx) * sy; mat[m + 7] = 0;
      mat[m + 8] = (xz + wy) * sz; mat[m + 9] = (yz - wx) * sz; mat[m + 10] = (1 - (xx + yy)) * sz; mat[m + 11] = 0;
      mat[m + 12] = px; mat[m + 13] = py; mat[m + 14] = pz; mat[m + 15] = 1;
      const ci = i * 3, rp = d[o + RAMP];
      if (rp >= 0) rampColor(RAMPS[rp], t, d[o + CR], d[o + CG], d[o + CB], col, ci);
      else { col[ci] = d[o + CR]; col[ci + 1] = d[o + CG]; col[ci + 2] = d[o + CB]; }
      i++;
    }
    this.n = n;
    const mesh = this.mesh;
    mesh.count = n;
    mesh.visible = n > 0;
    if (n > 0) {
      uploadRange(mesh.instanceMatrix, n * 16);
      uploadRange(mesh.instanceColor, n * 3);
    }
  }
}

// ───────────────────────────── 하트/별 빌보드 (InstancedMesh plane)
const B = 12; // stride: x,y,z, vx,vy, life,max, size, phase, alive, vz, spin
class BillboardPool {
  constructor(parent, geo, tex, cap, name) {
    this.cap = cap; this.head = 0; this.live = 0;
    this.d = new Float32Array(cap * B);
    const mat = new THREE.MeshBasicMaterial({ map: tex, alphaTest: 0.5, side: THREE.DoubleSide, fog: true });
    const mesh = new THREE.InstancedMesh(geo, mat, cap);
    mesh.name = 'fx.' + name;
    mesh.frustumCulled = false;
    mesh.instanceMatrix.setUsage(THREE.DynamicDrawUsage);
    mesh.count = 0; mesh.visible = false;
    mesh.renderOrder = 2;
    parent.add(mesh);
    this.mesh = mesh;
  }
  spawn(x, y, z, size, life, vy, vx) {
    const o = this.head * B, d = this.d;
    if (!d[o + 9]) this.live++;
    this.head = (this.head + 1) % this.cap; // 꽉 차면 가장 오래된 것을 재활용
    d[o] = x; d[o + 1] = y; d[o + 2] = z; d[o + 3] = vx; d[o + 4] = vy; d[o + 5] = 0; d[o + 6] = life;
    d[o + 7] = size; d[o + 8] = rnd() * 6.283; d[o + 9] = 1; d[o + 10] = rr(-0.4, 0.4); d[o + 11] = rr(-1, 1);
  }
  clear() { this.d.fill(0); this.live = 0; this.head = 0; this.mesh.count = 0; this.mesh.visible = false; }
  update(camQ) {
    if (this.live === 0) { if (this.mesh.visible) { this.mesh.visible = false; this.mesh.count = 0; } return; }
    const dt = FRAME[0];
    const d = this.d, mat = this.mesh.instanceMatrix.array;
    let k = 0;
    for (let i = 0; i < this.cap; i++) {
      const o = i * B;
      if (!d[o + 9]) continue;
      d[o + 5] += dt;
      const life = d[o + 5], t = life / d[o + 6];
      if (t >= 1) { d[o + 9] = 0; this.live--; continue; }
      if (dt > 0) {
        d[o + 4] *= 1 / (1 + 0.9 * dt);
        d[o] += (d[o + 3] + Math.cos(life * 3.1 + d[o + 8]) * 0.55) * dt;
        d[o + 1] += d[o + 4] * dt;
        d[o + 2] += d[o + 10] * dt;
      }
      let sc = t < 0.16 ? easeOutBack(t / 0.16) : t > 0.72 ? 1 - Math.pow((t - 0.72) / 0.28, 1.5) : 1 + Math.sin((t - 0.16) * 14) * 0.05;
      sc *= d[o + 7];
      _q2.setFromAxisAngle(AX_Z, Math.sin(life * 5.5 + d[o + 8]) * 0.24 + d[o + 11] * 0.15);
      _q.copy(camQ).multiply(_q2);
      _p.set(d[o], d[o + 1], d[o + 2]);
      _s.set(sc, sc, sc);
      _m.compose(_p, _q, _s);
      _m.toArray(mat, k * 16);
      k++;
    }
    const mesh = this.mesh;
    mesh.count = k; mesh.visible = k > 0;
    if (k > 0) uploadRange(mesh.instanceMatrix, k * 16);
  }
}

// ───────────────────────────── 스프라이트 풀 (글로우/반짝별)
const SP_FLASH = 0, SP_TWINKLE = 1, SP_FADE = 2, SP_POP = 3;
class SpritePool {
  constructor(parent, tex, cap, additive, name) {
    this.tex = tex;
    this.parent = parent;
    this.slots = [];
    this.next = 0;
    this.live = 0;
    for (let i = 0; i < cap; i++) {
      const mat = new THREE.SpriteMaterial({
        map: tex, transparent: true, depthWrite: false, fog: false,
        blending: additive ? THREE.AdditiveBlending : THREE.NormalBlending,
      });
      const sp = new THREE.Sprite(mat);
      sp.name = 'fx.' + name;
      sp.visible = false;
      sp.frustumCulled = false;
      parent.add(sp);
      this.slots.push({ sp, mat, on: false, t: 0, dur: 1, delay: 0, size: 1, curve: 0, rot: 0, rotV: 0, vx: 0, vy: 0, vz: 0, op: 1, drag: 0 });
    }
  }
  spawn(x, y, z, size, dur, color, curveId, opts) {
    // 비어 있는 슬롯 우선, 없으면 라운드로빈 (가장 오래된 것)
    let s = null;
    const n = this.slots.length;
    for (let j = 0; j < n; j++) { const c = this.slots[(this.next + j) % n]; if (!c.on) { s = c; this.next = (this.next + j + 1) % n; break; } }
    if (!s) { s = this.slots[this.next]; this.next = (this.next + 1) % n; this.live--; }
    s.on = true; this.live++;
    // opts.parent: 카메라 등 다른 부모의 로컬 좌표로 붙임 (twinkle 화면 고정용). 끝나면 root 로 복귀
    const par = (opts && opts.parent) || this.parent;
    if (s.sp.parent !== par) par.add(s.sp);
    s.t = 0; s.dur = Math.max(0.02, dur); s.size = size; s.curve = curveId;
    s.delay = opts?.delay || 0; s.rot = opts?.rot ?? rnd() * 6.283; s.rotV = opts?.rotV || 0;
    s.vx = opts?.vx || 0; s.vy = opts?.vy || 0; s.vz = opts?.vz || 0; s.drag = opts?.drag || 0;
    s.op = opts?.opacity ?? 1;
    s.sp.position.set(x, y, z);
    s.sp.renderOrder = opts?.renderOrder || 3;
    s.mat.depthTest = opts?.depthTest ?? true;
    s.mat.map = opts?.map || this.tex;
    s.mat.color.setHex(color);
    s.mat.rotation = s.rot;
    s.mat.opacity = 0;
    s.sp.scale.set(0.0001, 0.0001, 1);
    s.sp.visible = false;
    return s;
  }
  _off(s) { s.on = false; s.sp.visible = false; if (s.sp.parent !== this.parent) this.parent.add(s.sp); }
  clear() { for (const s of this.slots) this._off(s); this.live = 0; }
  update() {
    if (this.live === 0) return;
    const dt = FRAME[1], cx = CAM[0], cy = CAM[1], cz = CAM[2];
    for (let i = 0; i < this.slots.length; i++) {
      const s = this.slots[i];
      if (!s.on) continue;
      if (s.delay > 0) { s.delay -= dt; continue; }
      s.t += dt;
      const t = s.t / s.dur;
      if (t >= 1) { this._off(s); this.live--; continue; }
      if (dt > 0) {
        const dr = 1 / (1 + s.drag * dt);
        s.vx *= dr; s.vy *= dr; s.vz *= dr;
        s.sp.position.x += s.vx * dt; s.sp.position.y += s.vy * dt; s.sp.position.z += s.vz * dt;
        s.rot += s.rotV * dt;
      }
      let sc = 1, op = 1;
      switch (s.curve) {
        case SP_FLASH: sc = t < 0.1 ? 0.55 + 0.65 * (t / 0.1) : 1.2 * Math.pow(1 - (t - 0.1) / 0.9, 1.6); op = t < 0.45 ? 1 : 1 - (t - 0.45) / 0.55; break;
        case SP_TWINKLE:
          if (t < 0.11) sc = 1.28 * easeOutBack(t / 0.11) / 1.0;
          else if (t < 0.24) sc = 1.28 - 0.28 * ((t - 0.11) / 0.13);
          else if (t < 0.6) sc = 1 + 0.09 * Math.sin((t - 0.24) * 38);
          else sc = Math.pow(1 - (t - 0.6) / 0.4, 1.35);
          op = 1; break;
        case SP_FADE: sc = 0.75 + 0.6 * t; op = Math.pow(1 - t, 1.3); break;
        case SP_POP: sc = t < 0.18 ? easeOutBack(t / 0.18) : 1 - Math.pow((t - 0.18) / 0.82, 2); op = 1; break;
      }
      const z = Math.max(0.0001, s.size * sc);
      s.sp.scale.set(z, z, 1);
      // 카메라가 스프라이트 크기만큼 가까우면 서서히 투명 (화면 전체가 하얘지는 것 방지)
      const p = s.sp.position, local = s.sp.parent !== this.parent; // 카메라 자식이면 position 자체가 카메라 기준
      const ex = local ? p.x : p.x - cx, ey = local ? p.y : p.y - cy, ez = local ? p.z : p.z - cz, dist = Math.sqrt(ex * ex + ey * ey + ez * ez);
      const near = clamp((dist - 0.45 * s.size) / (0.6 * s.size), 0, 1);
      s.mat.opacity = clamp(op * s.op * near, 0, 1);
      s.mat.rotation = s.rot;
      s.sp.visible = true;
    }
  }
}

// ───────────────────────────── 캔버스 텍스처
function canvasTex(size, draw) {
  let cv;
  try { cv = document.createElement('canvas'); } catch { return null; }
  cv.width = cv.height = size;
  const g = cv.getContext('2d');
  if (g) draw(g, size);
  const tex = new THREE.CanvasTexture(cv);
  tex.colorSpace = THREE.SRGBColorSpace;
  tex.anisotropy = 2;
  return tex;
}
function glowTex() {
  return canvasTex(128, (g, n) => {
    const r = n / 2, gr = g.createRadialGradient(r, r, 0, r, r, r);
    gr.addColorStop(0, 'rgba(255,255,255,1)');
    gr.addColorStop(0.18, 'rgba(255,255,255,0.85)');
    gr.addColorStop(0.45, 'rgba(255,255,255,0.32)');
    gr.addColorStop(0.75, 'rgba(255,255,255,0.08)');
    gr.addColorStop(1, 'rgba(255,255,255,0)');
    g.fillStyle = gr; g.fillRect(0, 0, n, n);
  });
}
// 4갈래 반짝별 (오목한 변). R = 끝 반지름, k = 오목 정도
function starPath(g, cx, cy, R, k, rot = 0) {
  g.beginPath();
  for (let i = 0; i < 4; i++) {
    const a = rot + (i * Math.PI) / 2 - Math.PI / 2, b = a + Math.PI / 4, c2 = a + Math.PI / 2;
    const tx = cx + Math.cos(a) * R, ty = cy + Math.sin(a) * R;
    if (i === 0) g.moveTo(tx, ty);
    g.quadraticCurveTo(cx + Math.cos(b) * R * k, cy + Math.sin(b) * R * k, cx + Math.cos(c2) * R, cy + Math.sin(c2) * R);
  }
  g.closePath();
}
function twinkleTex() {
  return canvasTex(256, (g, n) => {
    const c = n / 2;
    // 부드러운 노란 후광
    const gl = g.createRadialGradient(c, c, 0, c, c, c);
    gl.addColorStop(0, 'rgba(255,248,190,0.95)'); gl.addColorStop(0.22, 'rgba(255,226,90,0.5)');
    gl.addColorStop(0.5, 'rgba(255,190,40,0.16)'); gl.addColorStop(1, 'rgba(255,170,0,0)');
    g.fillStyle = gl; g.fillRect(0, 0, n, n);
    g.lineJoin = 'round';
    // 메인 4갈래 별
    starPath(g, c, c, c * 0.95, 0.22);
    const fg = g.createRadialGradient(c, c, 0, c, c, c * 0.9);
    fg.addColorStop(0, '#ffffff'); fg.addColorStop(0.28, '#fffbd8'); fg.addColorStop(0.6, '#ffe24a'); fg.addColorStop(1, '#ffc21a');
    g.fillStyle = fg; g.fill();
    g.lineWidth = 6; g.strokeStyle = '#ff9a10'; g.stroke();
    // 중심 하이라이트
    const hc = g.createRadialGradient(c, c, 0, c, c, c * 0.24);
    hc.addColorStop(0, 'rgba(255,255,255,1)'); hc.addColorStop(1, 'rgba(255,255,255,0)');
    g.fillStyle = hc; g.beginPath(); g.arc(c, c, c * 0.24, 0, Math.PI * 2); g.fill();
  });
}
function sparkleTex() {
  return canvasTex(128, (g, n) => {
    const c = n / 2;
    const gl = g.createRadialGradient(c, c, 0, c, c, c);
    gl.addColorStop(0, 'rgba(255,255,255,0.9)'); gl.addColorStop(0.3, 'rgba(255,255,255,0.25)'); gl.addColorStop(1, 'rgba(255,255,255,0)');
    g.fillStyle = gl; g.fillRect(0, 0, n, n);
    starPath(g, c, c, c * 0.95, 0.14);
    g.fillStyle = '#ffffff'; g.fill();
  });
}
function heartTex() {
  return canvasTex(128, (g, n) => {
    const path = (x, y, w, h) => {
      g.beginPath();
      g.moveTo(x + w / 2, y + h * 0.27);
      g.bezierCurveTo(x + w * 0.5, y - h * 0.02, x, y - h * 0.02, x, y + h * 0.3);
      g.bezierCurveTo(x, y + h * 0.58, x + w * 0.38, y + h * 0.76, x + w / 2, y + h);
      g.bezierCurveTo(x + w * 0.62, y + h * 0.76, x + w, y + h * 0.58, x + w, y + h * 0.3);
      g.bezierCurveTo(x + w, y - h * 0.02, x + w * 0.5, y - h * 0.02, x + w / 2, y + h * 0.27);
      g.closePath();
    };
    g.lineJoin = 'round';
    path(16, 20, 96, 88);
    g.lineWidth = 18; g.strokeStyle = '#8a1030'; g.stroke();
    g.lineWidth = 11; g.strokeStyle = '#ffffff'; g.stroke();
    const fg = g.createLinearGradient(0, 20, 0, 108);
    fg.addColorStop(0, '#ff6b8a'); fg.addColorStop(1, '#ff1f4b');
    g.fillStyle = fg; g.fill();
    g.fillStyle = 'rgba(255,255,255,0.85)';
    g.beginPath(); g.ellipse(40, 42, 11, 7, -0.6, 0, Math.PI * 2); g.fill();
  });
}
function starTex() {
  return canvasTex(128, (g, n) => {
    const c = n / 2;
    g.beginPath();
    for (let i = 0; i < 10; i++) {
      const a = -Math.PI / 2 + (i * Math.PI) / 5, r = i % 2 ? 22 : 50;
      const x = c + Math.cos(a) * r, y = c + 4 + Math.sin(a) * r;
      if (i) g.lineTo(x, y); else g.moveTo(x, y);
    }
    g.closePath();
    g.lineJoin = 'round';
    g.lineWidth = 18; g.strokeStyle = '#8a4a00'; g.stroke();
    g.lineWidth = 11; g.strokeStyle = '#ffffff'; g.stroke();
    const fg = g.createLinearGradient(0, 14, 0, 110);
    fg.addColorStop(0, '#fff07a'); fg.addColorStop(1, '#ffb400');
    g.fillStyle = fg; g.fill();
  });
}

// 가짜 면 음영이 들어간 박스 (무광 재질에서도 큐브 느낌). 면 순서: +x, -x, +y, -y, +z, -z
function shadedBox() {
  const geo = new THREE.BoxGeometry(1, 1, 1);
  const shade = [0.84, 0.8, 1.0, 0.62, 0.92, 0.72];
  const col = new Float32Array(24 * 3);
  for (let f = 0; f < 6; f++) for (let v = 0; v < 4; v++) col.set([shade[f], shade[f], shade[f]], (f * 4 + v) * 3);
  geo.setAttribute('color', new THREE.BufferAttribute(col, 3));
  return geo;
}
// 램버트 + 인스턴스 색 기반 자체발광 (밤에도 칙칙해지지 않게)
function litMaterial(selfLit) {
  const m = new THREE.MeshLambertMaterial({ color: 0xffffff });
  const u = { value: selfLit };
  m.onBeforeCompile = (sh) => {
    sh.uniforms.uSelfLit = u;
    sh.fragmentShader = 'uniform float uSelfLit;\n' + sh.fragmentShader.replace(
      '#include <emissivemap_fragment>',
      '#include <emissivemap_fragment>\n\ttotalEmissiveRadiance += diffuseColor.rgb * uSelfLit;',
    );
  };
  m.customProgramCacheKey = () => 'fx-selflit';
  return m;
}

const HIT_STAR_OPTS = { rotV: 6 };
const CONFETTI_COLORS = [0xff3b30, 0xffcc00, 0x34c759, 0x0a84ff, 0xff2d92, 0xaf52de, 0xff9500, 0x5ac8fa, 0xffffff, 0x7cff4f, 0xff6b6b];

// ───────────────────────────── FX
export class FX {
  constructor(scene, camera) {
    this.scene = scene;
    this.camera = camera;
    this.root = new THREE.Group();
    this.root.name = 'fx';
    scene.add(this.root);

    this._box = shadedBox();
    this._plane = new THREE.PlaneGeometry(1, 1);

    // 큐브 풀
    this.basic = new CubePool(this.root, this._box, new THREE.MeshBasicMaterial({ vertexColors: true }), 900, 'basic');
    this.glow = new CubePool(this.root, this._box, new THREE.MeshBasicMaterial({
      transparent: true, blending: THREE.AdditiveBlending, depthWrite: false, fog: false,
    }), 320, 'glow');
    this.glow.mesh.renderOrder = 4;
    this.lit = new CubePool(this.root, this._box, litMaterial(0.16), 500, 'lit');
    this.smoke = new CubePool(this.root, this._box, litMaterial(0.55), 1000, 'smoke');
    this.conf = new CubePool(this.root, this._box, litMaterial(0.5), 700, 'confetti');
    this._pools = [this.basic, this.glow, this.lit, this.smoke, this.conf];

    // 텍스처
    this._tex = { glow: glowTex(), twinkle: twinkleTex(), sparkle: sparkleTex(), heart: heartTex(), star: starTex() };

    // 하트/별 빌보드
    this.heartPool = new BillboardPool(this.root, this._plane, this._tex.heart, 60, 'hearts');
    this.starPool = new BillboardPool(this.root, this._plane, this._tex.star, 30, 'stars');

    // 스프라이트
    this.glowSprites = new SpritePool(this.root, this._tex.glow, 28, true, 'glowSprite');
    this.starSprites = new SpritePool(this.root, this._tex.sparkle, 28, false, 'starSprite');
    this._twinkleTex = this._tex.twinkle;

    // 충격파 링
    const ringGeo = new THREE.RingGeometry(0.8, 1, 64, 1);
    ringGeo.rotateX(-Math.PI / 2);
    this._rings = [];
    for (let i = 0; i < 10; i++) {
      const mat = new THREE.MeshBasicMaterial({
        color: 0xffffff, transparent: true, opacity: 0, depthWrite: false, side: THREE.DoubleSide,
        polygonOffset: true, polygonOffsetFactor: -2, polygonOffsetUnits: -2,
      });
      const mesh = new THREE.Mesh(ringGeo, mat);
      mesh.name = 'fx.ring'; mesh.visible = false; mesh.frustumCulled = false; mesh.renderOrder = 2;
      this.root.add(mesh);
      this._rings.push({ mesh, mat, on: false, t: 0, dur: 0.5, R: 8, delay: 0, op: 1 });
    }
    this._ringGeo = ringGeo;

    // 코어 섬광 (가산 icosa)
    const coreGeo = new THREE.IcosahedronGeometry(1, 1);
    this._cores = [];
    for (let i = 0; i < 6; i++) {
      const mat = new THREE.MeshBasicMaterial({ color: 0xffffff, transparent: true, blending: THREE.AdditiveBlending, depthWrite: false, fog: false });
      const mesh = new THREE.Mesh(coreGeo, mat);
      mesh.name = 'fx.core'; mesh.visible = false; mesh.frustumCulled = false; mesh.renderOrder = 5;
      this.root.add(mesh);
      this._cores.push({ mesh, mat, on: false, t: 0, dur: 0.3, peak: 3 });
    }
    this._coreGeo = coreGeo;
    this._coreA = new THREE.Color(0xffffff); this._coreB = new THREE.Color(0xff9a2a);

    // smokeTrail 이미터
    this._trails = [];
    for (let i = 0; i < 16; i++) this._trails.push({ obj: null, on: false, t: 0, dur: 1, acc: 0, has: false, lx: 0, ly: 0, lz: 0, age: 0 });

    // 셰이크
    this._trauma = 0; this._shakeLeft = 0; this._shakeT = 0;
    this._shakeOffset = new THREE.Vector3();
    this._lastNow = -1;

    // 스피드라인 (카메라 자식)
    this._initSpeedLines();

    this._palette = []; for (let i = 0; i < 8; i++) this._palette.push(new THREE.Color());
  }

  // ───────── 공용
  _now() { return (typeof performance !== 'undefined' && performance.now) ? performance.now() : Date.now(); }

  update(dt) {
    dt = clamp(num(dt, 0), 0, 0.05);
    const now = this._now();
    const realDt = this._lastNow < 0 ? 0 : clamp((now - this._lastNow) / 1000, 0, 0.05);
    this._lastNow = now;
    // 섬광·스프라이트·셰이크는 "연출 시간"(= max(게임 dt, 실제 경과)) 으로 진행:
    // 히트스톱/슬로모션 중에도 섬광은 팍 터지고 금방 사라져 킬캠을 가리지 않는다. 큐브 파티클은 게임 dt (슬로모 불덩이).
    FRAME[0] = dt;
    FRAME[1] = dt > realDt ? dt : realDt;

    if (dt > 0) this._updateTrails();
    const cam = this.camera;
    if (cam && cam.isObject3D) { cam.getWorldPosition(_w); cam.getWorldQuaternion(_cq); } else { _w.set(0, 1e5, 0); _cq.identity(); }
    const camMoved = _w.x !== CAM[0] || _w.y !== CAM[1] || _w.z !== CAM[2];
    CAM[0] = _w.x; CAM[1] = _w.y; CAM[2] = _w.z;
    for (let i = 0; i < this._pools.length; i++) this._pools[i].update(camMoved);
    this.heartPool.update(_cq);
    this.starPool.update(_cq);
    this.glowSprites.update();
    this.starSprites.update();
    this._updateRings();
    this._updateCores();
    this._updateSpeedLines();
    this._updateShake();
  }

  clear() {
    for (const p of this._pools) p.clear();
    this.heartPool.clear(); this.starPool.clear();
    this.glowSprites.clear(); this.starSprites.clear();
    for (const r of this._rings) { r.on = false; r.mesh.visible = false; }
    for (const c of this._cores) { c.on = false; c.mesh.visible = false; }
    for (const t of this._trails) { t.on = false; t.obj = null; }
    this._trauma = 0; this._shakeLeft = 0; this._shakeOffset.set(0, 0, 0);
    this._slTarget = 0; this._slCur = 0;
    if (this._sl) { this._sl.group.visible = false; this._sl.mesh.count = 0; }
  }

  // ───────── 불꽃: 노랑/주황 큐브, 속도 방향으로 늘어남, 노면 바운스
  sparks(pos, opts = {}) {
    if (!readPos(pos, _P)) return;
    const o = (opts && typeof opts === 'object') ? opts : {};
    const count = clamp(Math.round(num(o.count, 14)), 0, 120);
    const speed = clamp(num(o.speed, 8), 0, 80);
    let hasDir = false;
    if (o.dir && readPos(o.dir, _D) && _D.lengthSq() > 1e-8) { _D.normalize(); hasDir = true; }
    const pool = this.basic, d = pool.d;
    for (let i = 0; i < count; i++) {
      randDir(_v);
      if (hasDir) _v.multiplyScalar(0.5).addScaledVector(_D, 1);
      else _v.y = Math.abs(_v.y) * 0.9 + 0.25;
      _v.normalize().multiplyScalar(speed * rr(0.55, 1.25));
      const k = pool.add();
      d[k + PX] = _P.x + rr(-0.12, 0.12); d[k + PY] = _P.y + rr(-0.08, 0.12); d[k + PZ] = _P.z + rr(-0.12, 0.12);
      d[k + VX] = _v.x; d[k + VY] = _v.y; d[k + VZ] = _v.z;
      const th = rr(0.17, 0.3);
      d[k + SX] = th; d[k + SY] = th; d[k + SZ] = th; d[k + STR] = 0.065;
      d[k + FLAGS] = F_STRETCH; d[k + GRAV] = 19; d[k + DRAG] = 0.6; d[k + BOUNCE] = 0.42;
      d[k + MAX] = rr(0.4, 0.8); d[k + CURVE] = C_SHRINK; d[k + RAMP] = R_SPARK;
    }
    // 큰 버스트(펑크 등)는 순간 섬광으로 "팍!"
    if (count >= 10) {
      this.glowSprites.spawn(_P.x, _P.y, _P.z, 1.4 + count * 0.09, 0.15, 0xffd070, SP_FLASH);
      this.starSprites.spawn(_P.x, _P.y + 0.1, _P.z, 1.0 + count * 0.07, 0.16, 0xfff4c0, SP_FLASH, HIT_STAR_OPTS);
    }
  }

  // ───────── 폭발: 코어 섬광 + 불덩이 + 가산 열기 + 연기 + 파편 + 불꽃 + 노면 충격파
  explosion(pos, scale = 1) {
    if (!readPos(pos, _P)) return;
    const s = clamp(num(scale, 1), 0.1, 5);
    const cm = clamp(0.7 + 0.3 * s, 0.6, 1.6);
    const x = _P.x, y = _P.y, z = _P.z;

    // 1) 코어 섬광: 팍! 커졌다가 줄어듦
    this._core(x, y, z, 3.0 * s, 0.24);
    this.glowSprites.spawn(x, y + 0.2, z, 9 * s, 0.22, 0xffffff, SP_FLASH);                                   // 백열 (가산)
    this.starSprites.spawn(x, y, z, 17 * s, 0.5, 0xffb347, SP_FLASH, { map: this._tex.glow, opacity: 0.62 });   // 따뜻한 후광 (일반 블렌딩 → 잔디 위에서도 주황)
    this.starSprites.spawn(x, y + 0.3, z, 10 * s, 0.22, 0xffffff, SP_FLASH, { rotV: 4 });

    const d1 = this.basic.d, dg = this.glow.d, dl = this.lit.d, dm = this.smoke.d;
    // 2) 불덩이 큐브 (무광, 흰→노랑→주황→빨강→검댕)
    const nFire = Math.round(42 * cm);
    for (let i = 0; i < nFire; i++) {
      const big = i % 10 < 3; // 30%: 가운데 큰 불덩이, 70%: 사방으로 튀는 불조각
      randDir(_v); _v.y = _v.y * 0.75 + 0.32; _v.normalize();
      const r0 = rnd() * (big ? 1.1 : 0.7) * s, sp = (big ? rr(1.5, 5) : rr(6, 14)) * s;
      const k = this.basic.add();
      d1[k + PX] = x + _v.x * r0; d1[k + PY] = y + _v.y * r0; d1[k + PZ] = z + _v.z * r0;
      d1[k + VX] = _v.x * sp; d1[k + VY] = _v.y * sp + 1.4; d1[k + VZ] = _v.z * sp;
      const sz = (big ? rr(1.3, 2.0) : rr(0.5, 1.15)) * s;
      d1[k + SX] = sz; d1[k + SY] = sz; d1[k + SZ] = sz;
      d1[k + EX] = rnd() * 6; d1[k + EY] = rnd() * 6; d1[k + EZ] = rnd() * 6;
      d1[k + WX] = rr(-5, 5); d1[k + WY] = rr(-5, 5); d1[k + WZ] = rr(-5, 5);
      d1[k + DRAG] = big ? 2.4 : 3.2; d1[k + GRAV] = big ? -4 : -2.5; d1[k + ENDMUL] = big ? 1.15 : 1.3;
      d1[k + MAX] = big ? rr(0.75, 1.25) : rr(0.45, 0.95); d1[k + DELAY] = rnd() < 0.3 ? rnd() * 0.07 : 0;
      d1[k + CURVE] = C_POP; d1[k + RAMP] = R_FIRE;
    }
    // 3) 가산 열기 (뜨거운 부분만 번쩍)
    const nGlow = Math.round(20 * cm);
    for (let i = 0; i < nGlow; i++) {
      randDir(_v); _v.y = Math.abs(_v.y) * 0.6 + 0.2; _v.normalize();
      const sp = rr(1.5, 6) * s;
      const k = this.glow.add();
      dg[k + PX] = x + _v.x * 0.5 * s; dg[k + PY] = y + _v.y * 0.5 * s; dg[k + PZ] = z + _v.z * 0.5 * s;
      dg[k + VX] = _v.x * sp; dg[k + VY] = _v.y * sp + 1; dg[k + VZ] = _v.z * sp;
      const sz = rr(1.6, 3.0) * s;
      dg[k + SX] = sz; dg[k + SY] = sz; dg[k + SZ] = sz;
      dg[k + EX] = rnd() * 6; dg[k + EY] = rnd() * 6; dg[k + EZ] = rnd() * 6;
      dg[k + WX] = rr(-3, 3); dg[k + WY] = rr(-3, 3);
      dg[k + DRAG] = 3; dg[k + GRAV] = -2; dg[k + MAX] = rr(0.25, 0.5);
      dg[k + CURVE] = C_POP; dg[k + RAMP] = R_GLOW;
    }
    // 4) 연기 (조금 늦게 피어올라 크게 부풂)
    const nSmoke = Math.round(26 * cm);
    for (let i = 0; i < nSmoke; i++) {
      randDir(_v); _v.y = Math.abs(_v.y) * 0.5 + 0.2; _v.normalize();
      const r0 = rnd() * 1.5 * s, sp = rr(1.2, 3.6) * s;
      const k = this.smoke.add();
      dm[k + PX] = x + _v.x * r0; dm[k + PY] = y + _v.y * r0 + 0.3; dm[k + PZ] = z + _v.z * r0;
      dm[k + VX] = _v.x * sp; dm[k + VY] = _v.y * sp + rr(2.4, 4.6); dm[k + VZ] = _v.z * sp;
      const sz = rr(0.75, 1.4) * s;
      dm[k + SX] = sz; dm[k + SY] = sz; dm[k + SZ] = sz;
      dm[k + EX] = rnd() * 6; dm[k + EY] = rnd() * 6; dm[k + EZ] = rnd() * 6;
      dm[k + WX] = rr(-1.5, 1.5); dm[k + WY] = rr(-1.5, 1.5); dm[k + WZ] = rr(-1.5, 1.5);
      dm[k + DRAG] = 1.3; dm[k + GRAV] = -2.4; dm[k + ENDMUL] = 1.65;
      dm[k + MAX] = rr(1.4, 2.5); dm[k + DELAY] = rr(0.08, 0.34);
      dm[k + CURVE] = C_GROW; dm[k + RAMP] = R_SMOKE;
      const tint = rr(0.8, 1.15); dm[k + CR] = tint; dm[k + CG] = tint; dm[k + CB] = tint;
    }
    // 5) 파편 (숯/잿빛/불씨, 중력 + 노면 바운스)
    const nDeb = Math.round(17 * cm), ss = Math.sqrt(s);
    for (let i = 0; i < nDeb; i++) {
      _v.set(rr(-1, 1), rr(0.55, 1.4), rr(-1, 1)).normalize();
      const sp = rr(8, 17) * ss;
      const k = this.lit.add();
      dl[k + PX] = x; dl[k + PY] = y; dl[k + PZ] = z;
      dl[k + VX] = _v.x * sp; dl[k + VY] = _v.y * sp; dl[k + VZ] = _v.z * sp;
      const sz = rr(0.36, 0.8) * s;
      dl[k + SX] = sz * rr(0.7, 1.3); dl[k + SY] = sz * rr(0.6, 1.1); dl[k + SZ] = sz * rr(0.7, 1.3);
      dl[k + WX] = rr(-14, 14); dl[k + WY] = rr(-10, 10); dl[k + WZ] = rr(-14, 14);
      dl[k + GRAV] = 28; dl[k + DRAG] = 0.25; dl[k + BOUNCE] = 0.42;
      dl[k + MAX] = rr(1.8, 2.8); dl[k + CURVE] = C_HOLD;
      const pick = rnd();
      if (pick < 0.25) { dl[k + RAMP] = R_EMBER; }
      else { _c.setHex(pick < 0.6 ? 0x2c2a2a : pick < 0.85 ? 0x4a4646 : 0x777270); dl[k + CR] = _c.r; dl[k + CG] = _c.g; dl[k + CB] = _c.b; }
    }
    // 6) 불꽃 줄기
    this.sparks(_P, { count: Math.round(22 * cm), speed: 17 * ss });
    // 7) 노면 충격파 (공중 폭발이면 생략)
    if (y < 5) { _w.set(x, 0.07, z); this.shockwave(_w, 9 * s, 0xfff0c0); }
  }

  // ───────── 연기 한 뭉치 (회색 큐브 상승)
  smokePuff(pos, opts = {}) {
    if (!readPos(pos, _P)) return;
    const o = (opts && typeof opts === 'object') ? opts : {};
    const count = clamp(Math.round(num(o.count, 6)), 0, 80);
    const size = clamp(num(o.size, 1), 0.05, 8);
    setColor(_c, o.color, 0xd0d0d0);
    const cr = _c.r, cg = _c.g, cb = _c.b;
    const pool = this.smoke, d = pool.d;
    for (let i = 0; i < count; i++) {
      const k = pool.add();
      d[k + PX] = _P.x + rr(-0.45, 0.45) * size; d[k + PY] = _P.y + rr(-0.2, 0.3) * size; d[k + PZ] = _P.z + rr(-0.45, 0.45) * size;
      d[k + VX] = rr(-1.3, 1.3) * size; d[k + VY] = rr(1.1, 2.6) * Math.sqrt(size); d[k + VZ] = rr(-1.3, 1.3) * size;
      const sz = rr(0.42, 0.82) * size;
      d[k + SX] = sz; d[k + SY] = sz; d[k + SZ] = sz;
      d[k + EX] = rnd() * 6; d[k + EY] = rnd() * 6; d[k + EZ] = rnd() * 6;
      d[k + WX] = rr(-2, 2); d[k + WY] = rr(-2, 2); d[k + WZ] = rr(-2, 2);
      d[k + DRAG] = 1.6; d[k + GRAV] = -0.9; d[k + ENDMUL] = 1.8;
      d[k + MAX] = rr(0.8, 1.4) * (0.75 + 0.25 * Math.sqrt(size)); d[k + DELAY] = rnd() * 0.06;
      d[k + CURVE] = C_GROW;
      const tint = rr(0.88, 1.08);
      d[k + CR] = cr * tint; d[k + CG] = cg * tint; d[k + CB] = cb * tint;
    }
  }

  // ───────── 오브젝트를 따라가며 연기 + 로켓 불꽃 방출
  smokeTrail(object3d, duration = 2) {
    if (!object3d || !object3d.isObject3D) return;
    const dur = clamp(num(duration, 2), 0.05, 12);
    let slot = null;
    for (const t of this._trails) if (t.on && t.obj === object3d) { t.t = Math.max(t.t, dur); t.dur = Math.max(t.dur, dur); return; }
    for (const t of this._trails) if (!t.on) { slot = t; break; }
    if (!slot) { slot = this._trails[0]; for (const t of this._trails) if (t.t < slot.t) slot = t; }
    slot.obj = object3d; slot.on = true; slot.t = dur; slot.dur = dur; slot.acc = 0; slot.has = false; slot.age = 0;
  }

  _updateTrails() {
    const dt = FRAME[0], dl = this.smoke.d, db = this.basic.d;
    for (let i = 0; i < this._trails.length; i++) {
      const tr = this._trails[i];
      if (!tr.on) continue;
      const obj = tr.obj;
      if (!obj || !obj.visible || !obj.parent) { tr.on = false; tr.obj = null; continue; }
      tr.t -= dt; tr.age += dt;
      if (tr.t <= 0) { tr.on = false; tr.obj = null; continue; }
      obj.getWorldPosition(_w);
      if (!tr.has) { tr.lx = _w.x; tr.ly = _w.y; tr.lz = _w.z; tr.has = true; }
      const dx = _w.x - tr.lx, dy = _w.y - tr.ly, dz = _w.z - tr.lz;
      const dist = Math.sqrt(dx * dx + dy * dy + dz * dz);
      tr.acc += dt * 34 + dist / 0.5;
      let n = Math.floor(tr.acc);
      tr.acc -= n;
      if (n > 12) n = 12;
      const fade = Math.min(1, tr.t / 0.35) * Math.min(1, 0.45 + tr.age * 4);
      for (let j = 0; j < n; j++) {
        const u = (j + 1) / n;
        const px = tr.lx + dx * u, py = tr.ly + dy * u, pz = tr.lz + dz * u;
        // 연기 (밝은 회색 뭉게)
        const k = this.smoke.add();
        dl[k + PX] = px + rr(-0.2, 0.2); dl[k + PY] = py + rr(-0.2, 0.2); dl[k + PZ] = pz + rr(-0.2, 0.2);
        dl[k + VX] = rr(-0.8, 0.8); dl[k + VY] = rr(0.2, 1.2); dl[k + VZ] = rr(-0.8, 0.8);
        const sz = rr(0.45, 0.85) * fade;
        dl[k + SX] = sz; dl[k + SY] = sz; dl[k + SZ] = sz;
        dl[k + EX] = rnd() * 6; dl[k + EY] = rnd() * 6; dl[k + EZ] = rnd() * 6;
        dl[k + WX] = rr(-2, 2); dl[k + WY] = rr(-2, 2);
        dl[k + DRAG] = 2.2; dl[k + GRAV] = -1.1; dl[k + ENDMUL] = 1.8;
        dl[k + MAX] = rr(0.7, 1.25); dl[k + CURVE] = C_GROW;
        const g = rr(0.8, 0.97); _c.setRGB(g, g, g * 0.98);
        dl[k + CR] = _c.r; dl[k + CG] = _c.g; dl[k + CB] = _c.b;
        // 로켓 불꽃 (방출점 근처만)
        if (u > 0.34 || rnd() < 0.5) {
          const f = this.basic.add();
          db[f + PX] = px + rr(-0.12, 0.12); db[f + PY] = py + rr(-0.12, 0.12); db[f + PZ] = pz + rr(-0.12, 0.12);
          db[f + VX] = rr(-1.2, 1.2); db[f + VY] = rr(-1.2, 1.2); db[f + VZ] = rr(-1.2, 1.2);
          const fs = rr(0.5, 0.9) * fade;
          db[f + SX] = fs; db[f + SY] = fs; db[f + SZ] = fs;
          db[f + EX] = rnd() * 6; db[f + EY] = rnd() * 6;
          db[f + DRAG] = 2; db[f + MAX] = rr(0.2, 0.36); db[f + CURVE] = C_SHRINK; db[f + RAMP] = R_TRAILFIRE;
        }
      }
      tr.lx = _w.x; tr.ly = _w.y; tr.lz = _w.z;
    }
  }

  // ───────── 색 조각 파편: 중력 + 노면 바운스
  debris(pos, colors = [], count = 12) {
    if (!readPos(pos, _P)) return;
    let nc = 0;
    if (Array.isArray(colors)) for (let i = 0; i < colors.length && nc < 8; i++) { if (colors[i] != null) setColor(this._palette[nc++], colors[i], 0x888888); }
    else if (colors != null && typeof colors !== 'object') setColor(this._palette[nc++], colors, 0x888888);
    else if (colors && colors.isColor) setColor(this._palette[nc++], colors, 0x888888);
    if (nc === 0) { this._palette[0].setHex(0x5a5a5a); this._palette[1].setHex(0x8c8c8c); this._palette[2].setHex(0x333333); nc = 3; }
    const n = clamp(Math.round(num(count, 12)), 0, 120);
    const pool = this.lit, d = pool.d;
    for (let i = 0; i < n; i++) {
      _v.set(rr(-1, 1), rr(0.5, 1.5), rr(-1, 1)).normalize();
      const sp = rr(6, 13.5);
      const k = pool.add();
      d[k + PX] = _P.x + rr(-0.3, 0.3); d[k + PY] = _P.y + rr(-0.2, 0.3); d[k + PZ] = _P.z + rr(-0.3, 0.3);
      d[k + VX] = _v.x * sp; d[k + VY] = _v.y * sp; d[k + VZ] = _v.z * sp;
      const sz = rr(0.26, 0.62);
      d[k + SX] = sz * rr(0.7, 1.4); d[k + SY] = sz * rr(0.5, 1.1); d[k + SZ] = sz * rr(0.7, 1.4);
      d[k + EX] = rnd() * 6; d[k + EY] = rnd() * 6; d[k + EZ] = rnd() * 6;
      d[k + WX] = rr(-13, 13); d[k + WY] = rr(-9, 9); d[k + WZ] = rr(-13, 13);
      d[k + GRAV] = 26; d[k + DRAG] = 0.25; d[k + BOUNCE] = 0.45;
      d[k + MAX] = rr(1.6, 2.5); d[k + CURVE] = C_HOLD;
      const c = this._palette[Math.floor(rnd() * nc)], tint = rr(0.9, 1.08);
      d[k + CR] = c.r * tint; d[k + CG] = c.g * tint; d[k + CB] = c.b * tint;
    }
  }

  // ───────── 컨페티: 하늘에서 쏟아지는 비 + 바닥에서 펑펑 쏘아 올리는 폭죽
  confetti(center, count = 120, spread = 30) {
    if (!readPos(center, _P)) return;
    const n = clamp(Math.round(num(count, 120)), 0, 700);
    const R = clamp(num(spread, 30), 1, 200);
    const pool = this.conf, d = pool.d;
    const pm = clamp(Math.sqrt(R / 30), 0.8, 1.7); // 넓게 뿌릴수록 조각도 크게 (드론샷 가독성)
    // 폭죽 발사 지점 4~6곳
    const nPop = 4 + Math.floor(rnd() * 3);
    const popX = this._popX || (this._popX = new Float32Array(8)), popZ = this._popZ || (this._popZ = new Float32Array(8));
    for (let j = 0; j < nPop; j++) {
      const a = (j / nPop) * Math.PI * 2 + rnd() * 0.8, r = R * rr(0.2, 0.62);
      popX[j] = _P.x + Math.cos(a) * r; popZ[j] = _P.z + Math.sin(a) * r;
    }
    for (let i = 0; i < n; i++) {
      const k = pool.add();
      const burst = i % 5 < 2; // 40% 폭죽, 60% 비
      if (burst) {
        const j = i % nPop;
        d[k + PX] = popX[j] + rr(-0.6, 0.6); d[k + PY] = _P.y + rr(0.6, 2); d[k + PZ] = popZ[j] + rr(-0.6, 0.6);
        randDir(_v); _v.y = Math.abs(_v.y) * 0.4 + 0.9; _v.normalize();
        const sp = rr(14, 26);
        d[k + VX] = _v.x * sp; d[k + VY] = _v.y * sp; d[k + VZ] = _v.z * sp;
        d[k + DELAY] = rnd() * 0.25 + (j % 3) * 0.12;
        d[k + MAX] = rr(3.6, 4.8);
      } else {
        const a = rnd() * Math.PI * 2, r = R * Math.sqrt(rnd());
        d[k + PX] = _P.x + Math.cos(a) * r * 0.72; d[k + PY] = _P.y + rr(9, 24); d[k + PZ] = _P.z + Math.sin(a) * r;
        d[k + VX] = rr(-2, 2); d[k + VY] = rr(-1, 2.5); d[k + VZ] = rr(-2, 2);
        d[k + DELAY] = rnd() * 0.7;
        d[k + MAX] = rr(3.4, 4.8);
      }
      const sz = rr(1.1, 1.6) * pm;
      if (i % 7 === 3) { d[k + SX] = 0.17 * sz; d[k + SY] = 0.05 * sz; d[k + SZ] = 1.5 * sz; } // 리본
      else { d[k + SX] = 0.78 * sz; d[k + SY] = 0.07 * sz; d[k + SZ] = 0.5 * sz; }
      d[k + EX] = rnd() * 6; d[k + EY] = rnd() * 6; d[k + EZ] = rnd() * 6;
      d[k + WX] = rr(-11, 11); d[k + WY] = rr(-5, 5); d[k + WZ] = rr(-11, 11);
      d[k + GRAV] = 9.5; d[k + DRAG] = 1.7; d[k + BOUNCE] = 0;
      d[k + FLAGS] = F_FLUTTER | F_SETTLE;
      d[k + PHASE] = rnd() * 6.283; d[k + FREQ] = rr(2.2, 4.6); d[k + AMP] = rr(1.6, 3.4);
      d[k + CURVE] = C_HOLD;
      _c.setHex(CONFETTI_COLORS[Math.floor(rnd() * CONFETTI_COLORS.length)]);
      d[k + CR] = _c.r; d[k + CG] = _c.g; d[k + CB] = _c.b;
    }
  }

  // ───────── 노면 링 확산 + 흙먼지
  shockwave(pos, radius = 8, color = 0xffffff) {
    if (!readPos(pos, _P)) return;
    const R = clamp(num(radius, 8), 0.3, 80);
    const y = _P.y < 1 ? Math.max(0.07, _P.y) : _P.y;
    setColor(_c, color, 0xffffff);
    this._ring(_P.x, y, _P.z, R, 0.42 + R * 0.012, _c, 0.95, 0);
    this._ring(_P.x, y + 0.01, _P.z, R * 0.62, 0.36 + R * 0.01, null, 0.7, 0.06);
    // 흙먼지 큐브: 링을 따라 바깥으로
    const n = Math.round(clamp(10 + R * 1.2, 8, 40));
    const d = this.smoke.d, sz0 = clamp(Math.sqrt(R / 8), 0.4, 2);
    for (let i = 0; i < n; i++) {
      const a = (i / n) * Math.PI * 2 + rr(-0.15, 0.15), sp = R * rr(1.7, 2.6);
      const k = this.smoke.add();
      d[k + PX] = _P.x + Math.cos(a) * 0.6; d[k + PY] = y + 0.25; d[k + PZ] = _P.z + Math.sin(a) * 0.6;
      d[k + VX] = Math.cos(a) * sp; d[k + VY] = rr(0.8, 2.6); d[k + VZ] = Math.sin(a) * sp;
      const sz = rr(0.3, 0.6) * sz0;
      d[k + SX] = sz; d[k + SY] = sz; d[k + SZ] = sz;
      d[k + EX] = rnd() * 6; d[k + EY] = rnd() * 6; d[k + WX] = rr(-4, 4); d[k + WZ] = rr(-4, 4);
      d[k + DRAG] = 3.6; d[k + GRAV] = 3; d[k + BOUNCE] = 0.2; d[k + ENDMUL] = 1.35;
      d[k + MAX] = rr(0.55, 0.9); d[k + CURVE] = C_GROW;
      _c.setHex(0xcdc3ae); const tint = rr(0.85, 1.05);
      d[k + CR] = _c.r * tint; d[k + CG] = _c.g * tint; d[k + CB] = _c.b * tint;
    }
  }

  _ring(x, y, z, R, dur, color, op, delay) {
    let r = null;
    for (const c of this._rings) if (!c.on) { r = c; break; }
    if (!r) { r = this._rings[0]; for (const c of this._rings) if (c.t / c.dur > r.t / r.dur) r = c; }
    r.on = true; r.t = 0; r.dur = dur; r.R = R; r.op = op; r.delay = delay;
    r.mesh.position.set(x, y, z);
    r.mesh.scale.setScalar(0.001);
    r.mesh.visible = false;
    if (color) r.mat.color.copy(color); else r.mat.color.setHex(0xffffff);
    r.mat.opacity = 0;
  }
  _updateRings() {
    const dt = FRAME[0];
    for (let i = 0; i < this._rings.length; i++) {
      const r = this._rings[i];
      if (!r.on) continue;
      if (r.delay > 0) { r.delay -= dt; continue; }
      r.t += dt;
      const t = r.t / r.dur;
      if (t >= 1) { r.on = false; r.mesh.visible = false; continue; }
      const e = 1 - Math.pow(1 - t, 3);
      r.mesh.scale.setScalar(0.15 + r.R * e);
      r.mat.opacity = r.op * Math.pow(1 - t, 1.4);
      r.mesh.visible = true;
    }
  }

  _core(x, y, z, peak, dur) {
    let c = null;
    for (const s of this._cores) if (!s.on) { c = s; break; }
    if (!c) { c = this._cores[0]; for (const s of this._cores) if (s.t > c.t) c = s; }
    c.on = true; c.t = 0; c.dur = dur; c.peak = peak;
    c.mesh.position.set(x, y, z);
    c.mesh.rotation.set(rnd() * 6, rnd() * 6, rnd() * 6);
    c.mesh.scale.setScalar(peak * 0.4);
    c.mat.color.copy(this._coreA); c.mat.opacity = 1;
    c.mesh.visible = true;
  }
  _updateCores() {
    const dt = FRAME[1];
    for (let i = 0; i < this._cores.length; i++) {
      const c = this._cores[i];
      if (!c.on) continue;
      c.t += dt;
      const t = c.t / c.dur;
      if (t >= 1) { c.on = false; c.mesh.visible = false; continue; }
      const sc = t < 0.14 ? 0.4 + 0.6 * (1 - Math.pow(1 - t / 0.14, 2)) : Math.pow(1 - (t - 0.14) / 0.86, 1.8);
      c.mesh.scale.setScalar(Math.max(0.001, c.peak * sc));
      c.mat.color.copy(this._coreA).lerp(this._coreB, Math.min(1, t * 1.4));
      c.mat.opacity = t < 0.5 ? 1 : 1 - (t - 0.5) / 0.5;
      c.mesh.rotation.y += dt * 2;
    }
  }

  // ───────── 반짝★ (원흉이 하늘로 날아가 사라짐 — 로켓단 "또 당했다~")
  // 화면 안에서 터지면 별 일행을 카메라 공간에 고정(카메라 자식) → 직후 카메라가 홱 돌아가도(킬캠→드론샷) 1초간 확실히 보인다.
  twinkle(pos) {
    if (!readPos(pos, _P)) return;
    const cam = this.camera;
    let parent = null, x = _P.x, y = _P.y, z = _P.z, dist = 30;
    if (cam && cam.isCamera) {
      cam.updateMatrixWorld();
      _v.copy(_P); cam.worldToLocal(_v);
      dist = _v.length();
      _w.copy(_P).project(cam);
      if (_v.z < -2 && Math.abs(_w.x) < 1.15 && Math.abs(_w.y) < 1.15) { parent = cam; x = _v.x; y = _v.y; z = _v.z; }
    }
    const S = clamp(dist * 0.36, 8, 12); // 별 크기 (m): 가까우면 8, 멀면 12
    const base = parent ? { parent, depthTest: false } : { depthTest: false };
    // 노란 후광 (일반 블렌딩 — 밝은 하늘에서도 노랗게) + 순간 백열 (가산)
    this.starSprites.spawn(x, y, z, S * 1.6, 1.05, 0xffbe2e, SP_TWINKLE, { ...base, renderOrder: 38, map: this._tex.glow, opacity: 0.7, rot: 0 });
    this.glowSprites.spawn(x, y, z, S * 1.2, 0.32, 0xffffff, SP_FLASH, { ...base, renderOrder: 39 });
    // 대각선 보조 별 (흰색, 메인 뒤에서 반대로 회전)
    this.starSprites.spawn(x, y, z, S * 0.65, 0.95, 0xffffff, SP_TWINKLE, { ...base, renderOrder: 40, rot: Math.PI / 4, rotV: -3.6, delay: 0.04 });
    // 메인 별 (노랑 4갈래, 주황 외곽선)
    this.starSprites.spawn(x, y, z, S, 1.1, 0xffffff, SP_TWINKLE, { ...base, renderOrder: 42, map: this._twinkleTex, rot: 0, rotV: 2.6 });
    // 미니 반짝이들이 화면 평면으로 퍼짐
    if (parent) { _R.set(1, 0, 0); _U.set(0, 1, 0); }
    else if (cam && cam.isObject3D) { _R.setFromMatrixColumn(cam.matrixWorld, 0); _U.setFromMatrixColumn(cam.matrixWorld, 1); }
    else { _R.set(1, 0, 0); _U.set(0, 1, 0); }
    for (let i = 0; i < 8; i++) {
      const a = (i / 8) * Math.PI * 2 + rnd() * 0.5, sp = rr(1.1, 1.8) * S;
      const ca = Math.cos(a), sa = Math.sin(a);
      this.starSprites.spawn(x, y, z, rr(0.24, 0.38) * S, rr(0.6, 0.9), i % 2 ? 0xffffff : 0xfff07a, SP_POP, {
        ...base, renderOrder: 43, vx: (_R.x * ca + _U.x * sa) * sp, vy: (_R.y * ca + _U.y * sa) * sp, vz: (_R.z * ca + _U.z * sa) * sp,
        drag: 2.2, rotV: rr(-6, 6), delay: 0.06,
      });
    }
  }

  // ───────── 작은 흰 섬광 (압정 명중)
  hitFlash(pos) {
    if (!readPos(pos, _P)) return;
    this.glowSprites.spawn(_P.x, _P.y, _P.z, 3.4, 0.15, 0xffffff, SP_FLASH);
    this.starSprites.spawn(_P.x, _P.y, _P.z, 2.6, 0.17, 0xffffff, SP_FLASH, HIT_STAR_OPTS);
    const d = this.basic.d;
    for (let i = 0; i < 4; i++) {
      randDir(_v); _v.y = Math.abs(_v.y) * 0.8 + 0.2; _v.normalize().multiplyScalar(rr(3, 6));
      const k = this.basic.add();
      d[k + PX] = _P.x; d[k + PY] = _P.y; d[k + PZ] = _P.z;
      d[k + VX] = _v.x; d[k + VY] = _v.y; d[k + VZ] = _v.z;
      const sz = rr(0.12, 0.2); d[k + SX] = sz; d[k + SY] = sz; d[k + SZ] = sz; d[k + STR] = 0.04;
      d[k + FLAGS] = F_STRETCH; d[k + GRAV] = 10; d[k + DRAG] = 2;
      d[k + MAX] = rr(0.14, 0.24); d[k + CURVE] = C_SHRINK; d[k + RAMP] = R_HIT;
    }
  }

  // ───────── 감사 하트/별 (해방된 차량 위) — 초당 20회 호출도 OK, 최대 60+30 재활용
  hearts(pos) {
    if (!readPos(pos, _P)) return;
    // 멀리(드론샷)서도 읽히도록 카메라 거리에 비례해 키움 (24m 이내 1배 ~ 최대 3.6배)
    let m = 1;
    const cam = this.camera;
    if (cam && cam.matrixWorld) {
      const e = cam.matrixWorld.elements, dx = e[12] - _P.x, dy = e[13] - _P.y, dz = e[14] - _P.z;
      m = clamp(Math.sqrt(dx * dx + dy * dy + dz * dz) / 24, 1, 3.6);
    }
    const n = rnd() < 0.5 ? 3 : 2;
    for (let i = 0; i < n; i++) {
      const x = _P.x + rr(-0.8, 0.8) * m, y = _P.y + rr(-0.1, 0.5) * m, z = _P.z + rr(-0.8, 0.8) * m;
      if (rnd() < 0.24) this.starPool.spawn(x, y, z, rr(1.3, 1.8) * m, rr(1.1, 1.5), rr(2.6, 3.8) * m, rr(-0.5, 0.5) * m);
      else this.heartPool.spawn(x, y, z, rr(1.5, 2.1) * m, rr(1.2, 1.6), rr(2.2, 3.4) * m, rr(-0.4, 0.4) * m);
    }
  }

  // ───────── 카메라 셰이크 (누적 trauma)
  shake(intensity = 0.5, duration = 0.3) {
    const i = clamp(num(intensity, 0.5), 0, 2);
    const d = clamp(num(duration, 0.3), 0.05, 4);
    if (i <= 0) return;
    this._trauma = Math.min(1.2, this._trauma + i);
    this._shakeLeft = Math.max(this._shakeLeft, d);
  }
  get shakeOffset() { return this._shakeOffset; }
  _updateShake() {
    const sdt = FRAME[1], o = this._shakeOffset;
    if (this._trauma <= 0) { if (o.x || o.y || o.z) o.set(0, 0, 0); return; }
    if (sdt <= 0) return; // 시간이 안 흐르면 오프셋 유지
    this._shakeT += sdt;
    if (this._shakeLeft > sdt) { this._trauma *= 1 - sdt / this._shakeLeft; this._shakeLeft -= sdt; }
    else { this._trauma = 0; this._shakeLeft = 0; o.set(0, 0, 0); return; }
    const a = 0.8 * Math.pow(this._trauma, 1.5), t = this._shakeT;
    o.set(
      a * (Math.sin(t * 31.0) * 0.55 + Math.sin(t * 17.3 + 1.7) * 0.3 + Math.sin(t * 53.1 + 0.4) * 0.15),
      a * (Math.sin(t * 27.7 + 2.3) * 0.55 + Math.sin(t * 13.9 + 0.9) * 0.3 + Math.sin(t * 47.3 + 3.1) * 0.15),
      a * 0.5 * (Math.sin(t * 23.3 + 4.1) * 0.6 + Math.sin(t * 11.1 + 2.2) * 0.4),
    );
  }

  // ───────── 스피드라인: 카메라 공간의 가는 흰 막대가 화면 가장자리로 흘러나감
  _initSpeedLines() {
    const N = 72;
    const group = new THREE.Group();
    group.name = 'fx.speedLines';
    group.visible = false;
    const mat = new THREE.MeshBasicMaterial({ color: 0xffffff, transparent: true, opacity: 0.5, depthWrite: false, depthTest: false, fog: false });
    const geo = new THREE.BoxGeometry(1, 1, 1);
    const mesh = new THREE.InstancedMesh(geo, mat, N);
    mesh.frustumCulled = false;
    mesh.renderOrder = 30;
    mesh.instanceMatrix.setUsage(THREE.DynamicDrawUsage);
    mesh.count = 0;
    group.add(mesh);
    if (this.camera && this.camera.isObject3D) this.camera.add(group); else this.root.add(group);
    this._sl = { group, mesh, mat, geo, N, d: new Float32Array(N * 6), init: false };
    this._slTarget = 0; this._slCur = 0;
  }
  speedLines(intensity) {
    const v = clamp(num(intensity, 0), 0, 1);
    this._slTarget = v;
    if (v <= 0) { this._slCur = 0; this._sl.group.visible = false; this._sl.mesh.count = 0; }
  }
  _slSpawn(i, tanX, tanY, anyZ) {
    const d = this._sl.d, o = i * 6;
    const z = anyZ ? -rr(3, 42) : -rr(16, 42);
    const a = rnd() * Math.PI * 2, rho = rr(0.5, 1.05);
    const az = -z;
    d[o] = Math.cos(a) * rho * az * tanX;
    d[o + 1] = Math.sin(a) * rho * az * tanY;
    d[o + 2] = z;
    d[o + 3] = rr(4, 12);                    // 길이
    d[o + 4] = rr(0.035, 0.07) * (az / 18);   // 두께 (화면상 비슷한 픽셀 폭)
    d[o + 5] = rr(55, 100);                  // 속도
  }
  _updateSpeedLines() {
    const dt = FRAME[0], sl = this._sl;
    if (this._slTarget <= 0 && this._slCur <= 0) { if (sl.group.visible) sl.group.visible = false; return; }
    this._slCur += (this._slTarget - this._slCur) * (1 - Math.exp(-4 * dt));
    if (this._slTarget <= 0 && this._slCur < 0.01) { this._slCur = 0; sl.group.visible = false; sl.mesh.count = 0; return; }
    const cam = this.camera;
    const fov = cam && cam.isPerspectiveCamera ? cam.fov : 50, aspect = cam && cam.isPerspectiveCamera ? cam.aspect : 1.6;
    const tanY = Math.tan((fov * Math.PI) / 360), tanX = tanY * aspect;
    const cur = Math.max(this._slCur, 0.02);
    if (!sl.init) { for (let i = 0; i < sl.N; i++) this._slSpawn(i, tanX, tanY, true); sl.init = true; }
    const active = Math.min(sl.N, Math.ceil(sl.N * cur));
    const d = sl.d, mat = sl.mesh.instanceMatrix.array;
    const spdMul = 0.6 + 0.8 * cur, lenMul = 0.5 + 0.9 * cur;
    for (let i = 0; i < active; i++) {
      const o = i * 6;
      d[o + 2] += d[o + 5] * spdMul * dt;
      const az = -d[o + 2];
      if (az < 1.5 || Math.abs(d[o]) > az * tanX * 1.4 || Math.abs(d[o + 1]) > az * tanY * 1.4) { this._slSpawn(i, tanX, tanY, false); }
      const m = i * 16, len = d[o + 3] * lenMul, w = d[o + 4];
      mat[m] = w; mat[m + 1] = 0; mat[m + 2] = 0; mat[m + 3] = 0;
      mat[m + 4] = 0; mat[m + 5] = w; mat[m + 6] = 0; mat[m + 7] = 0;
      mat[m + 8] = 0; mat[m + 9] = 0; mat[m + 10] = len; mat[m + 11] = 0;
      mat[m + 12] = d[o]; mat[m + 13] = d[o + 1]; mat[m + 14] = d[o + 2] - len * 0.5; mat[m + 15] = 1;
    }
    sl.mesh.count = active;
    sl.mat.opacity = 0.18 + 0.42 * cur;
    uploadRange(sl.mesh.instanceMatrix, active * 16);
    sl.group.visible = active > 0;
  }

  // 디버그/하네스용 (계약 외, 읽기 전용)
  _debugStats() {
    return {
      basic: this.basic.n, glow: this.glow.n, lit: this.lit.n, smoke: this.smoke.n, confetti: this.conf.n,
      hearts: this.heartPool.live, stars: this.starPool.live,
      glowSprites: this.glowSprites.live, starSprites: this.starSprites.live,
      rings: this._rings.filter((r) => r.on).length, cores: this._cores.filter((c) => c.on).length,
      trails: this._trails.filter((t) => t.on).length,
      trauma: +this._trauma.toFixed(3), speedLines: this._sl.group.visible ? this._sl.mesh.count : 0,
    };
  }
  _seed(n) { _seed = (n | 0) || 0x2f6e2b1d; }
}
