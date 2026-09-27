#!/usr/bin/env python3
"""pc-keyd v2 — 组合键注入守护（XTEST/EIS 主通道 + uinput 按需兜底）。

v2（09-27）：DRM 轮内 uinput 设备进不了 kwin 的 logind 设备交接层（工作总结 §40/§41），
而 Xwayland 的 XTEST 按键经 kwin 内置 EIS 插件直进 compositor 输入管线、送达焦点窗口
（决策门实测：zenity 收到 xdotool 注入的 HELLO，含 shift 大写）。故主通道=XTEST，
**不再默认创建 uinput 设备**——安卓"物理键盘"通知与 uinput 防滥用红线一并消失。

HTTP API 与 v1 完全兼容（pc.qml 零改动）：
  GET /combo?key=<Qt::Key 整数>&mods=ctrl,alt,shift,meta
  GET /unstick   GET /ping
uinput 老路径仅在 XTEST 失败（无 X、anland 的 XTEST 失灵场景）时按请求懒创建兜底；
单一实例：48222 端口占用即退出。禁止 systemd 自启（uinput 防滥用，§5.20）。
"""
import os, subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

PORT = 48222
UINPUT_FD = None
EV_SYN, EV_KEY = 0, 1
UI_SET_EVBIT, UI_SET_KEYBIT, UI_DEV_CREATE = 0x40045564, 0x40045565, 0x5501

def _xdisplay():
    """DRM 轮的 Xwayland 显示号由 desk-takeover 写入 /run/pc-keyd-display，缺省 :0。"""
    try:
        with open("/run/pc-keyd-display") as f:
            d = f.read().strip()
            if d:
                return d
    except OSError:
        pass
    return ":0"

# ---- XTEST 主通道 -----------------------------------------------------------

# Qt::Key -> X keysym 名（xdotool 直接接受）
MODNAME = {"ctrl": "ctrl", "shift": "shift", "alt": "alt", "meta": "super"}
QTFUNC_KS = {
    0x01000000: "Escape", 0x01000001: "Tab", 0x01000002: "Tab", 0x01000003: "BackSpace",
    0x01000004: "Return", 0x01000005: "Return", 0x01000006: "Insert", 0x01000007: "Delete",
    0x01000010: "Home", 0x01000011: "End", 0x01000012: "Left", 0x01000013: "Up",
    0x01000014: "Right", 0x01000015: "Down", 0x01000016: "Prior", 0x01000017: "Next",
    0x01000055: "Menu",
}
for _i in range(12):
    QTFUNC_KS[0x01000030 + _i] = "F%d" % (_i + 1)

def qt_to_keysym(key):
    k = int(key)
    if k in QTFUNC_KS: return QTFUNC_KS[k]
    if 0x41 <= k <= 0x5A or 0x61 <= k <= 0x7A or 0x30 <= k <= 0x39: return chr(k).lower()
    table = {0x20: "space", 0x2D: "minus", 0x3D: "equal", 0x5B: "bracketleft",
             0x5D: "bracketright", 0x5C: "backslash", 0x3B: "semicolon", 0x27: "apostrophe",
             0x2C: "comma", 0x2E: "period", 0x2F: "slash", 0x60: "grave"}
    return table.get(k)

def xtest_combo(keysym, mods):
    seq = [MODNAME[m] for m in mods] + [keysym]
    env = dict(os.environ, DISPLAY=_xdisplay())
    subprocess.run(["xdotool", "key", "--", "+".join(seq)],
                   env=env, timeout=10, check=True)

def xtest_unstick():
    env = dict(os.environ, DISPLAY=_xdisplay())
    subprocess.run(["xdotool", "keyup", "ctrl", "alt", "shift", "meta"],
                   env=env, timeout=10, check=False)

# ---- uinput 兜底（v1 逻辑原样保留，懒初始化） --------------------------------

import fcntl, struct

