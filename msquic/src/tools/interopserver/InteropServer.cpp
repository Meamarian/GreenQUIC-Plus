/*++

    Copyright (c) Microsoft Corporation.
    Licensed under the MIT License.

Abstract:

    Very Simple QUIC HTTP 1.1 GET server.

--*/

#include <csignal>
#include <cstdio>
#include <unistd.h>  // for pause()

#include "InteropServer.h"
#include "greenquic_plus.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

const QUIC_API_TABLE* MsQuic;

// GREENQUIC-BEGIN: tool-level MsQuic execution CPU config
static bool
GreenQuicReadConfigValue(
    const char* Key,
    char* Value,
    size_t ValueSize
    )
{
    const char* ConfigPath = getenv("GREENQUIC_CONFIG");
    if (ConfigPath == nullptr || ConfigPath[0] == '\0') {
        ConfigPath = "dpdk.ini";
    }

    FILE* File = fopen(ConfigPath, "r");
    if (File == nullptr) {
        return false;
    }

    char Line[512];
    const size_t KeyLen = strlen(Key);
    while (fgets(Line, sizeof(Line), File) != nullptr) {
        char* P = Line;
        while (*P == ' ' || *P == '\t') {
            ++P;
        }
        if (*P == '#' || *P == ';' || *P == '\0' || *P == '\n') {
            continue;
        }
        if (strncmp(P, Key, KeyLen) != 0) {
            continue;
        }
        P += KeyLen;
        while (*P == ' ' || *P == '\t') {
            ++P;
        }
        if (*P != '=') {
            continue;
        }
        ++P;
        while (*P == ' ' || *P == '\t') {
            ++P;
        }
        char* End = P + strlen(P);
        while (End > P && (End[-1] == '\n' || End[-1] == '\r' || End[-1] == ' ' || End[-1] == '\t')) {
            --End;
        }
        *End = '\0';
        strncpy(Value, P, ValueSize - 1);
        Value[ValueSize - 1] = '\0';
        fclose(File);
        return true;
    }

    fclose(File);
    return false;
}

static QUIC_EXECUTION_PROFILE
GreenQuicGetQuicExecutionProfile()
{
    char Value[64];
    if (!GreenQuicReadConfigValue("GreenQuicQuicProfile", Value, sizeof(Value))) {
        return QUIC_EXECUTION_PROFILE_TYPE_MAX_THROUGHPUT;
    }
    if (strcmp(Value, "low_latency") == 0 || strcmp(Value, "low-latency") == 0) {
        return QUIC_EXECUTION_PROFILE_LOW_LATENCY;
    }
    if (strcmp(Value, "scavenger") == 0) {
        return QUIC_EXECUTION_PROFILE_TYPE_SCAVENGER;
    }
    if (strcmp(Value, "real_time") == 0 || strcmp(Value, "real-time") == 0) {
        return QUIC_EXECUTION_PROFILE_TYPE_REAL_TIME;
    }
    return QUIC_EXECUTION_PROFILE_TYPE_MAX_THROUGHPUT;
}

