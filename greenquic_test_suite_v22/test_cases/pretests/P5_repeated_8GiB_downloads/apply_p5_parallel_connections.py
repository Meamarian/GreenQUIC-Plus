#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import sys

MARKER = "GREENQUIC-P5-PARALLEL-CONNECTIONS-V1"

if len(sys.argv) != 2:
    raise SystemExit("usage: apply_p5_parallel_connections.py PATH_TO_INTEROP_CPP")

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

if MARKER in text:
    print(f"{MARKER} already present: {path}")
    raise SystemExit(0)


def replace_once(old: str, new: str, label: str) -> None:
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(
            f"ERROR: expected exactly one {label} anchor, found {count}; "
            "refusing to modify an unexpected interop.cpp"
        )
    text = text.replace(old, new, 1)


# apply_p5_sequence.py has already added <thread>. Keep the transform usable
# only on that known P5 source so the two workload modes cannot silently drift.
replace_once(
    "#include <fstream>\n#include <thread>\n\nnamespace fs = std::filesystem;\n",
    "#include <fstream>\n#include <thread>\n#include <atomic>\n#include <memory>\n\nnamespace fs = std::filesystem;\n",
    "P5 sequential include block",
)

# Add one-request support to InteropConnection. Each parallel worker owns one
# InteropConnection and one InteropStream; no MsQuic/DPDK process is duplicated.
replace_once(
    r'''    bool WaitForHttpResponses() {
        bool Result = true;
''',
    r'''    // GREENQUIC-P5-PARALLEL-CONNECTIONS-V1
    bool SetLocalPort(uint16_t LocalPort) {
        QUIC_ADDR LocalAddress = {0};
        QuicAddrSetFamily(&LocalAddress, QUIC_ADDRESS_FAMILY_INET);
        QuicAddrSetPort(&LocalAddress, LocalPort);
        return QUIC_SUCCEEDED(
            MsQuic->SetParam(
                Connection,
                QUIC_PARAM_CONN_LOCAL_ADDRESS,
                sizeof(LocalAddress),
                &LocalAddress));
    }

    bool SendOneHttpRequest(const std::string& Url) {
        InteropStream* Stream = new InteropStream(Connection, Url.c_str());
        Streams.push_back(Stream);
        return Stream->SendHttpRequest(true);
    }

    bool WaitForHttpResponses() {
        bool Result = true;
''',
    "InteropConnection WaitForHttpResponses",
)

