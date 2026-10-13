# ARCHITECTURE — 모듈 계약서 (Contract)

가설: 모듈 간 인터페이스를 먼저 못박으면, 아트·사운드·이펙트·UI를 병렬로 만들어도 통합이 한 번에 맞는다.

- 런타임: 브라우저, ES modules, Three.js r170 (`import * as THREE from 'three'`), 애드온은 `three/addons/...`
- 빌드 없이 실행: 레포 루트에서 `npm run dev` → http://localhost:8080/game/
- 배포 번들: `npm run build` → `dist/index.html` (단일 파일, esbuild IIFE)
- **좌표계/치수/스테이지는 전부 `game/js/config.js`** (읽기 전용 공유). 진행 방향 = −Z, `z = -s`, 1차선(lane 0) = 가장 왼쪽(−X).
- 모든 모듈은 **DOM이나 Three 씬 외의 전역 상태를 건드리지 않는다.** 모듈 간 통신은 아래 export만으로.
- 성능 예산: NPC 차량 ~150대 + 반대편 30대 + 소품 수백 개. 차량 1대 = draw call 3개 이하. 모바일 고려.

## 파일 소유권
| 파일 | 담당 | 설명 |
|---|---|---|
| `game/js/config.js` | core | 좌표·튜닝·스테이지 (공유) |
| `game/js/vehicles.js` | art-vehicles | 차량·투사체 복셀 모델 |
| `game/js/scenery.js` | art-scenery | 도로 세그먼트·표지판·VMS·배경 소품 |
| `game/js/fx.js` | fx | 3D 파티클·카메라 셰이크·스피드라인 |
| `game/js/audio.js` | audio | WebAudio 합성 SFX/BGM |
| `game/js/ui.js`, `game/css/style.css` | ui | DOM HUD·메뉴·결과·터치 컨트롤 |
| `game/js/main.js`, `world.js`, `traffic.js`, `player.js`, `boss.js`, `weapons.js`, `input.js` | core | 게임 로직 |
| `game/index.html` | core | 엔트리 (importmap, 폰트, 캔버스 `#game`, UI 루트 `#ui`) |
| `game/dev/*.html` | 각 담당 | 모듈 단독 데모/검증 하네스 |

---

## vehicles.js
아트 디렉션: 길건너친구들(Crossy Road) 풍 **로우폴리 복셀**. 박스 위주의 통통한 비율(큰 바퀴, 높은 캐빈), 플랫 셰이딩, 채도 높은 색, 창문은 진한 남색 유리. 한국 도로 느낌(1톤 포터 같은 파란 트럭, 주황/흰 택시, 고속버스, 경차).

```js
export const MAT;   // 공유 재질: { body, brakeOn, brakeOff, hazardOn, hazardOff, headOn, headOff }
                    // body = MeshLambertMaterial({ vertexColors: true, flatShading: true }) 모든 차량 공유
export function buildVehicle(kind, opts = {}) : THREE.Group
//  kind: 'compact' | 'sedan' | 'suv' | 'taxi' | 'van' | 'pickup1t' | 'truck' | 'bus'
//        | 'player' | 'villainSedan' | 'villainTruck' | 'villainSuv' | 'villainPhone' | 'tractor' | 'police'
//  opts: { color?: number (차체 메인 색), detailed?: boolean, seed?: number }
//  - 앞쪽이 −Z, 원점 = 차량 바닥 중심(노면 y=0), +Y 위.
//  - 비(非)detailed: 차체+바퀴+창문+헤드라이트를 BufferGeometryUtils.mergeGeometries 로 **메시 1개**로 병합(vertex color).
//    지오메트리는 (kind,color) 키로 캐시해서 재사용. 브레이크등 메시 1개, 방향지시등(비상등) 메시 1개 별도.
//  - detailed:true (플레이어·원흉 전용): 바퀴 4개를 개별 Mesh 로 분리(펑크로 날아가야 함),
//    body 는 per-vehicle 재질 clone (피격 시 흰색 플래시용 emissive 조작 가능). 운전자 머리(선글라스 등) 포함.
//  - 그림자: 모든 Mesh castShadow = true, receiveShadow = false.
//  group.userData = {
//    kind, length, width, height,      // 바운딩 치수 (m). 승용 ~4.4×1.9, 트럭 ~9×2.5, 버스 ~11×2.5, 경운기 ~3.2×1.6
//    body: THREE.Object3D,             // 차체 (기울이기/흔들기 대상). detailed 일 때 바퀴는 body 의 자식이 아님
//    brake: THREE.Mesh | null,         // 브레이크등 (MAT.brakeOn/brakeOff 교체)
//    hazard: THREE.Mesh | null,        // 4모서리 방향지시등 (MAT.hazardOn/hazardOff 교체)
//    head: THREE.Mesh | null,          // 헤드라이트 (야간용, MAT.headOn/headOff)
//    wheels: THREE.Mesh[],             // detailed 일 때만 4개 [FL, FR, RL, RR], group 의 직접 자식, 허브 위치에 배치. 로컬 X축 회전 = 굴러감
//    wheelRadius: number,
//    driver: THREE.Object3D | null,    // detailed 일 때 운전자 머리
//    flashMats: THREE.Material[],      // detailed 일 때 플래시 대상 재질들
//  }
export function setBrake(vehicle, on)        // 브레이크등 on/off
export function setHazard(vehicle, on)       // 방향지시등 4개 on/off (깜빡임 타이밍은 호출자가)
export function setHeadlights(vehicle, on)
export function setFlash(vehicle, amount)    // 0..1, detailed 차량 흰색 피격 플래시 (emissive)
export function buildProjectile(kind) : THREE.Object3D
//  kind: 'tack'(압정, 작고 은색 뾰족) | 'missile'(분노 미사일, 빨강+노랑 불꽃 꼬리) | 'cup'(테이크아웃 커피컵)
//        | 'watermelon' | 'hay'(건초 뭉치) | 'phone' | 'butt'(담배꽁초) | 'chicken'(닭, 경운기 보너스)
//  원점 = 중심. 크기는 실제 비율보다 과장(가독성) — 압정 ~0.5m, 수박 ~0.9m, 건초 ~1.2m.
export function buildWarningMarker() : THREE.Object3D
//  노면 위 투하 경고 표시 (빨간 X 또는 원형 타깃, 지름 ~3m, y=0.03, 반투명 가능). userData.setProgress(0..1) 로 차오르는 연출
```

