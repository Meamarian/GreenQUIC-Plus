#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${1:-/root/mohsen/msquic}"
SUITE="${2:-/root/mohsen/greenquic_test_suite_v22}"
COMMON="$SUITE/common/bin"
GQ_COMMON="$COMMON/gq_common.sh"
BUNDLER="$COMMON/bundle_run_results.py"
SUMMARY="$COMMON/write_run_summary.py"
BUILD_HELPERS="$COMMON/build_greenquic_helpers.sh"
C_SRC="$COMMON/gq_cstate_trace.c"
C_BIN="$COMMON/gq_cstate_trace"
PLOTTER="$COMMON/cstate_trace.py"
MARKER="GREENQUIC-V22-CSTATE-TRACE-V1"
STAMP="$(date +%Y%m%d_%H%M%S)"

for path in "$GQ_COMMON" "$BUNDLER" "$SUMMARY"; do
    [[ -f "$path" ]] || { echo "ERROR: missing $path" >&2; exit 1; }
done
mkdir -p "$COMMON"

if grep -Fq "$MARKER" "$GQ_COMMON"; then
    echo "PASS: C-state tracing patch is already installed."
    exit 0
fi

for path in "$GQ_COMMON" "$BUNDLER" "$SUMMARY" "$BUILD_HELPERS"; do
    [[ -f "$path" ]] && cp -a "$path" "$path.before_cstate_trace_$STAMP"
done

echo "Backups created with suffix .before_cstate_trace_$STAMP"

cat > "$C_SRC" <<'C'
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
C

cat > "$PLOTTER" <<'PY'
#!/usr/bin/env python3
import argparse, csv, json, os, statistics
from collections import Counter, defaultdict
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import MultipleLocator


def env_float(name, default):
    try: return float(os.environ.get(name, default))
    except Exception: return float(default)


