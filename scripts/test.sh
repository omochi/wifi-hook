#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/wifi-hook-tests.XXXXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
swiftc -module-cache-path "$test_dir/module-cache" "$project_dir/WiFiHook/Domain.swift" "$project_dir/tests/ScriptRunnerTests.swift" -o "$test_dir/tests"
"$test_dir/tests"
