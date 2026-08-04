/*++

    Copyright (c) Microsoft Corporation.
    Licensed under the MIT License.

Abstract:

    QUIC Datapath Implementation (User Mode)

--*/

#include "platform_internal.h"

#ifdef QUIC_CLOG
#include "datapath_xplat.c.clog.h"
#endif

_IRQL_requires_max_(PASSIVE_LEVEL)
QUIC_STATUS
CxPlatDataPathInitialize(
    _In_ uint32_t ClientRecvContextLength,
    _In_opt_ const CXPLAT_UDP_DATAPATH_CALLBACKS* UdpCallbacks,
    _In_opt_ const CXPLAT_TCP_DATAPATH_CALLBACKS* TcpCallbacks,
    _In_opt_ QUIC_EXECUTION_CONFIG* Config,
    _Out_ CXPLAT_DATAPATH** NewDataPath
    )
{
    QUIC_STATUS Status = QUIC_STATUS_SUCCESS;
    if (NewDataPath == NULL) {
        Status = QUIC_STATUS_INVALID_PARAMETER;
        goto Error;
    }

    Status =
        DataPathInitialize(
            ClientRecvContextLength,
            UdpCallbacks,
            TcpCallbacks,
            Config,
            NewDataPath);
    if (QUIC_FAILED(Status)) {
        QuicTraceLogVerbose(
            DatapathInitFail,
            "[  dp] Failed to initialize datapath, status:%d", Status);
        goto Error;
    }

    // Initialize raw datapath (required for XDP/DPDK)
    Status =
        RawDataPathInitialize(
            ClientRecvContextLength,
            Config,
            (*NewDataPath),
            &((*NewDataPath)->RawDataPath));
    if (QUIC_FAILED(Status)) {
        QuicTraceLogVerbose(
            RawDatapathInitFail,
            "[ raw] Failed to initialize raw datapath, status:%d", Status);
        Status = QUIC_STATUS_SUCCESS;
        (*NewDataPath)->RawDataPath = NULL;
    }

Error:

    return Status;
}

_IRQL_requires_max_(PASSIVE_LEVEL)
void
CxPlatDataPathUninitialize(
    _In_ CXPLAT_DATAPATH* Datapath
    )
{
    if (Datapath->RawDataPath) {
        RawDataPathUninitialize(Datapath->RawDataPath);
    }
    DataPathUninitialize(Datapath);
}

_IRQL_requires_max_(PASSIVE_LEVEL)
void
CxPlatDataPathUpdateConfig(
    _In_ CXPLAT_DATAPATH* Datapath,
    _In_ QUIC_EXECUTION_CONFIG* Config
    )
{
    DataPathUpdateConfig(Datapath, Config);
    if (Datapath->RawDataPath) {
        RawDataPathUpdateConfig(Datapath->RawDataPath, Config);
    }
}

_IRQL_requires_max_(DISPATCH_LEVEL)
uint32_t
CxPlatDataPathGetSupportedFeatures(
    _In_ CXPLAT_DATAPATH* Datapath
    )
{
    if (Datapath->RawDataPath) {
        return DataPathGetSupportedFeatures(Datapath) |
               RawDataPathGetSupportedFeatures(Datapath->RawDataPath);
    }
    return DataPathGetSupportedFeatures(Datapath);
}

_IRQL_requires_max_(DISPATCH_LEVEL)
BOOLEAN
CxPlatDataPathIsPaddingPreferred(
    _In_ CXPLAT_DATAPATH* Datapath,
    _In_ CXPLAT_SEND_DATA* SendData
    )
{
    CXPLAT_DBG_ASSERT(
        DatapathType(SendData) == CXPLAT_DATAPATH_TYPE_USER ||
        DatapathType(SendData) == CXPLAT_DATAPATH_TYPE_RAW);
    return
        DatapathType(SendData) == CXPLAT_DATAPATH_TYPE_USER ?
            DataPathIsPaddingPreferred(Datapath) : RawDataPathIsPaddingPreferred(Datapath);
}

