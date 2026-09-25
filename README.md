中文 | [English](README_english.md)

# droid-pc-keyboard

为 [plasma-keyboard](https://invent.kde.org/plasma/plasma-keyboard)（Plasma 6 /
Qt VirtualKeyboard 6.10）提供**全尺寸 PC 键盘布局 + 中文拼音 + 粘滞修饰键组合键**的增强项目。
诞生于 Linux-on-Android 容器环境（小米 Pad 8 Pro，Ubuntu rootfs + kwin_wayland），
但没有任何设备特定逻辑——任何 Plasma 6 桌面都能直接受益。

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

## 功能

- **全尺寸 PC 布局**（6 行：功能键区、数字区、导航区、方向键），主键盘 `PC` 键一键切换
  （`Qt.Key_F13` + 打过补丁的 `Keyboard.qml`）。
- **粘滞 Ctrl / Alt / Shift**：点一下保持按下（键面淡色底 + 底部黑条点亮），下一个键消费并复位。
  按 ⇧ 时键帽**实时换字**（`1`→`!`、`q`→`Q`）。
- **真实修饰键组合**：由 `pc-keyd` uinput 小守护注入 `Ctrl+C`、`Shift+Tab`、`Ctrl+←`、`Ctrl+1..9`
  这类组合（input-method-v1 的 `send_key` 协议根本不带 modifiers，Wayland 下 uinput 是唯一可靠通道）。
- **中文拼音输入**：Qt VirtualKeyboard 官方 Pinyin 插件（Ubuntu 构建把它砍掉了），自带 fcitx
  引擎与词库；外加 `latinOnly` 补丁，Chrome 地址栏等 URL/邮箱输入域不再杀中文。

## 安装

**deb（推荐）**：从 [GitHub Actions](../../actions/workflows/build-debs.yml) 最新产物
（或 Release）下载对应架构的一个全包：

```
sudo apt install ./droid-pc-keyboard_1.0.0_arm64.deb
```

一包内含：PC 布局、入口键/Breeze 补丁（postinst 应用、自动备份、卸载还原）、pc-keyd 守护，
以及重编译的 Qt VirtualKeyboard 6.10.2（pcMode/F13 + latinOnly 补丁）和 Pinyin 插件
（覆盖 Ubuntu 的 `libqt6virtualkeyboard6` / `qml6-module-qtquick-virtualkeyboard`，版本钉死 6.10.2）。

**源码方式**：`sudo ./install.sh`，再按输出提示完成两处源码构建，重启 plasma-keyboard。

### 与发行版 Qt 共存 / 回滚

本 deb 是**叠加包**（overlay）：用 `Provides` + `Replaces` 覆盖同名文件，**绝不使用 `Breaks`**
——早期版本带 Breaks 时 apt 会把整个 Plasma 桌面栈拆掉（真实事故）。如果曾被误删，一键恢复：

```
sudo apt install --reinstall plasma-desktop plasma-workspace plasma-keyboard \
    libqt6virtualkeyboard6 qml6-module-qtquick-virtualkeyboard qt6-virtualkeyboard-plugin
```

## 案例：为什么虚拟键盘"只在 Chrome 弹出"

在 Wayland 桌面上曾经出现过：Chrome 聚焦时键盘正常弹出，其他任何应用都不弹。两个互相独立的原因，都在合成器侧：

1. **Qt 应用整体绕开了合成器 text-input**。`/etc/environment` 里有全局
   `QT_IM_MODULE=fcitx5`，导致所有 Qt5/6 应用绑定 fcitx5-qt 桥而不是 kwin 的
   `zwp_input_method_v1`——plasma-keyboard 永远收不到"输入面板激活"事件，键盘没有弹出的理由；
   而 Chrome **不读** `QT_IM_MODULE`，原生走合成器 text-input，所以偏偏只有它有键盘。
   解法：全局环境保持干净，确实需要 fcitx 桥的场景（比如安卓 IME 转发会话）在**会话级**注入。
2. **kwin 6.6 的 IM 管理器只认它亲手拉起的输入方法**。kwinrc 里开
   `[org.kde.kwin.virtualkeyboard] VirtualKeyboardEnabled=true`（配合 `setInputMethodCommand`），
   让 kwin 在任何客户端获得焦点前自己 exec plasma-keyboard（干净环境：`env -u QT_IM_MODULE`）。

排查心法："键盘不弹"是**两侧握手**的问题——先看聚焦客户端实际走哪条 text-input 通道
（Qt 平台插件 / GTK IM / 原生 wl text-input），再看合成器对 IM 的准入限制，不要只翻键盘自己的配置。

## 要求

- Plasma 6 + `plasma-keyboard` 6.6.x + Qt VirtualKeyboard 6.10（补丁按版本钉死，换版本 rebase 很容易）
- `/dev/uinput` 可用（`CONFIG_INPUT_UINPUT`）
- `pc-keyd` 必须从 **shell 会话**启动，不要用 systemd 单元：部分安卓内核对 systemd 上下文进程注入的
  uinput 事件会静默丢弃；开机 crash-loop 还会触发内核对 uinput 键盘的防滥用拉黑（本启动会话内全部注入失效，
  需冷却或重启）。推荐：`nohup python3 /usr/local/bin/pc-keyd.py >/tmp/pc-keyd.log 2>&1 &`
- 容器里若没有 udevd 而需要手动补 `/dev/input/eventNN` 节点：`mknod` 的 mode 会被 umask 削掉，
  **必须显式 `chmod 0666`**，否则非 root 的合成器打开键盘直接 EACCES 且静默跳过。

## CI

`.github/workflows/build-debs.yml`：amd64 / arm64 双架构，ubuntu:26.04 容器直接 apt 装
Qt 6.10.2（不用 aqtinstall——Qt 6.10 改了架构命名且没有 arm64 桌面归档），克隆 `v6.10.2`
源码、打补丁、编译、与运行时资产合成单一 deb。打 `vX.Y.Z` tag 自动发布 GitHub Release。

本地构建：`QT_PREFIX=/usr ./packaging/build-deb.sh`。

## 仓库结构

| 路径 | 说明 |
|---|---|
| `layout/fallback/pc.qml` | PC 页（v8.4） |
| `pc-keyd.py` | uinput 组合键守护（HTTP API 127.0.0.1:48222） |
| `patches/plasma-keyboard-pc-entry-key.patch` | 主键盘加 `PC` 切换键（fallback + zh_CN） |
| `patches/qtvirtualkeyboard-6.10.2-pc-mode-and-latinonly.patch` | pcMode + F13 拦截 + latinOnly |
| `patches/breeze-keytext-functionkey-40px.patch` | 功能键标签统一 40px |
| `scripts/install-pinyin-plugin.sh` | 单独重建 Pinyin 插件的应急脚本 |
| `packaging/build-deb.sh` | 一体化 deb 构建（CI 同款） |
| `pc-keyd.service` | 仅供参考，**勿 enable**（见"要求"） |

许可证：MIT（`LICENSE` 为纯模板文本）；上游 LGPL/GPL 补丁文件的许可说明见 `NOTICE`。
