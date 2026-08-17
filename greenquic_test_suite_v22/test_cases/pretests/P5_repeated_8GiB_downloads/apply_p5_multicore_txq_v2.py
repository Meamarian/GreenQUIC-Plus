#!/usr/bin/env python3
from __future__ import annotations
from pathlib import Path
import subprocess, sys, tempfile

if len(sys.argv) != 2:
    raise SystemExit('usage: apply_p5_multicore_txq_v2.py PATH_TO_DATAPATH')

here = Path(__file__).resolve().parent
base = here / 'apply_p5_multicore_txq.py'
src = base.read_text(encoding='utf-8')

# V2 compatibility fixes for the current Performance2 source. Keep the original
# V1 transform readable, but adapt anchors that drifted in the live datapath.
role_loop = 'for (uint16_t Index = 0; Index < RTE_MAX_LCORE; ++Index)'
role_loop_fixed = 'for (uint32_t Index = 0; Index < RTE_MAX_LCORE; ++Index)'
role_count = src.count(role_loop)
if role_count != 2:
    raise SystemExit(f'ERROR: V1 role-map loop anchor count={role_count}, expected 2')
src = src.replace(role_loop, role_loop_fixed)

old_slice = '''def function_slice(name: str, next_name: str) -> tuple[int, int, str]:
    start = text.find(name)
    if start < 0:
        raise SystemExit(f"ERROR: function anchor missing: {name}")
    # Walk back to the nearest static/IRQL declaration so replacements remain
    # scoped to the intended C function.
    back = max(text.rfind("\\nstatic", 0, start), text.rfind("\\n_IRQL", 0, start))
    if back >= 0:
        start = back + 1
    end = text.find(next_name, start + len(name))
    if end < 0:
        raise SystemExit(f"ERROR: next function anchor missing after {name}: {next_name}")
    return start, end, text[start:end]
'''
new_slice = '''def function_slice(name: str, next_name: str) -> tuple[int, int, str]:
    def definition_pos(token: str, after: int = 0) -> int:
        pos = text.find(token, after)
        while pos >= 0:
            brace = text.find("{", pos + len(token))
            semi = text.find(";", pos + len(token))
            if brace >= 0 and (semi < 0 or brace < semi):
                return pos
            pos = text.find(token, pos + len(token))
        return -1
    anchor = definition_pos(name)
    if anchor < 0:
        raise SystemExit(f"ERROR: function definition missing: {name}")
    back = max(text.rfind("\\nstatic", 0, anchor), text.rfind("\\n_IRQL", 0, anchor))
    start = back + 1 if back >= 0 else anchor
    next_anchor = definition_pos(next_name, anchor + len(name))
    if next_anchor < 0:
        raise SystemExit(f"ERROR: next function definition missing after {name}: {next_name}")
    next_back = max(text.rfind("\\nstatic", start, next_anchor), text.rfind("\\n_IRQL", start, next_anchor))
    end = next_back + 1 if next_back >= start else next_anchor
    return start, end, text[start:end]
'''
if src.count(old_slice) != 1:
    raise SystemExit(f'ERROR: V1 function_slice anchor count={src.count(old_slice)}')
src = src.replace(old_slice, new_slice, 1)

# Performance2 sharded handoff replaces the shared-ring producer call before
# this transform runs. Accept that known shape; N intentionally remains a
# single DPDK consumer, so its producer SPSC rings must not be remapped to
# multiple queue-local consumer rings.
old_enqueue_guard = '''if "Interface->TxRingBuffer" not in body:
    raise SystemExit("ERROR: TxEnqueue no longer contains shared ring anchor")
'''
new_enqueue_guard = '''if (
    "Interface->TxRingBuffer" not in body and
    "GreenQuicP2TxEnqueue(" not in body
):
    raise SystemExit("ERROR: TxEnqueue contains neither shared-ring nor sharded handoff shape")
'''
if src.count(old_enqueue_guard) != 1:
    raise SystemExit(f'ERROR: V1 TxEnqueue guard count={src.count(old_enqueue_guard)}')
src = src.replace(old_enqueue_guard, new_enqueue_guard, 1)

