// ui.js — DOM HUD · 타이틀 · 스테이지 카드 · 결과 · 일시정지 · 터치 컨트롤
//
// 가설: 클래시/길건너친구들 풍 통통한 DOM UI + 한국 도로표지 모티프(녹색 표지판, 고속도로 방패 번호)가
//      목업의 첫인상과 "쾌감 연출"(뻥 뚫렸다!!, 해방 카운터, 참교육 완료 도장)을 책임진다.
// 가설(v0.2): 결과 = 블박 제보 카드(과태료 도장) → ★ → 포상금 → 참교육 채널, 타이틀 = 챕터 탭 + 지갑/구독자 + 제보 앨범
//      → '퇴치 → 보상 → 수집' 루프가 한눈에 보인다. (docs/REWARDS.md)
//
// v0.2 API (하위 호환 — 기존 호출 그대로 동작)
//  showResult(r)  r.reward?: { photo, villainName, violation, fine, payout, bonus, stars, wallet, views, subsGain, subs,
//                             comments[3], milestone, stageId, cause, speedKmh? } → 보상 레이아웃. 없으면 기존 결과 화면.
//  showTitle(stages, progress, chapters?)  progress += { wallet, subs, album: {[id]: {stars, fine, photo, count}} }
//                 stages[].chapter(1..) 로 챕터 묶음 (없으면 한 챕터). chapters = [{ no, name, setting, theme }]
//                 → 챕터 탭(현재 챕터 타일만 렌더) · 지갑/구독자 칩 · '제보 앨범' 버튼
//  showAlbum(stages?, progress?, chapters?) / hideAlbum()  인자 없으면 마지막 showTitle 데이터 사용
//  handlers.onAlbum?(open: boolean)  앨범 열림/닫힘 알림 (선택)
//
// v0.3 API (하위 호환) — 가설: 별 기준(미션 3개)이 미리 보이고, 포상금으로 사는 '차고'가 생기면 "퇴치 → 보상 → 성장" 루프가 닫힌다.
//  showStageCard(stage, missions?)   missions = [{ label }] ×3 → 카드에 '★ 별 미션' 3칸 (별 i = 미션 i)
//  showResult(r)  r.missions?: [{ label, done, value? }] ×3 → 별 3개가 각 미션 카드 머리에 붙어서 done 인 칸만 켜짐
//  setHUD(s)      s.minis?: { done, total } → '잔챙이 1/3' 칩 (total 0/없음 = 숨김) · s.boostT?: 0..1 → 속도계 부스트 링
//                 s.rageMode?: 'horn'|'bomb'|'siren' → 분노 키 안내 ('R 분노의 경적!' / 'R 분노 폭탄!' / 'R 사이렌 대경적!'), 없으면 phase 로 추정
//  카탈로그 필드: stage.title 접두사 [최종보스]/[보스]/[엘리트]/[보너스] → 배지 (제목에서 뗌) · stage.boss/elite 플래그
//                 stage.card | reward.card: '고지서'|'형사'|'표창'|'계도' → 카드 디자인 · fine(실제 금액) ≠ payout(받는 포상금)
//                 stage.honkOnly → 스테이지 카드 '구조 상황 · 압정 금지 · 경적으로 깨우기' 태그
//  setControls({ jump?: boolean, jumpCd?: 0..1 })  터치 '점프' 버튼 (onControl('jump', pressed)) · 쿨다운 부채꼴
//  showTitle(stages, progress, chapters?, shop?)   shop = config SHOP → '차고' 버튼(살 수 있는 개수 배지) · ↑ 점프 키 힌트
//  showShop(shop?, progress?, tab?) / hideShop() / refreshShop(progress?)   참교육 차고(휴게소 정비소) 오버레이
//                 progress: { wallet, owned: [id], equip: { car, weapon, finish } }. 인자 없으면 마지막 showTitle 데이터
//                 refreshShop: owned 에 새로 생긴 id → 구매 연출(코인 버스트 + '구매 완료!'), equip 변경 → '장착!' 범프
//  handlers.onBuy?(id) · onEquip?(id) · onShop?(open: boolean)
//
// v0.4 API (하위 호환 · 전부 guard — 인자가 없거나 이상해도 throw 하지 않음) — docs/V04_SPEC.md 'HP' · R7
//  가설: 내 내구도(범퍼 5칸)가 깎이는 게 보이고, 견인 실패 카드가 있고, 판마다 다른 '도로 상황'이 시작 카드에 보이면
//       긴장감과 판 차별화가 체감된다 ❓
//  setHP({ hp, max, invuln?, lowFx? }) | setHP(null)
//                 분노 게이지 위(가로 폰 = 왼쪽) '범퍼 5칸'. 칸 = max/5, 반 칸 단위(올림 → 살아 있으면 최소 반 칸).
//                 hp 가 줄 때만 깎인 칸이 흔들리며 빨갛게 터짐(+ −N 숫자). 비율 ≤ 0.4 = 주의(노랑 점멸), ≤ 0.2 = 위험(빨강).
//                 invuln: true → 1초 깜빡임(무적, 계속 true 면 연장) · 숫자 = 그 초 · false = 끔. lowFx: 'auto'(기본, 위험일 때만) | true(강제) | false → 화면 가장자리 빨간 맥동.
//                 첫 호출 전·null·max ≤ 0 이면 숨김(honkOnly 판 등). 매 프레임 호출 OK (값이 바뀔 때만 DOM 갱신).
//  showFail({ title?, reason, villainName?, hpLost?, retryLabel? }) : Promise<'retry' | 'menu'>
//                 견인 실패 카드 ('견인!' 도장 + 레커차 + 사유 + [발견 지점부터 다시] / [메뉴]). 자동 진행 없음.
//                 Enter = 재도전, Esc = 메뉴 (0.45초 뒤부터, 코어 keydown 으로 새지 않게 막음). hpLost = 마지막 한 방 피해.
//                 열려 있는 동안 다시 부르면 내용만 바꾸고 같은 Promise 반환. showTitle/showStageCard/showResult 가 뜨면
//                 조용히 닫히고 Promise 는 settle 되지 않는다(코어가 이미 다른 흐름으로 갔다는 뜻). hideFail() 도 동일.
//  showStageCard(stage, missions?, road?)
//                 road = { shoulder: 'open'|'crowded'|'blocked'|'closed'|'dark'|'debris'|'watched'|'merge'|'occupied'|'none',
//                          honk: 'yield'|'gapRace'|'backfire'|'push'|'ignoredWhileYielding'|'rescue'|'normal'|'bait'|'notify'|'evict'|'echo',
//                          special?: string, hint?: string }
//                 → '도로 상황' 아이콘 3개(갓길 / 경적 / 특수) + 전광판 한 줄 힌트(없으면 '이번 판 경적 = ○○').
//                 모르는 값은 그 칸만 생략. road 가 없으면 기존 카드 그대로. 카드 시간 +1초.
//  toast(text, kind = 'info', ms?)   kind: 'warn' | 'info' | 'good'. 상단 짧은 알림 (최대 3개, 같은 문구는 ×2 로 합침)
//
// 규칙
//  - #ui 루트 안에 전부 동적으로 생성. 클래스 접두사 'ui-'.
//  - 매 프레임 호출(setHUD/setNav/showBoss/bubble/vignette)은 값이 바뀔 때만 DOM 을 건드린다.
//  - 어떤 순서로 호출해도 throw 하지 않는다 (모든 메서드 guard + 지연 빌드).
//  - 게임플레이 키는 바인딩하지 않는다 (core 담당). 스테이지 카드 스킵용 keydown 만 잠깐 듣는다.

// ───────────────────────────── 유틸
// 분노 게이지 칸 수 (config TUNE.rageSegs 와 맞출 것)
const RAGE_SEGS = 5;

let H = {};
let R = null;
let built = false;
const E = {};
const C = {};
const now = () => (typeof performance !== 'undefined' ? performance.now() : Date.now());
const clamp = (v, a, b) => (v < a ? a : v > b ? b : v);
const num = (v, d = 0) => { const n = +v; return Number.isFinite(n) ? n : d; };
const q = (v, steps) => Math.round(v * steps) / steps;
const fmt = (n) => { n = Math.round(num(n)); try { return n.toLocaleString('ko-KR'); } catch { return String(n); } };
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
let reduceMotion = false;
let VW = 1280, VH = 720;

function el(tag, cls, html) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (html != null) e.innerHTML = html;
  return e;
}
function call(name, ...a) {
  try { const f = H && H[name]; if (typeof f === 'function') f(...a); } catch (e) { console.error('[ui] handler', name, e); }
}
function anim(node, kf, opt) {
  if (!node || !node.animate || reduceMotion) return null;
  try { return node.animate(kf, opt); } catch { return null; }
}
const lastBump = Object.create(null);
function bump(node, key, gap = 90, kf = KF.bump, dur = 220) {
  const t = now();
  if (t - (lastBump[key] || 0) < gap) return;
  lastBump[key] = t;
  anim(node, kf, { duration: dur, easing: 'cubic-bezier(.3,1.7,.5,1)' });
}
// 보이기/숨기기 (진입·퇴장 키프레임은 CSS .is-in / .is-out)
function setShown(node, on, outMs = 260) {
  if (!node) return;
  const st = node._uiv || (node._uiv = { on: !node.hidden, t: 0 });
  if (st.on === on) return;
  st.on = on;
  clearTimeout(st.t);
  if (on) {
    node.hidden = false;
    node.classList.remove('is-out');
    node.classList.add('is-in');
  } else {
    node.classList.remove('is-in');
    node.classList.add('is-out');
    st.t = setTimeout(() => { if (!st.on) node.hidden = true; }, reduceMotion ? 0 : outMs);
  }
}
const isShown = (node) => !!(node && node._uiv && node._uiv.on);
// 클릭 버튼 (포커스를 가져가지 않음 → Space 발사가 버튼을 누르는 사고 방지)
function btn(cls, html, onClick, label) {
  const b = el('button', 'ui-btn ' + cls, html);
  b.type = 'button';
  if (label) b.setAttribute('aria-label', label);
  b.addEventListener('mousedown', (e) => e.preventDefault());
  b.addEventListener('click', (e) => { e.stopPropagation(); try { b.blur(); } catch { /* */ } onClick && onClick(e); });
  return b;
}

const KF = {
  bump: [{ transform: 'scale(1)' }, { transform: 'scale(1.18)' }, { transform: 'scale(1)' }],
  bigBump: [{ transform: 'scale(1)' }, { transform: 'scale(1.12) rotate(-1.5deg)' }, { transform: 'scale(1)' }],
  shake: [{ transform: 'translateX(0)' }, { transform: 'translateX(-5px) rotate(-1deg)' }, { transform: 'translateX(5px) rotate(1deg)' }, { transform: 'translateX(-3px)' }, { transform: 'translateX(0)' }],
  segPulse: [{ transform: 'scale(1)', filter: 'brightness(1)' }, { transform: 'scale(1.35)', filter: 'brightness(1.8)' }, { transform: 'scale(1)', filter: 'brightness(1)' }],
  tirePop: [{ transform: 'scale(1.6) rotate(0deg)', filter: 'brightness(2.5)' }, { transform: 'scale(.7) rotate(-25deg)' }, { transform: 'scale(1) rotate(-12deg)' }],
};

// ───────────────────────────── 아이콘 (인라인 SVG — 폰트/이모지 의존 없음)
const SVG = {
  shield: '<svg class="ui-shield__svg" viewBox="0 0 40 46" aria-hidden="true">'
    + '<path d="M3 8 Q11 2.5 20 6.5 Q29 2.5 37 8 L37 26 Q37 37.5 20 44 Q3 37.5 3 26 Z" fill="#1f4fa3" stroke="#17202b" stroke-width="3.2" stroke-linejoin="round"/>'
    + '<path d="M3 8 Q11 2.5 20 6.5 Q29 2.5 37 8 L37 15.5 L3 15.5 Z" fill="#e2231a"/>'
    + '<path d="M3 8 Q11 2.5 20 6.5 Q29 2.5 37 8 L37 26 Q37 37.5 20 44 Q3 37.5 3 26 Z" fill="none" stroke="#fff" stroke-width="2.4" transform="translate(20 24) scale(.82) translate(-20 -24)" stroke-linejoin="round"/>'
    + '<path d="M3 8 Q11 2.5 20 6.5 Q29 2.5 37 8 L37 26 Q37 37.5 20 44 Q3 37.5 3 26 Z" fill="none" stroke="#17202b" stroke-width="3.2" stroke-linejoin="round"/>'
    + '</svg>',
  flame: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 1.8c1.2 3.6-1.9 5.2-1.9 8 0 1.5 1 2.4 2.2 2.4 1.8 0 2.5-1.8 1.7-4.1 3.2 2.1 4.9 5.2 4.9 8A6.9 6.9 0 0 1 12 22.6 6.9 6.9 0 0 1 5.1 15.5c0-5 4.3-8.2 6.9-13.7z" fill="#ff5a1f" stroke="#17202b" stroke-width="1.8" stroke-linejoin="round"/><path d="M12 12.6c.6 1.8 2.9 2.5 2.9 5a2.9 2.9 0 0 1-5.8 0c0-1.9 1.9-2.8 2.9-5z" fill="#ffd23f"/></svg>',
  speaker: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3.5 9.2h4l5.2-4.4v14.4l-5.2-4.4h-4z" fill="#fff" stroke="#17202b" stroke-width="1.6" stroke-linejoin="round"/><path d="M15.6 8.6a4.6 4.6 0 0 1 0 6.8M18 6.2a8 8 0 0 1 0 11.6" fill="none" stroke="#fff" stroke-width="2.2" stroke-linecap="round"/></svg>',
  speakerOff: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3.5 9.2h4l5.2-4.4v14.4l-5.2-4.4h-4z" fill="#fff" stroke="#17202b" stroke-width="1.6" stroke-linejoin="round"/><path d="M15.5 9l5.5 6M21 9l-5.5 6" fill="none" stroke="#ff3b30" stroke-width="2.6" stroke-linecap="round"/></svg>',
  pause: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="5.5" y="4.5" width="4.6" height="15" rx="1.4" fill="#fff" stroke="#17202b" stroke-width="1.4"/><rect x="13.9" y="4.5" width="4.6" height="15" rx="1.4" fill="#fff" stroke="#17202b" stroke-width="1.4"/></svg>',
  play: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M7 4.5l12 7.5-12 7.5z" fill="#fff" stroke="#17202b" stroke-width="1.6" stroke-linejoin="round"/></svg>',
  tire: '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="10" fill="#2a2f38" stroke="#17202b" stroke-width="2"/><circle cx="12" cy="12" r="8.2" fill="none" stroke="#4a515c" stroke-width="2.4" stroke-dasharray="2.2 2"/><circle cx="12" cy="12" r="4.4" fill="#c9d0d8" stroke="#17202b" stroke-width="1.4"/><circle cx="12" cy="12" r="1.4" fill="#6b7179"/></svg>',
  tireFlat: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M2.5 14.5C2.5 8 7 3 12 3s9.5 5 9.5 11.5c0 3.2-1.2 5.2-3 6.2H5.5c-1.8-1-3-3-3-6.2z" fill="#7a808a" stroke="#17202b" stroke-width="2"/><circle cx="12" cy="13" r="4" fill="#a8aeb6" stroke="#17202b" stroke-width="1.4"/><path d="M7 5.5l2.2 3-1.6 1.4 2 2.6M17.5 6l-1.8 2.6 1.6 1.2" fill="none" stroke="#17202b" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  car: '<svg viewBox="0 0 34 20" aria-hidden="true"><rect x="1.5" y="2" width="31" height="16" rx="5.5" fill="#ffd23f" stroke="#17202b" stroke-width="2.4"/><rect x="18.5" y="4.6" width="6.4" height="10.8" rx="1.8" fill="#24366b"/><rect x="7.4" y="5.2" width="5" height="9.6" rx="1.6" fill="#24366b"/><rect x="29" y="4" width="2.4" height="3.4" rx="1" fill="#fff6c8"/><rect x="29" y="12.6" width="2.4" height="3.4" rx="1" fill="#fff6c8"/></svg>',
  angry: '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="10" fill="#ff3b30" stroke="#17202b" stroke-width="2.2"/><path d="M6.3 8.2l4.2 2.2M17.7 8.2l-4.2 2.2" stroke="#17202b" stroke-width="2.2" stroke-linecap="round"/><circle cx="9" cy="12.2" r="1.4" fill="#17202b"/><circle cx="15" cy="12.2" r="1.4" fill="#17202b"/><path d="M8.2 17.4q3.8-3 7.6 0" fill="none" stroke="#17202b" stroke-width="2.2" stroke-linecap="round"/></svg>',
  check: '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="10" fill="#22c55e" stroke="#17202b" stroke-width="2.2"/><path d="M7 12.4l3.4 3.4L17.2 9" fill="none" stroke="#fff" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  left: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M15.5 4.5L7 12l8.5 7.5z" fill="#fff" stroke="#17202b" stroke-width="2.2" stroke-linejoin="round"/></svg>',
  right: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M8.5 4.5L17 12l-8.5 7.5z" fill="#fff" stroke="#17202b" stroke-width="2.2" stroke-linejoin="round"/></svg>',
  star: '<svg viewBox="0 0 24 24" aria-hidden="true"><path class="ui-star__p" d="M12 1.9l3.05 6.2 6.85.95-4.97 4.8 1.2 6.8L12 17.4l-6.13 3.25 1.2-6.8L2.1 9.05l6.85-.95z" stroke="#17202b" stroke-width="1.9" stroke-linejoin="round"/><path d="M8 8.6l2.6-.4" stroke="#fff" stroke-opacity=".7" stroke-width="1.6" stroke-linecap="round"/></svg>',
  horn: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 9.5h3.5L15 4.8v14.4l-8.5-4.7H3z" fill="#fff" stroke="#17202b" stroke-width="1.6" stroke-linejoin="round"/><path d="M18 8.5l2.6-1.6M18.6 12h3M18 15.5l2.6 1.6" stroke="#fff" stroke-width="2" stroke-linecap="round"/></svg>',
  tack: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M7 4h10l-2 5 3 3H6l3-3z" fill="#fff" stroke="#17202b" stroke-width="1.6" stroke-linejoin="round"/><path d="M12 12v9" stroke="#fff" stroke-width="2.4" stroke-linecap="round"/></svg>',
  arrowUp: '<svg viewBox="0 0 40 52" aria-hidden="true"><path d="M20 2L37 20H27V50H13V20H3z" fill="#fff"/></svg>',
  // ── 보상 · 수집
  coin: '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="13" r="9.6" fill="#c98a00" stroke="#17202b" stroke-width="1.9"/><circle cx="12" cy="11.4" r="9.6" fill="#ffd23f" stroke="#17202b" stroke-width="1.9"/><circle cx="12" cy="11.4" r="6.6" fill="none" stroke="#e8a400" stroke-width="1.4"/><path d="M7.6 7.4l1.9 7.6 2.5-6 2.5 6 1.9-7.6M6.8 10.4h10.4M7.3 12.6h9.4" fill="none" stroke="#17202b" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  chan: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M8 2.6l4 3.4 4-3.4" fill="none" stroke="#17202b" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/><rect x="2" y="6" width="20" height="15" rx="4.4" fill="#ff3b30" stroke="#17202b" stroke-width="1.9"/><circle cx="10.6" cy="13.5" r="4.1" fill="#17202b"/><circle cx="10.6" cy="13.5" r="2.2" fill="#6aa6ff"/><circle cx="9.9" cy="12.7" r=".8" fill="#fff"/><circle cx="18" cy="9.6" r="1.3" fill="#fff"/></svg>',
  album: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 3.5h13.5a2.5 2.5 0 0 1 2.5 2.5v14.5H6.5A2.5 2.5 0 0 1 4 18z" fill="#2f6fd6" stroke="#17202b" stroke-width="1.9" stroke-linejoin="round"/><path d="M4 18a2.5 2.5 0 0 1 2.5-2.5H20" fill="none" stroke="#17202b" stroke-width="1.9"/><rect x="8" y="5.8" width="9" height="7.4" rx="1" fill="#fff" stroke="#17202b" stroke-width="1.4"/><path d="M8.6 12.5l2.6-3 1.8 2 1.2-1.2 2.2 2.2" fill="none" stroke="#17a466" stroke-width="1.4" stroke-linejoin="round"/><circle cx="14.6" cy="7.9" r=".9" fill="#ffb400"/></svg>',
  cam: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="2.5" y="6" width="19" height="12" rx="3" fill="#2a2f38" stroke="#fff" stroke-width="1.6"/><circle cx="14" cy="12" r="3.6" fill="#11161e" stroke="#fff" stroke-width="1.4"/><circle cx="14" cy="12" r="1.5" fill="#6aa6ff"/><circle cx="6.4" cy="9.4" r="1.3" fill="#ff3b30"/></svg>',
  lock: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M7.6 10.5V7.8a4.4 4.4 0 0 1 8.8 0v2.7" fill="none" stroke="#17202b" stroke-width="4.2" stroke-linecap="round"/><path d="M7.6 10.5V7.8a4.4 4.4 0 0 1 8.8 0v2.7" fill="none" stroke="#c9d0d8" stroke-width="1.8" stroke-linecap="round"/><rect x="4.6" y="10" width="14.8" height="11" rx="2.6" fill="#ffb400" stroke="#17202b" stroke-width="1.9"/><path d="M12 13.6v3.4" stroke="#17202b" stroke-width="2.2" stroke-linecap="round"/></svg>',
  close: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6.5 6.5l11 11M17.5 6.5l-11 11" stroke="#17202b" stroke-width="6" stroke-linecap="round"/><path d="M6.5 6.5l11 11M17.5 6.5l-11 11" stroke="#fff" stroke-width="2.8" stroke-linecap="round"/></svg>',
  thumb: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 10.5h3.6v9.8H3zM8.4 10.3l3.4-7c1.6 0 2.7 1.1 2.7 2.6v3h4.6c1.4 0 2.4 1.3 2.1 2.6l-1.8 7.4c-.3 1.1-1.2 1.8-2.3 1.8H8.4z" fill="currentColor"/></svg>',
  heart: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 20.6S3 15 3 8.9A4.6 4.6 0 0 1 12 6.8a4.6 4.6 0 0 1 9 2.1c0 6.1-9 11.7-9 11.7z" fill="#ff3b30" stroke="#17202b" stroke-width="1.6" stroke-linejoin="round"/></svg>',
  hazard: '<svg viewBox="0 0 48 48" aria-hidden="true"><rect x="3" y="4" width="42" height="42" rx="11" fill="#9e1209"/><rect x="3" y="2" width="42" height="40" rx="11" fill="#ff3b30" stroke="#17202b" stroke-width="3"/><path d="M24 9.5L38 33.5H10z" fill="none" stroke="#fff" stroke-width="3.6" stroke-linejoin="round"/><path d="M24 18.5L31 30.5H17z" fill="none" stroke="#fff" stroke-width="2.6" stroke-linejoin="round"/><path d="M9 8.5q6-4 13-4" fill="none" stroke="#fff" stroke-opacity=".55" stroke-width="2.4" stroke-linecap="round"/></svg>',
  medal: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6.5 2h4.2l2.6 6.5-3.6 2.4zM17.5 2h-4.2l-1.8 4.6 2.6 4.3z" fill="#2f6fd6" stroke="#17202b" stroke-width="1.6" stroke-linejoin="round"/><circle cx="12" cy="15.4" r="6.6" fill="#ffc61a" stroke="#17202b" stroke-width="1.9"/><path d="M12 11.6l1.2 2.4 2.6.4-1.9 1.8.5 2.6-2.4-1.3-2.4 1.3.5-2.6-1.9-1.8 2.6-.4z" fill="#fff" stroke="#c98a00" stroke-width=".8" stroke-linejoin="round"/></svg>',
  // ── v0.3 미션 · 차고 · 점프
  cross: '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="10" fill="#9aa3ae" stroke="#17202b" stroke-width="2.2"/><path d="M8.2 8.2l7.6 7.6M15.8 8.2l-7.6 7.6" stroke="#fff" stroke-width="3" stroke-linecap="round"/></svg>',
  mini: '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="11" cy="12.6" r="8.8" fill="#ff8a1f" stroke="#17202b" stroke-width="2"/><path d="M6.6 9.8l3.1 1.4M15.4 9.8l-3.1 1.4" stroke="#17202b" stroke-width="2" stroke-linecap="round"/><circle cx="8.8" cy="12.9" r="1.2" fill="#17202b"/><circle cx="13.2" cy="12.9" r="1.2" fill="#17202b"/><path d="M8.6 17h4.4" stroke="#17202b" stroke-width="2" stroke-linecap="round"/><path d="M13.2 17h7" stroke="#17202b" stroke-width="3.6" stroke-linecap="round"/><path d="M13.6 17h5.6" stroke="#fff" stroke-width="1.8" stroke-linecap="round"/><circle cx="20.4" cy="17" r="1.3" fill="#ff3b30"/></svg>',
  garage: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M1.8 10.2L12 3l10.2 7.2V21.5H1.8z" fill="#ffb400" stroke="#17202b" stroke-width="1.8" stroke-linejoin="round"/><rect x="5.6" y="11.2" width="12.8" height="10.3" fill="#c9d0d8" stroke="#17202b" stroke-width="1.6"/><path d="M5.6 13.8h12.8M5.6 16.4h12.8M5.6 19h12.8" stroke="#6d7682" stroke-width="1.3"/><rect x="9.6" y="6.6" width="4.8" height="2.6" rx=".6" fill="#fff" stroke="#17202b" stroke-width="1.1"/></svg>',
  jump: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3.5 19.5Q6 7.5 15.5 6.5" fill="none" stroke="#17202b" stroke-width="5.4" stroke-linecap="round"/><path d="M3.5 19.5Q6 7.5 15.5 6.5" fill="none" stroke="#fff" stroke-width="2.4" stroke-linecap="round"/><path d="M13.6 1.8l7.4 4.6-7 5.1z" fill="#fff" stroke="#17202b" stroke-width="1.7" stroke-linejoin="round"/></svg>',
  rocket: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M8.4 12.2L5 17.6l3.6-1.2zM15.6 12.2L19 17.6l-3.6-1.2z" fill="#ff3b30" stroke="#17202b" stroke-width="1.4" stroke-linejoin="round"/><path d="M9.6 16.2Q12 23.4 14.4 16.2z" fill="#ffb400" stroke="#17202b" stroke-width="1.2" stroke-linejoin="round"/><path d="M12 1.6c4 3.2 5 8.4 3.8 14.6H8.2C7 10 8 4.8 12 1.6z" fill="#fff" stroke="#17202b" stroke-width="1.7" stroke-linejoin="round"/><circle cx="12" cy="9.4" r="2.1" fill="#6aa6ff" stroke="#17202b" stroke-width="1.3"/></svg>',
  tackTab: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4.6 17.6v1.6a7.4 2.6 0 0 0 14.8 0v-1.6" fill="#8a929d" stroke="#17202b" stroke-width="1.6" stroke-linejoin="round"/><ellipse cx="12" cy="17.6" rx="7.4" ry="2.6" fill="#e9ecef" stroke="#17202b" stroke-width="1.6"/><path d="M10.2 17.5L12 2.6l1.8 14.9z" fill="#c9d0d8" stroke="#17202b" stroke-width="1.6" stroke-linejoin="round"/><path d="M17.5 4.5l.7 1.8 1.8.7-1.8.7-.7 1.8-.7-1.8-1.8-.7 1.8-.7z" fill="#ffd23f" stroke="#17202b" stroke-width=".9" stroke-linejoin="round"/></svg>',
  shieldOk: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 2.2l8.2 3.1v6.1c0 5.2-3.6 8.7-8.2 10.3-4.6-1.6-8.2-5.1-8.2-10.3V5.3z" fill="#fff" stroke="#17202b" stroke-width="1.8" stroke-linejoin="round"/><path d="M8.2 11.8l2.6 2.6 5-5.2" fill="none" stroke="#17a466" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  wrench: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M14.6 3.2a5 5 0 0 0-4.5 6.6L3.4 16.5a2.1 2.1 0 0 0 3 3l6.7-6.7a5 5 0 0 0 6.6-4.5l-3 1.6-2.6-.6-.6-2.6z" fill="#fff"/></svg>',
  fuel: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 21V5.2A2.2 2.2 0 0 1 6.2 3h6.6A2.2 2.2 0 0 1 15 5.2V21zM6.6 6v4.4h5.8V6z" fill="#fff" fill-rule="evenodd"/><path d="M15 9.2l2.6 1.6v6.6a1.5 1.5 0 0 0 3 0V8.6L18 6" fill="none" stroke="#fff" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  cup: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5.6 8h12.8l-1.6 12.4a1.6 1.6 0 0 1-1.6 1.4H8.8a1.6 1.6 0 0 1-1.6-1.4z" fill="#fff"/><rect x="4.4" y="5" width="15.2" height="3" rx="1" fill="#fff"/><path d="M9 3.6q-1.4-1.4 0-2.8M13 3.6q-1.4-1.4 0-2.8" fill="none" stroke="#fff" stroke-width="1.4" stroke-linecap="round"/></svg>',
  // ── v0.4 내구도 · 실패 · 알림
  carFront: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6.2 4.4h11.6l2.5 6.2H3.7z" fill="#ffd23f" stroke="#17202b" stroke-width="1.6" stroke-linejoin="round"/><path d="M7.5 6h9l1.5 3.9H6z" fill="#24366b"/><rect x="2" y="10" width="20" height="7.6" rx="2.6" fill="#ffd23f" stroke="#17202b" stroke-width="1.6"/><circle cx="6.1" cy="13.3" r="1.9" fill="#fff6c8" stroke="#17202b" stroke-width="1.1"/><circle cx="17.9" cy="13.3" r="1.9" fill="#fff6c8" stroke="#17202b" stroke-width="1.1"/><rect x="9.3" y="12.3" width="5.4" height="2.1" rx=".6" fill="#17202b" opacity=".55"/><rect x="1.2" y="16" width="21.6" height="3.8" rx="1.9" fill="#c9d0d8" stroke="#17202b" stroke-width="1.6"/><rect x="3" y="19.6" width="3.6" height="2.8" rx=".8" fill="#17202b"/><rect x="17.4" y="19.6" width="3.6" height="2.8" rx=".8" fill="#17202b"/></svg>',
  retry: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M19.2 12.6A7.3 7.3 0 1 1 16.6 6.3" fill="none" stroke="#17202b" stroke-width="5.6" stroke-linecap="round"/><path d="M19.2 12.6A7.3 7.3 0 1 1 16.6 6.3" fill="none" stroke="#fff" stroke-width="2.6" stroke-linecap="round"/><path d="M13.4 2.4l7.4 1.8-3.4 6.6z" fill="#fff" stroke="#17202b" stroke-width="1.6" stroke-linejoin="round"/></svg>',
  warnTri: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 2.6L22.4 20.6H1.6z" fill="#ffd23f" stroke="#17202b" stroke-width="2" stroke-linejoin="round"/><path d="M12 8.6v6" stroke="#17202b" stroke-width="2.8" stroke-linecap="round"/><circle cx="12" cy="17.6" r="1.5" fill="#17202b"/></svg>',
  info: '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="10" fill="#2f6fd6" stroke="#17202b" stroke-width="2"/><circle cx="12" cy="7.4" r="1.7" fill="#fff"/><path d="M12 11v6.4" stroke="#fff" stroke-width="3" stroke-linecap="round"/></svg>',
  road: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M8.6 2.5h6.8L21 21.5H3z" fill="#4a515c" stroke="#17202b" stroke-width="1.8" stroke-linejoin="round"/><path d="M12 4.5v2.6M12 10v3M12 16.2v3.6" stroke="#ffd23f" stroke-width="2" stroke-linecap="round"/></svg>',
};


