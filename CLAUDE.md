# CLAUDE.md — 작업 원칙 (모든 에이전트/세션 필수)

## 0. 가설 우선 (Hypothesis-first) — 절대 규칙
문제 해결·설계·디버깅·기능 추가 등 **모든 접근의 맨 앞에 아주 간략한 핵심 가설**을 먼저 달고 진행한다.

- **형식**: 응답 / 문서 / PR 설명 / 커밋 본문의 **최상단**에 `가설:` 블록, 1~3줄, 한 줄당 핵심만.
  - 예) `가설: 막힘 해소 쾌감 = "정체 길이 × 해소 속도". 해소 연출(파도처럼 뒤로 풀림)이 핵심.`
- **목적**: 사용자가 최전방 가설을 한눈에 먼저 보고, 가설이 틀렸으면 상세를 읽기 전에 즉시 교정하기 위함.
  가설 없이 본문만 따라가다 산으로 가거나, 틀린 가설 위에 시간을 쓰는 것을 막는다.
- **갱신**: 가설이 바뀌면 최상단을 갱신한다. `~~이전 가설~~ → 기각 이유 한 줄` 형태로 흔적을 남긴다.
- **검증 표시**: 확인된 가설은 ✅, 기각은 ❌, 미확인은 ❓.
- 서브에이전트에게 일을 맡길 때도 프롬프트 맨 앞에 가설을 적고, 결과도 가설 대비로 보고하게 한다.

## 1. 프로젝트 개요
- `game/` — "1차선 참교육" 웹 3D 목업 (Three.js, 빌드 없음, ES modules)
- 실행: `npx http-server game -p 8080` 후 http://localhost:8080
- 설계/구조 문서: `docs/GAME_DESIGN.md`, `docs/ARCHITECTURE.md`
- 피드백 루프: 사용자가 목업을 플레이 → 피드백 → `docs/FEEDBACK_LOG.md`에 가설/결정 기록 → 반영

## 2. iPhone 배포
- 절차: `docs/IPHONE_DEPLOY.md`(사용자 검증 가이드의 이 프로젝트 적용본), 1회 서명 준비: `tools/mac/SIGNING.md`, 빌드 상세: `docs/MOBILE_BUILD.md`.
- 먼저 환경을 판별한다(§0). Mac 로컬이면 `tools/mac/ios_run.sh`를 **로그인된 Terminal**에서 실행. 이 클라우드 컨테이너는 Mac에 닿지 않으므로 설치를 끝냈다고 보고하지 않는다. runner 경로(`tools/mac/iphone-install.yml.template`)는 **공개 저장소에서 활성화 금지** — private 저장소/별도 private 배포 저장소에서만.
- **이 저장소는 공개다.** Team ID·iPhone ID·Mac 주소·사용자·SSH 키 경로를 어떤 파일·커밋·로그에도 쓰지 않는다. 자동 감지 또는 `~/.lane1/deploy.env`(저장소 밖, chmod 600)·환경변수(`LANE1_TEAM_ID`, `LANE1_DEVICE_ID`)만 쓴다.
- 순서: 범위에 맞는 테스트 → 실기기용 서명 빌드(Debug, `generic/platform=iOS`, 자동 서명) → codesign·Bundle ID(`com.ffogtive.lane1Chamgyoyuk`) 확인 → devicectl 설치 → 실행 → 기능 확인. 실행별 로그 `.local/deploy-runs/`, 동시 배포는 잠금으로 막고 남은 잠금을 자동 삭제하지 않는다.
- 기존 앱 삭제·데이터 초기화 금지, 일반 설치에 검증용 launch argument 금지. 비밀번호·Apple 2FA·키체인 승인·기기 신뢰는 사용자가 직접 — 대신 입력하거나 우회하지 않는다.
- 빌드·설치·실행·기능 확인의 성공 여부를 **각각** 보고한다. 설치 명령 성공만으로 기능 검증 완료라고 하지 않는다.
