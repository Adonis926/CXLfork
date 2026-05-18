#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define CXL_ALIGN (2UL * 1024 * 1024)
#define CXL_MAGIC 0x4352495543584c31ULL /* "CRIUCXL1" */
#define CXL_VERSION 1
#define DEFAULT_DAX "/dev/dax0.0"
#define DEFAULT_MB 16
#define DEFAULT_ITERS 200000
#define NOTE_MAX 64
#define PATH_MAX_LOCAL 256
#define CGROUP_MAX_LOCAL 256

struct cxl_image_header {
    uint64_t magic;
    uint32_t version;
    uint32_t header_size;
    uint64_t total_size;
    uint64_t payload_size;
    uint64_t heap_len;
    uint64_t checkpoint_counter;
    uint64_t target_iters;
    uint64_t file_offset;
    uint64_t checksum;
    uint64_t unix_time_ns;
    uint64_t pid;
    uint64_t ppid;
    char hostname[64];
    char cwd[PATH_MAX_LOCAL];
    char file_path[PATH_MAX_LOCAL];
    char cgroup[CGROUP_MAX_LOCAL];
    char note[NOTE_MAX];
};

struct options {
    const char *dax_path;
    const char *mode;
    size_t heap_len;
    uint64_t iters;
};

static void die(const char *msg)
{
    perror(msg);
    exit(1);
}

static uint64_t now_ns(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_REALTIME, &ts) != 0)
        die("clock_gettime");
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static uint64_t fnv1a64(const void *data, size_t len)
{
    const unsigned char *p = data;
    uint64_t h = 1469598103934665603ULL;
    for (size_t i = 0; i < len; i++) {
        h ^= p[i];
        h *= 1099511628211ULL;
    }
    return h;
}

static size_t round_up(size_t value, size_t align)
{
    return (value + align - 1) & ~(align - 1);
}

static void *map_devdax_aligned(int fd, size_t size, int prot)
{
    size_t reserve_size = size + CXL_ALIGN;
    void *reserve = mmap(NULL, reserve_size, PROT_NONE,
                         MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (reserve == MAP_FAILED)
        die("reserve mmap");

    uintptr_t base = (uintptr_t)reserve;
    uintptr_t aligned = (base + CXL_ALIGN - 1) & ~(uintptr_t)(CXL_ALIGN - 1);
    size_t prefix = aligned - base;
    size_t suffix = reserve_size - prefix - size;

    if (prefix && munmap((void *)base, prefix) != 0)
        die("munmap prefix");
    if (suffix && munmap((void *)(aligned + size), suffix) != 0)
        die("munmap suffix");

    void *mapped = mmap((void *)aligned, size, prot, MAP_SHARED | MAP_FIXED, fd, 0);
    if (mapped == MAP_FAILED)
        die("devdax mmap");
    return mapped;
}

static void fill_heap(unsigned char *heap, size_t len, uint64_t counter)
{
    for (size_t i = 0; i < len; i++)
        heap[i] = (unsigned char)((i * 1315423911ULL + counter * 2654435761ULL) & 0xff);
}

static uint64_t mutate_heap(unsigned char *heap, size_t len, uint64_t start, uint64_t iters)
{
    uint64_t acc = 0;
    for (uint64_t i = start; i < iters; i++) {
        size_t idx = (size_t)((i * 1103515245ULL + 12345ULL) % len);
        heap[idx] ^= (unsigned char)(i & 0xff);
        acc += heap[idx];
    }
    return acc;
}

static void create_os_state_file(char *path, size_t path_len, uint64_t *offset)
{
    snprintf(path, path_len, "/tmp/criu-cxl-os-state-%ld.txt", (long)getpid());
    int fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0644);
    if (fd < 0 && errno == ENOENT) {
        snprintf(path, path_len, "/criu-cxl-os-state-%ld.txt", (long)getpid());
        fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0644);
    }
    if (fd < 0)
        die("open os state");

    const char *msg = "file-state-before-checkpoint\n";
    if (write(fd, msg, strlen(msg)) < 0)
        die("write os state");
    *offset = (uint64_t)lseek(fd, 0, SEEK_CUR);
    if ((off_t)*offset < 0)
        die("lseek os state");
    close(fd);
}

