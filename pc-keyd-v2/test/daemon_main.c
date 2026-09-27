#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include "anland-src/libdisplay_daemon/display_daemon.h"
static daemon_ctx *g;
int main(int argc, char **argv) {
    const char *sock = argc > 1 ? argv[1] : "/tmp/pk2-test.sock";
    if (daemon_create(&g, sock) < 0) return 1;
    daemon_run(g);
    daemon_destroy(g);
    return 0;
}
