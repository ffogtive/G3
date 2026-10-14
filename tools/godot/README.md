# tools/godot — engines and native build helpers (container)

가설: ✅ M1-0 버전 게이트 (a) Nix 경로 통과 — `godot47` = Godot 4.7.2-stable(upstream `ed1daf0bf`),
공식 export templates(Linux·Android·iOS 포함), Nix Mesa lavapipe로 헤드리스·Xvfb Mobile 렌더 모두 동작.

| Command | Engine | Use |
|---|---|---|
| `godot47` | **4.7.2.stable.nixpkgs.ed1daf0bf** (`/opt/godot47/godot47`) | everything in `native/` (required: ext has `compatibility_minimum = "4.7"`, runner uses `Logger` 4.5+) |
| `godot` | 4.4.1 Debian repack (`/opt/godot/godot`) | M0 spike only (`tools/godot/spike`) |

## Scripts

| Script | What | Time |
|---|---|---|
| `install_godot_nix.sh [--verify-eval] [--smoke-render]` | 4.7.2 editor + templates + Mesa/vulkan-loader from cache.nixos.org, NarHash-pinned; wrapper `/usr/local/bin/godot47`; templates linked to `~/.local/share/godot/export_templates/4.7.2.stable` | first run ≈ 1 min (≈1.5 GB), re-run ≈ 2 s |
| `build_ext.sh [--target=all] [--verify-api] [--fetch-only]` | godot-cpp 10.0.0-stable @ `507ed9d8` + `native/ext` → `native/ext/bin/libtraffic.linux.<target>.x86_64.so` | first ≈ 7 min, incremental ≈ 1 s |
| `install_godot.sh` | M0: 4.4.1 from the Ubuntu pool | ≈ 30 s |
| `../native-check.sh` | ext build → import → T0 (`tests/run_tests.gd`) → Xvfb Mobile smoke shot | ≈ 12 s warm |

## Pins (install_godot_nix.sh)

nixpkgs release `nixos-26.05.11767.7993f34ee47e` (`nixexprs.tar.xz` sha256 `eff212d6…1511`), x86_64-linux:

| Store path | NarHash |
|---|---|
| `d2kbzsp3cmn6jjd4dkbw7h0047wwbgdl-godot-4.7.2-stable` | `sha256:1q89gbnr…r3wq` |
| `fm6d6j23xzgdsppnqg13g9i45bflmzgv-godot-export-templates-bin-4.7.2-stable` | `sha256:0yj9x27i…zpvs` (same NAR as `8m369hjy…` cited in NATIVE_PORT 1-2) |
| `ij4mv4rzvd60yql6jafpmh95x3l63937-mesa-26.1.8` | `sha256:193p1r4c…s45a` |
| `9lkc4la5w66ajdqi1jfvdb12ifl26629-vulkan-loader-1.4.341.0` | `sha256:1mn77bfr…0js7` |

`--verify-eval` re-derives all four outPaths from the pinned nixexprs with `nix-instantiate` (checked ✅).

## Notes

- **Same engine as the Mac?** Same tag and commit (`4.7.2-stable`, `ed1daf0bf`), same `VERSION_FULL_CONFIG`
  (`4.7.2.stable`, so the same templates dir and project format). nixpkgs applies **no source patches** to 4.7 on
  Linux but links system libraries (harfbuzz 13.2.1, ICU 76, freetype 2.14, mbedtls 3.6 …) instead of Godot's
  bundled copies and sets `BUILD_NAME=nixpkgs`. Text shaping in T2 shots may differ slightly from the official
  build ❓ — compare before trusting a text baseline across machines.
- **Why the wrapper drops LD_LIBRARY_PATH:** the Nix binary runs on Nix glibc 2.42; system Mesa/LLVM or the
  4.4.1 side-loaded libs would mix ABIs. `VK_DRIVER_FILES` pins the Vulkan ICD to Nix lavapipe (the loader would
  otherwise also scan `/usr/share/vulkan/icd.d`). GL (Compatibility) goes through Nix glvnd → Nix Mesa llvmpipe.
- **GDExtensions built with Ubuntu g++** load into the Nix binary only with `-static-libstdc++ -static-libgcc`
  (the Nix closure has no libstdc++); `native/ext/CMakeLists.txt` does this and `build_ext.sh` checks `NEEDED`.
- **Fresh `.godot/` + GDExtension + headless `--import` = crash on quit** (4.7.2 EditorHelp doc-thread race).
  Seed `.godot/extension_list.cfg` first — `tools/native-check.sh` does; see `native/ext/README.md`.
- No Nix daemon runs here: as root the pre-installed multi-user store is used directly. On a machine without
  Nix the script does a pinned single-user install (`nix-2.34.6`, sha256-checked) first.
