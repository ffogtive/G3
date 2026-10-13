// 공유 설정 — 모든 모듈이 이 파일만 보고 좌표/치수/스테이지를 맞춘다.
//
// 좌표계 (meters):
//   s  = 도로 진행 방향 거리 (앞으로 갈수록 +). 월드 좌표로는 z = -s  (진행 방향 = -Z)
//   x  = 횡방향. 진행 방향을 바라볼 때 왼쪽이 -X.
//   y  = 위.  노면 y = 0.
//   1차선(lane 0)은 가장 왼쪽, 중앙분리대 바로 옆. lane 3 = 4차선(가장 오른쪽).

export const LANE_W = 3.6;
export const NUM_LANES = 4;
export const laneX = (i) => (i - (NUM_LANES - 1) / 2) * LANE_W; // lane0=-5.4 ... lane3=+5.4
export const ROAD_LEFT = -LANE_W * NUM_LANES / 2;   // -7.2 (1차선 왼쪽 끝 = 중앙분리대 쪽 차선 끝선)
export const ROAD_RIGHT = LANE_W * NUM_LANES / 2;   // +7.2 (4차선 오른쪽 끝선)
export const SHOULDER_W = 3.0;                       // 갓길 폭: x ∈ [7.2, 10.2]
export const MEDIAN_GAP = 0.6;                       // 차선 끝선 ~ 분리대 사이 여유
export const MEDIAN_W = 0.9;                         // 콘크리트 중앙분리대 폭
export const MEDIAN_X = ROAD_LEFT - MEDIAN_GAP - MEDIAN_W / 2; // 분리대 중심 x ≈ -8.25
// 반대편 차로 (서울 방향 등). 차량은 +Z 로(즉 s 감소 방향) 달린다. j=0 이 분리대에 가장 가까운 차선.
export const OPP_LANE_X = (j) => MEDIAN_X - MEDIAN_W / 2 - MEDIAN_GAP - LANE_W * (j + 0.5);
export const OPP_ROAD_LEFT = OPP_LANE_X(3) - LANE_W / 2; // 반대편 도로 바깥 끝 ≈ -23.25
export const SEG_LEN = 40;                           // 도로 세그먼트 길이 (s 방향)
export const SHOULDER_LANE = 4;                      // 갓길 = 가상의 5번째 차선 (laneX(4) = 9.0, 갓길 x∈[7.2,10.2])

export const sToZ = (s) => -s;
export const zToS = (z) => -z;

// 속도 변환
export const KMH = 1 / 3.6;           // km/h → m/s 곱셈 계수
export const toKmh = (ms) => ms * 3.6;

// 폰트 (Google Fonts: Black Han Sans, Jua). 캔버스 텍스처에도 이 문자열 사용.
export const FONT_DISPLAY = '"Black Han Sans", "Jua", "Apple SD Gothic Neo", "Malgun Gothic", sans-serif';
export const FONT_UI = '"Jua", "Apple SD Gothic Neo", "Malgun Gothic", sans-serif';

// 일반 차량 색 — 한국 도로는 흰/검/회/은색이 압도적. 가끔 원색.
export const NPC_COLORS_MONO = [0xf4f4f2, 0xf4f4f2, 0xe9ecef, 0x2b2d31, 0x1d1f22, 0x9aa1a9, 0xc3c8ce, 0x6b7179];
export const NPC_COLORS_POP = [0x2f6fd6, 0xd8342c, 0x3a9d5d, 0xe0a526, 0x6d4bb8, 0x8b5a3c, 0x16a4b5];
export const PLAYER_COLOR = 0xffc928; // 참교육 머신: 쨍한 노랑

// NPC 차종 출현 가중치
export const NPC_KINDS = [
  ['sedan', 30], ['compact', 14], ['suv', 20], ['taxi', 6], ['van', 6],
  ['pickup1t', 9], ['truck', 6], ['bus', 4],
];

