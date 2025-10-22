#!/usr/bin/env bash
# rhel-kernel-import-oci.sh
# Usage: ./rhel-kernel-import-oci.sh /absolute/path/to/repo
set -euo pipefail

REPO="${1:-}"
[[ -z "$REPO" ]] && { echo "Usage: $0 /abs/path/to/repo"; exit 1; }
REPO="$(readlink -f "$REPO" 2>/dev/null || realpath "$REPO")"
mkdir -p "$REPO"

# Choose podman or docker
OCI="${CONTAINER_ENGINE:-}"
if [[ -z "$OCI" ]]; then
  if command -v podman >/dev/null 2>&1; then OCI=podman
  elif command -v docker >/dev/null 2>&1; then OCI=docker
  else echo "Need podman or docker"; exit 1; fi
fi

# Build images (context: this directory with Dockerfiles + importer script)
$OCI build -f Dockerfile.rocky9  -t rhel-kernel-import:rocky9 .
$OCI build -f Dockerfile.rocky10 -t rhel-kernel-import:rocky10 .

# Ensure work dirs exist on host (prevents root-owned parents from the nested mount)
mkdir -p "$REPO/.work"/{srpms,tmp,logs}
# Make sure you own them (in case a prior run created them as root)
chown "$(id -u):$(id -g)" "$REPO/.work" "$REPO/.work"/{srpms,tmp,logs} 2>/dev/null || true

# Shared SRPM cache on host (reused across runs)
CACHE="${CACHE:-$HOME/.cache/rhel-kernel-srpms}"
mkdir -p "$CACHE"

# SELinux-aware volume flags
V_REPO="$REPO:/work"
V_CACHE="$CACHE:/work/.work/srpms"
if [[ "$OCI" == "podman" ]]; then
  V_REPO="$REPO:/work:Z"
  V_CACHE="$CACHE:/work/.work/srpms:Z"
elif command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null || echo Permissive)" != "Disabled" ]]; then
  # Docker on SELinux hosts typically wants :z
  V_REPO="$REPO:/work:z"
  V_CACHE="$CACHE:/work/.work/srpms:z"
fi

# Extra run args (keep host uid/gid inside container)
RUN_ARGS=(-u "$(id -u):$(id -g)")
if [[ "$OCI" == "podman" ]]; then
  RUN_ARGS+=(--userns=keep-id)   # ensures file ownership maps cleanly on rootless podman
fi

run_one () {
  local tag="$1" major="$2"
  echo "[INFO] Importing RHEL $major kernel stream via $tag …"
  "$OCI" run --rm \
    "${RUN_ARGS[@]}" \
    -e MAJORS="$major" \
    -e MODE="${MODE:-prep}" \
    -v "$V_REPO" \
    -v "$V_CACHE" \
    "rhel-kernel-import:${tag}" \
    import-rhel-kernel-srpms.sh /work
}

run_one rocky9  9
run_one rocky10 10

echo "[INFO] Finished. Repo: $REPO"
echo "[INFO] Latest tags:"
git -C "$REPO" tag --list 'rhel*-*' | sort -V | tail -20
