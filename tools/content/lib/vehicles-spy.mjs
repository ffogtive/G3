// See spy-hooks.mjs. The '?real' query makes this the single real vehicles.js instance in the process.
import * as R from '../../../game/js/vehicles.js?real';
export * from '../../../game/js/vehicles.js?real';

export function buildVehicle(kind, opts = {}) {
  const mesh = R.buildVehicle(kind, opts);
  mesh.userData.__spec = { kind, opts: { ...opts } };
  return mesh;
}
