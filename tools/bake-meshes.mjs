#!/usr/bin/env node
// tools/bake-meshes.mjs — bakes the FROZEN web build's vertex-colour geometry for the native port
//                         (docs/NATIVE_PORT.md 3-6 content pipeline, 3-7 mesh pipeline, M1a bake set).
//
// 가설: ✅ vehicles.js / scenery.js / shoulder.js 의 모든 M1a 모델은 Node(three@0.170)에서 원본 그대로 만들어지고,
//       메시를 걸어 다니며(이름·재질로 분류) 뽑은 삼각형만으로 Godot에서 같은 모양·같은 색을 다시 만들 수 있다.
//       ✅ 램프는 "켜질 때만 보이는 메시"라서 연결 성분(박스) 단위로 L/R/C · 앞/뒤 파트를 가를 수 있다.
//       ❓ 정점 레이캐스트 AO(별도 채널, 토글)가 Mobile 렌더러(SSAO 없음)에서 '웹보다 나은' 접지감을 준다 — 기기 판정 대기.
//
// What it does
//   1. Imports the UNMODIFIED game/js/{vehicles,scenery,shoulder}.js in Node with a canvas stub (text panels keep their
//      UV'd quad, the text itself is generated in Godot — NATIVE_PORT 3-7 (2)). A module load hook appends one line to
//      vehicles.js *in memory* (`export const __BAKE__ = { KINDS, GB, wheelParts }`) so the bake can tell which body
//      triangles are the merged (non-detailed) wheels; the file on disk is never touched.
//   2. Walks each built Object3D and routes every mesh to (node, surface, part): nodes = the main mesh plus pivoted
//      sub-meshes (detailed wheels, driver, cannon); surfaces = body | lamps | glass | fx | panel; parts = PART_IDS.
//      Lamp meshes (brake/head/hazard/blinkL/blinkR) are split into L/R/C and front/rear by connected component.
//   3. Fits a paint shade factor per vertex (NPC runtime tint, 3-7: "NPC 도색은 런타임 tint") by re-building each
//      vehicle with probe colours and checks the fit against all 15 NPC colours.
//   4. Welds identical vertices (position+normal+colour+custom+uv+part), bakes per-vertex hemisphere ray-cast AO against
//      the model's own opaque triangles (+ a ground plane for props) into a separate channel.
//   5. Writes <out>/<category>/<name>.json (header) + <name>.bin (buffers) and <out>/index.json.
//      Then: godot47 --headless --path native -s res://tools/import_meshes.gd -- --in=<out>
//
// Conventions (the contract with native/tools/import_meshes.gd; documented in native/assets/README.md)
//   - Right-handed, Y up, −Z forward, metres (web == Godot, NATIVE_PORT 3-4). Index triangles are written CCW
//     (Three/glTF front faces); the importer flips them to Godot's CW front faces.
//   - normal: flat face normal of the CCW triangle (what Three's flatShading derives per fragment).
//   - color: sRGB-encoded RGBA8. Godot stores ARRAY_COLOR as RGBA8 (measured on 4.7.2: 0.001 linear → 0), so linear
//     8-bit would crush dark paint; sRGB8 reproduces every web hex exactly. Materials use vertex_color_is_srgb=true.
//     (Deviation from NATIVE_PORT 3-4 "vertex_color_is_srgb=false", which assumed float storage.)
//   - custom0 (float32×4 here → RGBA_HALF in Godot): x = AO visibility (1 = open sky), y = part id (PART_IDS),
//     z = paint shade factor k (0 = fixed colour; srgb = shade(paint, k) exactly like vehicles.js shade()),
//     w = height-AO factor already multiplied into color (0.7+0.3·smoothstep(0.06,1.05,y) on vehicle bodies, else 1).
//
// Usage
//   node tools/bake-meshes.mjs [--out=native/build/bake] [--only=sedan,tree] [--list] [--no-ao] [--rays=N] [--ao-dist=m] [--quiet]
//   node tools/bake-meshes.mjs --web-sheet=<layout.json> --png=<out.png> [--url=http://localhost:8090]
//        Renders a contact-sheet layout written by native/tools/contact_sheet.gd with the REAL web builders and
//        materials (Playwright Chromium, SwiftShader) so the Godot sheet can be compared pixel by pixel.
//   node tools/bake-meshes.mjs --web-textures=<dir> [--url=…]
//        Extracts the text-free canvas textures the baked panels reference (acrylic sound-barrier panel) as PNG.
import { register } from 'node:module';
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { dirname, resolve, join, relative } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const GAME_JS = resolve(ROOT, 'game/js');
const VEHICLES_URL = pathToFileURL(resolve(GAME_JS, 'vehicles.js')).href;
const WEB_FROZEN_SHA = '753549a';
const SCHEMA = 1;

const argv = process.argv.slice(2);
const flag = (k) => argv.includes(`--${k}`);
const opt = (k, d) => { const a = argv.find((x) => x.startsWith(`--${k}=`)); return a ? a.slice(k.length + 3) : d; };
const log = (...a) => { if (!flag('quiet')) console.error(...a); };

// ───────────────────────────── part ids (custom0.y). Stable contract: append only.
export const PART_IDS = Object.freeze({
  body: 0,
  brake_L: 1, brake_R: 2, brake_C: 3,                 // tail/brake lamps (C = centre high-mount / bar)
  head_L: 4, head_R: 5, head_C: 6,                    // headlights (C = taxi roof sign)
  hazard_FL: 7, hazard_FR: 8, hazard_RL: 9, hazard_RR: 10, hazard_FC: 11, hazard_RC: 12, // amber lamps (setHazard)
  blink_FL: 13, blink_FR: 14, blink_RL: 15, blink_RR: 16, // exaggerated turn signals (setBlinker), L = −X
  glow: 17,                                           // always-lit emissive (MAT.glow / scenery glow)
  siren_R: 18, siren_B: 19, strobe_0: 20, strobe_1: 21,
  beam: 24,                                           // headlight beam quad (detailed only, additive)
  glass: 25,
  // 32..47: wheel_<i> — merged wheels inside a non-detailed body (static in web; centre/radius in the header)
  // 64..95: panel_<i> — UV'd texture/text quads
});
const WHEEL_ID0 = 32, PANEL_ID0 = 64;
// Lamp groups the web toggles together (setBrake / setHeadlights / setHazard / setBlinker side).
const LAMP_GROUPS = Object.freeze({
  brake: ['brake_L', 'brake_R', 'brake_C'],
  head: ['head_L', 'head_R', 'head_C'],
  hazard: ['hazard_FL', 'hazard_FR', 'hazard_RL', 'hazard_RR', 'hazard_FC', 'hazard_RC'],
  blink_L: ['blink_FL', 'blink_RL'],
  blink_R: ['blink_FR', 'blink_RR'],
  glow: ['glow'], siren_R: ['siren_R'], siren_B: ['siren_B'], strobe: ['strobe_0', 'strobe_1'], beam: ['beam'],
});
const SURFACE_ORDER = ['body', 'lamps', 'glass', 'fx', 'panel'];

// ───────────────────────────── modes that do not need the game modules
if (opt('web-sheet') || opt('web-textures')) {
  await webMode();
  process.exit(0);
}

// ───────────────────────────── load the game modules (hook + canvas stub first)
const HOOK = `
const TARGET = ${JSON.stringify(VEHICLES_URL)};
export async function load(url, context, next) {
  const r = await next(url, context);
  if (url === TARGET) {
    const src = typeof r.source === 'string' ? r.source : new TextDecoder().decode(r.source);
    return { format: 'module', shortCircuit: true, source: src + '\\n;export const __BAKE__ = { KINDS, GB, wheelParts };\\n' };
  }
  return r;
}`;
register('data:text/javascript,' + encodeURIComponent(HOOK));
installCanvasStub();

const THREE = await import('three');
const CFG = await import(pathToFileURL(resolve(GAME_JS, 'config.js')).href);
const VEH = await import(VEHICLES_URL);
const SC = await import(pathToFileURL(resolve(GAME_JS, 'scenery.js')).href);
const SH = await import(pathToFileURL(resolve(GAME_JS, 'shoulder.js')).href);
const { KINDS, GB, wheelParts } = VEH.__BAKE__;

