# NATIVE_PARITY — 웹(동결 오라클) ↔ 네이티브 기능 대조표

가설:
- ✅ 웹 플레이어 대면 기능을 96행으로 묶었다(세부 항목은 약 110개). 네이티브(M1a, `e7b4c93`)에서 done은 6행(이 중 2행은 네이티브 신규), partial은 30행, missing은 58행이다. "분노게이지 안 참·처음에 대시보드 없음"은 버그가 아니라 이식이 안 된 것이다(B6·C3은 정적 값이고, A2는 main_scene이 `game.tscn`).
- ✅ 두 불만은 담당이 정확히 나뉜다. 분노는 **IS**(GameSim 분노 소스 10종 + HUD 연결)이고, 대시보드는 **MS**(`app.tscn` 타이틀·챕터·그리드)다.
- ❓ CONTRACT `stage_finished` 결과에 필드가 빠져 있다(score, freed, cath, cheaters, mini_fines, retry_mul, hp_end, photo). 이대로는 웹의 포상금·구독자·BEST·도감 사진 공식을 재현할 수 없다. 7절에서 추가안을 제시한다.

범례
- **상태**(2026-10-14 `native/` grep 스냅샷): `✗` missing, `◐` partial, `●` done. 병렬 in-stage 워크플로가 끝나면 IS 행의 상태가 바뀐다.
- **담당**: **IS** = in-stage 워크플로(native/sim·ui·input·fx·audio, camera_rig, world), **MS** = meta-screens(native/meta·native/screens, 이 문서), **FI** = 최종 통합, **M2/M3/M4** = NATIVE_PORT 마일스톤으로 미룸, **drop** = 출시 빌드에서 뺌.
- 웹 위치는 `game/js/<file>:<function>`으로 적는다. 수치는 `config.js TUNE`(= `native/data/config.json tune`)과 같다.
- 웹 코드와 문서가 다르면 **코드가 기준**이다. 예: SHOP.md는 ★2를 "추돌+피격 3회 이하"로 적었지만 코드는 `HP ≥ 60`이다(main.js:showResult).

---

## A. 화면 · 메타 UI

