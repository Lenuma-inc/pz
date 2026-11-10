#!/usr/bin/env python3
"""Measure an existing Linux pz binary; never builds or sends model requests.

Uses a temporary HOME/project, disables MCP/LSP, and uses cat as a provider stub.
First output is not proof of prompt readiness. Initial output is the last write
before 200 ms of silence; input echo separately checks editor responsiveness.
RSS is sampled idle, CPU includes the pz process only (not subprocesses).
"""
import argparse
import concurrent.futures
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import signal
import statistics
import struct
import subprocess
import tempfile
import termios
import time


def receive(fd, timeout):
    if not select.select([fd], [], [], timeout)[0]:
        return b""
    data = os.read(fd, 65536)
    if not data:
        raise RuntimeError("terminal closed before measurement completed")
    return data


def sample(pid):
    # comm can contain spaces; fields following its closing parenthesis start at 3.
    fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
    ticks = int(fields[11]) + int(fields[12])
    status = Path(f"/proc/{pid}/status").read_text().splitlines()
    rss = next(int(line.split()[1]) for line in status if line.startswith("VmRSS:"))
    return ticks, rss


def measure(binary, idle_seconds):
    with tempfile.TemporaryDirectory(prefix="pz-startup-") as root:
        config = Path(root, "config.json")
        config.write_text(json.dumps({"mcp": False, "lsp": False, "skills": False, "exa": False}))
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        env = {key: value for key, value in os.environ.items()
               if not any(word in key.upper() for word in ("API_KEY", "TOKEN", "SECRET"))}
        env.update(HOME=root, TERM="xterm-256color", XDG_CONFIG_HOME=root,
                   XDG_STATE_HOME=root, PZ_DISABLE_BROWSER_OPEN="1", PZ_SKIP_VERSION_CHECK="1")
        started = time.monotonic()
        proc = None
        try:
            proc = subprocess.Popen(
                [binary, "--config", str(config), "--no-session", "--provider-cmd", "cat"],
                stdin=slave, stdout=slave, stderr=slave, cwd=root, env=env,
                start_new_session=True)
            os.close(slave)
            slave = None
            first = last = None
            output_bytes = 0
            while time.monotonic() - started < 5:
                data = receive(master, 0.05)
                if data:
                    last = time.monotonic()
                    first = first or last
                    output_bytes += len(data)
                if first and time.monotonic() - last >= 0.2:
                    break
            if first is None or proc.poll() is not None:
                raise RuntimeError("no live TUI within five seconds")
            ticks_before, rss = sample(proc.pid)
            idle_start = time.monotonic()
            idle_output_bytes = 0
            while time.monotonic() - idle_start < idle_seconds:
                idle_output_bytes += len(receive(master, min(0.05, idle_seconds)))
            elapsed = time.monotonic() - idle_start
            ticks_after, _ = sample(proc.pid)
            sent = time.monotonic()
            os.write(master, b"~")  # No Enter: never submit to provider.
            response = b""
            while b"~" not in response and time.monotonic() - sent < 2:
                response += receive(master, 0.05)
            if b"~" not in response:
                raise RuntimeError("editor did not display the probe character")
            return {
                "first_output_ms": round((first - started) * 1000, 3),
                "initial_output_ms": round((last - started) * 1000, 3),
                "input_redraw_ms": round((time.monotonic() - sent) * 1000, 3),
                "idle_cpu_percent": round((ticks_after - ticks_before) /
                    os.sysconf("SC_CLK_TCK") / elapsed * 100, 3),
                "idle_rss_kib": rss, "initial_output_bytes": output_bytes,
                "idle_output_bytes": idle_output_bytes,
            }
        finally:
            if slave is not None:
                os.close(slave)
            if proc is not None:
                # The stub and any startup children share this isolated process group.
                try:
                    os.killpg(proc.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait()
            os.close(master)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=lambda p: str(Path(p).resolve()))
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--idle-seconds", type=float, default=2)
    parser.add_argument("--parallel", type=int, default=1,
                        help="simultaneous TUI processes for startup load testing")
    args = parser.parse_args()
    if args.runs < 1 or args.idle_seconds <= 0 or args.parallel < 1:
        parser.error("runs, idle-seconds and parallel must be positive")
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.parallel) as pool:
        results = list(pool.map(lambda _: measure(args.binary, args.idle_seconds), range(args.runs)))
    print(json.dumps({"runs": results, "median": {
        key: statistics.median(row[key] for row in results) for key in results[0]
    }}, indent=2))


if __name__ == "__main__":
    main()
