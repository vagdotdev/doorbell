#include <stdio.h>
#include <sys/stat.h>
#include <errno.h>
#include <string.h>

// Atomically exchange complete bundles on one volume. There is never a gap at
// /Applications/Doorbell.app, even if the installer is killed during replacement.
int main(int argc, char **argv) {
    if (argc != 3) {
        fputs("Usage: DoorbellSwap staged-bundle installed-bundle\n", stderr);
        return 64;
    }
    struct stat first, second;
    if (lstat(argv[1], &first) || lstat(argv[2], &second)
        || !S_ISDIR(first.st_mode) || !S_ISDIR(second.st_mode)) {
        fputs("Both bundles must be real directories.\n", stderr);
        return 65;
    }
    if (renamex_np(argv[1], argv[2], RENAME_SWAP) != 0) {
        fprintf(stderr, "Bundle exchange failed: %s\n", strerror(errno));
        return 74;
    }
    return 0;
}