_IRQL_requires_max_(PASSIVE_LEVEL)
QUIC_STATUS
CxPlatSocketCreateUdp(
    _In_ CXPLAT_DATAPATH* Datapath,
    _In_ const CXPLAT_UDP_CONFIG* Config,
    _Out_ CXPLAT_SOCKET** NewSocket
    )
{
    QUIC_STATUS Status = QUIC_STATUS_SUCCESS;
    const BOOLEAN IsServerSocket = Config->RemoteAddress == NULL;
    const BOOLEAN NumPerProcessorSockets = IsServerSocket && Datapath->PartitionCount > 1;
    const uint16_t SocketCount = NumPerProcessorSockets ? (uint16_t)CxPlatProcCount() : 1;

    CXPLAT_DBG_ASSERT(Datapath->UdpHandlers.Receive != NULL || Config->Flags & CXPLAT_SOCKET_FLAG_PCP);

    const size_t RawBindingLength =
        CxPlatGetRawSocketSize() + SocketCount * sizeof(CXPLAT_SOCKET_CONTEXT);
    CXPLAT_SOCKET_RAW* RawBinding =
        (CXPLAT_SOCKET_RAW*)CXPLAT_ALLOC_PAGED(RawBindingLength, QUIC_POOL_SOCKET);
    if (RawBinding == NULL) {
      Status = QUIC_STATUS_OUT_OF_MEMORY;
      QuicTraceEvent(
          AllocFailure,
          "Allocation of '%s' failed. (%llu bytes)",
          "CXPLAT_SOCKET",
          RawBindingLength);
      goto Error;
    }
    CXPLAT_SOCKET* Binding = CxPlatRawToSocket(RawBinding);

    QuicTraceEvent(
        DatapathCreated,
        "[data][%p] Created, local=%!ADDR!, remote=%!ADDR!",
        Binding,
        CASTED_CLOG_BYTEARRAY(Config->LocalAddress ? sizeof(*Config->LocalAddress) : 0, Config->LocalAddress),
        CASTED_CLOG_BYTEARRAY(Config->RemoteAddress ? sizeof(*Config->RemoteAddress) : 0, Config->RemoteAddress));

    CxPlatZeroMemory(RawBinding, RawBindingLength);
    Binding->Datapath = Datapath;
    Binding->ClientContext = Config->CallbackContext;
    Binding->NumPerProcessorSockets = NumPerProcessorSockets;
    Binding->HasFixedRemoteAddress = (Config->RemoteAddress != NULL);
    Binding->Mtu = CXPLAT_MAX_MTU;
    Binding->Type = CXPLAT_SOCKET_UDP;
    CxPlatRefInitializeEx(&Binding->RefCount, SocketCount);
    if (Config->LocalAddress) {
      CxPlatConvertToMappedV6(Config->LocalAddress, &Binding->LocalAddress);
    } else {
      Binding->LocalAddress.Ip.sa_family = QUIC_ADDRESS_FAMILY_INET6;
    }
    if (Config->Flags & CXPLAT_SOCKET_FLAG_PCP) {
      Binding->PcpBinding = TRUE;
    }

    for (uint32_t i = 0; i < SocketCount; i++) {
      Binding->SocketContexts[i].Binding = Binding;
      Binding->SocketContexts[i].SocketFd = INVALID_SOCKET;
      CxPlatListInitializeHead(&Binding->SocketContexts[i].TxQueue);
      CxPlatLockInitialize(&Binding->SocketContexts[i].TxQueueLock);
      CxPlatRundownInitialize(&Binding->SocketContexts[i].UpcallRundown);
    }

    CxPlatConvertFromMappedV6(&Binding->LocalAddress, &Binding->LocalAddress);
    Binding->LocalAddress.Ipv6.sin6_scope_id = 0;

    if (Config->RemoteAddress != NULL) {
      Binding->RemoteAddress = *Config->RemoteAddress;
    } else {
      Binding->RemoteAddress.Ipv4.sin_port = 0;
    }

    //
    // Must set output pointer before starting receive path, as the receive path
    // will try to use the output.
    //
    *NewSocket = Binding;

    Binding = NULL;
    RawBinding = NULL;

    (*NewSocket)->RawSocketAvailable = 0;
    if (Datapath->RawDataPath) {
        Status =
            RawSocketCreateUdp(
                Datapath->RawDataPath,
                Config,
                CxPlatSocketToRaw(*NewSocket));
        (*NewSocket)->RawSocketAvailable = QUIC_SUCCEEDED(Status);
        if (QUIC_FAILED(Status)) {
            QuicTraceLogVerbose(
                RawSockCreateFail,
                "[sock] Failed to create raw socket, status:%d", Status);
            if (Datapath->UseTcp) {
                CxPlatSocketDelete(*NewSocket);
                goto Error;
            }
            Status = QUIC_STATUS_SUCCESS;
        }
    }

Error:
    return Status;
}

_IRQL_requires_max_(PASSIVE_LEVEL)
QUIC_STATUS
CxPlatSocketCreateTcp(
    _In_ CXPLAT_DATAPATH* Datapath,
    _In_opt_ const QUIC_ADDR* LocalAddress,
    _In_ const QUIC_ADDR* RemoteAddress,
    _In_opt_ void* CallbackContext,
    _Out_ CXPLAT_SOCKET** NewSocket
    )
{
    return SocketCreateTcp(
        Datapath,
        LocalAddress,
        RemoteAddress,
        CallbackContext,
        NewSocket);
}

