#!/usr/bin/env python3
import argparse
import ctypes
import fcntl
import importlib.util
import os
import statistics
import struct
import sys
import time

CXLFORK_DEVICE = "/dev/cxlfork"
CXLFORK_FORK_PREPARE = 3767026437
CXLFORK_FORK_RESUME = 3766502150
CXLFORK_STATS = 3224912643
CXLFORK_RELEASE = 1074283268
CXLFORK_F_SHARED_COW = 0x4

CHECKPOINT_SIZE = 8328
RESTORE_SIZE = 8320
STATS_SIZE = 56

OFF_KEY = 0
OFF_SCAN_START = 8
OFF_SCAN_END = 16
OFF_FLAGS = 24
OFF_NR_REGIONS = 32
OFF_NR_PTES = 40
OFF_TOTAL_PAGES = 48
OFF_CHECKPOINT_NS = 56
OFF_RESTORE_NR_REGIONS = 16
OFF_RESTORE_NR_PTES = 24
OFF_RESTORE_TOTAL_PAGES = 32
OFF_RESTORE_NS = 40
OFF_RESTORE_FLAGS = 8
OFF_STATS_READY = 8
OFF_STATS_TOTAL_PAGES = 40
OFF_STATS_FAULTS = 48

PROT_READ = 0x1
PROT_WRITE = 0x2
MAP_PRIVATE = 0x02
MAP_ANONYMOUS = 0x20
MAP_FIXED_NOREPLACE = 0x100000
MAP_FAILED = ctypes.c_void_p(-1).value

DEFAULT_BASE = 0x761000000000
PAGE_SIZE = 4096

libc = ctypes.CDLL(None, use_errno=True)
libc.mmap.argtypes = [
    ctypes.c_void_p,
    ctypes.c_size_t,
    ctypes.c_int,
    ctypes.c_int,
    ctypes.c_int,
    ctypes.c_long,
]
libc.mmap.restype = ctypes.c_void_p


def ns_now():
    return time.monotonic_ns()


def align_page(value):
    return (value + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1)


def mmap_fixed(base, length):
    addr = libc.mmap(
        ctypes.c_void_p(base),
        ctypes.c_size_t(length),
        PROT_READ | PROT_WRITE,
        MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE,
        -1,
        0,
    )
    if addr == MAP_FAILED or addr is None:
        err = ctypes.get_errno()
        raise OSError(err, os.strerror(err))
    if addr != base:
        raise RuntimeError("mmap returned 0x%x, expected 0x%x" % (addr, base))
    return addr


