// 교통 시뮬레이션 v2 — "정체의 인과"가 보이게
//
// 가설: 빌런이 1차선(추월차선)을 막고, 나머지 차선은 원래 느린 화물차·버스(frontRow)가 나란히 → 추월 불가 →
//       빌런 바로 뒤부터 빽빽한 정체. 플레이어(긴급차량)는 갓길로 맨 앞까지 간다.
//       빌런이 사라지면 1차선부터 터지고 → 2~4차선 차들이 1차선으로 빠져 추월 → 뒤로 물결.
//
// 구성
//  - IDM 차량 추종 (차선 0~3 = 1~4차선, 4 = 갓길)
//  - frontRow(isWall): 빌런 옆에 나란히 붙어 속도를 맞추는 정상 저속 차량
//  - 정체: frontRow/빌런 바로 뒤부터 촘촘하게
//  - 갓길: 고정 장애물(고장차/콘/낙하물) + 갓길 얌체(cheater, 경적 울리면 4차선으로 복귀)
//  - 경적: 갓길에서 → 얌체 복귀 / 장애물 앞에서 4차선이 끼워줌(let-in). 차선에서 → 앞차 양보 or 옆 차선이 끼워줌
//  - 해방: 1차선부터 차선별 지연 + 앞→뒤 물결, 해방 후 느린 차는 오른쪽, 빠른 차는 1차선으로 추월
import * as THREE from 'three';
import {
  laneX, LANE_W, NUM_LANES, NPC_KINDS, NPC_COLORS_MONO, NPC_COLORS_POP, TUNE, OPP_LANE_X, SHOULDER_LANE, MINI_TYPES,
} from './config.js';
import { buildVehicle, setBrake, setHazard, setHeadlights, setBlinker } from './vehicles.js';
import { buildShoulderObstacle } from './shoulder.js';