static void read_first_cgroup(char *buf, size_t len)
{
    FILE *f = fopen("/proc/self/cgroup", "r");
    if (!f) {
        snprintf(buf, len, "unavailable");
        return;
    }

    if (!fgets(buf, len, f))
        snprintf(buf, len, "empty");
    fclose(f);

    size_t n = strlen(buf);
    while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r'))
        buf[--n] = '\0';
}

static void parse_args(int argc, char **argv, struct options *opt)
{
    opt->dax_path = DEFAULT_DAX;
    opt->mode = NULL;
    opt->heap_len = DEFAULT_MB * 1024UL * 1024UL;
    opt->iters = DEFAULT_ITERS;

    if (argc < 2) {
        fprintf(stderr, "usage: %s checkpoint|restore|serve [--dax PATH] [--mb N] [--iters N]\n", argv[0]);
        exit(2);
    }
    opt->mode = argv[1];

    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--dax") == 0 && i + 1 < argc) {
            opt->dax_path = argv[++i];
        } else if (strcmp(argv[i], "--mb") == 0 && i + 1 < argc) {
            opt->heap_len = (size_t)strtoull(argv[++i], NULL, 10) * 1024UL * 1024UL;
        } else if (strcmp(argv[i], "--iters") == 0 && i + 1 < argc) {
            opt->iters = strtoull(argv[++i], NULL, 10);
        } else {
            fprintf(stderr, "unknown or incomplete arg: %s\n", argv[i]);
            exit(2);
        }
    }

    if (opt->heap_len == 0 || opt->iters == 0) {
        fprintf(stderr, "heap size and iterations must be non-zero\n");
        exit(2);
    }
}

static int do_serve(const struct options *opt)
{
    unsigned char *heap = malloc(opt->heap_len);
    uint64_t counter = 0;
    uint64_t checksum;

    if (!heap)
        die("malloc serve heap");

    fill_heap(heap, opt->heap_len, 11);

    for (;;) {
        uint64_t start = counter;
        uint64_t end = counter + opt->iters;
        uint64_t acc = mutate_heap(heap, opt->heap_len, start, end);

        counter = end;
        checksum = fnv1a64(heap, opt->heap_len);
        printf("serverless_tick pid=%ld counter=%" PRIu64 " heap=%zu acc=%" PRIu64
               " checksum=0x%016" PRIx64 "\n",
               (long)getpid(), counter, opt->heap_len, acc, checksum);
        fflush(stdout);
        usleep(100000);
    }

    free(heap);
    return 0;
}

static int do_checkpoint(const struct options *opt)
{
    unsigned char *heap = malloc(opt->heap_len);
    if (!heap)
        die("malloc heap");

    uint64_t checkpoint_counter = opt->iters / 2;
    fill_heap(heap, opt->heap_len, 7);
    uint64_t pre_acc = mutate_heap(heap, opt->heap_len, 0, checkpoint_counter);
    uint64_t checksum = fnv1a64(heap, opt->heap_len);

    struct cxl_image_header hdr;
    memset(&hdr, 0, sizeof(hdr));
    hdr.magic = CXL_MAGIC;
    hdr.version = CXL_VERSION;
    hdr.header_size = sizeof(hdr);
    hdr.payload_size = opt->heap_len;
    hdr.heap_len = opt->heap_len;
    hdr.checkpoint_counter = checkpoint_counter;
    hdr.target_iters = opt->iters;
    hdr.checksum = checksum;
    hdr.unix_time_ns = now_ns();
    hdr.pid = (uint64_t)getpid();
    hdr.ppid = (uint64_t)getppid();
    snprintf(hdr.note, sizeof(hdr.note), "cooperative CRIU-CXL checkpoint");
    gethostname(hdr.hostname, sizeof(hdr.hostname) - 1);
    if (!getcwd(hdr.cwd, sizeof(hdr.cwd)))
        die("getcwd");
    read_first_cgroup(hdr.cgroup, sizeof(hdr.cgroup));
    create_os_state_file(hdr.file_path, sizeof(hdr.file_path), &hdr.file_offset);

    size_t image_size = sizeof(hdr) + opt->heap_len;
    hdr.total_size = image_size;
    size_t map_size = round_up(image_size, CXL_ALIGN);

    int fd = open(opt->dax_path, O_RDWR | O_SYNC);
    if (fd < 0)
        die("open dax");
    unsigned char *map = map_devdax_aligned(fd, map_size, PROT_READ | PROT_WRITE);

    memset(map, 0, map_size);
    memcpy(map, &hdr, sizeof(hdr));
    memcpy(map + sizeof(hdr), heap, opt->heap_len);
    msync(map, map_size, MS_SYNC);

    printf("checkpoint=ok dax=%s pid=%" PRIu64 " ppid=%" PRIu64
           " host=%s heap=%zu counter=%" PRIu64 " target=%" PRIu64
           " checksum=0x%016" PRIx64 " pre_acc=%" PRIu64 " file_offset=%" PRIu64 "\n",
           opt->dax_path, hdr.pid, hdr.ppid, hdr.hostname, opt->heap_len, checkpoint_counter, opt->iters,
           checksum, pre_acc, hdr.file_offset);

    munmap(map, map_size);
    close(fd);
    free(heap);
    return 0;
}

