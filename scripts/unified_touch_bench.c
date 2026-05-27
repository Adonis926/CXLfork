// SPDX-License-Identifier: MIT
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "cxlfork_uapi.h"

#define PAGE_SIZE_LOCAL 4096UL
#define DEFAULT_BASE ((void *)0x776000000000ULL)

struct child_result {
	uint64_t child_start_ns;
	uint64_t restore_ns;
	uint64_t global_restore_ns;
	uint64_t pte_attach_ns;
	uint64_t pte_attach_pages;
	uint64_t touch_ns;
	uint64_t total_child_ns;
	uint64_t checksum;
	uint64_t faults;
};

static uint64_t nsec_now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000000ULL + ts.tv_nsec;
}

static size_t round_len(size_t len)
{
	return (len + PAGE_SIZE_LOCAL - 1) & ~(PAGE_SIZE_LOCAL - 1);
}

static uint64_t pattern(size_t off)
{
	return 0xc584f00d00000000ULL ^ ((uint64_t)off * 0x9e3779b97f4a7c15ULL);
}

static void map_and_fill(void *base, size_t len)
{
	uint64_t *p;
	size_t off;

	p = mmap(base, len, PROT_READ | PROT_WRITE,
		 MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0);
	if (p == MAP_FAILED) {
		perror("mmap");
		exit(1);
	}
	for (off = 0; off < len; off += sizeof(uint64_t))
		*(uint64_t *)((uint8_t *)base + off) = pattern(off);
}

static uint64_t touch_pages(void *base, size_t len, int write_pages)
{
	volatile uint64_t *slot;
	uint64_t acc = 0;
	size_t off;

	for (off = 0; off < len; off += PAGE_SIZE_LOCAL) {
		slot = (volatile uint64_t *)((uint8_t *)base + off);
		acc ^= *slot;
		if (write_pages)
			*(uint64_t *)((uint8_t *)base + off) = *slot ^ 0x55aa55aa55aa55aaULL;
	}
	return acc;
}

static void write_full(int fd, const void *buf, size_t len)
{
	const uint8_t *p = buf;

	while (len) {
		ssize_t n = write(fd, p, len);

		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0)
			_exit(111);
		p += n;
		len -= (size_t)n;
	}
}

static int read_full(int fd, void *buf, size_t len)
{
	uint8_t *p = buf;

	while (len) {
		ssize_t n = read(fd, p, len);

		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0)
			return -1;
		p += n;
		len -= (size_t)n;
	}
	return 0;
}

static uint64_t avg_u64(const uint64_t *v, int n)
{
	__uint128_t sum = 0;
	int i;

	for (i = 0; i < n; i++)
		sum += v[i];
	return (uint64_t)(sum / (uint64_t)n);
}

static int parse_write_mode(const char *mode)
{
	if (!strcmp(mode, "read"))
		return 0;
	if (!strcmp(mode, "write"))
		return 1;
	fprintf(stderr, "bad mode: %s\n", mode);
	exit(2);
}

static uint64_t tiering_flags(const char *policy)
{
	if (!strcmp(policy, "mow"))
		return CXLFORK_F_MIGRATE_ON_WRITE;
	if (!strcmp(policy, "moa"))
		return CXLFORK_F_MIGRATE_ON_ACCESS;
	if (!strcmp(policy, "hybrid"))
		return CXLFORK_F_HYBRID_TIERING;
	fprintf(stderr, "bad tiering policy: %s\n", policy);
	exit(2);
}

static int run_local(size_t len, int iters, int warmup, int write_pages)
{
	uint64_t *fork_ns;
	uint64_t *touch_ns;
	uint64_t *total_ns;
	uint64_t checksum = 0;
	int i, measured = 0;

	map_and_fill(DEFAULT_BASE, len);
	fork_ns = calloc((size_t)iters, sizeof(*fork_ns));
	touch_ns = calloc((size_t)iters, sizeof(*touch_ns));
	total_ns = calloc((size_t)iters, sizeof(*total_ns));
	if (!fork_ns || !touch_ns || !total_ns) {
		perror("calloc");
		return 1;
	}

	for (i = 0; i < warmup + iters; i++) {
		struct child_result res;
		uint64_t begin;
		int pipefd[2], status;
		pid_t pid;

		if (pipe(pipefd)) {
			perror("pipe");
			return 1;
		}
		begin = nsec_now();
		pid = fork();
		if (pid < 0) {
			perror("fork");
			return 1;
		}
		if (!pid) {
			uint64_t touch_begin;

			close(pipefd[0]);
			memset(&res, 0, sizeof(res));
			res.child_start_ns = nsec_now();
			touch_begin = nsec_now();
			res.checksum = touch_pages(DEFAULT_BASE, len, write_pages);
			res.touch_ns = nsec_now() - touch_begin;
			res.total_child_ns = nsec_now() - res.child_start_ns;
			write_full(pipefd[1], &res, sizeof(res));
			close(pipefd[1]);
			_exit(0);
		}
		close(pipefd[1]);
		if (read_full(pipefd[0], &res, sizeof(res))) {
			fprintf(stderr, "short read from child\n");
			return 1;
		}
		close(pipefd[0]);
		if (waitpid(pid, &status, 0) != pid) {
			perror("waitpid");
			return 1;
		}
		if (!WIFEXITED(status) || WEXITSTATUS(status)) {
			fprintf(stderr, "child failed status=%d\n", status);
			return 1;
		}
		checksum ^= res.checksum;
		if (i >= warmup) {
			fork_ns[measured] = res.child_start_ns - begin;
			touch_ns[measured] = res.touch_ns;
			total_ns[measured] = nsec_now() - begin;
			measured++;
		}
	}

	printf("unified_touch system=LocalFork bytes=%zu mode=%s iters=%d warmup=%d "
	       "fork_to_child_ns=%" PRIu64 " touch_ns=%" PRIu64
	       " total_ns=%" PRIu64 " pages=%zu checksum=%" PRIu64 " verify=ok\n",
	       len, write_pages ? "write" : "read", iters, warmup,
	       avg_u64(fork_ns, iters), avg_u64(touch_ns, iters),
	       avg_u64(total_ns, iters), len / PAGE_SIZE_LOCAL, checksum);
	return 0;
}

