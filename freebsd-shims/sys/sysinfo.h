/*
 * FreeBSD shim for <sys/sysinfo.h>
 *
 * WebKit's AvailableMemory.cpp and RAMSize.cpp include <sys/sysinfo.h>
 * under OS(FREEBSD), but this header only exists on Linux.
 * This shim provides a compatible struct sysinfo and sysinfo() function
 * implemented via FreeBSD's sysctl().
 */

#ifndef FREEBSD_SYSINFO_SHIM_H
#define FREEBSD_SYSINFO_SHIM_H

#include <sys/types.h>
#include <sys/sysctl.h>
#include <unistd.h>

struct sysinfo {
    unsigned long totalram;
    unsigned long mem_unit;
};

static inline int sysinfo(struct sysinfo *info)
{
    unsigned long physmem;
    size_t len = sizeof(physmem);

    if (sysctlbyname("hw.physmem", &physmem, &len, NULL, 0) != 0)
        return -1;

    info->totalram = physmem;
    info->mem_unit = 1;
    return 0;
}

#endif /* FREEBSD_SYSINFO_SHIM_H */
