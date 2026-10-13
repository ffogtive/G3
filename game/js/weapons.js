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
  }

  reset() {
    for (const t of this.tacks) { t.obj.visible = false; this.tackPool.push(t.obj); }
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

  // 지금 압정을 쏘면 맞을 대상
  _muzzle(player, out) { return out.set(player.x, 1.95 + player.hop, -(player.s + 0.4)); }

  fireTack(player, boss) {
    const target = boss.targetFor(player);
    const obj = this._get(this.tackPool, 'tack');
    const from = this._muzzle(player, new THREE.Vector3());
    const dur = 0.3;
    let to;
    if (target) {
      const leadS = target.s + target.v * dur - target.len * 0.3;
      to = new THREE.Vector3(target.x + (Math.random() - 0.5) * Math.min(1.2, target.w * 0.5), 0.6 + Math.random() * 0.7, -leadS);
    } else {
      to = new THREE.Vector3(player.x + (Math.random() - 0.5) * 0.4, 0.05, -(player.s + 20));
    }
    obj.position.copy(from);
    this.tacks.push({ obj, from, to, t: 0, dur, target, arc: target ? 2.2 : 3 });
    this.audio.play('tack', { pitch: 0.9 + Math.random() * 0.25, volume: 0.6 });
    this.shots++;
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
    this.missiles.push({ obj, from, target, t: 0, dur: 0.62, side, prev: from.clone() });
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
        this.cool = 1 / TUNE.tackRate;
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
        t.to.z = -(t.target.s - t.target.len * 0.3);
        t.to.x += (t.target.x - t.to.x) * Math.min(1, dt * 10);
      }
      t.obj.position.lerpVectors(t.from, t.to, p);
      t.obj.position.y += Math.sin(Math.PI * p) * t.arc;
      t.obj.rotation.x += dt * 25;
      if (p >= 1) {
        if (t.target && t.target.alive && Math.abs(t.target.x - t.to.x) < t.target.w / 2 + 0.7) {
          this.hits++;
          ctx.onHit(t.target, TUNE.tackDmg, t.obj.position.clone(), 'tack');
        } else {
          this.fx.sparks(t.obj.position, { count: 3, speed: 3 });
        }
        t.obj.visible = false;
        this.tackPool.push(t.obj);
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
        if (tg.alive) ctx.onHit(tg, TUNE.superDmg, pos, 'super');
      }
    }
    return res;
  }
}
