#!/usr/bin/env python3
"""Set each tracked file's modification time to its last commit time.

A fresh CI checkout stamps every file with the current time, so a restored
build cache would treat every source as changed and recompile everything.
Needs the full history (checkout with fetch-depth: 0).
"""
import os
import subprocess


def git(*args):
    return subprocess.run(["git", "-c", "core.quotepath=false", *args],
                          capture_output=True, text=True, check=True).stdout


tracked = set(git("ls-files", "-z").split("\0"))
stamp, seen = None, set()
# A PR checkout is a merge commit. Files the PR changes keep the checkout time,
# so they always count as newer than anything in a cache built from main.
if len(git("rev-list", "--parents", "-n", "1", "HEAD").split()) > 2:
    seen.update(git("diff", "--name-only", "-z", "HEAD^1", "HEAD").split("\0"))
for line in git("log", "--pretty=format:@%ct", "--name-only", "--no-renames").splitlines():
    if line.startswith("@"):
        stamp = int(line[1:])
    elif line in tracked and line not in seen and os.path.isfile(line):
        seen.add(line)
        os.utime(line, (stamp, stamp), follow_symlinks=False)
print(f"Set {len(seen)} of {len(tracked) - 1} file times")
