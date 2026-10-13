// 빌런 시그니처 행동 모듈 (v0.4) — docs/V04_SPEC.md
//
// 가설: 판 차별화 = '보이는' 시그니처 행동 × 그 행동이 만드는 정체 모양 × 판별 요령.
//       공통 엔진(boss.js)은 그대로 두고, 판마다 다른 움직임·단서·약점·카운터만 모듈로 끼운다.
//
// 모듈 인터페이스 (전부 선택):
//   fight: { gap, lockAt }        플레이어가 설 자리(빌런 기준 s 오프셋)와 '정면/측면 고정' 판정 위치
//   release: { openLane }         해방 때 먼저 열리는 차로 (피해 차로)
//   attacks: { kind: weight }     공격표 대체 (attack()이 처리하는 고유 공격 포함)
//   behindAttack: string|null     플레이어가 뒤(접근 중)일 때 공격 (null = 안 함)
//   init(B, stage)                스테이지 시작
//   motion(B, v, dt, ctx)         매 프레임 빌런 움직임·단서 (targetLanePos·v.v 등 조작)
//   attack(B, kind, v, ctx)       고유 공격이면 처리하고 true
//   vulnerable(B, v, ctx)         받는 피해 배율 (취약 창)
//   onHonk(B, v, ctx)             플레이어가 빌런에게 경적
//   onDeath(B, v, ctx)            퇴치 순간 연출 훅
//   stats(B)                      결과 화면 추가 줄
// ctx: { time, player, events[], laneFree(l, v), sound(name, v, opts), traffic }
import * as VEH from '../vehicles.js';
import { laneX } from '../config.js';

const clamp = (x, a, b) => Math.max(a, Math.min(b, x));