static QUIC_STATUS
GreenQuicSetMsQuicExecutionConfig()
{
    char CpuText[512];
    if (!GreenQuicReadConfigValue("GreenQuicQuicWorkerCpus", CpuText, sizeof(CpuText)) || CpuText[0] == '\0') {
        return QUIC_STATUS_SUCCESS;
    }

    uint16_t Cpus[256];
    uint32_t CpuCount = 0;
    const char* P = CpuText;
    while (*P != '\0' && CpuCount < ARRAYSIZE(Cpus)) {
        while (*P == ' ' || *P == '\t' || *P == ',') {
            ++P;
        }
        if (*P == '\0') {
            break;
        }
        char* End = nullptr;
        unsigned long Cpu = strtoul(P, &End, 10);
        if (End == P || Cpu > UINT16_MAX) {
            printf("GreenQUIC: invalid GreenQuicQuicWorkerCpus=%s\n", CpuText);
            return QUIC_STATUS_INVALID_PARAMETER;
        }
        Cpus[CpuCount++] = (uint16_t)Cpu;
        P = End;
    }

    if (CpuCount == 0) {
        return QUIC_STATUS_SUCCESS;
    }

    const uint32_t ConfigSize = QUIC_EXECUTION_CONFIG_MIN_SIZE + CpuCount * sizeof(uint16_t);
    QUIC_EXECUTION_CONFIG* ExecConfig = (QUIC_EXECUTION_CONFIG*)calloc(1, ConfigSize);
    if (ExecConfig == nullptr) {
        return QUIC_STATUS_OUT_OF_MEMORY;
    }

    char AffinitizeText[32];
    const bool Affinitize =
        GreenQuicReadConfigValue("GreenQuicQuicAffinitize", AffinitizeText, sizeof(AffinitizeText)) &&
        atoi(AffinitizeText) != 0;

    ExecConfig->Flags = QUIC_EXECUTION_CONFIG_FLAG_NONE;
#ifdef QUIC_API_ENABLE_PREVIEW_FEATURES
    if (Affinitize) {
        /* Private branch has no AFFINITIZE enum; ProcessorList remains active. */
        ExecConfig->Flags |= QUIC_EXECUTION_CONFIG_FLAG_NONE;
    }
#else
    if (Affinitize) {
        printf("GreenQUIC: GreenQuicQuicAffinitize requested, but QUIC_API_ENABLE_PREVIEW_FEATURES is not enabled; using ProcessorList without AFFINITIZE.\n");
    }
#endif
    ExecConfig->PollingIdleTimeoutUs = 0;
    ExecConfig->ProcessorCount = CpuCount;
    for (uint32_t i = 0; i < CpuCount; ++i) {
        ExecConfig->ProcessorList[i] = Cpus[i];
    }

    QUIC_STATUS Status =
        MsQuic->SetParam(
            nullptr,
            QUIC_PARAM_GLOBAL_EXECUTION_CONFIG,
            ConfigSize,
            ExecConfig);
    free(ExecConfig);

    if (QUIC_FAILED(Status)) {
        printf("GreenQUIC: failed to set MsQuic execution config, 0x%x\n", Status);
    } else {
        printf("GreenQUIC: MsQuic worker CPU list from dpdk.ini = %s\n", CpuText);
    }
    return Status;
}
// GREENQUIC-END
HQUIC Configuration;
const char* RootFolderPath;
const char* UploadFolderPath;

const QUIC_BUFFER SupportedALPNs[] = {
    { sizeof("hq-interop") - 1, (uint8_t*)"hq-interop" },
    { sizeof("hq-29") - 1, (uint8_t*)"hq-29" },
    { sizeof("siduck") - 1, (uint8_t*)"siduck" },
    { sizeof("siduck-00") - 1, (uint8_t*)"siduck-00" }
};

volatile sig_atomic_t exit_flag = 0;

void
handle_signal(int signum) {
    printf("Received signal %d. Exiting.\n", signum);
    exit_flag = 1;
}

void
PrintUsage()
{
    printf("quicinteropserver is simple http 0.9/1.1 server.\n\n");

    printf("Usage:\n");
    printf("  quicinteropserver -listen:<addr or *> -root:<path>"
           " [-thumbprint:<cert_thumbprint>]"
           " [-file:<cert_filepath> AND -key:<cert_key_filepath>]"
           " [-port:<####> (def:%u)]  [-retry:<0/1> (def:%u)]"
           " [-upload:<path>]"
           " [-enableVNE:<0/1>]\n\n",
           DEFAULT_QUIC_HTTP_SERVER_PORT, DEFAULT_QUIC_HTTP_SERVER_RETRY);

    printf("Examples:\n");
    printf("  quicinteropserver -listen:127.0.0.1 -name:localhost -port:443 -root:c:\\temp\n");
    printf("  quicinteropserver -listen:* -retry:1 -thumbprint:175342733b39d81c997817296c9b691172ca6b6e -root:c:\\temp\n");
}

