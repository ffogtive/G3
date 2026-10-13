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

// '남해 해안도로'·'영동대로' 같은 부분 일치를 막기 위해 'XX고속도로' 전체로 매칭, 긴 이름 먼저(중부내륙 > 중부)
const ROUTE_KEYS = Object.keys(ROUTES).sort((a, b) => b.length - a.length);
function routeOf(road) {
  for (const k of ROUTE_KEYS) if (road.includes(k + '고속도로')) return { key: k, route: ROUTES[k][0], signs: ROUTES[k][1] };
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

// 공격 템플릿 매핑 (카탈로그 → 엔진). summon(벽 소환)은 엔진에 없으므로 굴리기로 대체
const ATTACK_MAP = {
  highbeam: 'highbeam', selfie_flash: 'highbeam', horn_blast: 'horn', horn: 'horn', lunge: 'lunge', brake_check: 'lunge',
  throw: 'throw', roll: 'roll', spill: 'roll', swerve: 'swerve', zigzag: 'zigzag', smoke: 'smoke', summon: 'roll', argue_block: 'throw',
};
function throwItemFor(e, kind) {
  if (e.throw_item) return e.throw_item;   // 카탈로그 값 우선 (box·tire·cone·tack 포함)
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
const clamp = (x, a, b) => Math.max(a, Math.min(b, x));

// 이동 템플릿 → 엔진 플래그
const STOPPED_MV = new Set(['stopped_block', 'rubberneck', 'pedestrian_group']);
const ZIG_MV = new Set(['zigzag', 'tailgate_racer']);
const WIDE_MV = new Set(['straddle', 'wide_load']);
const mvOf = (m) => String(m || 'lane_cruise').replace(/^NEW:/, '');

// 빌런 배치: 카탈로그 lane·count를 그대로 쓴다 (빌런이 막은 차로 = 정체의 원인, 나머지 차로 = 앞줄 저속차 벽)
function layout(e, kind, diff, rng) {
  const mv = mvOf(e.movement);
  const hpBase = Math.round(110 + diff * 26);
  const name = e.name_ko || e.title;
  const zig = ZIG_MV.has(mv);
  const stopped = STOPPED_MV.has(mv);
  let count = clamp(Math.round(e.count ?? (mv === 'side_by_side' || mv === 'slow_convoy' || stopped ? 2 : 1)), 1, 3);
  let lane = e.lane ?? (mv === 'shoulder_cheater' ? 3 : 0);
  if (WIDE_MV.has(mv) && Number.isInteger(lane)) lane = clamp(lane + 0.5, 0.5, 2.5);
  if (!Number.isInteger(lane) && !WIDE_MV.has(mv)) lane = Math.floor(lane);
  if (zig) { count = 1; lane = clamp(Math.round(lane), 1, 2); }   // 지그재그는 중심 차로 ±1을 휘젓는다
  if (!Number.isInteger(lane)) count = 1;                          // 차선 물기는 한 대가 두 차로를 막는다
  const base = Number.isInteger(lane) ? clamp(lane, 0, 4 - count) : lane;
  const hpMul = count === 1 ? (WIDE_MV.has(mv) ? 1.15 : 1) : count === 2 ? 0.62 : 0.45;
  const villains = Array.from({ length: count }, (_, i) => ({
    kind: mv === 'spill_emitter' && !/^villain|truck|pickup1t|tractor/.test(kind) ? 'villainTruck' : kind,
    lane: base + i,
    hp: Math.round(hpBase * hpMul),
    name: count === 1 ? name : `${name} ${['1호', '2호', '3호'][i]}`,
    color: i === 0 ? COLORS[Math.floor(rng() * COLORS.length)] : COLORS[(i * 3 + Math.floor(rng() * 10)) % COLORS.length],
    stopped, zig,
  }));
  // 막힌 차로 계산 → 나머지는 앞줄(화물차·버스) 벽
  const blocked = new Set();
  for (const v of villains) {
    if (zig) { blocked.add(lane - 1); blocked.add(lane); blocked.add(lane + 1); }
    else if (Number.isInteger(v.lane)) blocked.add(v.lane);
    else { blocked.add(Math.floor(v.lane)); blocked.add(Math.ceil(v.lane)); }
  }
  const free = [0, 1, 2, 3].filter((l) => !blocked.has(l));
  const frontRow = Object.fromEntries(free.map((l, i) => [l, i % 3 === 1 ? 'bus' : (rng() < 0.3 ? 'pickup1t' : 'truck')]));
  return { villains, frontRow, zig, zigCenter: zig ? lane : undefined, stopped, slow: mv === 'merge_blocker' || mv === 'slow_convoy' };
}

function attackMap(list, lay, diff) {
  const out = {};
  for (const a of list || []) { const k = ATTACK_MAP[a]; if (k) out[k] = (out[k] || 0) + 2; }
  if (!Object.keys(out).length) return out;           // 공격 없음(구조형) = 빈 표 그대로
  if (lay.zig) out.zigzag = Math.max(out.zigzag || 0, 2);
  if (lay.stopped) { delete out.lunge; delete out.swerve; out.throw = (out.throw || 0) + 1; }
  if (lay.villains.length > 1) delete out.swerve;
  if (diff >= 6 && !out.lunge && !lay.stopped) out.lunge = 1;
  return out;
}

// 보스·엘리트 2~3페이즈: HP 비율에서 공격표·이동 성격 교체 (차 대수 변경은 엔진 미지원 → 공격표로 표현)
function phasesFor(e, diff, baseZig = false) {
  if (!Array.isArray(e.phases) || !e.phases.length) return null;
  return e.phases.map((ph) => {
    const mv = mvOf(ph.movement);
    // 페이즈 지그재그는 스테이지 자체가 지그재그 배치(중심 ±1 차로에 벽 없음)일 때만. 아니면 공격표만 바뀐다
    const lay = { zig: ZIG_MV.has(mv) && !!baseZig, stopped: STOPPED_MV.has(mv), villains: { length: ph.count || 1 } };
    return {
      hp: ph.hp ?? 0.5,
      attacks: attackMap(ph.attacks, lay, diff),
      stopped: lay.stopped,
      zig: lay.zig,
      slow: mv === 'merge_blocker' || mv === 'slow_convoy',
      label: PHASE_LABEL[mv] || '2페이즈!',
    };
  });
}
const PHASE_LABEL = {
  side_by_side: '나란히 벽 세우기!', stopped_block: '차 세우고 시비!', slow_convoy: '일행 줄 세우기!', merge_blocker: '합류 막기!',
  spill_emitter: '적재물 와르르!', straddle: '두 차로 점령!', tailgate_racer: '칼치기 폭주!', lane_cruise: '1차선 고수!', zigzag: '갈지자 폭주!',
};

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

// 도로 표기: 고속도로는 노선 방패 + 방향, 국도는 'N호선' 방패, 도심·교량은 도로명 그대로 (임의 노선을 섞지 않는다)
function roadInfo(e, rng) {
  const road = String(e.road || '').trim();
  const km = () => `${Math.round(3 + rng() * 25)}km`;
  const nat = road.match(/^국도\s*(\d+)호선\s*(.*)$/);   // 국도 먼저 ('국도 77호선 남해 해안도로'가 남해고속도로로 잡히지 않게)
  const r = nat ? null : routeOf(road);
  if (r) {
    // 'X톨게이트(경부고속도로)'처럼 괄호 안이 노선이면: 노선 = 괄호 안, 방향 칸 = 괄호 밖 장소
    const paren = road.match(/^(.*?)\((\S+고속도로)\)\s*(.*)$/);
    const m = paren ? null : road.match(/(\S+고속도로)\s*(.*)/);
    const highway = paren ? paren[2] : m ? m[1] : `${r.key}고속도로`;
    const direction = (paren ? [paren[1], paren[3]].filter(Boolean).join(' ') : m && m[2]) || r.signs[0][0] + ' 방향';
    // 표지판 도시는 진행 방향과 맞춘다 ('서울 방향'인데 '부산 387km' 금지)
    let signs = r.signs;
    const dm = direction.match(/^(\S+) 방향/);
    if (dm && dm[1] !== r.signs[0][0] && dm[1] !== r.signs[1][0]) signs = [[dm[1], km()], ['졸음쉼터', `${Math.round(2 + rng() * 6)}km`]];
    else if (dm && dm[1] === r.signs[1][0]) signs = [r.signs[1], ['졸음쉼터', `${Math.round(2 + rng() * 6)}km`]];
    return { highway, direction, route: r.route, signs };
  }
  if (nat) {
    const rest = nat[2].replace(/\s*구간$/, '').trim();
    const place = (rest.split(/[\s~]/)[0] || '읍내').replace(/[()]/g, '');
    return { highway: `국도 ${nat[1]}호선`, direction: rest || '시내 방향', route: +nat[1], signs: [[place, km()], ['시내', km()]] };
  }
  // 첫 단어가 도로명(…로·대로·길·교·방조제)일 때만 '도로명 / 구간'으로 나누고, 아니면 장소 이름 전체를 쓴다
  const clean = road.replace(/\s*\(.*\)\s*$/, '').trim() || '시내 도로';
  const urbanHit = URBAN.find((u) => clean.startsWith(u));
  const first = clean.split(/\s+/)[0];
  let highway = clean, rest = '';
  if (urbanHit) { highway = urbanHit; rest = clean.slice(urbanHit.length).trim(); }
  else if (/(로|길|교|방조제)$/.test(first) && clean.length > first.length) { highway = first; rest = clean.slice(first.length).trim(); }
  if (rest === '도로') rest = '';
  const direction = rest || (URBAN.includes(highway) ? (rng() < 0.5 ? '잠실 방향' : '여의도 방향') : '시내 방향');
  const route = highway === '올림픽대로' ? 88 : highway === '경인고속도로' ? 120 : '시';
  return { highway, direction, route, signs: [['시청', km()], ['외곽순환', km()]] };
}

// 카탈로그 항목 1개 → 스테이지
export function stageFromEntry(e) {
  const diff = clamp(e.difficulty_f ?? e.difficulty ?? 3, 1, 10);
  const rng = rngFor(e.id || 1);
  const kind = vehicleKind(e.vehicle, e.movement);
  const lay = layout(e, kind, diff, rng);
  const isBoss = e.boss ?? ((e.id % 10) === 0);
  const hpMul = isBoss ? 1.6 : e.elite ? 1.3 : 1;
  for (const v of lay.villains) v.hp = Math.round(v.hp * hpMul);
  const { highway, direction, route, signs } = roadInfo(e, rng);
  // 정체 길이: 리서치 문장에 km가 있으면 그 값(사실 근거), 없으면 난이도로 추정
  // '시속 10km'(속도)·'3km째'(주행 거리)는 정체 길이가 아니다. 숫자 중간부터 잡히지 않게 앞에 숫자·점 금지
  const kmHit = String(e.jam_causality || '').match(/(?<!시속\s*)(?<![\d.])(\d+(?:\.\d+)?)\s*km(?!\/h|째)/);
  const kmFromText = kmHit ? +kmHit[1] : NaN;
  const displayKm = kmFromText >= 0.5 && kmFromText <= 15 ? kmFromText : +(1.4 + diff * 0.45 + rng() * 0.8).toFixed(1);
  const jamSpeed = lay.stopped ? 1.2 : lay.slow ? 1.8 : 2.4;
  const honkOnly = Array.isArray(e.weapons) && e.weapons.length > 0 && e.weapons.every((w) => w === 'honk');
  const fine = e.fine_krw ?? 30000;
  const stage = {
    id: e.id,
    chapter: e.chapter || Math.ceil(e.id / 10),
    highway, direction, route,
    title: e.title || e.name_ko,
    villainLine: e.intro_line ? `"${String(e.intro_line).replace(/^"|"$/g, '')}"` : '"..."',
    blurb: e.jam_causality || '',
    cause: e.name_ko || e.title,
    violation: e.violation || '도로교통법 위반',
    fine,                                  // 카드 표시 (실제 범칙금·벌금)
    payout: e.payout_krw ?? fine,          // 포상금 기준 (게임값)
    card: e.card || '고지서',
    sky: SKY_OF[e.time] || 'day',
    jamLength: Math.min(215, 150 + diff * 6.5),
    displayKm,
    density: 1 + diff * 0.008,
    jamSpeed,
    villains: lay.villains,
    frontRow: lay.frontRow,
    zig: lay.zig, zigCenter: lay.zigCenter,
    shoulder: shoulderFor(diff, rng, e.setting),
    attacks: attackMap(e.attacks, lay, diff),
    phases: phasesFor(e, diff, lay.zig),
    honkOnly,
    throwItem: throwItemFor(e, kind),
    attackInterval: [Math.max(1.3, 2.7 - diff * 0.12), Math.max(2.0, 3.8 - diff * 0.14)],
    taunts: (e.taunts && e.taunts.length ? e.taunts : ['비켜 비켜~']).slice(0, 6),
    defeatLine: e.defeat_line || '',
    signs,
    vms: (e.jam_causality || '').split('→')[0].trim().slice(0, 14) || '안전운전 하세요',
    boss: isBoss,
    elite: !!e.elite,
    difficulty: diff,
    newAssets: e.new_assets || [],
    wrongWay: mvOf(e.movement) === 'wrong_way',
  };
  return stage;
}

// 손제작 스테이지의 frontRow는 빈 차로가 있을 수 있다 → 빌런이 안 막는 모든 차로에 저속차 벽을 채워 '보이지 않는 벽'을 없앤다
function fillFrontRow(hm) {
  const blocked = new Set();
  for (const v of hm.villains || []) {
    if (Number.isInteger(v.lane)) blocked.add(v.lane); else { blocked.add(Math.floor(v.lane)); blocked.add(Math.ceil(v.lane)); }
  }
  if (hm.zig || hm.attacks?.zigzag) { const c = hm.zigCenter ?? 1; [c - 1, c, c + 1].forEach((l) => blocked.add(l)); }
  const fr = { ...(hm.frontRow || {}) };
  for (const l of [0, 1, 2, 3]) {
    if (blocked.has(l)) delete fr[l];
    else if (!fr[l]) fr[l] = 'truck';
  }
  return fr;
}

// 카탈로그 전체 → 스테이지 배열. 손으로 만든 스테이지는 handmade_id가 가리키는 카탈로그 자리에 들어가고,
// 금액·카드·챕터·보스 정보는 카탈로그(리서치) 값을 쓴다.
export function buildStages(catalog, handmade = []) {
  const byId = new Map(handmade.map((s) => [s.id, s]));
  const out = [];
  for (const e of (catalog?.villains || []).slice().sort((a, b) => a.id - b.id)) {
    const hm = e.handmade_id != null ? byId.get(e.handmade_id) : null;
    if (hm) {
      const g = stageFromEntry(e);
      out.push({
        ...hm, id: e.id, chapter: g.chapter, handmadeId: hm.id, frontRow: fillFrontRow(hm),
        zig: hm.zig ?? !!hm.attacks?.zigzag, zigCenter: hm.zigCenter ?? (hm.attacks?.zigzag ? 1 : undefined),
        fine: g.fine, payout: g.payout, card: g.card, violation: g.violation,
        defeatLine: g.defeatLine, boss: g.boss, elite: g.elite, phases: g.phases, difficulty: g.difficulty,
      });
    } else out.push(stageFromEntry(e));
  }
  return out.length ? out : handmade;
}