/** A document whose canvases accept every 2D call and draw nothing (textures stay blank; we only need geometry). */
function installCanvasStub() {
  const makeCtx = () => new Proxy({}, {
    get(t, k) {
      if (k in t) return t[k];
      if (k === 'measureText') return () => ({ width: 0 });
      if (k === 'getImageData') return (x, y, w, h) => ({ data: new Uint8ClampedArray(Math.max(1, w * h * 4)), width: w, height: h });
      if (k === 'createLinearGradient' || k === 'createRadialGradient' || k === 'createPattern') return () => ({ addColorStop() {} });
      return () => {};
    },
    set(t, k, v) { t[k] = v; return true; },
  });
  globalThis.document = { createElement: () => ({ width: 0, height: 0, style: {}, getContext: makeCtx, toDataURL: () => '' }) };
}

// ───────────────────────────── colour helpers (Three r170 colour management: hex = sRGB, Color = linear)
const _c = new THREE.Color();
const linOf = (hex) => { _c.setHex(hex); return [_c.r, _c.g, _c.b]; };
const srgb8 = (r, g, b) => { _c.setRGB(r, g, b); const h = _c.getHex(); return [(h >> 16) & 255, (h >> 8) & 255, h & 255]; };
const hexStr = (h) => '#' + (h >>> 0).toString(16).padStart(6, '0');
function mixHex(a, b, t) { // == vehicles.js mixHex
  const ar = (a >> 16) & 255, ag = (a >> 8) & 255, ab = a & 255, br = (b >> 16) & 255, bg = (b >> 8) & 255, bb = b & 255;
  return (Math.round(ar + (br - ar) * t) << 16) | (Math.round(ag + (bg - ag) * t) << 8) | Math.round(ab + (bb - ab) * t);
}
const shade = (hex, k) => (k < 1 ? mixHex(hex, 0x000000, 1 - k) : mixHex(hex, 0xffffff, k - 1)); // == vehicles.js shade
const smooth = (a, b, x) => { const t = Math.min(1, Math.max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t); };
const heightAO = (y) => 0.7 + 0.3 * smooth(0.06, 1.05, y); // == vehicles.js GB.build(ao=true)
const r6 = (v) => Math.round(v * 1e6) / 1e6;

// ───────────────────────────── bake set (M1a: NATIVE_PORT 5 M1a "bake: 도로(day), 텍스트 없는 소품, CCTV, player, NPC 8종, 고장차·콘")
function npcKindsByWeight() { return [...CFG.NPC_KINDS].sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1)).map(([k]) => k); }
function canonVariants(kind) { // unique geometry variants and the first raw index that resolves to each
  const def = KINDS[kind], nv = def.variants || 1, out = new Map();
  for (let raw = 0; raw < nv; raw++) { const v = def.canon ? def.canon(raw) : raw; if (!out.has(v)) out.set(v, raw); }
  return [...out.entries()].sort((a, b) => a[0] - b[0]);
}
function bakeSet() {
  const specs = [];
  const npc = npcKindsByWeight();
  for (const kind of [...npc, 'player', 'villainSedan']) {
    for (const [v, raw] of canonVariants(kind)) {
      specs.push({ category: 'vehicles', name: `${kind}_v${v}`, type: 'vehicle', kind, variant: v, raw, npc: npc.includes(kind),
        weight: (CFG.NPC_KINDS.find((x) => x[0] === kind) || [0, 0])[1], m1a: kind !== 'villainSedan',
        source: { module: 'vehicles', fn: 'buildVehicle', args: [kind, { variant: raw }] }, ao: { dist: 0.5, rays: 96, ground: false } });
    }
  }
  // road segments (day): world.js uses seed = k*31 + stage.id → variant = seed % 4, soundBarrier null | 'right'
  for (let v = 0; v < 4; v++) for (const sb of [null, 'right']) {
    specs.push({ category: 'road', name: `segment_v${v}${sb ? '_sb_' + sb : ''}`, type: 'scenery', m1a: true,
      source: { module: 'scenery', fn: 'buildRoadSegment', args: [CFG.SEG_LEN, { night: false, soundBarrier: sb, seed: v }] }, ao: { dist: 0.8, rays: 48, ground: false } });
  }
  // text-free props used by world.js on a day stage (every variant), + CCTV (its sign is a panel quad)
  const PROPS = { tree: 12, pine: 8, bush: 6, paddy: 9, house: 8, church: 4, mountain: 10, cloud: 8 };
  const AO_PROP = { mountain: { dist: 6, rays: 48, ground: true }, cloud: { dist: 3, rays: 48, ground: false }, paddy: { dist: 0.5, rays: 48, ground: true } };
  for (const [kind, n] of Object.entries(PROPS)) for (let v = 0; v < n; v++) {
    specs.push({ category: 'props', name: `${kind}_v${v}`, type: 'scenery', m1a: true,
      source: { module: 'scenery', fn: 'buildProp', args: [kind, v, { night: false }] }, ao: AO_PROP[kind] || { dist: 1.0, rays: 64, ground: true } });
  }
  specs.push({ category: 'props', name: 'cctv', type: 'scenery', m1a: true,
    source: { module: 'scenery', fn: 'buildProp', args: ['cctv', 0, { night: false }] }, ao: { dist: 1.0, rays: 64, ground: true } });
  // shoulder obstacles: one cone of the 'cones' taper, the warning triangle of 'breakdown' (its car = an NPC mesh above)
  specs.push({ category: 'props', name: 'cone', type: 'scenery', m1a: true,
    source: { module: 'shoulder', fn: 'buildShoulderObstacle', args: ['cones'], rng: 0.5, pick: 0, resetPos: true }, ao: { dist: 0.6, rays: 64, ground: true } });
  specs.push({ category: 'props', name: 'warning_triangle', type: 'scenery', m1a: true,
    source: { module: 'shoulder', fn: 'buildShoulderObstacle', args: ['breakdown'], rng: 0.5, pick: 1, resetPos: true }, ao: { dist: 0.6, rays: 64, ground: true } });
  // overhead sign frames + panel quads (text = Godot text_panel.gd); stage 1 geometry (2 sign lines → board 3.6 m)
  specs.push({ category: 'props', name: 'gantry_sign_2l', type: 'scenery', m1a: false,
    source: { module: 'scenery', fn: 'buildGantrySign', args: [[['부산', '387km'], ['대전', '128km']], {}] }, ao: { dist: 1.0, rays: 48, ground: true } });
  specs.push({ category: 'props', name: 'vms', type: 'scenery', m1a: false,
    source: { module: 'scenery', fn: 'buildVMS', args: ['', {}] }, ao: { dist: 1.0, rays: 48, ground: true } });
  return specs;
}

// ───────────────────────────── build an object from its source spec (same code path as the web sheet)
function buildFromSource(src) {
  const mod = { vehicles: VEH, scenery: SC, shoulder: SH }[src.module];
  const args = structuredClone(src.args);
  if (src.rng !== undefined) args.push(() => src.rng);
  let obj = mod[src.fn](...args);
  if (obj && obj.group) obj = obj.group; // buildShoulderObstacle returns { group, len, w }
  if (src.pick !== undefined) { obj = obj.children[src.pick]; obj.removeFromParent(); }
  if (src.resetPos) { obj.position.set(0, 0, 0); obj.rotation.set(0, 0, 0); }
  obj.updateMatrixWorld(true);
  return obj;
}

// ───────────────────────────── merged-wheel capture (non-detailed bodies carry their wheels, NATIVE_PORT 3-7 body/wheels)
// vehicles.js caches compiled geometry (GEO_CACHE), so the capture is keyed by the shared body geometry.
const WHEEL_CAPTURE = new Map(); // body geometry uuid → { bodyTris, wheels: [{x,y,z,r,w,tris}] }
let _lastCtx = null;
for (const def of Object.values(KINDS)) {
  const orig = def.build;
  def.build = function bakeCapture(c, p) { const info = orig(c, p); _lastCtx = { c, bodyTris: c.body.tris, detailed: p.detailed }; return info; };
}
function buildVehicleCaptured(kind, opts) {
  _lastCtx = null;
  const root = VEH.buildVehicle(kind, opts);
  const key = root.userData.bodyMesh.geometry.uuid;
  if (_lastCtx && !WHEEL_CAPTURE.has(key)) {
    const { c, bodyTris, detailed } = _lastCtx;
    const merged = detailed ? c.wheels.slice(4) : c.wheels; // == compile(): detailed keeps 4 separate wheels
    const wheels = merged.map((w) => {
      const g = new GB();
      wheelParts(g, w.x, w.y, w.z, w.r, w.w, { ...w.o, side: w.o?.both ? 0 : Math.sign(w.x) || 1 }); // == compile()
      return { x: w.x, y: w.y, z: w.z, r: w.r, w: w.w, tris: g.tris };
    });
    WHEEL_CAPTURE.set(key, { bodyTris, wheels });
  }
  root.updateMatrixWorld(true);
  return { root, cap: WHEEL_CAPTURE.get(key) || null };
}

