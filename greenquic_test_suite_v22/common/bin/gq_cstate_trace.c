#define _GNU_SOURCE
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define MAX_CPUS 4096
#define MAX_STATES 256
#define BUF_SIZE 65536

static volatile sig_atomic_t stop_requested = 0;
static void on_signal(int sig) { (void)sig; stop_requested = 1; }

typedef struct {
    int active;
    int state;
    uint64_t enter_ns;
    uint64_t entries;
    uint64_t wakeups;
    uint64_t total_idle_ns[MAX_STATES];
    uint64_t state_entries[MAX_STATES];
} cpu_state_t;

static char tracefs[256];
static char saved_clock[256] = "";
static char saved_cpumask[512] = "";
static char saved_event_enable[32] = "";
static char saved_tracing_on[32] = "";
static char saved_current_tracer[128] = "";
static cpu_state_t cpus[MAX_CPUS];
static int selected[MAX_CPUS];
static int selected_count = 0;
static FILE *csv = NULL;
static const char *summary_path = NULL;
static uint64_t first_ts_ns = 0;
static uint64_t last_ts_ns = 0;
static uint64_t parsed_events = 0;
static uint64_t skipped_lines = 0;

static int path_exists(const char *p) { struct stat st; return stat(p, &st) == 0; }

static int read_text(const char *path, char *buf, size_t n) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    ssize_t r = read(fd, buf, n - 1);
    int e = errno;
    close(fd);
    if (r < 0) { errno = e; return -1; }
    buf[r] = 0;
    while (r > 0 && isspace((unsigned char)buf[r - 1])) buf[--r] = 0;
    return 0;
}

static int write_text(const char *path, const char *value) {
    int fd = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    size_t len = strlen(value);
    ssize_t w = write(fd, value, len);
    int e = errno;
    close(fd);
    if (w != (ssize_t)len) { errno = e ? e : EIO; return -1; }
    return 0;
}

static void make_path(char *out, size_t n, const char *suffix) {
    snprintf(out, n, "%s/%s", tracefs, suffix);
}

static int parse_cpu_list(const char *s) {
    char *copy = strdup(s ? s : "");
    if (!copy) return -1;
    char *save = NULL;
    for (char *tok = strtok_r(copy, ",", &save); tok; tok = strtok_r(NULL, ",", &save)) {
        while (*tok && isspace((unsigned char)*tok)) tok++;
        char *dash = strchr(tok, '-');
        long a, b;
        if (dash) {
            *dash = 0;
            a = strtol(tok, NULL, 10);
            b = strtol(dash + 1, NULL, 10);
        } else {
            a = b = strtol(tok, NULL, 10);
        }
        if (a < 0 || b < a || b >= MAX_CPUS) { free(copy); return -1; }
        for (long c = a; c <= b; c++) {
            if (!selected[c]) { selected[c] = 1; selected_count++; }
        }
    }
    free(copy);
    return selected_count ? 0 : -1;
}

static void build_cpumask(char *out, size_t n) {
    int highest = 0;
    for (int i = 0; i < MAX_CPUS; i++) if (selected[i]) highest = i;
    int groups = highest / 32 + 1;
    uint32_t *v = calloc((size_t)groups, sizeof(*v));
    if (!v) { snprintf(out, n, "0"); return; }
    for (int i = 0; i <= highest; i++) if (selected[i]) v[i / 32] |= 1u << (i % 32);
    out[0] = 0;
    for (int g = groups - 1; g >= 0; g--) {
        char tmp[16];
        if (g == groups - 1) snprintf(tmp, sizeof(tmp), "%x", v[g]);
        else snprintf(tmp, sizeof(tmp), ",%08x", v[g]);
        strncat(out, tmp, n - strlen(out) - 1);
    }
    free(v);
}

static uint64_t parse_timestamp_ns(const char *p, const char **endp) {
    while (*p && isspace((unsigned char)*p)) p++;
    uint64_t sec = 0, frac = 0;
    int digits = 0;
    while (isdigit((unsigned char)*p)) { sec = sec * 10 + (uint64_t)(*p++ - '0'); }
    if (*p == '.') {
        p++;
        while (isdigit((unsigned char)*p)) {
            if (digits < 9) frac = frac * 10 + (uint64_t)(*p - '0');
            digits++; p++;
        }
    }
    while (digits < 9) { frac *= 10; digits++; }
    if (digits > 9) { /* extra digits intentionally truncated */ }
    if (endp) *endp = p;
    return sec * 1000000000ull + frac;
}

