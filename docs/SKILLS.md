# 스킬 · 분노 사다리 · 아이템 · 피니시 (SKILLS)

가설:
- ❓ **H-S1 쾌감 = 예고 → 임팩트 → 해소가 같은 틱에 맞물릴 때.** 지금 분노 폭탄은 임팩트 층이 얇고(폭발 1개 + `superHit`, 히트스톱 0) 단계도 하나라 "큰 압정"처럼 느껴진다. 분노 5칸을 **1·3·5칸 사다리**로 나누고, 단계가 오를수록 히트스톱·슬로모·카메라·파티클·SFX·햅틱을 키운다.
- ❓ **H-S2 분노 버튼은 '탭 = 지금 쓸 수 있는 최고 단계'.** ~~홀드 차징~~ → ❌ 기각: 약점 창이 1.5 s뿐이고 오른손 엄지는 압정을 누르고 있다. 아껴 쓰는 선택은 "누르지 않고 기다리기"로 충분하다.
- ❓ **H-S3 차고 '날아가는 것'(`mv_jump`, `mv_drone`)을 액티브 버튼 2개로 바꾸면 '사서 쓰는 손맛'이 생긴다**(SHOP.md H19 루프).
- ❓ **H-S4 (r3, 피드백 2 "압정 콤보 5, 10개 등 특정 구간마다 큰 스킬")** 압정을 끊기지 않고 맞힌 수가 5·10·15·20(20 주기)에 닿으면 큰 스킬이 저절로 나가야 "압정만으로는 너무 오래 걸린다"가 풀린다. ✅ 시뮬: 1-1~1-4 압정+콤보 원흉전이 17.5–18.0 s다(전에는 압정만 1-2 41 s, 1-4 60 s). ❓ 손맛과 '1초마다 터지는 소음'인지는 기기에서 본다(§0-2).
- ✅ **코드 확인: iPhone에서 도는 GDScript 폴백(`_Creep`)에는 `rage_horn`·`mini_target`·`mini_hit`·`cars_behind_front`·`drop_walls`가 없다**(빈 값 또는 no-op, `sim/traffic_bridge.gd:442-481`). 그 결과는 두 가지다.
  - 정체에서 압정을 누르면 맞힐 잔챙이가 없다. `game_sim.gd`의 `fire_edge and mini_id == 0 → want_honk` 때문에 늘 경적이 된다(피드백 3의 원인).
  - 분노 경적은 부스트만 낸다.
  - 결론: 원흉전 스킬은 BossSim(순수 GDScript)만 쓰므로 폴백에서도 안전하다. 정체 스킬은 폴백 구현이 먼저 있어야 한다(§2-5).

관련 문서: DESIGN_REVIEW_2026-10-13 P0#7(큰 피해는 시그니처 창에서), #14(톤 안전장치) · NATIVE_PORT N2/N4, 햅틱 맵(2절) · SHOP.md · V04_SPEC(퍼펙트 회피 +0.04) · 웹 오라클 `game/js/main.js` rageHorn/onWeaponHit/kill, `weapons.js` fireMissile, `boss.js` _updateFinish.

---

## 0-2. r3 압정 콤보 · 범용 빈틈 창 · 분노 필중 (3차 기기 피드백 2, 값의 기준은 `native/data/src/config.json` `skills.combo`)

가설: ✅ 피드백 2의 원인은 세 가지였다. ① 압정을 쌓아도 보상이 없다. ② 1-2~1-10에는 약점 창이 아예 없어서(`BEHAVIORS = {occupy}`뿐) 압정 1과 분노 dmgOut만 들어간다. ③ 분노 t1은 잠금 전에는 갓길 경적이라 원흉 피해가 0이고, 잠금 뒤에는 30 m·±1차로라 헛방이 난다. C++ 변경 없이 GDScript(`skills_sim.gd`, `behaviors/generic_window.gd`)만으로 풀고, 폴백과 C++가 같은 숫자를 낸다.
~~기본은 ×10 따다닥 / ×20 타이어 저격, 5·15는 신호만~~ → 사용자 원문 "5, 10개 등"을 따라 5도 실제 스킬이다(main_overrides). 5발/s라 ×5마다 큰 스킬을 주면 1초마다 터지므로, c5는 가벼운 2타로 둔다.

**콤보 규칙** (`SkillsSim` 채널 `combo`: busy·무적·boss hold에 관여하지 않는다)
- +1: 보스 단계(잠금 전후 모두)에서 살아 있는 원흉에 맞은 압정 1발(`GameSim._on_landing` → `skills.on_tack_hit`). 스킬·콤보 타격과 잔챙이는 세지도 끊지도 않는다.
- 끊김: 집계된 적중 없이 sim 1.5 s(`timeout`, 근거: 적중 간격 p90 0.21 s, 엄지를 뗐을 때 0.56 s, 차로 회피 최대 1.79 s) → `combo_break{reason:"timeout"}`(n ≥ 5일 때만 이벤트). 피해가 들어간 피격(`on_player_hit`) → `combo_break{reason:"hit"}`(항상).
- 마일스톤 = `milestones[n mod cycle]`(0이면 cycle). 대상은 그 압정이 맞은 원흉(1-3 듀오). 마일스톤 압정이 마지막 원흉의 처치타면 발동하지 않는다(피니시 위에 겹치지 않게). 듀오면 살아 있는 쪽으로 간다.

| n | id | 이름 / 라벨 | 타격 (마일스톤 압정 뒤 sim s) | 한 타 피해 (max HP, 창 밖 / 창 안) | 그 밖 | 점수 |
|---|---|---|---|---|---|---|
| 5, 15 | `c5_double` | 따닥 / `따닥!` | 0.12, 0.18 | 0.5 % / 1.2 % | 압정음 2개, 카메라·플래시 없음, 햅틱 `combo5` | +50 |
| 10 | `c10_burst` | 따다닥 / `따다닥!` | 0.15, 0.21, 0.27 | 1.0 % / 2.5 % | 금색 압정 3개가 지붕에 박힌다, tack 피치 1.1/1.25/1.4 + crit, `combo10` | +100 |
| 20 | `c20_snipe` | 타이어 저격 / `타이어 저격!` | 0.25 | 5 % / 9 % | 펑크 1 + 공격 취소 + 경직 0.8 s(stunCap·stunImmune 준수 = 약점 창), 히트스톱 0.04, 2.2배 압정이 앞바퀴에, whoosh → pop + crit + explosion, `combo20` | +300 |

- 20 주기로 반복한다(25 = c5, 30 = c10, 40 = c20 …). `skills.minKillT` 하한을 지킨다.
- 이벤트: `combo_milestone{n, id, target_id, skill, label, name}`, `skill_start/skill_hit/skill_end{chan:"combo", id, key, n, combo}`, `combo_break{reason, n}`. `FightFx.SKILL_EVENTS`가 `combo_break`·`combo_milestone`을 SkillCues로 넘긴다(r3 통합, 끊김 햅틱 `comboBreak`는 이벤트로 1회, state 하락은 보조 경로).
- `state().skills.combo` = `{n, left, next_n, next_id, next_name, best, timeout, cycle, marks [5,10,15,20]}`. HUD 콤보 배지(우상단): `×N`, 20칸 진행바, 5·10·15·20 눈금, 다음 보상 이름 `→10 따다닥`, 타임아웃 선. 마일스톤 라벨은 배지 아래에 팝으로 뜨고(중앙 배너 아님), `hit` 끊김은 회색으로 흔들리며 `콤보 끊김`, `timeout`은 0.45 s 페이드. 보스 단계 밖이나 n = 0이면 숨긴다.
- `stats.combo`(점수 배율)와 `max_combo`(별점)의 의미는 바뀌지 않았다.

**범용 빈틈 창** (`sim/behaviors/generic_window.gd`, `config.boss.genericWindow {on, period 4.5, dur 1.2, first = period − dur}`)
- 시그니처 모듈이 아직 없는 판(지금 1-2~1-10)에 GameSim이 붙인다. 잠금 뒤 BossSim 시간으로 4.5 s마다 1.2 s 동안: `vulnerable` 1.5(압정 ×vulnMul), 공격 정지, 예고 취소, 원흉 말풍선 `헉헉… (빈틈!)` + stun 이벤트(`약점!` 레티클). 힌트 `발사 꾹 · 빈틈 노려`. 진짜 시그니처가 이식되면 저절로 빠진다.