// ───────────────────────────── routing: mesh → (node, surface, part)
const NODE_GROUPS = new Set(['driver', 'cannon', 'rider']);
function matDesc(m) {
  const d = { type: m.type, name: m.name || '', vertex_colors: !!m.vertexColors, color: hexStr(m.color ? m.color.getHex() : 0xffffff),
    opacity: m.opacity ?? 1, transparent: !!m.transparent, double_sided: m.side === THREE.DoubleSide, depth_write: m.depthWrite !== false,
    blend: m.blending === THREE.AdditiveBlending ? 'add' : 'mix', unlit: m.type === 'MeshBasicMaterial', flat: !!m.flatShading };
  if (m.emissive && m.emissive.getHex() !== 0) { d.emissive = hexStr(m.emissive.getHex()); d.emissive_intensity = m.emissiveIntensity ?? 1; }
  if (m.map) d.texture = { key: m.name || 'texture', px: [m.map.image?.width || 0, m.map.image?.height || 0] };
  return d;
}
/** Vehicle meshes: route by the names instantiate() gives them (vehicles.js 2708-2812). */
function routeVehicle(mesh, root) {
  for (let a = mesh.parent; a && a !== root; a = a.parent) if (NODE_GROUPS.has(a.name)) return { node: a.name, nodeObj: a, surface: 'body', part: 'body' };
  const m = mesh.material, nm = mesh.name;
  if (nm === 'wheel') return { node: 'wheel', nodeObj: mesh, surface: 'body', part: 'body', shared: true };
  if (nm === 'rimGlow') return { node: 'wheel', nodeObj: mesh.parent, surface: 'lamps', part: 'glow', shared: true };
  switch (nm) {
    case 'bodyMesh': return { node: 'main', surface: 'body', part: 'body', wheelSplit: true, heightAO: true };
    case 'brake': case 'head': case 'hazard': case 'blinkL': case 'blinkR': return { node: 'main', surface: 'lamps', split: nm };
    case 'glow': return { node: 'main', surface: 'lamps', part: 'glow' };
    case 'sirenR': return { node: 'main', surface: 'lamps', part: 'siren_R' };
    case 'sirenB': return { node: 'main', surface: 'lamps', part: 'siren_B' };
    case 'glass': return { node: 'main', surface: 'glass', part: 'glass' };
    case 'beam': return { node: 'main', surface: 'fx', part: 'beam' };
    default: break;
  }
  if (m.map) return { node: 'main', surface: 'panel', part: 'panel' };
  if (/^strobe/.test(m.name || '') || m === VEH.MAT.strobeR || m === VEH.MAT.strobeB || m === VEH.MAT.strobeA) {
    const idx = (root.userData.strobe || []).indexOf(mesh);
    return { node: 'main', surface: 'lamps', part: idx === 1 ? 'strobe_1' : 'strobe_0' };
  }
  if (m === VEH.MAT.glow) return { node: 'main', surface: 'lamps', part: 'glow' };
  if (mesh.position.lengthSq() > 0 || mesh.rotation.x || mesh.rotation.y || mesh.rotation.z) return { node: nm || 'extra', nodeObj: mesh, surface: 'body', part: 'body' };
  return { node: 'main', surface: 'body', part: 'body' };
}
/** Scenery / shoulder meshes: surface by material class. */
function routeScenery(mesh) {
  const d = matDesc(mesh.material);
  if (d.texture) return { node: 'main', surface: 'panel', part: 'panel' };
  if (d.blend === 'add') return { node: 'main', surface: 'fx', part: 'glow' };
  if (d.unlit) return { node: 'main', surface: 'lamps', part: 'glow' };
  if (d.transparent) return { node: 'main', surface: 'glass', part: 'glass' };
  return { node: 'main', surface: 'body', part: 'body' };
}

// ───────────────────────────── triangle soup extraction
/** Triangles of `mesh` in `space` (Matrix4 mapping mesh-local → export space): CCW positions, linear colours, uvs. */
function meshTris(mesh, space, isLamp) {
  const g = mesh.geometry, P = g.attributes.position, Cc = g.attributes.color, U = g.attributes.uv, I = g.index;
  const m = mesh.material, useVC = !!m.vertexColors && !!Cc;
  const mc = m.color ? [m.color.r, m.color.g, m.color.b] : [1, 1, 1];
  const n = I ? I.count / 3 : P.count / 3;
  const pos = new Float64Array(n * 9), col = new Float64Array(n * 9), uv = U ? new Float64Array(n * 6) : null;
  const v = new THREE.Vector3();
  for (let t = 0; t < n; t++) for (let k = 0; k < 3; k++) {
    const i = I ? I.getX(t * 3 + k) : t * 3 + k, o = (t * 3 + k) * 3;
    v.fromBufferAttribute(P, i).applyMatrix4(space);
    pos[o] = v.x; pos[o + 1] = v.y; pos[o + 2] = v.z;
    if (useVC) { // lamps keep their geometry colours: the instantiated lamp mesh wears its Off material (vehicles.js lightMesh)
      const f = isLamp ? [1, 1, 1] : mc;
      col[o] = Cc.getX(i) * f[0]; col[o + 1] = Cc.getY(i) * f[1]; col[o + 2] = Cc.getZ(i) * f[2];
    } else { col[o] = mc[0]; col[o + 1] = mc[1]; col[o + 2] = mc[2]; }
    if (uv) { uv[(t * 3 + k) * 2] = U.getX(i); uv[(t * 3 + k) * 2 + 1] = U.getY(i); }
  }
  return { n, pos, col, uv };
}

/** Connected components of a triangle soup (shared vertex positions) → [{tris:[...], ctr:[x,y,z]}]. */
function components(pos, n) {
  const parent = new Int32Array(n).map((_, i) => i);
  const find = (a) => { while (parent[a] !== a) { parent[a] = parent[parent[a]]; a = parent[a]; } return a; };
  const seen = new Map();
  for (let t = 0; t < n; t++) for (let k = 0; k < 3; k++) {
    const o = (t * 3 + k) * 3, key = `${Math.round(pos[o] * 1e5)},${Math.round(pos[o + 1] * 1e5)},${Math.round(pos[o + 2] * 1e5)}`;
    const u = seen.get(key);
    if (u === undefined) seen.set(key, t); else { const a = find(u), b = find(t); if (a !== b) parent[a] = b; }
  }
  const comps = new Map();
  for (let t = 0; t < n; t++) {
    const r = find(t);
    let c = comps.get(r);
    if (!c) { c = { tris: [], min: [Infinity, Infinity, Infinity], max: [-Infinity, -Infinity, -Infinity] }; comps.set(r, c); }
    c.tris.push(t);
    for (let k = 0; k < 9; k++) { const a = k % 3; c.min[a] = Math.min(c.min[a], pos[t * 9 + k]); c.max[a] = Math.max(c.max[a], pos[t * 9 + k]); }
  }
  return [...comps.values()].map((c) => ({ tris: c.tris, ctr: [0, 1, 2].map((a) => (c.min[a] + c.max[a]) / 2) }));
}
const SIDE_EPS = 0.18; // == vehicles.js blinkGeos: |ctr.x| < 0.18 is a centre lamp
function lampPartOf(split, ctr) {
  const side = ctr[0] < -SIDE_EPS ? 'L' : ctr[0] > SIDE_EPS ? 'R' : 'C', end = ctr[2] < 0 ? 'F' : 'R';
  switch (split) {
    case 'brake': return `brake_${side}`;
    case 'head': return `head_${side}`;
    case 'hazard': return `hazard_${end}${side}`;
    case 'blinkL': return `blink_${end}L`;
    case 'blinkR': return `blink_${end}R`;
    default: throw new Error(`lamp split ${split}`);
  }
}

