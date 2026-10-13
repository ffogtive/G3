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
};

// ─────────────────────────────────────────────────────────────
// 스테이지: 매 스테이지 = 정체 → 원흉 발견 → 참교육 → 뻥 뚫림
// villains[].kind 는 vehicles.js buildVehicle kind 와 일치해야 함.
// attacks: 'brakeCheck' | 'throw' | 'swerve' | 'smoke' | 'zigzag'
// throwItem: projectile kind (vehicles.js buildProjectile)
export const STAGES = [
  {
    id: 1,
    highway: '경부고속도로',
    route: 1,              // 실제 고속도로 노선번호 (방패 배지)
    direction: '부산 방향',
    title: '1차선 정속주행러',
    villainLine: '"규정속도 지키는데 뭐가 문제죠?"',
    blurb: '1차선에서 혼자 정속주행 중. 뒤로 3.2km가 막혔다.',
    sky: 'day',
    jamLength: 170,          // 실제 시뮬 거리(m). 연출상 표시 거리는 displayKm
    displayKm: 3.2,
    density: 1.0,            // 1.0 = 기본 차간
    jamSpeed: 2.4,           // 정체 기본 속도 m/s (~13km/h)
    villainSpeedLabel: '정속 80km/h',
    villains: [
      { kind: 'villainSedan', lane: 0, hp: 140, name: '정속주행 김사장', color: 0xd9c9a3 },
    ],
    attacks: { brakeCheck: 3, throw: 1 },
    throwItem: 'cup',
    attackInterval: [2.6, 3.8],
    taunts: ['규정속도 준수 중입니다~', '추월은 2차선으로 하세요', '1차선은 내 차선인데?', '왜 빵빵거려?', '난 안 급해~', '정속주행이 죄냐?'],
    signs: [['부산', '387km'], ['대전', '128km']],
    vms: '1차선은 추월차선입니다',
  },
  {
    id: 2,
    highway: '영동고속도로',
    route: 50,              // 실제 고속도로 노선번호 (방패 배지)
    direction: '강릉 방향',
    title: '화물차 나란히 주행',
    villainLine: '"형님 먼저~ 아우 먼저~"',
    blurb: '25톤 두 대가 1·2차선을 나란히 막고 수다 떠는 중.',
    sky: 'sunset',
    jamLength: 190,
    displayKm: 5.8,
    density: 1.03,
    jamSpeed: 2.4,
    villainSpeedLabel: '나란히 60km/h',
    villains: [
      { kind: 'villainTruck', lane: 0, hp: 120, name: '형님 트럭', color: 0x2f6fd6 },
      { kind: 'villainTruck', lane: 1, hp: 120, name: '아우 트럭', color: 0x3a9d5d },
    ],
    attacks: { throw: 3, brakeCheck: 1 },
    throwItem: 'watermelon',
    attackInterval: [2.2, 3.2],
    taunts: ['형님 먼저 가세요~', '아우 먼저 가~', '우린 나란히가 좋아', '수박 사세요~', '무전기 감도 좋고~'],
    signs: [['강릉', '164km'], ['원주', '52km']],
    vms: '화물차는 우측 차로로',
  },
  {
    id: 3,
    highway: '서해안고속도로',
    route: 15,              // 실제 고속도로 노선번호 (방패 배지)
    direction: '목포 방향',
    title: '차선 물고 가는 SUV',
    villainLine: '"차선? 그게 뭐임?"',
    blurb: '1·2차선 사이를 물고 달리며 아무도 못 지나가게 한다.',
    sky: 'morning',
    jamLength: 200,
    displayKm: 7.1,
    density: 1.06,
    jamSpeed: 2.4,
    villainSpeedLabel: '두 차선 점유',
    villains: [
      { kind: 'villainSuv', lane: 0.5, hp: 200, name: '차선물기 대마왕', color: 0x1d1f22 },
    ],
    attacks: { swerve: 3, throw: 2, brakeCheck: 1 },
    throwItem: 'cup',
    attackInterval: [2.0, 3.0],
    taunts: ['내 차 크잖아~', '두 칸이 편해', '깜빡이? 고장났어', '비켜 비켜~', '안 보여서 몰랐어'],
    signs: [['목포', '241km'], ['서산', '38km']],
    vms: '차선을 지켜주세요',
  },
  {
    id: 4,
    highway: '중부고속도로',
    route: 35,              // 실제 고속도로 노선번호 (방패 배지)
    direction: '통영 방향',
    title: '폰 보며 지그재그',
    villainLine: '"ㅋㅋㅋ 잠만 이것만 보고"',
    blurb: '숏폼 보면서 1~3차선을 갈지자로. 급정거는 덤.',
    sky: 'night',
    jamLength: 200,
    displayKm: 9.4,
    density: 1.08,
    jamSpeed: 2.4,
    villainSpeedLabel: '시속 ??km',
    villains: [
      { kind: 'villainPhone', lane: 1, hp: 220, name: '숏폼중독 드라이버', color: 0xe85d9a },
    ],
    attacks: { zigzag: 3, brakeCheck: 2, throw: 1 },
    throwItem: 'phone',
    attackInterval: [1.8, 2.8],
    taunts: ['ㅋㅋㅋㅋ', '잠만 이것만', '어? 여기 차선이었어?', '좋아요 눌러주세요~', '구독과 알림설정!'],
    signs: [['통영', '201km'], ['이천', '12km']],
    vms: '운전 중 휴대폰 사용금지',
  },
  {
    id: 5,
    highway: '남해고속도로',
    route: 10,              // 실제 고속도로 노선번호 (방패 배지)
    direction: '순천 방향',
    title: '1차선 경운기 (최종보스)',
    villainLine: '"허허, 젊은 것들이 급하긴"',
    blurb: '어떻게 들어왔는지 모를 경운기가 1차선을 점령했다.',
    sky: 'day',
    jamLength: 220,
    displayKm: 12.7,
    density: 1.1,
    jamSpeed: 2.4,
    villainSpeedLabel: '시속 15km',
    villains: [
      { kind: 'tractor', lane: 0, hp: 340, name: '전설의 경운기 할배', color: 0x3f8f3a },
    ],
    attacks: { throw: 3, smoke: 2, brakeCheck: 1 },
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

// 게임플레이 튜닝 값 (main/player/boss/weapons 공유)
export const TUNE = {
  playerMaxV: 18,          // 정체 구간 최고속 m/s (~65km/h)
  playerAccel: 9,
  playerBrake: 22,
  laneChangeTime: 0.18,
  bumpRage: 0.12,
  timeRage: 0.03,          // 느릴 때(<5m/s) 초당 분노 증가
  baseRage: 0.009,         // 정체 구간에 있기만 해도 초당 분노 증가
  cutinRage: 0.1,
  nowayRage: 0.03,         // 경적 울렸는데 못 비킬 때
  tauntRage: 0.025,        // 원흉 도발 볼 때마다
  bossTriggerDist: 45,     // 원흉과 이 거리 이내 → 보스전
  bossFollowGap: 13,       // 보스전에서 플레이어는 원흉 뒤 이 거리 유지
  tackDmg: 4,
  tackRate: 7,             // 초당 발사
  superDmg: 38,
  superCost: 1 / 3,        // 분노 게이지 1칸
  hitRage: 0.14,           // 원흉 공격 맞으면 분노 +
  releaseWaveSpeed: 70,    // m/s, 해방 물결이 뒤로 퍼지는 속도
  releaseSpeed: [27, 36],  // 해방 후 NPC 목표 속도 m/s (~100~130km/h)
  cruiseTime: 4.2,         // 해방 후 질주 시간
};
