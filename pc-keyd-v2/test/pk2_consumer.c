/* pk2_consumer.c — pc-keyd v2 协议验证：假 consumer。
 * 连接私有 display_daemon，发 CONSUMER_HELLO（带 5 个 socketpair 端），
 * 然后从 data fd 的本端读 InputEvent 帧并打印。验证注入器字节格式。
 * 用法: pk2_consumer <sock> [秒数] */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdint.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include "anland-src/common/protocol.h"
#include "anland-src/common/socket_utils.h"

int main(int argc, char **argv)
{
    const char *sock = argv[1];
    int secs = argc > 2 ? atoi(argv[2]) : 10;

    /* 5 对 socketpair，本端自读，对端递交 daemon（槽序: buf_ready,fence,data,shm,audio） */
    int mine[5], theirs[5];
    for (int i = 0; i < 5; i++) {
        int sv[2];
        if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0) { perror("socketpair"); return 1; }
        mine[i] = sv[0]; theirs[i] = sv[1];
    }

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, sock, sizeof(addr.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { perror("connect"); return 1; }

    struct ctrl_msg hello = { .type = CTRL_MSG_CONSUMER_HELLO, .size = 0 };
    if (send_fds(fd, &hello, sizeof(hello), theirs, 5) < 0) { perror("send hello"); return 1; }
    fprintf(stderr, "consumer: hello sent\n");

    /* data 通道 = 槽 2（buf_ready, fence, data, shm, audio） */
    int data_fd = mine[2];
    time_t start = time(NULL);
    while (time(NULL) - start < secs) {
        struct data_msg hdr;
        ssize_t n = recv(data_fd, &hdr, sizeof(hdr), MSG_DONTWAIT);
        if (n == 0) { fprintf(stderr, "consumer: data fd closed\n"); break; }
        if (n < 0) { if (errno == EAGAIN || errno == EWOULDBLOCK) { sleep(1); continue; } perror("recv"); break; }
        if (n < (ssize_t)sizeof(hdr)) continue;
        uint8_t payload[4096];
        if (hdr.size > sizeof(payload)) continue;
        ssize_t got = 0;
        while (got < (ssize_t)hdr.size) {
            ssize_t r = recv(data_fd, payload + got, hdr.size - got, MSG_DONTWAIT);
            if (r <= 0) break;
            got += r;
        }
        if (got != (ssize_t)hdr.size) continue;
        if (hdr.type == DATA_MSG_INPUT_EVENT && hdr.size >= 12) {
            uint32_t type; int32_t action, keycode;
            memcpy(&type, payload, 4);
            memcpy(&action, payload + 4, 4);
            memcpy(&keycode, payload + 8, 4);
            if (type == INPUT_TYPE_KEY)
                printf("KEY %s keycode=%d\n", action == 0 ? "DOWN" : "UP", keycode);
            else
                printf("INPUT type=%u size=%u\n", type, hdr.size);
            fflush(stdout);
        }
    }
    fprintf(stderr, "consumer: done\n");
    return 0;
}
