// 월드: 하늘/조명/안개 + 스테이지 도로 세그먼트 + 한국 고속도로 소품 배치
import * as THREE from 'three';
import { SEG_LEN, SKY, ROAD_RIGHT, SHOULDER_W, OPP_ROAD_LEFT } from './config.js';
import * as SC from './scenery.js';
import { mulberry32 } from './traffic.js';

const BANNERS = ['졸음운전! 자면 죽는다', '졸음쉼터 2km', '1차선은 추월차선', '안전띠는 생명띠', '휴게소 호두과자 5km', '과속은 사고의 지름길'];

export class World {
  constructor(scene, opts = {}) {
    this.scene = scene;
    this.mobile = !!opts.mobile;
    this.root = new THREE.Group();
    scene.add(this.root);

    this.hemi = new THREE.HemisphereLight(0xbfe4ff, 0x8a9a6a, 1.2);
    scene.add(this.hemi);
    this.sun = new THREE.DirectionalLight(0xffffff, 2.5);
    this.sun.castShadow = true;
    const sz = this.mobile ? 1024 : 2048;
    this.sun.shadow.mapSize.set(sz, sz);
    const sc = this.sun.shadow.camera;
    sc.left = -42; sc.right = 42; sc.top = 42; sc.bottom = -42; sc.near = 1; sc.far = 260;
    this.sun.shadow.bias = -0.0006;
    this.sun.shadow.normalBias = 0.03;
    scene.add(this.sun);
    scene.add(this.sun.target);
    this.sunDir = new THREE.Vector3(-0.4, 0.8, 0.3).normalize();

    this.sky = null;
    this.ground = null;
    this.vms = [];
    this.segments = [];
    this.overheads = [];   // 도로 위 구조물 (표지판/전광판/단속카메라) — 카메라 근처에서 반투명 처리
  }

  // 머리 위 구조물이 화면을 가리지 않도록, 재질을 개별 복제해 투명도 조절 가능하게
  _overhead(obj) {
    const mats = [];
    obj.traverse((m) => {
      if (!m.isMesh) return;
      const arr = Array.isArray(m.material) ? m.material : [m.material];
      const cl = arr.map((mt) => { const c = mt.clone(); c.transparent = true; c.userData.baseOpacity = mt.opacity ?? 1; mats.push(c); return c; });
      m.material = Array.isArray(m.material) ? cl : cl[0];
    });
    obj.userData.fadeMats = mats;
    obj.userData.fade = 1;
    this.overheads.push(obj);
    return obj;
  }

  applySky(name) {
    const P = SKY[name] || SKY.day;
    this.preset = P;
    const scene = this.scene;
    scene.fog = new THREE.Fog(P.fog, P.fogNear, P.fogFar);
    scene.background = new THREE.Color(P.bottom);
    this.hemi.color.setHex(P.hemiSky); this.hemi.groundColor.setHex(P.hemiGround); this.hemi.intensity = P.hemiI;
    this.sun.color.setHex(P.sun); this.sun.intensity = P.sunI;
    this.sunDir.set(...P.sunPos).normalize();
    if (this.sky) { scene.remove(this.sky); this.sky.geometry?.dispose(); }
    try { this.sky = SC.makeSkyDome(P.top, P.bottom); scene.add(this.sky); } catch (e) { console.warn('sky', e); this.sky = null; }
  }

  clear() {
    for (const c of [...this.root.children]) this.root.remove(c);
    this.vms.length = 0;
    this.segments.length = 0;
    for (const o of this.overheads) for (const m of o.userData.fadeMats || []) m.dispose();
    this.overheads.length = 0;
  }

  _add(obj, x, s, rotY = 0) {
    obj.position.set(x, obj.position.y || 0, -s);
    if (rotY) obj.rotation.y = rotY;
    this.root.add(obj);
    return obj;
  }

  _prop(kind, seed, x, s, rotY, opts) {
    try { return this._add(SC.buildProp(kind, seed, opts), x, s, rotY); }
    catch (e) { console.warn('prop', kind, e); return null; }
  }

