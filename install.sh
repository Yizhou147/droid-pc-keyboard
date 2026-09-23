#!/bin/bash
# droid-pc-keyboard installer (Debian/Ubuntu + Plasma 6 + plasma-keyboard 6.6.x)
# Applies: PC layout + entry-key patch + Breeze font patch + VKB source patch/build
#          + pinyin plugin + pc-keyd daemon.
# Run as: sudo ./install.sh            (VKB source build still needs your user
#          checkout: ./install.sh --build-vkb /path/to/qtvirtualkeyboard)
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }

STYLES=/usr/lib/$(uname -m | sed 's/arm64/aarch64/;s/x86_64/x86_64/')-linux-gnu/qt6/qml
[ -d "$STYLES" ] || STYLES=/usr/lib/qt6/qml
VKB_QML=$STYLES/QtQuick/VirtualKeyboard
BREEZE=$VKB_QML/Styles/Breeze/style.qml
PK_LAYOUTS=/usr/share/plasma/keyboard/layouts

bak() { [ -e "$1" ] && [ ! -e "$1.droidpk-bak" ] && cp -a "$1" "$1.droidpk-bak" || true; }

echo "== 1) PC layout file =="
install -D -m644 layout/fallback/pc.qml $PK_LAYOUTS/fallback/pc.qml

echo "== 2) plasma-keyboard entry-key patch (adds the 'PC' toggle key) =="
if grep -q "droid-pc-keyboard" $PK_LAYOUTS/fallback/main.qml 2>/dev/null; then
    echo "already applied, skip"
else
    patch -p1 --dry-run -d / -i patches/plasma-keyboard-pc-entry-key.patch &&
    patch -p1 -d / -i patches/plasma-keyboard-pc-entry-key.patch
fi

echo "== 3) Breeze style patch (functionKey labels -> 40px) =="
if grep -q "piano-patch" "$BREEZE" 2>/dev/null; then
    echo "already applied, skip"
else
    bak "$BREEZE"
    patch -p1 --dry-run -d "$(dirname "$BREEZE")" -i patches/breeze-keytext-functionkey-40px.patch &&
    patch -p1 -d "$(dirname "$BREEZE")" -i patches/breeze-keytext-functionkey-40px.patch
fi

echo "== 4) pc-keyd combo daemon (uinput) =="
install -m755 pc-keyd.py /usr/local/bin/pc-keyd.py
echo "start it from your session/takeover script (NO systemd unit; on Android"
echo "kernels systemd-context uinput injection can be silently dropped):"
echo "  nohup python3 /usr/local/bin/pc-keyd.py > /tmp/pc-keyd.log 2>&1 &"
echo "layout talks to it over http://127.0.0.1:48222/combo?key=<QtKey>&mods=..."
echo "NOTE: /dev/input nodes created by python obey umask -> pc-keyd.py chmods"
echo "0666 explicitly; keep that if you edit it."

echo "== 5) Chinese pinyin plugin =="
echo "run scripts/install-pinyin-plugin.sh (builds qtvirtualkeyboard v6.10.2"
echo "Pinyin plugin with bundled fcitx engine + dictionary)"

echo "== 6) qtvirtualkeyboard source patches =="
echo "apply patches/qtvirtualkeyboard-6.10.2-pc-mode-and-latinonly.patch to a"
echo "qt/qtvirtualkeyboard v6.10.2 checkout, then rebuild the components"
echo "plugin (Keyboard.qml is compiled into the QML module):"
echo "  git clone https://invent.kde.org/qt/qt/qtvirtualkeyboard -b v6.10.2"
echo "  git apply qtvirtualkeyboard-6.10.2-pc-mode-and-latinonly.patch"
echo "  cmake -B build -DCMAKE_INSTALL_PREFIX=/usr && cmake --build build && sudo cmake --install build"
echo "  IMPORTANT qmldir submodule import uses SPACE syntax:"
echo "    import QtQuick.VirtualKeyboard.Plugins.Pinyin auto"

echo "done. restart plasma-keyboard (or your session) to load."
