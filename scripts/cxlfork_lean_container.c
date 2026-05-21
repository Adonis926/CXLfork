#define _GNU_SOURCE
#include "cxlfork_lean_container.h"

#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define BUF_SIZE 512
#define DEFAULT_MODE 0755

static const char *cgroup_root(void)
{
	const char *root = getenv("CXLFORK_CGROUP_ROOT");

	return root && root[0] ? root : "/sys/fs/cgroup/cxlfork-bench";
}

static const char *python_user_site(void)
{
	const char *site = getenv("PYTHON_USER_SITE");

	return site && site[0] ? site : "/home/ubuntu/.local/lib/python3.12/site-packages";
}

static int write_file(const char *path, const char *value)
{
	int fd;
	ssize_t n;
	size_t len = strlen(value);

	fd = open(path, O_WRONLY | O_CLOEXEC);
	if (fd < 0)
		return -errno;
	n = write(fd, value, len);
	close(fd);
	if (n != (ssize_t)len)
		return -EIO;
	return 0;
}

static int mkdir_p(const char *path, mode_t mode)
{
	char tmp[BUF_SIZE];
	char *p;

	snprintf(tmp, sizeof(tmp), "%s", path);
	for (p = tmp + 1; *p; p++) {
		if (*p != '/')
			continue;
		*p = '\0';
		if (mkdir(tmp, mode) && errno != EEXIST)
			return -errno;
		*p = '/';
	}
	if (mkdir(tmp, mode) && errno != EEXIST)
		return -errno;
	return 0;
}

static int cgroup_path(char *buf, size_t len, const char *name)
{
	int n;

	if (name && name[0])
		n = snprintf(buf, len, "%s/%s", cgroup_root(), name);
	else
		n = snprintf(buf, len, "%s", cgroup_root());
	return n > 0 && (size_t)n < len ? 0 : -ENAMETOOLONG;
}

static int join_cgroup(pid_t pid, const char *name)
{
	char path[BUF_SIZE];
	char pidbuf[32];
	int ret;

	ret = cgroup_path(path, sizeof(path), name);
	if (ret)
		return ret;
	strncat(path, "/cgroup.procs", sizeof(path) - strlen(path) - 1);
	snprintf(pidbuf, sizeof(pidbuf), "%d", pid);
	return write_file(path, pidbuf);
}

static int bind_mount(const char *src, const char *dst)
{
	if (mkdir_p(dst, DEFAULT_MODE))
		return -1;
	if (mount(src, dst, NULL, MS_BIND | MS_REC, NULL) && errno != EBUSY) {
		perror("mount --bind");
		fprintf(stderr, "bind src=%s dst=%s\n", src, dst);
		return -1;
	}
	return 0;
}

static int prepare_bind_rootfs(const char *rootfs)
{
	char dst[BUF_SIZE];

	if (!rootfs || !rootfs[0])
		return 0;
	if (mkdir_p(rootfs, DEFAULT_MODE))
		return -1;
	if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) && errno != EINVAL)
		perror("mount private");

	snprintf(dst, sizeof(dst), "%s/usr", rootfs);
	if (bind_mount("/usr", dst))
		return -1;
	snprintf(dst, sizeof(dst), "%s/lib", rootfs);
	if (bind_mount("/lib", dst))
		return -1;
	snprintf(dst, sizeof(dst), "%s/lib64", rootfs);
	if (bind_mount("/lib64", dst))
		return -1;
	snprintf(dst, sizeof(dst), "%s/bin", rootfs);
	if (bind_mount("/bin", dst))
		return -1;
	snprintf(dst, sizeof(dst), "%s/etc", rootfs);
	if (bind_mount("/etc", dst))
		return -1;
	snprintf(dst, sizeof(dst), "%s/tmp", rootfs);
	if (bind_mount("/tmp", dst))
		return -1;
	snprintf(dst, sizeof(dst), "%s/dev", rootfs);
	if (bind_mount("/dev", dst))
		return -1;
	snprintf(dst, sizeof(dst), "%s/home/ubuntu/.local", rootfs);
	if (bind_mount("/home/ubuntu/.local", dst))
		return -1;
	snprintf(dst, sizeof(dst), "%s/sys/fs/cgroup", rootfs);
	if (bind_mount("/sys/fs/cgroup", dst))
		return -1;
	snprintf(dst, sizeof(dst), "%s/proc", rootfs);
	if (mkdir_p(dst, DEFAULT_MODE))
		return -1;
	if (mount("proc", dst, "proc", 0, NULL) && errno != EBUSY) {
		perror("mount proc");
		return -1;
	}
	return 0;
}

static int enter_rootfs(const char *rootfs)
{
	if (!rootfs || !rootfs[0])
		return 0;
	if (chdir(rootfs)) {
		perror("chdir rootfs");
		return -1;
	}
	if (chroot(".")) {
		perror("chroot");
		return -1;
	}
	if (chdir("/")) {
		perror("chdir /");
		return -1;
	}
	setenv("PYTHONPATH", python_user_site(), 1);
	return 0;
}

int init_cgroup(void)
{
	return mkdir_p(cgroup_root(), DEFAULT_MODE);
}

int deinit_cgroup(void)
{
	return 0;
}

int add_lean_container_template(char *name, struct ContainerSpec *spec)
{
	char path[BUF_SIZE];
	char file[BUF_SIZE];
	char value[64];
	int ret;

	(void)spec;
	ret = cgroup_path(path, sizeof(path), name);
	if (ret)
		return ret;
	ret = mkdir_p(path, DEFAULT_MODE);
	if (ret)
		return ret;
	if (spec && spec->memory_in_mb > 0) {
		snprintf(file, sizeof(file), "%s/memory.max", path);
		snprintf(value, sizeof(value), "%ld", spec->memory_in_mb * 1024L * 1024L);
		(void)write_file(file, value);
	}
	return 0;
}