static int parse_line(const char *line, uint64_t *ts_ns, int *cpu, int *state, int *cpu_id) {
    const char *lb = strchr(line, '[');
    const char *rb = lb ? strchr(lb, ']') : NULL;
    const char *event = strstr(line, "cpu_idle:");
    if (!lb || !rb || !event) return -1;
    *cpu = atoi(lb + 1);
    const char *p = rb + 1;
    while (*p && *p != ':') p++;
    if (*p != ':') return -1;
    /* Walk backward to the beginning of the timestamp token. */
    const char *q = p;
    while (q > rb && !isspace((unsigned char)q[-1])) q--;
    *ts_ns = parse_timestamp_ns(q, NULL);
    const char *sp = strstr(event, "state=");
    const char *cp = strstr(event, "cpu_id=");
    if (!sp || !cp) return -1;
    unsigned long raw_state = strtoul(sp + 6, NULL, 0);
    *state = (raw_state == 0xfffffffful || raw_state == ~0ul) ? -1 : (int)raw_state;
    *cpu_id = atoi(cp + 7);
    return 0;
}

static void write_event(uint64_t ts, int cpu, int state, const char *kind, uint64_t duration_ns, int previous_state) {
    if (!first_ts_ns) first_ts_ns = ts;
    last_ts_ns = ts;
    fprintf(csv, "%llu,%llu,%d,%d,%s,%d,%llu\n",
        (unsigned long long)ts,
        (unsigned long long)(ts - first_ts_ns),
        cpu, state, kind, previous_state,
        (unsigned long long)duration_ns);
}

static void process_event(uint64_t ts, int cpu, int state) {
    if (cpu < 0 || cpu >= MAX_CPUS || !selected[cpu]) return;
    cpu_state_t *c = &cpus[cpu];
    if (state >= 0) {
        if (c->active && ts >= c->enter_ns && c->state >= 0 && c->state < MAX_STATES) {
            uint64_t d = ts - c->enter_ns;
            c->total_idle_ns[c->state] += d;
            write_event(ts, cpu, state, "reenter", d, c->state);
        } else {
            write_event(ts, cpu, state, "enter", 0, -1);
        }
        c->active = 1;
        c->state = state;
        c->enter_ns = ts;
        c->entries++;
        if (state < MAX_STATES) c->state_entries[state]++;
    } else {
        uint64_t d = 0;
        int prev = -1;
        if (c->active && ts >= c->enter_ns) {
            d = ts - c->enter_ns;
            prev = c->state;
            if (prev >= 0 && prev < MAX_STATES) c->total_idle_ns[prev] += d;
        }
        c->active = 0;
        c->wakeups++;
        write_event(ts, cpu, -1, "wake", d, prev);
    }
    parsed_events++;
}

static void restore_tracefs(void) {
    char p[512];
    make_path(p, sizeof(p), "tracing_on"); write_text(p, "0");
    make_path(p, sizeof(p), "events/power/cpu_idle/enable"); if (*saved_event_enable) write_text(p, saved_event_enable);
    make_path(p, sizeof(p), "trace_clock"); if (*saved_clock) write_text(p, saved_clock);
    make_path(p, sizeof(p), "tracing_cpumask"); if (*saved_cpumask) write_text(p, saved_cpumask);
    make_path(p, sizeof(p), "current_tracer"); if (*saved_current_tracer) write_text(p, saved_current_tracer);
    make_path(p, sizeof(p), "tracing_on"); if (*saved_tracing_on) write_text(p, saved_tracing_on);
}

static void write_summary(void) {
    if (!summary_path) return;
    FILE *f = fopen(summary_path, "w");
    if (!f) return;
    fprintf(f, "{\n  \"schema\": \"greenquic-cstate-v1\",\n");
    fprintf(f, "  \"clock\": \"mono_raw\",\n  \"parsed_events\": %llu,\n  \"skipped_lines\": %llu,\n",
        (unsigned long long)parsed_events, (unsigned long long)skipped_lines);
    fprintf(f, "  \"first_timestamp_ns\": %llu,\n  \"last_timestamp_ns\": %llu,\n",
        (unsigned long long)first_ts_ns, (unsigned long long)last_ts_ns);
    fprintf(f, "  \"cpus\": [");
    int first = 1;
    for (int cpu = 0; cpu < MAX_CPUS; cpu++) if (selected[cpu]) {
        fprintf(f, "%s%d", first ? "" : ", ", cpu); first = 0;
    }
    fprintf(f, "],\n  \"per_cpu\": {\n");
    int first_cpu = 1;
    for (int cpu = 0; cpu < MAX_CPUS; cpu++) if (selected[cpu]) {
        cpu_state_t *c = &cpus[cpu];
        fprintf(f, "%s    \"%d\": {\"entries\": %llu, \"wakeups\": %llu, \"states\": {",
            first_cpu ? "" : ",\n", cpu,
            (unsigned long long)c->entries, (unsigned long long)c->wakeups);
        int first_state = 1;
        for (int s = 0; s < MAX_STATES; s++) if (c->state_entries[s] || c->total_idle_ns[s]) {
            fprintf(f, "%s\"%d\": {\"entries\": %llu, \"total_idle_ns\": %llu}",
                first_state ? "" : ", ", s,
                (unsigned long long)c->state_entries[s],
                (unsigned long long)c->total_idle_ns[s]);
            first_state = 0;
        }
        fprintf(f, "}, \"active\": %s}", c->active ? "true" : "false");
        first_cpu = 0;
    }
    fprintf(f, "\n  }\n}\n");
    fclose(f);
}

