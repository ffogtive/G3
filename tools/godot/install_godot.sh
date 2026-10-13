#!/usr/bin/env bash
# Re-runnable installer: Godot 4.4.1 (Ubuntu/Debian repack) into /opt/godot on Ubuntu 24.04 x86_64.
#
# Why 4.4.1 and not 4.6.3: godot_4.6.3+ds-2 links GLIBC_2.43 symbols (sqrtf/acosf@GLIBC_2.43);
# 24.04 ships glibc 2.39. 4.4.1 needs only GLIBC_2.38, but links 10 sonames that 24.04 lacks
# (icu76, mbedtls 3.6, enet7, wslay1, miniupnpc18, recast1, embree4). Those are side-loaded
# from the same archive pool into /opt/godot/lib (LD_LIBRARY_PATH via the wrapper) so the
# system apt state is not touched beyond normal 24.04 packages.
# godotengine.org / github releases are policy-blocked here; everything comes from archive.ubuntu.com.
#
# Result:  /opt/godot/godot (wrapper)  ->  /usr/local/bin/godot
#          Linux export templates in ~/.local/share/godot/export_templates/4.4.1.stable/
set -euo pipefail

PREFIX=/opt/godot
CACHE=${GODOT_DEB_CACHE:-/var/cache/godot-debs}
POOL=https://archive.ubuntu.com/ubuntu/pool
TPL_DIR="${HOME}/.local/share/godot/export_templates/4.4.1.stable"

# path-in-pool  sha256
DEBS=(
  "universe/g/godot/godot_4.4.1+ds-1_amd64.deb edb95657656ec137e503d30368b54608acb1ab91945773be2553811419d5a2d9"
  "universe/g/godot/godot-template-release_4.4.1+ds-1_amd64.deb 5ee0f634a47197763d398dc2c1cd9bd6c827a4dd3e2a40f5bdb010d9628ba23d"
  "universe/g/godot/godot-template-debug_4.4.1+ds-1_amd64.deb b3c07de18fe0b1cecaa36dd2cb53e6a1c60022d5062fcd17a0f939026717f4fa"
  "main/i/icu/libicu76_76.1-1ubuntu2_amd64.deb c289a52f92c9ab2a1783b6b5757c928bff228671f20473275a426798446a4ce1"
  "universe/e/enet/libenet7_1.3.18+ds-1_amd64.deb 7ab3a3b1e3fc36e49f60d90b4d47bb269982745ba40f05502db7fdf1dc2b7ab8"
  "universe/m/mbedtls/libmbedcrypto16_3.6.2-3ubuntu1_amd64.deb 155b18deb9efdce68e958a7e2ea4ea0b7d6c2e1b57495dd0f084b122122876c1"
  "universe/m/mbedtls/libmbedtls21_3.6.2-3ubuntu1_amd64.deb f4f730591bfd0da004566f5161b9b6627aea5bd21c0186266e88453575c5b6d6"
  "universe/m/mbedtls/libmbedx509-7_3.6.2-3ubuntu1_amd64.deb 155dd06d48c2b783d602960abd7daa794feb6f29f5299d43a65a17afdf45541a"
  "universe/w/wslay/libwslay1_1.1.1-4build1_amd64.deb b908b62da3b5b95a3b050f256a719b3274c9e8326699cd379705642058a3482c"
  "main/m/miniupnpc/libminiupnpc18_2.2.8-2build1_amd64.deb 7e663a81f8165cca34e0833f288b34677961f44180cb3c783d1edee3f8dc88e5"
  "universe/r/recastnavigation/librecast1_1.6.0+dfsg-1_amd64.deb ba0e388fda037ff61192977d909a1a010a8a70a239b9735198d0097df0664846"
  "universe/e/embree/libembree4-4_4.3.3+dfsg-1_amd64.deb ef92e1f04aa4a277f196676e0b884fd5ea454d7e539c2455432929a44c1e1547"
)

echo "[1/5] apt runtime deps (noble): tbb, Mesa GL/Vulkan(lavapipe), X/Wayland client libs, Xvfb"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  ca-certificates curl xvfb xauth libtbb12 \
  mesa-vulkan-drivers libvulkan1 libgl1-mesa-dri libgl1 libglx-mesa0 libegl1 libegl-mesa0 libgles2 \
  vulkan-tools mesa-utils \
  libx11-6 libxcursor1 libxinerama1 libxrandr2 libxi6 libxext6 libxrender1 libxkbcommon0 \
  libwayland-client0 libwayland-cursor0 libwayland-egl1 \
  libfontconfig1 libfreetype6 libharfbuzz0b libharfbuzz-icu0 libbrotli1 libogg0 libvorbis0a \
  libtheora0 libwebp7 libpng16-16t64 libzstd1 libpcre2-32-0 \
  libasound2t64 libpulse0 libdbus-1-3 libudev1 >/dev/null

echo "[2/5] download + verify debs into $CACHE"
mkdir -p "$CACHE"
for entry in "${DEBS[@]}"; do
  path=${entry% *}; sum=${entry##* }; f="$CACHE/$(basename "$path")"
  if [ ! -f "$f" ] || ! echo "$sum  $f" | sha256sum -c --status; then
    curl -fsSL --retry 3 -o "$f.part" "$POOL/$path"
    mv "$f.part" "$f"
  fi
  echo "$sum  $f" | sha256sum -c --quiet
done

echo "[3/5] extract into $PREFIX (clean)"
rm -rf "$PREFIX/root" "$PREFIX/lib" "$PREFIX/libroot"
mkdir -p "$PREFIX/root" "$PREFIX/lib" "$PREFIX/libroot"
for entry in "${DEBS[@]}"; do
  f="$CACHE/$(basename "${entry% *}")"
  case "$(basename "$f")" in
    godot*) dpkg-deb -x "$f" "$PREFIX/root" ;;
    *)      dpkg-deb -x "$f" "$PREFIX/libroot" ;;
  esac
done
cp -a "$PREFIX"/libroot/usr/lib/x86_64-linux-gnu/*.so* "$PREFIX/lib/"

echo "[4/5] wrappers"
for name in godot godot-template-release godot-template-debug; do
  cat > "$PREFIX/$name" <<EOF
#!/bin/sh
export LD_LIBRARY_PATH=$PREFIX/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}
exec $PREFIX/root/usr/bin/$name "\$@"
EOF
  chmod +x "$PREFIX/$name"
done
ln -sf "$PREFIX/godot" /usr/local/bin/godot

echo "[5/5] Linux export templates -> $TPL_DIR"
mkdir -p "$TPL_DIR"
ln -sf "$PREFIX/root/usr/bin/godot-template-release" "$TPL_DIR/linux_release.x86_64"
ln -sf "$PREFIX/root/usr/bin/godot-template-debug" "$TPL_DIR/linux_debug.x86_64"
echo "4.4.1.stable" > "$TPL_DIR/version.txt"

missing=$(LD_LIBRARY_PATH=$PREFIX/lib ldd "$PREFIX/root/usr/bin/godot" | grep 'not found' || true)
[ -z "$missing" ] || { echo "missing libs:"; echo "$missing"; exit 1; }
echo "OK: $(godot --version)"