// 시간대 프리셋
export const SKY = {
  day:    { top: 0x5fb8ff, bottom: 0xd8f0ff, fog: 0xcfeaff, fogNear: 120, fogFar: 420, sun: 0xfff4dc, sunI: 2.6, hemiSky: 0xbfe4ff, hemiGround: 0x8a9a6a, hemiI: 1.25, sunPos: [-40, 80, 30], night: false },
  sunset: { top: 0x5a6bd6, bottom: 0xffb27a, fog: 0xf3b48c, fogNear: 110, fogFar: 400, sun: 0xffc18a, sunI: 2.2, hemiSky: 0xffc9a0, hemiGround: 0x6a5a6a, hemiI: 1.1, sunPos: [-70, 35, -60], night: false },
  morning:{ top: 0x8fc9e8, bottom: 0xf2f6ee, fog: 0xe6efe9, fogNear: 70, fogFar: 330, sun: 0xfff1d6, sunI: 2.1, hemiSky: 0xdfeef2, hemiGround: 0x8a9a7a, hemiI: 1.35, sunPos: [50, 45, 40], night: false },
  night:  { top: 0x0b1030, bottom: 0x2a2f5c, fog: 0x1c2148, fogNear: 60, fogFar: 340, sun: 0x8fa6ff, sunI: 0.7, hemiSky: 0x4a5a9a, hemiGround: 0x1a1a2a, hemiI: 0.9, sunPos: [30, 60, 20], night: true },
  rain:   { top: 0x56626f, bottom: 0xa3aeb9, fog: 0x95a0ab, fogNear: 45, fogFar: 250, sun: 0xc9d4e0, sunI: 1.0, hemiSky: 0xaab6c4, hemiGround: 0x4a5560, hemiI: 1.2, sunPos: [-30, 70, 20], night: false, weather: 'rain' },
  snow:   { top: 0xaebdd0, bottom: 0xeef3f8, fog: 0xe3eaf1, fogNear: 45, fogFar: 250, sun: 0xffffff, sunI: 1.5, hemiSky: 0xe8f0ff, hemiGround: 0xc8d0dc, hemiI: 1.5, sunPos: [-40, 60, 30], night: false, weather: 'snow', ground: 0xeef2f6 },
  fog:    { top: 0xbfc8ce, bottom: 0xdde2e5, fog: 0xd5dbdf, fogNear: 14, fogFar: 120, sun: 0xffffff, sunI: 1.3, hemiSky: 0xe0e6ea, hemiGround: 0x8a9488, hemiI: 1.4, sunPos: [-40, 80, 30], night: false },
};

