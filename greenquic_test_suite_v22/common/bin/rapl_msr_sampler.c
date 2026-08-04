#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define DEFAULT_INTERVAL_MS 6.0
#define DEFAULT_SMOOTH_SAMPLES 3U
#define DEFAULT_PACKAGE_ENERGY "/sys/class/powercap/intel-rapl/intel-rapl:0/energy_uj"
#define DEFAULT_PACKAGE_MAX "/sys/class/powercap/intel-rapl/intel-rapl:0/max_energy_range_uj"
#define DEFAULT_DRAM_ENERGY "/sys/class/powercap/intel-rapl/intel-rapl:0/intel-rapl:0:0/energy_uj"
#define DEFAULT_DRAM_MAX "/sys/class/powercap/intel-rapl/intel-rapl:0/intel-rapl:0:0/max_energy_range_uj"

static volatile sig_atomic_t StopRequested = 0;

static void
OnSignal(int Signal)
{
    (void)Signal;
    StopRequested = 1;
}

static void
Usage(const char* Program)
{
    fprintf(stderr,
        "Usage: %s --output FILE [--interval-ms N] [--smooth-samples N] "
        "[--duration-s N]\n", Program);
}

static bool
ParseDouble(const char* Text, double* Value)
{
    char* End = NULL;
    errno = 0;
    double Parsed = strtod(Text, &End);
    if (errno != 0 || End == Text || *End != '\0') {
        return false;
    }
    *Value = Parsed;
    return true;
}

static bool
ParseUnsigned(const char* Text, unsigned* Value)
{
    char* End = NULL;
    errno = 0;
    unsigned long Parsed = strtoul(Text, &End, 10);
    if (errno != 0 || End == Text || *End != '\0' || Parsed > 1000000UL) {
        return false;
    }
    *Value = (unsigned)Parsed;
    return true;
}

static bool
ReadCounterFd(int Fd, uint64_t* Value)
{
    char Buffer[64];
    if (lseek(Fd, 0, SEEK_SET) < 0) {
        return false;
    }
    ssize_t Length = read(Fd, Buffer, sizeof(Buffer) - 1U);
    if (Length <= 0) {
        return false;
    }
    Buffer[Length] = '\0';
    char* End = NULL;
    errno = 0;
    unsigned long long Parsed = strtoull(Buffer, &End, 10);
    if (errno != 0 || End == Buffer) {
        return false;
    }
    *Value = (uint64_t)Parsed;
    return true;
}

static bool
ReadCounterPath(const char* Path, uint64_t* Value)
{
    int Fd = open(Path, O_RDONLY | O_CLOEXEC);
    if (Fd < 0) {
        return false;
    }
    bool Result = ReadCounterFd(Fd, Value);
    close(Fd);
    return Result;
}

static uint64_t
CounterDelta(uint64_t Current, uint64_t Previous, uint64_t Maximum)
{
    return Current >= Previous ? Current - Previous : Maximum - Previous + Current;
}

static uint64_t
TimespecToNs(const struct timespec* Value)
{
    return (uint64_t)Value->tv_sec * 1000000000ULL + (uint64_t)Value->tv_nsec;
}

static struct timespec
NsToTimespec(uint64_t Value)
{
    struct timespec Result;
    Result.tv_sec = (time_t)(Value / 1000000000ULL);
    Result.tv_nsec = (long)(Value % 1000000000ULL);
    return Result;
}

static int
SleepUntil(uint64_t DeadlineNs)
{
    struct timespec Deadline = NsToTimespec(DeadlineNs);
    while (!StopRequested) {
        int Result = clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &Deadline, NULL);
        if (Result == 0) {
            return 0;
        }
        if (Result != EINTR) {
            errno = Result;
            return -1;
        }
    }
    return 0;
}