### vehicles.js v0.4 추가 (깜빡이 · 폭주족 바이크 · 삼각별 세단)
가설: 깜빡이 빌런의 인과가 보이려면 추격캠 30~50m 앞에서 주황 번쩍임이 차폭 밖으로 번져야 한다 (✅ `?view=blinker` 브레이크등 바다 속에서도 읽힘).
기존 차종의 지오메트리·치수는 그대로다 (회귀 해시 360/360 동일). 꺼진 깜빡이는 `visible:false` 라서 평소 모습과 draw call 이 같다.

```js
export const BLINK_PERIOD = 2 / 3;               // 0.333s 켜짐 / 0.333s 꺼짐 ≈ 1.5Hz
export function setBlinker(vehicle, side, t = true) : boolean
//  side: 'left'(차 기준 왼쪽 = 로컬 −X) | 'right'(+X) | 'hazard'(양쪽 동시) | null/false(끔)
//  t: 초(number) → 주기 점멸, true → 켜짐 고정(스틸컷). 반환 = 지금 켜졌는지 (false→true 순간에 audio 'blink')
//  모든 차종(15종 + player 계열 + 빌런 + motorbike + starSedan). setHazard(기존 비상등 메시)와 독립.
//  켜짐 비용: 한쪽당 draw call 2 (과장 램프 Mesh + 후광 Points). 후광 크기 MAT.blinkHalo.size (기본 2.6, 월드 m)
export function setPose(vehicle, name) : boolean // 오토바이 라이더 포즈 (= userData.setPose)
export const RIDER_POSES = ['ride','stand','oneHand','noHands','lie','tumble','sprawl','sit'];
export const MOTORBIKE_VARIANTS = ['죽창 삼단','로켓카울','쭉쭉이 핸들','우퍼 스쿠터'];
//  buildVehicle(kind, { variant }) — 모든 차종에서 seed 대신 변형을 직접 지정 (없으면 기존 seed 규칙)
//  kind 추가: 'motorbike' | 'starSedan'  (둘 다 detailed 기본)
```

| userData (추가) | 대상 | 내용 |
|---|---|---|
| `blinkers` | 전 차종 | `[L, R]` Mesh(`blinkL`/`blinkR`, body 자식) + 자식 Points `blinkHalo`. setBlinker 가 visible 토글 |
| `blinkSide` | 전 차종 | 마지막 setBlinker side (`null` = 꺼짐) |
| `wheels` | motorbike | **2개 `[F, R]`** (차는 4개). group 직속, 로컬 X 회전 = 굴러감. 형광 휠 자식 `rimGlow` |
| `rider` (= `driver`) | motorbike | Group, body 자식, 원점 = 엉덩이/시트 접점. 포즈마다 지오메트리 1개(draw call 1) |
| `setPose(name)`, `poses` | motorbike | 포즈 교체(즉시 스냅). `rider.userData.groundY[pose]` = 땅에 놓을 때 rider 원점 높이 |
| `bike` (= `body`) | motorbike | 쓰러뜨리기 권장값 `fall = { rotZ: 1.22, y: 0.3 }` (body.rotation.z = ±rotZ, position.y = y) |
| `flags` | motorbike 0·2·3 | 깃발 Mesh[] (피벗 = 깃대 끝). 펄럭임 `flags[i].rotation.y = sin(t*9+i)*0.25` |
| `motoVariant` | motorbike | 변형 이름 |
| `ramPoint` | starSedan | Object3D, 앞범퍼 중앙 (들이받기 이펙트 위치) |