// ───────────────────────────── collect: Object3D → groups keyed node/surface/part (deterministic order)
function relMatrix(obj, root) { return new THREE.Matrix4().copy(root.matrixWorld).invert().multiply(obj.matrixWorld); }
function collect(root, type, cap) {
  const groups = new Map(); // `${node}|${surface}|${part}` → group
  const nodes = new Map();  // node → { name, placements: [Matrix4 root-space], geomKey }
  const points = {};
  const pointsLocal = {};
  const js = { tris: 0, meshes: [] };
  const add = (node, surface, part, desc, tri, ti, aoFlag) => {
    const key = `${node}|${surface}|${part}`;
    let g = groups.get(key);
    if (!g) { g = { node, surface, part, desc, pos: [], col: [], uv: tri.uv ? [] : null, aoh: [] }; groups.set(key, g); }
    for (let k = 0; k < 9; k++) { g.pos.push(tri.pos[ti * 9 + k]); g.col.push(tri.col[ti * 9 + k]); }
    if (g.uv) for (let k = 0; k < 6; k++) g.uv.push(tri.uv ? tri.uv[ti * 6 + k] : 0);
    for (let k = 0; k < 3; k++) g.aoh.push(aoFlag ? heightAO(tri.pos[ti * 9 + k * 3 + 1]) : 1);
  };
  const wheelGeoNodes = new Map(); // geometry uuid → node name (shared detailed wheels)
  root.traverse((o) => {
    if (o === root) return;
    if (o.isPoints || o.isSprite || o.isLine) { // halo sprites / glow sprites → point lists
      const nm = o.name === 'blinkHalo' ? `blink_halo_${o.parent?.name === 'blinkR' ? 'R' : 'L'}` : (o.name || 'sprite');
      const M = relMatrix(o, root), v = new THREE.Vector3();
      if (o.isPoints) { const P = o.geometry.attributes.position; for (let i = 0; i < P.count; i++) (points[nm] ||= []).push(v.fromBufferAttribute(P, i).applyMatrix4(M).toArray().map(r6)); }
      else (points[nm] ||= []).push(v.setFromMatrixPosition(M).toArray().map(r6));
      return;
    }
    if (!o.isMesh) {
      if (o.children.length === 0 && o.name) { // pivots / markers (exhaust, smokePoint, muzzle, towPoint …)
        points[o.name] = new THREE.Vector3().setFromMatrixPosition(relMatrix(o, root)).toArray().map(r6);
        for (let a = o.parent; a && a !== root; a = a.parent) if (NODE_GROUPS.has(a.name)) { pointsLocal[o.name] = { node: a.name, pos: o.position.toArray().map(r6) }; break; }
      }
      return;
    }
    const r = type === 'vehicle' ? routeVehicle(o, root) : routeScenery(o);
    const desc = matDesc(o.material);
    const tcount = o.geometry.index ? o.geometry.index.count / 3 : o.geometry.attributes.position.count / 3;
    js.tris += tcount;
    js.meshes.push({ name: o.name || '', tris: tcount, node: r.node, visible: o.visible });
    let nodeName = r.node, space;
    if (r.node === 'main') space = relMatrix(o, root);
    else {
      // Pivoted sub-mesh. Detailed wheels share one geometry (vehicles.js wheelGeo cache): one node, one placement per wheel.
      const wheelMesh = o.name === 'wheel' ? o : o.name === 'rimGlow' ? o.parent : null;
      if (wheelMesh) {
        const gk = wheelMesh.geometry.uuid;
        if (!wheelGeoNodes.has(gk)) wheelGeoNodes.set(gk, wheelGeoNodes.size ? `wheel${wheelGeoNodes.size}` : 'wheel');
        nodeName = wheelGeoNodes.get(gk);
      } else { // a group (driver/cannon/rider) or a positioned extra; same-named extras get _1, _2 …
        for (let k = 1; nodes.has(nodeName) && nodes.get(nodeName).obj !== r.nodeObj; k++) nodeName = `${r.node}_${k}`;
      }
      let N = nodes.get(nodeName);
      const first = !N;
      if (first) { N = { name: nodeName, placements: [], obj: r.nodeObj }; nodes.set(nodeName, N); }
      if (o.name === 'wheel') N.placements.push(relMatrix(o, root));
      else if (first) N.placements.push(relMatrix(r.nodeObj, root));
      if (wheelMesh && wheelMesh !== N.obj) return; // shared wheel geometry is collected from the first wheel only
      space = new THREE.Matrix4().copy(relMatrix(r.nodeObj, root)).invert().multiply(relMatrix(o, root));
    }
    const isLamp = r.surface === 'lamps' && type === 'vehicle';
    const tri = meshTris(o, space, isLamp);
    if (r.split) {
      for (const c of components(tri.pos, tri.n)) { const part = lampPartOf(r.split, c.ctr); for (const t of c.tris) add(nodeName, 'lamps', part, desc, tri, t, false); }
    } else if (r.wheelSplit && cap && cap.wheels.length) {
      let t0 = cap.bodyTris;
      if (t0 + cap.wheels.reduce((s, w) => s + w.tris, 0) !== tri.n) throw new Error(`merged-wheel ranges do not cover the body (${t0}+wheels != ${tri.n})`);
      const wheelOf = new Int16Array(tri.n).fill(-1);
      cap.wheels.forEach((w, i) => { wheelOf.fill(i, t0, t0 + w.tris); t0 += w.tris; });
      for (let t = 0; t < tri.n; t++) add(nodeName, 'body', wheelOf[t] < 0 ? 'body' : `wheel_${wheelOf[t]}`, desc, tri, t, r.heightAO);
    } else {
      const part = r.part === 'panel' ? `panel_${[...groups.values()].filter((g) => g.surface === 'panel' && g.node === nodeName).length}` : r.part;
      for (let t = 0; t < tri.n; t++) add(nodeName, r.surface, part, desc, tri, t, !!r.heightAO);
    }
  });
  // JS reference bbox: Three's own geometry bounding boxes of the same meshes (visible or not; points/sprites excluded)
  const bb = new THREE.Box3(), tmp = new THREE.Box3();
  root.traverse((o) => { if (o.isMesh) { o.geometry.computeBoundingBox(); tmp.copy(o.geometry.boundingBox).applyMatrix4(relMatrix(o, root)); bb.union(tmp); } });
  js.bbox = { min: bb.min.toArray().map(r6), max: bb.max.toArray().map(r6) };
  return { groups, nodes, points, pointsLocal, js };
}
function partId(name) {
  if (name in PART_IDS) return PART_IDS[name];
  let m = /^wheel_(\d+)$/.exec(name); if (m) return WHEEL_ID0 + +m[1];
  m = /^panel_(\d+)$/.exec(name); if (m) return PANEL_ID0 + +m[1];
  throw new Error(`unknown part ${name}`);
}

// ───────────────────────────── paint fit (NPC tint): per vertex k with srgb = shade(paint, k)
const NPC_COLORS = [...CFG.NPC_COLORS_MONO, ...CFG.NPC_COLORS_POP].filter((c, i, a) => a.indexOf(c) === i);
// Probes: paint = white gives 255·k (k<1), paint = black gives 255·(k−1) (k>1). The fit is accepted only if every
// NPC colour then reproduces the real build within ±1 sRGB level per channel (shade() rounds to integers).
function paintFit(spec, base) {
  const build = (color) => { const b = buildVehicleCaptured(spec.kind, { variant: spec.raw, color }); return collect(b.root, 'vehicle', b.cap).groups; };
  const W = build(0xffffff), B = build(0x000000);
  const checks = NPC_COLORS.map((c) => [c, build(c)]);
  const res = { tintable: false, paint_vertices: 0, nonfit_vertices: 0, geometry_varies: false, checked_colors: NPC_COLORS.length };
  for (const [key, g] of base.groups) {
    g.k = new Float64Array(g.pos.length / 3);
    const others = [W.get(key), B.get(key), ...checks.map(([, m]) => m.get(key))];
    if (others.some((o) => !o || o.pos.length !== g.pos.length || o.pos.some((p, i) => p !== g.pos[i]))) { res.geometry_varies = true; continue; }
    const [gw, gb] = others;
    for (let v = 0; v < g.k.length; v++) {
      const o = v * 3, a = g.aoh[v];
      const s8 = (gg) => srgb8(gg.col[o] / a, gg.col[o + 1] / a, gg.col[o + 2] / a);
      const sw = s8(gw), sb = s8(gb);
      if (sw[0] === sb[0] && sw[1] === sb[1] && sw[2] === sb[2]) continue; // fixed colour
      const k = sw[0] < 255 ? sw[0] / 255 : 1 + sb[0] / 255;
      const ok = checks.every(([c, gc]) => {
        const want = shade(c, k), got = s8(gc.get(key));
        return Math.abs(((want >> 16) & 255) - got[0]) <= 1 && Math.abs(((want >> 8) & 255) - got[1]) <= 1 && Math.abs((want & 255) - got[2]) <= 1;
      });
      if (ok) { g.k[v] = k; res.paint_vertices++; } else res.nonfit_vertices++;
    }
  }
  res.tintable = res.paint_vertices > 0 && !res.geometry_varies;
  return res;
}

