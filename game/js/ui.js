// ui.js — DOM HUD · 타이틀 · 스테이지 카드 · 결과 · 일시정지 · 터치 컨트롤
//
// 가설: 클래시/길건너친구들 풍 통통한 DOM UI + 한국 도로표지 모티프(녹색 표지판, 고속도로 방패 번호)가
//      목업의 첫인상과 "쾌감 연출"(뻥 뚫렸다!!, 해방 카운터, 참교육 완료 도장)을 책임진다.
//
// 규칙
//  - #ui 루트 안에 전부 동적으로 생성. 클래스 접두사 'ui-'.
//  - 매 프레임 호출(setHUD/setNav/showBoss/bubble/vignette)은 값이 바뀔 때만 DOM 을 건드린다.
//  - 어떤 순서로 호출해도 throw 하지 않는다 (모든 메서드 guard + 지연 빌드).
//  - 게임플레이 키는 바인딩하지 않는다 (core 담당). 스테이지 카드 스킵용 keydown 만 잠깐 듣는다.

// ───────────────────────────── 유틸
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
function stageTitle(s) { return String(s?.title || '').replace(/\s*\(최종보스\)\s*/, ''); }
const isFinalBoss = (s) => /최종보스/.test(String(s?.title || ''));

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
  E.world = R.appendChild(el('div', 'ui-world'));

  // HUD: 좌상 스테이지 칩
  E.chip = R.appendChild(el('div', 'ui-chip ui-hudpart'));
  // 상단 중앙 스택: 내비 → 원흉 거리 / 보스 바 → 힌트
  E.top = R.appendChild(el('div', 'ui-topstack'));
  buildNav();
  E.dist = E.top.appendChild(el('div', 'ui-dist ui-hudpart', `<span class="ui-dist__ico">${SVG.angry}</span><span class="ui-dist__l">원흉까지</span><b class="ui-dist__n">0</b><span class="ui-dist__u">m</span>`));
  E.distNum = E.dist.querySelector('.ui-dist__n');
  buildBoss();
  E.hint = E.top.appendChild(el('div', 'ui-hint', '<span class="ui-hint__ico">💡</span><span class="ui-hint__t"></span>'));
  E.hint.hidden = true;
  E.hintText = E.hint.querySelector('.ui-hint__t');

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
  E.album = R.appendChild(el('div', 'ui-screen ui-album'));
  E.album.hidden = true;
  E.album.addEventListener('click', () => hideAlbum());   // 책 바깥(배경) 탭 = 닫기
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
    hud: false, phase: null, speed: -1, fast: null, dist: -1, rage: -1, segF: [-1, -1, -1], rageInit: false, full: null, ready: null,
    score: -1, combo: -1, navP: -1, navR: -1, navDone: null, navFull: null,
    boss: false, bossName: null, hp: -1, lag: 1, lagShown: -1, lastHit: 0, lastBossT: 0, tires: -1,
    rel: null, relShown: 0, vig: -1, muted: null, touch: false, fireMode: null,
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
    <div class="ui-speedo__needle"></div><div class="ui-speedo__hub"></div>
    <div class="ui-speedo__read"><b class="ui-speedo__n">0</b><span class="ui-speedo__u">km/h</span></div>`));
  E.speedNum = E.speedo.querySelector('.ui-speedo__n');
  E.needle = E.speedo.querySelector('.ui-speedo__needle');
}

function buildRage() {
  E.rageEl = R.appendChild(el('div', 'ui-rage ui-hudpart',
    `<span class="ui-rage__ico">${SVG.flame}</span>`
    + '<div class="ui-rage__main"><span class="ui-rage__l">분노<em class="ui-rage__key">R 미사일!</em></span><div class="ui-rage__segs">'
    + '<span class="ui-rage__seg"><i></i></span><span class="ui-rage__seg"><i></i></span><span class="ui-rage__seg"><i></i></span>'
    + '</div></div><b class="ui-rage__max">MAX</b>'));
  E.segs = [...E.rageEl.querySelectorAll('.ui-rage__seg')];
  E.segFill = E.segs.map((s) => s.firstElementChild);
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
}
function releaseTouch() {
  for (const t of touchBtns) {
    if (t.st.ids.size) { t.st.ids.clear(); t.b.classList.remove('is-down'); call('onControl', t.name, false); }
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
  // 분노 3칸
  const rq = q(clamp(num(s.rage), 0, 1), 300);
  if (rq !== C.rage) {
    const prev = C.rageInit ? Math.floor(C.rage * 3 + 1e-6) : 99;
    C.rage = rq;
    C.rageInit = true;
    for (let i = 0; i < 3; i++) {
      const f = q(clamp(rq * 3 - i, 0, 1), 100);
      if (f !== C.segF[i]) {
        C.segF[i] = f;
        E.segFill[i].style.transform = `scaleX(${f})`;
        E.segs[i].classList.toggle('is-on', f >= 1);
      }
    }
    const segs = Math.floor(rq * 3 + 1e-6);
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

// ───────────────────────────── 타이틀 (챕터 × 스테이지, 지갑/구독자 칩, 제보 앨범)
// 가설: 100 스테이지도 "챕터 탭 + 현재 챕터 10칸"만 그리면 한눈에 들어오고 빠르다.
const TS = { stages: [], progress: null, chapters: null, P: null, groups: [], unlocked: 1, startIdx: 0, grid: false, multi: false, active: -1, list: null, head: null, tabs: null };

function readProgress(progress) {
  const pr = progress && typeof progress === 'object' ? progress : {};
  const obj = (o) => (o && typeof o === 'object' ? o : {});
  return { pr, stars: obj(pr.stars), best: obj(pr.best), album: obj(pr.album), wallet: Math.max(0, num(pr.wallet)), subs: Math.max(0, num(pr.subs)) };
}
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
  const locked = i >= TS.unlocked;
  const stars = starsOf(P, s);
  const best = Math.round(num(P.best[s?.id]));
  const fin = isFinalBoss(s);
  let st = '';
  for (let k = 0; k < 3; k++) st += `<span class="ui-star ${k < stars ? 'is-on' : ''}">${SVG.star}</span>`;
  const cls = `ui-stagecard${opts.compact ? ' ui-stagecard--sm' : ''}${locked ? ' is-locked' : ''}${i === TS.startIdx ? ' is-next' : ''}${stars > 0 ? ' is-cleared' : ''}${fin ? ' is-final' : ''}`;
  const meta = best > 0 ? 'BEST ' + fmt(best) : (locked ? '' : (s?.displayKm != null ? '정체 ' + esc(s.displayKm) + 'km' : ''));
  return `<button type="button" class="${cls}" data-i="${i}" style="--i:${opts.k}">
      <span class="ui-stagecard__head">${shieldHTML(s?.route, 'ui-shield--card')}<span class="ui-stagecard__hw"><b>${esc(s?.highway)}</b><span>${esc(s?.direction)}</span></span></span>
      <span class="ui-stagecard__body">
        <span class="ui-stagecard__no">${label}${fin ? '<em>최종보스</em>' : ''}</span>
        <span class="ui-stagecard__title">${esc(stageTitle(s))}</span>
        <span class="ui-stagecard__meta"><span class="ui-stars">${st}</span><span class="ui-stagecard__best">${meta}</span></span>
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
    const label = TS.multi ? `STAGE ${g.no}-${k + 1}` : `STAGE ${i + 1}`;
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
      + `<span class="ui-chaphead__stat"><span class="ui-star is-on">${SVG.star}</span><b>${got}</b>/${g.idx.length * 3}<i>·</i>${cleared}/${g.idx.length} 클리어</span>`;
    if (smooth) anim(TS.head, KF.bump, { duration: 260, easing: 'cubic-bezier(.3,1.7,.5,1)' });
  }
  if (TS.tabs && TS.tabs._setActive) TS.tabs._setActive(g.no, smooth);
}

