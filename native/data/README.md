# native/data — 콘텐츠 원천과 생성물

가설:
- ✅ 네이티브가 쓰는 콘텐츠는 동결 웹(`web-frozen` = **753549a**)의 game/js 모듈을 DOM 없이 Node에서 그대로 돌려 한 번에 뽑을 수 있다. M1-0 이후 원천은 `src/*.json` 한 곳이다.
- ✅ 1-1 traffic RNG(mulberry32(1007))·spawnJam 결과·호출 지점 태그 트레이스는 골든으로 뽑히고, 라이브 웹 페이지(가상 시간 Playwright)의 값과 비트 단위로 같다. 틱 골든은 기록한 입력만으로 Node에서 비트 단위로 재생된다.
- ❓ C++ traffic 코어가 이 골든과 비트 단위로 맞는지는 M1a에서 확인한다. `sin`은 libm마다 마지막 ulp가 달라서 재생 테스트는 기록된 `sinLf`를 써야 한다(아래 "수학 함수").

## 무엇이 원천이고 무엇이 생성물인가

| 경로 | 종류 | 누가 고치나 |
|---|---|---|
| `native/data/src/*.json` | **원천** (M1-0에 1회 export, 그 뒤 사람이 고치는 곳) | 사람 |
| `native/data/*.json` | **생성물** (`tools/content/build.mjs`가 src에서 만든다, 커밋함) | 아무도 손으로 고치지 않는다 |
| `native/tests/golden/*.json` | 웹 오라클 골든 (`tools/export-content.mjs`가 동결 웹에서 만든다) | 아무도 (웹이 동결이라 바뀌지 않는다) |
| `tools/content/stagegen.js` | 빌드 도구 소유 stagegen (game/js/stagegen.js 복사본 + 판별 표 주입) | 사람 (M3 패밀리 스키마 등) |

웹(`game/js`)은 고치지 않는다. 태그 `web-frozen`은 로컬에만 있다(git 프록시가 태그 push를 막음) — **SHA 753549a**로 참조한다.

### src (원천)
| 파일 | 내용 | 웹 출처 |
|---|---|---|
| `config.json` | 도로 기하, NPC 차종 가중치·색 순서, `tune`(TUNE, approach 제외), **`traffic.*`(traffic.js 인라인 상수: IDM `b`·`delta`, 차로 종류별 `T/s0/aMax/v0Mul`, 스폰 간격·추첨 범위, 이벤트 상수)**, `setup`(main.js setupStage), `rng` | config.js, traffic.js, main.js, world.js |
| `stages.json` | **100판 해석본 = 판 데이터의 진실**. `road:[{type:'straight'}]` 포함 | stagegen.buildStages(catalog, handmade) |
| `villain_catalog.json` | 리서치 카탈로그(100종 + chapters) | data/villain_catalog.js |
| `handmade_stages.json` | 손제작 5판 (stagegen 입력) | config.js STAGES |
| `approach.json` | `default`(=TUNE.approach, 런타임) · `byId`(stagegen 입력) · 갓길/경적 모드 라벨 | config.js, stagegen.js, ui.js |
| `jamshape.json`, `sig.json` | 판별 JamShaper · 시그니처 모듈 표 (stagegen 입력) | stagegen.js |
| `sky.json` | SKY 프리셋 7개 + `stageSky`(판별 하늘 덮어쓰기) | config.js, stagegen.js |
| `shop.json` | 상점 품목 + 기본 장착 | config.js |
| `mini_types.json` | 잔챙이 빌런 (**배열 순서 = RNG 순서**) | config.js |
| `lines.json` | `tables`(*_LINES) + `inline`(main/boss/behaviors/rewards의 한글 리터럴 전부, id = `file:line[#n]` 임시 키) | config.js, main.js 등 |
| `cards.json` | 처분 카드 표(고지서·형사·표창·계도), 판 등급 배지 | ui.js |
| `haptics.json` | 햅틱 맵(sim 이벤트 이름 → iOS 패턴 / Android 폴백). 웹 `fx.shake` 13곳 모두 대응 | NATIVE_PORT §2 |
| `vehicle_kinds.json` | 차종별 variants·canon·colorVariant·**변형별 치수 L/W/H** (sim이 메시 대신 읽음) | vehicles.js KINDS + 실제 buildVehicle |
| `export_meta.json` | export에 쓴 game/js 파일들의 sha256 | — |

`traffic.*`·`setup`의 각 값 옆 `_src`는 웹 소스 줄(`traffic.js:406`)이다. export는 그 줄에 그 숫자가 실제로 있는지 검사하고, 없으면 실패한다.

### 생성물 (`native/data/*.json`, DB autoload가 `res://data/<name>.json`으로 읽음)
`config, stages, chapters, shop, mini_types, lines, cards, sky, approach, haptics, vehicle_kinds` + `manifest.json`(각 출력과 원천의 sha256).
`_doc`, `_src` 같은 `_` 메타 키는 빠진다. 키는 정렬되고 출력은 결정적이다. stagegen 입력(catalog, handmade, jamshape, sig, approach.byId)은 이미 stages.json에 들어가 있어서 복사하지 않는다.

