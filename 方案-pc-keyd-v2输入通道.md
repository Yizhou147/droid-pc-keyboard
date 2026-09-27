# 方案：pc-keyd v2 输入通道改造（彻底绕开 udev/logind）

> 2026-09-27 立项。背景与全部取证见主项目《工作总结》§39-41。
> 一句话：DRM 轮内 kwin 的输入设备经 logind fd 传递，轮内新建的 uinput 设备无法进入
> kwin（三层定因见 §40），因此组合键失效。本方案让组合键注入**不再依赖 uinput/udev/logind**
> 这条脆弱链路，从根上消灭问题——附带消灭安卓"物理键盘"通知与 uinput 防滥用红线。

## 0. 设计原则

1. **对外接口不变**：plasma-keyboard PC 页（pc.qml）→ HTTP `127.0.0.1:48222/combo?key=<QtKey>&mods=ctrl,alt,shift`
   完全保留，QML 侧零改动。
2. **后端可插拔**：pc-keyd v2 内部抽象 `Backend` 接口，通道可切换/回退；
   uinput 老路径保留为兜底（`PC_KEYD_BACKEND=uinput|auto`，默认 auto）。
3. **双模式通用**：同一守护在 anland（wayland-0）与 DRM 轮（taketest）下都能工作。
4. **红线继承**：绝不轮内杀 kwin；绝不在轮内做 uinput 反复建删（v2 目标是根本不再用 uinput）。

## 1. 注入通道候选与决策门（Phase 0）

### 通道 B（快速试探）：XTEST / Xwayland —— 优先级回升（EIS 机理破案）
- **09-26 音量实证的解释（kwin 源码找到）**：kwin 6.6 内置 `plugins/eis/`（libEI 服务端），
  专门为 Xwayland 开了一条仿真输入通道：kwin 起 Xwayland 时创建
  `$XDG_RUNTIME_DIR/kwin-xwayland-eis-socket.<pid>`（eiscontext.cpp:74-76，校验连接方 pid 必须是
  Xwayland），Xwayland 的 XTEST 按键经此直进 kwin 输入管线；EIS 设备就是标准
  `InputDevice`（eisdevice.cpp），按键送达**焦点所在窗口**（Wayland/X11 一视同仁）。
  ⇒ 09-26 xdotool 动音量不是孤例，是 stock kwin 6.6 的正式机制。
- **anland 内 XTEST 失灵的原因待查**（12:03 zenity+音量双探针均无效）：anland 的 Xwayland 由
  补丁版 kwin 以 rootless 方式拉起（xwayland.patch），EIS 通道是否建立、或焦点归属差异，需在下
  一轮 DRM 里实测——DRM 轮才是目标场景。
- **决策门测试（下一轮 DRM，5 分钟，零风险）**：
  1. 轮内开 Wayland konsole，聚焦；
  2. `DISPLAY=:0 xdotool key a`（观察字符是否落入 konsole）；
  3. 判据：字符出现 = 通道 B 可用（XTEST→EIS→kwin→焦点窗口全通，进 Phase 1-B）；
     不出现 = EIS 通道在轮内也不通 → 转通道 C。
- **实现成本**：pc-keyd v2 的 Backend 直接调 Xlib XTEST（或 shell 出 xdotool），半天工作量。

### 通道 C（治本主力）：anland 虚拟输入协议（kwin 补丁 input-only 化）
- **原理**：anland 补丁版 kwin 内的 `AnlandInputDevice`（producers/kde/anland_backend_v5/src/
  anland_input.cpp:126 `Q_EMIT keyChanged(...)`）证明 kwin 内部虚拟输入设备可以完全绕过
  libinput/uinput/logind。anland 补丁把它绑在 `AnlandBackend`（输出后端）上，DRM 轮不能用；
  本方案把它**拆成独立的 input-only 模块**。
- **协议链（全部有源码）**：
  - 线格式：`libdisplay_consumer/display_consumer.c:470 push_input_event()` ——
    `DATA_MSG_INPUT_EVENT` 帧 + `INPUT_TYPE_KEY`（按键）/`INPUT_TYPE_TEXT_INPUT`（文本）；
  - kwin 侧消费：`anland_backend.cpp:342 processInputEvent()` → `AnlandInputDevice::keyboardKey()`
    → kwin 内部按键；文本路径 `anland_backend.cpp:922 sendTextInputToKWin()` →
    `InputMethod::commitText`（kwin.patch 新增）；
  - 后端选择：`anland_backend.cpp:45,120` + kwin.patch:80-93（`--anland`/`ANLAND_SOCKET` 时启用）。
