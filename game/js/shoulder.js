// 갓길 장애물 소품: 고장차(+삼각대), 공사 콘 구간, 낙하물. (복셀 풍, 메시 수 최소)
import * as THREE from 'three';
import { buildVehicle, setHazard } from './vehicles.js';

const MAT = {
  orange: new THREE.MeshLambertMaterial({ color: 0xff7a1a, flatShading: true }),
  white: new THREE.MeshLambertMaterial({ color: 0xf4f4f0, flatShading: true }),
  red: new THREE.MeshBasicMaterial({ color: 0xff2a2a }),
  black: new THREE.MeshLambertMaterial({ color: 0x24262a, flatShading: true }),
  box: new THREE.MeshLambertMaterial({ color: 0xc8955a, flatShading: true }),
  tape: new THREE.MeshLambertMaterial({ color: 0xe9d9a0, flatShading: true }),
};
const G = {
  cone: new THREE.ConeGeometry(0.32, 0.85, 6).translate(0, 0.425, 0),
  coneBand: new THREE.CylinderGeometry(0.205, 0.245, 0.14, 6).translate(0, 0.5, 0),
  coneBase: new THREE.BoxGeometry(0.62, 0.08, 0.62).translate(0, 0.04, 0),
  tri: (() => {
    // 삼각대: 빨간 삼각 프레임 (얇은 막대 3개)
    const g = new THREE.BoxGeometry(0.08, 0.72, 0.06);
    return g;
  })(),
  box: new THREE.BoxGeometry(0.9, 0.7, 0.8).translate(0, 0.35, 0),
  tire: new THREE.TorusGeometry(0.42, 0.18, 6, 10).rotateX(Math.PI / 2).translate(0, 0.18, 0),
};

function cone() {
  const g = new THREE.Group();
  const a = new THREE.Mesh(G.cone, MAT.orange); a.castShadow = true;
  const b = new THREE.Mesh(G.coneBand, MAT.white);
  const c = new THREE.Mesh(G.coneBase, MAT.black);
  g.add(a, b, c);
  return g;
}

function triangle() {
  const g = new THREE.Group();
  for (const [x, rz] of [[-0.2, -0.52], [0.2, 0.52]]) {
    const m = new THREE.Mesh(G.tri, MAT.red); m.position.set(x, 0.36, 0); m.rotation.z = rz; g.add(m);
  }
  const bot = new THREE.Mesh(G.tri, MAT.red); bot.rotation.z = Math.PI / 2; bot.position.y = 0.06; bot.scale.y = 0.95; g.add(bot);
  return g;
}

// 반환: { group, len, w, hazardCar? }  — group 원점 = 장애물 구간의 중심 (s 방향), 앞쪽이 −Z
// opts.dark: 무등화(비상등·삼각대 없음) — 밤 '어둠' 갓길 모드
export function buildShoulderObstacle(kind, rng, opts = {}) {
  const group = new THREE.Group();
  if (kind === 'breakdown') {
    const kinds = ['sedan', 'van', 'pickup1t', 'compact'];
    const car = buildVehicle(kinds[Math.floor(rng() * kinds.length)], { color: [0xf4f4f2, 0x9aa1a9, 0x2b2d31, 0x2a5db0][Math.floor(rng() * 4)] });
    const len = car.userData.length || 4.6;
    car.position.z = -2.4;               // 차는 앞쪽
    car.rotation.y = (rng() - 0.5) * 0.12;
    group.add(car);
    if (!opts.dark) { const t = triangle(); t.position.z = len / 2 + 1.5 - 2.4; group.add(t); } // 차 뒤 삼각대 (무등화 차는 없음)
    // 보닛 열린 느낌: 차 옆에 서 있는 박스(사람 대신 짐)
    return { group, len: len + 3.4, w: 2.1, hazardCar: opts.dark ? null : car };
  }
  if (kind === 'cones') {
    const n = 6;
    for (let i = 0; i < n; i++) {
      const c = cone();
      // 대각선으로 갓길을 막는 테이퍼
      c.position.set(-0.9 + (i / (n - 1)) * 1.8, 0, -5 + i * 2);
      group.add(c);
    }
    return { group, len: 11.5, w: 2.4 };
  }
  // debris: 낙하물 (박스 + 타이어)
  const nb = 2 + Math.floor(rng() * 2);
  for (let i = 0; i < nb; i++) {
    const b = new THREE.Mesh(G.box, i % 2 ? MAT.box : MAT.tape);
    b.position.set((rng() - 0.5) * 1.4, 0, (rng() - 0.5) * 2.2);
    b.rotation.y = rng() * 3;
    b.castShadow = true;
    group.add(b);
  }
  const tire = new THREE.Mesh(G.tire, MAT.black);
  tire.position.set((rng() - 0.5) * 1.2, 0, 1.6);
  tire.castShadow = true;
  group.add(tire);
  return { group, len: 4.2, w: 2.0 };
}

export { setHazard };