// 블박 화면 대체 그림 (사진이 없을 때) / 미수집 실루엣. viewBox 16:9, 그라데이션 id 없이 단색만 (중복 삽입 안전)
function dashArt(color = '#d9c9a3', mode = 'photo', seed = 1) {
  const sil = mode === 'silhouette';
  const sky = sil ? '#2a3140' : ['#3d5878', '#5a4a6e', '#5b6f7f', '#141a33'][Math.abs(seed | 0) % 4];
  const grd = sil ? '#232a35' : '#3f4d43';
  const road = sil ? '#1d232c' : '#3b3f46';
  const line = sil ? '#3a4352' : '#e8e8e0';
  const car = sil ? '#11161e' : color;
  const ink = sil ? '#0b0e13' : '#17202b';
  const tail = sil ? '#2a3140' : '#ff2a1a';
  return `<svg class="ui-art" viewBox="0 0 160 90" preserveAspectRatio="xMidYMid slice" aria-hidden="true">
    <rect width="160" height="44" fill="${sky}"/>
    <path d="M0 44 L0 36 Q20 26 42 34 Q62 22 86 32 Q112 20 136 31 Q150 27 160 33 L160 44z" fill="${sil ? '#262d3a' : '#2f4a3e'}"/>
    <rect y="43" width="160" height="47" fill="${grd}"/>
    <path d="M60 43 L100 43 L178 90 L-18 90z" fill="${road}"/>
    <path d="M61 43 L-6 88" stroke="${sil ? line : '#ffcf33'}" stroke-width="1.8"/>
    <path d="M73 43 L44 90 M87 43 L116 90" stroke="${line}" stroke-width="1.6" stroke-dasharray="6 7"/>
    <g transform="translate(80 62)">
      <rect x="-19" y="-8" width="38" height="18" rx="4" fill="${car}" stroke="${ink}" stroke-width="1.8"/>
      <rect x="-14" y="-17" width="28" height="11" rx="3.5" fill="${car}" stroke="${ink}" stroke-width="1.8"/>
      <rect x="-11.5" y="-15" width="23" height="6.4" rx="1.6" fill="${sil ? '#0b0e13' : '#24366b'}"/>
      <rect x="-17.5" y="-4.5" width="7" height="3.6" rx="1" fill="${tail}"/>
      <rect x="10.5" y="-4.5" width="7" height="3.6" rx="1" fill="${tail}"/>
      <rect x="-7" y="1.5" width="14" height="5" rx="1" fill="${sil ? '#2a3140' : '#fff'}" stroke="${ink}" stroke-width=".9"/>
      <rect x="-17" y="9" width="7" height="4.5" rx="1.2" fill="${ink}"/><rect x="10" y="9" width="7" height="4.5" rx="1.2" fill="${ink}"/>
    </g>
    ${sil ? '' : '<path d="M52 40h-6v6M108 40h6v6M52 84h-6v-6M108 84h6v-6" fill="none" stroke="#ff3b30" stroke-width="2"/>'}
  </svg>`;
}
// ───────────────────────────── 차고 아이템 그림 (인라인 SVG, 아이템마다 다른 그림 · id 없는 단색만 → 중복 삽입 안전)
// viewBox 120×84, 바닥 그림자 y≈75. 잉크 외곽선 #17202b, 플랫 색 (Crossy 풍)
const INK = '#17202b';
const so = (w = 3) => `stroke="${INK}" stroke-width="${w}" stroke-linejoin="round"`;
const wheel = (x, y, r = 10) => `<circle cx="${x}" cy="${y}" r="${r}" fill="#2a2f38" ${so()}/><circle cx="${x}" cy="${y}" r="${(r * 0.42).toFixed(1)}" fill="#c9d0d8" ${so(1.6)}/>`;
const shadow = (rx = 44, cx = 60, cy = 75) => `<ellipse cx="${cx}" cy="${cy}" rx="${rx}" ry="4.5" fill="#000" opacity=".2"/>`;
const sparkle = (x, y, s = 1, c = '#fff') => `<path d="M${x} ${y - 8 * s}L${x + 2 * s} ${y - 2 * s}L${x + 8 * s} ${y}L${x + 2 * s} ${y + 2 * s}L${x} ${y + 8 * s}L${x - 2 * s} ${y + 2 * s}L${x - 8 * s} ${y}L${x - 2 * s} ${y - 2 * s}z" fill="${c}" ${so(1.5)}/>`;
// 작은 차 (점프/피니시 그림용). (x,y) = 차체 중심, r = 기울기
const miniCar = (x, y, r = 0, s = 1, col = '#ffc928') => `<g transform="translate(${x} ${y}) rotate(${r}) scale(${s})">`
  + `<path d="M-13 -7L-9 -16H8L13 -7z" fill="${col}" ${so()}/><path d="M-8.4 -8.4L-6 -13.6H5.6L8.2 -8.4z" fill="#24366b"/>`
  + `<rect x="-21" y="-8" width="42" height="14" rx="4" fill="${col}" ${so()}/><rect x="16" y="-4" width="5" height="4" rx="1" fill="#fff6c8"/>`
  + `<circle cx="-11" cy="6" r="5.4" fill="#2a2f38" ${so(2.6)}/><circle cx="11" cy="6" r="5.4" fill="#2a2f38" ${so(2.6)}/></g>`;
// ───────────────────────────── v0.4 도로 상황 아이콘 (갓길 10 · 경적 11 · 특수)
// 갓길 = 위에서 본 도로 타일(오른쪽 밝은 띠가 갓길) + 모드 표시. 경적 = 파란 지시표지 원 + 경적 + 오른쪽 아래 배지.
// 특수 = 노란 주의표지 삼각형 + 키워드 그림. 40×40, id 없는 단색 (중복 삽입 안전)
const RI = {
  tile: (bg = '#4a515c', sh = '#78808b') => `<rect x="2" y="2" width="36" height="36" rx="8" fill="${bg}" ${so(2.4)}/>`
    + `<rect x="27" y="3.2" width="9.8" height="33.6" rx="1" fill="${sh}"/><path d="M27 3.5v33" stroke="#fff" stroke-width="1.6"/>`
    + '<path d="M10.5 5v6M10.5 17v6M10.5 29v6M18.8 5v6M18.8 17v6M18.8 29v6" stroke="#fff" stroke-opacity=".75" stroke-width="1.5"/>',
  cone: (x, y, s = 1) => `<path d="M${x} ${y - 6 * s}L${x + 3.6 * s} ${y + 3 * s}H${x - 3.6 * s}z" fill="#ff8a1f" stroke="${INK}" stroke-width="1.1" stroke-linejoin="round"/><path d="M${x - 2.1 * s} ${y - .2 * s}H${x + 2.1 * s}" stroke="#fff" stroke-width="1.3"/>`,
  carTop: (x, y, c = '#f4f4f2', w = 6.4, h = 9.6) => `<rect x="${x - w / 2}" y="${y - h / 2}" width="${w}" height="${h}" rx="1.8" fill="${c}" stroke="${INK}" stroke-width="1.2"/><rect x="${x - w / 2 + 1.2}" y="${y - h / 2 + 2}" width="${w - 2.4}" height="2.4" rx=".6" fill="#24366b"/>`,
  horn: '<path d="M7 16.6h3.4l7-4.6v16l-7-4.6H7z" fill="#fff" stroke="#17202b" stroke-width="1.5" stroke-linejoin="round"/><path d="M19.6 16.4l2.2-1.4M20.2 20h2.6M19.6 23.6l2.2 1.4" stroke="#fff" stroke-width="1.8" stroke-linecap="round"/>',
  badge: (inner, bg = '#fff') => `<circle cx="29.5" cy="29.5" r="9" fill="${bg}" ${so(2)}/>${inner}`,
};
const SH_MODES = {
  open: { label: '갓길 개방', short: '개방', tone: 'ok', svg: RI.tile() + '<path d="M31.9 33V12" stroke="#22c55e" stroke-width="3.4" stroke-linecap="round"/><path d="M27.6 15.6l4.3-6.4 4.3 6.4z" fill="#22c55e" stroke="#17202b" stroke-width="1.2" stroke-linejoin="round"/>' + RI.carTop(14.6, 24, '#ffd23f') },
  crowded: { label: '갓길 혼잡(얌체)', short: '혼잡', tone: 'warn', svg: RI.tile() + RI.carTop(31.9, 9.5, '#ff8a1f', 6, 8.6) + RI.carTop(31.9, 20, '#d8342c', 6, 8.6) + RI.carTop(31.9, 30.5, '#ff8a1f', 6, 8.6) },
  blocked: { label: '갓길 공사 구간', short: '공사 구간', tone: 'warn', svg: RI.tile() + RI.cone(31.9, 16.5, 0.9) + RI.cone(31.9, 24.5, 0.9) + '<path d="M28 33.5h7.8" stroke="#22c55e" stroke-width="2.4" stroke-linecap="round"/><path d="M28 6.5h7.8" stroke="#22c55e" stroke-width="2.4" stroke-linecap="round"/>' },
  closed: { label: '갓길 폐쇄', short: '폐쇄', tone: 'bad', svg: RI.tile() + '<rect x="28.2" y="4" width="7.4" height="32" fill="#fff"/><path d="M28.2 8l7.4-5M28.2 15l7.4-5M28.2 22l7.4-5M28.2 29l7.4-5M28.2 36l7.4-5" stroke="#ff3b30" stroke-width="2.8"/><rect x="28.2" y="4" width="7.4" height="32" fill="none" stroke="#17202b" stroke-width="1.2"/>' },
  dark: { label: '어두운 갓길(낙하물)', short: '어둠', tone: 'warn', svg: RI.tile('#1d2330', '#2a3140') + '<path d="M31.9 37L25.5 18h12.8z" fill="#fff3a6" opacity=".55"/><rect x="29.4" y="9" width="5" height="4.4" rx=".8" fill="#2a2f38" stroke="#5a6372" stroke-width="1"/><path d="M8 7.4a4 4 0 1 0 4.6 4.6 3.2 3.2 0 0 1-4.6-4.6z" fill="#ffe14d"/>' },
  debris: { label: '갓길 낙하물', short: '낙하물', tone: 'warn', svg: RI.tile() + '<circle cx="31.9" cy="11.5" r="3.6" fill="#2a2f38" stroke="#17202b" stroke-width="1.2"/><circle cx="31.9" cy="11.5" r="1.4" fill="#9aa1a9"/><rect x="29" y="20" width="6" height="5" rx=".8" fill="#c98a4a" stroke="#17202b" stroke-width="1.2" transform="rotate(-14 32 22.5)"/><path d="M29 31l2 1.6M33.5 30.2l1.6 2.2M30.6 34.6l2.6-.6" stroke="#ffd23f" stroke-width="1.4" stroke-linecap="round"/>' },
  watched: { label: '갓길 단속 카메라', short: '단속 카메라', tone: 'warn', svg: RI.tile() + '<path d="M24 34V14h6" fill="none" stroke="#c9d0d8" stroke-width="2.2"/><rect x="27.5" y="9.5" width="9.5" height="7.5" rx="1.6" fill="#f4f4f2" stroke="#17202b" stroke-width="1.3"/><circle cx="32.2" cy="13.2" r="2.1" fill="#24366b"/><path d="M29.5 20.5l-2 2.6M32.2 21v3M35 20.5l2 2.6" stroke="#ffe14d" stroke-width="1.6" stroke-linecap="round"/>' },
  merge: { label: '갓길=합류차로', short: '합류차로', tone: 'warn', svg: RI.tile() + RI.carTop(31.9, 27, '#2f6fd6', 6, 8.6) + RI.carTop(31.9, 15.6, '#f4f4f2', 6, 8.6) + '<path d="M31.9 9.5Q31.9 5.6 24.5 5.4" fill="none" stroke="#ffd23f" stroke-width="2.4" stroke-linecap="round"/><path d="M26.4 2.6l-4.2 2.8 4.2 2.8z" fill="#ffd23f" stroke="#17202b" stroke-width="1" stroke-linejoin="round"/>' },
  occupied: { label: '갓길 불법주차', short: '불법주차', tone: 'warn', svg: RI.tile() + RI.carTop(31.9, 12, '#3a3f47', 6, 8.6) + RI.carTop(31.9, 26, '#f4f4f2', 6, 8.6) + '<circle cx="29.4" cy="8.2" r="1.3" fill="#ffb400"/><circle cx="34.4" cy="8.2" r="1.3" fill="#ffb400"/><circle cx="29.4" cy="22.2" r="1.3" fill="#ffb400"/><circle cx="34.4" cy="22.2" r="1.3" fill="#ffb400"/><circle cx="9" cy="9" r="5.6" fill="#2f6fd6" stroke="#17202b" stroke-width="1.4"/><path d="M7.4 12V6.3h2.2a1.7 1.7 0 0 1 0 3.4H7.4" fill="none" stroke="#fff" stroke-width="1.6" stroke-linejoin="round"/>' },
  none: { label: '갓길 없음(터널)', short: '없음(터널)', tone: 'bad', svg: '<rect x="2" y="2" width="36" height="36" rx="8" fill="#7a808a" ' + so(2.4) + '/><path d="M5 38V21a15 15 0 0 1 30 0v17" fill="#11161e" stroke="#17202b" stroke-width="2"/><path d="M8.5 19a11.5 11.5 0 0 1 23 0" fill="none" stroke="#ffd23f" stroke-width="1.6" stroke-dasharray="1.6 3.2" stroke-linecap="round"/><path d="M14 38l3-12h6l3 12z" fill="#3b3f46"/><path d="M20 28v2.4M20 33v3" stroke="#fff" stroke-width="1.2"/>' },
};
const hornBase = (c = '#1f4fa3') => `<circle cx="19" cy="20" r="17" fill="${c}" ${so(2.4)}/><circle cx="19" cy="20" r="14.2" fill="none" stroke="#fff" stroke-width="1.6"/>` + RI.horn;
const HONK_MODES = {
  yield: { label: '경적=양보', short: '양보', tone: 'ok', svg: hornBase() + RI.badge('<path d="M25.5 33.5c0-4 2.6-6.6 6.6-6.6" fill="none" stroke="#17a466" stroke-width="2.6" stroke-linecap="round"/><path d="M31 23.6l4.6 3.3-4.6 3.3z" fill="#17a466"/>') },
  gapRace: { label: '경적=틈 경쟁', short: '틈 경쟁', tone: 'warn', svg: hornBase() + RI.badge('<circle cx="29.5" cy="30.4" r="5.4" fill="#fff" stroke="#17202b" stroke-width="1.6"/><path d="M29.5 30.4v-3.2M29.5 30.4l2.2 1.4" stroke="#ff3b30" stroke-width="1.6" stroke-linecap="round"/><path d="M28 23.4h3" stroke="#17202b" stroke-width="1.8" stroke-linecap="round"/>', '#ffd23f') },
  backfire: { label: '경적 역효과', short: '역효과', tone: 'bad', svg: hornBase('#c8241a') + RI.badge('<path d="M33.5 26.2a4.6 4.6 0 1 0 .6 5.6" fill="none" stroke="#c8241a" stroke-width="2.4" stroke-linecap="round"/><path d="M31.6 22.6l3.6 3.4-4.6 1.2z" fill="#c8241a"/>') },
  push: { label: '경적=방향 밀기', short: '방향 밀기', tone: 'warn', svg: hornBase() + RI.badge('<path d="M23.8 29.5h8.6" stroke="#2f6fd6" stroke-width="2.8" stroke-linecap="round"/><path d="M31 25.4l4.6 4.1-4.6 4.1z" fill="#2f6fd6"/><path d="M24.5 25.8v7.4" stroke="#17202b" stroke-width="1.4" stroke-dasharray="1.4 1.4"/>') },
  ignoredWhileYielding: { label: '양보 대기 차는 무시', short: '대기 차엔 무시', tone: 'warn', svg: hornBase() + RI.badge('<path d="M26 24.6h7l-7 9.8h7z" fill="#ffd23f" stroke="#17202b" stroke-width="1.4" stroke-linejoin="round"/><path d="M26.2 24.6h6.6M26.2 34.4h6.6" stroke="#17202b" stroke-width="2" stroke-linecap="round"/>') },
  rescue: { label: '경적=구출 교대', short: '구출 교대', tone: 'ok', svg: hornBase() + RI.badge('<path d="M29.5 35s-5.2-3.2-5.2-6.7a2.7 2.7 0 0 1 5.2-1.2 2.7 2.7 0 0 1 5.2 1.2c0 3.5-5.2 6.7-5.2 6.7z" fill="#ff3b30" stroke="#17202b" stroke-width="1.2" stroke-linejoin="round"/>') },
  normal: { label: '경적 정상', short: '정상', tone: 'ok', svg: hornBase() + RI.badge('<path d="M25.4 29.8l2.8 2.8 5.4-5.6" fill="none" stroke="#17a466" stroke-width="2.8" stroke-linecap="round" stroke-linejoin="round"/>') },
  bait: { label: '경적=미끼', short: '미끼', tone: 'warn', svg: hornBase() + RI.badge('<path d="M30.6 22.6v8.2a3.1 3.1 0 0 1-6.2 0v-1.4" fill="none" stroke="#17202b" stroke-width="2" stroke-linecap="round"/><path d="M24.4 29.4l-1.4 2.2" stroke="#17202b" stroke-width="2" stroke-linecap="round"/><circle cx="33.4" cy="26" r="2.4" fill="#ff3b30" stroke="#17202b" stroke-width="1.2"/>', '#ffd23f') },
  notify: { label: '경적=알림음', short: '알림음', tone: 'warn', svg: hornBase() + RI.badge('<rect x="25.6" y="23.4" width="7.6" height="12" rx="1.6" fill="#2a2f38" stroke="#17202b" stroke-width="1.2"/><rect x="26.8" y="25" width="5.2" height="7.8" rx=".6" fill="#6aa6ff"/><circle cx="33.6" cy="23.6" r="2.4" fill="#ff3b30" stroke="#17202b" stroke-width="1"/>') },
  evict: { label: '경적=퇴거 통보', short: '퇴거 통보', tone: 'warn', svg: hornBase() + RI.badge('<rect x="24.2" y="24" width="6.4" height="11" rx=".8" fill="#c98a4a" stroke="#17202b" stroke-width="1.3"/><circle cx="29" cy="29.8" r=".9" fill="#17202b"/><path d="M31 29.5h4.4" stroke="#ff3b30" stroke-width="2.2" stroke-linecap="round"/><path d="M33.6 26.8l2.6 2.7-2.6 2.7" fill="none" stroke="#ff3b30" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>') },
  echo: { label: '경적=메아리', short: '메아리', tone: 'warn', svg: hornBase('#3a3f4a') + RI.badge('<path d="M26.6 26.4a4.4 4.4 0 0 1 0 6.2M29.4 24a8 8 0 0 1 0 11M32.2 22.2a11 11 0 0 1 0 14.6" fill="none" stroke="#8b5cf6" stroke-width="1.9" stroke-linecap="round"/>') },
};
// 특수: 키워드 → 주의표지 안 그림 (없으면 '!')
const SP_GLYPH = [
  [/안개|fog/i, '<path d="M12.5 22.5h15M11 26.5h18M13.5 30.5h13" stroke="#17202b" stroke-width="2" stroke-linecap="round"/>'],
  [/밤|야간|어둠|무등화|dark|night/i, '<path d="M18 18.6a5.2 5.2 0 1 0 6 6 4.2 4.2 0 0 1-6-6z" fill="#17202b"/>'],
  [/카메라|단속|camera/i, '<rect x="13.4" y="20.6" width="13.2" height="9" rx="1.6" fill="#17202b"/><circle cx="21.4" cy="25.1" r="2.6" fill="#ffd23f"/><path d="M15.2 31.6h9.6" stroke="#17202b" stroke-width="1.6"/>'],
  [/터널|tunnel/i, '<path d="M12.6 32v-5.4a7.4 7.4 0 0 1 14.8 0V32z" fill="#17202b"/>'],
  [/비|빗길|rain/i, '<path d="M15 20.5l-1.6 3M20.5 20.5l-1.6 3M26 20.5l-1.6 3M17.6 26.5l-1.6 3M23 26.5l-1.6 3" stroke="#17202b" stroke-width="2" stroke-linecap="round"/>'],
  [/눈|빙판|snow/i, '<path d="M20 19.6v12.4M14.6 22.7l10.8 6.2M14.6 28.9l10.8-6.2" stroke="#17202b" stroke-width="2" stroke-linecap="round"/>'],
  [/공사|콘|cone/i, '<path d="M20 18.5l4.6 12h-9.2z" fill="#17202b"/><path d="M14 31.4h12" stroke="#17202b" stroke-width="2.2" stroke-linecap="round"/>'],
  [/합류|merge/i, '<path d="M15 32V24l5-5 5 5v8" fill="none" stroke="#17202b" stroke-width="2.2" stroke-linejoin="round"/><path d="M20 19v13" stroke="#17202b" stroke-width="2.2"/>'],
];
function specialSVG(text) {
  const g = (SP_GLYPH.find(([re]) => re.test(text)) || [0, '<path d="M20 18.4v7.6" stroke="#17202b" stroke-width="3.2" stroke-linecap="round"/><circle cx="20" cy="30" r="1.9" fill="#17202b"/>'])[1];
  return `<path d="M20 4.2L37.4 34.6H2.6z" fill="#ffd23f" stroke="#c8241a" stroke-width="3.4" stroke-linejoin="round"/><path d="M20 4.2L37.4 34.6H2.6z" fill="none" stroke="#17202b" stroke-width="1.2" stroke-linejoin="round"/>${g}`;
}
const roadSVG = (inner) => `<svg viewBox="0 0 40 40" aria-hidden="true">${inner}</svg>`;

