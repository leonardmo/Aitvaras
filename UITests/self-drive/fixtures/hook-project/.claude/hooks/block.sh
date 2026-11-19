#!/bin/sh
input=$(cat)
case "$input" in
  *"echo blocked-example"*) echo "Example rule: this command is not allowed" >&2; exit 2 ;;
esac
exit 0
