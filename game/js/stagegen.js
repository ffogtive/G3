// 스테이지 생성기: 리서치 카탈로그(villain_catalog.json) → 게임 스테이지 설정
//
// 가설: 100개를 손으로 만들지 않는다. 빌런 1종 = (이동 템플릿 + 공격 템플릿 + 차종 + 도로/시간대 + 난이도)로
//       기계적으로 매핑하면, 엔진 템플릿 십수 종만으로 100 스테이지가 서로 다르게 느껴진다.
//
// 카탈로그 항목 스키마: docs/VILLAIN_CATALOG.md (id, chapter, name_ko, title, setting, road, time, movement, attacks[],
//   vehicle, jam_causality, intro_line, taunts[], defeat_line, violation, fine_krw, difficulty, new_assets[])

// 고속도로 노선번호 (방패 배지) + 방향별 표지판 도시
const ROUTES = {
  경부: [1, [['부산', '387km'], ['대전', '128km']]], 남해: [10, [['순천', '58km'], ['진주', '12km']]],
  광주대구: [12, [['대구', '160km'], ['함양', '40km']]], 서해안: [15, [['목포', '241km'], ['서산', '38km']]],
  익산포항: [20, [['포항', '120km'], ['상주', '30km']]], 호남: [25, [['광주', '96km'], ['논산', '20km']]],
  당진영덕: [30, [['영덕', '210km'], ['청주', '45km']]], 중부: [35, [['통영', '201km'], ['이천', '12km']]],
  통영대전: [35, [['통영', '110km'], ['진주', '58km']]], 평택제천: [40, [['제천', '96km'], ['안성', '18km']]],
  중부내륙: [45, [['창원', '230km'], ['충주', '40km']]], 영동: [50, [['강릉', '164km'], ['원주', '52km']]],
  중앙: [55, [['춘천', '95km'], ['안동', '60km']]], 서울양양: [60, [['양양', '150km'], ['춘천', '62km']]],
  동해: [65, [['삼척', '88km'], ['동해', '20km']]], 수도권제1순환: [100, [['일산', '24km'], ['판교', '15km']]],
};
const URBAN = ['올림픽대로', '강변북로', '동부간선도로', '내부순환로', '서부간선도로', '경인고속도로'];

function routeOf(road) {
  for (const k of Object.keys(ROUTES)) if (road.includes(k)) return { key: k, route: ROUTES[k][0], signs: ROUTES[k][1] };
  return null;
}

// 차종 매핑 (카탈로그 vehicle → vehicles.js kind)
const VEHICLE_KINDS = new Set(['compact', 'sedan', 'suv', 'taxi', 'van', 'pickup1t', 'truck', 'bus', 'police', 'villainSedan', 'villainTruck', 'villainSuv', 'villainPhone', 'tractor']);
function vehicleKind(v, movement) {
  if (VEHICLE_KINDS.has(v)) return v;
  const s = String(v || '');
  const rules = [
    [/경운기|트랙터|농기계/, 'tractor'], [/폰|휴대|셀카|유튜|방송/, 'villainPhone'], [/버스|관광/, 'bus'],
    [/택시/, 'taxi'], [/1톤|포터|봉고|용달|과일|배추|이삿짐/, 'pickup1t'], [/수박|화물|트럭|레미콘|덤프|탱크로리|트레일러|25톤|화물차/, 'villainTruck'],
    [/SUV|suv|지프|대형 ?승용/, 'villainSuv'], [/캠핑|카라반|승합|밴|탑차|택배/, 'van'], [/경찰|순찰/, 'police'],
    [/경차|소형/, 'compact'], [/세단|승용|외제|슈퍼카|스포츠/, 'villainSedan'],
  ];
  for (const [re, k] of rules) if (re.test(s)) return k;
  if (movement === 'zigzag') return 'villainPhone';
  if (movement === 'wide_load' || movement === 'spill_emitter') return 'villainTruck';
  return 'villainSedan';
}

// 공격 템플릿 매핑 (카탈로그 → 엔진)
const ATTACK_MAP = {
  highbeam: 'highbeam', selfie_flash: 'highbeam', horn_blast: 'horn', horn: 'horn', lunge: 'lunge', brake_check: 'lunge',
  throw: 'throw', roll: 'roll', spill: 'roll', swerve: 'swerve', zigzag: 'zigzag', smoke: 'smoke', summon: 'roll', argue_block: 'throw',
};
function throwItemFor(e, kind) {
  const t = `${e.name_ko} ${e.title} ${e.vehicle} ${(e.new_assets || []).join(' ')}`;
  if (/수박|과일/.test(t)) return 'watermelon';
  if (/경운기|건초|벌초|농/.test(t) || kind === 'tractor') return 'hay';
  if (/닭/.test(t)) return 'chicken';
  if (/담배|꽁초/.test(t)) return 'butt';
  if (/폰|휴대|셀카|방송|유튜/.test(t) || kind === 'villainPhone') return 'phone';
  return 'cup';
}

