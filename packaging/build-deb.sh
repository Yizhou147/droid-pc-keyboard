#!/bin/bash
# Build the all-in-one deb: runtime assets (PC layout, entry-key/Breeze
# patches, pc-keyd) + patched qtvirtualkeyboard 6.10.2 (pcMode/F13,
# latinOnly fix) + Pinyin plugin. One deb per architecture, install & done.
#
# Usage: QT_PREFIX=$HOME/Qt/6.10.2/gcc_64 ./build-deb.sh [outdir]
#   QT_PREFIX   Qt 6.10.2 install (aqt or system) — required
#   BUILD_DIR   reusable clone/build dir        (default /tmp/vkb-build)
#   VERSION     package version                 (default 1.1.2)
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."
REPO=$PWD
OUT=${1:-$REPO/dist}
QT_PREFIX=${QT_PREFIX:?QT_PREFIX must point to a Qt 6.10.2 install}
VKB_TAG=v6.10.2
VERSION=${VERSION:-1.1.2}
ARCH=$(dpkg --print-architecture)
BUILD=${BUILD_DIR:-/tmp/vkb-build}

command -v cmake >/dev/null && command -v ninja >/dev/null || { echo "need cmake+ninja"; exit 1; }

echo "== building patched qtvirtualkeyboard ($VKB_TAG) =="
[ -d "$BUILD/src/.git" ] || git clone --depth 1 --branch "$VKB_TAG" https://code.qt.io/qt/qtvirtualkeyboard.git "$BUILD/src"
git -C "$BUILD/src" checkout -- . 2>/dev/null || true
git -C "$BUILD/src" apply "$REPO/patches/qtvirtualkeyboard-6.10.2-pc-mode-and-latinonly.patch" || \
    echo "note: patch may already be applied"

cmake -S "$BUILD/src" -B "$BUILD/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="$QT_PREFIX" \
    -DINPUT_lang_ch_CN=yes \
    -DFEATURE_handwriting=off
cmake --build "$BUILD/build"
rm -rf "$BUILD/image"
DESTDIR="$BUILD/image" cmake --install "$BUILD/build"

echo "== assembling deb =="
PKG=$OUT/droid-pc-keyboard_$VERSION
rm -rf "$PKG"; mkdir -p "$PKG/DEBIAN" "$PKG/usr/share/droid-pc-keyboard" "$PKG/usr/local/bin"

# runtime assets
cp -r layout patches scripts "$PKG/usr/share/droid-pc-keyboard/"
install -m755 pc-keyd.py "$PKG/usr/local/bin/pc-keyd.py"
[ -f "$REPO/README.md" ] && cp "$REPO/README.md" "$PKG/usr/share/droid-pc-keyboard/"

# overlay the built VKB (mirrors distro paths: usr/lib/<triple>/qt6/qml/...
# and libQt6VirtualKeyboard.so*)
cp -a "$BUILD/image"/. "$PKG/"
# runtime-only: strip dev files the distro keeps in separate -dev packages
rm -rf "$PKG"/usr/include
find "$PKG" -type d \( -name cmake -o -name mkspecs -o -name pkgconfig -o -name examples \) -prune -exec rm -rf {} + 2>/dev/null || true
find "$PKG" -name "*.prl" -delete 2>/dev/null || true
# never ship Layouts from upstream build (would clobber plasma-keyboard's)
find "$PKG" -type d -name Layouts -path "*VirtualKeyboard*" -exec rm -rf {} + 2>/dev/null || true

# qmldir: append the Pinyin submodule import (SPACE syntax, not upstream slash form)
QMD=$(find "$PKG" -path "*VirtualKeyboard/Plugins/qmldir" | head -1)
if [ -n "$QMD" ] && ! grep -q "Plugins.Pinyin" "$QMD"; then
    if grep -q "Hangul auto" "$QMD"; then
        sed -i "/Hangul auto/a import QtQuick.VirtualKeyboard.Plugins.Pinyin auto" "$QMD"
    else
        printf 'import QtQuick.VirtualKeyboard.Plugins.Pinyin auto\n' >> "$QMD"
    fi
fi

cat > "$PKG/DEBIAN/control" <<EOF
Package: droid-pc-keyboard
Version: $VERSION
Architecture: $ARCH
Maintainer: Yizhou <yizhou@example.invalid>
Depends: patch, python3, plasma-keyboard
Provides: libqt6virtualkeyboard6, qml6-module-qtquick-virtualkeyboard, qt6-virtualkeyboard-plugin
Replaces: libqt6virtualkeyboard6, qml6-module-qtquick-virtualkeyboard, qt6-virtualkeyboard-plugin
Description: Full-size PC layout, pinyin, combo keys and fcitx5 toggle for plasma-keyboard
 All-in-one: 6-row PC keyboard page with sticky Ctrl/Alt/Shift and real
 modifier chords via the pc-keyd v2 daemon (channel C/XTEST, uinput lazy
 fallback; Ctrl+Space toggles fcitx5 via DBus directly), Chinese pinyin (Qt VKB
 Pinyin plugin with bundled fcitx engine), and a rebuilt Qt VirtualKeyboard
 6.10.2 carrying the pcMode/F13 and latinOnly patches. Layout/Breeze patches
 are applied in postinst (backups kept, restored on purge). VKB parts are
 pinned to Qt 6.10.2.
