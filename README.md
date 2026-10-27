# RHEL Kernel Source Timeline (Rocky-based)

This repository tracks RHEL-compatible kernel sources via publicly available **Rocky Linux** SRPMs.
It's designed for downstream tooling (e.g., MCP/LLM servers) that need tagged,
chronological snapshots of the kernel source for semantic search, symbol lookup, and call graphs.

## Layout

- **Branches**
  - **`rhel9`** — Full source snapshots by release for EL9.
  - **`rhel10`** — Full source snapshots by release for EL10.
- **Tags**
  - `rhel<major>-<version-release>` (e.g., `rhel9-5.14.0-570.52.1.el9_6`).
- **Main branch (`main`)**
  - Minimal docs: **README.md**, generated **AGENTS.md**, **CHANGELOG.md**, and **index.json**.
  - No large source trees are committed on `main`.

## Running the Import

### Container Method (Recommended)

The easiest way to run the import is via the container wrapper script, which handles building Rocky 9/10 images and running the import with proper mounts:

```bash
./rhel-kernel-import-oci.sh /path/to/target/repo
```

#### Requirements
- **podman** or **docker** (podman preferred; auto-detected)
- Sufficient disk space for SRPMs and expanded kernel trees

#### How It Works

1. **Builds container images** — Creates `rhel-kernel-import:rocky9` and `rhel-kernel-import:rocky10` images with rpm-build tools
2. **Mounts host directories** — The target repo and SRPM cache are bind-mounted into containers
3. **Runs import for each stream** — Executes the import script inside each container (Rocky 9 for RHEL9, Rocky 10 for RHEL10)

#### Host Mounts

| Host Path | Container Path | Purpose |
|-----------|----------------|---------|
| `/path/to/target/repo` | `/work` | Git repository output |
| `$CACHE` (see below) | `/work/.work/srpms` | Persistent SRPM cache |

#### SRPM Cache

Downloaded SRPMs are cached on the host and reused across runs:

- **Default location:** `$HOME/.cache/rhel-kernel-srpms`
- **Custom location:** Set the `CACHE` environment variable

```bash
# Use custom cache directory
CACHE=/mnt/storage/srpms ./rhel-kernel-import-oci.sh /path/to/repo

# Cache persists across runs — SRPMs won't be re-downloaded
```

#### Container Engine Selection

The script auto-detects podman or docker. To force a specific engine:

```bash
CONTAINER_ENGINE=docker ./rhel-kernel-import-oci.sh /path/to/repo
```

#### SELinux

Volume mounts use appropriate SELinux labels automatically:
- `:Z` for podman (private unshared label)
- `:z` for docker on SELinux-enabled hosts

### Direct Execution (Inside Container)

If running manually inside a Rocky Linux container with rpm-build tools:

```bash
./import-rhel-kernel-srpms.sh /path/to/repo

# Reuse an existing SRPM cache when running directly
CACHE=$HOME/.cache/rhel-kernel-srpms ./import-rhel-kernel-srpms.sh /path/to/repo
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CACHE` | `$HOME/.cache/rhel-kernel-srpms` | SRPM cache directory |
| `CONTAINER_ENGINE` | auto-detect | Force `podman` or `docker` |
| `REBUILD` | `0` | Set to `1` to force container image rebuild (no cache) |
| `MAJORS` | `9 10` | RHEL major versions to import |
| `MODE` | `prep` | `prep` = full source tree; `sources` = raw SRPM contents |
| `ARCH` | `x86_64` | Target architecture for rpmbuild |
| `DEBUG` | `0` | Set to `1` for verbose output |
| `KEEP_SRPMS` | `1` | Keep downloaded SRPMs after import |
| `CONFIG_ARCHES` | `x86_64 ppc64le s390x` | Architectures for Kconfig export |
| `CONFIG_GENERATE` | `1` | Run `make olddefconfig` to resolve configs |

## Import Workflow

1. **Discovery** — Scrapes Rocky Linux mirrors and vault for kernel SRPMs
2. **Download** — Fetches missing SRPMs to the cache directory
3. **Prep** — Runs `rpm -Uvh` + `rpmbuild -bp` to expand source trees
4. **Config Export** — Optionally extracts per-arch Kconfig files to `metadata/configs/`
5. **Commit** — Creates orphan branch commit + annotated tag per version
6. **Docs** — Regenerates `main` branch CHANGELOG.md and index.json

## Directory Layout (Runtime)

```
/path/to/repo/
├── .work/                  # Working directory (git-ignored)
│   ├── srpms/              # Mounted from host cache
│   ├── tmp/                # rpmbuild workdirs (auto-pruned after 12h)
│   └── logs/               # Per-SRPM install/prep logs
├── metadata/
│   └── configs/            # Per-arch Kconfig snapshots (if enabled)
│       ├── x86_64/
│       ├── ppc64le/
│       └── s390x/
└── .git/
```

Select architecture-specific configs from `metadata/configs/<arch>/<tag>/` in a
source snapshot, or `<arch>/latest/` when enabled. Generated files end in
`.resolved.config`; the other `.config` files are original seed inputs. Config
export leaves any original root `.config` unchanged, so it does not identify the
snapshot architecture. Temporary generation configs stay outside the source tree,
including when generation fails. Existing imported tags are unchanged.

## Quick Usage

In a generated mirror, start with `AGENTS.md` for the exact-release
consumer guide. It uses `index.json` to select the requested version-release,
searches the tag, reads an architecture-specific config at that commit, and
creates a detached sibling worktree. The guide is generated in the **output
mirror**, not this scanner checkout.

For example, from a mirror's documentation checkout:

```bash
# Select one exact catalog entry; report an absent release unavailable locally.
jq -e --arg nvr 'kernel-5.14.0-570.52.1.el9_6' \
  '.[] | select(.nvr == $nvr) | {tag, commit, configs}' index.json
```

Stream branch tips may be older backfills, so they do not identify the latest
release. Resolve config paths against the selected tag/commit and architecture;
root `.config` and `latest/` directories are not exact-release selectors. Cite
tag, full commit, file path and relevant lines. These are Rocky-derived sources;
that provenance does not establish exact Red Hat source equivalence.

## Refreshing Generated Documentation

Refresh an existing mirror without downloading or preparing SRPMs:

```bash
./import-rhel-kernel-srpms.sh --refresh-main /path/to/target/repo
```

Refresh regenerates `AGENTS.md`, `CHANGELOG.md`, and `index.json`. It copies
`README_MD_SOURCE` when that file exists (default: the output mirror's own
README), otherwise preserves the existing README, or creates a fallback README
linking to the consumer guide. Supplied and existing READMEs retain their content.
The generated guide is available independently of README customization.

`MAIN_ENFORCE_MINIMAL=1` removes other top-level output files except `.git`,
`.gitignore`, `README.md`, `AGENTS.md`, `CHANGELOG.md`, `index.json`, and the working
directory basename. Use it only on an output mirror whose other files may be
removed. The refresh commits generated documentation on `MAIN_BRANCH` (default
`main`); tagged source/config snapshots are unchanged.
