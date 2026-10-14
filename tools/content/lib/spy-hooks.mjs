// Node module hooks for the one-time web export (tools/export-content.mjs).
// game/js/*.js import './vehicles.js' (or '../vehicles.js'); we hand them vehicles-spy.mjs instead, which re-exports
// the REAL, unmodified vehicles.js (real dimensions — the dev stub's dims are wrong, NATIVE_PORT 3-6) and only tags
// each built mesh with the spec it was built from (kind + opts incl. the RNG-drawn seed/color), so goldens can record them.
export async function resolve(specifier, context, next) {
  const parent = context.parentURL || '';
  if ((specifier === './vehicles.js' || specifier === '../vehicles.js') && parent.includes('/game/js/')) {
    return { url: new URL('./vehicles-spy.mjs', import.meta.url).href, shortCircuit: true };
  }
  return next(specifier, context);
}
