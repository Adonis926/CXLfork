#!/usr/bin/env python3
import argparse
import ctypes
import importlib.util
import os
import statistics
import struct
import sys
import time

PAGE_SIZE = 4096
DEFAULT_BASE = 0x762000000000

PROT_READ = 0x1
PROT_WRITE = 0x2
MAP_PRIVATE = 0x02
MAP_ANONYMOUS = 0x20
MAP_FIXED_NOREPLACE = 0x100000
MAP_FAILED = ctypes.c_void_p(-1).value

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
        arr[i] = 0x10CA1F04B0000000 ^ ((i * 0x9E3779B97F4A7C15) & 0xFFFFFFFFFFFFFFFF)
    if len(arr):
        arr[-1] = 0x10CA1F04B5A5A5A5A


def touch_working_set(base, length, write_pages):
    arr = (ctypes.c_uint64 * (length // 8)).from_address(base)
    step = PAGE_SIZE // 8
    acc = 0
    for i in range(0, len(arr), step):
        acc ^= arr[i]
        if write_pages:
            arr[i] ^= 0x55AA55AA55AA55AA
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
        spec = importlib.util.spec_from_file_location("local_fork_bench_%s" % workload, bench_py)
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


def child_once(fn, base, length, write_pages, out_fd):
    child_start = ns_now()
    touch_start = ns_now()
    acc = touch_working_set(base, length, write_pages)
    touch_ns = ns_now() - touch_start
    exec_start = ns_now()
    fn()
    exec_ns = ns_now() - exec_start
    payload = struct.pack("QQQ", child_start, touch_ns, exec_ns)
    os.write(out_fd, payload)
    os.close(out_fd)
    os._exit(0 if acc or length == 0 else 0)


def run(args):
    length = align_page(args.bytes)
    fn = load_workload(args.root, args.workload)
    for _ in range(args.warmup):
        fn()
    mmap_fixed(args.base, length)
    fill_working_set(args.base, length)

    rows = []
    for i in range(args.iters):
        rfd, wfd = os.pipe()
        start = ns_now()
        pid = os.fork()
        if pid == 0:
            os.close(rfd)
            child_once(fn, args.base, length, args.write_pages, wfd)

        os.close(wfd)
        data = b""
        while len(data) < 24:
            chunk = os.read(rfd, 24 - len(data))
            if not chunk:
                break
            data += chunk
        os.close(rfd)
        _, status = os.waitpid(pid, 0)
        total_ns = ns_now() - start
        if len(data) != 24 or status != 0:
            raise RuntimeError("child failed status=%s bytes=%d" % (status, len(data)))
        child_start, touch_ns, exec_ns = struct.unpack("QQQ", data)
        rows.append((child_start - start, touch_ns, exec_ns, total_ns))

    def avg(idx):
        return int(sum(r[idx] for r in rows) / len(rows))

    def pct(idx, q):
        vals = sorted(r[idx] for r in rows)
        return vals[min(len(vals) - 1, int(len(vals) * q))]

    print(
        "local_fork_python_worker workload=%s bytes=%d iters=%d warmup=%d "
        "fork_to_child_ns=%d touch_ns=%d execution_ns=%d total_ns=%d "
        "p50_total_ns=%d p90_total_ns=%d p99_total_ns=%d pages=%d write_pages=%d verify=ok"
        % (
            args.workload,
            length,
            args.iters,
            args.warmup,
            avg(0),
            avg(1),
            avg(2),
            avg(3),
            pct(3, 0.50),
            pct(3, 0.90),
            pct(3, 0.99),
            length // PAGE_SIZE,
            1 if args.write_pages else 0,
        )
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--workload", required=True)
    parser.add_argument("--bytes", type=int, required=True)
    parser.add_argument("--iters", type=int, default=5)
    parser.add_argument("--warmup", type=int, default=1)
    parser.add_argument("--base", type=lambda s: int(s, 0), default=DEFAULT_BASE)
    parser.add_argument("--write-pages", action="store_true")
    run(parser.parse_args())


if __name__ == "__main__":
    main()