치수: motorbike length 1.92~2.39 (깃발·죽창 끝 제외, 충돌용) × width 0.8 × height 2.0~2.7 (ride 포즈 + 깃발), 1,660~1,920▲, 7~9 draw call.
starSedan 5.53 × 1.96 × 1.54 (범퍼가드 포함), ~1,700▲, 7 draw call.
라이더 분리(슬랩스틱): `scene.attach(v.userData.rider)` → `setPose('tumble')` 으로 굴리고 → `'sprawl'`/`'sit'` + `groundY`. 피·부상 묘사 없음(어질어질 눈).

### vehicles.js v0.4.1 추가 (V04_SPEC 단계 4·10·13·17 + 부록 A)
가설: 판 차별화 = 빌런의 **보이는** 시그니처 행동 + 판마다 다른 무대. 그래서 깜빡이 템포·조향·손상·숨은 위반 단서를 추격캠에서 읽히는 덩어리로 만든다 (✅ 하네스 `?view=steer|stage56|violators|damage|props1|p1`).
기존 차종의 지오메트리·치수는 그대로다 (회귀 해시 434/434 동일). 새 옵션은 기본값일 때 캐시 키가 바뀌지 않는다.

```js
// 단계 4 — 깜빡이 템포·후광·조향 (4번째 인자를 안 주면 이전과 100% 같다)
export const BLINK_PERIOD_HYPER = 1 / 3, BLINK_HALO_VILLAIN = 1.8;
setBlinker(v, side, t, { tempo: 1 | 2 | 'hyper', period?, halo?: number | true, wet?: boolean }) : boolean
setBlinkHalo(v, k)            // 후광 배율 (차량에 기억). 배율별 공유 재질 + 렌더 직전 MAT.blinkHalo.size × k 동기화
setBlinkWet(v, on)            // 빗길: 깜빡이 램프 아래 노면 반사 줄 (가산, 램프와 같이 깜빡임)
export const STEER_MAX = π/6, STEER_BODY_YAW = 2°;
setSteer(v, rad) : number     // rad > 0 = 왼쪽(−X). detailed: steerWheels.rotation.y (order 'YXZ' → 굴러감 rotation.x 와 독립)
                              // 비detailed: body.rotation.y = (rad/STEER_MAX)·2°.  ±30° 로 과장해서 써도 됨 (진짜 차로 변경 텔)
// 단계 10 — 1-5·1-6 전용
buildVehicle('beginner', { variant: 0 | 1, detailed? })   // 민트 경차 + 뒷유리 '초보운전' 스티커 (detailed = 겁먹은 운전자)
buildVehicle('unmarked', { detailed? })                    // 진회색 암행순찰차. setStrobe(v, t) → 그릴·뒷선반 적청 + 뒷유리 LED '정차하세요'
buildFxProp('crashScene')                                  // 갓길 추돌사고 현장 묶음, userData.update(t) 로 비상등·경광등
buildVehicle(kind, { sticker: 'beginner' | 'myLane' })     // passenger 계열 뒷유리 스티커
// 부록 A — 숨은 위반 차량
buildVehicle(kind, { plate: 'normal' | 'none' | 'covered' | 'temp' })   // 뒤 번호판 (none 빈 브래킷 / covered 신문지+테이프 / temp 빨간 사선 임시)
buildVehicle('van', { passengers: 0..9 })                               // 탑승 인원(운전자 포함) 머리 실루엣
// HP 손상
setDamage(v, level 0..4, { focus: 'both' | 'rear' | 'front' }) : number
// 단계 13 — 판 소품
buildFxProp('angelRing' | 'wings' | 'devilHorns' | 'ruler' | 'rentFlag'); buildProjectile('phoneMount' | 'charger')
// 단계 17 — P1
buildVehicle('motorbike', { lod: true })      // 라이더(ride)·깃발 병합 → draw call 2 (차체 + 네온). 포즈 교체 없음
buildVehicle('motorbike', { leader: true })   // 분리형 리더 깃대 + 무지개 LED
setLeaderLed(v, on); setKickstand(v, on); export const KICK_LEAN = 0.16;
RIDER_POSES += 'dismount' | 'run' | 'run2' | 'cower'   // P1 판에서는 lie·sprawl·tumble·sit 금지 (라이더 선대피, 빈 바이크만 넘어짐)
buildVehicle('chairmanSedan')                // 회장님 세단 (삼각김밥 엠블럼, 실존 로고·차명 없음)
```

