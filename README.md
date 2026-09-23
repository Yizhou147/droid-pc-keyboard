# droid-pc-keyboard

A full-size **PC layout + Chinese pinyin + sticky-modifier combo keys**
upgrade for [plasma-keyboard](https://invent.kde.org/plasma/plasma-keyboard)
(Plasma 6 / Qt VirtualKeyboard 6.10), built and tested on Linux-in-Android
containers (Xiaomi Pad 8 Pro, Ubuntu rootfs + kwin_wayland), but nothing in
here is device-specific — any Plasma 6 desktop benefits.

```
┌───────────────────────────────────────┐
│ Esc F1 … F12                          │
│ ` 1! 2@ 3# … -_ =+  ⌫  Ins Del        │
│ Tab  Q W E R T Y U I O P  [] \  Home  │
│ Shift A S D F G H J K L  ;' Enter     │
│ Ctrl  Z X C V B N M  ,. /        ↑    │
│ Alt   PC   ␣␣␣␣␣␣␣␣  Menu   ← ↓ →     │
└───────────────────────────────────────┘
```

## What you get

- **Full-size PC layout** (6 rows: function keys, number row, nav cluster,
  arrows), toggled by a `PC` key on the normal keyboard (delivered as
  `Qt.Key_F13` + a patched `Keyboard.qml`).
- **Sticky Ctrl / Alt / Shift** — tap a modifier, it stays lit (dim wash +
  black underline), the next key consumes it. Keycaps live-update under
  Shift (`1`→`!`, `q`→`Q`).
- **Real modifier combos** via `pc-keyd`, a tiny uinput daemon:
  `Ctrl+C`, `Ctrl+Alt+Del`-style chords, `Shift+Tab`, `Ctrl+←` word-nav,
  `Ctrl+1..9` tab switching… (input-method-v1 `send_key` carries *no*
  modifiers — uinput is the only reliable path on Wayland.)
- **Chinese pinyin input** — Qt VirtualKeyboard's official Pinyin plugin
  (Ubuntu builds ship without it), self-contained fcitx engine + dictionary,
  plus a `latinOnly` patch so URL/email fields no longer kill CJK input
  in apps like Chrome.

## Install

**From a .deb (recommended):** grab the latest artifact from [GitHub Actions](../../actions/workflows/build-debs.yml)
(or a tagged release) — one all-in-one deb per architecture:

```
sudo apt install ./droid-pc-keyboard_1.0.0_arm64.deb
```

Contains: PC layout + entry-key/Breeze patches (applied in `postinst`,
backups kept, restored on removal), the `pc-keyd` combo daemon, and a
rebuilt Qt VirtualKeyboard 6.10.2 with the pcMode/F13 + latinOnly patches
and the Pinyin plugin (replaces Ubuntu's `libqt6virtualkeyboard6` /
`qml6-module-qtquick-virtualkeyboard`; version-pinned to Qt 6.10.2).

**From source:**

```
sudo ./install.sh
```

then follow the printed steps for the two source builds
(qtvirtualkeyboard patch + pinyin plugin). Restart plasma-keyboard.

## CI

`.github/workflows/build-debs.yml` builds, per arch (amd64 / arm64), one
`droid-pc-keyboard_<ver>_<arch>.deb` artifact — Qt 6.10.2 fetched via
aqtinstall, VKB cloned at `v6.10.2`, patched, built, merged with the
runtime assets. Tags `vX.Y.Z` publish a GitHub release with all debs.

Local build: `QT_PREFIX=$HOME/Qt/6.10.2/gcc_64 ./packaging/build-deb.sh`.



## Requirements

- Plasma 6 with `plasma-keyboard` 6.6.x and Qt VirtualKeyboard 6.10
  (patches are version-pinned; rebase trivially otherwise)
- `/dev/uinput` available (`CONFIG_INPUT_UINPUT`)
- `pc-keyd` must be started from a **shell session**, not a systemd unit:
  some Android kernels silently drop uinput events injected from
  systemd-context processes, and boot-time restart loops trip anti-spoof
  rate limiters. `nohup python3 /usr/local/bin/pc-keyd.py &` from your
  session launcher is the proven pattern.
- If you create the evdev node for the virtual keyboard yourself (no udevd),
  `chmod 0666` it explicitly — `mknod`/`os.mknod` modes are masked by umask
  and non-root compositors will fail to open the device *silently*.

## Layout of this repo

| path | what |
|---|---|
| `layout/fallback/pc.qml` | the PC page (v8.4) |
| `pc-keyd.py` | uinput combo daemon (HTTP API on 127.0.0.1:48222) |
| `patches/plasma-keyboard-pc-entry-key.patch` | adds the `PC` toggle key (fallback + zh_CN) |
| `patches/qtvirtualkeyboard-6.10.2-pc-mode-and-latinonly.patch` | `pcMode` + F13 intercept + latinOnly fix |
| `patches/breeze-keytext-functionkey-40px.patch` | uniform 40px function-key labels |
| `scripts/install-pinyin-plugin.sh` | build & install the Pinyin VKB plugin |
| `pc-keyd.service` | systemd unit kept for reference only — do **not** enable (see Requirements) |

License: MIT (see `LICENSE` for notes on the upstream-licensed patch files).
