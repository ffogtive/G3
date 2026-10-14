// 정체 구간 튜닝 시뮬레이터 (렌더링 없음)
// 사용법: node --import ./tools/sim/register.mjs tools/sim/jam.mjs [variantsJSON] [--no-honk]
//  예) node --import ./tools/sim/register.mjs tools/sim/jam.mjs '{"base":{},"wide":{"gapMin":14,"gapMax":30}}'
// 출력: 스테이지별(시드 2개) 원흉 도달 시간 / 평균속도 / 추돌 수 / 차량 수
// 가설 검증용: "정체 구간은 20~40초 안에 돌파 가능해야 한다"
import * as THREE from 'three';
import { STAGES, NUM_LANES, laneX } from '../../game/js/config.js';
import { Traffic, mulberry32 } from '../../game/js/traffic.js';
import { Player } from '../../game/js/player.js';

const HONK = !process.argv.includes('--no-honk');
const variants = JSON.parse(process.argv.slice(2).find((a) => a.startsWith('{')) || '{"current":{}}');

function run(stageIdx, over, seed) {
  const scene = new THREE.Scene();
  const stage = { ...STAGES[stageIdx], ...over };
  const t = new Traffic(scene); const p = new Player(scene);
  const frontS = stage.jamLength + 30;
  const villains = stage.villains.map((v) => ({ s: frontS, x: laneX(v.lane), w: 2.1, len: 4.8, v: stage.jamSpeed, vNominal: stage.jamSpeed, alive: true, isVillain: true }));
  t.spawnJam(stage, villains, { s: 0, lane: 2 }, mulberry32(stage.id * 1000 + seed));
  p.reset(0, 2);
  let time = 0, bumps = 0, next = 0, honkAt = 0, stuck = 0, dropUntil = 0; const dt = 1 / 30;
  while (time < 150) {
    time += dt; for (const v of villains) v.s += v.v * dt;
    let left = false, right = false, brake = false;
    if (time > next) {
      const front = p.s + p.len / 2;
      const gapIn = (l) => t.gapAhead(l, front - (l === p.lane ? 0 : p.len + 0.8), p).gap;
      const cur = gapIn(p.lane); let best = p.lane, bg = cur;
      for (const d of [-1, 1]) {
        const l = p.lane + d; if (l < 0 || l >= NUM_LANES) continue;
        if (t.laneBlocked(l, p.s - p.len / 2 - 0.6, p.s + p.len / 2 + 0.6, p)) continue;
        const g = gapIn(l); if (g > bg + 2) { bg = g; best = l; }
      }
      if (cur < 22 && best !== p.lane) { if (best < p.lane) left = true; else right = true; next = time + 0.2; stuck = 0; }
      else if (cur < 3 + p.v * 0.35) brake = true;
      // 양옆이 막혀 따라가기만 하면 잠깐 브레이크로 뒤로 빠져 틈을 찾는다
      if (cur < 6 && p.v < 3.5) stuck += 0.2; else stuck = Math.max(0, stuck - 0.1);
      if (stuck > 1.5) { dropUntil = time + 0.7; stuck = 0; }
      if (HONK && cur < 9 && time > honkAt) { honkAt = time + 0.6; t.honk(p); }
    }
    if (time < dropUntil) brake = true;
    if (left || right) p.requestLane(left ? -1 : 1, t);
    bumps += p.update(dt, { mode: 'jam', traffic: t, brake }).length;
    t.update(dt, { dt, time, player: p, villains, phase: 'jam', allowCutIn: false });
    if (p.s > frontS + villains[0].v * time - 29) break;
  }
  return `${time.toFixed(0)}s/v${(p.s / time).toFixed(1)}/b${bumps}/a${t.assists || 0}`;
}
console.log('stage →', STAGES.map((s) => s.id + ':' + s.title).join(' | '));
for (const [name, over] of Object.entries(variants)) {
  console.log(name.padEnd(12), STAGES.map((_, i) => [7, 11].map((sd) => run(i, over, sd)).join(' ')).join(' | '));
}