// ───────────────────────────── BVH ray caster (AO)
class BVH {
  constructor(tris) { // tris: Float64Array 9n (CCW)
    const n = tris.length / 9;
    this.t = tris; this.n = n;
    this.nrm = new Float64Array(n * 3);
    const cen = new Float64Array(n * 3);
    for (let i = 0; i < n; i++) {
      const o = i * 9, ux = tris[o + 3] - tris[o], uy = tris[o + 4] - tris[o + 1], uz = tris[o + 5] - tris[o + 2];
      const vx = tris[o + 6] - tris[o], vy = tris[o + 7] - tris[o + 1], vz = tris[o + 8] - tris[o + 2];
      this.nrm[i * 3] = uy * vz - uz * vy; this.nrm[i * 3 + 1] = uz * vx - ux * vz; this.nrm[i * 3 + 2] = ux * vy - uy * vx;
      for (let a = 0; a < 3; a++) cen[i * 3 + a] = (tris[o + a] + tris[o + 3 + a] + tris[o + 6 + a]) / 3;
    }
    this.idx = new Int32Array(n).map((_, i) => i);
    this.nodes = []; // [minx,miny,minz,maxx,maxy,maxz, left|-start-1, right|count]
    if (n) this._build(0, n, cen);
  }
  _build(s, e, cen) {
    const id = this.nodes.length; const nd = [Infinity, Infinity, Infinity, -Infinity, -Infinity, -Infinity, 0, 0]; this.nodes.push(nd);
    for (let i = s; i < e; i++) { const o = this.idx[i] * 9; for (let k = 0; k < 9; k++) { const a = k % 3; if (this.t[o + k] < nd[a]) nd[a] = this.t[o + k]; if (this.t[o + k] > nd[3 + a]) nd[3 + a] = this.t[o + k]; } }
    if (e - s <= 4) { nd[6] = -s - 1; nd[7] = e - s; return id; }
    const ax = [0, 1, 2].reduce((b, a) => (nd[3 + a] - nd[a] > nd[3 + b] - nd[b] ? a : b), 0);
    const sub = Array.from(this.idx.subarray(s, e)).sort((p, q) => cen[p * 3 + ax] - cen[q * 3 + ax]);
    this.idx.set(sub, s);
    const m = (s + e) >> 1;
    nd[6] = this._build(s, m, cen); nd[7] = this._build(m, e, cen);
    return id;
  }
  /** nearest front-face hit distance in (0, tMax], or Infinity */
  hit(ox, oy, oz, dx, dy, dz, tMax) {
    if (!this.n) return Infinity;
    const ix = 1 / dx, iy = 1 / dy, iz = 1 / dz, st = [0], T = this.t;
    let best = tMax;
    let found = false;
    while (st.length) {
      const nd = this.nodes[st.pop()];
      let t0 = ((ix >= 0 ? nd[0] : nd[3]) - ox) * ix, t1 = ((ix >= 0 ? nd[3] : nd[0]) - ox) * ix;
      const ty0 = ((iy >= 0 ? nd[1] : nd[4]) - oy) * iy, ty1 = ((iy >= 0 ? nd[4] : nd[1]) - oy) * iy;
      if (ty0 > t0) t0 = ty0; if (ty1 < t1) t1 = ty1;
      const tz0 = ((iz >= 0 ? nd[2] : nd[5]) - oz) * iz, tz1 = ((iz >= 0 ? nd[5] : nd[2]) - oz) * iz;
      if (tz0 > t0) t0 = tz0; if (tz1 < t1) t1 = tz1;
      if (t0 > t1 || t1 < 0 || t0 > best) continue;
      if (nd[6] >= 0) { st.push(nd[6], nd[7]); continue; }
      const s = -nd[6] - 1;
      for (let i = s; i < s + nd[7]; i++) {
        const tri = this.idx[i], N = this.nrm;
        if (N[tri * 3] * dx + N[tri * 3 + 1] * dy + N[tri * 3 + 2] * dz >= 0) continue; // back face → ignore (buried voxels)
        const o = tri * 9;
        const e1x = T[o + 3] - T[o], e1y = T[o + 4] - T[o + 1], e1z = T[o + 5] - T[o + 2];
        const e2x = T[o + 6] - T[o], e2y = T[o + 7] - T[o + 1], e2z = T[o + 8] - T[o + 2];
        const px = dy * e2z - dz * e2y, py = dz * e2x - dx * e2z, pz = dx * e2y - dy * e2x;
        const det = e1x * px + e1y * py + e1z * pz;
        if (Math.abs(det) < 1e-14) continue;
        const inv = 1 / det, sx = ox - T[o], sy = oy - T[o + 1], sz = oz - T[o + 2];
        const u = (sx * px + sy * py + sz * pz) * inv; if (u < 0 || u > 1) continue;
        const qx = sy * e1z - sz * e1y, qy = sz * e1x - sx * e1z, qz = sx * e1y - sy * e1x;
        const v = (dx * qx + dy * qy + dz * qz) * inv; if (v < 0 || u + v > 1) continue;
        const t = (e2x * qx + e2y * qy + e2z * qz) * inv;
        if (t > 1e-5 && t < best) { best = t; found = true; }
      }
    }
    return found ? best : Infinity;
  }
}
function hemiDirs(n) { // cosine-weighted Hammersley set in tangent space (deterministic)
  const out = [];
  for (let i = 0; i < n; i++) {
    let b = i, f = 0.5, rad = 0; while (b) { if (b & 1) rad += f; b >>= 1; f *= 0.5; }
    const u = (i + 0.5) / n, r = Math.sqrt(u), ph = 2 * Math.PI * rad;
    out.push([r * Math.cos(ph), r * Math.sin(ph), Math.sqrt(Math.max(0, 1 - u))]);
  }
  return out;
}
function basis(nx, ny, nz) { // Duff et al. 2017 orthonormal basis
  const s = nz >= 0 ? 1 : -1, a = -1 / (s + nz), b = nx * ny * a;
  return [[1 + s * nx * nx * a, s * b, -s * nx], [b, s + ny * ny * a, -ny]];
}