def env_int(name, default):
    try: return int(os.environ.get(name, default))
    except Exception: return int(default)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--csv", type=Path, required=True)
    p.add_argument("--summary", type=Path, required=True)
    p.add_argument("--timeline-svg", type=Path, required=True)
    p.add_argument("--histogram-svg", type=Path, required=True)
    p.add_argument("--role", required=True)
    a = p.parse_args()

    rows = []
    with a.csv.open(newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            r["relative_ns"] = int(r["relative_ns"])
            r["cpu"] = int(r["cpu"])
            r["state"] = int(r["state"])
            r["previous_state"] = int(r["previous_state"])
            r["idle_duration_ns"] = int(r["idle_duration_ns"])
            rows.append(r)
    summary = json.loads(a.summary.read_text(encoding="utf-8")) if a.summary.exists() else {}

    width_px = env_int("GQ_CSTATE_PLOT_WIDTH_PX", env_int("GQ_PLOT_WIDTH_PX", 24000))
    height_px = env_int("GQ_CSTATE_PLOT_HEIGHT_PX", env_int("GQ_PLOT_HEIGHT_PX", 3500))
    dpi = 100
    tick_ms = env_float("GQ_CSTATE_PLOT_X_TICK_MS", 10)
    label_ms = env_float("GQ_CSTATE_PLOT_X_LABEL_MS", 100)
    cpus = sorted({r["cpu"] for r in rows})

    fig, ax = plt.subplots(figsize=(width_px / dpi, height_px / dpi), dpi=dpi)
    ymap = {cpu: i for i, cpu in enumerate(cpus)}
    for r in rows:
        if r["event"] != "wake" or r["previous_state"] < 0 or r["idle_duration_ns"] <= 0: continue
        end_ms = r["relative_ns"] / 1e6
        start_ms = end_ms - r["idle_duration_ns"] / 1e6
        y = ymap[r["cpu"]]
        ax.broken_barh([(start_ms, end_ms - start_ms)], (y - .38, .76))
    ax.set_yticks(list(ymap.values()), [f"CPU {c}" for c in cpus])
    ax.set_xlabel("Time from first cpu_idle event (ms)")
    ax.set_ylabel("Traced CPU")
    ax.set_title(f"GreenQUIC Linux C-state residency — {a.role}")
    ax.xaxis.set_minor_locator(MultipleLocator(tick_ms))
    ax.xaxis.set_major_locator(MultipleLocator(label_ms))
    ax.grid(True, axis="x", which="major")
    ax.grid(True, axis="x", which="minor", alpha=.2)
    fig.tight_layout()
    fig.savefig(a.timeline_svg, format="svg")
    plt.close(fig)

    durations = defaultdict(list)
    for r in rows:
        if r["event"] == "wake" and r["previous_state"] >= 0 and r["idle_duration_ns"] > 0:
            durations[r["previous_state"]].append(r["idle_duration_ns"] / 1e6)
    states = sorted(durations)
    counts = [len(durations[s]) for s in states]
    fig, ax = plt.subplots(figsize=(max(12, len(states) * 2), 8), dpi=dpi)
    ax.bar([str(s) for s in states], counts)
    ax.set_xlabel("Linux cpu_idle state index")
    ax.set_ylabel("Completed idle intervals / wakeups")
    ax.set_title(f"GreenQUIC C-state wakeup histogram — {a.role}")
    ax.grid(True, axis="y", alpha=.3)
    fig.tight_layout()
    fig.savefig(a.histogram_svg, format="svg")
    plt.close(fig)

    # Add plot-friendly aggregate fields without changing raw C timestamps.
    summary["completed_idle_intervals"] = sum(counts)
    summary["state_interval_counts"] = {str(s): len(durations[s]) for s in states}
    summary["state_total_idle_ms"] = {str(s): sum(durations[s]) for s in states}
    summary["state_median_idle_us"] = {
        str(s): statistics.median(durations[s]) * 1000.0 for s in states if durations[s]
    }
    a.summary.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")

if __name__ == "__main__": main()
PY
chmod +x "$PLOTTER"

# Compile the helper now.
gcc -O2 -std=gnu11 -Wall -Wextra -Werror "$C_SRC" -o "$C_BIN"
chmod +x "$C_BIN"

python3 - "$GQ_COMMON" <<'PY'
from pathlib import Path
import re, sys
path = Path(sys.argv[1]); text = path.read_text(encoding="utf-8")
marker = "GREENQUIC-V22-CSTATE-TRACE-V1"

anchor = ': "${GQ_MSR_SMOOTH_SAMPLES:=3}"\n'
if anchor not in text: raise SystemExit("ERROR: C-state defaults anchor not found")
defaults = '''\
: "${ENABLE_CSTATE_RECORD:=0}"
: "${GQ_REQUIRE_CSTATE_RECORD:=0}"
: "${GQ_CSTATE_CPUS:=}"
: "${GQ_CSTATE_PLOT_X_TICK_MS:=10}"
: "${GQ_CSTATE_PLOT_X_LABEL_MS:=100}"
export ENABLE_CSTATE_RECORD GQ_REQUIRE_CSTATE_RECORD GQ_CSTATE_CPUS
export GQ_CSTATE_PLOT_X_TICK_MS GQ_CSTATE_PLOT_X_LABEL_MS
'''
text = text.replace(anchor, anchor + defaults, 1)

func_anchor = '\nrun_server() {'
if func_anchor not in text: raise SystemExit("ERROR: run_server anchor not found")
functions = r'''
# GREENQUIC-V22-CSTATE-TRACE-V1
cstate_trace_start() {
    local role="$1" output_prefix="$2"
    GQ_CSTATE_TRACE_PID=""
    [[ "${ENABLE_CSTATE_RECORD:-0}" == 1 ]] || return 0

    local helper="$GQ_COMMON_DIR/bin/gq_cstate_trace"
    local cpus="${GQ_CSTATE_CPUS:-}"
    if [[ -z "$cpus" ]]; then
        local cfg="$TEST_DIR/runtime/$role/dpdk.ini"
        cpus="$(sed -n 's/^[[:space:]]*GreenQuicDpdkLcores[[:space:]]*=[[:space:]]*//p' "$cfg" 2>/dev/null | tail -n 1 | tr -d '[:space:]')"
    fi
    [[ -n "$cpus" ]] || cpus="19"

    if [[ ! -x "$helper" ]]; then
        [[ "${GQ_REQUIRE_CSTATE_RECORD:-0}" == 1 ]] && die "C-state recorder is missing: $helper"
        warn "C-state recorder is unavailable; continuing without it."
        return 0
    fi

    "$helper" --cpus "$cpus" --output "${output_prefix}.csv" --summary "${output_prefix}.json" \
        >"${output_prefix}_sampler.log" 2>&1 &
    GQ_CSTATE_TRACE_PID=$!
    sleep 0.10
    if ! kill -0 "$GQ_CSTATE_TRACE_PID" 2>/dev/null; then
        local rc=0; wait "$GQ_CSTATE_TRACE_PID" || rc=$?
        GQ_CSTATE_TRACE_PID=""
        [[ "${GQ_REQUIRE_CSTATE_RECORD:-0}" == 1 ]] && die "C-state recorder failed to start; inspect ${output_prefix}_sampler.log"
        warn "C-state recorder failed to start (rc=$rc); continuing without it."
        return 0
    fi
    log "Started ${role} Linux cpu_idle trace pid=$GQ_CSTATE_TRACE_PID CPUs=$cpus clock=mono_raw"
}

cstate_trace_stop() {
    local pid="${1:-}"
    [[ -n "$pid" ]] || return 0
    kill -TERM "$pid" 2>/dev/null || true
    local rc=0; wait "$pid" || rc=$?
    if [[ "$rc" != 0 ]]; then
        [[ "${GQ_REQUIRE_CSTATE_RECORD:-0}" == 1 ]] && return "$rc"
        warn "C-state recorder stopped with rc=$rc; transport result is preserved."
    fi
    return 0
}
'''
text = text.replace(func_anchor, functions + func_anchor, 1)

server_local = '    local transfer_window="$TEST_DIR/results/server_transfer_${mode}_${stamp}.json"\n'
if server_local not in text: raise SystemExit("ERROR: server transfer anchor not found")
text = text.replace(server_local, server_local + '    local cstate_prefix="$TEST_DIR/results/server_cstate_${mode}_${stamp}"\n', 1)
server_start = '    msr_trace_start server "$msr_csv"\n'
if server_start not in text: raise SystemExit("ERROR: server MSR start anchor not found")
text = text.replace(server_start, server_start + '    cstate_trace_start server "$cstate_prefix"\n    GQ_SERVER_CSTATE_PID="${GQ_CSTATE_TRACE_PID:-}"\n', 1)
text = text.replace('local check_rc=0 energy_rc=0 power_rc=0 msr_rc=0 bundle_rc=0', 'local check_rc=0 energy_rc=0 power_rc=0 msr_rc=0 cstate_rc=0 bundle_rc=0', 1)
server_stop = '        msr_trace_stop "${GQ_SERVER_MSR_PID:-}" || msr_rc=$?\n'
if server_stop not in text: raise SystemExit("ERROR: server MSR stop anchor not found")
text = text.replace(server_stop, '        cstate_trace_stop "${GQ_SERVER_CSTATE_PID:-}" || cstate_rc=$?\n' + server_stop, 1)
server_status = '        [[ "$rc" == 0 && "$msr_rc" != 0 ]] && rc="$msr_rc"\n'
if server_status not in text: raise SystemExit("ERROR: server status anchor not found")
text = text.replace(server_status, server_status + '        [[ "$rc" == 0 && "$cstate_rc" != 0 ]] && rc="$cstate_rc"\n', 1)

client_local = '    local transfer_window="$TEST_DIR/results/client_transfer_${mode}_${stamp}.json"\n'
if client_local not in text: raise SystemExit("ERROR: client transfer anchor not found")
text = text.replace(client_local, client_local + '    local cstate_prefix="$TEST_DIR/results/client_cstate_${mode}_${stamp}"\n', 1)
client_start = '    msr_trace_start client "$msr_csv"\n'
if client_start not in text: raise SystemExit("ERROR: client MSR start anchor not found")
text = text.replace(client_start, client_start + '    cstate_trace_start client "$cstate_prefix"\n    local cstate_pid="${GQ_CSTATE_TRACE_PID:-}"\n', 1)
text = text.replace('local rc=0 energy_rc=0 power_rc=0 msr_rc=0 manifest_rc=0 cleanup_rc=0', 'local rc=0 energy_rc=0 power_rc=0 msr_rc=0 cstate_rc=0 manifest_rc=0 cleanup_rc=0', 1)
client_stop = '    msr_trace_stop "$msr_pid" || msr_rc=$?\n'
if client_stop not in text: raise SystemExit("ERROR: client MSR stop anchor not found")
text = text.replace(client_stop, '    cstate_trace_stop "$cstate_pid" || cstate_rc=$?\n' + client_stop, 1)
client_return = '    [[ "$msr_rc" == 0 ]] || return "$msr_rc"\n'
if client_return not in text: raise SystemExit("ERROR: client return anchor not found")
text = text.replace(client_return, client_return + '    [[ "$cstate_rc" == 0 ]] || return "$cstate_rc"\n', 1)

text += f"\n# {marker}\n"
path.write_text(text, encoding="utf-8")
PY

python3 - "$BUNDLER" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1]); text = path.read_text(encoding="utf-8")