static int do_restore(const struct options *opt)
{
    int fd = open(opt->dax_path, O_RDWR | O_SYNC);
    if (fd < 0)
        die("open dax");

    size_t map_size = CXL_ALIGN;
    unsigned char *map = map_devdax_aligned(fd, map_size, PROT_READ | PROT_WRITE);

    struct cxl_image_header hdr;
    memcpy(&hdr, map, sizeof(hdr));
    if (hdr.magic != CXL_MAGIC || hdr.version != CXL_VERSION ||
        hdr.header_size != sizeof(hdr) || hdr.heap_len == 0) {
        fprintf(stderr, "invalid checkpoint image\n");
        return 1;
    }

    size_t image_size = sizeof(hdr) + (size_t)hdr.heap_len;
    if (round_up(image_size, CXL_ALIGN) > map_size) {
        munmap(map, map_size);
        map_size = round_up(image_size, CXL_ALIGN);
        map = map_devdax_aligned(fd, map_size, PROT_READ | PROT_WRITE);
    }

    unsigned char *heap = malloc((size_t)hdr.heap_len);
    if (!heap)
        die("malloc restore heap");
    memcpy(heap, map + sizeof(hdr), (size_t)hdr.heap_len);

    uint64_t checksum = fnv1a64(heap, (size_t)hdr.heap_len);
    int verify_ok = checksum == hdr.checksum;
    uint64_t post_acc = mutate_heap(heap, (size_t)hdr.heap_len,
                                    hdr.checkpoint_counter, hdr.target_iters);
    uint64_t final_checksum = fnv1a64(heap, (size_t)hdr.heap_len);

    printf("restore=ok source_host=%s source_pid=%" PRIu64 " source_ppid=%" PRIu64
           " restore_pid=%ld heap=%" PRIu64 " counter=%" PRIu64
           " target=%" PRIu64 " verify=%s checksum=0x%016" PRIx64
           " continued=ok post_acc=%" PRIu64 " final=0x%016" PRIx64 "\n",
           hdr.hostname, hdr.pid, hdr.ppid, (long)getpid(), hdr.heap_len,
           hdr.checkpoint_counter, hdr.target_iters,
           verify_ok ? "ok" : "bad", checksum, post_acc, final_checksum);
    printf("os_state cwd=%s file=%s file_offset=%" PRIu64
           " cgroup=\"%s\" note=\"%s\"\n",
           hdr.cwd, hdr.file_path, hdr.file_offset, hdr.cgroup, hdr.note);

    free(heap);
    munmap(map, map_size);
    close(fd);
    return verify_ok ? 0 : 1;
}

int main(int argc, char **argv)
{
    struct options opt;
    parse_args(argc, argv, &opt);

    if (strcmp(opt.mode, "checkpoint") == 0)
        return do_checkpoint(&opt);
    if (strcmp(opt.mode, "restore") == 0)
        return do_restore(&opt);
    if (strcmp(opt.mode, "serve") == 0)
        return do_serve(&opt);

    fprintf(stderr, "mode must be checkpoint, restore, or serve\n");
    return 2;
}