_IRQL_requires_max_(PASSIVE_LEVEL)
QUIC_STATUS
CxPlatSocketCreateTcpListener(
    _In_ CXPLAT_DATAPATH* Datapath,
    _In_opt_ const QUIC_ADDR* LocalAddress,
    _In_opt_ void* RecvCallbackContext,
    _Out_ CXPLAT_SOCKET** NewSocket
    )
{
    return SocketCreateTcpListener(
        Datapath,
        LocalAddress,
        RecvCallbackContext,
        NewSocket);
}

_IRQL_requires_max_(PASSIVE_LEVEL)
void
CxPlatSocketDelete(
    _In_ CXPLAT_SOCKET* Socket
    )
{
    if (Socket->RawSocketAvailable) {
        RawSocketDelete(CxPlatSocketToRaw(Socket));
    }
    SocketDelete(Socket);
}

_IRQL_requires_max_(DISPATCH_LEVEL)
uint16_t
CxPlatSocketGetLocalMtu(
    _In_ CXPLAT_SOCKET* Socket
    )
{
    CXPLAT_DBG_ASSERT(Socket != NULL);
    if (Socket->UseTcp || (Socket->RawSocketAvailable &&
        !IS_LOOPBACK(Socket->RemoteAddress))) {
        return RawSocketGetLocalMtu(CxPlatSocketToRaw(Socket));
    }
    return Socket->Mtu;
}

_IRQL_requires_max_(DISPATCH_LEVEL)
void
CxPlatSocketGetLocalAddress(
    _In_ CXPLAT_SOCKET* Socket,
    _Out_ QUIC_ADDR* Address
    )
{
    CXPLAT_DBG_ASSERT(Socket != NULL);
    *Address = Socket->LocalAddress;
}

_IRQL_requires_max_(DISPATCH_LEVEL)
void
CxPlatSocketGetRemoteAddress(
    _In_ CXPLAT_SOCKET* Socket,
    _Out_ QUIC_ADDR* Address
    )
{
    CXPLAT_DBG_ASSERT(Socket != NULL);
    *Address = Socket->RemoteAddress;
}

_IRQL_requires_max_(DISPATCH_LEVEL)
void
CxPlatRecvDataReturn(
    _In_opt_ CXPLAT_RECV_DATA* RecvDataChain
    )
{
    if (RecvDataChain == NULL) {
        return;
    }
    CXPLAT_DBG_ASSERT(
        RecvDataChain->DatapathType == CXPLAT_DATAPATH_TYPE_USER ||
        RecvDataChain->DatapathType == CXPLAT_DATAPATH_TYPE_RAW);
    RecvDataChain->DatapathType == CXPLAT_DATAPATH_TYPE_USER ?
        RecvDataReturn(RecvDataChain) : RawRecvDataReturn(RecvDataChain);
}

_IRQL_requires_max_(DISPATCH_LEVEL)
_Success_(return != NULL)
CXPLAT_SEND_DATA*
CxPlatSendDataAlloc(
    _In_ CXPLAT_SOCKET* Socket,
    _Inout_ CXPLAT_SEND_CONFIG* Config
    )
{
    CXPLAT_SEND_DATA* SendData = NULL;
    // TODO: fallback?
    if (Socket->UseTcp || Config->Route->DatapathType == CXPLAT_DATAPATH_TYPE_RAW ||
        (Config->Route->DatapathType == CXPLAT_DATAPATH_TYPE_UNKNOWN &&
        Socket->RawSocketAvailable && !IS_LOOPBACK(Config->Route->RemoteAddress))) {
        SendData = RawSendDataAlloc(CxPlatSocketToRaw(Socket), Config);
    } else {
        SendData = SendDataAlloc(Socket, Config);
    }
    return SendData;
}

_IRQL_requires_max_(DISPATCH_LEVEL)
void
CxPlatSendDataFree(
    _In_ CXPLAT_SEND_DATA* SendData
    )
{
    CXPLAT_DBG_ASSERT(
        DatapathType(SendData) == CXPLAT_DATAPATH_TYPE_USER ||
        DatapathType(SendData) == CXPLAT_DATAPATH_TYPE_RAW);
    DatapathType(SendData) == CXPLAT_DATAPATH_TYPE_USER ?
    SendDataFree(SendData) : RawSendDataFree(SendData);
}

_IRQL_requires_max_(DISPATCH_LEVEL)
_Success_(return != NULL)
QUIC_BUFFER*
CxPlatSendDataAllocBuffer(
    _In_ CXPLAT_SEND_DATA* SendData,
    _In_ uint16_t MaxBufferLength
    )
{
    CXPLAT_DBG_ASSERT(
        DatapathType(SendData) == CXPLAT_DATAPATH_TYPE_USER ||
        DatapathType(SendData) == CXPLAT_DATAPATH_TYPE_RAW);
    return
        DatapathType(SendData) == CXPLAT_DATAPATH_TYPE_USER ?
        SendDataAllocBuffer(SendData, MaxBufferLength) : RawSendDataAllocBuffer(SendData, MaxBufferLength);
}

