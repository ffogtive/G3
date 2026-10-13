// 교통 시뮬레이션: IDM(지능형 차간거리 모델) 기반 차량 추종 + 정체 클러스터 + 칼치기 + 해방 물결.
import {
  laneX, LANE_W, NUM_LANES, NPC_KINDS, NPC_COLORS_MONO, NPC_COLORS_POP, TUNE, OPP_LANE_X,
} from './config.js';
import { buildVehicle, setBrake, setHazard, setHeadlights } from './vehicles.js';

// 결정적 난수 (스테이지마다 같은 배치)
export function mulberry32(a) {
  return function () {
    a |= 0; a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const LANE_HALF_OCC = LANE_W / 2 - 0.6;

// 엔티티 e(x,w)가 차선 i를 점유하는가
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

let CAR_ID = 1;

export class Traffic {
  constructor(scene) {
    this.scene = scene;
    this.cars = [];
    this.opp = [];
    this.buckets = Array.from({ length: NUM_LANES }, () => []);
    this.time = 0;
    this.frontLine = 0;
    this.frontV = 0;
    this.arenaGap = 30;
    this.released = false;
    this.releasedCount = 0;
    this.onReleased = null;   // (car) => void
    this.onCutIn = null;      // (car) => void
    this.night = false;
  }

  clear() {
    for (const c of this.cars) this.scene.remove(c.mesh);
    for (const c of this.opp) this.scene.remove(c.mesh);
    this.cars.length = 0;
    this.opp.length = 0;
    this.released = false;
    this.releasedCount = 0;
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
      brakeT: 0, brakeOn: false, hazardUntil: 0, hazardOn: false,
      released: false, releaseAt: Infinity, vFree: 30,
      isWall: false, nextLcAt: 6 + rng() * 16,
      bumpJolt: 0, yaw: 0,
      ...extra,
    };
    mesh.position.set(car.x, 0, -s);
    if (this.night) setHeadlights(mesh, true);
    this.scene.add(mesh);
    this.cars.push(car);
    return car;
  }

  // 정체 생성. villains: [{s, x, w, len, laneSet:Set}], playerStart: {s, lane}
  spawnJam(stage, villains, playerStart, rng, night = false) {
    this.clear();
    this.night = night;
    this.rng = rng;
    const sFront = Math.max(...villains.map((v) => v.s));
    this.frontLine = sFront;
    this.frontV = stage.jamSpeed;
    this.jamSpeed = stage.jamSpeed;
    const density = stage.density || 1;
    const tail = playerStart.s - 70;
    const jamHead = sFront - this.arenaGap;
    this.sTail = tail;
    this.sHead = jamHead;

    // 원흉이 점유하지 않는 차선에 "나란히 막는 벽" 차량
    const villainLanes = new Set();
    for (const v of villains) for (let i = 0; i < NUM_LANES; i++) if (occupies(v, i)) villainLanes.add(i);
    if (stage.attacks && stage.attacks.zigzag) { villainLanes.add(0); villainLanes.add(1); villainLanes.add(2); }
    for (let l = 0; l < NUM_LANES; l++) {
      if (villainLanes.has(l)) continue;
      const kind = rng() < 0.25 ? 'truck' : pickWeighted(rng, NPC_KINDS.filter(([k]) => k !== 'bus'));
      const c = this._makeCar(rng, kind, l, sFront - 7 - rng() * 1.5, stage.jamSpeed);
      c.isWall = true;
      c.wallOffset = 7 + rng() * 1.5 + (c.len - 4.5) / 2;
    }

    // 차선별 클러스터 배치 (앞→뒤)
    // 기본: 랜덤 간격(가끔 2대 묶음). 너무 촘촘하면 차선 변경이 불가능해 진행이 막힌다 (시뮬로 검증: tools/sim)
    const cMin = stage.clusterMin ?? 1, cMax = stage.clusterMax ?? 1;
    const gMin = stage.gapMin ?? 12, gMax = stage.gapMax ?? 28;
    for (let l = 0; l < NUM_LANES; l++) {
      // 차선마다 선두 위치를 엇갈리게 (선두가 일렬로 막지 않도록)
      let cursor = jamHead - rng() * 14 - l * 3;
      let clusterLeft = cMin + Math.floor(rng() * (cMax - cMin + 1));
      while (cursor > tail) {
        const kind = pickWeighted(rng, NPC_KINDS);
        // 길이를 알기 위해 먼저 빌드
        const tmp = this._makeCar(rng, kind, l, 0, stage.jamSpeed * 0.8);
        const s = cursor - tmp.len / 2;
        // 플레이어 시작 위치 근처는 비워둔다
        if (l === playerStart.lane && Math.abs(s - playerStart.s) < tmp.len / 2 + 9) {
          this.scene.remove(tmp.mesh); this.cars.pop();
          cursor = playerStart.s - 10;
          continue;
        }
        tmp.s = s;
        tmp.mesh.position.z = -s;
        let gap;
        clusterLeft--;
        if (clusterLeft <= 0) {
          gap = (gMin + rng() * (gMax - gMin)) / density;
          clusterLeft = cMin + Math.floor(rng() * (cMax - cMin + 1) * Math.min(1.4, density));
        } else {
          gap = 2.0 + rng() * 1.2;
        }
        cursor = s - tmp.len / 2 - gap;
      }
    }

    // 반대편 차로 (뻥 뚫려서 쌩쌩)
    for (let i = 0; i < 26; i++) {
      const j = Math.floor(rng() * 4);
      const kind = pickWeighted(rng, NPC_KINDS);
      const mono = rng() < 0.7;
      const pal = mono ? NPC_COLORS_MONO : NPC_COLORS_POP;
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

  // 차선 버킷 구축 (s 오름차순)
  _buildBuckets(extra) {
    const B = this.buckets;
    for (const b of B) b.length = 0;
    const add = (e) => {
      for (let i = 0; i < NUM_LANES; i++) if (occupies(e, i)) B[i].push(e);
    };
    for (const c of this.cars) add(c);
    for (const e of extra) if (e) add(e);
    for (const b of B) b.sort((a, b2) => a.s - b2.s);
  }

  // 엔티티 e 의 전방 선행 차량 (점유 차선들 중 가장 가까운 것)
  leaderOf(e) {
    let best = null, bestGap = Infinity;
    for (let i = 0; i < NUM_LANES; i++) {
      if (!occupies(e, i)) continue;
      const b = this.buckets[i];
      // 이진 탐색 대신 선형 (차선당 ~40대)
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

  // 특정 차선/구간에 무언가 있는가 (차선 변경 판단용)
  laneBlocked(lane, sMin, sMax, exclude) {
    for (const o of this.buckets[lane]) {
      if (o === exclude) continue;
      if (o.s + o.len / 2 > sMin && o.s - o.len / 2 < sMax) return o;
    }
    return null;
  }

  // 차선 lane 에서 s 앞쪽 가장 가까운 엔티티와의 간격
  gapAhead(lane, s, exclude) {
    let best = Infinity, who = null;
    for (const o of this.buckets[lane]) {
      if (o === exclude) continue;
      const rear = o.s - o.len / 2;
      if (rear > s && rear - s < best) { best = rear - s; who = o; }
    }
    return { gap: best, who };
  }

  release(time, waveSpeed = TUNE.releaseWaveSpeed) {
    this.released = true;
    this.releaseTime = time;
    const front = this.frontLine;
    const [lo, hi] = TUNE.releaseSpeed;
    for (const c of this.cars) {
      c.releaseAt = time + Math.max(0, front - c.s) / waveSpeed + (c.isWall ? 0 : 0.15);
      c.vFree = lo + this.rng() * (hi - lo) - (c.kind === 'truck' || c.kind === 'bus' ? 5 : 0);
    }
  }

  // ctx: { dt, time, player, villains:[...], phase, allowCutIn }
  update(dt, ctx) {
    this.time = ctx.time;
    const player = ctx.player;
    const villains = ctx.villains || [];
    const alive = villains.filter((v) => v.alive);
    if (alive.length) {
      this.frontLine = Math.max(...alive.map((v) => v.s));
      this.frontV = alive[0].v;
    }
    const extra = [player, ...alive];
    this._buildBuckets(extra);

    const t = ctx.time;
    const jamV = this.jamSpeed;
    const rng = this.rng;

    // 랜덤 급정거 이벤트 (브레이크 물결)
    if (!this.released && rng() < dt * 0.7) {
      const cand = this.cars.filter((c) => !c.isWall && c.s > player.s && c.s < player.s + 90);
      if (cand.length) cand[Math.floor(rng() * cand.length)].brakeT = 0.7 + rng() * 0.8;
    }

    // 고무줄 보조: 플레이어가 ~1.8초 이상 갇혀 있으면 옆 차선 차들이 치고 나가 틈을 만든다.
    // (모든 차선 앞에 차가 있는 '계단식 벽'은 흔하다 — 시뮬로 확인. 막힘은 잠깐의 답답함으로만)
    if (!this.released && ctx.phase === 'jam') this._breakWallForPlayer(ctx.dt ?? 1 / 60, player);

    for (const c of this.cars) {
      // 해방 시작
      if (!c.released && t >= c.releaseAt) {
        c.released = true;
        c.hazardUntil = t + 1.05;
        this.releasedCount++;
        if (this.onReleased) this.onReleased(c);
      }

      // 목표 속도
      let v0, T, s0, aMax;
      if (c.released) {
        v0 = c.vFree; T = 0.55; s0 = 2.2; aMax = 4.2;
      } else if (c.isWall) {
        // 원흉 옆에서 나란히 (pace)
        const target = this.frontLine - c.wallOffset;
        v0 = Math.max(0, this.frontV + (target - c.s) * 0.8);
        T = 0.5; s0 = 1.5; aMax = 3.0;
      } else {
        // 차선 단위 stop & go: 같은 차선은 같이 움직여 간격 구조가 유지된다 (평균은 원흉보다 약간 느림)
        const lf = 0.25 + 0.75 * (0.5 + 0.5 * Math.sin(t * 0.42 + c.lane * 1.9));
        // 최고치도 원흉보다 느리게 → 선두가 가상벽에 일렬로 붙어 '얼어붙는' 상태를 막는다 (시뮬 검증)
        v0 = jamV * c.personal * lf * 0.9;
        T = 0.55; s0 = 1.6; aMax = 1.8;
      }
      if (c.pullT > 0 && !c.released) { c.pullT -= dt; v0 = Math.max(v0, jamV * 2.8); aMax = 3.0; }
      if (c.brakeT > 0) { c.brakeT -= dt; v0 = 0.01; }

      // IDM
      const L = this.leaderOf(c);
      let gap = Infinity, dv = 0, lv = 0;
      if (L) { gap = L.gap; lv = L.car.v; dv = c.v - lv; }
      // 해방 전에는 앞 정체선(가상의 벽)을 넘지 못함
      if (!c.released && !c.isWall) {
        const wallS = this.frontLine - this.arenaGap;
        const g2 = wallS - (c.s + c.len / 2);
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
      // 겹침 방지
      if (L && gap < 0.25 && L.car !== player) {
        c.v = Math.min(c.v, Math.max(0, lv));
      }

      // NPC 차선 변경 (자연스럽게) + 칼치기
      if (c.lcT < 1) {
        c.lcT = Math.min(1, c.lcT + dt / c.lcDur);
        const e = c.lcT * c.lcT * (3 - 2 * c.lcT);
        const xFrom = laneX(c.laneFrom), xTo = laneX(c.laneTo);
        const nx = xFrom + (xTo - xFrom) * e;
        c.yaw = -Math.atan2((nx - c.x) / Math.max(dt, 1e-4), Math.max(2, c.v)) * 0.8;
        c.x = nx;
        if (c.lcT >= 1) { c.lane = c.laneTo; c.yaw = 0; }
      } else if (!c.isWall && !c.released && t > c.nextLcAt && Math.abs(c.s - player.s) > 12) {
        c.nextLcAt = t + 14 + rng() * 16;
        const dir = rng() < 0.5 ? -1 : 1;
        const tl = c.lane + dir;
        if (tl >= 0 && tl < NUM_LANES && this._safeToEnter(c, tl, 4)) this._startLaneChange(c, tl, 2.2);
      }

      // 차체 연출
      if (c.bumpJolt > 0) c.bumpJolt = Math.max(0, c.bumpJolt - dt * 3);
      const m = c.mesh;
      m.position.x = c.x;
      m.position.z = -c.s;
      m.rotation.y = c.yaw;
      if (m.userData.body) m.userData.body.rotation.x = -c.bumpJolt * 0.12 + Math.max(-0.05, Math.min(0.05, -acc * 0.006));

      // 브레이크등: 정체 중엔 대부분 켜짐 (빨간 바다)
      const wantBrake = !c.released && (acc < -0.25 || c.v < 1.6 || c.brakeT > 0 || Math.sin(t * 1.3 + c.phase) > 0.2);
      if (wantBrake !== c.brakeOn) { c.brakeOn = wantBrake; setBrake(m, wantBrake); }
      // 비상등 (해방 감사 깜빡깜빡)
      const hz = t < c.hazardUntil && ((t - c.hazardUntil) % 0.5 + 0.5) % 0.5 < 0.27;
      if (hz !== c.hazardOn) { c.hazardOn = hz; setHazard(m, hz); }
    }

    // 칼치기 이벤트 (플레이어 앞으로 끼어들기)
    if (ctx.allowCutIn && player.v > 6 && t > (this.nextCutIn || 0)) {
      this.nextCutIn = t + 4.5 + rng() * 3.5;
      this._tryCutIn(player);
    }

    // 반대편
    const focus = ctx.focusS ?? player.s;
    for (const c of this.opp) {
      c.s -= c.v * dt;
      if (c.s < focus - 130) c.s = focus + 280 + rng() * 160;
      c.mesh.position.z = -c.s;
    }
  }

  _breakWallForPlayer(dt, player) {
    if (player.v < 3 && player.mode === 'jam') this.stuckT = (this.stuckT || 0) + dt;
    else this.stuckT = Math.max(0, (this.stuckT || 0) - dt * 2);
    if (this.stuckT < (this.stuckLimit || 1.8)) return;
    this.stuckT = 0;
    // 옆 차선 중 '플레이어 뒤꽁무니 기준 앞차가 가장 먼' 차선을 연다
    let best = -1, bestGap = -Infinity;
    for (const d of [-1, 1]) {
      const l = player.lane + d;
      if (l < 0 || l >= NUM_LANES) continue;
      const g = this.gapAhead(l, player.s - player.len / 2 - 3, player).gap;
      if (g > bestGap) { bestGap = g; best = l; }
    }
    if (best < 0) return;
    let n = 0;
    for (const o of this.buckets[best]) {
      if (!this.cars.includes(o) || o.isWall || o.released) continue;
      if (o.s > player.s - 5 && o.s < player.s + 22) { o.pullT = 3.2; n++; }
    }
    // 내 차선 앞차도 살짝 앞으로 (경적 안 눌러도 숨통)
    const { who } = this.gapAhead(player.lane, player.s, player);
    if (who && this.cars.includes(who) && !who.isWall) who.pullT = Math.max(who.pullT || 0, 1.5);
    this.assists = (this.assists || 0) + 1;
  }

  _safeToEnter(c, tl, margin) {
    const b = this.buckets[tl];
    for (const o of b) {
      if (o === c) continue;
      const ahead = (o.s - o.len / 2) - (c.s + c.len / 2);
      const behind = (c.s - c.len / 2) - (o.s + o.len / 2);
      if (ahead > -0.1 && ahead < margin) return false;
      if (behind > -0.1 && behind < margin + Math.max(0, o.v - c.v) * 1.5) return false;
      if (ahead <= -0.1 && behind <= -0.1) return false; // 겹침
    }
    return true;
  }

  _startLaneChange(c, tl, dur) {
    c.laneFrom = c.lane; c.laneTo = tl; c.lcT = 0; c.lcDur = dur;
    c.lane = tl; // 목표 차선 기준으로 추종
  }

  _tryCutIn(player) {
    const pl = player.lane;
    const cands = [];
    for (const c of this.cars) {
      if (c.isWall || c.released || c.lcT < 1) continue;
      if (Math.abs(c.lane - pl) !== 1) continue;
      const d = c.s - player.s;
      if (d < 7 || d > 15) continue;
      // 플레이어 차선에 들어갈 자리
      const { gap } = this.gapAhead(pl, player.s + player.len / 2, player);
      if (gap < d + c.len + 2) continue;
      cands.push(c);
    }
    if (!cands.length) return;
    const c = cands[Math.floor(this.rng() * cands.length)];
    this._startLaneChange(c, pl, 0.75);
    c.v = Math.max(c.v, 3);
    if (this.onCutIn) this.onCutIn(c);
  }

  // 경적: 바로 앞 차가 옆 차선 틈으로 비켜준다 (원흉은 절대 안 비킴)
  // 반환: { car, moved: boolean } | null
  honk(player, range = 16) {
    const { gap, who } = this.gapAhead(player.lane, player.s + player.len / 2 - 0.5, player);
    if (!who || gap > range || !who.mesh || who.isWall || who.released) return null;
    if (who.isVillain || !this.cars.includes(who)) return { car: who, moved: false, villain: true };
    if (who.lcT < 1) return { car: who, moved: true };
    const opts = [who.lane - 1, who.lane + 1].filter((l) => l >= 0 && l < NUM_LANES);
    // 더 넓은 쪽 우선
    opts.sort((a, b) => this.gapAhead(b, who.s, who).gap - this.gapAhead(a, who.s, who).gap);
    for (const tl of opts) {
      if (this._safeToEnter(who, tl, 1.6)) { this._startLaneChange(who, tl, 0.85); who.nextLcAt = this.time + 6; return { car: who, moved: true }; }
    }
    return { car: who, moved: false };
  }

  // 플레이어 추돌 시 상대 차 반응
  jolt(car) { car.bumpJolt = 1; }

  countReleased() { return this.releasedCount; }
}