## 다시 만들기
```bash
# 판·표를 고친 뒤 (가장 흔한 경우): 검증 + 생성물 갱신
node tools/content/build.mjs
node tools/content/build.mjs --check          # 생성물이 원천과 다르면 exit 1 (T0 / CI)

# 카탈로그나 approach/jamshape/sig/sky 표를 고쳐서 100판을 다시 뽑을 때
node tools/content/build.mjs --regen-stages   # tools/content/stagegen.js로 src/stages.json을 다시 씀
#   build는 매번 "stagegen drift: N"을 출력한다(손으로 고친 판 수). --strict면 drift가 있을 때 실패.

# 웹 export·골든 (M1-0 1회. 동결 웹이 기준이라 다시 돌려도 결과가 같아야 한다)
npx http-server . -p 8090 -c-1 -s &           # 레포 루트를 8090에 (Playwright 웹 오라클용)
node tools/export-content.mjs --check         # 지금 파일들이 동결 웹 export와 같은지 (약 4분, 600틱 웹 녹화 포함)
node tools/export-content.mjs --no-web        # Playwright 없이 (웹 대조·틱 골든 생략)
```
- export-content는 `game/`이 753549a와 다르면 거부한다(`--allow-dirty`).
- **src를 손으로 고친 뒤 export-content를 다시 돌리면 덮어쓰지 않고 실패한다**(`--force`로만 웹 값으로 되돌린다). 골든은 웹에서만 나오므로 언제든 다시 만들어도 같다.

## 데이터 규칙 (이식할 때 지킬 것)
- **순서가 동작인 것은 배열이다.** JSON 키는 정렬되므로 순서가 의미 있는 표는 객체로 두지 않는다.
  - `config.npc.kinds` (pickWeighted 순서), `npc.colorsMono/Pop`, `mini_types.types` (`types[floor(rng*n)]`)
  - `stage.attacks`, `stage.phases[].attacks` = `[[kind, weight], …]` (boss.js가 표를 순서대로 돌며 가중 추첨)
  - `stage.frontRow` = 길이 4 배열 (index = 차로, 값 = 차종 | null)
- `null` = JS에서 그 키가 없었음(`??`·truthiness로 읽힘). 모든 판·빌런은 같은 키 집합을 갖는다.
- 색은 `0xRRGGBB` 정수, 거리 m, 속도 m/s, 시간 s.

## 골든 (`native/tests/golden/`)
| 파일 | 내용 |
|---|---|
| `rng_stage1.json` | 시드 1007의 mulberry32 처음 1000개: `u32[i]`와 `f64[i]`(=u32/2³², 17자리), 알고리즘 소스 |
| `rng_trace_stage{1,5,6}.json` | spawnJam 중 traffic `rng()` 호출 전부: 순번, **호출 지점 태그**(`lane/car.seed`, `shoulder.jitter`, `obstacle/breakdown.kind`, `opp.v` …), 소스 위치, 값. **계약의 원천** (NATIVE_PORT 3-3). 1-1은 1051회 |
| `spawn_stage{1,5,6}.json` | setupStage 경로의 spawn 결과: 차 전부(id, kind, lane, s, x, v, len, w, isWall/frontRow, wallOffset, cheater, personal, phase, color, seed, variant, mini), 장애물(+ 고장차 차종·색·회전, 낙하물 조각), 반대편 26대, 빌런, **플레이어 시작**(s 0, lane 3), traffic 상태, 다음 추첨값 |
| `traffic_ticks_stage1.json` | 라이브 웹 1-1(`?stage=1&skip=jam`, 플레이어 무입력)의 `Traffic.update` 600틱: 틱마다 **입력**(dt, time, phase, player, villains, extras, sinLf)과 **출력**(차 s/v/lane, 차선 변경 중 x, 반대편 s, 장애물 수, 그 틱의 rng 추첨 [태그, u32]) |

- 1-1 spawn은 NATIVE_PORT 3-3 기준값(126대, 1차로 버스 s=200.4453, 고장차 109.681 len 7, 콘 147.518, 잔챙이 131.90/66.63, 다음 추첨 0.3714370721)과 같고, 라이브 웹 페이지의 첫 프레임 전 상태와 모든 필드가 같다(export가 매번 검사).
- **웹 dt는 가변이다.** `main.js frame(now)` → `step(min(0.05, (now−last)/1000))`(rAF마다, `?ff=N`이면 1/30×N). 틱 골든은 가상 시간으로 rAF를 120Hz로 돌려서 dt ≈ 1/120이지만 부동소수 누적 때문에 비트 단위로 일정하지 않다 → **틱마다 `in.dt`를 그대로 쓴다.**
- 웹의 `Math.random`(보스 공격, 도발, fx)은 녹화 때 시드 mulberry32(`math_random_seed`)로 고정했다. traffic 상태에는 들어가지 않는다.
- 재생 방법(C++ T0 테스트도 같음): spawn 후 틱마다 player/villains/extras 필드를 `in.*`로 맞추고(객체 identity 유지) `update(in.dt, {time, phase, allowEvents, focusS, player, villains, extras})`를 부른 뒤 `out.*`와 비교한다. Node 재생은 600틱 전부 비트 단위로 일치한다.

### 수학 함수
sim 상태에 들어가는 초월함수는 packed 차로의 stop&go 계수 `sin(t·0.42 + lane·1.9)`(traffic.js:406) 하나뿐이다. 이 값은 엔진·libm마다 마지막 ulp가 다르다(이번 실행 표본 13175개 인자 중 Chromium 141과 Node 22가 96개에서 다름, glibc 2.39 `sin`은 Chromium과 13174개 일치). 그래서 틱 골든은 `in.sinLf[lane]`를 기록하고, 비트 단위 재생은 그 값을 쓴다. IDM의 `Math.pow(x, 2)`는 `x*x`와 같고(표본 10962개), `sqrt`는 정확하며, `atan2`는 화면용 yaw에만 쓰인다.
