#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

MARKER = "GREENQUIC-P5-TX-PACING-PROBE-V1"


def definition_bounds(text: str, token: str) -> tuple[int, int]:
    pos = text.find(token)
    while pos >= 0:
        brace = text.find("{", pos + len(token))
        semi = text.find(";", pos + len(token))
        if brace >= 0 and (semi < 0 or brace < semi):
            depth = 0
            state = "code"
            i = brace
            while i < len(text):
                c = text[i]
                n = text[i + 1] if i + 1 < len(text) else ""
                if state == "code":
                    if c == "/" and n == "/":
                        state = "line"; i += 2; continue
                    if c == "/" and n == "*":
                        state = "block"; i += 2; continue
                    if c == '"':
                        state = "string"; i += 1; continue
                    if c == "'":
                        state = "char"; i += 1; continue
                    if c == "{":
                        depth += 1
                    elif c == "}":
                        depth -= 1
                        if depth == 0:
                            start = max(
                                text.rfind("\nstatic", 0, pos),
                                text.rfind("\n_IRQL", 0, pos),
                            )
                            return (start + 1 if start >= 0 else pos, i + 1)
                    i += 1
                    continue
                if state == "line":
                    if c == "\n":
                        state = "code"
                    i += 1; continue
                if state == "block":
                    if c == "*" and n == "/":
                        state = "code"; i += 2; continue
                    i += 1; continue
                if state in {"string", "char"}:
                    quote = '"' if state == "string" else "'"
                    if c == "\\":
                        i += 2; continue
                    if c == quote:
                        state = "code"
                    i += 1; continue
            raise SystemExit(f"ERROR: unterminated function definition for {token}")
        pos = text.find(token, pos + len(token))
    raise SystemExit(f"ERROR: function definition missing: {token}")


def transform(text: str, backoff_ns: int, sleep_us: int) -> str:
    if MARKER in text:
        return text
    if backoff_ns and sleep_us:
        raise SystemExit("ERROR: choose busy backoff OR scheduler-yield sleep, not both")
    if backoff_ns < 0 or sleep_us < 0:
        raise SystemExit("ERROR: backoff values must be non-negative")
    if backoff_ns > 100_000:
        raise SystemExit("ERROR: busy backoff >100us refused")
    if sleep_us > 100:
        raise SystemExit("ERROR: scheduler-yield sleep >100us refused")

    start, end = definition_bounds(text, "CxPlatDpdkTx(")
    body = text[start:end]
    zero = "    if (unlikely(BufferCount == 0)) {\n"
    if body.count(zero) != 1:
        raise SystemExit(
            f"ERROR: CxPlatDpdkTx empty-dequeue anchor count={body.count(zero)}, expected 1"
        )

    record_anchor = '''    QuicTraceEvent(
        DatapathTxDequeue,
'''
    if body.count(record_anchor) != 1:
        raise SystemExit(
            f"ERROR: CxPlatDpdkTx nonempty record anchor count={body.count(record_anchor)}, expected 1"
        )

    helper = f'''/* {MARKER} backoff_ns={backoff_ns} sleep_us={sleep_us} */
static const char P5TxPacingProbeMarker[] __attribute__((used)) =
    "{MARKER} backoff_ns={backoff_ns} sleep_us={sleep_us}";
static atomic_uint_fast64_t P5TxPacingEmpty = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t P5TxPacingNonempty = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t P5TxPacingPackets = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t P5TxPacingBin1 = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t P5TxPacingBin2_4 = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t P5TxPacingBin5_8 = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t P5TxPacingBin9_16 = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t P5TxPacingBin17Plus = ATOMIC_VAR_INIT(0);

static inline void
P5TxPacingProbeBackoff(void)
{{
    if ({sleep_us}U != 0U) {{
        rte_delay_us_sleep({sleep_us}U);
        return;
    }}
    if ({backoff_ns}ULL == 0ULL) {{
        return;
    }}
    const uint64_t Hz = rte_get_tsc_hz();
    if (Hz == 0) {{
        return;
    }}
    const uint64_t Target =
        (Hz * {backoff_ns}ULL + 999999999ULL) / 1000000000ULL;
    const uint64_t Start = rte_get_tsc_cycles();
    while ((rte_get_tsc_cycles() - Start) < Target) {{
        rte_pause();
    }}
}}

static inline void
P5TxPacingProbeRecord(uint16_t Count)
{{
    atomic_fetch_add_explicit(&P5TxPacingNonempty, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&P5TxPacingPackets, Count, memory_order_relaxed);
    atomic_uint_fast64_t* Bin =
        Count == 1 ? &P5TxPacingBin1 :
        Count <= 4 ? &P5TxPacingBin2_4 :
        Count <= 8 ? &P5TxPacingBin5_8 :
        Count <= 16 ? &P5TxPacingBin9_16 : &P5TxPacingBin17Plus;
    atomic_fetch_add_explicit(Bin, 1, memory_order_relaxed);
}}

__attribute__((destructor))
static void
P5TxPacingProbeReport(void)
{{
    const uint64_t Calls =
        atomic_load_explicit(&P5TxPacingNonempty, memory_order_relaxed);
    const uint64_t Packets =
        atomic_load_explicit(&P5TxPacingPackets, memory_order_relaxed);
    fprintf(
        stderr,
        "[P5-TX-PACING] backoff_ns={backoff_ns} sleep_us={sleep_us} "
        "empty_dequeues=%" PRIu64 " nonempty_dequeues=%" PRIu64 " "
        "dequeued_packets=%" PRIu64 " bin1=%" PRIu64 " bin2_4=%" PRIu64 " bin5_8=%" PRIu64 " "
        "bin9_16=%" PRIu64 " bin17plus=%" PRIu64 "\\n",
        atomic_load_explicit(&P5TxPacingEmpty, memory_order_relaxed),
        Calls,
        Packets,
        atomic_load_explicit(&P5TxPacingBin1, memory_order_relaxed),
        atomic_load_explicit(&P5TxPacingBin2_4, memory_order_relaxed),
        atomic_load_explicit(&P5TxPacingBin5_8, memory_order_relaxed),
        atomic_load_explicit(&P5TxPacingBin9_16, memory_order_relaxed),
        atomic_load_explicit(&P5TxPacingBin17Plus, memory_order_relaxed));
}}

'''

    body = body.replace(
        zero,
        zero
        + "        if (Dpdk->GreenQuicMode == GREENQUIC_MODE_OFF) {\n"
          "            atomic_fetch_add_explicit(&P5TxPacingEmpty, 1, memory_order_relaxed);\n"
          "            P5TxPacingProbeBackoff();\n"
          "        }\n",
        1,
    )
    body = body.replace(
        record_anchor,
        "    if (Dpdk->GreenQuicMode == GREENQUIC_MODE_OFF) {\n"
        "        P5TxPacingProbeRecord(BufferCount);\n"
        "    }\n\n"
        + record_anchor,
        1,
    )
    return text[:start] + helper + body + text[end:]