int
QUIC_MAIN_EXPORT
main(
    _In_ int argc,
    _In_reads_(argc) _Null_terminated_ char* argv[]
    )
{
    if (argc < 2 ||
        GetFlag(argc, argv, "help") ||
        GetFlag(argc, argv, "?")) {
        PrintUsage();
        return -1;
    }

    HQUIC Registration = nullptr;
    EXIT_ON_FAILURE(MsQuicOpen2(&MsQuic));
    EXIT_ON_FAILURE(GreenQuicSetMsQuicExecutionConfig());
    const QUIC_REGISTRATION_CONFIG RegConfig = { "interopserver", GreenQuicGetQuicExecutionProfile() };
    EXIT_ON_FAILURE(MsQuic->RegistrationOpen(&RegConfig, &Registration));

    //
    // Optional parameters.
    //
    uint16_t LocalPort = DEFAULT_QUIC_HTTP_SERVER_PORT;
    BOOLEAN Retry = DEFAULT_QUIC_HTTP_SERVER_RETRY;
    BOOLEAN EnableVNE = FALSE;
    const char* SslKeyLogFileParam = nullptr;
    TryGetValue(argc, argv, "port", &LocalPort);
    TryGetValue(argc, argv, "retry", &Retry);
    if (Retry) {
        EXIT_ON_FAILURE(QuicForceRetry(MsQuic, true));
        printf("Enabling forced RETRY on server.\n");
    }
    TryGetValue(argc, argv, "upload", &UploadFolderPath);
    TryGetValue(argc, argv, "sslkeylogfile", &SslKeyLogFileParam);
    TryGetValue(argc, argv, "enablevne", &EnableVNE);

    //
    // Required parameters.
    //
    const char* ListenAddrStr = nullptr;
    QUIC_ADDR ListenAddr = { 0 };
    if (!TryGetValue(argc, argv, "listen", &ListenAddrStr) ||
        !ConvertArgToAddress(ListenAddrStr, LocalPort, &ListenAddr)) {
        printf("Missing or invalid '-listen' arg!\n");
        return -1;
    }
    if (!TryGetValue(argc, argv, "root", &RootFolderPath)) {
        printf("Missing '-root' arg!\n");
        return -1;
    }

    QUIC_SETTINGS Settings{0};
    Settings.PeerBidiStreamCount = MAX_HTTP_REQUESTS_PER_CONNECTION;
    Settings.IsSet.PeerBidiStreamCount = TRUE;
    Settings.PeerUnidiStreamCount = MAX_HTTP_REQUESTS_PER_CONNECTION;
    Settings.IsSet.PeerUnidiStreamCount = TRUE;
    Settings.InitialRttMs = 50; // Be more aggressive with RTT for interop testing
    Settings.IsSet.InitialRttMs = TRUE;
    Settings.ServerResumptionLevel = QUIC_SERVER_RESUME_AND_ZERORTT; // Enable resumption & 0-RTT
    Settings.IsSet.ServerResumptionLevel = TRUE;
    Settings.GreaseQuicBitEnabled = TRUE; // Enable Grease Quic Bit
    Settings.IsSet.GreaseQuicBitEnabled = TRUE;
    if (EnableVNE) {
        uint32_t SupportedVersions[] = {QUIC_VERSION_2_H, QUIC_VERSION_1_H, QUIC_VERSION_DRAFT_29_H, QUIC_VERSION_1_MS_H};
        QUIC_VERSION_SETTINGS VersionSettings{0};
        VersionSettings.AcceptableVersions = SupportedVersions;
        VersionSettings.OfferedVersions = SupportedVersions;
        VersionSettings.FullyDeployedVersions = SupportedVersions;
        VersionSettings.AcceptableVersionsLength = ARRAYSIZE(SupportedVersions);
        VersionSettings.OfferedVersionsLength = ARRAYSIZE(SupportedVersions);
        VersionSettings.FullyDeployedVersionsLength = ARRAYSIZE(SupportedVersions);
        if (QUIC_FAILED(
            MsQuic->SetParam(
                nullptr,
                QUIC_PARAM_GLOBAL_VERSION_SETTINGS,
                sizeof(VersionSettings),
                &VersionSettings))) {
            printf("Failed to enable Version Negotiation Extension!\n");
            return -1;
        }
    }

    Configuration = GetServerConfigurationFromArgs(argc, argv, MsQuic, Registration, SupportedALPNs, ARRAYSIZE(SupportedALPNs), &Settings, sizeof(Settings));
    if (!Configuration) {
        printf("Failed to load configuration from args!\n");
        return -1;
    }

    {
        HttpServer Server(Registration, SupportedALPNs, ARRAYSIZE(SupportedALPNs), &ListenAddr, SslKeyLogFileParam);
        if (GetFlag(argc, argv, "noexit")) {
            CXPLAT_EVENT Event;
            CxPlatEventInitialize(&Event, TRUE, FALSE);
            printf("Waiting forever.\n\n");
            CxPlatEventWaitForever(Event);
        } else if (GetFlag(argc, argv, "exitonsig")) {
            printf("Waiting for SIGINT (Ctrl+C) or SIGTERM...\n");

            signal(SIGINT, handle_signal);
            signal(SIGTERM, handle_signal);

            while (!exit_flag)
                pause();  // blocks until a signal is caught
        } else {
            printf("Press Enter to exit.\n\n");
            getchar();
        }
    }

    FreeServerConfiguration(MsQuic, Configuration);
    MsQuic->RegistrationShutdown(
        Registration,
        QUIC_CONNECTION_SHUTDOWN_FLAG_NONE,
        0);
    MsQuic->RegistrationClose(Registration);
    MsQuicClose(MsQuic);

    return 0;
}