**HP 비율 피해 · 배율**
- t1 `dmgInFrac` 0.05 / `dmgOutFrac` 0.04, t3 0.18 / 0.14(4타 분할), t5는 그대로. 판마다 t3 비율이 같고(1-1·1-4 창 밖 14.00 %), 칸당 피해가 t3 ≥ t1이다.
- `skills.hpMul` 1.45 → 1.7. `stages.json` `skillHpMul` 1-1 1.8, 1-2 1.5, 1-3 0.75(듀오). 1-1·1-2는 배율 없이 pilot 8.6/9.2 s라 10 s 게이트에 못 미쳐서 측정으로 정했다.

**분노 필중 (C3)**
- `mode()`는 보스 단계에서 원흉이 살아 있으면 잠금 전에도 `fight`다. 잠금 전 사다리는 `preLockLadder [1]`(t1만, t3·t5는 잠금 뒤).
- t1 대상 = `|ds| ≤ reach 60 m`인 살아 있는 원흉 전원, `laneRange 99`(차로 무관). 지연 = 0.12 + max(0, |ds| − 15) × 0.00833 s(20 m 0.162, 55 m 0.453, 60 m 0.495).
- 잠금 전 시전이면 같은 틱에 `_rage_horn_effect(2.2)`(갓길 24 m 청소 + 부스트, `via:"t1_wave"`)도 나가고 경직은 `stunPreLock` 0.4 s다. 잠금 전 시전은 `boss.hold`만 걸고 플레이어 무적은 주지 않는다(정체 범퍼 규칙 유지).
- 60 m 밖이면 `chase` 0.8 s 동안 부스트로 다가간 뒤 다시 본다. 그래도 밖이면 분노를 돌려주고 `skill_denied{reason:"far", refunded:true}` + `너무 멀다!`. 비활성 표시는 하지 않는다.
- 분노 t1은 병목 마개를 즉시 날린다(`neck.open("rage")`, exit fly, 보너스는 1-9 정답 동사일 때만).
- 연출(C4·F1): 전투 t1은 키 `t1_wave` `충격파!!`(sk_wave → superHit → explosion, hornTruck 없음, 원흉 쪽 카메라 킥 0.6 m / 0.12 s). 잠금 전 충격파의 `rage_horn`은 경적음(hornTruck·superHit)과 무작위 흔들림 없이 링만 낸다(`game.gd`, `fight_fx.gd`). 정체 t1_horn은 `갓길 청소!!` + 경적음 그대로. 분노 버튼 색 #e0245e(경적 #f08a1a와 hue 48° 차), 얼굴은 `state.skills.face`(청소 / 충격파 / 폭격 / 참교육).

**측정** (`tests/test_e2e_skills.gd`, 1-1~1-4 × 시드 5 × {C++, 폴백}, 두 백엔드 숫자가 같다)

| 정책 | 게이트 (마개 끔, 잠금 → 처치 중앙값) | 결과 (1-1 / 1-2 / 1-3 / 1-4) |
|---|---|---|
| pilot (분노·아이템 사용) | 10–16 s | 10.9 / 12.1 / 12.0 / 11.3 s |
| 압정 + 콤보 (분노 안 씀) | 13–21 s | 17.6 / 17.5 / 18.0 / 17.9 s (전: 압정만 1-2 41 s, 1-3 52 s, 1-4 60 s) |
| 엉성한 엄지 (사격 69 %) | ≤ 26 s | 20.1 / 22.2 / 22.0 / 21.5 s |

- 판당(1-1~1-4, 마개 끔) c20 2~4회, c10 2~5회, c5 4~10회. 첫 c20은 잠금 후 1.6~7.5 s(콤보를 잠금 전부터 세므로 프로토의 4.7~6.9 s보다 이를 수 있다, 게이트 `FIRST_C20_MAX` 8 s).
- 보스 구간 `skill_denied{target}` 0회(두 백엔드 × 3 정책 × 5 시드, 1-5~1-10 포함).
- 마개 켬(출시 기본, r3 통합): 아래 NATIVE_PORT §9 r3 절의 '원흉전 길이' 표.

## 0-1. 2026-10-14 리뷰 반영 (검토 rvA·rvB 뒤, 값의 기준은 `native/data/src/config.json`)

가설: ✅ 남은 막힘은 세 가지였다. ① 정체 점프가 빌런을 뚫는다. ② 폴백에서 MAX가 안 나온다. ③ 처치 프레임이 하얗게 날아가고 숫자가 겹친다. sim·데이터·뷰만 고쳐서 풀린다.

- **정체 점프(`mv_jump`, 레거시 `&"jump"`)**: `GameSim.jam_hop`이 시전 때 착지 칸을 고른다.
  - 내 차로의 차·갓길 장애물·빌런을 앞에서부터 본다. 한 대 이상 넘고, 차 길이 + `jamSlotPad` 0.7 m가 들어가는 첫 틈에 착지한다(`jamReach` 19 m 안).
  - 빌런은 넘지 않는다. 바로 앞이 빌런이거나 빌런 전에 칸이 없으면 거부한다(`blocked`, HUD `원흉은 못 넘는다!`). 칸이 없으면 `room`(`착지 공간 없음`)이다.
  - 공중에서는 s를 착지점으로 부드럽게 옮긴다(`PlayerSim.glide`). 착지 순간 순간이동은 없다. 체공 중에도 빌런과는 충돌한다.
  - 폴백(`_Creep`, iPhone 경로)은 짧은 틈(`jamMinSlot` 1.2 m)에도 착지한다. 넘은 차는 14 m/s로 뒤로 밀려 자리를 내준다. 플레이어를 기준으로 리더를 잡고(중심 기준), 겹친 차는 뒤로 밀린다. 네이티브 C++은 겹친 차를 멈추게만 하므로 엄격한 칸(차 + 0.7 m)만 쓴다.
- **분노 경제**: `rageGain.lock` 0.2 → 0.3. 폴백 + 점프·드론에서 잠금 시 분노가 약 0.32라 MAX가 0/10이었다. 지금은 `test_e2e_economy`에서 10/10이 MAX를 거쳐 t5 처형까지 간다(원흉전 14–15.5 s).
- **피해**: t1 16/8 → 12/6, t3 창 밖 12 → 20, `hitGap` 0.05 → 0.1(4타가 한 덩어리로 뭉개졌다), `tacks` 12 → 18, t5 `delay` 0.35 → 0.45(도장이 내려앉기 전에 임팩트가 왔다).
- **플래시**: t5 `["fff1c4", 0.45, 70]`, kill은 `Color(1, 0.96, 0.85, 0.4)` 0.1 s다. 처치 틱에는 레시피 플래시를 건너뛰고 kill 플래시 하나만 낸다. 흰 플래시 두 겹이 처형 프레임을 지웠다.
- **숫자**: 표시만 ×10(`Hud.DMG_SHOW_MUL`). `치명!`은 창 안 스킬 합계에만 붙인다. 압정 창 히트는 `-40!`로 뜬다. 스킬이 맞는 원흉 위에서는 압정 숫자를 생략한다. 팝은 1.6 m 오르고 화면에서 서로 비켜 쌓인다(최대 3칸). 처치 때 남은 팝은 지운다. 같은 때 원흉 도발 말풍선은 0.8 s 생략한다.
- **분노 버튼**: t1 얼굴은 `충격파`(파동 글리프)다. 경적 버튼과 같은 '경적' 얼굴이라 압정 위에서 경적처럼 읽혔다. 버튼을 압정에서 22 → 44 u 띄우고, 터치 존 grow를 4 → 0으로 줄였다.
- **배너**: `SKILL_BANNER_Y` 0.26 → 0.20, 도장 0.85×. 아이템도 시전 배너를 띄운다(`점프!`, `드론 폭격!`). `쿵!` 팝 수명은 1.25 → 0.85 s다.
- **기타**:
  - t3 압정에 전용 밝은 재질을 쓴다(공중 2.4× → 착지 1.7×). 첫 임팩트에 `explosion` + `superHit`가 난다. `sk_carpet`은 0.32 s에 나간다. 햅틱 `skillT3Hit`는 0.8이다.
  - 점프 체공 중 내 차가 1.25×로 커지고 앞이 들리며, 착지 때 찌그러진다. 로켓 피니시 샷을 넓혔다.
  - 1-2 지그 빌런은 내 차 옆으로 파고들지 않는다.
  - 3손가락 개발 패널은 빈 화면 손가락 3개가 0.3 s 안에 닿을 때만 열린다.
  - Debug 빌드 설정에 `테스트: 아이템 체험`을 추가했다.

## 0. 지금 상태 (2026-10-14 네이티브 M1b)

