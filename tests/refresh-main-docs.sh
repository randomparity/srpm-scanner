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
mkdir -p "$REPO_DIR" "$WORKDIR"
CONFIG_DIR='metadata/configs"quoted'
ARCHES="x86_64 ppc64le s390x"

git -C "$REPO_DIR" init -q -b main
git -C "$REPO_DIR" config user.name test
git -C "$REPO_DIR" config user.email test@example.invalid

git -C "$REPO_DIR" commit --allow-empty -qm "Initialize catalog branch"
git -C "$REPO_DIR" switch -qc snapshots

commit_import() {
	local nvr="$1"
	local tag="$2"
	local date="$3" arch dir

	mkdir -p "$REPO_DIR/kernel"
	printf 'void schedule(void) { /* %s */ }\n' "$nvr" >"$REPO_DIR/kernel/sched.c"
	printf 'CONFIG_WRONG_ROOT_ARCH=y\n' >"$REPO_DIR/.config"
	for arch in $ARCHES; do
		dir="$REPO_DIR/$CONFIG_DIR/$arch/$tag"
		mkdir -p "$dir"
		printf 'CONFIG_ARCH_%s=y\n' "$arch" >"$dir/kernel.$arch.resolved.config"
	done
	git -C "$REPO_DIR" add .
	GIT_AUTHOR_DATE="$date" \
		GIT_COMMITTER_DATE="$date" \
		git -C "$REPO_DIR" commit --allow-empty -qm "Import $nvr"
	GIT_COMMITTER_DATE="$date" git -C "$REPO_DIR" tag -a "$tag" -m "$nvr"
}

commit_import \
	kernel-5.14.0-570.52.1.el9_6 \
	rhel9-5.14.0-570.52.1.el9_6 \
	2026-05-01T00:00:00Z
commit_import \
	kernel-6.12.0-211.34.1.el10_2 \
	rhel10-6.12.0-211.34.1.el10_2 \
	2026-07-01T00:00:00Z

git -C "$REPO_DIR" branch rhel10
commit_import kernel-5.14.0-1.el9 rhel9-5.14.0-1.el9 2025-01-01T00:00:00Z
git -C "$REPO_DIR" branch rhel9
git -C "$REPO_DIR" switch -q main

WORKDIR="$WORKDIR" CONFIG_ARCHES="$ARCHES" CONFIG_EXPORT_DIR="$CONFIG_DIR" \
	"$ROOT_DIR/import-rhel-kernel-srpms.sh" --refresh-main "$REPO_DIR" >/dev/null

if ! grep -q '^## RHEL 10$' "$REPO_DIR/CHANGELOG.md"; then
	printf 'expected RHEL 10 section in generated changelog\n' >&2
	cat "$REPO_DIR/CHANGELOG.md" >&2
	exit 1
fi

if ! grep -q '^### EL 10.2$' "$REPO_DIR/CHANGELOG.md"; then
	printf 'expected EL 10.2 subsection in generated changelog\n' >&2
	cat "$REPO_DIR/CHANGELOG.md" >&2
	exit 1
fi

if grep -q 'Tagger:' "$REPO_DIR/index.json"; then
	printf 'annotated tag text leaked into index.json\n' >&2
	cat "$REPO_DIR/index.json" >&2
	exit 1
fi

python3 -m json.tool "$REPO_DIR/index.json" >/dev/null

if ! grep -q '"nvr":"kernel-6.12.0-211.34.1.el10_2"' "$REPO_DIR/index.json"; then
	printf 'expected RHEL 10 NVR without duplicated tag prefix in index.json\n' >&2
	cat "$REPO_DIR/index.json" >&2
	exit 1
fi

expected_config_path='"x86_64":"metadata/configs\"quoted/x86_64/rhel10-6.12.0-211.34.1.el10_2/"'
if ! grep -qF "$expected_config_path" "$REPO_DIR/index.json"; then
	printf 'expected repo-relative config path in index.json\n' >&2
	cat "$REPO_DIR/index.json" >&2
	exit 1
fi

