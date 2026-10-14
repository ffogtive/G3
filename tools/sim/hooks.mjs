// game/js/*.js 가 './vehicles.js' 를 import 하면 stub(Three 박스)으로 바꿔준다 → Node 에서 교통 시뮬 가능
export async function resolve(specifier, context, next) {
  if (specifier === './vehicles.js' && context.parentURL && context.parentURL.includes('/game/js/')) {
    return next(new URL('../../game/dev/stubs/vehicles.js', import.meta.url).href, context);
  }
  return next(specifier, context);
}
