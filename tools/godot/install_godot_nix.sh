#!/usr/bin/env bash
# install_godot_nix.sh — M1-0 version gate (a): Godot 4.7.2-stable from cache.nixos.org.
#
# 가설: ✅ nixos-26.05 의 godot_4_7(=4.7.2-stable, upstream commit ed1daf0bf) + 공식 export templates
#       (-bin, iOS/Android 포함) + 같은 리비전의 Mesa(lavapipe)·vulkan-loader 를 Nix glibc 클로저 그대로
#       쓰면, 시스템 라이브러리를 섞지 않고 헤드리스·Xvfb Mobile 렌더가 모두 된다.
#
# What it does (idempotent, re-runnable; ~1.5 GB download on first run, ~5 s afterwards):
#   1. makes sure a Nix store is usable (pre-installed multi-user Nix used daemon-less as root, or a
#      pinned single-user install from releases.nixos.org when no Nix exists);
#   2. substitutes 4 pinned store paths from https://cache.nixos.org (signature-checked by Nix) and
#      re-checks each NarHash against the pins below; adds GC roots under $PREFIX/gcroots;
#   3. writes the wrapper $PREFIX/godot47 (+ /usr/local/bin/godot47). /usr/local/bin/godot (4.4.1) is
#      NOT touched;
#   4. links the export templates into ~/.local/share/godot/export_templates/<VERSION_FULL_CONFIG>
#      and fails if the dir name / version.txt differ from the editor's VERSION_FULL_CONFIG;
#   5. smoke-checks: --version, a headless script, and (with --smoke-render) an Xvfb Mobile shot.
#
# Options:  --verify-eval   also download the pinned nixexprs tarball and re-derive every store path
#                           with nix-instantiate (proves the pins belong to NIXPKGS_RELEASE, x86_64-linux)
#           --smoke-render  run the M0 spike under Xvfb with --rendering-method mobile and check the
#                           blank-image guard (needs xvfb-run)
# Env:      GODOT47_PREFIX (default /opt/godot47), GODOT47_BIN_LINK (default /usr/local/bin/godot47)
#
# Pins: nixpkgs release nixos-26.05.11767.7993f34ee47e (channel nixos-26.05, 2026-10-13).
# The x86_64-linux outPaths below were derived from that release's nixexprs.tar.xz with
#   nix-instantiate --eval -E '(import <nixexprs> {system="x86_64-linux";}).godot_4_7.outPath' (etc.)
set -euo pipefail

PREFIX=${GODOT47_PREFIX:-/opt/godot47}
BIN_LINK=${GODOT47_BIN_LINK:-/usr/local/bin/godot47}
WANT_VERSION_CONFIG=4.7.2.stable

NIXPKGS_RELEASE=nixos-26.05.11767.7993f34ee47e
NIXEXPRS_URL=https://releases.nixos.org/nixos/26.05/${NIXPKGS_RELEASE}/nixexprs.tar.xz
NIXEXPRS_SHA256=eff212d642c1313e378b004c934887575f6b632fa988a61ffcad9479d6a81511

# Fallback Nix (only used when no Nix exists on the machine).
NIX_TARBALL_URL=https://releases.nixos.org/nix/nix-2.34.6/nix-2.34.6-x86_64-linux.tar.xz
NIX_TARBALL_SHA256=311b9f406f0239ef640a1e3fbea1df1bac9d3a7c316c4def30df3206dd964960

CACHE_URL=https://cache.nixos.org
CACHE_KEY='cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY='