exercise_guidance() {
  [[ -f "$REPO_DIR/AGENTS.md" ]] || {
    printf 'expected generated AGENTS.md consumer guidance\n' >&2
    return 1
  }
  git -C "$REPO_DIR" cat-file -e HEAD:AGENTS.md
  python3 - "$REPO_DIR/AGENTS.md" "$TMP_DIR/example.sh" <<'PYTHON'
import pathlib
import re
import sys
blocks = re.findall(r"^```bash\n(.*?)^```$", pathlib.Path(sys.argv[1]).read_text(), re.M | re.S)
assert blocks, "missing executable consumer examples"
pathlib.Path(sys.argv[2]).write_text("\n".join(blocks))
PYTHON
  local tag=rhel9-5.14.0-570.52.1.el9_6 arch worktree
  for arch in $ARCHES; do
    worktree="$TMP_DIR/kernel-$tag-$arch"
    (
      cd "$REPO_DIR"
      VERSION_RELEASE=5.14.0-570.52.1.el9_6 CONFIG_ARCH="$arch" \
        CONFIG_FILE="kernel.$arch.resolved.config" bash "$TMP_DIR/example.sh"
    ) >"$TMP_DIR/example.out"
    grep -qF "CONFIG_ARCH_$arch=y" "$TMP_DIR/example.out"
    grep -qF "$tag:kernel/sched.c:" "$TMP_DIR/example.out"
    grep -qF "Citation: tag=$tag commit=$(git -C "$REPO_DIR" rev-parse "$tag^{}") path=$CONFIG_DIR/$arch/$tag/kernel.$arch.resolved.config" "$TMP_DIR/example.out"
    [[ "$(git -C "$worktree" rev-parse HEAD)" == "$(git -C "$REPO_DIR" rev-parse "$tag^{}")" ]]
    if git -C "$worktree" symbolic-ref -q HEAD; then
      printf 'expected detached example worktree\n' >&2
      return 1
    fi
    git -C "$REPO_DIR" worktree remove "$worktree"
  done
  if (cd "$REPO_DIR"; VERSION_RELEASE=unavailable CONFIG_ARCH=x86_64 \
    CONFIG_FILE=missing.config bash "$TMP_DIR/example.sh") >"$TMP_DIR/missing.out" 2>&1; then
    printf 'expected missing release lookup to fail\n' >&2
    return 1
  fi
  grep -q 'unavailable locally' "$TMP_DIR/missing.out"
  if (cd "$REPO_DIR"; VERSION_RELEASE=5.14.0-570.52.1.el9_6 CONFIG_ARCH=x86_64 \
    CONFIG_FILE=missing.config bash "$TMP_DIR/example.sh") >"$TMP_DIR/missing-config.out" 2>&1; then
    printf 'expected missing config read to fail\n' >&2
    return 1
  fi
  [[ ! -e "$TMP_DIR/kernel-$tag-x86_64" ]]
}

exercise_guidance
cp "$REPO_DIR/README.md" "$TMP_DIR/fallback.md"
printf 'Custom consumer README, preserve exactly.\n' >"$TMP_DIR/custom.md"
for mode in fallback supplied existing repeated enforced; do
  source="$TMP_DIR/missing-readme"
  enforce=0
  if [[ "$mode" == supplied ]]; then source="$TMP_DIR/custom.md"; fi
  if [[ "$mode" == enforced ]]; then
    enforce=1
    printf 'obsolete guidance\n' >"$REPO_DIR/AGENTS.md"
    printf 'remove me\n' >"$REPO_DIR/unrelated.txt"
  fi
  WORKDIR="$WORKDIR" CONFIG_ARCHES="$ARCHES" CONFIG_EXPORT_DIR="$CONFIG_DIR" \
    README_MD_SOURCE="$source" MAIN_ENFORCE_MINIMAL="$enforce" \
    "$ROOT_DIR/import-rhel-kernel-srpms.sh" --refresh-main "$REPO_DIR"
  expected="$TMP_DIR/custom.md"
  if [[ "$mode" == fallback ]]; then expected="$TMP_DIR/fallback.md"; fi
  cmp "$expected" "$REPO_DIR/README.md"
  exercise_guidance
  if [[ "$mode" == enforced ]]; then
    [[ ! -e "$REPO_DIR/unrelated.txt" ]]
    python3 - "$REPO_DIR" <<'PYTHON'
import pathlib
import sys
assert {p.name for p in pathlib.Path(sys.argv[1]).iterdir()} == {
    ".git", ".gitignore", "README.md", "AGENTS.md", "CHANGELOG.md", "index.json"
}
PYTHON
  fi
done
