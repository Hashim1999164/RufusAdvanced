#include "cbootkit.h"
#include <errno.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

int cbk_authopen(const char *path, int oflags, const void *extauth, size_t extauth_len, char *err, size_t errlen) {
    int sv[2] = { -1, -1 }, in[2] = { -1, -1 };
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) {
        snprintf(err, errlen, "socketpair: %s", strerror(errno));
        return -1;
    }
    if (extauth != NULL && pipe(in) != 0) {
        snprintf(err, errlen, "pipe: %s", strerror(errno));
        close(sv[0]); close(sv[1]);
        return -1;
    }
    char flags[32];
    snprintf(flags, sizeof(flags), "%d", oflags);
    const char *argv[8];
    int a = 0;
    argv[a++] = "/usr/libexec/authopen";
    argv[a++] = "-stdoutpipe";
    if (extauth != NULL) argv[a++] = "-extauth";
    argv[a++] = "-o";
    argv[a++] = flags;
    argv[a++] = path;
    argv[a] = NULL;

    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, sv[1], STDOUT_FILENO);
    if (extauth != NULL) posix_spawn_file_actions_adddup2(&fa, in[0], STDIN_FILENO);
    posix_spawn_file_actions_addclose(&fa, sv[0]);
    if (extauth != NULL) posix_spawn_file_actions_addclose(&fa, in[1]);

    pid_t pid = 0;
    int rc = posix_spawn(&pid, argv[0], &fa, NULL, (char *const *)argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    close(sv[1]);
    if (extauth != NULL) close(in[0]);
    if (rc != 0) {
        snprintf(err, errlen, "cannot run authopen: %s", strerror(rc));
        close(sv[0]);
        if (extauth != NULL) close(in[1]);
        return -1;
    }
    if (extauth != NULL) {
        const char *p = (const char *)extauth;
        size_t left = extauth_len;
        while (left > 0) {
            ssize_t w = write(in[1], p, left);
            if (w < 0) { if (errno == EINTR) continue; break; }
            p += w; left -= (size_t)w;
        }
        close(in[1]);
    }

    int fd = -1;
    char byte = 0;
    struct iovec iov = { &byte, 1 };
    union { struct cmsghdr h; char buf[CMSG_SPACE(sizeof(int))]; } control;
    memset(&control, 0, sizeof(control));
    struct msghdr msg;
    memset(&msg, 0, sizeof(msg));
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = control.buf;
    msg.msg_controllen = sizeof(control.buf);
    ssize_t n;
    do { n = recvmsg(sv[0], &msg, 0); } while (n < 0 && errno == EINTR);
    if (n > 0) {
        for (struct cmsghdr *c = CMSG_FIRSTHDR(&msg); c != NULL; c = CMSG_NXTHDR(&msg, c)) {
            if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_RIGHTS) {
                memcpy(&fd, CMSG_DATA(c), sizeof(int));
                break;
            }
        }
    }
    close(sv[0]);
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    if (fd < 0) {
        int code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
        if (code == 0) code = EPERM;
        snprintf(err, errlen, "authopen could not open %s (%s)", path, code > 0 ? strerror(code) : "authorization failed or cancelled");
        return -1;
    }
    return fd;
}