  // sMin..sMax 도로 구축. marks: { startS, frontS }
  build(stage, sMin, sMax, marks) {
    this.clear();
    this.applySky(stage.sky);
    const night = !!this.preset.night;
    this.night = night;
    const rng = mulberry32(stage.id * 7919 + 13);

    if (SC.makeGround) {
      try {
        this.ground = SC.makeGround({ night, color: night ? 0x1f3a2a : undefined });
        this.ground.position.z = -(sMin + sMax) / 2;
        this.root.add(this.ground);
      } catch (e) { console.warn('ground', e); }
    }

    const k0 = Math.floor(sMin / SEG_LEN), k1 = Math.ceil(sMax / SEG_LEN);
    // 방음벽 구간 (연속 구간)
    const barrierFrom = k0 + 1 + Math.floor(rng() * 3), barrierLen = 3 + Math.floor(rng() * 3);
    for (let k = k0; k < k1; k++) {
      const s0 = k * SEG_LEN;
      const sb = (k >= barrierFrom && k < barrierFrom + barrierLen) ? 'right' : null;
      let seg;
      try { seg = SC.buildRoadSegment(SEG_LEN, { night, soundBarrier: sb, seed: k * 31 + stage.id }); }
      catch (e) { console.warn('segment', e); continue; }
      seg.position.z = -s0;
      this.root.add(seg);
      this.segments.push(seg);
      const hasBarrier = !!sb;

      // 오른쪽: 가까운 나무/덤불, 중간 논·집·교회, 먼 아파트, 아주 먼 산
      const edgeR = ROAD_RIGHT + SHOULDER_W + 4;
      if (!hasBarrier) {
        const nTree = 1 + Math.floor(rng() * 3);
        for (let i = 0; i < nTree; i++) this._prop(rng() < 0.5 ? 'tree' : 'pine', Math.floor(rng() * 1e5), edgeR + rng() * 14, s0 + rng() * SEG_LEN, rng() * 6, { night });
        if (rng() < 0.6) this._prop('bush', Math.floor(rng() * 1e5), edgeR - 1 + rng() * 3, s0 + rng() * SEG_LEN, 0, { night });
      }
      if (rng() < 0.45) this._prop('paddy', Math.floor(rng() * 1e5), edgeR + 22 + rng() * 25, s0 + rng() * SEG_LEN, 0, { night });
      if (rng() < 0.18) this._prop('house', Math.floor(rng() * 1e5), edgeR + 30 + rng() * 30, s0 + rng() * SEG_LEN, rng() * 6, { night });
      if (k % 9 === 4) this._prop('church', Math.floor(rng() * 1e5), edgeR + 55 + rng() * 20, s0 + rng() * SEG_LEN, 0, { night });
      if (k % 3 === 0) {
        const n = 2 + Math.floor(rng() * 2);
        for (let i = 0; i < n; i++) this._prop('apartment', 101 + Math.floor(rng() * 12), edgeR + 70 + i * 22 + rng() * 6, s0 + rng() * 10, -Math.PI / 2 + (rng() - 0.5) * 0.2, { night });
      }
      if (k % 4 === 1) this._prop('mountain', Math.floor(rng() * 1e5), edgeR + 170 + rng() * 80, s0 + rng() * SEG_LEN, rng() * 6, { night });

      // 왼쪽(반대편 도로 너머)
      const edgeL = OPP_ROAD_LEFT - 4;
      const nTreeL = 1 + Math.floor(rng() * 2);
      for (let i = 0; i < nTreeL; i++) this._prop(rng() < 0.6 ? 'pine' : 'tree', Math.floor(rng() * 1e5), edgeL - rng() * 16, s0 + rng() * SEG_LEN, rng() * 6, { night });
      if (k % 4 === 2) this._prop('apartment', 101 + Math.floor(rng() * 12), edgeL - 60 - rng() * 30, s0 + rng() * 20, Math.PI / 2, { night });
      if (k % 3 === 1) this._prop('mountain', Math.floor(rng() * 1e5), edgeL - 150 - rng() * 100, s0 + rng() * SEG_LEN, rng() * 6, { night });

      if (night && k % 1 === 0) this._prop('streetLight', k, ROAD_RIGHT + SHOULDER_W + 0.9, s0 + 10, 0, { night });
    }

    // 하늘 구름
    for (let i = 0; i < 14; i++) this._prop('cloud', i * 17 + stage.id, -150 + rng() * 300, sMin + rng() * (sMax - sMin + 300), 0, { night })?.position.setY(55 + rng() * 40);

    // 표지판 / 전광판 / 현수막 / 단속카메라
    const { startS, frontS } = marks;
    try { this._overhead(this._add(SC.buildGantrySign(stage.signs || [['서울', '10km']], {}), 0, startS + 46)); } catch (e) { console.warn('gantry', e); }
    try { this._overhead(this._add(SC.buildGantrySign([...(stage.signs || [])].reverse(), {}), 0, frontS + 150)); } catch (e) { console.warn('gantry2', e); }
    try {
      const v1 = SC.buildVMS(`앞쪽 정체 ${stage.displayKm}km\n원인: ${stage.cause || '저속차량'}`, {});
      this._add(v1, 0, startS + 105);
      const v2 = SC.buildVMS(stage.vms || '1차선은 추월차선입니다', {});
      this._add(v2, 0, frontS + 25);
      const v3 = SC.buildVMS('정체 구간 끝', {});
      this._add(v3, 0, frontS + 260);
      this.vms.push(v1, v2, v3);
      for (const v of this.vms) this._overhead(v);
    } catch (e) { console.warn('vms', e); }
    try { this._overhead(this._add(SC.buildProp('cctv', 0, { night }), 0, startS + (frontS - startS) * 0.55)); } catch (e) { console.warn('cctv', e); }
    const nb = 3;
    for (let i = 0; i < nb; i++) {
      try {
        const b = SC.buildBanner(BANNERS[(stage.id + i * 2) % BANNERS.length], {});
        this._add(b, ROAD_RIGHT + SHOULDER_W + 3.5, startS + 20 + (frontS - startS + 120) * (i + 0.5) / nb, 0);
      } catch (e) { console.warn('banner', e); }
    }
  }

  setVMS(text, color) {
    for (const v of this.vms) v.userData.setText?.(text, color);
  }

  // 매 프레임: 하늘 돔은 카메라를 따라오고, 태양·그림자 카메라는 초점을 따라온다
  update(camera, focus) {
    if (this.sky) this.sky.position.copy(camera.position);
    // 카메라 바로 앞(시선 경로)에 있는 머리 위 구조물은 반투명하게
    const cz = camera.position.z, cy = camera.position.y;
    for (const o of this.overheads) {
      const d = cz - o.position.z; // >0 이면 카메라 앞쪽
      let f = 1;
      if (cy > 5 && d > -2 && d < 30) f = 0.22 + 0.78 * Math.min(1, Math.max(0, (d - 12) / 18));
      if (Math.abs(f - o.userData.fade) > 0.01) {
        o.userData.fade = f;
        for (const m of o.userData.fadeMats) { m.opacity = m.userData.baseOpacity * f; m.depthWrite = f > 0.95; }
      }
    }
    this.sun.target.position.copy(focus);
    this.sun.position.copy(focus).addScaledVector(this.sunDir, 120);
  }
}
