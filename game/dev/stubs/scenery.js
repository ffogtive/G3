import * as THREE from 'three';
export function buildRoadSegment(len = 40) { const g = new THREE.Group(); const m = new THREE.Mesh(new THREE.PlaneGeometry(50, len).rotateX(-Math.PI / 2), new THREE.MeshLambertMaterial({ color: 0x444a50 })); m.position.set(-8, 0, -len / 2); m.receiveShadow = true; g.add(m); for (let i = -1; i <= 1; i++) { const l = new THREE.Mesh(new THREE.PlaneGeometry(0.15, 6).rotateX(-Math.PI / 2), new THREE.MeshBasicMaterial({ color: 0xffffff })); l.position.set(i * 3.6, 0.01, -len / 2); g.add(l); } return g; }
export function buildProp(kind) { const g = new THREE.Group(); const m = new THREE.Mesh(new THREE.ConeGeometry(2, 5, 6), new THREE.MeshLambertMaterial({ color: 0x3a8a3a })); m.position.y = 2.5; g.add(m); return g; }
export function buildGantrySign() { return new THREE.Group(); }
export function buildVMS() { const g = new THREE.Group(); g.userData.setText = () => {}; return g; }
export function buildBanner() { return new THREE.Group(); }
export function makeSkyDome(t, b) { return new THREE.Mesh(new THREE.SphereGeometry(900, 16, 8), new THREE.MeshBasicMaterial({ color: t, side: THREE.BackSide, fog: false })); }
export function makeGround() { const m = new THREE.Mesh(new THREE.PlaneGeometry(3000, 3000).rotateX(-Math.PI / 2), new THREE.MeshLambertMaterial({ color: 0x7fbf5a })); m.position.y = -0.05; m.receiveShadow = true; return m; }
export async function preloadFonts() {}