| 항목 | 지금 | 문제 |
|---|---|---|
| 분노 | 5칸(`tune.rageSegs` 5, `superCost` 0.2). 잠금 전에는 분노 경적(1칸, 갓길 24 m 청소 + 부스트 2.2 s), 잠금 뒤에는 분노 폭탄(1칸, 0.62 s 유도탄, 창 안 16 · 밖 8) | 단계가 하나다. 폭탄 명중 연출은 폭발 1 + `superHit` + 플래시 0.1 s뿐이고 히트스톱과 슬로모가 없다 |
| 분노 표시 | 분노 버튼의 원형 링(5눈금) + 하단 막대 행(`hud._rage_row`) | 같은 정보가 두 번 나온다(피드백 2). 막대를 지우고 링만 남긴다(§2-4) |
| 처치 | 히트스톱 0.16 s, 슬로모 ×0.28 1.25 s, 로켓 2.15 s(sim), `releaseDelay` 0.95 s. 해방까지 실시간 **약 4.0 s**. 풍선·헬기·UFO는 sim 3.2–3.8 s라 **5–5.7 s**이고 뷰 소품이 없다 | 길다. 궤도 카메라 때문에 위아래가 잘려 보였다(기기 피드백). 레터박스는 이미 뺐다 |
| 아이템 | 점프: `player.jump()`는 있지만 소유 확인과 쿨이 없다. 드론: 네이티브에 없다. `Progress.loadout()`이 `jump/drone`을 주지만 GameSim은 `options.finish`만 읽는다 | 차고에서 산 것이 판에 나오지 않는다 |

---

## 1. 원칙: 폰에서 처치가 시원하려면

1. **3박자를 지킨다.**
   - 예고(0.1–0.35 s): 버튼이 눌리며 찌그러지고 차징음이 오른다. 빌런이 "어?" 한다.
   - 임팩트(1틱): 흰 플래시, 히트스톱, 카메라 펀치, 파티클 폭발, 저음 SFX, 강한 햅틱을 **같은 틱**에 낸다. 햅틱은 실시간으로 바로 울린다(Haptics 규칙).
   - 해소(0.3–1.0 s): 슬로모에서 0.2 s 동안 정상 속도로 돌아온다. 빌런이 반응하고, 숫자 팝·콤보·점수가 뜬다.
2. **시간 예산**(실시간 기준, 히트스톱과 슬로모 포함)
   - t1 ≤ 0.5 s, 아이템 ≤ 1.0 s, t3 ≤ 1.2 s, t5 ≤ 2.5 s, 피니시 ≤ 2.5 s.
   - 0.5 s(피니시는 0.6 s)가 지나면 **화면 탭으로 건너뛴다.**
   - 피해·처치 판정은 임팩트 틱에 이미 끝난다. 건너뛰어도 sim 결과는 같다(§7 테스트).
3. **조작을 오래 뺏지 않는다.**
   - t1, t3, 아이템: 차선과 압정 조작이 그대로 살아 있다. 카메라는 펀치나 리프트만 하고 0.6 s 안에 돌아온다.
   - 카메라를 가져가는 것은 t5와 피니시뿐이다.
   - 시전 중에는 플레이어가 무적이고(`player.invuln` = 시전 시간 + 0.2 s), 빌런 공격은 멈춘다(`blocked`).
4. **슬로모·시네마틱 간격**: 6 s(`skills.cineGap`) 안에 다시 나오면 슬로모 없이 펀치만 준다. 매번 멈추면 리듬이 죽는다.
5. **읽히게 만든다.** 큰 글자는 6자 이하로 쓴다(`분노 경적!!`, `압정 폭격!!`, `참교육!!`). 숫자는 합산해 1번 크게 띄우고, 다단 히트는 작은 틱으로 보인다. 화면을 3분할했을 때 임팩트 지점이 가운데 띠에 들어와야 한다(CameraRig FRAME_Y 20–74 %).
6. **결정적으로 동작한다.**
   - 시간 배율은 GameSim의 `hitstop`/`slow_until`/`slow_scale`로만 준다. `Engine.time_scale`은 쓰지 않는다.
   - 무작위는 GameSim과 BossSim의 시드 RNG만 쓴다.
   - FX는 `fx.advance(real_dt × sim.time_scale())`로 함께 느려져야 슬로모가 읽힌다. 지금 game.gd는 실시간으로 넘긴다.
