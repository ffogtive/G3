// 키보드 + 터치(UI 버튼/스와이프) 입력 통합.
// held: 누르고 있는 상태, consume(name): 이번 프레임에 새로 눌렸는지 (엣지 트리거)

const KEYMAP = {
  ArrowLeft: 'left', KeyA: 'left',
  ArrowRight: 'right', KeyD: 'right',
  ArrowDown: 'brake', KeyS: 'brake',
  Space: 'fire', KeyJ: 'fire', ArrowUp: 'jump', KeyW: 'jump',
  KeyR: 'super', ShiftLeft: 'super', ShiftRight: 'super', KeyK: 'super', KeyE: 'super',
  KeyH: 'horn',
  KeyP: 'pause', Escape: 'pause',
  KeyM: 'mute',
  Enter: 'confirm', NumpadEnter: 'confirm',
};

export class Input {
  constructor(target) {
    this.held = Object.create(null);
    this.pressedSet = new Set();
    this.lastPointerType = 'mouse';
    this.enabled = true;

    window.addEventListener('keydown', (e) => {
      const name = KEYMAP[e.code];
      if (!name) return;
      if (['left', 'right', 'brake', 'fire'].includes(name) || e.code === 'Space') e.preventDefault();
      if (!e.repeat) this._down(name);
    }, { passive: false });
    window.addEventListener('keyup', (e) => {
      const name = KEYMAP[e.code];
      if (name) this._up(name);
    });
    window.addEventListener('blur', () => { for (const k in this.held) this.held[k] = false; });

    // 캔버스 스와이프 (모바일): 좌우 스와이프 = 차선 변경, 위로 스와이프 = 분노 미사일
    this._swipe = null;
    target.addEventListener('pointerdown', (e) => {
      this.lastPointerType = e.pointerType;
      this._swipe = { id: e.pointerId, x: e.clientX, y: e.clientY, t: performance.now(), fired: false };
    });
    target.addEventListener('pointermove', (e) => {
      const sw = this._swipe;
      if (!sw || sw.id !== e.pointerId || sw.fired) return;
      const dx = e.clientX - sw.x, dy = e.clientY - sw.y;
      if (Math.abs(dx) > 34 && Math.abs(dx) > Math.abs(dy) * 1.2) {
        this._tap(dx < 0 ? 'left' : 'right');
        sw.fired = true;
      } else if (dy < -60 && Math.abs(dy) > Math.abs(dx) * 1.5) {
        this._tap('super');
        sw.fired = true;
      }
    });
    const end = (e) => { if (this._swipe && this._swipe.id === e.pointerId) this._swipe = null; };
    target.addEventListener('pointerup', end);
    target.addEventListener('pointercancel', end);
  }

  _down(name) {
    if (!this.held[name]) this.pressedSet.add(name);
    this.held[name] = true;
  }
  _up(name) { this.held[name] = false; }
  _tap(name) { this.pressedSet.add(name); }

  // UI 터치 버튼에서 호출
  control(name, down) {
    if (down) this._down(name); else this._up(name);
  }

  isDown(name) { return !!this.held[name]; }
  consume(name) {
    if (this.pressedSet.has(name)) { this.pressedSet.delete(name); return true; }
    return false;
  }
  peek(name) { return this.pressedSet.has(name); }
  endFrame() { this.pressedSet.clear(); }
  reset() { this.pressedSet.clear(); for (const k in this.held) this.held[k] = false; }
}