const SKY_OF = { day: 'day', sunset: 'sunset', morning: 'morning', night: 'night', rain: 'rain', snow: 'snow', fog: 'fog' };
const COLORS = [0xd9c9a3, 0x1d1f22, 0xe85d9a, 0x2f6fd6, 0xd8342c, 0x3a9d5d, 0xe0a526, 0x6d4bb8, 0xf4f4f2, 0x8b5a3c];

function rngFor(id) { let a = id * 2654435761 >>> 0; return () => ((a = (a * 1664525 + 1013904223) >>> 0) / 4294967296); }

// 빌런 배치 (이동 템플릿 → villains[] + frontRow + 특수 플래그)
function layout(e, kind, diff, rng) {
  const hpBase = Math.round(110 + diff * 26);
  const name = e.name_ko || e.title;
  const color = COLORS[Math.floor(rng() * COLORS.length)];
  const one = (lane, extra = {}) => ({ kind, lane, hp: hpBase, name, color, ...extra });
  const trucks = (lanes) => Object.fromEntries(lanes.map((l, i) => [l, i % 3 === 1 ? 'bus' : (rng() < 0.3 ? 'pickup1t' : 'truck')]));
  switch (e.movement) {
    case 'side_by_side': {
      const n = diff >= 7 ? 3 : 2;
      const vs = Array.from({ length: n }, (_, i) => one(i, { hp: Math.round(hpBase * 0.62), name: `${name} ${['1호', '2호', '3호'][i]}`, color: COLORS[(i * 3 + Math.floor(rng() * 10)) % COLORS.length] }));
      return { villains: vs, frontRow: trucks([...Array(4).keys()].filter((l) => l >= n)) };
    }
    case 'straddle': case 'wide_load':
      return { villains: [one(0.5, { hp: Math.round(hpBase * 1.15) })], frontRow: trucks([3]) };
    case 'zigzag': case 'tailgate_racer':
      return { villains: [one(1, { kind: kind === 'villainSedan' ? 'villainPhone' : kind })], frontRow: trucks([3]), zig: true };
    case 'stopped_block': case 'rubberneck':
      return { villains: [one(0, { hp: Math.round(hpBase * 0.6) }), one(1, { hp: Math.round(hpBase * 0.6), name: `${name}(상대)`, color: COLORS[(Math.floor(rng() * 10) + 4) % 10] })], frontRow: trucks([2, 3]), stopped: true };
    case 'slow_convoy':
      return { villains: [one(0, { hp: Math.round(hpBase * 0.55) }), one(1, { hp: Math.round(hpBase * 0.55), name: `${name} 일행` })], frontRow: trucks([2, 3]) };
    case 'shoulder_cheater':
      return { villains: [one(3)], frontRow: trucks([0, 1, 2]) };
    case 'merge_blocker':
      return { villains: [one(1)], frontRow: trucks([0, 2, 3]), stopped: true };
    case 'spill_emitter':
      return { villains: [one(1, { kind: 'villainTruck' })], frontRow: trucks([0, 2, 3]) };
    case 'pedestrian_group':
      // 보행자 모델 전까지: 차를 세워두고 내린 사람들(말풍선) 컨셉 → 정차 차량 2대
      return { villains: [one(0, { hp: Math.round(hpBase * 0.6) }), one(1, { hp: Math.round(hpBase * 0.6), name: `${name}(일행)` })], frontRow: trucks([2, 3]), stopped: true };
    case 'lane_cruise': default:
      return { villains: [one(e.lane ?? 0)], frontRow: trucks([1, 2, 3].filter((l) => l !== (e.lane ?? 0))) };
  }
}

function attacksFor(e, lay, diff) {
  const out = {};
  for (const a of e.attacks || []) { const k = ATTACK_MAP[a]; if (k) out[k] = (out[k] || 0) + 2; }
  if (lay.zig) out.zigzag = Math.max(out.zigzag || 0, 3);
  if (lay.stopped) { delete out.lunge; delete out.swerve; out.throw = (out.throw || 0) + 2; }
  if (lay.villains.length > 1) delete out.swerve;
  if (!Object.keys(out).length) Object.assign(out, { horn: 2, highbeam: 1, throw: 1 });
  if (diff >= 6 && !out.lunge && !lay.stopped) out.lunge = 1;
  return out;
}