// ── 1-5 좀비 깜빡이: 왼쪽 깜빡이를 판 내내 켜 두고 안 들어온다 ───────────────────────────
const blinker_liar = {
  fight: { gap: 1.5, lockAt: -1.5 },        // 측면전: 1차로에서 나란히
  release: { openLane: 0 },                  // 피해 차로(1차로)부터 연다
  attacks: { cutin: 3, horn: 1 },
  behindAttack: null,                        // 접근 중엔 공격 안 함 (깜빡이만 깜빡깜빡)
  init(B) {
    B.sig = { blinks: 0, laneChanges: 0, prevOn: false, nextNote: 30 };
    for (const v of B.villains) Object.assign(v, { fakeT: 3 + Math.random() * 2, fake: 0, hyper: 0, flip: 0, exposed: 0, cut: null });
  },
  motion(B, v, dt, ctx) {
    const t = B.time;
    v.flip = Math.max(0, v.flip - dt);
    v.exposed = Math.max(0, v.exposed - dt);
    // 깜빡이: 평소 정상 템포(1.5Hz), 진짜 끼어들기 직전 0.8초만 하이퍼(3Hz). 경적 맞으면 0.5초 오른쪽(개그)
    const side = v.flip > 0 ? 'right' : 'left';
    const on = VEH.setBlinker?.(v.mesh, side, t, { tempo: v.hyper > 0 ? 2 : 1, halo: 1.8, wet: B.stage.sky === 'rain' });
    if (on && !B.sig.prevOn) {
      B.sig.blinks++;
      ctx.sound?.('blink', v, { volume: v.hyper > 0 ? 0.9 : 0.45 });
      if (B.sig.blinks >= B.sig.nextNote) { B.sig.nextNote += 40; ctx.events.push({ type: 'sigToast', text: `깜빡 ${B.sig.blinks}회째 · 차로 변경 ${B.sig.laneChanges}회` }); }
    }
    B.sig.prevOn = on;
    if (!v.cut) {
      // 페이크: 앞바퀴는 그대로, 코만 1차로 쪽으로 0.18차로 0.6초 → 복귀 (템포도 그대로)
      v.fakeT -= dt;
      if (v.fakeT <= 0 && v.fake <= 0) { v.fake = 0.6; v.fakeT = 5 + Math.random() * 2; }
      if (v.fake > 0) {
        v.fake -= dt;
        v.targetLanePos = v.homeLane - 0.18 * Math.sin(Math.PI * clamp((0.6 - v.fake) / 0.6, 0, 1));
      } else v.targetLanePos = v.homeLane;
      v.hyper = 0;
      return;
    }
    // 진짜 끼어들기: 하이퍼 0.8초 + 앞바퀴 꺾임 → 진입 → 2초 뒤 복귀
    const c = v.cut;
    c.t += dt;
    if (c.phase === 'tele') {
      v.hyper = Math.max(0.01, 0.8 - c.t);
      VEH.setSteer?.(v.mesh, c.dir * 0.5);
      if (c.t >= 0.8) { c.phase = 'go'; c.t = 0; v.targetLanePos = c.lane; B.sig.laneChanges++; }
    } else if (c.phase === 'go') {
      v.hyper = 0;
      VEH.setSteer?.(v.mesh, 0);
      const p = ctx.player;
      if (!c.hit && p && p.lane === c.lane && Math.abs(p.s - v.s) < (v.len + p.len) / 2 + 0.3 && p.invuln <= 0) {
        c.hit = true;
        ctx.events.push({ type: 'playerHit', cause: 'cutin', tier: 'heavy', text: '깜빡이 진짜였어?!' });
      }
      if (c.t > 0.7 && !c.hit && !c.judged) {
        c.judged = true;
        // 헛스윙: 내가 반 차 뒤로 빠져 있었으면 그가 빈자리로 들어와 뒷바퀴가 내 앞에 노출 (×2)
        v.exposed = 1.6;
        ctx.events.push({ type: 'sigPop', v, text: '헛스윙! 뒷바퀴 노출 ×2', kind: 'score' });
      }
      if (c.t > 2.0) { v.targetLanePos = v.homeLane; c.phase = 'back'; c.t = 0; }
    } else if (c.t > 0.9) {
      v.cut = null;
    }
  },
  attack(B, kind, v, ctx) {
    if (kind !== 'cutin') return false;
    if (v.cut || v.flip > 0) return true;          // 경적 개그 0.5초 동안은 진짜 진입 불가 = 안전한 사격 창
    const pl = ctx.player.lane;
    const lane = [v.homeLane - 1, v.homeLane + 1].includes(pl) ? pl : v.homeLane - 1;
    if (lane < 0 || (ctx.laneFree && !ctx.laneFree(lane, v))) return true;
    v.cut = { phase: 'tele', t: 0, lane, dir: lane < v.homeLane ? 1 : -1 };
    ctx.events.push({ type: 'sigPop', v, text: '딸깍딸깍딸깍!!', kind: 'warn' });
    return true;
  },
  vulnerable(B, v) { return v.exposed > 0 ? 2 : v.fake > 0 ? 1.5 : 1; },   // 페이크 중 명중 = 역관광 ×1.5
  onHonk(B, v, ctx) {
    if (v.flip > 0) return;
    v.flip = 0.5;
    ctx.events.push({ type: 'sigPop', v, text: '어? 오른쪽?', kind: 'score' });
  },
  onDeath(B, v, ctx) {
    VEH.setBlinker?.(v.mesh, null);
    ctx.events.push({ type: 'sigFinal', v, text: '딸깍. …드디어 꺼졌다' });
  },
  stats(B) { return [{ label: '깜빡이', value: `점등 ${B.sig.blinks}회 · 차로 변경 ${B.sig.laneChanges}회` }]; },
};


