// 자동 플레이테스트: 모든(또는 지정) 스테이지를 오토파일럿 + 빨리감기로 끝까지 돌려 페이즈 타이밍/에러를 리포트
// 사용법: node tools/playtest.mjs [--page game/index.html] [--stages 1,2,3,4,5] [--ff 6] [--shots dir] [--mobile] [--timeout 240]
// (레포 루트를 http://localhost:8090 에서 서빙 중이어야 함: npx http-server . -p 8090 -c-1 -s)
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
let pw; try { pw = require('playwright'); } catch { pw = require('/opt/node22/lib/node_modules/playwright'); }
const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf('--' + k); return i >= 0 ? args[i + 1] : d; };
const page0 = opt('page', 'game/index.html');
const stages = opt('stages', '1,2,3,4,5').split(',').map(Number);
const ff = +opt('ff', 6);
const shots = opt('shots', null);
const mobile = args.includes('--mobile');
const base = opt('base', 'http://localhost:8090');
const limitMs = +opt('timeout', 240) * 1000;   // 스테이지당 벽시계 제한(초). 병렬 실행 시 늘릴 것
const browser = await pw.chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--autoplay-policy=no-user-gesture-required'] });
const report = [];
for (const st of stages) {
  const page = await browser.newPage({ viewport: mobile ? { width: 390, height: 844 } : { width: 960, height: 540 }, hasTouch: mobile, isMobile: mobile });
  const errs = [];
  page.on('pageerror', (e) => errs.push('pageerror: ' + e.message));
  page.on('console', (m) => { if (m.type() === 'error') errs.push('console: ' + m.text()); });
  await page.goto(`${base}/${page0}?stage=${st}&auto=1&mute=1&ff=${ff}`);
  const phases = {}; let last = null; const t0 = Date.now(); let final = null;
  while (Date.now() - t0 < limitMs) {
    await page.waitForTimeout(700);
    const s = await page.evaluate(() => { const G = window.__game; if (!G || !G.objs) return null; return { ph: G.phase, t: G.time, bumps: G.bumps, rage: G.rage, supers: G.supers, hp: G.objs.boss.hpFrac(), php: G.hp, fails: G.fails || 0, err: G.lastError || null, fps: G.fps }; });
    if (!s) continue;
    if (s.ph !== last) {
      phases[s.ph] = +s.t.toFixed(1); last = s.ph;
      if (shots) await page.screenshot({ path: `${shots}/s${st}-${s.ph}.png` });
    }
    if (s.err) errs.push('update: ' + s.err.slice(0, 300));
    final = s;
    if (s.ph === 'result') { await page.waitForTimeout(1500); if (shots) await page.screenshot({ path: `${shots}/s${st}-result.png` }); break; }
  }
  report.push({ stage: st, phases, bumps: final?.bumps, supers: final?.supers, playerHp: final?.php, fails: final?.fails, done: final?.ph === 'result', errors: [...new Set(errs)].slice(0, 8) });
  console.log(JSON.stringify(report[report.length - 1]));
  await page.close();
}
await browser.close();
const bad = report.filter((r) => !r.done || r.errors.length);
console.log(bad.length ? `FAIL ${bad.length}/${report.length}` : `PASS ${report.length}/${report.length}`);
process.exit(bad.length ? 1 : 0);