//
// HttpRequest
//

HttpRequest::HttpRequest(HttpConnection *connection, HQUIC stream, bool Unidirectional) :
    Connection(connection), QuicStream(stream), File(nullptr),
    Shutdown(false), WriteHttp11Header(false), GreenQuicServerTxHintActive(false)
{
    MsQuic->SetCallbackHandler(
        QuicStream,
        Unidirectional ?
            (void*)QuicUnidiCallbackHandler :
            (void*)QuicBidiCallbackHandler,
        this);
    Connection->AddRef();
}

HttpRequest::~HttpRequest()
{
    if (GreenQuicServerTxHintActive) {
        CxPlatGreenQuicPlusEndTransfer(GQPLUS_HINT_SERVER_FILE_TX_ACTIVE);
        GreenQuicServerTxHintActive = false;
    }
    if (File) {
        fclose(File); // TODO - If POST, abandon/delete file as it wasn't finished.
    }
    MsQuic->StreamClose(QuicStream);
    Connection->Release();
}

void
HttpRequest::Process()
{
    if (Shutdown) {
        return;
    }

    QUIC_BUFFER* QuicBuffer = &Buffer.QuicBuffer;

    if (QuicBuffer->Length < 5 ||
        _strnicmp((const char*)QuicBuffer->Buffer, "get ", 4) != 0) {
        printf("[%s] Invalid get\n", GetRemoteAddr(MsQuic, QuicStream).Address);
        Abort(HttpRequestNotGet);
        return;
    }

    char* PathStart = (char*)QuicBuffer->Buffer + 4;

    char* end = strpbrk(PathStart, " \r\n");
    if (end != NULL) {
        if (*end == ' ') {
            WriteHttp11Header = true;
        }
        *end = '\0';
    }

    if (strstr(PathStart, "..") != nullptr) {
        printf("[%s] '..' found\n", GetRemoteAddr(MsQuic, QuicStream).Address);
        Abort(HttpRequestFoundDots); // Don't allow requests with ../ in them.
        return;
    }

    char index[] = "/index.html";
    if (strcmp("/", PathStart) == 0) {
        PathStart = index;
    }

    char FullFilePath[256];
    if (snprintf(FullFilePath, sizeof(FullFilePath), "%s%s", RootFolderPath, PathStart) < 0) {
        printf("[%s] Invalid get\n", GetRemoteAddr(MsQuic, QuicStream).Address);
        Abort(HttpRequestGetTooBig);
        return;
    }

    printf("[%s] GET '%s'\n", GetRemoteAddr(MsQuic, QuicStream).Address, PathStart);
    File = fopen(FullFilePath, "rb"); // In case of failure, SendData still works.

    SendData();
}

