// Read-only, finite resource sample. No app/window inspection or permissions.
#include <errno.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <time.h>

static double seconds(struct timespec t) { return t.tv_sec + t.tv_nsec / 1e9; }

int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "Usage: MeasureResources PID SECONDS(1..30)\n"); return 2; }
    char *end = NULL;
    long parsedPID = strtol(argv[1], &end, 10);
    if (!end || *end || parsedPID <= 0) return 2;
    double duration = strtod(argv[2], &end);
    if (!end || *end || duration < 1 || duration > 30) return 2;
    struct rusage_info_v2 before = {0}, after = {0};
    struct timespec started, finished;
    if (proc_pid_rusage((int)parsedPID, RUSAGE_INFO_V2, (rusage_info_t *)&before)) { perror("proc_pid_rusage"); return 1; }
    clock_gettime(CLOCK_MONOTONIC, &started);
    struct timespec pause = { .tv_sec = (time_t)duration, .tv_nsec = (long)((duration - (time_t)duration) * 1e9) };
    while (nanosleep(&pause, &pause) && errno == EINTR) {}
    clock_gettime(CLOCK_MONOTONIC, &finished);
    if (proc_pid_rusage((int)parsedPID, RUSAGE_INFO_V2, (rusage_info_t *)&after)) { perror("proc_pid_rusage"); return 1; }
    mach_timebase_info_data_t timebase;
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || timebase.denom == 0) return 1;
    double wall = seconds(finished) - seconds(started);
    double cpuTicks = (double)(after.ri_user_time - before.ri_user_time) + (double)(after.ri_system_time - before.ri_system_time);
    double cpuSeconds = cpuTicks * timebase.numer / timebase.denom / 1e9;
    printf("{\"pid\":%ld,\"seconds\":%.3f,\"cpuPercentOfOneCore\":%.4f,"
           "\"physicalFootprintMiB\":%.3f,\"residentMiB\":%.3f,"
           "\"footprintChangeMiB\":%.3f,\"idleWakeups\":%llu,\"interruptWakeups\":%llu}\n",
           parsedPID, wall, 100 * cpuSeconds / wall,
           after.ri_phys_footprint / 1048576.0, after.ri_resident_size / 1048576.0,
           ((double)after.ri_phys_footprint - before.ri_phys_footprint) / 1048576.0,
           (unsigned long long)(after.ri_pkg_idle_wkups - before.ri_pkg_idle_wkups),
           (unsigned long long)(after.ri_interrupt_wkups - before.ri_interrupt_wkups));
    return 0;
}
