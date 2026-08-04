#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static uint64_t now_ns(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        perror("clock_gettime");
        exit(2);
    }
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

int main(int argc, char** argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s MICROSECONDS\n", argv[0]);
        return 2;
    }
    char* end = NULL;
    errno = 0;
    unsigned long long us = strtoull(argv[1], &end, 10);
    if (errno != 0 || end == argv[1] || *end != '\0') {
        fprintf(stderr, "invalid microseconds: %s\n", argv[1]);
        return 2;
    }
    if (us == 0) return 0;

    const uint64_t target = now_ns() + us * 1000ull;
    if (us > 2000ull) {
        uint64_t coarse_us = us - 1000ull;
        struct timespec req = {
            .tv_sec = (time_t)(coarse_us / 1000000ull),
            .tv_nsec = (long)((coarse_us % 1000000ull) * 1000ull)
        };
        while (nanosleep(&req, &req) != 0 && errno == EINTR) { }
    }
    while (now_ns() < target) { }
    return 0;
}
