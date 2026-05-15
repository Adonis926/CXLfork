#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static void *aligned_devmap(int fd, size_t size, size_t align)
{
    size_t reserve_size = size + align;
    void *reserve = mmap(NULL, reserve_size, PROT_NONE,
                         MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (reserve == MAP_FAILED) {
        perror("reserve mmap");
        return MAP_FAILED;
    }

    uintptr_t base = (uintptr_t)reserve;
    uintptr_t aligned = (base + align - 1) & ~(uintptr_t)(align - 1);
    size_t prefix = aligned - base;
    size_t suffix = reserve_size - prefix - size;

    if (prefix)
        munmap((void *)base, prefix);
    if (suffix)
        munmap((void *)(aligned + size), suffix);

    void *mapped = mmap((void *)aligned, size, PROT_READ | PROT_WRITE,
                        MAP_SHARED | MAP_FIXED, fd, 0);
    if (mapped == MAP_FAILED)
        perror("devdax mmap");
    return mapped;
}

int main(int argc, char **argv)
{
    const size_t size = 2UL * 1024 * 1024;
    const size_t align = 2UL * 1024 * 1024;
    const char *path = argc > 1 ? argv[1] : "/dev/dax0.0";
    const char *message = argc > 2 ? argv[2] : NULL;

    int fd = open(path, O_RDWR | O_SYNC);
    if (fd < 0) {
        perror("open");
        return 1;
    }

    char *map = aligned_devmap(fd, size, align);
    if (map == MAP_FAILED) {
        close(fd);
        return 1;
    }

    if (message) {
        memset(map, 0, 64);
        snprintf(map, 64, "%s", message);
        msync(map, 64, MS_SYNC);
    }

    printf("%.64s\n", map);
    munmap(map, size);
    close(fd);
    return 0;
}
