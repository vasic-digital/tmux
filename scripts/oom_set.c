/*
 * oom_set — minimal helper to set /proc/<pid>/oom_score_adj to a specific
 * value. Designed to be granted CAP_SYS_RESOURCE via `setcap`, allowing the
 * non-root tmx wrapper to invoke it for OOM-score protection
 * without itself being setuid root.
 *
 * Build:
 *   bash scripts/build_oom_set.sh
 *
 * Permissions installed by build_oom_set.sh:
 *   sudo setcap cap_sys_resource+ep /usr/local/bin/tmx-oom-set
 *
 * Usage (called by tmx wrapper):
 *   tmx-oom-set <pid> <score>
 *   exit 0 = success, 1 = bad args, 2 = open failed, 3 = write failed
 *
 * Safety constraints (audit-friendly):
 *   1. Only writes to /proc/<numeric-pid>/oom_score_adj (no path traversal
 *      possible; the path is constructed from snprintf with %ld + atoll).
 *   2. Score is clamped to the kernel's accepted range [-1000, 1000];
 *      values outside that range are rejected with exit 1.
 *   3. Does NOT execvp / fork / system / open arbitrary files. Only the
 *      single oom_score_adj path. Capability privileges are released as
 *      soon as the write completes.
 *   4. PID must be a positive integer; PID 0 (whole-system scope) is
 *      explicitly rejected to prevent accidentally setting kernel oom
 *      score adj.
 *
 * License: same as ATMOSphere project (open AOSP fork, see parent LICENSE).
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s <pid> <oom_score_adj>\n", argv[0]);
        return 1;
    }

    char *endptr = NULL;
    long pid = strtol(argv[1], &endptr, 10);
    if (*argv[1] == '\0' || *endptr != '\0' || pid <= 0) {
        fprintf(stderr, "%s: invalid pid '%s' (must be positive integer)\n", argv[0], argv[1]);
        return 1;
    }

    long score = strtol(argv[2], &endptr, 10);
    if (*argv[2] == '\0' || *endptr != '\0' || score < -1000 || score > 1000) {
        fprintf(stderr, "%s: invalid score '%s' (must be in [-1000, 1000])\n", argv[0], argv[2]);
        return 1;
    }

    char path[64];
    int n = snprintf(path, sizeof(path), "/proc/%ld/oom_score_adj", pid);
    if (n <= 0 || (size_t)n >= sizeof(path)) {
        fprintf(stderr, "%s: path build failed\n", argv[0]);
        return 2;
    }

    FILE *f = fopen(path, "w");
    if (!f) {
        fprintf(stderr, "%s: cannot open %s: %s\n", argv[0], path, strerror(errno));
        return 2;
    }

    if (fprintf(f, "%ld\n", score) < 0) {
        fprintf(stderr, "%s: write failed: %s\n", argv[0], strerror(errno));
        fclose(f);
        return 3;
    }

    if (fclose(f) != 0) {
        fprintf(stderr, "%s: close failed: %s\n", argv[0], strerror(errno));
        return 3;
    }

    return 0;
}
