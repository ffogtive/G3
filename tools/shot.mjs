// 사용법: node tools/shot.mjs <url> <out.png> [--w 1280] [--h 720] [--wait 2500] [--eval "js expr"] [--mobile]
// 콘솔 에러/페이지 에러를 출력하고 스크린샷을 저장한다. (http-server 로 레포 루트를 띄운 상태에서 사용)
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
let pw;
try { pw = require('playwright'); } catch { pw = require('/opt/node22/lib/node_modules/playwright'); }
const args = process.argv.slice(2);
const url = args[0], out = args[1] || 'shot.png';
const opt = (k, d) => { const i = args.indexOf('--' + k); return i >= 0 ? args[i + 1] : d; };
const has = (k) => args.includes('--' + k);
const W = +opt('w', has('mobile') ? 390 : 1280), H = +opt('h', has('mobile') ? 844 : 720);
const wait = +opt('wait', 2500);
const evalJs = opt('eval', null);
const browser = await pw.chromium.launch({
  executablePath: process.env.CHROMIUM_PATH || undefined,
  args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--autoplay-policy=no-user-gesture-required', '--ignore-gpu-blocklist'],
});
const page = await browser.newPage({ viewport: { width: W, height: H }, deviceScaleFactor: 1, hasTouch: has('mobile'), isMobile: has('mobile') });
const errs = [];
page.on('console', (m) => { if (m.type() === 'error' || m.type() === 'warning') errs.push(`[${m.type()}] ${m.text()}`); });
page.on('pageerror', (e) => errs.push(`[pageerror] ${e.message}\n${e.stack || ''}`));
await page.goto(url, { waitUntil: 'load' });
await page.waitForTimeout(wait);
if (evalJs) {
  try { const r = await page.evaluate(evalJs); if (r !== undefined) console.log('eval →', typeof r === 'string' ? r : JSON.stringify(r)); }
  catch (e) { errs.push('[eval] ' + e.message); }
  await page.waitForTimeout(+opt('wait2', 800));
}
await page.screenshot({ path: out });
console.log(errs.length ? errs.join('\n') : '(no console errors)');
console.log('saved', out);
await browser.close();