| # | 기능 | 웹 위치 | 상태 | 담당 | 합격 기준 |
|---|---|---|---|---|---|
| A1 | 부트·로딩 화면, 폰트 선로딩 | main.js:boot, index.html `#boot` | ✗ (Godot 스플래시만) | MS | 콜드 스타트에서 스플래시 다음 바로 타이틀이 뜬다. 빈 프레임이 없고, 첫 Label부터 Black Han Sans/Jua로 그려진다. |
| A2 | 타이틀/대시보드: 로고 표지판(고속도로 빌런 헌터 · ↑ 1차선 참교육), VMS 한 줄 "막히면, 원인을 제거한다." | ui.js:showTitle | ✗ (main_scene = game.tscn) | MS → FI | 앱을 켜면 첫 화면이 타이틀이다. 390×844 샷이 웹과 같은 배치다. |
| A3 | 지갑 칩(포상금 ₩, 구독자 '1.2만' 표기), 값이 바뀌면 카운트업 | ui.js:showTitle·updateTitleShop·countTo, rewards.js:won·shortNum | ✗ | MS | 칩 값이 `Progress.wallet`·`subs`와 같다. 구매·보상 뒤 600ms 카운트업이 돈다. |
| A4 | 타이틀 배경: 1-1 정체 위를 도는 3D 플라이오버 | main.js:goTitle·updateCamera('title') | ✗ | M2 (MS는 정적 배경으로 시작) | 배경 정체 장면이 4.5 m/s로 흐른다. 메뉴에서 60fps 미만으로 떨어지지 않는다. |
| A5 | 챕터 탭 10개: CH.n, 이름, 잠금/왕관, 진행 바, 클리어 수/전체, ◀▶, 테마 색 | ui.js:chapTabs·chapterAccent·groupChapters | ✗ | MS | `chapters.json` 10개로 그린다. 잠긴 챕터는 첫 판이 잠긴 챕터다. 다 깬 챕터에는 왕관이 붙는다. |
| A6 | 챕터 헤더: CHAPTER n · 이름 · setting, ★ 모은 수/30, 클리어 수/10 | ui.js:renderChapter | ✗ | MS | 별 합계가 `Progress.stars`의 합과 같다. |
| A7 | 스테이지 타일: 노선 방패, 고속도로명, '1-3', 종류 배지(엘리트/보스/최종), 처분 칩(형사/구조/계도), ★3, BEST 점수, 잠김(탭하면 흔들림), NEXT 태그 | ui.js:stageTileHTML·stageKind·caseKind·shieldHTML | ✗ | MS | 100판이 `stages.json`에서 나온다. 잠긴 판을 탭하면 흔들리기만 한다. 열린 판을 탭하면 StageCard가 뜬다. |
| A8 | START 버튼 = 다음 열린 판("STAGE 1-4 · 제목") | ui.js:showTitle | ✗ | MS | 처음 실행하면 1-1, 1-1을 깨면 1-2를 가리킨다. |
| A9 | 제보 앨범 버튼(모은 수/100), 차고 버튼(보유/18 + 살 수 있는 수 배지, 9+) | ui.js:showTitle·updateTitleShop | ✗ | MS | 배지 숫자 = 지갑으로 살 수 있는 미보유 아이템 수. |
| A10 | 조작 안내 줄(PC 키 · 모바일) | ui.js:updateTitleShop | ✗ | MS (PC 줄 drop) | 모바일 안내 한 줄만 남긴다. 점프를 보유하면 점프 안내가 붙는다. |
| A11 | 음소거 버튼(타이틀·HUD), M 키 | ui.js:makeMuteBtn·setMuted, main.js:toggleMute | ✗ | MS (설정 A20으로 대체) | 설정의 음악/효과음 토글이 즉시 버스에 반영된다. |
| A12 | 해금 규칙: i판을 깨면 `unlocked = max(unlocked, i+2)` | main.js:showResult | ✗ | MS | `Progress.is_unlocked(id)` 단위 테스트. 1-1을 깨면 1-2만 열린다. |
| A13 | 스테이지 카드: 표지판(방패·고속도로·방향▶), STAGE 번호, 종류 배지, 처분 태그(오늘의 빌런/형사 사건/구조 요청/계도 대상), 제목, 빌런 대사, 소개문, 정체 km·원흉 속도, 구조 띠(honkOnly), 도로 상황 타일(갓길/경적/특수) + VMS 힌트, ★미션 3개, "탭하여 바로 시작", 자동 타이머 2.6~4.4초(280ms 입력 유예) | ui.js:showStageCard·roadHTML·normRoad·missionsHTML, main.js:roadInfo·stageMissions | ✗ | MS | 탭하거나 타이머가 끝나면 `start_stage(id, loadout)`이 한 번만 나간다. ❓ 웹은 카드 뒤에서 인트로(빌런 클로즈업 + 대사)가 이미 돌고 있다 → 7절 G2. |
| A14 | 제보 앨범(도감): 헤더(누적 범칙금, 수집 바), 챕터 탭, 카드(No.001, 배지, ★, 블박 사진 또는 절차적 dashArt, 미수집은 실루엣 + '?' + '제보 대기 중', REC, 제목, 빌런명, 처분별 금액 ₩/만원/구조 표창/계도, ×횟수), 등급 테두리 r1~r3 + ★3 홀로, 바깥 탭 닫기 | ui.js:showAlbum·albumCardHTML·renderAlbumPage·albumGot·dashArt | ✗ | MS | 1-1을 깬 뒤 1-1 카드에 사진(없으면 dashArt)과 ★·×1이 보인다. 나머지 99장은 실루엣이다. 누적 범칙금 = 수집한 판 fine의 합. |
| A15 | 차고(휴게소 정비소): 지갑, 닫기, 탭 5개(차/무기/날아가는 것/피니시/패시브, 보유/전체, 살 수 있음 점), 장착 줄(슬롯 3 + 보유 능력, 탭하면 해당 탭), 아이템 카드(그림, 리본 장착 중/보유, 가격/기본, 설명, 스펙 칩, 구매/장착/"₩X 더 모으면!") | ui.js:showShop·renderShopTabs·renderLoadout·itemCardHTML·itemSpecs·itemArt | ✗ | MS | `shop.json` 18개가 모두 보인다. 스펙 칩이 웹 itemSpecs와 같다(예: 마름쇠 '초당 피해 40 · 3발 동시'). |
| A16 | 구매/장착: 지갑 차감, owned 추가, 슬롯형(차·무기·피니시)은 자동 장착. 돈이 모자라면 흔들림 + "₩X 부족!" + warn. 사면 코인 버스트 + '구매 완료!' 도장 + stageClear. 장착하면 팝 + ui음 | main.js:onBuy·onEquip, ui.js:onShopClick·celebrate·equipPop·shopFloat | ✗ | MS | `can_buy`/`buy`/`equip` 단위 테스트(기본 아이템은 항상 보유, 이중 구매 금지, move/passive는 장착 없이 적용). 저장 후 재실행해도 유지된다. |
| A17 | 결과 보상 타임라인: 처분 카드 도장 @280ms(블박 사진 + REC OSD 날짜·시각·차로·속도, 위반 조항, 범칙금) → 미션 ✔/✖ @700+i·380ms + 별 효과음 → SCORE 카운트업 → 포상금 +₩ @1750 → 지갑 합계 @2150 → 참교육 채널 @2250(영상 제목 '[블박] …', 길이, 조회수 카운트업, +구독자, 총 구독자) → 가짜 댓글 3개 @2450(닉네임·아바타) → 마일스톤 @2600(실버/골드 상패 또는 메달 토스트, 4.2초 뒤 자동 닫힘) → 통계 줄 → 버튼(다음 빌런▶/다시하기/메뉴, 마지막 판은 '처음부터' + 완주 문구) | ui.js:showRewardResult·TL·popMissions·countScore·resultButtons·mileTier, main.js:showResult | ✗ | MS | 가짜 게임 결과로 타임라인 순서와 시각(±50ms)이 웹과 같다. 지갑 증가 = `record_result`가 돌려준 payout. 버튼 3개가 각각 다음 판 카드/같은 판 카드/대시보드로 간다. |
| A18 | 실패 카드(견인): 제목, 레커 그림 + '견인!' 도장, 사유, 빌런, '원인 발견 지점부터 다시'/메뉴, 0.45초 입력 가드, 자동 진행 없음 | ui.js:showFail·closeFail, main.js:update('wreck') | ✗ | IS | 재도전은 판 안에서 처리한다(스냅샷 복원). 메뉴를 고르면 `stage_finished({cleared:false})`. |
| A19 | 일시정지 오버레이: 계속하기/메뉴로. jam·boss에서만. 백그라운드로 가면 자동 정지 | ui.js:buildPause·setPausedVisible, main.js:setPaused·visibilitychange | ◐ (game.gd:set_paused는 트리 정지 + HUD 아이콘만, 오버레이·메뉴 없음) | IS (+MS: 설정 진입 ❓) | 메뉴로 → `stage_finished({cleared:false})` → 대시보드. 보상·패널티 없음. |
| A20 | 설정 {music, sfx, haptics, battery60, left_hand} + 크레딧/OFL | 웹에는 음소거와 prefers-reduced-motion만 있다(**네이티브 신규**) | ✗ | MS (적용은 IS/FI) | 토글이 Progress에 저장되고 재실행 뒤에도 유지된다. battery60이면 `Engine.max_fps = 60`, left_hand이면 전투 버튼 좌우가 반전된다. 크레딧에 OFL 원문이 보인다. |
| A21 | 오늘의 빌런(날짜 시드) | 웹에는 없다(카드 태그 '오늘의 빌런'만 있음, **네이티브 신규**) | ✗ | MS | 같은 날짜면 실행할 때마다 같은 판이다(yyyymmdd → Mulberry32). 열린 판에서만 고른다. 대시보드에 카드 하나로 보인다. |

