// 무기: 압정 연사(포물선, 소프트 조준) + 분노 미사일(유도, 폭발)
import * as THREE from 'three';
import { TUNE } from './config.js';
import { buildProjectile } from './vehicles.js';

const _a = new THREE.Vector3(), _b = new THREE.Vector3();

export class Weapons {
  constructor(scene, fx, audio) {
    this.scene = scene; this.fx = fx; this.audio = audio;
    this.tacks = [];      // 활성
    this.tackPool = [];
    this.missiles = [];
    this.missilePool = [];
    this.cool = 0;
    this.superCool = 0;
    this.shots = 0;
    this.hits = 0;
    this.wpn = { proj: 'tack', dmg: 4, rate: 7, spread: 1, slow: 0 };
    this.pools = {};
  }

  // 상점 무기 장착 (config SHOP weapon 항목)
  setWeapon(item) {
    this.wpn = { proj: item?.proj || 'tack', dmg: item?.dmg ?? TUNE.tackDmg, rate: item?.rate ?? TUNE.tackRate, spread: item?.spread ?? 1, slow: item?.slow || 0 };
  }

  reset() {
    for (const t of this.tacks) { t.obj.visible = false; (this.pools[t.kind] ||= []).push(t.obj); }
    for (const m of this.missiles) { m.obj.visible = false; this.missilePool.push(m.obj); }
    this.tacks.length = 0; this.missiles.length = 0;
    this.cool = 0; this.superCool = 0; this.shots = 0; this.hits = 0;
  }

  _get(pool, kind) {
    const o = pool.pop() || buildProjectile(kind);
    if (!o.parent) this.scene.add(o);
    o.visible = true;
    return o;
  }

  // 정면 참교육: 지붕 압정포가 뒤(빌런 쪽)를 보고 있다 → 뒤로 던진다
  _muzzle(player, out) {
    // 차종마다 압정포 위치가 다르다 (포터·레커는 높고 앞쪽) → 모델의 muzzle 기준
    const mz = player.mesh?.userData?.muzzle;
    if (mz) { player.mesh.updateMatrixWorld(true); return mz.getWorldPosition(out); }
    return out.set(player.x, 1.95 + player.hop, -(player.s - 0.6));
  }

  fireTack(player, boss) { this.fireAt(player, boss.targetFor(player)); }

  // 대상(원흉·잔챙이)에게 투척. 대상이 앞에 있으면 뒷바퀴 쪽, 뒤에 있으면 앞바퀴 쪽 노면을 노린다
  fireAt(player, target) {
    const W = this.wpn;
    const from0 = this._muzzle(player, new THREE.Vector3());
    const ahead = target ? target.s > player.s : false;
    const lob = target ? Math.abs(target.x - player.x) > 4 : false;   // 화물차 너머로 높이
    const dur = lob ? 0.46 : 0.32;
    const n = Math.max(1, W.spread);
    for (let k = 0; k < n; k++) {
      const kind = W.proj;
      const pool = (this.pools[kind] ||= []);
      const obj = this._get(pool, kind);
      const from = from0.clone();
      let to, aim = 0;
      const spreadX = (k - (n - 1) / 2) * 0.9;
      if (target) {
        aim = ahead ? -0.36 : 0.38;
        const leadS = target.s + target.v * dur + target.len * aim;
        to = new THREE.Vector3(target.x + spreadX + (Math.random() - 0.5) * Math.min(1.2, target.w * 0.5), 0.25 + Math.random() * 0.4, -leadS);
      } else {
        to = new THREE.Vector3(player.x + spreadX + (Math.random() - 0.5) * 0.6, 0.05, -(player.s - 9));
      }
      obj.position.copy(from);
      this.tacks.push({ obj, kind, from, to, t: 0, dur, target, arc: lob ? 5.5 : target ? 2.2 : 3, aim, fromRear: ahead, dx: spreadX });
    }
    this.audio.play('tack', { pitch: 0.9 + Math.random() * 0.25, volume: 0.6 });
    this.shots++;
  }

  // 쿨다운 관리 포함 (정체 구간 잔챙이용)
  tryFireAt(player, target) {
    if (this.cool > 0) return false;
    this.cool = 1 / this.wpn.rate;
    this.fireAt(player, target);
    return true;
  }

