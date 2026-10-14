const log = []; window.__audioLog = log;
export const audio = { init() {}, setMuted() {}, isMuted() { return true; }, play(n) { log.push(n); }, setEngine() {}, startAmbience() {}, cheerHorns() { log.push('cheer'); }, startMusic(k) { log.push('music:' + k); }, stopMusic() {}, duck() {} };