// 견인 실패 그림: 레커차(주황)가 플레이어 차(노랑)를 앞바퀴 들어 끌고 감.
// viewBox 240×130 (위 20 = 여유 하늘), 아래 기준 slice → 어떤 비율로 잘려도 도로·차·레커는 남고 하늘만 잘린다
function wreckerArt() {
  return `<svg class="ui-fail__svg" viewBox="0 -20 240 130" preserveAspectRatio="xMidYMax slice" aria-hidden="true">
    <rect y="-20" width="240" height="130" fill="#bfe3ff"/>
    <circle cx="24" cy="6" r="9" fill="#fff6c8" opacity=".9"/>
    <path d="M0 76 Q30 64 62 72 Q96 60 132 70 Q170 58 204 68 Q224 64 240 68 V80 H0z" fill="#8fc0a0"/>
    <rect y="78" width="240" height="32" fill="#5b5f66"/>
    <path d="M0 80.5h240" stroke="#ffcf33" stroke-width="2"/>
    <path d="M-4 99h248" stroke="#f2f2ee" stroke-width="2.6" stroke-dasharray="16 12"/>
    <g transform="translate(-4 0)">
    <ellipse cx="150" cy="90" rx="64" ry="4.5" fill="#000" opacity=".22"/>
    <ellipse cx="60" cy="90" rx="34" ry="3.6" fill="#000" opacity=".2"/>
    <g class="ui-fail__truck">
      <path d="M108 52 L146 34" stroke="${INK}" stroke-width="8" stroke-linecap="round"/>
      <path d="M108 52 L146 34" stroke="#ffd23f" stroke-width="3.6" stroke-linecap="round"/>
      <path d="M108 52 L101 66" stroke="${INK}" stroke-width="2.2"/>
      <path d="M97.5 64.5h7l-1.4 5.4h-4.2z" fill="#9aa1a9" stroke="${INK}" stroke-width="1.6" stroke-linejoin="round"/>
      <rect x="112" y="56" width="70" height="20" rx="3" fill="#ff8a1f" ${so(3)}/>
      <rect x="128" y="60" width="34" height="12" rx="2" fill="#fff" stroke="${INK}" stroke-width="1.8"/>
      <text x="145" y="70" text-anchor="middle" font-size="10.5" font-family="'Black Han Sans','Jua',sans-serif" fill="${INK}">긴급견인</text>
      <path d="M178 76V44q0-7 7-7h17q5 0 7.6 4.4l9.4 16V76z" fill="#ff8a1f" ${so(3)}/>
      <path d="M185 43h15.4q3 0 4.6 2.8l6 10.4H185z" fill="#24366b" stroke="${INK}" stroke-width="1.6" stroke-linejoin="round"/>
      <rect x="214" y="62" width="6" height="5" rx="1.2" fill="#fff6c8" stroke="${INK}" stroke-width="1.2"/>
      <g class="ui-fail__beacon"><rect x="183" y="29.5" width="9" height="6.5" rx="2" fill="#ffb400" ${so(1.8)}/><rect x="193" y="29.5" width="9" height="6.5" rx="2" fill="#ff3b30" ${so(1.8)}/></g>
      ${wheel(132, 78, 9.5)}${wheel(200, 78, 9.5)}
    </g>
    <g class="ui-fail__towed">
      <g transform="translate(64 66) rotate(-13) scale(1.5)">
        <path d="M-13 -7L-9 -16H8L13 -7z" fill="#ffd23f" ${so(2)}/><path d="M-8.4 -8.4L-6 -13.6H5.6L8.2 -8.4z" fill="#24366b"/>
        <rect x="-21" y="-8" width="42" height="14" rx="4" fill="#ffd23f" ${so(2)}/>
        <path d="M13 -8.2l4.6 -6.2 3.2 3.4z" fill="#ffd23f" ${so(1.6)}/>
        <path d="M-6 -2l3 2.4 -2 2.6M4 -3l-2.4 3 2.6 1.8" fill="none" stroke="${INK}" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round"/>
        <rect x="16" y="-4" width="5" height="4" rx="1" fill="#9aa1a9"/>
        <circle cx="-11" cy="6" r="5.4" fill="#2a2f38" ${so(2)}/><circle cx="11" cy="6" r="5.4" fill="#2a2f38" ${so(2)}/>
        <circle cx="-11" cy="6" r="2" fill="#c9d0d8"/><circle cx="11" cy="6" r="2" fill="#c9d0d8"/>
      </g>
      <g class="ui-fail__steam"><circle cx="86" cy="38" r="6" fill="#fff" ${so(1.6)}/><circle cx="94" cy="30" r="7.5" fill="#fff" ${so(1.6)}/><circle cx="86" cy="22" r="5" fill="#eef1f4" ${so(1.4)}/></g>
      <g class="ui-fail__dizzy"><path d="M50 30l1.6 3.4 3.6.4-2.7 2.4.8 3.6-3.3-1.8-3.3 1.8.8-3.6-2.7-2.4 3.6-.4z" fill="#ffd23f" ${so(1.3)}/><path d="M36 38l1.1 2.4 2.5.3-1.9 1.7.6 2.5-2.3-1.3-2.3 1.3.6-2.5-1.9-1.7 2.5-.3z" fill="#ffd23f" ${so(1.1)}/></g>
    </g>
    </g>
  </svg>`;
}

const ART = {
  car_hatch: () => shadow(46)
    + `<path d="M14 60V42L22 22Q23 19 27 19H72Q76 19 78 22L90 37L102 39Q108 40 108 46V58Q108 62 104 62H18Q14 62 14 60z" fill="#ffc928" ${so()}/>`
    + `<path d="M27 24H47V36H22z" fill="#24366b" ${so(2.2)}/><path d="M52 24H71Q73 24 74 26L82 36H52z" fill="#24366b" ${so(2.2)}/>`
    + '<path d="M22 44H100" stroke="#fff" stroke-opacity=".55" stroke-width="3" stroke-linecap="round"/><path d="M50 38V58" stroke="#17202b" stroke-opacity=".45" stroke-width="1.8"/>'
    + `<rect x="101" y="42" width="7" height="5" rx="1.5" fill="#fff6c8" ${so(1.5)}/><rect x="13" y="43" width="5" height="7" rx="1" fill="#ff3b30" ${so(1.5)}/>`
    + wheel(34, 62) + wheel(88, 62),
  car_porter: () => shadow(48)
    + `<rect x="10" y="50" width="98" height="9" rx="2" fill="#3a4352" ${so()}/>`
    + `<rect x="16" y="22" width="22" height="16" rx="1.5" fill="#d99a4a" ${so(2.4)}/><path d="M27 22V38" stroke="#a8612a" stroke-width="2.4"/>`
    + `<rect x="40" y="27" width="18" height="11" rx="1.5" fill="#f0bd73" ${so(2.4)}/>`
    + `<rect x="10" y="36" width="66" height="15" rx="1.5" fill="#d4dae2" ${so()}/><path d="M27 36V51M44 36V51M61 36V51" stroke="#17202b" stroke-width="1.8"/>`
    + `<path d="M76 61V22Q76 16 82 16H97Q104 16 105 22L108 37V58Q108 62 104 62H76z" fill="#2f6fd6" ${so()}/>`
    + `<path d="M81 21H97Q100 21 100.6 23.6L102.6 34H81z" fill="#24366b" ${so(2.2)}/><path d="M80 42H104" stroke="#fff" stroke-opacity=".5" stroke-width="3" stroke-linecap="round"/>`
    + `<rect x="101" y="44" width="7" height="6" rx="1.5" fill="#fff6c8" ${so(1.5)}/>`
    + wheel(30, 62) + wheel(92, 62),
  car_wrecker: () => shadow(48)
    + `<rect x="10" y="50" width="98" height="9" rx="2" fill="#3a4352" ${so()}/>`
    + `<rect x="12" y="38" width="62" height="14" rx="2" fill="#4a5466" ${so()}/>`
    + `<rect x="12" y="38" width="16" height="14" fill="#ffd23f" ${so(2.4)}/><path d="M14 52L22 38M20 52L28 40M12 46L16 39" stroke="#17202b" stroke-width="3"/>`
    + '<path d="M50 40L26 13" stroke="#17202b" stroke-width="10" stroke-linecap="round"/><path d="M50 40L26 13" stroke="#ffd23f" stroke-width="5" stroke-linecap="round"/>'
    + `<circle cx="26" cy="13" r="4.4" fill="#c9d0d8" ${so(2.2)}/><path d="M23 16V33" stroke="#17202b" stroke-width="2"/>`
    + '<path d="M23 33q-5.6 0-5.6 5.4t5.6 5.6q4.6 0 4.6-4.4" fill="none" stroke="#17202b" stroke-width="3.4" stroke-linecap="round"/>'
    + `<path d="M74 61V24Q74 18 80 18H96Q103 18 104 24L108 38V58Q108 62 104 62H74z" fill="#ff8a1f" ${so()}/>`
    + `<path d="M80 23H96Q99 23 99.6 25.6L101.6 35H80z" fill="#24366b" ${so(2.2)}/><path d="M78 43H104" stroke="#fff" stroke-opacity=".5" stroke-width="3" stroke-linecap="round"/>`
    + `<rect x="83" y="11" width="14" height="7" rx="2.5" fill="#ffb400" ${so(2.4)}/><path d="M80 8l-4-4M100 8l4-4M90 6V1" stroke="#ffb400" stroke-width="2.6" stroke-linecap="round"/>`
    + `<rect x="101" y="45" width="7" height="6" rx="1.5" fill="#fff6c8" ${so(1.5)}/>`
    + wheel(30, 62) + wheel(92, 62),
  car_patrol: () => shadow(48)
    + `<path d="M10 60V48Q10 42 16 41L30 39L42 24Q44 21 48 21H74Q78 21 80 24L92 38L104 40Q110 41 110 47V58Q110 62 106 62H14Q10 62 10 60z" fill="#262b35" ${so()}/>`
    + `<path d="M37 38L46 26H59V38z" fill="#6f8fc8" ${so(2.2)}/><path d="M63 26H74Q76 26 77 28L85 38H63z" fill="#6f8fc8" ${so(2.2)}/>`
    + '<path d="M18 47H102" stroke="#fff" stroke-opacity=".3" stroke-width="3" stroke-linecap="round"/><path d="M61 39V58" stroke="#000" stroke-opacity=".5" stroke-width="1.8"/>'
    + `<rect x="48" y="14" width="12" height="7" rx="2" fill="#ff3b30" ${so(2.2)}/><rect x="60" y="14" width="12" height="7" rx="2" fill="#2f6fd6" ${so(2.2)}/>`
    + '<path d="M44 12l-6-5M76 12l6-5M60 9V3" stroke="#ffd23f" stroke-width="2.8" stroke-linecap="round"/>'
    + `<rect x="103" y="44" width="7" height="5" rx="1.5" fill="#fff6c8" ${so(1.5)}/><rect x="9" y="45" width="5" height="6" rx="1" fill="#ff3b30" ${so(1.5)}/>`
    + wheel(32, 62) + wheel(88, 62),
  wpn_tack: () => shadow(34)
    + `<path d="M84 63L92 46L98 63z" fill="#c9d0d8" ${so(2.4)}/><ellipse cx="91" cy="64" rx="11" ry="3.6" fill="#9aa3ae" ${so(2.2)}/>`
    + `<path d="M30 60V65A30 8.5 0 0 0 90 65V60" fill="#8a929d" ${so()}/><ellipse cx="60" cy="60" rx="30" ry="8.5" fill="#e9ecef" ${so()}/>`
    + `<path d="M53 60L60 12L67 60z" fill="#c9d0d8" ${so()}/><path d="M58.6 54L60.4 22" stroke="#fff" stroke-width="2.4" stroke-linecap="round"/>`
    + '<path d="M40 58q8-4 18-4" fill="none" stroke="#fff" stroke-width="2.6" stroke-linecap="round"/>' + sparkle(76, 20, 1.1),
  wpn_caltrop: () => {
    const cal = (x, y, s) => {
      const d = `M${x} ${y}L${x} ${y - 15 * s}M${x} ${y}L${x - 14 * s} ${y + 7 * s}M${x} ${y}L${x + 14 * s} ${y + 7 * s}M${x} ${y}L${x + 2 * s} ${y + 12 * s}`;
      return `<path d="${d}" stroke="${INK}" stroke-width="${(8 * s).toFixed(1)}" stroke-linecap="round"/><path d="${d}" stroke="#9aa3ae" stroke-width="${(4 * s).toFixed(1)}" stroke-linecap="round"/><circle cx="${x}" cy="${y}" r="${(3.2 * s).toFixed(1)}" fill="#c9d0d8" ${so(1.6)}/>`;
    };
    return shadow(42) + cal(34, 58, 0.95) + cal(84, 60, 0.95) + cal(59, 42, 1.15)
      + `<circle cx="101" cy="17" r="12" fill="#ffb400" ${so()}/><text x="101" y="22.5" text-anchor="middle" font-family="Black Han Sans, Jua, sans-serif" font-size="15" fill="${INK}">×3</text>`;
  },
  wpn_water: () => shadow(32)
    + `<path d="M60 20C74 20 92 38 92 53C92 68 77 75 60 75C43 75 28 68 28 53C28 38 46 20 60 20z" fill="#4fb3ff" ${so()}/>`
    + `<path d="M54.5 21.4L60 11.5L65.5 21.4Q60 23.6 54.5 21.4z" fill="#2f7fd6" ${so(2.4)}/>`
    + '<path d="M40 44Q43 32 53 27" fill="none" stroke="#fff" stroke-width="4.4" stroke-linecap="round" stroke-opacity=".9"/><ellipse cx="72" cy="62" rx="7" ry="3.4" fill="#fff" opacity=".35"/>'
    + `<path d="M100 26q5 7 0 10.6q-5-3.6 0-10.6z" fill="#8fd0ff" ${so(2)}/><path d="M18 34q4 6 0 9q-4-3 0-9z" fill="#8fd0ff" ${so(2)}/><path d="M104 50q3.6 5 0 7.6q-3.6-2.6 0-7.6z" fill="#8fd0ff" ${so(1.8)}/>`,
  wpn_gum: () => shadow(34)
    + `<path d="M36 62q-9 7-17 4" fill="none" stroke="${INK}" stroke-width="8" stroke-linecap="round"/><path d="M36 62q-9 7-17 4" fill="none" stroke="#ff7ab8" stroke-width="4" stroke-linecap="round"/>`
    + `<circle cx="57" cy="50" r="24" fill="#ff7ab8" ${so()}/><circle cx="85" cy="40" r="10" fill="#ffb3d6" ${so(2.4)}/><circle cx="82" cy="37" r="2.6" fill="#fff" opacity=".8"/>`
    + '<path d="M42 42q4-9 13-11" fill="none" stroke="#fff" stroke-width="4" stroke-linecap="round" stroke-opacity=".85"/>'
    + `<path d="M63 27Q68 13 80 14" fill="none" stroke="${INK}" stroke-width="3.2" stroke-linecap="round"/>` + sparkle(84, 13, 1, '#ffd23f')
    + `<text x="57" y="58" text-anchor="middle" font-family="Black Han Sans, Jua, sans-serif" font-size="17" fill="#fff" stroke="${INK}" stroke-width="3" paint-order="stroke">껌</text>`,
  mv_jump: () => shadow(26, 86) + shadow(20, 28)
    + miniCar(86, 60, 0, 1, '#9aa1a9')
    + '<path d="M14 70Q34 6 96 22" fill="none" stroke="#fff" stroke-width="3.2" stroke-dasharray="1 8" stroke-linecap="round"/>'
    + '<path d="M22 46l-9-3M24 38l-9-5M28 30l-8-6" stroke="#fff" stroke-width="2.6" stroke-linecap="round"/>'
    + miniCar(58, 22, -14, 1.05) + sparkle(102, 44, 0.8, '#ffd23f'),
  mv_drone: () => shadow(22, 60, 76)
    + `<path d="M48 38L24 26M72 38L96 26" stroke="${INK}" stroke-width="5.4" stroke-linecap="round"/><path d="M48 38L24 26M72 38L96 26" stroke="#6d7682" stroke-width="2.2" stroke-linecap="round"/>`
    + `<ellipse cx="24" cy="23" rx="17" ry="4" fill="#d6f0ff" ${so(2)}/><ellipse cx="96" cy="23" rx="17" ry="4" fill="#d6f0ff" ${so(2)}/>`
    + `<rect x="21" y="22" width="6" height="6" rx="1.5" fill="#3a4352" ${so(1.6)}/><rect x="93" y="22" width="6" height="6" rx="1.5" fill="#3a4352" ${so(1.6)}/>`
    + `<rect x="42" y="32" width="36" height="15" rx="6" fill="#3a4352" ${so()}/><path d="M48 36H72" stroke="#fff" stroke-opacity=".35" stroke-width="2.4" stroke-linecap="round"/>`
    + `<rect x="51" y="46" width="18" height="11" rx="3.5" fill="#17202b" ${so(2)}/><circle cx="60" cy="51.5" r="3.6" fill="#6aa6ff" ${so(1.4)}/>`
    + `<circle cx="73" cy="39.5" r="2.6" fill="#ff3b30" ${so(1.2)}/><path d="M48 62l-6 7M72 62l6 7M60 64v8" stroke="#fff" stroke-width="2" stroke-dasharray="2 3" stroke-linecap="round"/>`,
  fin_rocket: () => `<g transform="rotate(38 60 44)">`
    + `<path d="M51 55Q60 82 69 55z" fill="#ffb400" ${so(2.6)}/><path d="M55 55Q60 70 65 55z" fill="#fff3a8"/>`
    + `<path d="M50 42L39 58L50 54zM70 42L81 58L70 54z" fill="#ff3b30" ${so(2.6)}/>`
    + `<path d="M60 7C71 17 73 33 70.5 55H49.5C47 33 49 17 60 7z" fill="#fff" ${so()}/><path d="M60 7C66 12 69.5 19 70.6 26H49.4C50.5 19 54 12 60 7z" fill="#ff3b30" ${so()}/>`
    + `<circle cx="60" cy="37" r="6.4" fill="#6aa6ff" ${so()}/><circle cx="58" cy="35" r="1.8" fill="#fff"/></g>`
    + sparkle(100, 16, 1.1, '#ffd23f') + sparkle(16, 22, 0.7) + sparkle(98, 64, 0.6),
  fin_balloon: () => shadow(18, 60, 77)
    + '<path d="M38 36L57 58M60 30V58M82 38L63 58" stroke="#17202b" stroke-width="1.8"/>'
    + `<ellipse cx="38" cy="23" rx="12" ry="14" fill="#ff3b30" ${so()}/><ellipse cx="82" cy="25" rx="12" ry="14" fill="#2f6fd6" ${so()}/><ellipse cx="60" cy="16" rx="13" ry="15" fill="#ffd23f" ${so()}/>`
    + '<path d="M33 16q2-5 6-6M77 18q2-5 6-6M54 9q2-5 6-6" fill="none" stroke="#fff" stroke-width="2.6" stroke-linecap="round" stroke-opacity=".85"/>'
    + miniCar(60, 66, 6, 0.82),
  fin_heli: () => '<path d="M70 42V56" stroke="#17202b" stroke-width="1.8" stroke-dasharray="3 2"/>' + miniCar(70, 66, -6, 0.8, '#d9c9a3')
    + `<path d="M48 26H14" stroke="${INK}" stroke-width="8" stroke-linecap="round"/><path d="M48 26H15" stroke="#17a466" stroke-width="3.6" stroke-linecap="round"/>`
    + `<circle cx="13" cy="25" r="7" fill="none" stroke="${INK}" stroke-width="2.4" stroke-dasharray="4 3"/>`
    + `<path d="M56 44H90M62 39V44M84 39V44" stroke="${INK}" stroke-width="3" stroke-linecap="round"/>`
    + `<path d="M46 28Q46 16 60 16H76Q92 16 94 29Q94 40 80 40H54Q46 40 46 32z" fill="#17a466" ${so()}/>`
    + `<path d="M77 20H85Q91 21 91.4 29H77z" fill="#9fe0ff" ${so(2.2)}/><path d="M52 24H70" stroke="#fff" stroke-opacity=".5" stroke-width="2.6" stroke-linecap="round"/>`
    + `<path d="M70 10V16" stroke="${INK}" stroke-width="3"/><path d="M34 10H106" stroke="${INK}" stroke-width="4.4" stroke-linecap="round"/><path d="M36 10H104" stroke="#c9d0d8" stroke-width="1.6" stroke-linecap="round"/>`,
  fin_ufo: () => '<path d="M46 40L26 80H94L74 40z" fill="#fff3a8" opacity=".75"/>'
    + miniCar(60, 64, 16, 0.72, '#d9c9a3') + '<path d="M44 76l-3 3M78 72l3 3M70 52l4-2" stroke="#fff" stroke-width="2" stroke-linecap="round"/>'
    + `<path d="M43 34Q45 14 60 14Q75 14 77 34z" fill="#7dffb0" ${so()}/><path d="M50 26q2-6 8-7" fill="none" stroke="#fff" stroke-width="2.6" stroke-linecap="round"/>`
    + `<ellipse cx="60" cy="38" rx="35" ry="10" fill="#c9d0d8" ${so()}/><path d="M30 37Q60 45 90 37" fill="none" stroke="#8a929d" stroke-width="2"/>`
    + ['36,40', '50,43.5', '70,43.5', '84,40'].map((p) => { const [x, y] = p.split(','); return `<circle cx="${x}" cy="${y}" r="2.6" fill="#ffd23f" ${so(1.3)}/>`; }).join('')
    + sparkle(100, 14, 0.7) + sparkle(18, 20, 0.6),
  pas_4k: () => shadow(36)
    + `<path d="M50 23V12H70V23" fill="#3a4352" ${so(2.6)}/><rect x="24" y="22" width="70" height="42" rx="11" fill="#2a2f38" ${so()}/>`
    + `<circle cx="50" cy="43" r="13" fill="#11161e" ${so()}/><circle cx="50" cy="43" r="6.4" fill="#6aa6ff" ${so(1.8)}/><circle cx="47.6" cy="40.4" r="2" fill="#fff"/>`
    + `<circle cx="82" cy="31" r="3.2" fill="#ff3b30" ${so(1.4)}/><path d="M30 28H44" stroke="#fff" stroke-opacity=".3" stroke-width="2.4" stroke-linecap="round"/>`
    + `<g transform="rotate(-8 86 54)"><rect x="70" y="45" width="34" height="19" rx="4" fill="#ffd23f" ${so()}/><text x="87" y="60" text-anchor="middle" font-family="Black Han Sans, Jua, sans-serif" font-size="15" fill="${INK}">4K</text></g>`,
  pas_airbag: () => {
    // 핸들(테두리 + 살 3개) 앞으로 에어백이 '펑' 부풀어 나옴
    const cs = [[49, 44, 11], [60, 36, 12.5], [71, 44, 11], [60, 51, 11], [52, 35, 8], [68, 35, 8]];
    return shadow(38)
      + `<circle cx="60" cy="43" r="31" fill="none" stroke="${INK}" stroke-width="11"/><circle cx="60" cy="43" r="31" fill="none" stroke="#5b6069" stroke-width="5.4"/>`
      + `<path d="M60 43L60 74M60 43L32 30M60 43L88 30" stroke="${INK}" stroke-width="8" stroke-linecap="round"/><path d="M60 43L60 72M60 43L34 31M60 43L86 31" stroke="#5b6069" stroke-width="3.6" stroke-linecap="round"/>`
      + cs.map(([x, y, r]) => `<circle cx="${x}" cy="${y}" r="${r}" fill="${INK}" stroke="${INK}" stroke-width="6"/>`).join('')
      + cs.map(([x, y, r]) => `<circle cx="${x}" cy="${y}" r="${r}" fill="#fff"/>`).join('')
      + '<path d="M47 38q3-5 8-6" fill="none" stroke="#c9d0d8" stroke-width="2.4" stroke-linecap="round"/>'
      + `<circle cx="55.5" cy="43" r="1.9" fill="${INK}"/><circle cx="64.5" cy="43" r="1.9" fill="${INK}"/><path d="M56 48.5q4 3.2 8 0" fill="none" stroke="${INK}" stroke-width="2.2" stroke-linecap="round"/>`
      + '<path d="M26 18l-6-4M94 18l6-4M60 8V2" stroke="#fff" stroke-width="2.6" stroke-linecap="round"/>';
  },
  pas_trot: () => shadow(32, 54)
    + `<path d="M22 35H36L70 17V67L36 49H22z" fill="#ffd23f" ${so()}/><ellipse cx="70" cy="42" rx="6.4" ry="25" fill="#ffb400" ${so()}/>`
    + '<path d="M28 40H38" stroke="#fff" stroke-opacity=".6" stroke-width="3" stroke-linecap="round"/>'
    + `<path d="M93.5 30V12L103 14.5V22" fill="none" stroke="${INK}" stroke-width="2.8" stroke-linejoin="round"/><ellipse cx="89.5" cy="30" rx="5.2" ry="4.2" fill="#ff3b8a" ${so(2)}/><ellipse cx="99" cy="24" rx="4.4" ry="3.6" fill="#ff3b8a" ${so(2)}/>`
    + `<path d="M104 58V44" stroke="${INK}" stroke-width="2.8"/><ellipse cx="100" cy="58" rx="5" ry="4" fill="#2f6fd6" ${so(2)}/>`
    + '<path d="M80 34q4 8 0 16M86 30q6 12 0 24" fill="none" stroke="#fff" stroke-width="2.6" stroke-linecap="round"/>',
  pas_coffee: () => shadow(26)
    + '<path d="M50 15q-5-5 0-10M60 13q-5-5 0-10M70 15q-5-5 0-10" fill="none" stroke="#fff" stroke-width="3" stroke-linecap="round"/>'
    + `<path d="M40 27H80L74.4 71Q73.8 75 69.8 75H50.2Q46.2 75 45.6 71z" fill="#fff" ${so()}/>`
    + `<path d="M42.4 41H77.6L75.6 58H44.4z" fill="#c98a4a" ${so(2.4)}/><path d="M36 19H84Q86 19 86 21V27H34V21Q34 19 36 19z" fill="#8b5a3c" ${so()}/>`
    + `<text x="60" y="54.5" text-anchor="middle" font-family="Black Han Sans, Jua, sans-serif" font-size="11" fill="#fff" stroke="${INK}" stroke-width="2.4" paint-order="stroke">쉼터</text>`
    + '<path d="M47 32L50 66" stroke="#e3e6ea" stroke-width="3" stroke-linecap="round"/>',
};
// 모르는 id 는 분류별 대표 그림
const ART_CAT = { car: 'car_hatch', weapon: 'wpn_tack', move: 'mv_jump', finish: 'fin_rocket', passive: 'pas_coffee' };
function itemArt(it) {
  const f = ART[it?.id] || ART[ART_CAT[it?.cat]] || ART.car_hatch;
  let inner = '';
  try { inner = f(); } catch { /* */ }
  return `<svg class="ui-item__svg" viewBox="0 0 120 84" aria-hidden="true">${inner}</svg>`;
}

