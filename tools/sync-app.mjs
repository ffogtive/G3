// 게임 빌드 결과를 Flutter 앱 에셋으로 복사
//  dist/index.html → app/assets/web/index.html
// 사용: npm run build:app   (= npm run build && node tools/sync-app.mjs)
import { copyFileSync, existsSync, mkdirSync, readFileSync, statSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, relative, resolve } from 'path';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const src = resolve(root, 'dist/index.html');
const dstDir = resolve(root, 'app/assets/web');
const dst = resolve(dstDir, 'index.html');

if (!existsSync(src)) {
  console.error(`[sync-app] ${relative(root, src)} 없음 — 먼저 npm run build`);
  process.exit(1);
}
const html = readFileSync(src, 'utf8');
// 앱은 이 파일 하나만 서빙한다 → 상대 경로 리소스(./x.js 등)가 섞이면 앱에서 404.
if (!html.includes('<canvas id="game"') || /<script[^>]+src=["'](?!https?:)/i.test(html)) {
  console.error('[sync-app] dist/index.html 이 단일 파일 번들이 아님 (canvas 없음 또는 로컬 script src 참조)');
  process.exit(1);
}
mkdirSync(dstDir, { recursive: true });
copyFileSync(src, dst);
console.log(`[sync-app] ${relative(root, src)} → ${relative(root, dst)} (${(statSync(dst).size / 1024).toFixed(0)}KB)`);
