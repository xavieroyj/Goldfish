#!/usr/bin/env python3
"""Read-only throughput benchmark matching Goldfish's range/block pattern."""

import argparse
import concurrent.futures
import os
import plistlib
import subprocess
import sys
import time


MIB = 1024 * 1024
RANGE_SIZE = 64 * MIB


def device_size(path: str) -> int:
    cooked = path.replace("/dev/rdisk", "/dev/disk", 1)
    result = subprocess.run(
        ["/usr/sbin/diskutil", "info", "-plist", cooked],
        check=True,
        stdout=subprocess.PIPE,
    )
    info = plistlib.loads(result.stdout)
    return int(info.get("TotalSize") or info.get("IOKitSize") or 0)


def read_range(path: str, start: int, length: int, block_size: int) -> int:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        completed = 0
        while completed < length:
            requested = min(block_size, length - completed)
            data = os.pread(descriptor, requested, start + completed)
            if not data:
                break
            completed += len(data)
        return completed
    finally:
        os.close(descriptor)


def benchmark(path: str, sample_size: int, block_size: int, workers: int) -> tuple[int, float]:
    ranges = []
    cursor = 0
    while cursor < sample_size:
        length = min(RANGE_SIZE, sample_size - cursor)
        ranges.append((path, cursor, length, block_size))
        cursor += length
    started = time.perf_counter()
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        completed = sum(pool.map(lambda args: read_range(*args), ranges))
    return completed, time.perf_counter() - started


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Benchmark a raw device using reads only; no bytes are written to the card."
    )
    parser.add_argument("device", help="raw device path, for example /dev/rdisk4s1")
    parser.add_argument("--sample-mib", type=int, default=1024, help="amount read per worker test (default: 1024)")
    parser.add_argument("--block-mib", type=int, default=4, help="read block size (default: 4)")
    parser.add_argument("--workers", default="1,2,4", help="comma-separated worker counts (default: 1,2,4)")
    args = parser.parse_args()

    if not args.device.startswith("/dev/rdisk"):
        parser.error("use a raw /dev/rdisk device path")
    workers = [int(value) for value in args.workers.split(",") if int(value) > 0]
    if not workers or args.sample_mib <= 0 or args.block_mib <= 0:
        parser.error("sample size, block size, and worker counts must be positive")

    try:
        total = device_size(args.device)
        sample = min(total, args.sample_mib * MIB)
        block = args.block_mib * MIB
        sample -= sample % 512
        print(f"Device: {args.device} ({total / MIB:,.0f} MiB)")
        print(f"Read-only sample per test: {sample / MIB:,.0f} MiB in {block / MIB:g} MiB blocks")
        results = []
        for worker_count in workers:
            completed, elapsed = benchmark(args.device, sample, block, worker_count)
            rate = completed / MIB / elapsed if elapsed else 0
            results.append((rate, worker_count))
            print(f"{worker_count} worker(s): {rate:,.1f} MiB/s ({elapsed:.2f}s)")
        best_rate, best_workers = max(results)
        print(f"Recommended worker count from this run: {best_workers} ({best_rate:,.1f} MiB/s)")
        return 0
    except PermissionError:
        print("Permission denied. Grant raw-device access, then run the benchmark again.", file=sys.stderr)
        return 2
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        print(f"Benchmark failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
