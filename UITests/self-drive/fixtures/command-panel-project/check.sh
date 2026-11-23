#!/bin/sh
set -eu
printf 'Suite: configuration\n'
sleep 2
printf 'PASS  loads defaults\n'
sleep 2
printf 'PASS  parses project settings\n'
sleep 2
if [ "$1" = fail ]; then
    printf 'FAIL  rejects an invalid retry limit\n'
    printf '      expected 3, received 0\n'
    printf '2 passed, 1 failed\n'
    exit 1
fi
printf 'PASS  rejects an invalid retry limit\n'
printf '3 passed, 0 failed\n'
