#!/bin/sh
# game/dev/core-mixed.html 생성: 실제 모듈이 있으면 실제, 없으면 stub 으로 매핑 (점진 통합 테스트용)
cd "$(dirname "$0")/.." || exit 1
MAP='"three":"../../node_modules/three/build/three.module.js","three/addons/":"../../node_modules/three/examples/jsm/"'
for m in vehicles scenery fx audio ui; do
  if [ ! -f "game/js/$m.js" ] || [ "$FORCE_STUB" = "1" ]; then MAP="$MAP,\"/game/js/$m.js\":\"/game/dev/stubs/$m.js\""; echo "stub: $m"; else echo "real: $m"; fi
done
CSS=''; [ -f game/css/style.css ] && CSS='<link rel="stylesheet" href="../css/style.css">'
cat > game/dev/core-mixed.html <<HTML
<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover"><title>core mixed</title>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Black+Han+Sans&family=Jua&display=swap">$CSS
<style>html,body{margin:0;height:100%;overflow:hidden}canvas#game{position:fixed;inset:0;width:100%;height:100%}</style>
<script type="importmap">{"imports":{$MAP}}</script>
</head><body><canvas id="game"></canvas><div id="ui"></div><div id="boot"></div>
<script type="module" src="/game/js/main.js"></script></body></html>
HTML
