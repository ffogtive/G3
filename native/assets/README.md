# native/assets — baked meshes (M1a set)

가설: ✅ 웹 빌드(`web-frozen` = `753549a`)의 정점색 메시는 Node에서 원본 그대로 만들어서 bake하면 Godot에서 같은 모양·같은 색으로 다시 만들 수 있다
(98개 모델의 삼각형·정점 수가 일치하고 AABB 오차 ≤ 1 mm. 웹 Lambert와 픽셀 비교한 결과는 아래 "검증"에 있다).
❓ 별도 채널로 구운 정점 AO(`custom0.x`)를 켜면 Mobile 렌더러(SSAO 없음)에서도 웹보다 접지감이 좋아진다. 기기에서 판정해야 한다.

Everything in `vehicles/`, `props/`, `road/` is **generated, never edited by hand**. Pipeline (docs/NATIVE_PORT.md 3-6 / 3-7):

```
node tools/bake-meshes.mjs [--out=native/build/bake] [--only=sedan,cone] [--no-ao] [--list]      # ~55 s, 98 models
godot47 --headless --path native -s res://tools/import_meshes.gd -- --in=<abs out dir> [--only=…]  # → res://assets/**
godot47 --headless --path native -s res://tests/run_tests.gd -- --filter=test_meshes             # T0 check
```

Both steps are deterministic: rebuilding from the same commit leaves `git status` clean. The bake refuses nothing
but logs `WARN game/js differs from web-frozen` if `game/js` has moved since `753549a`.

## What is baked

| category | files | source (unmodified web code) |
|---|---|---|
| `vehicles/` | `<kind>_v<variant>.res` main mesh, `.tres` VehicleTemplate, `<name>.<node>.res` sub-meshes | `buildVehicle(kind, {variant})` for the 8 NPC kinds of `NPC_KINDS` (sedan, suv, compact, pickup1t, taxi, truck, van, bus) × every canonical variant, `player`, `villainSedan` (beyond M1a) |
| `road/` | `segment_v0..3[_sb_right].res` | `buildRoadSegment(SEG_LEN, {night:false, soundBarrier, seed})`: day, the 4 seed variants, with/without right sound barrier |
| `props/` | `tree/pine/bush/paddy/house/church/mountain/cloud_v<i>.res`, `cctv`, `cone`, `warning_triangle`, `gantry_sign_2l`, `vms` | `buildProp(kind, v, {night:false})`, `buildShoulderObstacle('cones' / 'breakdown')`, `buildGantrySign` / `buildVMS` (frames + blank panel quads, beyond M1a) |

The **breakdown car** (고장차) is not its own mesh: `shoulder.js` picks sedan / van / pickup1t / compact with a fixed
colour and hazards on, so the view uses that NPC template + `props/warning_triangle`.

## Conventions (the contract between bake, importer and views)

- **Space:** right-handed, Y up, −Z forward, metres, same as the web (NATIVE_PORT 3-4). Vehicle origin = road
  contact under the body centre.
- **Winding:** the bake writes Three's CCW triangles, the importer swaps indices 1↔2 so Godot's CW front faces render
  (`test_meshes` checks that `(b−a)×(c−a)` opposes the normal for ≥ 99.5 % of triangles; it is 100 %).
- **Normals:** flat face normals (what Three's `flatShading` derives); vertices are welded per plane only.
- **COLOR:** sRGB RGBA8, the exact web hex. Materials set `vertex_color_is_srgb = true`.
  *Deviation from NATIVE_PORT 3-4 ("linear, `vertex_color_is_srgb=false`")*: Godot 4.7.2 stores `ARRAY_COLOR` as
  RGBA8 (measured: linear 0.001 → 0), so linear 8-bit would crush dark paint; sRGB8 keeps every web colour exact.
  Vehicle body colours already include the web's height AO (`0.7 + 0.3·smoothstep(0.06, 1.05, y)`).
- **CUSTOM0** (`ARRAY_CUSTOM_RGBA_HALF`, read as `CUSTOM0` in shaders):
  - `x` = baked AO visibility (1 = open sky). **Not** multiplied into COLOR, so it can be toggled:
    `albedo *= mix(1.0, CUSTOM0.x, ao_strength)`. Hemisphere ray cast (cosine-weighted, 48–96 rays/vertex) against
    the model's own opaque body triangles (+ a ground plane for props), max distance per model (`ao.dist` in the
    bake header). `--no-ao` writes 1.
  - `y` = part id (table below). Lamp shaders collapse or light vertices by id.
  - `z` = paint shade factor k for runtime NPC tint (0 = fixed colour):
    `srgb = k < 1 ? paint·k : paint + (1 − paint)(k − 1)` (= vehicles.js `shade()`), then `× w`.
  - `w` = the height-AO factor already in COLOR (1 for scenery).
- **UV** (panels only): `v = 1 − v` (Three CanvasTexture flipY). Text is not baked: panels are quads whose texture
  Godot renders at stage load (NATIVE_PORT 3-7 (2)); `panels` in the metadata names material / texture slot.
