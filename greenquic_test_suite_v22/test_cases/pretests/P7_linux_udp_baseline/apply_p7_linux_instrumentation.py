#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit('usage: apply_p7_linux_instrumentation.py MSQUIC_SOURCE_ROOT')

root = Path(sys.argv[1]).resolve()
server_h = root / 'src/tools/interopserver/InteropServer.h'
server_cpp = root / 'src/tools/interopserver/InteropServer.cpp'
datapath = root / 'src/platform/datapath_epoll.c'
raw_h = root / 'src/platform/datapath_raw.h'
xplat = root / 'src/platform/datapath_xplat.c'
for p in (server_h, server_cpp, datapath, raw_h, xplat):
    if not p.is_file():
        raise SystemExit(f'ERROR: expected source file missing: {p}')


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'ERROR: {label}: expected exactly one anchor, found {count}')
    return text.replace(old, new, 1)

rh = raw_h.read_text(encoding='utf-8')
if 'GREENQUIC-P7-NO-DPDK-HEADER-LEAK-V1' not in rh:
    rh = replace_once(
        rh,
        '#include "quic_hashtable.h"\n#include <rte_memcpy.h>\n\n// NOTE: this works only with DPDK\n#undef CxPlatCopyMemory\n#define CxPlatCopyMemory(Destination, Source, Length) rte_memcpy((Destination), (Source), (Length))\n',
        '#include "quic_hashtable.h"\n\n/* GREENQUIC-P7-NO-DPDK-HEADER-LEAK-V1\n'
        ' * The normal Linux build uses datapath_raw_dummy.c only as a stub.\n'
        ' * Keep the platform CxPlatCopyMemory implementation and do not pull\n'
        ' * DPDK headers into this isolated non-DPDK build.\n'
        ' */\n',
        'P7 remove private-branch DPDK header leak',
    )
    raw_h.write_text(rh, encoding='utf-8')

xp = xplat.read_text(encoding='utf-8')
if 'GREENQUIC-P7-NORMAL-LINUX-SOCKET-V1' not in xp:
    xp = replace_once(
        xp,
        'CxPlatSocketCreateUdp(\n    _In_ CXPLAT_DATAPATH* Datapath,\n    _In_ const CXPLAT_UDP_CONFIG* Config,\n    _Out_ CXPLAT_SOCKET** NewSocket\n    )\n{\n    QUIC_STATUS Status = QUIC_STATUS_SUCCESS;\n',
        'CxPlatSocketCreateUdp(\n    _In_ CXPLAT_DATAPATH* Datapath,\n    _In_ const CXPLAT_UDP_CONFIG* Config,\n    _Out_ CXPLAT_SOCKET** NewSocket\n    )\n{\n    /* GREENQUIC-P7-NORMAL-LINUX-SOCKET-V1\n     * The private DPDK branch\'s combined socket allocation is only valid when\n     * a raw datapath exists. P7 intentionally builds without DPDK/XDP, so use\n     * the normal Linux UDP socket constructor exactly for that case.\n     */\n    if (Datapath->RawDataPath == NULL) {\n        return SocketCreateUdp(Datapath, Config, NewSocket);\n    }\n\n    QUIC_STATUS Status = QUIC_STATUS_SUCCESS;\n',
        'P7 restore normal Linux UDP socket construction',
    )
    xplat.write_text(xp, encoding='utf-8')

h = server_h.read_text(encoding='utf-8')
if 'GREENQUIC-P7-SERVER-TIMELINE-V1' not in h:
    h = replace_once(
        h,
        '    bool GreenQuicServerTxHintActive;\nprivate:\n',
        '    bool GreenQuicServerTxHintActive;\n'
        '    // GREENQUIC-P7-SERVER-TIMELINE-V1\n'
        '    uint64_t P7RequestIndex;\n'
        '    uint64_t P7RequestStartUs;\n'
        'private:\n',
        'P7 HttpRequest fields',
    )
    server_h.write_text(h, encoding='utf-8')