// ─────────────────────────────────────────────────────────────
// 스테이지: 매 스테이지 = 정체 → 원흉 발견 → 참교육 → 뻥 뚫림
// villains[].kind 는 vehicles.js buildVehicle kind 와 일치해야 함.
// 정체의 개연성: 빌런이 1차선(추월차선) 등을 막고, 나머지 차선은 frontRow(원래 느린 화물차·버스)가 나란히 →
//   아무도 추월 못 함 → 빌런 바로 뒤부터 빽빽한 정체. 플레이어는 갓길(긴급차량)로 맨 앞까지 간다.
// attacks (플레이어가 빌런 '앞'에서 싸움, 공격은 앞으로 날아옴):
//   'highbeam'(상향등: 차선 섬광) | 'horn'(경적 충격파) | 'lunge'(돌진) | 'throw'(직격 투척) | 'roll'(굴러오는 것)
//   'swerve'(차선 가로막기) | 'zigzag'(갈지자) | 'smoke'(매연)
// frontRow: { [lane]: kind } — 빌런 옆에 나란히 서서 '벽'이 되는 정상 저속 차량
// shoulder: 갓길 장애물 구성 [kind, count] — 'breakdown'(고장차+삼각대) | 'cones'(공사 콘) | 'debris'(낙하물) | 'cheater'(갓길 얌체)
export const STAGES = [
  {
    id: 1,
    highway: '경부고속도로',
    route: 1,              // 실제 고속도로 노선번호 (방패 배지)
    direction: '부산 방향',
    title: '1차선 정속주행러',
    villainLine: '"규정속도 지키는데 뭐가 문제죠?"',
    blurb: '추월차선(1차선)을 혼자 정속주행. 2~4차선은 화물차라 아무도 못 지나간다.',
    cause: '1차선 저속차량',
    violation: '지정차로 위반 (1차로 저속 점유)',
    fine: 40000,               // 범칙금(원) → 포상금 기준
    sky: 'day',
    jamLength: 170,          // 실제 시뮬 거리(m). 연출상 표시 거리는 displayKm
    displayKm: 2.4,
    density: 1.0,
    jamSpeed: 2.4,           // 정체 기본 속도 m/s (~9km/h)
    villainSpeedLabel: '정속 80km/h',
    villains: [
      { kind: 'villainSedan', lane: 0, hp: 140, name: '정속주행 김사장', color: 0xd9c9a3 },
    ],
    frontRow: { 1: 'bus', 2: 'truck', 3: 'truck' },
    shoulder: [['breakdown', 1], ['cones', 1], ['cheater', 1]],
    attacks: { highbeam: 2, horn: 2, lunge: 2, throw: 1 },
    throwItem: 'cup',
    attackInterval: [2.4, 3.6],
    taunts: ['규정속도 준수 중입니다~', '추월은 2차선으로 하세요', '1차선은 내 차선인데?', '왜 빵빵거려?', '난 안 급해~', '정속주행이 죄냐?'],
    signs: [['부산', '387km'], ['대전', '128km']],
    vms: '1차선은 추월차선입니다',
  },
  {
    id: 2,
    highway: '영동고속도로',
    route: 50,
    direction: '강릉 방향',
    title: '화물차 나란히 주행',
    villainLine: '"형님 먼저~ 아우 먼저~"',
    blurb: '25톤 두 대가 1·2차선을 나란히 막고 무전 수다 중. 3·4차선도 화물차 행렬.',
    cause: '화물차 병렬 주행',
    violation: '지정차로 위반 (화물차 1·2차로 병렬)',
    fine: 50000,               // 범칙금(원) → 포상금 기준
    sky: 'sunset',
    jamLength: 190,
    displayKm: 4.1,
    density: 1.0,
    jamSpeed: 2.4,
    villainSpeedLabel: '나란히 60km/h',
    villains: [
      { kind: 'villainTruck', lane: 0, hp: 120, name: '형님 트럭', color: 0x2f6fd6 },
      { kind: 'villainTruck', lane: 1, hp: 120, name: '아우 트럭', color: 0x3a9d5d },
    ],
    frontRow: { 2: 'truck', 3: 'pickup1t' },
    shoulder: [['breakdown', 1], ['debris', 2], ['cheater', 1]],
    attacks: { roll: 3, horn: 2, lunge: 1 },
    throwItem: 'watermelon',
    attackInterval: [2.0, 3.0],
    taunts: ['형님 먼저 가세요~', '아우 먼저 가~', '우린 나란히가 좋아', '수박 사세요~', '무전기 감도 좋고~'],
    signs: [['강릉', '164km'], ['원주', '52km']],
    vms: '화물차는 우측 차로로',
  },
  {
    id: 3,
    highway: '서해안고속도로',
    route: 15,
    direction: '목포 방향',
    title: '차선 물고 가는 SUV',
    villainLine: '"차선? 그게 뭐임?"',
    blurb: '1·2차선을 물고 달리다가 추월하려는 차가 오면 옆으로 막아버린다.',
    cause: '차선 걸침 주행',
    violation: '차로 통행방법 위반 (두 차로 걸침)',
    fine: 30000,               // 범칙금(원) → 포상금 기준
    sky: 'morning',
    jamLength: 200,
    displayKm: 3.0,
    density: 1.02,
    jamSpeed: 2.4,
    villainSpeedLabel: '두 차선 점유',
    villains: [
      { kind: 'villainSuv', lane: 0.5, hp: 200, name: '차선물기 대마왕', color: 0x1d1f22 },
    ],
    frontRow: { 3: 'truck' },
    shoulder: [['cones', 2], ['breakdown', 1], ['cheater', 1]],
    attacks: { swerve: 3, highbeam: 2, lunge: 1, throw: 1 },
    throwItem: 'cup',
    attackInterval: [2.0, 3.0],
    taunts: ['내 차 크잖아~', '두 칸이 편해', '깜빡이? 고장났어', '비켜 비켜~', '안 보여서 몰랐어'],
    signs: [['목포', '241km'], ['서산', '38km']],
    vms: '차선을 지켜주세요',
  },
  {
    id: 4,
    highway: '중부고속도로',
    route: 35,
    direction: '통영 방향',
    title: '폰 보며 지그재그',
    villainLine: '"ㅋㅋㅋ 잠만 이것만 보고"',
    blurb: '숏폼 보면서 1~3차선을 갈지자로. 무서워서 아무도 옆으로 못 지나간다.',
    cause: '휴대폰 보며 갈지자 운전',
    violation: '운전 중 휴대전화 사용',
    fine: 60000,               // 범칙금(원) → 포상금 기준
    sky: 'night',
    jamLength: 200,
    displayKm: 2.6,
    density: 1.04,
    jamSpeed: 2.4,
    villainSpeedLabel: '시속 ??km',
    villains: [
      { kind: 'villainPhone', lane: 1, hp: 220, name: '숏폼중독 드라이버', color: 0xe85d9a },
    ],
    frontRow: { 3: 'bus' },
    shoulder: [['breakdown', 1], ['debris', 2], ['cones', 1], ['cheater', 1]],
    attacks: { zigzag: 3, highbeam: 2, throw: 1, lunge: 1 },
    throwItem: 'phone',
    attackInterval: [1.8, 2.8],
    taunts: ['ㅋㅋㅋㅋ', '잠만 이것만', '어? 여기 차선이었어?', '좋아요 눌러주세요~', '구독과 알림설정!'],
    signs: [['통영', '201km'], ['이천', '12km']],
    vms: '운전 중 휴대폰 사용금지',
  },
  {
    id: 5,
    highway: '남해고속도로',
    route: 10,
    direction: '순천 방향',
    title: '1차선 경운기 (최종보스)',
    villainLine: '"허허, 젊은 것들이 급하긴"',
    blurb: '시속 15km 경운기가 1차선을 점령. 옆 차선은 벌초 가는 트럭 행렬.',
    cause: '1차선 경운기',
    violation: '고속도로 통행금지 위반 (농기계)',
    fine: 30000,               // 범칙금(원) → 포상금 기준
    sky: 'day',
    jamLength: 220,
    displayKm: 5.8,
    density: 1.05,
    jamSpeed: 2.4,
    villainSpeedLabel: '시속 15km',
    villains: [
      { kind: 'tractor', lane: 0, hp: 340, name: '전설의 경운기 할배', color: 0x3f8f3a },
    ],
    frontRow: { 1: 'pickup1t', 2: 'truck', 3: 'truck' },
    shoulder: [['cones', 2], ['debris', 2], ['breakdown', 1], ['cheater', 1]],
    attacks: { roll: 3, smoke: 2, throw: 1, horn: 1 },
    throwItem: 'hay',
    attackInterval: [1.7, 2.6],
    taunts: ['허허 급하긴~', '탈탈탈탈탈', '논에 물 대러 가는 길이여', '빵빵거리지 마라 귀 아프다', '옛날엔 다 이렇게 다녔어'],
    signs: [['순천', '58km'], ['진주', '12km']],
    vms: '저속차량 주의',
  },
];

