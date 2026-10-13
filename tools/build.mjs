// 단일 파일 번들 빌드
//  dist/index.html    : 완전한 HTML 문서 (더블클릭으로 바로 실행 가능)
//  dist/artifact.html : claude.ai Artifact 용 (doctype/html/head/body 없이 본문만)
import { build } from 'esbuild';
import { readFileSync, writeFileSync, mkdirSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, resolve } from 'path';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const r = await build({
  entryPoints: [resolve(root, 'game/js/main.js')],
  bundle: true, format: 'iife', minify: true, write: false, target: ['es2020'],
  legalComments: 'none', logLevel: 'warning',
});
let js = r.outputFiles[0].text.replace(/<\/script/gi, '<\\/script');
const css = readFileSync(resolve(root, 'game/css/style.css'), 'utf8');
const fonts = '<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin><link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Black+Han+Sans&family=Jua&display=swap" media="print" onload="this.media=\'all\'">';
const bodyInner = `<canvas id="game"></canvas><div id="ui"></div><div id="boot">로딩 중…</div>\n<script>${js}</script>`;
mkdirSync(resolve(root, 'dist'), { recursive: true });
const full = `<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover"><title>1차선 참교육</title>${fonts}<style>${css}</style></head><body>${bodyInner}</body></html>`;
writeFileSync(resolve(root, 'dist/index.html'), full);
const art = `<title>1차선 참교육</title>\n${fonts}\n<style>${css}</style>\n${bodyInner}\n`;
writeFileSync(resolve(root, 'dist/artifact.html'), art);
console.log('built dist/index.html', (full.length / 1024).toFixed(0) + 'KB', '| dist/artifact.html', (art.length / 1024).toFixed(0) + 'KB');