static int run_prepare(uint64_t key, size_t len)
{
	struct cxlfork_checkpoint op;
	struct cxlfork_release rel = { .key = key };
	uint64_t checksum;
	int fd;

	map_and_fill(DEFAULT_BASE, len);
	checksum = touch_pages(DEFAULT_BASE, len, 0);

	fd = open(CXLFORK_DEVICE, O_RDWR);
	if (fd < 0) {
		perror(CXLFORK_DEVICE);
		return 1;
	}
	(void)ioctl(fd, CXLFORK_RELEASE, &rel);
	memset(&op, 0, sizeof(op));
	op.key = key;
	op.scan_start = (uintptr_t)DEFAULT_BASE;
	op.scan_end = (uintptr_t)DEFAULT_BASE + len;
	if (ioctl(fd, CXLFORK_FORK_PREPARE, &op)) {
		perror("CXLFORK_FORK_PREPARE");
		close(fd);
		return 1;
	}
	printf("unified_touch_prepare key=%" PRIu64 " bytes=%zu prepare_ns=%" PRIu64
	       " pages=%" PRIu64 " checksum=%" PRIu64 " verify=ok\n",
	       key, len, op.checkpoint_ns, op.total_pages, checksum);
	close(fd);
	return 0;
}

static int read_stats(int fd, uint64_t key, uint64_t *faults)
{
	struct cxlfork_stats st;

	memset(&st, 0, sizeof(st));
	st.key = key;
	if (ioctl(fd, CXLFORK_STATS, &st))
		return -1;
	*faults = st.faults;
	return 0;
}

static int cxlfork_child(uint64_t key, size_t len, int write_pages,
			 const char *policy, uint64_t hot_stride, int pipefd)
{
	struct cxlfork_restore op;
	struct child_result res;
	uint64_t before_faults = 0;
	uint64_t after_faults = 0;
	uint64_t begin;
	uint64_t touch_begin;
	int fd;

	memset(&res, 0, sizeof(res));
	res.child_start_ns = nsec_now();
	fd = open(CXLFORK_DEVICE, O_RDWR);
	if (fd < 0)
		_exit(1);
	memset(&op, 0, sizeof(op));
	op.key = key;
	op.flags = tiering_flags(policy) | CXLFORK_F_APPLY_MM_STATE |
		   CXLFORK_F_APPLY_GLOBAL_STATE | CXLFORK_F_REOPEN_FDS;
	op.tiering_hot_stride_pages = hot_stride;
	begin = nsec_now();
	if (ioctl(fd, CXLFORK_FORK_RESUME, &op))
		_exit(2);
	res.restore_ns = op.restore_ns ? op.restore_ns : nsec_now() - begin;
	res.global_restore_ns = op.global_restore_ns;
	res.pte_attach_ns = op.pte_attach_ns;
	res.pte_attach_pages = op.pte_attach_pages;
	(void)read_stats(fd, key, &before_faults);
	touch_begin = nsec_now();
	res.checksum = touch_pages(DEFAULT_BASE, len, write_pages);
	res.touch_ns = nsec_now() - touch_begin;
	(void)read_stats(fd, key, &after_faults);
	res.faults = after_faults - before_faults;
	res.total_child_ns = nsec_now() - res.child_start_ns;
	write_full(pipefd, &res, sizeof(res));
	close(fd);
	return 0;
}