| userData (추가) | 대상 | 내용 |
|---|---|---|
| `bodyMesh` | 전 차종 | 차체 메시 (detailed 면 body Group 안). setDamage 가 geometry 를 바꾼다 |
| `steerWheels`, `steer` | 전 차종 | 가장 앞 축 바퀴 (오토바이 = 앞바퀴 1개, 비detailed = 빈 배열) / 마지막 setSteer 각 |
| `blinkHalo`, `blinkWet` | 전 차종 | 후광 배율 / 빗길 반사 줄 켜짐 |
| `smokePoint` | 승용·SUV·밴·player 계열·포터캡 계열 | Object3D, 엔진룸(캡오버는 그릴) — 손상 연기·김 fx 위치 |
| `damage`, `damageFocus`, `damageMesh` | setDamage 대상 | 현재 단계 / 손상 덧붙임 메시 ('damage', 차량 재질 공유 → 피격 플래시 같이) |
| `sticker` | beginner · sticker 옵션 | 뒷유리 스티커 메시 |
| `strobe`, `strobePattern`, `strobeSign` | unmarked | 숨은 적/청 스트로브 [R, B] · 'police' · 뒷유리 LED 전광판 (setStrobe 가 같이 켜고 끔) |
| `plate`, `passengers` | plate·passengers 옵션 | 옵션 값 되읽기 (코어 판정용) |
| `lod` | motorbike lod | true (rider·flags·setPose 없음) |
| `flagPole`, `ledPole`, `ledBike`, `leds`, `leader` | motorbike leader | 깃대 Mesh(피벗 = 소켓, 자식 = LED·깃발) → `scene.attach(flagPole)` 한 번에 통째로 떨어짐 |
| `kickstand`, `parked` | motorbike (setKickstand 후) | 킥스탠드 다리 메시 / 정차 상태 |
| `tapFinger`, `ramPoint` | chairmanSedan | 핸들 톡톡 손가락(rotation.z) / 앞범퍼 중앙 (들이받기 이펙트) |

`buildFxProp` 추가 userData — `crashScene`: `{ cars:[앞, 뒤], police, steam, length: 19, update(t) }` (원점 = 갓길 중심선 x≈8.7, 앞 = −Z), `angelRing`: `ring`, `wings`: `wings[L,R]` + `setTorn(bool)`, `devilHorns`: `horns[L,R]`, `ruler`: `tag`, `rentFlag`: `flag`(펄럭 rotation.y). 셋(링·날개·뿔)·깃발의 원점 = 지붕 위 부착점 (차 `userData.height`).

비용: unmarked 꺼짐 1 dc / 켜짐 4 dc(+적·청·LED 판), beginner 2 dc(차체+스티커), chairmanSedan 8 dc(detailed)·1 dc, motorbike LOD 2 dc(1,610~1,870▲), leader 11 dc, van passengers 9 = 2,040▲(1 dc, 0명 768▲), plate 변형 +24~144▲(dc 동일), setDamage L≥1 = +1 dc(+180~800▲), crashScene 9 dc·4,070▲.

## scenery.js
아트 디렉션: 한국 고속도로. 진회색 아스팔트, 흰 점선 차선, 1차선 왼쪽 노란 실선, 콘크리트 중앙분리대 + **녹색 눈부심방지 판**, 우측 갓길 + 가드레일, 구간별 **방음벽**(투명 패널에 버드세이버 스티커/녹색 판넬), 아파트 단지("101동"), 소나무 산, 논, 교회 첨탑(밤엔 빨간 십자가), 녹색 도로 안내 표지판, 주황 LED VMS 전광판, 졸음쉼터 현수막.

```js
export function buildRoadSegment(length = SEG_LEN, opts = {}) : THREE.Group
//  s ∈ [0, length] 구간 (z: 0 → −length). 양방향 아스팔트, 차선 도색, 1차선 노란선, 중앙분리대+눈부심방지판,
//  우측 갓길+가드레일, 반대편 도로(OPP_LANE_X), 양쪽 잔디 비탈. 정적 메시는 재질별로 병합 권장.
//  opts: { night?: boolean, soundBarrier?: 'left'|'right'|'both'|null, seed?: number }
//  receiveShadow = true (노면), 가드레일/분리대 castShadow 가능.
export function buildProp(kind, seed = 0, opts = {}) : THREE.Group
//  kind: 'tree' | 'pine' | 'apartment' | 'mountain' | 'paddy' | 'church' | 'streetLight' | 'billboard' | 'cloud' | 'cctv' | 'house' | 'bush'
//  원점 = 바닥 중심. 대략 크기: tree 4~6m, apartment 폭 14m×높이 25~45m(라벨 "10X동"), mountain 반경 40~80m 높이 30~60m,
//  paddy 20×20m 평면(논, 물빛/녹색), cloud 공중용, cctv=도로 위 단속카메라 지주(도로 전체 폭), streetLight 높이 10m(밤엔 발광).
//  opts.night: 창문/가로등/십자가 발광.  소품 1개 = 메시 1~3개, vertex color + 공유 재질 권장.
export function buildGantrySign(lines, opts = {}) : THREE.Group
//  도로(4차선+갓길) 위를 가로지르는 녹색 안내표지판 문형 지주. lines: [['부산','387km'], ['대전','128km']]
//  원점 x=0, s=0 기준. 판 하단 높이 ~6.5m. 텍스트는 CanvasTexture (FONT_DISPLAY, 흰 글씨, 화살표).
export function buildVMS(text, opts = {}) : THREE.Group
//  도로 위 주황 LED 전광판(검은 판). userData.setText(text, color='#ffb000') 로 텍스트 교체(캔버스 다시 그림).
export function buildBanner(text, opts = {}) : THREE.Group
//  우측 비탈/가드레일 옆 현수막(흰 바탕 빨강/파랑 글씨) 예: '졸음운전! 자면 죽는다', '졸음쉼터 2km'.
export function makeSkyDome(topColor, bottomColor) : THREE.Mesh
//  큰 구(반경 ~900) 안쪽 그라데이션 셰이더 (fog:false, depthWrite:false). 카메라 따라다닐 수 있게 원점 기준.
```

