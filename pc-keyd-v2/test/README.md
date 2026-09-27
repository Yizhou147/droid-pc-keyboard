# pc-keyd v2 协议验证（2026-09-27，PASS）

离线三方验证（私有 display_daemon + pk2_consumer + pk2_injector）：
- 帧格式 `data_msg{type=102,size=12}` + `InputEvent{type=2(INPUT_TYPE_KEY), key{action,evdev码}}`
  经 daemon 的 fd 捎客（consumer hello 递 5 个 socketpair 端 → producer PICKUP_FDS 领取 →
  向 data 槽[2] 写帧）逐字节送达 consumer。
- 结果：KEY DOWN 30 / UP 30 / DOWN 46 / UP 46 全部收到（evdev A、L）。
- 结论：注入器字节格式与真 SystemIME 的 push_input_event 完全一致；
  anland 输入链（SystemIME→daemon→AnlandInputDevice）的 daily 工作即该路径的生产级证明。

结构（对真流程的镜像）：
- anland 运行态：kwin=consumer（读 socketpair 本端），Android SystemIME=producer（写对端），
  daemon 只捎 fd、从不转发数据帧。
- DRM 轮 v2：pc-keyd v2 充当 daemon（listen）+ 写入端；补丁版 kwin 作 consumer 连入并读取。
  待办：kwin input-only 补丁（ANLAND_INPUT_SOCKET 触发，不替换 DRM 输出后端）+ kwin 重编。

编译：`gcc -O1 -o pk2-daemon daemon_main.c anland-src/libdisplay_daemon/display_daemon.c anland-src/common/socket_utils.c -I.`（consumer/injector 同理；anland-src → Anland/anland 符号链接）。
注意：anland 运行态下不可活体注入——假 producer 会挤掉真 producer（显示断），只能离线或 DRM 轮内用。
