# native/screens — 메타 화면 (타이틀·카드·차고·도감·보상·일시정지·설정)

가설:
- ✅ 웹 대시보드 흐름(타이틀 → 챕터 탭 → 스테이지 그리드 → 스테이지 카드 → 시작 → 보상 타임라인 → 대시보드)을 Control 씬으로 옮기고 가짜 게임을 붙이면, 판 안 GameSim 없이도 루프 전체를 지금 테스트할 수 있다(`tests/test_screens.gd`).
- ✅ 화면은 `ScrMeta` 하나로만 진행도를 읽고 쓴다. 그래서 실제 `Progress` autoload(`native/meta`)와 대체 stub에서 같은 화면이 같은 숫자로 돈다(stub ↔ Progress 대조 테스트).
- ❓ 웹은 스테이지 카드를 인트로 위에 띄운다(NATIVE_PARITY 7 G2). 지금은 카드 → 게임 로드 순서다. 미리 로드할지는 최종 통합(FI)에서 정한다.

| 파일 | 역할 (웹 원본) |
|---|---|
| `app.tscn` / `app.gd` (`ScrApp`) | 앞으로 main scene이 된다. 상태 TITLE → CARD → GAME → (PAUSED) → REWARD를 돈다. `start_stage(id, loadout)` 신호, GameHost 아래 `GAME_SCENE`, `stage_finished` → `record_result` → 보상. 설정 적용(버스 mute, Haptics, max_fps)도 여기서 한다. |
| `title_dashboard.gd` (`ScrTitle`) | ui.js showTitle·chapTabs·renderChapter·stageTileHTML·updateTitleShop. 오늘의 빌런 줄은 네이티브 신규다. |
| `stage_card.gd` (`ScrStageCard`) | ui.js showStageCard·roadHTML·missionsHTML. 280ms 유예, 타이머 2.6초 + 0.8초 + 1초. 네이티브에만 있는 ✕ 버튼이 있다. |
| `garage.gd` (`ScrGarage`) | ui.js showShop·itemCardHTML·itemSpecs·onShopClick·celebrate. |
| `album.gd` (`ScrAlbum`) | ui.js showAlbum·albumCardHTML·dashArt. |
| `reward_timeline.gd` (`ScrReward`) | ui.js showRewardResult. TL은 280/700+380i/1750/2150/2250/2450+150k/2600ms다. `advance(dt)`로 결정적으로 돌린다. |
| `pause_menu.gd`, `settings.gd` | 계속/다시/설정/메뉴로. 설정은 음악·효과음·진동·60fps·왼손 + OFL 크레딧. |
| `dev_fake_game.tscn/.gd` (`ScrFakeGame`) | 가짜 game.tscn. `stage_id`, `loadout`, `stage_finished(result)`, `pause_requested`를 가진다. |
| `meta.gd` (`ScrMeta`) | Progress 어댑터. `resolve()`는 autoload를, `private(host, path, seed, wipe)`는 테스트·샷용 별도 세이브를 쓴다. |
| `dev_progress_stub.gd` | meta/가 없는 빌드에서 쓰는 대체 구현. 반환 키를 Progress와 같게 맞췄다. |
| `kit.gd` (`ScrKit`), `screen.gd`, `chapter_tabs.gd`, `backdrop.gd` | 공용 부품: 잉크 외곽선, 광택 알약, SVG 아이콘, safe area, 탭과 햅틱(`uiLight`)·`ui`음. |
| `svg_art.gd` | **생성물.** `node native/screens/dev/extract_svg.mjs`가 웹 ui.js의 SVG·아이템 그림·도로 상황 타일을 그대로 뽑는다. |
| `../ui/theme/` | `palette.gd`(`Lane1Pal`, style.css 색), `lane1_theme.tres`(`build_theme.gd`로 생성한다). |

## 실행 · 테스트
```bash
godot47 --headless --path native -s res://tests/run_tests.gd -- --filter=screens          # 루프·차고·설정·카드 타이머·stub 대조
godot47 --headless --path native -s res://tests/run_tests.gd -- --suite=integration --filter=screens_host   # 진짜 game.tscn 호스팅 스모크
xvfb-run -a -s "-screen 0 1280x1024x24" godot47 --path native --rendering-method mobile --audio-driver Dummy \
  -s res://tests/shot_screens.gd -- --out=/abs/dir [--web=/abs/web_shots] [--screens=title,card_36,reward_18,flow,...]
godot47 --path native res://screens/app.tscn -- --game=fake|real --stage=N --safe-pt=59,34   # 데스크톱에서 직접
```

## 최종 통합(FI)에 넘기는 것
1. `project.godot`의 `run/main_scene`을 `res://screens/app.tscn`으로 바꾼다. `Progress` autoload는 이미 등록돼 있다.
2. `app.gd`의 `GAME_SCENE`을 `REAL_GAME`(`res://view/game.tscn`)으로 바꾼다(한 줄). `dev_fake_game.*`는 export에서 뺀다.
3. game.tscn에는 다음이 필요하다(`test_screens_host`가 현재 없음을 보고한다).
   - `var loadout: Dictionary`: `Progress.loadout()`에 `left_hand`를 더한 값이다.
   - `signal stage_finished(result)`: 클리어·포기 때 한 번만 낸다. 키는 meta/README.md의 `record_result` 사실 키다.
   - `signal pause_requested` 또는 `paused_changed(on)`: 일시정지 메뉴를 띄운다.
   - `set_paused(on)`: 메뉴에서 계속하기를 누르면 app이 부른다.
