// SPDX-License-Identifier: MIT
#define _GNU_SOURCE
#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

#define PAGE_SIZE_LOCAL 4096UL
#define DEFAULT_BASE ((void *)0x775000000000ULL)

enum workload_kind {
	WORKLOAD_NONE,
	WORKLOAD_TOUCH,
	WORKLOAD_FLOAT,
	WORKLOAD_JSON,
	WORKLOAD_PYAES,
	WORKLOAD_HTML,
};

struct child_result {
	uint64_t child_start_ns;
	uint64_t touch_ns;
	uint64_t workload_ns;
	uint64_t checksum;
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

static enum workload_kind parse_workload(const char *name)
{
	if (!strcmp(name, "none"))
		return WORKLOAD_NONE;
	if (!strcmp(name, "touch"))
		return WORKLOAD_TOUCH;
	if (!strcmp(name, "float") || !strcmp(name, "Float"))
		return WORKLOAD_FLOAT;
	if (!strcmp(name, "json") || !strcmp(name, "Json"))
		return WORKLOAD_JSON;
	if (!strcmp(name, "pyaes") || !strcmp(name, "Pyaes"))
		return WORKLOAD_PYAES;
	if (!strcmp(name, "html") || !strcmp(name, "HTML"))
		return WORKLOAD_HTML;
	fprintf(stderr, "unknown workload: %s\n", name);
	exit(2);
}

static const char *workload_name(enum workload_kind kind)
{
	switch (kind) {
	case WORKLOAD_NONE:
		return "none";
	case WORKLOAD_TOUCH:
		return "touch";
	case WORKLOAD_FLOAT:
		return "Float";
	case WORKLOAD_JSON:
		return "Json";
	case WORKLOAD_PYAES:
		return "Pyaes";
	case WORKLOAD_HTML:
		return "HTML";
	}
	return "unknown";
}

static uint8_t byte_pattern(size_t i, enum workload_kind kind)
{
	static const char json_chars[] =
		"{\"key\":12345,\"value\":\"abcdef\",\"items\":[1,2,3,4]},";
	static const char html_chars[] =
		"<div class=\"item\"><span>cxlfork benchmark</span></div>\n";

	if (kind == WORKLOAD_JSON)
		return json_chars[i % (sizeof(json_chars) - 1)];
	if (kind == WORKLOAD_HTML)
		return html_chars[i % (sizeof(html_chars) - 1)];
	return (uint8_t)((i * 1315423911ULL + (uint64_t)kind * 17ULL) >> 8);
}

static void map_and_fill(size_t len, enum workload_kind kind)
{
	uint8_t *p;
	size_t i;

	if (!len)
		return;
	p = mmap(DEFAULT_BASE, len, PROT_READ | PROT_WRITE,
		 MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0);
	if (p == MAP_FAILED) {
		perror("mmap workload");
		exit(1);
	}
	for (i = 0; i < len; i++)
		p[i] = byte_pattern(i, kind);
}

static uint64_t touch_pages(size_t len, int write_pages)
{
	volatile uint8_t *p = DEFAULT_BASE;
	uint64_t sum = 0;
	size_t i;

	for (i = 0; i < len; i += PAGE_SIZE_LOCAL) {
		sum += p[i];
		if (write_pages)
			((uint8_t *)DEFAULT_BASE)[i] ^= 0x5a;
	}
	return sum;
}

static uint64_t run_float(size_t len)
{
	volatile uint8_t *p = DEFAULT_BASE;
	size_t count = len / sizeof(double);
	double acc = 1.000001;
	size_t i;

	for (i = 0; i < count; i++) {
		double v = (double)(p[(i * sizeof(double)) % len] + 1) * 0.0009765625;

		acc = acc * 1.0000001 + v;
		if (acc > 4096.0)
			acc *= 0.25;
	}
	return (uint64_t)(acc * 1000000.0);
}

static uint64_t run_json(size_t len)
{
	volatile uint8_t *p = DEFAULT_BASE;
	uint64_t score = 0;
	int depth = 0;
	size_t i;

	for (i = 0; i < len; i++) {
		uint8_t c = p[i];

		if (c == '{' || c == '[')
			depth++;
		else if ((c == '}' || c == ']') && depth > 0)
			depth--;
		else if (c >= '0' && c <= '9')
			score += (uint64_t)(c - '0') * (uint64_t)(depth + 1);
		else if (c == '"')
			score ^= i;
	}
	return score ^ (uint64_t)depth;
}

static uint64_t run_pyaes(size_t len)
{
	volatile uint8_t *p = DEFAULT_BASE;
	uint32_t s0 = 0x00112233U;
	uint32_t s1 = 0x44556677U;
	uint32_t s2 = 0x8899aabbU;
	uint32_t s3 = 0xccddeeffU;
	size_t i;

	for (i = 0; i < len; i++) {
		uint32_t b = p[i];

		s0 = ((s0 << 5) | (s0 >> 27)) ^ (b + s3);
		s1 = ((s1 << 7) | (s1 >> 25)) + (s0 ^ (b * 0x45d9f3bU));
		s2 = ((s2 << 11) | (s2 >> 21)) ^ (s1 + 0x9e3779b9U);
		s3 = ((s3 << 13) | (s3 >> 19)) + (s2 ^ b);
	}
	return ((uint64_t)s0 << 32) ^ s1 ^ s2 ^ s3;
}

static uint64_t run_html(size_t len)
{
	volatile uint8_t *p = DEFAULT_BASE;
	uint64_t tags = 0;
	uint64_t text = 0;
	int in_tag = 0;
	size_t i;

	for (i = 0; i < len; i++) {
		uint8_t c = p[i];

		if (c == '<') {
			in_tag = 1;
			tags++;
		} else if (c == '>') {
			in_tag = 0;
		} else if (!in_tag && c > ' ') {
			text += c;
		}
	}
	return (tags << 32) ^ text;
}

static uint64_t run_workload(size_t len, enum workload_kind kind)
{
	if (!len || kind == WORKLOAD_NONE)
		return 1;
	switch (kind) {
	case WORKLOAD_TOUCH:
		return touch_pages(len, 0);
	case WORKLOAD_FLOAT:
		return run_float(len);
	case WORKLOAD_JSON:
		return run_json(len);
	case WORKLOAD_PYAES:
		return run_pyaes(len);
	case WORKLOAD_HTML:
		return run_html(len);
	case WORKLOAD_NONE:
		return 1;
	}
	return 1;
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

static int cmp_u64(const void *a, const void *b)
{
	uint64_t va = *(const uint64_t *)a;
	uint64_t vb = *(const uint64_t *)b;

	return (va > vb) - (va < vb);
}

static uint64_t avg_u64(const uint64_t *v, int n)
{
	__uint128_t sum = 0;
	int i;

	for (i = 0; i < n; i++)
		sum += v[i];
	return (uint64_t)(sum / (uint64_t)n);
}

static uint64_t pct_u64(uint64_t *v, int n, int pct)
{
	int idx = (n * pct) / 100;

	if (idx >= n)
		idx = n - 1;
	qsort(v, n, sizeof(*v), cmp_u64);
	return v[idx];
}

static void usage(const char *prog)
{
	fprintf(stderr,
		"usage: %s <workload> <bytes> <iters> <warmup> <read|write|none>\n",
		prog);
}

int main(int argc, char **argv)
{
	enum workload_kind kind;
	size_t len;
	int iters, warmup, write_pages, run_payload;
	uint64_t *fork_ns, *touch_ns, *workload_ns, *total_ns;
	uint64_t *total_sorted;
	uint64_t checksum = 0;
	int i, measured = 0;

	if (argc != 6) {
		usage(argv[0]);
		return 2;
	}
	kind = parse_workload(argv[1]);
	len = round_len(strtoull(argv[2], NULL, 0));
	iters = atoi(argv[3]);
	warmup = atoi(argv[4]);
	write_pages = !strcmp(argv[5], "write");
	run_payload = strcmp(argv[5], "none") != 0;
	if (iters <= 0 || warmup < 0) {
		usage(argv[0]);
		return 2;
	}
	map_and_fill(len, kind);

	fork_ns = calloc((size_t)iters, sizeof(*fork_ns));
	touch_ns = calloc((size_t)iters, sizeof(*touch_ns));
	workload_ns = calloc((size_t)iters, sizeof(*workload_ns));
	total_ns = calloc((size_t)iters, sizeof(*total_ns));
	total_sorted = calloc((size_t)iters, sizeof(*total_sorted));
	if (!fork_ns || !touch_ns || !workload_ns || !total_ns || !total_sorted) {
		perror("calloc");
		return 1;
	}

	for (i = 0; i < warmup + iters; i++) {
		struct child_result res;
		uint64_t begin, touch_begin, workload_begin, total;
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
			memset(&res, 0, sizeof(res));
			res.child_start_ns = nsec_now();
			if (run_payload) {
				touch_begin = nsec_now();
				res.checksum ^= touch_pages(len, write_pages);
				res.touch_ns = nsec_now() - touch_begin;
				workload_begin = nsec_now();
				res.checksum ^= run_workload(len, kind);
				res.workload_ns = nsec_now() - workload_begin;
			}
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
		total = nsec_now() - begin;
		if (!WIFEXITED(status) || WEXITSTATUS(status)) {
			fprintf(stderr, "child failed status=%d\n", status);
			return 1;
		}
		checksum ^= res.checksum;
		if (i >= warmup) {
			fork_ns[measured] = res.child_start_ns - begin;
			touch_ns[measured] = res.touch_ns;
			workload_ns[measured] = res.workload_ns;
			total_ns[measured] = total;
			total_sorted[measured] = total;
			measured++;
		}
	}

	printf("local_fork_bare workload=%s bytes=%zu iters=%d warmup=%d mode=%s "
	       "fork_to_child_ns=%" PRIu64 " touch_ns=%" PRIu64
	       " workload_ns=%" PRIu64 " total_ns=%" PRIu64
	       " p50_total_ns=%" PRIu64 " p90_total_ns=%" PRIu64
	       " p99_total_ns=%" PRIu64 " pages=%zu checksum=%" PRIu64
	       " verify=ok\n",
	       workload_name(kind), len, iters, warmup, argv[5],
	       avg_u64(fork_ns, iters), avg_u64(touch_ns, iters),
	       avg_u64(workload_ns, iters), avg_u64(total_ns, iters),
	       pct_u64(total_sorted, iters, 50),
	       pct_u64(total_sorted, iters, 90),
	       pct_u64(total_sorted, iters, 99),
	       len / PAGE_SIZE_LOCAL, checksum);
	return 0;
}
