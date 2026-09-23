#!/bin/bash
# Build the patched qtvirtualkeyboard deb (droid-vkb-pc):
#   - pcMode + F13 intercept + latinOnly fix (patches/qtvirtualkeyboard-6.10.2-*.patch)
#   - Pinyin plugin with bundled fcitx engine (INPUT_lang_ch_CN=yes; Ubuntu's
#     build ships without it)
# Must run on a system with Qt 6.10.2 dev packages / aqt install (CI does aqt).
# Usage: QT_PREFIX=/path/to/Qt/6.10.2/gcc_64 ./build-vkb-deb.sh [outdir]
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."
REPO=$PWD
OUT=${1:-$REPO/dist}
QT_PREFIX=${QT_PREFIX:?set QT_PREFIX to a Qt 6.10.2 install (gcc_64 / linux_gcc_arm64)}
VKB_TAG=v6.10.2
VERSION=${VERSION:-6.10.2pc1}
ARCH=$(dpkg --print-architecture)
BUILD=${BUILD_DIR:-/tmp/vkb-build}

command -v cmake >/dev/null && command -v ninja >/dev/null || { echo "need cmake+ninja"; exit 1; }
[ -d "$BUILD/src" ] || git clone --depth 1 --branch "$VKB_TAG" https://code.qt.io/qt/qtvirtualkeyboard.git "$BUILD/src"
cd "$BUILD/src"
git apply "$REPO/patches/qtvirtualkeyboard-6.10.2-pc-mode-and-latinonly.patch" 2>/dev/null || \
    ( cd "$REPO" && git apply -p1 --unsafe-paths --directory "$BUILD/src" "$REPO/patches/qtvirtualkeyboard-6.10.2-pc-mode-and-latinonly.patch" )

cmake -S . -B build -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="$QT_PREFIX" \
    -DINPUT_lang_ch_CN=yes \
    -DFEATURE_handwriting=off
cmake --build build
DESTDIR=$BUILD/image cmake --install build

PKG=$OUT/droid-vkb-pc_$VERSION
rm -rf "$PKG"; mkdir -p "$PKG/DEBIAN"
cp -a "$BUILD/image"/. "$PKG/"
# layouts shipped by upstream build would clobber distro/plasma ones: drop them
rm -rf "$PKG"/usr/share/qt6/qml/QtQuick/VirtualKeyboard/Layouts 2>/dev/null || true
rm -rf "$PKG"/usr/lib/*/qt6/qml/QtQuick/VirtualKeyboard/Layouts 2>/dev/null || true

# qmldir: add Pinyin submodule import (SPACE syntax, not upstream's slash form)
QMD=$(find "$PKG" -path "*VirtualKeyboard/Plugins/qmldir" | head -1)
[ -n "$QMD" ] && grep -q "Pinyin" "$QMD" || [ -n "$QMD" ] && sed -i "/Hangul auto/a import QtQuick.VirtualKeyboard.Plugins.Pinyin auto" "$QMD"

cat > "$PKG/DEBIAN/control" <<EOF
Package: droid-vkb-pc
Version: $VERSION
Architecture: $ARCH
Maintainer: Yizhou <yizhou@example.invalid>
Depends: libc6
Replaces: libqt6virtualkeyboard6, qml6-module-qtquick-virtualkeyboard
Breaks: libqt6virtualkeyboard6, qml6-module-qtquick-virtualkeyboard
Description: Qt VirtualKeyboard 6.10.2 with PC-mode, latinOnly fix and Pinyin
 Rebuilt qtvirtualkeyboard carrying the droid-pc-keyboard patch set
 (pcMode layout switching via F13, ImhLatinOnly-only hint handling so CJK
 input survives URL/email fields) plus the official Pinyin plugin that
 Ubuntu's build omits. Version-pinned to Qt 6.10.2.
EOF

dpkg-deb -b --root-owner-group "$PKG" "$OUT" >/dev/null
echo "built: $OUT/droid-vkb-pc_${VERSION}_${ARCH}.deb"