anchor = '    move(msr_log_source, details / f"{stem}_msr_sampler.txt")\n'
if anchor not in text: raise SystemExit("ERROR: bundler MSR move anchor not found")
insert = '''\

    cstate_prefix = result_root / f"{args.role}_cstate_{args.mode}_{stamp}"
    cstate_csv = details / f"{stem}_cstate.csv"
    cstate_json = details / f"{stem}_cstate.json"
    move(Path(str(cstate_prefix) + ".csv"), cstate_csv)
    move(Path(str(cstate_prefix) + ".json"), cstate_json)
    move(Path(str(cstate_prefix) + "_sampler.log"), details / f"{stem}_cstate_sampler.txt")
'''
text = text.replace(anchor, anchor + insert, 1)

anchor2 = '        subprocess.run(command, check=True)\n\n    metadata = {'
if anchor2 not in text: raise SystemExit("ERROR: bundler plot anchor not found")
insert2 = '''\
        subprocess.run(command, check=True)

    if cstate_csv.is_file() and cstate_json.is_file():
        subprocess.run([
            "python3", str(Path(__file__).with_name("cstate_trace.py")),
            "--csv", str(cstate_csv),
            "--summary", str(cstate_json),
            "--timeline-svg", str(run_dir / f"{stem}_cstate_timeseries.svg"),
            "--histogram-svg", str(run_dir / f"{stem}_cstate_wakeup_histogram.svg"),
            "--role", args.role,
        ], check=True)

    metadata = {'''