old_enqueue = r'''# Declare routing immediately after Dpdk/Interface are available. Performance2
# may add diagnostics around this point, so anchor only the common declarations.
decl = "    DPDK_DATAPATH* Dpdk = Packet->Dpdk;\n    DPDK_INTERFACE* Interface = Packet->Interface;\n"
if decl not in body:
    raise SystemExit("ERROR: TxEnqueue Dpdk/Interface declarations changed")
body = body.replace(
    decl,
    decl +
    "    const uint16_t TxQueueId = GreenQuicSelectTxQueue(Dpdk, Packet->Mbuf);\n"
    "    struct rte_ring* TxRing =\n"
    "        TxQueueId < RTE_MAX_LCORE && Interface->TxRingByQueue[TxQueueId] != NULL ?\n"
    "            Interface->TxRingByQueue[TxQueueId] : Interface->TxRingBuffer;\n",
    1,
)
body = body.replace("Interface->TxRingBuffer", "TxRing")
body = body.replace("GreenQuicSignalTxWork(Dpdk);", "GreenQuicSignalTxQueueWork(Dpdk, TxQueueId);")
'''
new_enqueue = r'''# Performance2 has two producer handoff shapes. Shared mode is mapped to the
# queue selected from the packet flow. Sharded mode is used only by the N
# single-consumer experiment; preserve its per-producer SPSC handoff exactly.
interface_decl = "    DPDK_INTERFACE* Interface = Packet->Interface;\n"
dpdk_decl = "    DPDK_DATAPATH* Dpdk = Packet->Dpdk;\n"
if interface_decl not in body or dpdk_decl not in body:
    raise SystemExit("ERROR: TxEnqueue Dpdk/Interface declarations changed")

if "GreenQuicP2TxEnqueue(" not in body:
    # Rewrite only the pre-existing shared-ring accesses. Do this before
    # inserting the selector so its deliberate queue-0 fallback remains the
    # original Interface->TxRingBuffer.
    body = body.replace("Interface->TxRingBuffer", "TxRing")
    body = body.replace(
        "GreenQuicSignalTxWork(Dpdk);",
        "GreenQuicSignalTxQueueWork(Dpdk, TxQueueId);",
    )
    body = body.replace(
        dpdk_decl,
        dpdk_decl +
        "    const uint16_t TxQueueId = GreenQuicSelectTxQueue(Dpdk, Packet->Mbuf);\n"
        "    struct rte_ring* TxRing =\n"
        "        TxQueueId < RTE_MAX_LCORE && Interface->TxRingByQueue[TxQueueId] != NULL ?\n"
        "            Interface->TxRingByQueue[TxQueueId] : Interface->TxRingBuffer;\n",
        1,
    )
'''
if src.count(old_enqueue) != 1:
    raise SystemExit(f'ERROR: V1 TxEnqueue compatibility block count={src.count(old_enqueue)}')
src = src.replace(old_enqueue, new_enqueue, 1)

old_tx_consumer = r'''# Replace the old one-owner guard if it survived Performance2.
body = body.replace(
    "    if (Dpdk->GreenQuicEnableMultiCore &&\n"
    "        Core != Dpdk->GreenQuicTxOwnerLcore) {\n"
    "        return;\n"
    "    }\n",
    "    if (Dpdk->GreenQuicEnableMultiCore && !GreenQuicLcoreOwnsTx(Dpdk, Core)) {\n"
    "        return;\n"
    "    }\n",
)
# Insert queue/ring declarations after Interface.
anchor = "    DPDK_INTERFACE* Interface = &Dpdk->Interface;\n"
if anchor not in body:
    raise SystemExit("ERROR: CxPlatDpdkTx Interface declaration changed")
body = body.replace(
    anchor,
    anchor +
    "    const uint16_t TxQueueId = GreenQuicGetTxQueueId(Dpdk, Core);\n"
    "    struct rte_ring* TxRing = GreenQuicGetTxRing(Dpdk, Interface, Core);\n",
    1,
)
'''
new_tx_consumer = r'''# Replace the current one-owner guard with queue-map ownership. Keep the
# existing policy bookkeeping for a lcore that truly has no TX queue.
current_guard = (
    "    if (\n"
    "        Dpdk->GreenQuicEnableMultiCore &&\n"
    "        Core != Dpdk->GreenQuicTxOwnerLcore) {\n"
    "        if (Dpdk->GreenQuicMode != GREENQUIC_MODE_OFF) {\n"
    "            GreenQuicOnTxPoll(Dpdk, Core, 0, 0, 0);\n"
    "        }\n"
    "        return;\n"
    "    }\n"
)
legacy_guard = (
    "    if (Dpdk->GreenQuicEnableMultiCore &&\n"
    "        Core != Dpdk->GreenQuicTxOwnerLcore) {\n"
    "        return;\n"
    "    }\n"
)
new_guard = (
    "    if (Dpdk->GreenQuicEnableMultiCore && !GreenQuicLcoreOwnsTx(Dpdk, Core)) {\n"
    "        if (Dpdk->GreenQuicMode != GREENQUIC_MODE_OFF) {\n"
    "            GreenQuicOnTxPoll(Dpdk, Core, 0, 0, 0);\n"
    "        }\n"
    "        return;\n"
    "    }\n"
)
if current_guard in body:
    body = body.replace(current_guard, new_guard, 1)
elif legacy_guard in body:
    body = body.replace(legacy_guard, new_guard, 1)
else:
    raise SystemExit("ERROR: CxPlatDpdkTx one-owner guard shape changed")

anchor = "    struct rte_mbuf* Buffers[Dpdk->TxBurstSize];\n"
if body.count(anchor) != 1:
    raise SystemExit(
        f"ERROR: CxPlatDpdkTx Buffers declaration count={body.count(anchor)}, expected 1"
    )
body = body.replace(
    anchor,
    anchor +
    "    const uint16_t TxQueueId = GreenQuicGetTxQueueId(Dpdk, Core);\n"
    "    struct rte_ring* TxRing = GreenQuicGetTxRing(Dpdk, Interface, Core);\n",
    1,
)
'''
if src.count(old_tx_consumer) != 1:
    raise SystemExit(
        f'ERROR: V1 CxPlatDpdkTx compatibility block count={src.count(old_tx_consumer)}'
    )
