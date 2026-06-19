#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

assert_help() {
  local script="$1"
  local arg="$2"
  local output status

  set +e
  output="$("$ROOT_DIR/$script" "$arg" 2>&1)"
  status="$?"
  set -e

  [[ "$status" -eq 0 ]] || {
    printf '%s %s exited with %s\nOutput:\n%s\n' "$script" "$arg" "$status" "$output" >&2
    return 1
  }

  [[ "$output" == *"Usage:"* ]] || {
    printf '%s %s did not print usage\nOutput:\n%s\n' "$script" "$arg" "$output" >&2
    return 1
  }
}

assert_help import-rhel-kernel-srpms.sh --help
assert_help import-rhel-kernel-srpms.sh -h
assert_help rhel-kernel-import-oci.sh --help
assert_help rhel-kernel-import-oci.sh -h
