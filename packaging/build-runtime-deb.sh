#!/bin/bash
# Build the architecture-independent runtime deb:
#   droid-pc-keyboard  (PC layout, entry-key & Breeze patches, pc-keyd daemon)
# Usage: ./build-runtime-deb.sh [output-dir]
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."
REPO=$PWD
OUT=${1:-$REPO/dist}
VERSION=${VERSION:-1.0.0}
PKG=$OUT/droid-pc-keyboard_$VERSION
ARCH=amd64   # data-only package; keep matching the target dpkg

rm -rf "$PKG"; mkdir -p "$PKG/DEBIAN" "$PKG/usr/share/droid-pc-keyboard" "$PKG/usr/local/bin"

cp -r layout patches scripts "$PKG/usr/share/droid-pc-keyboard/"
install -m755 pc-keyd.py "$PKG/usr/local/bin/pc-keyd.py"

cat > "$PKG/DEBIAN/control" <<EOF
Package: droid-pc-keyboard
Version: $VERSION
Architecture: all
Maintainer: Yizhou <yizhou@example.invalid>
Depends: patch
Description: Full-size PC layout, pinyin and uinput combo keys for plasma-keyboard
 Adds a 6-row PC keyboard page (F-row, number row, nav cluster, arrows) with
 sticky Ctrl/Alt/Shift and real modifier chords injected through a tiny uinput
 daemon (pc-keyd). Ships version-pinned patches for plasma-keyboard layouts,
 the Breeze style and Qt VirtualKeyboard 6.10.2. The PC page switch requires
 the patched qtvirtualkeyboard build (droid-vkb-pc deb); everything else
 degrades gracefully without it.
EOF

cat > "$PKG/DEBIAN/postinst" <<'EOF'
#!/bin/bash
set -u
D=/usr/share/droid-pc-keyboard
LK=/usr/share/plasma/keyboard/layouts
STYLES_DIR=$(ls -d /usr/lib/*/qt6/qml/QtQuick/VirtualKeyboard/Styles/Breeze 2>/dev/null | head -1)

# 1) PC page layout file
install -D -m644 $D/layout/fallback/pc.qml $LK/fallback/pc.qml

# 2) entry-key + breeze patches (idempotent, marker-guarded, backed up once)
if ! grep -q droid-pc-keyboard $LK/fallback/main.qml 2>/dev/null; then
    [ -e $LK/fallback/main.qml ] && cp -a $LK/fallback/main.qml $LK/fallback/main.qml.droidpk-bak
    [ -e $LK/zh_CN/main.qml ] && cp -a $LK/zh_CN/main.qml $LK/zh_CN/main.qml.droidpk-bak
    patch -p3 -d / -i $D/patches/plasma-keyboard-pc-entry-key.patch || \
        echo "WARN: entry-key patch did not apply cleanly (plasma-keyboard version drift?); check manually"
fi
if [ -n "${STYLES_DIR:-}" ] && ! grep -q piano-patch "$STYLES_DIR/style.qml" 2>/dev/null; then
    cp -a "$STYLES_DIR/style.qml" "$STYLES_DIR/style.qml.droidpk-bak"
    patch -p1 -d "$STYLES_DIR" -i $D/patches/breeze-keytext-functionkey-40px.patch || \
        echo "WARN: breeze patch did not apply cleanly (style version drift?)"
fi

# 3) pc-keyd: NOT autostarted. Start it from your session launcher, e.g.
#    nohup python3 /usr/local/bin/pc-keyd.py >/tmp/pc-keyd.log 2>&1 &
# systemd units are deliberately avoided: some Android kernels drop uinput
# events injected from systemd-context processes.
echo "droid-pc-keyboard installed. Restart plasma-keyboard to load the PC page."
echo "Remember to start pc-keyd from your session (see README) and, for the"
echo "PC toggle + pinyin, install the matching droid-vkb-pc deb."
EOF

cat > "$PKG/DEBIAN/prerm" <<'EOF'
#!/bin/bash
set -u
LK=/usr/share/plasma/keyboard/layouts
for f in $LK/fallback/main.qml $LK/zh_CN/main.qml; do
    [ -e "$f.droidpk-bak" ] && mv -f "$f.droidpk-bak" "$f"
done
STYLES_DIR=$(ls -d /usr/lib/*/qt6/qml/QtQuick/VirtualKeyboard/Styles/Breeze 2>/dev/null | head -1)
[ -n "${STYLES_DIR:-}" ] && [ -e "$STYLES_DIR/style.qml.droidpk-bak" ] && mv -f "$STYLES_DIR/style.qml.droidpk-bak" "$STYLES_DIR/style.qml"
rm -f $LK/fallback/pc.qml
EOF

chmod 755 "$PKG/DEBIAN/postinst" "$PKG/DEBIAN/prerm"
dpkg-deb -b --root-owner-group -z2 "$PKG" "$OUT" >/dev/null
echo "built: $OUT/droid-pc-keyboard_${VERSION}_all.deb"