# name  nixpkgs-attr  store-path  narHash
PINS=(
  "godot         godot_4_7                    /nix/store/d2kbzsp3cmn6jjd4dkbw7h0047wwbgdl-godot-4.7.2-stable                       sha256:1q89gbnrmjvgvmhy5c3k7kp3hswyls1n1wghsas9wn54cylqr3wq"
  "templates     godot_4_7.export-templates-bin /nix/store/fm6d6j23xzgdsppnqg13g9i45bflmzgv-godot-export-templates-bin-4.7.2-stable sha256:0yj9x27imlf64hz80ngb6lml457j2sh30nrw1imanzv2aciazpvs"
  "mesa          mesa                         /nix/store/ij4mv4rzvd60yql6jafpmh95x3l63937-mesa-26.1.8                              sha256:193p1r4chvl4vd3j61mjbkm6yww8956pjqkr6y4jv1rqw0wss45a"
  "vulkan-loader vulkan-loader                /nix/store/9lkc4la5w66ajdqi1jfvdb12ifl26629-vulkan-loader-1.4.341.0                  sha256:1mn77bfry3ypsqyvf5fdga4v1y360gq8g89m3m9c3rxcmiph0js7"
)

VERIFY_EVAL=0
SMOKE_RENDER=0
for a in "$@"; do
  case "$a" in
    --verify-eval) VERIFY_EVAL=1 ;;
    --smoke-render) SMOKE_RENDER=1 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

log() { printf '[install_godot_nix] %s\n' "$*"; }
die() { printf '[install_godot_nix] FAIL: %s\n' "$*" >&2; exit 1; }
declare -A ATTR_OF PATH_OF HASH_OF
NAMES=()
for e in "${PINS[@]}"; do
  read -r n a p h <<<"$e"
  NAMES+=("$n"); ATTR_OF[$n]=$a; PATH_OF[$n]=$p; HASH_OF[$n]=$h
done

[ "$(uname -m)" = x86_64 ] || die "x86_64-linux only (pins are x86_64-linux store paths)"
[ -f /etc/ssl/certs/ca-certificates.crt ] && export NIX_SSL_CERT_FILE=${NIX_SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}

# ---------------------------------------------------------------------------------------------
log "[1/5] Nix store"
find_nix_bin() {
  local d
  for d in /nix/var/nix/profiles/default/bin "$HOME/.nix-profile/bin"; do
    [ -x "$d/nix-store" ] && { echo "$d"; return 0; }
  done
  command -v nix-store >/dev/null 2>&1 && { dirname "$(command -v nix-store)"; return 0; }
  return 1
}
if ! NIX_BIN=$(find_nix_bin); then
  log "no Nix found -> single-user install of $(basename "$NIX_TARBALL_URL")"
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 -o "$tmp/nix.tar.xz" "$NIX_TARBALL_URL"
  echo "$NIX_TARBALL_SHA256  $tmp/nix.tar.xz" | sha256sum -c --quiet || die "nix tarball sha256 mismatch"
  mkdir -p "$tmp/x" && tar -xJf "$tmp/nix.tar.xz" -C "$tmp/x"
  mkdir -p /nix
  "$tmp"/x/nix-*-x86_64-linux/install --no-daemon --no-channel-add --no-modify-profile --yes
  NIX_BIN=$(find_nix_bin) || die "nix install finished but nix-store not found"
fi
export PATH="$NIX_BIN:$PATH"
log "  using $(nix-store --version) from $NIX_BIN"
NIXOPTS=(--option substituters "$CACHE_URL" --option trusted-public-keys "$CACHE_KEY" --option require-sigs true)

# ---------------------------------------------------------------------------------------------
if [ "$VERIFY_EVAL" = 1 ]; then
  log "[1b] --verify-eval: re-derive store paths from $NIXPKGS_RELEASE"
  ev=$(mktemp -d)
  curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 -o "$ev/nixexprs.tar.xz" "$NIXEXPRS_URL"
  echo "$NIXEXPRS_SHA256  $ev/nixexprs.tar.xz" | sha256sum -c --quiet || die "nixexprs sha256 mismatch"
  tar -xJf "$ev/nixexprs.tar.xz" -C "$ev"
  src=$(find "$ev" -mindepth 1 -maxdepth 1 -type d | head -1)
  for n in "${NAMES[@]}"; do
    got=$(nix-instantiate --eval --json -E \
      "(import $src { system = \"x86_64-linux\"; config = {}; overlays = []; }).${ATTR_OF[$n]}.outPath" | tr -d '"')
    [ "$got" = "${PATH_OF[$n]}" ] || die "eval mismatch for $n: pinned ${PATH_OF[$n]}, nixpkgs says $got"
    log "  eval ok: ${ATTR_OF[$n]} -> $got"
  done
  rm -rf "$ev"