// 결정적 난수 (스테이지마다 같은 배치)
export function mulberry32(a) {
  return function () {
    a |= 0; a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export const ALL_LANES = NUM_LANES + 1; // 갓길 포함
const LANE_HALF_OCC = LANE_W / 2 - 0.6;

// 엔티티 e(x,w)가 차선 i를 점유하는가 (i=4 갓길 포함)
export function occupies(e, i) {
  return Math.abs(e.x - laneX(i)) < e.w / 2 + LANE_HALF_OCC;
}

function pickWeighted(rng, table) {
  let total = 0;
  for (const [, w] of table) total += w;
  let r = rng() * total;
  for (const [k, w] of table) { if ((r -= w) <= 0) return k; }
  return table[0][0];
}

const SLOW_KINDS = new Set(['truck', 'bus', 'pickup1t']);
let CAR_ID = 1;

export class Traffic {
  constructor(scene) {
    this.scene = scene;
    this.cars = [];
    this.obstacles = [];
    this.opp = [];
    this.buckets = Array.from({ length: ALL_LANES }, () => []);
    this.time = 0;
    this.frontLine = 0;
    this.frontV = 0;
    this.released = false;
    this.releasedCount = 0;
    this.onReleased = null;   // (car) => void
    this.onCheater = null;    // (car) => void  갓길 얌체 등장
    this.onMiniAct = null;    // (car, type) => void  잔챙이 빌런 행동 (투척 등)
    this.miniMat = new THREE.MeshBasicMaterial({ color: 0xff9a1a });
    this.miniGeo = new THREE.ConeGeometry(0.42, 0.85, 4).rotateX(Math.PI);
    this.night = false;
  }

  clear() {
    for (const c of this.cars) this.scene.remove(c.mesh);
    for (const c of this.opp) this.scene.remove(c.mesh);
    for (const o of this.obstacles) this.scene.remove(o.mesh);
    for (const d of this.decor || []) this.scene.remove(d);
    this.decor = [];
    this.cars.length = 0;
    this.opp.length = 0;
    this.obstacles.length = 0;
    this.released = false;
    this.releasedCount = 0;
    this.stuckT = 0;
  }

  _makeCar(rng, kind, lane, s, v, extra = {}) {
    const mono = rng() < 0.68;
    const palette = mono ? NPC_COLORS_MONO : NPC_COLORS_POP;
    const color = palette[Math.floor(rng() * palette.length)];
    const mesh = buildVehicle(kind, { color, seed: Math.floor(rng() * 1e6) });
    const ud = mesh.userData;
    const car = {
      id: CAR_ID++, mesh, kind,
      lane, laneFrom: lane, laneTo: lane, lcT: 1, lcDur: 1.8,
      x: laneX(lane), s, v, a: 0,
      len: ud.length || 4.5, w: ud.width || 1.9,
      personal: 0.97 + rng() * 0.06,
      phase: rng() * Math.PI * 2,
      brakeT: 0, pullT: 0, brakeOn: false, hazardUntil: 0, hazardOn: false,
      released: false, releaseAt: Infinity, vFree: 30, slow: SLOW_KINDS.has(kind),
      isWall: false, isCheater: false, nextLcAt: 0,
      bumpJolt: 0, yaw: 0,
      ...extra,
    };
    mesh.position.set(car.x, 0, -s);
    if (this.night) setHeadlights(mesh, true);
    this.scene.add(mesh);
    this.cars.push(car);
    return car;
  }

  // villains: [{s, x, w, len}], playerStart: {s, lane}
  spawnJam(stage, villains, playerStart, rng, night = false) {
    this.clear();
    this.night = night;
    this.rng = rng;
    this.nextCheater = null;   // 스테이지마다 첫 얌체는 시작 후 6초 뒤 (G.time은 전역 시계라 이전 판 마감이 남으면 안 됨)
    // 접근 규칙 (판별): 갓길 모드 · 끼워주기 틈 검사 · 경적 피로 · 고무줄
    this.approach = { ...TUNE.approach, ...(stage.approach || {}) };
    this.shoulderClosed = ['closed', 'none'].includes(this.approach.shoulder);
    this.stuckFor = 0;
    const sFront = Math.max(...villains.map((v) => v.s));
    this.frontLine = sFront;
    this.frontV = stage.jamSpeed;
    this.jamSpeed = stage.jamSpeed;
    const density = stage.density || 1;
    const tail = playerStart.s - 45;
    this.sTail = tail;

    // ① 앞줄(frontRow): 빌런 옆에 나란히 서는 정상 저속 차량 → '벽'
    const villainLanes = new Set();
    for (const v of villains) for (let i = 0; i < NUM_LANES; i++) if (occupies(v, i)) villainLanes.add(i);
    const zig = !!(stage.zig || (stage.attacks && stage.attacks.zigzag));
    const zc = stage.zigCenter ?? 1;
    if (zig) { villainLanes.add(zc - 1); villainLanes.add(zc); villainLanes.add(zc + 1); }
    const fr = stage.frontRow || { 1: 'truck', 2: 'truck', 3: 'truck' };
    const frontRear = new Array(NUM_LANES).fill(Infinity);
    for (const v of villains) for (let i = 0; i < NUM_LANES; i++) if (occupies(v, i)) frontRear[i] = Math.min(frontRear[i], v.s - v.len / 2);
    this.zigzag = zig;
    for (let l = 0; l < NUM_LANES; l++) {
      if (villainLanes.has(l)) continue;
      if (!fr[l]) continue; // 빌런이 스워브로 막는 차선 (가상의 '못 지나감' 벽)
      const kind = fr[l] || 'truck';
      const off = (rng() - 0.5) * 1.2;
      const c = this._makeCar(rng, kind, l, sFront + off, stage.jamSpeed, { isWall: true, wallOffset: off });
      frontRear[l] = c.s - c.len / 2;
    }
    // 지그재그 빌런: 빌런 바로 뒤 차선들은 겁나서 거리 둠 (그래도 막혀 있음)
    for (let l = 0; l < NUM_LANES; l++) if (!isFinite(frontRear[l])) frontRear[l] = sFront - 3;

    // ② 정체: 차로별 성격(JamShaper)대로 — 기본 'packed'는 앞줄 바로 뒤부터 빽빽하게 (플레이어 시작 자리만 비움)
    //    stage.jamShape.lanes[l]: 'packed' | 'train'(촘촘·쉬지 않고 굴러감) | 'flow'(꾸준히) | 'spaced'(차간 넓음 = 누빌 길)
    this.jamShape = stage.jamShape || null;
    this.laneKind = [0, 1, 2, 3].map((l) => this.jamShape?.lanes?.[l] || 'packed');
    this.jamWaves = [];
    this.jamSrcT = 0;
    for (let l = 0; l < NUM_LANES; l++) {
      const lk = this.laneKind[l];
      const gapOf = () => lk === 'spaced' ? 7 + rng() * 5 : lk === 'pass' ? 6 + rng() * 4 : lk === 'train' ? 1.2 + rng() * 0.5 : lk === 'flow' ? 2.6 + rng() * 2 : (1.5 + rng() * 1.7) / density;
      let cursor = frontRear[l] - (lk === 'spaced' ? 9 + rng() * 4 : 2.2 + rng() * 1.6) - (villainLanes.has(l) && zig ? 6 : 0);
      while (cursor > tail) {
        const kind = pickWeighted(rng, NPC_KINDS);
        const tmp = this._makeCar(rng, kind, l, 0, stage.jamSpeed * 0.7);
        let s = cursor - tmp.len / 2;
        if (l === playerStart.lane && s + tmp.len / 2 > playerStart.s - 3.4 && s - tmp.len / 2 < playerStart.s + 3.4) {
          // 플레이어 자리: 바로 뒤로 밀어 둔다
          s = playerStart.s - 3.4 - tmp.len / 2 - 2.0;
        }
        tmp.s = s;
        tmp.mesh.position.z = -s;
        cursor = s - tmp.len / 2 - gapOf();
      }
    }

    // ③ 갓길: 장애물 + 얌체 (갓길 모드별)
    const mode = this.approach.shoulder;
    let spec = stage.shoulder || [['breakdown', 1], ['cones', 1], ['cheater', 1]];
    if (this.shoulderClosed) spec = [];                                        // 폐쇄·터널: 갓길로 못 감
    else if (mode === 'crowded') spec = [...spec.filter(([k]) => k !== 'cheater'), ['cheater', 3]];
    else if (mode === 'dark') spec = [['debris', 3], ['breakdown', 1], ['cheater', 1]];   // 무등화 낙하물
    else if (mode === 'debris') spec = [['debris', 4], ['cheater', 1]];
    const list = [];
    for (const [k, n] of spec) for (let i = 0; i < n; i++) list.push(k);
    if (mode === 'closed') this._buildShoulderBarrier(playerStart.s - 20, sFront + 30);
    if (mode === 'blocked') {
      // 갓길 중간 60m 공사 구간: 콘이 줄지어 있어 날리면 콘마다 내구도 −5
      const b0 = playerStart.s + (sFront - playerStart.s) * 0.45;
      for (let k = 0; k < 5; k++) list.push({ kind: 'cones', at: b0 + k * 12 });
    }
    // 섞기
    for (let i = list.length - 1; i > 0; i--) { const j = Math.floor(rng() * (i + 1)); [list[i], list[j]] = [list[j], list[i]]; }
    const s0 = playerStart.s + 38, s1 = sFront - 22;
    const step = (s1 - s0) / Math.max(1, list.length);
    list.forEach((item, i) => {
      const kind = typeof item === 'string' ? item : item.kind;
      const s = typeof item === 'string' ? s0 + step * (i + 0.25 + rng() * 0.5) : item.at;
      if (kind === 'cheater') {
        const c = this._makeCar(rng, pickWeighted(rng, [['sedan', 3], ['suv', 2], ['compact', 1]]), SHOULDER_LANE, s, 4.5, { isCheater: true });
        c.cheaterV = 4 + rng() * 2.5;
        return;
      }
      const ob = buildShoulderObstacle(kind, rng, { dark: mode === 'dark' });
      ob.group.position.set(laneX(SHOULDER_LANE) - 0.1, 0, -s);
      this.scene.add(ob.group);
      const e = { id: CAR_ID++, kind, mesh: ob.group, s, x: laneX(SHOULDER_LANE) - 0.1, len: ob.len, w: ob.w, v: 0, isObstacle: true, hazardCar: ob.hazardCar, smash: kind !== 'breakdown' };
      if (ob.hazardCar && night) setHeadlights(ob.hazardCar, false);
      this.obstacles.push(e);
    });

    // ③-2 잔챙이 빌런: 갓길 바로 옆(4차선) 차 중 몇 대 — 지나가며 압정으로 참교육
    const nMini = stage.minis ?? Math.min(4, 2 + Math.floor((stage.difficulty ?? stage.id ?? 1) / 3));
    const types = Object.keys(MINI_TYPES);
    const lane3 = this.cars.filter((c) => c.lane === NUM_LANES - 1 && !c.isWall && !c.isCheater && c.s > playerStart.s + 30 && c.s < sFront - 30).sort((a, b) => a.s - b.s);
    for (let i = 0; i < nMini && lane3.length; i++) {
      const want = playerStart.s + 30 + ((sFront - 30) - (playerStart.s + 30)) * (i + 0.5) / nMini;
      let best = lane3[0];
      for (const c of lane3) if (Math.abs(c.s - want) < Math.abs(best.s - want)) best = c;
      lane3.splice(lane3.indexOf(best), 1);
      const type = types[Math.floor(rng() * types.length)];
      best.mini = { type, hp: 12, max: 12, cool: 0.6 + rng(), acted: 0, done: false };
      best.alive = true;
      const mk = new THREE.Mesh(this.miniGeo, this.miniMat);
      mk.position.y = (best.mesh.userData.height || 1.6) + 1.1;
      best.mesh.add(mk);
      best.miniMarker = mk;
    }

    // ④ 반대편 차로 (뻥 뚫려서 쌩쌩 — 약 올림)
    for (let i = 0; i < 26; i++) {
      const j = Math.floor(rng() * 4);
      const kind = pickWeighted(rng, NPC_KINDS);
      const pal = rng() < 0.7 ? NPC_COLORS_MONO : NPC_COLORS_POP;
      const mesh = buildVehicle(kind, { color: pal[Math.floor(rng() * pal.length)] });
      mesh.rotation.y = Math.PI;
      if (night) setHeadlights(mesh, true);
      this.scene.add(mesh);
      const c = { mesh, j, s: playerStart.s - 100 + rng() * 520, v: 24 + rng() * 12 - j * 2 };
      mesh.position.set(OPP_LANE_X(j), 0, -c.s);
      this.opp.push(c);
    }
    for (const c of this.cars) setBrake(c.mesh, true);
  }

  // 차선 버킷 (s 오름차순)
  _buildBuckets(extra) {
    const B = this.buckets;
    for (const b of B) b.length = 0;
    const add = (e) => { for (let i = 0; i < ALL_LANES; i++) if (occupies(e, i)) B[i].push(e); };
    for (const c of this.cars) add(c);
    for (const o of this.obstacles) add(o);
    for (const e of extra) if (e) add(e);
    for (const b of B) b.sort((a, b2) => a.s - b2.s);
  }

  // 엔티티 e 의 전방 선행 차량 (점유 차선 중 가장 가까운 것)
  leaderOf(e) {
    let best = null, bestGap = Infinity;
    for (let i = 0; i < ALL_LANES; i++) {
      if (!occupies(e, i)) continue;
      const b = this.buckets[i];
      for (let k = 0; k < b.length; k++) {
        const o = b[k];
        if (o === e || o.s <= e.s) continue;
        const gap = (o.s - o.len / 2) - (e.s + e.len / 2);
        if (gap < bestGap) { bestGap = gap; best = o; }
        break;
      }
    }
    return best ? { car: best, gap: bestGap } : null;
  }

  laneBlocked(lane, sMin, sMax, exclude) {
    const b = this.buckets[lane];
    if (!b) return null;
    for (const o of b) {
      if (o === exclude) continue;
      if (o.s + o.len / 2 > sMin && o.s - o.len / 2 < sMax) return o;
    }
    return null;
  }

  // 플레이어가 lane 으로 끼어들 수 있나: 양보 중인 뒤차는 앞범퍼가 살짝(≤1.3m) 겹쳐도 OK (멈칫해서 넣어줌)
  canMergeInto(lane, player, margin = 0.35) {
    const sMin = player.s - player.len / 2 - margin, sMax = player.s + player.len / 2 + margin;
    for (const o of this.buckets[lane] || []) {
      if (o === player) continue;
      const oFront = o.s + o.len / 2, oRear = o.s - o.len / 2;
      if (oFront <= sMin || oRear >= sMax) continue;
      if (o.yieldUntil > this.time && o.s < player.s && oFront - (player.s - player.len / 2) < 1.3) continue;
      return o;
    }
    return null;
  }

  gapAhead(lane, s, exclude) {
    let best = Infinity, who = null;
    const b = this.buckets[lane];
    if (!b) return { gap: best, who };
    for (const o of b) {
      if (o === exclude) continue;
      const rear = o.s - o.len / 2;
      if (rear > s && rear - s < best) { best = rear - s; who = o; }
    }
    return { gap: best, who };
  }

  // 해방: 빌런 자리(1차선)부터, 차선별 지연 + 앞→뒤 물결
  // openLane: 빌런이 막고 있던 차로 = 가장 먼저 풀리는 차로 (거기서 멀수록 조금씩 늦게)
  release(time, waveSpeed = TUNE.releaseWaveSpeed, openLane = 0) {
    this.released = true;
    this.releaseTime = time;
    const front = this.frontLine;
    const [lo, hi] = TUNE.releaseSpeed;
    const [tlo, thi] = TUNE.truckFreeSpeed;
    for (const c of this.cars) {
      const laneDelay = Math.min(3, Math.abs(Math.min(3, c.lane) - openLane)) * TUNE.releaseLaneDelay;
      c.releaseAt = time + Math.max(0, front - c.s) / waveSpeed + laneDelay + (c.isWall ? 0.35 : 0.08);
      c.vFree = c.slow ? tlo + this.rng() * (thi - tlo) : lo + this.rng() * (hi - lo);
    }
  }

  // ctx: { dt, time, player, villains:[...], phase, allowEvents, focusS }
  update(dt, ctx) {
    this.time = ctx.time;
    const player = ctx.player;
    const villains = ctx.villains || [];
    const alive = villains.filter((v) => v.alive);
    if (alive.length) {
      this.frontLine = Math.max(...alive.map((v) => v.baseS ?? v.s));
      this.frontV = alive[0].vNominal ?? alive[0].v;
    }
    this._buildBuckets([player, ...alive]);

    const t = ctx.time;
    const jamV = this.jamSpeed;
    const rng = this.rng;

    // 랜덤 급정거 (브레이크 물결)
    if (!this.released && rng() < dt * 0.6) {
      const cand = this.cars.filter((c) => !c.isWall && !c.isCheater && c.s > player.s - 10 && c.s < player.s + 80);
      if (cand.length) cand[Math.floor(rng() * cand.length)].brakeT = 0.6 + rng() * 0.7;
    }
    // 갇힘 보조 (갓길 장애물 앞 등): 옆 차선이 끼워준다
    if (!this.released && ctx.phase === 'jam') this._stuckAssist(dt, player);
    // 갓길 얌체 등장 이벤트: 4차선 차가 플레이어 앞 갓길로 튀어나옴
    if (this.nextCheater == null) this.nextCheater = t + 6;
    if (ctx.allowEvents && player.lane === SHOULDER_LANE && player.v > 8 && t > this.nextCheater) {
      this.nextCheater = t + 7 + rng() * 5;
      this._spawnCheaterAhead(player);
    }

    // 잔챙이 빌런 행동: 플레이어가 뒤에서 다가오면 꽁초/쓰레기 투척 or 갓길로 칼치기
    if (!this.released && ctx.phase === 'jam') {
      for (const c of this.cars) {
        const m = c.mini;
        if (!m || m.done) continue;
        if (c.miniMarker) c.miniMarker.position.y = (c.mesh.userData.height || 1.6) + 1.1 + Math.sin(t * 6 + c.id) * 0.18;
        const ds = c.s - player.s;
        if (ds < 4 || ds > 30) continue;
        m.cool -= dt;
        if (m.cool > 0) continue;
        if (m.type === 'cutin') {
          if (m.acted < 1 && ds > 10 && !this.laneBlocked(SHOULDER_LANE, c.s - c.len / 2 - 2, c.s + c.len / 2 + 2, c)) {
            m.acted++;
            c.isCheater = true; c.cheaterV = 3.5;
            this._startLaneChange(c, SHOULDER_LANE, 0.8);
            this.onMiniAct?.(c, m.type);
          }
          m.cool = 3;
        } else if (m.acted < 2) {
          // 잔챙이 투척은 지나갈 때 최대 2번 (옆에 붙어 기어가는 동안 무한 투척 금지)
          m.acted++;
          m.cool = 2.0 + this.rng() * 1.2;
          this.onMiniAct?.(c, m.type);
        }
      }
    }

    if (!this.released) this._updateJamShape(dt, t, alive, player);

    for (const c of this.cars) {
      if (!c.released && t >= c.releaseAt) {
        c.released = true;
        c.hazardUntil = t + 1.05;
        c.nextLcAt = t + 0.4 + rng() * 0.6;
        this.releasedCount++;
        if (this.onReleased) this.onReleased(c);
      }

      // 목표 속도
      let v0, T, s0, aMax;
      if (c.released) {
        v0 = c.vFree; T = 0.5; s0 = 2.0; aMax = c.slow ? 2.6 : 4.6;
      } else if (c.isWall) {
        const target = this.frontLine + c.wallOffset - (c.wallBack || 0);
        v0 = Math.max(0, this.frontV + (target - c.s) * 0.9);
        T = 0.5; s0 = 1.5; aMax = 3.0;
      } else if (c.isCheater) {
        v0 = c.cheaterV || 5; T = 0.6; s0 = 2.0; aMax = 2.5;
      } else {
        const lk = this.laneKind?.[Math.min(NUM_LANES - 1, c.lane)] || 'packed';
        if (lk === 'train') { v0 = jamV * 1.0; T = 0.45; s0 = 1.2; aMax = 1.6; }                 // 쉬지 않고 굴러가는 기차
        else if (lk === 'flow') { v0 = jamV * 0.95 * c.personal; T = 0.8; s0 = 2.2; aMax = 1.6; } // 꾸준한 흐름
        else if (lk === 'spaced') { v0 = jamV * 1.05 * c.personal; T = 1.6; s0 = 5.5; aMax = 1.4; } // 거리 두는 차로
        else if (lk === 'pass') { v0 = jamV * (this.jamShape?.passV ?? 2.2) * c.personal; T = 1.0; s0 = 3.0; aMax = 2.0; } // 유일한 추월 차로 (빌런 옆에서만 멈칫)
        else {
          // 차선 단위 stop & go (같은 차선은 같이 움직임)
          const lf = 0.35 + 0.65 * (0.5 + 0.5 * Math.sin(t * 0.42 + c.lane * 1.9));
          v0 = jamV * c.personal * lf * 1.25;
          T = 0.5; s0 = 1.4; aMax = 1.8;
        }
      }
      if (c.pullT > 0 && !c.released) { c.pullT -= dt; v0 = Math.max(v0, jamV * (c.letInBoost ? 3.6 : 2.2)); aMax = 3.6; T = 0.3; s0 = 1.0; }
      else c.letInBoost = 0;
      if (c.brakeT > 0) { c.brakeT -= dt; v0 = 0.01; }

      // IDM
      const L = this.leaderOf(c);
      let gap = Infinity, dv = 0, lv = 0;
      if (L) { gap = L.gap; lv = L.car.v; dv = c.v - lv; }
      // 해방 전: 빌런 옆을 지나가지 못함 (빌런이 막는 차선은 가상의 벽)
      if (!c.released && !c.isWall && !c.isCheater && this.laneKind?.[Math.min(NUM_LANES - 1, c.lane)] !== 'pass') {
        const g2 = (this.frontLine - 3 - (this.zigzag ? 5 : 0)) - (c.s + c.len / 2);
        if (g2 < gap) { gap = g2; dv = c.v - this.frontV; lv = this.frontV; }
      }
      const b = 3.0;
      const sStar = s0 + Math.max(0, c.v * T + (c.v * dv) / (2 * Math.sqrt(aMax * b)));
      const vr = c.v / Math.max(0.1, v0);
      let acc = aMax * (1 - vr * vr * vr * vr) - aMax * Math.pow(sStar / Math.max(0.3, gap), 2);
      acc = Math.max(-9, Math.min(aMax, acc));
      c.a = acc;
      c.v = Math.max(0, c.v + acc * dt);
      c.s += c.v * dt;
      if (L && gap < 0.25 && L.car !== player) c.v = Math.min(c.v, Math.max(0, lv));

      // 차선 변경 진행
      if (c.lcT < 1) {
        c.lcT = Math.min(1, c.lcT + dt / c.lcDur);
        if (c.blinkSide) setBlinker(c.mesh, c.blinkSide, t + (c.id % 7) * 0.09);
        const e = c.lcT * c.lcT * (3 - 2 * c.lcT);
        const nx = laneX(c.laneFrom) + (laneX(c.laneTo) - laneX(c.laneFrom)) * e;
        c.yaw = -Math.atan2((nx - c.x) / Math.max(dt, 1e-4), Math.max(2, c.v)) * 0.8;
        c.x = nx;
        if (c.lcT >= 1) {
          c.lane = c.laneTo; c.yaw = 0;
          if (c.blinkSide) { setBlinker(c.mesh, null); c.blinkSide = null; }
          if (c.isCheater && c.lane !== SHOULDER_LANE) c.isCheater = false;
        }
      } else if (c.released && t > c.nextLcAt) {
        this._postReleaseLaneChange(c);
      } else if (c.isCheater && this.released) {
        // 해방되면 얌체도 슬쩍 복귀
        if (this._safeToEnter(c, NUM_LANES - 1, 2.5)) this._startLaneChange(c, NUM_LANES - 1, 1.2);
      }

      // 차체 연출
      if (c.bumpJolt > 0) c.bumpJolt = Math.max(0, c.bumpJolt - dt * 3);
      const m = c.mesh;
      m.position.x = c.x;
      m.position.z = -c.s;
      m.rotation.y = c.yaw;
      if (m.userData.body) m.userData.body.rotation.x = -c.bumpJolt * 0.12 + Math.max(-0.05, Math.min(0.05, acc * 0.006));

      const wantBrake = !c.released && (acc < -0.25 || c.v < 1.6 || c.brakeT > 0 || Math.sin(t * 1.3 + c.phase) > 0.2);
      if (wantBrake !== c.brakeOn) { c.brakeOn = wantBrake; setBrake(m, wantBrake); }
      const hz = (t < c.hazardUntil && ((t - c.hazardUntil) % 0.5 + 0.5) % 0.5 < 0.27) || (c.isCheater && Math.floor(t * 2.2) % 2 === 0);
      if (hz !== c.hazardOn) { c.hazardOn = hz; setHazard(m, hz); }
    }

    // 고장차 비상등
    for (const o of this.obstacles) if (o.hazardCar) setHazard(o.hazardCar, Math.floor(t * 2) % 2 === 0);

    // 반대편
    const focus = ctx.focusS ?? player.s;
    for (const c of this.opp) {
      c.s -= c.v * dt;
      if (c.s < focus - 130) c.s = focus + 280 + rng() * 160;
      c.mesh.position.z = -c.s;
    }
  }

  // 해방 후: 느린 차(화물·버스)는 오른쪽 차로로, 빠른 차는 느린 앞차를 1차선 쪽으로 추월 → "1차선은 추월차선"이 제대로 작동
  _postReleaseLaneChange(c) {
    c.nextLcAt = this.time + 0.8 + this.rng() * 0.8;
    if (c.lane === SHOULDER_LANE) return;
    if (c.slow) {
      const tl = c.lane + 1;
      if (tl <= NUM_LANES - 1 && this._safeToEnter(c, tl, 3)) this._startLaneChange(c, tl, 1.4);
      return;
    }
    const L = this.leaderOf(c);
    if (L && L.gap < 22 && L.car.v < c.vFree - 3 && c.lane > 0) {
      const tl = c.lane - 1;
      if (this._safeToEnter(c, tl, 3.5)) this._startLaneChange(c, tl, 0.95);
    }
  }

  // 갇힘 보조: 1.6초 이상 거의 못 움직이면, 진행하고 싶은 옆 차선이 자리를 내준다
  _stuckAssist(dt, player) {
    const A = this.approach || TUNE.approach;
    if (player.v < 2.5 && player.mode === 'jam') { this.stuckT = (this.stuckT || 0) + dt; this.stuckFor = (this.stuckFor || 0) + dt; }
    else { this.stuckT = Math.max(0, (this.stuckT || 0) - dt * 2); this.stuckFor = 0; }
    if (this.stuckT < (A.rubber ?? 2.5)) return;
    this.stuckT = 0;
    let tl = player.lane === SHOULDER_LANE ? NUM_LANES - 1 : Math.min(SHOULDER_LANE, player.lane + 1);
    if (tl === SHOULDER_LANE && this.shoulderClosed) tl = NUM_LANES - 1 === player.lane ? player.lane - 1 : tl - 1;
    // 고무줄: 판별 틈만 여는 게 원칙이지만, 4초 넘게 못 움직이면 가장 가까운 틈을 강제로 연다 (소프트락 방지)
    const force = !A.gapCheck || this.stuckFor > (A.rubberSafety ?? 4);
    if (force || this._hasGap(tl, player)) this.letIn(tl, player, { force: true });
    else if (player.lane < NUM_LANES && this.stuckFor > 1) this._pullAhead(player);
    this.assists = (this.assists || 0) + 1;
    // 갓길 고장차 옆에서 정체가 얼어붙으면(정차형 빌런 판) 끼워줄 틈이 영영 안 생긴다 → 두 번 갇히면 레커 출동·견인
    if (player.lane >= NUM_LANES - 1) {
      const ob = this.obstacles.find((o) => !o.smash && o.s - o.len / 2 < player.s + 16 && o.s + o.len / 2 > player.s - 6);
      if (ob && (ob.stuckN = (ob.stuckN || 0) + 1) >= 2) {
        this.obstacles.splice(this.obstacles.indexOf(ob), 1);
        this.onAutoTow?.(ob);
      }
    }
  }

  // ── JamShaper: 브레이크 파동 (차로 lane, 위치 s에서 뒤로 speed m/s로 흐름; 차를 만날 때마다 강도 × amp)
  emitBrakeWave(lane, s, strength = 1, opts = {}) {
    if (lane < 0 || lane >= NUM_LANES) return;
    this.jamWaves.push({ lane, s, strength, amp: opts.amp ?? 0.88, speed: opts.speed ?? 6, hold: opts.hold ?? 0.6, life: opts.life ?? 6, hit: new Set() });
  }
  _updateJamShape(dt, t, alive, player) {
    // 파동 전파
    for (let i = this.jamWaves.length - 1; i >= 0; i--) {
      const w = this.jamWaves[i];
      w.s -= w.speed * dt; w.life -= dt;
      if (w.life <= 0 || w.strength < 0.15) { this.jamWaves.splice(i, 1); continue; }
      for (const c of this.buckets[w.lane] || []) {
        if (!this.cars.includes(c) || c.released || c.isWall || w.hit.has(c)) continue;
        if (Math.abs(c.s - w.s) < c.len / 2 + 1.2) {
          w.hit.add(c);
          c.brakeT = Math.max(c.brakeT, w.hold * Math.min(2.5, w.strength));
          w.strength *= w.amp;   // amp<1 약해짐(충격파), amp>1 커짐(유령정체 증폭)
        }
      }
    }
    // 소스: 판 시그니처가 만드는 정체 모양 (빌런 기준)
    const src = this.jamShape?.sources || [];
    if (!src.length || !alive.length) return;
    const v = alive[0];
    this.jamSrcT -= dt;
    for (const S of src) {
      if (S.type === 'yield' && this.jamSrcT <= 0) {
        // 옆 차로 톱니: 빌런 옆(-20~+5m) 차들이 '들어오나?' 하고 차례로 멈칫 → 그 차로에 틈(포켓)이 생김
        const lane = S.lane ?? 0;
        // 차마다 한 번만 멈칫하고 지나간다 (계속 붙잡으면 추월 차로가 얼어붙음)
        const cands = (this.buckets[lane] || []).filter((c) => this.cars.includes(c) && !c.isWall && !c.released && !c.yielded && c.brakeT <= 0 && c.s > v.s - 20 && c.s < v.s + 5);
        if (cands.length) {
          const c = cands.sort((a, b) => b.s - a.s)[0];
          c.brakeT = S.hold ?? 2.5;
          c.yielded = true;
          c.yieldPocket = t;
          this.emitBrakeWave(lane, c.s - c.len / 2 - 1, 0.7, { amp: 0.8 });
        }
      }
    }
    if (this.jamSrcT <= 0) this.jamSrcT = src[0].period ?? 2.5;
  }

  _hasGap(tl, player) {
    const need = (player.len || 4.2) + 1.0;
    let ahead = null, behind = null;
    for (const o of this.buckets[tl] || []) {
      if (o === player) continue;
      if (o.s >= player.s) { if (!ahead || o.s < ahead.s) ahead = o; }
      else if (!behind || o.s > behind.s) behind = o;
    }
    const front = ahead ? ahead.s - ahead.len / 2 : Infinity;
    const back = behind ? behind.s + behind.len / 2 : -Infinity;
    if (front - back < need) return false;
    // 틈이 내 위치 ±6m 안에 걸쳐 있어야
    return front > player.s - 6 && back < player.s + 6;
  }

  // 갓길 폐쇄: 콘 + 방호벽 띠 (장식, 충돌 없음 — 플레이어가 갓길로 못 들어감)
  _buildShoulderBarrier(sA, sB) {
    const g = new THREE.Group();
    const rng = this.rng || Math.random;
    for (let s = sA; s < sB; s += 6) {
      const ob = buildShoulderObstacle('cones', rng);
      ob.group.position.set(laneX(SHOULDER_LANE) - 1.2, 0, -s);
      ob.group.scale.set(1, 1, 0.5);
      g.add(ob.group);
    }
    this.scene.add(g);
    this.decor = this.decor || [];
    this.decor.push(g);
  }

  // 내 차로 앞차들을 살짝 당겨 숨통 (강제 개방 전 단계)
  _pullAhead(player) {
    for (const o of this.buckets[player.lane] || []) {
      if (!this.cars.includes(o) || o.isWall || o.released) continue;
      const d = o.s - player.s;
      if (d > 0 && d < 18) { o.pullT = Math.max(o.pullT, 1.2); }
    }
  }

  // 구조형 마무리: 원인 차량이 갓길로 빠질 때 그 사이 차로의 앞줄 벽이 뒤로 물러나 길을 터 줌
  dropWalls(lanes, meters = 9) {
    for (const c of this.cars) if (c.isWall && lanes.includes(c.lane)) c.wallBack = meters;
  }

  // 차선 tl 이 플레이어 옆에 자리를 만든다: 앞쪽 차는 살짝 당기고 뒤쪽 차는 멈칫
  letIn(tl, player, opts = {}) {
    // 실제 틈 검사: 목표 차로 ±6m 안에 (내 차 길이 + 1m) 이상의 틈이 있어야 끼워준다 (고무줄 강제 개방은 예외)
    if (this.approach?.gapCheck && !opts.force && !this._hasGap(tl, player)) return null;
    let who = null;
    for (const o of this.buckets[tl] || []) {
      if (!this.cars.includes(o) || o.isWall || o.released) continue;
      const d = o.s - player.s;
      // 옆·앞 차들은 줄줄이 당겨 앞으로 (앞 3~4대 연쇄) / 뒤 차들은 멈칫 → 플레이어 옆에 자리가 생김
      if (d > -3.5 && d < 22) { o.pullT = Math.max(o.pullT, 2.2); o.letInBoost = 1; who = who || o; }
      else if (d <= -3.5 && d > -14) { o.brakeT = Math.max(o.brakeT, 2.2); o.yieldUntil = this.time + 2.8; who = who || o; }
    }
    return who;
  }

  _spawnCheaterAhead(player) {
    // 플레이어 12~28m 앞, 4차선 차 중 하나가 갓길로 튀어나옴
    const cands = this.cars.filter((c) => c.lane === NUM_LANES - 1 && !c.isWall && !c.released && c.lcT >= 1 && c.s - player.s > 14 && c.s - player.s < 30);
    if (!cands.length) return;
    const c = cands[Math.floor(this.rng() * cands.length)];
    if (this.laneBlocked(SHOULDER_LANE, c.s - c.len / 2 - 2, c.s + c.len / 2 + 2, c)) return;
    c.isCheater = true;
    c.cheaterV = 4 + this.rng() * 2;
    this._startLaneChange(c, SHOULDER_LANE, 0.9);
    if (this.onCheater) this.onCheater(c);
  }

  _safeToEnter(c, tl, margin) {
    for (const o of this.buckets[tl] || []) {
      if (o === c) continue;
      const ahead = (o.s - o.len / 2) - (c.s + c.len / 2);
      const behind = (c.s - c.len / 2) - (o.s + o.len / 2);
      if (ahead > -0.1 && ahead < margin) return false;
      if (behind > -0.1 && behind < margin + Math.max(0, o.v - c.v) * 1.5) return false;
      if (ahead <= -0.1 && behind <= -0.1) return false;
    }
    return true;
  }

  _startLaneChange(c, tl, dur) {
    // 정상 운전자는 깜빡이를 켜고 들어간다 (얌체·잔챙이 칼치기는 안 켬 → 빌런과의 대비)
    c.blinkSide = (c.isCheater || c.mini) ? null : (tl > c.lane ? 'right' : 'left');
    c.laneFrom = c.lane; c.laneTo = tl; c.lcT = 0; c.lcDur = dur;
    c.lane = tl;
  }

  // 경적. 반환: { car, kind: 'cheater'|'yield'|'letin'|'noway'|'villain' } | null
  honk(player, opts = {}) {
    const pl = player.lane;
    const range = opts.siren ? 45 : opts.trot ? 24 : 18;  // 사이렌(암행차)·트로트 경적은 더 멀리·잘 비켜줌
    const { gap, who } = this.gapAhead(pl, player.s + player.len / 2 - 0.5, player);
    if (who && who.isVillain && gap < 30) return { car: who, kind: 'villain' };
    if (pl === SHOULDER_LANE) {
      // 갓길 얌체 → 4차선으로 복귀 (4차선 뒤차가 멈칫해서 자리 줌)
      // 갓길에 완전히 들어온 얌체만 (진입·복귀 중엔 순간이동·이중 보상 방지 — rageHorn과 같은 가드)
      if (who && who.isCheater && who.lcT >= 1 && who.lane === SHOULDER_LANE && gap < (opts.siren ? 50 : 30)) {
        this.letIn(NUM_LANES - 1, who, { force: true });
        this._startLaneChange(who, NUM_LANES - 1, 1.1);
        who.cheaterV = 0;
        return { car: who, kind: 'cheater' };
      }
      // 장애물이 앞에 있으면 4차선이 끼워줌
      if (who && who.isObstacle && gap < range) {
        const c = this.letIn(NUM_LANES - 1, player);
        return c ? { car: c, kind: 'letin' } : { car: who, kind: 'noway' };
      }
      return null;
    }
    if (!who || gap > range - 2 || !who.mesh || who.released) return null;
    // 경적 피로: 같은 차에 2번째는 절반만, 3번째부터 무시('또 빵?'). 8초마다 한 단계 풀림
    if (this.approach?.fatigue && this.cars.includes(who)) {
      if (who.honkT && this.time - who.honkT > 8) who.honkN = Math.max(0, (who.honkN || 0) - 1);
      who.honkN = (who.honkN || 0) + 1; who.honkT = this.time;
      if (who.honkN >= 3 || (who.honkN === 2 && this.rng() < 0.5)) return { car: who, kind: 'tired' };
    }
    // 앞차가 옆으로 비켜줄 수 있으면 비켜줌
    if (this.cars.includes(who) && !who.isWall && who.lcT >= 1) {
      const opts = [who.lane - 1, who.lane + 1].filter((l) => l >= 0 && l < NUM_LANES);
      for (const tl of opts) {
        if (this._safeToEnter(who, tl, 1.6)) { this._startLaneChange(who, tl, 0.85); return { car: who, kind: 'yield' }; }
      }
    }
    // 아니면 오른쪽(갓길 쪽) 차선이 끼워줌
    const c = this.letIn(Math.min(SHOULDER_LANE, pl + 1), player);
    return c ? { car: c, kind: 'letin' } : { car: who, kind: 'noway' };
  }

  // 분노의 경적: 갓길 앞 range 까지 싹 쓸어버림. 반환 { smashed:[obstacle], towed:[obstacle], cheaters:[car], startled:[car] }
  rageHorn(player, range) {
    const s0 = player.s - 2, s1 = player.s + range;
    const out = { smashed: [], towed: [], cheaters: [], startled: [] };
    for (const o of [...this.obstacles]) {
      if (o.s < s0 || o.s > s1) continue;
      // 콘·낙하물만 날린다. 고장차는 경적으로 사라지지 않음 (레커 장착 또는 '지인 주차' 판만 견인)
      if (!o.smash && !(this.approach?.shoulder === 'occupied' || player.stats?.tow)) continue;
      this.obstacles.splice(this.obstacles.indexOf(o), 1);
      (o.smash ? out.smashed : out.towed).push(o);
    }
    for (const c of this.cars) {
      if (c.released) continue;
      if (c.s < s0 || c.s > s1) continue;
      if ((c.isCheater || c.lane === SHOULDER_LANE) && c.lcT >= 1) {
        this.letIn(NUM_LANES - 1, c, { force: true });
        this._startLaneChange(c, NUM_LANES - 1, 0.7);
        c.cheaterV = 0;
        out.cheaters.push(c);
      } else if (c.lane >= NUM_LANES - 2 && !c.isWall) {
        c.bumpJolt = 1; c.brakeT = Math.max(c.brakeT, 0.5);
        out.startled.push(c);
      }
    }
    return out;
  }

  // 압정 사거리 안의 잔챙이 빌런 (앞쪽, 같은/옆 차선)
  miniTarget(player) {
    let best = null, bd = Infinity;
    for (const c of this.cars) {
      const m = c.mini;
      if (!m || m.done) continue;
      const ds = c.s - player.s;
      if (ds < -3 || ds > 26) continue;
      if (Math.abs(c.x - player.x) > LANE_W * 1.2) continue;
      if (ds < bd) { bd = ds; best = c; }
    }
    return best;
  }

  // 잔챙이 피격. 반환: 'hit' | 'down'
  miniHit(c, dmg) {
    const m = c.mini;
    if (!m || m.done) return null;
    m.hp -= dmg;
    c.bumpJolt = 0.6;
    if (m.hp > 0) return 'hit';
    m.done = true;
    c.alive = false;
    c.brakeT = 2.5;
    c.hazardUntil = this.time + 4;
    if (c.isCheater && c.lane === SHOULDER_LANE) { this.letIn(NUM_LANES - 1, c); this._startLaneChange(c, NUM_LANES - 1, 0.9); c.cheaterV = 0; }
    if (c.miniMarker) { c.mesh.remove(c.miniMarker); c.miniMarker = null; }
    return 'down';
  }

  // 빌런 바로 뒤 몇 대 (짜증 말풍선용)
  carsBehindFront(n = 6, range = 35) {
    return this.cars.filter((c) => !c.released && !c.isWall && !c.isCheater && this.frontLine - c.s < range && this.frontLine - c.s > 0).slice(0, n);
  }

  // 콘·낙하물을 날려버림 → 장애물 제거, 날아갈 조각 위치 반환
  smash(o) {
    const i = this.obstacles.indexOf(o);
    if (i < 0) return null;
    this.obstacles.splice(i, 1);
    const pieces = [];
    o.mesh.updateMatrixWorld(true);
    for (const ch of [...o.mesh.children]) {
      const p = ch.getWorldPosition(new ch.position.constructor());
      pieces.push({ obj: ch, pos: p });
    }
    return { group: o.mesh, pieces };
  }

  jolt(car) { if (car) car.bumpJolt = 1; }
  countReleased() { return this.releasedCount; }
}
