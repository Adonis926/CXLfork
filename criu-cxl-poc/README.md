# CRIU-CXL Userspace Prototype

This is a small cooperative checkpoint/restore prototype for the CXLfork
workspace. It follows the CRIU idea of serializing process state, but writes the
image into `/dev/dax0.0` instead of image files.

It is not a transparent CRIU replacement. Without kernel help, this program
cannot freeze an arbitrary process and restore CPU registers, kernel task state,
or page tables. Instead, the target process cooperates by serializing:

- a metadata header,
- lightweight OS-visible state such as cwd and a file offset,
- a synthetic heap memory footprint,
- a resume counter.

VM0 can checkpoint into the shared devdax region and VM1 can restore from the
same region.

## Build

```bash
make
```

## Run

On VM0:

```bash
sudo ./criu-cxl-poc checkpoint --dax /dev/dax0.0 --mb 16 --iters 200000
```

On VM1:

```bash
sudo ./criu-cxl-poc restore --dax /dev/dax0.0 --iters 200000
```

Expected restore output includes `verify=ok` and `continued=ok`.

## Docker-compatible CXL path

This mode keeps the same CXL data path, but runs the checkpoint and restore
program inside Docker containers. The container receives `/dev/dax0.0` as a
device and writes the checkpoint image directly into shared CXL memory.

Build the static binary and scratch image on each VM:

```bash
make clean docker-image
```

If the current shell is not in the `docker` group yet:

```bash
make clean DOCKER='sudo docker' docker-image
```

On VM0:

```bash
sudo ./docker-vm0-checkpoint.sh
```

On VM1:

```bash
sudo ./docker-vm1-restore.sh
```

The checkpoint header records the container process PID, PPID, hostname, cwd,
and cgroup line. Restore output includes the source container PID and the new
restore container PID. This is still cooperative process restore rather than a
transparent restoration of an arbitrary Docker container runtime state.
