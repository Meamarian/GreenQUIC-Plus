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
# The actual GreenQuicConfigureRoles loop uses uint32_t, not uint16_t.
role_loop = 'for (uint16_t Index = 0; Index < RTE_MAX_LCORE; ++Index)'
role_loop_fixed = 'for (uint32_t Index = 0; Index < RTE_MAX_LCORE; ++Index)'
role_count = src.count(role_loop)
if role_count != 2:
    raise SystemExit(f'ERROR: V1 role-map loop anchor count={role_count}, expected 2')
src = src.replace(role_loop, role_loop_fixed)

# V1 used the first token occurrence when finding function boundaries. The live
# datapath also contains prototypes, so resolve actual definitions instead.
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

# In the current datapath, Interface is declared before packet metadata is
# finalized and Dpdk is declared later. Do not require the declarations to be
# adjacent. Also rewrite the old shared-ring uses BEFORE inserting the new
# selector, otherwise a global replacement can corrupt the selector fallback
# into "TxRing = ... : TxRing".
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
new_enqueue = r'''# Interface and Dpdk are not adjacent in the current source. Require both, but
# insert routing after Dpdk becomes available (Interface is already in scope).
interface_decl = "    DPDK_INTERFACE* Interface = Packet->Interface;\n"
dpdk_decl = "    DPDK_DATAPATH* Dpdk = Packet->Dpdk;\n"
if interface_decl not in body or dpdk_decl not in body:
    raise SystemExit("ERROR: TxEnqueue Dpdk/Interface declarations changed")

# Rewrite only the pre-existing shared-ring accesses. Do this before inserting
# the selector so its deliberate queue-0 fallback remains Interface->TxRingBuffer.
body = body.replace("Interface->TxRingBuffer", "TxRing")
body = body.replace("GreenQuicSignalTxWork(Dpdk);", "GreenQuicSignalTxQueueWork(Dpdk, TxQueueId);")
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

# CxPlatDpdkTx currently receives Interface as a function argument:
#   CxPlatDpdkTx(DPDK_DATAPATH* Dpdk, uint16_t Core, DPDK_INTERFACE* Interface)
# There is therefore no local "DPDK_INTERFACE* Interface = ..." declaration.
# Adapt V1 to insert queue-local state after the existing Buffers declaration.
# Also replace the *actual* current one-owner guard while preserving its
# GreenQuicOnTxPoll bookkeeping for a non-owner lcore.
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

# Interface is a function parameter in the current datapath. Insert the queue
# id/ring immediately after the existing local TX burst buffer declaration.
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

with tempfile.NamedTemporaryFile('w', suffix='.py', delete=False, encoding='utf-8') as f:
    f.write(src)
    tmp = Path(f.name)
try:
    subprocess.run([sys.executable, str(tmp), sys.argv[1]], check=True)
finally:
    tmp.unlink(missing_ok=True)
