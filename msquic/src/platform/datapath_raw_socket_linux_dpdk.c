/*++

    Copyright (c) Microsoft Corporation.
    Licensed under the MIT License.

Abstract:

    QUIC raw datapath socket and IP framing abstractions for Linux DPDK

--*/

#include "datapath_raw_linux.h"
#ifdef QUIC_CLOG
#include "datapath_raw_socket_linux.c.clog.h"
#endif

#define SocketError() errno

#pragma warning(disable:4116) // unnamed type definition in parentheses
#pragma warning(disable:4100) // unreferenced formal parameter

//
// Socket Pool Logic
//

BOOLEAN
CxPlatSockPoolInitialize(
    _Inout_ CXPLAT_SOCKET_POOL* Pool
    )
{
    if (!CxPlatHashtableInitializeEx(&Pool->Sockets, CXPLAT_HASH_MIN_SIZE)) {
        return FALSE;
    }
    CxPlatRwLockInitialize(&Pool->Lock);
    return TRUE;
}

void
CxPlatSockPoolUninitialize(
    _Inout_ CXPLAT_SOCKET_POOL* Pool
    )
{
    CxPlatRwLockUninitialize(&Pool->Lock);
    CxPlatHashtableUninitialize(&Pool->Sockets);
}

QUIC_STATUS
ResolveBestL3Route(
    QUIC_ADDR* RemoteAddress,
    QUIC_ADDR* SourceAddress,
    QUIC_ADDR* GatewayAddress,
    int* oif
    )
{
    UNREFERENCED_PARAMETER(RemoteAddress);
    UNREFERENCED_PARAMETER(SourceAddress);
    UNREFERENCED_PARAMETER(GatewayAddress);
    UNREFERENCED_PARAMETER(oif);
    QUIC_STATUS Status = QUIC_STATUS_SUCCESS;

    return Status;
}

_IRQL_requires_max_(PASSIVE_LEVEL)
QUIC_STATUS
RawResolveRoute(
    _In_ CXPLAT_SOCKET_RAW* Socket,
    _Inout_ CXPLAT_ROUTE* Route,
    _In_ uint8_t PathId,
    _In_ void* Context,
    _In_ CXPLAT_ROUTE_RESOLUTION_CALLBACK_HANDLER Callback
    )
{
    UNREFERENCED_PARAMETER(Callback);
    QUIC_STATUS Status = QUIC_STATUS_SUCCESS;

    CXPLAT_DBG_ASSERT(!QuicAddrIsWildCard(&Route->RemoteAddress));

    Route->State = RouteResolving;

    QuicTraceEvent(
        DatapathGetRouteStart,
        "[data][%p] Querying route, local=%!ADDR!, remote=%!ADDR!",
        Socket,
        CASTED_CLOG_BYTEARRAY(sizeof(Route->LocalAddress), &Route->LocalAddress),
        CASTED_CLOG_BYTEARRAY(sizeof(Route->RemoteAddress), &Route->RemoteAddress));

    // just use the first interface here
    CXPLAT_LIST_ENTRY* Entry = Socket->RawDatapath->Interfaces.Flink;
    CXPLAT_INTERFACE* Interface = CXPLAT_CONTAINING_RECORD(Entry, CXPLAT_INTERFACE, Link);
    CXPLAT_DBG_ASSERT(sizeof(Interface->PhysicalAddress) == sizeof(Route->LocalLinkLayerAddress));
    CxPlatCopyMemory(&Route->LocalLinkLayerAddress, Interface->PhysicalAddress, sizeof(Route->LocalLinkLayerAddress));
    CxPlatDpRawAssignQueue(Interface, Route);

    // remote MAC
    CXPLAT_DBG_ASSERT(sizeof(Interface->PeerPhysicalAddress) == sizeof(Route->NextHopLinkLayerAddress));
    CxPlatCopyMemory(&Route->NextHopLinkLayerAddress, Interface->PeerPhysicalAddress, sizeof(Route->NextHopLinkLayerAddress));

    CxPlatResolveRouteComplete(Context, Route, Route->NextHopLinkLayerAddress, PathId);

    return Status;
}