- **改造内容**：
  1. kwin.patch 扩展：新增环境开关（如 `ANLAND_INPUT_ONLY=1` + `ANLAND_INPUT_SOCKET=<path>`），
     在**不替换 DRM 输出后端**的前提下，单独创建 `AnlandInputDevice` 并连 socket 消费输入帧
     （从 anland_backend.cpp 摘出输入处理部分，独立成 `AnlandInputIntegration`）；
  2. Linux 侧小守护 `pc-keyd-anland`：监听新 unix socket（替代 display_daemon 的中继角色），
     接收 pc-keyd v2 的注入请求，按 display_consumer 协议帧格式发 `INPUT_TYPE_KEY`；
     或者更简：pc-keyd v2 直接说该协议，去掉中转层（协议细节以 display_consumer.c 为准）；
  3. 按键映射复用 pc-keyd 现有 Qt→evdev 表（SystemIME 的 sendKey 也是 evdev 码，协议对齐）。
- **成本**：kwin 重编一轮（rootfs 构建器已有 Debian13_v5 补丁管线可套）+ 守护改造 1-2 天。
- **风险**：kwin 版本升级要跟着维护补丁；DRM 轮内 `InputMethod::commitText` 与 plasma-keyboard
  的 text-input 是否冲突需在实现时确认（组合键只走 key 路径，理论无冲突）。
- **实现模板（源码已定位）**：EIS 插件就是范本——`eisdevice.cpp` 演示了不碰 Session/libinput、
  直接实现并注册一个 `InputDevice`（input()->addInputDevice，input.cpp:3280）的完整路径；
  input-only 补丁 = 照此结构做一个"unix socket 控制的虚拟键盘设备"（无 pid 校验、无 libei 依赖），
  比改造 AnlandBackend 更小更独立。

### 通道 A（已排除记录）：EI/libei、zwlr_virtual_keyboard
- 本机 kwin 6.6.6 全库 strings 零命中 `zwlr_virtual_keyboard`/`zwp_virtual_keyboard`——
  无该服务端实现；EI 需要经 xdg-desktop-portal RemoteDesktop（轮内 portal 日志有 NoReply 报错，
  依赖链脆弱）。仅作记录，不走。

### 决策顺序
```
Phase 0（离线）: apt source kwin 读 Session/libinput 过滤器（顺带回答 §40 第二层，为 §41 收尾）
Phase 1（下一轮 DRM，被动）: 通道 B 决策门测试（xdotool 5 分钟）
   ├─ B 可达 Wayland 焦点应用 → Phase 1-B（pc-keyd v2 = XTEST 后端，1 天）
   └─ 不可达 → Phase 1-C（kwin 补丁 input-only 化 + 协议守护，2-3 天）
Phase 2: 接线（takeover 启动顺序、anland 侧恢复拉起、uinput 路径降级为 fallback）
Phase 3: 双模式回归 + 通知消失验证 + 发版
```

## 2. Phase 2 接线细节（两通道通用）

1. **启动顺序**：pc-keyd v2（通道 C 版）需要 kwin 先起来（要连它的 socket/wayland）——
   desk-takeover 中移到 DESKTOP-UP 之后、验证段之前；启动自带重试等待（wayland socket 就绪）。
   现有 PK-READY 段在 uinput fallback 保留时保留，纯 v2 时移除。
2. **anland 侧**：startanland-kde.sh 恢复 pc-keyd 拉起（v2 在 anland 的 wayland-0 上同样工作）
   → anland 的 PC 页组合键同步复活；安卓通知永久消失（不再有 uinput 设备）。
3. **desk-stop/desk-takeover 清理点**：清理对象改为 pc-keyd v2 进程名（沿用 pc-keyd.py 命名族）。
4. **uinput 兜底**：`PC_KEYD_BACKEND=uinput` 显式指定时才走老路径；/dev/uinput mknod 保留
   （兜底用），99-drm-input-seat.rules 不动（触摸/蓝牙 HID 仍需要）。

## 3. 验收清单（Phase 3）

- [ ] DRM 轮内：PC 页 Ctrl+C / Ctrl+Alt+T / Shift+字母 三类组合进 Wayland konsole 生效
- [ ] DRM 轮内：`PK-READY` 不再是组合键的必要条件（v2 不依赖 udev）
- [ ] 返回安卓后：无"pc-keyd-kbd"物理键盘通知（/dev/uinput 无设备）
- [ ] anland 内：PC 页组合键恢复可用（v2 接 wayland-0）
- [ ] 双模式回归：desk-takeover/desk-stop 全绿 ×2 轮，anland 会话正常
- [ ] droid-pc-keyboard 发版（deb 版本号 +1，Release 说明注明通道变更）

## 4. 红线与回退

- 全程禁止轮内杀 kwin（§40 红线）；所有验证走"下一轮自然进入"。
- v2 上线后保留 v1 uinput 代码路径至少一个版本，出问题可 `PC_KEYD_BACKEND=uinput` 一键回退。
- 若通道 C 的 kwin 补丁在验证中引发显示异常，先回退补丁（rootfs 构建器有锁定版本机制），
  回到通道 B/XTEST 兜底方案再评估。
