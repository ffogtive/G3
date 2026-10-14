# native/meta — Progress (meta state + web economy)

가설:
- ✅ rewards.js + main.js:showResult 549-571 + config SHOP 효과 + loadProgress 마이그레이션을 `Progress` 하나로 옮기면 별·지갑·해금·차고 효과·도감이 재실행 뒤에도 남고 웹과 같은 숫자가 나온다. 웹 오라클 7건(`tools/rewards_golden.json`)과 비트 단위로 같다(`tests/test_rewards_golden.gd`).
- ✅ 별과 포상금은 Progress가 결과의 **사실**(hp, 견인, 잔챙이, freed, cath …)로 정한다(NATIVE_PARITY 7 G4). 게임이 보낸 `missions`/`pay_mul`은 사실이 없을 때만 쓴다.
- ❓ P0 #6(견인 시 ★2 실패)·P0 #9(재플레이 25%)는 `shop.json economy` 스위치다. 기본값은 웹(꺼짐). GameSim은 이미 ★2에 "견인 0회"를 쓰므로 FI가 `star2NoTow`를 켤지 정해야 카드 문구와 맞는다.

| 파일 | 내용 |
|---|---|
| `progress.gd` | autoload `Progress` (project.godot, SaveGame 다음) |
| `rewards.gd` | `class_name Rewards`: rewards.js 순수 함수 (computeReward·applyReward·villainNames·pick·won·shortNum + 속시원함·점수·재도전 배율·통계 줄) |
| `tools/gen_rewards_golden.mjs` | 동결 웹 rewards.js로 골든 생성 (`--check`) |
| `../core/save_game.gd` | `user://progress.json` 원자 저장(tmp→rename, .bak, .corrupt), schema 1, 마이그레이션(웹 v3/v0.2), 미래 schema는 읽기 전용 |

## API (Progress)
- 상태: `wallet`, `subs`(읽기 전용 속성), `state()`, `reload()`, `reset()`, 신호 `changed(what)`, `setting_changed(key, value)`.
- 판: `stages()`, `stage(id)`, `stage_index(id)`, `chapters()` → `{no, name, setting, theme, stage_ids, total, cleared, stars, stars_max, locked, complete}`, `is_unlocked(id)`, `unlocked_count()`, `next_stage_id()`(START), `stars_of(id)`, `total_stars()`, `best(id)` → `{stars, score, cleared, count, photo, fine, at}`, `missions_for(id, minis_total=-1)` → `[{id: clear|hp|minis, label}]`, `case_of(stage)` → `fine|crime|rescue|warn`.
- 도감: `album_entry(id)`, `album_has(id)`, `album_count()`, `album_fine_total()`.
- 결과: `record_result(id, result)` → 보상 타임라인에 필요한 값 전부(아래).
- 차고: `shop_items()`(+`owned, equipped, can_buy`), `item(id)`, `owns(id)`, `equipped(cat)`, `can_buy(id)`, `buy(id)` → `{ok, reason: unknown|owned|funds, short, wallet, equipped}`, `equip(id)`(차·무기·피니시만), `owned_count()`, `affordable_count()`(차고 배지).
- `loadout()` → `{car, car_kind, speed, armor, hp_max, tow, siren, weapon_id, weapon{id, proj, dmg, rate, spread, slow}, finish_id, finish, pay_mul, airbag, trot, coffee, rage_start_segs, jump, jump_cool, drone, drone_every}`. 게임은 이 dict만 읽는다.
- `daily_villain()` → `{id, date}`: Mulberry32(yyyymmdd)로 열린 판 중 하나. 그날 처음 고른 판을 저장해서 해금이 늘어도 하루 동안 같다.
- 설정: `settings()`, `get_setting(key)`, `set_setting(key, value)` — `{music, sfx, haptics, battery60, left_hand}`(bool). 적용(버스·Haptics·max_fps·HUD 반전)은 FI.
- 회차(r3 S1, 피드백 3 '매번 똑같다'): `plays(id)` = 시작한 판 수 = 다음 회차 n(저장 키 `plays{"<id>": n}`, 없으면 0 → 업데이트 뒤 첫 판은 n = 0 = 예전 고정 시드). `next_play(id)` = `plays(id)`에서 `SEED_SKIP[id]`(측정한 나쁜 시드, 지금 `{5: [11]}`)를 건너뛴 값, n = 0은 건너뛰지 않는다. `begin_play(id)` = 판 시작마다 1회(카드 START·일시정지 다시하기) 증가 전 n을 돌려주고 저장한다. 판 안의 견인 재도전은 부르지 않는다(같은 시드). 시드는 `Mulberry32.run_seed(id, n)`. `screens/meta.gd`(ScrMeta)가 세 함수를 전달하고, meta 없는 빌드의 `ScrProgressStub`도 회차를 센다(건너뛰기 목록 없음). traffic·neck·판 데이터를 바꾸면 `--suite=e2e --filter=test_seed_variety --full`로 `SEED_SKIP`을 다시 잰다.

## `record_result(id, result)`
읽는 키(괄호 = 별칭): `cleared`, `aborted`, `hp_end`(`hp`), `hp_max`, `min_hp`, `tows`(`fails`, `retries`), `minis_done`, `minis_total`, `missions_done`(`missions[{done}]`, hp/minis가 없을 때만), `cath`(없으면 bumps·boss_time_s·supers·max_combo로 계산), `freed`, `cheaters`, `mini_fines`, `score`(최종 점수), `seed`(없으면 `floor(time_s·1000) % 997 + 1`), `time_s`, `photo`(Image 또는 user:// 경로), `stats`(보스 통계 줄), `retry_mul`(`pay_mul`, 견인 수가 없을 때만).
돌려주는 키: `stage_id, cleared, stars, prev_stars, new_stars, missions[{id,label,done}], score, best_score, new_best, fine, base, bonus, star_mult, item_pay_mul, retry_mul, replay_mul, pay_mul, payout, views, subs_gained, comments[3], milestone, wallet_before, wallet, subs_before, subs, violation, villain_name, card, case, cause, stage_name, photo, album_count, unlocks[ids], next_id, is_last, stats[{label,value}], seed, tows`.
클리어가 아니거나 `aborted`면 아무것도 바꾸지 않고 `payout 0`을 돌려준다. `cleared`가 없는 결과(GameSim `state().result`는 phase result에서만 생긴다)는 `missions`나 `stars`가 있으면 클리어로 본다.

## 테스트
`godot47 --headless --path native -s res://tests/run_tests.gd -- --filter=rewards` (웹 골든), `--filter=save` (원자 저장·.bak·마이그레이션·미래 schema), `--filter=meta` (해금 1→2→3, 구매·장착, loadout, 재로드, 설정, 오늘의 빌런, P0 스위치, GameSim 별칭, 사진).
