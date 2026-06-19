#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP_DIR="$(mktemp -d)"
cleanup() {
  chmod -R u+w "$TMP_DIR" 2>/dev/null || true
  rm -r "$TMP_DIR"
}
trap cleanup EXIT

REPO_DIR="$TMP_DIR/repo"
WORKDIR="$TMP_DIR/work"
CACHE_DIR="$WORKDIR/srpms"
mkdir -p "$REPO_DIR" "$WORKDIR" "$CACHE_DIR"

HAS_PATHFIX=0
command -v pathfix.py >/dev/null && HAS_PATHFIX=1

MAJORS="0" MODE=sources WORKDIR="$WORKDIR" CACHE="$CACHE_DIR" \
  "$ROOT_DIR/import-rhel-kernel-srpms.sh" "$REPO_DIR" >/dev/null

if [[ "$HAS_PATHFIX" -eq 0 &&
  -f /usr/lib/rpm/redhat/pathfix.py &&
  ! -x "$WORKDIR/bin/pathfix.py" ]]; then
  printf 'expected executable pathfix.py wrapper at %s\n' "$WORKDIR/bin/pathfix.py" >&2
  exit 1
fi

if [[ -d "$WORKDIR/bin" ]]; then
  PATH="$WORKDIR/bin:$PATH" command -v pathfix.py >/dev/null
fi