- **Coplanar layers:** where the web stacks a smaller decal on a coplanar face (web z-fights, e.g. truck roof
  panels), the bake pushes the smaller triangle out by 0.4 mm per layer. That is the only geometry change; it is why
  AABBs may differ from the JS Box3 by ≤ 1 mm.

### Surfaces (in this order when present)

| surface | material (stock .res default) | contents |
|---|---|---|
| `body` | Lambert, vertex colour, casts shadow | everything opaque; non-detailed vehicles include merged wheels (`wheel_<i>` parts) |
| `lamps` | unshaded, vertex colour, no shadow | every switchable lamp mesh. **The stock material shows all lamps lit**: a view must use a lamp shader (mask by `CUSTOM0.y`) — the web hides an off lamp |
| `glass` | Lambert/unlit, flat colour + opacity, alpha | detailed vehicles' windows |
| `fx` | unshaded, additive, no depth write | headlight beam quad (`beam`, detailed only) |
| `panel` | per panel, UV'd | text/texture quads (`panel_<i>`) |

### Part ids (`CUSTOM0.y`, append-only)

| id | part | web switch |
|---|---|---|
| 0 | `body` | — |
| 1 / 2 / 3 | `brake_L` / `brake_R` / `brake_C` | `setBrake` (C = centre high-mount / bar) |
| 4 / 5 / 6 | `head_L` / `head_R` / `head_C` | `setHeadlights` (C = taxi roof sign). There is no separate high-beam mesh in the web: high beam = `head` at higher emission + `beam` |
| 7–12 | `hazard_FL/FR/RL/RR/FC/RC` | `setHazard` |
| 13–16 | `blink_FL/FR/RL/RR` | `setBlinker('left' → FL+RL, 'right' → FR+RR)`; L = −X |
| 17 | `glow` | always-lit emissive |
| 18–21 | `siren_R`, `siren_B`, `strobe_0`, `strobe_1` | beacons (not in the M1a set) |
| 24 | `beam` | headlight beam quad |
| 25 | `glass` | — |
| 32–47 | `wheel_<i>` | merged wheels in a non-detailed body (centre/radius in `merged_wheels`) |
| 64–95 | `panel_<i>` | panel quads |

Lamp groups (`lamp_groups` in the template, only parts the model has): `brake`, `head`, `hazard`, `blink_L`, `blink_R`,
`glow`, `siren_R`, `siren_B`, `strobe`, `beam`. Lamp L/R/C and front/rear are split by connected component of the
web lamp mesh (|x| < 0.18 m = centre, like `vehicles.js blinkGeos`).

## VehicleTemplate (`vehicles/<name>.tres`, script `vehicles/vehicle_template.gd`)

`kind`, `variant`, `detailed`, `npc`, `npc_weight`, `length/width/height/wheel_radius` (= vehicles.js userData),
`mesh` (main ArrayMesh), `surface_names`, `parts` (name → `{surface, id, first_index, index_count, first_vertex,
vertex_count, aabb}`; ranges are contiguous in that surface), `lamp_groups`, `lamp_off_multiplier`, `sub_meshes`
(node → `{mesh, transforms: Array[Transform3D]}`: detailed `wheel` ×4, `driver`, `cannon`), `merged_wheels`
(`[{part, id, center, radius, width}]`), `points` (exhaust, smokePoint, muzzle, blink halo …), `points_local`,
`paint_default`, `tintable`, `livery` (taxi, pickup1t ignore the spawn colour), `js_ref` (bbox, tris,
welded_vertices, source call, paint fit, AO stats). No `class_name`: load it with
`preload("res://assets/vehicles/vehicle_template.gd")`.

Props and road `.res` carry the same information as `get_meta(&"bake")`: `{name, category, m1a, surfaces, parts,
points, js_ref, ao, panels}`.

## Verification (2026-10-13, Godot 4.7.2, Xvfb + lavapipe, Mobile renderer)

- `tests/test_meshes.gd`: 98 models, every M1a name present (NPC kinds from `data/config.json`, variants from
  `data/vehicle_kinds.json` canon), vertex and triangle counts == bake/JS (sedan 1188 tris), AABB within 1 cm
  (actual ≤ 1 mm), CW winding 100 %, part ranges and ids consistent, lamps brake/head/blink ×4/hazard and ≥ 4 wheels
  on every vehicle, dims == `vehicle_kinds.json`, NPC paint tint fits all 14 NPC colours exactly (0 non-fitting
  vertices; the bake rebuilds each vehicle with every colour and compares).
- Contact sheets: `native/tools/contact_sheet.gd --shading=web` evaluates Three r170 Lambert with the stage-1 day
  light, and `node tools/bake-meshes.mjs --web-sheet=<layout>` renders the same cells with the real web builders.
  Share of pixels whose max channel differs by > 48/255 (lamps on): road 0.39 %, big props 0.33 %, props 3.4 %
  (text panels, which Godot renders separately), vehicles 5.1 %. 89 % of the vehicle diff pixels are the two truck
  roofs, where the web z-fights two coplanar panels and the bake's coplanar layering draws the decal on top. The
  rest is 0.6 %.