fi

# ---------------------------------------------------------------------------------------------
log "[2/5] substitute pinned store paths from $CACHE_URL (+ NarHash check, GC roots)"
mkdir -p "$PREFIX/gcroots"
for name in "${NAMES[@]}"; do
  path=${PATH_OF[$name]} want=${HASH_OF[$name]}
  if [ ! -e "$path" ] || ! nix-store --check-validity "$path" 2>/dev/null; then
    log "  fetching $name ($path)"
  fi
  nix-store "${NIXOPTS[@]}" --realise "$path" --add-root "$PREFIX/gcroots/$name" >/dev/null
  got=$(nix-store --query --hash "$path")
  [ "$got" = "$want" ] || die "NarHash mismatch for $name: want $want got $got"
  log "  ok $name  $got"
done

GODOT_OUT=${PATH_OF[godot]}
TPL_OUT=${PATH_OF[templates]}
MESA_OUT=${PATH_OF[mesa]}
GODOT_EXE="$GODOT_OUT/bin/godot4.7"
LVP_ICD="$MESA_OUT/share/vulkan/icd.d/lvp_icd.x86_64.json"
[ -x "$GODOT_EXE" ] || die "missing $GODOT_EXE"
[ -f "$LVP_ICD" ] || die "missing lavapipe ICD $LVP_ICD"

# ---------------------------------------------------------------------------------------------
log "[3/5] wrapper $PREFIX/godot47 -> $BIN_LINK"
# Only Nix-closure libraries may enter this process (Nix glibc 2.42). The caller's LD_LIBRARY_PATH is
# dropped on purpose: /opt/godot/lib (4.4.1 side-loads, system glibc) or system Mesa would mix ABIs.
# VK_DRIVER_FILES pins the Vulkan ICD to Nix lavapipe (otherwise the loader also scans /usr/share and
# could pick Ubuntu's libvulkan_lvp.so, linked against the system LLVM/libstdc++).
cat > "$PREFIX/godot47.new" <<EOF
#!/bin/sh
# Generated by tools/godot/install_godot_nix.sh — Godot $WANT_VERSION_CONFIG (nixpkgs $NIXPKGS_RELEASE).
export VK_DRIVER_FILES="$LVP_ICD"
export VK_ICD_FILENAMES="$LVP_ICD"
export __EGL_VENDOR_LIBRARY_FILENAMES="$MESA_OUT/share/glvnd/egl_vendor.d/50_mesa.json"
export __GLX_VENDOR_LIBRARY_NAME=mesa
export LIBGL_DRIVERS_PATH="$MESA_OUT/lib/dri"
export LD_LIBRARY_PATH="$MESA_OUT/lib"
exec "$GODOT_EXE" "\$@"
EOF
chmod +x "$PREFIX/godot47.new"
mv -f "$PREFIX/godot47.new" "$PREFIX/godot47"
mkdir -p "$(dirname "$BIN_LINK")"
ln -sfn "$PREFIX/godot47" "$BIN_LINK"
cat > "$PREFIX/PINS.txt" <<EOF
nixpkgs_release=$NIXPKGS_RELEASE
upstream_tag=4.7.2-stable
upstream_commit=ed1daf0bf001b61586d9930840f2f1394092c079
$(for e in "${PINS[@]}"; do echo "$e" | tr -s ' '; done)
EOF