### scenery.js v0.4 추가: 터널 (갓길 없음)
가설: 추격캠(위 12.5m)은 터널 천장보다 높다 → 셸을 **안쪽 면만** 구우면 바깥(위) 카메라에서는 백페이스 컬링으로 천장이 자동으로 잘려 차가 절대 안 가려지고, 안쪽 낮은 카메라(인트로·킬캠)에서는 아치·제트팬·천장등이 보이는 진짜 터널이 된다 (✅ `vehicles.html?view=tunnel&cam=all`).

```js
export const TUNNEL;           // { wallX: 8.55, walkX: 7.55, walkH: 0.25, springY: 3, crownY: 8, capY: 9.2, portalTopY, boardY, approach: 14 }
export const TUNNEL_AMBIENCE;  // 터널 안 권장 조명 { hemiSky, hemiGround, hemiI, sunI, fog, fogNear, fogFar } → 코어가 보간
export function buildTunnelSegment(length = SEG_LEN, opts = {}) : THREE.Group
//  buildRoadSegment 와 같은 규약 (s ∈ [0,length], z: 0 → −length). 4차로(laneX) + 측방여유 0.35 + 1m 검사원 보도 + 측벽(|x| = 8.55)
//  → 갓길(x 7.2~10.2)·갓길 차로(SHOULDER_LANE 4)는 막힘. 반대편 도로·분리대·가드레일 없음 (한 방향 단독 터널).
//  차선 = 흰 실선(진로변경 제한). |x| > wallX 는 산 단면(암반면 + 높이 capY 잔디 윗면)이 덮어 바깥 소품이 안 비침.
//  메시 4개 = draw call 4: road / shell(안쪽만) / glow(나트륨 등기구·유도등) / light(가산 빛웅덩이). ~2,650▲. castShadow 없음.
//  opts: { night?, seed?, band?: 측벽 색띠 색, fans?: 제트팬(기본 true) }
export function buildTunnelPortal(name = '○○터널', opts = {}) : THREE.Group
//  원점 x=0, s=0 = 터널 시작면. 정면 +Z(다가오는 차), 두께 0.8m 와 날개벽·비탈(approach 14m) 은 +Z 쪽.
//  현판(캔버스, 아치 위 boardY) + 입구 오른쪽 길가 안내표지(낮아서 추격캠에서 오래 읽힘). opts: { night?, length?(m → 'L=2,400m'), sub?, exit? }
//  출구 = buildTunnelPortal(name, { exit: true }) 를 rotation.y = π 로 터널 끝 s 에 배치 (현판 없음).
```

### scenery.js v0.4.1 추가 (1챕터 판 소품 · 빗길 · 터널 제어)
가설: 판 소품은 추격캠(38° 내려다봄)에서 가장 크게 보이는 노면 데칼이 1순위, 세로 구조물은 실루엣 + 발광으로 보조 (✅ `vehicles.html?view=props1`, `?view=p1`).
기존 buildRoadSegment·buildTunnelSegment 지오메트리는 그대로 (opt-in 옵션만 캐시 키에 붙음).

```js
buildRoadDecal(kind, opts) : Group   // 노면 데칼 1 dc (y 0.025, polygonOffset). 원점 = 데칼 시작 s, x = 도로 좌표
//  'enforceStart'(빨간 '단속구간' 띠) | 'enforceEnd'('단속 끝' 띠) — opts.lanes=[a,b], 14.4 × 3.2m
//  'ownerOnly'('건물주 전용', opts.lane=0) → userData.setPassing(true) = 발광 '추월차로'
//  'mergeArrow' | 'bayText'('비상주차대') | 'laneHighlight'(#4 발광 굵은 점선 + 빨간 빗금, opts.x·length) | 'puddles'(#5 물웅덩이)
buildEnforceGantry({ night, rearLane = 2, label }) : Group   // #7 단속 갠트리 (cctv 지주 재사용) 3 dc + 플래시
//  userData: rearCam(Group, rotation.y 0 → π = 후면 단속), flash(i | 'rear', on), flashes[4], rearFlash, height, spansRoad
buildMergeTaper({ length = 120, taper = 40, night }) : Group // #8 갓길 = 합류차로 → 점선, 테이퍼 빗금, '합류 끝' 표지, 노면 화살표, 지퍼 빛줄
//  userData: taperS, endS, setZip(p 0..1, t) — 테이퍼 끝(앞)에서 뒤로 초록 지퍼 이빨이 켜짐 (지퍼식 합류 해방)
buildEmergencyBay({ length = 40, night }) : Group          // #3 갓길 비상주차대 표시 + 'P 비상주차대' 표지 + 비상전화. userData.stopS = 정차 차량 권장 s
buildRoadSegment(len, { wet: true }) / setRoadWet(seg, on)  // #5 빗길: 노면 재질 WET_MAT(Phong) + 물웅덩이 데칼 (+1 dc), 지오메트리 공유 그대로
buildTunnelSegment(len, { exit: true })                    // P1 비상구 문 + 보도 유도 표지, userData.exitPoint (라이더 대피 목표)
setTunnelLights(target, 'normal' | 'alarm' | 'wave', t, { waveS | waveZ }) : number
//  천장·어깨 등기구 발광 덮개(세그먼트당 첫 호출 때 생성, +1 dc) + 공유 셰이더. alarm = 빨간 비상 점멸 1.6Hz(빛웅덩이도 빨갛게),
//  wave = s ≥ waveS 인 등만 흰빛 (waveS 를 줄여 가면 앞에서 뒤로 '띵띵띵', 막 켜진 등은 더 밝게). 포인트 라이트 없음
export const TUNNEL_LIGHT_MODES, WET_MAT;
```