int
main(int Argc, char** Argv)
{
    const char* OutputPath = NULL;
    const char* PackageEnergyPath = DEFAULT_PACKAGE_ENERGY;
    const char* PackageMaxPath = DEFAULT_PACKAGE_MAX;
    const char* DramEnergyPath = DEFAULT_DRAM_ENERGY;
    const char* DramMaxPath = DEFAULT_DRAM_MAX;
    double IntervalMs = DEFAULT_INTERVAL_MS;
    double DurationS = 0.0;
    unsigned SmoothSamples = DEFAULT_SMOOTH_SAMPLES;

    for (int Index = 1; Index < Argc; ++Index) {
        if (strcmp(Argv[Index], "--output") == 0 && Index + 1 < Argc) {
            OutputPath = Argv[++Index];
        } else if (strcmp(Argv[Index], "--interval-ms") == 0 && Index + 1 < Argc) {
            if (!ParseDouble(Argv[++Index], &IntervalMs)) {
                fprintf(stderr, "ERROR: invalid --interval-ms value\n");
                return 2;
            }
        } else if (strcmp(Argv[Index], "--smooth-samples") == 0 && Index + 1 < Argc) {
            if (!ParseUnsigned(Argv[++Index], &SmoothSamples)) {
                fprintf(stderr, "ERROR: invalid --smooth-samples value\n");
                return 2;
            }
        } else if (strcmp(Argv[Index], "--duration-s") == 0 && Index + 1 < Argc) {
            if (!ParseDouble(Argv[++Index], &DurationS)) {
                fprintf(stderr, "ERROR: invalid --duration-s value\n");
                return 2;
            }
        } else if (strcmp(Argv[Index], "--package-energy-path") == 0 && Index + 1 < Argc) {
            PackageEnergyPath = Argv[++Index];
        } else if (strcmp(Argv[Index], "--package-max-path") == 0 && Index + 1 < Argc) {
            PackageMaxPath = Argv[++Index];
        } else if (strcmp(Argv[Index], "--dram-energy-path") == 0 && Index + 1 < Argc) {
            DramEnergyPath = Argv[++Index];
        } else if (strcmp(Argv[Index], "--dram-max-path") == 0 && Index + 1 < Argc) {
            DramMaxPath = Argv[++Index];
        } else if (strcmp(Argv[Index], "--help") == 0 || strcmp(Argv[Index], "-h") == 0) {
            Usage(Argv[0]);
            return 0;
        } else {
            Usage(Argv[0]);
            return 2;
        }
    }

    if (OutputPath == NULL || IntervalMs < 1.0 || IntervalMs > 60000.0 ||
        SmoothSamples < 1U || SmoothSamples > 10000U || DurationS < 0.0) {
        fprintf(stderr, "ERROR: invalid sampler configuration\n");
        Usage(Argv[0]);
        return 2;
    }

    uint64_t PackageMax = 0, DramMax = 0;
    if (!ReadCounterPath(PackageMaxPath, &PackageMax) ||
        !ReadCounterPath(DramMaxPath, &DramMax) || PackageMax == 0 || DramMax == 0) {
        fprintf(stderr, "ERROR: RAPL maximum-energy ranges are unavailable\n");
        return 3;
    }

    int PackageFd = open(PackageEnergyPath, O_RDONLY | O_CLOEXEC);
    int DramFd = open(DramEnergyPath, O_RDONLY | O_CLOEXEC);
    if (PackageFd < 0 || DramFd < 0) {
        fprintf(stderr, "ERROR: RAPL package or DRAM energy counter is unavailable: %s\n", strerror(errno));
        if (PackageFd >= 0) close(PackageFd);
        if (DramFd >= 0) close(DramFd);
        return 3;
    }

    FILE* Output = fopen(OutputPath, "w");
    if (Output == NULL) {
        fprintf(stderr, "ERROR: cannot create %s: %s\n", OutputPath, strerror(errno));
        close(PackageFd);
        close(DramFd);
        return 4;
    }
    setvbuf(Output, NULL, _IOFBF, 1024U * 1024U);

    double* PackageHistory = calloc(SmoothSamples, sizeof(double));
    double* DramHistory = calloc(SmoothSamples, sizeof(double));
    if (PackageHistory == NULL || DramHistory == NULL) {
        fprintf(stderr, "ERROR: cannot allocate smoothing history\n");
        free(PackageHistory);
        free(DramHistory);
        fclose(Output);
        close(PackageFd);
        close(DramFd);
        return 5;
    }

    signal(SIGINT, OnSignal);
    signal(SIGTERM, OnSignal);

    uint64_t PreviousPackage = 0, PreviousDram = 0;
    if (!ReadCounterFd(PackageFd, &PreviousPackage) || !ReadCounterFd(DramFd, &PreviousDram)) {
        fprintf(stderr, "ERROR: initial RAPL counter read failed\n");
        free(PackageHistory);
        free(DramHistory);
        fclose(Output);
        close(PackageFd);
        close(DramFd);
        return 6;
    }

    struct timespec StartTime;
    if (clock_gettime(CLOCK_MONOTONIC, &StartTime) != 0) {
        fprintf(stderr, "ERROR: clock_gettime failed: %s\n", strerror(errno));
        return 6;
    }
    uint64_t StartNs = TimespecToNs(&StartTime);
    uint64_t PreviousNs = StartNs;
    uint64_t IntervalNs = (uint64_t)(IntervalMs * 1000000.0 + 0.5);
    uint64_t DurationNs = DurationS > 0.0 ? (uint64_t)(DurationS * 1000000000.0 + 0.5) : 0ULL;
    uint64_t NextNs = StartNs + IntervalNs;

    fprintf(Output, "# schema=greenquic-rapl-msr-c-v2\n");
    fprintf(Output, "# start_monotonic_ns=%" PRIu64 "\n", StartNs);
    fprintf(Output, "# requested_interval_ms=%.6f\n", IntervalMs);
    fprintf(Output, "# smoothing_samples=%u\n", SmoothSamples);
    fprintf(Output, "# package_energy_path=%s\n", PackageEnergyPath);
    fprintf(Output, "# dram_energy_path=%s\n", DramEnergyPath);
    fprintf(Output,
        "sample_monotonic_ns,elapsed_ms,actual_interval_ms,package_energy_uj,dram_energy_uj,"
        "package_delta_j,dram_delta_j,package_power_w,dram_power_w,total_power_w,"
        "package_power_smoothed_w,dram_power_smoothed_w,total_power_smoothed_w\n");

    uint64_t Samples = 0;
    unsigned HistoryCount = 0;
    unsigned HistoryIndex = 0;
    double PackageHistorySum = 0.0;
    double DramHistorySum = 0.0;
    double PackageEnergyTotal = 0.0;
    double DramEnergyTotal = 0.0;

    while (!StopRequested) {
        struct timespec NowTime;
        if (clock_gettime(CLOCK_MONOTONIC, &NowTime) != 0) {
            break;
        }
        uint64_t NowNs = TimespecToNs(&NowTime);
        if (DurationNs != 0ULL && NowNs - StartNs >= DurationNs) {
            break;
        }
        if (SleepUntil(NextNs) != 0 || StopRequested) {
            break;
        }

        uint64_t PackageValue = 0, DramValue = 0;
        if (!ReadCounterFd(PackageFd, &PackageValue) || !ReadCounterFd(DramFd, &DramValue)) {
            fprintf(stderr, "ERROR: RAPL counter read failed after %" PRIu64 " samples\n", Samples);
            break;
        }
        if (clock_gettime(CLOCK_MONOTONIC, &NowTime) != 0) {
            break;
        }
        uint64_t SampleNs = TimespecToNs(&NowTime);
        uint64_t DeltaNs = SampleNs - PreviousNs;
        if (DeltaNs == 0ULL) {
            NextNs += IntervalNs;
            continue;
        }

        uint64_t PackageDeltaUj = CounterDelta(PackageValue, PreviousPackage, PackageMax);
        uint64_t DramDeltaUj = CounterDelta(DramValue, PreviousDram, DramMax);
        double DeltaS = (double)DeltaNs / 1000000000.0;
        double PackageDeltaJ = (double)PackageDeltaUj / 1000000.0;
        double DramDeltaJ = (double)DramDeltaUj / 1000000.0;
        double PackageW = PackageDeltaJ / DeltaS;
        double DramW = DramDeltaJ / DeltaS;

        if (HistoryCount == SmoothSamples) {
            PackageHistorySum -= PackageHistory[HistoryIndex];
            DramHistorySum -= DramHistory[HistoryIndex];
        } else {
            ++HistoryCount;
        }
        PackageHistory[HistoryIndex] = PackageW;
        DramHistory[HistoryIndex] = DramW;
        PackageHistorySum += PackageW;
        DramHistorySum += DramW;
        HistoryIndex = (HistoryIndex + 1U) % SmoothSamples;

        double PackageSmoothW = PackageHistorySum / (double)HistoryCount;
        double DramSmoothW = DramHistorySum / (double)HistoryCount;

        fprintf(Output,
            "%" PRIu64 ",%.6f,%.6f,%" PRIu64 ",%" PRIu64 ",%.9f,%.9f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f\n",
            SampleNs,
            (double)(SampleNs - StartNs) / 1000000.0,
            (double)DeltaNs / 1000000.0,
            PackageValue,
            DramValue,
            PackageDeltaJ,
            DramDeltaJ,
            PackageW,
            DramW,
            PackageW + DramW,
            PackageSmoothW,
            DramSmoothW,
            PackageSmoothW + DramSmoothW);

        PackageEnergyTotal += PackageDeltaJ;
        DramEnergyTotal += DramDeltaJ;
        ++Samples;
        if ((Samples % 128ULL) == 0ULL) {
            fflush(Output);
        }

        PreviousPackage = PackageValue;
        PreviousDram = DramValue;
        PreviousNs = SampleNs;
        NextNs += IntervalNs;
        if (SampleNs > NextNs) {
            uint64_t Missed = (SampleNs - NextNs) / IntervalNs + 1ULL;
            NextNs += Missed * IntervalNs;
        }
    }

    struct timespec EndTime;
    clock_gettime(CLOCK_MONOTONIC, &EndTime);
    double MeasuredS = (double)(TimespecToNs(&EndTime) - StartNs) / 1000000000.0;
    fflush(Output);
    fclose(Output);
    close(PackageFd);
    close(DramFd);
    free(PackageHistory);
    free(DramHistory);

    fprintf(stdout, "GreenQUIC C RAPL/MSR sampler finished\n");
    fprintf(stdout, "requested_interval_ms=%.6f\n", IntervalMs);
    fprintf(stdout, "smoothing_samples=%u\n", SmoothSamples);
    fprintf(stdout, "samples=%" PRIu64 "\n", Samples);
    fprintf(stdout, "measured_duration_s=%.6f\n", MeasuredS);
    fprintf(stdout, "package_energy_j=%.6f\n", PackageEnergyTotal);
    fprintf(stdout, "dram_energy_j=%.6f\n", DramEnergyTotal);
    if (MeasuredS > 0.0) {
        fprintf(stdout, "average_package_w=%.6f\n", PackageEnergyTotal / MeasuredS);
        fprintf(stdout, "average_dram_w=%.6f\n", DramEnergyTotal / MeasuredS);
        fprintf(stdout, "average_total_w=%.6f\n", (PackageEnergyTotal + DramEnergyTotal) / MeasuredS);
    }
    return Samples == 0ULL ? 7 : 0;
}