// ───────────────────────────── weld + AO + pack
function faceNormal(p, o) { // → [nx, ny, nz, degenerate]
  const ux = p[o + 3] - p[o], uy = p[o + 4] - p[o + 1], uz = p[o + 5] - p[o + 2], vx = p[o + 6] - p[o], vy = p[o + 7] - p[o + 1], vz = p[o + 8] - p[o + 2];
  const nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
  const l = Math.hypot(nx, ny, nz);
  return l < 1e-12 ? [0, 1, 0, true] : [nx / l, ny / l, nz / l, false];
}
// Coplanar overlap → layering. vehicles.js stacks boxes whose faces share a plane (a rail band around a box-truck
// roof, a plate on a lamp bar, reflector stripes on a bumper). The web render (SwiftShader, depthFunc LessEqual) shows
// the smaller, detail face on top; Godot's reverse-Z depth z-fights there instead (first contact sheet). So in every
// plane, faces are ordered by triangle area (larger first, then draw order) and a triangle that overlaps an
// already-placed one is pushed out along its normal by LAYER_EPS × layer. 0.4 mm per layer: invisible, AABB-safe.
const LAYER_EPS = 4e-4;
function layerCoplanar(parts) {
  const tris = []; // { g, t, n, d, area, order, layer }
  for (const { g } of parts) for (let t = 0; t < g.pos.length / 9; t++) {
    const fn = faceNormal(g.pos, t * 9);
    if (fn[3]) continue;
    const o = t * 9, p = g.pos;
    const ux = p[o + 3] - p[o], uy = p[o + 4] - p[o + 1], uz = p[o + 5] - p[o + 2], vx = p[o + 6] - p[o], vy = p[o + 7] - p[o + 1], vz = p[o + 8] - p[o + 2];
    const area = Math.hypot(uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx) / 2;
    tris.push({ g, t, n: fn, d: fn[0] * p[o] + fn[1] * p[o + 1] + fn[2] * p[o + 2], area, order: tris.length, layer: 0 });
  }
  const nk = (n) => `${Math.round(n[0] * 1e3)},${Math.round(n[1] * 1e3)},${Math.round(n[2] * 1e3)}`;
  const buckets = new Map();
  for (const tr of tris) { const k = `${nk(tr.n)}|${Math.round(tr.d * 1e4)}`; if (!buckets.has(k)) buckets.set(k, []); buckets.get(k).push(tr); }
  const placed = new Map(); // bucket key → placed triangles
  const sorted = [...tris].sort((a, b) => (Math.abs(b.area - a.area) > 1e-9 ? b.area - a.area : a.order - b.order));
  let moved = 0;
  for (const tr of sorted) {
    const k = nk(tr.n), dk = Math.round(tr.d * 1e4);
    let layer = 0;
    for (const dd of [dk - 1, dk, dk + 1]) for (const o of placed.get(`${k}|${dd}`) || []) {
      if (o.layer + 1 > layer && Math.abs(o.d - tr.d) < 1e-4 && overlap2D(o, tr)) {
        layer = o.layer + 1;
        if (flag('debug-layers')) log(`  layer ${layer}: tri ${tr.t} col ${srgb8(tr.g.col[tr.t * 9], tr.g.col[tr.t * 9 + 1], tr.g.col[tr.t * 9 + 2])} area ${tr.area.toFixed(4)} over tri ${o.t} col ${srgb8(o.g.col[o.t * 9], o.g.col[o.t * 9 + 1], o.g.col[o.t * 9 + 2])} area ${o.area.toFixed(4)} n ${tr.n.slice(0, 3).map((x) => x.toFixed(2))} d ${tr.d.toFixed(3)}`);
      }
    }
    tr.layer = layer;
    const key = `${k}|${dk}`;
    if (!placed.has(key)) placed.set(key, []);
    placed.get(key).push(tr);
  }
  for (const tr of tris) if (tr.layer > 0) {
    const o = tr.t * 9, e = LAYER_EPS * tr.layer;
    for (let k = 0; k < 3; k++) for (let a = 0; a < 3; a++) tr.g.pos[o + k * 3 + a] += tr.n[a] * e;
    moved++;
  }
  return moved;
}
/** Do two coplanar triangles overlap with positive area (shared edges/corners do not count)? 2D SAT in the plane. */
function overlap2D(A, B) {
  const n = A.n, ax = Math.abs(n[0]) > Math.abs(n[1]) ? (Math.abs(n[0]) > Math.abs(n[2]) ? 0 : 2) : (Math.abs(n[1]) > Math.abs(n[2]) ? 1 : 2);
  const u = (ax + 1) % 3, v = (ax + 2) % 3;
  const P = (tr) => [0, 1, 2].map((k) => [tr.g.pos[tr.t * 9 + k * 3 + u], tr.g.pos[tr.t * 9 + k * 3 + v]]);
  const a = P(A), b = P(B);
  for (const poly of [a, b]) for (let i = 0; i < 3; i++) {
    const p = poly[i], q = poly[(i + 1) % 3];
    let nx = q[1] - p[1], ny = p[0] - q[0];
    const l = Math.hypot(nx, ny); if (l < 1e-12) continue;
    nx /= l; ny /= l;
    let a0 = Infinity, a1 = -Infinity, b0 = Infinity, b1 = -Infinity;
    for (const s of a) { const d = s[0] * nx + s[1] * ny; a0 = Math.min(a0, d); a1 = Math.max(a1, d); }
    for (const s of b) { const d = s[0] * nx + s[1] * ny; b0 = Math.min(b0, d); b1 = Math.max(b1, d); }
    if (Math.min(a1, b1) - Math.max(a0, b0) <= 1e-5) return false;
  }
  return true;
}
function weldSurface(parts) { // parts: [{name, id, g}] in id order → { V: [{p,n,c8,aoh,k,uv,id}], I: [], ranges }
  const V = [], I = [], map = new Map(), ranges = [];
  let degenerate = 0;
  for (const { name, id, g } of parts) {
    const v0 = V.length, i0 = I.length, ntri = g.pos.length / 9;
    const lo = [Infinity, Infinity, Infinity], hi = [-Infinity, -Infinity, -Infinity];
    for (let t = 0; t < ntri; t++) {
      const fn = faceNormal(g.pos, t * 9);
      if (fn[3]) degenerate++; // kept (zero area, renders nothing) so triangle counts match the web
      for (let k = 0; k < 3; k++) {
        const vi = t * 3 + k, o = vi * 3;
        const p = [g.pos[o], g.pos[o + 1], g.pos[o + 2]];
        const c8 = srgb8(g.col[o], g.col[o + 1], g.col[o + 2]);
        const aoh = g.aoh[vi], kk = g.k ? g.k[vi] : 0;
        const uv = g.uv ? [g.uv[vi * 2], g.uv[vi * 2 + 1]] : null;
        const key = `${Math.round(p[0] * 1e6)},${Math.round(p[1] * 1e6)},${Math.round(p[2] * 1e6)}|${Math.round(fn[0] * 1e5)},${Math.round(fn[1] * 1e5)},${Math.round(fn[2] * 1e5)}|${c8}|${Math.round(aoh * 1e6)}|${Math.round(kk * 1e6)}|${uv ? Math.round(uv[0] * 1e6) + ',' + Math.round(uv[1] * 1e6) : ''}|${id}`;
        let idx = map.get(key);
        if (idx === undefined) { idx = V.length; map.set(key, idx); V.push({ p, n: fn.slice(0, 3), c8, aoh, k: kk, uv, id, ao: 1 }); }
        I.push(idx);
        for (let a = 0; a < 3; a++) { lo[a] = Math.min(lo[a], p[a]); hi[a] = Math.max(hi[a], p[a]); }
      }
    }
    ranges.push({ name, id, first_vertex: v0, vertex_count: V.length - v0, first_index: i0, index_count: I.length - i0, tris: ntri, js_vertices: ntri * 3,
      aabb: ntri ? { min: lo.map(r6), max: hi.map(r6) } : null });
  }
  return { V, I, ranges, degenerate };
}
function bakeAO(model, spec, nRays) {
  const occ = [];
  const push = (pos, M) => { const v = new THREE.Vector3(); for (let i = 0; i < pos.length; i += 3) { v.set(pos[i], pos[i + 1], pos[i + 2]); if (M) v.applyMatrix4(M); occ.push(v.x, v.y, v.z); } };
  for (const node of model.nodes) for (const M of node.placements) for (const s of node.surfaces) if (s.name === 'body') for (const pr of s.parts) push(pr.g.pos, M);
  const lo = [Infinity, Infinity, Infinity], hi = [-Infinity, -Infinity, -Infinity];
  for (let i = 0; i < occ.length; i++) { const a = i % 3; lo[a] = Math.min(lo[a], occ[i]); hi[a] = Math.max(hi[a], occ[i]); }
  if (spec.ao.ground && occ.length) { // ground plane y = 0 (props stand on terrain), CCW seen from above
    const ex = Math.max(hi[0] - lo[0], hi[2] - lo[2]) + 4 * spec.ao.dist, cx = (lo[0] + hi[0]) / 2, cz = (lo[2] + hi[2]) / 2;
    occ.push(cx - ex, 0, cz + ex, cx + ex, 0, cz + ex, cx + ex, 0, cz - ex, cx - ex, 0, cz + ex, cx + ex, 0, cz - ex, cx - ex, 0, cz - ex);
  }
  const bvh = new BVH(new Float64Array(occ)), dirs = hemiDirs(nRays), R = +opt('ao-dist', spec.ao.dist);
  let rays = 0;
  for (const node of model.nodes) for (const s of node.surfaces) for (const v of s.V) {
    let vis = 0;
    for (const M of node.placements) {
      const p = new THREE.Vector3(...v.p).applyMatrix4(M), n = new THREE.Vector3(...v.n).transformDirection(M);
      const [t1, t2] = basis(n.x, n.y, n.z), ox = p.x + n.x * 1e-3, oy = p.y + n.y * 1e-3, oz = p.z + n.z * 1e-3;
      let o = 0;
      for (const [a, b, c] of dirs) {
        const dx = t1[0] * a + t2[0] * b + n.x * c, dy = t1[1] * a + t2[1] * b + n.y * c, dz = t1[2] * a + t2[2] * b + n.z * c;
        const t = bvh.hit(ox, oy, oz, dx, dy, dz, R);
        if (t !== Infinity) o += 1 - t / R;
        rays++;
      }
      vis += 1 - o / dirs.length;
    }
    v.ao = vis / node.placements.length;
  }
  return { rays, occluder_tris: occ.length / 9 };
}