## B. 판 안 HUD

| # | 기능 | 웹 위치 | 상태 | 담당 | 합격 기준 |
|---|---|---|---|---|---|
| B1 | 좌상단 스테이지 칩(방패 + 고속도로 + 방향) | ui.js:setStage | ✗ | IS | 판 id에 맞는 노선 번호가 보인다. |
| B2 | 내비 바: 시드 정체 색띠(빨강/주황), 내 차 마커, 원흉 얼굴 → 해방 후 ✔, 해방 초록 채움 + 광택 | ui.js:buildNav·setJamPattern·setNav | ◐ (N1 바 + 마커만) | IS | 해방 중에는 초록이 (G.time−releaseTime)·70/(frontS−tailS) 비율로 찬다. |
| B3 | "원흉까지 N m" | ui.js:setHUD | ● (hud.gd N1, test_hud_progress) | IS | 유지. |
| B4 | 잔챙이 칩 done/total, 다 잡으면 ✔ + 펄스 | ui.js:setHUD(minis) | ✗ | IS | 잔챙이가 있는 판에서만 보인다. |
| B5 | 속도계 260° 다이얼, km/h, 100 이상 is-fast, 분노 경적 뒤 부스트 링 | ui.js:buildSpeedo·setHUD | ◐ (원판 + 숫자, 바늘·부스트 없음) | IS | 부스트 2.2초 동안 링이 줄어든다. |
| B6 | **분노 5칸**: 채움, 1칸 이상이면 준비 빛, MAX, 모드 라벨(분노의 경적/분노 폭탄/사이렌) | ui.js:buildRage·setHUD(rageMode) | ◐ (**hud.rage 0 고정** = 사용자 불만) | IS | 1-1 정체에서 멈춰 있으면 칸당 약 9.5초다(0.005+0.016 /s, 1칸 0.2). 40초 안에 ≥3칸. 분노 버튼 준비 빛이 칸과 같이 켜진다. |
| B7 | 범퍼 HP 5칸(반 칸 단위), 주의 ≤2칸/위험 ≤1칸, 피격 연출(붕괴 링·파편·0.5초 안의 −N 합산), 무적 깜빡임, HP 비네트 맥동 | ui.js:buildHP·setHP·hpHit·hpFx | ◐ (hud.hp 5 고정) | IS | 피해 10이면 반 칸이 깎인다. ≤20%면 빨간 비네트가 맥동한다. |
| B8 | SCORE 박스, 콤보 xN(20 이상 hot) | ui.js:setHUD | ✗ | IS | 콤보 0이면 숨는다. 숫자가 바뀌면 bump. |
| B9 | 보스 바: 빌런명('OO 2대' 축약), HP + 지연 바, 타이어 4개(펑크 아이콘) | ui.js:buildBoss·showBoss·hideBoss, rewards.js:villainNames | ✗ | IS | 펑크마다 타이어 한 칸이 바뀐다. kill 때 사라진다. |
| B10 | 배너(big/go/warn/boss + 회전 광선): 출발!, 원인 발견!, 앞을 막았다! 정면 참교육!, n페이즈!, 분노의 경적!!, 1대 참교육!, 원인 제거!, N차선 개방!, 뻥 뚫렸다!!, 질주 타임!, 견인!!, 재도전 n회차 | ui.js:banner·startBanner | ✗ | IS | 페이즈마다 웹 문구 그대로. 동시에 1개만 보인다. |
| B11 | 💡 힌트 바: 튜토리얼 2개(1-1 jam 0.9s·5.2s), 얌체/잔챙이 첫 등장, 원인 발견, 정면 고정, 정체에서 2.2초 멈춤, 시그니처 힌트 | ui.js:hint, main.js:enterPhase(jam·boss)·update(stuck)·onCheater·onMiniAct | ✗ | IS | 1-1을 처음 하면 힌트 두 개가 웹과 같은 시각에 뜬다. 문구는 터치용(IS_TOUCH 분기). |
| B12 | 토스트: '갓길 폐쇄!/터널: 갓길 없음!', 경적 피로, sigToast | ui.js:toast | ✗ | IS | 같은 토스트는 2초 안에 다시 뜨지 않는다. |
| B13 | 차 위 말풍선(taunt/thanks/angry, 최대 8) | ui.js:bubble, main.js:bubble·updateBubbles | ● (ui/bubbles.gd) | IS | 유지. |
| B14 | 팝 텍스트 5종(hit/crit/score/warn/bump) | ui.js:popText | ◐ (warn·score만) | IS | 펑크! = crit, 범퍼 −N = bump, −4 = hit. |
| B15 | 화면 플래시, 분노 비네트(jam에서 rage>0.5) | ui.js:flash·vignette | ✗ | IS | kill에서 흰 플래시 160ms. |
| B16 | 해방 카운터 "해방된 차량 N대" | ui.js:setReleaseCounter | ✗ | IS | release·cruise에서 sim 해방 수 × mult(displayCars/simCars). result 0.2초 뒤 사라진다. |
| B17 | 터치 버튼: ◀ ▶, 경적/발사(fireMode에 따라 라벨이 바뀜), 분노(준비 빛), 점프(보유 시만, 쿨 링), 일시정지 | ui.js:buildTouch·setControls·setFireMode | ◐ (◀ ▶ 경적 일시정지만) | IS | 분노 버튼이 rage_requested를 소비한다. mv_jump가 없으면 점프 버튼이 숨는다. |