# ---------------------------------------------------------------------------------------------
log "[4/5] export templates + VERSION_FULL_CONFIG check"
ver_line=$("$PREFIX/godot47" --headless --version 2>/dev/null | tail -1)
log "  godot47 --version: $ver_line"
probe=$(mktemp -d)
cat > "$probe/project.godot" <<'EOF'
config_version=5
EOF
cat > "$probe/probe.gd" <<'EOF'
extends SceneTree
## Prints Godot's VERSION_FULL_CONFIG (the export-templates dir name): "<major>.<minor>[.<patch>].<status>".
func _initialize() -> void:
	var v: Dictionary = Engine.get_version_info()
	var num: String = "%d.%d" % [v.major, v.minor]
	if int(v.patch) != 0:
		num += ".%d" % v.patch
	var cfg: String = "%s.%s" % [num, v.status]
	if ClassDB.class_exists(&"CSharpScript"):
		cfg += ".mono"
	print("VERSION_FULL_CONFIG=", cfg)
	quit(0)
EOF
cfg=$("$PREFIX/godot47" --headless --path "$probe" -s res://probe.gd 2>/dev/null | sed -n 's/^VERSION_FULL_CONFIG=//p' | tail -1)
rm -rf "$probe"
[ "$cfg" = "$WANT_VERSION_CONFIG" ] || die "editor VERSION_FULL_CONFIG='$cfg' (headless script failed?), want $WANT_VERSION_CONFIG"
log "  headless script ok, VERSION_FULL_CONFIG=$cfg"
tpl_src="$TPL_OUT/share/godot/export_templates/$cfg"
[ -d "$tpl_src" ] || die "templates dir $tpl_src missing (store has: $(ls "$TPL_OUT/share/godot/export_templates"))"
tpl_ver=$(tr -d '[:space:]' < "$tpl_src/version.txt")
[ "$tpl_ver" = "$cfg" ] || die "templates version.txt '$tpl_ver' != editor '$cfg'"
data_home=${XDG_DATA_HOME:-$HOME/.local/share}
tpl_dst="$data_home/godot/export_templates/$cfg"
mkdir -p "$(dirname "$tpl_dst")"
if [ -L "$tpl_dst" ] || [ ! -e "$tpl_dst" ]; then
  ln -sfn "$tpl_src" "$tpl_dst"
else
  die "$tpl_dst exists and is not a symlink; move it away first"
fi
for f in linux_debug.x86_64 linux_release.x86_64 android_debug.apk android_release.apk android_source.zip ios.zip; do
  [ -e "$tpl_dst/$f" ] || die "template $f missing"
done
log "  templates: $tpl_dst -> $tpl_src (linux, android apk/source, ios.zip present)"

# ---------------------------------------------------------------------------------------------
log "[5/5] smoke"
case "$ver_line" in
  "$WANT_VERSION_CONFIG".*) log "  version ok" ;;
  *) die "unexpected version '$ver_line'" ;;
esac
if [ "$SMOKE_RENDER" = 1 ]; then
  here=$(cd "$(dirname "$0")" && pwd)
  sp=$(mktemp -d)
  cp -r "$here/spike/." "$sp/"; rm -rf "$sp/.godot"
  "$PREFIX/godot47" --headless --path "$sp" --import >/dev/null 2>&1 || true
  out=$(xvfb-run -a -s "-screen 0 1280x1024x24" "$PREFIX/godot47" --path "$sp" --rendering-method mobile \
        --audio-driver Dummy -- --shot="$sp/shot.png" --frames=20 2>&1 | grep '^RESULT' || true)
  echo "$out" | sed 's/^/  /'
  echo "$out" | grep -q 'method=mobile driver=vulkan' || die "Mobile/Vulkan renderer did not start"
  echo "$out" | grep -q 'RESULT ok=true' || die "spike shot failed the blank-image guard"
  cp "$sp/shot.png" "$PREFIX/smoke_mobile.png"
  rm -rf "$sp"
  log "  Xvfb Mobile shot ok -> $PREFIX/smoke_mobile.png"
fi
log "OK: $BIN_LINK = Godot $ver_line (templates $cfg). /usr/local/bin/godot untouched: $(command -v godot >/dev/null && godot --version 2>/dev/null | tail -1 || echo n/a)"
