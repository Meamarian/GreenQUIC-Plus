/*++

    GreenQUIC Plus public hint API, v18 optional multi-core path.

    QUIC core events target a DPDK lcore through:
        MsQuic partition -> configured DPDK lcore.

    Recovery is reference-counted per mapped lcore.

--*/

#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define GQPLUS_LCORE_UNKNOWN              ((uint16_t)0xffffu)
#define GQPLUS_PARTITION_UNKNOWN          ((uint16_t)0xffffu)

#define GQPLUS_HINT_ACK_PENDING             (1ull << 0)
#define GQPLUS_HINT_CUBIC_CWND_BLOCKED     (1ull << 1)
#define GQPLUS_HINT_CUBIC_RECOVERY         (1ull << 2)
#define GQPLUS_HINT_CUBIC_RAMPING          (1ull << 3)
#define GQPLUS_HINT_SERVER_FILE_TX_ACTIVE  (1ull << 16)
#define GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE  (1ull << 17)

/* GREENQUIC-STRICT-OFF-V1: process-wide runtime gate; enabled only in PLUS mode. */
void CxPlatGreenQuicPlusSetRuntimeEnabled(int Enabled);
int CxPlatGreenQuicPlusRuntimeEnabled(void);

void CxPlatGreenQuicPlusSetThreadLcore(uint16_t Lcore);
void CxPlatGreenQuicPlusClearThreadLcore(void);
void CxPlatGreenQuicPlusSetPartitionDpdkLcore(uint16_t Partition, uint16_t Lcore);
uint16_t CxPlatGreenQuicPlusGetPartitionDpdkLcore(uint16_t Partition);

void CxPlatGreenQuicPlusSetHints(uint64_t Hints);
void CxPlatGreenQuicPlusClearHints(uint64_t Hints);
void CxPlatGreenQuicPlusBeginTransfer(uint64_t Hints);
void CxPlatGreenQuicPlusEndTransfer(uint64_t Hints);
void CxPlatGreenQuicPlusBeginRecovery(void);
void CxPlatGreenQuicPlusEndRecovery(void);
void CxPlatGreenQuicPlusBeginRecoveryForPartition(uint16_t Partition);
void CxPlatGreenQuicPlusEndRecoveryForPartition(uint16_t Partition);

void CxPlatGreenQuicPlusPulseHints(uint64_t Hints);
void CxPlatGreenQuicPlusPulseHintsForLcore(uint16_t Lcore, uint64_t Hints);
void CxPlatGreenQuicPlusPulseHintsForPartition(uint16_t Partition, uint64_t Hints);

uint64_t CxPlatGreenQuicPlusGetHints(void);
uint64_t CxPlatGreenQuicPlusGetTxHints(void);
uint64_t CxPlatGreenQuicPlusGetHintsForLcore(uint16_t Lcore, int IncludeUnknownGlobalHints);

#ifdef __cplusplus
}
#endif
