#ifndef CXLFORK_LEAN_CONTAINER_H
#define CXLFORK_LEAN_CONTAINER_H

#include <sys/types.h>

struct ContainerSpec {
	int cpu_start;
	int cpu_end;
	long memory_in_mb;
	int numa_start;
	int numa_end;
};

enum ContainerState {
	CONTAINER_ERROR = -1,
	CONTAINER_PAUSED = 0,
	CONTAINER_PAUSING = 1,
	CONTAINER_RUNNING = 2,
};

int init_cgroup(void);
int deinit_cgroup(void);
int add_lean_container_template(char *name, struct ContainerSpec *spec);
int remove_lean_container_template(char *name);
int setup_cached_namespace(char *rootfs);
int remove_cached_namespace(int namespace_pid, char *rootfs);
int setup_lean_container(char *name, char *rootfs_path, int namespace_pid);
int setup_lean_container_w_double_fork(char *name, char *rootfs_path,
				       int namespace_pid);
int pause_container(char *name);
int unpause_container(char *name);
int get_container_state(char *name);

#endif