## fx.js
아트 디렉션: Crossy 풍 **작은 큐브 파티클**(InstancedMesh 권장, 풀링). 과장되고 통통 튀게.

```js
export class FX {
  constructor(scene, camera)
  update(dt)                         // dt = 게임 시간(슬로모션 반영). 매 프레임 호출
  sparks(pos, opts = {})             // 노랑/주황 불꽃 큐브 버스트. opts: { count=14, dir?: Vector3, speed=8 }
  explosion(pos, scale = 1)          // 불덩이(노랑→주황→빨강→검정) + 연기 + 파편. 크고 통쾌하게
  smokePuff(pos, opts = {})          // 회색 연기 큐브 상승. opts: { color, count, size }
  smokeTrail(object3d, duration = 2) // 지정 오브젝트 따라가며 연기 방출 (날아가는 원흉용)
  debris(pos, colors = [], count = 12)// 색 조각, 중력 + 노면(y=0) 바운스
  confetti(center, count = 120, spread = 30) // 알록달록 큐브가 넓게 흩날림
  shockwave(pos, radius = 8, color = 0xffffff) // 노면 링 확산
  twinkle(pos)                       // 하늘에서 반짝★ (원흉 퇴장). 크게, 1초
  hitFlash(pos)                      // 작은 흰 섬광
  hearts(pos)                        // 감사 하트/별 몇 개 위로 (해방된 차량 위)
  shake(intensity = 0.5, duration = 0.3)  // 누적 가능
  get shakeOffset()  : THREE.Vector3 // 매 프레임 카메라 position 에 더할 오프셋
  speedLines(intensity)              // 0..1. 카메라 주변 흰 줄무늬 (질주감). 0이면 숨김
  clear()                            // 모든 파티클 제거 (스테이지 전환)
}
```

## audio.js
전부 WebAudio 합성(외부 파일 없음). 첫 사용자 제스처에서 `init()`.

```js
export const audio = {
  init(),                 // AudioContext 생성/resume. 여러 번 호출 안전
  setMuted(bool), isMuted(),
  play(name, opts = {}),  // 원샷 SFX. opts: { volume=1, pitch=1, pan=0 }
  //  name: 'horn' | 'hornShort' | 'hornTruck' | 'hornAngry' | 'tack' | 'hit' | 'crit' | 'pop'(타이어 펑크)
  //        | 'explosion' | 'whoosh' | 'bump' | 'laneChange' | 'ui' | 'uiConfirm' | 'rageFull' | 'super'(미사일 발사)
  //        | 'superHit' | 'brakeScreech' | 'warn' | 'throw' | 'splat'(수박/커피) | 'launch'(날아감) | 'twinkle'
  //        | 'stageClear' | 'star' | 'cutin' | 'blink'(비상등 딸깍) | 'tauntBlip' | 'chicken'
  setEngine(speedMs, throttle01),   // 플레이어 엔진음 연속 갱신 (속도 0~40 m/s)
  startAmbience(kind),    // 'jam'(멀리서 랜덤 빵빵 + 웅성) | 'free'(바람) | null 정지
  cheerHorns(),           // 해방 순간: 여러 차 경적이 "대~한민국 (짝짝 짝짝짝)" 리듬으로 합주 (~3초)
  startMusic(kind),       // 'menu' | 'jam'(답답·느릿) | 'boss'(긴박) | 'release'(신나는 질주) — 간단한 칩튠 루프
  stopMusic(),
  duck(amount, seconds),  // 음악 일시 감쇄 (킬캠 등)
}
```