_IRQL_requires_max_(DISPATCH_LEVEL)
void
CxPlatSendDataFreeBuffer(
    _In_ CXPLAT_SEND_DATA* SendData,
    _In_ QUIC_BUFFER* Buffer
    )
{
    CXPLAT_DBG_ASSERT(
        DatapathType(SendData) == CXPLAT_DATAPATH_TYPE_USER ||
        DatapathType(SendData) == CXPLAT_DATAPATH_TYPE_RAW);
    DatapathType(SendData) == CXPLAT_DATAPATH_TYPE_USER ?
    SendDataFreeBuffer(SendData, Buffer) : RawSendDataFreeBuffer(SendData, Buffer);
}

_IRQL_requires_max_(DISPATCH_LEVEL)
BOOLEAN
CxPlatSendDataIsFull(
    _In_ CXPLAT_SEND_DATA* SendData
    )
{
    CXPLAT_DBG_ASSERT(
        DatapathType(SendData) == CXPLAT_DATAPATH_TYPE_USER ||
        DatapathType(SendData) == CXPLAT_DATAPATH_TYPE_RAW);
    return DatapathType(SendData) == CXPLAT_DATAPATH_TYPE_USER ?
        SendDataIsFull(SendData) : RawSendDataIsFull(SendData);
}

_IRQL_requires_max_(DISPATCH_LEVEL)
QUIC_STATUS
CxPlatSocketSend(
    _In_ CXPLAT_SOCKET* Socket,
    _In_ const CXPLAT_ROUTE* Route,
    _In_ CXPLAT_SEND_DATA* SendData
    )
{
    CXPLAT_DBG_ASSERT(
        DatapathType(SendData) == CXPLAT_DATAPATH_TYPE_USER ||
        DatapathType(SendData) == CXPLAT_DATAPATH_TYPE_RAW);
    return DatapathType(SendData) == CXPLAT_DATAPATH_TYPE_USER ?
        SocketSend(Socket, Route, SendData) : RawSocketSend(CxPlatSocketToRaw(Socket), Route, SendData);
}

_IRQL_requires_max_(PASSIVE_LEVEL)
void
QuicCopyRouteInfo(
    _Inout_ CXPLAT_ROUTE* DstRoute,
    _In_ CXPLAT_ROUTE* SrcRoute
    )
{
    if (SrcRoute->DatapathType == CXPLAT_DATAPATH_TYPE_RAW) {
        CxPlatCopyMemory(DstRoute, SrcRoute, (uint8_t*)&SrcRoute->State - (uint8_t*)SrcRoute);
        CxPlatUpdateRoute(DstRoute, SrcRoute);
    } else if (SrcRoute->DatapathType == CXPLAT_DATAPATH_TYPE_USER) {
        *DstRoute = *SrcRoute;
    } else {
        CXPLAT_DBG_ASSERT(FALSE);
    }
}

void
CxPlatResolveRouteComplete(
    _In_ void* Context,
    _Inout_ CXPLAT_ROUTE* Route,
    _In_reads_bytes_(6) const uint8_t* PhysicalAddress,
    _In_ uint8_t PathId
    )
{
    CXPLAT_DBG_ASSERT(Route->DatapathType != CXPLAT_DATAPATH_TYPE_USER);
    if (Route->State != RouteResolved) {
        RawResolveRouteComplete(Context, Route, PhysicalAddress, PathId);
    }
}

//
// Tries to resolve route and neighbor for the given destination address.
//
_IRQL_requires_max_(PASSIVE_LEVEL)
QUIC_STATUS
CxPlatResolveRoute(
    _In_ CXPLAT_SOCKET* Socket,
    _Inout_ CXPLAT_ROUTE* Route,
    _In_ uint8_t PathId,
    _In_ void* Context,
    _In_ CXPLAT_ROUTE_RESOLUTION_CALLBACK_HANDLER Callback
    )
{
    if (Socket->UseTcp || Route->DatapathType == CXPLAT_DATAPATH_TYPE_RAW ||
        (Route->DatapathType == CXPLAT_DATAPATH_TYPE_UNKNOWN &&
        Socket->RawSocketAvailable && !IS_LOOPBACK(Route->RemoteAddress))) {
        return RawResolveRoute(CxPlatSocketToRaw(Socket), Route, PathId, Context, Callback);
    }
    Route->State = RouteResolved;
    return QUIC_STATUS_SUCCESS;
}