def self_test() -> None:
    sample = r'''
#include <stdint.h>
static
void
CxPlatDpdkTx(DPDK_DATAPATH* Dpdk)
{
    const uint16_t BufferCount =
        (uint16_t)rte_ring_sc_dequeue_burst(
            Interface->TxRingBuffer, (void**)Buffers, Dpdk->TxBurstSize, NULL);
    if (unlikely(BufferCount == 0)) {
        if (Dpdk->GreenQuicMode != GREENQUIC_MODE_OFF) {
            GreenQuicOnTxPoll(Dpdk, Core, RingBefore, 0, 0);
        }
        return;
    }

    QuicTraceEvent(
        DatapathTxDequeue,
        "x",
        BufferCount);
}
'''
    for ns, us in ((0, 0), (250, 0), (1000, 0), (0, 1)):
        out = transform(sample, ns, us)
        assert out.count(MARKER) >= 2
        assert "P5TxPacingProbeBackoff();" in out
        assert "P5TxPacingEmpty" in out
        assert "P5TxPacingProbeRecord(BufferCount);" in out
        assert transform(out, ns, us) == out
    try:
        transform(sample, 1, 1)
    except SystemExit:
        pass
    else:
        raise AssertionError("mixed busy/sleep control must fail")
    print("P5 TX PACING PROBE SELF-TEST PASS")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("path", nargs="?", type=Path)
    ap.add_argument("--backoff-ns", type=int, default=0)
    ap.add_argument("--sleep-us", type=int, default=0)
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        self_test()
        return 0
    if args.path is None:
        ap.error("path is required unless --self-test is used")
    text = args.path.read_text(encoding="utf-8")
    out = transform(text, args.backoff_ns, args.sleep_us)
    args.path.write_text(out, encoding="utf-8")
    print(
        f"P5 TX PACING PROBE APPLIED path={args.path} "
        f"backoff_ns={args.backoff_ns} sleep_us={args.sleep_us}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
