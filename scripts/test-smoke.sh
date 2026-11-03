#!/bin/zsh
# Pre-push smoke gate (docs/TESTING.md Layer 4): privacy sweep, Node helper
# contracts, package tests and the app build. Same as `make smoke`.
set -e
cd "$(dirname "$0")/.."
exec make smoke