  fireMissile(player, boss) {
    const alive = boss.alive;
    if (!alive.length) return false;
    // 가장 가까운(횡) 원흉
    let target = alive[0];
    for (const v of alive) if (Math.abs(v.x - player.x) < Math.abs(target.x - player.x)) target = v;
    const obj = this._get(this.missilePool, 'missile');
    const from = this._muzzle(player, new THREE.Vector3());
    const side = Math.random() < 0.5 ? -1 : 1;
    this.missiles.push({ obj, from, target, t: 0, dur: 0.62, side, prev: from.clone(), fromRear: target.s > player.s });
    obj.position.copy(from);
    this.fx.smokeTrail(obj, 0.7);
    this.audio.play('super');
    return true;
  }

  // ctx: { dt, phase, player, boss, wantFire, wantSuper, rage, onHit(villain, dmg, pos, kind) }
  // 반환: { superFired }
  update(dt, ctx) {
    const res = { superFired: false };
    const { player, boss } = ctx;
    this.cool -= dt; this.superCool -= dt;
    if (ctx.phase === 'boss' && boss.anyAlive) {
      if (ctx.wantFire && this.cool <= 0) {
        this.cool = 1 / this.wpn.rate;
        this.fireTack(player, boss);
      }
      if (ctx.wantSuper && this.superCool <= 0 && ctx.rage >= TUNE.superCost - 1e-6) {
        if (this.fireMissile(player, boss)) { this.superCool = 0.45; res.superFired = true; }
      }
    }

    // 압정 비행
    for (let i = this.tacks.length - 1; i >= 0; i--) {
      const t = this.tacks[i];
      t.t += dt;
      const p = Math.min(1, t.t / t.dur);
      // 목표가 움직이면 끝점 보정
      if (t.target && t.target.alive) {
        t.to.z = -(t.target.s + t.target.len * t.aim);
        t.to.x += (t.target.x + t.dx - t.to.x) * Math.min(1, dt * 10);
      }
      t.obj.position.lerpVectors(t.from, t.to, p);
      t.obj.position.y += Math.sin(Math.PI * p) * t.arc;
      t.obj.rotation.x += dt * 25;
      if (p >= 1) {
        if (t.target && t.target.alive && Math.abs(t.target.x - t.to.x) < t.target.w / 2 + 0.9) {
          this.hits++;
          ctx.onHit(t.target, this.wpn.dmg, t.obj.position.clone(), t.kind === 'tack' ? 'tack' : t.kind, t.fromRear);
        } else {
          this.fx.sparks(t.obj.position, { count: 3, speed: 3 });
        }
        t.obj.visible = false;
        (this.pools[t.kind] ||= []).push(t.obj);
        this.tacks.splice(i, 1);
      }
    }

    // 미사일 (베지어 곡선 유도)
    for (let i = this.missiles.length - 1; i >= 0; i--) {
      const m = this.missiles[i];
      m.t += dt;
      const p = Math.min(1, m.t / m.dur);
      const tg = m.target;
      _b.set(tg.x, 1.0, -tg.s);
      // 제어점: 위로 솟았다가 옆으로 휘어 내리꽂기
      _a.set((m.from.x + _b.x) / 2 + m.side * 4, 8, (m.from.z + _b.z) / 2);
      const u = 1 - p;
      m.prev.copy(m.obj.position);
      m.obj.position.set(
        u * u * m.from.x + 2 * u * p * _a.x + p * p * _b.x,
        u * u * m.from.y + 2 * u * p * _a.y + p * p * _b.y,
        u * u * m.from.z + 2 * u * p * _a.z + p * p * _b.z,
      );
      _a.subVectors(m.obj.position, m.prev);
      if (_a.lengthSq() > 1e-6) m.obj.lookAt(_b.copy(m.obj.position).add(_a));
      if (p >= 1) {
        const pos = m.obj.position.clone();
        m.obj.visible = false;
        this.missilePool.push(m.obj);
        this.missiles.splice(i, 1);
        this.fx.explosion(pos, 0.75);
        this.fx.shockwave(new THREE.Vector3(pos.x, 0.05, pos.z), 9, 0xffd04a);
        if (tg.alive) ctx.onHit(tg, TUNE.superDmg, pos, 'super', m.fromRear);
      }
    }
    return res;
  }
}
