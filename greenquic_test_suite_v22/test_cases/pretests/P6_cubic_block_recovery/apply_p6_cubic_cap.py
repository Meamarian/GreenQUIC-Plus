#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: apply_p6_cubic_cap.py PATH_TO_cubic.c")

path = Path(sys.argv[1])
src = path.read_text(encoding="utf-8")
marker = "GREENQUIC-P6-CUBIC-CWND-CAP-V1"
if marker in src:
    print(f"{marker}: already applied")
    raise SystemExit(0)

# The cap is P6-only and runtime-configurable. It does not synthesize the
# CWND_BLOCKED hint. It only caps the real CUBIC CongestionWindow; the existing
# GetSendAllowance path still decides blocked state using
# BytesInFlight >= CongestionWindow and pulses the existing hint naturally.
anchor = '''#define TEN_TIMES_C_CUBIC 4\n'''
insert = r'''

// GREENQUIC-P6-CUBIC-CWND-CAP-V1
// P6-only runtime congestion-window cap used to create a controlled
// congestion-window-limited sender on an otherwise near-zero-RTT direct link.
// 0 disables the cap. Units are bytes.
static BOOLEAN GreenQuicP6CwndCapInitialized = FALSE;
static uint32_t GreenQuicP6CwndCapBytes = 0;

static uint32_t
GreenQuicP6GetCwndCapBytes(void)
{
    if (!GreenQuicP6CwndCapInitialized) {
        const char* Value = getenv("GQ_P6_CWND_CAP_BYTES");
        if (Value != NULL && Value[0] != '\0') {
            const uint64_t Parsed = strtoull(Value, NULL, 10);
            GreenQuicP6CwndCapBytes =
                Parsed > UINT32_MAX ? UINT32_MAX : (uint32_t)Parsed;
        }
        GreenQuicP6CwndCapInitialized = TRUE;
        printf(
            "GreenQUIC P6 CUBIC cap: marker=%s cap_bytes=%u\n",
            "GREENQUIC-P6-CUBIC-CWND-CAP-V1",
            GreenQuicP6CwndCapBytes);
        fflush(stdout);
    }
    return GreenQuicP6CwndCapBytes;
}

static inline void
GreenQuicP6ApplyCwndCap(
    _Inout_ QUIC_CONGESTION_CONTROL_CUBIC* Cubic
    )
{
    const uint32_t Cap = GreenQuicP6GetCwndCapBytes();
    if (Cap != 0 && Cubic->CongestionWindow > Cap) {
        Cubic->CongestionWindow = Cap;
        if (Cubic->SlowStartThreshold > Cap) {
            Cubic->SlowStartThreshold = Cap;
        }
        if (Cubic->AimdWindow > Cap) {
            Cubic->AimdWindow = Cap;
        }
    }
}
'''

if src.count(anchor) != 1:
    raise SystemExit(f"ERROR: expected one CUBIC constant anchor, found {src.count(anchor)}")
src = src.replace(anchor, anchor + insert, 1)

# The same real CUBIC-window initialization sequence is used in both
# CubicCongestionControlReset() and CubicCongestionControlInitialize().
# Cap both sites so P6 starts capped on connection creation and stays capped
# after any later CUBIC reset.
old_reset = '''    Cubic->CongestionWindow = DatagramPayloadLength * Cubic->InitialWindowPackets;\n    Cubic->BytesInFlightMax = Cubic->CongestionWindow / 2;\n'''
new_reset = '''    Cubic->CongestionWindow = DatagramPayloadLength * Cubic->InitialWindowPackets;\n    GreenQuicP6ApplyCwndCap(Cubic);\n    Cubic->BytesInFlightMax = Cubic->CongestionWindow / 2;\n'''
if src.count(old_reset) != 2:
    raise SystemExit(
        f"ERROR: expected two CUBIC initialization/reset window blocks, "
        f"found {src.count(old_reset)}"
    )
src = src.replace(old_reset, new_reset)

# Apply after normal ACK-driven growth and the existing 2*BytesInFlightMax limit.
old_growth = '''    if (Cubic->CongestionWindow > 2 * Cubic->BytesInFlightMax) {\n        Cubic->CongestionWindow = 2 * Cubic->BytesInFlightMax;\n    }\n\n    if (Cubic->CongestionWindow > OldCongestionWindow) {\n'''
new_growth = '''    if (Cubic->CongestionWindow > 2 * Cubic->BytesInFlightMax) {\n        Cubic->CongestionWindow = 2 * Cubic->BytesInFlightMax;\n    }\n\n    GreenQuicP6ApplyCwndCap(Cubic);\n\n    if (Cubic->CongestionWindow > OldCongestionWindow) {\n'''
if src.count(old_growth) != 1:
    raise SystemExit(f"ERROR: expected one ACK growth limit block, found {src.count(old_growth)}")
src = src.replace(old_growth, new_growth, 1)

# Apply after congestion events reduce the normal CUBIC window too.
old_event = '''        Cubic->SlowStartThreshold =\n        Cubic->CongestionWindow =\n        Cubic->AimdWindow =\n            CXPLAT_MAX(\n                (uint32_t)DatagramPayloadLength * QUIC_PERSISTENT_CONGESTION_WINDOW_PACKETS,\n                Cubic->CongestionWindow * TEN_TIMES_BETA_CUBIC / 10);\n    }\n}\n'''
new_event = '''        Cubic->SlowStartThreshold =\n        Cubic->CongestionWindow =\n        Cubic->AimdWindow =\n            CXPLAT_MAX(\n                (uint32_t)DatagramPayloadLength * QUIC_PERSISTENT_CONGESTION_WINDOW_PACKETS,\n                Cubic->CongestionWindow * TEN_TIMES_BETA_CUBIC / 10);\n    }\n\n    GreenQuicP6ApplyCwndCap(Cubic);\n}\n'''
if src.count(old_event) != 1:
    raise SystemExit(f"ERROR: expected one congestion-event window block, found {src.count(old_event)}")
src = src.replace(old_event, new_event, 1)

path.write_text(src, encoding="utf-8")
print(f"Applied {marker} to {path}")
