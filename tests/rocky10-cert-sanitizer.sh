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
WORKDIR="$TMP_DIR/work"
CACHE_DIR="$WORKDIR/srpms"
mkdir -p "$BIN_DIR" "$REPO_DIR" "$CACHE_DIR"

touch "$CACHE_DIR/kernel-6.12.0-1.el10.src.rpm"

cat >"$BIN_DIR/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 22
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

if [[ "${1:-}" == "-Uvh" ]]; then
  top=""
  previous=""
  for arg in "$@"; do
    if [[ "$previous" == "--define" && "$arg" == "_topdir "* ]]; then
      top="${arg#_topdir }"
      break
    fi
    previous="$arg"
  done
  [[ -n "$top" ]] || exit 2
  mkdir -p "$top/SPECS" "$top/SOURCES"
  cat > "$top/SPECS/kernel.spec" <<'SPEC'
Name: kernel
Version: 6.12.0
Release: 1.el10
Summary: fake kernel
License: GPL-2.0-only
%global rhelkeys 1
%define driver_cert %{_datadir}/pki/sb-certs/kernel-dup1-%{_arch}.der
%prep
: rhelkeys=%{rhelkeys}
SPEC
  exit 0
fi

exit 2
EOF
chmod +x "$BIN_DIR/rpm"

cat >"$BIN_DIR/rpmbuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

top=""
previous=""
spec=""
for arg in "$@"; do
  if [[ "$previous" == "--define" && "$arg" == "_topdir "* ]]; then
    top="${arg#_topdir }"
  fi
  if [[ "$arg" == *.spec ]]; then
    spec="$arg"
  fi
  previous="$arg"
done

[[ -n "$top" && -n "$spec" ]] || exit 2
if grep -Eq '^%global[[:space:]]+rhelkeys[[:space:]]+1$' "$spec"; then
  printf 'rhelkeys was not disabled in %s\n' "$spec" >&2
  exit 1
fi

src="$top/BUILD/kernel-6.12.0-build/kernel-6.12.0/linux-6.12.0"
mkdir -p "$src"
touch "$src/Kconfig" "$src/Makefile"
EOF
chmod +x "$BIN_DIR/rpmbuild"

PATH="$BIN_DIR:$PATH" MAJORS="0" MODE=sources WORKDIR="$WORKDIR" CACHE="$CACHE_DIR" \
  CONFIG_ARCHES="" \
  "$ROOT_DIR/import-rhel-kernel-srpms.sh" "$REPO_DIR" >/dev/null

if ! git -C "$REPO_DIR" rev-parse -q --verify refs/tags/rhel10-6.12.0-1.el10 >/dev/null; then
  printf 'expected fake Rocky 10 SRPM to be imported\n' >&2
  sed -n '1,120p' "$WORKDIR/logs/kernel-6.12.0-1.el10.bp.log" >&2
  exit 1
fi