EOF

cat > "$PKG/DEBIAN/postinst" <<'EOF'
#!/bin/bash
set -u
D=/usr/share/droid-pc-keyboard
LK=/usr/share/plasma/keyboard/layouts
STYLES_DIR=$(ls -d /usr/lib/*/qt6/qml/QtQuick/VirtualKeyboard/Styles/Breeze 2>/dev/null | head -1)

install -D -m644 $D/layout/fallback/pc.qml $LK/fallback/pc.qml

# VKB 用 locale 目录里的 **0 字节 `<name>.fallback` 标记**把布局名 "pc" 解析到 fallback/pc.qml
# （en_US/main.fallback 等同理，是 plasma-keyboard 自带的那种标记）。
# 缺了 pc.fallback ⇒ 按下 PC 键时 layout() 返回 "pc" 也加载不出布局 = **按键毫无反应**
# （10-02 测试容器实测：装了 deb 但没这两个标记，PC 页死活出不来）。
# 这是安装期必须做的事，install.sh 与 postinst 两处都要有。
for _loc in $LK/*/; do
    [ -d "$_loc" ] || continue
    [ -e "$_loc/main.fallback" ] || [ -e "$_loc/main.qml" ] || continue
    [ -e "$_loc/pc.fallback" ] || : > "$_loc/pc.fallback"
done

# ---- 打补丁：必须**永不提问**，否则 apt 的 postinst 会永久卡住 ----
# 10-02 实测：缺目标文件时 `patch` 会停在 `File to patch:` 等输入，而 dpkg 的 postinst
# 是非交互跑的 ⇒ 安装挂死、dpkg 进入半配置（之后任何 apt install 都被
# "dpkg was interrupted" 挡下，看起来像"deb 装不上"）。两条措施：
#   · `--batch`  —— 找不到文件/有冲突也绝不提问；
#   · `--forward` —— 已打过就跳过，不反问 "Reversed (or previously applied) patch detected?"；
#   · 守卫用"**目标文件存在 且 还没打过**"，文件不在就明确跳过并提示（不静默、也不阻塞）。
if [ -e "$LK/fallback/main.qml" ] && ! grep -q "Qt.Key_F13" "$LK/fallback/main.qml" 2>/dev/null; then
    cp -a "$LK/fallback/main.qml" "$LK/fallback/main.qml.droidpk-bak"
    [ -e "$LK/zh_CN/main.qml" ] && cp -a "$LK/zh_CN/main.qml" "$LK/zh_CN/main.qml.droidpk-bak"
    patch --batch --forward -p1 -d / -i $D/patches/plasma-keyboard-pc-entry-key.patch || \
        echo "WARN: entry-key patch 未能应用（plasma-keyboard 版本不符？）——已跳过，不影响安装"
elif [ ! -e "$LK/fallback/main.qml" ]; then
    echo "WARN: 找不到 $LK/fallback/main.qml（plasma-keyboard 似乎没装）⇒ 跳过 PC 入口键补丁；"
    echo "      装上 plasma-keyboard 后重装本 deb 即可补上（本 deb 的 Depends 已包含它）。"
fi
if [ -n "${STYLES_DIR:-}" ] && [ -e "$STYLES_DIR/style.qml" ] && ! grep -q piano-patch "$STYLES_DIR/style.qml" 2>/dev/null; then
    cp -a "$STYLES_DIR/style.qml" "$STYLES_DIR/style.qml.droidpk-bak"
    patch --batch --forward -p1 -d "$STYLES_DIR" -i $D/patches/breeze-keytext-functionkey-40px.patch || \
        echo "WARN: breeze patch 未能应用（样式版本不符？）——已跳过，不影响安装"
fi

# pc-keyd is NOT autostarted on purpose: some Android kernels drop uinput
# events injected from systemd-context processes. Start it from your session
# launcher:  nohup python3 /usr/local/bin/pc-keyd.py >/tmp/pc-keyd.log 2>&1 &
echo "droid-pc-keyboard installed: restart plasma-keyboard to load the PC page."
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
for _loc in $LK/*/; do
    rm -f "$_loc/pc.fallback"
done
EOF

chmod 755 "$PKG/DEBIAN/postinst" "$PKG/DEBIAN/prerm"
dpkg-deb -b --root-owner-group -z2 "$PKG" "$OUT" >/dev/null
echo "built: $OUT/droid-pc-keyboard_${VERSION}_${ARCH}.deb"
