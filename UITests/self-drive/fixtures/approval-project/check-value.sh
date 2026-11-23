#!/bin/sh
set -eu
printf '%s\n' "$1" > value.txt
if [ "$(cat value.txt)" = correct ]; then
    echo VALUE-CHECK-PASSED
else
    echo VALUE-CHECK-FAILED
    exit 1
fi