// 해방 시 NPC들이 띄우는 말풍선
export const THANKS_LINES = ['감사합니다!!', '형님 최고!', '사이다!!', '10년 묵은 체증이…', '속이 다 시원하네', '이제 좀 살겠다', '드디어!!', '참교육 ㅇㅈ', '비상등 깜빡깜빡', '복 받으실 거예요'];
export const BUMP_LINES = ['아 뭐야!', '조심 좀!', '빵빵!!', '거리 유지!', '어휴'];
export const CUTIN_LINES = ['깜빡이 안 켜고 칼치기!', '끼어들기 ㅡㅡ', '말도 없이?!'];
export const YIELD_LINES = ['네네 가세요~', '급하시네 ㅎ', '에휴 먼저 가요', '비켜드림', '형님 먼저!'];
export const NOWAY_LINES = ['어디로 비켜!', '나도 막혔어!', '틈이 없어요!', '빵빵해도 소용없음'];
export const LETIN_LINES = ['들어오세요~', '긴급차량 먼저!', '어서 가세요!', '저 놈 좀 혼내줘요!'];
export const FRONT_RAGE_LINES = ['1차선 좀 비켜!!', '추월 좀 하자!!', '빵빵빵빵!', '앞에 뭐야 진짜…', '추월차선인데?!', '저 차 때문에…'];
export const CHEATER_LINES = ['죄송합니다~', '아 들켰다', '급해서요ㅠ', '블박 찍혔나?'];
// 잔챙이 빌런 (정체 구간에서 지나가며 참교육): 범칙금은 포상금 보너스로
export const MINI_TYPES = {
  butt: { name: '꽁초 투척러', item: 'butt', fine: 50000, violation: '차량 밖 담배꽁초 투척', lines: ['퉤~', '재떨이가 꽉 차서~'], sorry: ['죄송합니다ㅠ', '다신 안 버릴게요'] },
  trash: { name: '창밖 쓰레기 투척', item: 'cup', fine: 50000, violation: '차량 밖 쓰레기 투척', lines: ['옛다 커피~', '버릴 데가 없어서~'], sorry: ['주워갈게요ㅠ', '블박 찍혔다…'] },
  cutin: { name: '갓길 칼치기', item: null, fine: 60000, violation: '갓길 통행 + 끼어들기', lines: ['나 먼저~', '급해 급해!'], sorry: ['제자리로 갈게요', '죄송합니다~'] },
};