// ───────────────────────────── export one model
function exportModel(spec) {
  let root, cap = null;
  if (spec.type === 'vehicle') ({ root, cap } = buildVehicleCaptured(spec.kind, { variant: spec.raw }));
  else root = buildFromSource(spec.source);
  const base = collect(root, spec.type, cap);
  const paint = spec.type === 'vehicle' ? paintFit(spec, base) : null;
  // organise nodes → surfaces → parts
  const nodeNames = ['main', ...[...base.nodes.keys()]];
  const nodes = [];
  for (const nn of nodeNames) {
    const N = base.nodes.get(nn);
    const placements = nn === 'main' ? [new THREE.Matrix4()] : N.placements;
    const surfaces = [];
    for (const sname of SURFACE_ORDER) {
      const parts = [...base.groups.values()].filter((g) => g.node === nn && g.surface === sname)
        .map((g) => ({ name: g.part, id: partId(g.part), g })).sort((a, b) => a.id - b.id);
      if (!parts.length) continue;
      const desc = surfaceDesc(sname, parts, spec.type);
      surfaces.push({ name: sname, desc, parts, has_uv: parts.some((p) => p.g.uv) });
    }
    if (surfaces.length) nodes.push({ name: nn, placements, surfaces });
  }
  for (const node of nodes) for (const s of node.surfaces) { s.layered = layerCoplanar(s.parts); Object.assign(s, weldSurface(s.parts)); }
  const aoStats = flag('no-ao') ? { rays: 0, occluder_tris: 0 } : bakeAO({ nodes }, spec, +opt('rays', spec.ao.rays));
  return { root, cap, base, paint, nodes, aoStats };
}
function surfaceDesc(sname, parts, type) {
  const d = parts[0].g.desc;
  switch (sname) {
    case 'body': return { shading: 'lambert', vertex_colors: true, cast_shadow: true, ...(d.emissive ? { emissive: d.emissive, emissive_intensity: d.emissive_intensity } : {}) };
    case 'lamps': return { shading: 'unlit', vertex_colors: true, cast_shadow: false, lamp: type === 'vehicle' };
    case 'glass': return { shading: d.unlit ? 'unlit' : 'lambert', vertex_colors: false, color: d.color, opacity: d.opacity, transparent: true, double_sided: d.double_sided, cast_shadow: true };
    case 'fx': return { shading: 'unlit', vertex_colors: d.vertex_colors, color: d.color, opacity: d.opacity, blend: d.blend, transparent: true, depth_write: false, cast_shadow: false, double_sided: d.double_sided };
    case 'panel': return { shading: d.unlit ? 'unlit' : 'lambert', vertex_colors: false, cast_shadow: false, double_sided: d.double_sided, transparent: d.transparent,
      panels: parts.map((p) => ({ part: p.name, id: p.id, material: p.g.desc.name, texture: p.g.desc.texture, emissive: p.g.desc.emissive || null, emissive_intensity: p.g.desc.emissive_intensity ?? 0 })) };
    default: throw new Error(sname);
  }
}

// ───────────────────────────── binary pack + header
function align4(n) { return (n + 3) & ~3; }
function writeModel(spec, ex, outDir) {
  const chunks = [];
  let off = 0;
  const put = (buf) => { const at = off; chunks.push(Buffer.from(buf.buffer, buf.byteOffset, buf.byteLength)); off += buf.byteLength; const pad = align4(off) - off; if (pad) { chunks.push(Buffer.alloc(pad)); off += pad; } return at; };
  const nodesOut = [];
  let weldedTotal = 0;
  for (const node of ex.nodes) {
    const surfaces = [];
    for (const s of node.surfaces) {
      const nv = s.V.length;
      const P = new Float32Array(nv * 3), N = new Float32Array(nv * 3), C = new Uint8Array(nv * 4), X = new Float32Array(nv * 4), U = s.has_uv ? new Float32Array(nv * 2) : null;
      s.V.forEach((v, i) => {
        P.set(v.p, i * 3); N.set(v.n, i * 3); C.set([v.c8[0], v.c8[1], v.c8[2], 255], i * 4);
        X.set([Math.round(v.ao * 1e4) / 1e4, v.id, Math.round(v.k * 1e6) / 1e6, Math.round(v.aoh * 1e6) / 1e6], i * 4);
        if (U) U.set(v.uv || [0, 0], i * 2);
      });
      const I = new Uint32Array(s.I);
      weldedTotal += nv;
      surfaces.push({ name: s.name, material: s.desc, vertex_count: nv, index_count: I.length,
        buffers: { position: put(P), normal: put(N), color: put(C), custom0: put(X), uv: U ? put(U) : null, index: put(I) },
        parts: s.ranges, degenerate_tris: s.degenerate, layered_tris: s.layered });
    }
    nodesOut.push({ name: node.name, placements: node.placements.map((M) => M.toArray().map(r6)), surfaces });
  }
  const bin = Buffer.concat(chunks);
  const header = {
    schema: SCHEMA, name: spec.name, category: spec.category, type: spec.type, m1a: spec.m1a,
    generator: 'tools/bake-meshes.mjs', web_frozen_sha: WEB_FROZEN_SHA, three: THREE.REVISION,
    source: spec.source, winding: 'ccw', color: 'srgb8', custom0: ['ao', 'part_id', 'paint_k', 'height_ao'],
    bin: `${spec.name}.bin`, bin_bytes: bin.length,
    nodes: nodesOut,
    points: ex.base.points, points_local: ex.base.pointsLocal,
    ao: { ...spec.ao, rays: flag('no-ao') ? 0 : +opt('rays', spec.ao.rays), ...ex.aoStats },
    js: { ...ex.base.js, welded_vertices: weldedTotal },
  };
  if (spec.type === 'vehicle') {
    const ud = ex.root.userData, def = KINDS[spec.kind];
    header.vehicle = {
      kind: spec.kind, variant: spec.variant, raw: spec.raw, npc: spec.npc, npc_weight: spec.weight, detailed: !!ud.detailed,
      dims: { L: ud.length, W: ud.width, H: ud.height }, wheel_radius: ud.wheelRadius, wheel_radii: ud.wheelRadii,
      merged_wheels: (ex.nodes[0].surfaces.find((s) => s.name === 'body')?.ranges || []).filter((r) => r.name.startsWith('wheel_')).map((r, i) => {
        const w = ex.cap?.wheels[i];
        return w ? { part: r.name, center: [w.x, w.y, w.z].map(r6), radius: w.r, width: w.w } : { part: r.name };
      }),
      paint: { default: hexStr(buildColor(spec)), livery: !!def.livery, ...ex.paint },
      lamp_groups: LAMP_GROUPS,
      lamp_off_multiplier: { brake: hexStr(VEH.MAT.brakeOff.color.getHex()), hazard: hexStr(VEH.MAT.hazardOff.color.getHex()), head: hexStr(VEH.MAT.headOff.color.getHex()) },
      beacon_pos: ud.beaconPos || null,
    };
  }
  mkdirSync(join(outDir, spec.category), { recursive: true });
  writeFileSync(join(outDir, spec.category, `${spec.name}.bin`), bin);
  writeFileSync(join(outDir, spec.category, `${spec.name}.json`), JSON.stringify(header, null, 1));
  return header;
}
function buildColor(spec) {
  const def = KINDS[spec.kind];
  return (def.livery ? def.livery(def.canon ? def.canon(spec.raw) : spec.raw) : (def.variantColor ? def.variantColor(spec.raw) : def.color)) >>> 0;
}