## C. 판 안 시스템 (코어 루프 · 전투)

| # | 기능 | 웹 위치 | 상태 | 담당 | 합격 기준 |
|---|---|---|---|---|---|
| C1 | 페이즈 머신 intro→jam→boss→(wreck)→kill→release→cruise→result | main.js:enterPhase·update | ✗ (jam만) | IS | 1-1 autopilot 20 seed가 100% result에 도달한다(M1b T1). |
| C2 | 인트로: 빌런 클로즈업 + villainLine 대사 → 카드가 끝나면 2초 스윕 → 추격 | main.js:enterPhase('intro')·updateCamera('intro') | ✗ | IS | 카드가 닫히고 2.05초 뒤 jam. |
| C3 | **분노 획득 소스**: base 0.005/s(jam), +0.016/s(v<5), 추돌 0.06, 얌체 끼어들기 0.05, 잔챙이 칼치기 0.05, 경적 noway 0.015, 원흉 도발이 보일 때 0.015, 잔챙이·투척 피격 0.04, 정면 피격 0.08, 콘·낙하물 0.012. HP ≤20%면 ×2. 커피면 1칸으로 시작. 칸이 오르면 rageFull음 + '분노 충전!/분노 MAX!!' | main.js:addRage + 호출부(update·onBump·onCheater·onMiniAct·onPlayerHit·onSmash·taunt loop) | ✗ | IS | 단위 테스트: 소스별 증가량이 config.json tune과 같다. 정체 40초 ≥3칸(B6). |
| C4 | **분노 사용**(1칸 = 0.2): 정체·원흉 뒤 → 분노의 경적(갓길 앞 24~48m의 콘·낙하물 날림, 얌체 복귀, 옆 차 깜짝, 레커/지인 주차 견인, 부스트 2.2초, 배너, 충격파 4개) / 정면 → 분노 폭탄 미사일(superDmg 28) / 구조판 → 사이렌 대경적. 모자라면 '분노 부족!' | main.js:rageHorn·rescueHonk, weapons.js:fireMissile, traffic.js:rageHorn | ◐ (C++ `rage_horn` 있음, 미연결) | IS | 1칸으로 경적을 쓰면 rage −0.2. 갓길 콘이 날아가고 점수 +50/개. |
| C5 | HP: 최대 100(포터 130), 피해 등급 10/20/30/40, 판별 배율(1-1~3 ×0.5, 4~6 ×0.8, ch2 1.0 → ch10 1.3), jamFloor 20, 무적 1초, 상대속도 ≥6이면 추돌 10, 고장차 20, 콘 5(부스트 중 0), 잔챙이 투척 5, 회복(잔챙이 +10, 페이즈 +10 1회), 에어백 | main.js:applyDamage·healHP·stageDamageMul·onPlayerHit·onBump | ✗ | IS | 정체 구간에서는 HP가 20 아래로 내려가지 않는다(테스트). |
| C6 | 손상 연출: 차 손상 단계 0~4, 흰/검은 연기, ≤20%면 비상등 점멸 | main.js:syncHP·updateDamageFx, vehicles.js:setDamage·setHazard | ✗ | IS | HP 60 이하에서 연기가 0.6초 주기로 난다. |
| C7 | 견인·재도전: 0.3× 슬로모 1.4초, 폭발, 스핀, 비상등 → 실패 카드 → 원인 발견 지점부터(빌런 HP·펑크·페이즈 유지, 분노는 발견 시점 값, 포상금 ×(1−0.2·실패) ≥0.6, 배너) | main.js:wreck·retryFromDiscovery | ✗ | IS | NATIVE_PORT R1: 페이즈가 적용된 보스 상태 전체를 복원한다. retry_mul이 결과에 실린다(7절). |
| C8 | 경적: 쿨 1.0초, '빵!' 팝 + 링, 응답(원흉 도발, 얌체 +300 + ₩10,000, yield, letin, noway(+분노), tired + 피로 토스트), 사거리 기본 18 / 트로트 24 / 사이렌 45 | main.js:update(horn), traffic.js:honk | ◐ (game.gd:honk·_reply_bubble 말풍선 ●, C++ 피로 ●. 점수·보너스·분노·토스트·트로트/사이렌 ✗) | IS | 같은 차에 3번 누르면 '또 빵?' + 토스트. |
| C9 | 갓길 장애물 앞에서 경적 → 4차선이 끼워 줌(letIn) | traffic.js:letIn | ● (C++ let_in) | IS | 유지. |
| C10 | 갓길 얌체: 생성, 끼어들기 이벤트 → 말풍선 + 분노 + 첫 등장 힌트 + cutin음. 경적·분노 경적이면 복귀 | traffic.js:_spawnCheaterAhead, main.js:traffic.onCheater | ◐ (C++ 생성 + `cutin` 이벤트 → 신호 아이콘만) | IS | 1-1에서 얌체 1대가 끼어들면 분노 +0.05. |
| C11 | 갓길 장애물: 고장차(비상등, 충돌 20), 공사 콘(날림, 5), 낙하물(날림) | shoulder.js:buildShoulderObstacle, main.js:onSmash·flingObstacle | ◐ (고장차 소품 + 비상등만, 날림·충돌 ✗) | IS | 콘을 들이받으면 파편 + '콘 날리기!' + 점수 +50. |
| C12 | 접근 규칙: 갓길 모드 9종 × 경적 모드 11종(1챕터 매트릭스) | stagegen.js:APPROACH_BY_ID, traffic.js(approach), ui.js:SH_MODES·HONK_MODES | ◐ (C++가 approach를 읽음, 1-1 외 미검증) | M2 | 1-2~1-10에서 카드 타일과 실제 규칙이 같다. |
| C13 | 갇힘 보조: rubber band, 4초 강제 개방, 자동 견인 2회 '레커 출동!' | traffic.js:_stuckAssist, main.js:traffic.onAutoTow | ◐ (C++ stuck_assist + `auto_tow` 이벤트, 날림·팝 ✗) | IS | NATIVE_PORT R2: jamLike 동안 돈다. 고장차 앞에서 멈춰도 4초 안에 빠져나온다. |
| C14 | 잔챙이 3종(꽁초/쓰레기/갓길 칼치기, 주황 표식): 행동(투척 또는 칼치기 분노) + 첫 힌트. jam에서 압정으로 잡으면 +400, 범칙금 보너스, HP +10, 사과 말풍선, '꽁초 투척러 참교육! +5만원' | main.js:onMiniAct·onMiniHit, traffic.js:miniTarget·miniHit, config.js:MINI_TYPES | ◐ (C++ mini_act/mini_target/mini_hit, LAMP_MINI 비트. 게임 쪽 ✗) | IS | 1-1 잔챙이를 다 잡으면 ★3 미션 달성, mini_fines가 결과에 실린다. |
| C15 | 주변 차 수다: 원흉 뒤 차 고함 + 짧은 경적(1.1~2초 간격), 차선 변경이 막히면 '어딜 끼어들어!', 추돌 대사 | main.js:update(nextFrontRage)·onBump | ✗ | IS | intro~boss 동안 말풍선이 동시에 8개를 넘지 않는다. |
| C16 | 플레이어 주행: 차로 0~3 + 갓길(4), 차로 변경 0.18초, 가감속, 최고 18 m/s, 추돌 넉백, 부스트, 해방 때 ghost, 질주 110km/h | player.js:Player.update·requestLane·knock | ◐ (view/player_driver.gd IDM 대역) | IS | player.js와 같은 갓길 규칙(폐쇄면 'closed' 토스트). |
| C17 | 무기: 압정(꾹 누름, 초당 7발, 4)·마름쇠(3발)·물풍선(공격 지연)·껌(×1.6). jam에서는 잔챙이 자동 조준, 정면에서는 뒤로 투하 → 펑크 | weapons.js:fireAt·tryFireAt·update | ✗ | IS (압정) / FI (상점 무기 3종 — 상점에서 팔기 때문) | 장착 무기의 dmg·rate·spread가 loadout대로 적용된다. |
| C18 | 원흉 전투: 35m 앞에서 발견 → boss, 뒤에서 압정 선제, 정면 고정(lockAt·sameLane), 빌런 HP·타이어 4개·펑크, 공격 8종(highbeam/horn/lunge/throw/roll/swerve/zigzag/smoke) + 예고 표식·위험 차로, 공격 간격, 도발, 다중 빌런('1대 참교육!', '형님!!') | boss.js:BossManager.update·_attack·damage·_popTire·targetFor·dangerLanes | ✗ | IS | 1-1 김사장 HP 140, 공격표 highbeam 2/horn 2/lunge 2/throw 1. |
| C19 | 보스·엘리트 페이즈(HP 임계, 라벨 배너, 회복, 공격표 교체, 정차/서행/지그, 간격 ×0.85) | boss.js:_checkPhase, main.js:onBossPhase | ✗ | M2 (1-10이 첫 판) | 1-10 페이즈 2 진입 배너 + HP +10. |
| C20 | 구조판(honkOnly, 표창): 경적 = 깨우기 게이지, 사이렌, pullover 피니시, 압정·드론 금지 | main.js:rescueHonk, boss.js(pullover) | ✗ | M3 (첫 판 36) | 압정이 나가지 않는다. 결과 카드가 '구조 표창'이다. |
| C21 | 시그니처 모듈: occupy(1-1), blinker_liar(1-5), tailgater(1-6) + 신규 7종 | behaviors/index.js | ✗ | IS (occupy) / M2 (나머지) | 1-1 occupy의 정면 위치·해방 차로가 웹과 같다. |
| C22 | kill: 히트스톱 0.16, 0.28× 슬로모 1.25초, 흰 플래시, 흔들림, 덕킹, superHit, 킬캠 궤도, '원인 제거!' | main.js:enterPhase('kill')·updateCamera('kill') | ✗ | IS | 첫 kill 구간 최대 프레임 ≤16.7ms(M1b 기기). |
| C23 | 피니시: 로켓 → 반짝★(기본), 풍선, 헬기, UFO, pullover | boss.js:startDeath·_updateDeath·_updateFinish·fxProp | ✗ | IS (로켓) / FI (3종 — 상점에서 팔기 때문, 계획상 M3) | 장착 피니시가 결과에 반영된다(loadout.finish). |
| C24 | 블박 사진 캡처(kill + 0.45초, 256×144) → 결과·도감 | main.js:captureDashcam·frame(photoAt) | ✗ | IS (캡처) + MS (저장·표시) | 결과 카드와 도감에 같은 사진이 보인다. user:// 파일 ≤ 30KB/장. |
| C25 | 해방: 막힌 차로부터 개방(zig면 중심), VMS 문구 교체(초록), 'N차선 개방!' → '뻥 뚫렸다!!', 응원 경적, 0.6초 뒤 해방 BGM, 컨페티, 70 m/s 초록 파도, 감사 말풍선 28%, 하트 18%, 깜빡이음, 드론샷 카메라 | main.js:enterPhase('release')·releaseWave, traffic.js:release·onReleased | ◐ (C++ release + `released` 이벤트) | IS | 파도가 꼬리를 지나고 4.2초가 넘으면 cruise. |
| C26 | 질주: 스피드라인, '질주 타임!', 30.5 m/s 4.2초, FOV 확대 → result | main.js:enterPhase('cruise') | ✗ | IS | — |
| C27 | 점수·콤보·속시원함: 타격 dmg×10×(1+0.05·combo), 잔챙이 +400, 얌체 +300, 견인 +150, 날림 +50, 피격 −50. 추돌·피격이면 콤보 리셋. 최종 = score + freed×5 + cath×40. cath = 70 ± (추돌, 보스 시간, 분노 폭탄, maxCombo), 12~100 | main.js:onWeaponHit·showResult | ✗ | IS → 결과 dict | 결과 dict의 score·cath가 웹 공식과 같다(같은 입력이면 같은 값). |
| C28 | 해방 대수·아낀 시간: displayKm×4×125, (km/9 − km/100)×60분×대수 | main.js:showResult | ✗ | IS → 결과 dict | 1-1: 2.4km → 1,200대. |
| C29 | 별 미션: ① 원인 제거 ② **클리어 때 HP ≥ 60** ③ 잔챙이 전원(없으면 자동) | main.js:stageMissions·showResult | ✗ | IS (판정) / MS (라벨 `missions_for`) | missions_done[3]이 판정과 같다. ★ = 달성 수. |