void
HttpRequest::SendData()
{
    if (Shutdown) {
        return;
    }

    Buffer.Reset();

    if (File) {
        if (!GreenQuicServerTxHintActive) {
            CxPlatGreenQuicPlusBeginTransfer(GQPLUS_HINT_SERVER_FILE_TX_ACTIVE);
            GreenQuicServerTxHintActive = true;
        }
        if (WriteHttp11Header) {
            const char Http11ResponseHeaders[] = "HTTP/1.1 200 OK\r\nConnection: Close\r\n\r\n";
            Buffer.Write(Http11ResponseHeaders, sizeof(Http11ResponseHeaders));
            WriteHttp11Header = false;
        }

        while (!Buffer.IsFull()) {
            size_t BytesAvail = IO_SIZE - Buffer.QuicBuffer.Length;
            size_t BytesRead =
                fread(
                    Buffer.RawBuffer + Buffer.QuicBuffer.Length,
                    1,
                    BytesAvail,
                    File);
            Buffer.QuicBuffer.Length += (uint32_t)BytesRead;
            if (BytesAvail != BytesRead) {
                Buffer.Flags |= QUIC_SEND_FLAG_FIN;
                Shutdown = true;
                break;
            }
        }

    } else {
        const char BadRequestBuffer11[] = "HTTP/1.1 400 BAD REQUEST\r\nConnection: Close\r\n\r\n";
        const char BadRequestBuffer[] = "BAD REQUEST";
        const char *ResponseBuffer = BadRequestBuffer;
        uint32_t ResponseBufferSize = sizeof(BadRequestBuffer) - 1;

        if (WriteHttp11Header) {
            ResponseBuffer = BadRequestBuffer11;
            ResponseBufferSize = sizeof(BadRequestBuffer11) - 1;
            WriteHttp11Header = false;
        }

        Buffer.Write(ResponseBuffer, ResponseBufferSize);
        Buffer.Flags |= QUIC_SEND_FLAG_FIN;
        Shutdown = true;
    }

    QUIC_STATUS Status;
    if (QUIC_FAILED(
        Status =
        MsQuic->StreamSend(
            QuicStream,
            &Buffer.QuicBuffer,
            1,
            Buffer.Flags,
            this))) {
        printf("[%s] Send failed, 0x%x\n", GetRemoteAddr(MsQuic, QuicStream).Address, Status);
        Abort(HttpRequestSendFailed);
    }
}

bool
HttpRequest::ReceiveUniDiData(
    _In_ const QUIC_BUFFER* Buffers,
    _In_ uint32_t BufferCount
    )
{
    if (UploadFolderPath == nullptr) {
        printf("[%s] Server not configured for POST!\n", GetRemoteAddr(MsQuic, QuicStream).Address);
        return false;
    }

    uint32_t SkipLength = 0;
    if (File == nullptr) {
        const QUIC_BUFFER* FirstBuffer = Buffers;
        if (FirstBuffer->Length < 5 ||
            _strnicmp((const char*)FirstBuffer->Buffer, "post ", 5) != 0) {
            printf("[%s] Invalid post prefix\n", GetRemoteAddr(MsQuic, QuicStream).Address);
            return false;
        }

        char* FileName = (char*)FirstBuffer->Buffer + 5;
        char* FileNameEnd = strstr(FileName, "\r\n");
        if (FileNameEnd == nullptr) {
            printf("[%s] Invalid post suffix\n", GetRemoteAddr(MsQuic, QuicStream).Address);
            return false;
        }
        *FileNameEnd = '\0'; // We shouldn't be writing to the buffer. Don't imitate this.

        if (strstr(FileName, "..") != nullptr) {
            printf("[%s] '..' found\n", GetRemoteAddr(MsQuic, QuicStream).Address);
            return false;
        }

        char FullFilePath[256];
        if (snprintf(FullFilePath, sizeof(FullFilePath), "%s/%s", UploadFolderPath, FileName) < 0) {
            printf("[%s] Invalid path\n", GetRemoteAddr(MsQuic, QuicStream).Address);
            return false;
        }

        printf("[%s] POST '%s'\n", GetRemoteAddr(MsQuic, QuicStream).Address, FileName);
        File = fopen(FullFilePath, "wb");
        if (!File) {
            printf("[%s] Failed to open file\n", GetRemoteAddr(MsQuic, QuicStream).Address);
            return false;
        }

        FileNameEnd += 2; // Skip "\r\n"
        SkipLength = (uint32_t)((uint8_t*)FileNameEnd - FirstBuffer->Buffer);
    }

    for (uint32_t i = 0; i < BufferCount; ++i) {
        uint32_t DataLength = Buffers[i].Length - SkipLength;
        if (fwrite(Buffers[i].Buffer + SkipLength, 1, DataLength, File) < DataLength) {
            printf("[%s] Failed to write file\n", GetRemoteAddr(MsQuic, QuicStream).Address);
            return false;
        }
        SkipLength = 0;
    }

    return true;
}