// ── 1-6 범퍼키스 장인: '초보운전' 차 뒤 0.6m에 자석처럼 붙는다 (지그재그 아님) ───────────────
// 단서: 상향등 2연타 + 빵빵, 피해차가 톡 → 0.3초 늦게 급제동(유령정체 증폭파), 다시 '찰싹'
// 요령: 붙어 있으면 압정이 안 맞는다 → 차로를 바꿔 0.5초 지연 창에 쏘기 → 35% 이하에서 암행순찰차에게 넘기기
function body(B, kind, lane, s, v) {
  const mesh = VEH.buildVehicle(kind, {});
  B.scene.add(mesh);
  (B.sigMeshes ||= []).push(mesh);
  const ud = mesh.userData;
  const b = { mesh, kind, lane, x: laneX(lane), s, v, len: ud.length || 3.8, w: ud.width || 1.7, isVictim: true, alive: true };
  mesh.position.set(b.x, 0, -s);
  (B.sigBodies ||= []).push(b);
  return b;
}
function moveBody(b, dt) {
  b.s += b.v * dt;
  b.x += (laneX(b.lane) - b.x) * Math.min(1, dt * 4);
  b.mesh.position.set(b.x, 0, -b.s);
}
const tailgater = {
  fight: { gap: 0.6 + 4.3, lockAt: 4.2, sameLane: true },   // 내가 앞, 그가 내 뒤 0.6m (차 길이 반씩 포함)
  attacks: { tap: 3, highbeam: 1 },
  interval: [2.2, 3.2],
  behindAttack: null,
  immuneText: '너무 붙어서 안 맞아!',
  init(B, stage) {
    const v = B.villains[0];
    const J = stage.jamSpeed || 2.4;
    const victim = body(B, 'beginner', v.homeLane, v.baseS + v.len / 2 + 0.6 + 1.9, J);
    VEH.setHazard?.(victim.mesh, false);
    B.sig = { J, victim, rescued: false, unmarked: null, target: 'victim', tapT: 3 + Math.random() * 2, flashT: 1.2, passT: 10 + Math.random() * 2, brake: 0, react: -1, windowT: 0, mirrorT: 0, gapSum: 0, gapN: 0, last: 'victim', handed: false };
  },
  motion(B, v, dt, ctx) {
    const S = B.sig, t = B.time, p = ctx.player, J = S.J;
    S.windowT = Math.max(0, S.windowT - dt);
    // 피해차(초보운전): 겁먹고 3~5초마다 브레이크 '톡'
    const vic = S.victim;
    if (vic && vic.alive) {
      if (!S.rescued) {
        S.tapT -= dt;
        if (S.tapT <= 0) { S.tapT = 3 + Math.random() * 2; vic.tap = 0.4; S.react = 0.3; ctx.events.push({ type: 'sigPop', v: vic, text: 'ㅠㅠ 초보예요', kind: 'warn' }); VEH.setHazard?.(vic.mesh, true); }
        vic.tap = Math.max(0, (vic.tap || 0) - dt);
        vic.v = vic.tap > 0 ? J * 0.6 : J;
        if (vic.tap <= 0) VEH.setHazard?.(vic.mesh, Math.floor(t * 2) % 2 === 0 && S.brake > 0);
      } else {
        // 구출됨: 2차로로 빠져 천천히 뒤로 → 사라짐
        vic.lane = Math.min(3, v.homeLane + 1); vic.v = J * 0.6;
        VEH.setHazard?.(vic.mesh, Math.floor(t * 3) % 2 === 0);
        if (p.s - vic.s > 40) { vic.alive = false; vic.mesh.visible = false; }
      }
      moveBody(vic, dt);
    }
    // 0.3초 늦은 급제동 → 1차로 뒤로 커지는 파동(유령정체)
    if (S.react > 0) { S.react -= dt; if (S.react <= 0) { S.brake = 0.6; ctx.sound?.('brakeScreech', v, { volume: 0.35 }); ctx.traffic?.emitBrakeWave(v.homeLane, v.baseS - v.len / 2 - 1.5, 0.8, { amp: 1.18, speed: 5, hold: 0.7 }); } }
    S.brake = Math.max(0, S.brake - dt);
    v.nose = S.brake > 0 ? Math.min(1, v.nose + dt * 6) : v.nose;
    // 따라붙을 대상: 피해차 → (교대 후) 플레이어 → (35% 이하에서 넘기면) 암행순찰차
    let lead = null, gapWant = 0.6;
    if (S.target === 'victim' && vic && vic.alive && !S.rescued) lead = vic;
    else if (S.target === 'unmarked' && S.unmarked) lead = S.unmarked;
    else if (S.target === 'player' && p) {
      lead = { s: p.s, len: p.len, lane: p.lane, v: p.v };
      // 차로 미러링 0.5초 지연 → 그동안 간격이 4~6m로 벌어짐 = 사격 창
      if (Math.round(v.targetLanePos) !== p.lane) {
        if (S.mirrorT <= 0) { S.mirrorT = 0.5; S.windowT = 0.75; ctx.events.push({ type: 'sigPop', v, text: '지금! 사격 창', kind: 'score' }); }
        S.mirrorT -= dt;
        if (S.mirrorT <= 0 && p.lane <= 3) v.targetLanePos = p.lane;
        gapWant = 5;
      } else S.mirrorT = 0;
    }
    if (lead) {
      const want = lead.s - lead.len / 2 - gapWant - v.len / 2;
      let vv = S.brake > 0 ? J * 0.3 : Math.max(0, Math.min(J * 3, (lead.v ?? J) + (want - v.baseS) * 2.5));
      v.baseS += (vv - v.vNominal) * dt;            // boss.update가 이미 vNominal만큼 전진시켰으므로 차이만
      v.s = v.baseS + v.lungeOff;
      const g = (lead.s - lead.len / 2) - (v.baseS + v.len / 2);
      if (g < 1.2 && S.brake <= 0) { S.gapSum += g; S.gapN++; }
    }
    // 상향등 2연타 + 빵빵 (1.5초 주기)
    S.flashT -= dt;
    const ph = -S.flashT;
    VEH.setHeadlights?.(v.mesh, (ph > 0 && ph < 0.12) || (ph > 0.24 && ph < 0.36) || !!B.night);
    if (S.flashT < -0.4) { S.flashT = 1.5; if (Math.random() < 0.4) ctx.events.push({ type: 'sigPop', v, text: '번쩍번쩍 빵빵!', kind: 'warn' }); }
    // 우측 추월 시도(10~12초마다, 실패하고 복귀) — 접근 중에만
    if (S.target === 'victim') {
      S.passT -= dt;
      if (S.passT <= 0 && S.passT > -1.2) v.targetLanePos = v.homeLane + 0.55;
      else if (S.passT <= -1.2) { S.passT = 10 + Math.random() * 2; v.targetLanePos = v.homeLane; }
    }
    // 범퍼 툭 (예고 0.5초: 부릉 + 코 숙임 → 같은 차로·1.5m 안이면 30)
    if (v.tap) {
      v.tap.t += dt;
      v.nose = Math.min(1, v.tap.t / 0.5) * 0.7;
      if (v.tap.t > 0.5 && !v.tap.done) {
        v.tap.done = true;
        const gp = (p.s - p.len / 2) - (v.s + v.len / 2);
        if (p.lane === Math.round(v.lanePos) && gp < 1.6 && p.invuln <= 0) ctx.events.push({ type: 'playerHit', cause: 'tap', tier: 'heavy', text: '범퍼 툭!' });
      }
      if (v.tap.t > 0.8) v.tap = null;
    }
    // 35% 이하: 암행순찰차가 앞 1차로에 합류 → 내가 비켜 주면 습관대로 그 뒤에 붙음 → 확정 마무리
    if (S.target === 'player' && !S.unmarked && B.hpFrac() <= 0.35) {
      S.unmarked = body(B, 'unmarked', v.homeLane, p.s + 25, J * 0.85);
      S.unmarked.isVictim = false;
      ctx.events.push({ type: 'sigToast', text: '앞에 진회색 세단이 끼어들었다… 비켜 주면?' });
    }
    const U = S.unmarked;
    if (U) {
      moveBody(U, dt);
      if (S.target === 'player') {
        const ahead = U.s - p.s;
        if (p.lane !== U.lane && ahead > 2 && ahead < 14 && Math.abs(U.s - v.s) < 16) { S.target = 'unmarked'; v.targetLanePos = U.lane; S.handT = 1.4; ctx.events.push({ type: 'sigPop', v, text: '오 저 차 맛있겠다~', kind: 'warn' }); }
        else U.v = J * (ahead > 10 ? 0.7 : 1.0);
      } else if (S.target === 'unmarked' && !S.handed) {
        U.v = J;
        S.handT -= dt;
        if (S.handT <= 0) {
          S.handed = true;
          v.forceFinish = 'pullover';
          ctx.events.push({ type: 'sigPop', v: U, text: '암행순찰차입니다.', kind: 'crit' });
          ctx.events.push({ type: 'sigKill', v, text: '아…' });
          S.last = 'unmarked';
        }
      }
      if (S.handed || S.target === 'unmarked') VEH.setStrobe?.(U.mesh, S.handed ? t : null);
    }
  },
  choose(B) { return B.sig.target === 'player' ? (Math.random() < 0.65 ? 'tap' : 'highbeam') : null; },
  attack(B, kind, v, ctx) {
    if (kind !== 'tap') return false;
    if (!v.tap) { v.tap = { t: 0 }; ctx.sound?.('warn', v, { volume: 0.5 }); ctx.events.push({ type: 'sigPop', v, text: '부릉!', kind: 'warn' }); }
    return true;
  },
  vulnerable(B) { return B.sig.target === 'player' && B.sig.windowT <= 0 ? 0.12 : 1.3; },
  onHonk(B, v, ctx) {
    const S = B.sig, p = ctx.player, vic = S.victim;
    // 구출 교대: 2차로에서 피해차 옆에 붙어 경적 → 피해차가 2차로 내 뒤로 빠지고, 나는 그 앞 1차로로
    if (!S.rescued && vic && p.lane === vic.lane + 1 && Math.abs(p.s - vic.s) < 5) {
      S.rescued = true; S.target = 'none';
      ctx.events.push({ type: 'sigPop', v: vic, text: '감사합니다ㅠㅠ', kind: 'score' });
      ctx.events.push({ type: 'sigToast', text: '구출 교대! 이제 그 앞 1차로로 들어가세요' });
    }
  },
  onLock(B) { B.sig.target = 'player'; },
  onDeath(B, v, ctx) { ctx.events.push({ type: 'sigFinal', v, text: B.sig.handed ? '0.6m → ∞ (암행순찰차에 인계)' : '찰싹… 떨어졌다' }); },
  stats(B) {
    const S = B.sig;
    return [{ label: '평균 차간', value: `${S.gapN ? Math.max(0.3, S.gapSum / S.gapN).toFixed(1) : '0.6'}m · 마지막 상대 ${S.handed ? '암행순찰차' : '나'}` }];
  },
};