int remove_lean_container_template(char *name)
{
	char path[BUF_SIZE];

	if (cgroup_path(path, sizeof(path), name))
		return -1;
	if (rmdir(path) && errno != ENOENT && errno != EBUSY)
		return -errno;
	return 0;
}

static void namespace_sleeper(int *pipefd, char *rootfs)
{
	pid_t pid = -1;

	close(pipefd[0]);
	if (unshare(CLONE_NEWUTS | CLONE_NEWPID | CLONE_NEWIPC | CLONE_NEWNS) < 0) {
		perror("unshare");
		goto out;
	}
	if (prepare_bind_rootfs(rootfs))
		goto out;
	pid = fork();
	if (pid < 0) {
		perror("fork");
		goto out;
	}
	if (pid == 0) {
		close(pipefd[1]);
		if (enter_rootfs(rootfs))
			_exit(1);
		for (;;)
			pause();
	}
out:
	write(pipefd[1], &pid, sizeof(pid));
	close(pipefd[1]);
	_exit(pid < 0 ? 1 : 0);
}

int setup_cached_namespace(char *rootfs)
{
	int pipefd[2];
	pid_t pid;
	pid_t child = -1;

	if (pipe(pipefd))
		return -1;
	pid = fork();
	if (pid < 0)
		return -1;
	if (pid == 0)
		namespace_sleeper(pipefd, rootfs);
	close(pipefd[1]);
	(void)read(pipefd[0], &child, sizeof(child));
	close(pipefd[0]);
	(void)waitpid(pid, NULL, 0);
	return child;
}

int remove_cached_namespace(int namespace_pid, char *rootfs)
{
	(void)rootfs;
	if (namespace_pid > 0)
		return kill(namespace_pid, SIGKILL);
	return 0;
}

static int set_namespace(pid_t pid)
{
	const char *names[] = { "uts", "ipc", "mnt", "pid", NULL };
	char path[BUF_SIZE];
	int fd;
	int i;

	for (i = 0; names[i]; i++) {
		snprintf(path, sizeof(path), "/proc/%d/ns/%s", pid, names[i]);
		fd = open(path, O_RDONLY | O_CLOEXEC);
		if (fd < 0)
			return -1;
		if (setns(fd, 0)) {
			close(fd);
			return -1;
		}
		close(fd);
	}
	return 0;
}

int setup_lean_container(char *name, char *rootfs_path, int namespace_pid)
{
	int pipefd[2];
	pid_t pid;
	char token;

	if (pipe(pipefd))
		return -1;
	if (namespace_pid < 0) {
		if (unshare(CLONE_NEWUTS | CLONE_NEWPID | CLONE_NEWIPC | CLONE_NEWNS)) {
			perror("unshare");
			goto err;
		}
		if (prepare_bind_rootfs(rootfs_path))
			goto err;
	} else if (set_namespace(namespace_pid)) {
		perror("setns");
		goto err;
	}

	pid = fork();
	if (pid < 0)
		goto err;
	if (pid > 0) {
		close(pipefd[0]);
		if (join_cgroup(pid, name))
			perror("join_cgroup");
		token = 'x';
		(void)write(pipefd[1], &token, 1);
		close(pipefd[1]);
		return pid;
	}

	close(pipefd[1]);
	(void)read(pipefd[0], &token, 1);
	close(pipefd[0]);
	if (enter_rootfs(rootfs_path))
		_exit(1);
	return 0;

err:
	close(pipefd[0]);
	close(pipefd[1]);
	return -1;
}

int setup_lean_container_w_double_fork(char *name, char *rootfs_path,
				       int namespace_pid)
{
	int pipefd[2];
	pid_t pid;
	pid_t child = -1;

	if (pipe(pipefd))
		return -1;
	pid = fork();
	if (pid < 0)
		return -1;
	if (pid == 0) {
		close(pipefd[0]);
		child = setup_lean_container(name, rootfs_path, namespace_pid);
		if (child > 0) {
			(void)write(pipefd[1], &child, sizeof(child));
			close(pipefd[1]);
			_exit(0);
		}
		if (child == 0) {
			close(pipefd[1]);
			return 0;
		}
		_exit(1);
	}
	close(pipefd[1]);
	(void)read(pipefd[0], &child, sizeof(child));
	close(pipefd[0]);
	(void)waitpid(pid, NULL, 0);
	return child;
}

int pause_container(char *name)
{
	char path[BUF_SIZE];
	char file[BUF_SIZE];

	if (cgroup_path(path, sizeof(path), name))
		return -1;
	snprintf(file, sizeof(file), "%s/cgroup.freeze", path);
	return write_file(file, "1");
}

int unpause_container(char *name)
{
	char path[BUF_SIZE];
	char file[BUF_SIZE];

	if (cgroup_path(path, sizeof(path), name))
		return -1;
	snprintf(file, sizeof(file), "%s/cgroup.freeze", path);
	return write_file(file, "0");
}

int get_container_state(char *name)
{
	char path[BUF_SIZE];
	char file[BUF_SIZE];
	char state[16] = { 0 };
	int fd;
	ssize_t n;

	if (cgroup_path(path, sizeof(path), name))
		return CONTAINER_ERROR;
	snprintf(file, sizeof(file), "%s/cgroup.freeze", path);
	fd = open(file, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return CONTAINER_ERROR;
	n = read(fd, state, sizeof(state) - 1);
	close(fd);
	if (n <= 0)
		return CONTAINER_ERROR;
	return state[0] == '1' ? CONTAINER_PAUSED : CONTAINER_RUNNING;
}
