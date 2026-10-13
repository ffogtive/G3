// 보상: 블박 제보 카드(도감) · 포상금(재화) · 참교육 채널(구독자/댓글/플레이버튼)
// 가설: "범칙금은 빌런이, 포상금은 내가" — 블박 제보 문화를 그대로 옮기면 설명 없이 통한다 (docs/REWARDS.md)

const COMMENTS = [
  '사이다 ㅋㅋㅋㅋㅋ', '10년 묵은 체증이 내려갔습니다', '이분 국가유공자 지정해라', '형님 고속도로 순찰대 하세요',
  '{v} 보고 혈압 올랐는데 덕분에 내려감', '저 이 구간 매일 다니는데 진짜 저런 차 있음', '비상등 깜빡이는 거 보고 울컥했다',
  '대~한민국 경적 소리 듣고 빵 터짐', '이게 나라다', '타이어 펑크 소리 ASMR로 10시간 부탁드립니다',
  '{v} 본인 등판 기다립니다 ㅋㅋ', '오늘도 참교육 감사합니다', '구독 누르고 갑니다', '1차선은 추월차선입니다 여러분',
  '블박 화질 무엇? 4K임?', '정속주행 아저씨들 이거 보세요', '보는 내가 다 시원하네', '알고리즘이 여기로 데려왔다',
];
export const MILESTONES = [
  [1000, '구독자 1천 돌파!'], [10000, '구독자 1만 돌파!'], [100000, '실버 참교육 버튼 획득!'], [1000000, '골드 참교육 버튼 획득!'],
];

function pick(arr, n, seed) {
  const a = [...arr], out = [];
  let x = seed || 1;
  while (out.length < n && a.length) { x = (x * 9301 + 49297) % 233280; out.push(a.splice(Math.floor((x / 233280) * a.length), 1)[0]); }
  return out;
}

// 빌런 이름: 'OO 1호 & OO 2호' → 'OO 2대' (카드·채널 제목이 넘치지 않게)
export function villainNames(vs) {
  const names = (vs || []).map((v) => v.name);
  if (names.length > 1 && names.every((n) => / [1-3]호$/.test(n))) return `${names[0].replace(/ [1-3]호$/, '')} ${names.length}대`;
  return names.join(' & ');
}

// r: { stars, cath, freed, bumps, cheaters }
export function computeReward(stage, r, seed = 1) {
  const fine = stage.fine ?? 30000;              // 카드 표시: 실제 범칙금·벌금
  const base = stage.payout ?? fine;             // 포상금 기준(게임값): 형사 카드는 벌금 대신 30만~100만
  const mult = [1, 1, 1.5, 2][r.stars] || 1;
  const bonus = (r.cheaters || 0) * 10000 + (r.miniFines || 0);
  const payout = Math.round(((base * mult + bonus) * (r.payMult || 1)) / 100) * 100;
  const views = Math.round((r.freed * 38 + r.cath * 950) * (0.85 + ((seed * 7919) % 100) / 300));
  const subsGain = Math.max(12, Math.round(views * 0.011));
  const vName = villainNames(stage.villains);
  const comments = pick(COMMENTS, 3, seed + stage.id * 31).map((c) => c.replace('{v}', vName));
  return { fine, payout, bonus, views, subsGain, comments, violation: stage.violation || '도로교통법 위반', villainName: vName, stars: r.stars, card: stage.card || '고지서' };
}

// progress 갱신. 반환: { milestone: string|null }
export function applyReward(progress, stage, reward, photo) {
  progress.wallet = (progress.wallet || 0) + reward.payout;
  const before = progress.subs || 0;
  progress.subs = before + reward.subsGain;
  progress.album = progress.album || {};
  const prev = progress.album[stage.id];
  if (!prev || reward.stars >= (prev.stars || 0)) {
    progress.album[stage.id] = { stars: Math.max(reward.stars, prev?.stars || 0), fine: reward.fine, photo: photo || prev?.photo || null, at: Date.now(), count: (prev?.count || 0) + 1 };
  } else {
    prev.count = (prev.count || 0) + 1;
  }
  let milestone = null;
  for (const [n, label] of MILESTONES) if (before < n && progress.subs >= n) milestone = label;
  return { milestone };
}

export const won = (n) => '₩' + Math.round(n).toLocaleString('ko-KR');
export const shortNum = (n) => (n >= 10000 ? (n / 10000).toFixed(n >= 100000 ? 0 : 1) + '만' : n.toLocaleString('ko-KR'));