## D. 경제 · 진행 시스템 (Progress)

| # | 기능 | 웹 위치 | 상태 | 담당 | 합격 기준 |
|---|---|---|---|---|---|
| D1 | 세이브 스키마 v3 {unlocked, stars, best, wallet, subs, album, owned, equip}. 웹 v0.2 id 재매핑(1→1, 2→11, 3→4, 4→9, 5→50). 용량 초과면 사진부터 비움 | main.js:loadProgress·saveProgress | ◐ (core/save_game.gd: tmp+rename+.bak만, 스키마·마이그레이션 없음) | MS | 테스트: v0.2·v3 웹 JSON을 읽어 재매핑한다. 본 파일이 깨지면 .bak으로 읽는다. 미래 버전 파일은 덮어쓰지 않는다. |
| D2 | 판별 ★ 최고값 유지, BEST 점수 최고값 유지 | main.js:showResult | ✗ | MS | 더 낮은 ★로 다시 깨도 내려가지 않는다. |
| D3 | 포상금 = round100(((payout ?? fine) × [1,1,1.5,2][★] + 얌체×10,000 + 잔챙이 범칙금) × (4K면 1.25) × retryMul) | rewards.js:computeReward | ✗ | MS (`record_result`) | 표 테스트: 1-1(payout 40,000), ★3, 얌체 1, 잔챙이 2(꽁초·쓰레기 각 50,000), 4K 없음, 재도전 없음 → 40,000×2 + 10,000 + 100,000 = ₩190,000. 4K가 있으면 ₩237,500, 1회 견인 후면 ×0.8. |
| D4 | 조회수·구독자: views = (freed×38 + cath×950)×(0.85 + (seed·7919 mod 100)/300), subs = max(12, views×0.011). 댓글 3개(시드, {v} 치환). 마일스톤 1천/1만/10만 실버/100만 골드 | rewards.js:computeReward·applyReward·MILESTONES·COMMENTS | ✗ | MS | 같은 seed면 같은 값(결정적). 마일스톤을 넘은 판에서만 이벤트가 나간다. |
| D5 | 도감 항목 {stars 최고, fine, photo, at, count++} | rewards.js:applyReward | ✗ | MS | 다시 깨면 count만 오른다. 사진은 더 높은 ★일 때만 바뀐다. |
| D6 | 처분 카드 4종(고지서/형사/표창/계도): 도장 문구, 직인, 금액 표기(≥100만이면 'n만원') | ui.js:CASE·caseKind·bigWon, data/cards.json | ◐ (cards.json ●, UI ✗) | MS | 형사 판 결과 카드가 빨간 '형사 입건', 금액이 '1,500만원' 형식이다. |
| D7 | 상점 18종 효과: car_hatch 기본 / car_porter HP 130·속도 0.93 / car_wrecker 고장차 즉시 견인·armor 1·0.97 / car_patrol 사이렌(경적 45m·얌체 50m)·1.08 / wpn_tack·caltrop·water(slow 0.55)·gum / mv_jump(쿨 4초) / mv_drone(0.7초마다 자동 사격, 구조판 원흉 제외) / fin_rocket·balloon·heli·ufo / pas_4k ×1.25 / pas_airbag(판당 1회 HP 1로 버팀) / pas_trot(경적 24m) / pas_coffee(분노 1칸 시작) | config.js:SHOP, main.js:setupStage·owns·equipped·updateDrone | ◐ (shop.json ●, 효과 ✗) | MS (loadout) + IS (적용) + FI (차 3종 메시·드론·피니시 3종) | 각 아이템을 장착하고 1판을 하면 효과가 하나씩 관측된다(체크리스트 8). |
| D8 | loadout → GameSim: {speed, hp_max, armor, tow, siren, trot, airbag, jump, drone, coffee, car_kind, weapon{proj,dmg,rate,spread,slow}, finish} | main.js:setupStage | ✗ | MS (생성) / IS (소비) | `Progress.loadout()`의 키가 7절 G3 목록과 같다. |

