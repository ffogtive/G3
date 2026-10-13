# 1차선 참교육 🚗💥

> 가설: 고속도로 정체의 원흉(1차선 정속주행러 등)을 참교육하고 도로가 홍수처럼 뻥 뚫리는 순간의 **쾌감**이 이 게임의 전부다.

한국 고속도로가 꽉 막혔다. 맨 앞에 가보니 1차선에서 혼자 정속주행 중인 한 놈 때문이었다.
타이어를 펑크 내 하늘로 날려 보내면, 뒤로 수 km 막혔던 도로가 한 번에 뚫린다.

## 바로 플레이
- Artifact(비공개, 소유자 전용): https://claude.ai/artifact/XMH9x12fPh1n4fmjrJtKxk

## 실행
```bash
npm install
npm run dev          # http://localhost:8080/game/
npm run build        # dist/index.html (단일 파일, 더블클릭 실행)
```
- 디버그 URL 파라미터: `?stage=1..5` · `&skip=boss|kill` · `&auto=1` (오토파일럿) · `&mute=1` · `&ff=4` (빨리감기)

## 조작
| | PC | 모바일 |
|---|---|---|
| 차선 변경 | ← → / A D | ◀ ▶ 버튼, 좌우 스와이프 |
| 경적(정체 중) / 압정 발사(보스전) | Space / J | 발사 버튼 |
| 분노 미사일 | R / Shift | 분노 버튼, 위로 스와이프 |
| 브레이크 | ↓ / S | — |
| 일시정지 / 음소거 | P / M | 우상단 버튼 |

## 구조
- `game/js/` — Three.js r170 ES 모듈 (빌드 없이 실행)
  - core: `main.js`(상태머신·카메라·연출), `traffic.js`(IDM 교통), `player.js`, `boss.js`, `weapons.js`, `world.js`, `input.js`, `config.js`(스테이지·튜닝)
  - content: `vehicles.js`(복셀 차량), `scenery.js`(한국 고속도로), `fx.js`(큐브 파티클), `audio.js`(WebAudio 합성), `ui.js` + `css/style.css`
- `docs/` — `GAME_DESIGN.md`, `ARCHITECTURE.md`(모듈 계약), `FEEDBACK_LOG.md`(가설·결정 기록)
- `tools/` — `build.mjs`(단일 파일 번들), `shot.mjs`(헤드리스 스크린샷), `sim/jam.mjs`(정체 난이도 시뮬)