cpp = server_cpp.read_text(encoding='utf-8')
if 'GREENQUIC-P7-SERVER-TIMELINE-V1' not in cpp:
    cpp = replace_once(cpp, '#include <csignal>\n#include <cstdio>\n', '#include <csignal>\n#include <cstdio>\n#include <atomic>\n#include <time.h>\n', 'P7 server includes')
    cpp = replace_once(cpp, 'const QUIC_API_TABLE* MsQuic;\n\n', '''const QUIC_API_TABLE* MsQuic;\n\n// GREENQUIC-P7-SERVER-TIMELINE-V1\nstatic std::atomic<uint64_t> P7ServerRequestCounter{0};\n\nstatic uint64_t\nP7MonotonicUs()\n{\n    struct timespec Ts;\n    if (clock_gettime(CLOCK_MONOTONIC, &Ts) != 0) {\n        return 0;\n    }\n    return ((uint64_t)Ts.tv_sec * 1000000ull) + ((uint64_t)Ts.tv_nsec / 1000ull);\n}\n\n''', 'P7 server clock helper')
    cpp = replace_once(cpp, '    Shutdown(false), WriteHttp11Header(false), GreenQuicServerTxHintActive(false)\n', '    Shutdown(false), WriteHttp11Header(false), GreenQuicServerTxHintActive(false),\n    P7RequestIndex(0), P7RequestStartUs(0)\n', 'P7 constructor initialization')
    cpp = replace_once(cpp, '    printf("[%s] GET \'%s\'\\n", GetRemoteAddr(MsQuic, QuicStream).Address, PathStart);\n    File = fopen(FullFilePath, "rb"); // In case of failure, SendData still works.\n', '''    P7RequestIndex = P7ServerRequestCounter.fetch_add(1, std::memory_order_relaxed) + 1;\n    P7RequestStartUs = P7MonotonicUs();\n    printf("[%s] GET '%s'\\n", GetRemoteAddr(MsQuic, QuicStream).Address, PathStart);\n    printf(\n        "[GreenQUIC-P7] request=%llu start_us=%llu path=%s\\n",\n        (unsigned long long)P7RequestIndex,\n        (unsigned long long)P7RequestStartUs,\n        PathStart);\n    fflush(stdout);\n    File = fopen(FullFilePath, "rb"); // In case of failure, SendData still works.\n''', 'P7 server request start marker')
    cpp = replace_once(cpp, '    case QUIC_STREAM_EVENT_SHUTDOWN_COMPLETE:\n        if (pThis->GreenQuicServerTxHintActive) {\n', '''    case QUIC_STREAM_EVENT_SHUTDOWN_COMPLETE:\n        if (pThis->P7RequestIndex != 0 && pThis->P7RequestStartUs != 0) {\n            const uint64_t CompleteUs = P7MonotonicUs();\n            printf(\n                "[GreenQUIC-P7] request=%llu complete_us=%llu duration_us=%llu success=1\\n",\n                (unsigned long long)pThis->P7RequestIndex,\n                (unsigned long long)CompleteUs,\n                (unsigned long long)(CompleteUs - pThis->P7RequestStartUs));\n            fflush(stdout);\n        }\n        if (pThis->GreenQuicServerTxHintActive) {\n''', 'P7 server request completion marker')
    server_cpp.write_text(cpp, encoding='utf-8')

dp = datapath.read_text(encoding='utf-8')
if 'GREENQUIC-P7-LINUX-UDP-FEATURE-OBSERVE-V1' not in dp:
    dp = replace_once(dp, '#include <netinet/udp.h>\n', '#include <netinet/udp.h>\n#include <stdio.h>\n', 'P7 datapath include')
    dp = replace_once(
        dp,
        '    if (Datapath->Features & CXPLAT_DATAPATH_FEATURE_SEND_SEGMENTATION) {\n',
        '    /* GREENQUIC-P7-LINUX-UDP-FEATURE-OBSERVE-V1\n'
        '     * Report the result of the stock Linux feature probe without changing it.\n'
        '     */\n'
        '    printf(\n'
        '        "[GreenQUIC-P7] linux_udp_features send_segmentation=%u recv_coalescing=%u mode=stock_auto\\n",\n'
        '        (Datapath->Features & CXPLAT_DATAPATH_FEATURE_SEND_SEGMENTATION) != 0 ? 1U : 0U,\n'
        '        (Datapath->Features & CXPLAT_DATAPATH_FEATURE_RECV_COALESCING) != 0 ? 1U : 0U);\n'
        '    fflush(stdout);\n\n'
        '    if (Datapath->Features & CXPLAT_DATAPATH_FEATURE_SEND_SEGMENTATION) {\n',
        'P7 UDP feature observation',
    )
    datapath.write_text(dp, encoding='utf-8')

print(f'P7 Linux instrumentation applied under {root}')