## E. 월드 · 연출

| # | 기능 | 웹 위치 | 상태 | 담당 | 합격 기준 |
|---|---|---|---|---|---|
| E1 | 하늘 프리셋 7종(day/sunset/morning/night/rain/snow/fog), 판별 sky | config.js:SKY, world.js:applySky | ◐ (world.gd:_apply_sky가 sky.json 색을 읽음, 1-1 낮만 검증) | IS (1-1) / M2 (1챕터에 morning·sunset·rain·night 있음) | 1-2~1-10 샷이 웹과 ΔE 기준을 만족한다. |
| E2 | 날씨 파티클(비 선, 눈 점) | world.js:_setWeather·_updateWeather | ✗ | M2 (1-5 rain) | 1-5에서 비가 카메라를 따라 내린다. 비용 고정. |
| E3 | 밤: 전 차량 전조등, 가로등, 어두운 지면 | world.js:build(night), vehicles.js:setHeadlights | ◐ (LAMP_HEADLIGHTS 비트) | M2 (1-6, 1-9) | — |
| E4 | 갠트리 표지판 글자(stage.signs) + VMS 3개(정체 km + 원인 / stage.vms / 정체 구간 끝) + 해방 때 초록 문구 | world.js:build·setVMS, scenery.js:buildGantrySign·buildVMS | ◐ (프레임 + 빈 판) | IS (M1c 텍스트 판) | 1-1 VMS에 '앞쪽 정체 2.4km / 원인: 1차선 저속차량'. |
| E5 | 도로변 현수막 6종 문구, CCTV, 나무·집·아파트·교회·산·논·구름, 방음벽, 반대편 차로 | world.js:build·BANNERS | ◐ (소품·반대편 ●, 현수막 글자 ✗) | IS | — |
| E6 | 터널·합류 테이퍼·단속 갠트리·비상 주차대·노면 데칼·젖은 노면 | scenery.js(만들어 두었지만 웹 world가 안 씀) | — (웹에서도 안 보임) | M3 | 웹 대비 신규. |
| E7 | FX: 스파크, 폭발, 연기·연기 꼬리, 파편, 컨페티, 충격파 링, 반짝★, 히트 플래시, 하트, 카메라 흔들림, 스피드라인 | fx.js:FX.* | ◐ (honk_wave 링만) | IS | 페이즈 6개 샷 베이스라인(M1c T2). |
| E8 | 페이즈별 카메라: 타이틀 플라이오버, 인트로 스윕, 추격, boss 뒤/정면 탑다운(세로·가로), 킬 궤도, 해방 드론샷, 질주. 페이즈별 FOV, 흔들림 | main.js:updateCamera·chaseTarget | ◐ (추격만) | IS | — |
| E9 | 빌런 표식, 잔챙이 주황 표식, 공격 예고 표식·위험 차로 | boss.js:_getMarker·dangerLanes | ◐ (LAMP 비트 + N5 아이콘) | IS | — |
| E10 | N5 신호 아이콘(깜빡이/STOP/상향등/비상등/경적/무깜빡 끼어들기) | 웹에 없음(**네이티브 신규**) | ● (view/signal_icons.gd) | — | 유지. |

