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
