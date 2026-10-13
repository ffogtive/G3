// game/js/data/villain_catalog.json → villain_catalog.js (ES 모듈; 빌드 없이도, 번들에도 그대로 포함)
import { readFileSync, writeFileSync } from 'fs';
const src = new URL('../game/js/data/villain_catalog.json', import.meta.url);
const dst = new URL('../game/js/data/villain_catalog.js', import.meta.url);
const data = JSON.parse(readFileSync(src, 'utf8'));
writeFileSync(dst, `// 자동 생성: node tools/catalog2js.mjs (원본 villain_catalog.json)\nexport default ${JSON.stringify(data)};\n`);
console.log('villains', data.villains?.length, 'chapters', data.chapters?.length);