## F. 소리 · 햅틱

| # | 기능 | 웹 위치 | 상태 | 담당 | 합격 기준 |
|---|---|---|---|---|---|
| F1 | 음악 4곡: menu / jam / boss / release(130BPM), 페이즈 전환, kill·wreck 덕킹 | audio.js:startMusic·duck·SONGS | ✗ | IS (판 안) + MS (타이틀 menu) | 타이틀 → 판 → 결과 → 타이틀에서 곡이 끊기지 않고 바뀐다. |
| F2 | 앰비언스 jam/free, 엔진음(속도 연동) | audio.js:startAmbience·setEngine | ✗ | IS | — |
| F3 | 효과음 31종(horn, hornShort, hornTruck, hornAngry, tack, hit, crit, pop, explosion, whoosh, bump, laneChange, ui, uiConfirm, rageFull, super, superHit, brakeScreech, warn, throw, splat, launch, twinkle, stageClear, star, cutin, blink, tauntBlip, chicken, go) + 응원 경적, 거리별 팬·볼륨 | audio.js:SFX·play·cheerHorns | ◐ (horn·hornShort만) | IS / MS (ui·uiConfirm·star·stageClear·warn: 메뉴·상점·결과) | 결과 별이 뜰 때 star 음높이가 1, 1.25, 1.5로 오른다. |
| F4 | 햅틱 19종(bossPhase … wreck) | 웹에 없음(**네이티브 신규**, data/haptics.json) | ◐ (horn·laneChange 연결) | IS / MS (uiLight: 메뉴 버튼) | 설정 haptics=false면 하나도 나가지 않는다. |

## G. 입력 · 플랫폼

| # | 기능 | 웹 위치 | 상태 | 담당 | 합격 기준 |
|---|---|---|---|---|---|
| G1 | 좌우 스와이프로 차로 변경, 위 스와이프로 분노 | input.js:Input(pointer) | ◐ (lane_input.gd ●, rage_requested를 아무도 소비하지 않음) | IS | 위 스와이프 한 번 = 분노 한 번. |
| G2 | 멀티터치(발사를 누른 채 스와이프), 포커스를 잃으면 전부 해제 | input.js, ui.js:releaseTouch | ◐ (경적 존 hold) | IS | — |
| G3 | 브레이크(↓/S, 웹에서는 키보드만. 1-5 blinker_liar '헛스윙'에 필요) | input.js:KEYMAP | ✗ (터치 브레이크 없음) | M2 ❓ (터치 제스처를 정해야 함) | — |
| G4 | 백그라운드로 가면 자동 정지 | main.js:visibilitychange | ● (game.gd NOTIFICATION_APPLICATION_PAUSED) | IS | 유지. 메타 화면에서는 저장만 한다. |
| G5 | 세이프 에어리어 | 웹 CSS env() | ● (hud.gd) | IS + MS | 모든 메타 화면도 같은 inset을 쓴다. |
| G6 | 모션 줄이기(prefers-reduced-motion → 타임라인 즉시) | ui.js:build·later | ✗ | M4 | — |
| G7 | 키보드 단축키(Enter 시작/다음, M, P/Esc, A/D/J/K/H/R/E/W) | input.js:KEYMAP, main.js:update(confirm) | — | drop (데스크톱 개발용으로만) | — |

## H. 빼는 디버그 기능

