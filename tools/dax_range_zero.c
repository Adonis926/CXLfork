#define _FILE_OFFSET_BITS 64
#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define EXPECTED_DEVICE "/dev/dax0.0"
#define EXPECTED_SYSFS "/sys/bus/dax/devices/dax0.0"
#define EXPECTED_DEVICE_SIZE (64ULL * 1024 * 1024 * 1024)
#define EXPECTED_ALIGN (2ULL * 1024 * 1024)
#define ALLOWED_OFFSET (4ULL * 1024 * 1024 * 1024)
#define ALLOWED_LENGTH (8ULL * 1024 * 1024 * 1024)
#define CONFIRM_TOKEN "ZERO-CXLFORK-MR-4G-12G"

static void fail(const char *what)
{
	perror(what);
	exit(EXIT_FAILURE);
}

static uint64_t parse_u64(const char *text, const char *name)
{
	char *end = NULL;
	unsigned long long value;

	errno = 0;
	value = strtoull(text, &end, 0);
	if (errno || !end || *end != '\0') {
		fprintf(stderr, "invalid %s: %s\n", name, text);
		exit(EXIT_FAILURE);
	}
	return (uint64_t)value;
}

static uint64_t read_u64_file(const char *path)
{
	uint64_t value;
	FILE *file = fopen(path, "re");

	if (!file)
		fail(path);
	if (fscanf(file, "%" SCNu64, &value) != 1) {
		fprintf(stderr, "cannot parse %s\n", path);
		exit(EXIT_FAILURE);
	}
	if (fclose(file))
		fail(path);
	return value;
}

static double elapsed_seconds(const struct timespec *begin,
			      const struct timespec *end)
{
	return (double)(end->tv_sec - begin->tv_sec) +
	       (double)(end->tv_nsec - begin->tv_nsec) / 1000000000.0;
}

int main(int argc, char **argv)
{
	char driver[256];
	char path[256];
	struct stat st;
	struct timespec zero_begin, zero_end, verify_end;
	uint64_t offset, length, device_size, align;
	unsigned char *mapping;
	ssize_t driver_len;
	size_t chunk = (size_t)EXPECTED_ALIGN;
	uint64_t position;
	int fd;

	if (argc != 5) {
		fprintf(stderr,
			"usage: %s /dev/dax0.0 OFFSET_BYTES LENGTH_BYTES %s\n",
			argv[0], CONFIRM_TOKEN);
		return EXIT_FAILURE;
	}
	if (strcmp(argv[1], EXPECTED_DEVICE) != 0 ||
	    strcmp(argv[4], CONFIRM_TOKEN) != 0) {
		fprintf(stderr, "device or confirmation token does not match the locked profile\n");
		return EXIT_FAILURE;
	}
	offset = parse_u64(argv[2], "offset");
	length = parse_u64(argv[3], "length");
	if (offset != ALLOWED_OFFSET || length != ALLOWED_LENGTH) {
		fprintf(stderr,
			"refusing range [0x%" PRIx64 ",0x%" PRIx64
			"); only [4 GiB,12 GiB) is permitted\n",
			offset, offset + length);
		return EXIT_FAILURE;
	}
	if (offset % EXPECTED_ALIGN || length % EXPECTED_ALIGN ||
	    offset > UINT64_MAX - length) {
		fprintf(stderr, "range is not valid and 2 MiB aligned\n");
		return EXIT_FAILURE;
	}
	if (stat(EXPECTED_DEVICE, &st) || !S_ISCHR(st.st_mode)) {
		fprintf(stderr, "%s is not an accessible character device\n", EXPECTED_DEVICE);
		return EXIT_FAILURE;
	}

	snprintf(path, sizeof(path), "%s/size", EXPECTED_SYSFS);
	device_size = read_u64_file(path);
	snprintf(path, sizeof(path), "%s/align", EXPECTED_SYSFS);
	align = read_u64_file(path);
	if (device_size != EXPECTED_DEVICE_SIZE || align != EXPECTED_ALIGN ||
	    offset + length > device_size) {
		fprintf(stderr,
			"unexpected DAX geometry size=%" PRIu64 " align=%" PRIu64 "\n",
			device_size, align);
		return EXIT_FAILURE;
	}
	snprintf(path, sizeof(path), "%s/driver", EXPECTED_SYSFS);
	driver_len = readlink(path, driver, sizeof(driver) - 1);
	if (driver_len < 0)
		fail(path);
	driver[driver_len] = '\0';
	if (!strstr(driver, "device_dax")) {
		fprintf(stderr, "refusing DAX driver %s (expected device_dax)\n", driver);
		return EXIT_FAILURE;
	}

	fd = open(EXPECTED_DEVICE, O_RDWR | O_SYNC);
	if (fd < 0)
		fail("open DAX device");
	mapping = mmap(NULL, (size_t)length, PROT_READ | PROT_WRITE, MAP_SHARED,
		       fd, (off_t)offset);
	if (mapping == MAP_FAILED)
		fail("mmap DAX range");

	printf("zeroing device=%s range=[0x%" PRIx64 ",0x%" PRIx64
	       ") bytes=%" PRIu64 "\n", EXPECTED_DEVICE, offset,
	       offset + length, length);
	if (clock_gettime(CLOCK_MONOTONIC, &zero_begin))
		fail("clock_gettime");
	for (position = 0; position < length; position += chunk)
		memset(mapping + position, 0, chunk);
	if (msync(mapping, (size_t)length, MS_SYNC))
		fail("msync DAX range");
	if (clock_gettime(CLOCK_MONOTONIC, &zero_end))
		fail("clock_gettime");

	for (position = 0; position < length; position++) {
		if (mapping[position] != 0) {
			fprintf(stderr, "verification failed at device offset 0x%" PRIx64 "\n",
				offset + position);
			return EXIT_FAILURE;
		}
	}
	if (clock_gettime(CLOCK_MONOTONIC, &verify_end))
		fail("clock_gettime");

	printf("zero_seconds=%.6f zero_gib_per_s=%.3f verify_seconds=%.6f verify=ok\n",
	       elapsed_seconds(&zero_begin, &zero_end),
	       ((double)length / (1024.0 * 1024.0 * 1024.0)) /
	       elapsed_seconds(&zero_begin, &zero_end),
	       elapsed_seconds(&zero_end, &verify_end));
	if (munmap(mapping, (size_t)length))
		fail("munmap DAX range");
	if (close(fd))
		fail("close DAX device");
	return EXIT_SUCCESS;
}
