# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository mirrors RHEL-compatible kernel sources from Rocky Linux SRPMs into a chronologically tagged Git repository. It's designed for downstream tooling (MCP/LLM servers) that need tagged snapshots for semantic search, symbol lookup, and call graphs.

## Repository Structure

- **`main` branch**: Minimal docs only (README.md, CHANGELOG.md, index.json)
- **`rhel9` / `rhel10` branches**: Full kernel source snapshots, one commit per SRPM version
- **Tags**: `rhel<major>-<version-release>` (e.g., `rhel9-5.14.0-570.52.1.el9_6`)

## Running the Import

### Via Container (Recommended)
```bash
# Requires podman or docker
./rhel-kernel-import-oci.sh /path/to/target/repo
```

This builds Rocky 9 and Rocky 10 container images, then runs the import for both RHEL streams.

### Direct Execution (Inside Container)
```bash
./import-rhel-kernel-srpms.sh /path/to/repo
```

Runs inside the container. Requires rpm-build tools and Rocky Linux environment.

### Linting

There is no test suite — the project is Bash plus two Dockerfiles. Before committing changes to the scripts:

```bash
shellcheck import-rhel-kernel-srpms.sh rhel-kernel-import-oci.sh
shfmt -i 2 -d import-rhel-kernel-srpms.sh rhel-kernel-import-oci.sh
```

`rhel-kernel-import-oci.sh` rebuilds the images on every run. It passes a `SCRIPT_HASH` build-arg so the image cache only invalidates when `import-rhel-kernel-srpms.sh` changes; Dockerfile edits invalidate normally. Use `REBUILD=1` to force a full no-cache rebuild.

## Key Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MAJORS` | `9 10` | RHEL major versions to import |
| `MODE` | `prep` | `prep` = full source tree; `sources` = raw SRPM contents |
| `ARCH` | `x86_64` | Target architecture for rpmbuild |
| `DEBUG` | `0` | Set to `1` for verbose output |
| `KEEP_SRPMS` | `1` | Keep downloaded SRPMs after import |
| `CONFIG_ARCHES` | `x86_64 ppc64le s390x` | Architectures for Kconfig export |
| `CONFIG_GENERATE` | `1` | Run `make olddefconfig` to resolve configs |

## Architecture

### Workflow
1. **Discovery**: Scrapes Rocky Linux mirrors/vault for kernel SRPMs
2. **Download**: Fetches missing SRPMs to `.work/srpms/`
3. **Prep**: Runs `rpm -Uvh` + `rpmbuild -bp` to expand source
4. **Config Export**: Optionally extracts per-arch Kconfig files to `metadata/configs/`
5. **Commit**: Creates orphan branch commit + annotated tag per version
6. **Index**: Updates `main` branch with CHANGELOG.md and index.json

### Key Functions in import-rhel-kernel-srpms.sh
- `gather_urls()`: Discovers SRPM URLs from Rocky mirrors
- `prep_srpm()`: Expands SRPM via rpmbuild -bp, returns source tree path
- `export_configs()`: Extracts/generates Kconfig files per architecture
- `commit_one()`: Creates commit + tag on the appropriate rhel branch
- `update_main()`: Refreshes CHANGELOG.md and index.json on main branch

### Directory Layout (Runtime)
```
.work/
├── srpms/          # Downloaded SRPMs (cached)
├── tmp/            # rpmbuild workdirs (pruned after 12h)
├── logs/           # Per-SRPM install/prep logs
└── config-export/  # Temporary Kconfig staging
```

## Key Design Decisions

These are non-obvious and easy to break:

- **`rpmbuild` runs with `--nodeps`** (both `rpm -Uvh` and `rpmbuild -bp`). Spec `BuildRequires` are *not* resolved — every tool the kernel `%prep` needs must be baked into the Dockerfiles. A missing build dependency does not fail up front; it fails deep inside `%prep` with a confusing error. Recent EL kernel specs convert secure-boot certs in `%prep` (`openssl x509 -in /usr/share/pki/sb-certs/*.der`), which is why the images install `rocky-sb-certs` from the `crb` repo. When a new kernel release starts failing `%prep`, suspect a newly-required build dependency.
- **Idempotent and resumable.** A version is imported only if its tag does not already exist; existing tags are skipped at discovery and again before commit. A failed `%prep` is logged and skipped (not fatal) so one bad SRPM never halts the run. Re-running the import retries everything that lacks a tag.
- **Commits are back-dated to SRPM build time.** `commit_one()` sets `GIT_AUTHOR_DATE`/`GIT_COMMITTER_DATE` from the SRPM's `%{BUILDTIME}`, so `git log` on a `rhel*` branch is ordered by actual build chronology, not import time.
- **Per-stream orphan branches.** Each `rhel<major>` branch is an orphan line of history. `commit_one()` wipes the worktree, rsyncs the freshly prepped source tree in, and makes one commit + annotated tag per version.
- **Spec compatibility shims.** `sanitize_spec_builtins()` rewrites EL9-era macros (`rpmversion`/`rpmrelease`) that collide with newer rpmbuild built-ins, and the import passes custom `--define`s (`uname_variant`, `uname_suffix`, `py3_shebang_fix`) so older specs prep cleanly on a current toolchain.
- **Config export avoids `mrproper`.** `export_configs()` seeds `.config` and runs `make olddefconfig` per arch, deleting only `.config`/`.config.old` — `mrproper` would remove the `Makefile` and break the tree.

## Debugging Failed Imports

- Per-SRPM logs live in `.work/logs/<nvr>.{install.log,bp.log,diag.txt}`. **`<nvr>.bp.log` is the `rpmbuild -bp` output** — the first place to look for a `%prep` failure (the actual error is at the tail).
- `.work/` is git-ignored *and* in `.git/info/exclude`, so `fd` and `rg` skip it by default. Pass `-I` / `--no-ignore` to search inside it.
- `DEBUG=1` enables `set -x`, `rpmbuild -vv`, and dumps the generated `%prep` script and BUILD tree into the logs.
- On a failed prep the `.work/tmp/rpmbuild-<nvr>/` workdir is *not* pruned (pruning only happens after a successful commit), so the expanded spec and sources remain available for inspection.