int main(int argc, char **argv) {
    const char *output = NULL;
    const char *cpulist = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--output") && i + 1 < argc) output = argv[++i];
        else if (!strcmp(argv[i], "--summary") && i + 1 < argc) summary_path = argv[++i];
        else if (!strcmp(argv[i], "--cpus") && i + 1 < argc) cpulist = argv[++i];
        else if (!strcmp(argv[i], "--help")) {
            printf("usage: %s --output FILE.csv --summary FILE.json --cpus LIST\n", argv[0]); return 0;
        }
    }
    if (!output || !summary_path || !cpulist || parse_cpu_list(cpulist) != 0) {
        fprintf(stderr, "ERROR: --output, --summary and valid --cpus are required\n"); return 2;
    }
    if (path_exists("/sys/kernel/tracing/trace_pipe")) strcpy(tracefs, "/sys/kernel/tracing");
    else if (path_exists("/sys/kernel/debug/tracing/trace_pipe")) strcpy(tracefs, "/sys/kernel/debug/tracing");
    else { fprintf(stderr, "ERROR: tracefs is not mounted\n"); return 3; }

    char p[512], mask[512];
    make_path(p, sizeof(p), "trace_clock"); read_text(p, saved_clock, sizeof(saved_clock));
    make_path(p, sizeof(p), "tracing_cpumask"); read_text(p, saved_cpumask, sizeof(saved_cpumask));
    make_path(p, sizeof(p), "events/power/cpu_idle/enable"); read_text(p, saved_event_enable, sizeof(saved_event_enable));
    make_path(p, sizeof(p), "tracing_on"); read_text(p, saved_tracing_on, sizeof(saved_tracing_on));
    make_path(p, sizeof(p), "current_tracer"); read_text(p, saved_current_tracer, sizeof(saved_current_tracer));

    make_path(p, sizeof(p), "tracing_on"); if (write_text(p, "0")) { perror("tracing_on"); return 4; }
    make_path(p, sizeof(p), "current_tracer"); write_text(p, "nop");
    make_path(p, sizeof(p), "trace_clock"); if (write_text(p, "mono_raw")) { perror("trace_clock mono_raw"); restore_tracefs(); return 5; }
    build_cpumask(mask, sizeof(mask));
    make_path(p, sizeof(p), "tracing_cpumask"); if (write_text(p, mask)) { perror("tracing_cpumask"); restore_tracefs(); return 6; }
    make_path(p, sizeof(p), "trace"); write_text(p, "");
    make_path(p, sizeof(p), "events/power/cpu_idle/enable"); if (write_text(p, "1")) { perror("cpu_idle enable"); restore_tracefs(); return 7; }

    csv = fopen(output, "w");
    if (!csv) { perror("output"); restore_tracefs(); return 8; }
    setvbuf(csv, NULL, _IOLBF, 0);
    fprintf(csv, "timestamp_mono_raw_ns,relative_ns,cpu,state,event,previous_state,idle_duration_ns\n");

    make_path(p, sizeof(p), "trace_pipe");
    int fd = open(p, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) { perror("trace_pipe"); fclose(csv); restore_tracefs(); return 9; }

    signal(SIGINT, on_signal); signal(SIGTERM, on_signal); signal(SIGHUP, on_signal);
    make_path(p, sizeof(p), "tracing_on"); if (write_text(p, "1")) { perror("tracing_on=1"); close(fd); fclose(csv); restore_tracefs(); return 10; }

    char readbuf[BUF_SIZE], linebuf[BUF_SIZE * 2];
    size_t used = 0;
    struct pollfd pollfd = {.fd = fd, .events = POLLIN};
    while (!stop_requested) {
        int pr = poll(&pollfd, 1, 200);
        if (pr < 0) { if (errno == EINTR) continue; break; }
        if (pr == 0) continue;
        ssize_t r = read(fd, readbuf, sizeof(readbuf));
        if (r < 0) { if (errno == EAGAIN || errno == EINTR) continue; break; }
        for (ssize_t i = 0; i < r; i++) {
            char ch = readbuf[i];
            if (ch == '\n') {
                linebuf[used] = 0;
                uint64_t ts; int cpu, state, cpu_id;
                if (parse_line(linebuf, &ts, &cpu, &state, &cpu_id) == 0) process_event(ts, cpu_id >= 0 ? cpu_id : cpu, state);
                else skipped_lines++;
                used = 0;
            } else if (used + 1 < sizeof(linebuf)) linebuf[used++] = ch;
            else used = 0;
        }
    }

    make_path(p, sizeof(p), "tracing_on"); write_text(p, "0");
    close(fd);
    fclose(csv); csv = NULL;
    write_summary();
    restore_tracefs();
    return 0;
}