def _uinput_fd():
    global UINPUT_FD
    if UINPUT_FD is None:
        UINPUT_FD = os.open("/dev/uinput", os.O_WRONLY)
        fcntl.ioctl(UINPUT_FD, UI_SET_EVBIT, EV_KEY)
        for code in range(0x2ff + 1):
            fcntl.ioctl(UINPUT_FD, UI_SET_KEYBIT, code)
        # 设备名沿用 v1；v2 主路径不再建设备，防滥用风暴风险随调用频率自然消失
        data = b"pc-keyd-kbd".ljust(80, b"\0") + \
            struct.pack("HHHHI", 0x11, 0x01, 0x01, 0x01, 0) + bytes(4 * 64 * 4)
        os.write(UINPUT_FD, data)
        fcntl.ioctl(UINPUT_FD, 0x5501)  # UI_DEV_CREATE
    return UINPUT_FD

MODMAP = {"ctrl": 29, "shift": 42, "alt": 56, "meta": 125}
QTFUNC_EV = {
    0x01000000: 1, 0x01000001: 15, 0x01000002: 15, 0x01000003: 14, 0x01000004: 28,
    0x01000005: 28, 0x01000006: 110, 0x01000007: 111, 0x01000010: 102, 0x01000011: 107,
    0x01000012: 105, 0x01000013: 103, 0x01000014: 106, 0x01000015: 108, 0x01000016: 104,
    0x01000017: 109, 0x01000055: 139,
}
for _i in range(10):
    QTFUNC_EV[0x01000030 + _i] = 59 + _i
QTFUNC_EV[0x0100003A] = 87
QTFUNC_EV[0x0100003B] = 88

def qt_to_evdev(key):
    k = int(key)
    if 0x41 <= k <= 0x5A: return k - 0x41 + 30
    if 0x61 <= k <= 0x7A: return k - 0x61 + 30
    if 0x30 <= k <= 0x39: return k - 0x30 + 2 if k > 0x30 else 11
    table = {0x20: 57, 0x2D: 12, 0x3D: 13, 0x5B: 26, 0x5D: 27, 0x5C: 43, 0x3B: 39,
             0x27: 40, 0x2C: 51, 0x2E: 52, 0x2F: 53, 0x60: 41, 0x09: 15, 0x0D: 28,
             0x1B: 1, 0x08: 14}
    return table.get(k)

def _ev(t, code, value):
    os.write(_uinput_fd(), struct.pack("llHHi", 0, 0, t, code, value))

def uinput_combo(key_int, mods):
    code = QTFUNC_EV.get(key_int) or qt_to_evdev(key_int)
    if code is None: return False
    try:
        for m in mods: _ev(EV_KEY, MODMAP[m], 1); _ev(EV_SYN, 0, 0)
        _ev(EV_KEY, code, 1); _ev(EV_SYN, 0, 0)
        _ev(EV_KEY, code, 0); _ev(EV_SYN, 0, 0)
    finally:
        for m in reversed(mods):
            try: _ev(EV_KEY, MODMAP[m], 0); _ev(EV_SYN, 0, 0)
            except OSError: pass
    return True

def uinput_unstick():
    try:
        for c in (29, 42, 56, 125, 100, 97, 105):
            _ev(EV_KEY, c, 0); _ev(EV_SYN, 0, 0)
    except OSError:
        pass

# ---- HTTP 服务（API 与 v1 兼容） ---------------------------------------------

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/unstick":
            try: xtest_unstick()
            except Exception: uinput_unstick()
            self.send_response(204); self.end_headers(); return
        if u.path == "/ping":
            self.send_response(204); self.end_headers(); return
        if u.path == "/combo":
            q = parse_qs(u.query)
            mods = [m for m in q.get("mods", [""])[0].split(",") if m in MODNAME]
            if "key" in q:
                key_int = int(q["key"][0])
                keysym = qt_to_keysym(key_int)
                sent = False
                if keysym:
                    try:
                        xtest_combo(keysym, mods)
                        sent = True
                    except Exception:
                        sent = False
                if not sent:  # XTEST 不可用（无 X / anland 失灵）→ uinput 兜底
                    uinput_combo(key_int, mods)
            self.send_response(204); self.end_headers(); return
        self.send_response(404); self.end_headers()

    def log_message(self, *a):  # 静默访问日志
        pass

if __name__ == "__main__":
    # v2 默认不碰 /dev/uinput：主通道 XTEST 不需要节点，通知与防滥用红线随之消失；
    # 兜底路径在首个失败请求时才懒创建。
    print("pc-keyd v2 up (xtest primary, uinput lazy fallback) on port %d" % PORT, flush=True)
    HTTPServer(("127.0.0.1", PORT), H).serve_forever()