## ui.js (+ css/style.css)
아트 디렉션: Clash/Crossy 풍 **두꺼운 외곽선·통통한 버튼·강한 그림자**. 한국 도로표지 녹색(#0b7a4b)·고속도로 파랑(#1f4fa3)·경고 주황(#ffb400)·분노 빨강(#ff3b30). 폰트: Black Han Sans(타이틀), Jua(본문). 모바일 세로/가로 모두. 노치(safe-area) 고려.
`#ui` 루트(포인터 이벤트: 기본 none, 버튼만 auto) 안에 전부 동적으로 생성.

```js
export function initUI(handlers)
//  handlers: { onStartStage(index), onNext(), onRetry(), onMenu(), onToggleMute(), onControl(name, pressed) }
//  onControl name: 'left' | 'right' | 'fire' | 'super' | 'brake' | 'horn'   (터치 버튼 누름/뗌)
export const ui = {
  showTitle(stages, progress),   // 타이틀 + 스테이지 선택. progress: { unlocked: n, stars: {stageId: 0..3}, best: {stageId: score} }
  hideTitle(),
  showStageCard(stage) : Promise,// 스테이지 소개 카드(고속도로명/방향, 빌런 이름·대사, '정체 3.2km'). ~2.6s 후 또는 탭 시 resolve
  setHUD({ phase, speedKmh, distM, rage, score, combo }),  // phase: 'jam'|'boss'|'release'|'cruise'. rage 0..1 (3칸)
  setNav({ progress, released }),// 상단 내비 띠: 정체 빨강 → 해방되면 초록(released 0..1, 앞에서부터 초록). progress=플레이어 위치 0..1
  showBoss({ name, hp, tires }), // 원흉 HP 바 (hp 0..1, tires 남은 타이어 0..4 아이콘)
  hideBoss(),
  bubble(key, x, y, text, kind = 'taunt'),  // 화면 좌표 말풍선 생성/이동. kind: 'taunt'|'thanks'|'angry'|'player'
  removeBubble(key), clearBubbles(),
  popText(x, y, text, kind = 'hit'),        // 떠오르는 텍스트. kind: 'hit'|'crit'|'bump'|'score'|'warn'
  banner(text, kind = 'big', ms = 1600),    // 화면 중앙 큰 글씨. kind: 'big'|'warn'|'go'|'boss'
  setReleaseCounter(n | null),   // "해방된 차량 1,284대" 카운터 (null 숨김)
  showResult(result),            // { stageName, villainName, stars, score, stats:[{label,value}], isLast }
  hideResult(),
  setTouchVisible(bool),
  setMuted(bool),
  flash(color = '#fff', ms = 120),
  vignette(amount),              // 0..1 분노 빨간 비네트
  setPausedVisible(bool),
  hint(text, ms = 2600),         // (통합 중 추가) 상단 작은 튜토리얼 토스트
  // v0.2 보상·수집 (docs/REWARDS.md)
  // showResult(r): r.reward = { photo, villainName, violation, fine, payout, bonus, stars, wallet, views, subsGain, subs, comments[3], milestone, stageId, cause, speedKmh? }
  //   → 블박 제보 카드(과태료 고지서) + 포상금 흐름 + 참교육 채널 댓글 + 마일스톤(실버/골드 참교육 버튼). reward 없으면 기존 화면
  // showTitle(stages, progress, chapters?): progress.wallet/subs/album → 칩·앨범 버튼. stage.chapter 로 챕터 탭(활성 챕터만 렌더)
  showAlbum(stages?, progress?, chapters?), hideAlbum(),   // 블박 제보 앨범(도감)
}
// handlers 에 선택적으로 onAlbum(open) 추가 가능
```

## core (main / world / traffic / player / boss / weapons / input)
- 교통: IDM 차량 추종. 정체 최고속도 < 원흉 속도(선두 일렬 봉쇄 방지), 차선 단위 stop & go, **경적 → 앞차 양보**(`traffic.honk`), **고무줄 보조**(플레이어가 1.8초 이상 갇히면 옆 차선이 열림). 난이도는 `tools/sim/jam.mjs`로 검증.
- 보스: 25%마다 타이어 펑크(바퀴 분리) → 0이면 킬캠(히트스톱 0.16s + 슬로모 0.28×) → 하늘로 발사 → 반짝★ → 해방.
- 해방: `traffic.release()`가 앞→뒤로 70m/s 물결. 비상등 2회 깜빡 + 감사 말풍선 + 초록 물결 띠 + 내비 초록.
- `main.js`: 상태 머신 `TITLE → INTRO → JAM → BOSS → KILL → RELEASE → CRUISE → RESULT`, 카메라, 슬로모션/히트스톱, 저장(localStorage try/catch).
- 디버그: `window.__game` 노출. URL 파라미터 `?stage=N&skip=boss|release|result&auto=1&mute=1`.
  `auto=1` 이면 오토파일럿(차선 회피 + 자동 사격)으로 끝까지 진행 → 자동 플레이테스트용. `ff=N` 은 프레임당 1/30초 고정 스텝 N회(헤드리스 빨리감기).
- 회귀 테스트: `node tools/playtest.mjs [--page game/index.html] [--stages 1,2,3,4,5]` (전 스테이지 오토 완주 + 에러 검사).

## 스테이지 데이터 (v0.3, `stagegen.js` ← `data/villain_catalog.json`)
가설: 빌런 1종 = (이동 템플릿 + lane·count + 공격표 + 차종 + 도로·시간대 + 난이도) 조합이면, 엔진 템플릿 십수 종으로 100스테이지가 서로 다르게 느껴진다.

- 생성: `buildStages(CATALOG, HANDMADE)`.
  - 카탈로그 100종을 id 순서로 변환한다.
  - 손제작 5종은 `handmade_id`가 가리키는 자리(#1·#4·#9·#11·#50)에 들어간다. 금액·카드·챕터·보스 정보는 카탈로그 값을 쓴다.
  - 카탈로그 갱신 후 `node tools/catalog2js.mjs` 실행.
- 스테이지 필드 (기존 필드 외 추가분):

| 필드 | 의미 |
|---|---|
| `fine` / `payout` / `card` | 카드 표시용 실제 범칙금·벌금 / 포상금 기준(게임값) / 카드 종류: 고지서·형사·표창·계도 |
| `villains[].stopped/zig` | 정차형(비상등, 공격 시 돌진·스워브 없음) / 지그재그형(`zigCenter` ±1 차로를 휘저음) |
| `frontRow` | 빌런이 막지 않은 차로에만 저속 화물차·버스 벽 |
| `phases[]` | 보스·엘리트 페이즈. `{hp, attacks, stopped, zig, slow, label}`. `hpFrac() ≤ hp`일 때 공격표와 이동 성격을 바꾸고, 배너와 히트스톱을 낸다(`boss.update` 이벤트 `{type:'phase'}`) |
| `honkOnly` | 구조형(졸음·고장·대피). 압정·폭탄 대신 경적이 게이지를 깎는다. 타이어 펑크 없음. 마무리는 갓길 비상등 정차(`finish 'pullover'`)이고 하늘로 날리지 않는다 |
| `boss` / `elite` | HP 1.6배 / 1.3배 |
| `displayKm` | `jam_causality`에 'Nkm'가 있으면 그 값, 없으면 난이도로 추정. 해방 차량 수 = km × 4 × 125대/km |
| `wrongWay` | #83 역주행. **현재 미구현**: 일반 정속형 + 경적 전용으로 대체 |

- 엔진 미지원(카탈로그에만 있음): 페이즈별 차 대수 변경, summon(벽 소환 → 굴리기로 대체), 게이트·데칼·터널 소품(`new_assets`).

## v0.4 코어 계약 (판 차별화)
가설: 판 차별화 = 보이는 시그니처 행동 × 그 행동이 만드는 정체 모양 × 판별 접근·요령. 공통 엔진은 두고 판별 차이를 데이터와 모듈로 끼운다.

- **내구도(HP)**: `TUNE.hp`.
  - `main.applyDamage(raw, reason)`: 판 배율(`stageDamageMul`)을 곱하고, 정체 구간 하한은 20이다.
  - 0이 되면 `wreck` 단계 → `ui.showFail` → `retryFromDiscovery()`.
  - 재도전 시 빌런 HP·펑크·페이즈는 유지되고, 분노는 원인 발견 시점 값, 포상금은 ×0.8씩 줄어 최저 ×0.6.
  - 차량 손상 단계는 `VEH.setDamage`로 표시한다.
- **접근 규칙**: `stage.approach` = `{ shoulder, honk, gapCheck, fatigue, rubber, rubberSafety, rageHorn, hint }`. 기본값은 `TUNE.approach`, 1챕터 값은 `stagegen.APPROACH_BY_ID`.
  - 갓길 모드 `open | crowded | blocked | closed | dark | debris | none`. `closed`와 `none`은 플레이어가 갓길로 진입할 수 없고, 정체 85m에서 2차로로 시작한다.
  - 끼워주기는 실제 틈(내 차 길이 + 1m)이 있을 때만 된다.
  - 경적 쿨은 1.0초. 같은 차에 2회째는 50%, 3회째는 무시한다.
  - 고무줄은 판별 시간이고, 4초가 넘으면 강제로 연다.
  - 분노의 경적 반경은 24m이고, 고장차는 견인하지 않는다(레커 장착 또는 occupied 판만).
- **JamShaper** (`traffic.js`): `stage.jamShape` = `{ lanes: [packed|train|flow|spaced|pass ×4], passV, sources: [{ type: 'yield', lane, hold, period }] }`.
  - `pass` 차로에는 앞줄 벽이 없고 빌런을 지나간다. 유일한 추월 차로다.
  - `emitBrakeWave(lane, s, strength, { amp, speed, hold })`: amp < 1이면 감쇠, amp > 1이면 유령정체처럼 증폭된다.
- **시그니처 모듈** (`game/js/behaviors/index.js`, `stage.sig`): 인터페이스는 파일 머리 주석에 있다.
  - 구현된 모듈:
    - `blinker_liar`(1-5)
    - `tailgater`(1-6)
    - `occupy`(1-1)
  - `fight.gap`과 `lockAt`은 전투 위치다(정면 +11 / 측면 +1.5 / 들러붙기 +0.6). `sameLane`이면 빌런 차로에 들어가야 고정된다.
  - 이벤트: `sigPop`, `sigToast`, `sigFinal`, `sigKill`.
  - 모듈 소품 차량(`sigBodies`: 피해차, 암행)은 traffic 버킷에 들어가 충돌한다.
  - `auto()`는 오토파일럿용 정석 루트다.