static int run_resume(uint64_t key, size_t len, int iters, int warmup,
		      int write_pages, const char *policy, uint64_t hot_stride)
{
	uint64_t *fork_ns;
	uint64_t *restore_ns;
	uint64_t *global_restore_ns;
	uint64_t *pte_attach_ns;
	uint64_t *pte_attach_pages;
	uint64_t *touch_ns;
	uint64_t *total_ns;
	uint64_t *faults;
	uint64_t checksum = 0;
	int i, measured = 0;

	fork_ns = calloc((size_t)iters, sizeof(*fork_ns));
	restore_ns = calloc((size_t)iters, sizeof(*restore_ns));
	global_restore_ns = calloc((size_t)iters, sizeof(*global_restore_ns));
	pte_attach_ns = calloc((size_t)iters, sizeof(*pte_attach_ns));
	pte_attach_pages = calloc((size_t)iters, sizeof(*pte_attach_pages));
	touch_ns = calloc((size_t)iters, sizeof(*touch_ns));
	total_ns = calloc((size_t)iters, sizeof(*total_ns));
	faults = calloc((size_t)iters, sizeof(*faults));
	if (!fork_ns || !restore_ns || !global_restore_ns || !pte_attach_ns ||
	    !pte_attach_pages || !touch_ns || !total_ns || !faults) {
		perror("calloc");
		return 1;
	}

	for (i = 0; i < warmup + iters; i++) {
		struct child_result res;
		uint64_t begin;
		int pipefd[2], status;
		pid_t pid;

		if (pipe(pipefd)) {
			perror("pipe");
			return 1;
		}
		begin = nsec_now();
		pid = fork();
		if (pid < 0) {
			perror("fork");
			return 1;
		}
		if (!pid) {
			close(pipefd[0]);
			_exit(cxlfork_child(key, len, write_pages, policy,
					    hot_stride, pipefd[1]));
		}
		close(pipefd[1]);
		if (read_full(pipefd[0], &res, sizeof(res))) {
			fprintf(stderr, "short read from child\n");
			return 1;
		}
		close(pipefd[0]);
		if (waitpid(pid, &status, 0) != pid) {
			perror("waitpid");
			return 1;
		}
		if (!WIFEXITED(status) || WEXITSTATUS(status)) {
			fprintf(stderr, "child failed status=%d\n", status);
			return 1;
		}
		checksum ^= res.checksum;
		if (i >= warmup) {
			fork_ns[measured] = res.child_start_ns - begin;
			restore_ns[measured] = res.restore_ns;
			global_restore_ns[measured] = res.global_restore_ns;
			pte_attach_ns[measured] = res.pte_attach_ns;
			pte_attach_pages[measured] = res.pte_attach_pages;
			touch_ns[measured] = res.touch_ns;
			total_ns[measured] = nsec_now() - begin;
			faults[measured] = res.faults;
			measured++;
		}
	}

	printf("unified_touch system=CXLfork policy=%s hot_stride=%" PRIu64
	       " bytes=%zu mode=%s iters=%d warmup=%d "
	       "fork_to_child_ns=%" PRIu64 " restore_ns=%" PRIu64
	       " global_restore_ns=%" PRIu64 " pte_attach_ns=%" PRIu64
	       " pte_attach_pages=%" PRIu64 " touch_ns=%" PRIu64 " total_ns=%" PRIu64
	       " pages=%zu faults=%" PRIu64 " checksum=%" PRIu64 " verify=ok\n",
	       policy, hot_stride, len, write_pages ? "write" : "read", iters, warmup,
	       avg_u64(fork_ns, iters), avg_u64(restore_ns, iters),
	       avg_u64(global_restore_ns, iters), avg_u64(pte_attach_ns, iters),
	       avg_u64(pte_attach_pages, iters), avg_u64(touch_ns, iters),
	       avg_u64(total_ns, iters),
	       len / PAGE_SIZE_LOCAL, avg_u64(faults, iters), checksum);
	return 0;
}

static void usage(const char *prog)
{
	fprintf(stderr,
		"usage:\n"
		"  %s local <bytes> <iters> <warmup> <read|write>\n"
		"  %s prepare <key> <bytes>\n"
		"  %s resume <key> <bytes> <iters> <warmup> <read|write> [mow|moa|hybrid] [hot_stride_pages]\n",
		prog, prog, prog);
}

int main(int argc, char **argv)
{
	if (argc >= 2 && !strcmp(argv[1], "local")) {
		if (argc != 6) {
			usage(argv[0]);
			return 2;
		}
		return run_local(round_len(strtoull(argv[2], NULL, 0)),
				 atoi(argv[3]), atoi(argv[4]),
				 parse_write_mode(argv[5]));
	}
	if (argc >= 2 && !strcmp(argv[1], "prepare")) {
		if (argc != 4) {
			usage(argv[0]);
			return 2;
		}
		return run_prepare(strtoull(argv[2], NULL, 0),
				   round_len(strtoull(argv[3], NULL, 0)));
	}
	if (argc >= 2 && !strcmp(argv[1], "resume")) {
		const char *policy;
		uint64_t hot_stride;

		if (argc != 7 && argc != 8 && argc != 9) {
			usage(argv[0]);
			return 2;
		}
		policy = argc >= 8 ? argv[7] : "mow";
		hot_stride = argc >= 9 ? strtoull(argv[8], NULL, 0) : 4;
		return run_resume(strtoull(argv[2], NULL, 0),
				  round_len(strtoull(argv[3], NULL, 0)),
				  atoi(argv[4]), atoi(argv[5]),
				  parse_write_mode(argv[6]), policy, hot_stride);
	}
	usage(argv[0]);
	return 2;
}
