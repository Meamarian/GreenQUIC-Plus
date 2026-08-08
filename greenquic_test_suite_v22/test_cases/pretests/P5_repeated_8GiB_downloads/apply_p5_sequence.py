#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: apply_p5_sequence.py PATH_TO_INTEROP_CPP")

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")


def replace_once(old: str, new: str, label: str) -> None:
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(
            f"ERROR: expected exactly one {label} block, found {count}; "
            "refusing to modify an unexpected interop.cpp"
        )
    text = text.replace(old, new, 1)


replace_once(
    "#include <fstream>\n\nnamespace fs = std::filesystem;\n",
    "#include <fstream>\n#include <thread>\n\nnamespace fs = std::filesystem;\n",
    "include anchor",
)

replace_once(
    "bool CustomUrlPath = false;\n"
    "std::vector<std::string> Urls;\n\n",
    r'''bool CustomUrlPath = false;
std::vector<std::string> Urls;

// GreenQUIC-P5-SEQUENCE-V2
// Tool-only repeated-download sequencing. It is inactive unless explicitly
// enabled by the P5 test runner, so normal quicinterop behavior is unchanged.
static const char* const GreenQuicP5SequenceMarker =
    "GreenQUIC-P5-SEQUENCE-V2";

static bool
GreenQuicP5SequenceEnabled()
{
    const char* Value = getenv("GQ_INTEROP_P5_SEQUENCE");
    return Value != nullptr && Value[0] != '\0' && strcmp(Value, "0") != 0;
}

static uint64_t
GreenQuicP5EnvUs(const char* Name, uint64_t DefaultValue = 0)
{
    const char* Value = getenv(Name);
    if (Value == nullptr || Value[0] == '\0') {
        return DefaultValue;
    }
    char* End = nullptr;
    const unsigned long long Parsed = strtoull(Value, &End, 10);
    if (End == Value || *End != '\0') {
        printf("GreenQUIC-P5: invalid %s=%s\n", Name, Value);
        return DefaultValue;
    }
    return (uint64_t)Parsed;
}

static uint64_t
GreenQuicP5MonotonicUs()
{
    const auto Now = std::chrono::steady_clock::now().time_since_epoch();
    return (uint64_t)
        std::chrono::duration_cast<std::chrono::microseconds>(Now).count();
}

''',
    "P5 helper insertion",
)

old_method = r'''    bool SendHttpRequests(bool WaitForResponse = true) {
        for (auto& Url : Urls) {
            InteropStream* Stream = new InteropStream(Connection, Url.c_str());
            Streams.push_back(Stream);
            if (!Stream->SendHttpRequest(WaitForResponse)) {
                return false;
            }
        }
        return !WaitForResponse || WaitForHttpResponses();
    }
'''

