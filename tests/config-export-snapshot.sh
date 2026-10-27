#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT
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
  for arg in "$@"; do
    if [[ "$arg" == '_topdir '* ]]; then
      printf 'Name: kernel\nVersion: 6.12.0\n' >"${arg#_topdir }/SPECS/kernel.spec"
    fi
  done
else
  exit 2
fi
STUB
cat >"$TMP_DIR/bin/rpmbuild" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
  if [[ "$arg" == '_topdir '* ]]; then top="${arg#_topdir }"; fi
done
src="$top/BUILD/linux-6.12.0"
mkdir -p "$src/configs"
touch "$src/Kconfig" "$src/Makefile"
for arch in x86_64 ppc64le s390x; do
  printf 'CONFIG_SEED_%s=y\n' "$arch" >"$src/configs/kernel-$arch.config"
done
if [[ "$TEST_CASE" == original* ]]; then
  printf 'CONFIG_ORIGINAL=y\n' >"$src/.config"
  printf 'original backup\n' >"$src/.config.old"
fi
STUB
cat >"$TMP_DIR/bin/make" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
cfg="${KCONFIG_CONFIG:-.config}"
arch="${1#ARCH=}"
if [[ "$TEST_CASE" == original* ]]; then
  grep -q '^CONFIG_ORIGINAL=y$' "$cfg"
else
  grep -q '^CONFIG_SEED_' "$cfg"
fi
cp "$cfg" "$cfg.old"
printf 'CONFIG_RESOLVED_%s=y\n' "$arch" >"$cfg"
[[ "$TEST_CASE" != *failure ]]
STUB
chmod +x "$TMP_DIR/bin/"*
tag=rhel10-6.12.0-1.el10
for TEST_CASE in normal original failure original-failure disabled; do
  export TEST_CASE
  printf 'Checking config snapshot: %s\n' "$TEST_CASE"
  case_dir="$TMP_DIR/$TEST_CASE"
  repo="$case_dir/repo"
  work="$case_dir/work"
  cache="$case_dir/cache"
  mkdir -p "$repo" "$cache" "$work"
  printf 'fixture srpm\n' >"$cache/kernel-6.12.0-1.el10.src.rpm"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.name fixture
  git -C "$repo" config user.email fixture
  generate=1
  [[ "$TEST_CASE" != disabled ]] || generate=0
  include=''
  [[ "$TEST_CASE" != original* ]] || include='^\.config$'
  PATH="$TMP_DIR/bin:$PATH" MAJORS=0 MODE=prep WORKDIR="$work" CACHE="$cache" \
    CONFIG_GENERATE="$generate" CONFIG_ARCHES='x86_64 ppc64le s390x' \
    CONFIG_INCLUDE_REGEX="$include" PRUNE_TMP_AFTER_IMPORT=0 \
    GIT_IMPORT_NAME=fixture GIT_IMPORT_EMAIL=fixture \
    "$ROOT_DIR/import-rhel-kernel-srpms.sh" "$repo" >"$case_dir/stdout" 2>"$case_dir/stderr"
  for file in .config .config.old; do
    if [[ "$TEST_CASE" == original* ]]; then
      git -C "$repo" show "$tag:$file" >"$case_dir/$file"
      cmp "$work/tmp/rpmbuild-kernel-6.12.0-1.el10/BUILD/linux-6.12.0/$file" "$case_dir/$file"
      if [[ "$file" == .config ]]; then expected='CONFIG_ORIGINAL=y'; else expected='original backup'; fi
      [[ "$(cat "$case_dir/$file")" == "$expected" ]]
    elif git -C "$repo" cat-file -e "$tag:$file" 2>/dev/null; then
      printf 'temporary %s leaked into snapshot (%s)\n' "$file" "$TEST_CASE" >&2
      exit 1
    fi
  done
  [[ -z "$(find "$work/config-export/kernel-6.12.0-1.el10" -maxdepth 1 -type f -print)" ]]
  for arch in x86_64 ppc64le s390x; do
    case "$arch" in x86_64) karch=x86 ;; ppc64le) karch=powerpc ;; s390x) karch=s390 ;; esac
    base="metadata/configs/$arch/$tag"
    if [[ "$TEST_CASE" != *failure && "$generate" == 1 ]]; then
      git -C "$repo" show "$tag:$base/kernel-6.12.0-1.el10.$arch.resolved.config" \
        >"$case_dir/resolved"
      [[ "$(cat "$case_dir/resolved")" == "CONFIG_RESOLVED_$karch=y" ]]
    else
      if git -C "$repo" cat-file -e "$tag:$base/kernel-6.12.0-1.el10.$arch.resolved.config" 2>/dev/null; then
        echo 'unexpected resolved config after failed or disabled generation' >&2
        exit 1
      fi
    fi
    seed="kernel-$arch.config"
    [[ "$TEST_CASE" != original* ]] || seed=.config
    git -C "$repo" show "$tag:$base/$seed" >"$case_dir/seed"
    git -C "$repo" show "$tag:metadata/configs/$arch/latest/$seed" >"$case_dir/latest"
    cmp "$case_dir/seed" "$case_dir/latest"
  done
  if [[ "$TEST_CASE" == *failure ]]; then
    [[ "$(grep -c 'Failed to generate config for' "$case_dir/stderr")" == 3 ]]
  fi
done
