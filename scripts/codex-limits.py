#!/usr/bin/env python3
"""Reads the Codex rate-limit windows without spending tokens.

Usage: codex-limits.py <codex-binary> [--json] [--seconds-until-free THRESHOLD]

--seconds-until-free prints how many seconds to wait until every window is
below THRESHOLD percent used (0 when there is room now).
"""
import argparse
import datetime
import json
import select
import subprocess
import sys
import time


def read_limits(binary: str) -> dict:
    proc = subprocess.Popen(
        [binary, "app-server"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
    )

    def send(message: dict) -> None:
        proc.stdin.write(json.dumps(message) + "\n")
        proc.stdin.flush()

    try:
        send({"id": 1, "method": "initialize",
              "params": {"clientInfo": {"name": "aitvaras-limits", "version": "1"}}})
        send({"method": "initialized"})
        send({"id": 2, "method": "account/rateLimits/read"})
        deadline = time.time() + 20
        while time.time() < deadline:
            ready, _, _ = select.select([proc.stdout], [], [], 1)
            if not ready:
                continue
            line = proc.stdout.readline()
            if not line:
                break
            message = json.loads(line)
            if message.get("id") == 2:
                if "error" in message:
                    raise SystemExit(f"codex refused the limits request: {message['error']}")
                return message["result"]["rateLimits"]
    finally:
        proc.terminate()
    raise SystemExit("codex app-server did not report rate limits within 20 s")


def windows(limits: dict) -> list:
    return [(name, window) for name, window in limits.items()
            if isinstance(window, dict) and "usedPercent" in window]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("binary")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--seconds-until-free", type=float, metavar="THRESHOLD")
    args = parser.parse_args()
    limits = read_limits(args.binary)

    if args.json:
        print(json.dumps(limits))
    elif args.seconds_until_free is not None:
        now = time.time()
        waits = [window.get("resetsAt", now) - now
                 for _, window in windows(limits)
                 if window["usedPercent"] >= args.seconds_until_free]
        print(int(max(waits + [0])))
    else:
        for name, window in windows(limits):
            reset = window.get("resetsAt")
            when = datetime.datetime.fromtimestamp(reset).isoformat(" ", "minutes") if reset else "unknown"
            print(f"{name}: {window['usedPercent']}% used, resets {when}")
        for key in ("planType", "credits"):
            if key in limits:
                print(f"{key}: {json.dumps(limits[key])}")


if __name__ == "__main__":
    sys.exit(main())
