import * as THREE from 'three';
const lm = (c) => new THREE.MeshLambertMaterial({ color: c });
export const MAT = { body: lm(0xffffff), brakeOn: new THREE.MeshBasicMaterial({ color: 0xff2a2a }), brakeOff: new THREE.MeshBasicMaterial({ color: 0x5a1414 }), hazardOn: new THREE.MeshBasicMaterial({ color: 0xffb300 }), hazardOff: new THREE.MeshBasicMaterial({ color: 0x5a3d00 }), headOn: new THREE.MeshBasicMaterial({ color: 0xffffee }), headOff: new THREE.MeshBasicMaterial({ color: 0x888888 }) };
const DIM = { compact: [3.6, 1.65, 1.5], sedan: [4.6, 1.85, 1.45], suv: [4.7, 1.95, 1.8], taxi: [4.6, 1.85, 1.6], van: [5, 1.95, 2.1], pickup1t: [5, 1.8, 2], truck: [9.5, 2.5, 3.6], bus: [11.5, 2.5, 3.3], police: [4.6, 1.85, 1.6], player: [4, 1.85, 1.6], villainSedan: [4.9, 1.9, 1.5], villainTruck: [9, 2.5, 3.2], villainSuv: [5, 2.3, 1.9], villainPhone: [4.2, 1.8, 1.5], tractor: [3.4, 1.6, 1.8] };
export function buildVehicle(kind, opts = {}) {
  const [L, W, H] = DIM[kind] || DIM.sedan; const g = new THREE.Group();
  const body = new THREE.Mesh(new THREE.BoxGeometry(W, H * 0.7, L), lm(opts.color ?? 0xffc928)); body.position.y = H * 0.45; body.castShadow = true; g.add(body);
  const brake = new THREE.Mesh(new THREE.BoxGeometry(W * 0.9, 0.2, 0.1), MAT.brakeOff); brake.position.set(0, H * 0.5, L / 2 + 0.05); g.add(brake);
  const hazard = new THREE.Mesh(new THREE.BoxGeometry(W + 0.1, 0.12, 0.12), MAT.hazardOff); hazard.position.set(0, H * 0.7, L / 2); g.add(hazard);
  const wheels = [];
  const detailed = opts.detailed ?? (kind === 'player' || kind.startsWith('villain') || kind === 'tractor');
  if (detailed) for (let i = 0; i < 4; i++) { const w = new THREE.Mesh(new THREE.CylinderGeometry(0.42, 0.42, 0.3, 10).rotateZ(Math.PI / 2), lm(0x222222)); w.position.set((i % 2 ? 1 : -1) * W / 2, 0.42, (i < 2 ? -1 : 1) * L * 0.33); g.add(w); wheels.push(w); }
  g.userData = { kind, length: L, width: W, height: H, body, brake, hazard, head: null, wheels, wheelRadius: 0.42, driver: null, flashMats: detailed ? [body.material] : [] };
  return g;
}
export const setBrake = (v, on) => { if (v.userData.brake) v.userData.brake.material = on ? MAT.brakeOn : MAT.brakeOff; };
export const setHazard = (v, on) => { if (v.userData.hazard) v.userData.hazard.material = on ? MAT.hazardOn : MAT.hazardOff; };
export const setHeadlights = () => {};
export const setFlash = (v, a) => { for (const m of v.userData.flashMats || []) m.emissive?.setScalar(a); };
export function buildProjectile(kind) { const m = new THREE.Mesh(new THREE.BoxGeometry(0.5, 0.5, 0.5), lm(kind === 'missile' ? 0xff0000 : 0xcccccc)); return m; }
export function buildWarningMarker() { const m = new THREE.Mesh(new THREE.RingGeometry(1.2, 1.5, 24).rotateX(-Math.PI / 2), new THREE.MeshBasicMaterial({ color: 0xff0000 })); m.userData.setProgress = () => {}; return m; }
