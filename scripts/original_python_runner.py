#!/usr/bin/env python3
import argparse
import importlib.util
import os
import statistics
import sys
import time


def load_module(path):
    spec = importlib.util.spec_from_file_location("cxlfork_original_function", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load module from %s" % path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--workload", required=True)
    parser.add_argument("--root", default="/tmp/cxlfork-original/fork-functions")
    parser.add_argument("--iters", type=int, default=5)
    parser.add_argument("--warmup", type=int, default=1)
    args = parser.parse_args()

    workdir = os.path.join(args.root, args.workload)
    bench_py = os.path.join(workdir, "function_bench.py")
    if not os.path.exists(bench_py):
        raise SystemExit("missing function_bench.py for %s" % args.workload)

    os.environ.setdefault("OPENBLAS_NUM_THREADS", "1")
    os.environ.setdefault("MKL_NUM_THREADS", "1")
    os.chdir(workdir)
    sys.path.insert(0, workdir)
    sys.path.insert(0, os.path.abspath(os.path.join(args.root, "..", "common")))
    sys.argv = [bench_py]

    module = load_module(bench_py)
    if hasattr(module, "handler"):
        handler = module.handler
    elif hasattr(module, "lambda_handler"):
        handler = module.lambda_handler
    else:
        raise SystemExit("%s has no handler() or lambda_handler()" % bench_py)

    for _ in range(args.warmup):
        handler()

    samples = []
    for _ in range(args.iters):
        start = time.perf_counter_ns()
        handler()
        samples.append(time.perf_counter_ns() - start)

    samples_sorted = sorted(samples)
    p50 = samples_sorted[len(samples_sorted) // 2]
    p90 = samples_sorted[min(len(samples_sorted) - 1, (len(samples_sorted) * 90) // 100)]
    p99 = samples_sorted[min(len(samples_sorted) - 1, (len(samples_sorted) * 99) // 100)]
    print(
        "original_python workload=%s iters=%d warmup=%d avg_ns=%d min_ns=%d "
        "p50_ns=%d p90_ns=%d p99_ns=%d max_ns=%d stdev_ns=%d verify=ok"
        % (
            args.workload,
            args.iters,
            args.warmup,
            int(statistics.mean(samples)),
            min(samples),
            p50,
            p90,
            p99,
            max(samples),
            int(statistics.pstdev(samples)) if len(samples) > 1 else 0,
        )
    )


if __name__ == "__main__":
    main()
