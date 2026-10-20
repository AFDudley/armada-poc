#!/usr/bin/env bash
# Runs forge build and forge test, reporting both exit codes as JSON.
set -u
cd "$(dirname "$0")/.."

build_exit=1
forge build > /dev/null 2>&1
build_exit=$?
test_exit=1
forge test > /dev/null 2>&1
test_exit=$?

printf '{"build_exit_code":%d,"test_exit_code":%d}\n' "$build_exit" "$test_exit"