text = text.replace(anchor2, insert2, 1)
path.write_text(text, encoding="utf-8")
PY

python3 - "$SUMMARY" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1]); text = path.read_text(encoding="utf-8")
anchor = '    freq = read_json(first(details, f"{args.stem}_frequency.json"))\n'
if anchor not in text: raise SystemExit("ERROR: summary JSON anchor not found")
text = text.replace(anchor, anchor + '    cstate = read_json(first(details, f"{args.stem}_cstate.json"))\n', 1)

anchor2 = '    else:\n        lines.append(f"- EPOLL timeouts: {timeout_count}")\n\n    terminal_end = len(lines)\n'
if anchor2 not in text: raise SystemExit("ERROR: summary idle anchor not found")
insert = '''\
    else:
        lines.append(f"- EPOLL timeouts: {timeout_count}")

    lines.extend(["", "Linux C-state Trace", "-------------------"])
    if cstate:
        per_cpu = cstate.get("per_cpu") or {}
        total_entries = sum(int(v.get("entries", 0) or 0) for v in per_cpu.values())
        total_wakeups = sum(int(v.get("wakeups", 0) or 0) for v in per_cpu.values())
        state_counts = cstate.get("state_interval_counts") or {}
        state_idle_ms = cstate.get("state_total_idle_ms") or {}
        lines.extend([
            f"- Trace clock: {cstate.get('clock', 'unavailable')}",
            f"- CPUs traced: {', '.join(str(v) for v in cstate.get('cpus', [])) or 'none'}",
            f"- cpu_idle entries: {total_entries}",
            f"- Wakeups / idle exits: {total_wakeups}",
            f"- Completed idle intervals: {cstate.get('completed_idle_intervals', 0)}",
        ])
        if state_counts:
            rendered = ", ".join(
                f"state {state}={state_counts[state]} intervals/{float(state_idle_ms.get(state, 0.0)):.3f} ms"
                for state in sorted(state_counts, key=lambda value: int(value))
            )
            lines.append(f"- Per-state residency: {rendered}")
    else:
        lines.append("- Disabled or unavailable for this run.")

    terminal_end = len(lines)
'''
text = text.replace(anchor2, insert, 1)
path.write_text(text, encoding="utf-8")
PY

# Add helper build command for future installs/rebuilds.
if [[ -f "$BUILD_HELPERS" ]] && ! grep -Fq 'gq_cstate_trace.c' "$BUILD_HELPERS"; then
cat >> "$BUILD_HELPERS" <<'SH'

# GREENQUIC-V22-CSTATE-TRACE-V1
gcc -O2 -std=gnu11 -Wall -Wextra -Werror \
    "$GQ_COMMON_DIR/bin/gq_cstate_trace.c" \
    -o "$GQ_COMMON_DIR/bin/gq_cstate_trace"
chmod +x "$GQ_COMMON_DIR/bin/gq_cstate_trace"
SH
fi

bash -n "$GQ_COMMON" "$BUILD_HELPERS"
python3 -m py_compile "$BUNDLER" "$SUMMARY" "$PLOTTER"
"$C_BIN" --help >/dev/null

grep -Fq "$MARKER" "$GQ_COMMON" || { echo "ERROR: patch marker missing" >&2; exit 1; }

cat <<'DONE'

PASS: Linux cpu_idle C-state tracing is integrated.

Default:
  ENABLE_CSTATE_RECORD=0

Enable per run:
  ENABLE_CSTATE_RECORD=1 ./run_server.sh
  ENABLE_CSTATE_RECORD=1 ./run_client.sh

Optional controls:
  GQ_CSTATE_CPUS=19,20
  GQ_REQUIRE_CSTATE_RECORD=1
  GQ_CSTATE_PLOT_X_TICK_MS=10
  GQ_CSTATE_PLOT_X_LABEL_MS=100

The recorder uses the kernel power:cpu_idle tracepoint with trace_clock=mono_raw.
The timestamp written to CSV is the kernel event timestamp, not the later
userspace read time. state=-1 is counted as the idle exit/wakeup event.
No MsQuic rebuild is required.
DONE