QUIC_STATUS
QUIC_API
HttpRequest::QuicBidiCallbackHandler(
    _In_ HQUIC Stream,
    _In_opt_ void* Context,
    _Inout_ QUIC_STREAM_EVENT* Event
    )
{
    auto pThis = (HttpRequest*)Context;
    auto Buffer = &pThis->Buffer;

    switch (Event->Type) {
    case QUIC_STREAM_EVENT_RECEIVE:
        if (!Buffer->HasRoom(Event->RECEIVE.TotalBufferLength)) {
            printf("[%s] No room for recv\n", GetRemoteAddr(MsQuic, Stream).Address);
            pThis->Abort(HttpRequestRecvNoRoom);
        } else {
            for (uint32_t i = 0; i < Event->RECEIVE.BufferCount; ++i) {
                Buffer->Write(
                    Event->RECEIVE.Buffers[i].Buffer,
                    Event->RECEIVE.Buffers[i].Length);
            }
            Buffer->QuicBuffer.Buffer[Buffer->QuicBuffer.Length] = 0;
        }
        break;
    case QUIC_STREAM_EVENT_SEND_COMPLETE:
        pThis->SendData();
        break;
    case QUIC_STREAM_EVENT_PEER_SEND_SHUTDOWN:
        pThis->Process();
        break;
    case QUIC_STREAM_EVENT_PEER_SEND_ABORTED:
    case QUIC_STREAM_EVENT_PEER_RECEIVE_ABORTED:
        printf("[%s] Peer abort\n", GetRemoteAddr(MsQuic, Stream).Address);
        if (pThis->GreenQuicServerTxHintActive) {
            CxPlatGreenQuicPlusEndTransfer(GQPLUS_HINT_SERVER_FILE_TX_ACTIVE);
            pThis->GreenQuicServerTxHintActive = false;
        }
        pThis->Abort(HttpRequestPeerAbort);
        break;
    case QUIC_STREAM_EVENT_SHUTDOWN_COMPLETE:
        if (pThis->GreenQuicServerTxHintActive) {
            CxPlatGreenQuicPlusEndTransfer(GQPLUS_HINT_SERVER_FILE_TX_ACTIVE);
            pThis->GreenQuicServerTxHintActive = false;
        }
        delete pThis;
        break;
    default:
        break;
    }

    return QUIC_STATUS_SUCCESS;
}

_Function_class_(QUIC_STREAM_CALLBACK)
QUIC_STATUS
QUIC_API
HttpRequest::QuicUnidiCallbackHandler(
    _In_ HQUIC Stream,
    _In_opt_ void* Context,
    _Inout_ QUIC_STREAM_EVENT* Event
    )
{
    auto pThis = (HttpRequest*)Context;
    switch (Event->Type) {
    case QUIC_STREAM_EVENT_RECEIVE:
        if (!pThis->ReceiveUniDiData(Event->RECEIVE.Buffers, Event->RECEIVE.BufferCount)) {
            pThis->Abort(HttpRequestExtraRecv); // BUG - Seems like we continue to get receive callbacks!
        }
        break;
    case QUIC_STREAM_EVENT_PEER_SEND_SHUTDOWN:
        if (pThis->File) {
            fclose(pThis->File);
            pThis->File = nullptr;
        }
        break;
    case QUIC_STREAM_EVENT_PEER_SEND_ABORTED:
        printf("[%s] Peer abort (0x%llx)\n",
            GetRemoteAddr(MsQuic, Stream).Address,
            (unsigned long long)Event->PEER_SEND_ABORTED.ErrorCode);
        break;
    case QUIC_STREAM_EVENT_SHUTDOWN_COMPLETE:
        delete pThis;
        break;
    default:
        break;
    }
    return QUIC_STATUS_SUCCESS;
}