function shoulderFor(diff, rng, setting) {
  const n = 2 + Math.floor(diff / 4);
  const kinds = ['cones', 'debris', 'breakdown'];
  const counts = { cones: 0, debris: 0, breakdown: 0 };
  for (let i = 0; i < n; i++) counts[kinds[Math.floor(rng() * (diff >= 5 ? 3 : 2))]]++;
  if (/공사/.test(setting || '')) counts.cones += 2;
  const list = Object.entries(counts).filter(([, c]) => c > 0);
  list.push(['cheater', diff >= 4 ? 2 : 1]);
  return list;
}

// 카탈로그 항목 1개 → 스테이지
export function stageFromEntry(e) {
  const diff = Math.max(1, Math.min(10, e.difficulty || 3));
  const rng = rngFor(e.id || 1);
  const kind = vehicleKind(e.vehicle, e.movement);
  const lay = layout(e, kind, diff, rng);
  const isBoss = (e.id % 10) === 0;
  if (isBoss) for (const v of lay.villains) v.hp = Math.round(v.hp * 1.6);
  // 도로 이름
  let road = String(e.road || '');
  let r = routeOf(road);
  let highway, direction;
  if (r) {
    const m = road.match(/(\S+고속도로)\s*(.*)/);
    highway = m ? m[1] : `${r.key}고속도로`;
    direction = (m && m[2]) || r.signs[0][0] + ' 방향';
  } else if (/도심|시내|간선|대로|강변|올림픽/.test(road + e.setting)) {
    highway = URBAN.find((u) => road.includes(u)) || URBAN[(e.id || 0) % URBAN.length];
    direction = road.replace(highway, '').trim() || (rng() < 0.5 ? '잠실 방향' : '여의도 방향');
    r = { route: highway === '올림픽대로' ? 88 : highway === '경인고속도로' ? 120 : '시', signs: [['잠실', '6km'], ['여의도', '11km']] };
  } else {
    const keys = Object.keys(ROUTES);
    const k = keys[(e.id * 7) % keys.length];
    r = { key: k, route: ROUTES[k][0], signs: ROUTES[k][1] };
    highway = road && /도로|길|IC|JC|톨게이트|터널|교/.test(road) ? road.split(' ')[0] : `${k}고속도로`;
    direction = r.signs[0][0] + ' 방향';
  }
  const jamSpeed = lay.stopped ? 1.2 : 2.4;
  const stage = {
    id: e.id,
    chapter: e.chapter || Math.ceil(e.id / 10),
    highway, direction, route: r.route,
    title: e.title || e.name_ko,
    villainLine: e.intro_line ? `"${String(e.intro_line).replace(/^"|"$/g, '')}"` : '"..."',
    blurb: e.jam_causality || '',
    cause: e.name_ko || e.title,
    violation: e.violation || '도로교통법 위반',
    fine: e.fine_krw || 30000,
    sky: SKY_OF[e.time] || 'day',
    jamLength: Math.min(215, 150 + diff * 6.5),
    displayKm: +(1.4 + diff * 0.45 + rng() * 0.8).toFixed(1),   // 실제 병목 정체 규모 (1.8~6.6km)
    density: 1 + diff * 0.008,
    jamSpeed,
    villains: lay.villains.map((v) => ({ ...v, stopped: !!lay.stopped })),
    frontRow: lay.frontRow,
    shoulder: shoulderFor(diff, rng, e.setting),
    attacks: attacksFor(e, lay, diff),
    throwItem: throwItemFor(e, kind),
    attackInterval: [Math.max(1.3, 2.7 - diff * 0.12), Math.max(2.0, 3.8 - diff * 0.14)],
    taunts: (e.taunts && e.taunts.length ? e.taunts : ['비켜 비켜~']).slice(0, 6),
    defeatLine: e.defeat_line || '',
    signs: r.signs,
    vms: (e.jam_causality || '').slice(0, 14) || '안전운전 하세요',
    boss: isBoss,
    difficulty: diff,
    newAssets: e.new_assets || [],
  };
  return stage;
}

// 카탈로그 전체 → 스테이지 배열 (원래 손으로 만든 스테이지는 같은 id 자리에 우선 사용)
export function buildStages(catalog, handmade = []) {
  const byId = new Map(handmade.map((s) => [s.id, s]));
  const out = [];
  for (const e of (catalog?.villains || []).slice().sort((a, b) => a.id - b.id)) {
    const hm = byId.get(e.id);
    out.push(hm ? { ...hm, chapter: e.chapter || 1 } : stageFromEntry(e));
  }
  return out.length ? out : handmade;
}