// 게임플레이 튜닝 값 (main/player/boss/weapons 공유)
export const TUNE = {
  playerMaxV: 18,          // 정체 구간 최고속 m/s (~65km/h)
  playerAccel: 9,
  playerBrake: 22,
  laneChangeTime: 0.18,
  // 분노: 5칸 (사용자 피드백 v0.2: "중간쯤 이미 MAX" → 칸 늘리고 적립 속도 절반)
  rageSegs: 5,
  bumpRage: 0.06,
  timeRage: 0.016,         // 느릴 때(<5m/s) 초당 분노 증가
  baseRage: 0.005,         // 정체 구간에 있기만 해도 초당 분노 증가
  cutinRage: 0.05,
  nowayRage: 0.015,        // 경적 울렸는데 못 비킬 때
  tauntRage: 0.015,        // 원흉 도발 볼 때마다
  miniRage: 0.04,          // 잔챙이 빌런한테 당할 때
  smashRage: 0.012,        // 콘·낙하물 날릴 때
  rageHornRange: 48,       // 분노의 경적: 갓길 앞 이 거리까지 싹 쓸어버림
  boostTime: 2.2,          // 분노의 경적 후 가속 시간
  bossAheadGap: 11,        // 보스전: 플레이어는 원흉 '앞' 이 거리에서 싸운다 (뒤는 정체라 못 감)
  shoulderMaxV: 18,        // 갓길 최고속 m/s
  tackDmg: 4,
  tackRate: 7,             // 초당 발사
  superDmg: 28,
  superCost: 1 / 5,        // 분노 게이지 1칸 (정체: 분노의 경적 / 보스전: 분노 폭탄)
  hitRage: 0.08,           // 원흉 공격 맞으면 분노 +
  releaseWaveSpeed: 70,    // m/s, 해방 물결이 뒤로 퍼지는 속도
  releaseSpeed: [25, 30],  // 해방 후 NPC 목표 속도 m/s (90~108km/h, 고속도로 제한 100~110km/h)
  cruiseSpeed: 30.5,       // 질주 = 제한속도 110km/h (참교육 했다고 과속하면 안 됨)
  // 정체 밀도: 교통류 이론의 정체 밀도 ≈ 140 PCU/km/차로 → 대형차 혼입 보정 ≈ 125대/km/차로
  // 해방 대수 = 정체 길이(km) × 차로 × 정체 밀도 (결과 화면에 근거 표시)
  jamDensity: 125,
  releaseLaneDelay: 0.45,  // 해방 순서: 1차선 먼저 → 차선마다 이만큼 늦게 (인과가 보이도록)
  truckFreeSpeed: [22, 25],// 해방 후 화물차/버스 속도 (화물차 제한 80~90km/h)
  cruiseTime: 4.2,         // 해방 후 질주 시간
};

