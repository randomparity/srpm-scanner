#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT
export REAL_CP
REAL_CP="$(command -v cp)"
export ORIGINAL_SPEC="$TMP_DIR/original.spec"
cat >"$ORIGINAL_SPEC" <<'SPEC'
Name: kernel
Version: 6.12.0
Release: 1.el10
Summary: fixture
License: GPL-2.0-only
%global rpmversion 6.12.0
%global rhelkeys 1
%define driver_cert %{_datadir}/pki/sb-certs/missing.der
%prep
: %{rpmversion}
%changelog
* Thu Jan 01 2026 Fixture
- Preserve original changelog and %{rpmversion} bytes.
SPEC

mkdir -p "$TMP_DIR/bin"
cat >"$TMP_DIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
exit 22
STUB
cat >"$TMP_DIR/bin/rpm" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == -qp ]]; then
  if [[ "$*" == *BUILDTIME* ]]; then echo 1779494400; else echo kernel-6.12.0-1.el10; fi
elif [[ "$1" == -Uvh ]]; then
  [[ "$TEST_CASE" != fallback* ]] || exit 1
  for arg in "$@"; do
    if [[ "$arg" == '_topdir '* ]]; then
      "$REAL_CP" "$ORIGINAL_SPEC" "${arg#_topdir }/SPECS/kernel.spec"
    fi
  done
else
  exit 2
fi
STUB
cat >"$TMP_DIR/bin/rpm2cpio" <<'STUB'
#!/usr/bin/env bash
printf 'fixture archive\n'
STUB
cat >"$TMP_DIR/bin/cpio" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
cat > /dev/null
"$REAL_CP" "$ORIGINAL_SPEC" kernel.spec
STUB
cat >"$TMP_DIR/bin/rpmbuild" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
touch "$TEST_TRACE"
for arg in "$@"; do
  if [[ "$arg" == '_topdir '* ]]; then top="${arg#_topdir }"; fi
  if [[ "$arg" == *.spec ]]; then spec="$arg"; fi
done
grep -q '^%global _rpmver ' "$spec"
if [[ ! -d /usr/share/pki/sb-certs ]]; then grep -q '^%global rhelkeys 0$' "$spec"; fi
src="$top/BUILD/linux-6.12.0"
mkdir -p "$src"
touch "$src/Kconfig" "$src/Makefile"
case "$TEST_CASE" in
  directory) mkdir "$src/kernel.spec" ;;
  symlink) ln -s "$ORIGINAL_SPEC" "$src/kernel.spec" ;;
  *) printf 'source tree decoy\n' > "$src/kernel.spec" ;;
esac
STUB
cat >"$TMP_DIR/bin/cp" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
dest="${!#}"
case "$TEST_CASE:$dest" in
  preserve-fail:*/rpmbuild-*/kernel.spec|copy-fail:./kernel.spec) exit 1 ;;
  fallback-fail:*/SPECS/)
    printf 'partial spec\n' > "$dest/kernel.spec"
    exit 1
    ;;
esac
exec "$REAL_CP" "$@"
STUB
chmod +x "$TMP_DIR/bin/"*

run_import() {
  PATH="$TMP_DIR/bin:$PATH" MAJORS=0 MODE="$mode" WORKDIR="$work" CACHE="$cache" \
    CONFIG_GENERATE=0 CONFIG_ARCHES=x86_64 PRUNE_TMP_AFTER_IMPORT=0 \
    GIT_IMPORT_NAME=fixture GIT_IMPORT_EMAIL=fixture \
    "$ROOT_DIR/import-rhel-kernel-srpms.sh" "$repo" >"$case_dir/stdout" 2>"$case_dir/stderr"
}

for TEST_CASE in normal fallback ignored symlink directory preserve-fail copy-fail fallback-fail sources; do
  export TEST_CASE TEST_TRACE
  printf 'Checking %s\n' "$TEST_CASE"
  case_dir="$TMP_DIR/$TEST_CASE"
  TEST_TRACE="$case_dir/rpmbuild.started"
  repo="$case_dir/repo"
  work="$case_dir/work"
  cache="$case_dir/cache"
  mkdir -p "$repo" "$cache" "$work"
  printf 'fixture srpm\n' >"$cache/kernel-6.12.0-1.el10.src.rpm"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.name fixture
  git -C "$repo" config user.email fixture
  if [[ "$TEST_CASE" == ignored ]]; then printf '/kernel.spec\n' >"$repo/.gitignore"; fi
  mode=prep
  [[ "$TEST_CASE" != sources ]] || mode=sources
  status=0
  run_import || status=$?
  tag=rhel10-6.12.0-1.el10
  case "$TEST_CASE" in
  *-fail)
    if git -C "$repo" rev-parse -q --verify "refs/tags/$tag"; then
      printf 'unexpected tag after %s\n' "$TEST_CASE" >&2
      exit 1
    fi
    case "$TEST_CASE" in
    preserve-fail) diagnostic='Cannot preserve original spec' ;;
    copy-fail)
      diagnostic='Cannot include original kernel.spec'
      [[ "$status" -ne 0 ]]
      ;;
    fallback-fail) diagnostic='Cannot stage extracted spec' ;;
    esac
    if [[ "$TEST_CASE" != copy-fail ]]; then [[ ! -e "$TEST_TRACE" ]]; fi
    if git -C "$repo" show-ref --verify --quiet refs/heads/rhel10; then
      printf 'unexpected source commit after %s\n' "$TEST_CASE" >&2
      exit 1
    fi
    grep -q "$diagnostic" "$case_dir/stderr"
    ;;
  sources)
    [[ "$status" -eq 0 ]]
    git -C "$repo" show "$tag:packaging/SPECS/kernel.spec" >"$case_dir/packaged.spec"
    grep -q '^%global _rpmver ' "$case_dir/packaged.spec"
    if git -C "$repo" cat-file -e "$tag:kernel.spec" 2>/dev/null; then
      printf 'sources layout unexpectedly gained root kernel.spec\n' >&2
      exit 1
    fi
    ;;
  *)
    [[ "$status" -eq 0 ]] || {
      cat "$case_dir/stderr" >&2
      exit 1
    }
    git -C "$repo" show "$tag:kernel.spec" >"$case_dir/committed.spec"
    cmp "$ORIGINAL_SPEC" "$case_dir/committed.spec"
    [[ "$(git -C "$repo" ls-tree "$tag" kernel.spec)" == '100644 blob '* ]]
    before="$(git -C "$repo" rev-parse "refs/tags/$tag")"
    run_import
    [[ "$(git -C "$repo" rev-parse "refs/tags/$tag")" == "$before" ]]
    ;;
  esac
done