# Insert the parallel workload after the InteropConnection class and before
# RunInteropTest. A fixed, configurable local UDP port per connection makes the
# 5-tuples deliberately distinct. This is required for a meaningful two-queue
# RSS experiment in both DPDK and Linux.
replace_once(
    r'''bool
RunInteropTest(
''',
    r'''// GREENQUIC-P5-PARALLEL-CONNECTIONS-V1
static bool
GreenQuicP5ParallelEnabled()
{
    const char* Value = getenv("GQ_INTEROP_P5_PARALLEL");
    return Value != nullptr && Value[0] != '\0' && strcmp(Value, "0") != 0;
}

static uint32_t
GreenQuicP5ParallelEnvU32(const char* Name, uint32_t DefaultValue)
{
    const char* Value = getenv(Name);
    if (Value == nullptr || Value[0] == '\0') {
        return DefaultValue;
    }
    char* End = nullptr;
    const unsigned long Parsed = strtoul(Value, &End, 10);
    if (End == Value || *End != '\0' || Parsed > UINT32_MAX) {
        printf("[GreenQUIC-PARALLEL] invalid %s=%s\n", Name, Value);
        return DefaultValue;
    }
    return (uint32_t)Parsed;
}

static bool
GreenQuicP5WaitForStartGate()
{
    const char* GatePath = getenv("GQ_INTEROP_P5_START_GATE");
    if (GatePath == nullptr || GatePath[0] == '\0') {
        return true;
    }
    const uint64_t TimeoutUs =
        GreenQuicP5EnvUs("GQ_INTEROP_P5_GATE_TIMEOUT_US", 120000000);
    const uint64_t ReadyUs = GreenQuicP5MonotonicUs();
    printf(
        "[GreenQUIC-P5] ready_for_start_gate_us=%llu gate=%s\n",
        (unsigned long long)ReadyUs,
        GatePath);
    fflush(stdout);
    while (!fs::exists(GatePath)) {
        if (GreenQuicP5MonotonicUs() - ReadyUs >= TimeoutUs) {
            printf(
                "[GreenQUIC-P5] start_gate_timeout_us=%llu gate=%s\n",
                (unsigned long long)TimeoutUs,
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
    return true;
}

static bool
GreenQuicP5RunParallelConnections(
    HQUIC Configuration,
    const char* ServerName,
    uint16_t ServerPort
    )
{
    const uint32_t Requested = GreenQuicP5ParallelEnvU32(
        "GQ_INTEROP_P5_PARALLEL_CONNECTIONS",
        (uint32_t)Urls.size());
    const uint32_t BaseLocalPort = GreenQuicP5ParallelEnvU32(
        "GQ_INTEROP_P5_LOCAL_PORT_BASE",
        45000);
    const uint64_t ReadyTimeoutUs = GreenQuicP5EnvUs(
        "GQ_INTEROP_P5_PARALLEL_READY_TIMEOUT_US",
        120000000);

    if (Requested < 2 || Requested > Urls.size()) {
        printf(
            "[GreenQUIC-PARALLEL] invalid connections=%u urls=%zu; "
            "need 2..urls\n",
            Requested,
            Urls.size());
        return false;
    }
    if (BaseLocalPort == 0 || BaseLocalPort + Requested - 1 > 65535) {
        printf(
            "[GreenQUIC-PARALLEL] invalid local_port_base=%u connections=%u\n",
            BaseLocalPort,
            Requested);
        return false;
    }

    std::atomic<uint32_t> Ready{0};
    std::atomic<uint32_t> Connected{0};
    std::atomic<uint32_t> Completed{0};
    std::atomic<bool> Go{false};
    std::atomic<bool> Failed{false};
    std::vector<std::thread> Workers;
    Workers.reserve(Requested);

    printf(
        "[GreenQUIC-PARALLEL] marker=%s connections=%u "
        "local_port_base=%u urls=%zu\n",
        "GREENQUIC-P5-PARALLEL-CONNECTIONS-V1",
        Requested,
        BaseLocalPort,
        Urls.size());
    fflush(stdout);

    for (uint32_t Index = 0; Index < Requested; ++Index) {
        Workers.emplace_back([&, Index]() {
            const uint16_t LocalPort = (uint16_t)(BaseLocalPort + Index);
            InteropConnection Connection(Configuration, false);
            bool Ok = Connection.SetLocalPort(LocalPort);
            if (Ok) {
                Ok = Connection.ConnectToServer(ServerName, ServerPort);
            }
            if (Ok) {
                Connected.fetch_add(1, std::memory_order_relaxed);
            } else {
                Failed.store(true, std::memory_order_release);
            }
            Ready.fetch_add(1, std::memory_order_release);

            while (!Go.load(std::memory_order_acquire) &&
                   !Failed.load(std::memory_order_acquire)) {
                std::this_thread::sleep_for(std::chrono::microseconds(100));
            }
            if (!Ok || Failed.load(std::memory_order_acquire)) {
                return;
            }

            const uint64_t StartUs = GreenQuicP5MonotonicUs();
            printf(
                "[GreenQUIC-PARALLEL] conn=%u/%u start_us=%llu "
                "local_port=%u path=%s\n",
                Index + 1,
                Requested,
                (unsigned long long)StartUs,
                LocalPort,
                Urls[Index].c_str());
            fflush(stdout);

            Ok = Connection.SendOneHttpRequest(Urls[Index]);
            const uint64_t CompleteUs = GreenQuicP5MonotonicUs();
            if (Ok) {
                Completed.fetch_add(1, std::memory_order_relaxed);
            } else {
                Failed.store(true, std::memory_order_release);
            }
            printf(
                "[GreenQUIC-PARALLEL] conn=%u/%u complete_us=%llu "
                "duration_us=%llu success=%d local_port=%u path=%s\n",
                Index + 1,
                Requested,
                (unsigned long long)CompleteUs,
                (unsigned long long)(CompleteUs - StartUs),
                Ok ? 1 : 0,
                LocalPort,
                Urls[Index].c_str());
            fflush(stdout);
        });
    }

    const uint64_t ReadyStartUs = GreenQuicP5MonotonicUs();
    while (Ready.load(std::memory_order_acquire) != Requested) {
        if (GreenQuicP5MonotonicUs() - ReadyStartUs >= ReadyTimeoutUs) {
            Failed.store(true, std::memory_order_release);
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }

    if (!Failed.load(std::memory_order_acquire) &&
        Connected.load(std::memory_order_acquire) == Requested) {
        if (!GreenQuicP5WaitForStartGate()) {
            Failed.store(true, std::memory_order_release);
        }
    }

    const uint64_t BatchStartUs = GreenQuicP5MonotonicUs();
    printf(
        "[GreenQUIC-PARALLEL] batch=1 start_us=%llu connections=%u\n",
        (unsigned long long)BatchStartUs,
        Requested);
    fflush(stdout);
    Go.store(true, std::memory_order_release);

    for (auto& Worker : Workers) {
        Worker.join();
    }

    const uint64_t BatchCompleteUs = GreenQuicP5MonotonicUs();
    const bool Success =
        !Failed.load(std::memory_order_acquire) &&
        Completed.load(std::memory_order_acquire) == Requested;
    printf(
        "[GreenQUIC-PARALLEL] batch=1 complete_us=%llu duration_us=%llu "
        "connections=%u connected=%u completed=%u success=%d\n",
        (unsigned long long)BatchCompleteUs,
        (unsigned long long)(BatchCompleteUs - BatchStartUs),
        Requested,
        Connected.load(std::memory_order_relaxed),
        Completed.load(std::memory_order_relaxed),
        Success ? 1 : 0);
    fflush(stdout);
    return Success;
}

bool
RunInteropTest(
''',
    "RunInteropTest declaration",
)

# Parallel mode is checked before the sequential P5 mode. Both are explicit
# environment gates and the normal stock StreamData branch remains unchanged.
replace_once(
    r'''        if (Feature == StreamData && GreenQuicP5SequenceEnabled()) {
            // P5 is intentionally different from the stock StreamData path:
''',
    r'''        if (Feature == StreamData && GreenQuicP5ParallelEnabled()) {
            Success = GreenQuicP5RunParallelConnections(
                Configuration,
                Endpoint.ServerName,
                Port);
        } else if (Feature == StreamData && GreenQuicP5SequenceEnabled()) {
            // P5 is intentionally different from the stock StreamData path:
''',
    "P5 StreamData sequential branch",
)

path.write_text(text, encoding="utf-8")
print(f"P5 parallel-connection transform applied: {path}")