// ─────────────────────────────────────────────────────────────
// 차고/상점 (포상금으로 구매). docs/SHOP.md
// cat: car(하나 장착) | weapon(하나 장착) | move(보유 시 사용 가능) | finish(하나 장착) | passive(보유 시 적용)
export const SHOP = [
  { id: 'car_hatch', cat: 'car', name: '참교육 해치', price: 0, kind: 'player', desc: '기본 차. 작고 빨라서 갓길 질주에 최고.', stats: { speed: 1.0, armor: 0 } },
  { id: 'car_porter', cat: 'car', name: '1톤 포터', price: 180000, kind: 'playerPorter', desc: '튼튼한 짐칸. 추돌 2회까지 무시.', stats: { speed: 0.93, armor: 2 } },
  { id: 'car_wrecker', cat: 'car', name: '레커 견인차', price: 450000, kind: 'playerWrecker', desc: '갓길 고장차를 들이받으면 즉시 견인!', stats: { speed: 0.97, armor: 1, tow: true } },
  { id: 'car_patrol', cat: 'car', name: '암행 순찰차 st.', price: 900000, kind: 'playerPatrol', desc: '경적 = 사이렌. 얌체·4차선이 크게 비켜준다.', stats: { speed: 1.08, armor: 0, siren: true } },
  { id: 'wpn_tack', cat: 'weapon', name: '압정', price: 0, proj: 'tack', desc: '기본. 밟으면 펑크.', dmg: 4, rate: 7, spread: 1 },
  { id: 'wpn_caltrop', cat: 'weapon', name: '마름쇠 3연발', price: 150000, proj: 'caltrop', desc: '한 번에 3개 흩뿌려서 잘 맞는다.', dmg: 2.2, rate: 6, spread: 3 },
  { id: 'wpn_water', cat: 'weapon', name: '물풍선', price: 280000, proj: 'waterBalloon', desc: '앞유리 범벅! 맞으면 빌런 공격이 느려진다.', dmg: 7, rate: 3.5, spread: 1, slow: 0.55 },
  { id: 'wpn_gum', cat: 'weapon', name: '껌 폭탄', price: 520000, proj: 'gum', desc: '타이어에 껌이 쩍. 데미지 1.6배.', dmg: 6.4, rate: 5, spread: 1 },
  { id: 'mv_jump', cat: 'move', name: '참교육 점프', price: 220000, desc: '↑(점프 버튼): 앞차를 훌쩍 뛰어넘기. 쿨 4초.' },
  { id: 'mv_drone', cat: 'move', name: '블박 드론', price: 600000, desc: '드론이 위에서 따라오며 잔챙이 빌런·원흉에 자동 사격.' },
  { id: 'fin_rocket', cat: 'finish', name: '로켓 발사', price: 0, desc: '하늘 저편으로 반짝★ (기본 피니시)' },
  { id: 'fin_balloon', cat: 'finish', name: '풍선 둥실', price: 160000, desc: '풍선 다발에 매달려 둥실둥실 날아간다.' },
  { id: 'fin_heli', cat: 'finish', name: '참교육 헬기', price: 420000, desc: '헬기가 와서 대롱대롱 들고 간다.' },
  { id: 'fin_ufo', cat: 'finish', name: 'UFO 납치', price: 750000, desc: '빛줄기에 빨려 올라가 우주로.' },
  { id: 'pas_4k', cat: 'passive', name: '블박 4K 화질', price: 120000, desc: '선명한 증거 → 포상금 +25%' },
  { id: 'pas_airbag', cat: 'passive', name: '에어백', price: 200000, desc: '스테이지마다 추돌 3회까지 분노·점수 손해 없음' },
  { id: 'pas_trot', cat: 'passive', name: '트로트 경적', price: 140000, desc: '뽕짝 경적 → 앞차가 더 잘 비켜준다' },
  { id: 'pas_coffee', cat: 'passive', name: '졸음쉼터 커피', price: 240000, desc: '분노 게이지 1칸 채우고 시작' },
];
export const SHOP_DEFAULT = { car: 'car_hatch', weapon: 'wpn_tack', finish: 'fin_rocket' };