| # | 기능 | 웹 위치 | 처리 |
|---|---|---|---|
| H1 | `?auto=1` autopilot | main.js:autopilot | 플레이어 빌드에서 뺀다. 테스트 봇(T1/T4)으로만 남긴다. |
| H2 | `?stage=N&skip=jam/boss/kill`, `?ff=N`, `?mute=1` | main.js:boot·debugSkip·FF | 개발용 CLI 인자로만 둔다(`--stage`, `--skip`). |
| H3 | `window.__game`, `G.debugSkip/debugDamage/startStage/enterPhase/objs`, `G.fps`, `G.lastError` | main.js | 뺀다. 네이티브 `view/debug_panel.gd`는 debug 빌드에서만 켠다. |
| H4 | `window.claude.hot` 스냅샷·ready | main.js:boot | 뺀다(웹 뷰어 전용). |
| H5 | localStorage 용량 초과 시 사진 비우기 | main.js:saveProgress | 사진 파일당 크기 상한 + 최대 100장으로 대체한다. |
| H6 | game.gd `_write_boot` 부트 로그, native-check 단계 | view/game.gd | 출시 export에서 끈다(FI). |

---

## 7. CONTRACT 보강안 (meta ↔ game)

- **G1 결과 dict 필드 추가 ❓.** 계약은 {stage_id, cleared, time_s, min_hp, tows, payout_base, fine, card, missions_done, villain_name, stats}다. 웹 공식을 재현하려면 아래 필드가 더 있어야 한다.
  - `score: int` — BEST와 결과 SCORE(C27).
  - `freed: int`, `cath: int` — 조회수·구독자(D4), 통계 줄.
  - `cheaters: int`, `mini_fines: int` — 포상금 보너스(D3).
  - `retry_mul: float` — 재도전 감액(C7). 기본 1.
  - `hp_end: int`, `hp_max: int` — '남은 내구도' 통계. 웹 ★2는 클리어 때 HP다. min_hp가 아니다.
  - `fails: int` — '견인 n회'.
  - `photo: Image`(또는 `user://` 경로) — 결과 카드와 도감(C24).
  - `seed: int` — 댓글·조회수 시드. 웹은 `floor(G.time·1000) % 997 + 1`.
  - `aborted: bool` — 일시정지 '메뉴로'나 실패 카드 '메뉴'. 보상 없이 대시보드로 간다.
- **G2 인트로 겹침 ❓.** 웹은 스테이지 카드를 intro 페이즈 위에 띄운다. 그래서 빌런 클로즈업과 대사가 카드 뒤에서 이미 돌고 있다. 계약 순서(카드 → start → game 로드)를 따르면 이 장면이 사라진다. 제안: app이 카드를 띄우는 순간 `game.tscn`을 미리 붙인다(`set_process(false)` + intro 카메라). 카드가 닫히면 `start()`를 부른다. 이 방식은 로딩 히치도 숨긴다.
- **G3 loadout 키**는 D8 목록대로 한다. 값의 출처는 shop.json의 `stats`·`dmg`·`rate`·`spread`·`slow`·`kind`다. game은 이 dict 하나만 읽는다(game이 Progress를 직접 읽지 않음).
- **G4 payout 책임:** `payout_base`는 game이 보낸 값을 그대로 쓰지 않는다. `stages.json`의 `payout ?? fine`과 D3 공식으로 `Progress.record_result`가 계산한다. 책임이 한 곳에 있어야 웹과 대조 테스트를 할 수 있다.

## 8. 최종 통합 체크리스트

1. `project.godot`: autoload에 `Progress="*res://meta/progress.gd"`를 SaveGame 뒤에 추가한다. `run/main_scene`을 `res://screens/app.tscn`으로 바꾼다. 이 두 줄은 FI만 고친다.
2. `app.gd`의 `GAME_SCENE`을 `dev_fake_game.tscn`에서 `res://view/game.tscn`으로 바꾼다(상수 1개). 가짜 게임은 export 제외 필터에 넣는다.
3. `game.tscn` 루트: `stage_id`와 `loadout`을 build 전에 받는다. 클리어·실패 메뉴·일시정지 메뉴에서 각각 `stage_finished(result)`를 한 번만 낸다(7절 G1 필드 포함).
4. 설정을 연결한다. music/sfx는 AudioServer 버스 mute, haptics는 `Haptics` 게이트, battery60은 `Engine.max_fps = 60`, left_hand는 Hud 버튼 반전이다.
5. 음악을 넘긴다. 타이틀 menu → 판 jam/boss/release → 결과 → 다시 menu. 판을 시작할 때 menu가 겹치지 않아야 한다.
6. 사용자 불만 두 개를 실기기에서 확인한다. ① 1-1 정체에 40초 있으면 분노가 ≥3칸이고, 위 스와이프나 분노 버튼을 누르면 갓길이 열린다. ② 앱을 켜면 첫 화면이 대시보드다(챕터 탭, 1-1 NEXT, 지갑 ₩0).
7. 루프 하나를 끝까지 돈다. 대시보드 → 1-1 카드 → 플레이 → kill → 해방 → 보상 타임라인 → 지갑 증가 → 다음 빌런(1-2 카드) → 앱 종료·재실행 → 지갑·★·도감 사진이 그대로다.
8. 상점 효과를 하나씩 관측한다(D7). 포터 HP 130, 레커 즉시 견인, 순찰차 사이렌, 무기 3종 dps, 점프 버튼, 드론 사격, 피니시 3종, 4K 포상금 ×1.25, 에어백 '간신히 버팀', 트로트, 커피 1칸.
9. 테스트를 돌린다. `--filter=progress`(스키마·마이그레이션·D3/D4 표 테스트), `--filter=screens`(가짜 게임 루프 스모크), IS의 페이즈·분노 테스트, 그리고 390×844 Xvfb 샷 5종(타이틀·카드·차고·도감·결과)을 웹 Playwright 샷과 나란히 놓고 비교한다.
10. 기기에서 확인한다(CLAUDE.md §2). 빌드, 설치, 실행, 기능 확인(6·7번)의 성공 여부를 **각각** 보고한다. 결과는 `docs/FEEDBACK_LOG.md`와 NATIVE_PORT §9에 남긴다.