// ───────────────────────────── main
function gitState() {
  try {
    const head = execFileSync('git', ['-C', ROOT, 'rev-parse', '--short', 'HEAD'], { encoding: 'utf8' }).trim();
    const dirty = execFileSync('git', ['-C', ROOT, 'diff', '--stat', WEB_FROZEN_SHA, '--', 'game/js'], { encoding: 'utf8' }).trim();
    return { head, game_js_matches_web_frozen: dirty === '' };
  } catch { return { head: null, game_js_matches_web_frozen: null }; }
}
const OUT = resolve(opt('out', resolve(ROOT, 'native/build/bake')));
const only = opt('only', '').split(',').filter(Boolean);
let specs = bakeSet();
if (only.length) specs = specs.filter((s) => only.some((o) => s.name.includes(o)));
if (flag('list')) { for (const s of specs) console.log(`${s.category}/${s.name}${s.m1a ? '' : '  (beyond M1a)'}`); process.exit(0); }
const git = gitState();
if (git.game_js_matches_web_frozen === false) log(`[bake] WARN game/js differs from web-frozen ${WEB_FROZEN_SHA}`);
mkdirSync(OUT, { recursive: true });
const index = { schema: SCHEMA, generator: 'tools/bake-meshes.mjs', web_frozen_sha: WEB_FROZEN_SHA, git, three: THREE.REVISION,
  part_ids: PART_IDS, wheel_id0: WHEEL_ID0, panel_id0: PANEL_ID0, lamp_groups: LAMP_GROUPS, npc_kinds_by_weight: npcKindsByWeight(), models: [] };
const t0 = Date.now();
for (const spec of specs) {
  const t = Date.now();
  const ex = exportModel(spec);
  const h = writeModel(spec, ex, OUT);
  const tris = h.nodes.reduce((s, n) => s + n.surfaces.reduce((q, x) => q + x.index_count / 3, 0), 0);
  index.models.push({ category: spec.category, name: spec.name, json: `${spec.category}/${spec.name}.json`, tris: h.js.tris, welded_vertices: h.js.welded_vertices, m1a: spec.m1a });
  const layered = h.nodes.reduce((s, n) => s + n.surfaces.reduce((q, x) => q + x.layered_tris, 0), 0);
  log(`[bake] ${spec.category}/${spec.name}: js tris ${h.js.tris} (unique ${tris}, layered ${layered}) → ${h.js.welded_vertices} verts (${(h.js.welded_vertices / (tris * 3) * 100).toFixed(0)}%), ` +
    `${h.bin_bytes} B, AO ${h.ao.rays} rays${h.vehicle ? `, paint ${h.vehicle.paint.paint_vertices}/${h.vehicle.paint.nonfit_vertices} nonfit${h.vehicle.paint.livery ? ' (livery)' : ''}` : ''} [${Date.now() - t} ms]`);
}
writeFileSync(join(OUT, 'index.json'), JSON.stringify(index, null, 1));
log(`[bake] ${specs.length} models → ${relative(process.cwd(), OUT) || OUT} in ${((Date.now() - t0) / 1000).toFixed(1)} s`);

// ───────────────────────────── web modes (Playwright): contact sheet with the real web builders, static textures
async function webMode() {
  const require = createRequire(import.meta.url);
  let pw; try { pw = require('playwright'); } catch { pw = require('/opt/node22/lib/node_modules/playwright'); }
  const base = opt('url', 'http://localhost:8090');
  const browser = await pw.chromium.launch({ args: ['--use-gl=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'] });
  const errs = [];
  try {
    if (opt('web-sheet')) {
      const layout = JSON.parse(readFileSync(opt('web-sheet'), 'utf8'));
      const [w, h] = layout.viewport;
      const page = await browser.newPage({ viewport: { width: w, height: h }, deviceScaleFactor: 1 });
      page.on('pageerror', (e) => errs.push(`[pageerror] ${e.message}`));
      page.on('console', (m) => { if (m.type() === 'error') errs.push(`[console] ${m.text()}`); });
      await page.route(`${base}/game/__bake_sheet__.html`, (r) => r.fulfill({ contentType: 'text/html', body: sheetHtml(layout) }));
      await page.goto(`${base}/game/__bake_sheet__.html`, { waitUntil: 'load' });
      await page.waitForFunction('window.__done === true', null, { timeout: 120000 });
      const info = await page.evaluate('window.__info');
      await page.screenshot({ path: opt('png', 'web_sheet.png') });
      console.log(JSON.stringify({ saved: opt('png', 'web_sheet.png'), info, errors: errs }));
    }
    if (opt('web-textures')) {
      const dir = resolve(opt('web-textures'));
      mkdirSync(dir, { recursive: true });
      const page = await browser.newPage();
      page.on('pageerror', (e) => errs.push(`[pageerror] ${e.message}`));
      await page.route(`${base}/game/__bake_tex__.html`, (r) => r.fulfill({ contentType: 'text/html', body: texHtml() }));
      await page.goto(`${base}/game/__bake_tex__.html`, { waitUntil: 'load' });
      await page.waitForFunction('window.__tex !== undefined', null, { timeout: 60000 });
      const tex = await page.evaluate('window.__tex');
      for (const [key, url] of Object.entries(tex)) {
        writeFileSync(join(dir, `${key}.png`), Buffer.from(url.split(',')[1], 'base64'));
        console.log(`saved ${join(dir, key + '.png')}`);
      }
      if (errs.length) console.log(errs.join('\n'));
    }
  } finally { await browser.close(); }
}
function importmap() { return '<script type="importmap">{"imports":{"three":"../node_modules/three/build/three.module.js"}}</script>'; }
function texHtml() {
  return `<!doctype html><meta charset="utf-8">${importmap()}<script type="module">
import * as SC from './js/scenery.js';
const out = {};
const seg = SC.buildRoadSegment(40, { soundBarrier: 'right', seed: 0 });
const glass = seg.children.find((m) => m.name === 'glass');
if (glass && glass.material.map) out.acrylic = glass.material.map.image.toDataURL('image/png');
window.__tex = out;
</script>`;
}
function sheetHtml(layout) {
  return `<!doctype html><meta charset="utf-8"><style>html,body{margin:0;background:#000;overflow:hidden}canvas{display:block}</style>${importmap()}
<script type="module">
import * as THREE from 'three';
import * as V from './js/vehicles.js';
import * as SC from './js/scenery.js';
import * as SH from './js/shoulder.js';
const L = ${JSON.stringify(layout)};
const MODS = { vehicles: V, scenery: SC, shoulder: SH };
const renderer = new THREE.WebGLRenderer({ antialias: false, preserveDrawingBuffer: true });
renderer.setPixelRatio(1); renderer.setSize(L.viewport[0], L.viewport[1]);
document.body.appendChild(renderer.domElement);
const scene = new THREE.Scene();
scene.background = new THREE.Color(L.background);
const hemi = new THREE.HemisphereLight(L.light.hemi_sky, L.light.hemi_ground, L.light.hemi_intensity); scene.add(hemi);
const sun = new THREE.DirectionalLight(L.light.sun_color, L.light.sun_intensity);
sun.position.set(...L.light.sun_dir); scene.add(sun); scene.add(sun.target);
const info = { built: 0, failed: [] };
for (const it of L.items) {
  try {
    const s = it.source, args = structuredClone(s.args);
    if (s.rng !== undefined) args.push(() => s.rng);
    let o = MODS[s.module][s.fn](...args);
    if (o && o.group) o = o.group;
    if (s.pick !== undefined) { o = o.children[s.pick]; o.removeFromParent(); }
    if (s.resetPos) { o.position.set(0, 0, 0); o.rotation.set(0, 0, 0); }
    const holder = new THREE.Group(); holder.add(o);
    holder.position.set(...it.pos); holder.rotation.y = it.rot_y || 0; holder.scale.setScalar(it.scale || 1);
    scene.add(holder);
    const lamps = it.lamps || {};
    if (o.userData && o.userData.kind && s.module === 'vehicles') {
      V.setBrake(o, !!lamps.brake); V.setHazard(o, !!lamps.hazard); V.setHeadlights(o, !!lamps.head);
      if (lamps.blink) V.setBlinker(o, lamps.blink, true);
    }
    o.traverse((m) => { if (m.isPoints || m.isSprite) m.visible = false; if (m.name === 'beam') m.visible = !!lamps.beam; });
    info.built++;
  } catch (e) { info.failed.push(it.name + ': ' + e.message); }
}
const cam = new THREE.PerspectiveCamera(L.camera.fov, L.viewport[0] / L.viewport[1], L.camera.near, L.camera.far);
cam.position.set(...L.camera.pos); cam.lookAt(...L.camera.target);
renderer.render(scene, cam);
window.__info = info; window.__done = true;
</script>`;
}