function albumGot(P, s) {
  const a = P.album[s?.id];
  if (a && typeof a === 'object' && (num(a.count) > 0 || num(a.stars) > 0 || okSrc(a.photo))) return true;
  return starsOf(P, s) > 0; // 앨범 도입 전 세이브: 클리어 = 수집
}

function showTitle(stages, progress, chapters) {
  stages = Array.isArray(stages) ? stages : [];
  const P = readProgress(progress);
  const n = stages.length;
  const unlocked = clamp(Math.round(num(P.pr.unlocked, 1)) || 1, 1, Math.max(1, n));
  const startIdx = clamp(unlocked - 1, 0, Math.max(0, n - 1));

  finishCard();
  setHudOn(false);
  hideBoss();
  clearBubbles();
  setTouchVisible(false);
  setPausedVisible(false);
  setShown(E.result, false);
  hideAlbum();
  setReleaseCounter(null);
  C.phase = null; delete R.dataset.phase;

  const groups = groupChapters(stages, chapters);
  const multi = groups.length > 1;
  Object.assign(TS, { stages, progress, chapters: Array.isArray(chapters) ? chapters : null, P, groups, unlocked, startIdx, multi, grid: multi || n > 6, active: -1, list: null, head: null, tabs: null });

  const T = E.title;
  T.textContent = '';
  T.classList.toggle('ui-title--chapters', TS.grid);
  E.muteBtns = E.muteBtns.filter((b) => b.isConnected && !T.contains(b));
  const top = T.appendChild(el('div', 'ui-title__bar'));
  top.appendChild(makeMuteBtn('ui-title__mute'));

  // 지갑 · 구독자 칩
  T.appendChild(el('div', 'ui-purse',
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
    if (!isShown(E.title) || isShown(E.album)) return;
    call('onStartStage', i);
  });

  const s0 = stages[startIdx];
  const g0 = groups.find((g) => g.idx.includes(startIdx)) || groups[0];
  const k0 = g0 ? g0.idx.indexOf(startIdx) : startIdx;
  const go = wrap.appendChild(el('div', 'ui-title__go'));
  go.appendChild(btn('ui-btn--yellow ui-btn--xl ui-title__start',
    `<span class="ui-btn__main">START <span class="ui-btn__arrow">▶</span></span><span class="ui-btn__sub">${s0 ? `STAGE ${multi ? `${g0.no}-${k0 + 1}` : startIdx + 1} · ${esc(stageTitle(s0))}` : ''}</span>`,
    () => { if (isShown(E.title) && !isShown(E.album)) call('onStartStage', startIdx); }));
  const got = stages.filter((s) => albumGot(P, s)).length;
  go.appendChild(btn('ui-btn--blue ui-title__album',
    `<span class="ui-title__albumico">${SVG.album}</span><span class="ui-title__albumtxt"><span>제보 앨범</span><small><b>${got}</b>/${n}</small></span>`,
    () => { if (isShown(E.title)) showAlbum(); }, '제보 앨범'));
  wrap.appendChild(el('div', 'ui-help',
    '<span class="ui-help__row"><b>PC</b><kbd>←</kbd><kbd>→</kbd> 차선 · <kbd>Space</kbd> 발사/경적 · <kbd>R</kbd> 분노 미사일</span>'
    + '<span class="ui-help__row"><b>모바일</b> 버튼 · 스와이프</span>'));

  setShown(T, true);
  renderChapter(g0 ? g0.no : 1, false);
  try { T.scrollTop = 0; } catch { /* */ }
}
function hideTitle() { hideAlbum(); setShown(E.title, false, 320); }

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
  return `<div class="ui-acard ui-acard--r${rar}${has ? ' is-got' : ''}" style="--i:${k}">
    <div class="ui-acard__top"><span class="ui-acard__no">${label}</span><span class="ui-stars">${st}</span></div>
    <div class="ui-acard__pic">${pic}${has ? '<span class="ui-acard__rec"><i></i>REC</span>' : '<span class="ui-acard__q">?</span><span class="ui-acard__wait">제보 대기 중</span>'}</div>
    <div class="ui-acard__name">${esc(stageTitle(s))}</div>
    <div class="ui-acard__who">${has && vname ? esc(vname) : (s?.highway ? esc(s.highway) : '&nbsp;')}</div>
    <div class="ui-acard__meta"><span class="ui-acard__fine">${has ? won(fine) : '₩ ?'}</span><span class="ui-acard__cnt">${has ? `×${fmt(count)} 참교육` : '미검거'}</span></div>
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
    ? `<span class="ui-chaphead__no">CHAPTER ${esc(g.no)}</span><span class="ui-chaphead__txt"><b>${esc(chName(g))}</b>${g.meta?.setting ? `<span class="ui-chaphead__set">${esc(g.meta.setting)}</span>` : ''}</span><span class="ui-chaphead__stat"><b>${c}</b>/${g.idx.length} 수집${c === g.idx.length && c > 0 ? ' · <em>챕터 완성!</em>' : ''}</span>`
    : `<span class="ui-chaphead__txt"><b>참교육 기록</b><span class="ui-chaphead__set">빌런을 퇴치하면 블박 캡처 카드가 한 장씩 쌓입니다</span></span><span class="ui-chaphead__stat"><b>${c}</b>/${g.idx.length} 수집</span>`;
  if (AS.tabs && AS.tabs._setActive) AS.tabs._setActive(g.no, smooth);
  try { AS.page.scrollTop = 0; } catch { /* */ }
}

function hideAlbum() {
  if (!E.album || !isShown(E.album)) return;
  setShown(E.album, false, 240);
  call('onAlbum', false);
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
function showStageCard(stage) {
  finishCard();
  const s = stage || {};
  setStage(stage);
  setHudOn(false);
  hideAlbum();
  setShown(E.title, false, 320);
  setShown(E.result, false);
  const idx = Number.isFinite(+s.id) ? +s.id : '';
  E.card.innerHTML = `
    <div class="ui-card__panel${isFinalBoss(s) ? ' is-final' : ''}">
      <div class="ui-sign ui-sign--card">${shieldHTML(s.route, 'ui-shield--big')}<span class="ui-sign__txt"><b>${esc(s.highway)}</b><span>${esc(s.direction)} <i class="ui-sign__dirarrow">▶</i></span></span></div>
      <div class="ui-card__body">
        <div class="ui-card__no">STAGE ${esc(idx)}${isFinalBoss(s) ? ' · <em>최종보스</em>' : ''} <span class="ui-card__tag">${SVG.angry}오늘의 빌런</span></div>
        <div class="ui-card__title">${esc(stageTitle(s))}</div>
        <div class="ui-card__line">${esc(String(s.villainLine || '').replace(/^"|"$/g, ''))}</div>
        <div class="ui-card__blurb">${esc(s.blurb)}</div>
        <div class="ui-card__jam"><span class="ui-card__jamtag">정체</span><b>${esc(s.displayKm ?? '?')}km</b>${s.villainSpeedLabel ? `<span class="ui-card__spd">원흉 ${esc(s.villainSpeedLabel)}</span>` : ''}</div>
      </div>
      <div class="ui-card__tap">탭하여 바로 시작</div>
      <div class="ui-card__timer"><i></i></div>
    </div>`;
  setShown(E.card, true);
  return new Promise((resolve) => {
    const st = { resolve, timer: 0, arm: 0, onKey: null, onTap: null };
    st.onKey = (e) => { if (!e.repeat) finishCard(); };
    st.onTap = (e) => { e.preventDefault(); finishCard(); };
    cardState = st;
    st.timer = setTimeout(finishCard, 2600);
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
const later = (ms, fn) => { resT.push(setTimeout(() => { try { fn(); } catch (e) { console.error('[ui] result', e); } }, reduceMotion ? 0 : ms)); };
function showResult(r) {
  r = r || {};
  finishCard();
  setHudOn(false);
  hideBoss();
  clearBubbles();
  setPausedVisible(false);
  hideAlbum();
  clearResultTimers();
  if (r.reward && typeof r.reward === 'object') { showRewardResult(r, r.reward); return; }
  const stars = clamp(Math.round(num(r.stars)), 0, 3);
  const score = Math.max(0, Math.round(num(r.score)));
  const stats = Array.isArray(r.stats) ? r.stats : [];
  const S = C.stage;
  const P = E.result;
  P.textContent = '';
  const panel = P.appendChild(el('div', 'ui-result__panel'));
  panel.innerHTML = `
    <div class="ui-sign ui-sign--result">${S ? shieldHTML(S.route, 'ui-shield--chip') : ''}<span class="ui-sign__txt"><b>${esc(r.stageName)}</b></span></div>
    <div class="ui-result__body">
      <div class="ui-result__who"><span class="ui-result__lbl">참교육 대상</span><span class="ui-result__villain"><span>${esc(r.villainName)}</span></span></div>
      <div class="ui-stamp"><span>참교육 완료!</span></div>
      <div class="ui-result__stars">${[0, 1, 2].map((k) => `<span class="ui-star ui-star--big ${k < stars ? 'is-on' : ''}">${SVG.star}</span>`).join('')}</div>
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
  popStars(panel, stars);
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
  const mult = fine > 0 ? (payout - bonus) / fine : 0;
  const multTxt = mult > 0 && Number.isFinite(mult) ? '×' + (Math.round(mult * 10) / 10) : '';
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
        <span class="ui-cmt__meta"><b>@${esc(nick)}</b><span>${['방금 전', '1분 전', '2분 전'][k]}</span></span>
        <span class="ui-cmt__t">${esc(c)}</span>
        <span class="ui-cmt__act"><span class="ui-cmt__like">${SVG.thumb}<b>${kor(likes)}</b></span>${k === 0 ? `<span class="ui-cmt__heart">${SVG.heart}<small>채널 주인</small></span>` : ''}</span>
      </span>
    </li>`;
  });

  panel.innerHTML = `
    <div class="ui-sign ui-sign--result">${S ? shieldHTML(S.route, 'ui-shield--chip') : ''}<span class="ui-sign__txt"><b>${esc(r.stageName)}</b></span></div>
    <div class="ui-result__scroll">
      <div class="ui-rw">
        <div class="ui-rw__col ui-rw__col--l">
          <section class="ui-dash">
            <div class="ui-dash__head"><span class="ui-dash__ico">${SVG.cam}</span><b>블박 제보 접수</b><span class="ui-dash__no">No.${no}</span></div>
            <div class="ui-dash__cam"><div class="ui-dash__screen">
              ${photo ? '' : art}
              <div class="ui-dash__scan"></div>
              <div class="ui-dash__osd ui-dash__osd--tl"><span class="ui-dash__rec"><i></i>REC</span><span>${clock(d)}</span></div>
              <div class="ui-dash__osd ui-dash__osd--tr">CH1 FRONT</div>
              <div class="ui-dash__osd ui-dash__osd--bl"><span class="ui-dash__spd">${spd}<small>km/h</small></span><span class="ui-dash__lane">${lane}차로</span></div>
              <div class="ui-dash__osd ui-dash__osd--br"><span class="ui-dash__evt">충격감지</span></div>
              <div class="ui-dash__shutter"></div>
            </div></div>
            <div class="ui-dash__foot">
              <span class="ui-dash__lbl">위반 차량</span>
              <b class="ui-dash__villain"><span>${esc(vName)}</span></b>
              ${cause ? `<span class="ui-dash__cause">제보 사유 · ${esc(cause)}</span>` : ''}
              <span class="ui-dash__done">${SVG.check}<span>처리 결과: 참교육 완료</span></span>
            </div>
            <div class="ui-fine" style="--d:${TL.stamp}ms">
              <span class="ui-fine__t">과태료 고지서</span>
              <span class="ui-fine__v">${esc(violation)}</span>
              <span class="ui-fine__amt">범칙금 <b>${won(fine)}</b></span>
              <span class="ui-fine__seal"><span>참교</span><span>육청</span></span>
            </div>
          </section>
          ${rest.length ? '<div class="ui-stats ui-stats--mini"></div>' : ''}
        </div>
        <div class="ui-rw__col ui-rw__col--r">
          <section class="ui-rate">
            <div class="ui-result__stars">${starsHTML}</div>
            <div class="ui-rate__side">
              <div class="ui-rate__score"><span>SCORE</span><b>0</b></div>
              ${hero ? `<div class="ui-rate__hero"><span class="ui-rate__hl">${esc(hero.label)}</span><b>${esc(hero.value)}</b><span class="ui-stat__bar"><i style="--w:${heroW}"></i></span></div>` : ''}
            </div>
            ${r.isLast ? '<div class="ui-result__final">🎉 전 구간 소통 원활! 모든 빌런 참교육 완료 🎉</div>' : ''}
          </section>
          <section class="ui-money" style="--d:${TL.money}ms">
            <div class="ui-money__flow">
              <span class="ui-money__box ui-money__box--fine"><small>범칙금 · 빌런 부담</small><b>${won(fine)}</b></span>
              <span class="ui-money__arrow">${ARROW}${multTxt ? `<em>★${esc(multTxt)}</em>` : ''}</span>
              <span class="ui-money__box ui-money__box--pay"><small>포상금 · 내 몫</small><b class="ui-money__pay">+${won(0)}</b></span>
            </div>
            ${bonus ? `<div class="ui-money__bonus">+ 갓길 얌체 신고 보너스 <b>${won(bonus)}</b> 포함</div>` : ''}
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
              <span class="ui-chan__vt"><b>[블박] ${esc(vName || '빌런')} 참교육 현장 (사이다 주의)</b>
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

  popStars(panel, stars);
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
    const chan = panel.querySelector('.ui-chan');
    const over = chan.getBoundingClientRect().top + Math.min(chan.offsetHeight, 150) - sc.getBoundingClientRect().bottom;
    if (over > 4) try { sc.scrollTo({ top: sc.scrollTop + over + 8, behavior: reduceMotion ? 'auto' : 'smooth' }); } catch { sc.scrollTop += over + 8; }
  });
  if (mile) {
    later(TL.mile, () => { mile.hidden = false; panel.querySelector('.ui-chan__badge')?.classList.add('is-on'); });
    later(TL.mile + 4200, closeMile);
  }
}
function hideResult() { clearResultTimers(); setShown(E.result, false, 300); }

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
  showTitle: guard(showTitle),
  hideTitle: guard(hideTitle),
  showStageCard: guard((s) => showStageCard(s), () => Promise.resolve()),
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
};
