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

git -C "$REPO_DIR" init -q -b main
git -C "$REPO_DIR" config user.name test
git -C "$REPO_DIR" config user.email test@example.invalid

commit_import() {
	local nvr="$1"
	local tag="$2"
	local date="$3"

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

WORKDIR="$WORKDIR" CONFIG_ARCHES="x86_64" \
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

expected_config_path='"x86_64":"metadata/configs/x86_64/rhel10-6.12.0-211.34.1.el10_2/"'
if ! grep -q "$expected_config_path" "$REPO_DIR/index.json"; then
	printf 'expected repo-relative config path in index.json\n' >&2
	cat "$REPO_DIR/index.json" >&2
	exit 1
fi