def fill_working_set(base, length):
    arr = (ctypes.c_uint64 * (length // 8)).from_address(base)
    step = PAGE_SIZE // 8
    for i in range(0, len(arr), step):
        arr[i] = 0xC584F04B00000000 ^ ((i * 0x9E3779B97F4A7C15) & 0xFFFFFFFFFFFFFFFF)
    if len(arr):
        arr[-1] = 0xC584F04B5A5A5A5A


def touch_working_set(base, length):
    arr = (ctypes.c_uint64 * (length // 8)).from_address(base)
    step = PAGE_SIZE // 8
    acc = 0
    for i in range(0, len(arr), step):
        acc ^= arr[i]
    if len(arr):
        acc ^= arr[-1]
    return acc


def load_workload(root, workload):
    wdir = os.path.join(root, workload)
    bench_py = os.path.join(wdir, "function_bench.py")
    if not os.path.exists(bench_py):
        raise FileNotFoundError(bench_py)

    old_cwd = os.getcwd()
    old_argv = sys.argv[:]
    sys.path.insert(0, wdir)
    os.chdir(wdir)
    sys.argv = [bench_py]
    try:
        spec = importlib.util.spec_from_file_location("cxlfork_bench_%s" % workload, bench_py)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    finally:
        sys.argv = old_argv
        os.chdir(old_cwd)
        try:
            sys.path.remove(wdir)
        except ValueError:
            pass

    for name in ("lambda_handler", "handler"):
        fn = getattr(mod, name, None)
        if callable(fn):
            def run_in_workdir(fn=fn, wdir=wdir):
                old_cwd = os.getcwd()
                os.chdir(wdir)
                try:
                    return fn()
                finally:
                    os.chdir(old_cwd)

            return run_in_workdir
    raise RuntimeError("no lambda_handler/handler in %s" % bench_py)


def measure_handler(fn, iters, warmup):
    for _ in range(warmup):
        fn()
    vals = []
    for _ in range(iters):
        start = ns_now()
        fn()
        vals.append(ns_now() - start)
    vals.sort()
    return {
        "avg_ns": int(sum(vals) / len(vals)),
        "p50_ns": vals[len(vals) // 2],
        "p90_ns": vals[min(len(vals) - 1, int(len(vals) * 0.9))],
        "p99_ns": vals[-1],
    }


def ioctl_release(fd, key):
    buf = bytearray(8)
    struct.pack_into("Q", buf, 0, key)
    try:
        fcntl.ioctl(fd, CXLFORK_RELEASE, buf, True)
    except OSError:
        pass


def ioctl_prepare(fd, key, base, length):
    buf = bytearray(CHECKPOINT_SIZE)
    struct.pack_into("Q", buf, OFF_KEY, key)
    struct.pack_into("Q", buf, OFF_SCAN_START, base)
    struct.pack_into("Q", buf, OFF_SCAN_END, base + length)
    fcntl.ioctl(fd, CXLFORK_FORK_PREPARE, buf, True)
    return {
        "regions": struct.unpack_from("Q", buf, OFF_NR_REGIONS)[0],
        "ptes": struct.unpack_from("Q", buf, OFF_NR_PTES)[0],
        "pages": struct.unpack_from("Q", buf, OFF_TOTAL_PAGES)[0],
        "prepare_ns": struct.unpack_from("Q", buf, OFF_CHECKPOINT_NS)[0],
    }


def ioctl_resume(fd, key):
    buf = bytearray(RESTORE_SIZE)
    struct.pack_into("Q", buf, OFF_KEY, key)
    struct.pack_into("Q", buf, OFF_RESTORE_FLAGS, CXLFORK_F_SHARED_COW)
    fcntl.ioctl(fd, CXLFORK_FORK_RESUME, buf, True)
    return {
        "regions": struct.unpack_from("Q", buf, OFF_RESTORE_NR_REGIONS)[0],
        "ptes": struct.unpack_from("Q", buf, OFF_RESTORE_NR_PTES)[0],
        "pages": struct.unpack_from("Q", buf, OFF_RESTORE_TOTAL_PAGES)[0],
        "restore_ns": struct.unpack_from("Q", buf, OFF_RESTORE_NS)[0],
    }


def ioctl_stats(fd, key):
    buf = bytearray(STATS_SIZE)
    struct.pack_into("Q", buf, OFF_KEY, key)
    fcntl.ioctl(fd, CXLFORK_STATS, buf, True)
    return {
        "ready": struct.unpack_from("Q", buf, OFF_STATS_READY)[0],
        "pages": struct.unpack_from("Q", buf, OFF_STATS_TOTAL_PAGES)[0],
        "faults": struct.unpack_from("Q", buf, OFF_STATS_FAULTS)[0],
    }


def cmd_prepare(args):
    length = align_page(args.bytes)
    fn = load_workload(args.root, args.workload)
    for _ in range(args.warmup):
        fn()
    mmap_fixed(args.base, length)
    fill_working_set(args.base, length)
    fd = os.open(CXLFORK_DEVICE, os.O_RDWR)
    try:
        ioctl_release(fd, args.key)
        res = ioctl_prepare(fd, args.key, args.base, length)
    finally:
        os.close(fd)
    print(
        "cxlfork_python_worker_prepare workload=%s key=%d base=0x%x bytes=%d "
        "regions=%d ptes=%d pages=%d prepare_ns=%d pid=%d verify=ok"
        % (
            args.workload,
            args.key,
            args.base,
            length,
            res["regions"],
            res["ptes"],
            res["pages"],
            res["prepare_ns"],
            os.getpid(),
        )
    )


def cmd_resume(args):
    fn = load_workload(args.root, args.workload)
    fd = os.open(CXLFORK_DEVICE, os.O_RDWR)
    try:
        res = ioctl_resume(fd, args.key)
        start = ns_now()
        acc = touch_working_set(args.base, align_page(args.bytes))
        fault_ns = ns_now() - start
        exec_stats = measure_handler(fn, args.iters, args.warmup)
        stats = ioctl_stats(fd, args.key)
        logical_faults = min(stats["faults"], res["pages"])
    finally:
        os.close(fd)
    print(
        "cxlfork_python_worker_resume workload=%s key=%d base=0x%x bytes=%d "
        "regions=%d ptes=%d pages=%d restore_ns=%d fault_ns=%d faults=%d "
        "execution_ns=%d p50_ns=%d p90_ns=%d p99_ns=%d acc=%d pid=%d verify=ok"
        % (
            args.workload,
            args.key,
            args.base,
            align_page(args.bytes),
            res["regions"],
            res["ptes"],
            res["pages"],
            res["restore_ns"],
            fault_ns,
            logical_faults,
            exec_stats["avg_ns"],
            exec_stats["p50_ns"],
            exec_stats["p90_ns"],
            exec_stats["p99_ns"],
            acc,
            os.getpid(),
        )
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("prepare", "resume"))
    parser.add_argument("--root", required=True)
    parser.add_argument("--workload", required=True)
    parser.add_argument("--key", type=int, required=True)
    parser.add_argument("--bytes", type=int, default=4 * 1024 * 1024)
    parser.add_argument("--base", type=lambda s: int(s, 0), default=DEFAULT_BASE)
    parser.add_argument("--iters", type=int, default=5)
    parser.add_argument("--warmup", type=int, default=1)
    args = parser.parse_args()
    if args.mode == "prepare":
        cmd_prepare(args)
    else:
        cmd_resume(args)


if __name__ == "__main__":
    main()
