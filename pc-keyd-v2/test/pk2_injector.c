/* pk2_injector.c — pc-keyd v2 协议验证：假 producer（注入器）。
 * 连接私有 display_daemon，发 PRODUCER_HELLO + PICKUP_FDS 领取 consumer 递交的
 * fd 集，向 data fd（槽 2）写 INPUT_TYPE_KEY 帧。与真 SystemIME 的
 * push_input_event 帧格式逐字节一致（data_msg{102,12} + InputEvent{2,{action,keycode}}）。
 * 用法: pk2_injector <sock> <evdev码> [更多码...] */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdint.h>
#include <sys/socket.h>
#include <sys/un.h>
#include "anland-src/common/protocol.h"
#include "anland-src/common/socket_utils.h"

static int send_data_frame(int data_fd, uint32_t type, const void *payload, uint32_t size)
{
    struct data_msg hdr = { .type = type, .size = size };
    if (send_all(data_fd, &hdr, sizeof(hdr)) < 0) return -1;
    if (size && send_all(data_fd, payload, size) < 0) return -1;
    return 0;
}

static int send_key(int data_fd, int32_t keycode, int32_t action)
{
    struct InputEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = INPUT_TYPE_KEY;
    ev.key.action = action;
    ev.key.keycode = keycode;
    return send_data_frame(data_fd, DATA_MSG_INPUT_EVENT, &ev, sizeof(ev));
}

int main(int argc, char **argv)
{
    const char *sock = argv[1];
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, sock, sizeof(addr.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { perror("connect"); return 1; }

    struct ctrl_msg hello = { .type = CTRL_MSG_PRODUCER_HELLO, .size = 0 };
    if (send_all(fd, &hello, sizeof(hello)) < 0) { perror("hello"); return 1; }
    fprintf(stderr, "injector: producer hello sent\n");

    /* 请求领取 consumer 递交的 fd 集 */
    struct ctrl_msg pickup = { .type = CTRL_MSG_PICKUP_FDS, .size = 0 };
    if (send_all(fd, &pickup, sizeof(pickup)) < 0) { perror("pickup"); return 1; }

    /* 收 daemon 转来的 fds（ consumer 的 5 个端：buf_ready,fence,data,shm,audio ） */
    int got_fds[5], fd_count = 0;
    struct ctrl_msg reply;
    if (recv_fds(fd, &reply, sizeof(reply), got_fds, 5, &fd_count) < (ssize_t)sizeof(reply)) {
        perror("recv fds"); return 1;
    }
    fprintf(stderr, "injector: got %d fds (ctrl type=%u)\n", fd_count, reply.type);
    if (fd_count < 3) { fprintf(stderr, "injector: unexpected fd count\n"); return 1; }
    int data_fd = got_fds[2]; /* 槽 2 = data */

    for (int i = 2; i < argc; i++) {
        int code = atoi(argv[i]);
        if (send_key(data_fd, code, INPUT_ACTION_DOWN) < 0) { perror("down"); return 1; }
        usleep(30000);
        if (send_key(data_fd, code, INPUT_ACTION_UP) < 0) { perror("up"); return 1; }
        printf("injected key %d\n", code);
        fflush(stdout);
    }
    sleep(1);
    return 0;
}
