#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP_DIR="$(mktemp -d)"
cleanup() {
  chmod -R u+w "$TMP_DIR" 2>/dev/null || true
  rm -r "$TMP_DIR"
}
trap cleanup EXIT

BIN_DIR="$TMP_DIR/bin"
REPO_DIR="$TMP_DIR/repo"
HOME_DIR="$TMP_DIR/home"
WORKDIR="$TMP_DIR/work"
CACHE_DIR="$HOME_DIR/.cache/rhel-kernel-srpms"
mkdir -p "$BIN_DIR" "$REPO_DIR" "$CACHE_DIR" "$WORKDIR"

git -C "$REPO_DIR" init -q -b main
git -C "$REPO_DIR" config user.name test
git -C "$REPO_DIR" config user.email test@example.invalid
git -C "$REPO_DIR" commit --allow-empty -qm initial

printf 'fake srpm\n' >"$CACHE_DIR/kernel-6.12.0-1.el10.src.rpm"

cat >"$BIN_DIR/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
  *-fsI*Packages/k*)
    exit 0
    ;;
  *-fsI*)
    exit 22
    ;;
  *-fsSL*Packages/k*)
    printf 'kernel-6.12.0-1.el10.src.rpm\n'
    exit 0
    ;;
  *)
    printf 'unexpected curl invocation: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$BIN_DIR/curl"

cat >"$BIN_DIR/rpm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "-qp" ]]; then
  if [[ "$*" == *BUILDTIME* ]]; then
    printf '1779494400\n'
  else
    printf 'kernel-6.12.0-1.el10\n'
  fi
  exit 0
fi

exit 2
EOF
chmod +x "$BIN_DIR/rpm"

stderr="$TMP_DIR/stderr.log"
PATH="$BIN_DIR:$PATH" HOME="$HOME_DIR" MAJORS="10" MODE=sources WORKDIR="$WORKDIR" \
  CONFIG_ARCHES="" "$ROOT_DIR/import-rhel-kernel-srpms.sh" "$REPO_DIR" >/dev/null 2>"$stderr"

if ! grep -q 'cached 1, to download 0' "$stderr"; then
  printf 'expected default HOME cache SRPM to be counted as cached\n' >&2
  cat "$stderr" >&2
  exit 1
fi