7. **톤**(DESIGN_REVIEW #14): 만화 같은 단속·견인 패러디로 둔다. 들이받기, 부상, 운전자 피해 묘사는 금지다. 빌런은 반성 대사를 하고 웃기게 퇴장한다. 점프는 빌런 차 위가 아니라 **앞 노면**에 착지한다. 정체에서는 빌런을 넘지 않는다(§0-1 `jam_hop`).
8. **발열**: 파티클은 FightFx 상한(lit 700 · glow 700 · smoke 220) 안에서만 쓴다. t5에서 상한에 걸리면 컨페티부터 줄인다. Decal 풀은 8개다.

---

## 2. 분노 스킬 사다리

### 2-1 단계 선택: 탭 = 쓸 수 있는 최고 단계

- 사다리는 `[1, 3, 5]`칸이다. 칸 수 `segs = floor(rage × 5 + ε)`.
- **원흉전(정면 잠금 후)**: 탭하면 `segs` 이하에서 가장 높은 단계가 나간다. 2칸이면 t1(1칸 남음), 4칸이면 t3(1칸 남음), 5칸이면 t5다.
- **정체·잠금 전**: 칸 수와 관계없이 **항상 t1(분노 경적)**이다. 정체에서 MAX를 날리는 일을 막는다. 링에서 3·5 눈금은 어둡게 자물쇠로 보인다.
- 위로 스와이프도 같은 탭이다. 길게 눌러도 탭으로 처리한다(누르는 순간 1회).
- 이렇게 정한 이유:
  - 약점 창이 1.5 s라 차징하면 창의 40 %를 잃는다.
  - 오른손 엄지가 압정을 누르고 있어서 분노를 길게 누르면 사격이 끊긴다.
  - 단계마다 칸당 효율이 올라가므로(§5) 최고 단계를 쓰는 것이 늘 옳다. 고민은 "지금 쏠까, 5칸까지 참을까" 하나로 줄어든다.
- ❓ 플레이테스트에서 낮은 단계를 고르고 싶다는 요구가 나오면 '길게 누르기 = 1칸만'을 추가한다. 기본은 넣지 않는다.
- 분노가 모자라면 버튼이 흔들리고 '분노 부족!' 말풍선과 둔한 햅틱(`skillDenied`)이 나온다. 이벤트는 `skill_denied`다.

### 2-2 단계별 sim 효과

수치는 §5의 `skills.*` 키다. 피해는 P0#7처럼 **창 안 `dmgIn` / 창 밖 `dmgOut` 쌍**으로 정한다.

| 단계 | 이름 | 언제 | sim 효과 | 빌런 반응 |
|---|---|---|---|---|
| **t1 · 1칸** | 경적 충격파 | 정체·잠금 전 | 지금의 분노 경적: 갓길 앞 `approach.rageHorn`(24 m) 청소(콘·낙하물 smash, 고장차 tow, 얌체 회수), 부스트 2.2 s(밀어내기 피해 0). 폴백에서도 동작해야 한다(§2-5) | 앞차 깜짝 말풍선 |
| | | 원흉전 | 뒤로 원뿔 충격파(0.12 s 뒤 도착). 원흉 차로 ±1, 30 m 안의 **모든** 원흉에 피해 16/8. **진행 중인 공격 예고를 취소**(돌진 lunge·상향등 차단)하고 0.6 s 경직(창 생성) | 차가 1.5 m 뒤로 휘청, "깜짝이야!" |
| **t3 · 3칸** | 압정 폭격 (다차로 카펫) | 원흉전 | 지붕 발사대가 압정 12개를 부채꼴로 쏘아 올린다. 0.35–0.55 s에 원흉 앞바퀴 앞 **3차로 × 12 m** 띠로 쏟아진다. 피해 30/12를 **4번에 나눠** 준다(0.40·0.45·0.50·0.55 s, 드르륵). 타이어 1개는 반드시 펑크. **1.2 s 경직(창 생성)** → 이어지는 압정은 ×4. 띠 안의 원흉 전원이 맞는다(1-3 듀오) | 털썩 주저앉고 바퀴에서 불꽃, "내 타이어!!" |
| **t5 · MAX** | 참교육 피니시 | 원흉전 | 0.35 s 예고 뒤 임팩트. 목표 원흉의 `hp_frac ≤ 0.4`(`execute`)면 **즉시 처치하고 장착 피니시(§4)로 퇴장**. 아니면 최대 HP의 30 %/15 % 피해 + **2.0 s 경직**("한 번 더!") | "잠깐만요!!" → 피니시 |

- 공통 규칙
  - 시전 중 무적이다. 빌런 공격은 `blocked`다.
  - 시전 채널은 하나다. t5 중에는 아이템도 막힌다(`busy`).
  - 처치 하한: 원흉전 sim 시간이 `minKillT`(6 s) 전이면 스킬 피해로 HP가 1 아래로 내려가지 않는다(시그니처 최소 1사이클 보장).
  - 경직은 창이다: BossSim 범용 `v.stun_skill`이 `vuln()`에서 창(배율 1.5 → P0#7 ×4)으로 잡힌다. 시그니처 모듈과 상관없다.
  - 경직 상한은 2.0 s이고, 끝나면 1.5 s 동안 경직 면역이다. 연속 경직으로 묶어 두는 것을 막는다.
  - 점수: t1 200, t3 600, t5 1500(처치 시 +1000).
- **구조형 판(`honkOnly`, 압정 금지)**: 같은 사다리를 쓰되 피해 대신 '깨우기'가 오른다.
  - t1 = 사이렌 깨우기(웹 rescueHonk super)
  - t3 = 비상등 릴레이: 뒤차 전부 비상등 → 1.5 s 각성
  - t5 = 갓길 유도: 즉시 `pullover` 피니시. `execute`는 깨우기 게이지 기준이다.
  - 드론은 '블박 경고 방송', 점프는 원흉전에서 비활성이다.

### 2-3 단계별 FX · 오디오 · 햅틱 레시피

- 시간 축: 0 = 시전 틱. 히트스톱은 실시간이고, 슬로모는 sim 배율이다.
- SFX는 **첫 조각에서 기존 bake 이름을 겹쳐 쓴다**(`Audio.sfx(name, {delay, volume, pitch})`). 전용 음은 나중에 bake한다(§2-6).

**t1 경적 충격파 (원흉전, 총 0.5 s)**
- 0.00: 버튼 찌그러짐, `hornTruck`(1.0), 링 웨이브 3개(r 4 → 14 m, 0.35 s, 0.06 s 간격, #ffd23a, 내 차 뒤에서 원흉 쪽으로)
- 0.12 임팩트:
  - 히트스톱 60 ms, 슬로모 없음
  - 원흉 범퍼에 sparks 16, 배기 smoke 6
  - 화면 플래시 #ffd23a α0.30 90 ms, 카메라 펀치 −3°, shake 0.35
  - `superHit`(0.5, pitch 1.15)
  - 햅틱 `skillT1`: transient 0.8/0.5 + continuous 120 ms 0.5/0.3 (Android 60 ms, 0.8)
- 해소: `-16` 팝, "깜짝이야!" 말풍선, 원흉 `lunge_off` −1.5 m에서 0.3 s 복귀. 경직 링(기존 `stun` ring)
- 정체 t1(분노 경적)은 지금 레시피(`rage_horn`: ring 14 m + `hornTruck` + `superHit`)에 플래시 #ffd23a 120 ms와 배너 `분노 경적!!`(0.9 s)을 더한다.

**t3 압정 폭격 (총 1.2 s)**
- 0.00–0.20:
  - 발사 3연(0.00·0.07·0.14): 총구 sparks 8씩, `launch`(0.7)
  - `tack` ×4(0.05 s 간격, pitch 0.9–1.2)
  - 카메라 리프트: 보스 프레이밍 k +0.25를 0.3 s에 걸쳐(3차로 띠가 보이게)
  - 노면 예고 띠(LaneBand 재사용, 주황 깜빡임)
- 0.20–0.40: 압정 12개 포물선(FightFx 투사체 풀, `caltrop` 메시)
- 0.40·0.45·0.50·0.55 다단 히트(`skill_hit` idx 0..3):
  - 압정당 sparks 6 + 검은 고무 debris 2
  - `hit`(0.6, pitch 상승), shake 0.25
  - 햅틱 `skillT3Hit`(이벤트마다 1회: transient 0.6/0.8, 간격 ≥ 40 ms)
- 첫 히트에서:
  - 히트스톱 90 ms
  - 슬로모 ×0.35 0.6 s
  - 카메라 펀치 −5°
  - 플래시 주황 α0.25 120 ms
  - Decal: 3차로 압정 카펫 띠(3 s 페이드) + 스키드 마크 4
- 펑크(0.55):
  - debris 12, smoke 5, ring 5 m, shake 0.5
  - `pop` + `crit`
  - 햅틱 `tirePop`(기존)
- 해소: 합산 `-30` 크게, "내 타이어!!", 경직 링 + HUD '지금! ×4' 배지(1.2 s 창)

**t5 참교육 피니시 (총 ≤ 2.5 s)**
- 0.00–0.35 예고:
  - HUD 집중선(화면 공간 방사형, 0.35 s), 따뜻한 비네트
  - 버튼 링이 금색으로 번쩍
  - `rageFull`(pitch 0.8) + `super`
  - 카메라 푸시인(FOV −6°를 0.35 s에 걸쳐)
  - 햅틱 `skillT5Charge`: continuous 0.35 s, 0.25 → 0.7, sharpness 0.3
  - 도장 배너 `참교육!!`(기울임 −8°, 도장 팝)
- 0.35 임팩트:
  - 히트스톱 140 ms, 흰 플래시 α0.85 160 ms
  - `explosion(1.6)` + ring 16 m + 0.18 s 뒤 2차 폭발 + 0.4 s 뒤 confetti 70(지금 kill 레시피)
  - 카메라 펀치 −8°, shake 0.9
  - `superHit` + `explosion`, `Audio.duck_for(2.6, 0.75)`
  - 햅틱 `skillT5Impact` = `villainKill` 패턴
- 처치면 바로 §4 피니시로 넘어가고, 그 시간은 2.5 s 예산 안에 든다.
- 처치가 아니면:
  - 슬로모 ×0.3 0.8 s
  - 큰 피해 숫자, "한 번 더!" 칩
  - 1.0 s에 조작과 보스 카메라 복귀(0.25 s 블렌드)

**단계 준비 알림** (`tier_ready`)
- 링 눈금이 번쩍이고 버튼이 1.18배로 튄다(지금 `_rage_ready_t` 연출).
- t1 준비: `rageFull`(0.5, pitch 1.2), 햅틱 `tierReady1` transient 0.3/0.8
- t3 준비: `rageFull`(0.6, pitch 1.0), `tierReady3` transient 0.5/0.8 ×2(60 ms)
- t5 준비: `rageFull`(0.7), 기존 `rageFull` 상승 3틱 + 배너 `분노 MAX!`
- 정체에서는 t1 준비만 알린다.

### 2-4 분노 버튼 링 (피드백 2: 막대 삭제)

- 하단 막대 행(`hud._rage_row`, `_draw_rage`)을 지운다. **링이 유일한 분노 표시다.** HP 범퍼 행은 그대로 둔다.
- 링 구성
  - 5칸 세그먼트(칸 사이 틈 6°)
  - 1·3·5 위치에 긴 눈금과 작은 라벨 `1` `3` `MAX`
  - 채움 색: 1–2칸 주황, 3–4칸 적주황, 5칸 금색 + 회전 반짝이
- 버튼 얼굴 = `next_tier`: 경적 아이콘(t1) / 압정 비 아이콘(t3) / 장착 피니시 아이콘(t5). 아래 라벨은 `경적`·`폭격`·`참교육`이다.
- 정체에서는 얼굴이 늘 `경적`이고, 3·5 눈금은 어둡게 자물쇠로 보인다.
- t5가 준비된 원흉전에서는 보스 HP 바 40 % 지점에 **처형선**(금색 노치 + `참교육` 라벨)을 그린다. HP가 선 아래면 바가 금색으로 맥동한다.
- 터치 크기는 지금 104 u(≥ 64 pt)를 유지한다.

### 2-5 폴백(GDScript 교통) 선행 조건

- iPhone은 폴백으로 돈다. 정체 쪽 스킬과 압정이 동작하려면 `_Creep`에 아래가 필요하다(이 문서는 범위만 정한다).
  - `rage_horn(range)`: `obstacles()`에서 갓길 범위 안의 콘·낙하물은 smash, 고장차는 tow한다. 얌체(cheater)는 폴백에 없으므로 빈 값이다. 놀란 차는 `cars_in_lane(SHOULDER−1, s, s+range)`로 고른다.
  - `mini_target`·`mini_hit`: 폴백에도 잔챙이 표시(LAMP_MINI)와 피해, 검거를 넣는다. 아니면 압정이 정체에서 쏠 대상이 없다.
- 피드백 3 수정 계약(입력 담당): **`&"fire"`는 어떤 경우에도 `honk`를 만들지 않는다.** 대상이 없으면 내 차 뒤로 빈 투척(`fire_at({})`, 기존 miss 연출)을 한다. 스킬 입력도 서로 겹치지 않는다(§6).
- 원흉전 스킬(t1·t3·t5·아이템)은 BossSim·WeaponsSim·PlayerSim만 만진다. 그래서 폴백에서도 동작이 같다(§7에서 두 경로 모두 테스트).

### 2-6 전용 SFX bake (첫 조각 이후)

- 웹 `audio.js`는 동결이다. 새 레시피는 네이티브 전용 모듈(예: `tools/audio/skill_sfx.mjs`)에 두고, `bake-audio.mjs`가 같은 OfflineAudioContext로 렌더하게 한다.
- ❓ audio.js 헬퍼(hornTone·boom·noise)가 export되지 않으면 모듈 안에 복제한다.
- 이름
  - `sk_charge`: 상승 와인 0.35 s
  - `sk_carpet`: 금속 비 0.4 s
  - `sk_drone`: 도플러 와인 0.7 s
  - `sk_land`: 서브 쿵 0.3 s
  - `sk_tier1`/`sk_tier3`/`sk_tierMax`: 준비 차임 3음
  - `fin_rocket`/`fin_balloon`/`fin_heli`/`fin_ufo`: 피니시 스팅어 ≤ 2 s
- 데이터에서 겹쳐 쓰기 스택을 이름 하나로 바꾸면 끝난다(`skills.fx.<id>.sfx`).

---

## 3. 아이템 스킬

### 3-1 매핑 (기존 SHOP id 우선)

| 슬롯 | 아이템(SHOP id) | 정체 | 원흉전 | 쿨·충전 |
|---|---|---|---|---|
| `item1` · 왼쪽(이동 엄지) | **참교육 점프** `mv_jump` | 지금과 같다: 앞차를 뛰어넘기(hop 0.75 s, 3.4 m) | **점프 쿵**: 0.75 s 체공 중 무적(모든 공격 회피) → 내 차로 앞 노면에 착지 충격파 → 원흉 피해 8/3, 경직 0.6 s | 쿨 정체 4 s(웹) / 원흉전 6 s, 충전 무한 |
| `item2` · 오른쪽(공격 엄지) | **블박 드론** `mv_drone` | **드론 출동**: 앞 40 m 안의 잔챙이 1명 즉시 검거. 없으면 갓길 장애물 1개를 치운다(폴백 OK: `remove_obstacle`) | **드론 폭격**: 0.7 s 강하 → 원흉 차 길이를 따라 폭탄 6발 → 피해 15/5(6등분) | 쿨 정체 8 s / 원흉전 12 s, 충전 무한 |
| (제안, M2) `item2` 대안 | **레커 호출** `mv_tow` (신규 380,000원) | 앞 60 m 갓길 고장차·얌체 1대 견인 | **견인 고정**: 레커가 갓길로 들어와 원흉 범퍼에 고리 → 1.5 s 묶음(창, 돌진·차로 변경 불가) | 판당 1회. `car_wrecker` 장착 시 +1 |

- 드론 패시브(웹: 0.7 s마다 자동 사격)는 **정체 잔챙이만** 노리게 줄인다. 원흉 피해는 액티브에서만 나온다. 원흉전 길이를 지키려는 결정이고, 웹과 다르다 ❓.
- 새 아이템은 꼭 필요할 때만 넣는다. 첫 조각은 기존 2종이고, `mv_tow`는 M2 후보다.

### 3-2 장착 · 해금

- `Progress.loadout()`에 `"items": ["mv_jump", "mv_drone"]`(슬롯 순서, ≤ 2)를 더한다.
  - 첫 조각: 소유한 move 아이템이 SHOP 순서대로 슬롯을 채운다. 점프는 왼쪽, 드론과 레커는 오른쪽이다.
  - move가 3종이 되면 차고에 `move1`/`move2` 장착 슬롯을 연다(SLOT_CATS 확장).
- 지금 있는 `jump`·`jump_cool`·`drone`·`drone_every` 키는 호환용으로 남긴다.
- `view/game.gd`는 `tables.options.loadout = Progress.loadout()`을 넘긴다. `GameSim.setup`은 `options.loadout`에서 `finish`·`items`·`rage_start_segs`(졸음쉼터 커피)를 읽는다.
- 소유하지 않은 슬롯은 버튼을 그리지 않는다. 입력이 와도 `skill_denied{reason: "phase"}`이고 효과는 없다.

### 3-3 버튼 · 연출

- 크기는 88 u(64 pt)다.
  - `item1`은 ◀ ▶ 위, 왼쪽 엄지 호에 둔다.
  - `item2`는 경적 위, 분노 왼쪽에 둔다.
  - 둘 다 IDLE_ALPHA 0.45 고스팅이다.
- 쿨다운은 시계 방향으로 풀리는 파이로 보이고, 남은 초는 숫자로 띄운다. 충전형은 점(pip)으로 보인다.
- 쓸 수 없으면(`usable=false`) 회색 + 이유 아이콘이다(대상 없음 ⌀ / 구조형 🚫).
- **점프 쿵**
  - 이륙: `whoosh`(pitch 1.3), 햅틱 `laneChange`
  - 착지: 회색 먼지 ring 8 m, 아스팔트 debris 10, smoke 8, 원흉 `tilt_x` +0.1 튐, `쿵!` 팝
  - 착지 소리: `bump`(1.0, pitch 0.6) + `explosion`(0.3, pitch 1.6)
  - 카메라 펀치 −4°, shake 0.45
  - 햅틱 `itemJumpLand`: transient 1.0/0.3 + continuous 100 ms 0.6/0.2
- **드론 폭격**
  - 0–0.7 s: 드론이 내 차 위에서 원흉 위로 강하. `whoosh`(pitch 1.5)
  - 0.7–1.0 s: 폭탄 6발, 0.05 s 간격. 발마다 `explosion(0.35)` + sparks 6 + shake 0.15 + `pop`(stagger)
  - 끝: ring 6 m + `crit`
  - 햅틱 `itemDrone`: 발마다 transient 0.35/0.9
  - 카메라는 가져가지 않는다.
- **레커 호출**(M2)
  - 0–0.8 s: 레커가 갓길로 들어온다. `hornShort`, 비상등
  - 0.8 s: 고리 '철컥'(`bump` + `crit`), 체인 선
  - 햅틱 `itemTow`: transient 0.7/0.6 ×2

---

## 4. 피니시 연출 (장착 피니시별 1.5–2.5 s)

- 모든 피니시의 공통 박자
  - 0: 임팩트(히트스톱 140 ms + 흰 플래시 + `villainKill` 햅틱)
  - 0.14 → `settle`: 슬로모 ×0.3에서 빌런 반응(털썩, 타이어 펑크)
  - `settle` → `done`: 정상 속도로 퇴장
  - `done` + `releaseDelay` 0.3 s(지금 0.95): 해방
- 0.6 s 뒤에는 화면 탭으로 건너뛴다. 사망 타임라인을 `done`으로 점프한다.
- BossSim `_update_death`의 상수(0.8, 2.15, 3.0, 2.4)를 `skills.finish.<id>.*`로 데이터화한다.

| 피니시 | 시간표 (실시간 s) | 카메라 | 오디오 · 햅틱 |
|---|---|---|---|
| **로켓** `fin_rocket` | 0.14–0.5 털썩 + 바퀴 4개 펑크 → **0.6 점화**(차 밑 fireball 30, smoke 기둥, 그을음 decal) → 0.6–1.6 상승(vel_y 36) → **1.6 하늘 ★ 반짝**(별 스프라이트) → 1.9 끝 | 낮은 사이드 샷, 상승을 따라 최대 +12° 틸트. 도로는 아래 ≥ 35 %에 남긴다 | `launch` → `twinkle`. 햅틱 `finishRocket`: continuous 0.5 s 0.6 → 0.1, sharp 0.4 + ★에서 transient 0.4/1.0 |
| **풍선** `fin_balloon` | 0.14–0.5 털썩 → **0.5 지붕에서 풍선 다발 퐁퐁**(confetti 30, 6발 0.06 s 간격) → 0.5–1.9 흔들리며 상승(2 + 4.5 u m/s) → 1.9 ★ → 2.1 끝 | 고정 미디엄 샷(궤도 없음). 프레임 위로 빠져나간다 | `pop` ×6(stagger) → `twinkle`. 햅틱 `finishBalloon`: 풍선마다 transient 0.3/0.9 |
| **헬기** `fin_heli` | 0.14–0.3 털썩 → 0.3–0.9 헬기가 프레임 위에서 내려온다(로터 하향풍 smoke) → **0.9 고리 철컥** → 0.9–2.1 들어 올려 앞으로 이탈 → 2.1 ★ → 2.3 끝 | 고정 와이드. 헬기 등장 지점까지 화면에 넣는다(FRAME_Y 위쪽 20 %) | `whoosh`(pitch 0.6, 0.3 s마다) → `bump` + `crit` → `twinkle`. 햅틱 `finishHeli`: continuous 1.2 s 0.25, sharp 0.1 + 고리 transient 0.8/0.6 |
| **UFO** `fin_ufo` | 0.15–0.4 빛기둥 켜짐(가산 원기둥, 깜빡임 20 Hz) → 0.4–1.8 빙글 돌며 상승 → **1.8 깜빡 사라짐** → 2.0 끝 | 낮은 로우앵글. 빛기둥 꼭대기는 잘려도 되고 차와 도로는 남긴다 | `super`(pitch 0.7) → `twinkle` ×2. 햅틱 `finishUfo`: continuous 1.4 s 0.2 → 0.6, sharp 0.9 + transient 0.6/1.0 |
| 갓길 유도 `pullover` (구조형) | 지금과 같다(2.2 s): 깜빡이 → 갓길 정차 | 지금 궤도의 축소판 | `blink` + `cheer` 전주 |

**킬캠 프레이밍 규칙**(기기 피드백 "위아래 짤림")
1. 레터박스·크롭·세로 띠 비네트를 금지한다(이미 뺐다. 회귀 테스트 대상).
2. 임팩트 틱에는 원흉과 내 차가 모두 가로 70 %, 세로 FRAME_Y 20–74 % 안에 든다(보스 프레이밍 해를 0.2 s 동안 유지한 뒤 피니시 샷으로 블렌드).
3. look-at y ≤ 4.5 m. 빌런이 6 m 위로 올라가도 틸트는 최대 +12°만 따라간다. **도로 노면이 화면 아래 ≥ 35 %에 늘 보인다.** 빌런은 프레임 위로 '빠져나가는' 것이 맞고, 카메라가 하늘을 비추면 안 된다.
4. 궤도 회전 각은 ≤ 30°다(지금 −0.9 + 0.5t rad는 넓다). 세로 화면 FOV는 56–62°다.
5. HUD는 처치 배너와 0.6 s 뒤 `탭: 건너뛰기` 힌트만 남기고 숨긴다.
- 소품(드론·풍선 다발·헬기·UFO)은 웹 `vehicles.js buildFxProp`에 있다. `tools/bake-meshes.mjs`에 `category: 'fx'` 4종을 추가해 `native/assets/fx/*.res`로 굽는다(M3에서 앞당김).

---

## 5. 밸런스 (`data/src/config.json` → `skills.*`)

```json
"skills": {
  "_doc": "docs/SKILLS.md. 분노 사다리 t1/t3/t5 + 아이템 + 피니시. hitstop·slowFor·skipAfter는 실시간 s, delay·dur·cool·stun은 sim s. dmgIn = 약점 창(vuln window) 안, dmgOut = 밖.",
  "ladder": [1, 3, 5], "select": "highest", "jamTier": 1,
  "skipAfter": 0.5, "cineGap": 6.0, "minKillT": 6.0, "invulnPad": 0.2,
  "stunCap": 2.0, "stunImmune": 1.5, "hpMul": 1.25,
  "rageGain": { "windowHit": 0.01, "dodge": 0.04, "fightCap": 0.6 },
  "t1": { "cost": 1, "delay": 0.12, "dur": 0.5, "range": 30, "laneRange": 1, "dmgIn": 16, "dmgOut": 8, "stun": 0.6, "cancel": true,
          "jam": { "boost": 2.2 }, "hitstop": 0.06, "slow": 1.0, "slowFor": 0.0, "score": 200 },
  "t3": { "cost": 3, "delay": 0.4, "hits": 4, "hitGap": 0.05, "dur": 1.2, "tacks": 12, "laneRange": 1, "strip": 12,
          "dmgIn": 30, "dmgOut": 12, "stun": 1.2, "pop": 1, "hitstop": 0.09, "slow": 0.35, "slowFor": 0.6, "score": 600 },
  "t5": { "cost": 5, "delay": 0.35, "dur": 2.5, "execute": 0.4, "dmgInFrac": 0.3, "dmgOutFrac": 0.15, "stun": 2.0,
          "hitstop": 0.14, "slow": 0.3, "slowFor": 0.8, "score": 1500, "executeBonus": 1000 },
  "items": {
    "mv_jump":  { "slot": 1, "cool": 6.0, "coolJam": 4.0, "charges": -1, "hop": 0.75, "invuln": 0.85, "landRange": 14,
                  "dmgIn": 8, "dmgOut": 3, "stun": 0.6, "score": 150 },
    "mv_drone": { "slot": 2, "cool": 12.0, "coolJam": 8.0, "charges": -1, "delay": 0.7, "bomblets": 6, "bombGap": 0.05,
                  "dmgIn": 15, "dmgOut": 5, "jamRange": 40, "passive": "minis", "passiveEvery": 0.7, "score": 300 },
    "mv_tow":   { "slot": 2, "cool": 0, "charges": 1, "wreckerBonus": 1, "delay": 0.8, "pin": 1.5, "jamRange": 60, "score": 300 }
  },
  "finish": {
    "releaseDelay": 0.3, "skipAfter": 0.6,
    "rocket":   { "settle": 0.5, "lift": 0.6, "twinkle": 1.6, "done": 1.9 },
    "balloon":  { "settle": 0.5, "lift": 0.5, "twinkle": 1.9, "done": 2.1 },
    "heli":     { "settle": 0.3, "hook": 0.9, "twinkle": 2.1, "done": 2.3 },
    "ufo":      { "settle": 0.15, "beam": 0.4, "twinkle": 1.8, "done": 2.0 },
    "pullover": { "done": 2.2 }
  },
  "fx": { "_doc": "뷰 전용 레시피(sim은 읽지 않음): 이벤트 id별 sfx 스택 [[name, delay, volume, pitch]], camera {punch, shake, lift}, flash [hex, alpha, ms], banner",
    "t1": { "sfx": [["hornTruck", 0, 1.0, 1.0], ["superHit", 0.12, 0.5, 1.15]], "camera": { "punch": -3, "shake": 0.35 }, "flash": ["ffd23a", 0.3, 90], "banner": "분노 경적!!" },
    "t3": { "sfx": [["launch", 0, 0.7, 1.0], ["tack", 0.05, 0.6, 0.9], ["tack", 0.1, 0.6, 1.05], ["tack", 0.15, 0.6, 1.2]], "camera": { "lift": 0.25, "punch": -5, "shake": 0.5 }, "flash": ["ff7a1a", 0.25, 120], "banner": "압정 폭격!!" },
    "t5": { "sfx": [["rageFull", 0, 0.7, 0.8], ["super", 0, 0.6, 1.0], ["superHit", 0.35, 1.0, 1.0], ["explosion", 0.35, 0.95, 1.0]], "camera": { "push": -6, "punch": -8, "shake": 0.9 }, "flash": ["ffffff", 0.85, 160], "banner": "참교육!!" }
  }
}
```

**약점 창(×4)과의 관계**
- 압정은 지금처럼 창 밖 1, 창 안 ×4다.
- 스킬은 `dmgIn/dmgOut` 쌍으로 정하고 비율은 2–2.5×다. 스킬은 드물게 쓰므로 창 밖에서도 '조금은 시원해야' 한다. 창 밖에서 쓰면 '지금 아냐!' 칩이 뜬다(지금 폭탄 규칙).
- 스킬이 창을 **만든다**: t1 0.6 s, t3 1.2 s, t5(비처치) 2.0 s, 점프 0.6 s, 레커 1.5 s. 만든 창 안의 압정은 ×4다.
- 그래서 고민은 두 가지다: "자연 창(상향등 릴레이)에 겹쳐 쏠까, 창이 없을 때 창을 만들까".

**원흉전 길이 예산** (1-1, 목표 실시간 10–20 s)
- 지금(스킬 없음, 폭탄 있음): 원흉 HP 140. 사이클 ≈ 4 s(경직 1.5 s), 압정 5/s, 명중률 약 80 %.
  - 사이클당 ≈ 24(창) + 10(밖) = 34
  - autopilot 원흉전 10.9–12.9 s
- 스킬 사용: 판당 분노 예산 ≈ 정체 이월 2칸 + 원흉전 획득 2칸(피격 +0.08, 도발, `windowHit` 0.01 × 약 18타).
  - 전형적 사용: t3 1회(30 + 만든 창 1.2 s ≈ +19) + t1 1회(16 + 0.6 s 창 ≈ +7) ≈ 72
  - HP 그대로면 140 − 72 = 68 → 약 2사이클 ≈ 8 s로 짧다
  - **`skills.hpMul` 1.25 → 175** − 72 = 103 → 약 3사이클 ≈ 12 s + 시네마틱 1.7 s ≈ **14 s** ✅(계산). 실측은 ❓(§7 게이트)
- 상한: 스킬 피해 합(만든 창의 압정 포함)이 원흉 HP의 50 %를 넘지 않게 맞춘다. 넘으면 `hpMul`을 올리지 말고 t3·t1의 `dmgIn`을 내린다.
- MAX는 5칸을 모아야 하고 처형선이 40 %라서 보통 2–3사이클 뒤에 나온다. 마무리용이다.
- `minKillT` 6 s는 졸음쉼터 커피 + 정체 이월로 원흉전 초반에 5칸을 가진 경우의 안전장치다.
- 판별 조정은 `stages.json`의 `skillHpMul`(선택)로 한다. 듀오(1-3)는 t3 띠가 두 대를 함께 맞히므로 1.35 ❓.

---

## 6. 구현 인터페이스

```
GameSim 입력 (input(cmd, value)):
  &"rage"        탭(누르는 순간 1회, 위 스와이프 포함). value=null → 쓸 수 있는 최고 단계(정체·잠금 전 = 항상 t1).
                 value=int 1|3|5 → 그 단계 강제(테스트·autopilot 전용, 준비된 단계보다 높으면 denied).
  &"item1"       왼쪽 슬롯 아이템 탭 (loadout.items[0]).
  &"item2"       오른쪽 슬롯 아이템 탭 (loadout.items[1]).
  &"skip"        활성 시네마틱(t5, 피니시)에서 skipAfter 이후의 화면 탭. 이미 정해진 sim 결과는 바꾸지 않고, 슬로모를 끝내고
                 사망 타임라인을 finish.<id>.done으로 점프한다.
  계약: &"fire"는 절대 honk·스킬을 만들지 않는다. &"honk"는 경적 버튼만 보낸다. 입력끼리 겹치지 않는다(피드백 3).

setup: tables.options.loadout = Progress.loadout() → finish, items[], rage_start_segs를 읽는다.
       config.skills가 없으면 지금 동작(분노 경적 / 폭탄)으로 폴백한다.

state()["skills"]:
  segs: int                         분노 칸 0..5 = floor(rage*5 + 1e-6)
  rage_tiers_ready: Array[int]      ladder 중 segs 이하이고 지금 모드에서 허용된 단계 (예 [1, 3]; 정체 → [1] 또는 [])
  next_tier: int                    지금 탭하면 나갈 단계 (0 = 없음)
  mode: String                      "jam" | "fight" | "rescue" | "off"
  execute_frac: float               t5 준비 + 원흉전이면 skills.t5.execute(0.4), 아니면 0 (HP 바 처형선)
  active: Dictionary                {} 또는 {chan: "rage"|"item", tier: int, id: String, t: float, dur: float,
                                     target_id: int, cine: bool, skippable: bool}
  items: Array[Dictionary]          [{id, slot: 1|2, charges: int (-1 = 무한), cool: float, cool_max: float,
                                      ready: bool, usable: bool, reason: ""|"target"|"phase"|"busy"}]
  time_scale: float                 이번 틱의 sim 배율 (히트스톱 0, 슬로모 slow_scale, 평소 1) → fx.advance(real_dt * time_scale)
state()["villains"][i] 추가: stun_skill: float (남은 스킬 경직 s; vulnerable/window_left에 이미 반영)

이벤트 (events()):
  skill_start  {chan, tier, id, target_id, lanes: PackedInt32Array, dur, cine: bool, s, x}
  skill_hit    {chan, tier, id, target_id, idx, n, dmg, window: bool, immune: bool, stun, popped: int, killed: bool,
                hp_frac, s, x}                      다단 히트는 idx 0..n-1; t3 n=4, 드론 n=6, 그 외 n=1
  skill_end    {chan, tier, id, skipped: bool}
  skill_denied {chan, tier, id, reason: "rage"|"cool"|"charges"|"target"|"phase"|"busy"}
  tier_ready   {tier, segs}                         새 단계가 쓸 수 있게 된 틱 (정체에서는 t1만)
  item_ready   {id, slot}                           쿨이 끝난 틱
  finisher     {id: "rocket"|"balloon"|"heli"|"ufo"|"pullover", target_id, execute: bool, s, x}
                                                    마지막 원흉 처치 틱, 같은 틱의 kill 다음에 낸다
  id 값: "t1_horn" (정체: rage_horn도 함께), "t1_wave", "t3_carpet", "t5_finish", "mv_jump", "mv_drone", "mv_tow"
  유지: rage(칸 상승), rage_horn(정체 t1 결과), kill, stun. 폐지: 원흉전 bomb (t1_wave가 대신; WeaponsSim.fire_missile은
        지우지 않고 config.skills가 없을 때만 쓴다)

sim 쪽 책임:
  GameSim._skill_rage(tier) / _skill_item(slot) / _skill_tick(sdt)   — 비용·쿨·채널(rage/item, t5는 둘 다 막음)·무적·
      hitstop/slow 적용·minKillT 하한·점수. 지연 판정(delay, hits, hitGap)은 sim 시간 큐로 처리한다(결정적).
  BossSim.skill_damage(v, dmg_in, dmg_out, stun, from_rear) -> {killed, popped, window, immune, dmg}   — damage() 재사용 +
      stun_skill(stunCap/stunImmune), cancel_attack(v), pop_tire 강제, execute(v) (start_death 경로 그대로).
  BossSim._update_death: finish 타임라인을 config.skills.finish.<id>로 읽고, skip_death(v)는 done으로 점프한다.
  PlayerSim: jump(hop, invuln) 원흉전 허용; GameSim이 쿨과 소유를 확인한다.
  TrafficBridge(폴백 포함): rage_horn, mini_target, mini_hit, remove_obstacle, obstacles만 쓴다(§2-5).
  Autopilot: 창 left > 0.45 s 또는 hp_frac ≤ execute에서 &"rage"; 3–4칸이고 hp_frac > 0.55면 50 % 확률로 MAX까지 참는다.
      공격 예고가 내 차로에 오고 점프가 준비됐으면 &"item1"; 창 > 0.8 s이고 드론이 준비됐으면 &"item2".

뷰 훅:
  view/game.gd    LaneInput.consume_rage → &"rage"; consume_item(1|2) → &"item1"|&"item2"; consume_skip → &"skip".
                  fx.advance(real_dt * state.skills.time_scale). options.loadout 전달. 이벤트 → HUD/FightFx/Camera/Audio/Haptics.
  input/lane_input.gd   존 "item1", "item2"; signal item_requested(slot); 존 밖 탭이고 skills.active.skippable(또는 kill
                  phase에서 finish.skipAfter 경과)이면 skip edge. 3손가락 디버그는 그대로.
  ui/hud.gd       _rage_row 삭제. _draw_rage_btn: 5칸 링 + 1/3/MAX 눈금 + next_tier 얼굴/라벨 + 정체 자물쇠.
                  _draw_item(slot): 쿨 파이, pip, usable 회색. 보스 바 처형선(execute_frac). 배너(fx.<id>.banner),
                  합산 피해 팝, "한 번 더!" 칩, "탭: 건너뛰기" 힌트. on_event: skill_start/hit/end/denied, tier_ready, item_ready.
  fx/fight_fx.gd  on_event 분기 skill_start/skill_hit/skill_end/finisher. 새 기본 동작: carpet(lanes, s0, s1, n),
                  drone_dive(from, to, t), beam(pos, h, dur), star_twinkle(pos), dust_ring(pos, r), decal(pos, kind, life)
                  (Decal 풀 8: tack_strip, skid, scorch). 기존 sparks/debris/smoke/fireball/ring/light/explosion/confetti 재사용.
  view/camera_rig.gd    on_event: skill_start(t3) → lift(k+0.25, 0.3 s); skill_start(t5) → push(FOV −6, delay);
                  finisher → finish_shot(id) (§4 규칙: look y ≤ 4.5, 틸트 ≤ 12°, 노면 ≥ 35 %, 궤도 ≤ 30°);
                  skill_end / skip → end_shot(0.25 s 블렌드). punch/add_shake는 config.skills.fx.<id>.camera.
  autoload/audio.gd     config.skills.fx.<id>.sfx 스택 재생(Audio.sfx + delay); t5·finisher에서 duck_for(2.6, 0.75).
  autoload/haptics.gd + data/src/haptics.json   새 이벤트: skillT1, skillT3Hit, skillT5Charge, skillT5Impact,
                  tierReady1, tierReady3, (tierReady5 = rageFull), skillDenied, itemJumpLand, itemDrone, itemTow,
                  finishRocket, finishBalloon, finishHeli, finishUfo (ios transient/continuous + android ms/amp, §2-3·§3-3·§4 값).
                  다단 히트는 이벤트마다 1회 호출한다(패턴 시간에 슬로모를 굽지 않는다).
  meta/progress.gd      loadout()에 "items": Array[String] (≤ 2, 슬롯 순서). SLOT_CATS 확장(move1/move2)은 move 3종부터.
```

---

## 7. 테스트 계획과 첫 조각

### 7-1 헤드리스 (`godot47 --headless --path native -s res://tests/run_tests.gd -- --filter=skills`)

- 모든 sim 테스트는 `for fb in [false, true]`로 돈다. 확장이 없으면 native 경로는 건너뛴다. iPhone 경로는 `force_fallback=true`다.
- **`tests/test_skills_sim.gd`**(unit)
  1. 단계 선택
     - 원흉전, rage 0.2/0.4/0.6/0.8/1.0이면 t1/t1/t3/t3/t5이고, 남는 칸은 0.0/0.2/0.0/0.2/0.0이다.
     - 정체에서 1.0이면 t1이다.
     - 0.1이면 `skill_denied{reason: "rage"}`이고 분노가 그대로다.
  2. t1 원흉전: 30 m·±1차로 안의 원흉 전원이 맞는다. 진행 중인 lunge가 취소되고(플레이어 피해 이벤트 0), 0.6 s 동안 `vulnerable=true`다.
  3. t3: `skill_hit` n=4, 합이 창 안 30 / 밖 12와 같다. 타이어가 1개 이상 펑크 난다. 경직 1.2 s 동안 압정 피해가 ×4다. 듀오(1-3)에서는 두 대가 모두 맞는다.
  4. t5: `hp_frac` 0.39면 처치와 `finisher{id = 장착}`이 나온다. 0.6이면 처치가 아니고, 피해는 0.3 × max(창 안)이며 경직 2.0 s다.
  5. 안전장치
     - `minKillT` 전에는 HP가 1 아래로 떨어지지 않는다.
     - `stunCap`/`stunImmune`이 지켜진다(경직 합 ≤ 2.0 s, 면역 1.5 s).
     - 시전 중 무적이다(강제 공격에도 `damage` 0).
  6. 아이템
     - 쿨은 sim 시간으로 줄고, 쿨 중 입력은 `denied{cool}`이다.
     - 점프는 체공 중 회피하고 착지에서 `skill_hit`가 나온다. 드론은 n=6이다.
     - 소유하지 않으면 효과가 없고 `items[]`에 들어가지 않는다.
     - 정체 드론은 폴백에서 장애물 1개를 치운다.
  7. 건너뛰기: 같은 시드에서 `&"skip"`이 있든 없든 `skill_end` 시점의 원흉 HP와 kill 틱의 sim 결과가 같다. skip이 있으면 해방이 일찍 온다.
  8. 결정성: 같은 시드와 같은 입력 로그면 이벤트 로그 해시가 같다(두 경로 모두).
  9. 폴백 정체: 갓길 24 m 안에 장애물을 두고 t1을 쓰면 `rage_horn.smashed`/`towed`가 비어 있지 않다. 폴백 잔챙이를 압정으로 맞히면 `hit{kind: mini}`가 나온다. **정체에서 압정만 누르면 `honk` 이벤트가 0개다**(피드백 3 회귀).
- **`tests/test_e2e_skills.gd`**(`--suite=e2e`)
  - autopilot 스킬 정책 × 시드 5개(1007/3/11/42/77) × {native, fallback}에서 판이 result까지 간다.
  - 원흉전 실시간 10–20 s, sim 시간 ≥ `minKillT`.
  - t3 또는 t5를 1회 이상 쓰고, 마무리는 `finisher`다.
  - 스킬마다 실시간이 예산 이하다(t1 0.5, t3 1.2, t5 2.5, 피니시 `done` + 0.3).
  - INFO 줄에 단계별 사용 수와 원흉전 시간 분포를 찍는다(`hpMul` 튜닝 근거).
- 터치(`test_view_smoke` 방식, `Input.parse_input_event`로 InputEventScreenTouch를 버튼 rect에 보낸다)
  - 분노 rect → `&"rage"` 1회
  - item1/item2 rect → 해당 입력
  - 압정을 누른 채 item2 탭(멀티터치) → 둘 다 들어간다
  - t5 중 빈 화면 탭 → skip
  - 정체에서 압정 rect 홀드 → honk 0
- 계약: 새 햅틱 이벤트가 모두 `haptics.json`에 있다(T0 이벤트 계약). `skills.fx.*.sfx`의 이름은 모두 `Audio.has_sfx`다. `node tools/content/build.mjs --check`가 통과한다.

### 7-2 샷 (`native/tests/shot_fight.gd`)

- 인자: `--skill=t1|t3|t5|jump|drone`, `--finish=rocket|balloon|heli|ufo`, `--fallback`
- 프레임: 시전 0, 임팩트, +0.3 s, +1.0 s, 끝
- 자동 검사
  1. 노면 색 픽셀이 화면 아래 35 %에 있다(킬캠 포함).
  2. 임팩트 지점이 FRAME_Y 20–74 % 안에 있다.
  3. 레터박스나 검은 띠가 없다.
  4. HUD rect와 임팩트 지점이 겹치지 않는다.
- 링 샷: 분노 0/1/3/5칸 × {정체, 원흉전} 6장. 막대 행이 없는지 확인한다.
- 아이템 버튼 샷: 쿨 0/50/100 %, usable false.
- 게이트: `bash tools/native-check.sh`(e2e 단계에 fallback 시드 추가). iOS export dry-run은 변경 없이 통과해야 한다.

### 7-3 첫 조각 (한 번에 다 못 넣을 때)

**조각 A: 원흉전 사다리.** 폴백 안전, 쾌감 대비 비용 최소, 아이폰에서 바로 체감된다.
1. HUD: 막대 삭제(피드백 2), 링에 1·3·MAX 눈금, `next_tier` 얼굴, 처형선.
2. GameSim·BossSim
   - 단계 선택
   - t1 원흉전(충격파 + 공격 취소, 지금 폭탄 자리)
   - t3 카펫(다단 4 + 경직 창)
   - t5(처형 또는 큰 피해 + 경직)
   - 범용 `stun_skill`, `minKillT`, 무적, `hpMul`
3. 임팩트 스택(데이터 기반): 히트스톱, 슬로모, 펀치, 플래시, 배너, 기존 SFX 겹쳐 쓰기, 햅틱 6종. `fx.advance`에 time_scale을 반영한다.
4. 로켓 피니시만 2.5 s 이하로 줄이고 킬캠 규칙과 skip을 넣는다(기본 피니시라 모든 사용자가 본다).
5. `test_skills_sim`(두 경로) + `test_e2e_skills` + 샷.

**조각 B: 아이템.** `Progress.loadout().items`, item1/item2 버튼, 점프 쿵, 드론 폭격(소품 bake 포함), 정체 드론, autopilot 정책.
**조각 C: 피니시·사운드.** 풍선·헬기·UFO 소품과 타임라인, 전용 SFX bake(§2-6), Decal, 기기에서 햅틱 튜닝(FEEDBACK_LOG 기록). M2 후보: 레커 호출 `mv_tow`.

선행/병행(다른 담당): 폴백 `rage_horn`·잔챙이(§2-5)와 압정 → 경적 제거(피드백 3), 원흉 뒤에 섰을 때 통과 현상(피드백 1). 조각 A의 원흉전 부분은 이것들 없이도 동작한다.

---

## 8. 열린 질문

- ❓ `hpMul` 1.25는 계산값이다. e2e 분포로 확정하고, 판별 `skillHpMul`이 필요한지 본다.
- ❓ 원흉전 분노 획득(`windowHit` 0.01, `dodge` 0.04)으로 MAX가 판당 0.5–1회 나오는가? 너무 드물면 `windowHit`을 0.015로 올린다.
- ❓ 처형선 40 %가 '아직 멀었는데 끝났다'로 느껴지지 않는가? 기기에서 판정한다.
- ❓ 드론 패시브를 잔챙이 전용으로 줄인 것이 웹 플레이어의 기대와 어긋나지 않는가?
- ❓ 새 아이템 `mv_tow`의 가격과 이름. SHOP.md P0#9(경제 100판) 단계형 가격과 함께 정한다.