// ── 1-1 정속주행 김사장: 1차로에서 '정속 80' 고정, 공격도 메트로놈 박자 ─────────────────────
// 요령: 뒤차들의 상향등 릴레이가 꽂히는 순간(4초 주기) 1.5초 '눈부셔!' 경직 → 그때 몰아치기
const SEQ = ['highbeam', 'throw', 'horn', 'lunge'];
const occupy = {
  release: { openLane: 0 },
  interval: [3.0, 3.0],
  init(B) { B.sig = { seq: 0, relayT: 4, relay: null, stun: 0, cruiseT: 4, relays: 0 }; },
  motion(B, v, dt, ctx) {
    const S = B.sig;
    S.stun = Math.max(0, S.stun - dt);
    S.cruiseT -= dt;
    if (S.cruiseT <= 0) { S.cruiseT = 6 + Math.random() * 2; ctx.events.push({ type: 'sigPop', v, text: '정속 80 딱', kind: 'warn' }); }
    // 1차로 뒤차들의 상향등 릴레이 (멀리서 가까이 순서로)
    S.relayT -= dt;
    if (S.relayT <= 0 && !S.relay) {
      S.relayT = 4;
      const cars = (ctx.traffic?.cars || []).filter((c) => c.lane === v.homeLane && !c.released && c.s < v.s && c.s > v.s - 45).sort((a, b) => a.s - b.s);
      if (cars.length) S.relay = { t: 0, cars };
    }
    if (S.relay) {
      const R = S.relay;
      R.t += dt;
      R.cars.forEach((c, i) => { const k = R.t - i * 0.15; VEH.setHeadlights?.(c.mesh, k > 0 && k < 0.25); });
      if (R.t > R.cars.length * 0.15 + 0.3) {
        R.cars.forEach((c) => VEH.setHeadlights?.(c.mesh, !!B.night));
        S.relay = null; S.stun = 1.5; S.relays++;
        ctx.events.push({ type: 'sigPop', v, text: '눈부셔! (경직)', kind: 'score' });
      }
    }
    v.targetLanePos = v.homeLane;
  },
  choose(B) { const k = SEQ[B.sig.seq % SEQ.length]; B.sig.seq++; return k; },
  blocked(B) { return B.sig.stun > 0; },
  vulnerable(B) { return B.sig.stun > 0 ? 1.5 : 1; },
  onDeath(B, v, ctx) {
    VEH.setBlinker?.(v.mesh, 'right', true);
    ctx.events.push({ type: 'sigFinal', v, text: '어…? 2차선으로 갈게요… (깜빡이 사용 ✔)' });
  },
  stats(B) { return [{ label: '차로 변경', value: `0회 → 마지막에 1회 (깜빡이 ✔) · 상향등 릴레이 ${B.sig.relays}번` }]; },
};

export const BEHAVIORS = { blinker_liar, tailgater, occupy };