const hex = (c, d = '#d9c9a3') => (typeof c === 'number' && Number.isFinite(c) ? '#' + (c & 0xffffff).toString(16).padStart(6, '0') : typeof c === 'string' && /^#[0-9a-f]{3,8}$/i.test(c) ? c : d);
const villainColor = (s) => hex(s && Array.isArray(s.villains) && s.villains[0] ? s.villains[0].color : null, ['#d9c9a3', '#2f6fd6', '#3a3f47', '#f4f4f2', '#7a8a4a'][Math.abs(num(s?.id, 1)) % 5]);
// 사진 src 는 게임이 만든 것만 (data:image / blob / 상대·http 경로). DOM 속성으로만 넣는다.
const okSrc = (s) => typeof s === 'string' && s.length > 10 && /^(data:image\/|blob:|https?:|\.{0,2}\/)/.test(s);

// 보상 숫자 포맷
const won = (n) => '₩' + fmt(Math.max(0, num(n)));
function kor(n) {
  n = Math.max(0, Math.round(num(n)));
  const d1 = (v) => { const s = (Math.round(v * 10) / 10).toFixed(1); return s.endsWith('.0') ? s.slice(0, -2) : s; };
  if (n < 1000) return String(n);
  if (n < 9950) return d1(n / 1000) + '천';
  if (n < 999500) return d1(n / 1e4) + '만';
  if (n < 1e8) return fmt(Math.round(n / 1e4)) + '만';
  return d1(n / 1e8) + '억';
}
function clock(d = new Date()) {
  const p = (v) => String(v).padStart(2, '0');
  return `${d.getFullYear()}.${p(d.getMonth() + 1)}.${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}
const easeOut = (k) => 1 - Math.pow(1 - k, 3);

// 여러 카운트업을 rAF 하나로 (결과 화면 전용, clearResultTimers 에서 정리)
const tweens = new Set();
let twRaf = 0;
function tween(delay, dur, fn, done) {
  if (reduceMotion || dur <= 0) { try { fn(1); done && done(); } catch { /* */ } return; }
  try { fn(0); } catch { /* */ }
  tweens.add({ t0: now() + delay, dur, fn, done });
  if (!twRaf) twRaf = requestAnimationFrame(twTick);
}
function twTick() {
  twRaf = 0;
  const t = now();
  for (const w of tweens) {
    if (t < w.t0) continue;
    const k = clamp((t - w.t0) / w.dur, 0, 1);
    try { w.fn(easeOut(k)); } catch { tweens.delete(w); continue; }
    if (k >= 1) { tweens.delete(w); try { w.done && w.done(); } catch { /* */ } }
  }
  if (tweens.size) twRaf = requestAnimationFrame(twTick);
}
function clearTweens() { tweens.clear(); cancelAnimationFrame(twRaf); twRaf = 0; }

function shieldHTML(route, cls = '') {
  return `<span class="ui-shield ${cls}">${SVG.shield}<b class="ui-shield__n">${esc(route ?? '')}</b></span>`;
}
// ── 스테이지 등급 · 처분 카드 (100스테이지 카탈로그)
// 제목 접두사 [최종보스]/[보스]/[엘리트]/[보너스] → 제목에서 떼고 배지로. 없으면 플래그(boss/elite), 그다음 옛 '(최종보스)' 꼬리표.
const KIND_RE = /^\s*\[(최종보스|보스|엘리트|보너스)\]\s*/;
const KIND_OF = { 최종보스: 'final', 보스: 'boss', 엘리트: 'elite', 보너스: 'bonus' };
const KIND_LABEL = { final: '최종보스', boss: '보스', elite: '엘리트', bonus: '보너스' };
function stageKind(s) {
  const t = String(s?.title || '');
  const m = KIND_RE.exec(t);
  if (m) return KIND_OF[m[1]];
  if (s && s.elite) return 'elite';
  if (s && s.boss) return 'boss';
  if (/최종보스/.test(t)) return 'final';
  return '';
}
function stageTitle(s) { return String(s?.title || '').replace(KIND_RE, '').replace(/\s*\(최종보스\)\s*/, '').trim(); }
const isFinalBoss = (s) => stageKind(s) === 'final';
const kindBadge = (k, cls = '') => (k ? `<span class="ui-kindb ui-kindb--${k} ${cls}">${KIND_LABEL[k]}</span>` : '');
const CASE_CHIP = { crime: '형사', rescue: '구조', warn: '계도' };
const caseChip = (ck, cls = '') => (CASE_CHIP[ck] ? `<span class="ui-casechip ui-casechip--${ck} ${cls}">${CASE_CHIP[ck]}</span>` : '');
// 처분 카드: 고지서(기본) · 형사(빨강 '형사 입건') · 표창(금색 '구조 표창') · 계도(회색 '계도장', 범칙금 0)
const CASE_OF = { 고지서: 'fine', 형사: 'crime', 표창: 'rescue', 계도: 'warn' };
const caseKind = (c) => CASE_OF[String(c ?? '').trim()] || 'fine';
const CASE = {
  fine: { stamp: '과태료 고지서', tag: '오늘의 빌런', amt: '범칙금', done: '참교육 완료', seal: ['참교', '육청'] },
  crime: { stamp: '형사 입건', tag: '형사 사건', amt: '벌금', done: '형사 입건', seal: ['입', '건'] },
  rescue: { stamp: '구조 표창', tag: '구조 요청', amt: '', done: '구조 완료', seal: ['표', '창'] },
  warn: { stamp: '계도장', tag: '계도 대상', amt: '', done: '계도 완료', seal: ['계', '도'] },
};
// 큰 금액은 '1,500만원' (형사 벌금은 최대 5천만원), 작은 금액은 '₩40,000'
const bigWon = (n) => { n = Math.max(0, Math.round(num(n))); return n >= 1e6 ? `${kor(n)}원` : won(n); };

// ───────────────────────────── 빌드
function ensure() {
  if (built) return true;
  if (typeof document === 'undefined' || !document.body) return false;
  try { build(); built = true; } catch (e) { console.error('[ui] build failed', e); return false; }
  return true;
}

function build() {
  R = document.getElementById('ui');
  if (!R) { R = el('div'); R.id = 'ui'; document.body.appendChild(R); }
  R.classList.add('ui-root');
  R.textContent = '';
  try {
    const mq = matchMedia('(prefers-reduced-motion: reduce)');
    reduceMotion = mq.matches;
    mq.addEventListener?.('change', (e) => { reduceMotion = e.matches; });
  } catch { /* */ }
  makeRays();
  const onResize = () => { VW = innerWidth || 1280; VH = innerHeight || 720; };
  onResize();
  addEventListener('resize', onResize);

  // 레이어 (DOM 순서 = 아래→위)
  E.vignette = R.appendChild(el('div', 'ui-vignette', '<div class="ui-vignette__pulse"></div>'));
  E.hpVig = R.appendChild(el('div', 'ui-hpvig'));   // v0.4 내구도 위험 맥동 (코어의 분노 vignette 와 별도 레이어)
  E.world = R.appendChild(el('div', 'ui-world'));

  // HUD: 좌상 스테이지 칩
  E.chip = R.appendChild(el('div', 'ui-chip ui-hudpart'));
  // 상단 중앙 스택: 내비 → 원흉 거리 / 보스 바 → 힌트
  E.top = R.appendChild(el('div', 'ui-topstack'));
  buildNav();
  // 원흉 거리 + 잔챙이 칩 (한 줄)
  E.toprow = E.top.appendChild(el('div', 'ui-toprow'));
  E.dist = E.toprow.appendChild(el('div', 'ui-dist ui-hudpart', `<span class="ui-dist__ico">${SVG.angry}</span><span class="ui-dist__l">원흉까지</span><b class="ui-dist__n">0</b><span class="ui-dist__u">m</span>`));
  E.distNum = E.dist.querySelector('.ui-dist__n');
  E.minis = E.toprow.appendChild(el('div', 'ui-minis ui-hudpart',
    `<span class="ui-minis__ico">${SVG.mini}</span><span class="ui-minis__ok">${SVG.check}</span><span class="ui-minis__l">잔챙이</span><b class="ui-minis__n">0</b><span class="ui-minis__t">/0</span>`));
  E.minisN = E.minis.querySelector('.ui-minis__n');
  E.minisT = E.minis.querySelector('.ui-minis__t');
  buildBoss();
  E.hint = E.top.appendChild(el('div', 'ui-hint', '<span class="ui-hint__ico">💡</span><span class="ui-hint__t"></span>'));
  E.hint.hidden = true;
  E.hintText = E.hint.querySelector('.ui-hint__t');
  E.toasts = E.top.appendChild(el('div', 'ui-toasts'));

  // 우상: 점수 + 시스템 버튼
  E.scorebox = R.appendChild(el('div', 'ui-scorebox ui-hudpart', '<span class="ui-scorebox__l">SCORE</span><b class="ui-scorebox__n">0</b>'));
  E.score = E.scorebox.querySelector('.ui-scorebox__n');
  E.combo = R.appendChild(el('div', 'ui-combo', '<b class="ui-combo__n">x2</b><span class="ui-combo__l">COMBO</span>'));
  E.combo.hidden = true;
  E.comboNum = E.combo.querySelector('.ui-combo__n');
  E.sys = R.appendChild(el('div', 'ui-sys ui-hudpart'));
  E.muteBtns = [];
  E.sys.appendChild(makeMuteBtn());
  E.pauseBtn = E.sys.appendChild(btn('ui-btn--round ui-btn--blue ui-btn--sys', SVG.pause, () => call('onPause'), '일시정지'));

  buildSpeedo();
  buildRage();

  // 해방 카운터
  E.rel = R.appendChild(el('div', 'ui-release', '<div class="ui-release__plate"><span class="ui-release__l">해방된 차량</span><span class="ui-release__row"><b class="ui-release__n">0</b><span class="ui-release__u">대</span></span></div>'));
  E.rel.hidden = true;
  E.relNum = E.rel.querySelector('.ui-release__n');

  E.banners = R.appendChild(el('div', 'ui-banners'));
  buildTouch();

  // 화면들
  E.card = R.appendChild(el('div', 'ui-screen ui-card'));
  E.card.hidden = true;
  E.title = R.appendChild(el('div', 'ui-screen ui-title'));
  E.title.hidden = true;
  E.result = R.appendChild(el('div', 'ui-screen ui-result'));
  E.result.hidden = true;
  E.fail = R.appendChild(el('div', 'ui-screen ui-fail'));
  E.fail.hidden = true;
  E.album = R.appendChild(el('div', 'ui-screen ui-album'));
  E.album.hidden = true;
  E.album.addEventListener('click', () => hideAlbum());   // 책 바깥(배경) 탭 = 닫기
  E.shop = R.appendChild(el('div', 'ui-screen ui-shop'));
  E.shop.hidden = true;
  E.shop.addEventListener('click', () => hideShop());     // 패널 바깥(배경) 탭 = 닫기
  buildPause();
  E.flash = R.appendChild(el('div', 'ui-flash'));

  resetCache();
}

// 배너 뒤 회전 광선: 한 번만 비트맵으로 그려 두고 회전은 컴포지터 transform 으로만 (마스크/코닉 매 프레임 래스터 회피)
function makeRays() {
  try {
    const N = 256, cv = document.createElement('canvas');
    cv.width = cv.height = N;
    const g = cv.getContext('2d');
    const grad = g.createRadialGradient(N / 2, N / 2, N * 0.06, N / 2, N / 2, N / 2);
    grad.addColorStop(0, 'rgba(255,230,90,.6)');
    grad.addColorStop(0.55, 'rgba(255,225,77,.32)');
    grad.addColorStop(1, 'rgba(255,225,77,0)');
    g.fillStyle = grad;
    const rays = 20;
    for (let i = 0; i < rays; i++) {
      const a0 = (i / rays) * Math.PI * 2, a1 = a0 + Math.PI / rays;
      g.beginPath(); g.moveTo(N / 2, N / 2); g.arc(N / 2, N / 2, N / 2, a0, a1); g.closePath(); g.fill();
    }
    R.style.setProperty('--ui-rays', `url(${cv.toDataURL('image/png')})`);
  } catch { /* CSS 폴백 사용 */ }
}

function resetCache() {
  Object.assign(C, {
    hud: false, phase: null, speed: -1, fast: null, dist: -1, rage: -1, segF: [-1, -1, -1, -1, -1], rageInit: false, full: null, ready: null,
    score: -1, combo: -1, navP: -1, navR: -1, navDone: null, navFull: null,
    boss: false, bossName: null, hp: -1, lag: 1, lagShown: -1, lastHit: 0, lastBossT: 0, tires: -1,
    rel: null, relShown: 0, vig: -1, muted: null, touch: false, fireMode: null,
    miT: -1, miD: -1, boost: -1, jump: false, jumpCd: -1, rageMode: null,
  });
}

function makeMuteBtn(extra = '') {
  const b = btn('ui-btn--round ui-btn--blue ui-btn--sys ui-mute ' + extra, SVG.speaker, () => call('onToggleMute'), '소리 켜기/끄기');
  E.muteBtns.push(b);
  if (C.muted) { b.classList.add('is-muted'); b.innerHTML = SVG.speakerOff; }
  return b;
}

function buildNav() {
  E.nav = E.top.appendChild(el('div', 'ui-nav ui-hudpart',
    '<div class="ui-nav__track"><div class="ui-nav__jam"></div><div class="ui-nav__green"></div><div class="ui-nav__shine"></div></div>'
    + `<div class="ui-nav__lane"><div class="ui-nav__carpos"><span class="ui-nav__car">${SVG.car}</span></div></div>`
    + `<span class="ui-nav__villain"><span class="ui-nav__face">${SVG.angry}</span><span class="ui-nav__ok">${SVG.check}</span></span>`
    + '<span class="ui-nav__start"></span>'));
  E.navJam = E.nav.querySelector('.ui-nav__jam');
  E.navGreen = E.nav.querySelector('.ui-nav__green');
  E.navCar = E.nav.querySelector('.ui-nav__carpos');
  E.navVillain = E.nav.querySelector('.ui-nav__villain');
  setJamPattern(1);
}

// 카카오내비/T맵 정체 색 띠 (스테이지별 시드). 원흉 쪽(오른쪽)일수록 진한 빨강.
function setJamPattern(seed) {
  if (!E.navJam) return;
  let s = (num(seed, 1) * 9301 + 49297) % 233280;
  const rnd = () => { s = (s * 9301 + 49297) % 233280; return s / 233280; };
  const stops = [];
  let x = 0;
  while (x < 100) {
    const w = 5 + rnd() * 13;
    const t = x / 100;
    const r = rnd();
    const c = t > 0.72 ? (r < 0.6 ? '#c81e16' : '#e8322b') : t < 0.18 ? (r < 0.55 ? '#ff8c1a' : '#e8322b') : (r < 0.5 ? '#e8322b' : r < 0.78 ? '#ff8c1a' : '#c81e16');
    const x2 = Math.min(100, x + w);
    stops.push(`${c} ${x.toFixed(1)}% ${x2.toFixed(1)}%`);
    x = x2;
  }
  E.navJam.style.background = `linear-gradient(90deg, ${stops.join(', ')})`;
}

function buildBoss() {
  E.boss = E.top.appendChild(el('div', 'ui-boss',
    `<div class="ui-boss__plate"><span class="ui-boss__face">${SVG.angry}</span><span class="ui-boss__name"></span></div>`
    + '<div class="ui-boss__bar"><div class="ui-boss__lag"></div><div class="ui-boss__fill"></div><i style="left:25%"></i><i style="left:50%"></i><i style="left:75%"></i></div>'
    + '<div class="ui-boss__tires"></div>'));
  E.boss.hidden = true;
  E.bossName = E.boss.querySelector('.ui-boss__name');
  E.bossFill = E.boss.querySelector('.ui-boss__fill');
  E.bossLag = E.boss.querySelector('.ui-boss__lag');
  const tw = E.boss.querySelector('.ui-boss__tires');
  E.tires = [];
  for (let i = 0; i < 4; i++) {
    const t = tw.appendChild(el('span', 'ui-tire', `<span class="ui-tire__ok">${SVG.tire}</span><span class="ui-tire__flat">${SVG.tireFlat}</span>`));
    E.tires.push(t);
  }
}

function buildSpeedo() {
  // 260° 다이얼. 각도 0 = 12시, 시계방향 +
  const cx = 50, cy = 52, rr = 39;
  const pt = (deg, r = rr) => { const a = (deg - 90) * Math.PI / 180; return [cx + r * Math.cos(a), cy + r * Math.sin(a)]; };
  const arc = (d0, d1, r = rr) => { const [x0, y0] = pt(d0, r), [x1, y1] = pt(d1, r); return `M${x0.toFixed(2)} ${y0.toFixed(2)} A${r} ${r} 0 ${d1 - d0 > 180 ? 1 : 0} 1 ${x1.toFixed(2)} ${y1.toFixed(2)}`; };
  const A0 = -130, A1 = 130, span = A1 - A0;
  let ticks = '';
  for (let i = 0; i <= 8; i++) {
    const d = A0 + span * i / 8;
    const [x0, y0] = pt(d, rr - 8), [x1, y1] = pt(d, rr - (i % 2 ? 12 : 15));
    ticks += `<path d="M${x0.toFixed(2)} ${y0.toFixed(2)}L${x1.toFixed(2)} ${y1.toFixed(2)}" stroke="#fff" stroke-opacity="${i % 2 ? 0.45 : 0.85}" stroke-width="${i % 2 ? 1.6 : 2.4}" stroke-linecap="round"/>`;
  }
  E.speedo = R.appendChild(el('div', 'ui-speedo ui-hudpart',
    `<svg class="ui-speedo__dial" viewBox="0 0 100 100" aria-hidden="true">
      <circle cx="50" cy="50" r="47" fill="#17202b"/>
      <circle cx="50" cy="50" r="43.5" fill="#26303f" stroke="#3b4759" stroke-width="2"/>
      <path d="${arc(A0, A1)}" fill="none" stroke="#11161e" stroke-width="8" stroke-linecap="round"/>
      <path d="${arc(A0, A0 + span * 0.56)}" fill="none" stroke="#3ddc84" stroke-width="5.5" stroke-linecap="round"/>
      <path d="${arc(A0 + span * 0.6, A0 + span * 0.8)}" fill="none" stroke="#ffb400" stroke-width="5.5" stroke-linecap="round"/>
      <path d="${arc(A0 + span * 0.84, A1)}" fill="none" stroke="#ff3b30" stroke-width="5.5" stroke-linecap="round"/>
      ${ticks}
    </svg>
    <div class="ui-speedo__boost"></div><span class="ui-speedo__btag">BOOST</span>
    <div class="ui-speedo__needle"></div><div class="ui-speedo__hub"></div>
    <div class="ui-speedo__read"><b class="ui-speedo__n">0</b><span class="ui-speedo__u">km/h</span></div>`));
  E.speedNum = E.speedo.querySelector('.ui-speedo__n');
  E.needle = E.speedo.querySelector('.ui-speedo__needle');
}

function buildRage() {
  // v0.4: 하단 독 = [범퍼 5칸(내구도)] + [분노 5칸]. 세로/데스크톱은 위아래, 낮은 가로 화면은 좌우.
  E.dock = R.appendChild(el('div', 'ui-dock'));
  buildHP();
  E.rageEl = E.dock.appendChild(el('div', 'ui-rage ui-hudpart',
    `<span class="ui-rage__ico">${SVG.flame}</span>`
    + '<div class="ui-rage__main"><span class="ui-rage__l">분노<em class="ui-rage__key">R 분노의 경적!</em></span><div class="ui-rage__segs">'
    + '<span class="ui-rage__seg"><i></i></span>'.repeat(RAGE_SEGS)
    + '</div></div><b class="ui-rage__max">MAX</b>'));
  E.rageKey = E.rageEl.querySelector('.ui-rage__key');
  E.segs = [...E.rageEl.querySelectorAll('.ui-rage__seg')];
  E.segFill = E.segs.map((s) => s.firstElementChild);
}

// ───────────────────────────── v0.4 내구도 '범퍼 5칸'
// 가설: 내 피가 닳는 게 분노 게이지 바로 위에서 보이면 텔을 읽을 동기가 생긴다 ❓
// 칸 = max/5, 반 칸 단위 (올림: 살아 있으면 최소 반 칸). 칸 상태 data-s = 2(온전) | 1(반 깨짐) | 0(빈 칸)
const HP_SEGS = 5;
const HPS = { on: false, hp: -1, max: -1, halves: -1, n: -1, tier: null, inv: null, invTimer: 0, low: null, dmg: 0, dmgT: 0, dmgEl: null, fx: 0 };
function buildHP() {
  E.hp = E.dock.appendChild(el('div', 'ui-hp ui-hudpart',
    `<span class="ui-hp__ico">${SVG.carFront}</span>`
    + '<div class="ui-hp__main"><span class="ui-hp__l"><span class="ui-hp__lt">범퍼</span><em class="ui-hp__tag"></em><b class="ui-hp__n">0</b></span><div class="ui-hp__cells">'
    + '<span class="ui-hp__cell" data-s="2"><i class="ui-hp__ghost"></i><i class="ui-hp__fill"></i></span>'.repeat(HP_SEGS)
    + '</div></div>'));
  E.hp.setAttribute('role', 'meter');
  E.hp.setAttribute('aria-label', '내구도');
  E.hp.setAttribute('aria-valuemin', '0');
  E.hp.setAttribute('aria-valuemax', '100');
  E.hpCells = [...E.hp.querySelectorAll('.ui-hp__cell')];
  E.hpN = E.hp.querySelector('.ui-hp__n');
  E.hpTag = E.hp.querySelector('.ui-hp__tag');
  E.hpIco = E.hp.querySelector('.ui-hp__ico');
}
function hpOff() {
  if (!HPS.on) return;
  clearTimeout(HPS.invTimer);
  Object.assign(HPS, { on: false, hp: -1, max: -1, halves: -1, n: -1, tier: null, inv: null, low: null, dmg: 0 });
  E.hp.classList.remove('is-on', 'is-warn', 'is-danger', 'is-inv', 'is-dead');
  E.hpVig.classList.remove('is-on');
}
function setHP(s) {
  if (s == null || typeof s !== 'object') { hpOff(); return; }
  const max = 'max' in s ? num(s.max, NaN) : (HPS.max > 0 ? HPS.max : 100);
  if (!(max > 0)) { hpOff(); return; }
  let hp = num(s.hp, NaN);
  if (!Number.isFinite(hp)) { if (!HPS.on) return; hp = HPS.hp; }   // hp 없이 invuln 만 바꾸는 호출 허용
  hp = clamp(hp, 0, max);
  const first = !HPS.on;
  if (first) { HPS.on = true; E.hp.classList.add('is-on'); }
  const prevHp = HPS.hp, prevHalves = HPS.halves, sameMax = HPS.max === max;
  const ratio = hp / max;
  const halves = hp <= 0 ? 0 : clamp(Math.ceil(ratio * HP_SEGS * 2 - 1e-6), 1, HP_SEGS * 2);
  if (halves !== HPS.halves) {
    HPS.halves = halves;
    E.hpCells.forEach((c, i) => { const st = String(clamp(halves - i * 2, 0, 2)); if (c.dataset.s !== st) c.dataset.s = st; });
    E.hp.setAttribute('aria-valuenow', String(Math.round(ratio * 100)));
  }
  const n = hp > 0 ? Math.max(1, Math.round(hp)) : 0;
  if (n !== HPS.n) { HPS.n = n; E.hpN.textContent = n; }
  // 주의(≤ 2칸) · 위험(≤ 1칸) — 표시 칸과 같은 기준
  const tier = hp <= 0 ? 'dead' : ratio <= 0.2 + 1e-9 ? 'danger' : ratio <= 0.4 + 1e-9 ? 'warn' : 'ok';
  if (tier !== HPS.tier) {
    const was = HPS.tier;
    HPS.tier = tier;
    E.hp.classList.toggle('is-warn', tier === 'warn');
    E.hp.classList.toggle('is-danger', tier === 'danger' || tier === 'dead');
    E.hp.classList.toggle('is-dead', tier === 'dead');
    E.hpTag.textContent = tier === 'warn' ? '주의' : tier === 'danger' ? '위험!' : tier === 'dead' ? '견인' : '';
    if (was && was !== 'ok' && tier !== 'ok' && was !== tier) bump(E.hpTag, 'hpTag', 0, KF.bigBump, 300);
  }
  // 값이 줄 때만 피격 연출 (첫 호출 · 최대치 변경 = 연출 없음)
  if (!first && sameMax && prevHp >= 0 && hp < prevHp - 1e-6) hpHit(prevHalves, halves, prevHp - hp);
  HPS.hp = hp; HPS.max = max;
  // 무적 깜빡임: true = 1초(계속 true 로 부르면 연장), 숫자 = 그 초만큼, false = 즉시 끔, 생략 = 그대로
  if ('invuln' in s) {
    const v = s.invuln;
    const sec = v === true ? 1 : typeof v === 'number' && v > 0 ? Math.min(5, v) : 0;
    clearTimeout(HPS.invTimer);
    if (sec > 0 && hp > 0) HPS.invTimer = setTimeout(() => { HPS.inv = false; E.hp.classList.remove('is-inv'); }, sec * 1000);
    const inv = sec > 0 && hp > 0;
    if (inv !== HPS.inv) { HPS.inv = inv; E.hp.classList.toggle('is-inv', inv); }
  }
  const low = s.lowFx === true || (s.lowFx !== false && (tier === 'danger' || tier === 'dead'));
  if (low !== HPS.low) { HPS.low = low; E.hpVig.classList.toggle('is-on', low); }
}
KF.hpCell = [
  { transform: 'none', filter: 'none' },
  { transform: 'translate(-2px,-3px) scale(1.3) rotate(-8deg)', filter: 'brightness(2.2) saturate(1.6)', offset: 0.14 },
  { transform: 'translate(3px,1px) scale(1.12) rotate(6deg)', filter: 'brightness(1.4)', offset: 0.34 },
  { transform: 'translate(-2px,0) rotate(-3deg)', offset: 0.56 },
  { transform: 'translate(1px,0) rotate(1deg)', offset: 0.78 },
  { transform: 'none', filter: 'none' },
];
KF.hpIco = [{ transform: 'none' }, { transform: 'scale(1.25) rotate(-14deg)', filter: 'brightness(1.6) sepia(1) saturate(6) hue-rotate(-30deg)', offset: 0.2 }, { transform: 'rotate(8deg)', offset: 0.5 }, { transform: 'none', filter: 'none' }];
const HP_FX_MAX = 36;
function hpFx(node, kf, opt) {
  if (HPS.fx >= HP_FX_MAX) { node.remove(); return; }
  HPS.fx++;
  E.hp.appendChild(node);
  const a = anim(node, kf, opt);
  let over = false;
  const done = () => { if (over) return; over = true; HPS.fx--; node.remove(); };
  if (a) a.onfinish = a.oncancel = done; else done();
}
function hpHit(prevHalves, halves, dmg) {
  bump(E.hp, 'hpShake', 60, KF.shake, 320);
  anim(E.hpIco, KF.hpIco, { duration: 420, easing: 'ease-out' });
  if (reduceMotion) return;
  // 깎인 칸 (같은 반 칸 안의 작은 피해면 경계 칸만 살짝)
  const hit = [];
  for (let i = 0; i < HP_SEGS; i++) if (clamp(halves - i * 2, 0, 2) < clamp(prevHalves - i * 2, 0, 2)) hit.push(i);
  const soft = !hit.length;
  if (soft) hit.push(clamp(Math.ceil(halves / 2) - 1, 0, HP_SEGS - 1));
  for (const i of hit) {
    const c = E.hpCells[i];
    anim(c, KF.hpCell, { duration: soft ? 300 : 460, easing: 'ease-out' });
    if (soft) continue;
    const x = c.offsetLeft + c.offsetWidth * (halves - i * 2 >= 1 ? 0.75 : 0.5), y = c.offsetTop + c.offsetHeight / 2;
    // 빨간 폭발 링 + 범퍼 파편
    const ring = el('i', 'ui-hp__boom');
    ring.style.left = x + 'px'; ring.style.top = y + 'px';
    hpFx(ring, [{ transform: 'translate(-50%,-50%) scale(.3)', opacity: 1 }, { transform: 'translate(-50%,-50%) scale(1.5)', opacity: 0.9, offset: 0.35 }, { transform: 'translate(-50%,-50%) scale(2.1)', opacity: 0 }], { duration: 420, easing: 'ease-out' });
    for (let k = 0; k < 5; k++) {
      const sh = el('i', 'ui-hp__shard' + (k % 2 ? ' is-red' : ''));
      sh.style.left = x + 'px'; sh.style.top = y + 'px';
      const a = (-160 + 140 * (k / 4) + (Math.random() - 0.5) * 30) * Math.PI / 180, d = 22 + Math.random() * 18, r = (Math.random() - 0.5) * 540;
      const dx = Math.cos(a) * d, dy = Math.sin(a) * d;
      hpFx(sh, [{ transform: 'translate(-50%,-50%) rotate(0deg) scale(1)', opacity: 1 }, { transform: `translate(calc(-50% + ${dx.toFixed(1)}px), calc(-50% + ${dy.toFixed(1)}px)) rotate(${r.toFixed(0)}deg) scale(.9)`, opacity: 1, offset: 0.55 }, { transform: `translate(calc(-50% + ${(dx * 1.2).toFixed(1)}px), calc(-50% + ${(dy + 26).toFixed(1)}px)) rotate(${(r * 1.4).toFixed(0)}deg) scale(.6)`, opacity: 0 }], { duration: 560 + k * 30, easing: 'cubic-bezier(.2,.7,.4,1)' });
    }
  }
  // −N 숫자 (0.5초 안의 연타는 합산)
  const t = now();
  HPS.dmg = t - HPS.dmgT < 500 && HPS.dmgEl && HPS.dmgEl.isConnected ? HPS.dmg + dmg : dmg;
  HPS.dmgT = t;
  const txt = '−' + Math.max(1, Math.round(HPS.dmg));
  if (HPS.dmgEl && HPS.dmgEl.isConnected) HPS.dmgEl.remove();
  const de = el('b', 'ui-hp__dmg');
  de.textContent = txt;
  HPS.dmgEl = de;
  hpFx(de, [{ transform: 'translate(-50%,0) scale(.4)', opacity: 0 }, { transform: 'translate(-50%,-14px) scale(1.25)', opacity: 1, offset: 0.18 }, { transform: 'translate(-50%,-20px) scale(1)', opacity: 1, offset: 0.7 }, { transform: 'translate(-50%,-30px) scale(.9)', opacity: 0 }], { duration: 900, easing: 'ease-out' });
}

// ───────────────────────────── 터치 컨트롤
const touchBtns = [];
function buildTouch() {
  E.touch = R.appendChild(el('div', 'ui-touch'));
  E.touch.hidden = true;
  const mk = (name, cls, inner, label) => {
    const b = el('button', 'ui-tbtn ' + cls, inner);
    b.type = 'button';
    b.setAttribute('aria-label', label);
    const st = { ids: new Set() };
    const down = (e) => {
      if (e.pointerType === 'mouse' && e.button !== 0) return;
      e.preventDefault();
      try { b.setPointerCapture(e.pointerId); } catch { /* */ }
      if (st.ids.has(e.pointerId)) return;
      st.ids.add(e.pointerId);
      if (st.ids.size === 1) { b.classList.add('is-down'); call('onControl', name, true); }
    };
    const up = (e) => {
      if (!st.ids.has(e.pointerId)) return;
      st.ids.delete(e.pointerId);
      if (st.ids.size === 0) { b.classList.remove('is-down'); call('onControl', name, false); }
    };
    b.addEventListener('pointerdown', down);
    b.addEventListener('pointerup', up);
    b.addEventListener('pointercancel', up);
    b.addEventListener('lostpointercapture', up);
    b.addEventListener('contextmenu', (e) => e.preventDefault());
    b.addEventListener('mousedown', (e) => e.preventDefault());
    touchBtns.push({ b, st, name });
    return E.touch.appendChild(b);
  };
  mk('left', 'ui-tbtn--left', SVG.left, '왼쪽 차선');
  mk('right', 'ui-tbtn--right', SVG.right, '오른쪽 차선');
  E.tSuper = mk('super', 'ui-tbtn--super', `<span class="ui-tbtn__ico">${SVG.flame}</span><span class="ui-tbtn__t">분노</span>`, '분노 미사일');
  E.tFire = mk('fire', 'ui-tbtn--fire', `<span class="ui-tbtn__ico">${SVG.horn}</span><span class="ui-tbtn__t">경적</span>`, '발사 / 경적');
  E.tFireIco = E.tFire.querySelector('.ui-tbtn__ico');
  E.tFireTxt = E.tFire.querySelector('.ui-tbtn__t');
  // 참교육 점프 (차고에서 구매 시 setControls({ jump: true }))
  E.tJump = mk('jump', 'ui-tbtn--jump', `<span class="ui-tbtn__ico">${SVG.jump}</span><span class="ui-tbtn__t">점프</span>`, '점프');
}
function releaseTouch(only) {
  for (const t of touchBtns) {
    if (only && t.name !== only) continue;
    if (t.st.ids.size) { t.st.ids.clear(); t.b.classList.remove('is-down'); call('onControl', t.name, false); }
  }
}
// 추가 터치 버튼 on/off. c = { jump?: boolean, jumpCd?: 0..1 (남은 쿨다운 비율, 0 = 준비) }
function setControls(c) {
  c = c && typeof c === 'object' ? c : {};
  if ('jump' in c) {
    const on = !!c.jump;
    if (on !== C.jump) {
      C.jump = on;
      if (!on) releaseTouch('jump');
      E.touch.classList.toggle('has-jump', on);
    }
  }
  if ('jumpCd' in c) {
    const cd = q(clamp(num(c.jumpCd), 0, 1), 40);
    if (cd !== C.jumpCd) {
      const was = C.jumpCd;
      C.jumpCd = cd;
      E.tJump.style.setProperty('--cd', cd);
      E.tJump.classList.toggle('is-cd', cd > 0);
      if (cd === 0 && was > 0) bump(E.tJump, 'jumpReady', 0, KF.bump, 260);
    }
  }
}

function buildPause() {
  E.pause = R.appendChild(el('div', 'ui-screen ui-pause',
    '<div class="ui-pause__panel"><div class="ui-pause__plate"><span class="ui-pause__ico"></span>일시정지</div><p class="ui-pause__sub">잠깐 쉬어가요. 원흉은 기다려 줍니다.</p><div class="ui-pause__btns"></div></div>'));
  E.pause.hidden = true;
  E.pause.querySelector('.ui-pause__ico').innerHTML = SVG.pause;
  const bw = E.pause.querySelector('.ui-pause__btns');
  bw.appendChild(btn('ui-btn--yellow ui-btn--lg', `<span class="ui-btn__ico">${SVG.play}</span>계속하기`, () => call('onPause')));
  bw.appendChild(btn('ui-btn--grey', '메뉴로', () => { call('onPause'); call('onMenu'); }));
}

// ───────────────────────────── HUD 표시
function setHudOn(on) {
  if (C.hud === on) return;
  C.hud = on;
  R.classList.toggle('ui-root--hud', on);
  if (!on) { setShown(E.combo, false); C.combo = -1; }
}
function setStage(stage) {
  if (!stage) return;
  C.stage = stage;
  E.chip.innerHTML = `${shieldHTML(stage.route, 'ui-shield--chip')}<span class="ui-chip__txt"><b class="ui-chip__hw">${esc(stage.highway)}</b><span class="ui-chip__dir">${esc(stage.direction)}</span></span>`;
  setJamPattern(stage.id || 1);
}
function setFireMode(mode) {
  if (C.fireMode === mode) return;
  C.fireMode = mode;
  if (!E.tFire) return;
  const horn = mode === 'horn';
  E.tFireIco.innerHTML = horn ? SVG.horn : SVG.tack;
  E.tFireTxt.textContent = horn ? '경적' : '발사';
  E.tFire.classList.toggle('is-horn', horn);
}

const RAGE_KEY = { horn: ['R 분노의 경적!', '분노의 경적'], bomb: ['R 분노 폭탄!', '분노 폭탄'], siren: ['R 사이렌 대경적!', '사이렌 대경적'] };
function setHUD(s) {
  s = s || {};
  if (isShown(E.card)) finishCard();
  setHudOn(true);
  const phase = String(s.phase || 'jam');
  if (phase !== C.phase) {
    C.phase = phase;
    R.dataset.phase = phase;
    setFireMode(phase === 'jam' ? 'horn' : 'fire');
  }
  // 분노 1칸 안내: core 가 넘기는 rageMode 우선 (원흉 뒤 갓길에선 boss 단계여도 아직 '분노의 경적'), 없으면 단계로 추정
  const rm = ['horn', 'bomb', 'siren'].includes(s.rageMode) ? s.rageMode : (phase === 'boss' ? 'bomb' : 'horn');
  if (rm !== C.rageMode) {
    C.rageMode = rm;
    E.rageKey.textContent = RAGE_KEY[rm][0];
    E.tSuper.setAttribute('aria-label', RAGE_KEY[rm][1]);
    E.rageEl.dataset.mode = rm;
  }
  // 부스트 링 (분노의 경적 직후 가속) 0..1
  const bt = q(clamp(num(s.boostT), 0, 1), 20);
  if (bt !== C.boost) {
    const was = C.boost;
    C.boost = bt;
    E.speedo.style.setProperty('--boost', bt);
    E.speedo.classList.toggle('is-boost', bt > 0);
    if (bt > 0 && !(was > 0)) bump(E.speedo, 'boost', 0, KF.bigBump, 300);
  }
  // 잔챙이 빌런 칩
  const mi = s.minis && typeof s.minis === 'object' ? s.minis : null;
  const mt = mi ? Math.max(0, Math.round(num(mi.total))) : 0;
  const md = mt ? clamp(Math.round(num(mi.done)), 0, mt) : 0;
  if (mt !== C.miT || md !== C.miD) {
    const up = mt > 0 && mt === C.miT && md > C.miD;
    C.miT = mt; C.miD = md;
    const on = mt > 0;
    E.toprow.classList.toggle('has-minis', on);
    E.minis.classList.toggle('is-on', on);
    if (on) {
      E.minisN.textContent = md;
      E.minisT.textContent = '/' + mt;
      const done = md >= mt;
      E.minis.classList.toggle('is-done', done);
      if (up) bump(E.minis, 'minis', 0, done ? KF.segPulse : KF.bigBump, done ? 460 : 260);
    }
  }
  // 속도계
  const sp = Math.max(0, Math.round(num(s.speedKmh)));
  if (sp !== C.speed) {
    C.speed = sp;
    E.speedNum.textContent = sp;
    E.needle.style.transform = `translate(-50%, -100%) rotate(${(-130 + 260 * Math.min(1, sp / 160)).toFixed(1)}deg)`;
    const fast = sp >= 100;
    if (fast !== C.fast) { C.fast = fast; E.speedo.classList.toggle('is-fast', fast); }
  }
  // 원흉까지 거리 (jam 에서만 CSS 로 보임)
  if (phase === 'jam') {
    const d = Math.max(0, Math.round(num(s.distM)));
    if (d !== C.dist) { C.dist = d; E.distNum.textContent = fmt(d); }
  }
  // 분노 RAGE_SEGS 칸
  const rq = q(clamp(num(s.rage), 0, 1), 300);
  if (rq !== C.rage) {
    const prev = C.rageInit ? Math.floor(C.rage * RAGE_SEGS + 1e-6) : 99;
    C.rage = rq;
    C.rageInit = true;
    for (let i = 0; i < RAGE_SEGS; i++) {
      const f = q(clamp(rq * RAGE_SEGS - i, 0, 1), 100);
      if (f !== C.segF[i]) {
        C.segF[i] = f;
        E.segFill[i].style.transform = `scaleX(${f})`;
        E.segs[i].classList.toggle('is-on', f >= 1);
      }
    }
    const segs = Math.floor(rq * RAGE_SEGS + 1e-6);
    if (segs > prev && segs >= 1) {
      anim(E.segs[segs - 1], KF.segPulse, { duration: 420, easing: 'cubic-bezier(.3,1.6,.5,1)' });
      bump(E.rageEl.querySelector('.ui-rage__ico'), 'rageico', 0, KF.bump, 380);
    }
    const full = rq >= 0.999;
    if (full !== C.full) { C.full = full; E.rageEl.classList.toggle('is-full', full); }
    const ready = segs >= 1;
    if (ready !== C.ready) { C.ready = ready; E.rageEl.classList.toggle('is-ready', ready); E.tSuper.classList.toggle('is-ready', ready); }
  }
  // 점수
  const sc = Math.max(0, Math.round(num(s.score)));
  if (sc !== C.score) {
    const up = C.score >= 0 && sc > C.score;
    C.score = sc;
    E.score.textContent = fmt(sc);
    if (up) bump(E.score, 'score', 140, KF.bump, 200);
  }
  // 콤보
  const cb = Math.max(0, Math.round(num(s.combo)));
  if (cb !== C.combo) {
    const prev = C.combo;
    C.combo = cb;
    if (cb >= 2) {
      E.comboNum.textContent = 'x' + cb;
      setShown(E.combo, true);
      E.combo.classList.toggle('is-hot', cb >= 20);
      if (cb > prev) bump(E.combo, 'combo', 60, KF.bigBump, 200);
    } else if (prev >= 2) {
      setShown(E.combo, false, 320);
    }
  }
}

function setNav(n) {
  n = n || {};
  const p = q(clamp(num(n.progress), 0, 1), 1000);
  if (p !== C.navP) { C.navP = p; E.navCar.style.transform = `translateX(${(p * 100).toFixed(1)}%)`; }
  const r = q(clamp(num(n.released), 0, 1), 1000);
  if (r !== C.navR) {
    C.navR = r;
    E.navGreen.style.transform = `scaleX(${r})`;
    const done = r > 0;
    if (done !== C.navDone) { C.navDone = done; E.nav.classList.toggle('is-freed', done); }
    const full = r >= 1;
    if (full !== C.navFull) { C.navFull = full; E.nav.classList.toggle('is-clear', full); }
  }
}

function showBoss(b) {
  b = b || {};
  const t = now();
  const hp = q(clamp(num(b.hp, 1), 0, 1), 1000);
  if (!C.boss) {
    C.boss = true;
    C.hp = hp; C.lag = hp; C.lagShown = -1; C.tires = -1; C.lastBossT = t; C.lastHit = 0;
    E.bossFill.style.transform = `scaleX(${hp})`;
    setShown(E.boss, true);
  }
  const name = String(b.name ?? '');
  if (name !== C.bossName) { C.bossName = name; E.bossName.textContent = name; }
  if (hp !== C.hp) {
    if (hp < C.hp) {
      C.lastHit = t;
      bump(E.boss, 'bossShake', 140, KF.shake, 180);
    }
    C.hp = hp;
    E.bossFill.style.transform = `scaleX(${hp})`;
    E.boss.classList.toggle('is-low', hp <= 0.25);
  }
  // 흰색 데미지 잔상 (연타 중엔 버티다가 쭉 빠짐)
  const dt = Math.min(0.1, Math.max(0, (t - C.lastBossT) / 1000));
  C.lastBossT = t;
  if (C.lag > C.hp) {
    if (t - C.lastHit > 420) C.lag = Math.max(C.hp, C.lag - dt * (0.25 + (C.lag - C.hp) * 4));
    else C.lag = Math.max(C.hp, C.lag - dt * 0.04);
  } else C.lag = C.hp;
  const lq = q(C.lag, 500);
  if (lq !== C.lagShown) { C.lagShown = lq; E.bossLag.style.transform = `scaleX(${lq})`; }
  // 타이어
  const tires = clamp(Math.round(num(b.tires, 4)), 0, 4);
  if (tires !== C.tires) {
    const prev = C.tires;
    C.tires = tires;
    E.tires.forEach((node, i) => {
      const popped = i >= tires;
      if (node.classList.contains('is-popped') !== popped) {
        node.classList.toggle('is-popped', popped);
        if (popped && prev >= 0) anim(node, KF.tirePop, { duration: 460, easing: 'cubic-bezier(.3,1.5,.5,1)' });
      }
    });
  }
}
function hideBoss() {
  if (!C.boss) return;
  C.boss = false;
  setShown(E.boss, false, 320);
}

// ───────────────────────────── 말풍선 (키별 노드 재사용)
const bubbles = new Map();
const bubblePool = [];
const BUBBLE_MAX = 24;
function takeBubble() {
  let b = bubblePool.pop();
  if (!b) {
    const node = el('div', 'ui-bubble');
    node.innerHTML = '<div class="ui-bubble__a"><div class="ui-bubble__shift"><div class="ui-bubble__body"></div></div><i class="ui-bubble__tail"></i></div>';
    b = { el: node, a: node.firstChild, shift: node.querySelector('.ui-bubble__shift'), body: node.querySelector('.ui-bubble__body') };
    E.world.appendChild(node);
  }
  Object.assign(b, { text: null, kind: null, x: NaN, y: NaN, w: 0, dx: NaN, removing: false, timer: 0 });
  b.el.classList.remove('is-out');
  b.el.hidden = false;
  return b;
}
function freeBubble(key, b) {
  clearTimeout(b.timer);
  b.el.hidden = true;
  bubbles.delete(key);
  if (bubblePool.length < BUBBLE_MAX) bubblePool.push(b); else b.el.remove();
}
function bubble(key, x, y, text, kind = 'taunt') {
  key = String(key);
  x = num(x, NaN); y = num(y, NaN);
  if (!Number.isFinite(x) || !Number.isFinite(y)) return;
  let b = bubbles.get(key);
  let fresh = false;
  if (!b) {
    if (bubbles.size >= BUBBLE_MAX) return;
    b = takeBubble();
    bubbles.set(key, b);
    fresh = true;
  } else if (b.removing) {
    b.removing = false;
    clearTimeout(b.timer);
    b.el.classList.remove('is-out');
  }
  kind = String(kind || 'taunt');
  if (kind !== b.kind) { b.kind = kind; b.el.className = 'ui-bubble ui-bubble--' + kind; }
  text = String(text ?? '');
  if (text !== b.text) {
    const had = b.text != null;
    b.text = text;
    b.body.textContent = text;
    b.w = b.body.offsetWidth || text.length * 15;
    b.dx = NaN;
    if (fresh || had) anim(b.a, [{ transform: 'scale(.2)', opacity: 0 }, { transform: 'scale(1.12)', opacity: 1, offset: 0.6 }, { transform: 'scale(1)' }], { duration: 260, easing: 'ease-out' });
  }
  const rx = Math.round(x), ry = Math.round(y);
  if (rx !== b.x || ry !== b.y) {
    b.x = rx; b.y = ry;
    b.el.style.transform = `translate3d(${rx}px,${ry}px,0)`;
    b.el.style.zIndex = Math.max(1, ry | 0); // 가까운(아래쪽) 차의 말풍선이 위로
  }
  // 화면 밖으로 잘리지 않게 몸통만 옆으로 밀기 (꼬리는 그대로 x 를 가리킴)
  const half = b.w / 2;
  const cx = clamp(rx, 8 + half, Math.max(8 + half, VW - 8 - half));
  const dx = Math.round(cx - rx);
  if (dx !== b.dx) { b.dx = dx; b.shift.style.transform = `translateX(calc(-50% + ${dx}px))`; }
}
function removeBubble(key) {
  key = String(key);
  const b = bubbles.get(key);
  if (!b || b.removing) return;
  if (reduceMotion) { freeBubble(key, b); return; }
  b.removing = true;
  b.el.classList.add('is-out');
  b.timer = setTimeout(() => { if (b.removing && bubbles.get(key) === b) freeBubble(key, b); }, 170);
}
function clearBubbles() {
  for (const [k, b] of [...bubbles]) freeBubble(k, b);
}

// ───────────────────────────── 떠오르는 텍스트 (풀 40개, WAAPI)
const POP_N = 40;
const pops = [];
let popI = 0;
const POP_STYLE = {
  hit: { fs: 22, dur: 640, rise: 46, s0: 0.5, s1: 1.25, rot: 0 },
  crit: { fs: 32, dur: 1000, rise: 64, s0: 0.3, s1: 1.45, rot: 7 },
  bump: { fs: 34, dur: 760, rise: 40, s0: 0.4, s1: 1.4, rot: 12 },
  score: { fs: 26, dur: 900, rise: 60, s0: 0.5, s1: 1.25, rot: 0 },
  warn: { fs: 26, dur: 820, rise: 50, s0: 0.4, s1: 1.3, rot: 5 },
};
function popText(x, y, text, kind = 'hit') {
  x = num(x, NaN); y = num(y, NaN);
  if (!Number.isFinite(x) || !Number.isFinite(y)) return;
  kind = POP_STYLE[kind] ? kind : 'hit';
  let p = pops[popI];
  if (!p) { p = { el: E.world.appendChild(el('div', 'ui-pop')), text: null, kind: null, a: null }; pops[popI] = p; }
  popI = (popI + 1) % POP_N;
  if (p.a) { try { p.a.cancel(); } catch { /* */ } p.a = null; }
  text = String(text ?? '');
  if (p.kind !== kind) { p.kind = kind; p.el.className = 'ui-pop ui-pop--' + kind; }
  if (p.text !== text) { p.text = text; p.el.textContent = text; }
  const st = POP_STYLE[kind];
  const small = VW < 640 ? 0.8 : 1;
  const estW = text.length * st.fs * small * 0.95 * st.s1;
  const jx = kind === 'hit' ? (Math.random() - 0.5) * 34 : 0;
  const cx = clamp(x + jx, 8 + estW / 2, Math.max(8 + estW / 2, VW - 8 - estW / 2));
  const cy = clamp(y, 30, VH - 20);
  const rot = (Math.random() < 0.5 ? -1 : 1) * st.rot * Math.random();
  const T = (dy, s, r = rot) => `translate3d(${cx.toFixed(1)}px,${(cy + dy).toFixed(1)}px,0) translate(-50%,-50%) rotate(${r.toFixed(1)}deg) scale(${s})`;
  p.el.hidden = false;
  if (!p.el.animate || reduceMotion) {
    p.el.style.transform = T(-st.rise * 0.4, 1);
    p.el.style.opacity = 1;
    const ref = p;
    clearTimeout(p.t);
    p.t = setTimeout(() => { ref.el.hidden = true; }, reduceMotion ? 700 : st.dur);
    return;
  }
  p.el.style.opacity = '';
  p.a = p.el.animate([
    { transform: T(0, st.s0), opacity: 0 },
    { transform: T(-st.rise * 0.18, st.s1), opacity: 1, offset: 0.14 },
    { transform: T(-st.rise * 0.3, 1), opacity: 1, offset: 0.3 },
    { transform: T(-st.rise * 0.7, 1), opacity: 1, offset: 0.72 },
    { transform: T(-st.rise, 0.86), opacity: 0 },
  ], { duration: st.dur, easing: 'linear', fill: 'both' });
  const ref = p, a = p.a;
  a.onfinish = () => { if (ref.a === a) { ref.a = null; ref.el.hidden = true; } };
}

// ───────────────────────────── 배너 (같은 프레임에 연달아 오면 줄 세움)
const BQ = { cur: null, queue: [] };
function banner(text, kind = 'big', ms = 1600) {
  kind = ['big', 'warn', 'go', 'boss'].includes(kind) ? kind : 'big';
  ms = clamp(num(ms, 1600), 300, 10000);
  const t = now();
  const cur = BQ.cur;
  if (cur && t - cur.start < 350) {
    // 연출 버스트 ("참교육 완료!" → "뻥 뚫렸다!!"): 앞의 것을 짧게 보여주고 바로 이어서
    if (BQ.queue.length < 3) BQ.queue.push({ text, kind, ms });
    const cut = Math.max(0, cur.start + Math.min(cur.ms, 900) - t);
    clearTimeout(cur.timer);
    cur.timer = setTimeout(() => endBanner(cur), cut);
    return;
  }
  BQ.queue.length = 0;
  if (cur) endBanner(cur, true);
  startBanner(text, kind, ms);
}
function startBanner(text, kind, ms) {
  const node = el('div', `ui-banner ui-banner--${kind}`);
  const inner = el('div', 'ui-banner__in');
  if (kind === 'big') inner.appendChild(el('div', 'ui-banner__rays'));
  if (kind === 'boss') inner.appendChild(el('div', 'ui-banner__stripes'));
  const tx = inner.appendChild(el('div', 'ui-banner__t'));
  tx.textContent = String(text ?? '');
  node.appendChild(inner);
  E.banners.appendChild(node);
  const b = { node, start: now(), ms, timer: 0 };
  b.timer = setTimeout(() => endBanner(b), ms);
  BQ.cur = b;
}
function endBanner(b, immediate = false) {
  if (!b || b.done) return;
  b.done = true;
  clearTimeout(b.timer);
  b.node.classList.add('is-out');
  setTimeout(() => b.node.remove(), immediate || reduceMotion ? 120 : 300);
  if (BQ.cur === b) {
    BQ.cur = null;
    if (!immediate) {
      const nx = BQ.queue.shift();
      if (nx) startBanner(nx.text, nx.kind, nx.ms);
    }
  }
}

// ───────────────────────────── 해방 카운터 (목표값까지 째깍째깍 올라감)
let relRaf = 0;
function setReleaseCounter(n) {
  if (n == null || !Number.isFinite(+n)) {
    if (C.rel != null) { C.rel = null; setShown(E.rel, false, 360); }
    cancelAnimationFrame(relRaf); relRaf = 0;
    return;
  }
  n = Math.max(0, Math.round(+n));
  if (C.rel == null) {
    // 숨김 → 표시: 0 부터 째깍째깍 올라가게 (퇴장 애니 중에 다시 켜진 경우도 0 부터)
    C.relShown = 0;
    E.relNum.textContent = '0';
    setShown(E.rel, true);
  } else if (n > C.rel) bump(E.relNum, 'rel', 90, KF.bigBump, 180);
  C.rel = n;
  if (!relRaf) relRaf = requestAnimationFrame(tickRel);
}
let relLast = 0;
function tickRel(t) {
  relRaf = 0;
  if (C.rel == null) return;
  const dt = relLast ? Math.min(0.1, (t - relLast) / 1000) : 0.016;
  relLast = t;
  const target = C.rel;
  let v = C.relShown;
  if (v !== target) {
    const step = Math.max(1, Math.abs(target - v) * Math.min(1, dt * 9));
    v = v < target ? Math.min(target, Math.ceil(v + step)) : Math.max(target, Math.floor(v - step));
    C.relShown = v;
    E.relNum.textContent = fmt(v);
    relRaf = requestAnimationFrame(tickRel);
  } else relLast = 0;
}

// ───────────────────────────── 플래시 / 비네트
let flashA = null;
function flash(color = '#fff', ms = 120) {
  ms = clamp(num(ms, 120), 30, 3000);
  const f = E.flash;
  f.style.background = String(color || '#fff');
  if (flashA) { try { flashA.cancel(); } catch { /* */ } flashA = null; }
  const peak = reduceMotion ? 0.3 : 0.75;
  if (f.animate) {
    flashA = f.animate([{ opacity: peak }, { opacity: peak * 0.8, offset: 0.25 }, { opacity: 0 }], { duration: ms * 1.8 + 60, easing: 'ease-out' });
  } else {
    f.style.opacity = peak;
    setTimeout(() => { f.style.opacity = 0; }, ms);
  }
}
function vignette(amount) {
  const v = q(clamp(num(amount), 0, 1), 50);
  if (v === C.vig) return;
  C.vig = v;
  E.vignette.style.opacity = v;
  E.vignette.classList.toggle('is-hot', v >= 0.22);
}

// ───────────────────────────── 힌트 토스트
let hintT = 0;
function hint(text, ms = 2600) {
  text = String(text ?? '');
  if (!text) { setShown(E.hint, false); return; }
  ms = clamp(num(ms, 2600), 400, 20000);
  const was = isShown(E.hint);
  E.hintText.textContent = text;
  setShown(E.hint, true);
  if (was) bump(E.hint, 'hint', 0, KF.bump, 240);
  clearTimeout(hintT);
  hintT = setTimeout(() => setShown(E.hint, false, 260), ms);
}

// ───────────────────────────── v0.4 토스트 (짧은 상단 알림: '또 빵? (경적 피로)', '틈 없음', '레커 출동!')
// 힌트(💡 길게)와 달리 짧고 자주 뜬다. 최대 3개, 같은 문구는 새로 쌓지 않고 '×2' 로 합친다.
const TOAST_ICO = { warn: () => SVG.warnTri, info: () => SVG.info, good: () => SVG.check };
const TQ = [];
function dropToast(t, fast = false) {
  if (!t || t.out) return;
  t.out = true;
  clearTimeout(t.timer);
  t.node.classList.add('is-out');
  setTimeout(() => { t.node.remove(); const i = TQ.indexOf(t); if (i >= 0) TQ.splice(i, 1); }, fast || reduceMotion ? 100 : 240);
}
function toast(text, kind = 'info', ms) {
  text = typeof text === 'string' || typeof text === 'number' ? String(text).trim().slice(0, 80) : '';
  if (!text) return;
  kind = TOAST_ICO[kind] ? kind : 'info';
  ms = clamp(num(ms, kind === 'warn' ? 1900 : 1600), 500, 10000);
  const same = TQ.find((t) => !t.out && t.text === text && t.kind === kind);
  if (same) {
    same.n++;
    same.cnt.textContent = '×' + same.n;
    same.cnt.hidden = false;
    bump(same.node, 'toast' + text, 0, KF.bigBump, 240);
    clearTimeout(same.timer);
    same.timer = setTimeout(() => dropToast(same), ms);
    return;
  }
  const live = TQ.filter((t) => !t.out);
  while (live.length >= 3) dropToast(live.shift(), true);
  const node = el('div', `ui-toast ui-toast--${kind} is-in`, `<span class="ui-toast__ico">${TOAST_ICO[kind]()}</span><span class="ui-toast__t"></span><b class="ui-toast__n" hidden></b>`);
  node.querySelector('.ui-toast__t').textContent = text;
  node.setAttribute('role', 'status');
  E.toasts.prepend(node);
  const t = { node, text, kind, n: 1, cnt: node.querySelector('.ui-toast__n'), out: false, timer: 0 };
  t.timer = setTimeout(() => dropToast(t), ms);
  TQ.push(t);
}

// ───────────────────────────── 타이틀 (챕터 × 스테이지, 지갑/구독자 칩, 제보 앨범)
// 가설: 100 스테이지도 "챕터 탭 + 현재 챕터 10칸"만 그리면 한눈에 들어오고 빠르다.
const TS = { stages: [], progress: null, chapters: null, shop: null, P: null, groups: [], unlocked: 1, startIdx: 0, grid: false, multi: false, active: -1, list: null, head: null, tabs: null };

function readProgress(progress) {
  const pr = progress && typeof progress === 'object' ? progress : {};
  const obj = (o) => (o && typeof o === 'object' ? o : {});
  return {
    pr, stars: obj(pr.stars), best: obj(pr.best), album: obj(pr.album), wallet: Math.max(0, num(pr.wallet)), subs: Math.max(0, num(pr.subs)),
    owned: Array.isArray(pr.owned) ? pr.owned.map(String) : [], equip: obj(pr.equip),
  };
}
// 메뉴가 떠 있는 동안 (앨범·차고 위에서는 스테이지 시작 금지)
const overlayOpen = () => isShown(E.album) || isShown(E.shop);
const starsOf = (P, s) => clamp(Math.round(num(P.stars[s?.id])), 0, 3);

// stages[].chapter (1..) 로 묶음. chapter 가 없으면 앞 스테이지의 챕터(첫 스테이지는 1)를 따른다 → 전부 없으면 한 챕터.
function groupChapters(stages, chapters) {
  const meta = new Map();
  if (Array.isArray(chapters)) {
    chapters.forEach((c, k) => {
      if (!c || typeof c !== 'object') return;
      const no = Math.round(num(c.no, k + 1));
      if (!meta.has(no)) meta.set(no, c);
    });
  }
  const groups = new Map();
  let prev = 1;
  stages.forEach((s, i) => {
    let ch = Math.round(num(s?.chapter, NaN));
    if (!Number.isFinite(ch) || ch < 1) ch = prev;
    prev = ch;
    let g = groups.get(ch);
    if (!g) { g = { no: ch, idx: [], meta: meta.get(ch) || null }; groups.set(ch, g); }
    g.idx.push(i);
  });
  if (!groups.size) groups.set(1, { no: 1, idx: [], meta: meta.get(1) || null });
  return [...groups.values()].sort((a, b) => a.no - b.no);
}
const THEME_ACCENT = { day: '#2f9e5b', morning: '#4aa3c7', fog: '#7f97a8', sunset: '#f07a2a', dusk: '#c2577a', night: '#4b5bd6', snow: '#5fb3e6', rain: '#3d7bb8', coast: '#14a3b5', city: '#8b5cf6', mountain: '#5c8a3a', festival: '#e2231a', boss: '#c8241a' };
function chapterAccent(meta) {
  const t = meta && meta.theme;
  if (typeof t === 'string') {
    if (/^#[0-9a-f]{3,8}$/i.test(t)) return t;
    const k = t.toLowerCase();
    for (const key in THEME_ACCENT) if (k.includes(key)) return THEME_ACCENT[key];
  } else if (t && typeof t === 'object' && typeof t.accent === 'string' && /^#[0-9a-f]{3,8}$/i.test(t.accent)) return t.accent;
  return '';
}
const chName = (g) => String(g?.meta?.name || `CHAPTER ${g?.no ?? 1}`);

// 챕터 탭 줄 (타이틀/앨범 공용). stat(g) → { done, total, locked, complete }
function chapTabs(groups, activeNo, stat, onPick) {
  const wrap = el('div', 'ui-chap');
  const prev = wrap.appendChild(btn('ui-btn--round ui-btn--blue ui-chap__nav ui-chap__nav--prev', SVG.left, () => step(-1), '이전 챕터'));
  const strip = wrap.appendChild(el('div', 'ui-chap__tabs'));
  const next = wrap.appendChild(btn('ui-btn--round ui-btn--blue ui-chap__nav ui-chap__nav--next', SVG.right, () => step(1), '다음 챕터'));
  const tabs = new Map();
  groups.forEach((g, k) => {
    const st = stat(g);
    const tab = el('button', `ui-chaptab${st.locked ? ' is-locked' : ''}${st.complete ? ' is-done' : ''}`);
    tab.type = 'button';
    tab.dataset.ch = String(g.no);
    tab.style.setProperty('--i', k);
    const acc = chapterAccent(g.meta);
    if (acc) tab.style.setProperty('--ch', acc);
    const w = st.total ? clamp(st.done / st.total, 0, 1) : 0;
    tab.innerHTML = `<span class="ui-chaptab__no">CH.${esc(g.no)}${st.locked ? `<span class="ui-chaptab__lock">${SVG.lock}</span>` : st.complete ? `<span class="ui-chaptab__crown">${SVG.medal}</span>` : ''}</span>`
      + `<span class="ui-chaptab__name">${esc(chName(g))}</span>`
      + `<span class="ui-chaptab__prog"><i style="transform:scaleX(${w.toFixed(3)})"></i></span>`
      + `<span class="ui-chaptab__cnt"><b>${st.done}</b>/${st.total}</span>`;
    tab.addEventListener('mousedown', (e) => e.preventDefault());
    tab.addEventListener('click', (e) => { e.stopPropagation(); try { tab.blur(); } catch { /* */ } onPick(g.no, true); });
    strip.appendChild(tab);
    tabs.set(g.no, tab);
  });
  let cur = activeNo;
  function step(d) {
    const k = groups.findIndex((g) => g.no === cur);
    const g = groups[clamp(k + d, 0, groups.length - 1)];
    if (g && g.no !== cur) onPick(g.no, true);
  }
  function setActive(no, smooth) {
    cur = no;
    for (const [k, t] of tabs) t.classList.toggle('is-active', k === no);
    const k = groups.findIndex((g) => g.no === no);
    prev.disabled = k <= 0;
    next.disabled = k >= groups.length - 1;
    const tab = tabs.get(no);
    if (!tab) return;
    // scrollIntoView 는 바깥 세로 스크롤까지 건드려서 직접 계산
    try {
      const left = Math.max(0, tab.offsetLeft - (strip.clientWidth - tab.offsetWidth) / 2);
      if (strip.scrollTo) strip.scrollTo({ left, behavior: smooth && !reduceMotion ? 'smooth' : 'auto' });
      else strip.scrollLeft = left;
    } catch { /* */ }
  }
  wrap._setActive = setActive;
  return wrap;
}

function stageCardHTML(s, i, label, P, opts) {
  if (opts.compact) return stageTileHTML(s, i, label, P, opts);
  const locked = i >= TS.unlocked;
  const stars = starsOf(P, s);
  const best = Math.round(num(P.best[s?.id]));
  const kd = stageKind(s);
  const ck = caseKind(s?.card);
  let st = '';
  for (let k = 0; k < 3; k++) st += `<span class="ui-star ${k < stars ? 'is-on' : ''}">${SVG.star}</span>`;
  const cls = `ui-stagecard${opts.compact ? ' ui-stagecard--sm' : ''}${locked ? ' is-locked' : ''}${i === TS.startIdx ? ' is-next' : ''}${stars > 0 ? ' is-cleared' : ''}${kd ? ` is-${kd}` : ''} is-case-${ck}`;
  const meta = best > 0 ? 'BEST ' + fmt(best) : (locked ? '' : (s?.displayKm != null ? '정체 ' + esc(s.displayKm) + 'km' : ''));
  return `<button type="button" class="${cls}" data-i="${i}" style="--i:${opts.k}">
      <span class="ui-stagecard__head">${shieldHTML(s?.route, 'ui-shield--card')}<span class="ui-stagecard__hw"><b>${esc(s?.highway)}</b><span>${esc(s?.direction)}</span></span></span>
      <span class="ui-stagecard__body">
        <span class="ui-stagecard__no">${label}${kindBadge(kd)}${caseChip(ck)}</span>
        <span class="ui-stagecard__title">${esc(stageTitle(s))}</span>
        <span class="ui-stagecard__meta"><span class="ui-stars">${st}</span><span class="ui-stagecard__best">${meta}</span></span>
      </span>
      ${locked ? `<span class="ui-stagecard__lock"><span class="ui-stagecard__lockico">${SVG.lock}</span><span>잠김</span></span>` : ''}
      ${i === TS.startIdx && !locked ? '<span class="ui-stagecard__tag">NEXT</span>' : ''}
    </button>`;
}

// 챕터 모드 타일: 머리(방패 + 노선명 + 번호) / 제목 2줄 / ★ — 10칸이 한 화면에 들어가는 크기
function stageTileHTML(s, i, label, P, opts) {
  const locked = i >= TS.unlocked;
  const stars = starsOf(P, s);
  const best = Math.round(num(P.best[s?.id]));
  const kd = stageKind(s);
  const ck = caseKind(s?.card);
  let st = '';
  for (let k = 0; k < 3; k++) st += `<span class="ui-star ${k < stars ? 'is-on' : ''}">${SVG.star}</span>`;
  const cls = `ui-stagecard ui-stagecard--sm${locked ? ' is-locked' : ''}${i === TS.startIdx ? ' is-next' : ''}${stars > 0 ? ' is-cleared' : ''}${kd ? ` is-${kd}` : ''} is-case-${ck}`;
  const aria = `${label} ${kd ? KIND_LABEL[kd] + ' ' : ''}${stageTitle(s)}${ck !== 'fine' ? ' (' + CASE[ck].tag + ')' : ''}`;
  return `<button type="button" class="${cls}" data-i="${i}" style="--i:${opts.k}" aria-label="${esc(aria)}">
      <span class="ui-stagecard__head">${shieldHTML(s?.route, 'ui-shield--card')}<span class="ui-stagecard__hw"><b>${esc(s?.highway)}</b></span><span class="ui-stagecard__num">${esc(label)}${kd ? `<em>${kd === 'final' ? '최종' : KIND_LABEL[kd]}</em>` : ''}</span><span class="ui-stars ui-stagecard__hstars">${st}</span></span>
      <span class="ui-stagecard__body">
        <span class="ui-stagecard__title">${caseChip(ck, 'ui-casechip--tile')}${esc(stageTitle(s))}</span>
        <span class="ui-stagecard__meta"><span class="ui-stars">${st}</span>${locked ? '' : `<span class="ui-stagecard__best">${best > 0 ? 'BEST ' + fmt(best) : ''}</span>`}</span>
      </span>
      ${locked ? `<span class="ui-stagecard__lock"><span class="ui-stagecard__lockico">${SVG.lock}</span><span>잠김</span></span>` : ''}
      ${i === TS.startIdx && !locked ? '<span class="ui-stagecard__tag">NEXT</span>' : ''}
    </button>`;
}

function renderChapter(no, smooth) {
  const g = TS.groups.find((x) => x.no === no) || TS.groups[0];
  if (!g || !TS.list) return;
  TS.active = g.no;
  const P = TS.P;
  const stages = TS.stages;
  let html = '';
  g.idx.forEach((i, k) => {
    const label = TS.grid ? (TS.multi ? `${g.no}-${k + 1}` : `${i + 1}`) : `STAGE ${i + 1}`;
    html += stageCardHTML(stages[i], i, label, P, { compact: TS.grid, k: smooth ? k * 0.45 : k });
  });
  TS.list.innerHTML = html;
  TS.list.classList.toggle('is-swap', !!smooth);
  if (TS.head) {
    const acc = chapterAccent(g.meta);
    TS.head.style.setProperty('--ch', acc || '');
    const got = g.idx.reduce((a, i) => a + starsOf(P, stages[i]), 0);
    const cleared = g.idx.filter((i) => starsOf(P, stages[i]) > 0).length;
    const setting = g.meta && g.meta.setting ? `<span class="ui-chaphead__set">${esc(g.meta.setting)}</span>` : '';
    TS.head.innerHTML = `<span class="ui-chaphead__no">CHAPTER ${esc(g.no)}</span><span class="ui-chaphead__txt"><b>${esc(chName(g))}</b>${setting}</span>`
      + `<span class="ui-chaphead__stat"><span class="ui-chaphead__s1"><span class="ui-star is-on">${SVG.star}</span><b>${got}</b>/${g.idx.length * 3}</span><span class="ui-chaphead__s2"><b>${cleared}</b>/${g.idx.length} 클리어</span></span>`;
    if (smooth) anim(TS.head, KF.bump, { duration: 260, easing: 'cubic-bezier(.3,1.7,.5,1)' });
  }
  if (TS.tabs && TS.tabs._setActive) TS.tabs._setActive(g.no, smooth);
}

function albumGot(P, s) {
  const a = P.album[s?.id];
  if (a && typeof a === 'object' && (num(a.count) > 0 || num(a.stars) > 0 || okSrc(a.photo))) return true;
  return starsOf(P, s) > 0; // 앨범 도입 전 세이브: 클리어 = 수집
}

function showTitle(stages, progress, chapters, shop) {
  stages = Array.isArray(stages) ? stages : [];
  const P = readProgress(progress);
  const n = stages.length;
  const unlocked = clamp(Math.round(num(P.pr.unlocked, 1)) || 1, 1, Math.max(1, n));
  const startIdx = clamp(unlocked - 1, 0, Math.max(0, n - 1));

  finishCard();
  closeFail(null);
  setHudOn(false);
  hideBoss();
  clearBubbles();
  setTouchVisible(false);
  setPausedVisible(false);
  setShown(E.result, false);
  hideAlbum();
  hideShop();
  setReleaseCounter(null);
  C.phase = null; delete R.dataset.phase;

  const groups = groupChapters(stages, chapters);
  const multi = groups.length > 1;
  const shopList = Array.isArray(shop) ? shop : null;
  Object.assign(TS, { stages, progress, chapters: Array.isArray(chapters) ? chapters : null, shop: shopList, P, groups, unlocked, startIdx, multi, grid: multi || n > 6, active: -1, list: null, head: null, tabs: null });
  if (shopList) { SH.src = shopList; SH.progress = progress; }

  const T = E.title;
  T.textContent = '';
  T.classList.toggle('ui-title--chapters', TS.grid);
  E.muteBtns = E.muteBtns.filter((b) => b.isConnected && !T.contains(b));
  const top = T.appendChild(el('div', 'ui-title__bar'));
  top.appendChild(makeMuteBtn('ui-title__mute'));

  // 지갑 · 구독자 칩
  E.tPurse = T.appendChild(el('div', 'ui-purse',
    `<span class="ui-purse__chip ui-purse__chip--won"><span class="ui-purse__ico">${SVG.coin}</span><span class="ui-purse__txt"><small>포상금</small><b>${won(P.wallet)}</b></span></span>`
    + `<span class="ui-purse__chip ui-purse__chip--subs"><span class="ui-purse__ico">${SVG.chan}</span><span class="ui-purse__txt"><small>구독자</small><b>${kor(P.subs)}</b></span></span>`));

  const wrap = T.appendChild(el('div', 'ui-title__wrap'));
  wrap.appendChild(el('div', 'ui-title__logo',
    `<div class="ui-sign ui-sign--logo">
      <span class="ui-sign__kicker">고속도로 빌런 헌터</span>
      <span class="ui-sign__row"><span class="ui-sign__arrow">${SVG.arrowUp}</span><span class="ui-sign__main">1차선 참교육</span></span>
    </div>
    <div class="ui-sign__posts"><i></i><i></i></div>
    <div class="ui-vms"><span>막히면, 원인을 제거한다.</span></div>`));

  if (multi) {
    TS.tabs = wrap.appendChild(chapTabs(groups, -1, (g) => {
      const cleared = g.idx.filter((i) => starsOf(P, stages[i]) > 0).length;
      return { done: cleared, total: g.idx.length, locked: (g.idx[0] ?? 0) >= unlocked, complete: g.idx.length > 0 && cleared === g.idx.length };
    }, (no) => { if (no !== TS.active) renderChapter(no, true); }));
    TS.head = wrap.appendChild(el('div', 'ui-chaphead'));
  }

  const list = wrap.appendChild(el('div', `ui-stages${TS.grid ? ' ui-stages--grid' : ''}`));
  TS.list = list;
  list.addEventListener('mousedown', (e) => { if (e.target.closest && e.target.closest('.ui-stagecard')) e.preventDefault(); });
  list.addEventListener('click', (e) => {
    const card = e.target.closest && e.target.closest('.ui-stagecard');
    if (!card || !list.contains(card)) return;
    e.stopPropagation();
    try { card.blur(); } catch { /* */ }
    const i = Math.round(num(card.dataset.i, -1));
    if (i < 0 || i >= TS.stages.length) return;
    if (i >= TS.unlocked) { anim(card, KF.shake, { duration: 320 }); return; }
    if (!isShown(E.title) || overlayOpen()) return;
    call('onStartStage', i);
  });

  const s0 = stages[startIdx];
  const g0 = groups.find((g) => g.idx.includes(startIdx)) || groups[0];
  const k0 = g0 ? g0.idx.indexOf(startIdx) : startIdx;
  const go = wrap.appendChild(el('div', 'ui-title__go'));
  go.appendChild(btn('ui-btn--yellow ui-btn--xl ui-title__start',
    `<span class="ui-btn__main">START <span class="ui-btn__arrow">▶</span></span><span class="ui-btn__sub">${s0 ? `STAGE ${multi ? `${g0.no}-${k0 + 1}` : startIdx + 1} · ${esc(stageTitle(s0))}` : ''}</span>`,
    () => { if (isShown(E.title) && !overlayOpen()) call('onStartStage', startIdx); }));
  const got = stages.filter((s) => albumGot(P, s)).length;
  go.appendChild(btn('ui-btn--blue ui-title__album',
    `<span class="ui-title__albumico">${SVG.album}</span><span class="ui-title__albumtxt"><span>제보 앨범</span><small><b>${got}</b>/${n}</small></span>`,
    () => { if (isShown(E.title)) showAlbum(); }, '제보 앨범'));
  // 차고 (shop 을 넘겨준 경우만)
  E.tGarage = null;
  if (shopList && shopList.length) {
    E.tGarage = go.appendChild(btn('ui-btn--green ui-title__album ui-title__garage',
      `<span class="ui-title__albumico">${SVG.garage}</span><span class="ui-title__albumtxt"><span>차고</span><small></small></span><span class="ui-title__badge" hidden></span>`,
      () => { if (isShown(E.title) && !isShown(E.album)) showShop(); }, '참교육 차고'));
  }
  E.tHelp = wrap.appendChild(el('div', 'ui-help'));
  updateTitleShop(P, false);

  setShown(T, true);
  renderChapter(g0 ? g0.no : 1, false);
  try { T.scrollTop = 0; } catch { /* */ }
}
function hideTitle() { hideAlbum(); hideShop(); setShown(E.title, false, 320); }

// 타이틀의 차고 관련 조각 (지갑 칩 · 차고 버튼 배지 · 점프 키 힌트) — showTitle / refreshShop 공용
function updateTitleShop(P, animate) {
  if (!E.tHelp || !E.tHelp.isConnected) return;
  const jump = P.owned.includes('mv_jump');
  E.tHelp.innerHTML = `<span class="ui-help__row"><b>PC</b><kbd>←</kbd><kbd>→</kbd> 차선 · <kbd>Space</kbd> 발사/경적 · <kbd>R</kbd> 분노의 경적·폭탄${jump ? ' · <kbd>↑</kbd> 점프' : ''}</span>`
    + '<span class="ui-help__row"><b>모바일</b> 버튼 · 스와이프</span>';
  const wb = E.tPurse && E.tPurse.querySelector('.ui-purse__chip--won b');
  if (wb) {
    const prev = num(wb.dataset.v, P.wallet);
    wb.dataset.v = P.wallet;
    if (animate && prev !== P.wallet) countTo(wb, prev, P.wallet, 600, 'tw');
    else wb.textContent = won(P.wallet);
  }
  if (!E.tGarage || !TS.shop) return;
  const items = normItems(TS.shop);
  const st = shopState(items, P.pr);
  const owned = items.filter((it) => st.owned.has(it.id)).length;
  const can = items.filter((it) => !st.owned.has(it.id) && num(it.price) <= st.wallet).length;
  E.tGarage.querySelector('.ui-title__albumtxt small').innerHTML = `<b>${owned}</b>/${items.length}`;
  const bd = E.tGarage.querySelector('.ui-title__badge');
  bd.hidden = can <= 0;
  bd.textContent = can > 9 ? '9+' : String(can);
  E.tGarage.setAttribute('aria-label', can > 0 ? `참교육 차고 (살 수 있는 것 ${can}개)` : '참교육 차고');
}
// 숫자 카운트 (차고 지갑 · 타이틀 지갑). 노드별 rAF 하나
function countTo(node, from, to, ms, key) {
  if (!node) return;
  const st = node._ct || (node._ct = { raf: 0 });
  cancelAnimationFrame(st.raf);
  if (reduceMotion || ms <= 0) { node.textContent = won(to); return; }
  const t0 = now();
  const step = () => {
    const k = clamp((now() - t0) / ms, 0, 1);
    node.textContent = won(from + (to - from) * easeOut(k));
    if (k < 1) st.raf = requestAnimationFrame(step);
    else bump(node, key, 0, KF.bigBump, 240);
  };
  st.raf = requestAnimationFrame(step);
}

// ───────────────────────────── 제보 앨범 (도감)
// 가설: 블박 캡처가 "카드 한 장"으로 쌓이고, ★ 등급별 테두리(동·은·금)가 다시 플레이할 이유가 된다.
const AS = { stages: [], P: null, groups: [], active: -1, grid: null, head: null, tabs: null };
function showAlbum(stages, progress, chapters) {
  if (!Array.isArray(stages)) { stages = TS.stages; progress = progress ?? TS.progress; chapters = chapters ?? TS.chapters; }
  stages = Array.isArray(stages) ? stages : [];
  const P = readProgress(progress);
  const groups = groupChapters(stages, chapters);
  Object.assign(AS, { stages, P, groups, active: -1 });
  const n = stages.length;
  const got = stages.filter((s) => albumGot(P, s)).length;
  const fines = stages.reduce((a, s) => a + (albumGot(P, s) ? Math.max(0, num(P.album[s?.id]?.fine, num(s?.fine))) : 0), 0);

  const A = E.album;
  A.textContent = '';
  const book = A.appendChild(el('div', 'ui-album__book'));
  book.addEventListener('click', (e) => e.stopPropagation());
  const head = book.appendChild(el('div', 'ui-album__head',
    `<span class="ui-album__ico">${SVG.album}</span>
     <span class="ui-album__title"><b>블박 제보 앨범</b><small>빌런 도감 · 누적 범칙금 ${won(fines)}</small></span>
     <span class="ui-album__count"><span class="ui-album__got"><b>${got}</b><span>/${n}</span></span><span class="ui-album__bar"><i style="transform:scaleX(${n ? (got / n).toFixed(3) : 0})"></i></span></span>`));
  head.appendChild(btn('ui-btn--round ui-btn--red ui-album__close', SVG.close, () => hideAlbum(), '닫기'));
  if (groups.length > 1) {
    AS.tabs = book.appendChild(chapTabs(groups, -1, (g) => {
      const c = g.idx.filter((i) => albumGot(P, stages[i])).length;
      return { done: c, total: g.idx.length, locked: false, complete: g.idx.length > 0 && c === g.idx.length };
    }, (no) => { if (no !== AS.active) renderAlbumPage(no, true); }));
    AS.tabs.classList.add('ui-chap--album');
  } else AS.tabs = null;
  const page = book.appendChild(el('div', 'ui-album__page'));
  AS.head = page.appendChild(el('div', 'ui-album__pagehead'));
  AS.grid = page.appendChild(el('div', 'ui-album__grid'));
  AS.page = page;

  // 첫 페이지 = 타이틀에서 보던 챕터 (없으면 마지막으로 수집한 챕터)
  let start = groups.find((g) => g.no === TS.active && TS.stages === stages) || null;
  if (!start) {
    for (const g of groups) if (g.idx.some((i) => albumGot(P, stages[i]))) start = g;
    start = start || groups[0];
  }
  renderAlbumPage(start ? start.no : 1, false);
  setShown(A, true);
  call('onAlbum', true);
}

function albumCardHTML(s, i, k, label, P) {
  const a = P.album[s?.id] && typeof P.album[s?.id] === 'object' ? P.album[s.id] : {};
  const has = albumGot(P, s);
  const stars = has ? clamp(Math.round(Math.max(num(a.stars), starsOf(P, s))), 0, 3) : 0;
  const fine = Math.max(0, Math.round(num(a.fine, num(s?.fine))));
  const count = Math.max(has ? 1 : 0, Math.round(num(a.count)));
  const rar = has ? Math.max(1, stars) : 0;
  let st = '';
  for (let q2 = 0; q2 < 3; q2++) st += `<span class="ui-star ${q2 < stars ? 'is-on' : ''}">${SVG.star}</span>`;
  const pic = has
    ? (okSrc(a.photo) ? `<img class="ui-acard__img" src="${esc(a.photo)}" alt="" loading="lazy" decoding="async">` : dashArt(villainColor(s), 'photo', num(s?.id, i)))
    : dashArt('', 'silhouette');
  const vname = Array.isArray(s?.villains) ? s.villains.map((v) => v && v.name).filter(Boolean).join(' & ') : '';
  const kd = stageKind(s), ck = caseKind(s?.card);
  const amt = ck === 'rescue' ? '구조 표창' : ck === 'warn' ? '계도' : ck === 'crime' ? bigWon(fine) : won(fine);
  return `<div class="ui-acard ui-acard--r${rar}${has ? ' is-got' : ''} is-case-${ck}" style="--i:${k}">
    <div class="ui-acard__top"><span class="ui-acard__no">${label}${kindBadge(kd, 'ui-kindb--xs')}</span><span class="ui-stars">${st}</span></div>
    <div class="ui-acard__pic">${pic}${has ? '<span class="ui-acard__rec"><i></i>REC</span>' : '<span class="ui-acard__q">?</span><span class="ui-acard__wait">제보 대기 중</span>'}</div>
    <div class="ui-acard__name">${esc(stageTitle(s))}</div>
    <div class="ui-acard__who">${has && vname ? esc(vname) : (s?.highway ? esc(s.highway) : '&nbsp;')}</div>
    <div class="ui-acard__meta"><span class="ui-acard__fine">${has ? amt : '₩ ?'}</span><span class="ui-acard__cnt">${has ? `×${fmt(count)} ${ck === 'rescue' ? '구조' : '참교육'}` : (ck === 'rescue' ? '구조 대기' : '미검거')}</span></div>
    ${rar >= 3 ? '<i class="ui-acard__holo"></i>' : ''}
  </div>`;
}

function renderAlbumPage(no, smooth) {
  const g = AS.groups.find((x) => x.no === no) || AS.groups[0];
  if (!g || !AS.grid) return;
  AS.active = g.no;
  const P = AS.P, stages = AS.stages, multi = AS.groups.length > 1;
  let html = '';
  g.idx.forEach((i, k) => {
    const label = multi ? `No.${String(i + 1).padStart(3, '0')}` : `No.${String(i + 1).padStart(2, '0')}`;
    html += albumCardHTML(stages[i], i, smooth ? k * 0.5 : k, label, P);
  });
  AS.grid.innerHTML = html;
  const c = g.idx.filter((i) => albumGot(P, stages[i])).length;
  const acc = chapterAccent(g.meta);
  AS.head.style.setProperty('--ch', acc || '');
  AS.head.innerHTML = multi
    ? `<span class="ui-chaphead__no">CHAPTER ${esc(g.no)}</span><span class="ui-chaphead__txt"><b>${esc(chName(g))}</b>${g.meta?.setting ? `<span class="ui-chaphead__set">${esc(g.meta.setting)}</span>` : ''}</span><span class="ui-chaphead__stat"><span class="ui-chaphead__s1"><b>${c}</b>/${g.idx.length} 수집</span>${c === g.idx.length && c > 0 ? '<span class="ui-chaphead__s2"><em>챕터 완성!</em></span>' : ''}</span>`
    : `<span class="ui-chaphead__txt"><b>참교육 기록</b><span class="ui-chaphead__set">빌런을 퇴치하면 블박 캡처 카드가 한 장씩 쌓입니다</span></span><span class="ui-chaphead__stat"><span class="ui-chaphead__s1"><b>${c}</b>/${g.idx.length} 수집</span></span>`;
  if (AS.tabs && AS.tabs._setActive) AS.tabs._setActive(g.no, smooth);
  try { AS.page.scrollTop = 0; } catch { /* */ }
}

function hideAlbum() {
  if (!E.album || !isShown(E.album)) return;
  setShown(E.album, false, 240);
  call('onAlbum', false);
}

// ───────────────────────────── 참교육 차고 (고속도로 휴게소 정비소)
// 가설: 포상금으로 차·무기·날아가는 것·피니시를 사는 차고가 생기면 '퇴치 → 보상 → 성장' 루프가 닫힌다. (docs/SHOP.md)
//  - 차/무기/피니시 = 하나만 장착(slot), 날아가는 것/패시브 = 보유하면 항상 적용
//  - price 0 아이템은 항상 보유. equip 이 비어 있으면 그 분류의 기본(price 0) 아이템이 장착된 것으로 본다.
const SHOP_CATS = [
  { id: 'car', label: '차', ico: SVG.car, slot: true },
  { id: 'weapon', label: '무기', ico: SVG.tackTab, slot: true },
  { id: 'move', label: '날아가는 것', ico: SVG.jump, slot: false },
  { id: 'finish', label: '피니시', ico: SVG.rocket, slot: true },
  { id: 'passive', label: '패시브', ico: SVG.shieldOk, slot: false },
];
const SLOT_CATS = SHOP_CATS.filter((c) => c.slot).map((c) => c.id);
const SH = { src: null, progress: null, items: [], cats: [], tab: 'car', owned: new Set(), equip: {}, wallet: 0, busy: null, busyT: 0, el: {}, onKey: null };

function normItems(shop) {
  if (!Array.isArray(shop)) return [];
  const seen = new Set();
  const out = [];
  for (const it of shop) {
    if (!it || typeof it !== 'object' || typeof it.id !== 'string' || !it.id || seen.has(it.id)) continue;
    seen.add(it.id);
    out.push({ ...it, cat: typeof it.cat === 'string' && it.cat ? it.cat : 'etc' });
  }
  return out;
}
function shopState(items, progress) {
  const pr = progress && typeof progress === 'object' ? progress : {};
  const owned = new Set((Array.isArray(pr.owned) ? pr.owned : []).map(String));
  for (const it of items) if (num(it.price) <= 0) owned.add(it.id);
  const eq = pr.equip && typeof pr.equip === 'object' ? pr.equip : {};
  const equip = {};
  for (const c of SLOT_CATS) {
    const want = items.find((x) => x.id === eq[c] && x.cat === c && owned.has(x.id));
    const def = want || items.find((x) => x.cat === c && num(x.price) <= 0) || items.find((x) => x.cat === c && owned.has(x.id));
    equip[c] = def ? def.id : null;
  }
  return { owned, equip, wallet: Math.max(0, Math.round(num(pr.wallet))) };
}
function catsOf(items) {
  const cats = SHOP_CATS.filter((c) => items.some((it) => it.cat === c.id));
  for (const it of items) {
    if (!cats.some((c) => c.id === it.cat)) cats.push({ id: it.cat, label: it.cat === 'etc' ? '기타' : it.cat, ico: SVG.garage, slot: false });
  }
  return cats;
}
function itemStatus(it) {
  if (SH.owned.has(it.id)) return SLOT_CATS.includes(it.cat) ? (SH.equip[it.cat] === it.id ? 'equipped' : 'owned') : 'active';
  return num(it.price) <= SH.wallet ? 'buy' : 'poor';
}
// 스펙 칩 (데이터에 있는 것만)
function itemSpecs(it) {
  const out = [];
  const st = it.stats && typeof it.stats === 'object' ? it.stats : null;
  if (it.cat === 'car' && st) {
    const sp = num(st.speed, 1);
    out.push(Math.abs(sp - 1) < 0.005 ? ['속도 기본', ''] : [`최고속 ${sp > 1 ? '+' : '−'}${Math.round(Math.abs(sp - 1) * 100)}%`, sp > 1 ? 'up' : 'down']);
    if (num(st.armor) > 0) out.push([`추돌 무시 ${Math.round(num(st.armor))}회`, 'up']);
    if (st.tow) out.push(['고장차 견인', 'up']);
    if (st.siren) out.push(['사이렌', 'up']);
  } else if (it.cat === 'weapon' && it.dmg != null) {
    const dps = num(it.dmg) * num(it.rate, 1) * Math.max(1, num(it.spread, 1));
    out.push([`초당 피해 ${Math.round(dps)}`, '']);
    if (num(it.spread) > 1) out.push([`${Math.round(num(it.spread))}발 동시`, 'up']);
    if (it.slow) out.push(['공격 느려짐', 'up']);
  }
  return out;
}
function itemCardHTML(it, k) {
  const s = itemStatus(it);
  const price = Math.max(0, Math.round(num(it.price)));
  const id = esc(it.id);
  const specs = itemSpecs(it).map(([t, c]) => `<i${c ? ` class="is-${c}"` : ''}>${esc(t)}</i>`).join('');
  let act = '';
  if (s === 'equipped') act = `<span class="ui-item__state ui-item__state--on">${SVG.check}<span>장착 중</span></span>`;
  else if (s === 'owned') act = `<button type="button" class="ui-btn ui-btn--blue ui-item__btn" data-act="equip" data-id="${id}">장착</button>`;
  else if (s === 'active') act = `<span class="ui-item__state ui-item__state--have">${SVG.check}<span>${it.cat === 'move' ? '보유 · 사용 가능' : '보유 · 항상 적용'}</span></span>`;
  else if (s === 'buy') act = `<button type="button" class="ui-btn ui-btn--yellow ui-item__btn" data-act="buy" data-id="${id}"><span class="ui-btn__ico">${SVG.coin}</span>구매</button>`;
  else act = `<span class="ui-item__need">${won(price - SH.wallet)} 더 모으면!</span><button type="button" class="ui-btn ui-btn--grey ui-item__btn is-poor" data-act="poor" data-id="${id}" aria-disabled="true">포상금 부족</button>`;
  const rib = s === 'equipped' ? '<span class="ui-item__rib">장착 중</span>' : (s === 'owned' || s === 'active') ? '<span class="ui-item__rib ui-item__rib--have">보유</span>' : '';
  const tag = price > 0 ? (s === 'buy' || s === 'poor' ? `<span class="ui-item__price">${won(price)}</span>` : '') : '<span class="ui-item__price ui-item__price--free">기본</span>';
  return `<div class="ui-item ui-item--${esc(it.cat)} is-${s}" data-id="${id}" style="--i:${k}">
    <div class="ui-item__show">${itemArt(it)}${rib}</div>${tag}
    <div class="ui-item__body">
      <b class="ui-item__name">${esc(it.name || it.id)}</b>
      <span class="ui-item__desc">${esc(it.desc || '')}</span>
      ${specs ? `<span class="ui-item__specs">${specs}</span>` : ''}
    </div>
    <div class="ui-item__foot">${act}</div>
  </div>`;
}

function showShop(shop, progress, tab) {
  if (!Array.isArray(shop)) shop = SH.src || TS.shop;
  if (!progress || typeof progress !== 'object') progress = SH.progress || TS.progress;
  SH.src = Array.isArray(shop) ? shop : null;
  SH.progress = progress && typeof progress === 'object' ? progress : null;
  SH.items = normItems(SH.src);
  Object.assign(SH, shopState(SH.items, SH.progress));
  SH.cats = catsOf(SH.items);
  if (typeof tab === 'string' && SH.cats.some((c) => c.id === tab)) SH.tab = tab;
  else if (!SH.cats.some((c) => c.id === SH.tab)) SH.tab = SH.cats[0] ? SH.cats[0].id : 'car';
  SH.busy = null;
  clearTimeout(SH.busyT);

  const S = E.shop;
  S.textContent = '';
  const panel = S.appendChild(el('div', 'ui-shop__panel'));
  panel.addEventListener('click', (e) => e.stopPropagation());
  const head = panel.appendChild(el('div', 'ui-shop__head',
    `<span class="ui-shop__logo">${SVG.garage}</span>
     <span class="ui-shop__title"><small><span class="ui-shop__picto">${SVG.fuel}${SVG.cup}${SVG.wrench}</span>휴게소 정비소</small><b>참교육 차고</b></span>
     <span class="ui-shop__wallet"><span class="ui-shop__coin">${SVG.coin}</span><span class="ui-shop__wtxt"><small>포상금</small><b>${won(SH.wallet)}</b></span></span>`));
  head.appendChild(btn('ui-btn--round ui-btn--red ui-shop__close', SVG.close, () => hideShop(), '닫기'));
  panel.appendChild(el('div', 'ui-shop__awning'));
  const tabs = panel.appendChild(el('div', 'ui-shop__tabs'));
  const load = panel.appendChild(el('div', 'ui-shop__load'));
  const shelf = panel.appendChild(el('div', 'ui-shop__shelf'));
  const grid = shelf.appendChild(el('div', 'ui-shop__grid'));
  SH.el = { panel, tabs, load, shelf, grid, wallet: head.querySelector('.ui-shop__wtxt b'), walletChip: head.querySelector('.ui-shop__wallet') };

  const pick = (e, sel) => {
    const t = e.target.closest && e.target.closest(sel);
    if (!t) return null;
    e.stopPropagation();
    try { t.blur(); } catch { /* */ }
    return t;
  };
  const noFocus = (e) => { if (e.target.closest && e.target.closest('button')) e.preventDefault(); };
  for (const n of [tabs, load, grid]) n.addEventListener('mousedown', noFocus);
  const goTab = (c) => { if (c && c !== SH.tab && SH.cats.some((x) => x.id === c)) { SH.tab = c; renderShopTabs(); renderShopGrid(true); } };
  tabs.addEventListener('click', (e) => { const t = pick(e, '.ui-shoptab'); if (t) goTab(t.dataset.cat); });
  load.addEventListener('click', (e) => { const t = pick(e, '.ui-load__slot'); if (t) goTab(t.dataset.cat); });
  grid.addEventListener('click', onShopClick);

  renderShopTabs();
  renderLoadout();
  renderShopGrid(true);
  setShown(S, true);
  if (!SH.onKey) {
    SH.onKey = (e) => { if (e.key === 'Escape' && isShown(E.shop)) hideShop(); };
    addEventListener('keydown', SH.onKey);
  }
  call('onShop', true);
}

function renderShopTabs() {
  const t = SH.el.tabs;
  if (!t) return;
  t.innerHTML = SH.cats.map((c, k) => {
    const its = SH.items.filter((it) => it.cat === c.id);
    const own = its.filter((it) => SH.owned.has(it.id)).length;
    const can = its.some((it) => !SH.owned.has(it.id) && num(it.price) <= SH.wallet);
    const on = c.id === SH.tab;
    return `<button type="button" class="ui-shoptab ui-shoptab--${esc(c.id)}${on ? ' is-active' : ''}" data-cat="${esc(c.id)}" style="--i:${k}" aria-pressed="${on}">`
      + `<span class="ui-shoptab__ico">${c.ico}</span><span class="ui-shoptab__l">${esc(c.label)}</span><span class="ui-shoptab__n">${own}/${its.length}</span>`
      + `${can ? '<i class="ui-shoptab__dot" title="살 수 있는 아이템"></i>' : ''}</button>`;
  }).join('');
}
function renderLoadout(changed = []) {
  const L = SH.el.load;
  if (!L) return;
  const slots = SHOP_CATS.filter((c) => c.slot && SH.cats.some((x) => x.id === c.id));
  const extras = SH.items.filter((it) => !SLOT_CATS.includes(it.cat) && SH.owned.has(it.id));
  L.innerHTML = '<span class="ui-load__lbl">장착</span>'
    + slots.map((c) => {
      const it = SH.items.find((x) => x.id === SH.equip[c.id]);
      return `<button type="button" class="ui-load__slot" data-cat="${c.id}" aria-label="${esc(c.label)}: ${esc(it ? it.name : '없음')}"><span class="ui-load__ico">${it ? itemArt(it) : ''}</span><span class="ui-load__txt"><small>${esc(c.label)}</small><b>${esc(it ? it.name : '—')}</b></span></button>`;
    }).join('')
    + `<span class="ui-load__extra"><small>보유 능력</small><b>${extras.length ? extras.map((x) => esc(x.name)).join(' · ') : '아직 없음'}</b></span>`;
  for (const c of changed) {
    const s = L.querySelector(`.ui-load__slot[data-cat="${c}"]`);
    if (s) anim(s, KF.segPulse, { duration: 460, easing: 'cubic-bezier(.3,1.6,.5,1)' });
  }
}
function renderShopGrid(animate) {
  const g = SH.el.grid;
  if (!g) return;
  const its = SH.items.filter((it) => it.cat === SH.tab);
  g.classList.toggle('is-static', !animate);
  g.style.setProperty('--cols', Math.max(1, Math.min(4, its.length)));
  g.innerHTML = its.length ? its.map((it, k) => itemCardHTML(it, k)).join('') : '<div class="ui-shop__empty">상품 준비 중…</div>';
  if (animate) try { SH.el.shelf.scrollTop = 0; } catch { /* */ }
}
const cardOf = (id) => (SH.el.grid ? [...SH.el.grid.children].find((c) => c.dataset && c.dataset.id === id) : null);

function onShopClick(e) {
  const b = e.target.closest && e.target.closest('[data-act]');
  if (!b || !SH.el.grid.contains(b)) return;
  e.stopPropagation();
  try { b.blur(); } catch { /* */ }
  const id = b.dataset.id, act = b.dataset.act;
  const it = SH.items.find((x) => x.id === id);
  if (!it) return;
  if (act === 'poor') {
    anim(b.closest('.ui-item'), KF.shake, { duration: 320 });
    anim(SH.el.walletChip, KF.shake, { duration: 320 });
    shopFloat(b, `${won(num(it.price) - SH.wallet)} 부족!`, 'warn');
    return;
  }
  if (SH.busy === id) return;
  SH.busy = id;
  b.classList.add('is-busy');
  clearTimeout(SH.busyT);
  SH.busyT = setTimeout(() => { SH.busy = null; b.classList.remove('is-busy'); }, 1200);
  call(act === 'buy' ? 'onBuy' : 'onEquip', id);
}
// 패널 기준 떠오르는 글자 (부족 · 지출 · 장착)
function shopFloat(anchor, text, kind = 'warn') {
  const P = SH.el.panel;
  if (!P || !anchor || !anchor.getBoundingClientRect) return;
  const a = anchor.getBoundingClientRect(), p = P.getBoundingClientRect();
  const f = P.appendChild(el('span', `ui-shopfloat ui-shopfloat--${kind}`));
  f.textContent = text;
  f.style.left = `${Math.round(a.left - p.left + a.width / 2)}px`;
  f.style.top = `${Math.round(a.top - p.top + (kind === 'spend' ? a.height + 6 : -4))}px`;
  setTimeout(() => f.remove(), reduceMotion ? 700 : 1200);
}
// 구매 성공: 코인 버스트 + '구매 완료!' 도장
function celebrate(id) {
  const card = cardOf(id);
  if (!card) return;
  card.classList.add('is-bought');
  const fx = card.appendChild(el('div', 'ui-coinfx'));
  let h = '';
  const N = reduceMotion ? 0 : 14;
  for (let i = 0; i < N; i++) {
    const a = (i / N) * Math.PI * 2 + Math.random() * 0.35;
    const d = 70 + Math.random() * 60;
    h += `<i style="--dx:${(Math.cos(a) * d).toFixed(0)}px;--dy:${(Math.sin(a) * d * 0.75 - 40).toFixed(0)}px;--r:${Math.round(Math.random() * 720 - 360)}deg;--dl:${Math.round(Math.random() * 140)}ms">${SVG.coin}</i>`;
  }
  fx.innerHTML = h;
  card.querySelector('.ui-item__show')?.appendChild(el('div', 'ui-item__stamp', '<span>구매 완료!</span>'));
  anim(card, KF.bigBump, { duration: 440, easing: 'cubic-bezier(.3,1.7,.5,1)' });
  setTimeout(() => fx.remove(), 1500);
  try { card.scrollIntoView({ block: 'nearest', behavior: reduceMotion ? 'auto' : 'smooth' }); } catch { /* */ }
}
function equipPop(id) {
  const card = cardOf(id);
  if (!card) return;
  anim(card, KF.bump, { duration: 300, easing: 'cubic-bezier(.3,1.7,.5,1)' });
  const st = card.querySelector('.ui-item__state--on') || card;
  shopFloat(st, '장착!', 'equip');
}

function refreshShop(progress) {
  if (progress && typeof progress === 'object') SH.progress = progress;
  const pr = SH.progress;
  // 타이틀 지갑/배지/점프 힌트
  if (pr && E.tHelp && E.tHelp.isConnected) {
    TS.progress = pr;
    TS.P = readProgress(pr);
    updateTitleShop(TS.P, true);
  }
  if (!SH.items.length && Array.isArray(SH.src || TS.shop)) { SH.items = normItems(SH.src || TS.shop); SH.cats = catsOf(SH.items); }
  if (!isShown(E.shop) || !SH.el.grid || !SH.el.grid.isConnected) { Object.assign(SH, shopState(SH.items, pr)); return; }
  const prev = { owned: SH.owned, equip: { ...SH.equip }, wallet: SH.wallet };
  Object.assign(SH, shopState(SH.items, pr));
  SH.busy = null;
  clearTimeout(SH.busyT);
  const bought = SH.items.filter((it) => SH.owned.has(it.id) && !prev.owned.has(it.id));
  const changed = SLOT_CATS.filter((c) => SH.equip[c] !== prev.equip[c]);
  if (bought.length && !bought.some((it) => it.cat === SH.tab)) SH.tab = bought[0].cat;
  renderShopTabs();
  renderLoadout(changed);
  renderShopGrid(false);
  if (SH.wallet !== prev.wallet) {
    countTo(SH.el.wallet, prev.wallet, SH.wallet, 700, 'shopw');
    if (SH.wallet < prev.wallet) shopFloat(SH.el.walletChip, '−' + won(prev.wallet - SH.wallet), 'spend');
  }
  for (const it of bought) celebrate(it.id);
  for (const c of changed) if (!bought.some((it) => it.id === SH.equip[c])) equipPop(SH.equip[c]);
}

function hideShop() {
  if (!E.shop || !isShown(E.shop)) return;
  setShown(E.shop, false, 240);
  SH.busy = null;
  clearTimeout(SH.busyT);
  call('onShop', false);
}

// ───────────────────────────── 별 미션 (스테이지 카드 미리보기 · 결과 체크리스트 공용)
// 별 i = 미션 i. 카드에서는 빈 별 + 번호, 결과에서는 done 인 칸의 별만 금색으로 터진다.
function normMissions(ms) {
  if (!Array.isArray(ms)) return null;
  const out = [];
  for (const m of ms) {
    if (out.length >= 3) break;
    if (typeof m === 'string') out.push({ label: m, done: false, value: '' });
    else if (m && typeof m === 'object') out.push({ label: String(m.label ?? ''), done: !!m.done, value: m.value != null && m.value !== '' ? String(m.value) : '' });
  }
  return out.length ? out : null;
}
function missionsHTML(ms, mode) {
  const items = ms.map((m, i) => `<li class="ui-mis__item" style="--i:${i}">
      <span class="ui-mis__star"><span class="ui-star">${SVG.star}</span><b class="ui-mis__n">${i + 1}</b></span>
      <span class="ui-mis__t">${esc(m.label)}${m.value ? ` <em>${esc(m.value)}</em>` : ''}</span>
      ${mode === 'result' ? `<span class="ui-mis__mark ui-mis__mark--ok">${SVG.check}</span><span class="ui-mis__mark ui-mis__mark--no">${SVG.cross}</span>` : ''}
    </li>`).join('');
  return `<ol class="ui-mis ui-mis--${mode}" style="--n:${ms.length}" aria-label="별 미션">${items}</ol>`;
}
// 결과: main.js 효과음 타이밍(700 + i*380ms)에 맞춰 칸 i 를 판정 (done → 별 팡 + ✔, 아니면 ✖ + 흔들)
function popMissions(panel, ms) {
  panel.querySelectorAll('.ui-mis--result .ui-mis__item').forEach((it, i) => {
    const m = ms[i];
    if (!m) return;
    it.setAttribute('aria-label', `${i + 1}번 별: ${m.label} — ${m.done ? '달성' : '실패'}`);
    later(700 + i * 380, () => {
      it.classList.add(m.done ? 'is-done' : 'is-miss');
      if (!m.done) anim(it, KF.shake, { duration: 360 });
    });
  });
}

// ───────────────────────────── v0.4 도로 상황 (R7: 갓길 / 경적 / 특수 아이콘 3개 + 전광판 한 줄 힌트)
// 가설: 판마다 다른 갓길·경적 규칙이 시작 카드에서 3초 안에 읽히면 '갓길+빵 만능' 습관이 깨진다 ❓
function normRoad(r) {
  if (!r || typeof r !== 'object') return null;
  const own = (o, k) => typeof k === 'string' && Object.prototype.hasOwnProperty.call(o, k);   // iOS < 15.4 엔 Object.hasOwn 없음
  const sh = own(SH_MODES, r.shoulder) ? r.shoulder : null;
  const hk = own(HONK_MODES, r.honk) ? r.honk : null;
  const sp = (typeof r.special === 'string' || typeof r.special === 'number') ? String(r.special).trim().slice(0, 40) : '';
  let hint = (typeof r.hint === 'string' || typeof r.hint === 'number') ? String(r.hint).trim().slice(0, 60) : '';
  if (!hint) hint = hk ? `이번 판 경적 = ${HONK_MODES[hk].short}` : sh ? `이번 판 갓길 = ${SH_MODES[sh].short}` : '';
  if (!sh && !hk && !sp && !hint) return null;
  return { sh, hk, sp, hint };
}
function roadHTML(rd) {
  const tiles = [];
  const tile = (kind, cls, tone, label, svg) => `<li class="ui-road__tile ui-road__tile--${cls} is-${tone}" style="--i:${tiles.length}"><span class="ui-road__ico">${roadSVG(svg)}</span><span class="ui-road__txt"><small>${kind}</small><b>${esc(label)}</b></span></li>`;
  if (rd.sh) { const m = SH_MODES[rd.sh]; tiles.push(tile('갓길', 'sh', m.tone, m.label, m.svg)); }
  if (rd.hk) { const m = HONK_MODES[rd.hk]; tiles.push(tile('경적', 'hk', m.tone, m.label, m.svg)); }
  if (rd.sp) tiles.push(tile('특수', 'sp', 'warn', rd.sp, specialSVG(rd.sp)));
  return `<div class="ui-road" aria-label="도로 상황">
      <div class="ui-road__head"><span class="ui-road__tag">${SVG.road}도로 상황</span><span class="ui-road__sub">판마다 규칙이 달라요</span></div>
      ${tiles.length ? `<ul class="ui-road__tiles" style="--n:${tiles.length}">${tiles.join('')}</ul>` : ''}
      ${rd.hint ? `<div class="ui-vms ui-road__vms"><span>${esc(rd.hint)}</span></div>` : ''}
    </div>`;
}

// ───────────────────────────── 스테이지 카드
let cardState = null;
function finishCard() {
  const st = cardState;
  if (!st) return;
  cardState = null;
  clearTimeout(st.timer);
  clearTimeout(st.arm);
  removeEventListener('keydown', st.onKey, true);
  E.card.removeEventListener('pointerdown', st.onTap);
  setShown(E.card, false, 320);
  try { st.resolve(); } catch { /* */ }
}
function showStageCard(stage, missions, road) {
  finishCard();
  closeFail(null);
  const s = stage || {};
  setStage(stage);
  setHudOn(false);
  hideAlbum();
  hideShop();
  setShown(E.title, false, 320);
  setShown(E.result, false);
  const idx = Number.isFinite(+s.id) ? +s.id : '';
  const ms = normMissions(missions);
  const kd = stageKind(s), ck = caseKind(s.card);
  const honk = s.honkOnly ? `<div class="ui-card__honk"><span class="ui-card__honkico">${SVG.horn}</span><b>구조 상황</b><i>·</i><span>압정 금지</span><i>·</i><span>경적으로 깨우기</span></div>` : '';
  const rd = normRoad(road);
  // 미션 · 도로 상황이 있으면 읽을 시간을 조금 더 (탭/키로 바로 스킵 가능)
  const dur = (ms ? 3400 : 2600) + (rd ? 1000 : 0);
  E.card.classList.toggle('has-road', !!rd);
  E.card.innerHTML = `
    <div class="ui-card__panel${kd ? ` is-${kd}` : ''} is-case-${ck}${ms ? ' has-mis' : ''}${honk ? ' has-honk' : ''}${rd ? ' has-road' : ''}" style="--card-ms:${dur}ms">
      <div class="ui-sign ui-sign--card">${shieldHTML(s.route, 'ui-shield--big')}<span class="ui-sign__txt"><b>${esc(s.highway)}</b><span>${esc(s.direction)} <i class="ui-sign__dirarrow">▶</i></span></span></div>
      <div class="ui-card__body">
        <div class="ui-card__no">STAGE ${esc(idx)}${kindBadge(kd)}<span class="ui-card__tag ui-card__tag--${ck}">${ck === 'rescue' ? SVG.horn : SVG.angry}${CASE[ck].tag}</span></div>
        <div class="ui-card__title">${esc(stageTitle(s))}</div>
        <div class="ui-card__line">${esc(String(s.villainLine || '').replace(/^"|"$/g, ''))}</div>
        <div class="ui-card__blurb">${esc(s.blurb)}</div>
        <div class="ui-card__jam"><span class="ui-card__jamtag">정체</span><b>${esc(s.displayKm ?? '?')}km</b>${s.villainSpeedLabel ? `<span class="ui-card__spd">원흉 ${esc(s.villainSpeedLabel)}</span>` : ''}</div>
        ${honk}
      </div>
      ${rd ? roadHTML(rd) : ''}
      ${ms ? `<div class="ui-card__mis"><div class="ui-card__mishead"><span class="ui-card__mistag"><span class="ui-star is-on">${SVG.star}</span>별 미션</span><span class="ui-card__missub">하나 달성할 때마다 ★ 1개</span></div>${missionsHTML(ms, 'card')}</div>` : ''}
      <div class="ui-card__tap">탭하여 바로 시작</div>
      <div class="ui-card__timer"><i></i></div>
    </div>`;
  setShown(E.card, true);
  return new Promise((resolve) => {
    const st = { resolve, timer: 0, arm: 0, onKey: null, onTap: null };
    st.onKey = (e) => { if (!e.repeat) finishCard(); };
    st.onTap = (e) => { e.preventDefault(); finishCard(); };
    cardState = st;
    st.timer = setTimeout(finishCard, dur);
    // 시작 버튼을 누른 그 입력이 바로 스킵으로 먹히지 않게 잠깐 유예
    st.arm = setTimeout(() => {
      if (cardState !== st) return;
      addEventListener('keydown', st.onKey, true);
      E.card.addEventListener('pointerdown', st.onTap);
    }, 280);
  });
}

// ───────────────────────────── 결과
// 가설(v0.2): 결과 = "퇴치 → 보상 → 수집" 루프를 한 화면에. 블박 제보(도장) → ★ → 포상금 → 참교육 채널 순으로 터진다.
let resT = [];
let resRaf = 0;
function clearResultTimers() { resT.forEach(clearTimeout); resT = []; cancelAnimationFrame(resRaf); resRaf = 0; clearTweens(); }
// 연출 타이머 (모션 줄이기 = 즉시). real=true 는 모션과 무관한 실제 대기(토스트 자동 닫힘 등)
const later = (ms, fn, real = false) => { resT.push(setTimeout(() => { try { fn(); } catch (e) { console.error('[ui] result', e); } }, reduceMotion && !real ? 0 : ms)); };
function showResult(r) {
  r = r || {};
  finishCard();
  closeFail(null);
  setHudOn(false);
  hideBoss();
  clearBubbles();
  setPausedVisible(false);
  hideAlbum();
  hideShop();
  clearResultTimers();
  if (r.reward && typeof r.reward === 'object') { showRewardResult(r, r.reward); return; }
  const stars = clamp(Math.round(num(r.stars)), 0, 3);
  const score = Math.max(0, Math.round(num(r.score)));
  const stats = Array.isArray(r.stats) ? r.stats : [];
  const ms = normMissions(r.missions);
  const S = C.stage;
  const ck = caseKind((r.reward && r.reward.card) ?? r.card ?? S?.card);
  const P = E.result;
  P.textContent = '';
  const panel = P.appendChild(el('div', 'ui-result__panel'));
  panel.innerHTML = `
    <div class="ui-sign ui-sign--result">${S ? shieldHTML(S.route, 'ui-shield--chip') : ''}<span class="ui-sign__txt"><b>${esc(r.stageName)}</b></span>${kindBadge(stageKind(S), 'ui-kindb--sign')}</div>
    <div class="ui-result__body">
      <div class="ui-result__who"><span class="ui-result__lbl">${ck === 'rescue' ? '구조 대상' : '참교육 대상'}</span><span class="ui-result__villain${ck === 'rescue' ? ' is-rescue' : ''}"><span>${esc(r.villainName)}</span></span></div>
      <div class="ui-stamp ui-stamp--${ck}"><span>${CASE[ck].done}!</span></div>
      ${ms ? missionsHTML(ms, 'result') : `<div class="ui-result__stars">${[0, 1, 2].map((k) => `<span class="ui-star ui-star--big ${k < stars ? 'is-on' : ''}">${SVG.star}</span>`).join('')}</div>`}
      <div class="ui-result__score"><span>SCORE</span><b>0</b></div>
      ${r.isLast ? '<div class="ui-result__final">🎉 전 구간 소통 원활! 모든 빌런 참교육 완료 🎉</div>' : ''}
      <div class="ui-stats"></div>
    </div>
    <div class="ui-result__btns"></div>`;
  const statsEl = panel.querySelector('.ui-stats');
  stats.forEach((s, i) => {
    const v = String(s?.value ?? '');
    const pm = /^(\d+(?:\.\d+)?)%$/.exec(v.trim());
    const row = el('div', `ui-stat${i === 0 && pm ? ' ui-stat--hero' : ''}`);
    row.style.setProperty('--i', i);
    row.innerHTML = `<span class="ui-stat__l">${esc(s?.label)}</span><b class="ui-stat__v">${esc(v)}</b>${i === 0 && pm ? `<span class="ui-stat__bar"><i style="--w:${clamp(+pm[1], 0, 100) / 100}"></i></span>` : ''}`;
    statsEl.appendChild(row);
  });
  resultButtons(panel.querySelector('.ui-result__btns'), r);

  setShown(P, true);
  try { P.scrollTop = 0; } catch { /* */ }
  if (ms) popMissions(panel, ms); else popStars(panel, stars);
  countScore(panel.querySelector('.ui-result__score b'), score);
}
function resultButtons(bw, r) {
  if (r.isLast) bw.appendChild(btn('ui-btn--yellow ui-btn--lg ui-result__next', '처음부터', () => call('onMenu')));
  else bw.appendChild(btn('ui-btn--yellow ui-btn--lg ui-result__next', '다음 빌런 <span class="ui-btn__arrow">▶</span>', () => call('onNext')));
  bw.appendChild(btn('ui-btn--blue', '다시하기', () => call('onRetry')));
  bw.appendChild(btn('ui-btn--grey', '메뉴', () => call('onMenu')));
}
// 별: main.js 효과음 타이밍(700 + i*380ms)에 맞춤
function popStars(panel, stars) {
  panel.querySelectorAll('.ui-result__stars .ui-star').forEach((s, i) => {
    if (i < stars) later(700 + i * 380, () => s.classList.add('is-pop'));
  });
}
function countScore(scoreEl, score) {
  if (!scoreEl) return;
  if (reduceMotion || score === 0) { scoreEl.textContent = fmt(score); return; }
  tween(450, 1150, (k) => { scoreEl.textContent = fmt(score * k); }, () => anim(scoreEl, KF.bigBump, { duration: 260 }));
}

// ── 보상 결과
const NICKS = ['고속도로지킴이', '1차선은추월차선', '경부선출퇴근러', '비상등깜빡깜빡', '블박장인', '사이다중독자', '정체혐오자', '졸음쉼터단골', '톨게이트요정', '화물차기사24년', '서해안안개맨', '대관령눈길러', '귀성길생존자', '깜빡이켜는사람', '도로위평화주의자', '휴게소호두과자'];
const AV_COLORS = ['#ff8a1f', '#2f6fd6', '#17a466', '#8b5cf6', '#e2231a', '#0ea5b7', '#d97706', '#db2777'];
const TL = { stamp: 280, money: 1750, wallet: 2150, chan: 2250, cmt: 2450, mile: 2600 };
const ARROW = '<svg viewBox="0 0 44 24" aria-hidden="true"><path d="M3 8.5h24V3l14 9-14 9v-5.5H3z" fill="#fff" stroke="#17202b" stroke-width="2.6" stroke-linejoin="round"/></svg>';
function mileTier(m) { return /골드|gold/i.test(m) ? 'gold' : /실버|silver/i.test(m) ? 'silver' : 'bronze'; }

function showRewardResult(r, w) {
  const S = C.stage;
  const stars = clamp(Math.round(num(r.stars, num(w.stars))), 0, 3);
  const score = Math.max(0, Math.round(num(r.score)));
  const stats = Array.isArray(r.stats) ? r.stats.filter((s) => s && typeof s === 'object') : [];
  const fine = Math.max(0, Math.round(num(w.fine, num(S?.fine))));
  const payout = Math.max(0, Math.round(num(w.payout)));
  const bonus = Math.max(0, Math.round(num(w.bonus)));
  const wallet = Math.max(payout, Math.round(num(w.wallet, payout)));
  const views = Math.max(0, Math.round(num(w.views)));
  const gain = Math.max(0, Math.round(num(w.subsGain)));
  const subs = Math.max(gain, Math.round(num(w.subs, gain)));
  const vName = String(w.villainName || r.villainName || '');
  const violation = String(w.violation || S?.violation || '도로교통법 위반');
  const cause = String(w.cause || S?.cause || '');
  const milestone = w.milestone ? String(w.milestone) : '';
  const sid = Math.round(num(w.stageId, num(S?.id, 1)));
  const comments = (Array.isArray(w.comments) ? w.comments : []).map((c) => String(c ?? '').trim()).filter(Boolean).slice(0, 3);
  // 처분 카드 종류 · 등급. 범칙금/벌금(fine, 실제 금액) ≠ 포상금(payout, 받는 돈)
  const ck = caseKind(w.card ?? S?.card);
  const CK = CASE[ck];
  const kd = stageKind(S);
  const starMult = [1, 1, 1.5, 2][stars] || 1;
  const multTxt = '×' + starMult;
  const base = Math.max(0, num(w.base, num(S?.payout, fine)));
  const extra = base > 0 ? payout / (base * starMult + bonus) : 1;   // 블박 4K 등 추가 배율
  const extraPct = Number.isFinite(extra) && extra > 1.08 ? Math.round((extra - 1) * 100) : 0;
  const fineTxt = ck === 'crime' ? bigWon(fine) : won(fine);
  const caseNote = { crime: '벌금은 국고로 · 포상금은 제보 기준액 × ★', rescue: '범칙금 대신 구조 포상금 × ★', warn: '계도라 범칙금 0원 · 기본 포상금 × ★' }[ck] || '';
  const photo = okSrc(w.photo) ? w.photo : null;
  const d = new Date();
  const p2 = (v) => String(v).padStart(2, '0');
  const no = `${d.getFullYear()}${p2(d.getMonth() + 1)}${p2(d.getDate())}-${String(Math.abs(sid)).padStart(3, '0')}`;
  // 블박 OSD: 원흉 차로 / 내 속도 (없으면 원흉 속도 라벨에서 추정)
  const lane = S && Array.isArray(S.villains) && S.villains[0] ? clamp(Math.round(num(S.villains[0].lane, 0)) + 1, 1, 4) : 1;
  const vSpd = num((/(\d+)\s*km/i.exec(String(S?.villainSpeedLabel || '')) || [])[1], 0);
  const spd = Math.round(num(w.speedKmh, vSpd ? vSpd + 9 + (Math.abs(sid) % 5) : 92 + (Math.abs(sid) * 7) % 30));
  const heroI = stats.length && /^\d+(?:\.\d+)?%$/.test(String(stats[0].value ?? '').trim()) ? 0 : -1;
  const hero = heroI === 0 ? stats[0] : null;
  const rest = hero ? stats.slice(1) : stats;
  const seed = Math.abs(sid) * 7 + (views % 13);
  const art = dashArt(villainColor(S), 'photo', sid);
  const ms = normMissions(r.missions);

  const Pn = E.result;
  Pn.textContent = '';
  const panel = Pn.appendChild(el('div', 'ui-result__panel ui-result__panel--reward'));
  const heroW = hero ? clamp(parseFloat(hero.value) || 0, 0, 100) / 100 : 0;
  let starsHTML = '';
  for (let k = 0; k < 3; k++) starsHTML += `<span class="ui-star ui-star--big ${k < stars ? 'is-on' : ''}">${SVG.star}</span>`;
  let cmts = '';
  comments.forEach((c, k) => {
    const nick = NICKS[(seed + k * 5) % NICKS.length];
    const likes = Math.round(views * [0.012, 0.0042, 0.0016][k] * (0.8 + ((seed * (k + 3)) % 40) / 100)) + 3 + k;
    cmts += `<li class="ui-cmt" style="--d:${TL.cmt + k * 150}ms">
      <span class="ui-cmt__av" style="--c:${AV_COLORS[(seed + k * 3) % AV_COLORS.length]}">${esc(Array.from(nick)[0] || '?')}</span>
      <span class="ui-cmt__body">
        <span class="ui-cmt__meta"><b>@${esc(nick)}</b><span>${['방금 전', '1분 전', '2분 전'][k]}</span><span class="ui-cmt__act">${k === 0 ? `<span class="ui-cmt__heart" title="채널 주인이 좋아함">${SVG.heart}</span>` : ''}<span class="ui-cmt__like">${SVG.thumb}<b>${kor(likes)}</b></span></span></span>
        <span class="ui-cmt__t">${esc(c)}</span>
      </span>
    </li>`;
  });

  panel.innerHTML = `
    <div class="ui-sign ui-sign--result">${S ? shieldHTML(S.route, 'ui-shield--chip') : ''}<span class="ui-sign__txt"><b>${esc(r.stageName)}</b></span>${kindBadge(kd, 'ui-kindb--sign')}</div>
    <div class="ui-result__scroll">
      <div class="ui-rw${ms ? ' ui-rw--mis' : ''}">
        <div class="ui-rw__col ui-rw__col--l">
          <section class="ui-dash">
            <div class="ui-dash__head"><span class="ui-dash__ico">${SVG.cam}</span><b>${ck === 'rescue' ? '블박 구조 기록' : '블박 제보 접수'}</b><span class="ui-dash__no">No.${no}</span></div>
            <div class="ui-dash__cam"><div class="ui-dash__screen">
              ${photo ? '' : art}
              <div class="ui-dash__scan"></div>
              <div class="ui-dash__osd ui-dash__osd--tl"><span class="ui-dash__rec"><i></i>REC</span><span>${clock(d)}</span></div>
              <div class="ui-dash__osd ui-dash__osd--tr"><span class="ui-dash__ch">FRONT</span><span class="ui-dash__evt">충격감지</span></div>
              <div class="ui-dash__osd ui-dash__osd--bl"><span class="ui-dash__spd">${spd}<small>km/h</small></span><span class="ui-dash__lane">${lane}차로</span></div>
              <div class="ui-dash__shutter"></div>
            </div></div>
            <div class="ui-dash__foot">
              <span class="ui-dash__lbl">${ck === 'rescue' ? '구조 차량' : '위반 차량'}</span>
              <b class="ui-dash__villain${ck === 'rescue' ? ' is-rescue' : ''}"><span>${esc(vName)}</span></b>
              ${cause ? `<span class="ui-dash__cause">${ck === 'rescue' ? '구조 사유' : '제보 사유'} · ${esc(cause)}</span>` : ''}
              <span class="ui-dash__done">${SVG.check}<span>처리 결과: ${CK.done}</span></span>
            </div>
            <div class="ui-fine ui-fine--${ck}" style="--d:${TL.stamp}ms">
              <span class="ui-fine__t">${CK.stamp}</span>
              <span class="ui-fine__v">${ck === 'rescue' ? '잠든·고장난 운전자를 경적으로 깨워 갓길로 안전 유도' : esc(violation)}</span>
              <span class="ui-fine__amt">${ck === 'rescue' ? '<b>시민 구조 유공</b>' : ck === 'warn' ? '범칙금 없음 · <b>계도</b>' : `${CK.amt} <b>${fineTxt}</b>${ck === 'crime' ? '<small>(실제)</small>' : ''}`}</span>
              <span class="ui-fine__seal"><span>${CK.seal[0]}</span><span>${CK.seal[1]}</span></span>
            </div>
          </section>
          ${rest.length ? '<div class="ui-stats ui-stats--mini"></div>' : ''}
        </div>
        <div class="ui-rw__col ui-rw__col--r">
          <section class="ui-rate${ms ? ' ui-rate--mis' : ''}">
            ${ms ? missionsHTML(ms, 'result') : `<div class="ui-result__stars">${starsHTML}</div>`}
            <div class="ui-rate__side">
              <div class="ui-rate__score"><span>SCORE</span><b>0</b></div>
              ${hero ? `<div class="ui-rate__hero"><span class="ui-rate__hl">${esc(hero.label)}</span><b>${esc(hero.value)}</b><span class="ui-stat__bar"><i style="--w:${heroW}"></i></span></div>` : ''}
            </div>
            ${r.isLast ? '<div class="ui-result__final">🎉 전 구간 소통 원활! 모든 빌런 참교육 완료 🎉</div>' : ''}
          </section>
          <section class="ui-money" style="--d:${TL.money}ms">
            <div class="ui-money__flow">
              <span class="ui-money__box ui-money__box--fine ui-money__box--${ck}">${
  ck === 'rescue' ? '<small>구조 표창 · 시민 유공</small><b>표창장</b>'
    : ck === 'warn' ? `<small>계도 · 범칙금 없음</small><b>${won(0)}</b>`
      : `<small>${CK.amt} (실제) · 빌런 부담</small><b>${fineTxt}</b>`}</span>
              <span class="ui-money__arrow">${ARROW}<em>★${esc(multTxt)}</em></span>
              <span class="ui-money__box ui-money__box--pay"><small>포상금 · 내가 받는 돈</small><b class="ui-money__pay">+${won(0)}</b></span>
            </div>
            ${caseNote ? `<div class="ui-money__note">${caseNote}</div>` : ''}
            ${bonus || extraPct ? `<div class="ui-money__bonus">${bonus ? `+ 잔챙이·얌체 신고 보너스 <b>${won(bonus)}</b>` : ''}${bonus && extraPct ? ' · ' : ''}${extraPct ? `블박 4K <b>+${extraPct}%</b>` : ''} 포함</div>` : ''}
            <div class="ui-money__wallet"><span class="ui-money__coin">${SVG.coin}</span><span class="ui-money__wl">보유 포상금</span><b class="ui-money__total">${won(wallet - payout)}</b></div>
          </section>
          <section class="ui-chan" style="--d:${TL.chan}ms">
            <div class="ui-chan__head">
              <span class="ui-chan__av">${SVG.car}</span>
              <span class="ui-chan__name"><b>참교육 채널</b><small>새 블박 영상 업로드 완료</small></span>
              <span class="ui-chan__subs">${SVG.chan}<b>${kor(subs)}</b></span>
            </div>
            <div class="ui-chan__video">
              <span class="ui-chan__thumb">${photo ? '' : art}<span class="ui-chan__dur">0:${p2(30 + (Math.abs(seed) % 29))}</span></span>
              <span class="ui-chan__vt"><b>[블박] ${esc(vName || '빌런')} ${ck === 'rescue' ? '구조 현장 (경적 주의)' : ck === 'crime' ? '형사 입건 현장 (사이다 주의)' : '참교육 현장 (사이다 주의)'}</b>
                <span class="ui-chan__stats">조회수 <b class="ui-chan__views">0</b><i>·</i>구독자 <b class="ui-chan__gain">+0</b> <span class="ui-chan__tot">(총 ${kor(subs)})</span></span></span>
            </div>
            ${cmts ? `<ul class="ui-chan__cmts">${cmts}</ul>` : ''}
          </section>
        </div>
      </div>
    </div>
    <div class="ui-result__btns"></div>`;
  if (photo) {
    const mk = (cls) => { const im = el('img', cls); im.alt = ''; im.decoding = 'async'; im.src = photo; return im; };
    const scr = panel.querySelector('.ui-dash__screen');
    scr.insertBefore(mk('ui-dash__img'), scr.firstChild);
    const th = panel.querySelector('.ui-chan__thumb');
    th.insertBefore(mk('ui-chan__img'), th.firstChild);
  }
  const mini = panel.querySelector('.ui-stats--mini');
  rest.forEach((s, i) => {
    const row = el('div', 'ui-stat');
    row.style.setProperty('--i', i);
    row.innerHTML = `<span class="ui-stat__l">${esc(s.label)}</span><b class="ui-stat__v">${esc(s.value ?? '')}</b>`;
    mini.appendChild(row);
  });
  resultButtons(panel.querySelector('.ui-result__btns'), r);

  // 마일스톤: 실버/골드 = 참교육 버튼 상패(비상등 버튼 패러디), 그 외 = 메달 토스트
  let mile = null;
  if (milestone) {
    const tier = mileTier(milestone);
    mile = Pn.appendChild(el('div', `ui-mile ui-mile--${tier}`,
      `<div class="ui-mile__rays"></div>
       <div class="ui-mile__card">
         ${tier === 'bronze'
    ? `<span class="ui-mile__medal">${SVG.medal}</span>`
    : `<span class="ui-mile__plaque"><span class="ui-mile__btn">${SVG.hazard}</span><span class="ui-mile__plate">참교육 채널</span></span>`}
         <span class="ui-mile__txt"><small>구독자 ${esc(kor(subs))} 달성</small><b>${esc(milestone)}</b><span class="ui-mile__tap">탭해서 닫기</span></span>
       </div>`));
    mile.hidden = true;
    mile.addEventListener('click', (e) => { e.stopPropagation(); closeMile(); });
    const head = panel.querySelector('.ui-chan__head');
    head.appendChild(el('span', `ui-chan__badge ui-chan__badge--${tier}`, `${tier === 'bronze' ? SVG.medal : SVG.hazard}<span>${tier === 'gold' ? '골드' : tier === 'silver' ? '실버' : '돌파'}</span>`));
  }
  function closeMile() {
    if (!mile || mile.hidden || mile.classList.contains('is-off')) return;
    mile.classList.add('is-off');
    later(260, () => { mile.hidden = true; });
  }

  setShown(Pn, true);
  const sc = panel.querySelector('.ui-result__scroll');
  try { Pn.scrollTop = 0; sc.scrollTop = 0; } catch { /* */ }

  if (ms) popMissions(panel, ms); else popStars(panel, stars);
  countScore(panel.querySelector('.ui-rate__score b'), score);
  const payEl = panel.querySelector('.ui-money__pay');
  const totEl = panel.querySelector('.ui-money__total');
  const coin = panel.querySelector('.ui-money__coin');
  tween(TL.money + 150, 800, (k) => { payEl.textContent = '+' + won(payout * k); }, () => anim(payEl, KF.bigBump, { duration: 240 }));
  tween(TL.wallet, 900, (k) => { totEl.textContent = won(wallet - payout + payout * k); }, () => { anim(totEl, KF.bigBump, { duration: 260 }); anim(coin, KF.tirePop, { duration: 420 }); });
  const vEl = panel.querySelector('.ui-chan__views');
  const gEl = panel.querySelector('.ui-chan__gain');
  tween(TL.chan + 120, 1000, (k) => { vEl.textContent = kor(views * k); gEl.textContent = '+' + fmt(gain * k); }, () => anim(gEl, KF.bigBump, { duration: 240 }));
  // 모바일: 채널 패널이 접힌 아래에 있으면 등장 순간 살짝 보여 준다 (사용자가 직접 스크롤했으면 건드리지 않음)
  let touched = false;
  const mark = () => { touched = true; };
  sc.addEventListener('wheel', mark, { passive: true, once: true });
  sc.addEventListener('touchstart', mark, { passive: true, once: true });
  later(TL.chan + 150, () => {
    if (touched || !sc.isConnected) return;
    const col = panel.querySelector('.ui-rw__col');
    if (!col || getComputedStyle(col).display !== 'contents') return; // 한 줄(세로 폰) 배치일 때만
    const chan = panel.querySelector('.ui-chan');
    const over = chan.getBoundingClientRect().top + Math.min(chan.offsetHeight, 150) - sc.getBoundingClientRect().bottom;
    if (over > 4) try { sc.scrollTo({ top: sc.scrollTop + over + 8, behavior: reduceMotion ? 'auto' : 'smooth' }); } catch { sc.scrollTop += over + 8; }
  });
  if (mile) {
    later(TL.mile, () => { mile.hidden = false; panel.querySelector('.ui-chan__badge')?.classList.add('is-on'); });
    later(TL.mile + 4200, closeMile, true);
  }
}
function hideResult() { clearResultTimers(); setShown(E.result, false, 300); }

// ───────────────────────────── v0.4 견인 실패 카드
// 가설: 실패가 '견인!' 개그 + 바로 재도전 버튼이면 긴장은 남고 짜증은 안 남는다 ❓
// 자동 진행 없음. Enter = 재도전, Esc = 메뉴. 다시 부르면 내용만 바꾸고 같은 Promise.
const FS = { open: false, armed: false, resolve: null, promise: null, armT: 0, onKey: null };
function closeFail(choice) {
  if (!FS.open) return;
  FS.open = false;
  FS.armed = false;
  clearTimeout(FS.armT);
  removeEventListener('keydown', FS.onKey, true);
  E.fail.classList.remove('is-armed');
  setShown(E.fail, false, 300);
  const r = FS.resolve;
  FS.resolve = null;
  FS.promise = null;
  if (choice && r) { try { r(choice); } catch { /* */ } }
}
function pickFail(choice) {
  if (!FS.open || !FS.armed) return;
  closeFail(choice === 'menu' ? 'menu' : 'retry');
}
function showFail(o) {
  o = o && typeof o === 'object' ? o : {};
  const txt = (v, d, n = 60) => { const t = (typeof v === 'string' || typeof v === 'number') ? String(v).trim().slice(0, n) : ''; return t || d; };
  const title = txt(o.title, '참교육 실패', 24);
  const reason = txt(o.reason, '차가 더는 못 버텼다');
  const who = txt(o.villainName, '', 40);
  const lost = Math.max(0, Math.round(num(o.hpLost)));
  const retryLabel = txt(o.retryLabel, '발견 지점부터 다시', 24);
  finishCard();
  hideAlbum();
  hideShop();
  if (isShown(E.result)) hideResult();
  setShown(E.title, false, 320);
  setPausedVisible(false);
  hideBoss();
  clearBubbles();
  setHudOn(false);
  const P = E.fail;
  P.innerHTML = `
    <div class="ui-fail__panel" role="dialog" aria-label="${esc(title)}">
      <div class="ui-fail__head"><b class="ui-fail__title">${esc(title)}</b></div>
      <div class="ui-fail__art">${wreckerArt()}<div class="ui-fail__stamp"><span>견인!</span></div></div>
      <div class="ui-fail__body">
        <div class="ui-fail__why"><span class="ui-fail__lbl">사유</span><b class="ui-fail__reason">${esc(reason)}</b></div>
        ${who || lost ? `<div class="ui-fail__meta">${who ? `<span class="ui-fail__who"><i>${SVG.angry}</i>${esc(who)}</span>` : ''}${lost ? `<span class="ui-fail__lost">마지막 한 방 <b>−${lost}</b></span>` : ''}</div>` : ''}
      </div>
      <div class="ui-fail__btns"></div>
    </div>`;
  const bw = P.querySelector('.ui-fail__btns');
  bw.appendChild(btn('ui-btn--yellow ui-btn--lg ui-fail__retry', `<span class="ui-btn__ico">${SVG.retry}</span><span>${esc(retryLabel)}</span><kbd class="ui-fail__kbd">Enter</kbd>`, () => pickFail('retry'), retryLabel));
  bw.appendChild(btn('ui-btn--grey ui-fail__menu', '<span>메뉴</span><kbd class="ui-fail__kbd">Esc</kbd>', () => pickFail('menu'), '메뉴'));
  if (!FS.open) {
    FS.open = true;
    FS.armed = false;
    P.classList.remove('is-armed');
    setShown(P, true);
    try { P.scrollTop = 0; } catch { /* */ }
    // 코어 keydown(Esc = 일시정지 등)으로 새지 않게 캡처 단계에서 막고, 0.45초 뒤부터 반응 (피격 순간 연타 방지)
    FS.onKey = (e) => {
      if (!FS.open) return;
      const enter = e.key === 'Enter' || e.code === 'Enter' || e.code === 'NumpadEnter';
      const esc_ = e.key === 'Escape' || e.code === 'Escape';
      if (!enter && !esc_) return;
      e.preventDefault();
      e.stopImmediatePropagation();
      if (!e.repeat) pickFail(esc_ ? 'menu' : 'retry');
    };
    addEventListener('keydown', FS.onKey, true);
    FS.armT = setTimeout(() => { if (FS.open) { FS.armed = true; P.classList.add('is-armed'); } }, 450);
  }
  if (!FS.promise) FS.promise = new Promise((resolve) => { FS.resolve = resolve; });
  return FS.promise;
}
function hideFail() { closeFail(null); }

// ───────────────────────────── 기타
function setTouchVisible(on) {
  on = !!on;
  if (!on) releaseTouch();
  if (C.touch === on) return;
  C.touch = on;
  R.classList.toggle('ui-root--touch', on);
  setShown(E.touch, on, 240);
}
function setMuted(m) {
  m = !!m;
  C.muted = m;
  for (const b of E.muteBtns) {
    if (b.classList.contains('is-muted') === m) continue;
    b.classList.toggle('is-muted', m);
    b.innerHTML = m ? SVG.speakerOff : SVG.speaker;
  }
}
function setPausedVisible(on) {
  on = !!on;
  if (on) releaseTouch();
  setShown(E.pause, on, 220);
}

// ───────────────────────────── 공개 API
function guard(fn, fallback) {
  return function guarded(...a) {
    try { if (!ensure()) return typeof fallback === 'function' ? fallback() : fallback; return fn(...a); } catch (e) {
      console.error('[ui]', fn.name, e);
      return typeof fallback === 'function' ? fallback() : fallback;
    }
  };
}

export function initUI(handlers) {
  H = handlers && typeof handlers === 'object' ? handlers : {};
  ensure();
}

export const ui = {
  isOverlayOpen: () => { try { return !!overlayOpen(); } catch { return false; } },   // 차고·앨범이 열려 있으면 Enter로 스테이지 시작 금지
  showTitle: guard(showTitle),
  hideTitle: guard(hideTitle),
  showStageCard: guard((s, m, r) => showStageCard(s, m, r), () => Promise.resolve()),
  setHUD: guard(setHUD),
  setNav: guard(setNav),
  showBoss: guard(showBoss),
  hideBoss: guard(hideBoss),
  bubble: guard(bubble),
  removeBubble: guard(removeBubble),
  clearBubbles: guard(clearBubbles),
  popText: guard(popText),
  banner: guard(banner),
  setReleaseCounter: guard(setReleaseCounter),
  showResult: guard(showResult),
  hideResult: guard(hideResult),
  showAlbum: guard(showAlbum),
  hideAlbum: guard(hideAlbum),
  setTouchVisible: guard(setTouchVisible),
  setMuted: guard(setMuted),
  flash: guard(flash),
  vignette: guard(vignette),
  setPausedVisible: guard(setPausedVisible),
  hint: guard(hint),
  // v0.3
  setControls: guard(setControls),
  showShop: guard(showShop),
  hideShop: guard(hideShop),
  refreshShop: guard(refreshShop),
  // v0.4
  setHP: guard(setHP),
  showFail: guard(showFail, () => new Promise((res) => setTimeout(() => res('retry'), 900))),   // UI 고장 시: 갇히지 않게 0.9초 뒤 재도전
  hideFail: guard(hideFail),
  toast: guard(toast),
};