new_method = old_method + r'''    bool SendHttpRequestsP5Sequential() {
        const uint64_t GapUs =
            GreenQuicP5EnvUs("GQ_INTEROP_REQUEST_GAP_US", 0);
        const uint64_t GateTimeoutUs =
            GreenQuicP5EnvUs("GQ_INTEROP_P5_GATE_TIMEOUT_US", 120000000);
        const char* GatePath = getenv("GQ_INTEROP_P5_START_GATE");

        printf(
            "[GreenQUIC-P5] marker=%s downloads=%zu gap_us=%llu\n",
            GreenQuicP5SequenceMarker,
            Urls.size(),
            (unsigned long long)GapUs);
        fflush(stdout);

        if (GatePath != nullptr && GatePath[0] != '\0') {
            const uint64_t GateReadyUs = GreenQuicP5MonotonicUs();
            printf(
                "[GreenQUIC-P5] ready_for_start_gate_us=%llu gate=%s\n",
                (unsigned long long)GateReadyUs,
                GatePath);
            fflush(stdout);

            while (!fs::exists(GatePath)) {
                if (GreenQuicP5MonotonicUs() - GateReadyUs >= GateTimeoutUs) {
                    printf(
                        "[GreenQUIC-P5] start_gate_timeout_us=%llu gate=%s\n",
                        (unsigned long long)GateTimeoutUs,
                        GatePath);
                    fflush(stdout);
                    return false;
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            }

            printf(
                "[GreenQUIC-P5] start_gate_released_us=%llu gate=%s\n",
                (unsigned long long)GreenQuicP5MonotonicUs(),
                GatePath);
            fflush(stdout);
        }

        size_t RequestIndex = 0;
        for (auto& Url : Urls) {
            ++RequestIndex;
            const uint64_t StartUs = GreenQuicP5MonotonicUs();
            printf(
                "[GreenQUIC-P5] request=%zu/%zu start_us=%llu path=%s\n",
                RequestIndex,
                Urls.size(),
                (unsigned long long)StartUs,
                Url.c_str());
            fflush(stdout);

            InteropStream* Stream = new InteropStream(Connection, Url.c_str());
            Streams.push_back(Stream);
            const bool Success = Stream->SendHttpRequest(true);
            const uint64_t CompleteUs = GreenQuicP5MonotonicUs();

            printf(
                "[GreenQUIC-P5] request=%zu/%zu complete_us=%llu path=%s "
                "duration_us=%llu success=%d\n",
                RequestIndex,
                Urls.size(),
                (unsigned long long)CompleteUs,
                Url.c_str(),
                (unsigned long long)(CompleteUs - StartUs),
                Success ? 1 : 0);
            fflush(stdout);

            if (!Success) {
                return false;
            }

            if (GapUs > 0 && RequestIndex < Urls.size()) {
                const uint64_t GapStartUs = GreenQuicP5MonotonicUs();
                std::this_thread::sleep_for(
                    std::chrono::microseconds((long long)GapUs));
                const uint64_t GapEndUs = GreenQuicP5MonotonicUs();
                printf(
                    "[GreenQUIC-P5] gap_after=%zu requested_us=%llu actual_us=%llu\n",
                    RequestIndex,
                    (unsigned long long)GapUs,
                    (unsigned long long)(GapEndUs - GapStartUs));
                fflush(stdout);
            }
        }
        return true;
    }
'''

replace_once(old_method, new_method, "InteropConnection SendHttpRequests")

old_stream_data = r'''        InteropConnection Connection(Configuration, false);
        if (Feature == ZeroRtt) {
            Connection.SetResumptionTicket(ResumptionTicket, ResumptionTicketLength);
        }
        if (Connection.SendHttpRequests(false) &&
            Connection.ConnectToServer(Endpoint.ServerName, Port) &&
            Connection.WaitForHttpResponses()) {
            Connection.GetQuicVersion(QuicVersionUsed);
            Connection.GetNegotiatedAlpn(NegotiatedAlpn);
            if (Feature == ZeroRtt) {
                Success = Connection.UsedZeroRtt();
            } else {
                Success = true;
            }
        }
'''

new_stream_data = r'''        InteropConnection Connection(Configuration, false);
        if (Feature == ZeroRtt) {
            Connection.SetResumptionTicket(ResumptionTicket, ResumptionTicketLength);
        }
        if (Feature == StreamData && GreenQuicP5SequenceEnabled()) {
            // P5 is intentionally different from the stock StreamData path:
            // connect once, then issue one stream at a time and wait for that
            // 8-GiB response to finish before the configured idle gap and the
            // next stream. The same QUIC connection is reused for all streams.
            if (Connection.ConnectToServer(Endpoint.ServerName, Port) &&
                Connection.SendHttpRequestsP5Sequential()) {
                Connection.GetQuicVersion(QuicVersionUsed);
                Connection.GetNegotiatedAlpn(NegotiatedAlpn);
                Success = true;
            }
        } else if (Connection.SendHttpRequests(false) &&
            Connection.ConnectToServer(Endpoint.ServerName, Port) &&
            Connection.WaitForHttpResponses()) {
            Connection.GetQuicVersion(QuicVersionUsed);
            Connection.GetNegotiatedAlpn(NegotiatedAlpn);
            if (Feature == ZeroRtt) {
                Success = Connection.UsedZeroRtt();
            } else {
                Success = true;
            }
        }
'''

replace_once(old_stream_data, new_stream_data, "StreamData execution")

path.write_text(text, encoding="utf-8")
print(f"P5 source transform applied: {path}")
