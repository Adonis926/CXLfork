#define _GNU_SOURCE
#include "cxlfork_lean_container.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static long long nsec_now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static int wait_for_exit(pid_t pid)
{
	int st;

	if (waitpid(pid, &st, 0) != pid) {
		if (errno != ECHILD)
			return -1;
		while (kill(pid, 0) == 0)
			usleep(1000);
		return 0;
	}
	if (!WIFEXITED(st))
		return -1;
	return WEXITSTATUS(st);
}

int main(int argc, char **argv)
{
	struct ContainerSpec spec = {
		.cpu_start = -1,
		.cpu_end = -1,
		.memory_in_mb = -1,
		.numa_start = -1,
		.numa_end = -1,
	};
	const char *mode;
	char *name;
	char *rootfs;
	int cmd_index;
	int cached_ns = -1;
	long long start;
	long long setup_ns;
	pid_t pid;
	char cwd[4096];

	if (argc < 5) {
		fprintf(stderr,
			"usage: %s process|namespace|rootfs <name> <rootfs|none> -- command...\n",
			argv[0]);
		return 2;
	}

	mode = argv[1];
	name = argv[2];
	rootfs = !strcmp(argv[3], "none") ? NULL : argv[3];
	cmd_index = 4;
	if (!strcmp(argv[cmd_index], "--"))
		cmd_index++;
	if (cmd_index >= argc)
		return 2;
	if (!getcwd(cwd, sizeof(cwd))) {
		perror("getcwd");
		return 1;
	}

	if (init_cgroup()) {
		perror("init_cgroup");
		return 1;
	}
	if (add_lean_container_template(name, &spec)) {
		perror("add_lean_container_template");
		return 1;
	}

	start = nsec_now();
	if (!strcmp(mode, "process")) {
		pid = fork();
		if (pid == 0) {
			execvp(argv[cmd_index], &argv[cmd_index]);
			perror("execvp");
			_exit(127);
		}
		if (pid > 0)
			(void)pause_container(name), (void)unpause_container(name);
	} else {
		if (!strcmp(mode, "rootfs-cached")) {
			cached_ns = setup_cached_namespace(rootfs);
			if (cached_ns < 0) {
				perror("setup_cached_namespace");
				return 1;
			}
			pid = setup_lean_container_w_double_fork(name, rootfs, cached_ns);
		} else {
			pid = setup_lean_container_w_double_fork(name, rootfs, -1);
		}
	}
	setup_ns = nsec_now() - start;
	if (pid < 0) {
		perror("setup_lean_container");
		return 1;
	}
	if (pid == 0) {
		(void)chdir(cwd);
		execvp(argv[cmd_index], &argv[cmd_index]);
		perror("execvp");
		_exit(127);
	}

	{
		int rc = wait_for_exit(pid);

		if (cached_ns > 0)
			(void)remove_cached_namespace(cached_ns, rootfs);
		(void)remove_lean_container_template(name);
		printf("cxlfork_lean_exec mode=%s name=%s pid=%ld setup_ns=%lld rc=%d\n",
		       mode, name, (long)pid, setup_ns, rc);
		return rc == 0 ? 0 : 1;
	}
}