src = src.replace(old_tx_consumer, new_tx_consumer, 1)

# Performance2 sharded handoff intentionally replaces shared-ring backlog reads
# with GreenQuicP2TxBacklog(), which includes the producer SPSC rings. N is a
# single-DPDK-consumer experiment, so preserving that aggregate backlog helper is
# the correct composition. For normal/shared builds, keep V1's per-owner ring
# rewrite unchanged. Fail closed if neither known shape is present.
old_policy = r'''# Policy/idle logic must observe each owner's local software ring rather than
# queue 0. These functions are untouched by the Performance2 hot-path patchers.
for fn, nxt in (
    ("GreenQuicCanEnterWorkWait(", "GreenQuicSignalLcoreWork("),
    ("GreenQuicTryCStateIdle(", "GreenQuicOnRxPoll("),
    ("GreenQuicApplyPolicy(", "GreenQuicMaybePrintStats("),
):
    replace_in_function(
        fn,
        nxt,
        "rte_ring_count(Interface->TxRingBuffer)",
        "rte_ring_count(GreenQuicGetTxRing(Dpdk, Interface, Core))",
        f"local TX ring in {fn}",
    )
'''
new_policy = r'''# Policy/idle backlog can arrive in two validated shapes.
for fn, nxt in (
    ("GreenQuicCanEnterWorkWait(", "GreenQuicSignalLcoreWork("),
    ("GreenQuicTryCStateIdle(", "GreenQuicOnRxPoll("),
    ("GreenQuicApplyPolicy(", "GreenQuicMaybePrintStats("),
):
    start, end, body = function_slice(fn, nxt)
    shared_ring = "rte_ring_count(Interface->TxRingBuffer)"
    sharded_backlog = "GreenQuicP2TxBacklog(Interface)"
    if shared_ring in body:
        replace_in_function(
            fn,
            nxt,
            shared_ring,
            "rte_ring_count(GreenQuicGetTxRing(Dpdk, Interface, Core))",
            f"local TX ring in {fn}",
        )
    elif sharded_backlog in body:
        # Preserve aggregate sharded backlog. This build is exercised only by
        # the safe single-consumer N case.
        pass
    else:
        raise SystemExit(
            f"ERROR: TX backlog shape in {fn}: expected shared ring or sharded helper"
        )
'''
if src.count(old_policy) != 1:
    raise SystemExit(f'ERROR: V1 policy/backlog compatibility block count={src.count(old_policy)}')
src = src.replace(old_policy, new_policy, 1)

# The V1 ring-creation anchor included the following "// Set MTU" line. UDP
# segmentation inserts capability setup immediately after GreenQuicConfigureRoles,
# so that literal adjacency no longer exists. Match only the role-discovery call
# and leave whatever follows it (UDP setup or MTU) in place.
old_extra_head = '''replace_once(
    "    GreenQuicConfigureRoles(\\n"
    "        Dpdk, &DeviceInfo, &PortConfig, &rx_rings, &tx_rings);\\n\\n"
    "    // Set MTU\\n",
'''
new_extra_head = '''roles_anchor = (
    "    GreenQuicConfigureRoles(\\n"
    "        Dpdk, &DeviceInfo, &PortConfig, &rx_rings, &tx_rings);\\n"
)
replace_once(
    roles_anchor,
'''
if src.count(old_extra_head) != 1:
    raise SystemExit(f'ERROR: V1 extra-ring anchor head count={src.count(old_extra_head)}')
src = src.replace(old_extra_head, new_extra_head, 1)

old_extra_replacement_head = '''    "    GreenQuicConfigureRoles(\\n"
    "        Dpdk, &DeviceInfo, &PortConfig, &rx_rings, &tx_rings);\\n\\n"
'''
new_extra_replacement_head = '''    roles_anchor +
    "\\n"
'''
# Only the replacement half should be changed now; the original half was
# consumed by old_extra_head above.
if src.count(old_extra_replacement_head) != 1:
    raise SystemExit(
        f'ERROR: V1 extra-ring replacement head count={src.count(old_extra_replacement_head)}'
    )
src = src.replace(old_extra_replacement_head, new_extra_replacement_head, 1)

old_extra_tail = '''    "    }\\n\\n"
    "    // Set MTU\\n",
    "extra multicore software TX rings",
)
'''
new_extra_tail = '''    "    }\\n",
    "extra multicore software TX rings",
)
'''
if src.count(old_extra_tail) != 1:
    raise SystemExit(f'ERROR: V1 extra-ring replacement tail count={src.count(old_extra_tail)}')
src = src.replace(old_extra_tail, new_extra_tail, 1)

with tempfile.NamedTemporaryFile('w', suffix='.py', delete=False, encoding='utf-8') as f:
    f.write(src)
    tmp = Path(f.name)
try:
    subprocess.run([sys.executable, str(tmp), sys.argv[1]], check=True)
finally:
    tmp.unlink(missing_ok=True)
